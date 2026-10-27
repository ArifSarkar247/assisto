import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';

import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../widgets/skeleton.dart';
import '../widgets/storage_meter.dart';
import '../widgets/rewarded_ad_sheet.dart';
import '../ads/ads_service.dart';
import '../widgets/ladder_common.dart' show fmtInt;
import '../widgets/bn_day_periods.dart' show appDateLocale;
import '../payments/checkout_sheet.dart'; // pay1
import '../services/error_kind.dart' show honestFailText; // qa2
import '../payments/payments_api.dart'
    show ApiPaymentsBackend, PayConfig, payFlavour; // pay1
import '../widgets/paywall_sheet.dart'; // p2-money
import '../payments/play_prices.dart'; // credout: Play's own prices

/// CREDITS screen (Business Model Build 3, item 2).
///
/// One place for everything about the AI-credit economy:
///  - live balance + included monthly pool + ad-wallet balance,
///  - buy top-up packs (prices/credits/validity straight from the server),
///  - this-month usage by action (me/usage-summary) + the ledger
///    (credits/history),
///  - the always-visible storage meter (reused widget), and
///  - a "pool used up -> buy credits" explainer.
///
/// HONESTY: every number comes from the server. Tapping a pack opens the
/// pay1 checkout sheet; with no payment channel set up it says so honestly —
/// we NEVER render a fake checkout or grant credits on the device. The rewarded-ad option is shown to FREE users
/// only and is itself honest when AdMob is not enabled.
class CreditsScreen extends StatefulWidget {
  const CreditsScreen({super.key});
  @override
  State<CreditsScreen> createState() => _CreditsScreenState();
}

class _CreditsScreenState extends State<CreditsScreen> {
  bool _loading = true;
  bool _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
  bool _buying = false;

  Map<String, dynamic> _usage = const {}; // me/usage-summary
  Map<String, dynamic> _history = const {}; // credits/history
  List<Map<String, dynamic>> _packs = const [];
  // NO SHOWPIECES: the "watch an ad" entry shows only when a rewarded ad can
  // really play (AdMob configured server-side).
  bool _adsReady = false;
  // pay1 + NO SHOWPIECES: live payment channels (null = none / unknown).
  PayConfig? _payCfg;

  @override
  void initState() {
    super.initState();
    _load();
  }

  int _int(dynamic v) => v is num ? v.toInt() : 0;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    final api = context.read<AppState>().api;
    try {
      final res = await Future.wait([
        api.meUsageSummary(),
        api.creditsHistory(),
        api.creditsPacks(),
      ]);
      _usage = res[0] as Map<String, dynamic>;
      _history = res[1] as Map<String, dynamic>;
      _packs = (res[2] as List).cast<Map<String, dynamic>>();
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    // NO SHOWPIECES: a pack is buyable only through a LIVE channel
    // (/payments/config: owner switch on AND keys added). No channel -> no
    // buy buttons; the "no packs right now" strip shows instead.
    try {
      _payCfg = await ApiPaymentsBackend(api).config(payFlavour());
    } catch (_) {
      _payCfg = null;
    }
    final cfg = _payCfg;
    _packs = cfg == null
        ? const []
        : _packs
            .where((p) => cfg.canBuy(
                'pack_${p['code'] ?? p['id'] ?? ''}', payFlavour()))
            .toList();
    // credout: the Play build shows Play's own pack prices only.
    if (payFlavour() == 'play' && cfg != null) {
      await PlayPrices.ensure(cfg.products['play'] ?? const []);
    }
    if (mounted) {
      _adsReady = await AdsService.instance
          .rewardedAvailable(context.read<AppState>());
    }
    if (mounted) setState(() => _loading = false);
  }

  bool get _isFree {
    final plan = (_usage['plan'] ?? '').toString().toLowerCase();
    return plan.isEmpty || plan == 'free';
  }

  /// pay1: a pack opens the ONE checkout sheet (Google Play first on the
  /// Play build; EPS bKash/Nagad/card on the website APK). Credits are added
  /// only after our server verified the payment.
  Future<void> _topup(Map<String, dynamic> pack) async {
    final code = (pack['code'] ?? pack['id'] ?? '').toString();
    if (code.isEmpty) return;
    setState(() => _buying = true);
    try {
      final ok =
          await CheckoutSheet.show(context, 'pack_$code', flavour: payFlavour());
      if (ok == true && mounted) await _load();
    } finally {
      if (mounted) setState(() => _buying = false);
    }
  }

  Future<void> _watchAds() async {
    final credited = await RewardedAdSheet.show(context);
    if (credited == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.creditsTitle),
        actions: [
          if (!_loading && !_error)
            IconButton(
                tooltip: t.refresh,
                icon: const Icon(Icons.refresh_rounded),
                onPressed: _load),
        ],
      ),
      body: _loading
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
              : RefreshIndicator(onRefresh: _load, child: _body(t, scheme)),
    );
  }

  Widget _body(AppLocalizations t, ColorScheme scheme) {
    final balance = _int(_usage['balance']);
    final pool = _int(_usage['included_pool']);
    final adWallet = _int(_usage['ad_wallet_credits']);
    final monthTotal = _int(_usage['month_total']);
    final poolUsedUp = pool > 0 && balance <= 0;

    final usageRows = (_usage['month_usage'] as List?)
            ?.whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList() ??
        const <Map<String, dynamic>>[];
    final ledger = (_history['items'] as List?)
            ?.whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList() ??
        const <Map<String, dynamic>>[];
    final buckets = (_history['expiry_buckets'] as List?)
            ?.whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList() ??
        const <Map<String, dynamic>>[];

    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xxl),
      children: [
        _balanceHero(t, balance, pool, adWallet, monthTotal),
        const SizedBox(height: Gap.lg),

        // Pool-used-up explainer (also the "nothing unlimited" honesty line).
        _poolExplainer(t, scheme, poolUsedUp, pool),
        const SizedBox(height: Gap.lg),
        // p2-money: out of credits on Free -> the paywall with that reason
        if (_isFree && balance + adWallet <= 0) ...[
          FilledButton.tonalIcon(
            key: const Key('p2-credits-paywall'),
            onPressed: () => PaywallSheet.show(context, PaywallReason.outOfCredits),
            icon: const Icon(Icons.workspace_premium_rounded),
            label: Text(t.p2GetPremium),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
          ),
          const SizedBox(height: Gap.lg),
        ],

        // Storage meter (reused widget). Buy-storage CTA just nudges to packs
        // below (same credits economy) — honest, no fake purchase.
        StorageMeter(
          initial: (_usage['storage'] as Map?)?.cast<String, dynamic>(),
          onBuyStorage: () {
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(t.storageBuyHint)));
          },
        ),
        const SizedBox(height: Gap.lg),

        // Top-up packs.
        _sectionTitle(t.creditsPacksTitle, Icons.shopping_cart_rounded, scheme),
        const SizedBox(height: Gap.sm),
        if (_packs.isEmpty)
          _infoStrip(scheme, t.creditsPacksEmpty)
        else
          for (final p in _packs) _packCard(t, scheme, p),

        // FREE users: honest "earn via ads" option.
        if (_adsReady && _isFree) ...[
          const SizedBox(height: Gap.sm),
          OutlinedButton.icon(
            onPressed: _buying ? null : _watchAds,
            icon: const Icon(Icons.ondemand_video_rounded, size: 18),
            label: Text(t.adEarnCredits),
            style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(46)),
          ),
        ] else if (_adsReady) ...[
          // Premium/Business: NO ads — unless the user opts in here.
          const SizedBox(height: Gap.sm),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: const Icon(Icons.ondemand_video_rounded),
              title: Text(t.adsPaidOptInTitle),
              subtitle: Text(t.adsPaidOptInSub),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _buying ? null : _watchAds,
            ),
          ),
        ],

        // This month by action.
        if (usageRows.isNotEmpty) ...[
          const SizedBox(height: Gap.xl),
          _sectionTitle(t.creditsThisMonthTitle, Icons.insights_rounded, scheme),
          const SizedBox(height: Gap.sm),
          _usageCard(t, scheme, usageRows, monthTotal),
        ],

        // Expiry buckets (validity).
        if (buckets.isNotEmpty) ...[
          const SizedBox(height: Gap.xl),
          _sectionTitle(t.creditsExpiryTitle, Icons.schedule_rounded, scheme),
          const SizedBox(height: Gap.sm),
          for (final b in buckets) _bucketRow(t, scheme, b),
        ],

        // Ledger.
        if (ledger.isNotEmpty) ...[
          const SizedBox(height: Gap.xl),
          _sectionTitle(t.creditsHistoryTitle, Icons.receipt_long_rounded, scheme),
          const SizedBox(height: Gap.sm),
          for (final it in ledger) _ledgerRow(t, scheme, it),
        ],
      ],
    );
  }

  Widget _balanceHero(AppLocalizations t, int balance, int pool, int adWallet,
      int monthTotal) {
    return Container(
      decoration: BoxDecoration(
          gradient: Brand.gradient,
          borderRadius: BorderRadius.circular(Radii.lg)),
      padding: const EdgeInsets.all(Gap.xl),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t.creditsBalanceLabel,
            style: AType.bodySmall.copyWith(color: Colors.white70)),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Icon(Icons.bolt_rounded, color: Colors.white, size: 30),
          const SizedBox(width: Gap.xs),
          Text(fmtInt(context, balance),
              style: AType.displayMedium.copyWith(color: Colors.white,
                  fontFeatures: AFonts.tabular, fontWeight: FontWeight.w800)),
          const SizedBox(width: 6),
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(t.creditsUnit,
                style: AType.bodyMedium.copyWith(color: Colors.white70)),
          ),
        ]),
        const SizedBox(height: Gap.md),
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          _heroPill(Icons.calendar_month_rounded,
              t.creditsIncludedPool(fmtInt(context, pool))),
          _heroPill(Icons.ondemand_video_rounded,
              t.creditsAdWallet(fmtInt(context, adWallet))),
          _heroPill(Icons.trending_up_rounded,
              t.creditsUsedThisMonth(fmtInt(context, monthTotal))),
        ]),
      ]),
    );
  }

  Widget _heroPill(IconData icon, String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: 6),
        decoration: BoxDecoration(
            color: Colors.white24,
            borderRadius: BorderRadius.circular(Radii.pill)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: Colors.white),
          const SizedBox(width: 6),
          Flexible( // qa1: wraps at large font
            child: Text(text,
                style: AType.bodySmall.copyWith(color: Colors.white,
                    fontWeight: FontWeight.w600)),
          ),
        ]),
      );

  Widget _poolExplainer(
      AppLocalizations t, ColorScheme scheme, bool usedUp, int pool) {
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
            color: tint, size: 22),
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
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant,
                    height: 1.35)),
          ]),
        ),
      ]),
    );
  }

  Widget _packCard(
      AppLocalizations t, ColorScheme scheme, Map<String, dynamic> p) {
    final takaAmt = _int(p['taka']);
    final credits = _int(p['credits']);
    // credout: Play build -> Play's formatted price; unknown -> honest text,
    // no buy (pull to refresh asks the store again).
    final playProd = payFlavour() == 'play'
        ? _payCfg?.product('play', 'pack_${p['code'] ?? p['id'] ?? ''}')
        : null;
    final storePrice = playProd == null ? null : PlayPrices.of(playProd);
    final priceOk = payFlavour() != 'play' || storePrice != null;
    final priceText = payFlavour() != 'play'
        ? '\u09F3${fmtInt(context, takaAmt)}'
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
                  style:
                      AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.xxs),
              // truth: bought pack credits NEVER expire (core/credits.py
              // rule B; legal_content.py says the same). The admin
              // `valid_months` field is not enforced, so it is not shown.
              Text(t.truthPackNeverExpires,
                  style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
            ]),
          ),
          const SizedBox(width: Gap.sm),
          Flexible(
            child: FilledButton(
              key: ValueKey('pack-buy-${p['code'] ?? p['id'] ?? ''}'),
              onPressed: (_buying || !priceOk) ? null : () => _topup(p),
              style: FilledButton.styleFrom(minimumSize: const Size(92, 48)),
              // Taka sign by code point (keeps the language gate strict).
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
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(children: [
        for (final r in sorted) ...[
          Row(children: [
            Expanded(
              child: Text(_actionLabel(t, '${r['action']}'),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
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
          Text(fmtInt(context, total),
              style: const TextStyle(fontWeight: FontWeight.w800)),
        ]),
      ]),
    );
  }

  Widget _bucketRow(
      AppLocalizations t, ColorScheme scheme, Map<String, dynamic> b) {
    final credits = _int(b['credits']);
    final when = (b['expires_at'] ?? b['month'] ?? b['label'] ?? '').toString();
    String label = when;
    final dt = DateTime.tryParse(when);
    if (dt != null) {
      label = DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag())
          .format(dt.toLocal());
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(children: [
        Icon(Icons.schedule_rounded, size: 16, color: scheme.onSurfaceVariant),
        const SizedBox(width: Gap.sm),
        Expanded(
            child: Text(t.creditsExpiresOn(label),
                style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant))),
        Text(t.creditsPackCredits(fmtInt(context, credits)),
            style: AType.titleSmall.copyWith(fontWeight: FontWeight.w600)),
      ]),
    );
  }

  Widget _ledgerRow(
      AppLocalizations t, ColorScheme scheme, Map<String, dynamic> it) {
    final delta = _int(it['credits'] ?? it['delta'] ?? it['amount']);
    final credit = delta >= 0;
    final reason = (it['reason'] ?? it['action'] ?? it['kind'] ?? '').toString();
    final at = (it['created_at'] ?? it['at'] ?? '').toString();
    String when = at;
    final dt = DateTime.tryParse(at);
    if (dt != null) {
      when = DateFormat('d MMM, h:mm a', appDateLocale(context)).format(dt.toLocal());
    }
    final color = credit ? Brand.success : scheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(children: [
        Icon(credit ? Icons.add_circle_outline_rounded : Icons.remove_circle_outline_rounded,
            size: 18, color: credit ? Brand.success : scheme.onSurfaceVariant),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(reason.isEmpty ? t.creditsLedgerEntry : _actionLabel(t, reason),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            if (when.isNotEmpty)
              Text(when,
                  style: AType.labelSmall.copyWith(color: scheme.onSurfaceVariant)),
          ]),
        ),
        Text('${credit ? '+' : ''}${fmtInt(context, delta)}',
            style: TextStyle(
                fontWeight: FontWeight.w700, color: color, fontFeatures: AFonts.tabular)),
      ]),
    );
  }

  /// Localized label for a usage/ledger action code (the ledger `note` the
  /// server groups by: billing.charge action, "photo:<feature>",
  /// "vision:chat", "shop_extra_camera"). QA qa1: the most common codes
  /// (ai_msg_cheap / ai_msg_strong) were missing and showed raw to users;
  /// unknown codes now read "Other" instead of an internal name.
  String _actionLabel(AppLocalizations t, String code) {
    if (code.startsWith('photo:')) return t.creditsActionPhotoStudio;
    if (code.startsWith('vision:')) return t.creditsActionChatPhoto;
    switch (code) {
      case 'ai_msg_cheap':
      case 'ai_msg_strong':
      case 'ai_chat':
        return t.creditsActionAiChat;
      case 'scan_ocr':
        return t.creditsActionScan;
      case 'shop_extra_camera':
        return t.creditsActionShopCamera;
      case 'ai_reply':
      case 'ai_drafting':
        return t.creditsActionAiDraft;
      case 'inbox_summary':
      case 'ai_inbox_summary':
        return t.creditsActionInboxSummary;
      case 'scam_check':
      case 'ai_scam_check':
        return t.creditsActionScamCheck;
      case 'photo_enhance':
      case 'cloud_photo_enhance':
        return t.creditsActionPhotoEnhance;
      case 'studio':
        return t.creditsActionStudio;
      case 'topup':
      case 'purchase':
        return t.creditsActionTopup;
      case 'rewarded':
      case 'ad_reward':
        return t.creditsActionAdReward;
      case 'monthly_pool':
      case 'included':
        return t.creditsActionMonthlyPool;
      default:
        return t.creditsActionOther;
    }
  }

  Widget _sectionTitle(String text, IconData icon, ColorScheme scheme) => Row(
        children: [
          Icon(icon, size: 18, color: scheme.primary),
          const SizedBox(width: Gap.sm),
          Text(text,
              style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800)),
        ],
      );

  Widget _infoStrip(ColorScheme scheme, String text) => Container(
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(children: [
          Icon(Icons.info_outline_rounded, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.md),
          Expanded(child: Text(text)),
        ]),
      );
}
