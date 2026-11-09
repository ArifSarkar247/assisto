// cctvbox: Guard Box for IP cameras without a PC — pure rules (alert, cool
// downs, health incl. "camera lost", live pacing), brand presets + ONVIF
// GetStreamUri, and the screen at 200% text, bn/en, light/dark.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:assisto/ipcam/ipcam_guard_screen.dart';
import 'package:assisto/ipcam/ipcam_logic.dart';
import 'package:assisto/ipcam/ipcam_presets.dart';
import 'package:assisto/ipcam/rtsp_client.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/theme.dart';

import 'ipcam_shots.dart';

Widget _app(Widget home, {String lang = 'en', double scale = 1.0, bool dark = false}) => MaterialApp(
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
      builder: (ctx, child) =>
          MediaQuery(data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
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

  group('alert rules (same as the phone camera)', () {
    test('person model: only a person alerts; source says IP camera via phone', () {
      expect(ipcamAlert(modelAvailable: true, boxes: const []), isNull);
      final a = ipcamAlert(modelAvailable: true, boxes: const [
        [0.1, 0.1, 0.3, 0.9, 0.71],
        [0.5, 0.1, 0.7, 0.9, 0.52],
      ], brand: 'hikvision')!;
      expect(a.type, 'person_detected');
      expect(a.signals['source'], 'ip_camera_via_phone');
      expect(a.signals['persons'], 2);
      expect(a.signals['conf'], 0.71);
      expect(a.signals['camera_brand'], 'hikvision');
    });

    test('no model: honest motion alert', () {
      final a = ipcamAlert(modelAvailable: false)!;
      expect(a.type, 'motion');
      expect(a.signals['person_check'], 'unavailable');
      expect(a.signals.containsKey('camera_brand'), isFalse);
    });

    test('cool downs: 60 s person / 3 min motion; checks at most every 5 s', () {
      final c = AlertClock();
      final t0 = DateTime(2026, 11, 9, 20);
      expect(c.mayCheck(t0, model: true), isTrue);
      c.lastCheck = t0;
      expect(c.mayCheck(t0.add(const Duration(seconds: 3)), model: true), isFalse);
      expect(c.mayCheck(t0.add(const Duration(seconds: 6)), model: true), isTrue);
      c.lastAlert = t0;
      expect(c.mayCheck(t0.add(const Duration(seconds: 59)), model: true), isFalse);
      expect(c.mayCheck(t0.add(const Duration(seconds: 61)), model: true), isTrue);
      expect(c.mayCheck(t0.add(const Duration(seconds: 61)), model: false), isFalse);
      expect(c.mayCheck(t0.add(const Duration(minutes: 3, seconds: 1)), model: false), isTrue);
    });

    test('health: battery + dark; camera lost only after 2 minutes', () {
      final t0 = DateTime(2026, 11, 9, 20);
      final h = ipcamHealth({'level': 55.4, 'charging': true, 'temp_c': 31.26}, dark: false,
          lostSince: t0, now: t0.add(const Duration(seconds: 90)));
      expect(h, {'dark': false, 'level': 55, 'charging': true, 'temp_c': 31.3});
      final l = ipcamHealth(null, dark: false, lostSince: t0, now: t0.add(const Duration(minutes: 2)));
      expect(l['cam_lost'], isTrue);
    });

    test('offline queue: newest 20 kept, sent oldest first, stops while still offline', () async {
      final q = OfflineQueue<int>(max: 3);
      for (var i = 1; i <= 5; i++) {
        q.add(i);
      }
      expect(q.length, 3);
      expect(q.droppedOld, 2);
      final sent = <int>[];
      var up = false;
      expect(await q.flush((i) async => up), 0);
      up = true;
      expect(await q.flush((i) async {
        sent.add(i);
        return true;
      }), 3);
      expect(sent, [3, 4, 5]);
      expect(q.isEmpty, isTrue);
    });

    test('live pacing: SD 640 / HD 1280, 4 pictures a second', () {
      final p = LivePace();
      expect(p.maxW, 640);
      p.hd = true;
      expect(p.maxW, 1280);
      expect(p.every, const Duration(milliseconds: 250));
    });
  });

  group('brand presets', () {
    test('sub stream first for every brand; credentials encoded; custom port', () {
      expect(brandUrls('hikvision', '192.168.1.64', 'admin', 'p@ss'), [
        'rtsp://admin:p%40ss@192.168.1.64/Streaming/Channels/102',
        'rtsp://admin:p%40ss@192.168.1.64/Streaming/Channels/101',
      ]);
      expect(brandUrls('imou', '10.0.0.9:10554', 'admin', 'L2ABCD').first,
          'rtsp://admin:L2ABCD@10.0.0.9:10554/cam/realmonitor?channel=1&subtype=1');
      expect(brandUrls('tapo', '10.0.0.7', 'cam', 'x').first, 'rtsp://cam:x@10.0.0.7/stream2');
      expect(brandUrls('ezviz', '10.0.0.8', 'admin', 'ABCDEF').first,
          'rtsp://admin:ABCDEF@10.0.0.8/h264/ch1/sub/av_stream');
      expect(brandUrls('dahua', '', 'a', 'b'), isEmpty);
      for (final b in ['hikvision', 'dahua', 'imou', 'ezviz', 'tapo']) {
        for (final u in brandUrls(b, '192.168.0.10', 'admin', 'pw')) {
          final p = RtspUrl.parse(u)!;
          expect(p.host, '192.168.0.10');
          expect(p.pass, 'pw');
        }
      }
      expect(defaultUser('tapo'), '');
      expect(defaultUser('imou'), 'admin');
    });

    test('brand guessed from the ONVIF name; credentials added to an ONVIF URI', () {
      expect(guessBrand('HIKVISION DS-2CD1023G0E-I'), 'hikvision');
      expect(guessBrand('IPC-HFW1230S'), 'dahua');
      expect(guessBrand('IMOU Bullet 2'), 'imou');
      expect(guessBrand('Tapo C200'), 'tapo');
      expect(guessBrand('Generic'), 'onvif');
      expect(withCreds('rtsp://10.0.0.5:554/live/ch00_1', 'admin', 'a b'), 'rtsp://admin:a%20b@10.0.0.5/live/ch00_1');
      expect(withCreds('rtsp://u:p@10.0.0.5/x', 'admin', 'zzz'), 'rtsp://u:p@10.0.0.5/x');
    });

    test('ONVIF GetStreamUri: sub profile first, credentials added', () async {
      final calls = <String>[];
      final client = MockClient((req) async {
        final b = req.body;
        if (b.contains('GetCapabilities')) {
          calls.add('caps');
          return http.Response(
              '<tds:Capabilities><tt:Media><tt:XAddr>http://10.0.0.5/onvif/media</tt:XAddr></tt:Media></tds:Capabilities>',
              200);
        }
        if (b.contains('GetProfiles')) {
          calls.add('profiles');
          return http.Response('<trt:Profiles token="main"/><trt:Profiles token="sub"/>', 200);
        }
        if (b.contains('GetStreamUri')) {
          final tok = RegExp(r'<ProfileToken>([^<]+)<').firstMatch(b)!.group(1);
          calls.add('uri:$tok');
          return http.Response(
              '<trt:MediaUri><tt:Uri>rtsp://10.0.0.5:554/Streaming/Channels/${tok == 'sub' ? '102' : '101'}?a=1&amp;b=2</tt:Uri></trt:MediaUri>',
              200);
        }
        return http.Response('', 400);
      });
      final out = await onvifStreamUris('http://10.0.0.5/onvif/device_service', 'admin', 'pw', client: client);
      expect(calls, ['caps', 'profiles', 'uri:sub', 'uri:main']);
      expect(out.first, 'rtsp://admin:pw@10.0.0.5/Streaming/Channels/102?a=1&b=2');
      expect(out.length, 2);
      final none = await onvifStreamUris('http://x/onvif', 'a', 'b',
          client: MockClient((_) async => http.Response('nope', 401)));
      expect(none, isEmpty);
    });
  });

  group('screen', () {
    testWidgets('flag off = honest "not available", no dead controls', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(const IpCamGuardScreen(preview: IpCamPreview(paired: false))));
      await _settle(tester);
      expect(find.text(en.gbNotYet), findsOneWidget);
      expect(find.byKey(const Key('icgClaim')), findsNothing);
    });

    testWidgets('unpaired: claim enabled only with a code; wrong code is an honest error', (tester) async {
      _phone(tester, height: 1200);
      await tester.pumpWidget(_app(const IpCamGuardScreen(force: true, preview: IpCamPreview(paired: false))));
      await _settle(tester);
      final btn = find.byKey(const Key('icgClaim'));
      expect(tester.widget<FilledButton>(btn).onPressed, isNull);
      await tester.enterText(find.byKey(const Key('icgCode')), 'abc');
      await _settle(tester);
      await tester.tap(btn);
      await _settle(tester);
      expect(find.text(en.pcCodeInvalid), findsOneWidget);
    });

    testWidgets('camera step: brand hints, RTSP link mode, test needs an address', (tester) async {
      _phone(tester, height: 1600);
      await tester.pumpWidget(_app(const IpCamGuardScreen(force: true, preview: IpCamPreview(brand: 'imou'))));
      await _settle(tester);
      expect(find.text(en.icgHintImou), findsOneWidget);
      expect(find.text(en.gbCamPassNote), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('icgBrand_tapo')));
      await tester.tap(find.byKey(const Key('icgBrand_tapo')));
      await _settle(tester);
      expect(find.text(en.icgHintTapo), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('icgBrand_rtsp')));
      await tester.tap(find.byKey(const Key('icgBrand_rtsp')));
      await _settle(tester);
      expect(find.byKey(const Key('icgRtsp')), findsOneWidget);
      expect(find.byKey(const Key('icgHost')), findsNothing);
      final test = find.byKey(const Key('icgTest'));
      expect(tester.widget<FilledButton>(test).onPressed, isNull);
      await tester.enterText(find.byKey(const Key('icgRtsp')), 'rtsp://u:p@192.168.1.20/stream');
      await _settle(tester);
      expect(tester.widget<FilledButton>(test).onPressed, isNotNull);
      // no decoder on the test host: an honest message, never a crash
      await tester.ensureVisible(find.byKey(const Key('icgTest')));
      await tester.tap(find.byKey(const Key('icgTest')));
      await _settle(tester, 20);
      expect(find.text(en.icgFailDecoder), findsOneWidget);
    });

    testWidgets('running: alerts, person check, camera lost + old-phone mode, stop', (tester) async {
      _phone(tester, height: 1400);
      await tester.pumpWidget(_app(const IpCamGuardScreen(
          force: true,
          preview: IpCamPreview(tested: true, running: true, alerts: 2, camLost: true, lowPower: true))));
      await _settle(tester);
      expect(find.byKey(const Key('icgCamLost')), findsOneWidget);
      expect(find.text(en.icgLowPower), findsOneWidget);
      expect(find.text(en.pcAlertsSent('2')), findsOneWidget);
      expect(find.text(en.pcModelOn), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('icgStop')));
      await tester.tap(find.byKey(const Key('icgStop')));
      await _settle(tester);
      expect(find.byKey(const Key('icgStart')), findsOneWidget);
    });

    testWidgets('bn: Bangla digits in the counters', (tester) async {
      _phone(tester, height: 1400);
      await tester.pumpWidget(_app(
          const IpCamGuardScreen(force: true, preview: IpCamPreview(tested: true, running: true, alerts: 12)),
          lang: 'bn'));
      await _settle(tester);
      expect(find.text(bn.pcAlertsSent('১২')), findsOneWidget);
      expect(find.text(bn.icgTitle), findsOneWidget);
    });

    for (final dark in [false, true]) {
      for (final lang in ['en', 'bn']) {
        testWidgets('every gallery state at 200% text, $lang, dark=$dark: no overflow', (tester) async {
          _phone(tester);
          for (final e in ipcamShots.entries) {
            await tester.pumpWidget(_app(e.value(lang), lang: lang, scale: 2.0, dark: dark));
            await _settle(tester, 4);
            expect(tester.takeException(), isNull, reason: e.key);
          }
        });
      }
    }
  });
}
