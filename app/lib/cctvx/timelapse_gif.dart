// cctvactivity (W10, owner CCTV order E10) — the 30-second daily TIME-LAPSE,
// made ON THE PHONE from the day's stored photos: no server video encoding,
// no native code, no new package (the `image` package already in pubspec).
// Pure Dart; runs in a background isolate via compute() so the UI never
// freezes. Each frame is fitted to 480x270 and stamped with its time.
import 'dart:typed_data';

import 'package:image/image.dart' as img;

const int kTlWidth = 480;
const int kTlHeight = 270;
const int kTlMaxFrames = 60;

/// Per-frame delay in 1/100 s so the film lasts ~[seconds] (0.1 s .. 2 s).
int timelapseDelayCs(int frames, {int seconds = 30}) {
  if (frames <= 0) return 0;
  final d = (seconds * 100 / frames).round();
  return d < 10 ? 10 : (d > 200 ? 200 : d);
}

/// Evenly spread [n] items over [items] (first and last kept).
List<T> spreadFrames<T>(List<T> items, int n) {
  if (n >= items.length) return List<T>.of(items);
  if (n <= 1) return items.take(1).toList();
  final step = (items.length - 1) / (n - 1);
  return [for (var i = 0; i < n; i++) items[(i * step).round()]];
}

/// compute() entry: {'frames': List<Uint8List>, 'labels': List<String>}
/// -> animated GIF bytes, or null when no frame could be decoded.
Uint8List? buildTimelapseGif(Map<String, Object> job) {
  final raw = (job['frames'] as List).cast<Uint8List>();
  final labels = (job['labels'] as List?)?.cast<String>() ?? const <String>[];
  final decoded = <img.Image>[];
  final stamps = <String>[];
  for (var i = 0; i < raw.length && decoded.length < kTlMaxFrames; i++) {
    final im = img.decodeImage(raw[i]);
    if (im == null) continue; // a broken / expired photo is skipped, not faked
    final fit = img.copyResize(im,
        width: kTlWidth,
        height: kTlHeight,
        maintainAspect: true,
        backgroundColor: img.ColorRgb8(0, 0, 0),
        interpolation: img.Interpolation.average);
    decoded.add(fit);
    stamps.add(i < labels.length ? labels[i] : '');
  }
  if (decoded.isEmpty) return null;
  final delay = timelapseDelayCs(decoded.length);
  final enc = img.GifEncoder(
      delay: delay,
      repeat: 0,
      quantizerType: img.QuantizerType.octree,
      dither: img.DitherKernel.none);
  for (var i = 0; i < decoded.length; i++) {
    final f = decoded[i];
    final s = stamps[i];
    if (s.isNotEmpty) {
      // ASCII time stamp (HH:MM + camera) — the bitmap font has no Bangla
      img.fillRect(f, x1: 4, y1: kTlHeight - 22, x2: 8 + s.length * 8, y2: kTlHeight - 4,
          color: img.ColorRgb8(0, 0, 0));
      img.drawString(f, s,
          font: img.arial14, x: 6, y: kTlHeight - 21, color: img.ColorRgb8(255, 255, 255));
    }
    enc.addFrame(f, duration: delay);
  }
  return enc.finish();
}
