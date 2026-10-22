import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import 'payments_api.dart';
import 'store_billing.dart';
import '../services/error_report.dart'; // db1

/// Taka sign via code point (no Bangla-block literal in Dart source).
const _taka = '৳';

/// pay1 — the ONE checkout sheet (plans, credits, renew).
///
///  * Play build: "Google Play" first, then "bKash / Nagad / Card — EPS"
///    when the owner keeps the gateway on for the Play build.
///  * Website APK: the gateway only — Play Billing is never attempted.
///  * Which options exist comes from the SERVER at runtime
///    (/payments/config: owner switches + whether keys are added), the same
///    for every user. NO SHOWPIECES: a switched-off or not-yet-set-up option
///    is NOT listed at all (no dead option); callers only open the sheet when
///    a channel is live (PayConfig.canBuy).
///  * Prices are the server's (৳). Nothing is granted on the device: every
///    purchase is verified by our server first.
///
/// Returns true when something was bought (callers reload).
class CheckoutSheet extends StatefulWidget {
  final String sku;
  final PaymentsBackend backend;
  final String flavour;
  const CheckoutSheet(
      {super.key,
      required this.sku,
      required this.backend,
      required this.flavour});

  /// Opens the browser for the gateway page. Tests replace it.
  static Future<bool> Function(Uri) launcher =
      (u) => launchUrl(u, mode: LaunchMode.externalApplication);

  static Future<bool?> show(BuildContext context, String sku,
      {PaymentsBackend? backend, String? flavour}) {
    final b = backend ??
        ApiPaymentsBackend(Provider.of<AppState>(context, listen: false).api);
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) =>
          CheckoutSheet(sku: sku, backend: b, flavour: flavour ?? payFlavour()),
    );
  }

  @override
  State<CheckoutSheet> createState() => _CheckoutSheetState();
}

enum _Step { loading, loadFailed, choose, busy, waitingGateway, done, failed }

class _CheckoutSheetState extends State<CheckoutSheet>
    with WidgetsBindingObserver {
  _Step _step = _Step.loading;
  PayConfig? _cfg;
  String _msg = '';
  String _doneMsg = '';
  int? _orderId;
  bool _checking = false;
  late final String _idem =
      '${widget.sku}-${DateTime.now().microsecondsSinceEpoch}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    // Back from the browser: check the order once, quietly.
    if (s == AppLifecycleState.resumed && _step == _Step.waitingGateway) {
      _checkOrder(quiet: true);
    }
  }

  Future<void> _load() async {
    setState(() => _step = _Step.loading);
    try {
      final c = await widget.backend.config(widget.flavour);
      if (!mounted) return;
      setState(() {
        _cfg = c;
        _step = _Step.choose;
      });
    } catch (_) {
      if (mounted) setState(() => _step = _Step.loadFailed);
    }
  }

  List<PayChannel> get _channels {
    final c = _cfg;
    if (c == null) return const [];
    // Only LIVE channels that sell this sku (never Play on the website APK,
    // whatever the server says). Off / unconfigured ones are hidden.
    return c
        .live(widget.flavour)
        .where((ch) => _product(ch.id) != null)
        .toList();
  }

  PayProduct? _product(String channel) => _cfg?.product(channel, widget.sku);

  String _err(AppLocalizations t, PayResult r) {
    if (r.reason == 'network') return t.payNetwork;
    return r.message.isNotEmpty ? r.message : t.payFailedBody;
  }

  // ------------------------------------------------------------ gateway
  Future<void> _payGateway() async {
    final t = AppLocalizations.of(context);
    setState(() => _step = _Step.busy);
    final r = await widget.backend.checkout(widget.sku, _idem, widget.flavour);
    if (!mounted) return;
    if (!r.ok) {
      setState(() {
        _msg = _err(t, r);
        _step = _Step.failed;
      });
      return;
    }
    final o = r.order;
    _orderId = (o['id'] as num?)?.toInt();
    if (o['status'] == 'paid') return _success(t, null);
    final url = '${o['redirect_url'] ?? ''}';
    var opened = false;
    if (url.startsWith('https://')) {
      try {
        opened = await CheckoutSheet.launcher(Uri.parse(url));
      } catch (_) {
        opened = false;
      }
    }
    if (!mounted) return;
    setState(() {
      _msg = opened ? '' : t.payOpenFailed;
      _step = opened ? _Step.waitingGateway : _Step.failed;
    });
  }

  Future<void> _checkOrder({bool quiet = false}) async {
    final id = _orderId;
    if (id == null || _checking) return;
    final t = AppLocalizations.of(context);
    setState(() => _checking = true);
    final r = await widget.backend.order(id);
    if (!mounted) return;
    setState(() => _checking = false);
    final st = '${r.order['status'] ?? ''}';
    if (r.ok && st == 'paid') {
      _success(t, null);
    } else if (!quiet) {
      setState(() => _msg = r.ok ? t.payStillPending : _err(t, r));
    }
  }

  // ------------------------------------------------------------ play
  Future<void> _payPlay() async {
    final t = AppLocalizations.of(context);
    final p = _product('play');
    if (p == null) return;
    setState(() => _step = _Step.busy);
    final pre = await widget.backend.playPrecheck(widget.sku);
    if (!mounted) return;
    if (!pre.ok) {
      setState(() {
        _msg = _err(t, pre);
        _step = _Step.failed;
      });
      return;
    }
    final billing = await StoreBilling.forThisBuild();
    if (!mounted) return;
    if (billing == null) {
      setState(() {
        _msg = t.payPlayUnavailable;
        _step = _Step.failed;
      });
      return;
    }
    StoreBuyResult res;
    try {
      res = await billing.buy(
          productId: p.playProductId,
          basePlanId: p.playBasePlan,
          isSubscription: p.isSub,
          accountId: '${pre.data['play_account_id'] ?? _cfg?.playAccountId ?? ''}');
    } catch (e) {
      res = StoreBuyResult(StoreBuyStatus.error, error: '$e');
    }
    if (!mounted) return;
    switch (res.status) {
      case StoreBuyStatus.cancelled:
        setState(() => _step = _Step.choose);
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text(t.payCancelled)));
        return;
      case StoreBuyStatus.pending:
        setState(() {
          _msg = t.payPlayPending;
          _step = _Step.failed;
        });
        return;
      case StoreBuyStatus.unavailable:
      case StoreBuyStatus.error:
        setState(() {
          _msg = res.status == StoreBuyStatus.unavailable
              ? t.payPlayUnavailable
              : t.payFailedBody;
          _step = _Step.failed;
        });
        return;
      case StoreBuyStatus.purchased:
        break;
    }
    final v = await widget.backend.playVerify(
        kind: p.isSub ? 'sub' : 'pack',
        productId: p.playProductId,
        purchaseToken: res.purchaseToken);
    if (!mounted) return;
    final good = v.ok &&
        (v.data['entitled'] == true || v.data['state'] == 'granted');
    if (good) {
      try {
        await billing.finish(res.purchaseToken);
      } catch (e) {
        // db1: the purchase is already verified + granted server-side; a
        // failed local acknowledge is reported, not shown.
        reportNonFatal('checkout.finishPurchase', e);
      }
      return _success(t, v.data);
    }
    setState(() {
      _msg = v.data['state'] == 'pending' ? t.payPlayPending : _err(t, v);
      _step = _Step.failed;
    });
  }

  void _success(AppLocalizations t, Map<String, dynamic>? data) {
    final p = _product('gateway') ?? _product('play');
    setState(() {
      _doneMsg = (p != null && !p.isSub)
          ? t.paySuccessCredits(p.credits)
          : t.paySuccessPlan(p?.title ?? '');
      _step = _Step.done;
    });
  }

  // ------------------------------------------------------------ UI
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg,
          Gap.lg + MediaQuery.of(context).viewInsets.bottom),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 180),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _body(t, scheme),
        ),
      ),
    );
  }

  List<Widget> _body(AppLocalizations t, ColorScheme scheme) {
    switch (_step) {
      case _Step.loading:
      case _Step.busy:
        return [
          const SizedBox(height: Gap.xl),
          const Center(child: CircularProgressIndicator()),
          const SizedBox(height: Gap.md),
          Text(t.payWorking,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.xl),
        ];
      case _Step.loadFailed:
        return _state(scheme, Icons.cloud_off, scheme.error, t.payNetwork, '',
            [FilledButton.tonal(onPressed: _load, child: Text(t.retry))]);
      case _Step.waitingGateway:
        return _state(
            scheme,
            Icons.open_in_browser,
            scheme.primary,
            t.payWaitingTitle,
            _msg.isNotEmpty ? _msg : t.payWaitingBody,
            [
              FilledButton.icon(
                onPressed: _checking ? null : () => _checkOrder(),
                icon: _checking
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.verified_outlined),
                label: Text(t.payCheckNow),
              ),
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(t.payLater)),
            ]);
      case _Step.done:
        return _state(scheme, Icons.check_circle, Brand.success,
            t.paySuccessTitle, _doneMsg, [
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(t.payDone)),
        ]);
      case _Step.failed:
        return _state(scheme, Icons.info_outline, Brand.warning,
            t.payFailedTitle, _msg.isNotEmpty ? _msg : t.payFailedBody, [
          FilledButton.tonal(
              onPressed: () => setState(() {
                    _msg = '';
                    _step = _Step.choose;
                  }),
              child: Text(t.retry)),
        ]);
      case _Step.choose:
        return _choose(t, scheme);
    }
  }

  List<Widget> _state(ColorScheme scheme, IconData icon, Color tint,
      String title, String body, List<Widget> actions) {
    return [
      const SizedBox(height: Gap.sm),
      Icon(icon, size: 48, color: tint),
      const SizedBox(height: Gap.md),
      Text(title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium),
      if (body.isNotEmpty) ...[
        const SizedBox(height: Gap.sm),
        Text(body,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
      ],
      const SizedBox(height: Gap.lg),
      for (final a in actions) ...[a, const SizedBox(height: Gap.sm)],
    ];
  }

  String _period(AppLocalizations t, PayProduct p) {
    if (!p.isSub) return '';
    return p.period == 'yearly' ? t.plansPerYear : t.plansPerMonth;
  }

  List<Widget> _choose(AppLocalizations t, ColorScheme scheme) {
    final chans = _channels;
    final any = _product('play') ?? _product('gateway');
    return [
      Text(t.payChooseTitle, style: Theme.of(context).textTheme.titleLarge),
      if (any != null) ...[
        const SizedBox(height: 4),
        Text(
            any.isSub
                ? '${any.title} · $_taka${any.priceBdt} ${_period(t, any)}'
                : '${t.payCreditsN(any.credits)} · $_taka${any.priceBdt}',
            style: TextStyle(color: scheme.onSurfaceVariant)),
      ],
      const SizedBox(height: Gap.lg),
      for (final c in chans) _option(t, scheme, c),
      if (chans.isEmpty) ...[
        const SizedBox(height: Gap.sm),
        Text(t.payNoneAvailable,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
      ],
      const SizedBox(height: Gap.md),
      Row(children: [
        Icon(Icons.lock_outline, size: 16, color: scheme.onSurfaceVariant),
        const SizedBox(width: Gap.sm),
        Expanded(
            child: Text(t.paySafeNote,
                style: TextStyle(
                    fontSize: 12, color: scheme.onSurfaceVariant))),
      ]),
    ];
  }

  Widget _option(AppLocalizations t, ColorScheme scheme, PayChannel c) {
    final p = _product(c.id);
    final isPlay = c.id == 'play';
    final title = isPlay ? t.payPlayTitle : t.payGatewayTitle;
    final sub = isPlay ? t.payPlaySub : t.payGatewaySub;
    final can = c.usable && p != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.md),
        child: InkWell(
          key: ValueKey('pay-option-${c.id}'),
          borderRadius: BorderRadius.circular(Radii.md),
          onTap: can ? (isPlay ? _payPlay : _payGateway) : null,
          child: Container(
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Radii.md),
              border: Border.all(
                  color: can ? scheme.primary : scheme.outlineVariant,
                  width: can ? 1.4 : 1),
            ),
            child: Row(children: [
              Icon(isPlay ? Icons.shop_outlined : Icons.account_balance_wallet_outlined,
                  color: can ? scheme.primary : scheme.onSurfaceVariant),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: can ? null : scheme.onSurfaceVariant)),
                      const SizedBox(height: 2),
                      Text(sub,
                          style: TextStyle(
                              fontSize: 12.5,
                              color: scheme.onSurfaceVariant,
                              height: 1.3)),
                    ]),
              ),
              if (p != null) ...[
                const SizedBox(width: Gap.sm),
                Text('$_taka${p.priceBdt}',
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: can ? scheme.primary : scheme.onSurfaceVariant)),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}
