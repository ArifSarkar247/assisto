import 'package:flutter/material.dart';
import '../theme.dart';

/// Shared presentational widgets for the ADVANCED quote + AFTER-SALE screens.
/// Pure UI; no strings baked in (all copy is passed in, already localized by
/// the caller via AppLocalizations). Zero Bangla here.

/// A coloured status pill. `tone` picks a WCAG-safe fg/bg pair.
enum CrmStatusTone { neutral, info, success, warning, danger }

class CrmStatusPill extends StatelessWidget {
  final String label;
  final CrmStatusTone tone;
  const CrmStatusPill(this.label, {super.key, this.tone = CrmStatusTone.neutral});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Color bg;
    Color fg;
    switch (tone) {
      case CrmStatusTone.success:
        bg = Brand.success;
        fg = Colors.white;
        break;
      case CrmStatusTone.warning:
        bg = Brand.warning;
        fg = Colors.white;
        break;
      case CrmStatusTone.danger:
        bg = Brand.danger;
        fg = Colors.white;
        break;
      case CrmStatusTone.info:
        bg = Brand.blue;
        fg = Colors.white;
        break;
      case CrmStatusTone.neutral:
        bg = scheme.surfaceContainerHighest;
        fg = scheme.onSurfaceVariant;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Text(label,
          style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 11)),
    );
  }
}

/// A key → value money/label row (spaceBetween). Bold the value for totals.
class CrmMoneyRow extends StatelessWidget {
  final String label;
  final String value;
  final bool bold;
  final Color? valueColor;
  const CrmMoneyRow(this.label, this.value,
      {super.key, this.bold = false, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Flexible(child: Text(label)),
        const SizedBox(width: Gap.sm),
        Text(value,
            style: TextStyle(
                fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
                color: valueColor)),
      ]),
    );
  }
}

/// A small section header for the after-sale cards.
class CrmSectionHeader extends StatelessWidget {
  final String title;
  final IconData? icon;
  const CrmSectionHeader(this.title, {super.key, this.icon});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: Gap.md, bottom: Gap.xs),
      child: Row(children: [
        if (icon != null) ...[
          Icon(icon, size: 18, color: scheme.primary),
          const SizedBox(width: Gap.xs),
        ],
        Text(title,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
      ]),
    );
  }
}

/// A linear progress bar for "collected of booked" — WCAG-safe colours.
class CrmProgressBar extends StatelessWidget {
  final double fraction; // 0..1
  final String caption;
  const CrmProgressBar(this.fraction, this.caption, {super.key});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final f = fraction.clamp(0.0, 1.0);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: LinearProgressIndicator(
          value: f,
          minHeight: 10,
          backgroundColor: scheme.surfaceContainerHighest,
          valueColor: AlwaysStoppedAnimation(
              f >= 1.0 ? Brand.success : Brand.blue),
        ),
      ),
      const SizedBox(height: Gap.xs),
      Text(caption,
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
    ]);
  }
}
