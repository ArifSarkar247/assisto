import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import '../../theme.dart';
import '../../api.dart';
import '../../business_selling_api.dart';
import '../../widgets/skeleton.dart';
import '../../l10n/app_localizations.dart';
import 'selling_common.dart';

/// Reports (§3): daily / weekly / monthly sales, profit, top products, top
/// customers, by payment method, net profit after expenses; text-summary share.
///
/// A staff role receives a report with profit / cost / net already stripped by
/// the server (`full_report(..., role='staff')`). The screen hides those rows
/// when the keys are absent and shows a staff-restricted note.
class ReportsScreen extends StatefulWidget {
  final int? businessId;
  const ReportsScreen({super.key, this.businessId});
  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  String _period = 'daily';
  Map<String, dynamic>? _data;
  bool _loading = true;
  Object? _error;

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
    try {
      _data = await sellApi(context)
          .report(period: _period, businessId: widget.businessId);
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  bool get _profitRedacted {
    final d = _data;
    if (d == null) return true;
    if ((d['role'] ?? '').toString() == 'staff') return true;
    return !d.containsKey('profit') && !d.containsKey('net_profit');
  }

  Future<void> _export() async {
    final t = AppLocalizations.of(context);
    // A plain-text summary through the share sheet (no pdf/excel package is
    // bundled, so the UI no longer claims PDF/Excel).
    final d = _data ?? const {};
    final buf = StringBuffer()
      ..writeln(t.biz_report)
      ..writeln('${t.biz_report_sales}: ${poishaOf(d['sales']).takaIn(context)}');
    if (!_profitRedacted) {
      buf.writeln('${t.biz_report_profit}: ${poishaOf(d['profit']).takaIn(context)}');
      buf.writeln(
          '${t.biz_report_net_profit}: ${poishaOf(d['net_profit']).takaIn(context)}');
    }
    await Share.share(buf.toString(), subject: t.biz_report);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.biz_report),
        actions: [
          // q1-seams: the menu offered "PDF" / "Excel" but always shared plain
          // text. Until a real PDF/Excel builder exists it is one honest
          // "Share" action for the text summary.
          IconButton(
            key: const ValueKey('q1-report-share'),
            tooltip: t.share,
            icon: const Icon(Icons.ios_share_rounded),
            onPressed: _export,
          ),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.sm),
          child: SegmentedButton<String>(
            segments: [
              ButtonSegment(value: 'daily', label: Text(t.biz_report_daily)),
              ButtonSegment(value: 'weekly', label: Text(t.biz_report_weekly)),
              ButtonSegment(value: 'monthly', label: Text(t.biz_report_monthly)),
            ],
            selected: {_period},
            onSelectionChanged: (s) {
              setState(() => _period = s.first);
              _load();
            },
          ),
        ),
        if (_profitRedacted && !_loading && _error == null)
          const StaffRedactedNote(),
        Expanded(child: _body(t, scheme)),
      ]),
    );
  }

  Widget _body(AppLocalizations t, ColorScheme scheme) {
    if (_loading) return const SkeletonList();
    if (_error != null) {
      return StateMessage(
        icon: Icons.cloud_off_rounded,
        tint: scheme.error,
        title: t.loadFailed,
        message: _error is ApiException ? (_error as ApiException).message : null,
        action: FilledButton.tonalIcon(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(t.retry)),
      );
    }
    final d = _data ?? const {};
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          _summaryCards(t, scheme, d),
          const SizedBox(height: Gap.lg),
          _byPayment(t, scheme, d),
          const SizedBox(height: Gap.lg),
          _topList(t, scheme, t.biz_report_top_products,
              (d['top_products'] ?? []) as List, Icons.inventory_2_rounded),
          const SizedBox(height: Gap.lg),
          _topList(t, scheme, t.biz_report_top_customers,
              (d['top_customers'] ?? []) as List, Icons.person_outline_rounded),
          const SizedBox(height: Gap.xl),
        ],
      ),
    );
  }

  Widget _summaryCards(
      AppLocalizations t, ColorScheme scheme, Map d) {
    final sales = poishaOf(d['sales'] ?? d['total_sales']);
    final profit = poishaOf(d['profit']);
    final net = poishaOf(d['net_profit']);
    final expenses = poishaOf(d['expenses']);
    return Column(children: [
      Container(
        padding: const EdgeInsets.all(Gap.lg),
        decoration: BoxDecoration(
          gradient: Brand.gradient,
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.biz_report_sales,
              style: AType.bodyMedium.copyWith(color: Colors.white70)),
          const SizedBox(height: Gap.xs),
          Text(sales.takaIn(context),
              style: AType.headlineLarge.copyWith(color: Colors.white,
                  fontWeight: FontWeight.w800)),
        ]),
      ),
      if (!_profitRedacted) ...[
        const SizedBox(height: Gap.md),
        Row(children: [
          Expanded(
              child: _statCard(scheme, t.biz_report_profit, profit.takaIn(context),
                  AssistoTokens.of(context).success)),
          const SizedBox(width: Gap.md),
          Expanded(
              child: _statCard(scheme, t.biz_report_expenses,
                  expenses.takaIn(context), AssistoTokens.of(context).warning)),
        ]),
        const SizedBox(height: Gap.md),
        SellCard(
          child: MoneyRow(t.biz_report_net_profit, net,
              strong: true,
              valueColor: net >= 0 ? AssistoTokens.of(context).success : Theme.of(context).colorScheme.error),
        ),
      ],
    ]);
  }

  Widget _statCard(ColorScheme scheme, String label, String value, Color tint) {
    return SellCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.xs),
        Text(value,
            style: AType.titleLarge.copyWith(color: Brand.onTint(context, tint), fontWeight: FontWeight.w800)),
      ]),
    );
  }

  Widget _byPayment(AppLocalizations t, ColorScheme scheme, Map d) {
    final byPay = (d['by_payment_method'] ?? d['by_payment'] ?? {});
    final map = byPay is Map ? byPay : <String, dynamic>{};
    if (map.isEmpty) return const SizedBox.shrink();
    final methods = paymentMethods(t);
    return SellCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t.biz_report_by_payment,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.sm),
        for (final m in methods)
          if (map.containsKey(m.code))
            MoneyRow(m.label, poishaOf(map[m.code])),
      ]),
    );
  }

  Widget _topList(AppLocalizations t, ColorScheme scheme, String title,
      List items, IconData icon) {
    if (items.isEmpty) return const SizedBox.shrink();
    return SellCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.sm),
        for (int i = 0; i < items.length && i < 10; i++)
          _topRow(scheme, icon, items[i] as Map, i + 1),
      ]),
    );
  }

  Widget _topRow(ColorScheme scheme, IconData icon, Map m, int rank) {
    final name = (m['name'] ?? m['product_name'] ?? m['customer'] ?? '').toString();
    final amount = poishaOf(m['total'] ?? m['sales'] ?? m['amount']);
    final count = m['qty'] ?? m['count'];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        CircleAvatar(
          radius: 13,
          backgroundColor: scheme.surfaceContainerHighest,
          child: Text('$rank',
              style: AType.labelMedium.copyWith(fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Text(name,
              maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        if (count != null)
          Padding(
            padding: const EdgeInsets.only(right: Gap.sm),
            child: Text('x$count',
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          ),
        Text(amount.takaIn(context),
            style: const TextStyle(fontWeight: FontWeight.w700)),
      ]),
    );
  }
}
