// cctvplay item 4 — optional CONTINUOUS recording on the camera phone.
// PURE rules (no Flutter, no plugins, no I/O) so each decision is tested:
//   * segment file names (start second + length) and the published spans,
//   * which segment holds a second a viewer asked for,
//   * the battery / heat / storage / live guards (pause, then resume),
//   * one YUV420 camera frame -> a small JPEG for the alert photo while the
//     camera is busy recording (no second still capture on old phones).

import 'dart:typed_data';

import 'package:image/image.dart' as img;

const kRecSegmentS = 60;
const kRecCapChoicesMb = [1000, 2000, 4000, 8000];
const kRecCapDefaultMb = 2000;
const kRecMinFreeBytes = 300 * 1024 * 1024; // keep the phone itself usable
const kRecHotC = 45.0;
const kRecLowBattery = 30;

String segName(int startS, int durS) => 'seg_${startS}_$durS.mp4';

/// (start second, length) from "seg_<start>_<dur>.mp4", else null.
(int, int)? parseSeg(String path) {
  final m = RegExp(r'seg_(\d{9,11})_(\d{1,4})\.mp4$').firstMatch(path);
  if (m == null) return null;
  final s = int.parse(m.group(1)!), d = int.parse(m.group(2)!);
  return d <= 0 ? null : (s, d);
}

/// Merged [[start, end]] spans (a gap of <= 3 s between segments is joined).
List<List<int>> spansOf(Iterable<(int, int)> segs) {
  final l = [...segs]..sort((a, b) => a.$1.compareTo(b.$1));
  final out = <List<int>>[];
  for (final (s, d) in l) {
    final e = s + d;
    if (out.isNotEmpty && s <= out.last[1] + 3) {
      if (e > out.last[1]) out.last[1] = e;
    } else {
      out.add([s, e]);
    }
  }
  return out;
}

/// The segment path that holds second [t] (or null).
String? segFor(Iterable<String> paths, int t) {
  for (final p in paths) {
    final s = parseSeg(p);
    if (s != null && s.$1 <= t && t < s.$1 + s.$2) return p;
  }
  return null;
}

/// Why continuous recording must pause right now ('' = record).
/// Alerts never pause — only the optional continuous recording does.
String recGuard({bool? charging, int? level, double? tempC, int? freeBytes, bool inLive = false}) {
  if (inLive) return 'live';
  if (tempC != null && tempC >= kRecHotC) return 'hot';
  if (charging == false && (level ?? 100) < kRecLowBattery) return 'battery';
  if (freeBytes != null && freeBytes < kRecMinFreeBytes) return 'storage';
  return '';
}

/// One camera frame (YUV420: Y plane + U/V planes with their strides) ->
/// a JPEG at most [maxSide] px on the long side, turned by `rot` degrees
/// (the sensor orientation). Null on a malformed frame.
/// Pure Dart — run it in an isolate (compute) on the camera phone.
Uint8List? yuvToJpeg(Map<String, Object> f, {int maxSide = 640, int quality = 70}) {
  try {
    final w = f['w'] as int, h = f['h'] as int;
    final y = f['y'] as Uint8List, u = f['u'] as Uint8List, v = f['v'] as Uint8List;
    final yRow = f['yRow'] as int, uvRow = f['uvRow'] as int, uvPix = f['uvPix'] as int;
    final step = (w > h ? w : h) > maxSide ? ((w > h ? w : h) / maxSide).ceil() : 1;
    final ow = w ~/ step, oh = h ~/ step;
    var out = img.Image(width: ow, height: oh);
    for (var oy = 0; oy < oh; oy++) {
      final sy = oy * step;
      for (var ox = 0; ox < ow; ox++) {
        final sx = ox * step;
        final yy = y[sy * yRow + sx];
        final uvi = (sy >> 1) * uvRow + (sx >> 1) * uvPix;
        final uu = u[uvi] - 128, vv = v[uvi] - 128;
        int c(num x) => x < 0 ? 0 : (x > 255 ? 255 : x.toInt());
        out.setPixelRgb(ox, oy, c(yy + 1.402 * vv), c(yy - 0.344 * uu - 0.714 * vv), c(yy + 1.772 * uu));
      }
    }
    // the sensor is mounted sideways on most phones: turn it upright
    final rot = (f['rot'] as int?) ?? 0;
    if (rot % 360 != 0) out = img.copyRotate(out, angle: rot % 360);
    return img.encodeJpg(out, quality: quality);
  } catch (_) {
    return null;
  }
}
