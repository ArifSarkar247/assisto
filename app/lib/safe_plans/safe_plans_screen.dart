import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';
import '../widgets/chatnav.dart';
import '../widgets/ladder_common.dart' show fmtInt;
import '../widgets/local_counter.dart';
import 'safe_ad_unlock_screen.dart';
import 'safe_plans_api.dart';

/// safeplans — "Safety plans" screen (route `safe_plans`, switch default
/// OFF). Follows the existing plans screen: gradient "your plan" card, the
/// green "safety is always free" card, plan cards with Play's own price.
/// Never shows an ad (plans/payment screens are fenced); the "watch ads"
/// card opens [SafeAdUnlockScreen] (screen key `credits`).
class SafePlansScreen extends StatefulWidget {
  final SafePlansApi? api;
  const SafePlansScreen({super.key, this.api});

  @override
  State<SafePlansScreen> createState() => _SafePlansScreenState();
}

class _SafePlansScreenState extends State<SafePlansScreen> {
  Map<String, dynamic>? _st;
  Map<String, String> _prices = const {};
  bool _loading = true, _failed = false, _busy = false;
  late SafePlansApi _api;

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? SafePlansDeps.debugApi ?? ApiSafePlansApi(context.read<AppState>().api);
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final st = await _api.load();
      final ids = <String>{
        for (final p in (st['pack_products'] as List? ?? const [])) '${spMap(p)['id']}',
        '${spMap(spMap(st['plans'])['child'])['product_id']}',
        '${spMap(spMap(st['plans'])['family'])['product_id']}',
      };
      final prices = await SafePlansBuyer(_api).prices(ids);
      if (!mounted) return;
      setState(() {
        _st = st;
        _prices = prices;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  String _price(String productId, [String base = '']) =>
      _prices[productId] ?? (base.isEmpty ? '' : _prices['$productId/$base'] ?? '');

  Future<void> _buy(String productId, {bool sub = false}) async {
    final t = AppLocalizations.of(context);
    final m = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    final r = await SafePlansBuyer(_api).buy(
        productId: productId,
        basePlanId: sub ? '${_st?['base_plan_id'] ?? 'monthly'}' : '',
        subscription: sub,
        accountId: '${_st?['play_account_id'] ?? ''}');
    if (!mounted) return;
    setState(() => _busy = false);
    final msg = switch (r) {
      SafeBuyStatus.done => t.spBuyDone,
      SafeBuyStatus.pending => t.spBuyPending,
      SafeBuyStatus.cancelled => t.spBuyCancelled,
      SafeBuyStatus.unavailable => t.spPlayOnly,
      SafeBuyStatus.failed => t.spBuyFailed,
    };
    m.showSnackBar(SnackBar(content: Text(msg)));
    if (r == SafeBuyStatus.done) _load();
  }

  Future<void> _school() async {
    final ok = await showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _SchoolCodeSheet(api: _api, children: [
        for (final c in (_st?['children'] as List? ?? const [])) spMap(c)
      ]),
    );
    if (ok == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.spTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _failed || _st == null
              ? _Retry(onTap: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: withNavBarInset(
                        context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xl)),
                    children: _body(context, t, _st!),
                  ),
                ),
    );
  }

  List<Widget> _body(BuildContext context, AppLocalizations t, Map<String, dynamic> st) {
    final plans = spMap(st['plans']);
    final child = spMap(plans['child']), fam = spMap(plans['family']);
    final school = spMap(plans['school']);
    final bal = spMap(st['balance']);
    final ads = spMap(st['ads']);
    final plan = '${st['plan']}';
    final onSale = st['on_sale'] == true;
    String n(dynamic v) => fmtInt(context, spInt(v));
    final planName = switch (plan) {
      'child' => t.spPlanChild,
      'family' => t.spPlanFamily,
      _ => t.spPlanFree,
    };
    return [
      _HeaderCard(
        label: t.spCurrentPlan,
        name: planName,
        badge: st['source'] == 'ads' ? t.spFromAds : null,
        line: t.spRequestsLeft(n(bal['total'])),
        note: t.spResetsNote,
      ),
      const SizedBox(height: Gap.md),
      _AlwaysFreeCard(title: t.spAlwaysFreeTitle, body: t.spAlwaysFreeBody),
      const SizedBox(height: Gap.lg),
      Text(t.spChoose, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: Gap.sm),
      _PlanCard(
        title: t.spPlanChild,
        price: _price('${child['product_id']}', '${st['base_plan_id']}'),
        current: plan == 'child' && st['source'] == 'play',
        features: [
          t.spChildF1(n(child['children']), n(child['guardians'])),
          t.spChildF2,
          t.spChildF3(n(child['requests'])),
        ],
        action: _buyAction(t, onSale, '${child['product_id']}', true, plan == 'child' && st['source'] == 'play'),
      ),
      const SizedBox(height: Gap.md),
      _PlanCard(
        title: t.spPlanFamily,
        price: _price('${fam['product_id']}', '${st['base_plan_id']}'),
        current: plan == 'family',
        features: [
          t.spFamF1(n(fam['members'])),
          t.spFamF2(n(fam['credits']), n(spMap(st['costs'])['location_request']),
              n(spMap(st['costs'])['live_trip'])),
          t.spFamF3(n(fam['history_days']), n(fam['update_min'])),
        ],
        action: _buyAction(t, onSale, '${fam['product_id']}', true, plan == 'family'),
      ),
      const SizedBox(height: Gap.md),
      _PlanCard(
        title: t.spSchoolTitle,
        price: '',
        current: (st['schools'] as List? ?? const []).isNotEmpty,
        features: [
          t.spSchoolBody,
          t.spSchoolF1(n(school['guardians']), n(school['requests'])),
          t.spSchoolF2,
        ],
        action: SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            icon: const Icon(Icons.school_outlined),
            label: Text(t.spEnterCode),
            onPressed: _busy ? null : _school,
          ),
        ),
      ),
      for (final s in (st['schools'] as List? ?? const []))
        Padding(
          padding: const EdgeInsets.only(top: Gap.sm),
          child: Text(t.spSchoolActive('${spMap(s)['name']}', n(spMap(s)['left'])),
              style: Theme.of(context).textTheme.bodyMedium),
        ),
      const SizedBox(height: Gap.lg),
      Text(t.spMoreTitle, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: Gap.xs),
      Text(t.spPackNote(n(st['pack_valid_days'])), style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: Gap.sm),
      Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
        for (final p in (st['pack_products'] as List? ?? const []))
          _packButton(t, onSale, spMap(p), n),
      ]),
      if (!onSale)
        Padding(
          padding: const EdgeInsets.only(top: Gap.sm),
          child: Text(t.spNotOnSale, style: Theme.of(context).textTheme.bodySmall),
        ),
      if (ads['eligible'] == true) ...[
        const SizedBox(height: Gap.lg),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.spAdsTitle, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: Gap.xs),
              Text(t.spAdsDay(n(ads['for_day']))),
              Text(t.spAdsReq(n(ads['for_request']))),
              const SizedBox(height: Gap.sm),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  icon: const Icon(Icons.play_circle_outline),
                  label: Text(t.spAdsOpen),
                  onPressed: () async {
                    await Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => SafeAdUnlockScreen(api: _api)));
                    _load();
                  },
                ),
              ),
            ]),
          ),
        ),
      ],
    ];
  }

  Widget _buyAction(AppLocalizations t, bool onSale, String productId, bool sub, bool current) {
    if (current) return Text(t.spCurrent, style: const TextStyle(fontWeight: FontWeight.w600));
    if (!onSale) return Text(t.spNotOnSale);
    final price = _price(productId, '${_st?['base_plan_id']}');
    if (price.isEmpty) {
      return SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: _load,
          child: Text(t.spPriceRetry),
        ),
      );
    }
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        onPressed: _busy ? null : () => _buy(productId, sub: sub),
        child: Text(t.spBuyFor(price)),
      ),
    );
  }

  Widget _packButton(AppLocalizations t, bool onSale, Map<String, dynamic> p, String Function(dynamic) n) {
    final price = _price('${p['id']}');
    final label = price.isEmpty
        ? t.spPackRequests(n(p['requests']))
        : '${t.spPackRequests(n(p['requests']))} · $price';
    return OutlinedButton(
      style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
      onPressed: (!onSale || _busy)
          ? null
          : price.isEmpty
              ? _load
              : () => _buy('${p['id']}'),
      child: Text(label),
    );
  }
}

class _Retry extends StatelessWidget {
  final VoidCallback onTap;
  const _Retry({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(t.spLoadFailed, textAlign: TextAlign.center),
          const SizedBox(height: Gap.md),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
            onPressed: onTap,
            child: Text(t.spRetry),
          ),
        ]),
      ),
    );
  }
}

class _HeaderCard extends StatelessWidget {
  final String label, name, line, note;
  final String? badge;
  const _HeaderCard(
      {required this.label, required this.name, required this.line, required this.note, this.badge});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Semantics(
      container: true,
      child: Container(
        padding: const EdgeInsets.all(Gap.xl),
        decoration: BoxDecoration(
            gradient: Brand.gradient, borderRadius: BorderRadius.circular(Radii.lg)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: tt.bodyMedium?.copyWith(color: Colors.white)),
          Text(name, style: tt.headlineMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
          if (badge != null)
            Container(
              margin: const EdgeInsets.only(top: Gap.xs),
              padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xxs),
              decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(Radii.pill)),
              child: Text(badge!, style: tt.labelMedium?.copyWith(color: Colors.white)),
            ),
          const SizedBox(height: Gap.sm),
          Text(line, style: tt.titleMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.xs),
          Text(note, style: tt.bodySmall?.copyWith(color: Colors.white)),
        ]),
      ),
    );
  }
}

class _AlwaysFreeCard extends StatelessWidget {
  final String title, body;
  const _AlwaysFreeCard({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final green = Brand.onTint(context, const Color(0xFF16A34A));
    return Container(
      padding: const EdgeInsets.all(Gap.lg),
      decoration: BoxDecoration(
        color: const Color(0xFF16A34A).withValues(alpha: 0.10),
        border: Border.all(color: const Color(0xFF16A34A).withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.verified_user_outlined, color: green),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(color: s.onSurface)),
            const SizedBox(height: Gap.xs),
            Text(body, style: Theme.of(context).textTheme.bodyMedium),
          ]),
        ),
      ]),
    );
  }
}

class _PlanCard extends StatelessWidget {
  final String title, price;
  final bool current;
  final List<String> features;
  final Widget action;
  const _PlanCard(
      {required this.title,
      required this.price,
      required this.current,
      required this.features,
      required this.action});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.lg),
        side: BorderSide(color: current ? s.primary : s.outlineVariant, width: current ? 2 : 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          if (price.isNotEmpty)
            Text(price, style: tt.headlineSmall?.copyWith(color: s.primary, fontWeight: FontWeight.w800)),
          const SizedBox(height: Gap.sm),
          for (final f in features)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.xs),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.check_circle, size: 20, color: Brand.onTint(context, const Color(0xFF16A34A))),
                const SizedBox(width: Gap.sm),
                Expanded(child: Text(f, style: tt.bodyMedium)),
              ]),
            ),
          const SizedBox(height: Gap.sm),
          action,
        ]),
      ),
    );
  }
}

class _SchoolCodeSheet extends StatefulWidget {
  final SafePlansApi api;
  final List<Map<String, dynamic>> children;
  const _SchoolCodeSheet({required this.api, required this.children});

  @override
  State<_SchoolCodeSheet> createState() => _SchoolCodeSheetState();
}

class _SchoolCodeSheetState extends State<_SchoolCodeSheet> {
  final _code = TextEditingController();
  int? _child;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.children.length == 1) _child = spInt(widget.children.first['id']);
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final t = AppLocalizations.of(context);
    if (_child == null || _code.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    Map<String, dynamic> r;
    try {
      r = await widget.api.redeemSchool(_code.text.trim(), _child!);
    } on ApiException {
      r = const {'ok': false, 'reason': 'error'};
    }
    if (!mounted) return;
    if (r['ok'] == true) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _error = switch ('${r['reason']}') {
        'bad_code' => t.spCodeBad,
        'school_full' => t.spCodeFull,
        'too_many_guardians' => t.spCodeGuardians,
        _ => t.spCodeFailed,
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
          Gap.lg, Gap.xs, Gap.lg, Gap.lg + MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t.spEnterCode, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: Gap.xs),
        Text(t.spSchoolBody),
        const SizedBox(height: Gap.md),
        if (widget.children.isEmpty) ...[
          Text(t.spNoChildren),
          const SizedBox(height: Gap.sm),
          FilledButton.tonal(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () {
              Navigator.of(context).pop(false);
              ChatNav.push(context, 'circle');
            },
            child: Text(t.spOpenCircle),
          ),
        ] else ...[
          Text(t.spPickChild, style: Theme.of(context).textTheme.titleSmall),
          Wrap(spacing: Gap.sm, children: [
            for (final c in widget.children)
              ChoiceChip(
                label: Text('${c['name']}'),
                selected: _child == spInt(c['id']),
                onSelected: (_) => setState(() => _child = spInt(c['id'])),
              ),
          ]),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _code,
            maxLength: 12,
            buildCounter: localCounter,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(labelText: t.spCodeLabel, errorText: _error),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: Gap.sm),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: (_busy || _child == null || _code.text.trim().isEmpty) ? null : _send,
              child: Text(t.spCodeSend),
            ),
          ),
        ],
      ]),
    );
  }
}

/// The approved "requests used up" sheet: buy credits / watch ads / move to
/// Safe Family. Shown when the server answers 402 `safe_credits_out`.
/// SOS and safety alerts are never blocked, and the sheet says so.
Future<void> showSafeCreditsOutSheet(BuildContext context, Map<String, dynamic>? sheet) {
  final opts = spMap(sheet?['options']);
  return showAppSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) {
      final t = AppLocalizations.of(ctx);
      void open(Widget w) {
        Navigator.of(ctx).pop();
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
      }

      final any = opts['buy'] == true || opts['ads'] == true || opts['upgrade'] == true;
      return Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.xs, Gap.lg, Gap.lg),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.spOutTitle, style: Theme.of(ctx).textTheme.titleLarge),
          const SizedBox(height: Gap.xs),
          Text(t.spOutBody),
          const SizedBox(height: Gap.md),
          if (opts['buy'] == true)
            _OutButton(icon: Icons.add_shopping_cart, label: t.spOutBuy, onTap: () => open(const SafePlansScreen())),
          if (opts['ads'] == true)
            _OutButton(
                icon: Icons.play_circle_outline,
                label: t.spOutAds(fmtInt(ctx, spInt(sheet?['ads_for_request']))),
                onTap: () => open(const SafeAdUnlockScreen())),
          if (opts['upgrade'] == true)
            _OutButton(icon: Icons.family_restroom, label: t.spOutUpgrade, onTap: () => open(const SafePlansScreen())),
          if (!any) Text(t.spOutNone),
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(t.spNotNow),
          ),
        ]),
      );
    },
  );
}

class _OutButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _OutButton({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.sm),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.tonalIcon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            icon: Icon(icon),
            label: Text(label),
            onPressed: onTap,
          ),
        ),
      );
}
