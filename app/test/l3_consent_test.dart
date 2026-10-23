// L3 — Google UMP consent gate. The plugin sits behind [ConsentBridge]; these
// tests never touch google_mobile_ads. They prove:
//  * no AdMob app id in the APK (today) -> the whole flow is a no-op: no
//    consent call, no Settings entry;
//  * with a real app id, NO ad request happens before consent, and none at all
//    when canRequestAds() is false / UMP is not linked;
//  * the Settings "Ad privacy choices" entry exists only while UMP says the
//    privacy-options entry point is REQUIRED, and re-opens the form.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/ads/ad_privacy_tile.dart';
import 'package:assisto/ads/ads_bridge.dart';
import 'package:assisto/ads/ads_service.dart';
import 'package:assisto/ads/consent.dart';
import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/state.dart';

// Shape-valid but made-up id (never a real publisher).
const _fakeRealAppId = 'ca-app-pub-1111111111111111~2222222222';

class _Log {
  final calls = <String>[];
}

class _FakeConsent implements ConsentBridge {
  _FakeConsent(this.log,
      {this.updateOk = true,
      this.canRequest = true,
      this.status = PrivacyOptionsStatus.notRequired,
      this.formOk = true});
  final _Log log;
  bool updateOk;
  bool canRequest;
  PrivacyOptionsStatus status;
  bool formOk;
  bool? lastDebugEea;
  List<String>? lastDevices;

  @override
  bool get linked => true;
  @override
  Future<bool> requestUpdate(
      {required bool debugEea, required List<String> testDeviceIds}) async {
    log.calls.add('consent.update');
    lastDebugEea = debugEea;
    lastDevices = testDeviceIds;
    return updateOk;
  }

  @override
  Future<void> loadAndShowIfRequired() async => log.calls.add('consent.form');
  @override
  Future<bool> canRequestAds() async {
    log.calls.add('consent.canRequestAds');
    return canRequest;
  }

  @override
  Future<PrivacyOptionsStatus> privacyOptionsStatus() async {
    log.calls.add('consent.status');
    return status;
  }

  @override
  Future<bool> showPrivacyOptionsForm() async {
    log.calls.add('consent.privacyForm');
    return formOk;
  }
}

class _FakeAds implements AdsBridge {
  _FakeAds(this.log);
  final _Log log;
  @override
  bool get linked => true;
  @override
  Future<bool> init() async {
    log.calls.add('ads.init');
    return true;
  }

  @override
  Future<bool> showAppOpen(String unitId) async {
    log.calls.add('ads.appOpen');
    return true;
  }

  @override
  Future<RewardOutcome> showRewarded(String unitId) async {
    log.calls.add('ads.rewarded');
    return RewardOutcome.earned;
  }
}

class _Api extends ApiClient {
  _Api({this.paid = false, this.debugEea = false}) {
    token = 't';
  }
  final bool paid;
  final bool debugEea;
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path == '/ads/config') {
      return {
        'configured': false,
        'app_id': '',
        'units': const {},
        'plan': paid ? 'premium' : 'free',
        'paid': paid,
        'rewarded_enabled': true,
        'consent_debug_eea': debugEea,
        'consent_test_devices': debugEea ? ['ABCDEF0123456789'] : const [],
      };
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
          [Map<String, dynamic> body = const {}]) async =>
      {'ok': true};
}

AppState _app({bool paid = false, bool debugEea = false}) {
  final app = AppState();
  app.api = _Api(paid: paid, debugEea: debugEea);
  app.user = AppUser(
      id: 1, name: 'A', phone: '0', email: '', autonomyLevel: 2, language: 'en');
  app.loading = false;
  return app;
}

Widget _host(AppState app, Widget child) => ChangeNotifierProvider.value(
      value: app,
      child: MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(body: ListView(children: [child])),
      ),
    );

void main() {
  late _Log log;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AdsService.instance.resetForTest();
    AdConsent.instance.resetForTest();
    log = _Log();
  });

  group('no AdMob app id in the APK (today)', () {
    test('the built app id is Google\'s test id -> flow inactive', () {
      expect(AdConsent.instance.active, isFalse);
      expect(AdConsent.isRealAppId('ca-app-pub-3940256099942544~3347511713'),
          isFalse);
      expect(AdConsent.isRealAppId(''), isFalse);
      expect(AdConsent.isRealAppId('garbage'), isFalse);
      expect(AdConsent.isRealAppId(_fakeRealAppId), isTrue);
    });

    test('allowsAds is a no-op: nothing reaches the consent SDK', () async {
      AdConsent.instance.resetForTest(bridge: _FakeConsent(log));
      expect(await AdConsent.instance.allowsAds(), isTrue);
      await AdConsent.instance.refreshPrivacyStatus();
      expect(await AdConsent.instance.showPrivacyOptions(), isFalse);
      expect(log.calls, isEmpty);
      expect(AdConsent.instance.privacyOptionsRequired.value, isFalse);
    });

    testWidgets('rewarded (Google TEST unit in debug) never calls UMP',
        (tester) async {
      AdConsent.instance.resetForTest(bridge: _FakeConsent(log));
      AdsService.instance.bridge = _FakeAds(log);
      final out = await AdsService.instance
          .showRewarded(_app(), screen: 'credits');
      expect(out, RewardOutcome.earned);
      expect(log.calls, ['ads.rewarded']);
    });

    testWidgets('Settings: no "Ad privacy choices" entry, no consent call',
        (tester) async {
      AdConsent.instance.resetForTest(
          bridge: _FakeConsent(log, status: PrivacyOptionsStatus.required));
      await tester.pumpWidget(_host(_app(), const AdPrivacyTile()));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-ad-privacy')), findsNothing);
      expect(log.calls, isEmpty);
    });
  });

  group('real AdMob app id', () {
    testWidgets('consent is gathered BEFORE the ad request', (tester) async {
      AdConsent.instance
          .resetForTest(appId: _fakeRealAppId, bridge: _FakeConsent(log));
      AdsService.instance.bridge = _FakeAds(log);
      final out = await AdsService.instance
          .showRewarded(_app(), screen: 'credits');
      expect(out, RewardOutcome.earned);
      expect(log.calls, [
        'consent.update',
        'consent.form',
        'consent.status',
        'consent.canRequestAds',
        'ads.rewarded',
      ]);
    });

    testWidgets('canRequestAds false -> no ad request at all', (tester) async {
      AdConsent.instance.resetForTest(
          appId: _fakeRealAppId, bridge: _FakeConsent(log, canRequest: false));
      AdsService.instance.bridge = _FakeAds(log);
      final out = await AdsService.instance
          .showRewarded(_app(), screen: 'credits');
      expect(out, RewardOutcome.unavailable);
      expect(log.calls.where((c) => c.startsWith('ads.')), isEmpty);
    });

    testWidgets('UMP not linked -> fail closed (no ad, no rewarded entry)',
        (tester) async {
      AdConsent.instance.resetForTest(
          appId: _fakeRealAppId, bridge: const NoopConsentBridge());
      AdsService.instance.bridge = _FakeAds(log);
      final app = _app();
      expect(await AdsService.instance.showRewarded(app, screen: 'credits'),
          RewardOutcome.unavailable);
      expect(await AdsService.instance.rewardedAvailable(app), isFalse);
      expect(log.calls, isEmpty);
    });

    test('update failed but earlier consent still valid -> canRequestAds decides',
        () async {
      final b = _FakeConsent(log, updateOk: false, canRequest: true);
      AdConsent.instance.resetForTest(appId: _fakeRealAppId, bridge: b);
      expect(await AdConsent.instance.allowsAds(), isTrue);
      expect(log.calls.contains('consent.form'), isFalse);
    });

    test('one consent update per session, concurrent callers share it',
        () async {
      AdConsent.instance
          .resetForTest(appId: _fakeRealAppId, bridge: _FakeConsent(log));
      final r = await Future.wait(
          [AdConsent.instance.allowsAds(), AdConsent.instance.allowsAds()]);
      expect(r, [true, true]);
      await AdConsent.instance.allowsAds();
      expect(log.calls.where((c) => c == 'consent.update').length, 1);
    });

    testWidgets('Owner Admin debug EEA + test devices reach the UMP request',
        (tester) async {
      final b = _FakeConsent(log);
      AdConsent.instance.resetForTest(appId: _fakeRealAppId, bridge: b);
      AdsService.instance.bridge = _FakeAds(log);
      await AdsService.instance
          .showRewarded(_app(debugEea: true), screen: 'credits');
      expect(b.lastDebugEea, isTrue);
      expect(b.lastDevices, ['ABCDEF0123456789']);
    });

    testWidgets('Settings entry hidden when not required', (tester) async {
      AdConsent.instance.resetForTest(
          appId: _fakeRealAppId,
          bridge: _FakeConsent(log, status: PrivacyOptionsStatus.notRequired));
      await tester.pumpWidget(_host(_app(), const AdPrivacyTile()));
      await tester.pumpAndSettle();
      expect(log.calls.contains('consent.status'), isTrue);
      expect(log.calls.contains('consent.form'), isFalse); // no form from Settings
      expect(find.byKey(const Key('settings-ad-privacy')), findsNothing);
    });

    testWidgets('paid user: Settings asks UMP nothing', (tester) async {
      AdConsent.instance.resetForTest(
          appId: _fakeRealAppId,
          bridge: _FakeConsent(log, status: PrivacyOptionsStatus.required));
      await tester.pumpWidget(_host(_app(paid: true), const AdPrivacyTile()));
      await tester.pumpAndSettle();
      expect(log.calls, isEmpty);
      expect(find.byKey(const Key('settings-ad-privacy')), findsNothing);
    });

    testWidgets('required -> entry shown; tap re-opens the privacy form',
        (tester) async {
      AdConsent.instance.resetForTest(
          appId: _fakeRealAppId,
          bridge: _FakeConsent(log, status: PrivacyOptionsStatus.required));
      await tester.pumpWidget(_host(_app(), const AdPrivacyTile()));
      await tester.pumpAndSettle();
      final t = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(t.l3AdPrivacyTitle), findsOneWidget);
      await tester.tap(find.byKey(const Key('settings-ad-privacy')));
      await tester.pumpAndSettle();
      expect(log.calls.contains('consent.privacyForm'), isTrue);
      expect(find.text(t.l3AdPrivacyFailed), findsNothing);
    });

    testWidgets('privacy form error -> honest message', (tester) async {
      AdConsent.instance.resetForTest(
          appId: _fakeRealAppId,
          bridge: _FakeConsent(log,
              status: PrivacyOptionsStatus.required, formOk: false));
      await tester.pumpWidget(_host(_app(), const AdPrivacyTile()));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-ad-privacy')));
      await tester.pumpAndSettle();
      final t = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(t.l3AdPrivacyFailed), findsOneWidget);
    });
  });
}
