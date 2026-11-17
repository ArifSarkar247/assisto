import 'package:flutter/material.dart';
import '../theme.dart';
import '../ds/ds.dart';

/// One scrolling DS chip row whose end fades into the page, so a chip cut
/// at the edge reads as "scroll for more". The row grows with the font
/// (no fixed height). The fade is a plain gradient strip on top — no
/// ShaderMask / saveLayer (GPU-light on low-end phones).
class FadeChipRow extends StatelessWidget {
  const FadeChipRow({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
  });

  final List<Widget> children;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).colorScheme.ds.bg;
    return Stack(children: [
      DsChipRow(padding: padding, children: [...children, const SizedBox(width: Gap.lg)]),
      PositionedDirectional(
        end: 0,
        top: 0,
        bottom: 0,
        width: Gap.xl,
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: AlignmentDirectional.centerStart,
                end: AlignmentDirectional.centerEnd,
                colors: [bg.withValues(alpha: 0), bg],
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}
