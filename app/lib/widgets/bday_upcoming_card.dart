import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import 'bday_model.dart';
import 'ladder_common.dart';

/// One upcoming occasion (ADVANCED). Shows kind + name + relation, when it is
/// (today / tomorrow / in N days, with Bangla digits via [bNum]), the turning
/// age / years, a "this week" highlight ring + badge, a "linked in Circle"
/// chip, and three actions: send a wish (one-tap), edit, delete.
///
/// Larger tap targets + an accessible tooltip on every icon button keep it
/// WCAG-friendly; the highlight uses primaryContainer (not colour alone) so it
/// reads for low-vision users.
class BdayUpcomingCard extends StatelessWidget {
  final Map<String, dynamic> occasion;
  final VoidCallback onWish;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  const BdayUpcomingCard({
    super.key,
    required this.occasion,
    required this.onWish,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final name = (occasion['name'] ?? '').toString();
    final kind = (occasion['kind'] ?? 'birthday').toString();
    final kindLabel = (occasion['kind_label'] ?? '').toString();
    final relation = (occasion['relation'] ?? '').toString();
    final linked = occasion['linked_contact_id'] != null ||
        occasion['linked_user_id'] != null;
    final thisWeek = occasion['this_week'] == true;

    // days_until: prefer the server value; fall back to a local computation so
    // cached/offline rows still read correctly.
    int? daysUntil =
        (occasion['days_until'] is int) ? occasion['days_until'] as int : null;
    daysUntil ??= bDaysUntil(occasion['date']?.toString());
    final age = occasion['turning_age'];

    final String when;
    if (daysUntil == null) {
      when = (occasion['next_date'] ?? '').toString();
    } else if (daysUntil <= 0) {
      when = t.birthdayToday;
    } else if (daysUntil == 1) {
      when = t.birthdayTomorrow;
    } else {
      when = t.birthdayInDays(fmtInt(context, daysUntil));
    }

    final subtitleParts = <String>[
      if (kindLabel.isNotEmpty) kindLabel,
      when,
      if (age is int) t.birthdayTurningAge(fmtInt(context, age)),
    ];

    final card = Card(
      // highlight "this week" with a tinted container + accent border (not
      // colour alone — also a badge below), keeping WCAG contrast.
      color: thisWeek ? scheme.primaryContainer.withValues(alpha: 0.35) : null,
      shape: thisWeek
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: scheme.primary, width: 1.2),
            )
          : null,
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Row(children: [
          CircleAvatar(
            backgroundColor: scheme.primaryContainer,
            child: Icon(bKindIcon(kind), color: scheme.onPrimaryContainer),
          ),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(
                      child: Text(name,
                          style: Theme.of(context).textTheme.titleMedium,
                          overflow: TextOverflow.ellipsis),
                    ),
                    if (relation.isNotEmpty) ...[
                      const SizedBox(width: Gap.sm),
                      _Pill(text: relation, scheme: scheme),
                    ],
                  ]),
                  const SizedBox(height: 2),
                  Text(
                    subtitleParts.join(' · '),
                    style: TextStyle(
                        fontSize: 12.5, color: scheme.onSurfaceVariant),
                  ),
                  if (thisWeek || linked) ...[
                    const SizedBox(height: Gap.xs),
                    Wrap(spacing: Gap.xs, runSpacing: Gap.xs, children: [
                      if (thisWeek)
                        _Badge(
                          icon: Icons.local_fire_department_outlined,
                          text: bStr(context, 'bThisWeek'),
                          fg: scheme.onPrimary,
                          bg: scheme.primary,
                        ),
                      if (linked)
                        _Badge(
                          icon: Icons.link,
                          text: bStr(context, 'bLinked'),
                          fg: scheme.onSecondaryContainer,
                          bg: scheme.secondaryContainer,
                        ),
                    ]),
                  ],
                ]),
          ),
          IconButton(
            tooltip: t.birthdayWishAction,
            icon: const Icon(Icons.mail_outline),
            color: scheme.primary,
            onPressed: onWish,
          ),
          // qa1: three icon buttons squeezed the subtitle into 2-word lines
          // at 360dp; edit + delete move into one overflow menu.
          PopupMenuButton<String>(
            tooltip: MaterialLocalizations.of(context).showMenuTooltip,
            onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
            itemBuilder: (_) => [
              PopupMenuItem(
                  value: 'edit',
                  child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.edit_outlined),
                      title: Text(bStr(context, 'bEdit')))),
              PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.delete_outline, color: scheme.error),
                      title: Text(t.delete))),
            ],
          ),
        ]),
      ),
    );
    return Semantics(
      container: true,
      label: '$name, ${subtitleParts.join(', ')}',
      child: card,
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final ColorScheme scheme;
  const _Pill({required this.text, required this.scheme});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text,
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
    );
  }
}

class _Badge extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color fg;
  final Color bg;
  const _Badge(
      {required this.icon,
      required this.text,
      required this.fg,
      required this.bg});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13, color: fg),
        const SizedBox(width: 4),
        Text(text,
            style: TextStyle(
                fontSize: 11, color: fg, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}
