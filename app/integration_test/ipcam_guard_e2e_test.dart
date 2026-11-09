// cctvbox — Guard Box E2E ON THE EMULATOR (.github/workflows/ipcam-e2e.yml):
// the real app code on Android pulls a REAL RTSP stream (mediamtx on the CI
// runner, a looped synthetic scene in which a public-domain person photo
// walks in) through the real native MediaCodec decoder, runs the on-phone
// motion + person check, and posts the alert with its photo to a throw-away
// Django. Then the runner opens LIVE as the owner (aiortc viewer) and must
// receive JPEG pictures over the WebRTC data channel.
//
//   flutter test integration_test/ipcam_guard_e2e_test.dart \
//     --dart-define=REALITY_API_BASE=http://10.0.2.2:18700 \
//     --dart-define=IPCAM_CTL=http://10.0.2.2:18799
//
// The control server (tools/e2e/ipcam_ctl.py serve) mints a fresh pairing
// code and says when the live probe is done. Prints "IPCAM_E2E {json}" lines
// the workflow greps for the proof table.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:assisto/ipcam/ipcam_guard_screen.dart';
import 'package:assisto/l10n/app_localizations.dart';

const _ctl = String.fromEnvironment('IPCAM_CTL', defaultValue: 'http://10.0.2.2:18799');

Future<Map<String, dynamic>> _get(String path) async {
  final c = HttpClient();
  try {
    final r = await (await c.getUrl(Uri.parse('$_ctl$path'))).close();
    return jsonDecode(await r.transform(utf8.decoder).join()) as Map<String, dynamic>;
  } finally {
    c.close();
  }
}

void _proof(String step, Map<String, Object?> data) =>
    // ignore: avoid_print
    print('IPCAM_E2E ${jsonEncode({'step': step, ...data})}');

Future<bool> _waitFor(WidgetTester tester, Finder f, Duration max) async {
  final end = DateTime.now().add(max);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 500));
    if (f.evaluate().isNotEmpty) return true;
  }
  return false;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('guard box: RTSP camera -> decode -> alert with photo -> live pictures', (tester) async {
    final t0 = DateTime.now();
    final mint = await _get('/mint');
    final code = mint['code'] as String;
    final rtsp = mint['rtsp'] as String;
    _proof('mint', {'code_len': code.length});

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const IpCamGuardScreen(force: true),
    ));
    await tester.pump(const Duration(seconds: 2));

    // 1. pair with the owner's code (same as the phone-camera QR)
    await tester.enterText(find.byKey(const Key('icgCode')), code);
    await tester.pump();
    await tester.tap(find.byKey(const Key('icgClaim')));
    final paired = await _waitFor(tester, find.byKey(const Key('icgBrand_rtsp')), const Duration(seconds: 30));
    _proof('paired', {'ok': paired});
    expect(paired, isTrue, reason: 'pairing failed');

    // 2. the camera: RTSP link mode (the brand presets are unit-tested)
    await tester.ensureVisible(find.byKey(const Key('icgBrand_rtsp')));
    await tester.tap(find.byKey(const Key('icgBrand_rtsp')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.enterText(find.byKey(const Key('icgRtsp')), rtsp);
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('icgTest')));
    await tester.tap(find.byKey(const Key('icgTest')));
    final tTest = DateTime.now();
    final works = await _waitFor(tester, find.byKey(const Key('icgPreview')), const Duration(seconds: 60));
    final fail = find.byKey(const Key('icgTestFail'));
    _proof('test', {
      'ok': works,
      'seconds': DateTime.now().difference(tTest).inMilliseconds / 1000,
      'works': works ? (tester.widget<Text>(find.byKey(const Key('icgWorks'))).data ?? '') : '',
      'fail': fail.evaluate().isEmpty ? '' : tester.widget<Text>(fail).data,
    });
    expect(works, isTrue, reason: 'camera test showed no decoded picture');

    // 3. guard: the scene's person walks in every ~12 s
    await tester.ensureVisible(find.byKey(const Key('icgStart')));
    await tester.tap(find.byKey(const Key('icgStart')));
    final tStart = DateTime.now();
    // the person model downloads once (SHA-256 checked) before checks start
    final modelOn = await _waitFor(
        tester, find.text('Person check on this phone: on'), const Duration(seconds: 100));
    _proof('model', {'person_model': modelOn, 'seconds': DateTime.now().difference(tStart).inSeconds});
    var alerted = false;
    final end = DateTime.now().add(const Duration(seconds: 180));
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(seconds: 1));
      final a = find.byKey(const Key('icgAlerts'));
      if (a.evaluate().isNotEmpty) {
        final txt = tester.widget<Text>(a).data ?? '';
        if (RegExp(r'[1-9]').hasMatch(txt)) {
          alerted = true;
          break;
        }
      }
    }
    _proof('alert', {
      'ok': alerted,
      'seconds_after_start': DateTime.now().difference(tStart).inMilliseconds / 1000,
      'person_model': find.text('Person check on this phone: on').evaluate().isNotEmpty,
    });
    expect(alerted, isTrue, reason: 'no alert reached the server');

    // 4. live: the runner's owner-side viewer asks; keep guarding meanwhile
    var liveSeen = false;
    var probe = <String, dynamic>{};
    final liveEnd = DateTime.now().add(const Duration(seconds: 150));
    while (DateTime.now().isBefore(liveEnd)) {
      await tester.pump(const Duration(seconds: 1));
      if (find.byKey(const Key('icgLive')).evaluate().isNotEmpty) liveSeen = true;
      if (DateTime.now().second % 5 == 0) {
        try {
          probe = await _get('/live_status');
          if (probe['done'] == true) break;
        } catch (_) {}
      }
    }
    _proof('live', {'answered_on_phone': liveSeen, ...probe});

    await tester.tap(find.byKey(const Key('icgStop')));
    await tester.pump(const Duration(seconds: 1));
    _proof('done', {'total_seconds': DateTime.now().difference(t0).inSeconds});
  }, timeout: const Timeout(Duration(minutes: 9)));
}
