// flag-cctv-e2e (W3): the app side of CCTV alert -> action, found by the
// emulator flow (integration_test/flows/cctv_alert_flow.dart):
//  * the alert photo: a NETWORK failure no longer says "deleted after the
//    keep period" — it says it did not load, offers Try again and retries by
//    itself; only 403 / 404 / 410 is "deleted"; a slow (2G) load says so
//  * the alerts list retries BY ITSELF after an offline error
//  * one notification per CCTV alert (a resend replaces it), and the photo is
//    only fetched from our own server
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/push/push_notifier.dart';
import 'package:assisto/push/push_payload.dart';
import 'package:assisto/screens/watchman/alert_snapshot.dart';
import 'package:assisto/screens/watchman/watchman_alerts.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'cctv1_fakes.dart';
import 'fake_api.dart';

AppState _state() {
  final s = AppState();
  s.api = FakeApi();
  s.user = AppUser(id: 1, name: 'A', phone: '01712345678', email: '', autonomyLevel: 2, language: 'en');
  s.locale = const Locale('en');
  s.loading = false;
  return s;
}

Widget _app(Widget home, {String lang = 'en'}) => ChangeNotifierProvider<AppState>.value(
      value: _state(),
      child: MaterialApp(
        locale: Locale(lang),
        theme: AssistoTheme.light,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: home,
      ),
    );

/// An image that fails like the network would (statusCode 0 = no answer).
class _FailImage extends ImageProvider<_FailImage> {
  final int code;
  const _FailImage(this.code);
  @override
  Future<_FailImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(_FailImage key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(Future<ImageInfo>.error(
          NetworkImageLoadException(statusCode: code, uri: Uri.parse('http://10.0.2.2/x.jpg'))));
  @override
  bool operator ==(Object other) => other is _FailImage && other.code == code;
  @override
  int get hashCode => code.hashCode;
}

/// An image that never arrives (a stalled 2G download).
class _SlowImage extends ImageProvider<_SlowImage> {
  const _SlowImage();
  @override
  Future<_SlowImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(_SlowImage key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(Completer<ImageInfo>().future);
}

Widget _snap(ImageProvider img, {String lang = 'en'}) => _app(
    Scaffold(body: SizedBox(width: 360, height: 203, child: AlertSnapshot(url: 'x', debugImage: img))),
    lang: lang);

/// Flaky network: the first [fails] loads throw like an offline phone.
class _Flaky extends FakeWatchman {
  int fails;
  int loads = 0;
  _Flaky(this.fails) : super('data');
  @override
  Future<Map<String, dynamic>> events(int siteId) async {
    loads++;
    if (fails > 0) {
      fails--;
      throw ApiException('No internet connection.', 0);
    }
    return super.events(siteId);
  }
}

void main() {
  setUp(() {
    AlertSnapshot.retryAfterS = const [5, 15, 30];
    AlertSnapshot.slowAfter = const Duration(seconds: 3);
  });

  group('alert photo states', () {
    testWidgets('network failure: "did not load" + Try again, never "deleted"', (tester) async {
      final t = lookupAppLocalizations(const Locale('en'));
      await tester.pumpWidget(_snap(const _FailImage(0)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('wm-snap-error')), findsOneWidget);
      expect(find.text(t.caeSnapFailed), findsOneWidget);
      expect(find.text(t.wmSnapshotGone), findsNothing);
      expect(find.byKey(const ValueKey('wm-snap-retry')), findsOneWidget);
      expect(tester.getSize(find.byKey(const ValueKey('wm-snap-retry'))).height, greaterThanOrEqualTo(48));
      // Try again starts a fresh load
      await tester.tap(find.byKey(const ValueKey('wm-snap-retry')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('wm-snap-error')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 2)); // no timer left behind
    });

    testWidgets('it retries by itself after a network failure', (tester) async {
      AlertSnapshot.retryAfterS = const [1];
      await tester.pumpWidget(_snap(const _FailImage(0)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final img1 = find.byKey(const ValueKey('wm-snap-img-0'));
      expect(img1, findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('wm-snap-img-1')), findsOneWidget, reason: 'an automatic retry');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 1));
    });

    testWidgets('404 / 410 is the honest "deleted after the keep period"', (tester) async {
      final t = lookupAppLocalizations(const Locale('en'));
      for (final code in [404, 410]) {
        await tester.pumpWidget(_snap(_FailImage(code)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text(t.wmSnapshotGone), findsOneWidget);
        expect(find.byKey(const ValueKey('wm-snap-retry')), findsNothing);
      }
    });

    testWidgets('2G: a loading bar, then "slow network" after 3 s (bn too)', (tester) async {
      for (final lang in ['en', 'bn']) {
        final t = lookupAppLocalizations(Locale(lang));
        await tester.pumpWidget(_snap(const _SlowImage(), lang: lang));
        await tester.pump();
        expect(find.byKey(const ValueKey('wm-snap-loading')), findsOneWidget);
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        expect(find.text(t.caeSnapSlow), findsNothing);
        await tester.pump(const Duration(seconds: 3));
        await tester.pump();
        expect(find.text(t.caeSnapSlow), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
    });
  });

  // cctv-preview: the small photo shows first; the full one only adds a thin bar
  testWidgets('2G: the <= 20 KB preview shows first, the full photo keeps loading', (tester) async {
    final png = MemoryImage(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII='));
    final phases = <String>[];
    AlertSnapshot.debugOnPhase = phases.add;
    addTearDown(() => AlertSnapshot.debugOnPhase = null);
    await tester.pumpWidget(_app(Scaffold(
        body: SizedBox(
            width: 360,
            height: 203,
            child: AlertSnapshot(url: 'x', debugImage: const _SlowImage(), debugPreview: png)))));
    await tester.runAsync(() async {
      await precacheImage(png, tester.element(find.byType(AlertSnapshot)));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('wm-snap-preview')), findsOneWidget);
    expect(find.byKey(const ValueKey('wm-snap-loading-full')), findsOneWidget);
    expect(find.byKey(const ValueKey('wm-snap-loading')), findsNothing);
    expect(phases, contains('preview'));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('alerts list: offline error, then loads BY ITSELF (no tap)', (tester) async {
    final t = lookupAppLocalizations(const Locale('en'));
    final src = _Flaky(2);
    await tester.pumpWidget(_app(WatchmanAlertsScreen(source: src, siteId: 1, owner: true)));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('wm-alerts-autoretry')), findsOneWidget);
    expect(find.text(t.caeAutoRetry), findsOneWidget);
    await tester.pump(const Duration(seconds: 5)); // 1st automatic retry -> still offline
    await tester.pump(const Duration(milliseconds: 200));
    expect(src.loads, 2);
    await tester.pump(const Duration(seconds: 10)); // 2nd -> back online
    await tester.pump(const Duration(milliseconds: 200));
    expect(src.loads, 3);
    expect(find.byKey(const ValueKey('wm-alerts-autoretry')), findsNothing);
    expect(find.textContaining('Front door'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  group('the CCTV notification', () {
    test('one notification per alert: a resend replaces it', () {
      final a = PushPayload.fromData({'kind': 'shop_alert', 'event_id': '7', 'sent_at': '100'});
      final b = PushPayload.fromData({'kind': 'shop_alert', 'event_id': '7', 'sent_at': '160'});
      final c = PushPayload.fromData({'kind': 'shop_alert', 'event_id': '8', 'sent_at': '160'});
      expect(a.notificationId, b.notificationId);
      expect(a.notificationId, isNot(c.notificationId));
    });

    test('the alert photo is fetched only from our own server', () {
      const base = 'https://api.lifeassisto.com';
      expect(PushNotifier.cctvPhotoUrlOk('https://api.lifeassisto.com/media/s/1.jpg?sig=x', apiBase: base), isTrue);
      expect(PushNotifier.cctvPhotoUrlOk('https://evil.example/1.jpg', apiBase: base), isFalse);
      expect(PushNotifier.cctvPhotoUrlOk('http://api.lifeassisto.com/1.jpg', apiBase: base), isFalse);
      expect(PushNotifier.cctvPhotoUrlOk('', apiBase: base), isFalse);
      // the CI / debug backend (plain http on its own port)
      expect(PushNotifier.cctvPhotoUrlOk('http://10.0.2.2:8700/media/1.jpg', apiBase: 'http://10.0.2.2:8700'),
          isTrue);
    });
  });
}
