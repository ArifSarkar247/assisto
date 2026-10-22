import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// Share-invite composer for the advanced Referral screen (feature #102).
///
/// Three honest delivery routes, each embedding the user's referral CODE so a
/// join can be attributed back to the inviter:
///   • Share link  — system share sheet with the deep link (+ code).
///   • QR          — a real scannable QR (qr_flutter) of the link + code, plus
///                   the selectable link/code.
///   • Own-SIM SMS — opens the phone's SMS composer (sms: URI) pre-filled; the
///                   USER presses send from their own number. Nothing is sent
///                   on their behalf.
///
/// The link and code come straight from the backend balance payload
/// (invite_link / referral_code); this widget invents neither.
class RefShareSheet extends StatelessWidget {
  final String? link;
  final String? code;
  final String message;
  const RefShareSheet({
    super.key,
    required this.link,
    required this.code,
    required this.message,
  });

  String get _payload {
    final l = (link ?? '').trim();
    final c = (code ?? '').trim();
    if (l.isNotEmpty) return l;
    return c; // fall back to the bare code if there's no link yet
  }

  String get _shareText {
    final p = _payload;
    return p.isNotEmpty ? '$message\n$p' : message;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final hasCode = (code ?? '').trim().isNotEmpty;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.refShareTitle,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Gap.sm),
            Text(t.refShareSubtitle,
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.md),
            if (hasCode) _codeChip(context, t, scheme),
            const SizedBox(height: Gap.md),
            _tile(context,
                icon: Icons.ios_share,
                title: t.refShareLink,
                onTap: () async {
                  Navigator.pop(context);
                  await Share.share(_shareText);
                }),
            _tile(context,
                icon: Icons.qr_code_2,
                title: t.refShareQr,
                onTap: () {
                  Navigator.pop(context);
                  _showQr(context, t, scheme);
                }),
            _tile(context,
                icon: Icons.sms_outlined,
                title: t.refShareSms,
                subtitle: t.refShareSmsNote,
                onTap: () async {
                  Navigator.pop(context);
                  final uri = Uri.parse(
                      'sms:?body=${Uri.encodeComponent(_shareText)}');
                  await launchUrl(uri);
                }),
          ],
        ),
      ),
    );
  }

  Widget _codeChip(
      BuildContext context, AppLocalizations t, ColorScheme scheme) {
    return InkWell(
      borderRadius: BorderRadius.circular(Radii.sm),
      onTap: () => Clipboard.setData(ClipboardData(text: code!.trim())),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: Gap.md, vertical: Gap.sm),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(t.refShareCodeLabel,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          const SizedBox(width: Gap.sm),
          Text(code!.trim(),
              style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.5,
                  fontSize: 16)),
          const SizedBox(width: Gap.sm),
          Icon(Icons.copy_outlined, size: 16, color: scheme.onSurfaceVariant),
        ]),
      ),
    );
  }

  Widget _tile(BuildContext context,
      {required IconData icon,
      required String title,
      String? subtitle,
      required VoidCallback onTap}) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: scheme.primary.withValues(alpha: 0.12),
        child: Icon(icon, color: scheme.primary, size: 20),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle, style: const TextStyle(fontSize: 12)),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }

  void _showQr(BuildContext context, AppLocalizations t, ColorScheme scheme) {
    final value = _payload;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.refShareQr),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          // q1-seams: a REAL scannable QR (qr_flutter is bundled); it used to
          // be a QR-shaped icon nobody could scan.
          if (value.isNotEmpty)
            Container(
              key: const ValueKey('q1-ref-qr'),
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                color: Colors.white, // dark-on-white so any scanner reads it
                borderRadius: BorderRadius.circular(Radii.md),
              ),
              child: SizedBox.square(
                  dimension: 180, child: QrImageView(data: value, size: 180)),
            ),
          const SizedBox(height: Gap.md),
          SelectableText(value.isNotEmpty ? value : t.refShareUnavailable,
              textAlign: TextAlign.center),
        ]),
        actions: [
          if (value.isNotEmpty)
            TextButton.icon(
              icon: const Icon(Icons.copy_outlined),
              label: Text(t.copy),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: value));
                Navigator.pop(ctx);
              },
            ),
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(t.close)),
        ],
      ),
    );
  }
}
