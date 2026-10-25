import 'package:flutter/material.dart';

/// Big, unmistakable in-app SOS button (item 7). This works NOW — tapping it
/// opens the SOS flow immediately. The discreet native triggers (power-button
/// x5, shake, lock-screen tile, hidden widget) are platform work and are
/// surfaced as clearly-gated "Available when ___" rows elsewhere; this on-screen
/// button is the always-available path.
class SosButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  final bool compact;
  const SosButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFFC62828),
          foregroundColor: Colors.white,
          padding: EdgeInsets.symmetric(vertical: compact ? 14 : 20),
        ),
        onPressed: onPressed,
        icon: Icon(Icons.sos_rounded, size: compact ? 22 : 28),
        label: Text(label,
            style: TextStyle(
                fontSize: compact ? 16 : 20, fontWeight: FontWeight.bold)),
      ),
    );
  }
}
