// antitheft-nine — shared helpers for the atnine + atbattery emulator flows
// (board row 11). Same model as antitheft_e2e_flow.dart: the REAL native
// AntiTheftService runs on the emulator for account B (protected phone),
// account A (trusted contact) is the app on screen. Host actions (adb) go
// through `REALITY_HOST <verb> <file>` (tools/reality/run_flows.sh).
// Sample data only (made-up SIM id, a central-Dhaka GPS point).
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/api.dart';
import 'package:assisto/config.dart';
import 'package:assisto/services/antitheft_resume.dart';
import 'package:assisto/services/antitheft_service.dart';

import '../support/harness.dart';

const atCh = MethodChannel('com.assisto/antitheft');
const atPin = '4826'; // B's Security PIN (same as the atproof flows)
const atLat = 23.7331, atLng = 90.4170; // sample point, central Dhaka
const atOwnSim = 's3:47001'; // made-up SIM identity

class AtKit {
  AtKit._();
  static ApiClient? a, b;
  static int phoneId = 0;
  static int _n = 0;
  static final traces = <String, (Map<String, Object>, List<double>)>{};

  static Future<Map<String, dynamic>> state(RFlow f) async =>
      Map<String, dynamic>.from(
          await f.net(() => atCh.invokeMethod<Map>('debugState')) ?? const {});

  /// Ask the CI host to do [verb] with adb; returns its output.
  static Future<String> host(RFlow f, String verb, {int seconds = 60}) async {
    final file = '${f.r.id}_${verb}_${_n++}';
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
    f.note('host $verb: ${out.trim().split('\n').take(3).join(' | ')}');
    return out;
  }

  static Future<void> geo(RFlow f) async {
    final file = 'at9geo_${_n++}';
    final d = await f.tester.runAsync(() => f.h.outDir());
    final ack = File('${d!.path}/acks/$file');
    // ignore: avoid_print
    print('REALITY_GEO ${atLat.toStringAsFixed(6)} ${atLng.toStringAsFixed(6)} $file');
    await f.tester.runAsync(() async {
      final end = DateTime.now().add(const Duration(seconds: 25));
      while (DateTime.now().isBefore(end) && !await ack.exists()) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    });
  }

  /// Same linear-acceleration magnitude as test/sosat_snatch_harness_test.dart.
  static (Map<String, Object>, List<double>) parse(String csv) {
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
      const al = 0.98;
      g = [al * g[0] + (1 - al) * x, al * g[1] + (1 - al) * y, al * g[2] + (1 - al) * z];
      final lx = x - g[0], ly = y - g[1], lz = z - g[2];
      mags.add(math.sqrt(lx * lx + ly * ly + lz * lz));
    }
    return (<String, Object>{
      'inUse': meta['in_use'] == '1',
      'screenOn': meta['screen_on'] == '1' || meta['in_use'] == '1',
      'hour': int.tryParse(meta['hour'] ?? '') ?? 12,
    }, mags);
  }

  static Future<void> loadTraces(RFlow f, List<String> names) async {
    if (names.every(traces.containsKey)) return;
    final out = await host(f, 'traces');
    final d = await f.tester.runAsync(() => f.h.outDir());
    for (final n in names) {
      final csv = await f.tester.runAsync(() => File('${d!.path}/traces/$n.csv').readAsString());
      if (csv == null) throw TestFailure('trace $n missing; host said: $out');
      traces[n] = parse(csv);
    }
  }

  static Future<Map<String, dynamic>> inject(RFlow f, String name) async {
    final t = traces[name];
    if (t == null) throw TestFailure('trace $name was not pushed by the host');
    final r = await f.net(() => atCh.invokeMethod<Map>('debugInject',
        {'mags': t.$2, 'dtMs': 20, 'ctx': t.$1, 'endGrace': true}));
    final m = Map<String, dynamic>.from(r ?? const {});
    if (m['refused'] != null) throw TestFailure('inject refused: ${m['refused']}');
    return m;
  }

  static Future<List<Map>> events(ApiClient api) async {
    final tl = await api.getJson('/security/engine/timeline?phone_id=$phoneId');
    return ((tl['events'] as List?) ?? const []).cast<Map>();
  }

  /// Server clock (the outbox's) — every latency is server time - server time.
  static Future<double> serverNow(RFlow f) async => ((await f.net(
          () => a!.getJson('/ci-e2e/outbox?kind=none')))['now'] as num)
      .toDouble();

  /// Pushes the server sent to A since [since] (CI outbox, fake FCM).
  static Future<List<Map>> pushesToA(double since) async {
    final o = await a!.getJson('/ci-e2e/outbox?kind=push&user=me&since=$since');
    return ((o['rows'] as List?) ?? const []).cast<Map>();
  }

  /// Poll [probe] with runAsync ONLY (no tester.pump): with the screen OFF
  /// there are no frames, and a pump would wait forever.
  static Future<void> until(RFlow f, String what, Future<bool> Function() probe,
      {int seconds = 45}) async {
    Object? last;
    final ok = await f.tester.runAsync(() async {
      final end = DateTime.now().add(Duration(seconds: seconds));
      while (DateTime.now().isBefore(end)) {
        try {
          if (await probe()) return true;
        } catch (e) {
          last = e;
        }
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
      return false;
    });
    if (ok != true) {
      throw TestFailure('never happened: $what${last != null ? ' (last error: $last)' : ''}');
    }
  }

  static Future<void> waitNoPending(RFlow f) async {
    await f.eventually('no grab is pending on the phone', () async {
      final s = await atCh.invokeMethod<Map>('debugState');
      return (s?['grabPendingMs'] as num? ?? -1) < 0;
    }, seconds: 30);
  }

  /// B turns protection on with A trusted and the REAL engine starts (or is
  /// already running from an earlier group). Idempotent.
  static Future<void> arm(RFlow f, {List<String> traceNames = const []}) async {
    a ??= await f.h.backend();
    b ??= await f.h.backend(userB: true);
    await geo(f);
    if (traceNames.isNotEmpty) await loadTraces(f, traceNames);
    await f.net(() => b!.postJsonRaw('/security/pin/set', {'new_pin': atPin}));
    final st = await f.net(() => b!.getJson('/security/engine/state'));
    phoneId = (st['phone_id'] as num).toInt();
    final s0 = await state(f);
    if (st['enabled'] == true && s0['running'] == true) return;
    final cands = ((st['candidates'] as List?) ?? const []).cast<Map>();
    final ca = cands.where((c) => '${c['name']}'.contains('Rahim')).toList();
    if (ca.isEmpty) throw TestFailure("A is not in B's circle: $cands");
    final r = await f.net(() => b!.postJsonRaw('/security/engine/enable', {
          'pin': atPin,
          'alert_member_ids': [ca.first['id']],
          'capabilities': {'locationPermission': true},
        }));
    if (r['ok'] != true) throw TestFailure('enable failed: $r');
    await f.net(() => atCh.invokeMethod('debugSim', {'slots': [atOwnSim]}));
    final ok = await f.net(() => AntiTheftService.start(
          engineToken: '${r['engine_token']}',
          apiBase: AppConfig.apiBase + AppConfig.apiPrefix,
          config: (r['config'] as Map?)?.cast<String, dynamic>() ?? const {},
          notif: AntiTheftResume.texts(f.t),
          rebaseline: true,
        ));
    if (ok != true) throw TestFailure('the native engine refused to start');
    await f.eventually('engine running', () async {
      final s = await atCh.invokeMethod<Map>('debugState');
      return s?['running'] == true;
    }, seconds: 40);
  }

  /// Protection off, fakes cleared (always from a finally).
  static Future<void> disarm(RFlow f) async {
    try {
      await f.net(() => b!.postJsonRaw('/security/action',
          {'action': 'turn_off_lost', 'pin': atPin}));
    } catch (_) {}
    try {
      await f.net(() => b!.postJsonRaw('/security/engine/disable', {'pin': atPin}));
    } catch (_) {}
    try {
      await f.net(() => atCh.invokeMethod('debugSim', {'slots': null}));
    } catch (_) {}
    try {
      await f.net(AntiTheftService.stop);
    } catch (_) {}
  }

  static String pct(List<double> xs, double p) {
    if (xs.isEmpty) return '-';
    final s = [...xs]..sort();
    final i = ((p / 100) * (s.length - 1)).round().clamp(0, s.length - 1);
    return s[i].toStringAsFixed(1);
  }
}
