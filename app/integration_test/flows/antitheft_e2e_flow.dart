// antitheft-e2e — scripted emulator E2E of the anti-theft engine (board row
// 11). Opt-in group `atproof` (e2e.yml group=start+atproof, DEBUG build).
//
//   PROTECTED PHONE = account B. Unlike the at100 flow (HTTP-simulated engine)
//     the REAL native AntiTheftService runs on the emulator with B's engine
//     token: real foreground service, real detector, real "Are you OK?"
//     notification + pending grab, real check-ins, real USER_PRESENT from the
//     emulator's SECURE lock screen, real lost-mode lock-screen message.
//   TRUSTED CONTACT = account A, the app on screen (A's family view, feed).
//
// Test-only seams (refused in a release build, see AntiTheftService.kt
// isDebuggable): `debugInject` replays a labelled sensor trace
// (app/test/fixtures/sensor_traces, SYNTHETIC physics-modelled — pushed by the
// CI host) into the real detector; `debugSim` fakes the SIM slots (the
// emulator cannot swap SIMs). Host actions (adb: PIN lock, lock/unlock, lock
// screen shot, trace push) go through `REALITY_HOST` in
// tools/reality/run_flows.sh. Sample data only (made-up SIM ids, Dhaka GPS).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/api.dart';
import 'package:assisto/config.dart';
import 'package:assisto/push/push_service.dart' show appNavigatorKey;
import 'package:assisto/screens/watched_phones_screen.dart';
import 'package:assisto/services/antitheft_resume.dart';
import 'package:assisto/services/antitheft_service.dart';
import 'package:assisto/widgets/grab_check_dialog.dart';
import 'package:assisto/widgets/remote_switches_card.dart';

import '../support/harness.dart';

const _ch = MethodChannel('com.assisto/antitheft');
const _pin = '4826'; // B's Security PIN (same as the at100 flow)
const _lat = 23.7331, _lng = 90.4170; // sample point, central Dhaka
const _ownSim = 's3:47001'; // made-up SIM identities (SimBaseline form)
const _thiefSim = 's9:47003';
// what a grab event may carry: motion numbers + the facts the server re-checks
const _motion = {'v', 'profile', 'sens', 'in_use', 'peak', 'moving', 'thirds',
    'rhythm', 'step_hz', 'mean'};
const _facts = {'locked', 'charging', 'face_down_still', 'hour', 'wifi',
    'screen_on', 'confirm', 'acc', 'fix_at', 'false_alarm', 'suppressed'};

// trace name -> (context, linear magnitudes) ; filled by at01
final _traces = <String, (Map<String, Object>, List<double>)>{};
ApiClient? _a, _b;
int _phoneId = 0;
int _hostN = 0;

// ------------------------------------------------------------------ helpers
Future<T?> _call<T>(RFlow f, String m, [Map<String, Object?>? args]) =>
    f.net(() => _ch.invokeMethod<T>(m, args));

Future<Map<String, dynamic>> _state(RFlow f) async =>
    Map<String, dynamic>.from(await _call<Map>(f, 'debugState') ?? const {});

/// Ask the CI host to do [verb] with adb; returns its output. Polls with
/// runAsync only (no frames needed: the screen may be off meanwhile).
Future<String> _host(RFlow f, String verb, {int seconds = 60}) async {
  final file = '${f.r.id}_${verb}_${_hostN++}';
  final d = await f.tester.runAsync(() => f.h.outDir());
  final ack = File('${d!.path}/acks/$file');
  // ignore: avoid_print
  print('REALITY_HOST $verb $file');
  final out = await f.tester.runAsync(() async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    while (DateTime.now().isBefore(end)) {
      if (await ack.exists()) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        return ack.readAsString();
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return null;
  });
  if (out == null) throw TestFailure('the CI host never did "$verb" (no ack in ${seconds}s)');
  f.note('host $verb: ${out.trim().split('\n').take(2).join(' | ')}');
  return out;
}

Future<void> _geo(RFlow f) async {
  final file = 'atgeo_${_hostN++}';
  final d = await f.tester.runAsync(() => f.h.outDir());
  final ack = File('${d!.path}/acks/$file');
  // ignore: avoid_print
  print('REALITY_GEO ${_lat.toStringAsFixed(6)} ${_lng.toStringAsFixed(6)} $file');
  await f.tester.runAsync(() async {
    final end = DateTime.now().add(const Duration(seconds: 25));
    while (DateTime.now().isBefore(end) && !await ack.exists()) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  });
}

/// The same linear-acceleration magnitude as the unit-tested harness
/// (test/sosat_snatch_harness_test.dart: gravity low-pass alpha 0.98).
(Map<String, Object>, List<double>) _parse(String csv) {
  final meta = <String, String>{};
  final mags = <double>[];
  List<double>? g;
  for (final line in const LineSplitter().convert(csv)) {
    if (line.startsWith('#')) {
      final kv = line.substring(1).trim();
      final i = kv.indexOf('=');
      if (i > 0) meta[kv.substring(0, i).trim()] = kv.substring(i + 1).trim();
      continue;
    }
    final p = line.split(',');
    if (p.length < 4 || int.tryParse(p[0]) == null) continue;
    final x = double.parse(p[1]), y = double.parse(p[2]), z = double.parse(p[3]);
    g ??= [x, y, z];
    const a = 0.98;
    g = [a * g[0] + (1 - a) * x, a * g[1] + (1 - a) * y, a * g[2] + (1 - a) * z];
    final lx = x - g[0], ly = y - g[1], lz = z - g[2];
    mags.add(math.sqrt(lx * lx + ly * ly + lz * lz));
  }
  final ctx = <String, Object>{
    'inUse': meta['in_use'] == '1',
    'screenOn': meta['screen_on'] == '1' || meta['in_use'] == '1',
    'hour': int.tryParse(meta['hour'] ?? '') ?? 12,
  };
  return (ctx, mags);
}

/// Replay one trace into the REAL detector of the running engine.
Future<Map<String, dynamic>> _inject(RFlow f, String name, {bool endGrace = true}) async {
  final t = _traces[name];
  if (t == null) throw TestFailure('trace $name was not pushed by the host');
  final r = await _call<Map>(f, 'debugInject',
      {'mags': t.$2, 'dtMs': 20, 'ctx': t.$1, 'endGrace': endGrace});
  final m = Map<String, dynamic>.from(r ?? const {});
  if (m['refused'] != null) throw TestFailure('inject refused: ${m['refused']}');
  f.note('$name: fired=${m['fired']} sens=${m['sensitivity']}');
  return m;
}

Future<List<Map>> _events(ApiClient api) async {
  final tl = await api.getJson('/security/engine/timeline?phone_id=$_phoneId');
  return ((tl['events'] as List?) ?? const []).cast<Map>();
}

Future<int> _feedCount(ApiClient api) async {
  final r = await api.getJson('/notif/feed?type=security');
  return ((r['items'] as List?) ?? const []).length;
}

Future<String> _feedNewest(ApiClient api) async {
  final r = await api.getJson('/notif/feed?type=security');
  final items = (r['items'] as List?) ?? const [];
  return items.isEmpty ? '' : jsonEncode(items.first);
}

/// What the server holds for B's grabs (diagnostics for a failed step).
Future<String> _grabSummary(RFlow f) async {
  final evs = await f.net(() => _events(_b!));
  return evs.where((e) => e['kind'] == 'snatch').map((e) {
    final d = e['data'] as Map;
    return 'held=${e['held']} confirm=${d['confirm']} suppressed=${d['suppressed']} '
        'charging=${d['charging']} profile=${d['profile']}';
  }).join(' / ');
}

Future<void> _waitNoPending(RFlow f) async {
  await f.eventually('no grab is pending on the phone', () async {
    final s = await _ch.invokeMethod<Map>('debugState');
    return (s?['grabPendingMs'] as num? ?? -1) < 0;
  }, seconds: 25);
}

/// B (the owner) answers "It was me" with the Security PIN, then the app
/// drops the local window (exactly what GrabCheck does after a good PIN).
Future<void> _imOk(RFlow f) async {
  final r = await f.net(() => _b!.postJsonRaw('/security/engine/false-alarm', {'pin': _pin}));
  if (r['_status'] != 200) throw TestFailure('false-alarm: $r');
  await f.net(AntiTheftService.grabCancel);
}

Future<void> _setSens(RFlow f, String v) async {
  final r = await f.net(() => _b!.postJsonRaw('/security/engine/settings',
      {'pin': _pin, 'snatch_sensitivity': v}));
  if (r['ok'] != true) throw TestFailure('settings $v: $r');
  // the engine must pick it up from its check-in (not from this app screen)
  await f.net(AntiTheftService.flushNow);
  await f.eventually('the running engine uses "$v"', () async {
    final s = await _ch.invokeMethod<Map>('debugState');
    return s?['sensitivity'] == v;
  }, seconds: 30);
}

void _dismissDialog(RFlow f) {
  if (find.byKey(const Key('grab-yes')).evaluate().isNotEmpty) {
    appNavigatorKey.currentState?.pop();
  }
}

Future<void> _bothLangShots(RFlow f, String name) async {
  await f.shot('${name}_en');
  await f.app.setLocale(const Locale('bn'), syncServer: false);
  await f.pumpFor(const Duration(seconds: 2));
  await f.shot('${name}_bn');
  await f.app.setLocale(const Locale('en'), syncServer: false);
  await f.pumpFor(const Duration(seconds: 2));
}

// -------------------------------------------------------------------- flows
void registerAntiTheftE2eFlows() {
  realityFlow('at01_engine_live_sim_baseline', 'Family & safety',
      'Anti-theft E2E: B arms protection (A trusted) -> the REAL engine runs on this phone, reads the sensor, records the SIM silently, ignores grabs while just armed',
      (f) async {
    await f.home();
    _a = await f.h.backend();
    _b = await f.h.backend(userB: true);
    await f.step('GPS + the labelled sensor traces reach the phone', () async {
      await _geo(f);
      // the emulator always reports AC power; a grab on the charger is
      // ignored by design (phone AND server), so the phone is "unplugged"
      await _host(f, 'unplug');
      final out = await _host(f, 'traces');
      final d = await f.tester.runAsync(() => f.h.outDir());
      for (final n in [
        'fa_snatch_shop_counter_run', 'fa_snatch_from_hand_rickshaw_thief_runs',
        'fa_borderline_in_hand_weak_grab_run', 'fa_nosnatch_rickshaw_potholes_in_use',
        'fa_nosnatch_fast_walk_in_use_bump', 'fa_nosnatch_table_to_bag_walk',
        'fa_nosnatch_dropped_on_floor_left', 'fa_nosnatch_tossed_on_sofa',
      ]) {
        final csv = await f.tester.runAsync(() => File('${d!.path}/traces/$n.csv').readAsString());
        if (csv == null) throw TestFailure('trace $n missing; host said: $out');
        _traces[n] = _parse(csv);
      }
    });
    await f.step('B turns protection on with A as the trusted contact', () async {
      await f.net(() => _b!.postJsonRaw('/security/pin/set', {'new_pin': _pin}));
      final st = await f.net(() => _b!.getJson('/security/engine/state'));
      _phoneId = (st['phone_id'] as num).toInt();
      final cands = ((st['candidates'] as List?) ?? const []).cast<Map>();
      final a = cands.where((c) => '${c['name']}'.contains('Rahim')).toList();
      if (a.isEmpty) throw TestFailure("A is not in B's circle: $cands");
      final r = await f.net(() => _b!.postJsonRaw('/security/engine/enable', {
            'pin': _pin,
            'alert_member_ids': [a.first['id']],
            'capabilities': {'locationPermission': true},
          }));
      if (r['ok'] != true) throw TestFailure('enable failed: $r');
      // the SIM in "this phone" right now is B's own (made-up identity)
      await _call(f, 'debugSim', {'slots': [_ownSim]});
      final ok = await f.net(() => AntiTheftService.start(
            engineToken: '${r['engine_token']}',
            apiBase: AppConfig.apiBase + AppConfig.apiPrefix,
            config: (r['config'] as Map?)?.cast<String, dynamic>() ?? const {},
            notif: AntiTheftResume.texts(f.t),
            rebaseline: true,
          ));
      if (ok != true) throw TestFailure('the native engine refused to start');
    });
    await f.step('engine live: sensor samples flow, SIM baseline recorded silently', () async {
      await f.eventually('engine running + sensor + SIM baseline', () async {
        final s = await _ch.invokeMethod<Map>('debugState');
        return s?['running'] == true &&
            ((s?['halSamples'] as num?) ?? 0) > 0 &&
            s?['simBase'] == _ownSim;
      }, seconds: 40);
      final s = await _state(f);
      f.note('sensor samples=${s['halSamples']} grace=${s['graceLeftMs']}ms');
      final evs = await f.net(() => _events(_b!));
      if (evs.any((e) => e['kind'] == 'sim_change')) {
        throw TestFailure('arming reported B\'s OWN SIM as a SIM change: $evs');
      }
    });
    await f.step('just armed: a grab is ignored for 2 minutes (owner handling)', () async {
      final r = await _inject(f, 'fa_snatch_shop_counter_run', endGrace: false);
      if (r['suppressed'] != true || r['fired'] == true) {
        throw TestFailure('grab counted during the arming grace: $r');
      }
    });
  });

  realityFlow('at02_rickshaw_walk_no_alert', 'Family & safety',
      'Anti-theft E2E: rickshaw / fast walk with the phone unlocked in the hand, drops and tosses -> NO grab, A is never told',
      (f) async {
    await f.home();
    final before = await f.net(() => _feedCount(_a!));
    for (final n in [
      'fa_nosnatch_rickshaw_potholes_in_use', 'fa_nosnatch_fast_walk_in_use_bump',
      'fa_nosnatch_table_to_bag_walk', 'fa_nosnatch_dropped_on_floor_left',
      'fa_nosnatch_tossed_on_sofa',
    ]) {
      await f.step('$n -> no grab', () async {
        final r = await _inject(f, n);
        if (r['fired'] == true) throw TestFailure('FALSE grab on $n: ${r['features']}');
      });
    }
    await f.step('server + A: nothing', () async {
      await f.pumpFor(const Duration(seconds: 5));
      final evs = await f.net(() => _events(_b!));
      if (evs.any((e) => e['kind'] == 'snatch')) throw TestFailure('a grab reached the server: $evs');
      if (await f.net(() => _feedCount(_a!)) != before) throw TestFailure('A got a notification');
    });
  });

  realityFlow('at03_snatch_are_you_ok_family_alerted', 'Family & safety',
      'Anti-theft E2E: real snatch trace -> "Are you OK?" on the phone -> no answer in 15 s -> A gets the alert with the last location',
      (f) async {
    await f.home();
    final before = await f.net(() => _feedCount(_a!));
    late DateTime t0;
    await f.step('snatch from a shop counter + run -> grab, motion numbers only', () async {
      final r = await _inject(f, 'fa_snatch_shop_counter_run');
      t0 = DateTime.now();
      if (r['fired'] != true) throw TestFailure('real snatch NOT detected: $r');
      final keys = (r['features'] as Map).keys.map((k) => '$k').toSet();
      if (!keys.containsAll(_motion) || keys.difference(_motion).isNotEmpty) {
        throw TestFailure('grab features are not motion numbers only: $keys');
      }
      final s = await _state(f);
      if (((s['grabPendingMs'] as num?) ?? -1) <= 0) throw TestFailure('no "Are you OK?" window: $s');
    });
    await f.step('held: the server has it, A does NOT see it yet (no location)', () async {
      Map? held;
      try {
        await f.eventually('the held grab reached the server', () async {
          final evs = await _events(_b!);
          held = evs.where((e) => e['kind'] == 'snatch' && e['held'] == true).firstOrNull;
          return held != null;
        }, seconds: 20);
      } catch (_) {
        f.note('server grabs: ${await _grabSummary(f)}');
        rethrow;
      }
      final keys = (held!['data'] as Map).keys.map((k) => '$k').toSet();
      final extra = keys.difference(_motion.union(_facts));
      if (extra.isNotEmpty) throw TestFailure('grab payload carries more than motion + facts: $extra');
      final fam = await f.net(() => _events(_a!));
      if (fam.any((e) => e['kind'] == 'snatch')) {
        throw TestFailure('A sees a HELD grab (privacy): $fam');
      }
    });
    await f.step('"Are you OK?" on the phone (en + bn), nobody answers', () async {
      final ctx = appNavigatorKey.currentContext!;
      unawaited(GrabCheck.maybeShow(ctx,
          send: (pin) async => const {'ok': false}, escalate: (r) async => const {}));
      await f.waitFor(find.byKey(const Key('grab-yes')), what: 'Are you OK? dialog');
      await _bothLangShots(f, 'are_you_ok');
    });
    await f.step('15 s later A has the alert with the last location', () async {
      Map? sent;
      await f.eventually('A got the grab alert', () async {
        final evs = await _events(_a!);
        sent = evs.where((e) => e['kind'] == 'snatch').firstOrNull;
        return sent != null;
      }, seconds: 45);
      final secs = DateTime.now().difference(t0).inSeconds;
      f.note('grab -> family alert in ${secs}s');
      if ((sent!['data'] as Map)['confirm'] != 'timeout') throw TestFailure('not a timeout escalation: $sent');
      if (((sent!['recipients'] as num?) ?? 0) < 1) throw TestFailure('told nobody: $sent');
      final lat = (sent!['lat'] as num?)?.toDouble();
      if (lat == null || (lat - _lat).abs() > 0.01) throw TestFailure('alert without the location: $sent');
      if (secs > 40) throw TestFailure('alert took ${secs}s');
      await f.eventually('A has a new security notification', () async =>
          await _feedCount(_a!) > before, seconds: 15);
      final top = await f.net(() => _feedNewest(_a!));
      if (!top.contains('23.73')) f.note('feed item has no coordinates text: ${top.length} chars');
      _dismissDialog(f);
      await f.pumpFor(const Duration(seconds: 1));
    });
    await f.step("A's view of B's phone (en + bn)", () async {
      await f.openRoute('watched_phones');
      await f.waitFor(find.byType(RemoteSwitchesCard), what: "B's phone");
      expect(find.byType(WatchedPhoneScreen), findsWidgets);
      await _bothLangShots(f, 'family_alert');
    });
  }, timeout: const Duration(minutes: 6));

  realityFlow('at04_secure_unlock_cancels', 'Family & safety',
      'Anti-theft E2E: a grab, then the owner unlocks with the phone\'s SECURE lock inside 15 s -> dropped, A is never told, no location kept',
      (f) async {
    await f.home();
    final before = await f.net(() => _feedCount(_a!));
    final famBefore = (await f.net(() => _events(_a!))).length;
    try {
      await f.step('the phone gets a secure PIN lock', () async {
        await _waitNoPending(f);
        final o = await _host(f, 'pin_on');
        if (o.toLowerCase().contains('error')) throw TestFailure('set-pin: $o');
      });
      late DateTime t0;
      await f.step('grab detected', () async {
        final r = await _inject(f, 'fa_snatch_shop_counter_run');
        t0 = DateTime.now();
        if (r['fired'] != true) throw TestFailure('grab not detected: $r');
      });
      await f.step('screen off -> on -> unlock WITH the PIN (real USER_PRESENT)', () async {
        await _host(f, 'lock_unlock');
        final secs = DateTime.now().difference(t0).inSeconds;
        f.note('unlocked ${secs}s after the grab');
        if (secs >= 15) throw TestFailure('host unlock too slow (${secs}s) to prove the cancel');
      });
      await f.step('server dropped the held grab; A never told; no location kept', () async {
        try {
          await f.eventually('the grab was dropped by the owner unlock', () async {
            final evs = await _events(_b!);
            return evs.any((e) => e['kind'] == 'snatch' &&
                (e['data'] as Map)['confirm'] == 'owner_unlock');
          }, seconds: 30);
        } catch (_) {
          f.note('server grabs: ${await _grabSummary(f)}');
          rethrow;
        }
        final ev = (await f.net(() => _events(_b!))).firstWhere((e) =>
            e['kind'] == 'snatch' && (e['data'] as Map)['confirm'] == 'owner_unlock');
        if (ev['lat'] != null || ev['lng'] != null) {
          throw TestFailure('a dropped grab kept the location: $ev');
        }
        // past the window: still nothing for A
        await f.tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 18)));
        await f.pumpFor(const Duration(seconds: 1));
        _dismissDialog(f);
        if (await f.net(() => _feedCount(_a!)) != before) throw TestFailure('A was told');
        if ((await f.net(() => _events(_a!))).length != famBefore) {
          throw TestFailure("the dropped grab is on A's timeline");
        }
      });
    } finally {
      try {
        await _host(f, 'pin_off');
      } catch (_) {}
    }
  }, timeout: const Duration(minutes: 5));

  realityFlow('at05_sensitivity_levels', 'Family & safety',
      'Anti-theft E2E: sensitivity low / normal / high (set from the server, picked up by the running engine) changes the outcome of an in-hand snatch and a borderline grab',
      (f) async {
    await f.home();
    final table = <String>[];
    Future<bool> run(String trace) async {
      await _waitNoPending(f);
      final r = await _inject(f, trace);
      return r['fired'] == true;
    }

    Future<void> serverHeldThenOk(String what) async {
      try {
        await f.eventually('$what reached the server and is held (not suppressed)', () async {
          final evs = await _events(_b!);
          return evs.any((e) => e['kind'] == 'snatch' && e['held'] == true);
        }, seconds: 20);
      } catch (_) {
        f.note('server grabs: ${await _grabSummary(f)}');
        rethrow;
      }
      await _imOk(f);
    }

    await f.step('LOW: never from the unlocked hand', () async {
      await _setSens(f, 'low');
      final hand = await run('fa_snatch_from_hand_rickshaw_thief_runs');
      final border = await run('fa_borderline_in_hand_weak_grab_run');
      table.add('low: hand=$hand border=$border');
      if (hand || border) throw TestFailure('low counted an in-hand grab');
    });
    await f.step('NORMAL: in-hand snatch yes, borderline no', () async {
      await _setSens(f, 'normal');
      final hand = await run('fa_snatch_from_hand_rickshaw_thief_runs');
      if (hand) await serverHeldThenOk('in-hand snatch');
      final border = await run('fa_borderline_in_hand_weak_grab_run');
      table.add('normal: hand=$hand border=$border');
      if (!hand || border) throw TestFailure('normal: hand=$hand border=$border');
    });
    await f.step('HIGH: the borderline grab counts too', () async {
      await _setSens(f, 'high');
      final border = await run('fa_borderline_in_hand_weak_grab_run');
      if (border) await serverHeldThenOk('borderline grab');
      table.add('high: border=$border');
      if (!border) throw TestFailure('high did not count the borderline grab');
    });
    await f.step('back to normal', () => _setSens(f, 'normal'));
    f.note(table.join(' ; '));
  }, timeout: const Duration(minutes: 8));

  realityFlow('at06_sim_change_alert', 'Family & safety',
      'Anti-theft E2E: own SIM again -> nothing; a NEW SIM -> SIM-change alert to A',
      (f) async {
    await f.home();
    await f.step("B's own SIM seen again -> no alert", () async {
      await _call(f, 'debugSim', {'slots': [_ownSim]});
      await f.tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 6)));
      final evs = await f.net(() => _events(_b!));
      if (evs.any((e) => e['kind'] == 'sim_change')) throw TestFailure('own SIM alerted: $evs');
    });
    await f.step("a thief's SIM -> SIM-change alert reaches A", () async {
      await _call(f, 'debugSim', {'slots': [_thiefSim]});
      Map? ev;
      await f.eventually('A got the SIM-change alert', () async {
        final evs = await _events(_a!);
        ev = evs.where((e) => e['kind'] == 'sim_change').firstOrNull;
        return ev != null;
      }, seconds: 40);
      final d = ev!['data'] as Map;
      if (d['state'] != 'inserted' || d['v'] != 2) throw TestFailure('odd SIM event: $d');
      if (((ev!['recipients'] as num?) ?? 0) < 1) throw TestFailure('told nobody: $ev');
    });
    await f.step('the SIM goes back (cleanup of the fake)', () async {
      await _call(f, 'debugSim', {'slots': [_ownSim]});
    });
  });

  realityFlow('at07_lost_mode_screen', 'Family & safety',
      'Anti-theft E2E: A turns LOST MODE on from the family side -> the phone shows the "This phone is lost" message on its lock screen',
      (f) async {
    await f.home();
    try {
      await f.step('A turns lost mode on with a message', () async {
        await f.openRoute('watched_phones');
        await f.waitFor(find.byType(RemoteSwitchesCard), what: 'remote switches');
        final lost = find.byKey(const Key('at100-lost_mode'));
        await f.scrollTo(lost);
        await f.tap(lost);
        await f.tester.enterText(find.byKey(const Key('at100-msg')),
            'This phone is lost. Please call the number on this screen.');
        await f.tap(find.byKey(const Key('at100-msg-send')), settleSeconds: 3);
        await _bothLangShots(f, 'lost_mode_family');
      });
      await f.step('the phone checks in and shows the lost message', () async {
        await f.net(AntiTheftService.flushNow);
        await f.eventually('lost-mode message is on the phone', () async {
          final s = await _ch.invokeMethod<Map>('debugState');
          if (s?['lostShown'] == true) return true;
          await AntiTheftService.flushNow();
          return false;
        }, seconds: 45);
        final o = await _host(f, 'lockshot');
        f.note('lock screen: $o');
      });
    } finally {
      await f.step('cleanup: lost mode off, "It was me", protection off', () async {
        try {
          // "It was me" first: the SIM change froze sensitive actions (by
          // design a thief with the PIN cannot end lost mode for 48 h)
          await f.net(() => _b!.postJsonRaw('/security/engine/false-alarm', {'pin': _pin}));
          final off = await f.net(() => _b!.postJsonRaw('/security/action',
              {'action': 'turn_off_lost', 'pin': _pin}));
          f.note('lost mode off: ${off['_status']} ${off['reason'] ?? ''}');
          await f.net(AntiTheftService.flushNow);
          await f.tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 12)));
          final s = await _state(f);
          f.note('lost message after off: ${s['lostShown']}');
          await f.net(() => _b!.postJsonRaw('/security/engine/disable', {'pin': _pin}));
        } catch (e) {
          f.note('cleanup: $e');
        }
        await _call(f, 'debugSim', {'slots': null});
        await f.net(AntiTheftService.stop);
        try {
          await _host(f, 'battery_reset');
        } catch (_) {}
      });
    }
  }, timeout: const Duration(minutes: 5));
}
