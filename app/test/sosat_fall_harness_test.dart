// sosat — fall-detector MEASUREMENT harness. Runs the experimental
// FallDetector (lib/services/safety_triggers_logic.dart; Kotlin mirror
// SafetyTriggers.kt) over every labelled trace in
// test/fixtures/sensor_traces/ (detector=fall) and prints a confusion table,
// precision / recall and false alarms per hour of "normal life" traces.
//
// HONESTY: today every trace there is `source=synthetic` (physics-modelled,
// tools/sensor_traces/gen_synthetic.py) — the numbers measure the RULES on
// textbook shapes, not real-world accuracy. Real recordings (the app's
// "Record sensor trace" tool) dropped into the same folder are reported as a
// separate group.
import 'dart:io';

import 'package:assisto/services/safety_triggers_logic.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sosat_trace_io.dart';

void main() {
  final traces = loadTraces('fall');

  test('there are labelled fall traces of both kinds', () {
    expect(traces.where((t) => t.label == 'fall').length, greaterThanOrEqualTo(4));
    expect(traces.where((t) => t.label == 'nofall').length, greaterThanOrEqualTo(8));
  });

  test('fall harness: confusion table, precision, recall, false alarms/hour', () {
    final results = <String, bool>{};
    for (final t in traces) {
      final d = FallDetector();
      var fired = false;
      for (final s in t.samples) {
        if (d.onSample(s.x, s.y, s.z, s.t)) fired = true;
      }
      results[t.name] = fired;
    }
    for (final group in ['synthetic', 'recorded']) {
      final g = traces.where((t) => t.source == group).toList();
      if (g.isEmpty) {
        // ignore: avoid_print
        print('FALL[$group] no traces yet');
        continue;
      }
      final m = Metrics.of(g, results, positive: 'fall');
      // ignore: avoid_print
      print('FALL[$group] ${m.summary()}');
    }
    for (final t in traces) {
      // ignore: avoid_print
      print('FALL ${t.label.padRight(6)} ${results[t.name]! ? "FIRED " : "quiet "} ${t.name}');
    }
    // The rules' contract on the synthetic set (documented in the card):
    for (final t in traces.where((t) => t.source == 'synthetic')) {
      if (t.name.contains('MISS_EXPECTED') || t.name.contains('FP_RISK')) continue;
      expect(results[t.name], t.label == 'fall', reason: t.name);
    }
  });

  test('the fixtures folder is next to the test (CI cwd = app/)', () {
    expect(Directory(kTraceDir).existsSync(), isTrue);
  });
}
