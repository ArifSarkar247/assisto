import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../acct_api.dart';
import '../../../api.dart';
import '../../../l10n/app_localizations.dart';
import '../../../services/error_kind.dart' show honestFailText;
import '../../../state.dart';
import '../../../theme.dart';
import '../../../widgets/app_sheet.dart' show withNavBarInset;
import '../../../widgets/skeleton.dart';
import '../business_common.dart' show pair;
import 'acct_common.dart';

/// acctui — OPENING BALANCE wizard: what the shop had on the day the books
/// start (cash in the drawer, bank, bKash / Nagad, dues to collect, dues to
/// pay, stock value), one plain question per step with why it matters.
/// Dues already in the khata are shown and must NOT be typed again (the
/// khata is already in the books). Server: business/acct/opening.
class AcctOpeningScreen extends StatefulWidget {
  final int? businessId;
  const AcctOpeningScreen({super.key, this.businessId});

  @override
  State<AcctOpeningScreen> createState() => _AcctOpeningScreenState();
}

class _AcctOpeningScreenState extends State<AcctOpeningScreen> {
  static const _fields = [
    'cash', 'bank', 'bkash', 'nagad', 'receivable', 'payable', 'loans', 'stock'
  ];
  final _c = {for (final f in _fields) f: TextEditingController()};
  Map<String, dynamic>? _data; // hints (business/acct/hints)
  Map<String, dynamic>? _opening; // the core's saved opening, or null
  Object? _error;
  String? _saveError;
  bool _saving = false;
  int _step = 0;
  static const _steps = 5;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Rows the owner typed with a party name elsewhere are kept as they are;
  /// the wizard's single field is the party-less row.
  static int _unnamed(Object? rows) => (rows as List? ?? const [])
      .cast<Map>()
      .where((r) => '${r['party'] ?? ''}'.isEmpty)
      .fold(0, (a, r) => a + ((r['amount'] as num?)?.toInt() ?? 0));

  static List<Map> _named(Object? rows) => (rows as List? ?? const [])
      .cast<Map>()
      .where((r) => '${r['party'] ?? ''}'.isNotEmpty)
      .toList();

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final api = context.read<AppState>().api;
      final h = await api.acctHints(widget.businessId);
      final o = await api.booksOpening(widget.businessId);
      if (!mounted) return;
      final ob = (o['opening'] as Map?)?.cast<String, dynamic>();
      if (ob != null) {
        for (final f in ['cash', 'bank', 'bkash', 'nagad', 'loans']) {
          _c[f]!.text = poishaToField((ob[f] as num?)?.toInt());
        }
        _c['receivable']!.text = poishaToField(_unnamed(ob['receivables']));
        _c['payable']!.text = poishaToField(_unnamed(ob['payables']));
        _c['stock']!.text = poishaToField((ob['inventory'] as num?)?.toInt());
      }
      setState(() {
        _data = h;
        _opening = ob;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  int? _val(String f) => _c[f]!.text.trim().isEmpty ? 0 : parseTakaToPoisha(_c[f]!.text);

  /// The opening day: the saved one, else the books' start day.
  String? get _day => '${_opening?['date'] ?? _data?['start_date'] ?? ''}'.isEmpty
      ? null
      : '${_opening?['date'] ?? _data?['start_date']}';

  bool get _locked {
    final lock = DateTime.tryParse('${_data?['lock_date'] ?? ''}');
    final day = DateTime.tryParse(_day ?? '');
    return lock != null && day != null && !day.isAfter(lock);
  }

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    final v = <String, int>{};
    for (final f in _fields) {
      if (f == 'stock' && _c[f]!.text.trim().isEmpty) continue; // keep the estimate
      final x = _val(f);
      if (x == null) {
        setState(() => _saveError = t.acuErrAmount);
        return;
      }
      v[f] = x;
    }
    final body = <String, dynamic>{
      'date': _day ?? acctIso(DateTime.now()),
      for (final f in ['cash', 'bank', 'bkash', 'nagad', 'loans']) f: v[f],
      'inventory': v['stock'], // null = keep the reconstructed opening stock
      'receivables': [
        ..._named(_opening?['receivables']),
        if ((v['receivable'] ?? 0) > 0) {'party': '', 'amount': v['receivable']},
      ],
      'payables': [
        ..._named(_opening?['payables']),
        if ((v['payable'] ?? 0) > 0) {'party': '', 'amount': v['payable']},
      ],
    };
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final r = await context.read<AppState>().api.booksSetOpening(widget.businessId, body);
      if ((r['_status'] as int? ?? 0) == 200) {
        messenger.showSnackBar(SnackBar(content: Text(t.acuOpeningSaved)));
        nav.pop(true);
        return;
      }
      if (!mounted) return;
      setState(() => _saveError = pair(context, r['detail'], fallback: t.acuSaveFailed));
    } catch (e) {
      if (mounted) setState(() => _saveError = honestFailText(t, e));
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.acuOpening)),
      body: _body(t),
      bottomNavigationBar: _data == null || _locked ? null : _nav(t),
    );
  }

  Widget _nav(AppLocalizations t) {
    final last = _step == _steps - 1;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.md),
        child: Row(children: [
          if (_step > 0)
            Expanded(
              child: SizedBox(
                height: 52,
                child: OutlinedButton(
                  onPressed: _saving ? null : () => setState(() => _step--),
                  child: Text(t.acuBack),
                ),
              ),
            ),
          if (_step > 0) const SizedBox(width: Gap.sm),
          Expanded(
            flex: 2,
            child: SizedBox(
              height: 52,
              child: FilledButton(
                key: const ValueKey('acct-opening-next'),
                onPressed: _saving
                    ? null
                    : last
                        ? _save
                        : () => setState(() {
                              _step++;
                              _saveError = null;
                            }),
                child: Text(last ? t.acuOpeningSave : t.acuNext),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _field(String f, String label, String help) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.lg),
        child: TextField(
          key: ValueKey('acct-opening-$f'),
          controller: _c[f],
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
          decoration: InputDecoration(
            prefixText: '৳ ',
            labelText: label,
            helperText: help,
            helperMaxLines: 4,
            border: const OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {}),
        ),
      );

  Widget _hint(String s) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: Gap.lg),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
          color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(Radii.md)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.info_outline_rounded, color: scheme.onSecondaryContainer),
        const SizedBox(width: Gap.sm),
        Expanded(
            child: Text(s, style: TextStyle(color: scheme.onSecondaryContainer, height: 1.4))),
      ]),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_error != null) {
      final e = _error;
      return StateMessage(
        icon: e is ApiException && e.status == 403 ? Icons.lock_rounded : Icons.cloud_off_rounded,
        title: t.acuOpening,
        message: e is ApiException && e.status == 403 ? e.message : honestFailText(t, e),
        action: FilledButton(onPressed: _load, child: Text(t.retry)),
      );
    }
    final d = _data;
    if (d == null) return const SkeletonList();
    final start = acctDay(context, _day);
    if (_locked) {
      return StateMessage(
          icon: Icons.lock_rounded, title: t.acuOpening, message: t.acuOpeningLocked(start));
    }
    final scheme = Theme.of(context).colorScheme;
    final khata = (d['khata'] as Map?) ?? const {};
    final children = <Widget>[
      Semantics(
        liveRegion: true,
        child: Text(t.acuStepOf(acctDigits(context, _step + 1), acctDigits(context, _steps)),
            style: TextStyle(color: scheme.onSurfaceVariant)),
      ),
      const SizedBox(height: Gap.xs),
      LinearProgressIndicator(value: (_step + 1) / _steps),
      const SizedBox(height: Gap.lg),
    ];
    switch (_step) {
      case 0:
        children.addAll([
          Text(t.acuOpeningIntroTitle,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: Gap.sm),
          Text(t.acuOpeningIntroBody(start), style: const TextStyle(height: 1.5)),
          const SizedBox(height: Gap.lg),
          _hint(t.acuOpeningIntroTip),
        ]);
      case 1:
        children.addAll([
          _title(t.acuOpeningMoneyTitle),
          _field('cash', t.acuAccCash, t.acuOpeningCashHelp(start)),
          _field('bank', t.acuAccBank, t.acuOpeningBankHelp),
          _field('bkash', t.acuAccBkash, t.acuOpeningMfsHelp),
          _field('nagad', t.acuAccNagad, t.acuOpeningMfsHelp),
        ]);
      case 2:
        children.addAll([
          _title(t.acuOpeningDuesTitle),
          _hint(t.acuOpeningKhataHas(acctMoney(context, khata['receivable']),
              acctMoney(context, khata['payable']))),
          _field('receivable', t.acuOpeningReceivable, t.acuOpeningReceivableHelp),
          _field('payable', t.acuOpeningPayable, t.acuOpeningPayableHelp),
          _field('loans', t.acuOpeningLoans, t.acuOpeningLoansHelp),
        ]);
      case 3:
        final est = d['stock_estimate'];
        children.addAll([
          _title(t.acuOpeningStockTitle),
          if (est != null) _hint(t.acuOpeningStockEstimate(acctMoney(context, est))),
          _field('stock', t.acuOpeningStock, t.acuOpeningStockHelp),
        ]);
      default:
        children.addAll([
          _title(t.acuOpeningReviewTitle),
          for (final f in _fields)
            _reviewRow(
                switch (f) {
                  'cash' => t.acuAccCash,
                  'bank' => t.acuAccBank,
                  'bkash' => t.acuAccBkash,
                  'nagad' => t.acuAccNagad,
                  'receivable' => t.acuOpeningReceivable,
                  'payable' => t.acuOpeningPayable,
                  'loans' => t.acuOpeningLoans,
                  _ => t.acuOpeningStock,
                },
                f == 'stock' && _c[f]!.text.trim().isEmpty
                    ? t.acuOpeningStockKept
                    : (_val(f) == null ? t.acuErrAmount : acctMoney(context, _val(f)))),
          const SizedBox(height: Gap.md),
          _hint(t.acuOpeningReviewNote),
        ]);
    }
    if (_saveError != null) {
      children.add(Semantics(
        liveRegion: true,
        child: Text(_saveError!,
            style: TextStyle(color: scheme.error, fontWeight: FontWeight.w600)),
      ));
    }
    return ListView(
      padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
      children: children,
    );
  }

  Widget _title(String s) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.lg),
        child: Semantics(
          header: true,
          child: Text(s,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        ),
      );

  Widget _reviewRow(String label, String value) => ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: Gap.md,
            children: [Text(label), Text(value, style: const TextStyle(fontWeight: FontWeight.w700))],
          ),
        ),
      );
}
