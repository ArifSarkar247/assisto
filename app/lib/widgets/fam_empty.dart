import 'package:flutter/material.dart';

import '../theme.dart';
import 'fam_sharing_strings.dart' show famNum;

/// famcare (owner real-phone review 28 Oct): EVERY empty Family Care tab
/// shows the same honest shape — one line saying what the family gains, a
/// big primary button that does the first real step, an optional second
/// action, and a short numbered how-to. Scrolls at 200% text; 56dp button.
class FamEmptyState extends StatelessWidget {
  const FamEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.benefit,
    required this.primaryLabel,
    required this.onPrimary,
    this.primaryIcon = Icons.add_rounded,
    this.steps = const [],
    this.secondaryLabel,
    this.onSecondary,
    this.header,
  });

  final IconData icon;
  final String title;
  final String benefit;
  final String primaryLabel;
  final IconData primaryIcon;
  final VoidCallback? onPrimary;
  final List<String> steps;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  /// Optional widget above the state (e.g. the Family tab's alerts entry).
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      key: const ValueKey('fam-empty'),
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl),
      children: [
        if (header != null) header!,
        const SizedBox(height: Gap.lg),
        Center(
          child: Container(
            height: 72,
            width: 72,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 34, color: scheme.primary),
          ),
        ),
        const SizedBox(height: Gap.lg),
        Text(title,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.sm),
        Text(benefit,
            key: const ValueKey('fam-empty-benefit'),
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodyLarge
                ?.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.xl),
        SizedBox(
          height: 56,
          child: FilledButton.icon(
            key: const ValueKey('fam-empty-primary'),
            onPressed: onPrimary,
            icon: Icon(primaryIcon),
            label: Text(primaryLabel,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
        ),
        if (secondaryLabel != null && onSecondary != null) ...[
          const SizedBox(height: Gap.sm),
          SizedBox(
            height: 48,
            child: OutlinedButton(
              key: const ValueKey('fam-empty-secondary'),
              onPressed: onSecondary,
              child: Text(secondaryLabel!, textAlign: TextAlign.center),
            ),
          ),
        ],
        if (steps.isNotEmpty) ...[
          const SizedBox(height: Gap.xl),
          Card(
            color: scheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (var i = 0; i < steps.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: Gap.xs),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      CircleAvatar(
                        radius: 12,
                        backgroundColor: scheme.primary,
                        child: Text(famNum(context, i + 1),
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: scheme.onPrimary)),
                      ),
                      const SizedBox(width: Gap.sm),
                      Expanded(child: Text(steps[i])),
                    ]),
                  ),
              ]),
            ),
          ),
        ],
      ],
    );
  }
}

/// Bangla digits inside any string under bn (dates, phone numbers, times).
String famDigits(BuildContext c, String s) {
  if (Localizations.localeOf(c).languageCode != 'bn') return s;
  final b = StringBuffer();
  for (final r in s.runes) {
    b.writeCharCode(r >= 0x30 && r <= 0x39 ? 0x09E6 + (r - 0x30) : r);
  }
  return b.toString();
}

/// "12 Nov 2026"-style short date, localized digits; '' for null.
String famDate(BuildContext c, DateTime? d) {
  if (d == null) return '';
  final l = MaterialLocalizations.of(c);
  return famDigits(c, l.formatMediumDate(d));
}
