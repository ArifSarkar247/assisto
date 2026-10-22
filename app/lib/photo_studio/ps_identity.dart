/// Photo Studio — IDENTITY CHECK geometry (p2-photo). Pure Dart.
///
/// "Same person, best version": an edit is only kept when the face geometry
/// AFTER matches BEFORE. Landmarks come from ML Kit face detection on the
/// phone (PhotoFaces.kt), in a fixed order:
///   0 LEFT_EYE, 1 RIGHT_EYE, 2 NOSE_BASE, 3 MOUTH_LEFT, 4 MOUTH_RIGHT,
///   5 MOUTH_BOTTOM, 6 LEFT_CHEEK, 7 RIGHT_CHEEK
/// (fakes in tests may send fewer points; the first two are always the eyes).
///
/// Comparison: an optimal 2-D similarity alignment (Procrustes: translation +
/// rotation + uniform scale) of AFTER onto BEFORE, then the residual of every
/// point in units of BEFORE's inter-ocular distance (IOD). Rotation/zoom/crop
/// of the whole photo therefore does NOT count as a change; moving a feature
/// relative to the others (a different nose, wider jaw, moved mouth) does.
///
/// No face-embedding model is used: none with a clear commercial licence was
/// found (see .phaseB/MODEL_LICENSES.md, re-checked 22 Oct 2026).
library;

import 'dart:math' as math;

typedef Pt = math.Point<double>;

/// Conservative thresholds (in IOD units). ML Kit landmark jitter between two
/// near-identical photos is ~0.01–0.03 IOD; a visibly different nose/mouth
/// position is ≥ 0.10 IOD. To be re-checked with real phone logs (Bangla
/// checklist in .phaseB/proposals/p2-photo.md).
class IdentityThresholds {
  const IdentityThresholds({this.maxRms = 0.05, this.maxPoint = 0.09});
  final double maxRms;
  final double maxPoint;
}

class GeometryScore {
  const GeometryScore(this.rms, this.maxPoint);
  final double rms;
  final double maxPoint;
  static const infinite = GeometryScore(double.infinity, double.infinity);
  bool within(IdentityThresholds t) => rms <= t.maxRms && maxPoint <= t.maxPoint;
}

/// Residual of [after] aligned onto [before] (same order, ≥ 3 points).
GeometryScore compareFaces(List<Pt> before, List<Pt> after) {
  final n = math.min(before.length, after.length);
  if (n < 3) return GeometryScore.infinite;
  final iod = before[0].distanceTo(before[1]);
  if (!(iod > 1e-6)) return GeometryScore.infinite;
  var bx = 0.0, by = 0.0, ax = 0.0, ay = 0.0;
  for (var i = 0; i < n; i++) {
    bx += before[i].x;
    by += before[i].y;
    ax += after[i].x;
    ay += after[i].y;
  }
  bx /= n;
  by /= n;
  ax /= n;
  ay /= n;
  // optimal similarity transform mapping centred AFTER onto centred BEFORE
  var sa = 0.0, sb = 0.0, norm = 0.0;
  for (var i = 0; i < n; i++) {
    final px = after[i].x - ax, py = after[i].y - ay;
    final qx = before[i].x - bx, qy = before[i].y - by;
    sa += px * qx + py * qy;
    sb += px * qy - py * qx;
    norm += px * px + py * py;
  }
  if (norm <= 1e-9) return GeometryScore.infinite;
  final c = sa / norm, s = sb / norm;
  var se = 0.0, mx = 0.0;
  for (var i = 0; i < n; i++) {
    final px = after[i].x - ax, py = after[i].y - ay;
    final tx = c * px - s * py, ty = s * px + c * py;
    final dx = tx - (before[i].x - bx), dy = ty - (before[i].y - by);
    final d = math.sqrt(dx * dx + dy * dy) / iod;
    se += d * d;
    if (d > mx) mx = d;
  }
  return GeometryScore(math.sqrt(se / n), mx);
}

enum IdentityDecision { same, different, noFaces, cannotVerify }

class IdentityResult {
  const IdentityResult(this.decision, {this.worst});
  final IdentityDecision decision;
  final GeometryScore? worst;
}

/// Decide for whole photos. Faces are compared in the order the detector
/// returns them (left to right). Conservative rules:
///  * no faces before -> [IdentityDecision.noFaces] (nothing to protect);
///  * a face lost, or a NEW face appearing after the edit -> different;
///  * any face whose geometry moved beyond the thresholds -> different;
///  * a face whose landmarks were incomplete on either side -> cannotVerify
///    (the caller treats that like a failure: the edit is not used).
IdentityResult decideIdentity(List<List<Pt>> before, List<List<Pt>> after,
    {IdentityThresholds t = const IdentityThresholds()}) {
  if (before.isEmpty) {
    return const IdentityResult(IdentityDecision.noFaces);
  }
  if (after.length != before.length) {
    return const IdentityResult(IdentityDecision.different);
  }
  GeometryScore? worst;
  for (var i = 0; i < before.length; i++) {
    if (before[i].length < 3 || after[i].length < 3) {
      return const IdentityResult(IdentityDecision.cannotVerify);
    }
    final s = compareFaces(before[i], after[i]);
    if (worst == null || s.rms > worst.rms) worst = s;
    if (!s.within(t)) return IdentityResult(IdentityDecision.different, worst: s);
  }
  return IdentityResult(IdentityDecision.same, worst: worst);
}
