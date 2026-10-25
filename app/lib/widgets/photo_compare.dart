import '../l10n/app_localizations.dart';
// Photo Enhance (ADVANCED, SPEC §21) — before/after compare widget.
//
// Two honest modes over ONE source image:
//  - a draggable split slider (left = original, right = adjusted), and
//  - press-&-hold anywhere to momentarily reveal the full original.
// The "adjusted" side is the SAME pixels rendered through the live
// ColorFiltered/Transform pipeline the editor uses — never a fabricated or
// AI-invented image. Fully keyboard/screen-reader labelled.
import 'package:flutter/material.dart';

class PhotoCompare extends StatefulWidget {
  const PhotoCompare({
    super.key,
    required this.original,
    required this.adjusted,
    this.height = 240,
  });

  /// The untouched source (what the user picked).
  final Widget original;

  /// The same image with the current faithful adjustments applied.
  final Widget adjusted;
  final double height;

  @override
  State<PhotoCompare> createState() => _PhotoCompareState();
}

class _PhotoCompareState extends State<PhotoCompare> {
  double _split = 0.5; // 0 = all original, 1 = all adjusted
  bool _holding = false; // press-and-hold reveals the full original

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          label: AppLocalizations.of(context).phHeadCompare,
          child: LayoutBuilder(builder: (context, c) {
            final w = c.maxWidth;
            final effective = _holding ? 0.0 : _split;
            return GestureDetector(
              onTapDown: (_) => setState(() => _holding = true),
              onTapUp: (_) => setState(() => _holding = false),
              onTapCancel: () => setState(() => _holding = false),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  height: widget.height,
                  width: w,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Adjusted fills the whole area…
                      widget.adjusted,
                      // …and the original is clipped to the left portion.
                      ClipRect(
                        clipper: _LeftClipper(effective * w),
                        child: widget.original,
                      ),
                      // Divider handle (hidden while holding).
                      if (!_holding)
                        Positioned(
                          left: (effective * w) - 1,
                          top: 0,
                          bottom: 0,
                          child: Container(width: 2, color: scheme.primary),
                        ),
                      // Corner labels (text + icon, not colour alone).
                      Positioned(
                        left: 8,
                        top: 8,
                        child: _tag(context, AppLocalizations.of(context).phBefore,
                            scheme, Icons.history_rounded),
                      ),
                      Positioned(
                        right: 8,
                        top: 8,
                        child: _tag(context, AppLocalizations.of(context).phAfter,
                            scheme, Icons.auto_fix_high_rounded),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 6),
        Row(children: [
          Icon(Icons.compare_rounded,
              size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${AppLocalizations.of(context).phSlideToCompare} · ${AppLocalizations.of(context).phHoldToCompare}',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
        ]),
        Slider(
          value: _split,
          onChanged: _holding ? null : (v) => setState(() => _split = v),
          label: AppLocalizations.of(context).phHeadCompare,
        ),
      ],
    );
  }

  Widget _tag(
      BuildContext context, String text, ColorScheme scheme, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        // High-contrast chip (WCAG): dark scrim + light text in both themes.
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13, color: Colors.white),
        const SizedBox(width: 4),
        Text(text,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

/// Clips to the left [width] pixels so the original peeks through.
class _LeftClipper extends CustomClipper<Rect> {
  _LeftClipper(this.width);
  final double width;
  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, width.clamp(0, size.width), size.height);
  @override
  bool shouldReclip(_LeftClipper old) => old.width != width;
}
