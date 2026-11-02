import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// channels (2 Nov) — Share a channel / community: the https link (opens the
/// app straight on it; without the app a web page with Google Play), a real
/// scannable QR, Copy and Share. Buttons stack full-width so 200% text never
/// clips. Open with `showAppSheet` (nav-bar safe).
class SpaceInviteSheet extends StatelessWidget {
  final String url;
  final String title;

  /// One honest line under the QR (e.g. "Anyone with this link can follow").
  final String note;

  /// Optional extra action (e.g. "New link" for admins).
  final Widget? extra;

  const SpaceInviteSheet({
    super.key,
    required this.url,
    required this.title,
    this.note = '',
    this.extra,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Gap.lg),
            Center(
              child: Container(
                padding: const EdgeInsets.all(Gap.sm),
                decoration: BoxDecoration(
                  color: Colors.white, // quiet zone: scans in dark mode too
                  borderRadius: BorderRadius.circular(Radii.md),
                ),
                child: QrImageView(
                    key: const Key('space-invite-qr'), data: url, size: 180),
              ),
            ),
            const SizedBox(height: Gap.md),
            SelectableText(url,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium),
            if (note.isNotEmpty) ...[
              const SizedBox(height: Gap.sm),
              Text(note,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            ],
            const SizedBox(height: Gap.lg),
            FilledButton.icon(
              key: const Key('space-invite-share'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => Share.share(url),
              icon: const Icon(Icons.ios_share_rounded),
              label: Text(t.channelShareLink),
            ),
            const SizedBox(height: Gap.sm),
            OutlinedButton.icon(
              key: const Key('space-invite-copy'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: url));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(t.channelLinkCopied)));
                }
              },
              icon: const Icon(Icons.copy_rounded),
              label: Text(t.channelCopyLink),
            ),
            if (extra != null) ...[const SizedBox(height: Gap.sm), extra!],
          ],
        ),
      ),
    );
  }
}
