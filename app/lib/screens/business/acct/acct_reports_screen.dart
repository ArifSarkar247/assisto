import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart' show getTemporaryDirectory;
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../acct_api.dart';
import '../../../api.dart';
import '../../../books_api.dart';
import '../../../l10n/app_localizations.dart';
import '../../../services/error_kind.dart' show honestFailText;
import '../../../state.dart';
import '../../../theme.dart';
import '../../../widgets/app_sheet.dart';
import '../../../widgets/skeleton.dart';
import 'acct_common.dart';
import 'acct_entry_screen.dart';
import 'acct_report_model.dart';
import 'acct_report_pdf.dart';
import 'mini_xlsx.dart';

/// acctui — the five reports a BD shop's accountant / bank asks for: profit &
/// loss, balance sheet, trial balance, cash flow, VAT (Mushak) summary — per
/// month / quarter / year, each with a one-line plain explanation. Only the
/// report on screen is fetched (2 GB phones). Export: Excel (.xlsx, all five
/// + the journal), PDF (Bangla, this report) or CSV, through the share sheet.
class AcctReportsScreen extends StatefulWidget {
  final int? businessId;
  final bool openExport;
  final String initialReport;
  const AcctReportsScreen(
      {super.key, this.businessId, this.openExport = false, this.initialReport = 'pl'});

  @override
  State<AcctReportsScreen> createState() => _AcctReportsScreenState();
}

const acctReportIds = ['pl', 'bs', 'tb', 'cf', 'vat'];

class _AcctReportsScreenState extends State<AcctReportsScreen> {
  AcctPeriod _period = const AcctPeriod(AcctPeriodKind.month);
  late String _report = acctReportIds.contains(widget.initialReport) ? widget.initialReport : 'pl';
  final Map<String, Map<String, dynamic>> _cache = {};
  Object? _error;
  bool _loading = true;
  bool _exporting = false;
  bool _askedExport = false;
  String _shop = '';

  ApiClient get _api => context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String get _key => '$_report|${_period.kind.name}|${_period.offset}';

  Future<Map<String, dynamic>> _fetch(String report, AcctPeriod period) async {
    final (s, e) = period.range();
    final from = acctIso(s), to = acctIso(e);
    final biz = widget.businessId;
    switch (report) {
      case 'pl':
        return _api.booksProfitLoss(biz, from: from, to: to);
      case 'bs':
        return _api.acctBalanceSheetAsOf(biz, to);
      case 'tb':
        return _api.acctTrialBalanceAsOf(biz, to);
      case 'cf':
        return _api.booksCashFlow(biz, from: from, to: to);
      default:
        // acctui detail (VAT paid kept apart) + the core's sales register
        final v = await _api.acctVat(biz, from: from, to: to);
        try {
          final core = await _api.booksVat(biz, from: from, to: to);
          return {...v, 'register': core['register'] ?? const [], 'vat_ready': core['vat_ready']};
        } catch (_) {
          return v; // the register is extra; the summary stands alone
        }
    }
  }

  Future<void> _load() async {
    final key = _key;
    if (_cache.containsKey(key)) {
      setState(() {
        _loading = false;
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await _fetch(_report, _period);
      if ('${d['shop'] ?? ''}'.isNotEmpty) _shop = '${d['shop']}';
      if (!mounted) return;
      setState(() {
        _cache[key] = d;
        _loading = false;
      });
      if (widget.openExport && !_askedExport) {
        _askedExport = true;
        _exportSheet();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  String _periodText(String report, AcctPeriod period) {
    final t = AppLocalizations.of(context);
    final (s, e) = period.range();
    if (report == 'bs' || report == 'tb') return t.acuAsOf(acctDay(context, acctIso(e)));
    return t.acuRange(acctDay(context, acctIso(s)), acctDay(context, acctIso(e)));
  }

  AcctReport _build(String report, Map<String, dynamic> d, AcctPeriod period) {
    final t = AppLocalizations.of(context);
    final p = _periodText(report, period);
    return switch (report) {
      'pl' => plReport(t, d, p),
      'bs' => bsReport(t, d, p),
      'tb' => tbReport(t, d, p),
      'cf' => cfReport(t, d, p),
      _ => vatReport(t, d, p, (v) => acctDigits(context, v ?? 0)),
    };
  }

  String _reportName(AppLocalizations t, String id) => switch (id) {
        'pl' => t.acuRepPl,
        'bs' => t.acuRepBs,
        'tb' => t.acuRepTb,
        'cf' => t.acuRepCf,
        _ => t.acuRepVat,
      };

  String _reportWhat(AppLocalizations t, String id) => switch (id) {
        'pl' => t.acuRepPlWhat,
        'bs' => t.acuRepBsWhat,
        'tb' => t.acuRepTbWhat,
        'cf' => t.acuRepCfWhat,
        _ => t.acuRepVatWhat,
      };

  // ---------------------------------------------------------------- build
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.acuReports),
        actions: [
          IconButton(
            key: const ValueKey('acct-export'),
            tooltip: t.acuExport,
            onPressed: _exporting ? null : _exportSheet,
            icon: _exporting
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.ios_share_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          _cache.remove(_key);
          await _load();
        },
        child: ListView(
          padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xl)),
          children: [
            _periodBar(t),
            const SizedBox(height: Gap.md),
            Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
              for (final id in acctReportIds)
                ChoiceChip(
                  key: ValueKey('acct-rep-$id'),
                  label: Text(_reportName(t, id)),
                  selected: _report == id,
                  onSelected: (_) {
                    setState(() => _report = id);
                    _load();
                  },
                ),
            ]),
            const SizedBox(height: Gap.sm),
            Text(_reportWhat(t, _report),
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, height: 1.4)),
            const SizedBox(height: Gap.md),
            ..._content(t),
          ],
        ),
      ),
    );
  }

  Widget _periodBar(AppLocalizations t) {
    final lang = acctLang(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SegmentedButton<AcctPeriodKind>(
        segments: [
          ButtonSegment(value: AcctPeriodKind.month, label: Text(t.acuMonth)),
          ButtonSegment(value: AcctPeriodKind.quarter, label: Text(t.acuQuarter)),
          ButtonSegment(value: AcctPeriodKind.year, label: Text(t.acuYear)),
        ],
        selected: {_period.kind},
        showSelectedIcon: false,
        onSelectionChanged: (s) {
          setState(() => _period = AcctPeriod(s.first));
          _load();
        },
      ),
      const SizedBox(height: Gap.xs),
      Row(children: [
        IconButton(
          tooltip: t.acuPrevPeriod,
          icon: const Icon(Icons.chevron_left_rounded),
          onPressed: () {
            setState(() => _period = _period.shift(-1));
            _load();
          },
        ),
        Expanded(
          child: Text(_period.label(lang),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        ),
        IconButton(
          tooltip: t.acuNextPeriod,
          icon: const Icon(Icons.chevron_right_rounded),
          onPressed: _period.offset >= 0
              ? null
              : () {
                  setState(() => _period = _period.shift(1));
                  _load();
                },
        ),
      ]),
    ]);
  }

  List<Widget> _content(AppLocalizations t) {
    if (_loading) return const [SizedBox(height: 320, child: SkeletonList())];
    final e = _error;
    if (e != null) {
      return [
        StateMessage(
          icon: e is ApiException && e.status == 403 ? Icons.lock_rounded : Icons.cloud_off_rounded,
          title: _reportName(t, _report),
          message: e is ApiException && e.status == 403 ? e.message : honestFailText(t, e),
          action: FilledButton(onPressed: _load, child: Text(t.retry)),
        )
      ];
    }
    final d = _cache[_key];
    if (d == null) return const [];
    final r = _build(_report, d, _period);
    final empty = !r.rows.any((x) => (x.amount ?? 0) != 0 || (x.debit ?? 0) != 0 || (x.credit ?? 0) != 0);
    return [
      Text(r.period, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      if (r.balanced != null) _balanced(t, r.balanced!, cashFlow: r.id == 'cf'),
      if (empty) _empty(t) else ...r.rows.map((x) => _row(r, x)),
      if (r.footnote != null && !empty) ...[
        const SizedBox(height: Gap.md),
        Text(r.footnote!,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, height: 1.4)),
      ],
    ];
  }

  Widget _balanced(AppLocalizations t, bool ok, {bool cashFlow = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: Gap.xs),
      child: Semantics(
        liveRegion: true,
        child: Row(children: [
          Icon(ok ? Icons.verified_rounded : Icons.error_outline_rounded,
              size: 20, color: ok ? scheme.primary : scheme.error),
          const SizedBox(width: Gap.xs),
          Expanded(
            child: Text(
                cashFlow
                    ? (ok ? t.acuCfReconciles : t.acuCfNotReconciles)
                    : (ok ? t.acuBalanced : t.acuNotBalanced),
                style: TextStyle(fontWeight: FontWeight.w600, color: ok ? scheme.primary : scheme.error)),
          ),
        ]),
      ),
    );
  }

  Widget _empty(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: Gap.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Icon(Icons.insights_rounded, size: 48, color: scheme.primary),
        const SizedBox(height: Gap.sm),
        Text(t.acuRepEmptyTitle,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: Gap.xs),
        Text(t.acuRepEmptyBody, textAlign: TextAlign.center, style: const TextStyle(height: 1.4)),
        const SizedBox(height: Gap.lg),
        SizedBox(
          height: 52,
          child: FilledButton.icon(
            key: const ValueKey('acct-rep-empty-cta'),
            onPressed: () async {
              final saved = await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => AcctEntryScreen(businessId: widget.businessId)));
              if (saved == true && mounted) {
                _cache.clear();
                await _load();
              }
            },
            icon: const Icon(Icons.add_rounded),
            label: Text(t.acuEmptyCta),
          ),
        ),
        const SizedBox(height: Gap.md),
        Text(t.acuRepEmptyHowTo, style: TextStyle(height: 1.5, color: scheme.onSurfaceVariant)),
      ]),
    );
  }

  Widget _row(AcctReport r, AcctReportRow x) {
    final heading = x.style == AcctRowStyle.heading;
    final strong = x.style == AcctRowStyle.strong;
    final base = strong
        ? Theme.of(context).textTheme.titleMedium
        : Theme.of(context).textTheme.bodyMedium;
    final style = (base ?? const TextStyle()).copyWith(
        fontWeight: heading || strong ? FontWeight.w800 : FontWeight.w400, height: 1.35);
    final amounts = r.twoColumns
        ? [
            if ((x.debit ?? 0) != 0 || strong) '${r.colA}: ${acctMoney(context, x.debit)}',
            if ((x.credit ?? 0) != 0 || strong) '${r.colB}: ${acctMoney(context, x.credit)}',
          ].join('   ')
        : (x.amount == null ? '' : acctMoney(context, x.amount));
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Padding(
        padding: EdgeInsets.only(
            left: x.style == AcctRowStyle.indent ? Gap.md : 0, top: heading ? Gap.md : 6, bottom: 6),
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: Gap.md,
          children: [
            Text(x.label, style: style),
            if (amounts.isNotEmpty) Text(amounts, style: style),
          ],
        ),
      ),
    );
    return Semantics(
      container: true,
      header: heading,
      label: amounts.isEmpty ? x.label : '${x.label}, $amounts',
      excludeSemantics: true,
      child: strong
          ? DecoratedBox(
              decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant))),
              child: row)
          : row,
    );
  }

  // ---------------------------------------------------------------- export
  Future<void> _exportSheet() async {
    final t = AppLocalizations.of(context);
    final pick = await showAppSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t.acuExportTitle, style: Theme.of(ctx).textTheme.titleLarge),
          const SizedBox(height: Gap.xs),
          Text(t.acuExportBody(_period.label(acctLang(ctx))), style: const TextStyle(height: 1.4)),
          const SizedBox(height: Gap.md),
          ListTile(
            key: const ValueKey('acct-export-xlsx'),
            leading: const Icon(Icons.table_view_rounded),
            title: Text(t.acuExportXlsx),
            subtitle: Text(t.acuExportXlsxSub),
            onTap: () => Navigator.pop(ctx, 'xlsx'),
          ),
          ListTile(
            key: const ValueKey('acct-export-pdf'),
            leading: const Icon(Icons.picture_as_pdf_rounded),
            title: Text(t.acuExportPdf),
            subtitle: Text(t.acuExportPdfSub(_reportName(t, _report))),
            onTap: () => Navigator.pop(ctx, 'pdf'),
          ),
          ListTile(
            key: const ValueKey('acct-export-csv'),
            leading: const Icon(Icons.description_rounded),
            title: Text(t.acuExportCsv),
            subtitle: Text(t.acuExportCsvSub(_reportName(t, _report))),
            onTap: () => Navigator.pop(ctx, 'csv'),
          ),
        ]),
      ),
    );
    if (pick == null || !mounted) return;
    await _export(pick);
  }

  String _fileStem() {
    final (s, e) = _period.range();
    return 'assisto_accounts_${acctIso(s)}_${acctIso(e)}';
  }

  Future<void> _export(String what) async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final lang = acctLang(context);
    final shop = _shop.isEmpty ? t.acuTitle : _shop;
    setState(() => _exporting = true);
    try {
      final dir = await getTemporaryDirectory();
      late File f;
      late String mime;
      if (what == 'xlsx') {
        final sheets = <XlsxSheet>[];
        for (final id in acctReportIds) {
          final key = '$id|${_period.kind.name}|${_period.offset}';
          final d = _cache[key] ?? await _fetch(id, _period);
          _cache[key] = d;
          if (!mounted) return;
          sheets.add(reportSheet(_build(id, d, _period),
              shop: shop,
              colAccount: t.acuColAccount,
              colCode: t.acuColCode,
              colAmount: t.acuColAmount,
              balancedText: id == 'cf'
                  ? (d['reconciles'] == false ? t.acuCfNotReconciles : t.acuCfReconciles)
                  : (d['balanced'] == false ? t.acuNotBalanced : t.acuBalanced)));
        }
        final journal = await _journal();
        if (!mounted) return;
        sheets.add(reportSheet(journalReport(t, journal, _periodText('pl', _period)),
            shop: shop,
            colAccount: t.acuColAccount,
            colCode: t.acuColCode,
            colAmount: t.acuColAmount,
            balancedText: ''));
        f = File('${dir.path}/${_fileStem()}.xlsx');
        await f.writeAsBytes(buildXlsx(sheets), flush: true);
        mime = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      } else {
        final d = _cache[_key] ?? await _fetch(_report, _period);
        if (!mounted) return;
        final r = _build(_report, d, _period);
        if (what == 'pdf') {
          final now = DateTime.now();
          final bytes = await buildReportPdf(
              r,
              AcctPdfText(
                shop: shop,
                made: t.acuPdfMade(acctDay(context, acctIso(now))),
                balanced: r.balanced == null
                    ? ''
                    : r.id == 'cf'
                        ? (r.balanced! ? t.acuCfReconciles : t.acuCfNotReconciles)
                        : (r.balanced! ? t.acuBalanced : t.acuNotBalanced),
                money: (p) => acctMoneyFor(p, lang),
                pageLabel: (p, n) => t.acuPdfPage(acctDigits(context, p), acctDigits(context, n)),
              ));
          f = File('${dir.path}/${_fileStem()}_${r.id}.pdf');
          await f.writeAsBytes(bytes, flush: true);
          mime = 'application/pdf';
        } else {
          f = File('${dir.path}/${_fileStem()}_${r.id}.csv');
          await f.writeAsBytes(
              utf8.encode(reportCsv(r,
                  shop: shop,
                  colAccount: t.acuColAccount,
                  colCode: t.acuColCode,
                  colAmount: t.acuColAmount)),
              flush: true);
          mime = 'text/csv';
        }
      }
      try {
        await _api.acctExportLog(widget.businessId, what); // audit: who exported what
      } catch (_) {}
      await Share.shareXFiles([XFile(f.path, mimeType: mime)],
          text: t.acuExportShareText(shop, _period.label(lang)));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(t.acuExportFailed)));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// The period's journal, oldest first (at most 20 pages = 1,000 entries).
  Future<List<Map>> _journal() async {
    final (s, e) = _period.range();
    final out = <Map>[];
    for (var page = 1; page <= 20; page++) {
      final r = await _api.acctJournal(widget.businessId,
          from: acctIso(s), to: acctIso(e), page: page);
      out.addAll((r['entries'] as List? ?? const []).cast<Map>());
      if (r['has_more'] != true) break;
    }
    return out.reversed.toList();
  }
}
