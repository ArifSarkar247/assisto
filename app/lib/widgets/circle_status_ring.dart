import 'package:flutter/material.dart';

import '../theme.dart';

/// A circular avatar wrapped in a WhatsApp/Messenger-style "story ring".
///
/// - [hasUnseen] true -> a bright brand-gradient ring (there is something new);
///   false -> a muted grey ring (all seen).
/// - [segments] draws N gaps in the ring, one per status (like WhatsApp), so a
///   person with 3 posts shows a 3-segment ring.
/// Original design — not a copy of their exact ring art.
class CircleStatusRing extends StatelessWidget {
  final String label; // initial(s) to show when there's no photo
  final bool hasUnseen;
  final int segments;
  final double size;
  final IconData? icon; // overrides label (e.g. '+' for add)

  const CircleStatusRing({
    super.key,
    required this.label,
    this.hasUnseen = true,
    this.segments = 1,
    this.size = 56,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RingPainter(
          segments: segments < 1 ? 1 : segments,
          gradient: hasUnseen ? Brand.gradient : null,
          dimColor: scheme.outlineVariant,
        ),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: CircleAvatar(
            backgroundColor: scheme.primaryContainer,
            child: icon != null
                ? Icon(icon, color: scheme.onPrimaryContainer)
                : Text(
                    label,
                    style: TextStyle(
                      color: scheme.onPrimaryContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final int segments;
  final Gradient? gradient;
  final Color dimColor;

  _RingPainter({
    required this.segments,
    required this.gradient,
    required this.dimColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    const stroke = 3.0;
    final r = (size.shortestSide - stroke) / 2;
    final center = rect.center;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    if (gradient != null) {
      paint.shader = gradient!.createShader(rect);
    } else {
      paint.color = dimColor;
    }

    const gap = 0.18; // radians of gap between segments
    final sweep = (2 * 3.1415926535 - gap * segments) / segments;
    var start = -3.1415926535 / 2; // top
    for (var i = 0; i < segments; i++) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: r),
        start,
        sweep,
        false,
        paint,
      );
      start += sweep + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.segments != segments ||
      old.gradient != gradient ||
      old.dimColor != dimColor;
}
