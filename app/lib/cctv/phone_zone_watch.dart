// cctvdet: the PHONE CAMERA's side of the zone detections — the glue between
// phone_camera_screen.dart (frames, person checks, ingest) and the shared
// rules (detect_rules.dart = the Shop Box's detect_rules.py).
//
//   * applyConfig(shop/config)   the owner's zones (gate / post / dwell) and
//                                the camera schedule, drawn on the picture
//   * onGrid(grid)               every frame (the 32 x 24 motion grid, ~0 ms):
//                                tamper every 30 s, the gate zone pictures
//                                every 5 s ("gate left open")
//   * needsCheck(t)              run the person model now even without motion
//                                (a post zone is armed / someone is in a zone)
//   * onBoxes(boxes)             the person boxes of THIS check -> detections
//
// Pure Dart; unit-tested in app/test/cctv_detect_engine_test.dart.
import 'dart:typed_data';

import 'detect_rules.dart';

/// The motion grid turned like the alert photo (clockwise, as
/// phonecam_rec_logic.yuvToJpeg turns the frame by the sensor orientation),
/// so the zones drawn on the photo land on the same cells.
(Float64List, int, int) rotateGrid(Float64List g, int w, int h, int deg) {
  final r = ((deg % 360) + 360) % 360;
  if (r == 0) return (g, w, h);
  if (r == 180) {
    final out = Float64List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        out[y * w + x] = g[(h - 1 - y) * w + (w - 1 - x)];
      }
    }
    return (out, w, h);
  }
  final nw = h, nh = w;
  final out = Float64List(nw * nh);
  for (var y = 0; y < nh; y++) {
    for (var x = 0; x < nw; x++) {
      out[y * nw + x] = r == 90 ? g[(h - 1 - x) * w + y] : g[x * w + (w - 1 - y)];
    }
  }
  return (out, nw, nh);
}

class PhoneZoneWatch {
  final ZoneRules rules = ZoneRules();
  final TamperCheck tamper = TamperCheck();
  final DateTime Function() now;
  double? lastCheck;
  double? _lastPatch;
  final Map<String, double> _cool = {};
  double cooldownS = 180;
  void Function(Map<String, Map<String, Object?>> refs)? onRefsChanged;

  PhoneZoneWatch({DateTime Function()? now}) : now = now ?? DateTime.now;

  bool get active => rules.zones.isNotEmpty;

  /// shop/config body -> the zones of this phone's camera.
  void applyConfig(Map? body) {
    for (final c in (body?['cameras'] as List? ?? const [])) {
      if (c is! Map) continue;
      rules.configureFromJson((c['zones'] as Map?) ?? (c['zone_config'] as Map?));
      final cd = (c['tuning'] as Map?)?['cooldown_s'];
      if (cd is num) cooldownS = cd.toDouble();
      return;
    }
  }

  double _t(DateTime d) => d.millisecondsSinceEpoch / 1000.0;

  (int, int) _local(DateTime d) => (d.weekday - 1, d.hour * 60 + d.minute);

  /// Every frame: the motion grid (luma, row-major). Returns the tamper /
  /// "gate left open" detections of this frame (usually none).
  List<Map<String, Object?>> onGrid(Float64List raw, int rw, int rh, {int rot = 0}) {
    final (grid, w, h) = rotateGrid(raw, rw, rh, rot);
    final d = now();
    final t = _t(d);
    final out = <Map<String, Object?>>[];
    final ints = <int>[];
    if (tamper.due(t) || (rules.gateZones().isNotEmpty &&
        (_lastPatch == null || t - _lastPatch! >= 5))) {
      for (final v in grid) {
        ints.add(v.round().clamp(0, 255).toInt());
      }
    }
    if (tamper.due(t) && ints.isNotEmpty) {
      final (g8, mean, std) = stillStats(ints, w, h);
      final kind = tamper.check(g8, mean, std, mean < 40, t);
      if (kind != null) out.add({'type': kDetCameraHealth, 'kind': kind});
    }
    final gates = rules.gateZones();
    if (gates.isNotEmpty && ints.isNotEmpty && (_lastPatch == null || t - _lastPatch! >= 5)) {
      _lastPatch = t;
      var sum = 0;
      for (final v in ints) {
        sum += v;
      }
      final night = sum / ints.length < 40;
      final patches = <String, List<double>>{};
      var changed = false;
      for (final z in gates) {
        final p = zonePatch(ints, w, h, z.points);
        patches[z.id] = p;
        if (rules.wantsRef(z.id)) {
          rules.setRef(z.id, p, night, t);
          changed = true;
        }
      }
      if (changed) onRefsChanged?.call(rules.refs());
      final (wd, mn) = _local(d);
      out.addAll(rules.step(t, wd, mn, null, night: night, patches: patches)
          .where((x) => x['type'] == kDetGateOpen));
    }
    return out.where(_allow).toList();
  }

  bool needsCheck() {
    if (!active) return false;
    final d = now();
    final (wd, mn) = _local(d);
    return rules.needsPersonCheck(_t(d), wd, mn, lastCheck);
  }

  /// The person boxes of one check (null = no model) -> detections.
  List<Map<String, Object?>> onBoxes(List<List<double>>? boxes, {bool night = false}) {
    if (!active) return const [];
    final d = now();
    final t = _t(d);
    lastCheck = t;
    final (wd, mn) = _local(d);
    return rules.step(t, wd, mn, boxes, night: night).where(_allow).toList();
  }

  bool _allow(Map<String, Object?> det) {
    final t = _t(now());
    final key = '${det['type']}/${det['zone'] ?? ''}';
    if (t - (_cool[key] ?? -1e9) < cooldownS) return false;
    _cool[key] = t;
    return true;
  }

  Map<String, dynamic> signals(Map<String, Object?> det, {required bool model}) =>
      detectionSignals(det, detector: model ? 'yolox_nano_phone' : 'android_frame_diff',
          source: 'phone_camera');
}
