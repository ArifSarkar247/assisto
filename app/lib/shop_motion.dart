import 'dart:math' as math;
import 'dart:typed_data';

/// Shop Box mode (an old Android phone as the shop camera) — PURE on-device
/// motion logic. No Flutter, no plugins, no I/O: it works on a luminance (Y)
/// plane the camera plugin hands us and is unit-tested in isolation.
///
/// How it works (cheap on purpose — old phones):
///   * the Y plane is box-averaged down to a small grid ([gridW] x [gridH]);
///   * a running-average background is kept per cell;
///   * a cell "moved" when |cell - background| > [cellThreshold];
///   * a frame-wide change above [globalResetFrac] (lights switched, auto
///     exposure jump) resets the background and reports NO motion;
///   * motion must persist for [confirmFrames] consecutive samples.
///   * cctvacc: all of this now runs through [MotionGate] — the SAME rules
///     and constants as the Shop Box (exposure compensation, per-cell noise,
///     still-change absorption, blob + freshness filter, 3-frame persistence).
///
/// The optional cash zone is a normalised rectangle (0..1). Detection results
/// are SIGNALS only — the server's combined-signal rule decides on an alert,
/// and the owner always reads "please check", never an accusation.
class MotionResult {
  final bool motion; // confirmed motion anywhere
  final bool inZone; // confirmed motion inside the cash zone
  final double changedFrac; // share of cells that changed this frame
  final bool reset; // background was reset (global change)
  const MotionResult(
      {required this.motion,
      required this.inZone,
      required this.changedFrac,
      this.reset = false});
}

/// A normalised rectangle (0..1) — the optional cash-drawer zone.
class ZoneRect {
  final double left, top, right, bottom;
  const ZoneRect(this.left, this.top, this.right, this.bottom);

  bool get isValid =>
      right > left && bottom > top && left >= 0 && top >= 0 && right <= 1 && bottom <= 1;

  Map<String, dynamic> toJson() =>
      {'left': left, 'top': top, 'right': right, 'bottom': bottom};

  static ZoneRect? fromJson(Object? j) {
    if (j is! Map) return null;
    double d(Object? v) => v is num ? v.toDouble() : -1;
    final z = ZoneRect(d(j['left']), d(j['top']), d(j['right']), d(j['bottom']));
    return z.isValid ? z : null;
  }
}

// ------------------------------------------------------------- cctvacc gate
/// The motion GATE shared with the Shop Box (edge/shopbox/shopbox/
/// motion_gate.py): the same algorithm and the same constants (both test
/// suites assert them equal to edge/shopbox/shopbox/cctv_thresholds.json and
/// run the same fixture cases), so the phone and the box decide alike.
///   1. exposure compensated (median ratio): auto exposure / flicker ignored;
///   2. a big global jump or >= [kGateGlobalFrac] of cells changing = scene
///      change (lights, IR switch): adopt it for [kGateHoldFrames] frames;
///   3. a cell moved when |cell - bg*ratio| > max(cellThr, kSigma*noise) —
///      swaying trees, rain and IR noise raise their own noise;
///   4. a still change (a lamp in one corner) is absorbed after
///      [kGateStableFrames] frames;
///   5. only 8-connected blobs >= [kGateMinBlob] cells holding >=
///      [kGateMinFresh] cells that changed since the last frame count;
///   6. confirmed after [kGateConfirmFrames] candidate frames in a row.
const kGateGridW = 32;
const kGateGridH = 24;
const kGateCellThr = 14.0;
const kGateKSigma = 3.0;
const kGateSigma0 = 4.0;
const kGateVarLearn = 0.1;
const kGateVarCap = 3600.0;
const kGateBgLearn = 0.08;
const kGateRatioMin = 0.6;
const kGateRatioMax = 1.6667;
const kGateGlobalFrac = 0.35;
const kGateMinBlob = 3;
const kGateMinFresh = 2;
const kGateFreshDiff = 7.0;
const kGateStableFrames = 2;
const kGateHoldFrames = 2;
const kGateConfirmFrames = 3;

/// Person-check thresholds (the native channel applies the night one when
/// the photo is grey / IR or dark — same rule as the Shop Box night.py).
const kPersonScoreDay = 0.45;
const kPersonScoreNight = 0.30;
const kNightSpreadMax = 10.0;
const kNightLumaMax = 40.0;

class GateResult {
  final bool candidate;
  final bool confirmed;
  final bool sceneChange;
  final bool warmingUp;
  final double frac;
  final List<bool>? moved;
  const GateResult(
      {this.candidate = false,
      this.confirmed = false,
      this.sceneChange = false,
      this.warmingUp = false,
      this.frac = 0,
      this.moved});
}

double _median(Float64List v) {
  final s = Float64List.fromList(v)..sort();
  final n = s.length;
  if (n == 0) return 0;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

class MotionGate {
  final int confirmFrames;
  List<bool>? mask; // cells that count (null = all)
  Float64List? _bg, _var, _prev;
  List<int>? _stable;
  int _hold = 0;
  int streak = 0;

  MotionGate({this.mask, this.confirmFrames = kGateConfirmFrames});

  void reset() {
    _bg = null;
    _var = null;
    _prev = null;
    _stable = null;
    _hold = 0;
    streak = 0;
  }

  void _adopt(Float64List g) {
    _bg = Float64List.fromList(g);
    _prev = Float64List.fromList(g);
    _stable = List<int>.filled(g.length, 0);
    streak = 0;
  }

  static bool anyBlob(List<bool> moved, List<bool> fresh,
      {int w = kGateGridW, int h = kGateGridH}) {
    final seen = List<bool>.filled(moved.length, false);
    for (var s = 0; s < moved.length; s++) {
      if (!moved[s] || seen[s]) continue;
      var size = 0, nFresh = 0;
      final stack = <int>[s];
      seen[s] = true;
      while (stack.isNotEmpty) {
        final i = stack.removeLast();
        size++;
        if (fresh[i]) nFresh++;
        final y = i ~/ w, x = i % w;
        for (var dy = -1; dy <= 1; dy++) {
          final ny = y + dy;
          if (ny < 0 || ny >= h) continue;
          for (var dx = -1; dx <= 1; dx++) {
            final nx = x + dx;
            if ((dx == 0 && dy == 0) || nx < 0 || nx >= w) continue;
            final j = ny * w + nx;
            if (moved[j] && !seen[j]) {
              seen[j] = true;
              stack.add(j);
            }
          }
        }
      }
      if (size >= kGateMinBlob && nFresh >= kGateMinFresh) return true;
    }
    return false;
  }

  GateResult feed(Float64List g) {
    final bg0 = _bg;
    if (bg0 == null || bg0.length != g.length) {
      _adopt(g);
      _var = Float64List(g.length)..fillRange(0, g.length, kGateSigma0 * kGateSigma0);
      _hold = 0;
      return const GateResult(warmingUp: true);
    }
    if (_hold > 0) {
      _hold--;
      _adopt(g);
      return const GateResult(sceneChange: true);
    }
    final mg = _median(g);
    final ratio = (mg + 1) / (_median(bg0) + 1);
    if (ratio < kGateRatioMin || ratio > kGateRatioMax) {
      _adopt(g);
      _hold = kGateHoldFrames;
      return const GateResult(sceneChange: true);
    }
    final n = g.length;
    final v = _var!;
    final pred = Float64List(n);
    final d = Float64List(n);
    final moved = List<bool>.filled(n, false);
    var nMoved = 0;
    for (var i = 0; i < n; i++) {
      pred[i] = bg0[i] * ratio;
      d[i] = g[i] - pred[i];
      final sd = kGateKSigma * math.sqrt(v[i]);
      final thr = sd > kGateCellThr ? sd : kGateCellThr;
      if (d[i].abs() > thr) {
        moved[i] = true;
        nMoved++;
      }
    }
    if (nMoved / n >= kGateGlobalFrac) {
      _adopt(g);
      _hold = kGateHoldFrames;
      return GateResult(sceneChange: true, frac: nMoved / n);
    }
    final prev = _prev!;
    final pr = (mg + 1) / (_median(prev) + 1);
    final st = _stable!;
    final fresh = List<bool>.filled(n, false);
    final absorb = List<bool>.filled(n, false);
    final m = mask;
    var nEff = 0;
    for (var i = 0; i < n; i++) {
      fresh[i] = (g[i] - prev[i] * pr).abs() > kGateFreshDiff;
      st[i] = (moved[i] && !fresh[i]) ? st[i] + 1 : 0;
      absorb[i] = st[i] >= kGateStableFrames;
      if (absorb[i]) moved[i] = false;
      if (m != null && m.length == n && !m[i]) moved[i] = false;
      if (moved[i]) nEff++;
    }
    final candidate = anyBlob(moved, fresh);
    for (var i = 0; i < n; i++) {
      final dd = d[i] * d[i];
      v[i] = (1 - kGateVarLearn) * v[i] + kGateVarLearn * (dd < kGateVarCap ? dd : kGateVarCap);
      bg0[i] = absorb[i] ? g[i] : (1 - kGateBgLearn) * pred[i] + kGateBgLearn * g[i];
      if (absorb[i]) st[i] = 0;
      prev[i] = g[i];
    }
    streak = candidate ? streak + 1 : 0;
    return GateResult(
        candidate: candidate,
        confirmed: streak >= confirmFrames,
        frac: nEff / n,
        moved: moved);
  }
}

class MotionDetector {
  final int gridW;
  final int gridH;
  final double zoneChangedFrac; // share of ZONE cells for "in zone"
  final int confirmFrames;

  ZoneRect? zone;
  final MotionGate _gate;
  int _streakZone = 0;

  MotionDetector({
    this.gridW = kGateGridW,
    this.gridH = kGateGridH,
    this.zoneChangedFrac = 0.06,
    this.confirmFrames = kGateConfirmFrames,
    this.zone,
  }) : _gate = MotionGate(confirmFrames: confirmFrames);

  void reset() {
    _gate.reset();
    _streakZone = 0;
  }

  /// Box-average a Y plane (row stride [rowStride]) into the small grid.
  Float64List downsample(Uint8List y, int width, int height, int rowStride) {
    final out = Float64List(gridW * gridH);
    final cw = width / gridW, ch = height / gridH;
    // sample a few pixels per cell (fast; old phones) instead of every pixel
    const s = 4;
    for (var gy = 0; gy < gridH; gy++) {
      for (var gx = 0; gx < gridW; gx++) {
        var sum = 0, n = 0;
        for (var iy = 0; iy < s; iy++) {
          final py = (gy * ch + (iy + 0.5) * ch / s).floor().clamp(0, height - 1);
          final row = py * rowStride;
          for (var ix = 0; ix < s; ix++) {
            final px = (gx * cw + (ix + 0.5) * cw / s).floor().clamp(0, width - 1);
            final idx = row + px;
            if (idx < y.length) {
              sum += y[idx];
              n++;
            }
          }
        }
        out[gy * gridW + gx] = n == 0 ? 0 : sum / n;
      }
    }
    return out;
  }

  /// Feed one luminance frame; returns the (debounced) decision.
  MotionResult feed(Uint8List y, int width, int height, int rowStride) {
    return feedGrid(downsample(y, width, height, rowStride));
  }

  MotionResult feedGrid(Float64List g) {
    final r = _gate.feed(g);
    if (r.sceneChange || r.warmingUp) {
      _streakZone = 0;
      return MotionResult(
          motion: false, inZone: false, changedFrac: r.frac, reset: r.sceneChange);
    }
    var zoneNow = false;
    final z = zone;
    final moved = r.moved;
    if (r.candidate && z != null && moved != null) {
      var zoneCells = 0, zoneChanged = 0;
      for (var i = 0; i < g.length; i++) {
        final cx = ((i % gridW) + 0.5) / gridW;
        final cy = ((i ~/ gridW) + 0.5) / gridH;
        if (cx >= z.left && cx <= z.right && cy >= z.top && cy <= z.bottom) {
          zoneCells++;
          if (moved[i]) zoneChanged++;
        }
      }
      zoneNow = zoneCells > 0 && zoneChanged / zoneCells >= zoneChangedFrac;
    }
    _streakZone = zoneNow ? _streakZone + 1 : 0;
    return MotionResult(
        motion: r.confirmed,
        inZone: _streakZone >= confirmFrames,
        changedFrac: r.frac);
  }
}

/// {"open": "HH:MM", "close": "HH:MM"} local hours. Mirrors the server's
/// camera_hooks.is_after_hours: overnight shops supported; no/invalid hours or
/// open == close -> never after hours.
bool isAfterHours(Map? hours, DateTime localNow) {
  if (hours == null) return false;
  int? mins(Object? v) {
    final p = (v ?? '').toString().split(':');
    if (p.length != 2) return null;
    final h = int.tryParse(p[0]), m = int.tryParse(p[1]);
    if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) return null;
    return h * 60 + m;
  }

  final o = mins(hours['open']), c = mins(hours['close']);
  if (o == null || c == null || o == c) return false;
  final t = localNow.hour * 60 + localNow.minute;
  if (o < c) return !(o <= t && t < c);
  return c <= t && t < o; // overnight: closed between close and open
}

/// What Shop Box mode posts for a detection, or null (nothing worth sending).
/// Mirrors the Windows Shop Box table: closed -> after_hours; open + zone
/// motion -> motion with zone_breach; open without zone -> nothing.
({String type, Map<String, dynamic> signals})? decideEvent(
    MotionResult r, {required bool afterHours, required bool hasZone}) {
  if (afterHours && r.motion) {
    return (
      type: 'after_hours',
      signals: {
        'after_hours': true,
        'multiple_frames': true,
        'detector': 'android_frame_diff',
      }
    );
  }
  if (!afterHours && hasZone && r.inZone) {
    return (
      type: 'motion',
      signals: {
        'zone_breach': true,
        'motion_in_zone': true,
        'detector': 'android_frame_diff',
      }
    );
  }
  return null;
}
