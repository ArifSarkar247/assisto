import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/finance_common.dart';
import '../widgets/finance_calc.dart' as calc;

/// Finance tools (feature 26) — ADVANCED.
///
/// A tool picker (empty state) opens into focused calculators: EMI/loan
/// (reducing + flat + amortization), DPS/savings projection, savings-goal,
/// rate-vs-installment compare, zakat, 50-30-20 budget, affordability
/// cashflow, break-even, simple ROI, currency/unit convert, plus the existing
/// net-worth (backend-computed from the user's own data).
///
/// Every calculator computes CLIENT-SIDE and offline (see widgets/finance_calc)
/// — the only network call is net-worth. Rates/prices are user inputs; the app
/// never invents gold prices or FX rates. All strings come from
/// AppLocalizations (zero Bangla literals here).
class FinanceScreen extends StatefulWidget {
  const FinanceScreen({super.key});
  @override
  State<FinanceScreen> createState() => _FinanceScreenState();
}

/// Identifies which tool is open (null = picker / empty state).
enum _Tool {
  emi,
  rateCompare,
  dps,
  goal,
  zakat,
  budget,
  afford,
  breakEven,
  roi,
  convert,
  netWorth,
}

class _ToolMeta {
  final _Tool tool;
  final IconData icon;
  const _ToolMeta(this.tool, this.icon);
}

class _FinanceScreenState extends State<FinanceScreen> {
  _Tool? _open;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_open == null ? t.financeAdvTitle : _title(t, _open!)),
        leading: _open == null
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() => _open = null),
              ),
      ),
      body: _open == null ? _Picker(onPick: (x) => setState(() => _open = x)) : _body(t),
    );
  }

  Widget _body(AppLocalizations t) {
    switch (_open!) {
      case _Tool.netWorth:
        return const _NetWorthTab();
      case _Tool.emi:
        return const _EmiCalculator(flatToggle: true);
      case _Tool.rateCompare:
        return const _RateCompareCalculator();
      case _Tool.dps:
        return const _DpsCalculator();
      case _Tool.goal:
        return const _GoalCalculator();
      case _Tool.zakat:
        return const _ZakatCalculator();
      case _Tool.budget:
        return const _BudgetCalculator();
      case _Tool.afford:
        return const _AffordCalculator();
      case _Tool.breakEven:
        return const _BreakEvenCalculator();
      case _Tool.roi:
        return const _RoiCalculator();
      case _Tool.convert:
        return const _ConvertCalculator();
    }
  }
}

String _title(AppLocalizations t, _Tool tool) {
  switch (tool) {
    case _Tool.emi:
      return t.financeToolEmi;
    case _Tool.rateCompare:
      return t.financeToolRateCompare;
    case _Tool.dps:
      return t.financeToolDps;
    case _Tool.goal:
      return t.financeToolGoal;
    case _Tool.zakat:
      return t.financeToolZakat;
    case _Tool.budget:
      return t.financeToolBudget;
    case _Tool.afford:
      return t.financeToolAfford;
    case _Tool.breakEven:
      return t.financeToolBreakEven;
    case _Tool.roi:
      return t.financeToolRoi;
    case _Tool.convert:
      return t.financeToolConvert;
    case _Tool.netWorth:
      return t.netWorth;
  }
}

// ---------------------------------------------------------------------------
// Tool picker (empty state)
// ---------------------------------------------------------------------------

class _Picker extends StatelessWidget {
  final ValueChanged<_Tool> onPick;
  const _Picker({required this.onPick});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final groups = <(String, List<_ToolMeta>)>[
      (t.financeCatLoans, const [
        _ToolMeta(_Tool.emi, Icons.account_balance_outlined),
        _ToolMeta(_Tool.rateCompare, Icons.compare_arrows),
        _ToolMeta(_Tool.afford, Icons.shopping_cart_checkout),
      ]),
      (t.financeCatSavings, const [
        _ToolMeta(_Tool.dps, Icons.savings_outlined),
        _ToolMeta(_Tool.goal, Icons.flag_outlined),
        _ToolMeta(_Tool.roi, Icons.trending_up),
      ]),
      (t.financeCatPlanning, const [
        _ToolMeta(_Tool.budget, Icons.pie_chart_outline),
        _ToolMeta(_Tool.netWorth, Icons.account_balance_wallet_outlined),
      ]),
      (t.financeCatReligious, const [
        _ToolMeta(_Tool.zakat, Icons.volunteer_activism_outlined),
      ]),
      (t.financeCatBusiness, const [
        _ToolMeta(_Tool.breakEven, Icons.balance_outlined),
      ]),
      (t.financeCatUtility, const [
        _ToolMeta(_Tool.convert, Icons.currency_exchange),
      ]),
    ];
    return ListView(
      padding: const EdgeInsets.all(Gap.lg),
      children: [
        Container(
          padding: const EdgeInsets.all(Gap.lg),
          decoration: BoxDecoration(
            gradient: Brand.gradient,
            borderRadius: BorderRadius.circular(Radii.lg),
          ),
          child: DefaultTextStyle.merge(
            style: const TextStyle(color: Colors.white),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.calculate_outlined,
                    color: Colors.white, size: 28),
                const SizedBox(height: Gap.sm),
                Text(t.financePickTool,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w800)),
                const SizedBox(height: Gap.xs),
                Text(t.financePickToolBody,
                    style: const TextStyle(height: 1.4)),
              ],
            ),
          ),
        ),
        const SizedBox(height: Gap.xl),
        for (final g in groups) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm, left: Gap.xs),
            child: Text(g.$1,
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurfaceVariant)),
          ),
          ...g.$2.map((m) => Card(
                margin: const EdgeInsets.only(bottom: Gap.sm),
                child: ListTile(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(Radii.md)),
                  leading: CircleAvatar(
                    backgroundColor: scheme.secondaryContainer,
                    foregroundColor: scheme.onSecondaryContainer,
                    child: Icon(m.icon, size: 20),
                  ),
                  title: Text(_title(t, m.tool),
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(_subtitle(t, m.tool)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => onPick(m.tool),
                ),
              )),
          const SizedBox(height: Gap.lg),
        ],
      ],
    );
  }
}

String _subtitle(AppLocalizations t, _Tool tool) {
  switch (tool) {
    case _Tool.emi:
      return t.financeToolEmiSub;
    case _Tool.rateCompare:
      return t.financeToolRateCompareSub;
    case _Tool.dps:
      return t.financeToolDpsSub;
    case _Tool.goal:
      return t.financeToolGoalSub;
    case _Tool.zakat:
      return t.financeToolZakatSub;
    case _Tool.budget:
      return t.financeToolBudgetSub;
    case _Tool.afford:
      return t.financeToolAffordSub;
    case _Tool.breakEven:
      return t.financeToolBreakEvenSub;
    case _Tool.roi:
      return t.financeToolRoiSub;
    case _Tool.convert:
      return t.financeToolConvertSub;
    case _Tool.netWorth:
      return t.financeCatPlanning;
  }
}

// ---------------------------------------------------------------------------
// Shared scaffold for a calculator form.
// ---------------------------------------------------------------------------

/// Builds a share string from label/value pairs + a title.
String _shareText(String title, List<(String, String)> rows) {
  final b = StringBuffer('$title\n');
  for (final r in rows) {
    b.writeln('• ${r.$1}: ${r.$2}');
  }
  b.write('— Assisto');
  return b.toString();
}

Future<void> _share(BuildContext context, String text, String copiedMsg) async {
  try {
    await Share.share(text);
  } catch (_) {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(copiedMsg)));
    }
  }
}

// ---------------------------------------------------------------------------
// EMI / loan calculator (reducing + flat + amortization schedule)
// ---------------------------------------------------------------------------

class _EmiCalculator extends StatefulWidget {
  final bool flatToggle;
  const _EmiCalculator({this.flatToggle = true});
  @override
  State<_EmiCalculator> createState() => _EmiCalculatorState();
}

class _EmiCalculatorState extends State<_EmiCalculator> {
  final _principal = TextEditingController();
  final _rate = TextEditingController();
  final _months = TextEditingController();
  String _mode = 'reducing';
  calc.EmiResult? _r;
  String? _err;
  bool _showSchedule = false;

  @override
  void dispose() {
    _principal.dispose();
    _rate.dispose();
    _months.dispose();
    super.dispose();
  }

  void _calc(AppLocalizations t) {
    final p = parseNum(_principal.text);
    final r = parseNum(_rate.text) ?? 0;
    final n = parseNum(_months.text);
    if (p == null || n == null) {
      setState(() => _err = t.financeErrEnterNumbers);
      return;
    }
    if (p <= 0) {
      setState(() => _err = t.financeErrPositive);
      return;
    }
    if (n < 1) {
      setState(() => _err = t.financeErrMonths);
      return;
    }
    setState(() {
      _err = null;
      _r = calc.emiSchedule(p, r, n.round(), _mode);
      _showSchedule = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final r = _r;
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      if (_err != null) FinanceErrorBanner(_err!),
      FinanceField(
          controller: _principal,
          label: t.financeFieldPrincipal,
          icon: Icons.payments_outlined),
      FinanceField(
          controller: _rate,
          label: t.financeFieldRate,
          suffix: '%',
          icon: Icons.percent),
      FinanceField(
          controller: _months,
          label: t.financeFieldMonths,
          allowDecimal: false,
          icon: Icons.event_repeat),
      if (widget.flatToggle) ...[
        const SizedBox(height: Gap.xs),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(value: 'reducing', label: Text(t.financeModeReducing)),
            ButtonSegment(value: 'flat', label: Text(t.financeModeFlat)),
          ],
          selected: {_mode},
          onSelectionChanged: (s) => setState(() {
            _mode = s.first;
            if (_r != null) _calc(t);
          }),
        ),
        const SizedBox(height: Gap.md),
      ],
      FilledButton(onPressed: () => _calc(t), child: Text(t.financeCalculate)),
      if (r != null) ...[
        const SizedBox(height: Gap.lg),
        FinanceResultCard(
          noteLabel: t.financeNote,
          explanation: _mode == 'flat'
              ? t.financeExplEmiFlat
              : t.financeExplEmiReducing,
          shareLabel: t.financeShare,
          onShare: () => _share(
              context,
              _shareText(t.financeToolEmi, [
                (t.financeResultEmi, fmtTaka(r.emi)),
                (t.financeResultTotalPay, fmtTaka(r.total)),
                (t.financeResultTotalInterest, fmtTaka(r.interest)),
              ]),
              t.financeCopied),
          rows: [
            FinanceResultRow(t.financeResultEmi, fmtTaka(r.emi),
                emphasise: true),
            FinanceResultRow(t.financeResultTotalPay, fmtTaka(r.total)),
            FinanceResultRow(t.financeResultTotalInterest, fmtTaka(r.interest),
                valueColor: Brand.warning),
          ],
          extra: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextButton.icon(
                onPressed: () => setState(() => _showSchedule = !_showSchedule),
                icon: Icon(_showSchedule
                    ? Icons.expand_less
                    : Icons.expand_more),
                label: Text(_showSchedule
                    ? t.financeHideSchedule
                    : t.financeShowSchedule),
              ),
              if (_showSchedule) _ScheduleTable(rows: r.schedule, t: t),
            ],
          ),
        ),
      ],
    ]);
  }
}

class _ScheduleTable extends StatelessWidget {
  final List<calc.AmortRow> rows;
  final AppLocalizations t;
  const _ScheduleTable({required this.rows, required this.t});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowHeight: 40,
        dataRowMinHeight: 36,
        dataRowMaxHeight: 40,
        columnSpacing: Gap.lg,
        headingTextStyle: TextStyle(
            fontWeight: FontWeight.w700, color: scheme.onSecondaryContainer),
        columns: [
          DataColumn(label: Text(t.financeSchMonth)),
          DataColumn(label: Text(t.financeSchPayment)),
          DataColumn(label: Text(t.financeSchPrincipal)),
          DataColumn(label: Text(t.financeSchInterest)),
          DataColumn(label: Text(t.financeSchBalance)),
        ],
        rows: [
          for (final row in rows)
            DataRow(cells: [
              DataCell(Text(fmtNum(row.month.toDouble()))),
              DataCell(Text(fmtTaka(row.payment))),
              DataCell(Text(fmtTaka(row.principal))),
              DataCell(Text(fmtTaka(row.interest))),
              DataCell(Text(fmtTaka(row.balance))),
            ]),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Rate vs installment compare
// ---------------------------------------------------------------------------

class _RateCompareCalculator extends StatefulWidget {
  const _RateCompareCalculator();
  @override
  State<_RateCompareCalculator> createState() => _RateCompareState();
}

class _RateCompareState extends State<_RateCompareCalculator> {
  final _principal = TextEditingController();
  final _months = TextEditingController();
  final _rateA = TextEditingController();
  final _rateB = TextEditingController();
  calc.RateCompareResult? _r;
  String? _err;

  @override
  void dispose() {
    _principal.dispose();
    _months.dispose();
    _rateA.dispose();
    _rateB.dispose();
    super.dispose();
  }

  void _calc(AppLocalizations t) {
    final p = parseNum(_principal.text);
    final n = parseNum(_months.text);
    final a = parseNum(_rateA.text) ?? 0;
    final b = parseNum(_rateB.text) ?? 0;
    if (p == null || n == null) {
      setState(() => _err = t.financeErrEnterNumbers);
      return;
    }
    if (p <= 0) {
      setState(() => _err = t.financeErrPositive);
      return;
    }
    if (n < 1) {
      setState(() => _err = t.financeErrMonths);
      return;
    }
    setState(() {
      _err = null;
      _r = calc.rateCompare(p, n.round(), a, b, 'reducing');
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final r = _r;
    final scheme = Theme.of(context).colorScheme;
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      if (_err != null) FinanceErrorBanner(_err!),
      FinanceField(
          controller: _principal,
          label: t.financeFieldPrincipal,
          icon: Icons.payments_outlined),
      FinanceField(
          controller: _months,
          label: t.financeFieldMonths,
          allowDecimal: false,
          icon: Icons.event_repeat),
      FinanceField(controller: _rateA, label: t.financeFieldRateA, suffix: '%'),
      FinanceField(controller: _rateB, label: t.financeFieldRateB, suffix: '%'),
      FilledButton(onPressed: () => _calc(t), child: Text(t.financeCalculate)),
      if (r != null) ...[
        const SizedBox(height: Gap.lg),
        FinanceResultCard(
          noteLabel: t.financeNote,
          explanation: t.financeExplEmiReducing,
          shareLabel: t.financeShare,
          onShare: () => _share(
              context,
              _shareText(t.financeToolRateCompare, [
                ('${t.financeResultOptionA} ${t.financeResultEmi}',
                    fmtTaka(r.a.emi)),
                ('${t.financeResultOptionB} ${t.financeResultEmi}',
                    fmtTaka(r.b.emi)),
                (t.financeResultYouSave, fmtTaka(r.savings)),
              ]),
              t.financeCopied),
          rows: [
            FinanceResultRow(
                '${t.financeResultOptionA} · ${t.financeResultEmi}',
                fmtTaka(r.a.emi)),
            FinanceResultRow(
                '${t.financeResultOptionA} · ${t.financeResultTotalPay}',
                fmtTaka(r.a.total)),
            const Divider(),
            FinanceResultRow(
                '${t.financeResultOptionB} · ${t.financeResultEmi}',
                fmtTaka(r.b.emi)),
            FinanceResultRow(
                '${t.financeResultOptionB} · ${t.financeResultTotalPay}',
                fmtTaka(r.b.total)),
            const Divider(),
            FinanceResultRow(
              '${t.financeResultCheaper}: ${r.cheaper == "a" ? t.financeResultOptionA : (r.cheaper == "b" ? t.financeResultOptionB : "=")}',
              fmtTaka(r.savings),
              emphasise: true,
              valueColor: scheme.primary,
            ),
          ],
        ),
      ],
    ]);
  }
}

// ---------------------------------------------------------------------------
// DPS / savings projection
// ---------------------------------------------------------------------------

class _DpsCalculator extends StatefulWidget {
  const _DpsCalculator();
  @override
  State<_DpsCalculator> createState() => _DpsState();
}

class _DpsState extends State<_DpsCalculator> {
  final _monthly = TextEditingController();
  final _rate = TextEditingController();
  final _months = TextEditingController();
  calc.DpsResult? _r;
  String? _err;

  @override
  void dispose() {
    _monthly.dispose();
    _rate.dispose();
    _months.dispose();
    super.dispose();
  }

  void _calc(AppLocalizations t) {
    final m = parseNum(_monthly.text);
    final r = parseNum(_rate.text) ?? 0;
    final n = parseNum(_months.text);
    if (m == null || n == null) {
      setState(() => _err = t.financeErrEnterNumbers);
      return;
    }
    if (m <= 0) {
      setState(() => _err = t.financeErrPositive);
      return;
    }
    if (n < 1) {
      setState(() => _err = t.financeErrMonths);
      return;
    }
    setState(() {
      _err = null;
      _r = calc.dpsProjection(m, r, n.round());
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final r = _r;
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      if (_err != null) FinanceErrorBanner(_err!),
      FinanceField(
          controller: _monthly,
          label: t.financeFieldMonthlyDeposit,
          icon: Icons.savings_outlined),
      FinanceField(controller: _rate, label: t.financeFieldRate, suffix: '%'),
      FinanceField(
          controller: _months,
          label: t.financeFieldMonths,
          allowDecimal: false),
      FilledButton(onPressed: () => _calc(t), child: Text(t.financeCalculate)),
      if (r != null) ...[
        const SizedBox(height: Gap.lg),
        FinanceResultCard(
          noteLabel: t.financeNote,
          explanation: '${t.financeExplDps} ${t.financeEstimateNote}',
          shareLabel: t.financeShare,
          onShare: () => _share(
              context,
              _shareText(t.financeToolDps, [
                (t.financeResultMaturity, fmtTaka(r.maturity)),
                (t.financeResultInvested, fmtTaka(r.invested)),
                (t.financeResultProfit, fmtTaka(r.profit)),
              ]),
              t.financeCopied),
          rows: [
            FinanceResultRow(t.financeResultMaturity, fmtTaka(r.maturity),
                emphasise: true),
            FinanceResultRow(t.financeResultInvested, fmtTaka(r.invested)),
            FinanceResultRow(t.financeResultProfit, fmtTaka(r.profit),
                valueColor: Brand.success),
          ],
        ),
      ],
    ]);
  }
}

// ---------------------------------------------------------------------------
// Savings goal (solve monthly deposit)
// ---------------------------------------------------------------------------

class _GoalCalculator extends StatefulWidget {
  const _GoalCalculator();
  @override
  State<_GoalCalculator> createState() => _GoalState();
}

class _GoalState extends State<_GoalCalculator> {
  final _target = TextEditingController();
  final _current = TextEditingController();
  final _rate = TextEditingController();
  final _months = TextEditingController();
  calc.GoalResult? _r;
  String? _err;

  @override
  void dispose() {
    _target.dispose();
    _current.dispose();
    _rate.dispose();
    _months.dispose();
    super.dispose();
  }

  void _calc(AppLocalizations t) {
    final tg = parseNum(_target.text);
    final cur = parseNum(_current.text) ?? 0;
    final r = parseNum(_rate.text) ?? 0;
    final n = parseNum(_months.text);
    if (tg == null || n == null) {
      setState(() => _err = t.financeErrEnterNumbers);
      return;
    }
    if (tg <= 0) {
      setState(() => _err = t.financeErrPositive);
      return;
    }
    if (n < 1) {
      setState(() => _err = t.financeErrMonths);
      return;
    }
    setState(() {
      _err = null;
      _r = calc.goalSavings(tg, cur, r, n.round());
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final r = _r;
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      if (_err != null) FinanceErrorBanner(_err!),
      FinanceField(
          controller: _target,
          label: t.financeFieldTarget,
          icon: Icons.flag_outlined),
      FinanceField(
          controller: _current, label: t.financeFieldCurrentSaved),
      FinanceField(controller: _rate, label: t.financeFieldRate, suffix: '%'),
      FinanceField(
          controller: _months,
          label: t.financeFieldMonths,
          allowDecimal: false),
      FilledButton(onPressed: () => _calc(t), child: Text(t.financeCalculate)),
      if (r != null) ...[
        const SizedBox(height: Gap.lg),
        FinanceResultCard(
          noteLabel: t.financeNote,
          explanation: '${t.financeExplGoal} ${t.financeEstimateNote}',
          shareLabel: t.financeShare,
          onShare: () => _share(
              context,
              _shareText(t.financeToolGoal, [
                (t.financeResultMonthlyNeeded, fmtTaka(r.monthly)),
              ]),
              t.financeCopied),
          rows: [
            FinanceResultRow(t.financeResultMonthlyNeeded, fmtTaka(r.monthly),
                emphasise: true, valueColor: Brand.blue),
          ],
        ),
      ],
    ]);
  }
}

// ---------------------------------------------------------------------------
// Zakat
// ---------------------------------------------------------------------------

class _ZakatCalculator extends StatefulWidget {
  const _ZakatCalculator();
  @override
  State<_ZakatCalculator> createState() => _ZakatState();
}

class _ZakatState extends State<_ZakatCalculator> {
  final _cash = TextEditingController();
  final _bank = TextEditingController();
  final _gold = TextEditingController();
  final _silver = TextEditingController();
  final _invest = TextEditingController();
  final _goods = TextEditingController();
  final _lent = TextEditingController();
  final _debts = TextEditingController();
  final _nisab = TextEditingController();
  calc.ZakatResult? _r;

  @override
  void dispose() {
    for (final c in [
      _cash, _bank, _gold, _silver, _invest, _goods, _lent, _debts, _nisab
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _calc() {
    setState(() {
      _r = calc.zakatFull(
        cash: parseNum(_cash.text) ?? 0,
        bank: parseNum(_bank.text) ?? 0,
        goldValue: parseNum(_gold.text) ?? 0,
        silverValue: parseNum(_silver.text) ?? 0,
        investments: parseNum(_invest.text) ?? 0,
        businessGoods: parseNum(_goods.text) ?? 0,
        moneyLent: parseNum(_lent.text) ?? 0,
        debts: parseNum(_debts.text) ?? 0,
        nisab: parseNum(_nisab.text) ?? 0,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final r = _r;
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      FinanceField(controller: _cash, label: t.financeFieldCash),
      FinanceField(controller: _bank, label: t.financeFieldBank),
      FinanceField(controller: _gold, label: t.financeFieldGoldValue),
      FinanceField(controller: _silver, label: t.financeFieldSilverValue),
      FinanceField(controller: _invest, label: t.financeFieldInvestments),
      FinanceField(controller: _goods, label: t.financeFieldBusinessGoods),
      FinanceField(controller: _lent, label: t.financeFieldMoneyLent),
      FinanceField(controller: _debts, label: t.financeFieldDebts),
      FinanceField(controller: _nisab, label: t.financeFieldNisab),
      FilledButton(onPressed: _calc, child: Text(t.financeCalculate)),
      if (r != null) ...[
        const SizedBox(height: Gap.lg),
        FinanceResultCard(
          noteLabel: t.financeNote,
          explanation: t.financeExplZakat,
          shareLabel: t.financeShare,
          onShare: () => _share(
              context,
              _shareText(t.financeToolZakat, [
                (t.financeResultZakatable, fmtTaka(r.zakatable)),
                (t.financeResultZakatDue, fmtTaka(r.due)),
              ]),
              t.financeCopied),
          rows: [
            FinanceResultRow(t.financeResultZakatable, fmtTaka(r.zakatable)),
            FinanceResultRow(t.financeResultZakatDue, fmtTaka(r.due),
                emphasise: true, valueColor: Brand.blue),
          ],
        ),
      ],
    ]);
  }
}

// ---------------------------------------------------------------------------
// 50-30-20 budget
// ---------------------------------------------------------------------------

class _BudgetCalculator extends StatefulWidget {
  const _BudgetCalculator();
  @override
  State<_BudgetCalculator> createState() => _BudgetState();
}

class _BudgetState extends State<_BudgetCalculator> {
  final _income = TextEditingController();
  calc.BudgetResult? _r;
  String? _err;

  @override
  void dispose() {
    _income.dispose();
    super.dispose();
  }

  void _calc(AppLocalizations t) {
    final inc = parseNum(_income.text);
    if (inc == null) {
      setState(() => _err = t.financeErrEnterNumbers);
      return;
    }
    if (inc <= 0) {
      setState(() => _err = t.financeErrPositive);
      return;
    }
    setState(() {
      _err = null;
      _r = calc.budget503020(inc);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final r = _r;
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      if (_err != null) FinanceErrorBanner(_err!),
      FinanceField(
          controller: _income,
          label: t.financeFieldIncome,
          icon: Icons.payments_outlined),
      FilledButton(onPressed: () => _calc(t), child: Text(t.financeCalculate)),
      if (r != null) ...[
        const SizedBox(height: Gap.lg),
        FinanceResultCard(
          noteLabel: t.financeNote,
          explanation: t.financeExplBudget,
          shareLabel: t.financeShare,
          onShare: () => _share(
              context,
              _shareText(t.financeToolBudget, [
                (t.financeResultNeeds, fmtTaka(r.needs)),
                (t.financeResultWants, fmtTaka(r.wants)),
                (t.financeResultSavings, fmtTaka(r.savings)),
              ]),
              t.financeCopied),
          rows: [
            FinanceResultRow(t.financeResultNeeds, fmtTaka(r.needs)),
            FinanceResultRow(t.financeResultWants, fmtTaka(r.wants)),
            FinanceResultRow(t.financeResultSavings, fmtTaka(r.savings),
                emphasise: true, valueColor: Brand.success),
          ],
        ),
      ],
    ]);
  }
}

// ---------------------------------------------------------------------------
// Can I afford this? (cashflow vs EMI)
// ---------------------------------------------------------------------------

class _AffordCalculator extends StatefulWidget {
  const _AffordCalculator();
  @override
  State<_AffordCalculator> createState() => _AffordState();
}

class _AffordState extends State<_AffordCalculator> {
  final _income = TextEditingController();
  final _expenses = TextEditingController();
  final _price = TextEditingController();
  final _down = TextEditingController();
  final _months = TextEditingController();
  final _rate = TextEditingController();
  calc.AffordResult? _r;
  String? _err;

  @override
  void dispose() {
    _income.dispose();
    _expenses.dispose();
    _price.dispose();
    _down.dispose();
    _months.dispose();
    _rate.dispose();
    super.dispose();
  }

  void _calc(AppLocalizations t) {
    final inc = parseNum(_income.text);
    final exp = parseNum(_expenses.text) ?? 0;
    final price = parseNum(_price.text);
    final down = parseNum(_down.text) ?? 0;
    final n = parseNum(_months.text) ?? 1;
    final r = parseNum(_rate.text) ?? 0;
    if (inc == null || price == null) {
      setState(() => _err = t.financeErrEnterNumbers);
      return;
    }
    if (inc <= 0 || price <= 0) {
      setState(() => _err = t.financeErrPositive);
      return;
    }
    setState(() {
      _err = null;
      _r = calc.affordability(inc, exp, price, down, n.round(), r, 'reducing');
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final r = _r;
    final good = r != null && r.affordable && r.burdenPct <= 30;
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      if (_err != null) FinanceErrorBanner(_err!),
      FinanceField(controller: _income, label: t.financeFieldIncome),
      FinanceField(controller: _expenses, label: t.financeFieldExpenses),
      FinanceField(controller: _price, label: t.financeFieldPrice),
      FinanceField(controller: _down, label: t.financeFieldDownPayment),
      FinanceField(
          controller: _months,
          label: t.financeFieldMonths,
          allowDecimal: false),
      FinanceField(controller: _rate, label: t.financeFieldRate, suffix: '%'),
      FilledButton(onPressed: () => _calc(t), child: Text(t.financeCalculate)),
      if (r != null) ...[
        const SizedBox(height: Gap.lg),
        FinanceResultCard(
          noteLabel: t.financeNote,
          explanation: t.financeExplAfford,
          shareLabel: t.financeShare,
          onShare: () => _share(
              context,
              _shareText(t.financeToolAfford, [
                (t.financeResultEmi, fmtTaka(r.emi)),
                (t.financeResultLeftover, fmtTaka(r.leftover)),
                (t.financeResultBurden, '${fmtNum(r.burdenPct)}%'),
              ]),
              t.financeCopied),
          rows: [
            FinanceResultRow(t.financeResultFreeCash, fmtTaka(r.freeCash)),
            FinanceResultRow(t.financeResultEmi, fmtTaka(r.emi)),
            FinanceResultRow(t.financeResultLeftover, fmtTaka(r.leftover),
                emphasise: true,
                valueColor: r.leftover >= 0 ? Brand.success : Brand.danger),
            FinanceResultRow(
                t.financeResultBurden, '${fmtNum(r.burdenPct)}%',
                valueColor: good ? Brand.success : Brand.warning),
          ],
        ),
      ],
    ]);
  }
}

// ---------------------------------------------------------------------------
// Break-even
// ---------------------------------------------------------------------------

class _BreakEvenCalculator extends StatefulWidget {
  const _BreakEvenCalculator();
  @override
  State<_BreakEvenCalculator> createState() => _BreakEvenState();
}

class _BreakEvenState extends State<_BreakEvenCalculator> {
  final _fixed = TextEditingController();
  final _price = TextEditingController();
  final _cost = TextEditingController();
  calc.BreakEvenResult? _r;
  String? _err;

  @override
  void dispose() {
    _fixed.dispose();
    _price.dispose();
    _cost.dispose();
    super.dispose();
  }

  void _calc(AppLocalizations t) {
    final f = parseNum(_fixed.text);
    final p = parseNum(_price.text);
    final c = parseNum(_cost.text) ?? 0;
    if (f == null || p == null) {
      setState(() => _err = t.financeErrEnterNumbers);
      return;
    }
    if (f <= 0 || p <= 0) {
      setState(() => _err = t.financeErrPositive);
      return;
    }
    setState(() {
      _err = null;
      _r = calc.breakEven(f, p, c);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final r = _r;
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      if (_err != null) FinanceErrorBanner(_err!),
      FinanceField(controller: _fixed, label: t.financeFieldFixedCost),
      FinanceField(controller: _price, label: t.financeFieldUnitPrice),
      FinanceField(controller: _cost, label: t.financeFieldUnitCost),
      FilledButton(onPressed: () => _calc(t), child: Text(t.financeCalculate)),
      if (r != null) ...[
        const SizedBox(height: Gap.lg),
        if (r.impossible)
          FinanceErrorBanner(t.financeErrPositive)
        else
          FinanceResultCard(
            noteLabel: t.financeNote,
            explanation: t.financeExplBreakEven,
            shareLabel: t.financeShare,
            onShare: () => _share(
                context,
                _shareText(t.financeToolBreakEven, [
                  (t.financeResultUnits, fmtNum(r.units!.toDouble())),
                  (t.financeResultRevenue, fmtTaka(r.revenue)),
                ]),
                t.financeCopied),
            rows: [
              FinanceResultRow(
                  t.financeResultUnits, fmtNum(r.units!.toDouble()),
                  emphasise: true, valueColor: Brand.blue),
              FinanceResultRow(t.financeResultRevenue, fmtTaka(r.revenue)),
            ],
          ),
      ],
    ]);
  }
}

// ---------------------------------------------------------------------------
// Simple ROI
// ---------------------------------------------------------------------------

class _RoiCalculator extends StatefulWidget {
  const _RoiCalculator();
  @override
  State<_RoiCalculator> createState() => _RoiState();
}

class _RoiState extends State<_RoiCalculator> {
  final _invested = TextEditingController();
  final _returned = TextEditingController();
  final _months = TextEditingController();
  calc.RoiResult? _r;
  String? _err;

  @override
  void dispose() {
    _invested.dispose();
    _returned.dispose();
    _months.dispose();
    super.dispose();
  }

  void _calc(AppLocalizations t) {
    final inv = parseNum(_invested.text);
    final ret = parseNum(_returned.text);
    final n = parseNum(_months.text) ?? 0;
    if (inv == null || ret == null) {
      setState(() => _err = t.financeErrEnterNumbers);
      return;
    }
    if (inv <= 0) {
      setState(() => _err = t.financeErrPositive);
      return;
    }
    setState(() {
      _err = null;
      _r = calc.simpleRoi(inv, ret, n.round());
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final r = _r;
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      if (_err != null) FinanceErrorBanner(_err!),
      FinanceField(controller: _invested, label: t.financeFieldInvested),
      FinanceField(controller: _returned, label: t.financeFieldReturned),
      FinanceField(
          controller: _months,
          label: t.financeFieldMonths,
          allowDecimal: false),
      FilledButton(onPressed: () => _calc(t), child: Text(t.financeCalculate)),
      if (r != null) ...[
        const SizedBox(height: Gap.lg),
        FinanceResultCard(
          noteLabel: t.financeNote,
          explanation: t.financeExplRoi,
          shareLabel: t.financeShare,
          onShare: () => _share(
              context,
              _shareText(t.financeToolRoi, [
                (t.financeResultRoi, '${fmtNum(r.roiPct)}%'),
                (t.financeResultProfit, fmtTaka(r.profit)),
              ]),
              t.financeCopied),
          rows: [
            FinanceResultRow(t.financeResultRoi, '${fmtNum(r.roiPct)}%',
                emphasise: true,
                valueColor: r.profit >= 0 ? Brand.success : Brand.danger),
            FinanceResultRow(t.financeResultProfit, fmtTaka(r.profit)),
            if (r.annualisedPct != null)
              FinanceResultRow(
                  t.financeResultAnnualised, '${fmtNum(r.annualisedPct!)}%'),
          ],
        ),
      ],
    ]);
  }
}

// ---------------------------------------------------------------------------
// Currency / unit convert
// ---------------------------------------------------------------------------

class _ConvertCalculator extends StatefulWidget {
  const _ConvertCalculator();
  @override
  State<_ConvertCalculator> createState() => _ConvertState();
}

class _ConvertState extends State<_ConvertCalculator> {
  final _amount = TextEditingController();
  final _rate = TextEditingController();
  double? _r;
  String? _err;

  @override
  void dispose() {
    _amount.dispose();
    _rate.dispose();
    super.dispose();
  }

  void _calc(AppLocalizations t) {
    final a = parseNum(_amount.text);
    final rate = parseNum(_rate.text);
    if (a == null || rate == null) {
      setState(() => _err = t.financeErrEnterNumbers);
      return;
    }
    setState(() {
      _err = null;
      _r = calc.convertAmount(a, rate);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final r = _r;
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      if (_err != null) FinanceErrorBanner(_err!),
      FinanceField(controller: _amount, label: t.financeFieldAmount),
      FinanceField(controller: _rate, label: t.financeFieldFxRate),
      FilledButton(onPressed: () => _calc(t), child: Text(t.financeCalculate)),
      if (r != null) ...[
        const SizedBox(height: Gap.lg),
        FinanceResultCard(
          noteLabel: t.financeNote,
          explanation: t.financeExplConvert,
          shareLabel: t.financeShare,
          onShare: () => _share(
              context,
              _shareText(t.financeToolConvert, [
                (t.financeResultConverted, fmtNum(r)),
              ]),
              t.financeCopied),
          rows: [
            FinanceResultRow(t.financeResultConverted, fmtNum(r),
                emphasise: true, valueColor: Brand.blue),
          ],
        ),
      ],
    ]);
  }
}

// ---------------------------------------------------------------------------
// Net worth (backend-computed — the one network call)
// ---------------------------------------------------------------------------

class _NetWorthTab extends StatefulWidget {
  const _NetWorthTab();
  @override
  State<_NetWorthTab> createState() => _NetWorthTabState();
}

class _NetWorthTabState extends State<_NetWorthTab> {
  Map<String, dynamic>? _r;
  bool _loading = true;
  bool _error = false;

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
      _r = await context.read<AppState>().api.finance('net_worth', {});
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_off,
                size: 40, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: Gap.md),
            FilledButton(onPressed: _load, child: Text(t.financeCalculate)),
          ],
        ),
      );
    }
    final r = _r ?? {};
    double v(String k) => parseNum(r[k]?.toString() ?? '0') ?? 0;
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(children: [
            FinanceResultRow(t.assets, fmtTaka(v('assets'))),
            FinanceResultRow(t.receivable, fmtTaka(v('receivable'))),
            FinanceResultRow(t.liabilities, fmtTaka(v('liabilities')),
                valueColor: Brand.danger),
            const Divider(),
            FinanceResultRow(t.netWorth, fmtTaka(v('net_worth')),
                emphasise: true, valueColor: Brand.blue),
          ]),
        ),
      ),
    ]);
  }
}
