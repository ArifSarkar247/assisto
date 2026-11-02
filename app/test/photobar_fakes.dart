// photobar test doubles: a pure-Dart edit codec (package:image decode/PNG
// encode, steps inline, overlays drawn as solid patches) so controller and
// widget tests run without the engine's image codec, and a picture picker.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'package:assisto/photo_studio/ps_controller.dart';
import 'package:assisto/photo_studio/ps_edit.dart';
import 'package:assisto/photo_studio/ps_edit_ui.dart';
import 'package:assisto/photo_studio/ps_recipe.dart';

/// A [w]×[h] PNG: a soft gradient with a "head" in the middle.
Uint8List pbPhoto(int w, int h, {bool noise = false}) {
  final im = img.Image(width: w, height: h);
  final rnd = math.Random(7);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final head = math.pow((x - w / 2) / (w * 0.2), 2) + math.pow((y - h * 0.4) / (h * 0.2), 2) < 1;
      final n = noise ? rnd.nextInt(255) : 0;
      im.setPixelRgba(x, y, head ? 205 : (60 + 150 * x ~/ w + n) % 256,
          head ? 150 : (90 + 100 * y ~/ h + n) % 256, head ? 120 : (200 + n) % 256, 255);
    }
  }
  return img.encodePng(im);
}

class PureEditCodec extends UiEditCodec {
  PureEditCodec() : super(inline: true);
  final drawn = <(int, int, int)>[]; // (items, w, h) per rasterize call
  int decodes = 0;

  @override
  Future<RgbaOut> decode(Uint8List encoded, {int? maxLong}) async {
    decodes++;
    final d = img.decodeImage(encoded)!;
    final rgba = Uint8List.fromList(
        d.convert(numChannels: 4, format: img.Format.uint8).getBytes(order: img.ChannelOrder.rgba));
    return RgbaOut(rgba, d.width, d.height);
  }

  @override
  Future<Uint8List> encodePreview(RgbaOut o) async => img.encodePng(img.Image.fromBytes(
      width: o.w, height: o.h, bytes: Uint8List.fromList(o.rgba).buffer, numChannels: 4));

  @override
  Future<List<MarkPatch>> rasterize(List<PsOverlay> items, int w, int h) async {
    drawn.add((items.length, w, h));
    return [
      for (final o in items)
        MarkPatch(Uint8List.fromList(List.filled(4 * 4 * 4, 255)..fillRange(0, 4, 255)),
            (o.cx * w).round() - 2, (o.cy * h).round() - 2, 4, 4),
    ];
  }
}

class PbPicker implements PhotoPicker {
  PbPicker(this.photo);
  final Uint8List photo;
  @override
  Future<Uint8List?> pick({required bool camera}) async => photo;
  @override
  Future<List<Uint8List>> pickMany({int limit = 10}) async => [photo];
}
