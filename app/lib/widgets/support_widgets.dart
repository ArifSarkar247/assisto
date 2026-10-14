import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../theme.dart';
import '../l10n/app_localizations.dart';

/// Status pill for a support ticket (#181, §21). Honest 3-state mapping from
/// the backend SupportTicket fields: a non-empty `reply` means an agent has
/// answered; `resolved` means closed; otherwise the ticket is still open.
enum TicketStatus { open, answered, resolved }

TicketStatus ticketStatusOf(Map<String, dynamic> t) {
  if (t['resolved'] == true) return TicketStatus.resolved;
  if ((t['reply'] ?? '').toString().trim().isNotEmpty) {
    return TicketStatus.answered;
  }
  return TicketStatus.open;
}

class TicketStatusPill extends StatelessWidget {
  final TicketStatus status;
  const TicketStatusPill({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final (Color c, String label) = switch (status) {
      TicketStatus.open => (Brand.warning, t.supportStatusOpen),
      TicketStatus.answered => (Brand.blue, t.supportStatusAnswered),
      TicketStatus.resolved => (Brand.success, t.supportStatusResolved),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label,
          style: TextStyle(
              color: c, fontSize: 12, fontWeight: FontWeight.w700)),
    );
  }
}

/// A single ticket row: kind icon, message preview, status pill, date, and the
/// agent reply (when present). Text never clips at 360dp — the message wraps
/// to two lines with an ellipsis.
class TicketCard extends StatelessWidget {
  final Map<String, dynamic> ticket;
  const TicketCard({super.key, required this.ticket});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final status = ticketStatusOf(ticket);
    final kind = (ticket['kind'] ?? 'support').toString();
    final message = (ticket['message'] ?? '').toString();
    final reply = (ticket['reply'] ?? '').toString().trim();

    String dateStr = '';
    final created = ticket['created_at']?.toString();
    if (created != null && created.isNotEmpty) {
      final dt = DateTime.tryParse(created);
      if (dt != null) dateStr = DateFormat('d MMM, h:mm a').format(dt.toLocal());
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  kind == 'bug'
                      ? Icons.bug_report_outlined
                      : Icons.support_agent_outlined,
                  size: 20,
                  color: scheme.primary,
                ),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(
                    kind == 'bug' ? t.supportKindBug : t.supportKindHelp,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                TicketStatusPill(status: status),
              ],
            ),
            const SizedBox(height: Gap.sm),
            Text(message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
            if (reply.isNotEmpty) ...[
              const SizedBox(height: Gap.sm),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(Gap.sm),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.supportReplyLabel,
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: scheme.primary)),
                    const SizedBox(height: 2),
                    Text(reply, style: const TextStyle(height: 1.4)),
                  ],
                ),
              ),
            ],
            if (dateStr.isNotEmpty) ...[
              const SizedBox(height: Gap.sm),
              Text(dateStr,
                  style: TextStyle(fontSize: 11, color: scheme.outline)),
            ],
          ],
        ),
      ),
    );
  }
}

/// An expandable FAQ / self-help entry. Both question and answer come from ARB
/// getters — the caller passes already-localized strings.
class FaqTile extends StatelessWidget {
  final String question;
  final String answer;
  const FaqTile({super.key, required this.question, required this.answer});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: Icon(Icons.help_outline, color: scheme.primary),
        title: Text(question,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        childrenPadding:
            const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.md),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(answer,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.5)),
        ],
      ),
    );
  }
}
