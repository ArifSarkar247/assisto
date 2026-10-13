import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// One upcoming birthday / memorable day: name, kind, days-until, next date and
/// (when known) the turning age. Actions: generate a wish DRAFT, or delete.
class HealthBirthdayCard extends StatelessWidget {
  final Map<String, dynamic> occasion;
  final VoidCallback onWish;
  final VoidCallback onDelete;
  const HealthBirthdayCard({
    super.key,
    required this.occasion,
    required this.onWish,
    required this.onDelete,
  });

  IconData _icon(String kind) {
    switch (kind) {
      case 'anniversary':
        return Icons.favorite_outline;
      case 'death_anniversary':
        return Icons.local_florist_outlined;
      case 'memorable':
        return Icons.star_outline;
      default:
        return Icons.cake_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final name = (occasion['name'] ?? '').toString();
    final kind = (occasion['kind'] ?? 'birthday').toString();
    final kindLabel = (occasion['kind_label'] ?? '').toString();
    final daysUntil = (occasion['days_until'] is int) ? occasion['days_until'] as int : null;
    final nextDate = (occasion['next_date'] ?? '').toString();
    final age = occasion['turning_age'];

    final String when;
    if (daysUntil == null) {
      when = nextDate;
    } else if (daysUntil <= 0) {
      when = t.birthdayToday;
    } else if (daysUntil == 1) {
      when = t.birthdayTomorrow;
    } else {
      when = t.birthdayInDays(daysUntil);
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Row(children: [
          CircleAvatar(
            backgroundColor: scheme.primaryContainer,
            child: Icon(_icon(kind), color: scheme.onPrimaryContainer),
          ),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 2),
              Text(
                [
                  if (kindLabel.isNotEmpty) kindLabel,
                  when,
                  if (age is int) t.birthdayTurningAge(age),
                ].join(' · '),
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ]),
          ),
          IconButton(
            tooltip: t.birthdayWishAction,
            icon: const Icon(Icons.mail_outline),
            color: scheme.primary,
            onPressed: onWish,
          ),
          IconButton(
            tooltip: t.delete,
            icon: const Icon(Icons.delete_outline),
            color: scheme.error,
            onPressed: onDelete,
          ),
        ]),
      ),
    );
  }
}
