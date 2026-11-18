// antitheft-nine — guards for the native (Kotlin) fixes of board row 11.
// The Kotlin is compiled + exercised on the emulator by
// integration_test/flows/antitheft_nine_flow.dart (API 26 / 33 / 34); these
// source checks keep the fixes from silently coming back between E2E runs.
//   1. a real phone's CPU sleeps with the screen off even while the engine's
//      foreground service runs: the wake-up push (remote alarm / lock), a grab
//      and the heartbeat now hold a TIMED partial wake lock, and the heartbeat
//      has an inexact ELAPSED_REALTIME_WAKEUP alarm backstop (no exact-alarm
//      permission);
//   2. intruder photo / instant lock / wrong-unlock threshold from a check-in
//      reach the running engine (like the sensitivity);
//   3. the remote alarm keeps ringing on a sleeping phone (player wake mode);
//   4. the intruder photo carries a fresh location fix.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _dir = 'android_overlay/app/src/main/kotlin/com/assisto/assisto/antitheft';

String _read(String f) => File('$_dir/$f').readAsStringSync();

String _after(String s, String marker, [int len = 600]) {
  final i = s.indexOf(marker);
  expect(i, greaterThan(0), reason: 'missing: $marker');
  return s.substring(i, (i + len).clamp(0, s.length));
}

void main() {
  test('wake locks are always TIMED and short', () {
    final w = _read('EngineWake.kt');
    expect(w, contains('PARTIAL_WAKE_LOCK'));
    expect(w, contains('w.acquire(t)')); // never the open-ended acquire()
    expect(w, isNot(contains('.acquire()')));
    expect(w, contains('const val MAX_MS = 60_000L'));
    expect(w, contains('ms.coerceIn(1_000L, MAX_MS)'));
  });

  test('push wake-up, grab and alarm heartbeat hold the CPU awake', () {
    final s = _read('AntiTheftService.kt');
    expect(_after(s, 'fun onCommandPush(ctx: Context)'),
        contains('EngineWake.hold(ctx, EngineWake.PUSH_MS)'));
    expect(_after(s, 'private fun onSnatchDetected()'),
        contains('EngineWake.hold(applicationContext, EngineWake.GRAB_MS)'));
    expect(_after(s, 'private val beatAlarm'),
        contains('EngineWake.hold(applicationContext, EngineWake.BEAT_MS)'));
  });

  test('heartbeat has an inexact wake-up alarm backstop (no exact alarm)', () {
    final s = _read('AntiTheftService.kt');
    final b = _after(s, 'private fun scheduleBeatAlarm(', 800);
    expect(b, contains('AlarmManager.ELAPSED_REALTIME_WAKEUP'));
    expect(b, contains('am.cancel(beatAlarm)'));
    expect(b, isNot(contains('setExact')));
    expect(_after(s, 'private val heartbeatTick'), contains('scheduleBeatAlarm(interval)'));
    expect(_after(s, 'override fun onDestroy()'), contains('alarmMgr?.cancel(beatAlarm)'));
  });

  test('a check-in applies intruder photo, instant lock and threshold', () {
    final s = _read('AntiTheftService.kt');
    expect(_after(s, 'nightGuard = cfg.optBoolean("night_guard", nightGuard)', 500),
        contains('applySwitches(cfg)'));
    final a = _after(s, 'private fun applySwitches(cfg: JSONObject)', 1500);
    for (final k in ['"intruder_photo"', '"snatch_lock"', '"failed_unlock_threshold"']) {
      expect(a, contains('cfg.has($k)'), reason: k);
    }
    expect(a, contains('intruderPhoto = v'));
    expect(a, contains('snatchLock = v'));
  });

  test('remote alarm keeps ringing on a sleeping phone', () {
    final r = _read('RemoteCommands.kt');
    expect(_after(r, 'mp.setDataSource(c, uri)', 400),
        contains('mp.setWakeMode(c, PowerManager.PARTIAL_WAKE_LOCK)'));
  });

  test('the intruder photo is sent with a fresh fix', () {
    final s = _read('AntiTheftService.kt');
    expect(_after(s, 'private fun snapInApp()', 1500),
        contains('currentFix(2 * 60_000L, 8_000L)'));
  });

  test('the new debug fields are behind the debuggable check', () {
    final s = _read('AntiTheftService.kt');
    final d = _after(s, 'fun debugState(ctx: Context)', 2500);
    expect(d.indexOf('if (!isDebuggable(ctx))'), lessThan(d.indexOf('"pushWakes"')));
  });
}
