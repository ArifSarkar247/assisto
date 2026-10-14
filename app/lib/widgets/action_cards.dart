import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import 'action_models.dart';

/// Presentation atoms for the Action Center (SPEC v2.1 §21, feature #9).
/// Pure widgets — no network, no Bangla literals (all copy via
/// `AppLocalizations`, emitted to `.phaseB/up_action_arb.json`).

final DateFormat _fmt = DateFormat('d MMM, h:mm a');

/// Transparency banner shown at the top of both tabs: "Assisto only acts
/// within your autonomy setting." Also states the current level so the promise
/// is concrete, with a tap target to open the autonomy dial in Settings.
class ActionTransparencyBanner extends StatelessWidget {
  final int autonomyLevel;
  final VoidCallback? onOpenAutonomy;
  const ActionTransparencyBanner({
    super.key,
    required this.autonomyLevel,
    this.onOpenAutonomy,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.sm),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: cs.primaryContainer,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.verified_user_outlined,
                  size: 18, color: cs.onPrimaryContainer),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(
                  t.actionTransparencyTitle,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: cs.onPrimaryContainer,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Gap.xs),
          Text(
            t.actionTransparencyBody(autonomyShort(t, autonomyLevel)),
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: cs.onPrimaryContainer,
            ),
          ),
          if (onOpenAutonomy != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: Gap.xs),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: onOpenAutonomy,
                child: Text(t.actionOpenAutonomy),
              ),
            ),
        ],
      ),
    );
  }
}

/// A single PENDING action awaiting approval, with Approve / Reject / Edit.
class PendingActionCard extends StatelessWidget {
  final PendingAction item;
  final bool busy;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onEdit;
  const PendingActionCard({
    super.key,
    required this.item,
    required this.busy,
    required this.onApprove,
    required this.onReject,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.sm),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: cs.secondaryContainer,
                  child: Icon(actionIcon(item.module),
                      size: 18, color: cs.onSecondaryContainer),
                ),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.title,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(
                        '${moduleLabel(t, item.module)} · ${_fmt.format(item.createdAt.toLocal())}',
                        style:
                            TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (item.summary.isNotEmpty) ...[
              const SizedBox(height: Gap.sm),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(Gap.sm),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: Text(item.summary,
                    style: const TextStyle(fontSize: 13, height: 1.4)),
              ),
            ],
            const SizedBox(height: Gap.sm),
            // Why it's waiting — ties the queue to the autonomy level.
            Row(
              children: [
                Icon(Icons.tune, size: 14, color: cs.onSurfaceVariant),
                const SizedBox(width: Gap.xs),
                Expanded(
                  child: Text(
                    t.actionQueuedBecause(autonomyShort(t, item.autonomyLevel)),
                    style:
                        TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Gap.sm),
            if (busy)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: Gap.xs),
                child: LinearProgressIndicator(minHeight: 2),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: onApprove,
                      icon: const Icon(Icons.check, size: 18),
                      label: Text(t.actionApprove),
                    ),
                  ),
                  const SizedBox(width: Gap.sm),
                  OutlinedButton(
                    onPressed: onEdit,
                    child: Text(t.actionEdit),
                  ),
                  const SizedBox(width: Gap.sm),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                        foregroundColor: Brand.danger),
                    onPressed: onReject,
                    child: Text(t.actionReject),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// A single DONE audit entry, with an Undo affordance when the action is
/// reversible (delete within the server's 180s window).
class DoneActionTile extends StatelessWidget {
  final AuditEntry entry;
  final bool undoable;
  final VoidCallback? onUndo;
  const DoneActionTile({
    super.key,
    required this.entry,
    required this.undoable,
    this.onUndo,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final module = moduleOf(entry.action);
    final tint = actionOutcomeColor(entry.action, cs);
    return ListTile(
      leading: CircleAvatar(
        radius: 16,
        backgroundColor: tint.withValues(alpha: 0.14),
        child: Icon(actionIcon(module), size: 18, color: tint),
      ),
      title: Text(actionLabel(t, entry.action),
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
      subtitle: Text(
        '${moduleLabel(t, module)} · ${_fmt.format(entry.createdAt.toLocal())}',
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
      ),
      trailing: undoable
          ? TextButton.icon(
              onPressed: onUndo,
              icon: const Icon(Icons.undo, size: 16),
              label: Text(t.actionUndo),
            )
          : null,
    );
  }
}

/// Module + type filter bar (choice chips) shared by the DONE tab.
class ActionFilterBar extends StatelessWidget {
  final List<String> modules; // slugs present in the data
  final String? selectedModule; // null = all
  final ValueChanged<String?> onModule;
  const ActionFilterBar({
    super.key,
    required this.modules,
    required this.selectedModule,
    required this.onModule,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: Gap.sm),
            child: ChoiceChip(
              label: Text(t.actionFilterAll),
              selected: selectedModule == null,
              onSelected: (_) => onModule(null),
            ),
          ),
          for (final m in modules)
            Padding(
              padding: const EdgeInsets.only(right: Gap.sm),
              child: ChoiceChip(
                label: Text(moduleLabel(t, m)),
                selected: selectedModule == m,
                onSelected: (_) => onModule(m),
              ),
            ),
        ],
      ),
    );
  }
}
