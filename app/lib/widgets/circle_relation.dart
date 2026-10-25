import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// Relationship vocabulary for the Connected Circle (mirrors
/// core/logic/circle.py RELATIONS). Machine `code` is ASCII and stored; the
/// label is localized via AppLocalizations so no Bangla literal lives in Dart.
class CircleRelation {
  final String code;
  final IconData icon;
  final String Function(AppLocalizations t) label;
  const CircleRelation(this.code, this.icon, this.label);

  /// Picker order matching core.logic.circle.relation_catalog().
  static final List<CircleRelation> catalog = [
    CircleRelation('father', Icons.man_rounded, (t) => t.circleRelFather),
    CircleRelation('mother', Icons.woman_rounded, (t) => t.circleRelMother),
    CircleRelation('child', Icons.child_care_rounded, (t) => t.circleRelChild),
    CircleRelation('husband', Icons.favorite_outline_rounded, (t) => t.circleRelHusband),
    CircleRelation('wife', Icons.favorite_outline_rounded, (t) => t.circleRelWife),
    CircleRelation('brother', Icons.people_outline_rounded, (t) => t.circleRelBrother),
    CircleRelation('sister', Icons.people_outline_rounded, (t) => t.circleRelSister),
    CircleRelation('relative', Icons.diversity_3_rounded, (t) => t.circleRelRelative),
    CircleRelation('friend', Icons.group_rounded, (t) => t.circleRelFriend),
    CircleRelation('colleague', Icons.badge_rounded, (t) => t.circleRelColleague),
    CircleRelation('custom', Icons.edit_rounded, (t) => t.circleRelCustom),
  ];

  static CircleRelation byCode(String code) => catalog.firstWhere(
        (r) => r.code == code,
        orElse: () => catalog.last, // custom
      );

  /// Localized label for any code, honouring a user-typed custom label.
  static String labelFor(AppLocalizations t, String code, {String? custom}) {
    if (code == 'custom' && (custom ?? '').trim().isNotEmpty) {
      return custom!.trim();
    }
    return byCode(code).label(t);
  }
}

/// A grid of relation choices. Returns the chosen code (+ custom text) via
/// [onSelected]. Used in the "add to circle" flow.
class CircleRelationPicker extends StatelessWidget {
  final String? selected;
  final ValueChanged<String> onSelected;
  const CircleRelationPicker({super.key, this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: Gap.sm,
      runSpacing: Gap.sm,
      children: [
        for (final r in CircleRelation.catalog)
          ChoiceChip(
            avatar: Icon(r.icon,
                size: 18,
                color: selected == r.code
                    ? scheme.onSecondaryContainer
                    : scheme.onSurfaceVariant),
            label: Text(r.label(t)),
            selected: selected == r.code,
            onSelected: (_) => onSelected(r.code),
          ),
      ],
    );
  }
}
