import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'payments_api.dart';
import 'store_billing.dart';

/// pay-e2e — restore + Play subscription status (Play build only).
///
/// Restore: every purchase Google Play still holds for the signed-in Google
/// account goes to OUR server (/payments/play/verify). The server decides:
/// the same Assisto account gets it (idempotent — never granted twice), a
/// DIFFERENT Assisto account is refused ("other_account"). Nothing is ever
/// granted on the device.

class RestoreOutcome {
  int found = 0, restored = 0, otherAccount = 0, pending = 0, failed = 0;
}

/// Re-verifies every owned Play purchase that belongs to one of our products.
Future<RestoreOutcome> restorePlayPurchases(
    PaymentsBackend backend, StoreBilling billing, PayConfig cfg) async {
  final out = RestoreOutcome();
  List<StoreOwned> owned;
  try {
    owned = await billing.owned();
  } catch (_) {
    owned = const [];
  }
  final seen = <String>{};
  for (final o in owned) {
    if (!seen.add(o.purchaseToken)) continue;
    PayProduct? p;
    for (final x in cfg.products['play'] ?? const <PayProduct>[]) {
      if (x.playProductId == o.productId) {
        p = x;
        break;
      }
    }
    if (p == null) continue; // not an Assisto product
    out.found++;
    final r = await backend.playVerify(
        kind: p.isSub ? 'sub' : 'pack',
        productId: o.productId,
        purchaseToken: o.purchaseToken);
    if (r.ok && (r.data['entitled'] == true || r.data['state'] == 'granted')) {
      out.restored++;
    } else if (r.reason == 'other_account') {
      out.otherAccount++;
    } else if (r.data['state'] == 'pending') {
      out.pending++;
    } else {
      out.failed++;
    }
  }
  return out;
}

/// The one-line result of a restore, for a snackbar.
String restoreMessage(AppLocalizations t, RestoreOutcome o) {
  if (o.otherAccount > 0) return t.payRestoreOtherAccount;
  if (o.restored > 0) return t.payRestoreDone(o.restored);
  if (o.pending > 0) return t.payPlayPending;
  if (o.failed > 0) return t.payRestoreFailed;
  return t.payRestoreNone;
}

/// "Restore purchases" — shown only on the Play build while the Play channel
/// is live (NO SHOWPIECES).
class RestorePurchasesButton extends StatefulWidget {
  final PaymentsBackend backend;
  final PayConfig cfg;
  final Future<StoreBilling?> Function() billing;
  final VoidCallback? onRestored;
  const RestorePurchasesButton(
      {super.key,
      required this.backend,
      required this.cfg,
      this.billing = StoreBilling.forThisBuild,
      this.onRestored});

  @override
  State<RestorePurchasesButton> createState() => _RestorePurchasesButtonState();
}

class _RestorePurchasesButtonState extends State<RestorePurchasesButton> {
  bool _busy = false;

  Future<void> _run() async {
    if (_busy) return; // double tap
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _busy = true);
    String msg;
    var restored = false;
    try {
      final b = await widget.billing();
      if (b == null) {
        msg = t.payPlayUnavailableNoAlt;
      } else {
        final o = await restorePlayPurchases(widget.backend, b, widget.cfg);
        restored = o.restored > 0;
        msg = restoreMessage(t, o);
      }
    } catch (_) {
      msg = t.payRestoreFailed;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    messenger?.showSnackBar(SnackBar(content: Text(msg)));
    if (restored) widget.onRestored?.call();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return TextButton.icon(
      key: const ValueKey('pay-restore'),
      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
      onPressed: _busy ? null : _run,
      icon: _busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.restore_rounded, size: 20),
      label: Text(t.payRestore),
    );
  }
}

/// Google Play's own subscription page for this app (cancel, resume, fix
/// payment method). Play's documented deep link.
Uri playManageUri(String productId, String package) => Uri.https(
    'play.google.com', '/store/account/subscriptions', {
  if (productId.isNotEmpty) 'sku': productId,
  if (package.isNotEmpty) 'package': package,
});

/// The Play subscription banner: active / cancelled / grace / on hold /
/// paused + "Manage subscription" or "Fix payment". `play` is the `play`
/// block of /payments/state.
class PlayStatusCard extends StatelessWidget {
  final Map<String, dynamic> play;
  const PlayStatusCard({super.key, required this.play});

  /// Opens the Play page. Tests replace it.
  static Future<bool> Function(Uri) launcher =
      (u) => launchUrl(u, mode: LaunchMode.externalApplication);

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final status = '${play['status'] ?? ''}';
    final ends = DateTime.tryParse('${play['expires_at'] ?? ''}')?.toLocal();
    final date = ends == null
        ? ''
        : MaterialLocalizations.of(context).formatMediumDate(ends);
    final problem = status == 'grace' || status == 'on_hold';
    final String text;
    switch (status) {
      case 'grace':
        text = t.payPlayGrace(date);
        break;
      case 'on_hold':
        text = t.payPlayOnHold;
        break;
      case 'paused':
        text = t.payPlayPaused;
        break;
      case 'canceled':
        text = t.payPlayCanceled(date);
        break;
      default:
        text = date.isEmpty ? t.payManagedByPlay : t.payPlayActive(date);
    }
    final tint = problem ? Brand.warning : scheme.primary;
    return Container(
      key: ValueKey('play-status-$status'),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: tint.withValues(alpha: 0.40)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(problem ? Icons.credit_card_off_rounded : Icons.shop_rounded,
              size: 22, color: tint),
          const SizedBox(width: Gap.sm),
          Expanded(child: Text(text, style: AType.bodyMedium)),
        ]),
        const SizedBox(height: Gap.sm),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: problem
              ? FilledButton.icon(
                  key: const ValueKey('play-manage'),
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => _open(context),
                  icon: const Icon(Icons.payment_rounded, size: 18),
                  label: Text(t.payFixPayment),
                )
              : FilledButton.tonalIcon(
                  key: const ValueKey('play-manage'),
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => _open(context),
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: Text(t.payManageSub),
                ),
        ),
      ]),
    );
  }

  Future<void> _open(BuildContext context) async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    var ok = false;
    try {
      ok = await launcher(playManageUri(
          '${play['product_id'] ?? ''}', '${play['package'] ?? ''}'));
    } catch (_) {
      ok = false;
    }
    if (!ok) messenger?.showSnackBar(SnackBar(content: Text(t.payOpenFailed)));
  }
}
