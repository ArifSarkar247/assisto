import 'package:flutter/material.dart';

/// qa2 — the 30-day Ramadan grid (calendar + fasting tracker).
///
/// A 7-column grid cannot give each day a 48dp target on a 360dp phone, so
/// the grid uses 6 columns (30 days = 5 clean rows) and drops to 5 columns
/// (6 rows) when even 6 would go under 48dp. Cells stretch to fill the row, so
/// the grid is always edge-to-edge aligned with the card text above it.
/// Rows are 48dp tall (the target height) so the card does not grow tall.
class RamadanDayGrid extends StatelessWidget {
  const RamadanDayGrid({
    super.key,
    required this.count,
    required this.cell,
    this.gap = 6,
  });

  final int count;
  final double gap;

  /// Builds day [n] (1-based); [size] is the cell width.
  final Widget Function(BuildContext context, int n, double size) cell;

  static const double minTarget = 48;

  /// Columns for [width]: 6 when each cell stays >= 48dp, else 5, else fewer.
  static int columnsFor(double width, {double gap = 6}) {
    for (final c in const [6, 5, 4, 3]) {
      if ((width - gap * (c - 1)) / c >= minTarget) return c;
    }
    return 2;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      final cols = columnsFor(w, gap: gap);
      final size = (w - gap * (cols - 1)) / cols;
      final rows = (count + cols - 1) ~/ cols;
      // Rows of Expanded cells: exactly edge-to-edge (a Wrap of floored
      // widths left a ragged right margin).
      return Column(children: [
        for (var r = 0; r < rows; r++) ...[
          if (r > 0) SizedBox(height: gap),
          SizedBox(
            height: minTarget,
            child: Row(children: [
              for (var c = 0; c < cols; c++) ...[
                if (c > 0) SizedBox(width: gap),
                Expanded(
                  child: r * cols + c < count
                      ? cell(context, r * cols + c + 1, size)
                      : const SizedBox.shrink(),
                ),
              ],
            ]),
          ),
        ],
      ]);
    });
  }
}
