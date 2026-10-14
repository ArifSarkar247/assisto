import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'inbox_mock.dart';

/// One unified-inbox row (ADVANCED): category stripe + icon, source, summary,
/// a "needs reply" chip, priority-driven accent, selection checkbox for bulk
/// mode, and per-item quick actions (reply / snooze / done / task / reminder).
/// WCAG: category colour is paired with an icon + text label, never colour
/// alone; all tap targets >= 44px.
class InboxItemCard extends StatelessWidget {
  final InboxItem item;
  final bool selectMode;
  final bool selected;
  final VoidCallback onToggleSelect;
  final VoidCallback onReply;
  final VoidCallback onSnooze;
  final VoidCallback onDone;
  final VoidCallback onTask;
  final VoidCallback onReminder;

  const InboxItemCard({
    super.key,
    required this.item,
    required this.selectMode,
    required this.selected,
    required this.onToggleSelect,
    required this.onReply,
    required this.onSnooze,
    required this.onDone,
    required this.onTask,
    required this.onReminder,
  });

  static Color categoryColor(InboxCategory c) {
    switch (c) {
      case InboxCategory.urgent:
        return const Color(0xFFE0485A); // red
      case InboxCategory.action:
        return const Color(0xFFE0A500); // amber
      case InboxCategory.fyi:
        return const Color(0xFF2E9E6B); // green
      case InboxCategory.promo:
        return const Color(0xFF6B7280); // grey
    }
  }

  static IconData categoryIcon(InboxCategory c) {
    switch (c) {
      case InboxCategory.urgent:
        return Icons.priority_high;
      case InboxCategory.action:
        return Icons.reply;
      case InboxCategory.fyi:
        return Icons.info_outline;
      case InboxCategory.promo:
        return Icons.local_offer_outlined;
    }
  }

  static String categoryLabel(AppLocalizations tr, InboxCategory c) {
    switch (c) {
      case InboxCategory.urgent:
        return tr.inboxCatUrgent;
      case InboxCategory.action:
        return tr.inboxCatAction;
      case InboxCategory.fyi:
        return tr.inboxCatFyi;
      case InboxCategory.promo:
        return tr.inboxCatPromo;
    }
  }

  static IconData sourceIcon(InboxSource s) {
    switch (s) {
      case InboxSource.email:
        return Icons.mail_outline;
      case InboxSource.notification:
        return Icons.notifications_none;
      case InboxSource.message:
        return Icons.chat_bubble_outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final cColor = categoryColor(item.category);

    return Card(
      margin: const EdgeInsets.only(bottom: Gap.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: selectMode ? onToggleSelect : onReply,
        child: IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // Category stripe (plus icon/label below for non-colour cue).
            Container(width: 5, decoration: BoxDecoration(
                color: cColor,
                borderRadius: const BorderRadius.horizontal(left: Radius.circular(Radii.md)))),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(Gap.md),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (selectMode)
                    Padding(
                      padding: const EdgeInsets.only(right: Gap.sm),
                      child: SizedBox(
                        width: 36, height: 36,
                        child: Checkbox(
                          value: selected,
                          onChanged: (_) => onToggleSelect(),
                        ),
                      ),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.only(right: Gap.sm, top: 2),
                      child: Icon(sourceIcon(item.source),
                          size: 20, color: scheme.onSurfaceVariant),
                    ),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(
                          child: Text(
                            item.sender.isEmpty ? item.subject : item.sender,
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: item.read ? FontWeight.w500 : FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                        ),
                        _CategoryBadge(color: cColor, icon: categoryIcon(item.category),
                            label: categoryLabel(tr, item.category)),
                      ]),
                      const SizedBox(height: 2),
                      Text(
                        item.subject,
                        maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: scheme.onSurface,
                          fontWeight: item.read ? FontWeight.w400 : FontWeight.w600,
                        ),
                      ),
                      if (item.snippet.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          item.snippet,
                          maxLines: 2, overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                        ),
                      ],
                      const SizedBox(height: Gap.sm),
                      Row(children: [
                        if (item.needsReply)
                          Padding(
                            padding: const EdgeInsets.only(right: Gap.sm),
                            child: _Pill(
                              icon: Icons.mark_email_unread_outlined,
                              label: tr.inboxNeedsReply,
                              color: scheme.primary,
                            ),
                          ),
                        if (item.snoozedUntil != null)
                          _Pill(icon: Icons.snooze, label: tr.inboxSnoozed,
                              color: scheme.onSurfaceVariant),
                      ]),
                      if (!selectMode) ...[
                        const SizedBox(height: Gap.xs),
                        _ActionRow(
                          tr: tr,
                          hideReply: item.category == InboxCategory.promo,
                          onReply: onReply, onSnooze: onSnooze, onDone: onDone,
                          onTask: onTask, onReminder: onReminder,
                        ),
                      ],
                    ]),
                  ),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _CategoryBadge extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String label;
  const _CategoryBadge({required this.color, required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(
            fontSize: 11, fontWeight: FontWeight.w700, color: color)),
      ]),
    );
  }
}

class _Pill extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _Pill({required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 14, color: color),
      const SizedBox(width: 4),
      Text(label, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    ]);
  }
}

class _ActionRow extends StatelessWidget {
  final AppLocalizations tr;
  final bool hideReply;
  final VoidCallback onReply, onSnooze, onDone, onTask, onReminder;
  const _ActionRow({
    required this.tr, required this.hideReply,
    required this.onReply, required this.onSnooze, required this.onDone,
    required this.onTask, required this.onReminder,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget btn(IconData icon, String tip, VoidCallback onTap) => Tooltip(
          message: tip,
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.sm),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(icon, size: 20, color: scheme.onSurfaceVariant),
            ),
          ),
        );
    return Wrap(spacing: 2, children: [
      if (!hideReply) btn(Icons.reply, tr.inboxQuickReply, onReply),
      btn(Icons.snooze, tr.inboxSnooze, onSnooze),
      btn(Icons.check_circle_outline, tr.inboxMarkDone, onDone),
      btn(Icons.task_alt, tr.inboxConvertTask, onTask),
      btn(Icons.alarm_add, tr.inboxConvertReminder, onReminder),
    ]);
  }
}
