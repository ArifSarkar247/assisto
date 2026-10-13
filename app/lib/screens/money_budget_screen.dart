import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import 'money_common.dart';

/// One budget category across months, showing the rollover carry-in/out.
/// Data from GET /money/budget?category=... (money_engine.budget_with_rollover).
class MoneyBudgetScreen extends StatefulWidget {
  final String category;
  const MoneyBudgetScreen({super.key, required this.category});
  @override
  State<MoneyBudgetScreen> createState() => _MoneyBudgetScreenState();
}

class _MoneyBudgetScreenState extends State<MoneyBudgetScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      _data =
          await context.read<AppState>().api.moneyBudgetDetail(widget.category);
    } catch (_) {
      _failed = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  Color _stateColor(String? s) {
    switch (s) {
      case 'over':
        return Brand.danger;
      case 'near':
        return Brand.warning;
      default:
        return Brand.success;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.category), actions: [
        IconButton(onPressed: _load, icon: const Icon(Icons.sync)),
      ]),
      body: _loading
          ? const SkeletonList(count: 4)
          : _failed
              ? StateMessage(
                  icon: Icons.cloud_off_outlined,
                  title: widget.category,
                  message: t.moneySummaryOffline,
                  action: FilledButton(onPressed: _load, child: Text(t.retry)),
                )
              : _body(context, t),
    );
  }

  Widget _body(BuildContext context, AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    final rollover = _data?['rollover'] == true;
    final months = (_data?['months'] as List?)?.cast<Map<String, dynamic>>() ??
        [];
    final carry = dbl(_data?['carry_forward']);
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      Row(children: [
        Icon(rollover ? Icons.autorenew : Icons.block, size: 18),
        const SizedBox(width: Gap.sm),
        Text(rollover ? t.moneyRolloverOn : t.moneyRolloverOff,
            style: const TextStyle(fontWeight: FontWeight.w600)),
      ]),
      const SizedBox(height: Gap.md),
      if (rollover)
        Card(
          color: scheme.secondaryContainer,
          child: ListTile(
            leading: Icon(Icons.savings_outlined,
                color: scheme.onSecondaryContainer),
            title: Text(t.moneyCarryForward,
                style: TextStyle(color: scheme.onSecondaryContainer)),
            trailing: Text(tkFmt(carry),
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: scheme.onSecondaryContainer)),
          ),
        ),
      const SizedBox(height: Gap.md),
      for (final m in months)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('${m['month']}',
                            style:
                                const TextStyle(fontWeight: FontWeight.bold)),
                        Text(
                            '${tkFmt(m['spent'])} / ${tkFmt(m['effective_limit'])}'),
                      ]),
                  const SizedBox(height: Gap.sm),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(Radii.sm),
                    child: LinearProgressIndicator(
                        value: ((m['pct'] as num?)?.toInt() ?? 0).clamp(0, 100) /
                            100,
                        minHeight: 8,
                        color: _stateColor(m['state'])),
                  ),
                  const SizedBox(height: Gap.sm),
                  Wrap(spacing: Gap.lg, runSpacing: Gap.xs, children: [
                    _chip(context, t.moneyBaseLimit, tkFmt(m['base_limit'])),
                    if (rollover)
                      _chip(context, t.moneyCarriedIn,
                          tkFmt(m['carried_in'])),
                    _chip(context, t.moneyRemaining, tkFmt(m['remaining'])),
                  ]),
                ]),
          ),
        ),
    ]);
  }

  Widget _chip(BuildContext context, String label, String value) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label: ',
            style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
        Text(value,
            style:
                const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      ]);
}
