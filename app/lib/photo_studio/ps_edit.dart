/// Photo Studio — photobar (2 Nov): the everyday editor every competitor has
/// and we did not — crop / rotate / flip, colour filters, background fill
/// (white / blue / transparent), text + stickers (overlay patches drawn by
/// Flutter, composited here), Bangladesh ID / passport / visa sizes, the
/// 4x6 inch print sheet, the 300 DPI PNG tag and the portal JPEG under a KB
/// limit.
///
/// Every edit is a [PsPixelStep] (ps_recipe.dart): pure Dart, resolution-
/// free fields, so the proxy preview and the full-size export run the SAME
/// code ([applySteps]). Nothing here touches Flutter — it runs in isolates
/// and in plain unit tests.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'ps_recipe.dart';

// =========================================================================
// Crop / rotate / flip (+ exact output size for ID photos)
// =========================================================================
/// Crop rectangle in 0..1 of the rotated + flipped photo.
class PsCrop {
  const PsCrop(this.l, this.t, this.r, this.b);
  static const full = PsCrop(0, 0, 1, 1);
  final double l, t, r, b;
  bool get isFull => l <= 0 && t <= 0 && r >= 1 && b >= 1;

  /// The largest centred rect of [aspect] (w/h) inside a [w]×[h] photo.
  static PsCrop centred(int w, int h, double aspect) {
    if (w <= 0 || h <= 0 || aspect <= 0) return full;
    final photo = w / h;
    if (photo > aspect) {
      final f = aspect / photo; // share of the width kept
      return PsCrop((1 - f) / 2, 0, (1 + f) / 2, 1);
    }
    final f = photo / aspect; // share of the height kept
    return PsCrop(0, (1 - f) / 2, 1, (1 + f) / 2);
  }

  @override
  bool operator ==(Object o) => o is PsCrop && o.l == l && o.t == t && o.r == r && o.b == b;
  @override
  int get hashCode => Object.hash(l, t, r, b);
  @override
  String toString() => 'PsCrop($l, $t, $r, $b)';
}

/// Rotate (clockwise quarter [turns]) -> mirror ([flipH]) -> [crop] ->
/// optional exact [outW]×[outH] (area-average shrink; bilinear when it has
/// to grow — an ID preset on a small photo).
class GeoStep extends PsPixelStep {
  const GeoStep({this.turns = 0, this.flipH = false, this.crop = PsCrop.full, this.outW, this.outH});
  final int turns;
  final bool flipH;
  final PsCrop crop;
  final int? outW, outH;

  int get _t => ((turns % 4) + 4) % 4;
  bool get isIdentity => _t == 0 && !flipH && crop.isFull && outW == null;

  ({int w, int h}) rotated(int w, int h) => _t.isOdd ? (w: h, h: w) : (w: w, h: h);

  /// The crop in pixels of the rotated photo (never empty).
  ({int x, int y, int w, int h}) cropPx(int w, int h) {
    final r = rotated(w, h);
    final x0 = (crop.l * r.w).round().clamp(0, r.w - 1);
    final y0 = (crop.t * r.h).round().clamp(0, r.h - 1);
    final x1 = (crop.r * r.w).round().clamp(x0 + 1, r.w);
    final y1 = (crop.b * r.h).round().clamp(y0 + 1, r.h);
    return (x: x0, y: y0, w: x1 - x0, h: y1 - y0);
  }

  @override
  ({int w, int h}) outSize(int w, int h) {
    if (outW != null && outH != null) return (w: outW!, h: outH!);
    final c = cropPx(w, h);
    return (w: c.w, h: c.h);
  }

  @override
  RgbaOut apply(Uint8List rgba, int w, int h) {
    final r = rotated(w, h);
    final c = cropPx(w, h);
    final out = Uint8List(c.w * c.h * 4);
    final t = _t;
    for (var y = 0; y < c.h; y++) {
      final ry = y + c.y;
      var o = y * c.w * 4;
      for (var x = 0; x < c.w; x++) {
        var rx = x + c.x;
        if (flipH) rx = r.w - 1 - rx;
        int sx, sy;
        switch (t) {
          case 1:
            sx = ry;
            sy = h - 1 - rx;
          case 2:
            sx = w - 1 - rx;
            sy = h - 1 - ry;
          case 3:
            sx = w - 1 - ry;
            sy = rx;
          default:
            sx = rx;
            sy = ry;
        }
        final s = (sy * w + sx) * 4;
        out[o] = rgba[s];
        out[o + 1] = rgba[s + 1];
        out[o + 2] = rgba[s + 2];
        out[o + 3] = rgba[s + 3];
        o += 4;
      }
    }
    if (outW == null || outH == null || (outW == c.w && outH == c.h)) {
      return RgbaOut(out, c.w, c.h);
    }
    return RgbaOut(resizeRgba(out, c.w, c.h, outW!, outH!), outW!, outH!);
  }
}

/// Resize to exactly [nw]×[nh]: area average per axis when shrinking (no
/// aliasing on a 12 MP -> 531 px passport photo), bilinear when growing.
Uint8List resizeRgba(Uint8List src, int w, int h, int nw, int nh) {
  if (nw == w && nh == h) return Uint8List.fromList(src);
  // horizontal pass -> float rows, then vertical
  final tmp = Float32List(nw * h * 4);
  for (var y = 0; y < h; y++) {
    _resample(src, y * w * 4, 4, w, tmp, y * nw * 4, 4, nw);
  }
  final out = Uint8List(nw * nh * 4);
  final col = Float32List(h * 4);
  final res = Float32List(nh * 4);
  for (var x = 0; x < nw; x++) {
    for (var y = 0; y < h; y++) {
      final s = (y * nw + x) * 4;
      col[y * 4] = tmp[s];
      col[y * 4 + 1] = tmp[s + 1];
      col[y * 4 + 2] = tmp[s + 2];
      col[y * 4 + 3] = tmp[s + 3];
    }
    _resample(col, 0, 4, h, res, 0, 4, nh);
    for (var y = 0; y < nh; y++) {
      final o = (y * nw + x) * 4;
      for (var c = 0; c < 4; c++) {
        out[o + c] = res[y * 4 + c].round().clamp(0, 255);
      }
    }
  }
  return out;
}

/// One line of [n] RGBA pixels (stride [ss]) -> [m] pixels (stride [ds]).
void _resample(List<num> s, int so, int ss, int n, Float32List d, int dO, int ds, int m) {
  if (m <= n) {
    final scale = n / m;
    for (var i = 0; i < m; i++) {
      final a = i * scale, b = (i + 1) * scale;
      var acc0 = 0.0, acc1 = 0.0, acc2 = 0.0, acc3 = 0.0, wsum = 0.0;
      var k = a.floor();
      while (k < b && k < n) {
        final wgt = math.min(b, k + 1.0) - math.max(a, k.toDouble());
        if (wgt > 0) {
          final p = so + k * ss;
          acc0 += s[p].toDouble() * wgt;
          acc1 += s[p + 1].toDouble() * wgt;
          acc2 += s[p + 2].toDouble() * wgt;
          acc3 += s[p + 3].toDouble() * wgt;
          wsum += wgt;
        }
        k++;
      }
      final o = dO + i * ds;
      if (wsum <= 0) wsum = 1;
      d[o] = acc0 / wsum;
      d[o + 1] = acc1 / wsum;
      d[o + 2] = acc2 / wsum;
      d[o + 3] = acc3 / wsum;
    }
    return;
  }
  for (var i = 0; i < m; i++) {
    final f = ((i + 0.5) * n / m - 0.5).clamp(0.0, n - 1.0);
    final k0 = f.floor(), k1 = math.min(n - 1, k0 + 1);
    final a = f - k0;
    final p0 = so + k0 * ss, p1 = so + k1 * ss, o = dO + i * ds;
    for (var c = 0; c < 4; c++) {
      d[o + c] = (s[p0 + c] * (1 - a) + s[p1 + c] * a).toDouble();
    }
  }
}

// =========================================================================
// Colour filters (4x5 matrices, the same layout as Flutter's
// ColorFilter.matrix — so the live thumbnail and the export agree)
// =========================================================================
class PsMatrix {
  PsMatrix._();
  static const identity = <double>[
    1, 0, 0, 0, 0, //
    0, 1, 0, 0, 0, //
    0, 0, 1, 0, 0, //
    0, 0, 0, 1, 0,
  ];

  /// a·b (apply b first, then a).
  static List<double> mul(List<double> a, List<double> b) {
    final out = List<double>.filled(20, 0);
    for (var r = 0; r < 4; r++) {
      for (var c = 0; c < 5; c++) {
        var v = c == 4 ? a[r * 5 + 4] : 0.0;
        for (var k = 0; k < 4; k++) {
          v += a[r * 5 + k] * b[k * 5 + c];
        }
        out[r * 5 + c] = v;
      }
    }
    return out;
  }

  static List<double> chain(List<List<double>> ms) =>
      ms.fold(identity, (acc, m) => mul(m, acc));

  static List<double> saturation(double s) {
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final sr = (1 - s) * lr, sg = (1 - s) * lg, sb = (1 - s) * lb;
    return [
      sr + s, sg, sb, 0, 0, //
      sr, sg + s, sb, 0, 0, //
      sr, sg, sb + s, 0, 0, //
      0, 0, 0, 1, 0,
    ];
  }

  static List<double> contrast(double c) {
    final o = 128 * (1 - c);
    return [c, 0, 0, 0, o, 0, c, 0, 0, o, 0, 0, c, 0, o, 0, 0, 0, 1, 0];
  }

  static List<double> brightness(double b) =>
      [1, 0, 0, 0, b, 0, 1, 0, 0, b, 0, 0, 1, 0, b, 0, 0, 0, 1, 0];

  static List<double> scale(double r, double g, double b, {double or = 0, double og = 0, double ob = 0}) =>
      [r, 0, 0, 0, or, 0, g, 0, 0, og, 0, 0, b, 0, ob, 0, 0, 0, 1, 0];

  static const sepia = <double>[
    0.393, 0.769, 0.189, 0, 0, //
    0.349, 0.686, 0.168, 0, 0, //
    0.272, 0.534, 0.131, 0, 0, //
    0, 0, 0, 1, 0,
  ];

  /// [amount] 0..1 of [m] blended with identity.
  static List<double> mix(List<double> m, double amount) => [
        for (var i = 0; i < 20; i++) identity[i] + (m[i] - identity[i]) * amount.clamp(0.0, 1.0)
      ];
}

/// The filter presets (ids are stable; the screen localises the names).
class PsFilter {
  const PsFilter(this.id, this.matrix);
  final String id;
  final List<double> matrix;

  static final List<PsFilter> all = [
    const PsFilter('original', PsMatrix.identity),
    PsFilter('vivid', PsMatrix.chain([PsMatrix.saturation(1.35), PsMatrix.contrast(1.08)])),
    PsFilter('eid_glow', PsMatrix.chain([
      PsMatrix.brightness(10), PsMatrix.saturation(1.15), PsMatrix.scale(1.04, 1.0, 0.96)])),
    PsFilter('warm', PsMatrix.scale(1.08, 1.02, 0.90, or: 6)),
    PsFilter('cool', PsMatrix.scale(0.94, 1.0, 1.08, ob: 8)),
    PsFilter('golden', PsMatrix.chain([
      PsMatrix.scale(1.10, 1.04, 0.86, or: 8, og: 4), PsMatrix.saturation(1.1)])),
    PsFilter('drama', PsMatrix.chain([
      PsMatrix.contrast(1.28), PsMatrix.saturation(1.08), PsMatrix.brightness(-10)])),
    PsFilter('fade', PsMatrix.chain([PsMatrix.contrast(0.84), PsMatrix.brightness(18),
      PsMatrix.saturation(0.85)])),
    PsFilter('bw', PsMatrix.chain([PsMatrix.saturation(0), PsMatrix.contrast(1.1)])),
    const PsFilter('sepia', PsMatrix.sepia),
  ];

  static PsFilter? byId(String id) {
    for (final f in all) {
      if (f.id == id) return f;
    }
    return null;
  }
}

class FilterStep extends PsPixelStep {
  const FilterStep(this.id, this.matrix);
  final String id;
  final List<double> matrix;

  @override
  RgbaOut apply(Uint8List rgba, int w, int h) =>
      RgbaOut(applyColorMatrix(rgba, matrix), w, h);
}

/// RGB through the 4x5 [m] (offsets in 0..255), alpha kept.
Uint8List applyColorMatrix(Uint8List rgba, List<double> m) {
  final out = Uint8List(rgba.length);
  // lookup tables per input channel (256 entries x 3 outputs) — 9 tables
  final t = List<Float32List>.generate(9, (_) => Float32List(256));
  for (var v = 0; v < 256; v++) {
    for (var r = 0; r < 3; r++) {
      for (var c = 0; c < 3; c++) {
        t[r * 3 + c][v] = m[r * 5 + c] * v;
      }
    }
  }
  final o0 = m[4], o1 = m[9], o2 = m[14];
  for (var i = 0; i < rgba.length; i += 4) {
    final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
    out[i] = (t[0][r] + t[1][g] + t[2][b] + o0).round().clamp(0, 255);
    out[i + 1] = (t[3][r] + t[4][g] + t[5][b] + o1).round().clamp(0, 255);
    out[i + 2] = (t[6][r] + t[7][g] + t[8][b] + o2).round().clamp(0, 255);
    out[i + 3] = rgba[i + 3];
  }
  return out;
}

// =========================================================================
// Background fill (white / light blue / transparent) with the U²-Net mask
// =========================================================================
/// The background colours offered (ARGB). 0 = transparent.
class PsBg {
  PsBg._();
  static const white = 0xFFFFFFFF;
  static const blue = 0xFFD6E9FF; // the pale studio blue many forms accept
  static const transparent = 0x00000000;
}

/// Replace what the mask calls background by [argb]. The person keeps the
/// ORIGINAL pixels (identity cannot change); the edge is feathered by the
/// mask's softness. Transparent: straight alpha out of the mask; the fully
/// clear pixels carry a light checkerboard in RGB, so a viewer that ignores
/// alpha (the BMP preview) still shows "transparent" honestly — invisible
/// in the PNG.
class BgFillStep extends PsPixelStep {
  const BgFillStep(this.mask, this.side, this.argb, {this.maxLong = 2048});
  final Uint8List mask;
  final int side;
  final int argb;
  final int maxLong;

  @override
  ({int w, int h}) outSize(int w, int h) => psFitSize(w, h, maxLong);

  @override
  RgbaOut apply(Uint8List rgba, int w, int h) {
    var cur = rgba, cw = w, ch = h;
    final s = psFitSize(w, h, maxLong);
    if (s.w != w || s.h != h) {
      final small = resizeRgba(rgba, w, h, s.w, s.h);
      cur = small;
      cw = s.w;
      ch = s.h;
    }
    return RgbaOut(fillBackgroundRgba(cur, cw, ch, mask, side, side, argb), cw, ch);
  }
}

Uint8List fillBackgroundRgba(Uint8List rgba, int w, int h, Uint8List mask, int mw, int mh, int argb) {
  final out = Uint8List.fromList(rgba);
  final ca = (argb >> 24) & 0xFF;
  final cr = (argb >> 16) & 0xFF, cg = (argb >> 8) & 0xFF, cb = argb & 0xFF;
  for (var y = 0; y < h; y++) {
    final fy = ((y + 0.5) * mh / h - 0.5).clamp(0.0, mh - 1.0);
    final y0 = fy.floor(), y1 = math.min(mh - 1, y0 + 1);
    final ay = fy - y0;
    for (var x = 0; x < w; x++) {
      final fx = ((x + 0.5) * mw / w - 0.5).clamp(0.0, mw - 1.0);
      final x0 = fx.floor(), x1 = math.min(mw - 1, x0 + 1);
      final ax = fx - x0;
      final top = mask[y0 * mw + x0] * (1 - ax) + mask[y0 * mw + x1] * ax;
      final bot = mask[y1 * mw + x0] * (1 - ax) + mask[y1 * mw + x1] * ax;
      var a = (top * (1 - ay) + bot * ay) / 255.0;
      // smoothstep(0.3, 0.7): solid person, short soft edge
      a = ((a - 0.3) / 0.4).clamp(0.0, 1.0);
      a = a * a * (3 - 2 * a);
      if (a >= 0.999) continue;
      final i = (y * w + x) * 4;
      if (ca == 0) {
        out[i + 3] = (rgba[i + 3] * a).round();
        if (a <= 0.001) {
          final light = ((x >> 4) + (y >> 4)).isEven;
          out[i] = out[i + 1] = out[i + 2] = light ? 0xF2 : 0xCC;
        }
      } else {
        out[i] = (rgba[i] * a + cr * (1 - a)).round();
        out[i + 1] = (rgba[i + 1] * a + cg * (1 - a)).round();
        out[i + 2] = (rgba[i + 2] * a + cb * (1 - a)).round();
        out[i + 3] = 255;
      }
    }
  }
  return out;
}

// =========================================================================
// Text + stickers
// =========================================================================
/// One text / sticker on the photo, resolution-free: centre ([cx], [cy]) and
/// font height ([size], share of the photo's SHORT edge) in 0..1.
class PsOverlay {
  const PsOverlay({
    required this.text,
    this.font = 'NotoSansBengali',
    this.color = 0xFFFFFFFF,
    this.bg = 0,
    this.size = 0.08,
    this.cx = 0.5,
    this.cy = 0.85,
    this.sticker = false,
  });
  final String text;
  final String font;
  final int color;

  /// Pill behind the text (ARGB, 0 = none — then a soft shadow keeps it
  /// readable on any photo).
  final int bg;
  final double size, cx, cy;
  final bool sticker;

  PsOverlay copyWith({String? text, String? font, int? color, int? bg, double? size,
          double? cx, double? cy}) =>
      PsOverlay(
          text: text ?? this.text,
          font: font ?? this.font,
          color: color ?? this.color,
          bg: bg ?? this.bg,
          size: size ?? this.size,
          cx: cx ?? this.cx,
          cy: cy ?? this.cy,
          sticker: sticker);
}

/// The Bangla fonts bundled for text (all SIL OFL 1.1, in assets/fonts).
const psFonts = <String>['NotoSansBengali', 'HindSiliguri', 'Galada', 'Atma'];

/// Ready stickers: emoji (system emoji font) and greeting badges. A badge's
/// words come from the app's language ([greeting] id -> the screen's
/// localised text: Bangla in Bangla, "Eid Mubarak" in English).
class PsSticker {
  const PsSticker(this.text, {this.greeting, this.bg = 0, this.color = 0xFFFFFFFF, this.font = 'Galada'});
  final String text;
  final String? greeting;
  final int bg, color;
  final String font;
  bool get emoji => greeting == null;

  static const all = <PsSticker>[
    PsSticker('', greeting: 'eid', bg: 0xFF0F7B4F, color: 0xFFFFF4C2),
    PsSticker('', greeting: 'birthday', bg: 0xFFD6336C),
    PsSticker('', greeting: 'new_year', bg: 0xFFC92A2A, color: 0xFFFFF8E1),
    PsSticker('', greeting: 'congrats', bg: 0xFF5F3DC4),
    PsSticker('', greeting: 'love', bg: 0xFFE8590C),
    PsSticker('', greeting: 'wedding', bg: 0xFFAE3EC9, color: 0xFFFFF0F6),
    PsSticker('', greeting: 'puja', bg: 0xFFF08C00, color: 0xFF3B0A00),
    PsSticker('', greeting: 'victory', bg: 0xFF006A4E),
    PsSticker('\u2764\uFE0F'),
    PsSticker('\u{1F319}'),
    PsSticker('\u2B50'),
    PsSticker('\u{1F389}'),
    PsSticker('\u{1F382}'),
    PsSticker('\u{1F338}'),
    PsSticker('\u{1F60A}'),
    PsSticker('\u{1F44D}'),
    PsSticker('\u{1F1E7}\u{1F1E9}'),
    PsSticker('\u{1F54C}'),
  ];
}

/// Text / stickers BEFORE they are drawn: the controller turns this into a
/// [PatchStep] at the exact size it is applied to (preview or export) —
/// Flutter's text engine shapes Bangla conjuncts correctly; this file
/// cannot. Applying it un-drawn is a bug and fails loudly (never a file
/// silently without the user's text).
class OverlayStep extends PsPixelStep {
  const OverlayStep(this.items);
  final List<PsOverlay> items;
  @override
  RgbaOut apply(Uint8List rgba, int w, int h) =>
      throw StateError('overlay not rasterised');
}

/// Drawn overlay patches (straight-alpha RGBA) for a [forW]×[forH] photo.
class PatchStep extends PsPixelStep {
  const PatchStep(this.patches, this.forW, this.forH);
  final List<MarkPatch> patches;
  final int forW, forH;
  @override
  RgbaOut apply(Uint8List rgba, int w, int h) {
    final out = Uint8List.fromList(rgba);
    for (final p in patches) {
      p.compositeRows(out, w, 0, h);
    }
    return RgbaOut(out, w, h);
  }
}

/// Size each step sees: [steps] applied to a [w]×[h] input — the size an
/// [OverlayStep] at index [i] must be drawn for.
({int w, int h}) psSizeBefore(int w, int h, List<PsStep> steps, int i) =>
    psStepsSize(w, h, steps.sublist(0, i));

// =========================================================================
// Bangladesh ID / passport / visa presets
// =========================================================================
class PsIdPreset {
  const PsIdPreset(this.id,
      {this.wMm,
      this.hMm,
      required this.pxW,
      required this.pxH,
      this.dpi = 300,
      this.fmt = 'png',
      this.maxKb = 0,
      this.verified = 'common_practice',
      this.source = ''});
  final String id;
  final double? wMm, hMm;
  final int pxW, pxH, dpi, maxKb;
  final String fmt, verified, source;
  double get aspect => pxW / pxH;
  bool get jpg => fmt == 'jpg';
  bool get printable => wMm != null && hMm != null;

  /// Built-in copy (mirrors backend core/logic/photo_studio.py BD_PHOTO_SIZES;
  /// the server's values win when the config carries them).
  static const builtIn = <PsIdPreset>[
    PsIdPreset('passport_bd', wMm: 45, hMm: 55, pxW: 531, pxH: 650,
        verified: 'official_mission',
        source: 'https://www.bhclondon.org.uk/mrp-documents-preparation-fee-for-application'),
    PsIdPreset('visa_bd', wMm: 35, hMm: 45, pxW: 413, pxH: 531,
        verified: 'official_portal', source: 'https://dip.portal.gov.bd'),
    PsIdPreset('visa_india', wMm: 51, hMm: 51, pxW: 602, pxH: 602, fmt: 'jpg', maxKb: 1000,
        verified: 'official_portal', source: 'https://indianvisaonline.gov.in/visa/'),
    PsIdPreset('job_bd', pxW: 300, pxH: 300, fmt: 'jpg', maxKb: 100,
        source: 'https://alljobs.teletalk.com.bd'),
    PsIdPreset('stamp_bd', wMm: 19, hMm: 25, pxW: 224, pxH: 295),
  ];

  /// [server] = the config's `bd_sizes` map (may be empty / partial).
  static List<PsIdPreset> resolve(Map<String, Map<String, dynamic>> server) {
    num? n(Object? v) => v is num ? v : null;
    return [
      for (final b in builtIn)
        if (server[b.id] case final s?)
          PsIdPreset(b.id,
              wMm: n(s['w_mm'])?.toDouble(),
              hMm: n(s['h_mm'])?.toDouble(),
              pxW: (n(s['px_w']) ?? b.pxW).toInt().clamp(64, 4000),
              pxH: (n(s['px_h']) ?? b.pxH).toInt().clamp(64, 4000),
              dpi: (n(s['dpi']) ?? b.dpi).toInt().clamp(72, 1200),
              fmt: s['fmt'] == 'jpg' ? 'jpg' : 'png',
              maxKb: (n(s['max_kb']) ?? b.maxKb).toInt().clamp(0, 10000),
              verified: '${s['verified'] ?? b.verified}',
              source: '${s['source'] ?? b.source}')
        else
          b,
    ];
  }
}

/// A 4x6 inch print sheet (300 DPI) filled with as many copies of a
/// [cellW]×[cellH] photo as fit (portrait or landscape — whichever holds
/// more), each with a thin grey cut line around it.
class SheetStep extends PsPixelStep {
  const SheetStep({this.dpi = 300, this.shortIn = 4, this.longIn = 6});
  final int dpi;
  final double shortIn, longIn;

  static const gap = 24, margin = 30;

  ({int w, int h, int cols, int rows}) layout(int cw, int ch) {
    final s = (shortIn * dpi).round(), l = (longIn * dpi).round();
    int fit(int paper, int cell) => math.max(0, (paper - 2 * margin + gap) ~/ (cell + gap));
    final pc = fit(s, cw), pr = fit(l, ch); // portrait paper
    final lc = fit(l, cw), lr = fit(s, ch); // landscape paper
    return lc * lr > pc * pr
        ? (w: l, h: s, cols: lc, rows: lr)
        : (w: s, h: l, cols: pc, rows: pr);
  }

  int copies(int cw, int ch) {
    final l = layout(cw, ch);
    return l.cols * l.rows;
  }

  @override
  ({int w, int h}) outSize(int w, int h) {
    final l = layout(w, h);
    return (w: l.w, h: l.h);
  }

  @override
  RgbaOut apply(Uint8List rgba, int w, int h) {
    final l = layout(w, h);
    final out = Uint8List(l.w * l.h * 4)..fillRange(0, l.w * l.h * 4, 255);
    if (l.cols == 0 || l.rows == 0) return RgbaOut(out, l.w, l.h);
    final usedW = l.cols * w + (l.cols - 1) * gap, usedH = l.rows * h + (l.rows - 1) * gap;
    final ox = (l.w - usedW) ~/ 2, oy = (l.h - usedH) ~/ 2;
    for (var r = 0; r < l.rows; r++) {
      for (var c = 0; c < l.cols; c++) {
        final x0 = ox + c * (w + gap), y0 = oy + r * (h + gap);
        // cut line: 1 px grey, 2 px outside the photo
        for (var x = x0 - 2; x < x0 + w + 2; x++) {
          _px(out, l.w, l.h, x, y0 - 2, 0xBB);
          _px(out, l.w, l.h, x, y0 + h + 1, 0xBB);
        }
        for (var y = y0 - 2; y < y0 + h + 2; y++) {
          _px(out, l.w, l.h, x0 - 2, y, 0xBB);
          _px(out, l.w, l.h, x0 + w + 1, y, 0xBB);
        }
        for (var y = 0; y < h; y++) {
          final d = ((y0 + y) * l.w + x0) * 4;
          out.setRange(d, d + w * 4, rgba, y * w * 4);
          // a transparent photo prints on white
          for (var k = d + 3; k < d + w * 4; k += 4) {
            final a = out[k];
            if (a == 255) continue;
            out[k - 3] = (out[k - 3] * a + 255 * (255 - a)) ~/ 255;
            out[k - 2] = (out[k - 2] * a + 255 * (255 - a)) ~/ 255;
            out[k - 1] = (out[k - 1] * a + 255 * (255 - a)) ~/ 255;
            out[k] = 255;
          }
        }
      }
    }
    return RgbaOut(out, l.w, l.h);
  }

  static void _px(Uint8List o, int w, int h, int x, int y, int v) {
    if (x < 0 || y < 0 || x >= w || y >= h) return;
    final i = (y * w + x) * 4;
    o[i] = o[i + 1] = o[i + 2] = v;
    o[i + 3] = 255;
  }
}

// =========================================================================
// File tags: 300 DPI in the PNG, the portal JPEG under its KB limit
// =========================================================================
/// [png] with a pHYs chunk saying [dpi] (print shops then print the 531 px
/// passport photo at exactly 45 mm). An existing pHYs is replaced.
Uint8List psPngWithDpi(Uint8List png, int dpi) {
  if (png.length < 33 || png[0] != 0x89 || png[1] != 0x50) return png;
  final ppm = (dpi / 0.0254).round();
  final data = Uint8List(9);
  ByteData.sublistView(data)
    ..setUint32(0, ppm)
    ..setUint32(4, ppm);
  data[8] = 1; // metre
  final chunk = pngChunk('pHYs', data);
  final b = BytesBuilder(copy: false)..add(Uint8List.sublistView(png, 0, 33));
  b.add(chunk);
  var p = 33;
  while (p + 12 <= png.length) {
    final len = ByteData.sublistView(png, p, p + 4).getUint32(0);
    final end = p + 12 + len;
    if (end > png.length) break;
    final isPhys = png[p + 4] == 0x70 && png[p + 5] == 0x48 && png[p + 6] == 0x59 && png[p + 7] == 0x73;
    if (!isPhys) b.add(Uint8List.sublistView(png, p, end));
    p = end;
  }
  return b.toBytes();
}

/// DPI written in a PNG's pHYs chunk (null = none) — tests / file info.
int? psPngDpi(Uint8List png) {
  var p = 8;
  while (p + 12 <= png.length) {
    final d = ByteData.sublistView(png);
    final len = d.getUint32(p);
    if (png[p + 4] == 0x70 && png[p + 5] == 0x48 && png[p + 6] == 0x59 && png[p + 7] == 0x73) {
      return (d.getUint32(p + 8) * 0.0254).round();
    }
    p += 12 + len;
  }
  return null;
}

/// Encode RGBA as a JPEG no bigger than [maxKb] KB (quality stepped down
/// from 92 to 40; transparent parts on white). null = cannot fit even at
/// quality 40 — the caller says so honestly instead of handing over a file
/// the portal will reject.
({Uint8List bytes, int quality})? psJpegUnder(Uint8List rgba, int w, int h, int maxKb) {
  final flat = Uint8List.fromList(rgba);
  for (var i = 3; i < flat.length; i += 4) {
    final a = flat[i];
    if (a == 255) continue;
    for (var c = 1; c <= 3; c++) {
      flat[i - c] = (flat[i - c] * a + 255 * (255 - a)) ~/ 255;
    }
    flat[i] = 255;
  }
  final im = img.Image.fromBytes(width: w, height: h, bytes: flat.buffer, numChannels: 4);
  final limit = maxKb <= 0 ? 1 << 30 : maxKb * 1000;
  for (var q = 92; q >= 40; q -= 8) {
    final b = img.encodeJpg(im, quality: q);
    if (b.length <= limit) return (bytes: b, quality: q);
  }
  return null;
}

/// A 32-bit BMP (the studio's fast preview format) -> RGBA WITH its alpha
/// (Flutter's decoder ignores BMP alpha, which would turn a removed
/// background into the checkerboard). null = not such a BMP.
RgbaOut? psDecodeBmp32(Uint8List b) {
  if (b.length < 54 || b[0] != 0x42 || b[1] != 0x4D) return null;
  final d = ByteData.sublistView(b);
  final off = d.getUint32(10, Endian.little);
  final w = d.getInt32(18, Endian.little), hRaw = d.getInt32(22, Endian.little);
  if (d.getUint16(28, Endian.little) != 32 || d.getUint32(30, Endian.little) != 0) return null;
  final h = hRaw.abs();
  if (w <= 0 || h <= 0 || off + w * h * 4 > b.length) return null;
  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    final row = hRaw < 0 ? y : h - 1 - y;
    var s = off + row * w * 4, o = y * w * 4;
    for (var x = 0; x < w; x++, s += 4, o += 4) {
      out[o] = b[s + 2];
      out[o + 1] = b[s + 1];
      out[o + 2] = b[s];
      out[o + 3] = b[s + 3];
    }
  }
  return RgbaOut(out, w, h);
}

/// RGBA -> PNG (alpha kept when there is any).
Uint8List psEncodePng(Uint8List rgba, int w, int h) {
  final e = PngStreamEncoder(w, h, alpha: PngStreamEncoder.hasAlpha(rgba));
  e.addRows(rgba, h);
  return e.close();
}

/// RGBA of a PNG (the exported ID photo) — pure Dart, small images only.
({Uint8List rgba, int w, int h})? psDecodePng(Uint8List png) {
  final d = img.decodePng(png);
  if (d == null) return null;
  final rgba = d.convert(numChannels: 4, format: img.Format.uint8).getBytes(order: img.ChannelOrder.rgba);
  return (rgba: Uint8List.fromList(rgba), w: d.width, h: d.height);
}
