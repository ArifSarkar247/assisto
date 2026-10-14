import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// One incoming community message request — a first contact from someone
/// OUTSIDE the recipient's circle. It never lands in the normal inbox: the
/// recipient must Accept (then it becomes a normal chat), Decline, Block, or
/// Report. There is deliberately NO call action here — calls are refused by the
/// server until the request is accepted.
class MsgrCommunityRequestTile extends StatelessWidget {
  final String senderName;
  final String? senderPhoto;

  /// The community the sender reached out from (context for the recipient).
  final String communityName;

  /// A short preview line (decrypted on-device from the first-message envelope),
  /// or a generic "sent you a message" when no preview is available.
  final String preview;

  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback onBlock;
  final VoidCallback onReport;

  const MsgrCommunityRequestTile({
    super.key,
    required this.senderName,
    this.senderPhoto,
    required this.communityName,
    required this.preview,
    required this.onAccept,
    required this.onDecline,
    required this.onBlock,
    required this.onReport,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final hasPhoto = senderPhoto != null && senderPhoto!.isNotEmpty;
    return Card(
      margin: const EdgeInsets.fromLTRB(Gap.lg, Gap.xs, Gap.lg, Gap.xs),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: scheme.primaryContainer,
                  backgroundImage: hasPhoto ? NetworkImage(senderPhoto!) : null,
                  child: hasPhoto
                      ? null
                      : Text(
                          senderName.isNotEmpty
                              ? senderName.characters.first.toUpperCase()
                              : '?',
                          style:
                              TextStyle(color: scheme.onPrimaryContainer)),
                ),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(senderName,
                          style: text.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600)),
                      Text(t.communityRequestFromCommunity(communityName),
                          style: text.labelSmall
                              ?.copyWith(color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: Gap.sm),
            // Clear "this is a request, not an open chat" banner.
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: Gap.sm, vertical: Gap.xs),
              decoration: BoxDecoration(
                color: scheme.tertiary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Row(
                children: [
                  Icon(Icons.mark_email_unread_outlined,
                      size: 15, color: scheme.tertiary),
                  const SizedBox(width: Gap.xs),
                  Expanded(
                    child: Text(t.communityRequestBanner,
                        style: text.labelSmall?.copyWith(color: scheme.tertiary)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Gap.sm),
            Text(preview,
                style: text.bodyMedium, maxLines: 3, overflow: TextOverflow.ellipsis),
            const SizedBox(height: Gap.sm),
            Row(
              children: [
                FilledButton(
                    onPressed: onAccept, child: Text(t.communityRequestAccept)),
                const SizedBox(width: Gap.sm),
                OutlinedButton(
                    onPressed: onDecline, child: Text(t.communityRequestDecline)),
                const Spacer(),
                PopupMenuButton<String>(
                  tooltip: t.communityMemberMore,
                  onSelected: (v) {
                    if (v == 'block') onBlock();
                    if (v == 'report') onReport();
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                        value: 'block',
                        child: Text(t.communityRequestBlock)),
                    PopupMenuItem(
                        value: 'report',
                        child: Text(t.communityRequestReport)),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
