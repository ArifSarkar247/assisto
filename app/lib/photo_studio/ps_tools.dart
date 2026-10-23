/// Photo Studio — the d1-photo tool set (pure parts + the engine seam).
///
/// ON-DEVICE (free to us, offline once the models are on the phone):
///   * Upscale 2x / 4x  — Real-ESRGAN general x4v3 (BSD-3) via ONNX Runtime,
///                        tiled, per-tile progress, cancel;
///   * Denoise          — classical edge-preserving denoise (ps_classic.dart);
///   * Low-light fix    — classical levels + strong gamma lift + denoise;
///   * Background blur  — U²-Net-p mask (Apache-2.0) via ONNX Runtime, then a
///                        Dart blur composite: the person's pixels are the
///                        ORIGINAL pixels (identity cannot change).
/// SERVER / GPU (key-gated, credits/ads + Profit Guard, ps_controller.dart):
///   deblur (NAFNet), colorize (DDColor), old-photo restore. Face restoration
///   is NOT offered: no licence-clean model exists (.phaseB/MODEL_LICENSES.md).
///
/// Nothing here fakes a result: a tool whose model/runtime is missing is
/// reported unavailable and the screen hides it.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'ps_report.dart';

enum PsTool {
  upscale2x('upscale2x'),
  upscale4x('upscale4x'),
  denoise('denoise'),
  lowLight('low_light'),
  bgBlur('bg_blur');

  const PsTool(this.wire);
  final String wire;
  bool get usesAi => this == upscale2x || this == upscale4x;
}

/// Which tools this phone can run for THIS photo, and roughly how long.
class ToolsAvailability {
  const ToolsAvailability({
    this.upscale2x = false,
    this.upscale4x = false,
    this.classic = false,
    this.bgBlur = false,
    this.needsUpscaleModel = false,
    this.needsMaskModel = false,
    this.etaMs = const {},
  });
  final bool upscale2x, upscale4x, classic, bgBlur;

  /// The tool exists on this phone but its model is not downloaded yet.
  final bool needsUpscaleModel, needsMaskModel;

  /// Estimated time per tool (measured per-tile speed × tiles).
  final Map<PsTool, int> etaMs;
  static const none = ToolsAvailability();

  bool has(PsTool t) => switch (t) {
        PsTool.upscale2x => upscale2x,
        PsTool.upscale4x => upscale4x,
        PsTool.denoise || PsTool.lowLight => classic,
        PsTool.bgBlur => bgBlur,
      };
  bool get any => upscale2x || upscale4x || classic || bgBlur;
}

/// Engine seam for the tools (StudioEnhanceEngine implements it; fakes in
/// tests). [progress] receives honest stage/tile updates while a call runs.
abstract class PhotoToolEngine {
  PsProgressFn? progress;
  Future<ToolsAvailability> tools(Uint8List encoded);

  /// Downloads whatever model [tool] still needs (progress via [progress]).
  Future<bool> prepareTool(PsTool tool);

  /// Encoded in -> encoded PNG out. Throws [PsCancelled] on cancel and
  /// [PhotoStudioFailure] on a real failure (already reported).
  Future<Uint8List> runTool(PsTool tool, Uint8List encoded, {int? maxLongEdge});
  Future<void> cancel();
}

// =========================================================================
// Upscale sizing (pure; mirrored by PhotoNativeChannel.kt which obeys it)
// =========================================================================
class UpscalePlan {
  const UpscalePlan(this.inputLong, this.targetLong, this.tiles);
  final int inputLong, targetLong, tiles;

  /// Largest source long edge each factor accepts (output ≤ 2560 px keeps
  /// the native buffers ~80 MB on a 4 GB phone).
  static const maxOut = 2560;
  static int maxSrc(int factor) => maxOut ~/ factor;

  /// Plan for a w×h photo and factor 2 or 4; null = too big for this tool.
  /// The model is always x4: 4x feeds the whole photo, 2x feeds the photo
  /// and shrinks the x4 result to x2 (sharper than running at half size).
  static UpscalePlan? of(int w, int h, int factor, {int tile = 128}) {
    final long = math.max(w, h);
    if (long > maxSrc(factor) || long < 16) return null;
    return UpscalePlan(long, long * factor, tilesFor(w, h, long, tile));
  }

  static int tilesFor(int w, int h, int inputLong, int tile) {
    final long = math.max(w, h);
    final f = inputLong / long;
    final iw = math.max(1, (w * f).round()), ih = math.max(1, (h * f).round());
    return ((iw + tile - 1) ~/ tile) * ((ih + tile - 1) ~/ tile);
  }
}

// =========================================================================
// Background blur composite (pure Dart, runs in an isolate)
// =========================================================================
/// Sample a mask (mw×mh, 0..255) bilinearly at image pixel (x, y) of w×h.
double _maskAt(Uint8List m, int mw, int mh, int w, int h, int x, int y) {
  final fx = ((x + 0.5) * mw / w - 0.5).clamp(0.0, mw - 1.0);
  final fy = ((y + 0.5) * mh / h - 0.5).clamp(0.0, mh - 1.0);
  final x0 = fx.floor(), y0 = fy.floor();
  final x1 = math.min(mw - 1, x0 + 1), y1 = math.min(mh - 1, y0 + 1);
  final ax = fx - x0, ay = fy - y0;
  final a = m[y0 * mw + x0] * (1 - ax) + m[y0 * mw + x1] * ax;
  final b = m[y1 * mw + x0] * (1 - ax) + m[y1 * mw + x1] * ax;
  return (a * (1 - ay) + b * ay) / 255.0;
}

/// Three box passes ≈ Gaussian. Separate RGB planes, edges clamped.
void _blurPlane(Float32List p, Float32List tmp, int w, int h, int r) {
  for (var pass = 0; pass < 3; pass++) {
    final win = 2 * r + 1;
    for (var y = 0; y < h; y++) {
      final row = y * w;
      var acc = 0.0;
      for (var k = -r; k <= r; k++) {
        acc += p[row + k.clamp(0, w - 1)];
      }
      for (var x = 0; x < w; x++) {
        tmp[row + x] = acc / win;
        acc += p[row + math.min(w - 1, x + r + 1)] - p[row + math.max(0, x - r)];
      }
    }
    for (var x = 0; x < w; x++) {
      var acc = 0.0;
      for (var k = -r; k <= r; k++) {
        acc += tmp[k.clamp(0, h - 1) * w + x];
      }
      for (var y = 0; y < h; y++) {
        p[y * w + x] = acc / win;
        acc += tmp[math.min(h - 1, y + r + 1) * w + x] - tmp[math.max(0, y - r) * w + x];
      }
    }
  }
}

/// Blur everything the mask calls background. Foreground (mask ≈ 1) keeps
/// the ORIGINAL pixels exactly; the edge is feathered by the mask's own
/// softness plus a small smoothstep. [strength] 0..1 scales the blur radius
/// (1 = ~1/40 of the long edge).
Uint8List blurBackgroundRgba(Uint8List rgba, int w, int h, Uint8List mask, int mw, int mh,
    {double strength = 0.7}) {
  assert(rgba.length == w * h * 4 && mask.length == mw * mh);
  final n = w * h;
  final r = math.max(1, (math.max(w, h) / 40 * strength.clamp(0.1, 1.0)).round());
  // blur at reduced size for speed when the photo is big (background only)
  final out = Uint8List.fromList(rgba);
  final planes = [Float32List(n), Float32List(n), Float32List(n)];
  final tmp = Float32List(n);
  for (var i = 0; i < n; i++) {
    planes[0][i] = rgba[i * 4].toDouble();
    planes[1][i] = rgba[i * 4 + 1].toDouble();
    planes[2][i] = rgba[i * 4 + 2].toDouble();
  }
  for (final p in planes) {
    _blurPlane(p, tmp, w, h, r);
  }
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var a = _maskAt(mask, mw, mh, w, h, x, y);
      // smoothstep(0.25, 0.75): solid inside, soft but short edge
      a = ((a - 0.25) / 0.5).clamp(0.0, 1.0);
      a = a * a * (3 - 2 * a);
      final i = y * w + x;
      if (a >= 0.999) continue; // foreground: original pixel, untouched
      for (var c = 0; c < 3; c++) {
        out[i * 4 + c] = (rgba[i * 4 + c] * a + planes[c][i] * (1 - a)).round().clamp(0, 255);
      }
    }
  }
  return out;
}

/// Share of the image the mask calls foreground (0..1) — a mask that keeps
/// (almost) nothing or (almost) everything is not a usable portrait mask.
double maskCoverage(Uint8List mask) {
  if (mask.isEmpty) return 0;
  var on = 0;
  for (final v in mask) {
    if (v >= 128) on++;
  }
  return on / mask.length;
}
