import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../books_api.dart';
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
  Widget _empty(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: withNavBarInset(context, const EdgeInsets.all(Gap.xl)),
      children: [
        Icon(Icons.menu_book_rounded, size: 56, color: scheme.primary),
        const SizedBox(height: Gap.lg),
        Text(t.lgrEmptyTitle,
            textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: Gap.sm),
        Text(t.lgrEmptyBody,
            textAlign: TextAlign.center,
            style: TextStyle(height: 1.4, color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.xl),
        SizedBox(
          height: 52,
          child: FilledButton.icon(
            onPressed: _syncing ? null : _sync,
            icon: const Icon(Icons.sync_rounded),
            label: Text(t.lgrUpdate),
          ),
        ),
        const SizedBox(height: Gap.lg),
        Text(t.lgrEmptyHowTo, style: TextStyle(height: 1.5, color: scheme.onSurfaceVariant)),
      ],
    );
  }

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
      Container(
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
            color: scheme.errorContainer, borderRadius: BorderRadius.circular(Radii.md)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
          const SizedBox(width: Gap.sm),
          Expanded(
              child: Text(pair(context, w), style: TextStyle(color: scheme.onErrorContainer))),
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
              style: TextStyle(
                  fontWeight: FontWeight.w600, color: ok ? scheme.primary : scheme.error)),
        ),
      ]),
    );
  }

  Widget _heading(String text) => Padding(
        padding: const EdgeInsets.only(top: Gap.lg, bottom: Gap.xs),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w800, letterSpacing: .2)),
      );

  /// One label / amount row. Wraps (never clips) at 200% font.
  Widget _row(String label, Object? amount, {bool strong = false, bool indent = false}) {
    final style = TextStyle(
        fontWeight: strong ? FontWeight.w800 : FontWeight.w400,
        fontSize: strong ? 16 : null,
        height: 1.35);
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

  Widget _rule() => Divider(height: Gap.md, color: Theme.of(context).colorScheme.outlineVariant);

  List<Widget> _accountRows(Object? rows) => [
        for (final r in (rows as List? ?? const []).cast<Map>())
          _row('${r['name']}', r['amount'], indent: true),
      ];

  // ---------------------------------------------------------------- tabs
  Widget _plTab(AppLocalizations t) {
    final p = _pl!;
    final net = (p['net_profit'] as num?)?.toInt() ?? 0;
    final periods = {
      _Period.thisMonth: t.lgrPeriodThisMonth,
      _Period.lastMonth: t.lgrPeriodLastMonth,
      _Period.thisYear: t.lgrPeriodThisYear,
    };
    return _list([
      Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
        for (final e in periods.entries)
          ChoiceChip(
            label: Text(e.value),
            selected: _period == e.key,
            onSelected: (_) {
              setState(() => _period = e.key);
              _load();
            },
          ),
      ]),
      const SizedBox(height: Gap.sm),
      Text(t.lgrPeriodRange(_day(p['from']), _day(p['to'])),
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      _heading(t.lgrIncomeHeading),
      ..._accountRows(p['sales']),
      if (((p['discounts_total'] as num?) ?? 0) != 0)
        _row(t.lgrDiscounts, -((p['discounts_total'] as num).toInt()), indent: true),
      _row(t.lgrNetSales, p['net_sales'], strong: true),
      _row(t.lgrCogs, -(((p['cogs_total'] as num?) ?? 0).toInt()), indent: true),
      _rule(),
      _row(t.lgrGrossProfit, p['gross_profit'], strong: true),
      _heading(t.lgrOpex),
      ..._accountRows(p['operating_expenses']),
      if ((p['operating_expenses'] as List? ?? const []).isEmpty) _row(t.lgrOpex, 0, indent: true),
      if ((p['other_income'] as List? ?? const []).isNotEmpty) ...[
        _heading(t.lgrOtherIncome),
        ..._accountRows(p['other_income']),
      ],
      _rule(),
      _row(net >= 0 ? t.lgrNetProfit : t.lgrNetLoss, net, strong: true),
    ]);
  }

  Widget _bsTab(AppLocalizations t) {
    final b = _bs!;
    return _list([
      _balancedBadge(b['balanced'] == true),
      Text(t.lgrAsOf(_day(b['as_of'])),
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      _heading(t.lgrAssets),
      ..._accountRows(b['assets']),
      _row(t.lgrTotalAssets, b['total_assets'], strong: true),
      _heading(t.lgrLiabilities),
      ..._accountRows(b['liabilities']),
      _row(t.lgrTotal, b['total_liabilities'], strong: true),
      _heading(t.lgrEquity),
      ..._accountRows(b['equity']),
      _row(t.lgrProfitToDate, b['profit_to_date'], indent: true),
      _row(t.lgrTotal, b['total_equity'], strong: true),
      _rule(),
      _row(t.lgrTotalLiabEq, b['total_liabilities_equity'], strong: true),
    ]);
  }

  Widget _tbTab(AppLocalizations t) {
    final b = _tb!;
    final scheme = Theme.of(context).colorScheme;
    return _list([
      _balancedBadge(b['balanced'] == true),
      Text(t.lgrAsOf(_day(b['as_of'])), style: TextStyle(color: scheme.onSurfaceVariant)),
      const SizedBox(height: Gap.md),
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
    ]);
  }
}
