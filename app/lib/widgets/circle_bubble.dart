import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// One decrypted message in the circle chat. The plaintext here NEVER came from
/// the server — it was decrypted on-device (see crypto/e2e.dart). The server
/// only ever held the ciphertext.
class CircleMessage {
  final String id;
  final String text; // decrypted on-device; null/empty if decryption failed
  final bool mine;
  final DateTime at;
  final String status; // sent | delivered | read (sender view)
  final bool decryptFailed;
  const CircleMessage({
    required this.id,
    required this.text,
    required this.mine,
    required this.at,
    this.status = 'sent',
    this.decryptFailed = false,
  });
}

class CircleBubble extends StatelessWidget {
  final CircleMessage msg;
  const CircleBubble({super.key, required this.msg});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final mine = msg.mine;
    final bg = mine ? scheme.primary : scheme.surfaceContainerHighest;
    final fg = mine ? scheme.onPrimary : scheme.onSurface;

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: Gap.xs, horizontal: Gap.sm),
        padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.md),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78),
        decoration: BoxDecoration(
          color: msg.decryptFailed ? scheme.errorContainer : bg,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(Radii.lg),
            topRight: const Radius.circular(Radii.lg),
            bottomLeft: Radius.circular(mine ? Radii.lg : Radii.xs),
            bottomRight: Radius.circular(mine ? Radii.xs : Radii.lg),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              msg.decryptFailed ? t.circleDecryptFailed : msg.text,
              style: TextStyle(
                  color: msg.decryptFailed
                      ? scheme.onErrorContainer
                      : fg,
                  fontStyle:
                      msg.decryptFailed ? FontStyle.italic : FontStyle.normal,
                  height: 1.4),
            ),
            const SizedBox(height: Gap.xs),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  DateFormat.Hm().format(msg.at),
                  style: TextStyle(
                      fontSize: 11,
                      color: (mine ? scheme.onPrimary : scheme.onSurfaceVariant)
                          .withValues(alpha: 0.8)),
                ),
                if (mine) ...[
                  const SizedBox(width: Gap.xs),
                  Icon(_statusIcon(msg.status),
                      size: 14,
                      color: msg.status == 'read'
                          ? scheme.tertiaryContainer
                          : scheme.onPrimary.withValues(alpha: 0.8)),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  IconData _statusIcon(String status) {
    switch (status) {
      case 'read':
        return Icons.done_all;
      case 'delivered':
        return Icons.done_all;
      default:
        return Icons.done;
    }
  }
}

/// The small reassurance banner shown at the top of every circle chat: messages
/// are end-to-end encrypted; the server (and its AI) cannot read them.
class CircleEncryptionBanner extends StatelessWidget {
  const CircleEncryptionBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.all(Gap.sm),
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(
        children: [
          Icon(Icons.lock_outline,
              size: 16, color: scheme.onSecondaryContainer),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(
              t.circleE2eBanner,
              style: TextStyle(
                  fontSize: 12, color: scheme.onSecondaryContainer, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
}
