import '../../../l10n/app_localizations.dart';
import 'mini_xlsx.dart';

/// acctui — ONE shape for every report, so the screen, the PDF, the Excel
/// sheet and the CSV can never disagree. Rows keep RAW poisha; each renderer
/// formats (screen/PDF: ৳ + lakh grouping + Bangla digits; Excel/CSV: plain
/// taka numbers an accountant can add up).
enum AcctRowStyle { heading, normal, indent, strong, note }

class AcctReportRow {
  final String label;
  final int? amount; // poisha (single-column reports)
  final int? debit, credit; // two-column (trial balance, journal)
  final AcctRowStyle style;
  final String? code;
  const AcctReportRow(this.label,
      {this.amount, this.debit, this.credit, this.style = AcctRowStyle.normal, this.code});
}

class AcctReport {
  final String id; // pl | bs | tb | cf | vat
  final String title;
  final String period; // already localized "1 Nov 2026 to 30 Nov 2026"
  final List<AcctReportRow> rows;
  final bool twoColumns;
  final String? colA, colB; // two-column headings
  final bool? balanced;
  final String? footnote;
  const AcctReport(
      {required this.id,
      required this.title,
      required this.period,
      required this.rows,
      this.twoColumns = false,
      this.colA,
      this.colB,
      this.balanced,
      this.footnote});
}

int _i(Object? v) => (v as num?)?.toInt() ?? 0;
List<Map> _l(Object? v) => (v as List? ?? const []).cast<Map>();

AcctReportRow _acct(Map r, {bool negative = false}) => AcctReportRow('${r['name']}',
    amount: negative ? -_i(r['amount']) : _i(r['amount']),
    style: AcctRowStyle.indent,
    code: '${r['code'] ?? ''}');

AcctReport plReport(AppLocalizations t, Map<String, dynamic> p, String period) {
  final net = _i(p['net_profit']);
  return AcctReport(id: 'pl', title: t.acuRepPl, period: period, rows: [
    AcctReportRow(t.acuRepIncome, style: AcctRowStyle.heading),
    ..._l(p['sales']).map(_acct),
    if (_i(p['discounts_total']) != 0)
      AcctReportRow(t.acuRepDiscounts, amount: -_i(p['discounts_total']), style: AcctRowStyle.indent),
    AcctReportRow(t.acuRepNetSales, amount: _i(p['net_sales']), style: AcctRowStyle.strong),
    AcctReportRow(t.acuRepCogs, amount: -_i(p['cogs_total']), style: AcctRowStyle.indent),
    AcctReportRow(t.acuRepGrossProfit, amount: _i(p['gross_profit']), style: AcctRowStyle.strong),
    AcctReportRow(t.acuRepOpex, style: AcctRowStyle.heading),
    ..._l(p['operating_expenses']).map((r) => _acct(r, negative: true)),
    AcctReportRow(t.acuRepOpexTotal, amount: -_i(p['operating_expenses_total']), style: AcctRowStyle.strong),
    if (_l(p['other_income']).isNotEmpty) ...[
      AcctReportRow(t.acuRepOtherIncome, style: AcctRowStyle.heading),
      ..._l(p['other_income']).map(_acct),
    ],
    AcctReportRow(net >= 0 ? t.acuRepNetProfit : t.acuRepNetLoss, amount: net, style: AcctRowStyle.strong),
  ]);
}

AcctReport bsReport(AppLocalizations t, Map<String, dynamic> b, String period) => AcctReport(
      id: 'bs',
      title: t.acuRepBs,
      period: period,
      balanced: b['balanced'] == true,
      rows: [
        AcctReportRow(t.acuRepAssets, style: AcctRowStyle.heading),
        ..._l(b['assets']).map(_acct),
        AcctReportRow(t.acuRepTotalAssets, amount: _i(b['total_assets']), style: AcctRowStyle.strong),
        AcctReportRow(t.acuRepLiabilities, style: AcctRowStyle.heading),
        ..._l(b['liabilities']).map(_acct),
        AcctReportRow(t.acuRepTotal, amount: _i(b['total_liabilities']), style: AcctRowStyle.strong),
        AcctReportRow(t.acuRepEquity, style: AcctRowStyle.heading),
        ..._l(b['equity']).map(_acct),
        AcctReportRow(t.acuRepProfitToDate, amount: _i(b['profit_to_date']), style: AcctRowStyle.indent),
        AcctReportRow(t.acuRepTotal, amount: _i(b['total_equity']), style: AcctRowStyle.strong),
        AcctReportRow(t.acuRepTotalLiabEq,
            amount: _i(b['total_liabilities_equity']), style: AcctRowStyle.strong),
      ],
    );

AcctReport tbReport(AppLocalizations t, Map<String, dynamic> b, String period) => AcctReport(
      id: 'tb',
      title: t.acuRepTb,
      period: period,
      twoColumns: true,
      colA: t.acuRepDebit,
      colB: t.acuRepCredit,
      balanced: b['balanced'] == true,
      footnote: t.acuRepTbNote,
      rows: [
        for (final r in _l(b['rows']))
          AcctReportRow('${r['name']}',
              debit: _i(r['debit']), credit: _i(r['credit']), code: '${r['code'] ?? ''}'),
        AcctReportRow(t.acuRepTotal,
            debit: _i(b['total_debit']), credit: _i(b['total_credit']), style: AcctRowStyle.strong),
      ],
    );

AcctReport cfReport(AppLocalizations t, Map<String, dynamic> c, String period) {
  final op = (c['operating'] as Map?) ?? const {};
  final fin = (c['financing'] as Map?) ?? const {};
  final inv = (c['investing'] as Map?) ?? const {};
  return AcctReport(
    id: 'cf',
    title: t.acuRepCf,
    period: period,
    balanced: c['balanced'] == true,
    footnote: t.acuRepCfNote,
    rows: [
      AcctReportRow(t.acuRepCfOpening, amount: _i(c['opening_cash']), style: AcctRowStyle.strong),
      if (_i(c['opening_balances']) != 0)
        AcctReportRow(t.acuRepCfOpeningEntered, amount: _i(c['opening_balances']), style: AcctRowStyle.indent),
      AcctReportRow(t.acuRepCfOperating, style: AcctRowStyle.heading),
      AcctReportRow(t.acuRepCfCustomers, amount: _i(op['customers']), style: AcctRowStyle.indent),
      AcctReportRow(t.acuRepCfSuppliers, amount: _i(op['suppliers']), style: AcctRowStyle.indent),
      AcctReportRow(t.acuRepCfExpenses, amount: _i(op['expenses']), style: AcctRowStyle.indent),
      if (_i(op['vat']) != 0) AcctReportRow(t.acuRepCfVat, amount: _i(op['vat']), style: AcctRowStyle.indent),
      if (_i(op['other_income']) != 0)
        AcctReportRow(t.acuRepCfOtherIncome, amount: _i(op['other_income']), style: AcctRowStyle.indent),
      if (_i(op['other']) != 0)
        AcctReportRow(t.acuRepCfOther, amount: _i(op['other']), style: AcctRowStyle.indent),
      AcctReportRow(t.acuRepTotal, amount: _i(op['total']), style: AcctRowStyle.strong),
      if (_i(inv['total']) != 0) ...[
        AcctReportRow(t.acuRepCfInvesting, style: AcctRowStyle.heading),
        AcctReportRow(t.acuRepTotal, amount: _i(inv['total']), style: AcctRowStyle.strong),
      ],
      AcctReportRow(t.acuRepCfFinancing, style: AcctRowStyle.heading),
      AcctReportRow(t.acuRepCfCapital, amount: _i(fin['capital']), style: AcctRowStyle.indent),
      AcctReportRow(t.acuRepCfDrawings, amount: _i(fin['drawings']), style: AcctRowStyle.indent),
      AcctReportRow(t.acuRepCfLoans, amount: _i(fin['loans']), style: AcctRowStyle.indent),
      AcctReportRow(t.acuRepTotal, amount: _i(fin['total']), style: AcctRowStyle.strong),
      AcctReportRow(t.acuRepCfNet, amount: _i(c['net_change']), style: AcctRowStyle.strong),
      AcctReportRow(t.acuRepCfClosing, amount: _i(c['closing_cash']), style: AcctRowStyle.strong),
    ],
  );
}

AcctReport vatReport(AppLocalizations t, Map<String, dynamic> v, String period,
        String Function(Object?) digits) =>
    AcctReport(
      id: 'vat',
      title: t.acuRepVat,
      period: period,
      footnote: t.acuRepVatNote,
      rows: [
        AcctReportRow(t.acuRepVatSales(digits(v['sale_invoices'])), style: AcctRowStyle.heading),
        AcctReportRow(t.acuRepVatTaxableSales, amount: _i(v['taxable_sales']), style: AcctRowStyle.indent),
        AcctReportRow(t.acuRepVatOutput, amount: _i(v['output_vat']), style: AcctRowStyle.indent),
        AcctReportRow(t.acuRepVatPurchases(digits(v['purchase_bills'])), style: AcctRowStyle.heading),
        AcctReportRow(t.acuRepVatTaxablePurchases,
            amount: _i(v['taxable_purchases']), style: AcctRowStyle.indent),
        AcctReportRow(t.acuRepVatInput, amount: _i(v['input_vat']), style: AcctRowStyle.indent),
        AcctReportRow(t.acuRepVatNet, amount: _i(v['net_payable']), style: AcctRowStyle.strong),
        AcctReportRow(t.acuRepVatPaid, amount: _i(v['paid']), style: AcctRowStyle.indent),
        AcctReportRow(t.acuRepVatStillDue, amount: _i(v['still_due']), style: AcctRowStyle.strong),
      ],
    );

/// Journal (for the accountant's Excel): one row per line.
AcctReport journalReport(AppLocalizations t, List<Map> entries, String period) => AcctReport(
      id: 'journal',
      title: t.acuRepJournal,
      period: period,
      twoColumns: true,
      colA: t.acuRepDebit,
      colB: t.acuRepCredit,
      rows: [
        for (final e in entries) ...[
          AcctReportRow('#${e['number']} · ${e['date']} · ${e['memo'] ?? ''}'
              '${e['status'] == 'reversed' ? ' (${t.acuAuditReversed})' : e['status'] == 'reversal' ? ' (${t.acuAuditReversal})' : ''}',
              style: AcctRowStyle.heading),
          for (final l in _l(e['lines']))
            AcctReportRow('${l['name']}${'${l['party'] ?? ''}'.isEmpty ? '' : ' — ${l['party']}'}',
                debit: _i(l['debit']), credit: _i(l['credit']), code: '${l['code'] ?? ''}'),
        ],
      ],
    );

// ---------------------------------------------------------------- export
double _taka(int? p) => (p ?? 0) / 100;

/// One Excel sheet: title, period, headings, rows (numbers in TAKA).
XlsxSheet reportSheet(AcctReport r, {required String shop, required String colAccount,
    required String colCode, required String colAmount, required String balancedText}) {
  final rows = <List<XlsxCell?>>[
    [XlsxCell(shop, bold: true)],
    [XlsxCell(r.title, bold: true)],
    [XlsxCell(r.period)],
    [],
    [
      XlsxCell(colCode, bold: true),
      XlsxCell(colAccount, bold: true),
      if (r.twoColumns) ...[XlsxCell(r.colA, bold: true), XlsxCell(r.colB, bold: true)]
      else XlsxCell(colAmount, bold: true),
    ],
  ];
  for (final x in r.rows) {
    final bold = x.style == AcctRowStyle.heading || x.style == AcctRowStyle.strong;
    final label = x.style == AcctRowStyle.indent ? '    ${x.label}' : x.label;
    rows.add([
      XlsxCell(x.code),
      XlsxCell(label, bold: bold),
      if (r.twoColumns) ...[
        if (x.style == AcctRowStyle.heading) null else XlsxCell(_taka(x.debit), bold: bold),
        if (x.style == AcctRowStyle.heading) null else XlsxCell(_taka(x.credit), bold: bold),
      ] else
        x.amount == null ? null : XlsxCell(_taka(x.amount), bold: bold),
    ]);
  }
  if (r.balanced != null) rows.addAll([[], [null, XlsxCell(balancedText)]]);
  if (r.footnote != null) rows.add([null, XlsxCell(r.footnote)]);
  return XlsxSheet(r.title, rows, widths: r.twoColumns ? [8, 48, 16, 16] : [8, 48, 18]);
}

String _csvCell(String s) =>
    RegExp(r'[",\n\r]').hasMatch(s) ? '"${s.replaceAll('"', '""')}"' : s;

/// CSV (UTF-8 with BOM so Excel shows Bangla), numbers in TAKA.
String reportCsv(AcctReport r, {required String shop, required String colAccount,
    required String colCode, required String colAmount}) {
  final b = StringBuffer('﻿');
  void line(List<String> cells) => b.write('${cells.map(_csvCell).join(',')}\r\n');
  line([shop]);
  line([r.title]);
  line([r.period]);
  line(r.twoColumns
      ? [colCode, colAccount, r.colA ?? '', r.colB ?? '']
      : [colCode, colAccount, colAmount]);
  String n(int? p) => _taka(p).toStringAsFixed(2);
  for (final x in r.rows) {
    if (x.style == AcctRowStyle.heading) {
      line(['', x.label]);
    } else if (r.twoColumns) {
      line([x.code ?? '', x.label, n(x.debit), n(x.credit)]);
    } else {
      line([x.code ?? '', x.label, x.amount == null ? '' : n(x.amount)]);
    }
  }
  if (r.footnote != null) line(['', r.footnote!]);
  return b.toString();
}
