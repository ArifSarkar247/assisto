/// photobar: the Flutter half of the editor (ps_edit.dart is pure Dart) —
/// decode for an edit preview, run the steps off the UI thread, draw text /
/// stickers with Flutter's text engine (correct Bangla shaping) into small
/// RGBA patches, and the portal JPEG. One drawing function serves the live
/// editor AND the file, so what you place is what you get.
library;

import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'ps_edit.dart';
import 'ps_recipe.dart';

abstract class PsEditCodec {
  /// Encoded -> straight RGBA (at most [maxLong] on the long edge).
  Future<RgbaOut> decode(Uint8List encoded, {int? maxLong});

  /// Pure steps (no un-drawn [OverlayStep]) off the UI thread.
  Future<RgbaOut> run(Uint8List rgba, int w, int h, List<PsStep> steps);

  /// RGBA -> bytes the screen can show (fast; not the exported file).
  Future<Uint8List> encodePreview(RgbaOut img);

  /// Draw [items] for a [w]×[h] photo.
  Future<List<MarkPatch>> rasterize(List<PsOverlay> items, int w, int h);

  /// The exported PNG -> a JPEG under [maxKb] (null = cannot fit).
  Future<({Uint8List bytes, int quality})?> jpegUnder(Uint8List png, int maxKb);
}

/// Text style + box of one overlay at [fontPx] (shared by the editor's
/// painter and [UiEditCodec.rasterize]).
class PsOverlayLayout {
  PsOverlayLayout(PsOverlay o, double fontPx)
      : painter = TextPainter(
          text: TextSpan(
            text: o.text,
            style: TextStyle(
              fontFamily: o.font,
              fontSize: math.max(4.0, fontPx),
              height: 1.25,
              fontWeight: o.font == 'Galada' ? FontWeight.w400 : FontWeight.w600,
              color: Color(o.color),
              shadows: o.bg == 0
                  ? [Shadow(blurRadius: fontPx * 0.12, color: const Color(0xB3000000),
                      offset: Offset(0, fontPx * 0.04))]
                  : null,
            ),
          ),
          textAlign: TextAlign.center,
          textDirection: TextDirection.ltr,
        ),
        padX = fontPx * (o.bg == 0 ? 0.25 : 0.55),
        padY = fontPx * (o.bg == 0 ? 0.15 : 0.30),
        bg = o.bg {
    painter.layout();
  }

  final TextPainter painter;
  final double padX, padY;
  final int bg;
  Size get size => Size(painter.width + padX * 2, painter.height + padY * 2);

  /// Paint with the box's top-left at [origin].
  void paint(Canvas c, Offset origin) {
    final s = size;
    if (bg != 0) {
      c.drawRRect(
          RRect.fromRectAndRadius(origin & s, Radius.circular(s.height * 0.35)),
          Paint()..color = Color(bg));
    }
    painter.paint(c, origin + Offset(padX, padY));
  }

  void dispose() => painter.dispose();
}

/// Font height in pixels for a photo of [w]×[h].
double psOverlayFontPx(PsOverlay o, num w, num h) => o.size * math.min(w, h).toDouble();

class UiEditCodec implements PsEditCodec {
  const UiEditCodec({this.inline = false});

  /// Run the steps on the calling isolate (tests).
  final bool inline;

  @override
  Future<RgbaOut> decode(Uint8List encoded, {int? maxLong}) async {
    // the studio's own BMP previews: read directly, alpha kept
    final bmp = psDecodeBmp32(encoded);
    if (bmp != null && (maxLong == null || math.max(bmp.w, bmp.h) <= maxLong)) return bmp;
    final buf = await ui.ImmutableBuffer.fromUint8List(encoded);
    final desc = await ui.ImageDescriptor.encoded(buf);
    int? tw, th;
    final long = math.max(desc.width, desc.height);
    if (maxLong != null && long > maxLong) {
      final f = maxLong / long;
      tw = math.max(1, (desc.width * f).round());
      th = math.max(1, (desc.height * f).round());
    }
    final codec = await desc.instantiateCodec(targetWidth: tw, targetHeight: th);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      final bd = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      if (bd == null) throw StateError('decode');
      return RgbaOut(bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes), image.width,
          image.height);
    } finally {
      image.dispose();
      codec.dispose();
      desc.dispose();
      buf.dispose();
    }
  }

  @override
  Future<RgbaOut> run(Uint8List rgba, int w, int h, List<PsStep> steps) async {
    RgbaOut job(Uint8List px) {
      final r = applySteps(px, w, h, steps);
      return RgbaOut(r.rgba, r.w, r.h);
    }

    if (inline) return job(rgba);
    final t = TransferableTypedData.fromList([rgba]);
    final out = await Isolate.run(() {
      final r = job(t.materialize().asUint8List());
      return (TransferableTypedData.fromList([r.rgba]), r.w, r.h);
    });
    return RgbaOut(out.$1.materialize().asUint8List(), out.$2, out.$3);
  }

  @override
  Future<Uint8List> encodePreview(RgbaOut img) async => encodeBmp(img.rgba, img.w, img.h);

  @override
  Future<List<MarkPatch>> rasterize(List<PsOverlay> items, int w, int h) async {
    final out = <MarkPatch>[];
    for (final o in items) {
      if (o.text.trim().isEmpty) continue;
      final lay = PsOverlayLayout(o, psOverlayFontPx(o, w, h));
      try {
        final s = lay.size;
        final pw = s.width.ceil(), ph = s.height.ceil();
        if (pw <= 0 || ph <= 0) continue;
        final rec = ui.PictureRecorder();
        lay.paint(Canvas(rec), Offset.zero);
        final pic = rec.endRecording();
        final im = await pic.toImage(pw, ph);
        final bd = await im.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
        im.dispose();
        pic.dispose();
        if (bd == null) continue;
        out.add(MarkPatch(bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes),
            (o.cx * w - pw / 2).round(), (o.cy * h - ph / 2).round(), pw, ph));
      } finally {
        lay.dispose();
      }
    }
    return out;
  }

  @override
  Future<({Uint8List bytes, int quality})?> jpegUnder(Uint8List png, int maxKb) async {
    ({Uint8List bytes, int quality})? job(Uint8List p) {
      final d = psDecodePng(p);
      if (d == null) return null;
      return psJpegUnder(d.rgba, d.w, d.h, maxKb);
    }

    if (inline) return job(png);
    return Isolate.run(() => job(png));
  }
}
