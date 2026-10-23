import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import 'money_common.dart';
import '../services/error_kind.dart' show honestFailText; // qa2

/// Monthly report — the data behind the PDF / Excel export. Shows the month's
/// income/expense/net, savings rate, biggest expense, per-category spend and
/// budget adherence. Export buttons hit the same byte endpoints as the rest of
/// the app (GET /money/report.pdf / .xlsx) via ApiClient.getBytes.
class MoneyReportScreen extends StatefulWidget {
  const MoneyReportScreen({super.key});
  @override
  State<MoneyReportScreen> createState() => _MoneyReportScreenState();
}

class _MoneyReportScreenState extends State<MoneyReportScreen> {
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
      _data = await context.read<AppState>().api.moneyReport();
    } catch (e) {
      _failed = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _export(String fmt) async {
    final t = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      // m2-reality: the bytes used to be downloaded and DROPPED while the
      // snackbar claimed "exported". Save the real file and hand it to the
      // share sheet (save to Files / WhatsApp / email) — then say so.
      final bytes = await app.api.getBytes('/money/report.$fmt');
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/assisto-money-report.$fmt');
      await f.writeAsBytes(bytes, flush: true);
      await Share.shareXFiles([XFile(f.path)]);
      messenger.showSnackBar(SnackBar(content: Text(t.moneyReportExported)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(t.exportFailed(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.moneyReportTitle), actions: [
        IconButton(
            tooltip: 'PDF',
            icon: const Icon(Icons.picture_as_pdf_outlined),
            onPressed: () => _export('pdf')),
        IconButton(
            tooltip: 'Excel',
            icon: const Icon(Icons.table_chart_outlined),
            onPressed: () => _export('xlsx')),
      ]),
      body: _loading
          ? const SkeletonList(count: 5)
          : _failed
              ? StateMessage(
                  icon: Icons.cloud_off_outlined,
                  title: t.moneyReportTitle,
                  message: honestFailText(t, _failCause, otherwise: t.moneySummaryOffline),
                  action: FilledButton(onPressed: _load, child: Text(t.retry)),
                )
              : _body(context, t),
    );
  }

  Widget _body(BuildContext context, AppLocalizations t) {
    final d = _data!;
    final byCat = (d['by_category'] as List?)?.cast<Map<String, dynamic>>() ??
        [];
    final budgets = (d['budgets'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final biggest = d['biggest_expense'] as Map<String, dynamic>?;
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      Text(t.moneyReportFor(moneyMonth(context, d['month'])),
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      const SizedBox(height: Gap.md),
      Row(children: [
        Expanded(
            child: statCard(context, t.moneyMonthIncome,
                tkFmt(d['income']), Brand.success, Icons.south_west)),
        const SizedBox(width: Gap.md),
        Expanded(
            child: statCard(context, t.moneyMonthExpense,
                tkFmt(d['expense']), Brand.danger, Icons.north_east)),
      ]),
      const SizedBox(height: Gap.md),
      Row(children: [
        Expanded(
            child: statCard(context, t.moneyMonthNet, tkFmt(d['net']),
                dbl(d['net']) >= 0 ? Brand.blue : Brand.danger,
                Icons.savings_outlined)),
        const SizedBox(width: Gap.md),
        Expanded(
            child: statCard(context, t.moneySavingsRate,
                '${d['savings_rate'] ?? 0}%', Brand.purple,
                Icons.percent)),
      ]),
      if (biggest != null) ...[
        const SizedBox(height: Gap.md),
        Card(
          child: ListTile(
            leading: const Icon(Icons.local_fire_department_outlined,
                color: Brand.warning),
            title: Text(t.moneyBiggestExpense),
            subtitle: Text('${biggest['category']} · ${moneyDay(context, biggest['date'])}'),
            trailing: Text(tkFmt(biggest['amount']),
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        ),
      ],
      const SizedBox(height: Gap.xl),
      Text(t.moneyExpenseBreakdown,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
      const SizedBox(height: Gap.sm),
      for (final c in byCat)
        ListTile(
          dense: true,
          title: Text('${c['category']}'),
          trailing: Text(tkFmt(c['amount']),
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
      if (budgets.isNotEmpty) ...[
        const SizedBox(height: Gap.xl),
        Text(t.moneyTabBudget,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        const SizedBox(height: Gap.sm),
        for (final b in budgets)
          ListTile(
            dense: true,
            title: Text('${b['category']}'),
            subtitle: Text('${tkFmt(b['spent'])} / ${tkFmt(b['limit'])}'),
            trailing: Icon(
                b['state'] == 'over'
                    ? Icons.error_outline
                    : b['state'] == 'near'
                        ? Icons.warning_amber_outlined
                        : Icons.check_circle_outline,
                color: b['state'] == 'over'
                    ? Brand.danger
                    : b['state'] == 'near'
                        ? Brand.warning
                        : Brand.success),
          ),
      ],
    ]);
  }
}
