import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'finance_common.dart';

/// Shared widgets for the Tax & Zakat surface (#60, SPEC v2.1 §21).
///
/// ZERO Bangla literals — every user-visible string comes from
/// AppLocalizations. Reuses [FinanceField] / [FinanceResultRow] from
/// finance_common so the look matches the rest of the money tools.

/// The persistent "not tax advice" disclaimer. Shown on EVERY tab — the
/// estimator is informational only and must never be presented as advice.
class TaxDisclaimerBanner extends StatelessWidget {
  const TaxDisclaimerBanner({super.key});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: Gap.md),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.gavel_rounded,
              size: 18, color: scheme.onTertiaryContainer),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(t.taxDisclaimer,
                style: TextStyle(
                    height: 1.4, color: scheme.onTertiaryContainer)),
          ),
        ],
      ),
    );
  }
}

/// A compact "verify with NBR" note shown under estimate results. Honest about
/// the figures being published rates that can change.
class TaxSourceNote extends StatelessWidget {
  final String source;
  const TaxSourceNote({super.key, required this.source});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: Gap.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.xs),
          Expanded(
            child: Text('${t.taxVerifyNbr}  ($source)',
                style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: scheme.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }
}

/// Section heading inside a tab.
class TaxSectionTitle extends StatelessWidget {
  final String text;
  const TaxSectionTitle(this.text, {super.key});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: Gap.sm, bottom: Gap.sm),
      child: Text(text,
          style: TextStyle(
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onSurfaceVariant)),
    );
  }
}

/// Open an external URL (NBR portal). Honest fallback: if it can't open, the
/// link is copied to the clipboard so the user can paste it — we never pretend
/// to have filed anything.
Future<void> openExternal(
    BuildContext context, String url, String copiedMsg) async {
  final uri = Uri.parse(url);
  try {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (ok) return;
  } catch (_) {/* best-effort: fall through to copy */}
  await Clipboard.setData(ClipboardData(text: url));
  if (context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(copiedMsg)));
  }
}

/// Share (or clipboard-fallback) a result string.
Future<void> shareOrCopy(
    BuildContext context, String text, String copiedMsg) async {
  try {
    await SharePlusCompat.share(text);
  } catch (_) {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(copiedMsg)));
    }
  }
}

/// The e-return reminder card: links to the NBR portal and is explicit that we
/// do NOT file on the user's behalf. Opening the link shows the official site.
class EReturnReminderCard extends StatelessWidget {
  const EReturnReminderCard({super.key});

  // Official NBR e-return portal.
  static const String nbrEReturnUrl = 'https://etaxnbr.gov.bd/';
  static const String nbrHomeUrl = 'https://nbr.gov.bd/';

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.event_available_rounded,
                  color: scheme.onSecondaryContainer),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(t.taxEReturnTitle,
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 16)),
              ),
            ]),
            const SizedBox(height: Gap.sm),
            Text(t.taxEReturnBody, style: const TextStyle(height: 1.4)),
            const SizedBox(height: Gap.md),
            Wrap(
              spacing: Gap.sm,
              runSpacing: Gap.sm,
              children: [
                FilledButton.icon(
                  onPressed: () =>
                      openExternal(context, nbrEReturnUrl, t.taxLinkCopied),
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: Text(t.taxEReturnOpen),
                ),
                OutlinedButton.icon(
                  onPressed: () =>
                      openExternal(context, nbrHomeUrl, t.taxLinkCopied),
                  icon: const Icon(Icons.public_rounded, size: 18),
                  label: Text(t.taxNbrHome),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Thin indirection so share_plus stays isolated and easy to swap. Kept tiny to
/// avoid importing share_plus across every widget.
class SharePlusCompat {
  static Future<void> Function(String text)? _impl;

  /// Wired once at screen construction by money_tax_screen (which imports
  /// share_plus). Falls back to throwing so [shareOrCopy] uses the clipboard.
  static void wire(Future<void> Function(String text) impl) => _impl = impl;

  static Future<void> share(String text) {
    final f = _impl;
    if (f == null) throw StateError('share not wired');
    return f(text);
  }
}
