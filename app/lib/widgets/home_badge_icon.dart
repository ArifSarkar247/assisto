import 'package:flutter/material.dart';
import '../theme.dart';

/// A top-bar [IconButton] with a small unread/unseen count bubble.
///
/// Rules (per owner):
///  - Bubble is HIDDEN when [count] <= 0.
///  - Counts above 99 render as "99+".
///  - Digits are composed from codepoints (U+0030..U+0039 / U+002B) so the
///    badge label is built in code with ZERO string literals — language and
///    script are irrelevant to a count.
class HomeBadgeIcon extends StatelessWidget {
  final IconData icon;
  final int count;
  final String tooltip;
  final VoidCallback onPressed;
  const HomeBadgeIcon({
    super.key,
    required this.icon,
    required this.count,
    required this.tooltip,
    required this.onPressed,
  });

  /// Build "0".."99" / "99+" from Unicode codepoints — no literal digits.
  static String _label(int n) {
    final capped = n > 99;
    final value = capped ? 99 : n;
    final buf = StringBuffer();
    for (final ch in value.toString().runes) {
      buf.writeCharCode(ch); // ASCII digit codepoints (U+0030..U+0039)
    }
    if (capped) buf.writeCharCode(0x2B); // '+'
    return buf.toString();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final button = IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon),
    );
    if (count <= 0) return button;
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        button,
        Positioned(
          top: 6,
          right: 4,
          child: Container(
            constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: scheme.error,
              borderRadius: BorderRadius.circular(Radii.pill),
              border: Border.all(color: scheme.surface, width: 1.5),
            ),
            child: Center(
              child: Text(
                _label(count),
                style: TextStyle(
                  color: scheme.onError,
                  fontSize: 10,
                  height: 1.0,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
