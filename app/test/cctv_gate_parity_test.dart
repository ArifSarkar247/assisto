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

Float64List _plane(Map f) {
  final base = (f['base'] as num).toDouble();
  final gain = ((f['gain'] ?? 1.0) as num).toDouble();
  final g = Float64List(kPixW * kPixH)..fillRange(0, kPixW * kPixH, base);
  for (final r in (f['rects'] as List? ?? const [])) {
    final q = [for (final v in r as List) (v as num)];
    for (var y = q[1].toInt(); y < q[1] + q[3]; y++) {
      for (var x = q[0].toInt(); x < q[0] + q[2]; x++) {
        g[y * kPixW + x] = q[4].toDouble();
      }
    }
  }
  for (var i = 0; i < g.length; i++) {
    g[i] = g[i] * gain;
  }
  return g;
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
    // cctvacc2: night enhancement + 2-frame check + the phone pixel check
    expect(kNightPre, spec['night_pre']);
    expect(kNightClaheClip, spec['night_clahe_clip']);
    expect(kNightClaheTiles, spec['night_clahe_tiles']);
    expect(kNightGammaTarget, spec['night_gamma_target']);
    expect(kNightConfirm, spec['night_confirm']);
    expect(kNightConfirmGapS, spec['night_confirm_gap_s']);
    expect(kGuardNightArgs['nightPre'], kNightPre);
    expect(kGuardNightArgs['claheClip'], kNightClaheClip);
    expect(kGuardNightArgs['claheTiles'], kNightClaheTiles);
    expect(kGuardNightArgs['gammaTarget'], kNightGammaTarget);
    final px = spec['pixel'] as Map<String, dynamic>;
    final dartPx = <String, num>{
      'w': kPixW,
      'h': kPixH,
      'samples': kPixSamples,
      'diff': kPixDiff,
      'learn': kPixLearn,
      'scene_frac': kPixSceneFrac,
      'min_area': kPixMinArea,
    };
    expect(dartPx.keys.toSet(), px.keys.toSet());
    for (final k in px.keys) {
      expect(dartPx[k], px[k], reason: 'pixel.$k');
    }
  });

  test('pixel check: same answers as the Shop Box (cctvacc2)', () {
    final cases = _json('edge/shopbox/tests/fixtures/pixel_check_cases.json')['cases'] as List;
    expect(cases.length, greaterThanOrEqualTo(8));
    for (final c in cases.cast<Map<String, dynamic>>()) {
      final pc = PixelCheck();
      final gm = _mask(c['gate_moved'] as List?);
      final got = [for (final f in (c['frames'] as List)) pc.feed(_plane(f as Map), gm)];
      expect(got, c['expect'], reason: c['name'] as String);
    }
    expect(PixelCheck.histMedian(Float64List.fromList([1.9, 5.0, 7.2, 200.0])), 5);
  });

  test('night 2-frame confirmation (cctvacc2)', () {
    final c = NightConfirm();
    expect(c.check(true, night: false, now: 0), isTrue); // day: at once
    expect(c.check(true, night: true, now: 1.0), isFalse);
    expect(c.pending, isTrue);
    expect(c.check(true, night: true, now: 1.4), isTrue);
    expect(c.check(true, night: true, now: 10.0), isFalse); // too far apart
    expect(c.check(false, night: true, now: 10.3), isFalse);
    expect(c.pending, isFalse);
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
