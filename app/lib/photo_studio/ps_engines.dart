import 'dart:math' as math;

import 'package:flutter/services.dart';

import 'ps_models.dart';

/// Photo Studio on-device seams (ps1-photo).
///
/// Every native piece (on-device super-resolution runtime + models, ML Kit
/// face detection, face landmarks/embedding, FLAG_SECURE) sits behind one of
/// these interfaces. In THIS build none of the native parts are linked, so the
/// default implementations report an honest "not available in this build
/// yet" state — they never return a fake enhanced image. The integrator binds
/// real implementations after the native proposal
/// (`.phaseB/proposals/ps1-photo.md`) passes a launch smoke.

// =========================================================================
// One-tap enhance
// =========================================================================
enum EnhanceState {
  /// The runtime/model is not part of this app build.
  notInBuild,

  /// Runtime present, model must be downloaded first ("preparing the photo
  /// tool…").
  needsDownload,
  downloading,
  ready,
}

class EnhanceAvailability {
  const EnhanceAvailability(this.state, {this.progress = 0, this.maxScale = 2});
  final EnhanceState state;
  final double progress;

  /// 2 or 4 — the largest upscale this phone can do.
  final int maxScale;
  bool get ready => state == EnhanceState.ready;
  static const notInBuild = EnhanceAvailability(EnhanceState.notInBuild);
}

class EnhanceRequest {
  const EnhanceRequest({
    this.strength = EditStrength.natural,
    this.upscale = 2,
    this.denoise = true,
    this.deblur = true,
    this.lowLight = true,
    this.restoreOld = false,
    this.colorize = false,
    this.faceRestore = true,
    this.maxLongEdge,
  });
  final EditStrength strength;
  final int upscale;
  final bool denoise;
  final bool deblur;
  final bool lowLight;
  final bool restoreOld;
  final bool colorize;
  final bool faceRestore;

  /// Render at most this long edge (free preview = reduced size).
  final int? maxLongEdge;

  EnhanceRequest withStrength(EditStrength s) => EnhanceRequest(
      strength: s,
      upscale: upscale,
      denoise: denoise,
      deblur: deblur,
      lowLight: lowLight,
      restoreOld: restoreOld,
      colorize: colorize,
      faceRestore: faceRestore,
      maxLongEdge: maxLongEdge);

  EnhanceRequest withMaxLongEdge(int? px) => EnhanceRequest(
      strength: strength,
      upscale: upscale,
      denoise: denoise,
      deblur: deblur,
      lowLight: lowLight,
      restoreOld: restoreOld,
      colorize: colorize,
      faceRestore: faceRestore,
      maxLongEdge: px);
}

class EnhanceUnavailable implements Exception {
  const EnhanceUnavailable(this.state);
  final EnhanceState state;
}

abstract class EnhanceEngine {
  Future<EnhanceAvailability> availability();

  /// Start (or resume) the in-app model download. Never a separate install.
  Future<EnhanceAvailability> prepare();

  /// Encoded image in -> encoded image out. Throws [EnhanceUnavailable] when
  /// not ready; never returns the input pretending it was enhanced.
  Future<Uint8List> enhance(Uint8List encoded, EnhanceRequest req);
}

class UnavailableEnhanceEngine implements EnhanceEngine {
  const UnavailableEnhanceEngine();
  @override
  Future<EnhanceAvailability> availability() async => EnhanceAvailability.notInBuild;
  @override
  Future<EnhanceAvailability> prepare() async => EnhanceAvailability.notInBuild;
  @override
  Future<Uint8List> enhance(Uint8List encoded, EnhanceRequest req) =>
      Future.error(const EnhanceUnavailable(EnhanceState.notInBuild));
}

// =========================================================================
// Faces
// =========================================================================
/// A face box, normalised 0..1 to the image size.
class FaceBox {
  const FaceBox(this.x, this.y, this.w, this.h);
  final double x, y, w, h;
  List<double> toList() => [x, y, w, h];
}

abstract class FaceDetector {
  bool get available;
  Future<List<FaceBox>> detect(Uint8List encoded);
}

class UnavailableFaceDetector implements FaceDetector {
  const UnavailableFaceDetector();
  @override
  bool get available => false;
  @override
  Future<List<FaceBox>> detect(Uint8List encoded) async => const [];
}

/// Facial landmarks for each face (e.g. eye centres, nose tip, mouth corners,
/// jaw contour), in image pixels. Order must be stable between calls.
abstract class LandmarkProvider {
  bool get available;
  Future<List<List<math.Point<double>>>> landmarks(Uint8List encoded);
}

class UnavailableLandmarks implements LandmarkProvider {
  const UnavailableLandmarks();
  @override
  bool get available => false;
  @override
  Future<List<List<math.Point<double>>>> landmarks(Uint8List encoded) async => const [];
}

/// ArcFace-class embedding per face. NO commercially licensed model is
/// chosen yet (.phaseB/MODEL_LICENSES.md) — default is unavailable.
abstract class FaceEmbedder {
  bool get available;
  Future<List<List<double>>> embed(Uint8List encoded);
}

class UnavailableEmbedder implements FaceEmbedder {
  const UnavailableEmbedder();
  @override
  bool get available => false;
  @override
  Future<List<List<double>>> embed(Uint8List encoded) async => const [];
}

// =========================================================================
// Identity guard
// =========================================================================
enum IdentityOutcome { same, different, cannotVerify, noFaces }

class IdentityVerdict {
  const IdentityVerdict(this.outcome, {this.similarity, this.landmarkDelta});
  final IdentityOutcome outcome;
  final double? similarity;
  final double? landmarkDelta;
  bool get pass => outcome == IdentityOutcome.same || outcome == IdentityOutcome.noFaces;
}

/// "Same person, best version": compare BEFORE vs AFTER with
///  * landmark geometry (normalised by inter-ocular distance), and
///  * embedding cosine similarity when a licensed embedder is linked.
/// Missing landmarks -> [IdentityOutcome.cannotVerify] (the caller must NOT
/// show the result).
class IdentityGuard {
  const IdentityGuard({
    this.landmarks = const UnavailableLandmarks(),
    this.embedder = const UnavailableEmbedder(),
    this.minSimilarity = 0.80,
    this.maxLandmarkDelta = 0.035,
  });
  final LandmarkProvider landmarks;
  final FaceEmbedder embedder;
  final double minSimilarity;
  final double maxLandmarkDelta;

  bool get available => landmarks.available;

  static List<math.Point<double>> normalise(List<math.Point<double>> pts) {
    if (pts.length < 2) return pts;
    // first two points are the eye centres by contract
    final a = pts[0], b = pts[1];
    final cx = (a.x + b.x) / 2, cy = (a.y + b.y) / 2;
    final iod = math.max(1e-6, a.distanceTo(b));
    return [for (final p in pts) math.Point((p.x - cx) / iod, (p.y - cy) / iod)];
  }

  static double geometryDelta(List<math.Point<double>> before, List<math.Point<double>> after) {
    final n = math.min(before.length, after.length);
    if (n == 0) return double.infinity;
    final b = normalise(before.sublist(0, n));
    final a = normalise(after.sublist(0, n));
    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      sum += b[i].distanceTo(a[i]);
    }
    return sum / n;
  }

  static double cosine(List<double> a, List<double> b) {
    final n = math.min(a.length, b.length);
    var dot = 0.0, na = 0.0, nb = 0.0;
    for (var i = 0; i < n; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    if (na <= 0 || nb <= 0) return 0;
    return dot / (math.sqrt(na) * math.sqrt(nb));
  }

  Future<IdentityVerdict> check(Uint8List before, Uint8List after) async {
    if (!landmarks.available) {
      return const IdentityVerdict(IdentityOutcome.cannotVerify);
    }
    final lb = await landmarks.landmarks(before);
    final la = await landmarks.landmarks(after);
    if (lb.isEmpty) return const IdentityVerdict(IdentityOutcome.noFaces);
    if (la.length != lb.length) return const IdentityVerdict(IdentityOutcome.different);
    var worst = 0.0;
    for (var i = 0; i < lb.length; i++) {
      worst = math.max(worst, geometryDelta(lb[i], la[i]));
    }
    double? sim;
    if (embedder.available) {
      final eb = await embedder.embed(before);
      final ea = await embedder.embed(after);
      if (eb.length != ea.length || eb.isEmpty) {
        return IdentityVerdict(IdentityOutcome.different, landmarkDelta: worst);
      }
      sim = 1.0;
      for (var i = 0; i < eb.length; i++) {
        sim = math.min(sim!, cosine(eb[i], ea[i]));
      }
    }
    final same = worst <= maxLandmarkDelta && (sim == null || sim >= minSimilarity);
    return IdentityVerdict(same ? IdentityOutcome.same : IdentityOutcome.different,
        similarity: sim, landmarkDelta: worst);
  }
}

/// Run an edit under the identity guard: natural -> light -> light again is
/// pointless, so at most [maxTries] progressively lighter attempts; if none is
/// clearly the same person the result is DISCARDED (null) and the original
/// stays.
class GuardedEdit {
  const GuardedEdit(this.guard, {this.maxTries = 2});
  final IdentityGuard guard;
  final int maxTries;

  Future<GuardedResult> run(Uint8List before, EditStrength start,
      Future<Uint8List> Function(EditStrength) edit,
      {bool hasPeople = true}) async {
    var s = start;
    for (var i = 0; i < maxTries; i++) {
      final out = await edit(s);
      if (!hasPeople) return GuardedResult(out, s, const IdentityVerdict(IdentityOutcome.noFaces));
      final v = await guard.check(before, out);
      if (v.outcome == IdentityOutcome.cannotVerify) return GuardedResult(null, s, v);
      if (v.pass) return GuardedResult(out, s, v);
      if (s == EditStrength.light) return GuardedResult(null, s, v);
      s = s.lighter;
    }
    return GuardedResult(null, s, const IdentityVerdict(IdentityOutcome.different));
  }
}

class GuardedResult {
  const GuardedResult(this.image, this.strength, this.verdict);
  final Uint8List? image;
  final EditStrength strength;
  final IdentityVerdict verdict;
}

// =========================================================================
// Face-lock compositor (pure Dart, RGBA)
// =========================================================================
/// FACE-LOCK: put the ORIGINAL face pixels back over the edited image inside
/// each face ellipse, with a feathered (smoothstep) edge so the seam blends.
/// [original] and [edited] are RGBA8888 buffers of the same w×h.
Uint8List compositeFaces(Uint8List original, Uint8List edited, int w, int h,
    List<FaceBox> faces,
    {double feather = 0.18}) {
  assert(original.length == w * h * 4 && edited.length == w * h * 4);
  final out = Uint8List.fromList(edited);
  for (final f in faces) {
    final cx = (f.x + f.w / 2) * w, cy = (f.y + f.h / 2) * h;
    // expand a little so hairline/jaw stay original too
    final rx = f.w * w * 0.55, ry = f.h * h * 0.6;
    if (rx <= 0 || ry <= 0) continue;
    final x0 = math.max(0, (cx - rx).floor()), x1 = math.min(w - 1, (cx + rx).ceil());
    final y0 = math.max(0, (cy - ry).floor()), y1 = math.min(h - 1, (cy + ry).ceil());
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        final dx = (x + 0.5 - cx) / rx, dy = (y + 0.5 - cy) / ry;
        final d = math.sqrt(dx * dx + dy * dy); // 0 centre .. 1 edge
        if (d >= 1) continue;
        final inner = 1 - feather;
        double a;
        if (d <= inner) {
          a = 1;
        } else {
          final t = (d - inner) / feather; // 0..1
          a = 1 - t * t * (3 - 2 * t);
        }
        final i = (y * w + x) * 4;
        for (var c = 0; c < 4; c++) {
          out[i + c] = (original[i + c] * a + out[i + c] * (1 - a)).round();
        }
      }
    }
  }
  return out;
}

// =========================================================================
// Screenshot / screen-recording block (Android FLAG_SECURE)
// =========================================================================
abstract class SecureScreen {
  /// true when the platform actually applied the flag.
  Future<bool> enable();
  Future<void> disable();
}

/// Talks to a tiny MainActivity channel (proposal ps1-photo, native part).
/// Until that ships the channel is missing and this honestly reports false.
class ChannelSecureScreen implements SecureScreen {
  const ChannelSecureScreen();
  static const _ch = MethodChannel('com.assisto/photo_secure');
  @override
  Future<bool> enable() async {
    try {
      return (await _ch.invokeMethod<bool>('enable')) == true;
    } catch (_) {
      return false; // MissingPluginException in this build
    }
  }

  @override
  Future<void> disable() async {
    try {
      await _ch.invokeMethod<bool>('disable');
    } catch (_) {}
  }
}
