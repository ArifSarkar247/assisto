import 'dart:math' as math;

import 'package:flutter/services.dart';

import 'ps_identity.dart';
import 'ps_models.dart';

export 'ps_identity.dart' show IdentityThresholds;

/// Photo Studio on-device seams (ps1-photo, made real by p2-photo).
///
/// * [EnhanceEngine] — one-tap enhance. The real engine
///   (`StudioEnhanceEngine`, ps_enhance.dart) runs the classical pipeline on
///   every phone and, when the AI model is downloaded, Real-ESRGAN on-device.
/// * [FaceDetector] / [LandmarkProvider] — ML Kit through ps_native.dart.
/// * [IdentityGuard] — landmark geometry before vs after (ps_identity.dart).
/// * [SecureScreen] — FLAG_SECURE on the free preview.
/// None of them ever returns a fake result: an unavailable piece says so and
/// the studio hides the option that needs it.

// =========================================================================
// One-tap enhance
// =========================================================================
enum EnhanceState {
  /// No engine (only fakes / the website-photo flow): the enhance card is
  /// hidden — never a dead button.
  unavailable,

  /// The instant classical pipeline is ready (every phone).
  ready,
}

/// The optional on-device AI restore/upscale step.
enum AiState {
  /// Not on this phone/build or not published by the server: not shown.
  notOffered,

  /// Offered; needs a one-time download of [EnhanceAvailability.aiBytes].
  needsDownload,
  downloading,
  ready,

  /// The last download failed (network / checksum) — the user can retry.
  failed,
}

class EnhanceAvailability {
  const EnhanceAvailability(this.state,
      {this.ai = AiState.notOffered, this.progress = 0, this.aiBytes = 0, this.maxScale = 2});
  final EnhanceState state;
  final AiState ai;

  /// 0..1 while [ai] == downloading.
  final double progress;
  final int aiBytes;

  /// 2 or 4 — the largest upscale this phone can do.
  final int maxScale;
  bool get ready => state == EnhanceState.ready;
  static const unavailable = EnhanceAvailability(EnhanceState.unavailable);

  EnhanceAvailability withAi(AiState a, {double? progress}) => EnhanceAvailability(state,
      ai: a, progress: progress ?? this.progress, aiBytes: aiBytes, maxScale: maxScale);
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
    this.faceRestore = false,
    this.ai = false,
    this.maxLongEdge,
  });
  final EditStrength strength;
  final int upscale;
  final bool denoise;
  final bool deblur;
  final bool lowLight;
  final bool restoreOld;
  final bool colorize;

  /// No face-restoration model is used (GFPGAN / CodeFormer are not licence
  /// clean); kept false.
  final bool faceRestore;

  /// Run the on-device AI restore/upscale step first (when ready).
  final bool ai;

  /// Render at most this long edge (free preview = reduced size).
  final int? maxLongEdge;

  EnhanceRequest copyWith({EditStrength? strength, bool? ai, int? maxLongEdge, bool clearMax = false}) =>
      EnhanceRequest(
          strength: strength ?? this.strength,
          upscale: upscale,
          denoise: denoise,
          deblur: deblur,
          lowLight: lowLight,
          restoreOld: restoreOld,
          colorize: colorize,
          faceRestore: faceRestore,
          ai: ai ?? this.ai,
          maxLongEdge: clearMax ? null : (maxLongEdge ?? this.maxLongEdge));

  EnhanceRequest withStrength(EditStrength s) => copyWith(strength: s);
  EnhanceRequest withMaxLongEdge(int? px) =>
      px == null ? copyWith(clearMax: true) : copyWith(maxLongEdge: px);
}

class EnhanceUnavailable implements Exception {
  const EnhanceUnavailable(this.state);
  final EnhanceState state;
}

/// What the last [EnhanceEngine.enhance] actually did (shown honestly).
class EnhanceReport {
  const EnhanceReport(
      {this.aiUsed = false, this.aiRejected = false, this.aiFailed = false, this.ms = 0, this.ep = ''});
  final bool aiUsed;

  /// d1-photo: the AI step itself failed on this phone (reported to Owner
  /// Admin -> App errors); the classical result was used and the user is told.
  final bool aiFailed;

  /// The AI result did not keep the face geometry -> the classical-only
  /// result was used instead.
  final bool aiRejected;
  final int ms;
  final String ep;
  static const none = EnhanceReport();
}

abstract class EnhanceEngine {
  Future<EnhanceAvailability> availability();

  /// Start (or resume) the in-app AI model download. Never a separate install.
  Future<EnhanceAvailability> prepare({void Function(EnhanceAvailability)? onProgress});

  /// Encoded image in -> encoded image out. Throws [EnhanceUnavailable] when
  /// not ready; never returns the input pretending it was enhanced.
  Future<Uint8List> enhance(Uint8List encoded, EnhanceRequest req);

  EnhanceReport get lastReport;
}

class UnavailableEnhanceEngine implements EnhanceEngine {
  const UnavailableEnhanceEngine();
  @override
  Future<EnhanceAvailability> availability() async => EnhanceAvailability.unavailable;
  @override
  Future<EnhanceAvailability> prepare({void Function(EnhanceAvailability)? onProgress}) async =>
      EnhanceAvailability.unavailable;
  @override
  Future<Uint8List> enhance(Uint8List encoded, EnhanceRequest req) =>
      Future.error(const EnhanceUnavailable(EnhanceState.unavailable));
  @override
  EnhanceReport get lastReport => EnhanceReport.none;
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
///  * landmark geometry (Procrustes residual in inter-ocular units,
///    ps_identity.dart), and
///  * embedding cosine similarity only if a licensed embedder is ever linked
///    (none is: .phaseB/MODEL_LICENSES.md).
/// Missing landmarks / a failed detection -> [IdentityOutcome.cannotVerify]
/// (the caller must NOT show the result).
class IdentityGuard {
  const IdentityGuard({
    this.landmarks = const UnavailableLandmarks(),
    this.embedder = const UnavailableEmbedder(),
    this.minSimilarity = 0.80,
    this.thresholds = const IdentityThresholds(),
  });
  final LandmarkProvider landmarks;
  final FaceEmbedder embedder;
  final double minSimilarity;
  final IdentityThresholds thresholds;

  bool get available => landmarks.available;

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
    final List<List<math.Point<double>>> lb, la;
    try {
      lb = await landmarks.landmarks(before);
      la = await landmarks.landmarks(after);
    } catch (_) {
      return const IdentityVerdict(IdentityOutcome.cannotVerify);
    }
    final r = decideIdentity(lb, la, t: thresholds);
    switch (r.decision) {
      case IdentityDecision.noFaces:
        return const IdentityVerdict(IdentityOutcome.noFaces);
      case IdentityDecision.cannotVerify:
        return const IdentityVerdict(IdentityOutcome.cannotVerify);
      case IdentityDecision.different:
        return IdentityVerdict(IdentityOutcome.different, landmarkDelta: r.worst?.rms);
      case IdentityDecision.same:
        break;
    }
    double? sim;
    if (embedder.available) {
      final eb = await embedder.embed(before);
      final ea = await embedder.embed(after);
      if (eb.length != ea.length || eb.isEmpty) {
        return IdentityVerdict(IdentityOutcome.different, landmarkDelta: r.worst?.rms);
      }
      sim = 1.0;
      for (var i = 0; i < eb.length; i++) {
        sim = math.min(sim!, cosine(eb[i], ea[i]));
      }
    }
    final same = sim == null || sim >= minSimilarity;
    return IdentityVerdict(same ? IdentityOutcome.same : IdentityOutcome.different,
        similarity: sim, landmarkDelta: r.worst?.rms);
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

/// Talks to PhotoNativeChannel.kt ("com.assisto/photo_secure"): sets
/// FLAG_SECURE on the activity window while a free preview is open and
/// clears it when the user leaves Photo Studio. Off Android (or on an APK
/// without the channel) it reports false and the screen says nothing.
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
