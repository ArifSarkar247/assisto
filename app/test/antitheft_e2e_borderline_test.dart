// antitheft-e2e — the owner's grab sensitivity must CHANGE the outcome on a
// borderline trace (the same trace the emulator E2E feeds into the native
// engine: integration_test/flows/antitheft_e2e_flow.dart). SYNTHETIC trace
// (gen_flag_antitheft_traces.py #8): phone in use, a grab between the high
// (22.5) and normal (25) grab thresholds, then a real run.
import 'package:assisto/services/antitheft_logic.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sosat_snatch_harness_test.dart' show runSnatch;
import 'sosat_trace_io.dart';

void main() {
  final border = loadTraces('snatch_borderline');
  final snatch = {for (final t in loadTraces('snatch')) t.name: t};

  test('there is one borderline trace and it is synthetic', () {
    expect(border.map((t) => t.name), ['fa_borderline_in_hand_weak_grab_run']);
    expect(border.single.source, 'synthetic');
  });

  test('borderline: low no, normal no, high YES', () {
    final t = border.single;
    expect(runSnatch(t, sensitivity: SnatchSensitivity.low), isFalse);
    expect(runSnatch(t, sensitivity: SnatchSensitivity.normal), isFalse);
    expect(runSnatch(t, sensitivity: SnatchSensitivity.high), isTrue);
  });

  test('in-hand snatch: low no (never from the unlocked hand), normal + high yes', () {
    final t = snatch['fa_snatch_from_hand_rickshaw_thief_runs']!;
    expect(runSnatch(t, sensitivity: SnatchSensitivity.low), isFalse);
    expect(runSnatch(t, sensitivity: SnatchSensitivity.normal), isTrue);
    expect(runSnatch(t, sensitivity: SnatchSensitivity.high), isTrue);
  });

  test('rickshaw in use never fires at any level (the live false-alert pattern)', () {
    final t = snatch['fa_nosnatch_rickshaw_potholes_in_use']!;
    for (final s in [SnatchSensitivity.low, SnatchSensitivity.normal, SnatchSensitivity.high]) {
      expect(runSnatch(t, sensitivity: s), isFalse, reason: s);
    }
  });
}
