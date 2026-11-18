import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../ds/ds.dart';
import '../widgets/skeleton.dart';
import 'money_common.dart';
import '../widgets/money_digits.dart';
import '../services/error_kind.dart' show honestFailText; // qa2

/// Net worth: assets + receivables - liabilities, plus a net-worth-over-time
/// line. Data from GET /money/networth (money_engine.net_worth + net_worth_series).
class MoneyNetWorthScreen extends StatefulWidget {
  const MoneyNetWorthScreen({super.key});
  @override
  State<MoneyNetWorthScreen> createState() => _MoneyNetWorthScreenState();
}

class _MoneyNetWorthScreenState extends State<MoneyNetWorthScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  bool _failed = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

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
      _data = await context.read<AppState>().api.moneyNetWorth();
    } catch (e) {
      _failed = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    syncMoneyDigits(context); // design3: amounts in Bangla digits in bn
    final t = AppLocalizations.of(context);
    return Scaffold(
      // banners-everywhere (owner 26 Oct): one bottom banner, Free only
      appBar: AppBar(title: Text(t.moneyNetWorthTitle), actions: [
        IconButton(
            tooltip: AppLocalizations.of(context).refresh,onPressed: _load, icon: const Icon(Icons.sync_rounded)),
      ]),
      body: _loading
          ? const SkeletonList(count: 4)
          : _failed
              ? StateMessage(
                  icon: Icons.cloud_off_rounded,
                  title: t.moneyNetWorthTitle,
                  message: honestFailText(t, _failCause, otherwise: t.moneySummaryOffline),
                  action: FilledButton(onPressed: _load, child: Text(t.retry)),
                )
              : _body(context, t),
    );
  }

  Widget _body(BuildContext context, AppLocalizations t) {
    final nw = dbl(_data?['net_worth']);
    final assets = dbl(_data?['assets']);
    final receivable = dbl(_data?['receivable']);
    final liabilities = dbl(_data?['liabilities']);
    final series =
        (_data?['series'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      // design3: net worth = the soft DS hero, big tight number
      DsHeroCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.moneyNetWorthLabel,
              style: AType.bodyMedium.copyWith(color: DsTokens.of(context).muted)),
          const SizedBox(height: Gap.xs),
          DsNumber(tkOf(context, nw), color: nw < 0 ? DsTokens.of(context).dangerInk : null),
        ]),
      ),
      const SizedBox(height: Gap.md),
      statCard(context, t.moneyAssets, tkOf(context, assets), AssistoTokens.of(context).success,
          Icons.account_balance_wallet_rounded),
      const SizedBox(height: Gap.md),
      Row(children: [
        Expanded(
            child: statCard(context, t.moneyReceivable, tkOf(context, receivable),
                Theme.of(context).colorScheme.primary, Icons.call_received_rounded)),
        const SizedBox(width: Gap.md),
        Expanded(
            child: statCard(context, t.moneyLiabilities, tkOf(context, liabilities),
                DsTokens.of(context).dangerInk, Icons.call_made_rounded)),
      ]),
      const SizedBox(height: Gap.xl),
      Text(t.moneyNetWorthOverTime,
          style: AType.titleMedium.copyWith(fontWeight: FontWeight.bold)),
      const SizedBox(height: Gap.md),
      if (series.isEmpty)
        Text(t.moneyNoTransactionsHint,
            style: AType.bodyMedium.copyWith(color: DsTokens.of(context).muted))
      else
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: _lineChart(context, series),
          ),
        ),
      const SizedBox(height: Gap.md),
      for (final p in series.reversed)
        ListTile(
          dense: true,
          title: Text(moneyMonth(context, p['month'])),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(tkOf(context, p['net_worth']),
                style: AType.titleSmall.copyWith(fontFeatures: AFonts.tabular, fontWeight: FontWeight.w600)),
            const SizedBox(width: Gap.md),
            deltaChip(context, dbl(p['delta']), upIsBad: false),
          ]),
        ),
    ]);
  }

  Widget _lineChart(BuildContext context, List<Map<String, dynamic>> series) {
    final values = series.map((s) => dbl(s['net_worth'])).toList();
    final maxV = values.fold<double>(0, (p, v) => v > p ? v : p);
    final minV = values.fold<double>(values.first, (p, v) => v < p ? v : p);
    return SizedBox(
      height: 140,
      child: CustomPaint(
        size: Size.infinite,
        painter: _LinePainter(values, maxV, minV,
            Theme.of(context).colorScheme.primary,
            Theme.of(context).colorScheme.primary.withValues(alpha: 0.12)),
      ),
    );
  }
}

class _LinePainter extends CustomPainter {
  final List<double> values;
  final double maxV;
  final double minV;
  final Color line;
  final Color fill;
  _LinePainter(this.values, this.maxV, this.minV, this.line, this.fill);

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final range = (maxV - minV).abs() < 1 ? 1.0 : (maxV - minV);
    final dx = size.width / (values.length - 1);
    Offset pt(int i) => Offset(
        dx * i, size.height - ((values[i] - minV) / range) * size.height * 0.9 - 8);
    final path = Path()..moveTo(pt(0).dx, pt(0).dy);
    for (int i = 1; i < values.length; i++) {
      path.lineTo(pt(i).dx, pt(i).dy);
    }
    final area = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(area, Paint()..color = fill);
    canvas.drawPath(
        path,
        Paint()
          ..color = line
          ..strokeWidth = 2.5
          ..style = PaintingStyle.stroke);
    for (int i = 0; i < values.length; i++) {
      canvas.drawCircle(pt(i), 3, Paint()..color = line);
    }
  }

  @override
  bool shouldRepaint(covariant _LinePainter old) => old.values != values;
}
