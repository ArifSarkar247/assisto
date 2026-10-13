import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';

/// Plans / paywall — the "why pay" surface.
///
/// Benchmarked against Duolingo / Notion / Blinkist paywalls: lead with the
/// current entitlement + a concrete value hook, then a scannable plan list
/// where EACH paid plan spells out its everyday benefits as bullets, an
/// annual-saving nudge, and a standing promise that safety stays free.
///
/// Data: `api.plan()` -> current entitlement (name/desc/benefits/credits/
/// trial); `api.plansPublic()` -> every purchasable plan localized
/// (id/name/price/cur/period/desc/benefits/unlimited_ai/ads/family). Billing is
/// not wired yet, so upgrade shows a clean "Available when ___" state instead
/// of a dead button.
class PlansScreen extends StatefulWidget {
  const PlansScreen({super.key});
  @override
  State<PlansScreen> createState() => _PlansScreenState();
}

class _PlansScreenState extends State<PlansScreen> {
  Map<String, dynamic>? _p;
  List<Map<String, dynamic>> _all = [];
  bool _loading = true, _error = false, _busy = false, _annual = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final api = context.read<AppState>().api;
      final res = await Future.wait([api.plan(), api.plansPublic()]);
      _p = res[0] as Map<String, dynamic>;
      _all = (res[1] as List).cast<Map<String, dynamic>>();
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _rewarded() async {
    setState(() => _busy = true);
    try {
      final r = await context.read<AppState>().api.rewardedAd();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(r['ok'] == true
                ? AppLocalizations.of(context).plansCreditAdded
                : (r['msg'] ??
                        AppLocalizations.of(context).plansDailyLimitReached)
                    .toString())));
      }
      await _load();
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _notYet() {
    final t = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.plansBillingComingSoon)));
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
              : _body(t, scheme),
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
    // Paid plans, split so monthly/annual toggle can swap the premium card.
    final monthly = _all
        .where((p) => p['id'] != 'annual' && p['id'] != 'free')
        .toList();
    final annualPlan =
        _all.where((p) => p['id'] == 'annual').toList();
    final freePlan = _all.where((p) => p['id'] == 'free').toList();

    final visible = <Map<String, dynamic>>[
      if (_annual) ...annualPlan else ...monthly.where((p) => p['id'] == 'premium'),
      ...monthly.where((p) => p['id'] != 'premium'),
    ];

    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      _currentCard(t),
      const SizedBox(height: Gap.lg),
      _safetyPromise(t, scheme),
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
      ],
      const SizedBox(height: Gap.md),
      Text(t.purchasingTurnsOnWhenA,
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
    ]);
  }

  bool _isFeatured(dynamic id) =>
      (_annual && id == 'annual') || (!_annual && id == 'premium');

  Widget _billingToggle(AppLocalizations t, ColorScheme scheme) {
    return SegmentedButton<bool>(
      showSelectedIcon: false,
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 12)),
      ),
      segments: [
        ButtonSegment(value: false, label: Text(t.plansMonthly)),
        ButtonSegment(value: true, label: Text(t.plansYearly)),
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
            color: Colors.white24, borderRadius: BorderRadius.circular(Radii.pill)),
        child: Text(text,
            style: const TextStyle(
                color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
      );

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
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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

  Widget _planCard(AppLocalizations t, ColorScheme scheme,
      Map<String, dynamic> p,
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
              style:
                  OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
              child: Text(isCurrent ? t.plansCurrentTag : t.plansIncluded),
            )
          else if (isCurrent)
            FilledButton.tonal(
              onPressed: null,
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(44)),
              child: Text(t.plansCurrentTag),
            )
          else
            FilledButton.icon(
              onPressed: _notYet,
              icon: const Icon(Icons.lock_open_outlined, size: 18),
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                  backgroundColor: highlighted ? null : scheme.secondaryContainer,
                  foregroundColor:
                      highlighted ? null : scheme.onSecondaryContainer),
              label: Text(t.plansChoose(_planLabel(p))),
            ),
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
