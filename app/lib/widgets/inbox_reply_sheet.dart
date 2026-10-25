import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'inbox_mock.dart';

/// Quick-reply bottom sheet. Shows the item summary, up to 3 AI-suggested
/// quick-reply labels (MOCK - deterministic, from inbox_mock.replyKeysFor),
/// and an honest key-gated banner: sending a real reply needs a connected
/// account + provider key, so here it only copies the chosen reply as a draft.
class InboxReplySheet extends StatelessWidget {
  final InboxItem item;
  final bool accountConnected;
  const InboxReplySheet({super.key, required this.item, required this.accountConnected});

  static Future<String?> show(BuildContext context, InboxItem item, bool connected) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => InboxReplySheet(item: item, accountConnected: connected),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final keys = replyKeysFor(item.category);

    return Padding(
      padding: EdgeInsets.only(
        left: Gap.lg, right: Gap.lg, top: Gap.sm,
        bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg,
      ),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr.inboxQuickReply,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
        const SizedBox(height: Gap.sm),
        Card(
          color: scheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Text(item.summary, style: TextStyle(color: scheme.onSurface)),
          ),
        ),
        const SizedBox(height: Gap.md),
        Text(tr.inboxSuggestedReplies,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        const SizedBox(height: Gap.sm),
        if (keys.isEmpty)
          Text(tr.inboxNoRepliesForPromo,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant))
        else
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            for (final k in keys)
              ActionChip(
                avatar: const Icon(Icons.bolt_rounded, size: 16),
                label: Text(replyLabel(tr, k)),
                onPressed: () => Navigator.pop(context, replyLabel(tr, k)),
              ),
          ]),
        const SizedBox(height: Gap.lg),
        // Honest key-gated state: real send needs account + AI key.
        Container(
          padding: const EdgeInsets.all(Gap.md),
          decoration: BoxDecoration(
            color: scheme.tertiaryContainer,
            borderRadius: BorderRadius.circular(Radii.md),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.vpn_key_rounded, size: 18, color: scheme.onTertiaryContainer),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(
                accountConnected
                    ? tr.inboxReplyKeyGatedDraftOnly
                    : tr.inboxReplyConnectToSend,
                style: TextStyle(fontSize: 12, color: scheme.onTertiaryContainer),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}
