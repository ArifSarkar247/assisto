import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import 'agent_core_source.dart';

/// agent-core WP-APP: shared bits of the agent screens — Bangla digits,
/// times, run/step state labels, the risk chip and the approval card.
/// No Bangla literals here (language gate): Bangla digits are built from
/// code points.

bool acBn(BuildContext context) =>
    Localizations.localeOf(context).languageCode == 'bn';

/// '0'-'9' -> Bangla digits when [bn].
String acDigits(Object v, bool bn) {
  final s = '$v';
  if (!bn) return s;
  final b = StringBuffer();
  for (final c in s.codeUnits) {
    b.writeCharCode(c >= 0x30 && c <= 0x39 ? 0x09E6 + (c - 0x30) : c);
  }
  return b.toString();
}

String acNum(BuildContext context, int n) => acDigits(n, acBn(context));

/// "14:05" today, "28/10 14:05" on another day (local time, local digits).
String acTime(BuildContext context, DateTime? t, {DateTime? now}) {
  if (t == null) return '';
  final n = now ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final hm = '${two(t.hour)}:${two(t.minute)}';
  final sameDay = t.year == n.year && t.month == n.month && t.day == n.day;
  return acDigits(sameDay ? hm : '${t.day}/${t.month} $hm', acBn(context));
}

String acRunStateLabel(AppLocalizations t, String state) => switch (state) {
      'queued' => t.acStateQueued,
      'running' => t.acStateRunning,
      'waiting_approval' => t.acStateWaiting,
      'done' => t.acStateDone,
      'budget' => t.acStateBudget,
      'cancelled' => t.acStateCancelled,
      'expired' => t.acStateExpired,
      _ => t.acStateFailed,
    };

String acStepStateLabel(AppLocalizations t, String state) => switch (state) {
      'pending' => t.acStepStPending,
      'running' => t.acStepStRunning,
      'done' => t.acStepStDone,
      'waiting_approval' => t.acStepStApproval,
      'rejected' => t.acStepStRejected,
      'skipped' => t.acStepStSkipped,
      _ => t.acStepStFailed,
    };

IconData acStateIcon(String state) => switch (state) {
      'done' => Icons.check_circle_rounded,
      'queued' || 'pending' => Icons.schedule_rounded,
      'running' => Icons.autorenew_rounded,
      'waiting_approval' => Icons.front_hand_rounded,
      'cancelled' || 'skipped' || 'rejected' => Icons.block_rounded,
      'expired' => Icons.timer_off_rounded,
      _ => Icons.error_outline_rounded,
    };

/// Text/icon colour for a state (theme pairs, AA in light + dark).
Color acStateColor(ColorScheme s, String state) => switch (state) {
      'done' => s.primary,
      'failed' || 'budget' || 'expired' => s.error,
      'waiting_approval' => s.tertiary,
      _ => s.onSurfaceVariant,
    };

String acRiskLabel(AppLocalizations t, String risk) => switch (risk) {
      'external' => t.acRiskExternal,
      'money' => t.acRiskMoney,
      'delete' => t.acRiskDelete,
      _ => t.acRiskOther,
    };

IconData acRiskIcon(String risk) => switch (risk) {
      'external' => Icons.send_rounded,
      'money' => Icons.payments_rounded,
      'delete' => Icons.delete_outline_rounded,
      _ => Icons.edit_rounded,
    };

/// A labelled pill: icon + text (never colour-only).
class AcPill extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color bg, fg;
  const AcPill(
      {super.key, required this.icon, required this.text, required this.bg, required this.fg});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xs),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Radii.pill)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 16, color: fg),
          const SizedBox(width: Gap.xs),
          Flexible(
              child: Text(text,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: fg))),
        ]),
      );
}

class AcRiskChip extends StatelessWidget {
  final String risk;
  const AcRiskChip(this.risk, {super.key});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final strong = risk == 'money' || risk == 'delete';
    return AcPill(
        icon: acRiskIcon(risk),
        text: acRiskLabel(AppLocalizations.of(context), risk),
        bg: strong ? s.errorContainer : s.tertiaryContainer,
        fg: strong ? s.onErrorContainer : s.onTertiaryContainer);
  }
}

/// Centered message + optional action (empty / error / honest states).
class AcMessage extends StatelessWidget {
  final IconData icon;
  final String? title;
  final String body;
  final String? action;
  final VoidCallback? onAction;
  const AcMessage(
      {super.key,
      required this.icon,
      this.title,
      required this.body,
      this.action,
      this.onAction});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(Gap.xl),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 40, color: s.onSurfaceVariant),
        const SizedBox(height: Gap.md),
        if (title != null) ...[
          Text(title!,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Gap.sm),
        ],
        Text(body,
            textAlign: TextAlign.center,
            style: TextStyle(color: s.onSurfaceVariant, height: 1.4)),
        if (action != null && onAction != null) ...[
          const SizedBox(height: Gap.lg),
          FilledButton.tonal(
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: onAction,
              child: Text(action!)),
        ],
      ]),
    );
  }
}

/// One pending approval: exactly what will be done, by which step, for which
/// task, what it costs, until when — and one-tap Approve / Reject.
class AcApprovalCard extends StatelessWidget {
  final AcApproval ap;
  final bool busy;
  final bool fromNotification;
  final DateTime? now;
  final VoidCallback onApprove, onReject;
  const AcApprovalCard(
      {super.key,
      required this.ap,
      required this.onApprove,
      required this.onReject,
      this.busy = false,
      this.fromNotification = false,
      this.now});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final expired = ap.expired(now ?? DateTime.now());
    return Card(
      key: ValueKey('ac_approval_${ap.id}'),
      margin: const EdgeInsets.symmetric(vertical: Gap.sm),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.lg),
          side: BorderSide(
              color: fromNotification ? s.primary : s.outlineVariant,
              width: fromNotification ? 2 : 1)),
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (fromNotification) ...[
            Text(t.acApFromNotif,
                style: TextStyle(color: s.primary, fontWeight: FontWeight.w600)),
            const SizedBox(height: Gap.md),
          ],
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [AcRiskChip(ap.risk)]),
          const SizedBox(height: Gap.md),
          Semantics(
              header: true,
              child: Text(ap.title, style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
          if (ap.goal.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Text(t.acApForGoal(ap.goal), style: TextStyle(color: s.onSurfaceVariant)),
          ],
          if (ap.toolLabel.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Text(t.acApStep(ap.toolLabel), style: TextStyle(color: s.onSurfaceVariant)),
          ],
          if (ap.details.isNotEmpty) ...[
            const SizedBox(height: Gap.md),
            Text(t.acApDetails, style: tt.labelLarge),
            const SizedBox(height: Gap.xs),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                  color: s.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(Radii.md)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final d in ap.details)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: Gap.xxs),
                    child: Text('${d.key}: ${acDigits(d.value, acBn(context))}',
                        style: TextStyle(color: s.onSurface)),
                  ),
              ]),
            ),
            if (ap.hasMasked) ...[
              const SizedBox(height: Gap.xs),
              Text(t.acApMaskedNote,
                  style: TextStyle(fontSize: 12, color: s.onSurfaceVariant)),
            ],
          ],
          const SizedBox(height: Gap.md),
          Row(children: [
            Icon(Icons.toll_rounded, size: 18, color: s.onSurfaceVariant),
            const SizedBox(width: Gap.xs),
            Expanded(
                child: Text(ap.credits > 0
                    ? t.acApCost(acNum(context, ap.credits))
                    : t.acApCostFree)),
          ]),
          const SizedBox(height: Gap.xs),
          Row(children: [
            Icon(expired ? Icons.timer_off_rounded : Icons.timer_outlined,
                size: 18, color: expired ? s.error : s.onSurfaceVariant),
            const SizedBox(width: Gap.xs),
            Expanded(
                child: Text(
                    expired ? t.acApExpired : t.acApExpires(acTime(context, ap.expiresAt)),
                    style: TextStyle(color: expired ? s.error : null))),
          ]),
          const SizedBox(height: Gap.lg),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: Gap.sm,
            runSpacing: Gap.sm,
            children: [
              OutlinedButton.icon(
                key: ValueKey('ac_reject_${ap.id}'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: busy ? null : onReject,
                icon: const Icon(Icons.close_rounded),
                label: Text(t.acReject),
              ),
              FilledButton.icon(
                key: ValueKey('ac_approve_${ap.id}'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: busy || expired ? null : onApprove,
                icon: busy
                    ? const SizedBox(
                        width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.check_rounded),
                label: Text(t.acApprove),
              ),
            ],
          ),
        ]),
      ),
    );
  }
}
