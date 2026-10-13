import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import 'money_common.dart';
import 'money_report_screen.dart';

/// Trends: month-over-month income/expense/net bars + per-category movement.
/// Data from GET /money/trends (money_engine.month_over_month + category_trends).
class MoneyTrendsScreen extends StatefulWidget {
  const MoneyTrendsScreen({super.key});
  @override
  State<MoneyTrendsScreen> createState() => _MoneyTrendsScreenState();
}

class _MoneyTrendsScreenState extends State<MoneyTrendsScreen> {
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
      _data = await context.read<AppState>().api.moneyTrends();
    } catch (_) {
      _failed = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.moneyTrendsTitle), actions: [
        IconButton(
            tooltip: t.moneyReportTitle,
            icon: const Icon(Icons.description_outlined),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const MoneyReportScreen()))),
        IconButton(onPressed: _load, icon: const Icon(Icons.sync)),
      ]),
      body: _loading
          ? const SkeletonList(count: 5)
          : _failed
              ? StateMessage(
                  icon: Icons.cloud_off_outlined,
                  title: t.moneyTrendsTitle,
                  message: t.moneySummaryOffline,
                  action: FilledButton(
                      onPressed: _load, child: Text(t.retry)),
                )
              : _body(context, t),
    );
  }

  Widget _body(BuildContext context, AppLocalizations t) {
    final months =
        (_data?['months'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final cats = (_data?['categories'] as List?)?.cast<Map<String, dynamic>>() ??
        [];
    if (months.isEmpty && cats.isEmpty) {
      return StateMessage(
          icon: Icons.insights_outlined,
          title: t.moneyTrendsTitle,
          message: t.moneyNoTransactionsHint);
    }
    final maxVal = months.fold<double>(0, (p, m) {
      final hi = dbl(m['income']) > dbl(m['expense'])
          ? dbl(m['income'])
          : dbl(m['expense']);
      return hi > p ? hi : p;
    });
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      Text(t.moneyMonthlyFlow,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
      const SizedBox(height: Gap.md),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final m in months)
                Expanded(child: _monthBars(context, t, m, maxVal)),
            ],
          ),
        ),
      ),
      const SizedBox(height: Gap.lg),
      Row(children: [
        _legend(context, Brand.success, t.moneyMonthIncome),
        const SizedBox(width: Gap.lg),
        _legend(context, Brand.danger, t.moneyMonthExpense),
      ]),
      const SizedBox(height: Gap.xl),
      Text(t.moneyCategoryTrends,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
      const SizedBox(height: Gap.sm),
      for (final c in cats)
        Card(
          child: ListTile(
            title: Text('${c['category']}'),
            subtitle: Text(t.moneyVsLastMonth(tkFmt(c['previous']))),
            trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(tkFmt(c['current']),
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  deltaChip(context, dbl(c['delta'])),
                ]),
          ),
        ),
    ]);
  }

  Widget _monthBars(
      BuildContext context, AppLocalizations t, Map m, double maxVal) {
    final inc = maxVal > 0 ? (dbl(m['income']) / maxVal).clamp(0.02, 1.0) : 0.0;
    final exp = maxVal > 0 ? (dbl(m['expense']) / maxVal).clamp(0.02, 1.0) : 0.0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Column(children: [
        SizedBox(
          height: 110,
          child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _bar(inc, Brand.success),
                const SizedBox(width: 3),
                _bar(exp, Brand.danger),
              ]),
        ),
        const SizedBox(height: Gap.xs),
        Builder(builder: (_) {
          // month is 'YYYY-MM'; show 'MM'. Guard null/short strings so a
          // malformed value can't throw RangeError on .substring(5).
          final ms = '${m['month'] ?? ''}';
          final label = ms.length >= 6 ? ms.substring(5) : ms;
          return Text(label, style: const TextStyle(fontSize: 11));
        }),
      ]),
    );
  }

  Widget _bar(double frac, Color color) => Expanded(
        child: FractionallySizedBox(
          heightFactor: frac,
          child: Container(
            decoration: BoxDecoration(
                color: color,
                borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(Radii.sm))),
          ),
        ),
      );

  Widget _legend(BuildContext context, Color c, String label) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 12,
            height: 12,
            decoration:
                BoxDecoration(color: c, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: Gap.xs),
        Text(label,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12)),
      ]);
}
