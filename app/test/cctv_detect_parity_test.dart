// cctvdet: the phone / Android Guard Box zone detections must equal the Shop
// Box's (edge/shopbox/shopbox/detect_rules.py): same constants
// (cctv_thresholds.json["detect"]) and the same answers on the shared cases
// (edge/shopbox/tests/fixtures/detect_cases.json, also run by
// edge/shopbox/tests/test_detect_rules.py).
import 'dart:convert';
import 'dart:io';

import 'package:assisto/cctv/detect_rules.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _json(String rel) {
  for (final base in ['..', '../..', '.']) {
    final f = File('$base/$rel');
    if (f.existsSync()) return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  }
  throw StateError('missing $rel');
}

List<double> _patch(Map p) => [
      for (var j = 0; j < kPatchH; j++)
        for (var i = 0; i < kPatchW; i++)
          (((p['pattern'] == 'h' ? j : i) % 2 == 0) ? p['lo'] as num : p['hi'] as num).toDouble()
    ];

List<List<double>>? _boxes(Object? v) => v == null
    ? null
    : [
        for (final b in v as List) [for (final x in b as List) (x as num).toDouble()]
      ];

void main() {
  final spec = _json('edge/shopbox/shopbox/cctv_thresholds.json');
  final fix = _json('edge/shopbox/tests/fixtures/detect_cases.json');

  test('constants equal the shared thresholds file', () {
    final d = spec['detect'] as Map<String, dynamic>;
    final mine = <String, num>{
      'zone_hit_points': kZoneHitPoints,
      'gate_confirm': kGateConfirm,
      'presence_gap_s': kPresenceGapS,
      'dwell_s_default': kDwellSDefault,
      'absent_min_default': kAbsentMinDefault,
      'open_min_default': kOpenMinDefault,
      'post_check_s': kPostCheckS,
      'presence_check_s': kPresenceCheckS,
      'patch_w': kPatchW,
      'patch_h': kPatchH,
      'gate_closed_sim': kGateClosedSim,
      'tamper_every_s': kTamperEveryS,
      'bad_persist_s': kBadPersistS,
      'moved_min_gap_s': kMovedMinGapS,
      'post_presence_score': kPostPresenceScore,
      'crowd_s_default': kCrowdSDefault,
      'veh_gap_s': kVehGapS,
      'veh_check_s': kVehCheckS,
      'veh_still': kVehStill,
      'overstay_min_default': kOverstayMinDefault,
      'wrong_s_default': kWrongSDefault,
      'track_max_jump': kTrackMaxJump,
      'moved_shape_sim': kMovedShapeSim,
      'moved_shape_keep': kMovedShapeKeep,
      // cctvdet3
      'track_jump_cap': kTrackJumpCap,
      'track_coast_s': kTrackCoastS,
      'cross_margin': kCrossMargin,
      'dwell_keep_score': kDwellKeepScore,
      'crowd_score': kCrowdScore,
      'crowd_keep_s': kCrowdKeepS,
      'post_weak_hits': kPostWeakHits,
      'veh_start_score': kVehStartScore,
      'veh_present_frac': kVehPresentFrac,
    };
    expect(mine.keys.toSet(), d.keys.toSet());
    for (final e in mine.entries) {
      expect(e.value, d[e.key], reason: e.key);
    }
  });

  test('shared zone cases give the same detections as the Shop Box', () {
    final cases = fix['cases'] as List;
    expect(cases.length, greaterThanOrEqualTo(13));
    for (final c in cases) {
      final name = c['name'];
      final rules = ZoneRules();
      rules.configureFromJson({'zones': c['zones'], 'schedule': c['cam_schedule']});
      for (final s in c['steps'] as List) {
        final t = (s['t'] as num).toDouble();
        final wd = s['wd'] as int, mn = s['min'] as int;
        if (s['check'] != null) {
          final last = (s['check']['last'] as num?)?.toDouble();
          expect(rules.needsPersonCheck(t, wd, mn, last), s['check']['expect'], reason: '$name t=$t check');
        }
        if (s['set_ref'] != null) {
          final r = s['set_ref'];
          rules.setRef(r['zone'], _patch(r['patch']), r['night'] == true, (r['t'] as num).toDouble());
        }
        final pIn = s['patches'] as Map?;
        final patches = pIn == null ? null : {for (final e in pIn.entries) '${e.key}': _patch(e.value as Map)};
        final got = rules.step(t, wd, mn, _boxes(s['boxes']),
            night: s['night'] == true,
            patches: patches,
            minScore: ((s['min_score'] as num?) ?? 0).toDouble(),
            vehicles: _boxes(s['vehicles']));
        final want = s['expect'] as List;
        expect(got.length, want.length, reason: '$name t=$t: $got');
        for (var i = 0; i < want.length; i++) {
          for (final e in (want[i] as Map).entries) {
            final g = got[i][e.key];
            if (e.value is num && g is num) {
              expect((g - (e.value as num)).abs() < 1e-6, isTrue, reason: '$name t=$t ${e.key}');
            } else {
              expect(g, e.value, reason: '$name t=$t ${e.key}');
            }
          }
        }
        for (final e in ((s['expect_wants_ref'] as Map?) ?? const {}).entries) {
          expect(rules.wantsRef('${e.key}'), e.value, reason: '$name t=$t wantsRef');
        }
      }
    }
  });

  test('tamper cases = the server rule', () {
    for (final e in (fix['tamper'] as Map).entries) {
      var st = <String, dynamic>{};
      for (final s in e.value as List) {
        final grid = [for (final v in s['grid'] as List) (v as num).toDouble()];
        final (ns, kind) = assessStill(st, grid, (s['mean'] as num).toDouble(),
            (s['std'] as num).toDouble(), s['ir'] == true, (s['ts'] as num).toDouble());
        st = ns;
        expect(kind, s['expect'], reason: '${e.key} ts=${s['ts']}');
      }
    }
  });

  test('camera moved by shapes = the Shop Box (stage 2)', () {
    for (final e in (fix['shape'] as Map).entries) {
      var st = <String, dynamic>{};
      for (final s in e.value as List) {
        final (ns, kind) = assessShape(st, _patch(s['shape'] as Map), s['ir'] == true, (s['ts'] as num).toDouble());
        st = ns;
        expect(kind, s['expect'], reason: '${e.key} ts=${s['ts']}');
      }
    }
  });

  test('zone picture + similarity cases', () {
    for (final c in fix['patches'] as List) {
      final got = zonePatch([for (final v in c['gray'] as List) v as int], c['w'], c['h'],
          [for (final p in c['poly'] as List) [for (final x in p as List) (x as num).toDouble()]],
          pw: c['pw'], ph: c['ph']);
      final want = [for (final v in c['expect'] as List) (v as num).toDouble()];
      expect(got.length, want.length);
      for (var i = 0; i < want.length; i++) {
        expect((got[i] - want[i]).abs() < 1e-9, isTrue);
      }
    }
    for (final c in fix['similarity'] as List) {
      final got = detSimilarity(_patch(c['a']), _patch(c['b']), gradOnly: c['grad_only'] == true);
      expect((got - (c['expect'] as num)).abs() < 1e-3, isTrue, reason: '$c');
    }
  });

  test('no model: presence and absence are never guessed', () {
    final rules = ZoneRules();
    rules.configureFromJson({
      'zones': [
        {
          'id': 'p',
          'type': 'post',
          'points': [
            [0, 0],
            [1, 0],
            [1, 1],
            [0, 1]
          ],
          'schedule': {
            'days': [0, 1, 2, 3, 4, 5, 6],
            'start': '00:00',
            'end': '00:00'
          },
          'opts': {'absent_min': 1}
        }
      ]
    });
    for (var t = 0; t < 600; t += 5) {
      expect(rules.step(t.toDouble(), 2, 600, null), isEmpty);
    }
  });

  test('detection signals mirror the Shop Box payload (never identity)', () {
    final s = detectionSignals({'type': kDetGatePerson, 'zone': 'g1', 'label': 'Shutter', 'conf': 0.8},
        detector: 'yolox_nano_phone', source: 'phone_camera');
    expect(s['person'], isTrue);
    expect(s['zone_breach'], isTrue);
    expect(s['zone_label'], 'Shutter');
    expect(s['source'], 'edge');
    expect(s.keys.any((k) => k.contains('face') || k == 'name'), isFalse);
    final l = detectionSignals({'type': kDetLoitering, 'zone': 'g1', 'seconds': 130},
        detector: 'x', source: 'guard_box');
    expect(l['zone_dwell'], isTrue);
    expect(l['human'], isTrue);
  });
}
