// antitheft-nine — the last proofs for board row 11 (phone anti-theft),
// opt-in group `atnine` (e2e.yml group=start+atnine or start+atproof+atnine,
// DEBUG build, google_apis image, emulated FRONT camera, adb root).
//
//   at08  thief photo: 3 wrong Security PINs typed in Assisto -> the REAL
//         engine takes ONE front photo (emulated camera, shutter sound) ->
//         uploaded encrypted -> A gets the alert with the phone's location
//         and can open the photo. Also proves a check-in now brings the
//         owner's intruder-photo switch to the running engine.
//   at09  remote alarm + lock from A with B's screen OFF and the phone in
//         DOZE: the server's silent "at_command" push is handed to the phone
//         exactly as Google Play services does (c2dm RECEIVE, high priority)
//         -> the engine wakes, checks in, rings on the ALARM stream / locks;
//         A sees the honest result. Timed.
//   at10  speed: 10 real grabs in a row, grab -> A's high-priority push,
//         measured on the server clock: p50 / p95 / max (the 15 s "Are you
//         OK?" window is by design and included).
//
// Honest seams: sensor traces are SYNTHETIC (debugInject, debug builds only);
// the FCM transport is simulated by the host (the server's push is real code
// up to the fake FCM call, the phone's receiver + engine are real); the
// 10-minute "one alert per kind" cooldown is set to 0 in this CI run only
// (E2E_AT_COOLDOWN_MIN) so every grab of the speed loop is pushed.

import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/services/antitheft_service.dart';
import 'package:assisto/services/intruder_snap.dart';

import '../support/harness.dart';
import 'antitheft_nine_kit.dart';

const _snatch = 'fa_snatch_shop_counter_run';
const _consent = 2; // core/views_at_remote.INTRUDER_CONSENT_VERSION

void registerAntiTheftNineFlows() {
  realityFlow('at08_thief_photo_reaches_family', 'Family & safety',
      'Anti-theft: 3 wrong Security PINs in Assisto -> the real engine takes ONE front photo -> A gets it with the location',
      (f) async {
    await f.home();
    await f.step('protection on (B), A trusted; front camera present', () async {
      await AtKit.arm(f, traceNames: const [_snatch]);
      final cam = await AtKit.host(f, 'cam_info');
      if (!cam.contains('granted')) throw TestFailure('camera permission: $cam');
    });
    await f.step('B switches the thief photo on (consent) -> the RUNNING engine learns it from a check-in', () async {
      final r = await f.net(() => AtKit.b!.postJsonRaw('/security/engine/settings',
          {'pin': atPin, 'intruder_photo': true, 'intruder_consent': _consent}));
      if (r['ok'] != true) throw TestFailure('settings: $r');
      await f.eventually('engine has intruderPhoto=true', () async {
        await AntiTheftService.flushNow();
        final s = await atCh.invokeMethod<Map>('debugState');
        return s?['intruderPhoto'] == true;
      }, seconds: 40);
    });
    late double t0;
    await f.step('3 wrong PINs -> the server asks for the photo on the 3rd', () async {
      t0 = await AtKit.serverNow(f);
      final snaps = <Object?>[];
      for (var i = 0; i < 3; i++) {
        final r = await f.net(() => AtKit.b!.postJsonRaw('/security/engine/settings',
            {'pin': '0000', 'snatch_sensitivity': 'normal'}));
        snaps.add(r['intruder_snap']);
        // the app's own code path (always_on_protection_screen / GrabCheck)
        IntruderSnap.after(r);
      }
      f.note('intruder_snap per attempt: $snaps');
      if (snaps.last != true) throw TestFailure('3rd wrong PIN did not ask for a photo: $snaps');
    });
    await f.step('the engine took ONE photo (emulated front camera)', () async {
      await f.eventually('photo taken', () async {
        final s = await atCh.invokeMethod<Map>('debugState');
        return ((s?['photoOk'] as num?) ?? 0) >= 1;
      }, seconds: 40);
      final s = await AtKit.state(f);
      f.note('photo tries=${s['photoTries']} ok=${s['photoOk']} err=${s['photoErr']}');
    });
    await f.step('A: alert with the location + the photo opens', () async {
      Map? ev;
      await f.eventually('A sees the intruder photo event', () async {
        await AntiTheftService.flushNow();
        final evs = await AtKit.events(AtKit.a!);
        ev = evs.where((e) => e['kind'] == 'intruder_photo').firstOrNull;
        return ev != null;
      }, seconds: 60);
      final lat = (ev!['lat'] as num?)?.toDouble();
      if (lat == null || (lat - atLat).abs() > 0.01) throw TestFailure('photo without location: $ev');
      if (ev!['has_photo'] != true) throw TestFailure('event has no photo: $ev');
      final pushes = await f.net(() => AtKit.pushesToA(t0));
      final p = pushes.where((r) => '${(r['data'] as Map?)?['antitheft_kind']}' == 'intruder_photo').firstOrNull;
      if (p == null) throw TestFailure('A got no push for the photo: ${pushes.length} pushes');
      f.note('wrong PIN #3 -> A push in ${((p['ts'] as num) - t0).toStringAsFixed(1)} s (high=${p['high']})');
      final link = await f.net(() => AtKit.a!.getJson('/security/engine/event/${ev!['id']}/photo-link'));
      final bytes = await f.net(() => AtKit.a!.getBytes('${link['url']}'));
      if (bytes.length < 500 || bytes[0] != 0xFF || bytes[1] != 0xD8) {
        throw TestFailure('A could not open a JPEG (${bytes.length} bytes)');
      }
      f.note('A opened the photo: ${bytes.length} bytes JPEG');
    });
    await f.step('B\'s right PIN resets the wrong count; photo switch back off', () async {
      final r = await f.net(() => AtKit.b!.postJsonRaw('/security/engine/settings',
          {'pin': atPin, 'intruder_photo': false}));
      if (r['ok'] != true) throw TestFailure('reset: $r');
      await f.eventually('engine has intruderPhoto=false', () async {
        await AntiTheftService.flushNow();
        final s = await atCh.invokeMethod<Map>('debugState');
        return s?['intruderPhoto'] == false;
      }, seconds: 40);
    });
  }, timeout: const Duration(minutes: 6));

  realityFlow('at09_remote_alarm_lock_screen_off_doze', 'Family & safety',
      'Anti-theft: A rings the loud alarm and locks B\'s phone while its screen is OFF and it is in Doze -> wake-up push -> it rings / locks, A sees the result',
      (f) async {
    await f.home();
    await AtKit.arm(f);
    try {
      await f.step('A turns lost mode on (a trusted contact may then ring / lock)', () async {
        final r = await f.net(() => AtKit.a!.postJsonRaw('/security/engine/command', {
              'kind': 'lost_mode', 'phone_id': AtKit.phoneId,
              'message': 'This phone is lost. Please call the number on this screen.'}));
        if (r['ok'] != true) throw TestFailure('lost mode: $r');
        final adm = await AtKit.host(f, 'admin_on');
        f.note('device admin: ${adm.trim()}');
      });
      await f.step('B\'s phone: screen OFF, unplugged, forced into Doze', () async {
        final o = await AtKit.host(f, 'doze_on');
        if (!o.contains('deep=IDLE')) throw TestFailure('not in Doze: $o');
        final s = await AtKit.state(f);
        f.note('engine running=${s['running']} interactive=${s['interactive']} idle=${s['deviceIdle']}');
        if (s['interactive'] == true) throw TestFailure('screen is still on');
      });
      Future<(Map, double)> press(String kind, bool Function(Map s) done) async {
        final before = (await AtKit.state(f))['pushWakes'] as num? ?? 0;
        final t0 = await AtKit.serverNow(f);
        final r = await f.net(() => AtKit.a!.postJsonRaw('/security/engine/command',
            {'kind': kind, 'phone_id': AtKit.phoneId}));
        if (r['ok'] != true) throw TestFailure('$kind: $r');
        final cmdId = ((r['command'] as Map)['id'] as num).toInt();
        // the server's wake-up push for B's phone (fake FCM outbox), then
        // the host hands it to the phone as Play services would
        await AtKit.host(f, 'fcm_wake');
        Map? s;
        await f.eventually('$kind ran on the sleeping phone', () async {
          s = await atCh.invokeMethod<Map>('debugState');
          return ((s?['pushWakes'] as num?) ?? 0) > before && done(s!);
        }, seconds: 45);
        final ran = await AtKit.serverNow(f) - t0;
        Map? cmd;
        await f.eventually('A sees the honest result of $kind', () async {
          final l = await AtKit.a!.getJson('/security/engine/commands?phone_id=${AtKit.phoneId}');
          cmd = ((l['commands'] as List?) ?? const []).cast<Map>()
              .where((c) => c['id'] == cmdId).firstOrNull;
          return cmd != null && '${cmd!['state']}' == 'done';
        }, seconds: 45);
        f.note('$kind: ran ${ran.toStringAsFixed(1)} s after A pressed; result ${cmd!['detail']}; lastCmd=${s!['lastCmd']}');
        return (cmd!, ran);
      }

      await f.step('A: loud alarm -> it rings on the ALARM stream, screen still off', () async {
        final (c, _) = await press('alarm', (s) => s['alarmPlaying'] == true);
        if (!'${c['detail']}'.startsWith('rang')) throw TestFailure('alarm result: $c');
        final a = await AtKit.host(f, 'alarm_state');
        f.note('audio: ${a.trim().replaceAll('\n', ' ')}');
      });
      await f.step('A: stop alarm -> silent again', () async {
        await press('alarm_stop', (s) => s['alarmPlaying'] == false);
      });
      await f.step('A: lock -> the phone locks itself (device admin)', () async {
        final (c, _) = await press('lock', (s) => '${s['lastCmd']}'.startsWith('lock:'));
        if ('${c['detail']}' != 'locked') throw TestFailure('lock result: $c');
      });
    } finally {
      await f.step('cleanup: out of Doze, screen on, unlocked; lost mode off', () async {
        try {
          await AtKit.host(f, 'doze_off');
        } catch (e) {
          f.note('doze_off: $e');
        }
        try {
          await f.net(() => AtKit.b!.postJsonRaw('/security/action',
              {'action': 'turn_off_lost', 'pin': atPin}));
          await AntiTheftService.flushNow();
        } catch (e) {
          f.note('lost off: $e');
        }
      });
    }
  }, timeout: const Duration(minutes: 7));

  realityFlow('at10_alert_speed_p95', 'Family & safety',
      'Anti-theft speed: 10 real grabs, nobody answers "Are you OK?" -> A\'s high-priority push; p50 / p95 / max from the grab (15 s answer window included)',
      (f) async {
    await f.home();
    await AtKit.arm(f, traceNames: const [_snatch]);
    final lat = <double>[];
    final upload = <double>[];
    for (var i = 0; i < 10; i++) {
      await f.step('grab ${i + 1}/10 -> A pushed', () async {
        await AtKit.waitNoPending(f);
        final t0 = await AtKit.serverNow(f);
        final r = await AtKit.inject(f, _snatch);
        if (r['fired'] != true) throw TestFailure('grab not detected: $r');
        Map? push;
        await f.eventually('A got the grab push', () async {
          final rows = await AtKit.pushesToA(t0);
          push = rows.where((p) => '${(p['data'] as Map?)?['antitheft_kind']}' == 'snatch').firstOrNull;
          return push != null;
        }, seconds: 60);
        if (push!['high'] != true) throw TestFailure('grab push is not high priority: $push');
        final evs = await f.net(() => AtKit.events(AtKit.b!));
        final ev = evs.where((e) => e['kind'] == 'snatch').firstOrNull;
        final rec = DateTime.tryParse('${ev?['received_at'] ?? ''}');
        if (rec != null) upload.add(rec.millisecondsSinceEpoch / 1000 - t0);
        lat.add((push!['ts'] as num).toDouble() - t0);
      });
    }
    final line = 'grab -> family push (s): p50 ${AtKit.pct(lat, 50)} p95 ${AtKit.pct(lat, 95)} '
        'max ${AtKit.pct(lat, 100)} (n=${lat.length}); grab -> server '
        'p95 ${AtKit.pct(upload, 95)} (n=${upload.length})';
    f.note(line);
    // ignore: avoid_print
    print('AT_SPEED $line');
    await f.step('p95 within 25 s (15 s answer window + 10 s)', () async {
      final s = [...lat]..sort();
      if (s.isEmpty) throw TestFailure('no samples');
      final p95 = s[((0.95) * (s.length - 1)).round()];
      if (p95 > 25) throw TestFailure('p95 ${p95.toStringAsFixed(1)} s > 25 s');
    });
    await f.step('cleanup: protection off', () => AtKit.disarm(f));
  }, timeout: const Duration(minutes: 9));
}
