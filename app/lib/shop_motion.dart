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

class MotionDetector {
  final int gridW;
  final int gridH;
  final double cellThreshold; // luminance delta (0..255) for a cell to count
  final double minChangedFrac; // share of cells for "motion" anywhere
  final double zoneChangedFrac; // share of ZONE cells for "in zone"
  final double globalResetFrac;
  final int confirmFrames;
  final double learnRate;

  ZoneRect? zone;
  Float64List? _bg;
  int _streakAny = 0;
  int _streakZone = 0;

  MotionDetector({
    this.gridW = 32,
    this.gridH = 24,
    this.cellThreshold = 18,
    this.minChangedFrac = 0.01,
    this.zoneChangedFrac = 0.06,
    this.globalResetFrac = 0.6,
    this.confirmFrames = 2,
    this.learnRate = 0.08,
    this.zone,
  });

  void reset() {
    _bg = null;
    _streakAny = 0;
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
    final bg = _bg;
    if (bg == null || bg.length != g.length) {
      _bg = Float64List.fromList(g);
      return const MotionResult(motion: false, inZone: false, changedFrac: 0);
    }
    var changed = 0, zoneCells = 0, zoneChanged = 0;
    final z = zone;
    for (var i = 0; i < g.length; i++) {
      final moved = (g[i] - bg[i]).abs() > cellThreshold;
      if (moved) changed++;
      if (z != null) {
        final cx = ((i % gridW) + 0.5) / gridW;
        final cy = ((i ~/ gridW) + 0.5) / gridH;
        if (cx >= z.left && cx <= z.right && cy >= z.top && cy <= z.bottom) {
          zoneCells++;
          if (moved) zoneChanged++;
        }
      }
    }
    final frac = changed / g.length;
    if (frac >= globalResetFrac) {
      _bg = Float64List.fromList(g);
      _streakAny = 0;
      _streakZone = 0;
      return MotionResult(motion: false, inZone: false, changedFrac: frac, reset: true);
    }
    for (var i = 0; i < g.length; i++) {
      bg[i] = bg[i] * (1 - learnRate) + g[i] * learnRate;
    }
    final anyNow = frac >= minChangedFrac;
    final zoneNow = zoneCells > 0 && zoneChanged / zoneCells >= zoneChangedFrac;
    _streakAny = anyNow ? _streakAny + 1 : 0;
    _streakZone = zoneNow ? _streakZone + 1 : 0;
    return MotionResult(
        motion: _streakAny >= confirmFrames,
        inZone: _streakZone >= confirmFrames,
        changedFrac: frac);
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
