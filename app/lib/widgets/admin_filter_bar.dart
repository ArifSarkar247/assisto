import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// Shared OWNER-ADMIN list controls (SPEC v2.1 §21 — #174 users, #175
/// moderation queue). Advanced list surfaces need more than a single filter
/// row: a scrollable filter-chip rail, a bottom-sheet sort picker, and an
/// honest result-count header that doubles as the "N results" summary. These
/// are factored here so both admin screens share one implementation and stay
/// visually identical. Original Assisto identity; every human string resolves
/// through [AppLocalizations] (zero Bangla in source).

/// One selectable option (filter value or sort key) with a localized label and
/// optional leading icon.
class AdminChoice {
  final String value;
  final String label;
  final IconData? icon;
  const AdminChoice(this.value, this.label, {this.icon});
}

/// Horizontal chip rail for the list filters. Keeps a consistent height and
/// padding so the two admin screens line up pixel-for-pixel.
class AdminFilterRail extends StatelessWidget {
  final List<AdminChoice> choices;
  final String selected;
  final ValueChanged<String> onSelected;
  const AdminFilterRail({
    super.key,
    required this.choices,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
        children: [
          for (final c in choices)
            Padding(
              padding: const EdgeInsets.only(right: Gap.sm),
              child: ChoiceChip(
                avatar: c.icon == null
                    ? null
                    : Icon(c.icon,
                        size: 16,
                        color: selected == c.value
                            ? Theme.of(context).colorScheme.onSecondaryContainer
                            : Theme.of(context).colorScheme.onSurfaceVariant),
                label: Text(c.label),
                selected: selected == c.value,
                onSelected: (_) => onSelected(c.value),
              ),
            ),
        ],
      ),
    );
  }
}

/// A result-count header with a trailing "Sort" button. Shows the honest count
/// ("N results") and the current sort label so the admin always knows what
/// ordering they're looking at. [onSort] opens [AdminSortSheet].
class AdminListHeader extends StatelessWidget {
  final String countLabel;
  final String sortLabel;
  final VoidCallback onSort;
  const AdminListHeader({
    super.key,
    required this.countLabel,
    required this.sortLabel,
    required this.onSort,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.sm, Gap.sm),
      child: Row(
        children: [
          Expanded(
            child: Text(
              countLabel,
              style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                  fontSize: 13),
            ),
          ),
          TextButton.icon(
            onPressed: onSort,
            icon: const Icon(Icons.swap_vert_rounded, size: 18),
            label: Text(sortLabel),
          ),
        ],
      ),
    );
  }
}

/// Bottom-sheet single-choice sort picker. Returns the chosen value, or null if
/// dismissed. Reused by both admin list screens.
class AdminSortSheet {
  static Future<String?> show(
    BuildContext context, {
    required String title,
    required List<AdminChoice> options,
    required String selected,
  }) {
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
                child: Text(title,
                    style: Theme.of(ctx)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w800)),
              ),
              for (final o in options)
                RadioListTile<String>(
                  value: o.value,
                  groupValue: selected,
                  secondary: o.icon == null ? null : Icon(o.icon),
                  title: Text(o.label),
                  onChanged: (v) => Navigator.of(ctx).pop(v),
                ),
              const SizedBox(height: Gap.sm),
            ],
          ),
        );
      },
    );
  }
}
