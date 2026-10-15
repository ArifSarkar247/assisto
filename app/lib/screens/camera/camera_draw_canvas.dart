import 'package:flutter/material.dart';

/// A single freehand stroke: the points (in the canvas' local coordinates) plus
/// its colour and width. Kept dead simple so it serialises/exports cleanly.
class DrawStroke {
  final List<Offset> points;
  final Color color;
  final double width;
  DrawStroke({required this.color, required this.width}) : points = <Offset>[];
}

/// A short text sticker the user drops on the photo, positioned by its centre
/// as a fraction of the canvas size so it survives resize/export.
class TextSticker {
  String text;
  Offset fraction; // 0..1 in each axis
  Color color;
  TextSticker({required this.text, required this.fraction, required this.color});
}

/// Paints the freehand strokes over the image. The image itself is rendered by
/// the parent (an Image widget) behind this painter inside a RepaintBoundary, so
/// exporting the boundary captures image + drawing + text together.
class DrawPainter extends CustomPainter {
  final List<DrawStroke> strokes;
  const DrawPainter(this.strokes);

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in strokes) {
      if (stroke.points.length < 2) {
        if (stroke.points.length == 1) {
          final p = Paint()
            ..color = stroke.color
            ..style = PaintingStyle.fill;
          canvas.drawCircle(stroke.points.first, stroke.width / 2, p);
        }
        continue;
      }
      final paint = Paint()
        ..color = stroke.color
        ..strokeWidth = stroke.width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      final path = Path()
        ..moveTo(stroke.points.first.dx, stroke.points.first.dy);
      for (var i = 1; i < stroke.points.length; i++) {
        path.lineTo(stroke.points[i].dx, stroke.points[i].dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant DrawPainter old) =>
      old.strokes != strokes || old.strokes.length != strokes.length;
}
