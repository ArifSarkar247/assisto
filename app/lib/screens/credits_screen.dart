import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../widgets/skeleton.dart';
import '../widgets/storage_meter.dart';
import '../widgets/rewarded_ad_sheet.dart';
import '../ads/ads_service.dart';
import '../widgets/ladder_common.dart' show fmtInt;
import '../payments/checkout_sheet.dart'; // pay1
import '../services/error_kind.dart' show honestFailText; // qa2
import '../payments/payments_api.dart'
    show ApiPaymentsBackend, PayConfig, payFlavour; // pay1
import '../widgets/paywall_sheet.dart'; // p2-money
import '../payments/play_prices.dart'; // credout: Play's own prices
import '../billing/billing_api.dart'; // billapp
import '../billing/billing_format.dart'; // billapp
import '../billing/refund_screen.dart'; // billapp

/// Why the Credits screen was opened from somewhere else (an out-of-credits
/// moment). The banner says exactly that; the numbers still come from the
/// server.
class CreditsOpenReason {
  /// Credits the refused task needs (the server's 402 `need`), 0 = unknown.
  final int need;

  /// The server's own line from that refusal, shown when given.
  final String serverMessage;
  const CreditsOpenReason({this.need = 0, this.serverMessage = ''});
}

/// CREDITS screen — billing v2 (billapp, owner order 27 Oct).
///
/// Everything comes from the server:
///  - GET /credits/state: usable now, locked part + WHEN it opens ("18 usable
///    now, 72 more unlock in 2 days"), each bucket (plan / pack / free /
///    rewarded / referral / earlier / owed) with its expiry, debt after a
///    refund, purchase block, and what each task costs (action_costs);
///  - GET /credits/history (paged ledger, plain-language reasons);
///  - GET /me/usage-summary (this month by feature, included pool, storage);
///  - GET /credits/packs + /payments/config (packs only through a LIVE
///    channel; Play shows Play's own prices).
/// Offline: the last good state is kept per account and shown with its
/// "saved at" time. Credits are never cash (said on the screen). The
/// rewarded-ad entry is opt-in; the ad plays in its own sheet, never as a
/// banner here.
class CreditsScreen extends StatefulWidget {
  const CreditsScreen({super.key, this.reason});

  final CreditsOpenReason? reason;

  @override
  State<CreditsScreen> createState() => _CreditsScreenState();
}

class _CreditsScreenState extends State<CreditsScreen> {
  bool _loading = true;
  bool _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
  bool _buying = false;

  CreditsState? _st; // credits/state (live or cached)
  DateTime? _cachedAt; // non-null = showing the saved copy (offline)
  DateTime? _updatedAt;
  Map<String, dynamic> _usage = const {}; // me/usage-summary
  List<Map<String, dynamic>> _packs = const [];
  // history (paged)
  final List<LedgerRow> _ledger = [];
  int? _nextOffset;
  bool _histLoading = false;
  bool _histFailed = false;
  bool _adsReady = false;
  PayConfig? _payCfg;

  static const _pageSize = 30;

  @override
  void initState() {
    super.initState();
    _load();
  }

  int _int(dynamic v) => v is num ? v.toInt() : 0;

  String get _uid => '${context.read<AppState>().user?.id ?? 0}';

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    final app = context.read<AppState>();
    final api = app.api;
    final uid = _uid;
    final bill = BillingApi(api);
    // 1) the credit state — the heart of the screen (cache when offline)
    try {
      final s = await bill.state();
      _st = s;
      _cachedAt = null;
      _updatedAt = DateTime.now();
      await CreditsCache.save(uid, s.raw);
    } catch (e) {
      _failCause = e;
      final c = await CreditsCache.load(uid);
      if (c != null) {
        _st = c.state;
        _cachedAt = c.at;
      } else {
        _st = null;
      }
    }
    // 2) usage + packs (optional: never blank the screen)
    try {
      _usage = await api.meUsageSummary();
    } catch (e) {
      _usage = const {};
      _failCause ??= e;
    }
    try {
      _packs = (await api.creditsPacks()).cast<Map<String, dynamic>>();
    } catch (_) {
      _packs = const [];
    }
    if (_st == null && _usage.isEmpty) _error = true;
    // An older server without /credits/state: the plain balance, honestly.
    if (_st == null && _usage.isNotEmpty) {
      final b = _int(_usage['balance']);
      _st = CreditsState(balance: b, nowUsable: b < 0 ? 0 : b, debt: b < 0 ? -b : 0);
    }
    // NO SHOWPIECES: a pack is buyable only through a LIVE channel.
    try {
      _payCfg = await ApiPaymentsBackend(api).config(payFlavour());
    } catch (_) {
      _payCfg = null;
    }
    final cfg = _payCfg;
    _packs = cfg == null || (_st?.purchaseBlocked ?? false)
        ? const []
        : _packs
            .where((p) => cfg.canBuy(
                'pack_${p['code'] ?? p['id'] ?? ''}', payFlavour()))
            .toList();
    if (payFlavour() == 'play' && cfg != null) {
      await PlayPrices.ensure(cfg.products['play'] ?? const []);
    }
    if (mounted) {
      _adsReady = await AdsService.instance.rewardedAvailable(app);
    }
    if (mounted) setState(() => _loading = false);
    if (!_error && _cachedAt == null) await _loadHistory(reset: true);
  }

  Future<void> _loadHistory({bool reset = false}) async {
    if (_histLoading) return;
    setState(() {
      _histLoading = true;
      _histFailed = false;
    });
    try {
      final page = await BillingApi(context.read<AppState>().api)
          .history(offset: reset ? 0 : (_nextOffset ?? 0), limit: _pageSize);
      if (reset) _ledger.clear();
      _ledger.addAll(page.rows);
      _nextOffset = page.nextOffset;
    } catch (_) {
      _histFailed = true;
    }
    if (mounted) setState(() => _histLoading = false);
  }

  bool get _isFree {
    final plan = (_usage['plan'] ?? '').toString().toLowerCase();
    return plan.isEmpty || plan == 'free';
  }

  Future<void> _topup(Map<String, dynamic> pack) async {
    final code = (pack['code'] ?? pack['id'] ?? '').toString();
    if (code.isEmpty) return;
    setState(() => _buying = true);
    try {
      final ok =
          await CheckoutSheet.show(context, 'pack_$code', flavour: payFlavour());
      // the server verified the payment -> show the server's new state
      if (ok == true && mounted) await _load();
    } finally {
      if (mounted) setState(() => _buying = false);
    }
  }

  Future<void> _watchAds() async {
    final credited = await RewardedAdSheet.show(context);
    if (credited == true) _load();
  }

  Future<void> _openRefunds() async {
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => const RefundScreen()));
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.creditsTitle),
        actions: [
          if (!_loading)
            IconButton(
                tooltip: t.refresh,
                icon: const Icon(Icons.refresh_rounded),
                onPressed: _load),
        ],
      ),
      body: _loading && _st == null
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off_rounded,
                  tint: scheme.error,
                  title: t.loadFailed,
                  message: honestFailText(t, _failCause, otherwise: t.loadFailedBody),
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(t.retry)))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xxl),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: _body(t, scheme),
                    ),
                  )),
    );
  }

  List<Widget> _body(AppLocalizations t, ColorScheme scheme) {
    final st = _st ?? const CreditsState();
    final pool = _int(_usage['included_pool']);
    final adWallet = _int(_usage['ad_wallet_credits']);
    final monthTotal = _int(_usage['month_total']);
    final usageRows = (_usage['month_usage'] as List?)
            ?.whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList() ??
        const <Map<String, dynamic>>[];
    final usable = st.nowUsable;
    final poolUsedUp = pool > 0 && usable <= 0 && st.locked <= 0;
    final offline = _cachedAt != null;

    return [
      if (widget.reason != null) ...[
        _reasonBanner(t, scheme, st),
        const SizedBox(height: Gap.md),
      ],
      if (offline) ...[
        _strip(scheme, Icons.cloud_off_rounded,
            t.billCachedAt(billDateTime(context, _cachedAt!)),
            key: const Key('credits-cached')),
        const SizedBox(height: Gap.md),
      ],
      if (st.debt > 0 || st.blocked) ...[
        _warn(scheme, t.billDebtTitle, t.billDebtBody(fmtInt(context, st.debt)),
            key: const Key('credits-debt')),
        const SizedBox(height: Gap.md),
      ],
      if (st.purchaseBlocked) ...[
        _warn(scheme, t.billPurchaseBlockedTitle, t.billPurchaseBlocked,
            key: const Key('credits-purchase-blocked')),
        const SizedBox(height: Gap.md),
      ],
      _hero(t, st, pool, adWallet, monthTotal),
      if (_updatedAt != null && !offline)
        Padding(
          padding: const EdgeInsets.only(top: Gap.xs),
          child: Text(t.billUpdatedAt(billDateTime(context, _updatedAt!)),
              textAlign: TextAlign.end,
              style: AType.labelSmall.copyWith(color: scheme.onSurfaceVariant)),
        ),
      const SizedBox(height: Gap.lg),
      if (st.locked > 0) ...[
        _strip(scheme, Icons.lock_clock_rounded,
            t.billLockedExplain(fmtInt(context, st.unlockPct), fmtInt(context, st.unlockHours)),
            key: const Key('credits-locked-explain')),
        const SizedBox(height: Gap.lg),
      ],
      _poolExplainer(t, scheme, poolUsedUp, pool),
      const SizedBox(height: Gap.lg),
      if (_isFree && usable + adWallet <= 0 && st.locked <= 0) ...[
        FilledButton.tonalIcon(
          key: const Key('p2-credits-paywall'),
          onPressed: () => PaywallSheet.show(context, PaywallReason.outOfCredits),
          icon: const Icon(Icons.workspace_premium_rounded),
          label: Text(t.p2GetPremium),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
        const SizedBox(height: Gap.lg),
      ],

      // ---- where the credits are (buckets) ----
      _sectionTitle(t.billBucketsTitle, Icons.account_balance_wallet_rounded, scheme),
      const SizedBox(height: Gap.sm),
      if (st.buckets.isEmpty)
        _strip(scheme, Icons.info_outline_rounded, t.billBucketsEmpty,
            key: const Key('credits-buckets-empty'))
      else
        _card(scheme, [for (final b in st.buckets) _bucketRow(t, scheme, b)]),
      const SizedBox(height: Gap.sm),
      _noCash(t, scheme),
      const SizedBox(height: Gap.xl),

      // ---- top-up packs ----
      _sectionTitle(t.creditsPacksTitle, Icons.shopping_cart_rounded, scheme),
      const SizedBox(height: Gap.sm),
      if (_packs.isEmpty)
        _strip(scheme, Icons.info_outline_rounded,
            st.purchaseBlocked ? t.billPurchaseBlocked : t.creditsPacksEmpty)
      else
        for (final p in _packs) _packCard(t, scheme, p),

      // FREE users: opt-in "earn via ads" (the ad plays in its own sheet).
      if (_adsReady && _isFree && !offline) ...[
        const SizedBox(height: Gap.sm),
        OutlinedButton.icon(
          onPressed: _buying ? null : _watchAds,
          icon: const Icon(Icons.ondemand_video_rounded, size: 18),
          label: Text(t.adEarnCredits),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
      ] else if (_adsReady && !offline) ...[
        const SizedBox(height: Gap.sm),
        Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            minVerticalPadding: 12,
            leading: const Icon(Icons.ondemand_video_rounded),
            title: Text(t.adsPaidOptInTitle),
            subtitle: Text(t.adsPaidOptInSub),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: _buying ? null : _watchAds,
          ),
        ),
      ],

      // ---- refunds ----
      const SizedBox(height: Gap.sm),
      Card(
        margin: EdgeInsets.zero,
        child: ListTile(
          key: const Key('credits-refunds'),
          minVerticalPadding: 12,
          leading: const Icon(Icons.undo_rounded),
          title: Text(t.billRefundEntry),
          subtitle: st.refundWindowHours > 0
              ? Text(t.billRefundEntrySub(fmtInt(context, st.refundWindowHours)))
              : null,
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: _openRefunds,
        ),
      ),

      // ---- what things cost (server's action_costs) ----
      const SizedBox(height: Gap.xl),
      _sectionTitle(t.billCostsTitle, Icons.price_change_rounded, scheme),
      const SizedBox(height: Gap.sm),
      _costs(t, scheme, st),

      // ---- this month by feature ----
      if (usageRows.isNotEmpty) ...[
        const SizedBox(height: Gap.xl),
        _sectionTitle(t.creditsThisMonthTitle, Icons.insights_rounded, scheme),
        const SizedBox(height: Gap.sm),
        _usageCard(t, scheme, usageRows, monthTotal),
      ],

      const SizedBox(height: Gap.xl),
      StorageMeter(
        initial: (_usage['storage'] as Map?)?.cast<String, dynamic>(),
        onBuyStorage: () {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(t.storageBuyHint)));
        },
      ),

      // ---- ledger (paged) ----
      if (!offline) ...[
        const SizedBox(height: Gap.xl),
        _sectionTitle(t.creditsHistoryTitle, Icons.receipt_long_rounded, scheme),
        const SizedBox(height: Gap.sm),
        ..._history(t, scheme),
      ],
    ];
  }

  // ------------------------------------------------------------ pieces
  Widget _reasonBanner(AppLocalizations t, ColorScheme scheme, CreditsState st) {
    final r = widget.reason!;
    final lines = <String>[
      if (r.need > 0)
        t.billReasonNeed(fmtInt(context, r.need), fmtInt(context, st.nowUsable))
      else
        t.billReasonNoCredits,
      if (st.blocked) t.billReasonBlocked,
      if (st.locked > 0 && st.untilUnlock() != null)
        t.billReasonLocked(fmtInt(context, st.locked), unlockWhen(context, st.untilUnlock()!)),
    ];
    return Container(
      key: const Key('credits-reason'),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: Brand.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: Brand.warning.withValues(alpha: 0.45)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.bolt_rounded, color: Brand.onTint(context, Brand.warning)),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Semantics(
            liveRegion: true,
            child: Text(lines.join('\n'), style: const TextStyle(height: 1.4)),
          ),
        ),
      ]),
    );
  }

  Widget _hero(AppLocalizations t, CreditsState st, int pool, int adWallet, int monthTotal) {
    final until = st.untilUnlock();
    return Container(
      key: const Key('credits-hero'),
      decoration: BoxDecoration(
          gradient: Brand.gradient, borderRadius: BorderRadius.circular(Radii.lg)),
      clipBehavior: Clip.antiAlias,
      // a dark scrim over the brand gradient keeps white text >= 4.5:1
      child: Container(
      color: Colors.black.withValues(alpha: 0.32),
      padding: const EdgeInsets.all(Gap.xl),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t.billNowUsable, style: AType.bodySmall.copyWith(color: Colors.white)),
        Semantics(
          label: '${t.billNowUsable}: ${fmtInt(context, st.nowUsable)} ${t.creditsUnit}',
          excludeSemantics: true,
          child: Wrap(crossAxisAlignment: WrapCrossAlignment.end, spacing: 6, children: [
            const Icon(Icons.bolt_rounded, color: Colors.white, size: 30),
            Text(fmtInt(context, st.nowUsable),
                key: const Key('credits-now'),
                style: AType.displayMedium.copyWith(
                    color: Colors.white,
                    fontFeatures: AFonts.tabular,
                    fontWeight: FontWeight.w800)),
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(t.creditsUnit,
                  style: AType.bodyMedium.copyWith(color: Colors.white)),
            ),
          ]),
        ),
        if (st.locked > 0 && until != null) ...[
          const SizedBox(height: Gap.xs),
          Text(
            t.billNowAndLocked(fmtInt(context, st.nowUsable), fmtInt(context, st.locked),
                unlockWhen(context, until)),
            key: const Key('credits-locked-line'),
            style: AType.bodyMedium.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
          ),
        ],
        const SizedBox(height: Gap.md),
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          if (pool > 0)
            _heroPill(Icons.calendar_month_rounded,
                t.creditsIncludedPool(fmtInt(context, pool))),
          if (adWallet > 0)
            _heroPill(Icons.ondemand_video_rounded,
                t.creditsAdWallet(fmtInt(context, adWallet))),
          _heroPill(Icons.trending_up_rounded,
              t.creditsUsedThisMonth(fmtInt(context, monthTotal))),
        ]),
      ]),
      ),
    );
  }

  Widget _heroPill(IconData icon, String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: 6),
        decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.22),
            borderRadius: BorderRadius.circular(Radii.pill)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: Colors.white),
          const SizedBox(width: 6),
          Flexible(
            child: Text(text,
                style: AType.bodySmall
                    .copyWith(color: Colors.white, fontWeight: FontWeight.w600)),
          ),
        ]),
      );

  Widget _bucketRow(AppLocalizations t, ColorScheme scheme, CreditBucket b) {
    final debt = b.bucket == 'debt';
    final subs = <String>[
      if (b.locked > 0 && b.unlocksAt != null)
        t.billLockedUntil(fmtInt(context, b.locked), billDateTime(context, b.unlocksAt!)),
      if (!debt)
        b.expiresAt != null
            ? t.creditsExpiresOn(billDate(context, b.expiresAt!))
            : t.billNeverExpires,
    ];
    final amount = debt ? -b.remaining.abs() : b.remaining;
    return Padding(
      key: ValueKey('bucket-${b.bucket}'),
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(bucketIcon(b.bucket),
            size: 22, color: debt ? scheme.error : scheme.primary),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(bucketLabel(t, b.bucket),
                style: const TextStyle(fontWeight: FontWeight.w700)),
            for (final s in subs)
              Text(s, style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          ]),
        ),
        const SizedBox(width: Gap.sm),
        Text(fmtInt(context, amount),
            style: TextStyle(
                fontWeight: FontWeight.w800,
                fontFeatures: AFonts.tabular,
                color: debt ? scheme.error : scheme.onSurface)),
      ]),
    );
  }

  Widget _noCash(AppLocalizations t, ColorScheme scheme) => Row(
        key: const Key('credits-no-cash'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.sm),
          Expanded(
              child: Text(t.credoutNoCash,
                  style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant))),
        ],
      );

  Widget _costs(AppLocalizations t, ColorScheme scheme, CreditsState st) {
    final rows = [
      for (final e in st.actionCosts.entries)
        if (e.value > 0 && costLabel(t, e.key) != null) (costLabel(t, e.key)!, e.value, e.key),
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    if (rows.isEmpty) {
      return _strip(scheme, Icons.info_outline_rounded, t.billCostsEmpty,
          key: const Key('credits-costs-empty'));
    }
    return _card(scheme, [
      for (final r in rows)
        Padding(
          key: ValueKey('cost-${r.$3}'),
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Expanded(child: Text(r.$1)),
            const SizedBox(width: Gap.sm),
            Text(t.creditsPackCredits(fmtInt(context, r.$2)),
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ]),
        ),
      const Divider(height: Gap.md),
      Text(t.billCostsNote,
          style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
    ]);
  }

  List<Widget> _history(AppLocalizations t, ColorScheme scheme) {
    if (_ledger.isEmpty && _histLoading) {
      return const [
        Padding(
          padding: EdgeInsets.all(Gap.lg),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    if (_ledger.isEmpty && _histFailed) {
      return [
        _strip(scheme, Icons.cloud_off_rounded, t.billHistoryFailed),
        TextButton.icon(
          key: const Key('credits-history-retry'),
          style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: () => _loadHistory(reset: true),
          icon: const Icon(Icons.refresh_rounded),
          label: Text(t.retry),
        ),
      ];
    }
    if (_ledger.isEmpty) {
      return [
        _strip(scheme, Icons.receipt_long_rounded, t.billHistoryEmpty,
            key: const Key('credits-history-empty'))
      ];
    }
    return [
      for (final it in _ledger) _ledgerRow(t, scheme, it),
      if (_nextOffset != null || _histFailed)
        TextButton.icon(
          key: const Key('credits-history-more'),
          style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: _histLoading ? null : () => _loadHistory(),
          icon: _histLoading
              ? const SizedBox(
                  width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.expand_more_rounded),
          label: Text(_histFailed ? t.retry : t.billHistoryMore),
        ),
    ];
  }

  Widget _ledgerRow(AppLocalizations t, ColorScheme scheme, LedgerRow it) {
    final credit = it.delta >= 0;
    final label = ledgerLabel(t, it.reason, it.bucket, it.note);
    final sub = <String>[
      if (it.at != null) billDateTime(context, it.at!),
      if (it.bucket.isNotEmpty && it.bucket != 'legacy') bucketLabel(t, it.bucket),
    ].join(' · ');
    final amount = '${credit ? '+' : ''}${fmtInt(context, it.delta)}';
    return Semantics(
      label: '$label, $amount ${t.creditsUnit}${sub.isEmpty ? '' : ', $sub'}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.xs),
        child: Row(children: [
          Icon(credit ? Icons.add_circle_outline_rounded : Icons.remove_circle_outline_rounded,
              size: 20,
              color: credit ? Brand.onTint(context, Brand.success) : scheme.onSurfaceVariant),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label),
              if (sub.isNotEmpty)
                Text(sub, style: AType.labelSmall.copyWith(color: scheme.onSurfaceVariant)),
            ]),
          ),
          const SizedBox(width: Gap.sm),
          Text(amount,
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontFeatures: AFonts.tabular,
                  color: credit ? Brand.onTint(context, Brand.success) : scheme.onSurface)),
        ]),
      ),
    );
  }

  Widget _poolExplainer(AppLocalizations t, ColorScheme scheme, bool usedUp, int pool) {
    final tint = usedUp ? Brand.warning : scheme.primary;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: tint.withValues(alpha: 0.35)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(usedUp ? Icons.battery_alert_rounded : Icons.info_outline_rounded,
            color: usedUp ? Brand.onTint(context, Brand.warning) : tint, size: 22),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(usedUp ? t.creditsPoolUsedUpTitle : t.creditsNothingUnlimited,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: Gap.xxs),
            Text(
                usedUp
                    ? t.creditsPoolUsedUpBody
                    : t.creditsNothingUnlimitedBody(fmtInt(context, pool)),
                style: AType.bodySmall
                    .copyWith(color: scheme.onSurfaceVariant, height: 1.35)),
          ]),
        ),
      ]),
    );
  }

  Widget _packCard(AppLocalizations t, ColorScheme scheme, Map<String, dynamic> p) {
    final takaAmt = _int(p['taka']);
    final credits = _int(p['credits']);
    final playProd = payFlavour() == 'play'
        ? _payCfg?.product('play', 'pack_${p['code'] ?? p['id'] ?? ''}')
        : null;
    final storePrice = playProd == null ? null : PlayPrices.of(playProd);
    final priceOk = payFlavour() != 'play' || storePrice != null;
    final priceText = payFlavour() != 'play'
        ? '৳${fmtInt(context, takaAmt)}'
        : (storePrice != null
            ? localizeStoreDigits(context, storePrice)
            : t.payPriceUnavailable);
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: scheme.outlineVariant),
        ),
        padding: const EdgeInsets.all(Gap.md),
        child: Row(children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(Radii.sm)),
            child: Icon(Icons.bolt_rounded, color: scheme.primary),
          ),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.creditsPackCredits(fmtInt(context, credits)),
                  style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.xxs),
              // billing v2 + truth: bought pack credits NEVER expire (core/credits.py
              // rule B); the admin `valid_months` field is not enforced, so not shown.
              Text(t.billPackNeverExpires,
                  style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
            ]),
          ),
          const SizedBox(width: Gap.sm),
          Flexible(
            child: FilledButton(
              key: ValueKey('pack-buy-${p['code'] ?? p['id'] ?? ''}'),
              onPressed: (_buying || !priceOk) ? null : () => _topup(p),
              style: FilledButton.styleFrom(minimumSize: const Size(92, 48)),
              child: Text(priceText, textAlign: TextAlign.center),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _usageCard(AppLocalizations t, ColorScheme scheme,
      List<Map<String, dynamic>> rows, int total) {
    final sorted = [...rows]
      ..sort((a, b) => _int(b['credits']).compareTo(_int(a['credits'])));
    final max = sorted.isNotEmpty ? _int(sorted.first['credits']) : 0;
    return _card(scheme, [
      for (final r in sorted) ...[
        Row(children: [
          Expanded(child: Text(actionLabel(t, '${r['action']}'))),
          const SizedBox(width: Gap.sm),
          Text(fmtInt(context, _int(r['credits'])),
              style: const TextStyle(
                  fontWeight: FontWeight.w700, fontFeatures: AFonts.tabular)),
        ]),
        const SizedBox(height: Gap.xs),
        ClipRRect(
          borderRadius: BorderRadius.circular(Radii.pill),
          child: LinearProgressIndicator(
            value: max > 0 ? _int(r['credits']) / max : 0,
            minHeight: 6,
            backgroundColor: scheme.surfaceContainerHighest,
            valueColor: AlwaysStoppedAnimation(scheme.primary),
          ),
        ),
        const SizedBox(height: Gap.sm),
      ],
      const Divider(height: Gap.md),
      Row(children: [
        Expanded(
            child: Text(t.creditsMonthTotal,
                style: const TextStyle(fontWeight: FontWeight.w700))),
        Text(fmtInt(context, total), style: const TextStyle(fontWeight: FontWeight.w800)),
      ]),
    ]);
  }

  Widget _card(ColorScheme scheme, List<Widget> children) => Container(
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      );

  Widget _sectionTitle(String text, IconData icon, ColorScheme scheme) => Semantics(
        header: true,
        child: Row(children: [
          Icon(icon, size: 18, color: scheme.primary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(text,
                style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800)),
          ),
        ]),
      );

  Widget _strip(ColorScheme scheme, IconData icon, String text, {Key? key}) => Container(
        key: key,
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(children: [
          Icon(icon, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.md),
          Expanded(child: Text(text)),
        ]),
      );

  Widget _warn(ColorScheme scheme, String title, String body, {Key? key}) => Container(
        key: key,
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: TextStyle(
                      fontWeight: FontWeight.w700, color: scheme.onErrorContainer)),
              const SizedBox(height: Gap.xxs),
              Text(body, style: TextStyle(color: scheme.onErrorContainer, height: 1.35)),
            ]),
          ),
        ]),
      );
}
