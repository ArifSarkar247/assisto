import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../books_api.dart';
import '../../ds/ds.dart';
import '../../l10n/app_localizations.dart';
import '../../messaging/date_separators.dart' show fmtDate, localDigits;
import '../../services/error_kind.dart' show honestFailText;
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
import 'business_common.dart' show pair, rememberedBusinessId;
import 'package:assisto/widgets/app_sheet.dart';

/// ledger (owner Part 1 f): the shop's double-entry BOOKS — profit & loss,
/// balance sheet and trial balance. Nothing is typed here: the server posts
/// every POS sale, khata entry, expense and cashbox row into the journal
/// (backend/core/ledger_service.py) and the reports read it. Behind the flag
/// `accounting_v2` (route 'books'); owner only (the hub hides it for staff and
/// the server answers 403 staff_restricted).
class BooksScreen extends StatefulWidget {
  final int? businessId;
  const BooksScreen({super.key, this.businessId});

  @override
  State<BooksScreen> createState() => _BooksScreenState();
}

enum _Period { thisMonth, lastMonth, thisYear }

class _BooksScreenState extends State<BooksScreen> {
  bool _loading = true;
  bool _syncing = false;
  Object? _error;
  int? _biz;
  _Period _period = _Period.thisMonth;
  Map<String, dynamic>? _pl, _bs, _tb;

  ApiClient get _api => context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _biz = widget.businessId ?? await rememberedBusinessId();
    await _load();
  }

  static String _d(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  (DateTime, DateTime) _range() {
    final now = DateTime.now();
    switch (_period) {
      case _Period.thisMonth:
        return (DateTime(now.year, now.month, 1), now);
      case _Period.lastMonth:
        final first = DateTime(now.year, now.month - 1, 1);
        return (first, DateTime(now.year, now.month, 0));
      case _Period.thisYear:
        return (DateTime(now.year, 1, 1), now);
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = _pl == null;
      _error = null;
    });
    try {
      final (from, to) = _range();
      // The first report syncs the books; the next two read the same journal.
      final pl = await _api.booksProfitLoss(_biz, from: _d(from), to: _d(to));
      final bs = await _api.booksBalanceSheet(_biz);
      final tb = await _api.booksTrialBalance(_biz);
      if (!mounted) return;
      setState(() {
        _pl = pl;
        _bs = bs;
        _tb = tb;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _sync() async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _syncing = true);
    try {
      final r = await _api.booksSync(_biz);
      final ok = (r['_status'] as int? ?? 0) == 200;
      if (ok) await _load();
      messenger.showSnackBar(SnackBar(
          content: Text(ok ? t.lgrUpdatedOk : pair(context, r['detail'], fallback: t.lgrUpdateFailed))));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(t.lgrUpdateFailed)));
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  bool get _hasData =>
      !_loading && _error == null && _tb != null && ((_tb!['rows'] as List?) ?? const []).isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(t.lgrTitle),
          actions: [
            IconButton(
              tooltip: t.lgrUpdate,
              onPressed: _syncing ? null : _sync,
              icon: _syncing
                  ? const SizedBox(
                      width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.sync_rounded),
            ),
          ],
          // tabs only when there is something to switch between (never a
          // dead tab bar over the empty / error state)
          bottom: !_hasData ? null : TabBar(isScrollable: true, tabs: [
            Tab(text: t.lgrTabPl),
            Tab(text: t.lgrTabBs),
            Tab(text: t.lgrTabTb),
          ]),
        ),
        body: _body(t),
      ),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_loading) return const SkeletonList();
    if (_error != null || _pl == null) {
      final e = _error;
      final staff = e is ApiException && e.status == 403;
      return StateMessage(
        icon: staff ? Icons.lock_rounded : Icons.cloud_off_rounded,
        title: t.lgrTitle,
        message: e is ApiException && staff ? e.message : honestFailText(t, e),
        action: staff ? null : FilledButton(onPressed: _load, child: Text(t.retry)),
      );
    }
    final empty = ((_tb!['rows'] as List?) ?? const []).isEmpty;
    if (empty) return _empty(t);
    return TabBarView(children: [_plTab(t), _bsTab(t), _tbTab(t)]);
  }

  /// Empty state: benefit line + big button + how-to (never a dead end).
  Widget _empty(AppLocalizations t) => ListView(
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        children: [
          DsEmptyState(
            icon: Icons.menu_book_rounded,
            title: t.lgrEmptyTitle,
            benefit: t.lgrEmptyBody,
            actionLabel: t.lgrUpdate,
            onAction: _syncing ? null : _sync,
            howTo: [t.lgrEmptyHowTo],
          ),
        ],
      );

  // ---------------------------------------------------------------- format
  String get _lang => Localizations.localeOf(context).languageCode;

  /// Poisha -> "৳1,25,000" (Bangladesh lakh grouping, Bangla digits in bn).
  /// Negative amounts in brackets, the accounting convention.
  String _money(Object? poisha) {
    final p = (poisha as num?)?.toInt() ?? 0;
    final taka = p.abs() / 100;
    final f = NumberFormat(taka == taka.truncateToDouble() ? '#,##,##0' : '#,##,##0.00', 'en');
    final s = localDigits('৳${f.format(taka)}', _lang);
    return p < 0 ? '($s)' : s;
  }

  String _day(Object? iso) {
    final d = DateTime.tryParse('${iso ?? ''}');
    return d == null ? '' : fmtDate('d MMM yyyy', d, _lang);
  }

  // ---------------------------------------------------------------- widgets
  Widget _list(List<Widget> children) => RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
          children: [..._warning(), ...children],
        ),
      );

  List<Widget> _warning() {
    final w = (_pl?['book'] as Map?)?['warning'];
    if (w == null) return const [];
    final scheme = Theme.of(context).colorScheme;
    return [
      DsCard(
        tone: DsTone.danger,
        padding: const EdgeInsets.all(Gap.md),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.warning_amber_rounded, color: scheme.ds.dangerInk),
          const SizedBox(width: Gap.sm),
          Expanded(
              child: Text(pair(context, w), style: AType.bodyMedium.copyWith(color: scheme.ds.dangerInk))),
        ]),
      ),
      const SizedBox(height: Gap.md),
    ];
  }

  Widget _balancedBadge(bool ok) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Row(children: [
        Icon(ok ? Icons.verified_rounded : Icons.error_outline_rounded,
            size: 20, color: ok ? scheme.primary : scheme.error),
        const SizedBox(width: Gap.xs),
        Expanded(
          child: Text(ok ? t.lgrBalanced : t.lgrNotBalanced,
              style: AType.bodyMedium.copyWith(
                  fontWeight: FontWeight.w600, color: ok ? scheme.primary : scheme.error)),
        ),
      ]),
    );
  }

  /// One label / amount row. Wraps (never clips) at 200% font.
  Widget _row(String label, Object? amount, {bool strong = false, bool indent = false}) {
    final base = strong
        ? Theme.of(context).textTheme.titleMedium
        : Theme.of(context).textTheme.bodyMedium;
    final style = (base ?? AType.bodyMedium).copyWith(
        fontWeight: strong ? FontWeight.w800 : FontWeight.w400, height: 1.35);
    return Semantics(
      container: true,
      label: '$label, ${_money(amount)}',
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Padding(
          padding: EdgeInsets.only(left: indent ? Gap.md : 0, top: 6, bottom: 6),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: Gap.md,
            children: [Text(label, style: style), Text(_money(amount), style: style)],
          ),
        ),
      ),
    );
  }

  Widget _rule() => Divider(height: Gap.md, color: Theme.of(context).colorScheme.ds.border);

  /// One report section: a header, then its rows in one DS card.
  List<Widget> _section(String title, List<Widget> rows) => [
        DsSectionHeader(title),
        DsCard(
          padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
        ),
      ];

  /// The headline figure of a report as the soft DS hero (big tight number).
  Widget _hero(String label, String value, String sub, {Color? valueColor, Widget? top}) {
    final ds = DsTokens.of(context);
    return DsHeroCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (top != null) ...[top, const SizedBox(height: Gap.sm)],
        Text(label, style: AType.titleSmall.copyWith(color: ds.muted)),
        const SizedBox(height: Gap.xs),
        DsNumber(value, color: valueColor),
        const SizedBox(height: Gap.xs),
        Text(sub, style: AType.bodyMedium.copyWith(color: ds.muted)),
      ]),
    );
  }

  List<Widget> _accountRows(Object? rows) => [
        for (final r in (rows as List? ?? const []).cast<Map>())
          _row('${r['name']}', r['amount'], indent: true),
      ];

  // ---------------------------------------------------------------- tabs
  // Page rule: the headline figure first (soft hero), then the report rows
  // grouped in DS cards; the period filter sits under the hero.
  Widget _plTab(AppLocalizations t) {
    final p = _pl!;
    final ds = DsTokens.of(context);
    final net = (p['net_profit'] as num?)?.toInt() ?? 0;
    final periods = {
      _Period.thisMonth: t.lgrPeriodThisMonth,
      _Period.lastMonth: t.lgrPeriodLastMonth,
      _Period.thisYear: t.lgrPeriodThisYear,
    };
    return _list([
      _hero(net >= 0 ? t.lgrNetProfit : t.lgrNetLoss, _money(net),
          t.lgrPeriodRange(_day(p['from']), _day(p['to'])),
          valueColor: net < 0 ? ds.dangerInk : ds.successInk),
      const SizedBox(height: Gap.md),
      // the three periods as three equal DS pills in one row: never an odd
      // chip row; labels wrap at 200% instead of overflowing
      IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final e in periods.entries) ...[
          if (e.key != _Period.thisMonth) const SizedBox(width: Gap.sm),
          Expanded(
            child: Semantics(
              button: true,
              selected: _period == e.key,
              child: DsSurface(
                flat: true,
                radius: DsRadius.button,
                color: _period == e.key ? ds.primarySoft : ds.card,
                borderColor: _period == e.key ? ds.primaryInk : ds.border,
                padding: const EdgeInsets.symmetric(horizontal: Gap.xs, vertical: Gap.md),
                onTap: () {
                  setState(() => _period = e.key);
                  _load();
                },
                child: Center(
                  child: Text(e.value,
                      textAlign: TextAlign.center,
                      style: AType.labelLarge.copyWith(
                          color: _period == e.key ? ds.primaryInk : ds.text,
                          fontWeight: _period == e.key ? FontWeight.w700 : FontWeight.w500)),
                ),
              ),
            ),
          ),
        ],
      ])),
      ..._section(t.lgrIncomeHeading, [
        ..._accountRows(p['sales']),
        if (((p['discounts_total'] as num?) ?? 0) != 0)
          _row(t.lgrDiscounts, -((p['discounts_total'] as num).toInt()), indent: true),
        _row(t.lgrNetSales, p['net_sales'], strong: true),
        _row(t.lgrCogs, -(((p['cogs_total'] as num?) ?? 0).toInt()), indent: true),
        _rule(),
        _row(t.lgrGrossProfit, p['gross_profit'], strong: true),
      ]),
      ..._section(t.lgrOpex, [
        ..._accountRows(p['operating_expenses']),
        if ((p['operating_expenses'] as List? ?? const []).isEmpty) _row(t.lgrOpex, 0, indent: true),
      ]),
      if ((p['other_income'] as List? ?? const []).isNotEmpty)
        ..._section(t.lgrOtherIncome, _accountRows(p['other_income'])),
      // (net profit / loss is the hero at the top — not repeated here)
    ]);
  }

  Widget _bsTab(AppLocalizations t) {
    final b = _bs!;
    return _list([
      _hero(t.lgrTotalAssets, _money(b['total_assets']), t.lgrAsOf(_day(b['as_of'])),
          top: _balancedBadge(b['balanced'] == true)),
      ..._section(t.lgrAssets, [
        ..._accountRows(b['assets']),
        _row(t.lgrTotalAssets, b['total_assets'], strong: true),
      ]),
      ..._section(t.lgrLiabilities, [
        ..._accountRows(b['liabilities']),
        _row(t.lgrTotal, b['total_liabilities'], strong: true),
      ]),
      ..._section(t.lgrEquity, [
        ..._accountRows(b['equity']),
        _row(t.lgrProfitToDate, b['profit_to_date'], indent: true),
        _row(t.lgrTotal, b['total_equity'], strong: true),
      ]),
      const SizedBox(height: Gap.md),
      DsCard(
        padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm),
        child: _row(t.lgrTotalLiabEq, b['total_liabilities_equity'], strong: true),
      ),
    ]);
  }

  Widget _tbTab(AppLocalizations t) {
    final b = _tb!;
    return _list([
      _hero(t.lgrTotalDebit, _money(b['total_debit']), t.lgrAsOf(_day(b['as_of'])),
          top: _balancedBadge(b['balanced'] == true)),
      ..._section(t.lgrTabTb, [
        for (final r in (b['rows'] as List? ?? const []).cast<Map>())
          Semantics(
            container: true,
            excludeSemantics: true,
            label: '${r['code']} ${r['name']}, '
                '${(r['debit'] as num? ?? 0) > 0 ? '${t.lgrDebit} ${_money(r['debit'])}' : '${t.lgrCredit} ${_money(r['credit'])}'}',
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: Gap.md,
                  children: [
                    Text('${localDigits('${r['code']}', _lang)}  ${r['name']}'),
                    Text((r['debit'] as num? ?? 0) > 0
                        ? '${t.lgrDebitShort} ${_money(r['debit'])}'
                        : '${t.lgrCreditShort} ${_money(r['credit'])}'),
                  ],
                ),
              ),
            ),
          ),
        _rule(),
        _row(t.lgrTotalDebit, b['total_debit'], strong: true),
        _row(t.lgrTotalCredit, b['total_credit'], strong: true),
      ]),
    ]);
  }
}
