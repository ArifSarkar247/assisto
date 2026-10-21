import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'watch_item.dart';

/// Localized number: Western digits in [n] -> Bangla digits when locale is bn.
/// Uses codepoints only (no Bangla glyphs in source).
String watchLocaleNum(BuildContext context, int n) {
  final isBn = Localizations.localeOf(context).languageCode == 'bn';
  if (!isBn) return '$n';
  const zeroBn = 0x09E6; // Bengali digit zero
  final buf = StringBuffer();
  for (final r in n.abs().toString().runes) {
    buf.writeCharCode(zeroBn + (r - 0x30));
  }
  return (n < 0 ? '-' : '') + buf.toString();
}

/// Human due label for a WatchItem (today / tomorrow / in N days / N overdue).
String watchDueLabel(BuildContext context, WatchItem it) {
  final t = AppLocalizations.of(context);
  final d = it.daysUntil;
  if (d == null) return '';
  if (d < 0) return t.watchOverdueByDays(watchLocaleNum(context, -d));
  if (d == 0) return t.watchDueToday;
  if (d == 1) return t.watchDueTomorrow;
  return t.watchDueInDays(watchLocaleNum(context, d));
}

/// Localized fallback title for a signal kind, used when a source gives no
/// text of its own (so a card is never blank).
String watchKindTitle(AppLocalizations t, String kind) {
  switch (kind) {
    case 'reminder':
      return t.watchItemReminder;
    case 'medicine_dose':
      return t.watchItemMedicineDose;
    case 'refill':
      return t.watchItemRefill;
    case 'loan_due':
      return t.watchItemLoanDue;
    case 'budget':
      return t.watchItemBudget;
    case 'subscription':
      return t.watchItemSubscription;
    case 'birthday':
      return t.watchItemBirthday;
    case 'checkin_overdue':
      return t.watchItemCheckinOverdue;
    case 'doc_expiry':
    case 'doc_expired':
      return t.watchItemDocExpiry;
    case 'change':
      return t.watchItemChange;
    default:
      return t.watchItemFamilyAlert;
  }
}

/// Icon + ARB verb for a quick action.
({IconData icon, String Function(AppLocalizations) label}) _actionSpec(
    WatchAction a) {
  switch (a) {
    case WatchAction.open:
      return (icon: Icons.open_in_new, label: (t) => t.watchOpen);
    case WatchAction.dismiss:
      return (icon: Icons.close, label: (t) => t.watchDismiss);
    case WatchAction.snooze:
      return (icon: Icons.snooze_outlined, label: (t) => t.watchSnooze);
    case WatchAction.markDone:
      return (icon: Icons.check, label: (t) => t.watchMarkDone);
    case WatchAction.markTaken:
      return (icon: Icons.medication_outlined, label: (t) => t.watchMarkTaken);
    case WatchAction.call:
      return (icon: Icons.call_outlined, label: (t) => t.watchCall);
    case WatchAction.payHint:
      return (icon: Icons.payments_outlined, label: (t) => t.watchPayHint);
  }
}

/// One actionable feed card. Deep-links on tap; shows quick actions below.
class WatchCard extends StatelessWidget {
  final WatchItem item;
  final VoidCallback onOpen;
  final Future<void> Function(WatchAction) onAction;

  const WatchCard({
    super.key,
    required this.item,
    required this.onOpen,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final vis = watchSeverityVisual(item.severity, scheme);
    final due = watchDueLabel(context, item);
    final bigText = MediaQuery.textScalerOf(context).scale(1) > 1.2;

    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md)),
      child: InkWell(
        onTap: item.route == null ? null : onOpen,
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
                      color: vis.tint.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(Radii.sm),
                    ),
                    child: Icon(vis.icon, color: vis.tint, size: 22),
                  ),
                  const SizedBox(width: Gap.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            item.title.isEmpty
                                ? watchKindTitle(t, item.kind)
                                : item.title,
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700)),
                        // large font: the due chip moves under the title so
                        // the title keeps its width (no mid-word breaks)
                        if (due.isNotEmpty && bigText) ...[
                          const SizedBox(height: 4),
                          _DueChip(
                              text: due, overdue: (item.daysUntil ?? 0) < 0),
                        ],
                        if (item.body != null && item.body!.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(item.body!,
                              style: TextStyle(
                                  color: scheme.onSurfaceVariant, height: 1.3)),
                        ],
                      ],
                    ),
                  ),
                  if (due.isNotEmpty && !bigText) ...[
                    const SizedBox(width: Gap.sm),
                    _DueChip(text: due, overdue: (item.daysUntil ?? 0) < 0),
                  ],
                ],
              ),
              const SizedBox(height: Gap.sm),
              // Quick actions. Primary (first) is a filled tonal; rest text.
              Wrap(
                spacing: Gap.sm,
                runSpacing: Gap.xs,
                children: [
                  for (var i = 0; i < item.actions.length; i++)
                    _buildAction(context, t, item.actions[i], primary: i == 0),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAction(BuildContext context, AppLocalizations t, WatchAction a,
      {required bool primary}) {
    final spec = _actionSpec(a);
    final onTap = a == WatchAction.open
        ? onOpen
        : () => onAction(a);
    final icon = Icon(spec.icon, size: 18);
    final label = Text(spec.label(t));
    return primary
        ? FilledButton.tonalIcon(onPressed: onTap, icon: icon, label: label)
        : TextButton.icon(onPressed: onTap, icon: icon, label: label);
  }
}

class _DueChip extends StatelessWidget {
  final String text;
  final bool overdue;
  const _DueChip({required this.text, required this.overdue});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = overdue ? Brand.danger : scheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 2),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Text(text,
          style: TextStyle(
              color: tint, fontWeight: FontWeight.w700, fontSize: 12)),
    );
  }
}
