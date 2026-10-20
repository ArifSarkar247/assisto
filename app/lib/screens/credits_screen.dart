import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';

import '../api.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../widgets/skeleton.dart';
import '../widgets/storage_meter.dart';
import '../widgets/rewarded_ad_sheet.dart';
import '../widgets/ladder_common.dart' show fmtInt;

/// Taka sign (U+09F3) via code point so no Bangla-block literal lives in source
/// (keeps the language gate strict — mirrors ladder_common). Pack prices come
/// from the server as whole-taka ints, so we format them directly rather than
/// via [taka] (which expects poisha).
const _takaSign = '\u09F3';

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
/// HONESTY: every number comes from the server. Tapping a pack calls
/// `credits/topup`; with no payment provider wired the server returns
/// `needs_provider` and we show the honest "payment setup pending" state — we
/// NEVER render a fake checkout. The rewarded-ad option is shown to FREE users
/// only and is itself honest when AdMob is not enabled.
class CreditsScreen extends StatefulWidget {
  const CreditsScreen({super.key});
  @override
  State<CreditsScreen> createState() => _CreditsScreenState();
}

class _CreditsScreenState extends State<CreditsScreen> {
  bool _loading = true;
  bool _error = false;
  bool _buying = false;

  Map<String, dynamic> _usage = const {}; // me/usage-summary
  Map<String, dynamic> _history = const {}; // credits/history
  List<Map<String, dynamic>> _packs = const [];

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
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  bool get _isFree {
    final plan = (_usage['plan'] ?? '').toString().toLowerCase();
    return plan.isEmpty || plan == 'free';
  }

  Future<void> _topup(Map<String, dynamic> pack) async {
    final t = AppLocalizations.of(context);
    final code = (pack['code'] ?? pack['id'] ?? '').toString();
    if (code.isEmpty) return;
    setState(() => _buying = true);
    try {
      final r = await context.read<AppState>().api.creditsTopup(code);
      if (!mounted) return;
      final state = (r['state'] ?? '').toString();
      if (state == 'confirmed') {
        await _load();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(t.creditsTopupConfirmed)));
        }
      } else {
        // 'needs_provider' | 'pending' | anything else -> honest sheet.
        _showTopupStateSheet(state, r);
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      _showTopupStateSheet('needs_provider', {'message': e.message});
    } catch (_) {
      if (!mounted) return;
      _showTopupStateSheet('needs_provider', const {});
    } finally {
      if (mounted) setState(() => _buying = false);
    }
  }

  void _showTopupStateSheet(String state, Map<String, dynamic> r) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final pending = state == 'pending';
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(pending ? Icons.schedule : Icons.construction_outlined,
              size: 44, color: pending ? scheme.secondary : Brand.warning),
          const SizedBox(height: Gap.md),
          Text(pending ? t.creditsTopupPendingTitle : t.creditsNoProviderTitle,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center),
          const SizedBox(height: Gap.sm),
          Text(
            (r['message'] ?? '').toString().isNotEmpty
                ? '${r['message']}'
                : (pending
                    ? t.creditsTopupPendingBody
                    : t.creditsNoProviderBody),
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
          ),
          const SizedBox(height: Gap.lg),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
                onPressed: () => Navigator.pop(context), child: Text(t.ok)),
          ),
        ]),
      ),
    );
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
                icon: const Icon(Icons.refresh),
                onPressed: _load),
        ],
      ),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off,
                  tint: scheme.error,
                  title: t.loadFailed,
                  message: t.loadFailedBody,
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
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
        _sectionTitle(t.creditsPacksTitle, Icons.shopping_cart_outlined, scheme),
        const SizedBox(height: Gap.sm),
        if (_packs.isEmpty)
          _infoStrip(scheme, t.creditsPacksEmpty)
        else
          for (final p in _packs) _packCard(t, scheme, p),

        // FREE users: honest "earn via ads" option.
        if (_isFree) ...[
          const SizedBox(height: Gap.sm),
          OutlinedButton.icon(
            onPressed: _watchAds,
            icon: const Icon(Icons.ondemand_video_outlined, size: 18),
            label: Text(t.adEarnCredits),
            style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(46)),
          ),
        ],

        // This month by action.
        if (usageRows.isNotEmpty) ...[
          const SizedBox(height: Gap.xl),
          _sectionTitle(t.creditsThisMonthTitle, Icons.insights_outlined, scheme),
          const SizedBox(height: Gap.sm),
          _usageCard(t, scheme, usageRows, monthTotal),
        ],

        // Expiry buckets (validity).
        if (buckets.isNotEmpty) ...[
          const SizedBox(height: Gap.xl),
          _sectionTitle(t.creditsExpiryTitle, Icons.schedule_outlined, scheme),
          const SizedBox(height: Gap.sm),
          for (final b in buckets) _bucketRow(t, scheme, b),
        ],

        // Ledger.
        if (ledger.isNotEmpty) ...[
          const SizedBox(height: Gap.xl),
          _sectionTitle(t.creditsHistoryTitle, Icons.receipt_long_outlined, scheme),
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
            style: const TextStyle(color: Colors.white70, fontSize: 12)),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Icon(Icons.bolt, color: Colors.white, size: 30),
          const SizedBox(width: 4),
          Text(fmtInt(context, balance),
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 34,
                  fontWeight: FontWeight.w800)),
          const SizedBox(width: 6),
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(t.creditsUnit,
                style: const TextStyle(color: Colors.white70, fontSize: 13)),
          ),
        ]),
        const SizedBox(height: Gap.md),
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          _heroPill(Icons.calendar_month,
              t.creditsIncludedPool(fmtInt(context, pool))),
          _heroPill(Icons.ondemand_video_outlined,
              t.creditsAdWallet(fmtInt(context, adWallet))),
          _heroPill(Icons.trending_up,
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
          Text(text,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
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
        Icon(usedUp ? Icons.battery_alert_outlined : Icons.info_outline,
            color: tint, size: 22),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(usedUp ? t.creditsPoolUsedUpTitle : t.creditsNothingUnlimited,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(
                usedUp
                    ? t.creditsPoolUsedUpBody
                    : t.creditsNothingUnlimitedBody(fmtInt(context, pool)),
                style: TextStyle(
                    fontSize: 12.5,
                    color: scheme.onSurfaceVariant,
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
    final months = _int(p['valid_months']);
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
            child: Icon(Icons.bolt, color: scheme.primary),
          ),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.creditsPackCredits(fmtInt(context, credits)),
                  style:
                      const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              const SizedBox(height: 2),
              Text(t.creditsPackValidity(fmtInt(context, months)),
                  style: TextStyle(
                      fontSize: 12, color: scheme.onSurfaceVariant)),
            ]),
          ),
          const SizedBox(width: Gap.sm),
          FilledButton(
            onPressed: _buying ? null : () => _topup(p),
            style: FilledButton.styleFrom(minimumSize: const Size(92, 42)),
            child: Text('\$_takaSign${fmtInt(context, takaAmt)}'),
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
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 4),
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
        Icon(Icons.schedule, size: 16, color: scheme.onSurfaceVariant),
        const SizedBox(width: Gap.sm),
        Expanded(
            child: Text(t.creditsExpiresOn(label),
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant))),
        Text(t.creditsPackCredits(fmtInt(context, credits)),
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
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
      when = DateFormat('d MMM, h:mm a').format(dt.toLocal());
    }
    final color = credit ? Brand.success : scheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Icon(credit ? Icons.add_circle_outline : Icons.remove_circle_outline,
            size: 18, color: credit ? Brand.success : scheme.onSurfaceVariant),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(reason.isEmpty ? t.creditsLedgerEntry : _actionLabel(t, reason),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            if (when.isNotEmpty)
              Text(when,
                  style: TextStyle(
                      fontSize: 11, color: scheme.onSurfaceVariant)),
          ]),
        ),
        Text('${credit ? '+' : ''}${fmtInt(context, delta)}',
            style: TextStyle(fontWeight: FontWeight.w700, color: color)),
      ]),
    );
  }

  /// Localized label for a usage/ledger action code; unknown codes fall back to
  /// the raw code (never a crash, never "null").
  String _actionLabel(AppLocalizations t, String code) {
    switch (code) {
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
        return code;
    }
  }

  Widget _sectionTitle(String text, IconData icon, ColorScheme scheme) => Row(
        children: [
          Icon(icon, size: 18, color: scheme.primary),
          const SizedBox(width: Gap.sm),
          Text(text,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
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
          Icon(Icons.info_outline, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.md),
          Expanded(child: Text(text)),
        ]),
      );
}
