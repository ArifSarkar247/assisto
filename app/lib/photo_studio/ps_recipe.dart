/// Photo Studio — PROXY editing + deterministic RECIPE (photoperf).
///
/// 2 GB CI run 40603594625: one edit of a 12 MP photo took 14–17.6 s and
/// picking it ~3 s, peak PSS 411 MB — every step ran on the full camera
/// image. Now:
///
///  * every interactive step (face detection, planning, tool previews,
///    enhance, sliders) runs on a PROXY: the photo shrunk so its long edge is
///    ≤ [psProxyLong] (1600 px on ≤ 3 GB phones, 2400 px otherwise; free
///    users never above the server's `preview_max_px`);
///  * each edit is recorded as a [PsStep] that carries everything that is
///    measured on the photo (the classical pipeline's global statistics, the
///    face boxes in 0..1 coordinates, the background mask) — so applying the
///    same steps to the full-resolution original on export/save reproduces
///    the preview exactly, only sharper ([applySteps] is the ONE code path
///    for both; local filter radii already scale with the photo size);
///  * the export runs in a background isolate ([PsWorker]) with real
///    progress and an honest cancel (the isolate is killed; nothing is
///    saved), streams the result rows straight into the PNG encoder (no
///    second full-size buffer) and returns the finished PNG.
///
/// Pure Dart (no Flutter import): runs in isolates and in unit tests.
library;

import 'dart:async';
import 'dart:convert' show ByteConversionSink;
import 'dart:io' show RawZLibFilter, ZLibEncoder;
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'ps_classic.dart';
import 'ps_tools.dart' show blurBackgroundRgba;

// =========================================================================
// Proxy size rules
// =========================================================================
/// Long edge of the editing proxy for this phone. [ramMb] = total RAM as
/// Android reports it (a "2 GB" phone ~1900, a "3 GB" one ~2800); 0 =
/// unknown (desktop/tests) -> the bigger proxy.
int psProxyLong({required int ramMb, required bool lowRam}) =>
    (lowRam || (ramMb > 0 && ramMb <= 3328)) ? 1600 : 2400;

/// The long edge every interactive step works at: the proxy, and for free
/// users never more than the server's preview size (enhance AND tools).
int psInteractiveLong({required int proxyLong, required bool free, required int previewMaxPx}) =>
    free ? math.max(64, math.min(proxyLong, previewMaxPx)) : proxyLong;

/// Size of a [w]×[h] photo shrunk to [maxLong] (never enlarged) — the same
/// rounding the decoders use (UiImageCodec, downscaleRgba).
({int w, int h}) psFitSize(int w, int h, int maxLong) {
  final long = math.max(w, h);
  if (long <= maxLong || long <= 0) return (w: w, h: h);
  final f = maxLong / long;
  return (w: math.max(1, (w * f).round()), h: math.max(1, (h * f).round()));
}

/// Proxy pixel coordinates -> original pixel coordinates (landmarks; face
/// BOXES are 0..1 and need no scaling).
List<math.Point<double>> psPointsToSource(List<math.Point<double>> pts,
    {required int proxyW, required int proxyH, required int srcW, required int srcH}) {
  if (proxyW <= 0 || proxyH <= 0) return pts;
  final fx = srcW / proxyW, fy = srcH / proxyH;
  return [for (final p in pts) math.Point(p.x * fx, p.y * fy)];
}

/// The editing copy of one photo.
class PsProxy {
  const PsProxy(
      {required this.bytes,
      required this.w,
      required this.h,
      required this.srcW,
      required this.srcH});

  /// The proxy itself (identical to the original when it is small enough).
  factory PsProxy.identity(Uint8List original, int w, int h) =>
      PsProxy(bytes: original, w: w, h: h, srcW: w, srcH: h);

  /// Encoded proxy (BMP on the phone: no compression cost, ~7.7 MB at 1600 px).
  final Uint8List bytes;
  final int w, h;

  /// Size of the full-resolution original.
  final int srcW, srcH;

  /// The proxy IS the original (nothing was shrunk): edits are full quality.
  bool get identity => w == srcW && h == srcH;
  int get long => math.max(w, h);
}

// =========================================================================
// Recipe steps
// =========================================================================
abstract class PsStep {
  const PsStep();

  /// Output size for a [w]×[h] input.
  ({int w, int h}) outSize(int w, int h) => (w: w, h: h);
}

/// The classical pipeline with its MEASURED global statistics ([plan]) —
/// null only before the first run (the proxy run measures it once; the
/// export re-uses it, so white balance / levels / CLAHE are identical).
class ClassicStep extends PsStep {
  const ClassicStep(this.params, {this.plan, this.faces = const []});
  final ClassicParams params;
  final ClassicPlan? plan;

  /// Face ellipses in 0..1 image coordinates (skin mask), from the proxy.
  final List<ClassicFace> faces;
  ClassicStep withPlan(ClassicPlan p) => ClassicStep(params, plan: p, faces: faces);
}

/// Background blur with the model's mask (0..255, [side]×[side]) — the mask
/// is resolution-free, the blur radius follows the photo size.
class BlurStep extends PsStep {
  const BlurStep(this.mask, this.side, {this.strength = 0.7, this.maxLong = 2048});
  final Uint8List mask;
  final int side;
  final double strength;

  /// The blur composite works at most at this long edge (as before).
  final int maxLong;
  @override
  ({int w, int h}) outSize(int w, int h) => psFitSize(w, h, maxLong);
}

({int w, int h}) psStepsSize(int w, int h, List<PsStep> steps) {
  var s = (w: w, h: h);
  for (final st in steps) {
    s = st.outSize(s.w, s.h);
  }
  return s;
}

class RecipeOut {
  const RecipeOut(this.rgba, this.w, this.h, this.steps);
  final Uint8List rgba;
  final int w, h;

  /// The steps as run (classic plans filled in).
  final List<PsStep> steps;
}

/// THE recipe renderer (proxy previews and the full-resolution export).
/// [progress] gets (done, total) in 1/1000 of the whole job.
RecipeOut applySteps(Uint8List rgba, int w, int h, List<PsStep> steps,
    {void Function(int done, int total)? progress, int stripRows = 256}) {
  var cur = rgba, cw = w, ch = h;
  final done = <PsStep>[];
  final n = steps.length;
  for (var i = 0; i < n; i++) {
    final st = steps[i];
    void part(int d, int t) =>
        progress?.call(((i + (t <= 0 ? 0 : d / t)) / n * 1000).round(), 1000);
    if (st is ClassicStep) {
      final plan = st.plan ?? _measure(cur, cw, ch, st.params);
      cur = applyPlan(cur, cw, ch, st.params, plan,
          faces: st.faces, stripRows: stripRows, onStrip: part);
      done.add(st.plan == null ? st.withPlan(plan) : st);
    } else if (st is BlurStep) {
      final s = psFitSize(cw, ch, st.maxLong);
      if (s.w != cw || s.h != ch) {
        final d = downscaleRgba(cur, cw, ch, st.maxLong);
        cur = d.rgba;
        cw = d.w;
        ch = d.h;
      }
      cur = blurBackgroundRgba(cur, cw, ch, st.mask, st.side, st.side, strength: st.strength);
      part(1, 1);
      done.add(st);
    } else {
      throw ArgumentError('unknown step $st');
    }
  }
  progress?.call(1000, 1000);
  return RecipeOut(cur, cw, ch, done);
}

ClassicPlan _measure(Uint8List rgba, int w, int h, ClassicParams p) {
  final small = downscaleRgba(rgba, w, h, 1024);
  return analyse(small.rgba, small.w, small.h, p);
}

/// The export: [steps] applied to the full-resolution [rgba], the corner
/// [mark] composited, encoded as PNG with [extraChunks] (AI-edit metadata)
/// — the LAST classic step streams its rows into the encoder, so no second
/// full-size buffer exists. [progress] in 1/1000.
Uint8List renderRecipePng(Uint8List rgba, int w, int h, List<PsStep> steps,
    {MarkPatch? mark,
    List<int> extraChunks = const [],
    void Function(int done, int total)? progress,
    int stripRows = 256,
    int level = 2}) {
  // all but the last step (rare: tool chains), then the last one streamed
  var cur = rgba, cw = w, ch = h;
  final n = steps.length;
  if (n > 1) {
    final r = applySteps(cur, cw, ch, steps.sublist(0, n - 1),
        progress: (d, t) => progress?.call((d * (n - 1) / n).round(), 1000), stripRows: stripRows);
    cur = r.rgba;
    cw = r.w;
    ch = r.h;
  }
  final last = n == 0 ? null : steps[n - 1];
  final base = n <= 1 ? 0 : (n - 1) * 1000 ~/ n;
  final share = 1000 - base;
  if (last is ClassicStep) {
    final plan = last.plan ?? _measure(cur, cw, ch, last.params);
    final png = PngStreamEncoder(cw, ch, extraChunks: extraChunks, level: level);
    applyPlan(cur, cw, ch, last.params, plan, faces: last.faces, stripRows: stripRows,
        onRows: (y0, y1, rows) {
      if (mark != null) mark.compositeRows(rows, cw, y0, y1);
      png.addRows(rows, y1 - y0);
      progress?.call(base + (y1 / ch * share * 0.97).round(), 1000);
    });
    final out = png.close();
    progress?.call(1000, 1000);
    return out;
  }
  if (last != null) {
    final r = applySteps(cur, cw, ch, [last],
        progress: (d, t) => progress?.call(base + (d / 1000 * share * 0.8).round(), 1000));
    cur = r.rgba;
    cw = r.w;
    ch = r.h;
  }
  if (mark != null) mark.compositeRows(cur, cw, 0, ch);
  final png = PngStreamEncoder(cw, ch, extraChunks: extraChunks, level: level);
  const band = 256;
  for (var y = 0; y < ch; y += band) {
    final y1 = math.min(ch, y + band);
    png.addRows(Uint8List.sublistView(cur, y * cw * 4, y1 * cw * 4), y1 - y);
    progress?.call(base + ((0.8 + 0.2 * y1 / ch) * share).round(), 1000);
  }
  final out = png.close();
  progress?.call(1000, 1000);
  return out;
}

// =========================================================================
// photoperf: bands — one classic step split by strips over several cores.
// Every band runs exactly the strips a single pass would, so the pixels are
// bit-identical to [applySteps]; only the work is spread.
// =========================================================================
/// Row ranges (multiples of [stripRows]) for [n] workers.
List<(int, int)> psBands(int h, int stripRows, int n) {
  final strips = (h + stripRows - 1) ~/ stripRows;
  final k = math.max(1, math.min(n, strips));
  return [
    for (var i = 0; i < k; i++)
      (math.min(h, i * strips ~/ k * stripRows), math.min(h, (i + 1) * strips ~/ k * stripRows)),
  ];
}

class BandRgba {
  const BandRgba(this.from, this.to, this.rows, this.plan);
  final int from, to;
  final Uint8List rows;
  final ClassicPlan plan;
}

/// Interactive band: [rgba] is the whole (proxy) photo; the plan is measured
/// here when the step has none (each band measures the same numbers).
BandRgba classicBand(Uint8List rgba, int w, int h, ClassicStep st, int from, int to,
    {void Function(int done, int total)? progress, int stripRows = 256}) {
  final plan = st.plan ?? _measure(rgba, w, h, st.params);
  final out = Uint8List((to - from) * w * 4);
  applyPlan(rgba, w, h, st.params, plan,
      faces: st.faces,
      stripRows: stripRows,
      rowFrom: from,
      rowTo: to,
      onRows: (y0, y1, rows) => out.setRange((y0 - from) * w * 4, (y1 - from) * w * 4, rows),
      onStrip: (d, t) => progress?.call(d - from, to - from));
  return BandRgba(from, to, out, plan);
}

/// Assemble band results into one photo + the step with its plan.
RecipeOut joinBands(List<BandRgba> bands, int w, int h, ClassicStep st) {
  final out = Uint8List(w * h * 4);
  for (final b in bands) {
    out.setRange(b.from * w * 4, b.to * w * 4, b.rows);
  }
  return RecipeOut(out, w, h, [st.plan == null ? st.withPlan(bands.first.plan) : st]);
}

/// One export band, PNG-ready: an IDAT chunk holding this band's part of
/// the zlib stream (header in the first band, sync-flushed so the parts
/// concatenate, final block in the last) + its Adler-32 for the trailer.
class PngBand {
  const PngBand(this.chunk, this.adler, this.rawLen);
  final Uint8List chunk;
  final int adler, rawLen;
}

/// [src] holds rows [srcRow0].. of the w×h photo (the band + context rows).
PngBand exportBand(Uint8List src, int srcRow0, int w, int h, ClassicStep st, int from, int to,
    {MarkPatch? mark,
    bool alpha = false,
    required bool first,
    required bool last,
    int level = 2,
    int stripRows = 256,
    void Function(int done, int total)? progress}) {
  final z = RawZLibFilter.deflateFilter(level: level, raw: true);
  final data = BytesBuilder(copy: false);
  if (first) data.add(const [0x78, 0x01]);
  void drain({bool flush = false, bool end = false}) {
    for (;;) {
      final o = z.processed(flush: flush, end: end);
      if (o == null) break;
      data.add(o);
    }
  }

  final bpp = alpha ? 4 : 3;
  final stride = w * bpp;
  final line = Uint8List(stride + 1);
  final cur = Uint8List(stride), prev = Uint8List(stride);
  var a = 1, b = 0, raw = 0, row = from;
  void adler(Uint8List d) {
    for (var i = 0; i < d.length; i++) {
      a += d[i];
      if (a >= 65521) a -= 65521;
      b += a;
      if (b >= 65521) b -= 65521;
    }
  }

  applyPlan(src, w, h, st.params, st.plan!, // exports always carry the proxy's plan
      faces: st.faces,
      stripRows: stripRows,
      rowFrom: from,
      rowTo: to,
      srcRow0: srcRow0,
      onRows: (y0, y1, rows) {
    if (mark != null) mark.compositeRows(rows, w, y0, y1);
    for (var r = 0; r < y1 - y0; r++) {
      var s = r * w * 4;
      if (bpp == 4) {
        cur.setRange(0, stride, rows, s);
      } else {
        for (var j = 0; j < stride; j += 3, s += 4) {
          cur[j] = rows[s];
          cur[j + 1] = rows[s + 1];
          cur[j + 2] = rows[s + 2];
        }
      }
      // the band's first row has no previous row here: filter None (PNG
      // allows a filter per row), then Up
      if (row == from) {
        line[0] = 0;
        line.setRange(1, stride + 1, cur);
      } else {
        line[0] = 2;
        for (var j = 0; j < stride; j++) {
          line[j + 1] = (cur[j] - prev[j]) & 0xFF;
        }
      }
      prev.setAll(0, cur);
      adler(line);
      raw += line.length;
      z.process(line, 0, line.length);
      drain();
      row++;
    }
    progress?.call(y1 - from, to - from);
  });
  drain(flush: true, end: last);
  return PngBand(pngChunk('IDAT', data.takeBytes()), (b << 16) | a, raw);
}

/// zlib's adler32_combine: Adler-32 of A+B from adler(A), adler(B), len(B).
int adler32Combine(int a1, int a2, int len2) {
  const base = 65521;
  final rem = len2 % base;
  var sum1 = a1 & 0xFFFF;
  var sum2 = (rem * sum1) % base;
  sum1 += (a2 & 0xFFFF) + base - 1;
  sum2 += ((a1 >> 16) & 0xFFFF) + ((a2 >> 16) & 0xFFFF) + base - rem;
  if (sum1 >= base) sum1 -= base;
  if (sum1 >= base) sum1 -= base;
  if (sum2 >= (base << 1)) sum2 -= (base << 1);
  if (sum2 >= base) sum2 -= base;
  return sum1 | (sum2 << 16);
}

/// The PNG file from export bands (in order).
Uint8List joinPngBands(List<PngBand> bands, int w, int h,
    {bool alpha = false, List<int> extraChunks = const []}) {
  var ad = bands.first.adler;
  for (var i = 1; i < bands.length; i++) {
    ad = adler32Combine(ad, bands[i].adler, bands[i].rawLen);
  }
  final ihdr = Uint8List(13);
  ByteData.sublistView(ihdr)
    ..setUint32(0, w)
    ..setUint32(4, h);
  ihdr[8] = 8;
  ihdr[9] = alpha ? 6 : 2;
  final trailer = Uint8List(4);
  ByteData.sublistView(trailer).setUint32(0, ad);
  final out = BytesBuilder(copy: false)
    ..add(const [137, 80, 78, 71, 13, 10, 26, 10])
    ..add(pngChunk('IHDR', ihdr));
  if (extraChunks.isNotEmpty) out.add(extraChunks);
  for (final b in bands) {
    out.add(b.chunk);
  }
  out
    ..add(pngChunk('IDAT', trailer))
    ..add(pngChunk('IEND', const []));
  return out.toBytes();
}

/// Is an encoded image possibly transparent? (PNG colour type with alpha;
/// JPEG/BMP proxies are opaque).
bool psMayHaveAlpha(Uint8List b) =>
    b.length > 25 && b[0] == 0x89 && b[1] == 0x50 && (b[25] == 4 || b[25] == 6);

// =========================================================================
// Corner mark (rendered by Flutter on the main isolate as a small RGBA
// patch, composited here at full resolution)
// =========================================================================
class MarkPatch {
  const MarkPatch(this.rgba, this.x, this.y, this.w, this.h);

  /// Straight-alpha RGBA, [w]×[h], placed at ([x], [y]) of the photo.
  final Uint8List rgba;
  final int x, y, w, h;

  /// Alpha-blend the patch into the photo rows [y0]..[y1] ([rows] holds just
  /// those rows, [imgW] wide).
  void compositeRows(Uint8List rows, int imgW, int y0, int y1) {
    final ya = math.max(y, y0), yb = math.min(y + h, y1);
    if (ya >= yb) return;
    final xa = math.max(0, x), xb = math.min(imgW, x + w);
    for (var yy = ya; yy < yb; yy++) {
      var pi = ((yy - y) * w + (xa - x)) * 4;
      var di = ((yy - y0) * imgW + xa) * 4;
      for (var xx = xa; xx < xb; xx++) {
        final a = rgba[pi + 3];
        if (a == 255) {
          rows[di] = rgba[pi];
          rows[di + 1] = rgba[pi + 1];
          rows[di + 2] = rgba[pi + 2];
        } else if (a > 0) {
          final ia = 255 - a;
          rows[di] = (rgba[pi] * a + rows[di] * ia + 127) ~/ 255;
          rows[di + 1] = (rgba[pi + 1] * a + rows[di + 1] * ia + 127) ~/ 255;
          rows[di + 2] = (rgba[pi + 2] * a + rows[di + 2] * ia + 127) ~/ 255;
        }
        pi += 4;
        di += 4;
      }
    }
  }
}

// =========================================================================
// Encoders (pure Dart)
// =========================================================================
/// RGBA -> BMP (32-bit BGRA, top-down). No compression: ~10 ms for a
/// 1600 px proxy (a PNG encode of the same is several hundred ms on a slow
/// phone). Decoded by Flutter (Skia) and Android's BitmapFactory alike.
Uint8List encodeBmp(Uint8List rgba, int w, int h) {
  const head = 54;
  final n = w * h * 4;
  final out = Uint8List(head + n);
  final bd = ByteData.sublistView(out);
  out[0] = 0x42; // 'B'
  out[1] = 0x4D; // 'M'
  bd.setUint32(2, head + n, Endian.little);
  bd.setUint32(10, head, Endian.little);
  bd.setUint32(14, 40, Endian.little); // BITMAPINFOHEADER
  bd.setInt32(18, w, Endian.little);
  bd.setInt32(22, -h, Endian.little); // negative = top-down rows
  bd.setUint16(26, 1, Endian.little);
  bd.setUint16(28, 32, Endian.little);
  bd.setUint32(30, 0, Endian.little); // BI_RGB
  bd.setUint32(34, n, Endian.little);
  bd.setInt32(38, 2835, Endian.little);
  bd.setInt32(42, 2835, Endian.little);
  for (var i = 0, o = head; i < n; i += 4, o += 4) {
    out[o] = rgba[i + 2];
    out[o + 1] = rgba[i + 1];
    out[o + 2] = rgba[i];
    out[o + 3] = rgba[i + 3];
  }
  return out;
}

/// The size of an encoded PNG / JPEG / BMP / WebP from its header (no
/// decode, no copy). null = unknown format (the caller asks the codec).
({int w, int h})? psHeaderSize(Uint8List b) {
  try {
    if (b.length >= 24 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      final d = ByteData.sublistView(b);
      return (w: d.getUint32(16), h: d.getUint32(20));
    }
    if (b.length >= 26 && b[0] == 0x42 && b[1] == 0x4D) {
      final d = ByteData.sublistView(b);
      return (w: d.getInt32(18, Endian.little).abs(), h: d.getInt32(22, Endian.little).abs());
    }
    if (b.length >= 4 && b[0] == 0xFF && b[1] == 0xD8) {
      var i = 2;
      while (i + 9 < b.length) {
        if (b[i] != 0xFF) {
          i++;
          continue;
        }
        final m = b[i + 1];
        if (m == 0xD8 || m == 0x01 || (m >= 0xD0 && m <= 0xD7) || m == 0xFF) {
          i += m == 0xFF ? 1 : 2;
          continue;
        }
        final len = (b[i + 2] << 8) | b[i + 3];
        // SOF0..SOF15 except DHT(C4), JPG(C8), DAC(CC)
        if (m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC) {
          final h = (b[i + 5] << 8) | b[i + 6];
          final w = (b[i + 7] << 8) | b[i + 8];
          // EXIF orientation is NOT applied here: callers only use the long
          // edge / aspect-free numbers, or fall back to the codec.
          return (w > 0 && h > 0) ? (w: w, h: h) : null;
        }
        i += 2 + len;
      }
    }
  } catch (_) {}
  return null;
}

/// PNG encoder fed with RGBA rows; "Up" filter + zlib (dart:io, native),
/// RGB when the photo is opaque. [extraChunks] are inserted after IHDR.
class PngStreamEncoder {
  factory PngStreamEncoder(int w, int h, {List<int> extraChunks = const [], int level = 2}) =>
      PngStreamEncoder._(w, h, extraChunks, level, _Collect());
  PngStreamEncoder._(this.w, this.h, this.extraChunks, int level, this._sink)
      : _z = ZLibEncoder(level: level).startChunkedConversion(_sink);

  final int w, h;
  final List<int> extraChunks;
  final _Collect _sink;
  final ByteConversionSink _z;
  Uint8List? _prev;
  int _rows = 0;
  bool? _alpha;

  void addRows(Uint8List rgba, int rows) {
    // the first band decides RGB vs RGBA for the whole file (photos are
    // opaque; a PNG with transparency keeps it)
    _alpha ??= _hasAlpha(rgba);
    final bpp = _alpha! ? 4 : 3;
    final stride = w * bpp;
    _prev ??= Uint8List(stride);
    final line = Uint8List(stride + 1);
    final cur = Uint8List(stride);
    for (var r = 0; r < rows; r++) {
      var s = r * w * 4;
      if (bpp == 4) {
        cur.setRange(0, stride, rgba, s);
      } else {
        for (var j = 0; j < stride; j += 3, s += 4) {
          cur[j] = rgba[s];
          cur[j + 1] = rgba[s + 1];
          cur[j + 2] = rgba[s + 2];
        }
      }
      line[0] = 2; // Up
      final p = _prev!;
      for (var j = 0; j < stride; j++) {
        line[j + 1] = (cur[j] - p[j]) & 0xFF;
      }
      _z.add(line);
      _prev!.setAll(0, cur);
      _rows++;
    }
  }

  static bool _hasAlpha(Uint8List rgba) {
    for (var i = 3; i < rgba.length; i += 4) {
      if (rgba[i] != 255) return true;
    }
    return false;
  }

  Uint8List close() {
    if (_rows != h) throw StateError('png: $_rows of $h rows');
    _z.close();
    final idat = _sink.bytes();
    final out = BytesBuilder(copy: false)..add(const [137, 80, 78, 71, 13, 10, 26, 10]);
    final ihdr = Uint8List(13);
    ByteData.sublistView(ihdr)
      ..setUint32(0, w)
      ..setUint32(4, h);
    ihdr[8] = 8;
    ihdr[9] = (_alpha ?? false) ? 6 : 2;
    out.add(pngChunk('IHDR', ihdr));
    if (extraChunks.isNotEmpty) out.add(extraChunks);
    out.add(pngChunk('IDAT', idat));
    out.add(pngChunk('IEND', const []));
    return out.toBytes();
  }
}

/// Collects zlib output (chunks kept until close; one copy at the end).
class _Collect implements Sink<List<int>> {
  final BytesBuilder _b = BytesBuilder(copy: false);
  @override
  void add(List<int> data) => _b.add(data);
  @override
  void close() {}
  Uint8List bytes() => _b.takeBytes();
}

/// One PNG chunk (length, type, data, CRC).
Uint8List pngChunk(String type, List<int> data) {
  final out = Uint8List(12 + data.length);
  final bd = ByteData.sublistView(out);
  bd.setUint32(0, data.length);
  for (var i = 0; i < 4; i++) {
    out[4 + i] = type.codeUnitAt(i);
  }
  out.setRange(8, 8 + data.length, data);
  bd.setUint32(8 + data.length, _crc(out, 4, 8 + data.length));
  return out;
}

final Uint32List _crcTable = () {
  final t = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    t[n] = c;
  }
  return t;
}();

int _crc(Uint8List b, int from, int to) {
  var c = 0xFFFFFFFF;
  for (var i = from; i < to; i++) {
    c = _crcTable[(c ^ b[i]) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

// =========================================================================
// Background worker with progress + honest cancel
// =========================================================================
class PsWorkCancelled implements Exception {
  const PsWorkCancelled();
}

/// Runs heavy jobs in background isolates (or inline for tests): real
/// progress messages, and [cancel] KILLS every isolate (nothing kept).
class PsWorker {
  PsWorker({this.inline = false});

  /// Run on the calling isolate (unit/widget tests with fake async).
  final bool inline;
  final Set<Isolate> _isos = {};
  int _running = 0;
  bool _cancelled = false;

  bool get running => _running > 0;

  Future<T> run<T>(T Function(void Function(int done, int total) progress) job,
      {void Function(int done, int total)? onProgress}) async {
    final r = await runAll<T>([job], onProgress: onProgress);
    return r.single;
  }

  /// photoperf: several jobs at once (one isolate each, e.g. bands of one
  /// photo on a multi-core phone); progress is the sum over the jobs, in
  /// 1/1000. Any failure or a cancel stops all of them.
  Future<List<T>> runAll<T>(List<T Function(void Function(int done, int total) progress)> jobs,
      {void Function(int done, int total)? onProgress}) async {
    _cancelled = false;
    final n = jobs.length;
    final part = List<double>.filled(n, 0);
    void report(int i, int d, int t) {
      part[i] = t <= 0 ? 0 : d / t;
      if (onProgress != null) {
        var sum = 0.0;
        for (final v in part) {
          sum += v;
        }
        onProgress((sum / n * 1000).round(), 1000);
      }
    }

    if (inline) {
      final out = <T>[];
      for (var i = 0; i < n; i++) {
        out.add(jobs[i]((d, t) {
          if (_cancelled) throw const PsWorkCancelled();
          report(i, d, t);
        }));
        if (_cancelled) throw const PsWorkCancelled();
      }
      return out;
    }
    _running++;
    try {
      return await Future.wait([for (var i = 0; i < n; i++) _one<T>(jobs[i], (d, t) => report(i, d, t))],
          eagerError: true);
    } catch (e) {
      if (_isos.isNotEmpty) _killAll(); // one failed -> stop the others
      if (_cancelled) throw const PsWorkCancelled();
      rethrow;
    } finally {
      _running--;
    }
  }

  Future<T> _one<T>(T Function(void Function(int, int)) job, void Function(int, int) prog) async {
    final port = ReceivePort();
    final done = Completer<Object?>();
    port.listen((m) {
      if (m is List && m.length == 3 && m[0] == 'p') {
        prog(m[1] as int, m[2] as int);
      } else if (m is List && m.length == 2 && m[0] == 'e') {
        if (!done.isCompleted) done.completeError(StateError('${m[1]}'));
      } else if (m is List && m.length == 2 && m[0] == 'r') {
        if (!done.isCompleted) done.complete(m[1]);
      } else if (m == null) {
        // isolate exited without a result (killed or crashed)
        if (!done.isCompleted) {
          done.completeError(_cancelled ? const PsWorkCancelled() : StateError('worker_exit'));
        }
      }
    });
    Isolate? iso;
    try {
      iso = await Isolate.spawn<_Job>(_entry, _Job(port.sendPort, job),
          onExit: port.sendPort, errorsAreFatal: true);
      _isos.add(iso);
      if (_cancelled) iso.kill(priority: Isolate.immediate);
      final r = await done.future;
      return r as T;
    } finally {
      port.close();
      if (iso != null) _isos.remove(iso);
    }
  }

  void _killAll() {
    for (final i in _isos.toList()) {
      i.kill(priority: Isolate.immediate);
    }
  }

  /// Stop now: the isolates are killed (their exit makes [run] / [runAll]
  /// throw [PsWorkCancelled]; a cancel during spawn is applied right after).
  void cancel() {
    _cancelled = true;
    _killAll();
  }
}

class _Job {
  const _Job(this.port, this.job);
  final SendPort port;
  final Object? Function(void Function(int, int)) job;
}

void _entry(_Job j) {
  Object? r;
  try {
    var last = -1;
    r = j.job((d, t) {
      // at most ~100 messages per job
      final q = t <= 0 ? 0 : d * 100 ~/ t;
      if (q != last) {
        last = q;
        j.port.send(['p', d, t]);
      }
    });
  } catch (e) {
    j.port.send(['e', e.runtimeType.toString()]);
    return;
  }
  // hands the result over without a copy
  Isolate.exit(j.port, ['r', r]);
}
