import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ads/ads_service.dart';
import '../api.dart';
import '../l10n/app_localizations.dart';
import '../services/error_report.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/rewarded_ad_sheet.dart';
import '../widgets/subs_common.dart' show fmtInt;
import 'checkout_sheet.dart';
import 'payments_api.dart';
import 'play_prices.dart';
import 'store_billing.dart';

/// credout — THE out-of-AI-credits moment, the same for every AI task.
///
/// When the server answers an AI request with 402 {reason:'credits'} (home
/// chat, Assisto AI chat, voice, photo in chat, Photo Studio, @Assisto in My
/// Circle, Ask the web, CV/cover letter, vehicle summary) the caller keeps
/// what the user typed and calls [CreditsOut.offer]. This sheet opens at once
/// (zero extra taps) and lists the credit packs:
///
///  * Play build: the four Google Play in-app products credits_p20 / p50 /
///    p100 / p200 with Play's OWN localized price. One tap on a pack opens
///    the Play purchase sheet. EPS is never offered here (Play policy).
///  * Website APK: the same packs from the gateway (bKash / Nagad / card).
///  * A rewarded-ad row ONLY for Free users on screens where ads are allowed
///    (never on safety, call, chat-with-people, business or payment screens),
///    only when the AdMob server switch is on and the daily cap allows it.
///
/// Packs are CONSUMABLE: our server verifies the token, grants once per token
/// and consumes it, so the same pack can be bought again and again. Nothing is
/// granted on the device. Returns true only when credits really landed
/// (verified purchase or server-verified reward); the caller then sends the
/// original request again ONCE. Cancel / pending / failure return false and
/// the typed text stays in the box. Credits are never cash.
class CreditsOut {
  CreditsOut._();

  /// Tests: replace the whole sheet (screen-level retry tests).
  static Future<bool> Function(BuildContext context,
      {required String screen, required bool draftKept})? debugOffer;

  /// Screens where the rewarded-ad row may appear (Free users only, and only
  /// where an AI task of the user's own runs). Everything else — SOS / safety,
  /// calls, chats with people (My Circle), business, payments, vehicle — never
  /// shows an ad row.
  static const adScreens = {
    'home',
    'ai_chat',
    'chat_photo',
    'photo_studio',
    'world',
    'jobs',
    'credits',
  };

  static bool _open = false;

  /// Open the buy-credits sheet. True when credits were really added.
  static Future<bool> offer(BuildContext context,
      {required String screen,
      bool draftKept = false,
      PaymentsBackend? backend,
      String? flavour}) async {
    final o = debugOffer;
    if (o != null) return o(context, screen: screen, draftKept: draftKept);
    if (_open || !context.mounted) return false; // double 402 / double tap
    _open = true;
    try {
      PaymentsBackend? b = backend;
      b ??= ApiPaymentsBackend(Provider.of<AppState>(context, listen: false).api);
      final ok = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        useSafeArea: true,
        builder: (_) => CreditsOutSheet(
          screen: screen,
          draftKept: draftKept,
          backend: b!,
          flavour: flavour ?? payFlavour(),
        ),
      );
      if (ok == true && context.mounted) {
        final t = AppLocalizations.of(context);
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
            content: Text(draftKept ? t.credoutAddedRetry : t.credoutAdded)));
      }
      return ok == true;
    } catch (e) {
      reportNonFatal('credout.offer', e);
      return false;
    } finally {
      _open = false;
    }
  }
}

/// Reasons our server uses for "not enough credits".
const _creditReasons = {'credits', 'out_of_credits', 'insufficient'};

/// True when an API error is the server's out-of-credits answer.
bool isOutOfCredits(Object? e) =>
    e is ApiException && e.status == 402 && _creditReasons.contains(e.reason);

/// True when a JSON body (any status) says the task needs more credits.
bool isOutOfCreditsBody(Map? body) {
  if (body == null) return false;
  if (body['code'] == 'out_of_credits') return true;
  final st = body['_status'];
  return _creditReasons.contains('${body['reason'] ?? ''}') &&
      (st == null || st == 402 || body['ok'] == false || body['ai'] == false);
}

const _taka = '৳';

class CreditsOutSheet extends StatefulWidget {
  const CreditsOutSheet({
    super.key,
    required this.screen,
    required this.backend,
    required this.flavour,
    this.draftKept = false,
    this.billing = StoreBilling.forThisBuild,
    this.adsAvailable,
    this.watchAd,
    this.gatewayCheckout,
  });

  final String screen;
  final bool draftKept;
  final PaymentsBackend backend;
  final String flavour; // 'play' | 'apk'
  final Future<StoreBilling?> Function() billing;

  /// Tests: whether a rewarded ad can really play (default: AdsService).
  final Future<bool> Function(BuildContext context)? adsAvailable;

  /// Tests: the rewarded flow (default: [RewardedAdSheet]); true = credited.
  final Future<bool?> Function(BuildContext context)? watchAd;

  /// Tests: the website-APK gateway checkout (default: [CheckoutSheet]).
  final Future<bool?> Function(BuildContext context, String sku)? gatewayCheckout;

  @override
  State<CreditsOutSheet> createState() => _CreditsOutSheetState();
}

enum _S { loading, offline, list }

class _CreditsOutSheetState extends State<CreditsOutSheet> {
  _S _s = _S.loading;
  PayConfig? _cfg;
  bool _pricesLoading = false;
  bool _ads = false;
  String? _busySku; // a purchase is running (double-tap guard)
  String _note = '';
  bool _noteBad = false;

  bool get _play => widget.flavour == 'play';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _s = _S.loading);
    PayConfig c;
    try {
      c = await widget.backend.config(widget.flavour);
    } catch (_) {
      if (mounted) setState(() => _s = _S.offline);
      return;
    }
    if (!mounted) return;
    _cfg = c;
    // ads row: never on a no-ad screen; Free + AdMob on + caps (AdsService)
    var ads = false;
    if (CreditsOut.adScreens.contains(widget.screen)) {
      try {
        final f = widget.adsAvailable;
        ads = f != null
            ? await f(context)
            : await AdsService.instance.rewardedAvailable(
                context.read<AppState>(),
                screen: 'credits');
      } catch (_) {
        ads = false;
      }
    }
    if (!mounted) return;
    setState(() {
      _ads = ads;
      _s = _S.list;
    });
    if (_play) await _loadPrices();
  }

  /// Play build: Play's own localized prices only (never the server's taka
  /// number). Cached per app run, lazy, crash-guarded.
  Future<void> _loadPrices() async {
    if (_packs.isEmpty) return;
    setState(() => _pricesLoading = true);
    await PlayPrices.ensure(_packs);
    if (mounted) setState(() => _pricesLoading = false);
  }

  /// Play build: a pack is buyable only once its store price is known.
  bool _priced(PayProduct p) => !_play || PlayPrices.of(p) != null;

  String? get _channel {
    final c = _cfg;
    if (c == null) return null;
    for (final ch in c.live(widget.flavour)) {
      return ch.id;
    }
    return null;
  }

  /// The credit packs the live channel sells, cheapest first.
  List<PayProduct> get _packs {
    final ch = _channel;
    if (ch == null) return const [];
    final l = (_cfg!.products[ch] ?? const <PayProduct>[])
        .where((p) => p.kind == 'pack' && (!_play || p.playProductId.isNotEmpty))
        .toList()
      ..sort((a, b) => a.priceBdt.compareTo(b.priceBdt));
    return l;
  }

  String _price(AppLocalizations t, PayProduct p) {
    if (!_play) return '$_taka${fmtInt(context, p.priceBdt)}';
    final s = PlayPrices.of(p);
    if (s != null) return localizeStoreDigits(context, s);
    return _pricesLoading ? '\u2026' : t.payPriceUnavailable;
  }

  void _say(String m, {bool bad = false}) {
    if (!mounted) return;
    setState(() {
      _note = m;
      _noteBad = bad;
      _busySku = null;
    });
  }

  void _done() {
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _tap(PayProduct p) async {
    if (_busySku != null) return; // double tap
    setState(() {
      _busySku = p.sku;
      _note = '';
    });
    if (_play) {
      await _buyPlay(p);
    } else {
      await _buyGateway(p);
    }
  }

  // ------------------------------------------------------------ website APK
  Future<void> _buyGateway(PayProduct p) async {
    final f = widget.gatewayCheckout;
    bool? ok;
    try {
      ok = f != null
          ? await f(context, p.sku)
          : await CheckoutSheet.show(context, p.sku,
              backend: widget.backend, flavour: widget.flavour);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    if (ok == true) return _done();
    final t = AppLocalizations.of(context);
    _say(widget.draftKept ? t.credoutCancelledKept : t.payFailedBody);
  }

  // ------------------------------------------------------------ Google Play
  Future<void> _buyPlay(PayProduct p) async {
    final t = AppLocalizations.of(context);
    final pre = await widget.backend.playPrecheck(p.sku);
    if (!mounted) return;
    if (!pre.ok) {
      return _say(pre.reason == 'network' ? t.payNetwork : _failed(t), bad: true);
    }
    StoreBilling? billing;
    try {
      billing = await widget.billing();
    } catch (_) {
      billing = null;
    }
    if (!mounted) return;
    if (billing == null) return _say(t.payPlayUnavailableNoAlt, bad: true);
    StoreBuyResult res;
    try {
      res = await billing.buy(
          productId: p.playProductId,
          basePlanId: '',
          isSubscription: false,
          accountId:
              '${pre.data['play_account_id'] ?? _cfg?.playAccountId ?? ''}');
    } catch (e) {
      res = StoreBuyResult(StoreBuyStatus.error, error: '$e');
    }
    if (!mounted) return;
    switch (res.status) {
      case StoreBuyStatus.cancelled:
        return _say(widget.draftKept ? t.credoutCancelledKept : t.payCancelled);
      case StoreBuyStatus.pending:
        return _say(t.credoutPendingKept);
      case StoreBuyStatus.unavailable:
      case StoreBuyStatus.error:
        // An earlier pack Play still holds (verified late / not consumed)
        // blocks a new purchase of it: hand it to our server first.
        if (await _reconcile(billing)) return _done();
        if (!mounted) return;
        return _say(
            res.status == StoreBuyStatus.unavailable
                ? t.payPlayUnavailableNoAlt
                : _failed(t),
            bad: true);
      case StoreBuyStatus.purchased:
        break;
    }
    if (await _verify(billing, p.playProductId, res.purchaseToken)) {
      return _done();
    }
  }

  String _failed(AppLocalizations t) =>
      widget.draftKept ? t.credoutFailedKept : t.payFailedBody;

  /// Server verify (+ a little retry offline: Google already took the money).
  /// True when credits were granted. Consumes when the server could not.
  Future<bool> _verify(StoreBilling billing, String productId, String token,
      {bool quiet = false}) async {
    final t = AppLocalizations.of(context);
    Future<PayResult> v() => widget.backend
        .playVerify(kind: 'pack', productId: productId, purchaseToken: token);
    var r = await v();
    for (var i = 0; i < 2 && !r.ok && r.reason == 'network'; i++) {
      await Future<void>.delayed(Duration(seconds: 2 * (i + 1)));
      if (!mounted) return false;
      r = await v();
    }
    if (!mounted) return false;
    if (r.ok && r.data['state'] == 'granted') {
      try {
        if (r.data['consumed'] == false) {
          await billing.consume(token); // re-buyable even if the server failed
        } else {
          await billing.finish(token);
        }
      } catch (e) {
        reportNonFatal('credout.consume', e);
      }
      return true;
    }
    if (!quiet) {
      _say(
          (r.data['state'] == 'pending' || r.reason == 'network')
              ? t.credoutPendingKept
              : (r.message.isNotEmpty ? r.message : _failed(t)),
          bad: r.data['state'] != 'pending' && r.reason != 'network');
    }
    return false;
  }

  /// Verify every credit pack Play still holds (idempotent per token on the
  /// server). True when one of them granted credits now.
  Future<bool> _reconcile(StoreBilling billing) async {
    final ids = {for (final p in _packs) p.playProductId};
    List<StoreOwned> owned;
    try {
      owned = await billing.owned();
    } catch (_) {
      return false;
    }
    var any = false;
    for (final o in owned) {
      if (!ids.contains(o.productId) || !mounted) continue;
      if (await _verify(billing, o.productId, o.purchaseToken, quiet: true)) {
        any = true;
      }
    }
    return any;
  }

  // ------------------------------------------------------------ rewarded ad
  Future<void> _watch() async {
    if (_busySku != null) return;
    setState(() {
      _busySku = '_ad';
      _note = '';
    });
    bool? ok;
    try {
      final f = widget.watchAd;
      ok = f != null ? await f(context) : await RewardedAdSheet.show(context);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    if (ok == true) return _done();
    setState(() => _busySku = null);
  }

  // ------------------------------------------------------------ UI
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg,
          Gap.lg + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CircleAvatar(
              backgroundColor: scheme.primaryContainer,
              child: Icon(Icons.bolt_rounded, color: scheme.onPrimaryContainer),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Text(t.credoutTitle,
                  key: const Key('credout-title'),
                  style: Theme.of(context).textTheme.titleLarge),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          Text(widget.draftKept ? t.credoutBodyDraft : t.credoutBody,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
          const SizedBox(height: Gap.lg),
          ..._content(t, scheme),
          if (_note.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Container(
              key: const Key('credout-note'),
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                color: (_noteBad ? scheme.errorContainer : scheme.secondaryContainer)
                    .withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(Radii.md),
              ),
              child: Text(_note,
                  style: TextStyle(
                      height: 1.35,
                      color: _noteBad
                          ? scheme.onErrorContainer
                          : scheme.onSecondaryContainer)),
            ),
          ],
          const SizedBox(height: Gap.md),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.info_outline_rounded,
                size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: Text(t.credoutNoCash,
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant))),
          ]),
          const SizedBox(height: Gap.sm),
          TextButton(
            key: const Key('credout-not-now'),
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t.p2PayNotNow),
          ),
        ],
      ),
    );
  }

  List<Widget> _content(AppLocalizations t, ColorScheme scheme) {
    switch (_s) {
      case _S.loading:
        return const [
          Padding(
            padding: EdgeInsets.all(Gap.lg),
            child: Center(child: CircularProgressIndicator()),
          ),
        ];
      case _S.offline:
        return [
          Text(t.payNetwork,
              style: TextStyle(color: scheme.error, height: 1.4)),
          const SizedBox(height: Gap.sm),
          FilledButton.tonal(
            key: const Key('credout-retry'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: _load,
            child: Text(t.retry),
          ),
        ];
      case _S.list:
        final packs = _packs;
        return [
          if (packs.isEmpty)
            Text(t.payNoneAvailable,
                key: const Key('credout-none'),
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4))
          else ...[
            for (final p in packs) _packRow(t, scheme, p),
            if (_play && !_pricesLoading && packs.any((p) => !_priced(p)))
              TextButton.icon(
                key: const Key('credout-price-retry'),
                style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                onPressed: _loadPrices,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(t.retry),
              ),
            const SizedBox(height: Gap.xs),
            Text(_play ? t.credoutPlayNote : t.credoutGatewayNote,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ],
          if (_ads) ...[
            const SizedBox(height: Gap.md),
            _adRow(t, scheme),
          ],
        ];
    }
  }

  Widget _packRow(AppLocalizations t, ColorScheme scheme, PayProduct p) {
    final busy = _busySku == p.sku;
    final enabled = _busySku == null && _priced(p);
    final credits = t.qa1CreditsN(fmtInt(context, p.credits));
    final price = _price(t, p);
    final bonus = p.credits - p.priceBdt;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Semantics(
        button: true,
        label: t.credoutBuySemantic(credits, price),
        excludeSemantics: true,
        child: Material(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(Radii.md),
          child: InkWell(
            key: ValueKey('credout-pack-${p.sku}'),
            borderRadius: BorderRadius.circular(Radii.md),
            onTap: enabled ? () => _tap(p) : null,
            child: Container(
              constraints: const BoxConstraints(minHeight: 56),
              padding: const EdgeInsets.symmetric(
                  horizontal: Gap.md, vertical: Gap.sm),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Radii.md),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Row(children: [
                Icon(Icons.bolt_rounded, color: scheme.primary),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(credits,
                            style: const TextStyle(fontWeight: FontWeight.w700)),
                        if (bonus > 0)
                          Text(t.credoutBonus(fmtInt(context, bonus)),
                              style: TextStyle(
                                  fontSize: 12.5,
                                  color: Brand.onTint(context, Brand.success))),
                      ]),
                ),
                const SizedBox(width: Gap.sm),
                if (busy)
                  const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.4))
                else
                  Flexible(
                    child: Text(price,
                        key: ValueKey('credout-price-${p.sku}'),
                        textAlign: TextAlign.end,
                        style: TextStyle(
                            fontWeight: FontWeight.w800,
                            color: enabled
                                ? scheme.primary
                                : scheme.onSurfaceVariant)),
                  ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _adRow(AppLocalizations t, ColorScheme scheme) => OutlinedButton.icon(
        key: const Key('credout-ad'),
        style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            padding: const EdgeInsets.symmetric(
                horizontal: Gap.md, vertical: Gap.sm)),
        onPressed: _busySku == null ? _watch : null,
        icon: const Icon(Icons.ondemand_video_rounded),
        label: Text(t.credoutWatchAd, textAlign: TextAlign.center),
      );
}
