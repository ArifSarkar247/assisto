// cctvphone: an old Android phone as an Assisto camera — pure rules
// (pairing code, rolling clip store, dark/covered, person-or-motion alert,
// health report) + the camera-phone screens, the owner's pairing sheet and
// the live-view link at 200% text, bn/en, light/dark.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/phonecam/phone_camera_screen.dart';
import 'package:assisto/phonecam/phonecam_link.dart';
import 'package:assisto/phonecam/phonecam_logic.dart';
import 'package:assisto/phonecam/phonecam_pair_sheet.dart';
import 'package:assisto/theme.dart';

import 'phonecam_shots.dart';

Widget _app(Widget home, {String lang = 'en', double scale = 1.0, bool dark = false}) =>
    MaterialApp(
      key: UniqueKey(),
      locale: Locale(lang),
      theme: dark ? AssistoTheme.dark : AssistoTheme.light,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
      home: home,
    );

Future<void> _settle(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void _phone(WidgetTester tester, {double height = 800}) {
  tester.view.physicalSize = Size(360 * 3, height * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

late AppLocalizations en;
late AppLocalizations bn;

void main() {
  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
    bn = await AppLocalizations.delegate.load(const Locale('bn'));
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('pairing code (mirrors core/logic/phonecam.py)', () {
    test('normalises typed, scanned and link forms', () {
      expect(normalizePairCode('12-HK7P4Q'), '12-HK7P4Q');
      expect(normalizePairCode(' 12 hk7p4q '), '12-HK7P4Q');
      expect(normalizePairCode('12HK7P4Q'), '12-HK7P4Q');
      expect(normalizePairCode('https://lifeassisto.com/pc/12-HK7P4Q'), '12-HK7P4Q');
      expect(normalizePairCode('/pc/012-HK7P4Q'), '12-HK7P4Q');
      expect(normalizePairCode('12-HK7P40'), isNull); // 0 is not in the alphabet
      expect(normalizePairCode('HK7P4Q'), isNull);
      expect(normalizePairCode(''), isNull);
      expect(normalizePairCode(null), isNull);
    });

    test('only our App Link is a pairing link', () {
      expect(pairCodeFromLink('/pc/7-ABCDEF'), '7-ABCDEF');
      expect(pairCodeFromLink('https://lifeassisto.com/pc/7-ABCDEF'), '7-ABCDEF');
      expect(pairCodeFromLink('/i/7-ABCDEF'), isNull);
      expect(pairCodeFromLink('https://evil.example/pc/7-ABCDEF'), isNull);
      expect(PhoneCamLink.route(const RouteSettings(name: '/photo/app')), isNull);
    });
  });

  group('rolling clip store', () {
    final t0 = DateTime(2026, 11, 3);
    ClipFile c(String p, int mb, int min) => ClipFile(p, mb * 1024 * 1024, t0.add(Duration(minutes: min)));

    test('deletes oldest first until the new clip fits', () {
      final clips = [c('b', 200, 2), c('a', 200, 1), c('c', 200, 3)];
      final del = clipsToDelete(clips, 500 * 1024 * 1024, incomingBytes: 50 * 1024 * 1024);
      expect(del.map((e) => e.path), ['a', 'b']);
    });

    test('nothing to delete under the cap; total bytes', () {
      final clips = [c('a', 10, 1), c('b', 10, 2)];
      expect(clipsToDelete(clips, 500 * 1024 * 1024), isEmpty);
      expect(clipsTotalBytes(clips), 20 * 1024 * 1024);
    });
  });

  group('dark / covered lens', () {
    test('dark only after the hold time; light clears it at once', () {
      final m = DarkMonitor(threshold: 14, hold: const Duration(seconds: 60));
      final t = DateTime(2026, 11, 3, 22);
      expect(m.feed(5, t), isFalse);
      expect(m.feed(5, t.add(const Duration(seconds: 30))), isFalse);
      expect(m.feed(5, t.add(const Duration(seconds: 61))), isTrue);
      expect(m.feed(120, t.add(const Duration(seconds: 62))), isFalse);
      expect(DarkMonitor.meanOf(Float64List.fromList([10, 20, 30])), 20);
    });
  });

  group('alert decision', () {
    test('person model: a person box -> person_detected with conf', () {
      final a = phoneAlert(modelAvailable: true, boxes: [
        [0.1, 0.1, 0.4, 0.9, 0.62],
        [0.5, 0.2, 0.7, 0.8, 0.81],
      ]);
      expect(a!.type, 'person_detected');
      expect(a.signals['conf'], 0.81);
      expect(a.signals['persons'], 2);
    });

    test('person model, nobody -> no alert (a curtain is not a person)', () {
      expect(phoneAlert(modelAvailable: true, boxes: const []), isNull);
      expect(phoneAlert(modelAvailable: true, boxes: null), isNull);
    });

    test('no model -> honest motion-only alert', () {
      final a = phoneAlert(modelAvailable: false);
      expect(a!.type, 'motion');
      expect(a.signals['person_check'], 'unavailable');
    });
  });

  group('health', () {
    test('report keeps known values only', () {
      expect(healthReport({'level': 55.4, 'charging': false, 'temp_c': 41.26}, dark: false),
          {'dark': false, 'level': 55, 'charging': false, 'temp_c': 41.3});
      expect(healthReport(null, dark: true), {'dark': true});
    });

    test('local warnings use the server thresholds', () {
      expect(localWarnings({'charging': false, 'level': 15, 'temp_c': 46.0, 'dark': true}),
          ['unplugged', 'low_battery', 'hot', 'dark']);
      expect(localWarnings({'charging': true, 'level': 5, 'temp_c': 30.0, 'dark': false}), isEmpty);
    });
  });

  group('camera-phone screen', () {
    testWidgets('unpaired: code field; a wrong code is an honest error, no network', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(const PhoneCameraScreen(preview: PhoneCamPreview(paired: false))));
      await _settle(tester);
      expect(find.byKey(const Key('pcCodeField')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('pcCodeField')), 'abc');
      await tester.tap(find.byKey(const Key('pcClaim')));
      await _settle(tester);
      expect(find.text(en.pcCodeInvalid), findsOneWidget);
    });

    testWidgets('App Link code is pre-filled', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(const PhoneCameraScreen(
          initialCode: '/pc/12-hk7p4q', preview: PhoneCamPreview(paired: false))));
      await _settle(tester);
      expect(find.text('12-HK7P4Q'), findsOneWidget);
    });

    testWidgets('paired: start, sound consent OFF by default, unbind', (tester) async {
      _phone(tester, height: 1400);
      await tester.pumpWidget(_app(const PhoneCameraScreen(preview: PhoneCamPreview(camera: 'Gate'))));
      await _settle(tester);
      expect(find.byKey(const Key('pcStart')), findsOneWidget);
      final sw = tester.widget<SwitchListTile>(find.byKey(const Key('pcAudio')));
      expect(sw.value, isFalse);
      expect(find.byKey(const Key('pcUnbind')), findsOneWidget);
    });

    testWidgets('running: the recording notice is always on screen', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(const PhoneCameraScreen(
          preview: PhoneCamPreview(running: true, warnings: ['unplugged'], model: false))));
      await _settle(tester);
      expect(find.byKey(const Key('pcRecordingBanner')), findsOneWidget);
      expect(find.text(en.pcRecordingBanner), findsOneWidget);
      expect(find.text(en.pcWarnUnplugged), findsOneWidget);
      expect(find.text(en.pcModelOff), findsOneWidget);
      expect(find.byKey(const Key('pcStop')), findsOneWidget);
      await tester.tap(find.byKey(const Key('pcStop')));
      await _settle(tester);
      expect(find.byKey(const Key('pcStart')), findsOneWidget);
    });

    testWidgets('sound consent ON says so in the banner (bn)', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(
          const PhoneCameraScreen(preview: PhoneCamPreview(running: true, audio: true)),
          lang: 'bn'));
      await _settle(tester);
      expect(find.text(bn.pcRecordingBannerAudio), findsOneWidget);
    });
  });

  group('owner pairing sheet', () {
    testWidgets('shows QR + code, then the new camera', (tester) async {
      _phone(tester, height: 1400);
      var calls = 0;
      Future<Map<String, dynamic>> load() async {
        calls++;
        final d = await pcFakePair();
        return {
          ...d,
          'cameras': calls < 2
              ? const []
              : [
                  {'id': 9, 'name': 'Gate'}
                ],
        };
      }

      await tester.pumpWidget(_app(Scaffold(
          body: PhoneCamPairSheet(load: load, pollEvery: const Duration(milliseconds: 200)))));
      await _settle(tester, 3);
      expect(find.byKey(const Key('pcPairCode')), findsOneWidget);
      expect(find.text('12-HK7P4Q'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 250));
      await _settle(tester, 3);
      expect(find.byKey(const Key('pcPairDone')), findsOneWidget);
      expect(find.text(en.pcPairDone('Gate')), findsOneWidget);
    });

    testWidgets('validity timer uses Bangla digits in Bangla', (tester) async {
      _phone(tester, height: 1400);
      await tester.pumpWidget(
          _app(const Scaffold(body: PhoneCamPairSheet(load: pcFakePair)), lang: 'bn'));
      await _settle(tester, 3);
      expect(find.text(bn.pcCodeValid('১২:২২')), findsOneWidget);
    });

    testWidgets('a server error is shown with Retry (no dead end)', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(Scaffold(
          body: PhoneCamPairSheet(load: () async => throw StateError('Not found.')))));
      await _settle(tester, 3);
      expect(find.text(en.retry), findsOneWidget);
    });
  });

  for (final lang in ['bn', 'en']) {
    for (final dark in [false, true]) {
      testWidgets('phone camera screens at 200% text — $lang ${dark ? 'dark' : 'light'}',
          (tester) async {
        _phone(tester, height: 800);
        for (final e in phonecamShots.entries) {
          await tester.pumpWidget(_app(e.value(lang), lang: lang, scale: 2.0, dark: dark));
          await _settle(tester, 6);
          final err = tester.takeException();
          expect(err, isNull, reason: '${e.key} ($lang, 2.0x): $err');
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
        unawaited(Future<void>.value());
      });
    }
  }
}
