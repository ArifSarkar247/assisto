/// Photo Studio — the INSTANT classical enhance pipeline (p2-photo).
///
/// Pure Dart (no Flutter import) so it runs in a background isolate on every
/// phone, in unit tests and in the desktop evaluation harness
/// (`app/tool/ps_eval.dart`, numbers in `.phaseB/photo_studio_eval/`).
///
/// Steps (all per-pixel or small local filters — none of them can move a
/// facial feature, so the result is geometry-preserving by construction):
///   1. white balance  — grey-world gains from mid-tone, low-saturation pixels,
///                        clamped to ±25 % and blended by strength;
///   2. levels          — 0.5 % / 99.5 % luminance stretch (never more than
///                        2.2x) + a gentle gamma lift for dark photos;
///   3. denoise         — edge-preserving guided filter on luminance + box
///                        blur on chroma (chroma noise is what phones show);
///   4. CLAHE           — 8x8-tile contrast-limited histogram equalisation on
///                        luminance, bilinear between tiles, blended;
///   5. skin smoothing  — guided filter on luminance, ONLY where a skin-colour
///                        mask (YCbCr) meets a detected face ellipse; without
///                        face boxes it is skipped (conservative);
///   6. sharpen         — unsharp mask on luminance with a noise threshold,
///                        reduced on skin;
///   7. vibrance        — small saturation lift for dull colours only.
///
/// Memory: global statistics come from a ≤1024 px analysis copy; the local
/// filters run in horizontal strips (256 rows + overlap), so a 12 MP photo
/// needs ~15 MB of working memory instead of ~400 MB.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'ps_models.dart';

/// Strength -> parameters. Light is barely visible, Strong is clearly
/// "edited" but still natural (no plastic skin: skin blend ≤ 0.45).
class ClassicParams {
  const ClassicParams({
    required this.wb,
    required this.levels,
    required this.lift,
    required this.denoise,
    required this.clahe,
    required this.claheClip,
    required this.skin,
    required this.sharpen,
    required this.vibrance,
    this.gammaFloor = 0.55,
  });
  final double wb, levels, lift, denoise, clahe, claheClip, skin, sharpen, vibrance;

  /// d1-photo: strongest allowed gamma for the dark-photo lift (smaller =
  /// brighter). 0.55 for the enhance strengths; the Low-light tool uses 0.40.
  final double gammaFloor;

  static const light = ClassicParams(
      wb: 0.35, levels: 0.45, lift: 0.35, denoise: 0.30, clahe: 0.15,
      claheClip: 2.0, skin: 0.18, sharpen: 0.25, vibrance: 0.05);
  static const natural = ClassicParams(
      wb: 0.60, levels: 0.75, lift: 0.60, denoise: 0.50, clahe: 0.30,
      claheClip: 2.4, skin: 0.30, sharpen: 0.40, vibrance: 0.10);
  static const strong = ClassicParams(
      wb: 0.85, levels: 1.00, lift: 0.85, denoise: 0.70, clahe: 0.45,
      claheClip: 2.8, skin: 0.42, sharpen: 0.60, vibrance: 0.16);

  static ClassicParams of(EditStrength s) => switch (s) {
        EditStrength.light => light,
        EditStrength.natural => natural,
        EditStrength.strong => strong,
      };

  Map<String, double> toMap() => {
        'wb': wb, 'levels': levels, 'lift': lift, 'denoise': denoise,
        'clahe': clahe, 'claheClip': claheClip, 'skin': skin,
        'sharpen': sharpen, 'vibrance': vibrance,
      };

  /// d1-photo tools (on-device, instant, geometry-preserving like the rest).
  /// Denoise: only the edge-preserving luminance/chroma denoise (+ a touch of
  /// sharpening so edges don't go soft) — tone and colour untouched.
  static const denoiseTool = ClassicParams(
      wb: 0, levels: 0, lift: 0, denoise: 1.0, clahe: 0,
      claheClip: 2.0, skin: 0, sharpen: 0.12, vibrance: 0);

  /// Low-light fix: full levels stretch, strong gamma lift (floor 0.40),
  /// full denoise and almost no sharpening (lifting a dark photo lifts its
  /// sensor noise — d1 eval: sharpen 0.25 doubled the grain), local contrast.
  static const lowLightTool = ClassicParams(
      wb: 0.6, levels: 1.0, lift: 1.0, denoise: 1.0, clahe: 0.35,
      claheClip: 2.4, skin: 0.2, sharpen: 0.08, vibrance: 0.10, gammaFloor: 0.40);
}

/// A face ellipse in normalised 0..1 image coordinates (same as FaceBox, but
/// kept here so this file has no Flutter-side dependency).
class ClassicFace {
  const ClassicFace(this.x, this.y, this.w, this.h);
  final double x, y, w, h;
}

/// Global statistics measured once on the analysis copy.
class ClassicPlan {
  ClassicPlan({
    required this.gainR,
    required this.gainG,
    required this.gainB,
    required this.lo,
    required this.hi,
    required this.gamma,
    required this.gx,
    required this.gy,
    required this.luts,
  });
  final double gainR, gainG, gainB, lo, hi, gamma;
  final int gx, gy;

  /// gx*gy tables of 256 output levels (0..1), CLAHE per tile.
  final Float32List luts;
}

const double _kr = 0.299, _kg = 0.587, _kb = 0.114;

double _clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

/// Area-average downscale of RGBA to at most [maxLong] px on the long edge.
({Uint8List rgba, int w, int h}) downscaleRgba(
    Uint8List rgba, int w, int h, int maxLong) {
  final long = math.max(w, h);
  if (long <= maxLong) return (rgba: rgba, w: w, h: h);
  final f = long / maxLong;
  final nw = math.max(1, (w / f).round()), nh = math.max(1, (h / f).round());
  final out = Uint8List(nw * nh * 4);
  for (var y = 0; y < nh; y++) {
    final sy0 = (y * h / nh).floor(), sy1 = math.max(sy0 + 1, ((y + 1) * h / nh).floor());
    for (var x = 0; x < nw; x++) {
      final sx0 = (x * w / nw).floor(), sx1 = math.max(sx0 + 1, ((x + 1) * w / nw).floor());
      var r = 0, g = 0, b = 0, a = 0, n = 0;
      for (var yy = sy0; yy < sy1; yy++) {
        var i = (yy * w + sx0) * 4;
        for (var xx = sx0; xx < sx1; xx++) {
          r += rgba[i];
          g += rgba[i + 1];
          b += rgba[i + 2];
          a += rgba[i + 3];
          n++;
          i += 4;
        }
      }
      final o = (y * nw + x) * 4;
      out[o] = r ~/ n;
      out[o + 1] = g ~/ n;
      out[o + 2] = b ~/ n;
      out[o + 3] = a ~/ n;
    }
  }
  return (rgba: out, w: nw, h: nh);
}

/// Measure WB gains, levels, gamma and the CLAHE tables on [rgba] (should be
/// the ≤1024 px analysis copy).
ClassicPlan analyse(Uint8List rgba, int w, int h, ClassicParams p) {
  final n = w * h;
  // ---- 1. grey-world on mid-tone, not-too-saturated pixels
  var sr = 0.0, sg = 0.0, sb = 0.0;
  var cnt = 0;
  for (var i = 0; i < n; i++) {
    final r = rgba[i * 4], g = rgba[i * 4 + 1], b = rgba[i * 4 + 2];
    final mx = math.max(r, math.max(g, b)), mn = math.min(r, math.min(g, b));
    if (mx < 30 || mx > 245) continue;
    if (mx - mn > 0.55 * mx) continue; // strongly coloured: not "grey" evidence
    sr += r;
    sg += g;
    sb += b;
    cnt++;
  }
  double gr = 1, gg = 1, gb = 1;
  if (cnt > n * 0.02 && sr > 0 && sg > 0 && sb > 0) {
    final grey = (sr + sg + sb) / 3;
    gr = (grey / sr).clamp(0.8, 1.25);
    gg = (grey / sg).clamp(0.8, 1.25);
    gb = (grey / sb).clamp(0.8, 1.25);
    // keep overall brightness: normalise so the luma weight of gains is 1
    final norm = _kr * gr + _kg * gg + _kb * gb;
    gr /= norm;
    gg /= norm;
    gb /= norm;
  }
  gr = 1 + (gr - 1) * p.wb;
  gg = 1 + (gg - 1) * p.wb;
  gb = 1 + (gb - 1) * p.wb;

  // ---- 2. levels on the white-balanced luminance
  final hist = Int32List(256);
  final y8 = Uint8List(n);
  for (var i = 0; i < n; i++) {
    final yv = _kr * rgba[i * 4] * gr + _kg * rgba[i * 4 + 1] * gg + _kb * rgba[i * 4 + 2] * gb;
    final q = yv < 0 ? 0 : (yv > 255 ? 255 : yv.round());
    y8[i] = q;
    hist[q]++;
  }
  int pct(double f) {
    final target = (n * f).floor();
    var acc = 0;
    for (var i = 0; i < 256; i++) {
      acc += hist[i];
      if (acc > target) return i;
    }
    return 255;
  }

  var lo = pct(0.005) / 255.0, hi = pct(0.995) / 255.0;
  // never stretch more than 2.2x (very flat photos would turn to noise)
  if (hi - lo < 1 / 2.2) {
    final mid = (lo + hi) / 2;
    lo = math.max(0, mid - 0.5 / 2.2);
    hi = math.min(1, lo + 1 / 2.2);
  }
  lo = lo * p.levels;
  hi = 1 - (1 - hi) * p.levels;
  // gentle gamma lift when the photo is dark (median < 0.42)
  final med = pct(0.5) / 255.0;
  final mStretched = _clamp01((med - lo) / math.max(1e-3, hi - lo));
  var gamma = 1.0;
  if (mStretched > 0.02 && mStretched < 0.42) {
    final g = math.log(0.42) / math.log(mStretched); // < 1 brightens
    gamma = 1 + (g.clamp(p.gammaFloor, 1.0) - 1) * p.lift;
  }

  // ---- 4. CLAHE tables on the toned luminance
  const gxN = 8, gyN = 8;
  final gx = math.min(gxN, math.max(1, w ~/ 16)), gy = math.min(gyN, math.max(1, h ~/ 16));
  final luts = Float32List(gx * gy * 256);
  final tone = Float32List(256);
  for (var v = 0; v < 256; v++) {
    tone[v] = _toneY(v / 255.0, lo, hi, gamma);
  }
  final th = Int32List(256);
  for (var ty = 0; ty < gy; ty++) {
    final y0 = ty * h ~/ gy, y1 = (ty + 1) * h ~/ gy;
    for (var tx = 0; tx < gx; tx++) {
      final x0 = tx * w ~/ gx, x1 = (tx + 1) * w ~/ gx;
      th.fillRange(0, 256, 0);
      var tn = 0;
      for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1; x++) {
          final t = (tone[y8[y * w + x]] * 255).round();
          th[t < 0 ? 0 : (t > 255 ? 255 : t)]++;
          tn++;
        }
      }
      final base = (ty * gx + tx) * 256;
      if (tn == 0) {
        for (var v = 0; v < 256; v++) {
          luts[base + v] = v / 255.0;
        }
        continue;
      }
      final limit = math.max(1, (p.claheClip * tn / 256).floor());
      var excess = 0;
      for (var v = 0; v < 256; v++) {
        if (th[v] > limit) {
          excess += th[v] - limit;
          th[v] = limit;
        }
      }
      final add = excess ~/ 256;
      var rem = excess - add * 256;
      var acc = 0;
      for (var v = 0; v < 256; v++) {
        var c = th[v] + add;
        if (rem > 0) {
          c++;
          rem--;
        }
        acc += c;
        luts[base + v] = acc / tn;
      }
    }
  }
  return ClassicPlan(
      gainR: gr, gainG: gg, gainB: gb, lo: lo, hi: hi, gamma: gamma,
      gx: gx, gy: gy, luts: luts);
}

double _toneY(double y, double lo, double hi, double gamma) {
  var v = (y - lo) / math.max(1e-3, hi - lo);
  v = _clamp01(v);
  if (gamma != 1.0 && v > 0) v = math.pow(v, gamma).toDouble();
  return v;
}

/// Separable box filter (radius r, clamped edges) of a w×h plane, in place
/// via [tmp] (same length).
void boxBlur(Float32List src, Float32List dst, Float32List tmp, int w, int h, int r) {
  if (r <= 0) {
    dst.setAll(0, src);
    return;
  }
  final win = 2 * r + 1;
  // horizontal: src -> tmp
  for (var y = 0; y < h; y++) {
    final row = y * w;
    var acc = 0.0;
    for (var k = -r; k <= r; k++) {
      acc += src[row + (k < 0 ? 0 : (k >= w ? w - 1 : k))];
    }
    for (var x = 0; x < w; x++) {
      tmp[row + x] = acc / win;
      final xo = x - r, xi = x + r + 1;
      acc += src[row + (xi >= w ? w - 1 : xi)] - src[row + (xo < 0 ? 0 : xo)];
    }
  }
  // vertical: tmp -> dst. photoperf: row-major with one running sum per
  // column (was column-by-column, a cache miss on every read of a 4000 px
  // wide strip). Each column sees the SAME additions in the same order, so
  // the result is bit-identical to the old loop.
  final acc = Float64List(w);
  for (var k = -r; k <= r; k++) {
    final row = (k < 0 ? 0 : (k >= h ? h - 1 : k)) * w;
    for (var x = 0; x < w; x++) {
      acc[x] += tmp[row + x];
    }
  }
  for (var y = 0; y < h; y++) {
    final o = y * w;
    final yo = y - r, yi = y + r + 1;
    final ri = (yi >= h ? h - 1 : yi) * w, ro = (yo < 0 ? 0 : yo) * w;
    for (var x = 0; x < w; x++) {
      dst[o + x] = acc[x] / win;
      acc[x] += tmp[ri + x] - tmp[ro + x];
    }
  }
}

/// Self-guided filter (He et al. 2010): edge-preserving smoothing of [p].
void guidedFilter(Float32List p, Float32List out, int w, int h, int r, double eps,
    _Scratch s) {
  final n = w * h;
  boxBlur(p, s.a, s.t, w, h, r); // mean
  for (var i = 0; i < n; i++) {
    s.b[i] = p[i] * p[i];
  }
  boxBlur(s.b, s.c, s.t, w, h, r); // mean of squares
  for (var i = 0; i < n; i++) {
    final m = s.a[i];
    final v = s.c[i] - m * m;
    final a = v / (v + eps);
    s.b[i] = a;
    s.c[i] = m - a * m;
  }
  boxBlur(s.b, s.d, s.t, w, h, r);
  boxBlur(s.c, s.b, s.t, w, h, r);
  for (var i = 0; i < n; i++) {
    out[i] = s.d[i] * p[i] + s.b[i];
  }
}

class _Scratch {
  _Scratch(int n)
      : a = Float32List(n),
        b = Float32List(n),
        c = Float32List(n),
        d = Float32List(n),
        t = Float32List(n);
  _Scratch.view(_Scratch s, int n)
      : a = Float32List.sublistView(s.a, 0, n),
        b = Float32List.sublistView(s.b, 0, n),
        c = Float32List.sublistView(s.c, 0, n),
        d = Float32List.sublistView(s.d, 0, n),
        t = Float32List.sublistView(s.t, 0, n);
  final Float32List a, b, c, d, t;
}

/// Run the whole pipeline on a full-size RGBA buffer. Pure function: [rgba]
/// is not modified.
Uint8List enhanceClassic(Uint8List rgba, int w, int h, ClassicParams p,
    {List<ClassicFace> faces = const [], int stripRows = 256}) {
  assert(rgba.length == w * h * 4);
  final small = downscaleRgba(rgba, w, h, 1024);
  final plan = analyse(small.rgba, small.w, small.h, p);
  return applyPlan(rgba, w, h, p, plan, faces: faces, stripRows: stripRows);
}

/// photoperf options (all keep the pixels bit-identical to the plain call):
///  * [out] (rgba.length bytes) receives the result instead of a new buffer;
///  * [onRows] STREAMS the result: every finished strip (rows y0..y1, RGBA,
///    only valid during the call) goes to the caller and no full-size output
///    buffer is allocated — the export encodes rows as they come;
///  * [rowFrom]/[rowTo] (multiples of [stripRows]) limit the work to a band
///    (parallel workers split a photo by strips, same strips as one worker);
///  * [onStrip] reports (rows done, rows total) after each strip.
/// Context rows a strip needs above/below (the filters' supports added up) —
/// a band worker must get rows [from - pad, to + pad) of the photo.
int classicPad(int w, int h, List<ClassicFace> faces) {
  final sc = math.max(w, h) / 1000.0;
  final rDen = math.max(1, (2 * sc).round());
  final rChroma = math.max(1, (2 * sc).round());
  final rSharp = math.max(1, (1.2 * sc).round());
  var faceW = 0.0;
  for (final f in faces) {
    faceW = math.max(faceW, f.w * w);
  }
  final rSkin = math.max(2, (faceW / 40).round());
  return 2 * (rDen + rChroma + rSharp + rSkin) + 8;
}

Uint8List applyPlan(Uint8List rgba, int w, int h, ClassicParams p, ClassicPlan plan,
    {List<ClassicFace> faces = const [],
    int stripRows = 256,
    Uint8List? out,
    void Function(int y0, int y1, Uint8List rows)? onRows,
    int rowFrom = 0,
    int? rowTo,
    int srcRow0 = 0,
    void Function(int done, int total)? onStrip}) {
  // [srcRow0]: [rgba] holds only rows srcRow0.. of the h-row photo (a band
  // with its context rows, see [classicPad]) — streamed output only.
  assert(srcRow0 == 0 || onRows != null);
  assert(out == null || out.length == rgba.length);
  assert(rowFrom % stripRows == 0);
  final rowEnd = math.min(h, rowTo ?? h);
  final Uint8List dst = onRows != null
      ? Uint8List(math.min(h, stripRows) * w * 4)
      : (out ?? Uint8List(rgba.length));
  final long = math.max(w, h);
  // filter radii scale with the photo (tuned at ~1000 px long edge)
  final sc = long / 1000.0;
  final rDen = math.max(1, (2 * sc).round());
  final rChroma = math.max(1, (2 * sc).round());
  final rSharp = math.max(1, (1.2 * sc).round());
  // skin radius follows the face size (≈ 1/40 of the face width)
  var faceW = 0.0;
  for (final f in faces) {
    faceW = math.max(faceW, f.w * w);
  }
  final rSkin = math.max(2, (faceW / 40).round());
  // context rows around each strip: the filters run one after another, so
  // their supports add up (denoise 2r, skin 2r+2, sharpen 2r ...)
  final pad = classicPad(w, h, faces);
  assert(pad == 2 * (rDen + rChroma + rSharp + rSkin) + 8);
  final doSkin = p.skin > 0 && faces.isNotEmpty;

  // tone LUT (WB is applied before it, per channel)
  final tone = Float32List(1024);
  for (var v = 0; v < 1024; v++) {
    tone[v] = _toneY(v / 1023.0, plan.lo, plan.hi, plan.gamma);
  }

  // CLAHE column terms (same expressions as the per-pixel code had)
  final cTx0 = Int32List(w), cTx1 = Int32List(w);
  final cWx = Float64List(w);
  for (var x = 0; x < w; x++) {
    final fx = (x + 0.5) / w * plan.gx - 0.5;
    cTx0[x] = fx.floor().clamp(0, plan.gx - 1);
    cTx1[x] = (fx.floor() + 1).clamp(0, plan.gx - 1);
    cWx[x] = _clamp01(fx - fx.floor());
  }

  final maxRows = math.min(h, stripRows) + 2 * pad;
  final cap = w * maxRows;
  // photoperf: the box-blur temp is the scratch's own `t` (it was a separate
  // plane; every pass overwrites it first) and the skin plane only exists
  // when there is a face — 2 of 11 strip planes less (12 MP: ~12 MB).
  final yP = Float32List(cap), cbP = Float32List(cap), crP = Float32List(cap);
  final tmp1 = Float32List(cap);
  final skinW = doSkin ? Float32List(cap) : Float32List(0);
  final s = _Scratch(cap);

  for (var y0 = rowFrom; y0 < rowEnd; y0 += stripRows) {
    final y1 = math.min(rowEnd, y0 + stripRows);
    final a0 = math.max(0, y0 - pad), a1 = math.min(h, y1 + pad);
    final sh = a1 - a0;
    final sn = w * sh;
    final yv = Float32List.sublistView(yP, 0, sn);
    final cb = Float32List.sublistView(cbP, 0, sn);
    final cr = Float32List.sublistView(crP, 0, sn);
    final t1 = Float32List.sublistView(tmp1, 0, sn);
    final sc2 = _Scratch.view(s, sn);
    final t2 = sc2.t;
    final sk = doSkin ? Float32List.sublistView(skinW, 0, sn) : skinW;

    // ---- 1+2: WB, levels/gamma -> Y Cb Cr (0..1, chroma centred on 0)
    for (var yy = 0; yy < sh; yy++) {
      var si = ((a0 + yy - srcRow0) * w) * 4;
      var di = yy * w;
      for (var x = 0; x < w; x++) {
        final r = _clamp01(rgba[si] / 255.0 * plan.gainR);
        final g = _clamp01(rgba[si + 1] / 255.0 * plan.gainG);
        final b = _clamp01(rgba[si + 2] / 255.0 * plan.gainB);
        final y = _kr * r + _kg * g + _kb * b;
        final ty = tone[(y * 1023).round()];
        // levels scale chroma with luminance so colours keep their look
        final k = y > 1e-3 ? math.min(2.5, ty / y) : 1.0;
        yv[di] = ty;
        cb[di] = (b - y) * 0.564 * k;
        cr[di] = (r - y) * 0.713 * k;
        si += 4;
        di++;
      }
    }

    // ---- 3: denoise
    if (p.denoise > 0) {
      guidedFilter(yv, t1, w, sh, rDen, 0.0016 + 0.0024 * p.denoise, sc2);
      for (var i = 0; i < sn; i++) {
        yv[i] += (t1[i] - yv[i]) * p.denoise * 0.85;
      }
      boxBlur(cb, t1, t2, w, sh, rChroma);
      boxBlur(cr, sc2.a, t2, w, sh, rChroma);
      final cAmt = math.min(1.0, p.denoise * 1.2);
      for (var i = 0; i < sn; i++) {
        cb[i] += (t1[i] - cb[i]) * cAmt;
        cr[i] += (sc2.a[i] - cr[i]) * cAmt;
      }
    }

    // ---- 4: CLAHE (bilinear between tile tables, full-image coordinates)
    if (p.clahe > 0) {
      final gx = plan.gx, gy = plan.gy;
      for (var yy = 0; yy < sh; yy++) {
        final fy = ((a0 + yy) + 0.5) / h * gy - 0.5;
        final ty0 = fy.floor().clamp(0, gy - 1), ty1 = (fy.floor() + 1).clamp(0, gy - 1);
        final wy = _clamp01(fy - fy.floor());
        for (var x = 0; x < w; x++) {
          final i = yy * w + x;
          // photoperf: the per-column tile terms are computed once per photo
          final tx0 = cTx0[x], tx1 = cTx1[x];
          final wx = cWx[x];
          final v = (yv[i] * 255).round().clamp(0, 255);
          final l00 = plan.luts[(ty0 * gx + tx0) * 256 + v];
          final l01 = plan.luts[(ty0 * gx + tx1) * 256 + v];
          final l10 = plan.luts[(ty1 * gx + tx0) * 256 + v];
          final l11 = plan.luts[(ty1 * gx + tx1) * 256 + v];
          final m = (l00 * (1 - wx) + l01 * wx) * (1 - wy) + (l10 * (1 - wx) + l11 * wx) * wy;
          yv[i] += (m - yv[i]) * p.clahe;
        }
      }
    }

    // ---- 5: skin mask (skin colour ∩ face ellipses), softened
    if (doSkin) {
      sk.fillRange(0, sn, 0);
      for (final f in faces) {
        final cx = (f.x + f.w / 2) * w, cy = (f.y + f.h / 2) * h;
        final rx = f.w * w * 0.62, ry = f.h * h * 0.72;
        if (rx < 2 || ry < 2) continue;
        final yA = math.max(a0, (cy - ry).floor()), yB = math.min(a1 - 1, (cy + ry).ceil());
        final xA = math.max(0, (cx - rx).floor()), xB = math.min(w - 1, (cx + rx).ceil());
        for (var yy = yA; yy <= yB; yy++) {
          for (var x = xA; x <= xB; x++) {
            final dx = (x + 0.5 - cx) / rx, dy = (yy + 0.5 - cy) / ry;
            final d = dx * dx + dy * dy;
            if (d >= 1) continue;
            final i = (yy - a0) * w + x;
            // YCbCr skin range (Chai & Ngan), on 0..255 offsets
            final cbv = cb[i] * 255 + 128, crv = cr[i] * 255 + 128;
            final inSkin = cbv >= 77 && cbv <= 127 && crv >= 133 && crv <= 173 &&
                yv[i] > 0.12 && yv[i] < 0.96;
            if (!inSkin) continue;
            final edge = d < 0.7 ? 1.0 : (1 - (d - 0.7) / 0.3);
            if (edge > sk[i]) sk[i] = edge;
          }
        }
      }
      boxBlur(sk, t1, t2, w, sh, 2);
      sk.setAll(0, t1);
      guidedFilter(yv, t1, w, sh, rSkin, 0.0025, sc2);
      for (var i = 0; i < sn; i++) {
        final a = sk[i] * p.skin;
        if (a > 0) yv[i] += (t1[i] - yv[i]) * a;
      }
    }

    // ---- 6: sharpen (unsharp mask with a noise threshold, less on skin)
    if (p.sharpen > 0) {
      boxBlur(yv, t1, t2, w, sh, rSharp);
      boxBlur(t1, sc2.a, t2, w, sh, rSharp);
      const thr = 0.008;
      for (var i = 0; i < sn; i++) {
        var d = yv[i] - sc2.a[i];
        if (d > thr) {
          d -= thr;
        } else if (d < -thr) {
          d += thr;
        } else {
          d = 0;
        }
        // no face: the skin weight is 0 -> factor exactly 1.0 (as before)
        yv[i] += d * p.sharpen * 1.4 * (doSkin ? (1 - 0.8 * sk[i]) : 1.0);
      }
    }

    // ---- 7: back to RGB with vibrance; write only the strip's own rows
    // streamed: strip-relative rows (ai is band-relative, so offset by the band)
    final ob = onRows != null ? (y0 - srcRow0) * w * 4 : 0;
    for (var yy = y0; yy < y1; yy++) {
      var si = (yy - a0) * w;
      var ai = (yy - srcRow0) * w * 4;
      var oi = ai - ob;
      for (var x = 0; x < w; x++) {
        final y = yv[si];
        var u = cb[si], v = cr[si];
        if (p.vibrance > 0) {
          final sat = math.sqrt(u * u + v * v) * 2.2; // ~0..1
          final k = 1 + p.vibrance * (1 - _clamp01(sat)) * (doSkin ? (1 - sk[si] * 0.7) : 1.0);
          u *= k;
          v *= k;
        }
        final r = y + 1.402 * v;
        final g = y - 0.344136 * u - 0.714136 * v;
        final b = y + 1.772 * u;
        dst[oi] = (_clamp01(r) * 255).round();
        dst[oi + 1] = (_clamp01(g) * 255).round();
        dst[oi + 2] = (_clamp01(b) * 255).round();
        dst[oi + 3] = rgba[ai + 3];
        si++;
        oi += 4;
        ai += 4;
      }
    }
    if (onRows != null) {
      onRows(y0, y1, Uint8List.sublistView(dst, 0, (y1 - y0) * w * 4));
    }
    onStrip?.call(y1, h);
  }
  return onRows != null ? Uint8List(0) : dst;
}

// ---------------------------------------------------------------- metrics
/// PSNR (dB) of two RGBA buffers on RGB.
double psnr(Uint8List a, Uint8List b) {
  var se = 0.0;
  var n = 0;
  for (var i = 0; i < a.length; i += 4) {
    for (var c = 0; c < 3; c++) {
      final d = a[i + c] - b[i + c];
      se += d * d;
      n++;
    }
  }
  if (se == 0) return 99;
  return 10 * math.log(255 * 255 / (se / n)) / math.ln10;
}

/// Sharpness = variance of the 4-neighbour Laplacian of luminance.
double laplacianVariance(Uint8List rgba, int w, int h) {
  final y = Float32List(w * h);
  for (var i = 0; i < w * h; i++) {
    y[i] = _kr * rgba[i * 4] + _kg * rgba[i * 4 + 1] + _kb * rgba[i * 4 + 2];
  }
  var s = 0.0, s2 = 0.0;
  var n = 0;
  for (var yy = 1; yy < h - 1; yy++) {
    for (var x = 1; x < w - 1; x++) {
      final i = yy * w + x;
      final l = y[i - 1] + y[i + 1] + y[i - w] + y[i + w] - 4 * y[i];
      s += l;
      s2 += l * l;
      n++;
    }
  }
  if (n == 0) return 0;
  final m = s / n;
  return s2 / n - m * m;
}
