// sosat — false-snatch MEASUREMENT harness. Runs the shipped SnatchDetector
// (lib/services/antitheft_logic.dart, the unit-tested mirror of
// SnatchDetector.kt / SnatchPolicy.kt) over every labelled trace in
// test/fixtures/sensor_traces/ (detector=snatch) with each trace's context
// (screen, hour, charging, unlock moment, home Wi-Fi) and prints precision /
// recall / false alarms per hour.
//
// Linear acceleration is derived from the raw trace like Android's own
// example filter (gravity low-pass, alpha 0.8) — real phones use sensor
// fusion (TYPE_LINEAR_ACCELERATION), so recorded traces may differ.
// HONESTY: every trace today is `source=synthetic` (see gen_synthetic.py).
import 'dart:math' as math;

import 'package:assisto/services/antitheft_logic.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sosat_trace_io.dart';

bool runSnatch(Trace t) {
  final d = SnatchDetector();
  final unlockAt = t.intMeta('unlock_at_ms', -1);
  final screenOn0 = t.intMeta('screen_on', 0) == 1;
  final hour = t.intMeta('hour', 12);
  final charging = t.intMeta('charging', 0) == 1;
  final homeWifi = t.intMeta('home_wifi', 0) == 1;
  var g = <double>[t.samples.first.x, t.samples.first.y, t.samples.first.z];
  int faceDownSince = 0;
  int faceDownStillUntil = 0;
  var fired = false;
  for (final s in t.samples) {
    const a = 0.8;
    g = [a * g[0] + (1 - a) * s.x, a * g[1] + (1 - a) * s.y, a * g[2] + (1 - a) * s.z];
    final lx = s.x - g[0], ly = s.y - g[1], lz = s.z - g[2];
    final mag = math.sqrt(lx * lx + ly * ly + lz * lz);
    // face-down = gravity on -z for REST_MS, kept 2 s after (service rule)
    if (g[2] < -7.0) {
      if (faceDownSince == 0) faceDownSince = s.t == 0 ? 1 : s.t;
    } else {
      if (faceDownSince > 0 && s.t - faceDownSince >= SnatchPolicy.restMs) {
        faceDownStillUntil = s.t + 2000;
      }
      faceDownSince = 0;
    }
    final faceDown = (faceDownSince > 0 && s.t - faceDownSince >= SnatchPolicy.restMs) ||
        s.t < faceDownStillUntil;
    final unlocked = unlockAt >= 0 && s.t >= unlockAt;
    final ctx = SnatchContext(
      charging: charging,
      screenOn: screenOn0 || unlocked,
      unlocked: unlocked,
      msSinceUnlock: unlocked ? s.t - unlockAt : null,
      hour: hour,
      faceDown: faceDown,
      onHomeWifi: homeWifi,
    );
    if (d.onSample(magnitude: mag, tMs: s.t, ctx: ctx)) fired = true;
  }
  return fired;
}

void main() {
  final traces = loadTraces('snatch');

  test('there are labelled snatch traces of both kinds', () {
    expect(traces.where((t) => t.label == 'snatch').length, greaterThanOrEqualTo(3));
    expect(traces.where((t) => t.label == 'nosnatch').length, greaterThanOrEqualTo(5));
  });

  test('snatch harness: confusion table, precision, recall, false alarms/hour', () {
    final results = {for (final t in traces) t.name: runSnatch(t)};
    for (final group in ['synthetic', 'recorded']) {
      final g = traces.where((t) => t.source == group).toList();
      if (g.isEmpty) {
        // ignore: avoid_print
        print('SNATCH[$group] no traces yet');
        continue;
      }
      // ignore: avoid_print
      print('SNATCH[$group] ${Metrics.of(g, results, positive: 'snatch').summary()}');
    }
    for (final t in traces) {
      // ignore: avoid_print
      print('SNATCH ${t.label.padRight(8)} ${results[t.name]! ? "FIRED " : "quiet "} ${t.name}');
    }
    for (final t in traces.where((t) => t.source == 'synthetic')) {
      if (t.name.contains('MISS_EXPECTED') || t.name.contains('FP_RISK')) continue;
      expect(results[t.name], t.label == 'snatch', reason: t.name);
    }
  });
}
