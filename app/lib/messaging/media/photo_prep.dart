import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// circlemedia — the on-phone photo work of a multi-photo send: rotate,
/// HD or Standard size, JPEG re-encode WITHOUT any metadata (no location,
/// no camera details). Pure Dart (package:image) so it runs in a background
/// isolate and is unit-tested.

/// Standard: the long edge the app has always sent (small, fast on 2G/3G).
const int kStdEdge = 1600;
const int kStdQuality = 80;

/// HD: sharper, about 2-3x the bytes.
const int kHdEdge = 2560;
const int kHdQuality = 88;

/// The prep block a [MediaJob] carries until step 1 runs it.
Map<String, dynamic> photoPrepSpec({required int turns, required bool hd}) => {
      'rot': turns % 4,
      'edge': hd ? kHdEdge : kStdEdge,
      'q': hd ? kHdQuality : kStdQuality,
    };

/// The size a photo of [w]x[h] will have after [photoPrepSpec] (for the
/// bubble before the work has run).
(int, int)? preppedSize(int? w, int? h, {required int turns, required bool hd}) {
  if (w == null || h == null || w <= 0 || h <= 0) return null;
  var (a, b) = turns % 2 == 1 ? (h, w) : (w, h);
  final edge = hd ? kHdEdge : kStdEdge;
  final long = math.max(a, b);
  if (long > edge) {
    final f = edge / long;
    a = math.max(1, (a * f).round());
    b = math.max(1, (b * f).round());
  }
  return (a, b);
}

class PhotoPrepOut {
  final Uint8List bytes;
  final int width, height;
  const PhotoPrepOut(this.bytes, this.width, this.height);
}

/// Decode → apply EXIF orientation → rotate by [turns] quarter turns →
/// shrink so the long edge is at most [maxEdge] → JPEG at [quality] with no
/// metadata. null when the bytes are not a picture this code can read (the
/// caller then sends the original, already scrubbed, file).
PhotoPrepOut? photoPrepSync(Uint8List src, int turns, int maxEdge, int quality) {
  try {
    final decoded = img.decodeImage(src);
    if (decoded == null) return null;
    var im = img.bakeOrientation(decoded);
    final t = turns % 4;
    if (t != 0) im = img.copyRotate(im, angle: 90 * t);
    final long = math.max(im.width, im.height);
    if (long > maxEdge) {
      im = im.width >= im.height
          ? img.copyResize(im, width: maxEdge, interpolation: img.Interpolation.average)
          : img.copyResize(im, height: maxEdge, interpolation: img.Interpolation.average);
    }
    im.exif = img.ExifData(); // nothing about the place or the phone
    final out = img.encodeJpg(im, quality: quality.clamp(40, 95));
    return PhotoPrepOut(Uint8List.fromList(out), im.width, im.height);
  } catch (_) {
    return null;
  }
}

PhotoPrepOut? _iso(List<Object> a) =>
    photoPrepSync(a[0] as Uint8List, a[1] as int, a[2] as int, a[3] as int);

/// [photoPrepSync] in a background isolate (keeps the chat smooth).
Future<PhotoPrepOut?> photoPrep(Uint8List src,
        {required int turns, required int maxEdge, required int quality}) =>
    compute(_iso, <Object>[src, turns, maxEdge, quality]);

/// Whether running the prep would change anything for a [w]x[h] photo.
bool prepNeeded(Map<String, dynamic>? prep, int? w, int? h) {
  if (prep == null) return false;
  final turns = (prep['rot'] as num?)?.toInt() ?? 0;
  if (turns % 4 != 0) return true;
  final edge = (prep['edge'] as num?)?.toInt() ?? kStdEdge;
  if (w == null || h == null) return true;
  return math.max(w, h) > edge;
}
