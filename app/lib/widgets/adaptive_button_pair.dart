import 'package:flutter/material.dart';

/// Two equal buttons side by side — stacked full-width when the user's font
/// size is large (QA a6: side-by-side pills wrapped to 2–3 lines and the label
/// spilled past the border at 1.3–1.6x text). Pure layout, no state.
class AdaptiveButtonPair extends StatelessWidget {
  const AdaptiveButtonPair({
    super.key,
    required this.first,
    required this.second,
    this.gap = 8,
    this.stackAbove = 1.15,
  });

  final Widget first;
  final Widget second;
  final double gap;

  /// Text-scale factor above which the pair is stacked.
  final double stackAbove;

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    if (scale > stackAbove) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [first, SizedBox(height: gap), second],
      );
    }
    return Row(children: [
      Expanded(child: first),
      SizedBox(width: gap),
      Expanded(child: second),
    ]);
  }
}
