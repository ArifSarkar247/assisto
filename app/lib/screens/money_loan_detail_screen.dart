import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import 'money_common.dart';
import '../widgets/bn_day_periods.dart' show appDateLocale;

/// One loan: principal, running balance, partial-repayment history + ledger.
/// Repayments are stored on the synced loan item (data['repayments'] list) so
/// the running balance is computed locally AND matches money_engine.loan_balance.
class MoneyLoanDetailScreen extends StatefulWidget {
  final Map<String, dynamic> item;
  const MoneyLoanDetailScreen({super.key, required this.item});
  @override
  State<MoneyLoanDetailScreen> createState() => _MoneyLoanDetailScreenState();
}

class _MoneyLoanDetailScreenState extends State<MoneyLoanDetailScreen> {
  late Map<String, dynamic> _data;

  @override
  void initState() {
    super.initState();
    _data = Map<String, dynamic>.from(widget.item['data']);
  }

  List<Map<String, dynamic>> get _repayments =>
      ((_data['repayments'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  double get _paid =>
      _repayments.fold<double>(0, (p, r) => p + dbl(r['amount']));

  double get _balance {
    final b = dbl(_data['amount']) - _paid;
    return b < 0 ? 0 : b;
  }

  bool get _settled => _data['settled'] == true || _balance <= 0;

  Future<void> _persist() async {
    final app = context.read<AppState>();
    await app.loans.update(widget.item, {
      'repayments': _repayments,
      'paid': _paid.toString(),
      'settled': _settled,
    });
    if (mounted) setState(() {});
  }

  Future<void> _addRepayment() async {
    final t = AppLocalizations.of(context);
    final amount = TextEditingController(
        text: _balance > 0 ? _balance.toStringAsFixed(0) : '');
    DateTime date = DateTime.now();
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, setD) => AlertDialog(
                  title: Text(t.moneyAddRepayment),
                  content: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        controller: amount,
                        keyboardType: TextInputType.number,
                        autofocus: true,
                        decoration: InputDecoration(labelText: t.amount)),
                    const SizedBox(height: Gap.sm),
                    InkWell(
                      onTap: () async {
                        final picked = await showDatePicker(
                            context: ctx,
                            initialDate: date,
                            firstDate: DateTime(2020),
                            lastDate: DateTime(2100));
                        if (picked != null) setD(() => date = picked);
                      },
                      child: Row(children: [
                        const Icon(Icons.calendar_today_rounded, size: 16),
                        const SizedBox(width: Gap.xs),
                        Text(DateFormat('d MMM yyyy', appDateLocale(context)).format(date)),
                      ]),
                    ),
                  ]),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: Text(t.cancel)),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: Text(t.save)),
                  ],
                )));
    if (ok == true && dbl(amount.text) > 0) {
      _data['repayments'] = [
        ..._repayments,
        {
          'amount': amount.text.trim(),
          'date': DateFormat('yyyy-MM-dd').format(date),
        }
      ];
      await _persist();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final principal = dbl(_data['amount']);
    final progress = principal > 0 ? (_paid / principal).clamp(0.0, 1.0) : 1.0;
    final given = _data['kind'] == 'given';
    final fmt = DateFormat('d MMM yyyy', appDateLocale(context));

    // ledger: principal first, then each repayment (newest last), with balance
    double running = principal;
    final ledger = <Map<String, dynamic>>[
      {'type': 'principal', 'amount': principal, 'date': _data['date'], 'balance': principal}
    ];
    final sorted = [..._repayments]
      ..sort((a, b) => '${a['date']}'.compareTo('${b['date']}'));
    for (final r in sorted) {
      running -= dbl(r['amount']);
      ledger.add({
        'type': 'repayment',
        'amount': dbl(r['amount']),
        'date': r['date'],
        'balance': running < 0 ? 0 : running,
      });
    }

    return Scaffold(
      appBar: AppBar(title: Text('${_data['person']}')),
      floatingActionButton: _settled
          ? null
          : FloatingActionButton.extended(
              onPressed: _addRepayment,
              icon: const Icon(Icons.add_rounded),
              label: Text(t.moneyAddRepayment)),
      body: ListView(padding: const EdgeInsets.all(Gap.lg), children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(given ? Icons.call_made_rounded : Icons.call_received_rounded,
                        color: given ? AssistoTokens.of(context).warning : scheme.primary),
                    const SizedBox(width: Gap.sm),
                    Text(given ? t.moneyLoanGiven : t.moneyLoanTaken,
                        style: TextStyle(color: scheme.onSurfaceVariant)),
                    const Spacer(),
                    if (_settled)
                      Chip(
                          avatar: Icon(Icons.check_circle_rounded,
                              color: AssistoTokens.of(context).success, size: 18),
                          label: Text(t.moneyLoanSettled)),
                  ]),
                  const SizedBox(height: Gap.md),
                  Text(t.moneyLoanBalance,
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                  Text(tkFmt(_balance),
                      style: AType.headlineLarge.copyWith(fontFeatures: AFonts.tabular, fontWeight: FontWeight.bold)),
                  const SizedBox(height: Gap.sm),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(Radii.sm),
                    child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 8,
                        color: AssistoTokens.of(context).success),
                  ),
                  const SizedBox(height: Gap.xs),
                  Text(t.moneyLoanPaidOf(tkFmt(_paid), tkFmt(principal)),
                      style: AType.bodySmall.copyWith(fontFeatures: AFonts.tabular, color: scheme.onSurfaceVariant)),
                ]),
          ),
        ),
        const SizedBox(height: Gap.lg),
        if (!_settled)
          OutlinedButton.icon(
            onPressed: () async {
              _data['settled'] = true;
              await _persist();
            },
            icon: const Icon(Icons.done_all_rounded),
            label: Text(t.moneyMarkSettled),
          ),
        const SizedBox(height: Gap.lg),
        Text(t.moneyLoanLedger,
            style: AType.titleMedium.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: Gap.sm),
        for (final e in ledger)
          Card(
            child: ListTile(
              leading: Icon(
                  e['type'] == 'principal'
                      ? Icons.flag_rounded
                      : Icons.payments_rounded,
                  color: e['type'] == 'principal'
                      ? scheme.primary
                      : AssistoTokens.of(context).success),
              title: Text(e['type'] == 'principal'
                  ? t.moneyLoanPrincipal
                  : t.moneyLoanRepayment),
              subtitle: Text(e['date'] != null
                  ? fmt.format(
                      DateTime.tryParse('${e['date']}') ?? DateTime.now())
                  : ''),
              isThreeLine: MediaQuery.textScalerOf(context).scale(10) > 12, // qa1
              // qa1: scale down (never clip) the 2-line amount at large font
              trailing: FittedBox(fit: BoxFit.scaleDown, child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(tkFmt(e['amount']),
                        style: const TextStyle(fontFeatures: AFonts.tabular, fontWeight: FontWeight.w700)),
                    Text(t.moneyLoanBalanceLabel(tkFmt(e['balance'])),
                        style:
                            AType.labelSmall.copyWith(fontFeatures: AFonts.tabular, color: scheme.onSurfaceVariant)),
                  ])),
            ),
          ),
      ]),
    );
  }
}
