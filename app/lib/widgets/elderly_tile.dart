import 'package:flutter/material.dart';

/// SPEC v2.1 feature 29 — a single large, high-contrast ACTION TILE for the
/// elderly simple-mode home.
///
/// Design (benchmarked against senior launchers — Big Launcher, GrandPad,
/// Jitterbug): one clear job per tile, a large glyph, a short label, generous
/// padding, a minimum 96dp tappable height (well over the 56dp floor), a thick
/// focus/border for low-vision users, and a strong solid colour chosen for
/// WCAG AAA contrast against white text (>= 7:1 for the body text sizes used).
///
/// No strings are hard-coded here; the caller passes a localized [label] and an
/// optional [sublabel]. No Bangla literals (language gate — this file holds no
/// user-facing text at all).
class ElderlyTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? sublabel;
  final Color color;
  final VoidCallback onTap;

  /// When true the tile spans the full row (used for SOS). Otherwise it sits in
  /// a 2-up grid.
  final bool wide;

  const ElderlyTile({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.sublabel,
    this.wide = false,
  });

  @override
  Widget build(BuildContext context) {
    // AAA-sized text: title >= 24sp, sublabel >= 18sp, white on a dark solid.
    return Semantics(
      button: true,
      label: sublabel == null ? label : '$label. $sublabel',
      child: Material(
        color: color,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            constraints: BoxConstraints(minHeight: wide ? 110 : 150),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.9), width: 2),
            ),
            child: wide ? _wideBody() : _tallBody(),
          ),
        ),
      ),
    );
  }

  Widget _tallBody() => Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 52, color: Colors.white),
          const SizedBox(height: 12),
          // scaleDown keeps the text as large as possible but never clips —
          // critical for low-vision elderly users (no "…" truncation).
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(label,
                  maxLines: 1,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      height: 1.15)),
            ),
          ),
          if (sublabel != null) ...[
            const SizedBox(height: 4),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(sublabel!,
                    maxLines: 1,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 18, height: 1.2)),
              ),
            ),
          ],
        ],
      );

  Widget _wideBody() => Row(
        children: [
          Icon(icon, size: 56, color: Colors.white),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        height: 1.1)),
                if (sublabel != null) ...[
                  const SizedBox(height: 4),
                  Text(sublabel!,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 18, height: 1.2)),
                ],
              ],
            ),
          ),
          const Icon(Icons.chevron_right, size: 40, color: Colors.white),
        ],
      );
}
