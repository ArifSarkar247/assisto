import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../widgets/finance_common.dart';
import '../widgets/tax_calc.dart' as tax;
import '../widgets/tax_widgets.dart';

/// Tax & Zakat (#60, SPEC v2.1 §21 ADVANCED) — Bangladesh.
///
/// Three tabs: INCOME TAX estimator (NBR slabs + tax-free threshold +
/// investment rebate + TDS, tax-year selector, category selector), ZAKAT
/// calculator (2.5%, nisab from user-entered gold 87.48g / silver 612.36g
/// per-gram prices, full asset buckets), and FILE RETURN (honest e-return
/// reminder linking to the official NBR portal — we never file for the user).
///
/// Everything computes CLIENT-SIDE and offline via widgets/tax_calc.dart
/// (mirrors backend/core/logic/tax_zakat.py). Every rate/threshold is a
/// PUBLISHED NBR figure, source-noted, NEVER invented. Amounts and bullion
/// prices are user inputs, never guessed. A persistent "not tax advice" banner
/// shows on every tab. ZERO Bangla literals — all strings via AppLocalizations.
class MoneyTaxScreen extends StatefulWidget {
  const MoneyTaxScreen({super.key});
  @override
  State<MoneyTaxScreen> createState() => _MoneyTaxScreenState();
}

class _MoneyTaxScreenState extends State<MoneyTaxScreen> {
  @override
  void initState() {
    super.initState();
    // Wire share_plus into the isolated compat shim used by tax_widgets.
    SharePlusCompat.wire((text) => Share.share(text));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(t.taxTitle),
          bottom: TabBar(
            isScrollable: MediaQuery.textScalerOf(context).scale(10) > 11.5,
            tabAlignment: MediaQuery.textScalerOf(context).scale(10) > 11.5
                ? TabAlignment.start
                : null,
            tabs: [
              Tab(text: t.taxTabIncome),
              Tab(text: t.taxTabZakat),
              Tab(text: t.taxTabFile),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _IncomeTaxTab(),
            _ZakatTab(),
            _FileReturnTab(),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// INCOME TAX estimator
// ---------------------------------------------------------------------------

class _IncomeTaxTab extends StatefulWidget {
  const _IncomeTaxTab();
  @override
  State<_IncomeTaxTab> createState() => _IncomeTaxTabState();
}

class _IncomeTaxTabState extends State<_IncomeTaxTab> {
  final _income = TextEditingController();
  final _invest = TextEditingController();
  final _tds = TextEditingController();
  String _year = tax.defaultTaxYear;
  tax.TaxCategory _category = tax.TaxCategory.general;
  String _location = 'dhaka_ctg';
  tax.TaxEstimate? _r;
  String? _err;
  bool _showBands = false;

  @override
  void dispose() {
    _income.dispose();
    _invest.dispose();
    _tds.dispose();
    super.dispose();
  }

  void _calc(AppLocalizations t) {
    final inc = parseNum(_income.text);
    final inv = parseNum(_invest.text) ?? 0;
    final tds = parseNum(_tds.text) ?? 0;
    if (inc == null) {
      setState(() => _err = t.financeErrEnterNumbers);
      return;
    }
    if (inc < 0) {
      setState(() => _err = t.financeErrPositive);
      return;
    }
    setState(() {
      _err = null;
      _r = tax.estimateIncomeTax(
        inc,
        year: _year,
        category: _category,
        eligibleInvestment: inv,
        tdsPaid: tds,
        location: _location,
      );
      _showBands = false;
    });
  }

  String _catLabel(AppLocalizations t, tax.TaxCategory c) {
    switch (c) {
      case tax.TaxCategory.general:
        return t.taxCatGeneral;
      case tax.TaxCategory.femaleSenior:
        return t.taxCatFemaleSenior;
      case tax.TaxCategory.disabled:
        return t.taxCatDisabled;
      case tax.TaxCategory.thirdGender:
        return t.taxCatThirdGender;
      case tax.TaxCategory.freedomFighter:
        return t.taxCatFreedomFighter;
    }
  }

  String _locLabel(AppLocalizations t, String loc) {
    switch (loc) {
      case 'dhaka_ctg':
        return t.taxLocDhakaCtg;
      case 'other_city':
        return t.taxLocOtherCity;
      default:
        return t.taxLocElsewhere;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final r = _r;
    final scheme = Theme.of(context).colorScheme;
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      const TaxDisclaimerBanner(),
      if (_err != null) FinanceErrorBanner(_err!),
      TaxSectionTitle(t.taxYearLabel),
      DropdownButtonFormField<String>(
        isExpanded: true, // long labels ellipsize instead of overflowing
        initialValue: _year,
        decoration: InputDecoration(labelText: t.taxYearLabel),
        items: tax.taxYears.keys
            .map((y) => DropdownMenuItem(value: y, child: Text(y)))
            .toList(),
        onChanged: (v) => setState(() {
          _year = v ?? tax.defaultTaxYear;
          if (_r != null) _calc(t);
        }),
      ),
      const SizedBox(height: Gap.md),
      DropdownButtonFormField<tax.TaxCategory>(
        isExpanded: true, // long labels ellipsize instead of overflowing
        initialValue: _category,
        decoration: InputDecoration(labelText: t.taxCategoryLabel),
        items: tax.TaxCategory.values
            .map((c) =>
                DropdownMenuItem(value: c, child: Text(_catLabel(t, c), overflow: TextOverflow.ellipsis)))
            .toList(),
        onChanged: (v) => setState(() {
          _category = v ?? tax.TaxCategory.general;
          if (_r != null) _calc(t);
        }),
      ),
      const SizedBox(height: Gap.md),
      DropdownButtonFormField<String>(
        isExpanded: true, // long labels ellipsize instead of overflowing
        initialValue: _location,
        decoration: InputDecoration(labelText: t.taxLocationLabel),
        items: const ['dhaka_ctg', 'other_city', 'elsewhere']
            .map((l) =>
                DropdownMenuItem(value: l, child: Text(_locLabel(t, l), overflow: TextOverflow.ellipsis)))
            .toList(),
        onChanged: (v) => setState(() {
          _location = v ?? 'dhaka_ctg';
          if (_r != null) _calc(t);
        }),
      ),
      const SizedBox(height: Gap.lg),
      FinanceField(
          controller: _income,
          label: t.taxFieldTaxableIncome,
          icon: Icons.payments_rounded),
      FinanceField(
          controller: _invest,
          label: t.taxFieldEligibleInvestment,
          icon: Icons.savings_rounded),
      FinanceField(
          controller: _tds,
          label: t.taxFieldTdsPaid,
          icon: Icons.receipt_long_rounded),
      FilledButton(onPressed: () => _calc(t), child: Text(t.taxEstimate)),
      if (r != null) ...[
        const SizedBox(height: Gap.lg),
        Card(
          color: scheme.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FinanceResultRow(t.taxResultYear, r.year),
                FinanceResultRow(
                    t.taxResultThreshold, fmtTaka(r.threshold)),
                FinanceResultRow(
                    t.taxResultTaxableAbove, fmtTaka(r.taxableAboveThreshold)),
                const Divider(),
                FinanceResultRow(t.taxResultGross, fmtTaka(r.grossTax)),
                FinanceResultRow(t.taxResultRebate, '-${fmtTaka(r.rebate)}',
                    valueColor: AssistoTokens.of(context).success),
                FinanceResultRow(
                    t.taxResultAfterRebate, fmtTaka(r.taxAfterRebate)),
                if (r.minimumTaxApplied)
                  FinanceResultRow(
                      t.taxResultMinApplied, fmtTaka(r.minimumTax),
                      valueColor: AssistoTokens.of(context).warning),
                FinanceResultRow(t.taxResultNet, fmtTaka(r.netTax)),
                if (r.tdsPaid > 0)
                  FinanceResultRow(
                      t.taxResultTds, '-${fmtTaka(r.tdsPaid)}'),
                const Divider(),
                if (r.refund > 0)
                  FinanceResultRow(t.taxResultRefund, fmtTaka(r.refund),
                      emphasise: true, valueColor: AssistoTokens.of(context).success)
                else
                  FinanceResultRow(t.taxResultPayable, fmtTaka(r.payable),
                      emphasise: true, valueColor: Theme.of(context).colorScheme.primary),
                if (r.bands.isNotEmpty) ...[
                  const SizedBox(height: Gap.sm),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () =>
                          setState(() => _showBands = !_showBands),
                      icon: Icon(_showBands
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded),
                      label: Text(_showBands
                          ? t.taxHideBands
                          : t.taxShowBands),
                    ),
                  ),
                  if (_showBands) _BandsTable(bands: r.bands, t: t),
                ],
                TaxSourceNote(source: _sourceFor(_year)),
                const SizedBox(height: Gap.md),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => shareOrCopy(
                        context, _shareText(t, r), t.taxLinkCopied),
                    icon: const Icon(Icons.ios_share_rounded, size: 18),
                    label: Text(t.taxShareEstimate),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ]);
  }

  // Human-readable source note per year (matches tax_zakat.py `source`).
  String _sourceFor(String year) => year == '2024-2025'
      ? 'NBR Finance Act 2024'
      : 'NBR Finance Ordinance 2025';

  String _shareText(AppLocalizations t, tax.TaxEstimate r) {
    final b = StringBuffer('${t.taxTitle} — ${t.taxTabIncome}\n');
    b.writeln('${t.taxResultYear}: ${r.year}');
    b.writeln('${t.taxResultGross}: ${fmtTaka(r.grossTax)}');
    b.writeln('${t.taxResultRebate}: ${fmtTaka(r.rebate)}');
    b.writeln('${t.taxResultNet}: ${fmtTaka(r.netTax)}');
    if (r.refund > 0) {
      b.writeln('${t.taxResultRefund}: ${fmtTaka(r.refund)}');
    } else {
      b.writeln('${t.taxResultPayable}: ${fmtTaka(r.payable)}');
    }
    b.writeln('— ${t.taxDisclaimer}');
    b.write('— Assisto');
    return b.toString();
  }
}

class _BandsTable extends StatelessWidget {
  final List<tax.SlabBandResult> bands;
  final AppLocalizations t;
  const _BandsTable({required this.bands, required this.t});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowHeight: 40,
        dataRowMinHeight: 36,
        dataRowMaxHeight: 40,
        columnSpacing: Gap.xl,
        headingTextStyle: TextStyle(
            fontWeight: FontWeight.w700, color: scheme.onSecondaryContainer),
        columns: [
          DataColumn(label: Text(t.taxBandSlab)),
          DataColumn(label: Text(t.taxBandRate)),
          DataColumn(label: Text(t.taxBandTax)),
        ],
        rows: [
          for (final b in bands)
            DataRow(cells: [
              DataCell(Text(fmtTaka(b.width))),
              DataCell(Text('${fmtNum(b.ratePct)}%')),
              DataCell(Text(fmtTaka(b.tax))),
            ]),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// ZAKAT calculator (nisab from user-entered per-gram prices + asset buckets)
// ---------------------------------------------------------------------------

class _ZakatTab extends StatefulWidget {
  const _ZakatTab();
  @override
  State<_ZakatTab> createState() => _ZakatTabState();
}

class _ZakatTabState extends State<_ZakatTab> {
  // Nisab inputs (per-gram prices the user enters — never guessed).
  final _goldPrice = TextEditingController();
  final _silverPrice = TextEditingController();
  // Asset buckets.
  final _cash = TextEditingController();
  final _bank = TextEditingController();
  final _gold = TextEditingController();
  final _silver = TextEditingController();
  final _invest = TextEditingController();
  final _goods = TextEditingController();
  final _lent = TextEditingController();
  final _debts = TextEditingController();

  tax.NisabResult? _nisab;
  bool _useSilverNisab = true; // silver nisab captures more wealth (lower)
  tax.ZakatResult? _r;

  @override
  void dispose() {
    for (final c in [
      _goldPrice, _silverPrice, _cash, _bank, _gold, _silver, _invest,
      _goods, _lent, _debts
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _calcNisab() {
    setState(() {
      _nisab = tax.zakatNisab(
        goldPricePerGram: parseNum(_goldPrice.text) ?? 0,
        silverPricePerGram: parseNum(_silverPrice.text) ?? 0,
      );
    });
  }

  double _chosenNisab() {
    final n = _nisab;
    if (n == null) return 0;
    return _useSilverNisab ? n.silverNisab : n.goldNisab;
  }

  void _calc() {
    setState(() {
      _r = tax.zakat(
        cash: parseNum(_cash.text) ?? 0,
        bank: parseNum(_bank.text) ?? 0,
        goldValue: parseNum(_gold.text) ?? 0,
        silverValue: parseNum(_silver.text) ?? 0,
        investments: parseNum(_invest.text) ?? 0,
        businessGoods: parseNum(_goods.text) ?? 0,
        moneyLent: parseNum(_lent.text) ?? 0,
        debts: parseNum(_debts.text) ?? 0,
        nisab: _chosenNisab(),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final n = _nisab;
    final r = _r;
    final scheme = Theme.of(context).colorScheme;
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      const TaxDisclaimerBanner(),
      TaxSectionTitle(t.zakatNisabTitle),
      Text(t.zakatNisabHint,
          style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
      const SizedBox(height: Gap.md),
      FinanceField(
          controller: _goldPrice,
          label: t.zakatFieldGoldPricePerGram,
          icon: Icons.scale_rounded),
      FinanceField(
          controller: _silverPrice,
          label: t.zakatFieldSilverPricePerGram,
          icon: Icons.scale_rounded),
      OutlinedButton(
          onPressed: _calcNisab, child: Text(t.zakatCalcNisab)),
      if (n != null) ...[
        const SizedBox(height: Gap.md),
        Card(
          color: scheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Column(children: [
              FinanceResultRow(
                  '${t.zakatNisabGold} (${tax.nisabGoldGrams}g)',
                  fmtTaka(n.goldNisab)),
              FinanceResultRow(
                  '${t.zakatNisabSilver} (${tax.nisabSilverGrams}g)',
                  fmtTaka(n.silverNisab)),
              const SizedBox(height: Gap.sm),
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(value: true, label: Text(t.zakatUseSilver)),
                  ButtonSegment(value: false, label: Text(t.zakatUseGold)),
                ],
                selected: {_useSilverNisab},
                onSelectionChanged: (s) => setState(() {
                  _useSilverNisab = s.first;
                  if (_r != null) _calc();
                }),
              ),
            ]),
          ),
        ),
      ],
      const Divider(height: Gap.xl),
      TaxSectionTitle(t.zakatAssetsTitle),
      FinanceField(controller: _cash, label: t.financeFieldCash),
      FinanceField(controller: _bank, label: t.financeFieldBank),
      FinanceField(controller: _gold, label: t.financeFieldGoldValue),
      FinanceField(controller: _silver, label: t.financeFieldSilverValue),
      FinanceField(controller: _invest, label: t.financeFieldInvestments),
      FinanceField(controller: _goods, label: t.financeFieldBusinessGoods),
      FinanceField(controller: _lent, label: t.financeFieldMoneyLent),
      FinanceField(controller: _debts, label: t.financeFieldDebts),
      FilledButton(onPressed: _calc, child: Text(t.zakatCalculate)),
      if (r != null) ...[
        const SizedBox(height: Gap.lg),
        Card(
          color: scheme.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FinanceResultRow(
                    t.zakatResultZakatable, fmtTaka(r.zakatable)),
                if (r.nisabSet)
                  FinanceResultRow(t.zakatResultNisab, fmtTaka(r.nisab))
                else
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: Gap.xs),
                    child: Text(t.zakatNisabUnset,
                        style: TextStyle(color: AssistoTokens.of(context).warning)),
                  ),
                FinanceResultRow(
                    t.zakatResultAboveNisab,
                    r.aboveNisab ? t.zakatYes : t.zakatNo,
                    valueColor:
                        r.aboveNisab ? AssistoTokens.of(context).success : scheme.onSurface),
                const Divider(),
                FinanceResultRow(t.zakatResultDue, fmtTaka(r.due),
                    emphasise: true, valueColor: Theme.of(context).colorScheme.primary),
                Padding(
                  padding: const EdgeInsets.only(top: Gap.xs),
                  child: Text(t.zakatRateNote,
                      style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
                ),
                const SizedBox(height: Gap.md),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => shareOrCopy(context,
                        _shareText(t, r), t.taxLinkCopied),
                    icon: const Icon(Icons.ios_share_rounded, size: 18),
                    label: Text(t.zakatShare),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ]);
  }

  String _shareText(AppLocalizations t, tax.ZakatResult r) {
    final b = StringBuffer('${t.taxTitle} — ${t.taxTabZakat}\n');
    b.writeln('${t.zakatResultZakatable}: ${fmtTaka(r.zakatable)}');
    if (r.nisabSet) b.writeln('${t.zakatResultNisab}: ${fmtTaka(r.nisab)}');
    b.writeln('${t.zakatResultDue}: ${fmtTaka(r.due)}');
    b.write('— Assisto');
    return b.toString();
  }
}

// ---------------------------------------------------------------------------
// FILE RETURN (e-return reminder → official NBR portal)
// ---------------------------------------------------------------------------

class _FileReturnTab extends StatelessWidget {
  const _FileReturnTab();
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      const TaxDisclaimerBanner(),
      const EReturnReminderCard(),
      const SizedBox(height: Gap.lg),
      Text(t.taxFileHonestNote,
          style: TextStyle(
              height: 1.4,
              color: Theme.of(context).colorScheme.onSurfaceVariant)),
    ]);
  }
}
