import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import 'ladder_common.dart';

/// Presentation atoms for the Payment / Auto-pay Ladder module. Pure widgets —
/// no state, no network, no money ever moved. WCAG: semantic colours kept at
/// AA contrast via `onX` pairs; text never clipped (wraps, ellipsis only on the
/// single-line party name with a visible full value in the detail sheet).

/// The top hero: total owed to you / you owe, and the net position.
class LadderHero extends StatelessWidget {
  final String kind;
  final int outstandingPoisha;
  final int actionCount;
  const LadderHero({
    super.key,
    required this.kind,
    required this.outstandingPoisha,
    required this.actionCount,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final receivable = kind == kKindReceivable;
    final tint = receivable ? Brand.success : Brand.warning;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(receivable ? t.plHeroReceivable : t.plHeroPayable,
                style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: Gap.xs),
            Text(taka(context, outstandingPoisha),
                style: Theme.of(context)
                    .textTheme
                    .headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w800, color: tint)),
            const SizedBox(height: Gap.sm),
            Row(children: [
              Icon(Icons.bolt, size: 18, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: Gap.xs),
              Expanded(
                child: Text(
                  actionCount > 0
                      ? t.plActionDueCount(fmtInt(context, actionCount))
                      : t.plNoActionDue,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

/// The honest "we never hold money / never auto-charge" banner.
class LadderNoMoneyBanner extends StatelessWidget {
  const LadderNoMoneyBanner({super.key});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: cs.secondaryContainer,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(children: [
        Icon(Icons.verified_user_outlined, color: cs.onSecondaryContainer),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Text(t.plNoMoneyBanner,
              style: TextStyle(color: cs.onSecondaryContainer, height: 1.35)),
        ),
      ]),
    );
  }
}

/// A section header row (icon + title).
class LadderSection extends StatelessWidget {
  final IconData icon;
  final String title;
  final Color? tint;
  const LadderSection({super.key, required this.icon, required this.title, this.tint});
  @override
  Widget build(BuildContext context) {
    final c = tint ?? Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.lg, Gap.xs, Gap.sm),
      child: Row(children: [
        Icon(icon, size: 20, color: c),
        const SizedBox(width: Gap.sm),
        Text(title,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
      ]),
    );
  }
}

/// One row inside the step timeline — an icon, the step action + channel, its
/// timing, and a status chip (past / now / upcoming).
class LadderStepRow extends StatelessWidget {
  final Map<String, dynamic> step; // from scheduleOf()
  const LadderStepRow({super.key, required this.step});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final action = '${step['action']}';
    final status = '${step['status']}';
    final tint = actionTint(action);
    final cs = Theme.of(context).colorScheme;
    final (badge, badgeColor) = switch (status) {
      'due' => (t.plStepDueBadge, Brand.danger),
      'past' => (t.plStepPast, cs.outline),
      _ => (t.plStepUpcoming, cs.primary),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(children: [
        CircleAvatar(
          radius: 16,
          backgroundColor: tint.withValues(alpha: 0.16),
          child: Icon(actionIcon(action), size: 18, color: tint),
        ),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(actionLabel(t, action),
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Row(children: [
              Icon(channelIcon('${step['channel']}'),
                  size: 13, color: cs.onSurfaceVariant),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  '${channelLabel(t, '${step['channel']}')}  •  ${offsetLabel(t, context, step['offset_days'] as int)}',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                ),
              ),
            ]),
          ]),
        ),
        _StatusChip(label: badge, color: badgeColor),
      ]),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String label;
  final Color color;
  const _StatusChip({required this.label, required this.color});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Text(label,
          style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700)),
    );
  }
}

/// A debt card: party, outstanding amount, the current due action (if any) with
/// a "Do this step" button, and quick actions (mark paid / snooze / edit).
class LadderDebtCard extends StatelessWidget {
  final Map<String, dynamic> debt;
  final Map<String, dynamic> ladder;
  final Map<String, dynamic>? due; // dueStep() result, or null
  final Map<String, dynamic>? upcoming; // nextStep() result, or null
  final VoidCallback onTap;
  final VoidCallback onDoStep;
  final VoidCallback onMarkPaid;
  final VoidCallback onTogglePause;
  const LadderDebtCard({
    super.key,
    required this.debt,
    required this.ladder,
    required this.due,
    required this.upcoming,
    required this.onTap,
    required this.onDoStep,
    required this.onMarkPaid,
    required this.onTogglePause,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final party = '${debt['party'] ?? ''}';
    final tint = partyColor(party);
    final paused = debt['paused'] == true;
    final paid = isPaid(debt);

    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.md),
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: tint.withValues(alpha: 0.16),
                child: Text(
                  party.isNotEmpty ? party.characters.first.toUpperCase() : '?',
                  style: TextStyle(color: tint, fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(party,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                  const SizedBox(height: 2),
                  Text(t.plOutstanding(taka(context, outstandingPoisha(debt))),
                      style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
                ]),
              ),
              if (paused)
                _StatusChip(label: t.plPaused, color: cs.outline)
              else if (paid)
                _StatusChip(label: t.plStepPast, color: Brand.success)
              else if (due != null)
                _StatusChip(label: t.plStepDueBadge, color: Brand.danger),
            ]),
            if (!paid && due != null) ...[
              const SizedBox(height: Gap.md),
              Container(
                padding: const EdgeInsets.all(Gap.sm),
                decoration: BoxDecoration(
                  color: actionTint('${due!['action']}').withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: Row(children: [
                  Icon(actionIcon('${due!['action']}'),
                      size: 18, color: actionTint('${due!['action']}')),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Text(
                      '${t.plStepN(fmtInt(context, due!['step'] as int))}  •  ${actionLabel(t, '${due!['action']}')}',
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                  ),
                  FilledButton.tonal(
                    onPressed: onDoStep,
                    style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                        visualDensity: VisualDensity.compact),
                    child: Text(t.plDoAction),
                  ),
                ]),
              ),
            ] else if (!paid && upcoming != null) ...[
              const SizedBox(height: Gap.sm),
              Row(children: [
                Icon(Icons.schedule, size: 15, color: cs.onSurfaceVariant),
                const SizedBox(width: Gap.xs),
                Text(t.plNextIn(fmtInt(context, upcoming!['days_until'] as int)),
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
              ]),
            ],
            const SizedBox(height: Gap.sm),
            Row(children: [
              if (!paid)
                TextButton.icon(
                  onPressed: onMarkPaid,
                  icon: const Icon(Icons.check_circle_outline, size: 18),
                  label: Text(t.plMarkPaid),
                ),
              if (!paid)
                TextButton.icon(
                  onPressed: onTogglePause,
                  icon: Icon(paused ? Icons.play_arrow : Icons.snooze, size: 18),
                  label: Text(paused ? t.plResume : t.plPause),
                ),
            ]),
          ]),
        ),
      ),
    );
  }
}
