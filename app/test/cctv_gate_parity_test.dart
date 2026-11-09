// cctvacc: the phone's motion gate + person thresholds must equal the Shop
// Box's (edge/shopbox/shopbox/cctv_thresholds.json) and give the same answers
// on the shared fixture cases (also run by edge/shopbox/tests/test_motion_gate.py).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:assisto/cashguard/guard_box_model.dart';
import 'package:assisto/shop_motion.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _json(String rel) {
  for (final base in ['..', '../..', '.']) {
    final f = File('$base/$rel');
    if (f.existsSync()) return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  }
  throw StateError('missing $rel');
}

Float64List _grid(Map f) {
  final base = (f['base'] as num).toDouble();
  final gain = ((f['gain'] ?? 1.0) as num).toDouble();
  final g = Float64List(kGateGridW * kGateGridH)..fillRange(0, kGateGridW * kGateGridH, base);
  for (final r in (f['rects'] as List? ?? const [])) {
    final q = [for (final v in r as List) (v as num)];
    for (var y = q[1].toInt(); y < q[1] + q[3]; y++) {
      for (var x = q[0].toInt(); x < q[0] + q[2]; x++) {
        g[y * kGateGridW + x] = q[4].toDouble();
      }
    }
  }
  for (var i = 0; i < g.length; i++) {
    g[i] = g[i] * gain;
  }
  return g;
}

List<bool>? _mask(List? r) {
  if (r == null) return null;
  final m = List<bool>.filled(kGateGridW * kGateGridH, false);
  for (var y = (r[1] as int); y < (r[1] as int) + (r[3] as int); y++) {
    for (var x = (r[0] as int); x < (r[0] as int) + (r[2] as int); x++) {
      m[y * kGateGridW + x] = true;
    }
  }
  return m;
}

void main() {
  test('constants equal the shared Shop Box spec', () {
    final spec = _json('edge/shopbox/shopbox/cctv_thresholds.json');
    final m = spec['motion'] as Map<String, dynamic>;
    final dart = <String, num>{
      'grid_w': kGateGridW,
      'grid_h': kGateGridH,
      'cell_thr': kGateCellThr,
      'k_sigma': kGateKSigma,
      'sigma0': kGateSigma0,
      'var_learn': kGateVarLearn,
      'var_cap': kGateVarCap,
      'bg_learn': kGateBgLearn,
      'ratio_min': kGateRatioMin,
      'ratio_max': kGateRatioMax,
      'global_frac': kGateGlobalFrac,
      'min_blob': kGateMinBlob,
      'min_fresh': kGateMinFresh,
      'fresh_diff': kGateFreshDiff,
      'stable_frames': kGateStableFrames,
      'hold_frames': kGateHoldFrames,
      'confirm_frames': kGateConfirmFrames,
    };
    expect(dart.keys.toSet(), m.keys.toSet());
    for (final k in m.keys) {
      expect(dart[k], m[k], reason: k);
    }
    expect(kPersonScoreDay, spec['person_score_day']);
    expect(kPersonScoreNight, spec['person_score_night']);
    expect(kNightSpreadMax, spec['night_spread_max']);
    expect(kNightLumaMax, spec['night_luma_max']);
    expect(kGuardNightArgs['thrNight'], kPersonScoreNight);
    expect(kGuardNightArgs['nightSpread'], kNightSpreadMax);
    expect(kGuardNightArgs['nightLuma'], kNightLumaMax);
  });

  test('shared fixture cases: same answers as the Shop Box', () {
    final cases = _json('edge/shopbox/tests/fixtures/motion_gate_cases.json')['cases'] as List;
    expect(cases.length, greaterThanOrEqualTo(8));
    for (final c in cases.cast<Map<String, dynamic>>()) {
      final gate = MotionGate(mask: _mask(c['mask'] as List?));
      final res = [for (final f in (c['frames'] as List)) gate.feed(_grid(f as Map))];
      expect([for (final r in res) r.candidate], c['candidate'], reason: c['name'] as String);
      expect([for (final r in res) r.confirmed], c['confirmed'], reason: c['name'] as String);
      if (c['scene'] != null) {
        expect([for (final r in res) r.sceneChange], c['scene'], reason: c['name'] as String);
      }
    }
  });
}
