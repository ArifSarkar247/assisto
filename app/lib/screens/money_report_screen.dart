import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../ads/ad_moment.dart'; // adcontrol
import '../ads/ad_placements.dart' show AdExit, AdExitPlacement; // adcontrol
import '../ads/ad_spot_card.dart'; // adcontrol
import '../ds/ds.dart';
import '../widgets/skeleton.dart';
import 'money_common.dart';
import '../widgets/money_digits.dart';
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
      final r = await Share.shareXFiles([XFile(f.path)]);
      // remhbud: say "done" only when the phone confirms a target was chosen;
      // closing the share sheet is not an export.
      if (r.status == ShareResultStatus.success) {
        messenger.showSnackBar(SnackBar(content: Text(t.moneyReportExported)));
        // adcontrol (owner 10 Nov): one interstitial after a PDF export /
        // share (Free only; all caps apply) — never before or during it
        AdExit.transition(AdExitPlacement.financeAfterExport);
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(t.exportFailed(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    syncMoneyDigits(context); // design3: amounts in Bangla digits in bn
    final t = AppLocalizations.of(context);
    return Scaffold(
      // banners-everywhere (owner 26 Oct): one bottom banner, Free only
      appBar: AppBar(title: Text(t.moneyReportTitle), actions: [
        IconButton(
            tooltip: 'PDF',
            icon: const Icon(Icons.picture_as_pdf_rounded),
            onPressed: () => _export('pdf')),
        IconButton(
            tooltip: 'Excel',
            icon: const Icon(Icons.table_chart_rounded),
            onPressed: () => _export('xlsx')),
      ]),
      body: _loading
          ? const SkeletonList(count: 5)
          : _failed
              ? StateMessage(
                  icon: Icons.cloud_off_rounded,
                  title: t.moneyReportTitle,
                  message: honestFailText(t, _failCause, otherwise: t.moneySummaryOffline),
                  action: FilledButton(onPressed: _load, child: Text(t.retry)),
                )
              // adcontrol: the month's full report -> one interstitial
              : AdMomentOnShow(
                  placement: AdExitPlacement.financeMonthReport,
                  child: _body(context, t)),
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
          style: AType.titleMedium.copyWith(fontWeight: FontWeight.bold)),
      const SizedBox(height: Gap.md),
      Row(children: [
        Expanded(
            child: statCard(context, t.moneyMonthIncome,
                tkOf(context, d['income']), AssistoTokens.of(context).success, Icons.south_west_rounded)),
        const SizedBox(width: Gap.md),
        Expanded(
            child: statCard(context, t.moneyMonthExpense,
                tkOf(context, d['expense']), DsTokens.of(context).dangerInk, Icons.north_east_rounded)),
      ]),
      const SizedBox(height: Gap.md),
      Row(children: [
        Expanded(
            child: statCard(context, t.moneyMonthNet, tkOf(context, d['net']),
                dbl(d['net']) >= 0 ? Theme.of(context).colorScheme.primary : DsTokens.of(context).dangerInk,
                Icons.savings_rounded)),
        const SizedBox(width: Gap.md),
        Expanded(
            child: statCard(context, t.moneySavingsRate,
                '${d['savings_rate'] ?? 0}%', Brand.onTint(context, Brand.purple),
                Icons.percent_rounded)),
      ]),
      if (biggest != null) ...[
        const SizedBox(height: Gap.md),
        Card(
          child: ListTile(
            leading: Icon(Icons.local_fire_department_rounded,
                color: AssistoTokens.of(context).warning),
            title: Text(t.moneyBiggestExpense),
            subtitle: Text('${biggest['category']} · ${moneyDay(context, biggest['date'])}'),
            trailing: Text(tkOf(context, biggest['amount']),
                style: AType.titleSmall.copyWith(fontFeatures: AFonts.tabular, fontWeight: FontWeight.w700)),
          ),
        ),
      ],
      const SizedBox(height: Gap.xl),
      Text(t.moneyExpenseBreakdown,
          style: AType.titleMedium.copyWith(fontWeight: FontWeight.bold)),
      const SizedBox(height: Gap.sm),
      for (final c in byCat)
        ListTile(
          dense: true,
          title: Text('${c['category']}'),
          trailing: Text(tkOf(context, c['amount']),
              style: AType.titleSmall.copyWith(fontFeatures: AFonts.tabular, fontWeight: FontWeight.w600)),
        ),
      if (budgets.isNotEmpty) ...[
        const SizedBox(height: Gap.xl),
        Text(t.moneyTabBudget,
            style: AType.titleMedium.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: Gap.sm),
        for (final b in budgets)
          ListTile(
            dense: true,
            title: Text('${b['category']}'),
            subtitle: Text('${tkOf(context, b['spent'])} / ${tkOf(context, b['limit'])}', style: AType.bodyMedium.copyWith(fontFeatures: AFonts.tabular)),
            trailing: Icon(
                b['state'] == 'over'
                    ? Icons.error_outline_rounded
                    : b['state'] == 'near'
                        ? Icons.warning_amber_rounded
                        : Icons.check_circle_outline_rounded,
                color: b['state'] == 'over'
                    ? DsTokens.of(context).dangerInk
                    : b['state'] == 'near'
                        ? AssistoTokens.of(context).warning
                        : AssistoTokens.of(context).success),
          ),
      ],
      // adcontrol: reports — one native card at the bottom (Free only)
      const AdSpotCard(placement: 'finance_reports', padding: EdgeInsets.only(top: Gap.lg)),
    ]);
  }
}
