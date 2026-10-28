import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../business_ai_api.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/business_ui.dart';
import '../../widgets/skeleton.dart';
import '../plans_screen.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// Per-product bargaining rules (PAID).
///
/// - list price + MINIMUM price (minimum shown READ-ONLY as the hard floor).
/// - allowed discount steps, bundle min qty, free-delivery-over threshold.
/// - negotiation tone.
/// - Explicit in the UI: selling below minimum is IMPOSSIBLE and routes to the
///   owner ("I'll check with the owner"). The floor is enforced in code, not AI.
class BargainRulesScreen extends StatefulWidget {
  const BargainRulesScreen({super.key});
  @override
  State<BargainRulesScreen> createState() => _BargainRulesScreenState();
}

class _BargainRulesScreenState extends State<BargainRulesScreen> {
  bool _loading = true;
  bool _locked = false;
  String? _error;
  List<Map<String, dynamic>> _rules = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final api = context.read<AppState>().api;
    try {
      _rules = await api.bargainRules();
      _locked = false;
    } catch (e) {
      if (isUpgradeRequired(e)) {
        _locked = true;
      } else {
        _error = e.toString();
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  void _openPlans() => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => const PlansScreen()));

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr.bizBargainTitle)),
      body: _body(tr),
    );
  }

  Widget _body(AppLocalizations tr) {
    if (_loading) return const SkeletonList();
    if (_locked) {
      return BizPremiumGate(featureLine: tr.bizBargainGateLine, onUpgrade: _openPlans);
    }
    if (_error != null) {
      return StateMessage(
        icon: Icons.cloud_off_rounded,
        title: tr.bizLoadFailed,
        message: _error,
        action: FilledButton(onPressed: _load, child: Text(tr.bizRetry)),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(Gap.lg), children: [
        // The core rule, stated plainly.
        BizNote(text: tr.bizBelowMinImpossible, icon: Icons.lock_outline_rounded),
        const SizedBox(height: Gap.md),
        if (_rules.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xl),
            child: StateMessage(
              icon: Icons.sell_rounded,
              title: tr.bizBargainEmptyTitle,
              message: tr.bizBargainEmptyBody,
            ),
          )
        else
          for (final r in _rules) ...[
            _ruleCard(tr, r),
            const SizedBox(height: Gap.md),
          ],
      ]),
    );
  }

  Widget _ruleCard(AppLocalizations tr, Map<String, dynamic> r) {
    final name = (r['name'] ?? '').toString();
    final list = r['list_price'];
    final min = r['min_price'];
    final steps = ((r['discount_steps'] ?? []) as List).map((e) => e.toString()).toList();
    final freeOver = r['free_delivery_over'];
    final bundle = r['bundle_min_qty'];
    final tone = (r['tone'] ?? '').toString();
    return BizCard(
      title: name,
      icon: Icons.sell_rounded,
      trailing: IconButton(
        tooltip: tr.bizEdit,
        icon: const Icon(Icons.edit_rounded),
        onPressed: () => _edit(tr, r),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: _kv(tr.bizListPrice, '৳$list')),
          // Minimum is READ-ONLY: the hard floor.
          Expanded(
            child: Row(children: [
              Expanded(child: _kv(tr.bizMinPriceFloor, '৳$min')),
              Icon(Icons.lock_rounded, size: 14, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ]),
          ),
        ]),
        const SizedBox(height: Gap.sm),
        if (steps.isNotEmpty) ...[
          Text(tr.bizDiscountSteps, style: _label()),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            for (final s in steps) Chip(label: Text(s), visualDensity: VisualDensity.compact),
          ]),
          const SizedBox(height: Gap.sm),
        ],
        if (freeOver != null) _kv(tr.bizFreeDeliveryOver, '৳$freeOver'),
        if (bundle != null) _kv(tr.bizBundleMinQty, '$bundle'),
        if (tone.isNotEmpty) _kv(tr.bizTone, tone),
      ]),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.xs),
        // db1: one wrapping run — a fixed label overflowed the half-width
        // "Minimum price (floor)" column by 11px at 360dp (tap sweep).
        child: Text.rich(TextSpan(children: [
          TextSpan(text: '$k: ', style: _label()),
          TextSpan(text: v, style: const TextStyle(fontWeight: FontWeight.w600)),
        ])),
      );

  TextStyle _label() =>
      AType.bodyMedium.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);

  Future<void> _edit(AppLocalizations tr, Map<String, dynamic> r) async {
    final steps = TextEditingController(
        text: ((r['discount_steps'] ?? []) as List).join(', '));
    final freeOver = TextEditingController(text: (r['free_delivery_over'] ?? '').toString());
    final bundle = TextEditingController(text: (r['bundle_min_qty'] ?? '').toString());
    final tone = TextEditingController(text: (r['tone'] ?? '').toString());
    final ok = await showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: Gap.lg,
          right: Gap.lg,
          top: Gap.lg,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + Gap.lg,
        ),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr.bizEditRules,
              style: Theme.of(ctx).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.md),
          // Minimum is NOT editable here — surfaced read-only so it's clear.
          BizNote(text: tr.bizMinNotEditableHere, icon: Icons.lock_outline_rounded),
          const SizedBox(height: Gap.md),
          TextField(controller: steps, decoration: InputDecoration(labelText: tr.bizDiscountSteps)),
          const SizedBox(height: Gap.sm),
          TextField(controller: freeOver, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: tr.bizFreeDeliveryOver)),
          const SizedBox(height: Gap.sm),
          TextField(controller: bundle, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: tr.bizBundleMinQty)),
          const SizedBox(height: Gap.sm),
          TextField(controller: tone, decoration: InputDecoration(labelText: tr.bizTone)),
          const SizedBox(height: Gap.lg),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr.bizSave)),
        ]),
      ),
    );
    if (ok != true || !mounted) return;
    final api = context.read<AppState>().api;
    try {
      final parsedSteps = steps.text
          .split(RegExp(r'[,\s]+'))
          .where((s) => s.trim().isNotEmpty)
          .toList();
      await api.bargainRuleSave((r['product_id'] as num).toInt(), {
        'discount_steps': parsedSteps,
        if (freeOver.text.trim().isNotEmpty)
          'free_delivery_over': num.tryParse(freeOver.text.trim()),
        if (bundle.text.trim().isNotEmpty)
          'bundle_min_qty': int.tryParse(bundle.text.trim()),
        'tone': tone.text.trim(),
      });
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }
}
