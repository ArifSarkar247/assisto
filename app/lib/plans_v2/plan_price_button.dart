import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../payments/checkout_sheet.dart';
import '../payments/payments_api.dart';
import '../payments/play_prices.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/ladder_common.dart' show fmtInt;
import 'buy_inside.dart' show BuyOrigin;
import 'plans_v2.dart' show planName;

/// buyinside — the in-place price button of a plan ("Premium — ৳449 a
/// month") + the honest small line ("then ৳449 a month · cancel any time ·
/// paid with Google Play"). Shown ONLY when a live payment channel of this
/// build sells the plan and (Play build) Play's own price is known — never a
/// fake button. Opens the shared CheckoutSheet; [onBought] runs after a
/// verified purchase (the caller pops back to the same screen, unlocked).
class PlanPriceButton extends StatefulWidget {
  final String plan; // premium | business
  final String origin;
  final bool primary;
  final VoidCallback onBought;
  final PaymentsBackend? backend;
  final String? flavour;

  const PlanPriceButton(
      {super.key,
      required this.plan,
      required this.origin,
      required this.onBought,
      this.primary = true,
      this.backend,
      this.flavour});

  @override
  State<PlanPriceButton> createState() => _PlanPriceButtonState();
}

class _PlanPriceButtonState extends State<PlanPriceButton> {
  PayConfig? _cfg;
  bool _pricesLoading = false;

  String get _flavour => widget.flavour ?? payFlavour();
  String get _sku => '${widget.plan}_monthly';

  PaymentsBackend? _backend() {
    if (widget.backend != null) return widget.backend;
    try {
      return ApiPaymentsBackend(context.read<AppState>().api);
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final b = _backend();
    try {
      if (b != null) _cfg = await b.config(_flavour);
    } catch (_) {
      _cfg = null;
    }
    if (!mounted) return;
    final p = _product();
    if (_flavour == 'play' && p != null) {
      setState(() => _pricesLoading = true);
      await PlayPrices.ensure([p]);
      if (mounted) setState(() => _pricesLoading = false);
    } else {
      setState(() {});
    }
  }

  PayProduct? _product() {
    final c = _cfg;
    if (c == null) return null;
    for (final ch in c.live(_flavour)) {
      final p = c.product(ch.id, _sku);
      if (p != null) return p;
    }
    return null;
  }

  String? _price(PayProduct p) {
    if (_flavour == 'play') {
      final s = PlayPrices.of(p);
      return s == null ? null : localizeStoreDigits(context, s);
    }
    return '৳${fmtInt(context, p.priceBdt)}';
  }

  Future<void> _buy() async {
    BuyOrigin.current = widget.origin;
    final ok = await CheckoutSheet.show(context, _sku,
        backend: widget.backend, flavour: _flavour);
    if (ok == true && mounted) widget.onBought();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final p = _product();
    final price = p == null ? null : _price(p);
    if (p == null || price == null) {
      if (p != null && _flavour == 'play' && _pricesLoading) {
        return Text(t.pv2PriceLoading,
            style: TextStyle(color: scheme.onSurfaceVariant));
      }
      return const SizedBox.shrink();
    }
    final label = Text(t.biPlanPrice(planName(t, widget.plan), price),
        textAlign: TextAlign.center);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (widget.primary)
        FilledButton(
          key: const Key('bi-plan-buy'),
          onPressed: _buy,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          child: label,
        )
      else
        OutlinedButton(
          key: const Key('bi-plan-buy'),
          onPressed: _buy,
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
          child: label,
        ),
      const SizedBox(height: Gap.xs),
      Text(_flavour == 'play' ? t.biThenPlay(price) : t.biThenApk(price),
          key: const Key('bi-plan-then'),
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant)),
    ]);
  }
}
