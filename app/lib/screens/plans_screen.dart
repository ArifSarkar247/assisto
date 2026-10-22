import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import '../l10n/app_localizations.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../widgets/plans_compare_table.dart';
import '../widgets/plans_referral_section.dart';
import '../widgets/plans_faq.dart';
import '../widgets/ladder_common.dart' show fmtInt;
import 'credits_screen.dart';

/// Plans / monetization — the "why pay (or earn) it" surface (SPEC v2.1 §21).
///
/// ADVANCED upgrade over the old paywall: it now leads with the current
/// entitlement, keeps the safety-stays-free promise, then gives a scannable
/// plan list AND a per-feature "what you get" comparison matrix, a referral
/// block where Premium time can be *earned* (balance + progress + redeem +
/// points history), an honest manage/cancel + billing note, an
/// annual-vs-monthly explainer computed from the REAL owner-set prices, and a
/// short FAQ. Every price shown comes straight from the backend catalogue
/// (`api.plansPublic()`) — the app never invents or changes a price.
///
/// Section 21 states all handled: loading (skeleton), error (retry),
/// success-empty (no-plans strip), offline (banner + cached-ish behaviour),
/// bilingual (all copy via ARB, zero Bangla in Dart), WCAG (brand/scheme
/// tokens, semantics on table dashes + progress), and a real scenario flow
/// (view -> compare -> invite/redeem -> earn Premium days).
///
/// Data: `api.plan()` -> current entitlement; `api.plansPublic()` -> every
/// purchasable plan; `api.referralBalance()` + `api.referralHistory()` ->
/// points balance / redeemable days / ledger; `api.referralRedeem()` applies
/// Premium days server-side. Billing is not wired yet, so upgrade shows a
/// clean "available when ___" state instead of a dead button.
class PlansScreen extends StatefulWidget {
  const PlansScreen({super.key});
  @override
  State<PlansScreen> createState() => _PlansScreenState();
}

class _PlansScreenState extends State<PlansScreen> {
  Map<String, dynamic>? _p;
  List<Map<String, dynamic>> _all = [];

  // Referral block — loaded alongside plans; failure here must NOT kill the
  // paywall, so it has its own flags and the body degrades gracefully.
  Map<String, dynamic>? _ref;
  List<Map<String, dynamic>> _refHistory = [];
  bool _refFailed = false;

  bool _loading = true, _error = false, _busy = false, _annual = false;
  bool _showHistory = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
      _refFailed = false;
    });
    final api = context.read<AppState>().api;
    try {
      final res = await Future.wait([api.plan(), api.plansPublic()]);
      _p = res[0] as Map<String, dynamic>;
      _all = (res[1] as List).cast<Map<String, dynamic>>();
    } catch (_) {
      _error = true;
    }
    // Referral loads separately so a referral outage never blanks the paywall.
    try {
      final r = await Future.wait([api.referralBalance(), api.referralHistory()]);
      _ref = r[0];
      _refHistory =
          ((r[1]['history'] ?? []) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      _refFailed = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  /// a6: ads never play on the plans/payment screen. The "watch an ad"
  /// button opens the Credits screen, where the rewarded flow plays a REAL
  /// ad first (the old direct /credits/rewarded call granted a credit with no
  /// ad shown once AdMob was enabled).
  Future<void> _rewarded() async {
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => const CreditsScreen()));
    if (mounted) await _load();
  }

  // NO SHOWPIECES: there is no in-app plan checkout yet, so the old
  // "Choose <plan>" button could only say "billing isn't connected" — it is
  // removed. Add it back together with a real checkout.

  int _int(dynamic v) => v is num ? v.toInt() : 0;

  Future<void> _invite() async {
    final t = AppLocalizations.of(context);
    final link = (_ref?['invite_link'] ?? '').toString();
    final msg = link.isNotEmpty
        ? '${t.referralShareMessage}\n$link'
        : t.referralShareMessage;
    await Share.share(msg);
  }

  Future<void> _redeem() async {
    final t = AppLocalizations.of(context);
    final b = _ref;
    if (b == null) return;
    final points = _int(b['points']);
    final perDay = _int(b['points_per_day']);
    final maxDays = perDay > 0 ? points ~/ perDay : 0;
    if (maxDays < 1) return;

    final days = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _RedeemSheet(maxDays: maxDays, pointsPerDay: perDay),
    );
    if (days == null || days < 1) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final r =
          await context.read<AppState>().api.referralRedeem(days * perDay);
      final granted = _int(r['days']);
      messenger.showSnackBar(SnackBar(
          content: Text(r['ok'] == true
              ? t.referralRedeemedDays(granted)
              : t.referralRedeemFailed)));
      await _load();
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(t.referralRedeemFailed)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.planCredits)),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off,
                  tint: scheme.error,
                  title: t.loadFailed,
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: Text(t.retry)))
              : RefreshIndicator(onRefresh: _load, child: _body(t, scheme)),
    );
  }

  /// Never render the literal "null": fall back name -> plan slug -> ''.
  String _planLabel(Map<String, dynamic> p) {
    final name = (p['name'] ?? '').toString();
    if (name.isNotEmpty) return name;
    return (p['plan'] ?? p['id'] ?? '').toString();
  }

  Widget _body(AppLocalizations t, ColorScheme scheme) {
    final current = (_p?['plan'] ?? '').toString();
    final online = context.watch<AppState>().online;

    // Paid plans, split so monthly/annual toggle can swap the premium card.
    final monthly =
        _all.where((p) => p['id'] != 'annual' && p['id'] != 'free').toList();
    final annualPlan = _all.where((p) => p['id'] == 'annual').toList();
    final freePlan = _all.where((p) => p['id'] == 'free').toList();

    final visible = <Map<String, dynamic>>[
      if (_annual)
        ...annualPlan
      else
        ...monthly.where((p) => p['id'] == 'premium'),
      ...monthly.where((p) => p['id'] != 'premium'),
    ];

    final annualRow = annualPlan.isNotEmpty ? annualPlan.first : null;
    final premiumRow =
        monthly.where((p) => p['id'] == 'premium').toList();

    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      if (!online) _offlineBanner(t, scheme),
      _currentCard(t),
      const SizedBox(height: Gap.lg),
      _safetyPromise(t, scheme),
      const SizedBox(height: Gap.md),
      // Honest allowance explainer: NOTHING is unlimited. Each paid plan
      // includes a MONTHLY credit pool; when it's used up you buy credits.
      _allowanceNote(t, scheme),
      const SizedBox(height: Gap.sm),
      // Entry to the Credits screen (balance / packs / usage / storage).
      OutlinedButton.icon(
        onPressed: () => Navigator.push(context,
            MaterialPageRoute(builder: (_) => const CreditsScreen())),
        icon: const Icon(Icons.bolt, size: 18),
        label: Text(t.plansManageCredits),
        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
      ),
      const SizedBox(height: Gap.lg),
      Row(children: [
        Expanded(
          child: Text(t.plansChooseYourPlan,
              style:
                  const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
        ),
        if (annualPlan.isNotEmpty) _billingToggle(t, scheme),
      ]),
      const SizedBox(height: Gap.md),
      if (_all.isEmpty)
        // Success-but-empty: /plans returned []. Keep the current-plan + safety
        // promise above; just say there's nothing else to show (no dead UI).
        Container(
          padding: const EdgeInsets.all(Gap.lg),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(Radii.md),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Row(children: [
            Icon(Icons.info_outline, color: scheme.onSurfaceVariant),
            const SizedBox(width: Gap.md),
            Expanded(child: Text(t.plansEmptyState)),
          ]),
        )
      else ...[
        for (final p in visible)
          _planCard(t, scheme, p,
              highlighted: _isFeatured(p['id']), current: current),
        for (final p in freePlan)
          _planCard(t, scheme, p, highlighted: false, current: current),

        // ---- Per-feature "what you get" comparison matrix (Section 21) ----
        const SizedBox(height: Gap.lg),
        Text(t.plansCompareTitle,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
        const SizedBox(height: 2),
        Text(t.plansCompareSubtitle,
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.md),
        PlansCompareTable(plans: _all, current: current),
      ],

      const SizedBox(height: Gap.sm),
      Text(t.purchasingTurnsOnWhenA,
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),

      // ---- Earn Premium days by inviting (referral) ----
      const SizedBox(height: Gap.xl),
      const Divider(height: 1),
      const SizedBox(height: Gap.lg),
      PlansReferralSection(
        balance: _ref,
        history: _refHistory,
        failed: _refFailed,
        busy: _busy,
        onInvite: _invite,
        onRedeem: _redeem,
        showHistory: _showHistory,
        onToggleHistory: () => setState(() => _showHistory = !_showHistory),
      ),

      // ---- Annual-vs-monthly + manage/cancel + FAQ ----
      const SizedBox(height: Gap.xl),
      const Divider(height: 1),
      const SizedBox(height: Gap.lg),
      PlansFaq(
        annualPlan: annualRow,
        monthlyPremium: premiumRow.isNotEmpty ? premiumRow.first : null,
      ),
      const SizedBox(height: Gap.xl),
    ]);
  }

  Widget _offlineBanner(AppLocalizations t, ColorScheme scheme) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.md),
        child: Container(
          padding: const EdgeInsets.all(Gap.md),
          decoration: BoxDecoration(
            color: Brand.warning.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(Radii.md),
            border: Border.all(color: Brand.warning.withValues(alpha: 0.4)),
          ),
          child: Row(children: [
            Icon(Icons.wifi_off, size: 20, color: Brand.warning),
            const SizedBox(width: Gap.md),
            Expanded(
                child: Text(t.plansOfflineNote,
                    style: const TextStyle(fontSize: 13))),
          ]),
        ),
      );

  bool _isFeatured(dynamic id) =>
      (_annual && id == 'annual') || (!_annual && id == 'premium');

  Widget _billingToggle(AppLocalizations t, ColorScheme scheme) {
    // Size the segment labels on the Text widgets (not via a bare TextStyle on
    // the button) so they keep inheriting the app font family — a plain
    // TextStyle(fontSize:) on the button strips the family and the labels fall
    // back to a glyph-less font (rendering as empty boxes/bars).
    const seg = TextStyle(fontSize: 12);
    return SegmentedButton<bool>(
      showSelectedIcon: false,
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
      ),
      segments: [
        ButtonSegment(value: false, label: Text(t.plansMonthly, style: seg)),
        ButtonSegment(value: true, label: Text(t.plansYearly, style: seg)),
      ],
      selected: {_annual},
      onSelectionChanged: (s) => setState(() => _annual = s.first),
    );
  }

  Widget _currentCard(AppLocalizations t) {
    final p = _p!;
    final credits = p['credits'] ?? 0;
    final trial = p['trial_active'] == true;
    final unlimited = p['unlimited_ai'] == true;
    return Container(
      decoration: BoxDecoration(
          gradient: Brand.gradient,
          borderRadius: BorderRadius.circular(Radii.lg)),
      padding: const EdgeInsets.all(Gap.xl),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t.currentPlan,
            style: const TextStyle(color: Colors.white70, fontSize: 12)),
        Text(_planLabel(p),
            style: const TextStyle(
                color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800)),
        if ((p['desc'] ?? '').toString().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text('${p['desc']}',
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ),
        if (trial)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: _pill(t.freeTrialActive),
          ),
        const SizedBox(height: Gap.md),
        Row(children: [
          const Icon(Icons.bolt, color: Colors.white, size: 20),
          const SizedBox(width: 6),
          Text(unlimited ? t.unlimitedAi : t.aiCreditsCount(credits),
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600)),
        ]),
        if (!unlimited) ...[
          const SizedBox(height: Gap.md),
          FilledButton.tonalIcon(
            onPressed: _busy ? null : _rewarded,
            icon: const Icon(Icons.ondemand_video, size: 18),
            label: Text(t.watchAnAd1Credit),
          ),
        ],
      ]),
    );
  }

  Widget _pill(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 2),
        decoration: BoxDecoration(
            color: Colors.white24,
            borderRadius: BorderRadius.circular(Radii.pill)),
        child: Text(text,
            style: const TextStyle(
                color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
      );

  /// "Nothing is unlimited" honesty line — paid plans ship a MONTHLY credit
  /// pool; when it runs out you buy credits (never a surprise cap).
  Widget _allowanceNote(AppLocalizations t, ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.info_outline, color: scheme.primary, size: 20),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.plansNothingUnlimitedTitle,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(t.plansNothingUnlimitedBody,
                style: TextStyle(
                    fontSize: 12.5,
                    color: scheme.onSurfaceVariant,
                    height: 1.35)),
          ]),
        ),
      ]),
    );
  }

  /// The MONTHLY allowance (included credit pool) for a plan, read straight
  /// from the server catalogue. Tries a few shapes the backend might use.
  int _includedPool(Map<String, dynamic> p) {
    final v = p['included_pool'] ??
        p['included_credits'] ??
        p['credits'] ??
        p['pool'];
    return v is num ? v.toInt() : 0;
  }

  /// Safety-stays-free promise — never cripple emergency / scam / medicine.
  Widget _safetyPromise(AppLocalizations t, ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: Brand.success.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: Brand.success.withValues(alpha: 0.35)),
      ),
      child: Row(children: [
        Icon(Icons.verified_user_outlined, color: Brand.success, size: 22),
        const SizedBox(width: Gap.md),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.plansSafetyAlwaysFreeTitle,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(t.plansSafetyAlwaysFreeBody,
                style:
                    TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ]),
        ),
      ]),
    );
  }

  Widget _planCard(
      AppLocalizations t, ColorScheme scheme, Map<String, dynamic> p,
      {required bool highlighted, required String current}) {
    final id = (p['id'] ?? '').toString();
    final isCurrent = id == current;
    final benefits =
        (p['benefits'] as List?)?.cast<String>() ?? const <String>[];
    final isBusiness = id == 'business';
    final isFree = id == 'free';

    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.md),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(
            color: highlighted ? scheme.primary : scheme.outlineVariant,
            width: highlighted ? 1.6 : 1,
          ),
        ),
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(_planLabel(p),
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 17)),
            ),
            if (highlighted && !isCurrent)
              _tag(scheme, t.plansMostPopular, scheme.primary),
            if (isCurrent) _tag(scheme, t.plansCurrentTag, Brand.success),
          ]),
          const SizedBox(height: 2),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(_priceLabel(p),
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 22,
                    color: scheme.primary)),
            const SizedBox(width: 4),
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(_periodLabel(t, p),
                  style:
                      TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ),
          ]),
          if ((p['desc'] ?? '').toString().isNotEmpty) ...[
            const SizedBox(height: 2),
            Text('${p['desc']}',
                style:
                    TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
          ],
          // Monthly allowance (included credit pool). Free plans show no pool.
          if (!isFree && _includedPool(p) > 0) ...[
            const SizedBox(height: Gap.sm),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: Gap.md, vertical: 6),
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.calendar_month, size: 16, color: scheme.primary),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                      t.plansMonthlyAllowance(
                          fmtInt(context, _includedPool(p))),
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: scheme.primary)),
                ),
              ]),
            ),
          ],
          const SizedBox(height: Gap.md),
          for (final b in benefits) _benefitRow(scheme, b),
          if (isBusiness) ...[
            const SizedBox(height: Gap.sm),
            Text(t.plansCrmSeatsReview,
                style: TextStyle(
                    fontSize: 11,
                    fontStyle: FontStyle.italic,
                    color: scheme.onSurfaceVariant)),
          ],
          const SizedBox(height: Gap.md),
          if (isFree)
            OutlinedButton(
              onPressed: null,
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(44)),
              child: Text(isCurrent ? t.plansCurrentTag : t.plansIncluded),
            )
          else if (isCurrent)
            FilledButton.tonal(
              onPressed: null,
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(44)),
              child: Text(t.plansCurrentTag),
            )
        ]),
      ),
    );
  }

  Widget _benefitRow(ColorScheme scheme, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.check_circle, size: 17, color: Brand.success),
          const SizedBox(width: Gap.sm),
          Expanded(
              child: Text(text,
                  style: const TextStyle(fontSize: 13, height: 1.35))),
        ]),
      );

  Widget _tag(ColorScheme scheme, String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
        decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(Radii.pill)),
        child: Text(text,
            style: TextStyle(
                color: color, fontSize: 11, fontWeight: FontWeight.w700)),
      );

  String _priceLabel(Map<String, dynamic> p) {
    final price = p['price'];
    final cur = (p['cur'] ?? 'BDT').toString();
    if (price == 0 || price == 0.0) return _curSign(cur) + '0';
    return _curSign(cur) + _fmt(price);
  }

  String _curSign(String cur) => cur == 'USD' ? '\$' : '৳';

  String _fmt(dynamic n) {
    if (n is num && n == n.roundToDouble()) {
      final s = n.round().toString();
      // thousands separator
      final b = StringBuffer();
      for (int i = 0; i < s.length; i++) {
        if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
        b.write(s[i]);
      }
      return b.toString();
    }
    return n.toString();
  }

  String _periodLabel(AppLocalizations t, Map<String, dynamic> p) {
    switch ((p['period'] ?? 'mo').toString()) {
      case 'yr':
        return t.plansPerYear;
      case 'life':
        return t.plansLifetime;
      default:
        return t.plansPerMonth;
    }
  }
}

/// Bottom sheet to pick how many Premium days to redeem (1..maxDays). Mirrors
/// the Referral screen's sheet so redeeming feels the same on both surfaces.
class _RedeemSheet extends StatefulWidget {
  final int maxDays;
  final int pointsPerDay;
  const _RedeemSheet({required this.maxDays, required this.pointsPerDay});
  @override
  State<_RedeemSheet> createState() => _RedeemSheetState();
}

class _RedeemSheetState extends State<_RedeemSheet> {
  late int _days = 1;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final cost = _days * widget.pointsPerDay;
    final maxD = widget.maxDays < 1 ? 1 : widget.maxDays;
    return Padding(
      padding: EdgeInsets.only(
          left: Gap.lg,
          right: Gap.lg,
          top: Gap.lg,
          bottom: Gap.lg + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.referralRedeem,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Gap.sm),
            Text(t.referralRedeemPickDays,
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.md),
            Text(t.referralRedeemDaysChosen(_days),
                style: const TextStyle(fontWeight: FontWeight.w700)),
            Slider(
              value: _days.toDouble(),
              min: 1,
              max: maxD.toDouble(),
              divisions: maxD > 1 ? maxD - 1 : null,
              label: '$_days',
              onChanged: (v) => setState(() => _days = v.round()),
            ),
            Text(t.referralRedeemCost(cost),
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.lg),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(_days),
                child: Text(t.referralRedeemConfirm),
              ),
            ),
          ]),
    );
  }
}
