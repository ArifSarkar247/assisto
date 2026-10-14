import 'package:flutter/material.dart';

import '../theme.dart';

/// Lightweight, dependency-free analytics chart primitives for the owner
/// dashboard (SPEC v2.1 §21, ADVANCED). Everything is drawn with CustomPainter
/// / plain widgets — NO external chart package — from data the backend already
/// returns. Nothing here fabricates values: zero-filled gaps render as real
/// zeros, and empty series render an honest "no data" placeholder rather than
/// an invented line.
///
/// Privacy: these widgets only ever receive aggregate counts (ints). No names,
/// phones or emails are passed in or displayed.
///
/// All user-facing text is passed in already-localised (and numerals already
/// converted to the active locale's digits by the caller) — these widgets hold
/// ZERO hard-coded copy, so they stay bilingual-safe with no Bangla literals.

/// A single point in a trend series: a day label (opaque to the chart) and an
/// integer count. The chart only cares about [value]; [day] is used for the
/// accessible tooltip/semantics the caller supplies.
class TrendPoint {
  final String day;
  final int value;
  const TrendPoint(this.day, this.value);
}

/// A compact sparkline for a trailing daily series (e.g. daily active users).
/// Renders an honest polyline + soft fill. Flat-zero series render a baseline,
/// never a fabricated slope.
class Sparkline extends StatelessWidget {
  final List<TrendPoint> points;
  final Color? color;
  final double height;

  /// Already-localised accessible description, e.g. "Daily active users trend".
  final String semanticLabel;

  const Sparkline({
    super.key,
    required this.points,
    required this.semanticLabel,
    this.color,
    this.height = 56,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = color ?? scheme.primary;
    return Semantics(
      label: semanticLabel,
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(
          painter: _SparkPainter(points, c),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  final List<TrendPoint> pts;
  final Color color;
  _SparkPainter(this.pts, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (pts.isEmpty) return;
    final maxV = pts.fold<int>(0, (m, p) => p.value > m ? p.value : m);
    final n = pts.length;
    // Horizontal step; guard the single-point case.
    final dx = n > 1 ? size.width / (n - 1) : 0.0;
    // Leave a little vertical padding so the stroke isn't clipped.
    const padTop = 4.0;
    final usableH = size.height - padTop - 2;

    double yFor(int v) {
      if (maxV <= 0) return size.height - 2; // honest flat baseline
      return padTop + usableH * (1 - v / maxV);
    }

    final line = Path();
    final fill = Path();
    for (var i = 0; i < n; i++) {
      final x = n > 1 ? dx * i : size.width / 2;
      final y = yFor(pts[i].value);
      if (i == 0) {
        line.moveTo(x, y);
        fill.moveTo(x, size.height);
        fill.lineTo(x, y);
      } else {
        line.lineTo(x, y);
        fill.lineTo(x, y);
      }
    }
    fill.lineTo(n > 1 ? size.width : size.width / 2, size.height);
    fill.close();

    canvas.drawPath(
      fill,
      Paint()
        ..style = PaintingStyle.fill
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.22), color.withValues(alpha: 0.0)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _SparkPainter old) =>
      old.pts != pts || old.color != color;
}

/// A funnel rendered as proportional horizontal bars (viewed -> started ->
/// paid). Each stage's width is relative to the first (largest) stage; a
/// zero-top funnel renders empty bars with the real "0" labels the caller
/// supplies — no invented proportions.
class FunnelBars extends StatelessWidget {
  /// Ordered stages: (localised label, count, localised value string).
  final List<FunnelStage> stages;
  const FunnelBars({super.key, required this.stages});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final top = stages.isEmpty
        ? 0
        : stages.map((s) => s.count).fold<int>(0, (m, v) => v > m ? v : m);
    return Column(
      children: [
        for (var i = 0; i < stages.length; i++) ...[
          if (i > 0) const SizedBox(height: Gap.sm),
          _FunnelRow(
            stage: stages[i],
            frac: top > 0 ? stages[i].count / top : 0,
            tint: Color.lerp(Brand.cyan, Brand.purple,
                stages.length > 1 ? i / (stages.length - 1) : 0)!,
            scheme: scheme,
          ),
        ],
      ],
    );
  }
}

class FunnelStage {
  final String label;
  final int count;
  final String valueText;
  const FunnelStage(this.label, this.count, this.valueText);
}

class _FunnelRow extends StatelessWidget {
  final FunnelStage stage;
  final double frac;
  final Color tint;
  final ColorScheme scheme;
  const _FunnelRow({
    required this.stage,
    required this.frac,
    required this.tint,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '${stage.label}: ${stage.valueText}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  stage.label,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 13),
                ),
              ),
              Text(
                stage.valueText,
                style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                    fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(Radii.sm),
            child: Stack(
              children: [
                Container(
                  height: 14,
                  color: scheme.surfaceContainerHighest,
                ),
                FractionallySizedBox(
                  // Always show a sliver when count > 0 so a tiny stage is
                  // still visible; truly-zero stages stay empty (honest).
                  widthFactor: stage.count > 0
                      ? (frac < 0.04 ? 0.04 : frac)
                      : 0.0,
                  child: Container(
                    height: 14,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [tint, tint.withValues(alpha: 0.75)],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A horizontal segmented bar comparing plan paid-user counts (revenue plan
/// breakdown). Proportional to counts; renders nothing if there are no paid
/// users (the caller shows a "no data" state instead).
class PlanBreakdownBar extends StatelessWidget {
  /// (localised plan label, paid users, localised count text).
  final List<PlanSlice> slices;
  const PlanBreakdownBar({super.key, required this.slices});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total =
        slices.fold<int>(0, (s, p) => s + (p.users > 0 ? p.users : 0));
    if (total <= 0) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(Radii.sm),
          child: Row(
            children: [
              for (var i = 0; i < slices.length; i++)
                if (slices[i].users > 0)
                  Expanded(
                    flex: slices[i].users,
                    child: Container(
                      height: 16,
                      color: Color.lerp(Brand.blue, Brand.purple,
                          slices.length > 1 ? i / (slices.length - 1) : 0),
                    ),
                  ),
            ],
          ),
        ),
        const SizedBox(height: Gap.sm),
        Wrap(
          spacing: Gap.md,
          runSpacing: Gap.xs,
          children: [
            for (var i = 0; i < slices.length; i++)
              _Legend(
                color: Color.lerp(Brand.blue, Brand.purple,
                    slices.length > 1 ? i / (slices.length - 1) : 0)!,
                label: slices[i].label,
                value: slices[i].countText,
                scheme: scheme,
              ),
          ],
        ),
      ],
    );
  }
}

class PlanSlice {
  final String label;
  final int users;
  final String countText;
  const PlanSlice(this.label, this.users, this.countText);
}

class _Legend extends StatelessWidget {
  final Color color;
  final String label;
  final String value;
  final ColorScheme scheme;
  const _Legend({
    required this.color,
    required this.label,
    required this.value,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: Gap.xs),
        Text(label,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
        const SizedBox(width: Gap.xs),
        Text(value,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
      ],
    );
  }
}

/// A row of selectable date-range chips (All / 7d / 30d / 90d, etc.). The chip
/// labels are passed in already-localised; the chart filters a trailing window
/// client-side over the backend's own daily series, so no number is invented.
class RangeChips extends StatelessWidget {
  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  const RangeChips({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: Gap.sm,
      children: [
        for (var i = 0; i < labels.length; i++)
          ChoiceChip(
            label: Text(labels[i]),
            selected: i == selectedIndex,
            onSelected: (_) => onSelected(i),
          ),
      ],
    );
  }
}
