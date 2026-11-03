import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../payments/play_prices.dart' show localizeStoreDigits;
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import 'market_source.dart';

/// amarket: small shared pieces of the Assisto Market screens.

String mkNum(BuildContext context, Object n) => localizeStoreDigits(context, '$n');

/// POISHA -> "৳1,234" (Bangla digits in the Bangla UI).
String mkTaka(BuildContext context, Object? poisha) {
  final p = poisha is num ? poisha.toInt() : int.tryParse('$poisha') ?? 0;
  final whole = (p.abs() ~/ 100)
      .toString()
      .replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  final rest = p.abs() % 100;
  final s = rest == 0 ? whole : '$whole.${rest.toString().padLeft(2, '0')}';
  return '৳${p < 0 ? '-' : ''}${mkNum(context, s)}';
}

/// "in N hours" / "in N days" for a delivery time.
String mkHours(BuildContext context, Object? h) {
  final t = AppLocalizations.of(context);
  final n = h is num ? h.toInt() : int.tryParse('$h') ?? 0;
  if (n >= 24 && n % 24 == 0) return t.amkInDays(mkNum(context, n ~/ 24));
  return t.amkInHours(mkNum(context, n));
}

bool mkOffline(Object e) =>
    e is SocketException || e is http.ClientException || e is TimeoutException;

/// Server `detail` (already bn/en) else a friendly offline / error line.
String mkMessage(BuildContext context, Object e) {
  final t = AppLocalizations.of(context);
  if (e is ApiException) {
    final d = e.body?['detail'];
    if (d is String && d.trim().isNotEmpty) return d;
  }
  return mkOffline(e) ? t.amkOffline : t.amkError;
}

String? mkReason(Object e) => e is ApiException ? (e.reason ?? '${e.body?['reason'] ?? ''}') : null;

void mkSnack(BuildContext context, String msg) =>
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(msg)));

/// Empty state = benefit line + big button + how-to (owner rule).
class MkEmpty extends StatelessWidget {
  final IconData icon;
  final String title;
  final String benefit;
  final String? howTo;
  final String? button;
  final VoidCallback? onPressed;
  const MkEmpty({
    super.key,
    required this.icon,
    required this.title,
    required this.benefit,
    this.howTo,
    this.button,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(Gap.xl),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 48, color: cs.primary),
        const SizedBox(height: Gap.md),
        Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: Gap.sm),
        Text(benefit, textAlign: TextAlign.center),
        if (button != null && onPressed != null) ...[
          const SizedBox(height: Gap.lg),
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(160, 48)),
            onPressed: onPressed,
            icon: const Icon(Icons.add_rounded),
            label: Text(button!),
          ),
        ],
        if (howTo != null) ...[
          const SizedBox(height: Gap.md),
          Text(howTo!,
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
        ],
      ]),
    );
  }
}

/// Error / offline body with a 48dp retry.
class MkError extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;
  const MkError({super.key, required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final off = mkOffline(error);
    return ListView(padding: const EdgeInsets.all(Gap.xl), children: [
      const SizedBox(height: 40),
      Icon(off ? Icons.wifi_off_rounded : Icons.error_outline_rounded,
          size: 48, color: Theme.of(context).colorScheme.outline),
      const SizedBox(height: Gap.md),
      Text(mkMessage(context, error), textAlign: TextAlign.center),
      const SizedBox(height: Gap.lg),
      Center(
        child: FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
          onPressed: onRetry,
          icon: const Icon(Icons.refresh_rounded),
          label: Text(t.amkRetry),
        ),
      ),
    ]);
  }
}

/// A small coloured label ("Lowest price", "Suggested", ...).
class MkBadge extends StatelessWidget {
  final String text;
  final Color color;
  final Color onColor;
  const MkBadge(this.text, {super.key, required this.color, required this.onColor});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(12)),
        child: Text(text, style: TextStyle(color: onColor, fontSize: 12, fontWeight: FontWeight.w600)),
      );
}

/// Report reasons the server accepts (core.market.REPORT_CATEGORIES).
const kMkReportCategories = ['scam_fraud', 'spam', 'harassment', 'impersonation', 'other'];

String mkReportLabel(AppLocalizations t, String c) => switch (c) {
      'scam_fraud' => t.amkRepScam,
      'spam' => t.amkRepSpam,
      'harassment' => t.amkRepHarass,
      'impersonation' => t.amkRepFake,
      _ => t.amkRepOther,
    };

String mkStatusLabel(AppLocalizations t, String s) => switch (s) {
      'open' => t.amkStOpen,
      'accepted' => t.amkStAccepted,
      'cancelled' => t.amkStCancelled,
      'delivered' => t.amkStDelivered,
      'confirmed' => t.amkStConfirmed,
      _ => t.amkStClosed,
    };

/// Report (reason sheet) or block — used on needs, offers, sellers, deals.
Future<void> mkReportOrBlock(BuildContext context, MarketSource src, String kind, int id,
    {String? blockKind, int? blockId, VoidCallback? onDone}) async {
  final t = AppLocalizations.of(context);
  final choice = await showAppSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SingleChildScrollView(
      key: const Key('amk-report-sheet'),
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.amkReportTitle, style: Theme.of(ctx).textTheme.titleMedium),
        const SizedBox(height: Gap.sm),
        for (final c in kMkReportCategories)
          ListTile(
            minTileHeight: 48,
            leading: const Icon(Icons.flag_outlined),
            title: Text(mkReportLabel(t, c)),
            onTap: () => Navigator.pop(ctx, c),
          ),
        const Divider(),
        ListTile(
          minTileHeight: 48,
          leading: const Icon(Icons.block_rounded),
          title: Text(t.amkBlock),
          subtitle: Text(t.amkBlockNote),
          onTap: () => Navigator.pop(ctx, '__block'),
        ),
      ]),
    ),
  );
  if (choice == null || !context.mounted) return;
  try {
    if (choice == '__block') {
      await src.block(blockKind ?? kind, blockId ?? id);
      if (context.mounted) mkSnack(context, t.amkBlocked);
    } else {
      await src.report(kind, id, choice);
      if (context.mounted) mkSnack(context, t.amkReported);
    }
    onDone?.call();
  } catch (e) {
    if (context.mounted) mkSnack(context, mkMessage(context, e));
  }
}
