import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'notif_models.dart';

/// Snooze choices surfaced by the ▸ menu. `custom` opens date+time pickers.
enum SnoozePreset { m15, h1, tomorrow, custom }

/// One reminder row: icon + title + when, and three actions —
/// Done · Snooze ▸ · Open. `overdue` tints the time chip (Missed section).
class NotifReminderCard extends StatelessWidget {
  final NotifReminder reminder;
  final bool overdue;
  final VoidCallback onDone;
  final void Function(SnoozePreset) onSnooze;
  final VoidCallback onOpen;

  const NotifReminderCard({
    super.key,
    required this.reminder,
    required this.onDone,
    required this.onSnooze,
    required this.onOpen,
    this.overdue = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final title = pickText(context, reminder.title);
    final when = notifWhen(context, reminder.whenIso);
    final canOpen = (reminder.route ?? '').isNotEmpty;

    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      clipBehavior: Clip.antiAlias,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
      child: InkWell(
        onTap: canOpen ? onOpen : null,
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 40,
                    width: 40,
                    decoration: BoxDecoration(
                      color: (overdue ? Brand.danger : scheme.primary)
                          .withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(Radii.sm),
                    ),
                    child: Icon(
                      overdue
                          ? Icons.notification_important_outlined
                          : Icons.alarm_outlined,
                      size: 22,
                      color: overdue ? Brand.danger : scheme.primary,
                    ),
                  ),
                  const SizedBox(width: Gap.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title.isEmpty ? t.notifReminderFallbackTitle : title,
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        if (when.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            when,
                            style: TextStyle(
                              color: overdue
                                  ? Brand.danger
                                  : scheme.onSurfaceVariant,
                              height: 1.3,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Gap.sm),
              Wrap(
                spacing: Gap.sm,
                runSpacing: Gap.xs,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: onDone,
                    icon: const Icon(Icons.check, size: 18),
                    label: Text(t.notifDone),
                  ),
                  _SnoozeMenu(onSelected: onSnooze),
                  TextButton.icon(
                    onPressed: canOpen ? onOpen : null,
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: Text(t.notifOpen),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Snooze ▸" as a popup menu offering 15m · 1h · tomorrow · custom.
class _SnoozeMenu extends StatelessWidget {
  final void Function(SnoozePreset) onSelected;
  const _SnoozeMenu({required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return PopupMenuButton<SnoozePreset>(
      onSelected: onSelected,
      tooltip: t.notifSnooze,
      itemBuilder: (_) => [
        PopupMenuItem(
            value: SnoozePreset.m15, child: Text(t.notifSnooze15m)),
        PopupMenuItem(value: SnoozePreset.h1, child: Text(t.notifSnooze1h)),
        PopupMenuItem(
            value: SnoozePreset.tomorrow, child: Text(t.notifSnoozeTomorrow)),
        PopupMenuItem(
            value: SnoozePreset.custom, child: Text(t.notifSnoozeCustom)),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: Gap.md, vertical: Gap.sm),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.snooze_outlined, size: 18),
            const SizedBox(width: Gap.xs),
            Text(t.notifSnooze),
            const Icon(Icons.arrow_drop_down, size: 20),
          ],
        ),
      ),
    );
  }
}
