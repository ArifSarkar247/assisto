import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../acct_api.dart';
import '../../../api.dart';
import '../../../l10n/app_localizations.dart';
import '../../../services/error_kind.dart' show honestFailText;
import '../../../state.dart';
import '../../../theme.dart';
import '../../../widgets/app_sheet.dart';
import '../../../widgets/skeleton.dart';
import '../business_common.dart' show pair;
import '../cashbox_screen.dart';
import 'acct_common.dart';

/// ledger2 — business accounting phase 2 screens (flag accounting_v2):
///  * AcctCashboxScreen  — say once what each hand-written cashbox row was
///    (the books park it in "unclassified" until then); a reclass entry.
///  * AcctVatRatesScreen — per-product VAT: exempt (VAT Act 2012, First
///    Schedule) or a reduced rate the OWNER types (Third Schedule). No rate
///    is invented by the app; a change counts from the day picked.
///  * AcctYearCloseSection — year-end close to retained earnings; reopening
///    needs a written reason (audit trail).
///  * AcctCostGapBanner / sheet — old sales with cost price 0 overstate
///    profit: honest banner + one-tap list, fix only when the owner asks.
/// Server: backend/core/ledger2_views.py.

String acctPct(BuildContext context, Object? bp) {
  final v = ((bp as num?)?.toInt() ?? 0) / 100;
  var s = v == v.truncateToDouble() ? '${v.toInt()}' : v.toStringAsFixed(2);
  if (s.contains('.')) s = s.replaceAll(RegExp(r'0+$'), '');
  return acctDigits(context, '$s%');
}

/// "7.5" / Bangla-digit "7.5" / "7,5" -> basis points (750); null when not 0 < x < 100.
int? parsePctToBp(String raw) {
  final b = StringBuffer();
  for (final r in raw.runes) {
    if (r >= 0x09E6 && r <= 0x09EF) {
      b.writeCharCode(0x30 + r - 0x09E6);
    } else if (r >= 0x30 && r <= 0x39) {
      b.writeCharCode(r);
    } else if (r == 0x2E || r == 0x2C) {
      b.write('.');
    }
  }
  final v = double.tryParse(b.toString());
  if (v == null || v <= 0 || v >= 100) return null;
  return (v * 100).round();
}

String _name(BuildContext context, Object? m) => pair(context, m);

Widget _errorState(BuildContext context, AppLocalizations t, Object e, String title,
        VoidCallback retry) =>
    StateMessage(
      icon: e is ApiException && e.status == 403 ? Icons.lock_rounded : Icons.cloud_off_rounded,
      title: title,
      message: e is ApiException && e.status == 403 ? e.message : honestFailText(t, e),
      action: FilledButton(onPressed: retry, child: Text(t.retry)),
    );

void _snack(BuildContext context, String s) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

bool _ok(Map<String, dynamic> r) {
  final s = r['_status'] as int? ?? 200;
  return s >= 200 && s < 300;
}

// ===================================================================== cashbox
class AcctCashboxScreen extends StatefulWidget {
  final int? businessId;
  const AcctCashboxScreen({super.key, this.businessId});

  @override
  State<AcctCashboxScreen> createState() => _AcctCashboxScreenState();
}

class _AcctCashboxScreenState extends State<AcctCashboxScreen> {
  Map<String, dynamic>? _d;
  Object? _error;
  bool _busy = false;
  bool _changed = false;

  ApiClient get _api => context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final d = await _api.acctCashbox(widget.businessId);
      if (mounted) setState(() => _d = d);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _pick(Map row) async {
    final t = AppLocalizations.of(context);
    final kind = '${row['kind']}';
    final choices = ((_d?['choices'] as Map?)?[kind] as List? ?? const []).cast<Map>();
    final current = '${row['code'] ?? ''}';
    final picked = await showAppSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
          children: [
            Text(kind == 'in' ? t.lg2CashInWhat : t.lg2CashOutWhat,
                style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: Gap.xs),
            Text('${acctMoney(ctx, row['amount'])} · ${acctDay(ctx, row['date'])}'
                '${'${row['note'] ?? ''}'.isEmpty ? '' : ' · ${row['note']}'}'),
            const SizedBox(height: Gap.sm),
            RadioGroup<String>(
              groupValue: current,
              onChanged: (v) => Navigator.pop(ctx, v),
              child: Column(children: [
                for (final c in choices)
                  RadioListTile<String>(
                    key: ValueKey('acct-cls-${c['code']}'),
                    value: '${c['code']}',
                    title: Text(_name(ctx, c['name'])),
                  ),
              ]),
            ),
            if (current.isNotEmpty)
              TextButton.icon(
                key: const ValueKey('acct-cls-clear'),
                onPressed: () => Navigator.pop(ctx, ''),
                icon: const Icon(Icons.undo_rounded),
                label: Text(t.lg2ClassifyClear),
              ),
          ],
        ),
      ),
    );
    if (picked == null || picked == current || !mounted) return;
    setState(() => _busy = true);
    try {
      final r = await _api.acctClassifyCash(widget.businessId, (row['id'] as num).toInt(), picked);
      if (!mounted) return;
      if (_ok(r)) {
        _changed = true;
        _snack(context, picked.isEmpty ? t.lg2ClassifyCleared : t.lg2ClassifyDone);
      } else {
        _snack(context, pair(context, r['detail'], fallback: t.acuSaveFailed));
      }
    } catch (e) {
      if (mounted) _snack(context, honestFailText(t, e));
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (did, _) {
        if (!did) Navigator.pop(context, _changed);
      },
      child: Scaffold(appBar: AppBar(title: Text(t.lg2CashboxTitle)), body: _body(t)),
    );
  }

  Widget _body(AppLocalizations t) {
    final e = _error;
    if (e != null) return _errorState(context, t, e, t.lg2CashboxTitle, _load);
    final d = _d;
    if (d == null) return const SkeletonList();
    final rows = (d['rows'] as List? ?? const []).cast<Map>();
    final scheme = Theme.of(context).colorScheme;
    if (rows.isEmpty) {
      return StateMessage(
        icon: Icons.point_of_sale_rounded,
        title: t.lg2CashboxEmptyTitle,
        message: t.lg2CashboxEmptyHow,
        action: widget.businessId == null
            ? null
            : FilledButton.icon(
                key: const ValueKey('acct-open-cashbox'),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => CashboxScreen(business: {'id': widget.businessId}))),
                icon: const Icon(Icons.point_of_sale_rounded),
                label: Text(t.lg2OpenCashbox),
              ),
      );
    }
    final pending = (d['unclassified'] as num?)?.toInt() ?? 0;
    final sorted = [...rows.where((r) => '${r['code'] ?? ''}'.isEmpty),
      ...rows.where((r) => '${r['code'] ?? ''}'.isNotEmpty)];
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        children: [
          Card(
            color: pending > 0 ? scheme.tertiaryContainer : scheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Semantics(
                liveRegion: true,
                child: Text(
                    pending > 0
                        ? t.lg2CashboxPending(acctDigits(context, pending),
                            acctMoney(context, d['unclassified_amount']))
                        : t.lg2CashboxAllDone,
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        height: 1.4,
                        color: pending > 0 ? scheme.onTertiaryContainer : null)),
              ),
            ),
          ),
          const SizedBox(height: Gap.sm),
          Text(t.lg2CashboxWhy,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
          const SizedBox(height: Gap.md),
          for (final r in sorted)
            Card(
              margin: const EdgeInsets.only(bottom: Gap.sm),
              child: ListTile(
                key: ValueKey('acct-cash-${r['id']}'),
                minVerticalPadding: Gap.sm,
                enabled: !_busy,
                leading: Icon(r['kind'] == 'in' ? Icons.south_west_rounded : Icons.north_east_rounded,
                    color: r['kind'] == 'in' ? scheme.primary : scheme.error),
                title: Text(
                    '${r['kind'] == 'in' ? t.lg2CashIn : t.lg2CashOut} · ${acctMoney(context, r['amount'])}',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text([
                  acctDay(context, r['date']),
                  if ('${r['note'] ?? ''}'.isNotEmpty) '${r['note']}',
                  '${r['code'] ?? ''}'.isEmpty ? t.lg2NotClassified : _name(context, r['name']),
                ].join(' · ')),
                trailing: Icon('${r['code'] ?? ''}'.isEmpty
                    ? Icons.help_outline_rounded
                    : Icons.check_circle_rounded,
                    color: '${r['code'] ?? ''}'.isEmpty ? scheme.tertiary : scheme.primary),
                onTap: () => _pick(r),
              ),
            ),
        ],
      ),
    );
  }
}

// ===================================================================== VAT rates
class AcctVatRatesScreen extends StatefulWidget {
  final int? businessId;
  const AcctVatRatesScreen({super.key, this.businessId});

  @override
  State<AcctVatRatesScreen> createState() => _AcctVatRatesScreenState();
}

class _AcctVatRatesScreenState extends State<AcctVatRatesScreen> {
  Map<String, dynamic>? _d;
  Object? _error;
  String _q = '';
  bool _changed = false;

  ApiClient get _api => context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final d = await _api.acctVatRates(widget.businessId, q: _q);
      if (mounted) setState(() => _d = d);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  String _modeText(AppLocalizations t, Map p) => switch ('${p['mode']}') {
        'exempt' => t.lg2VatExempt,
        'reduced' => t.lg2VatReducedAt(acctPct(context, p['vat_bp'])),
        _ => t.lg2VatStandardAt(acctPct(context, _d?['shop_vat_bp'])),
      };

  Future<void> _edit(Map p) async {
    final t = AppLocalizations.of(context);
    var mode = '${p['mode'] ?? 'standard'}';
    final rate = TextEditingController(
        text: p['mode'] == 'reduced' ? acctPct(context, p['vat_bp']).replaceAll('%', '') : '');
    final note = TextEditingController(text: '${p['note'] ?? ''}');
    String? err;
    final ok = await showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + MediaQuery.viewInsetsOf(ctx).bottom),
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('${p['name']}', style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: Gap.sm),
              RadioGroup<String>(
                groupValue: mode,
                onChanged: (v) => setSheet(() {
                  mode = v ?? mode;
                  err = null;
                }),
                child: Column(children: [
                  for (final m in const ['standard', 'exempt', 'reduced'])
                    RadioListTile<String>(
                      key: ValueKey('acct-vatmode-$m'),
                      value: m,
                      title: Text(switch (m) {
                        'exempt' => t.lg2VatExempt,
                        'reduced' => t.lg2VatReduced,
                        _ => t.lg2VatStandardAt(acctPct(ctx, _d?['shop_vat_bp'])),
                      }),
                      subtitle: Text(switch (m) {
                        'exempt' => t.lg2VatExemptLaw,
                        'reduced' => t.lg2VatReducedLaw,
                        _ => t.lg2VatStandardSub,
                      }),
                    ),
                ]),
              ),
              if (mode == 'reduced')
                TextField(
                  key: const ValueKey('acct-vat-rate'),
                  controller: rate,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                      labelText: t.lg2VatRateLabel,
                      suffixText: '%',
                      helperText: t.lg2VatRateHelp,
                      helperMaxLines: 3,
                      border: const OutlineInputBorder()),
                ),
              if (mode != 'standard') ...[
                const SizedBox(height: Gap.sm),
                TextField(
                  key: const ValueKey('acct-vat-note'),
                  controller: note,
                  maxLength: 120,
                  decoration: InputDecoration(
                      labelText: t.lg2VatNoteLabel,
                      helperText: t.lg2VatNoteHelp,
                      helperMaxLines: 3,
                      border: const OutlineInputBorder()),
                ),
              ],
              if (err != null)
                Semantics(
                  liveRegion: true,
                  child: Text(err!, style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
                ),
              const SizedBox(height: Gap.sm),
              Text(t.lg2VatFromToday,
                  style: TextStyle(color: Theme.of(ctx).colorScheme.onSurfaceVariant, height: 1.4)),
              const SizedBox(height: Gap.sm),
              SizedBox(
                height: 52,
                child: FilledButton(
                  key: const ValueKey('acct-vat-save'),
                  onPressed: () {
                    if (mode == 'reduced' && parsePctToBp(rate.text) == null) {
                      setSheet(() => err = t.lg2VatRateBad);
                      return;
                    }
                    Navigator.pop(ctx, true);
                  },
                  child: Text(t.save),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final r = await _api.acctSetVatRate(widget.businessId, {
        'product_id': p['product_id'],
        'mode': mode,
        if (mode == 'reduced') 'vat_bp': parsePctToBp(rate.text),
        if (mode != 'standard' && note.text.trim().isNotEmpty) 'note': note.text.trim(),
      });
      if (!mounted) return;
      if (_ok(r)) {
        _changed = true;
        _snack(context, t.lg2VatSaved);
      } else {
        _snack(context, pair(context, r['detail'], fallback: t.acuSaveFailed));
      }
    } catch (e) {
      if (mounted) _snack(context, honestFailText(t, e));
    }
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (did, _) {
        if (!did) Navigator.pop(context, _changed);
      },
      child: Scaffold(appBar: AppBar(title: Text(t.lg2VatRatesTitle)), body: _body(t)),
    );
  }

  Widget _body(AppLocalizations t) {
    final e = _error;
    if (e != null) return _errorState(context, t, e, t.lg2VatRatesTitle, _load);
    final d = _d;
    if (d == null) return const SkeletonList();
    final scheme = Theme.of(context).colorScheme;
    final products = (d['products'] as List? ?? const []).cast<Map>();
    final seller = d['vat_seller'] == true;
    return ListView(
      padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
      children: [
        Card(
          color: seller ? scheme.surfaceContainerHighest : scheme.tertiaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Text(
                seller ? t.lg2VatShopRate(acctPct(context, d['shop_vat_bp'])) : t.lg2VatNotSeller,
                style: TextStyle(
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                    color: seller ? null : scheme.onTertiaryContainer)),
          ),
        ),
        const SizedBox(height: Gap.sm),
        Text(t.lg2VatRatesWhy, style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
        const SizedBox(height: Gap.md),
        TextField(
          key: const ValueKey('acct-vat-search'),
          decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search_rounded),
              labelText: t.lg2VatSearch,
              border: const OutlineInputBorder()),
          textInputAction: TextInputAction.search,
          onSubmitted: (v) {
            _q = v.trim();
            _load();
          },
        ),
        const SizedBox(height: Gap.md),
        if (products.isEmpty)
          StateMessage(
            icon: Icons.inventory_2_rounded,
            title: t.lg2VatNoProducts,
            message: t.lg2VatNoProductsHow,
          )
        else
          for (final p in products)
            Card(
              margin: const EdgeInsets.only(bottom: Gap.sm),
              child: ListTile(
                key: ValueKey('acct-vatp-${p['product_id']}'),
                minVerticalPadding: Gap.sm,
                title: Text('${p['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text([
                  _modeText(t, p),
                  if ('${p['note'] ?? ''}'.isNotEmpty) '${p['note']}',
                ].join(' · ')),
                trailing: const Icon(Icons.edit_rounded),
                onTap: () => _edit(p),
              ),
            ),
      ],
    );
  }
}

// ===================================================================== year close
class AcctYearCloseSection extends StatefulWidget {
  final int? businessId;
  final VoidCallback? onChanged;
  const AcctYearCloseSection({super.key, this.businessId, this.onChanged});

  @override
  State<AcctYearCloseSection> createState() => _AcctYearCloseSectionState();
}

class _AcctYearCloseSectionState extends State<AcctYearCloseSection> {
  Map<String, dynamic>? _d;
  Object? _error;
  bool _busy = false;

  ApiClient get _api => context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await _api.acctYearCloses(widget.businessId);
      if (!mounted) return;
      setState(() {
        _d = d;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _close(String end, String kind) async {
    final t = AppLocalizations.of(context);
    final day = acctDay(context, end);
    var understood = false;
    final ok = await showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(t.lg2YearCloseTitle(day), style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: Gap.sm),
              Text(t.lg2YearCloseExplain, style: const TextStyle(height: 1.5)),
              CheckboxListTile(
                key: const ValueKey('acct-year-understand'),
                contentPadding: EdgeInsets.zero,
                value: understood,
                title: Text(t.lg2YearCloseUnderstand),
                onChanged: (v) => setSheet(() => understood = v ?? false),
              ),
              SizedBox(
                height: 52,
                child: FilledButton(
                  key: const ValueKey('acct-year-confirm'),
                  onPressed: understood ? () => Navigator.pop(ctx, true) : null,
                  child: Text(t.lg2YearCloseButton),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
    if (ok != true || !mounted) return;
    if (kind.isEmpty) return;
    await _send(() => _api.acctCloseYear(widget.businessId, end),
        (r) => t.lg2YearClosedDone(day, acctMoney(context, r['profit'])));
  }

  Future<void> _reopen(String end) async {
    final t = AppLocalizations.of(context);
    final day = acctDay(context, end);
    final reason = TextEditingController();
    final ok = await showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + MediaQuery.viewInsetsOf(ctx).bottom),
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(t.lg2YearReopenTitle(day), style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: Gap.sm),
              Text(t.lg2YearReopenExplain, style: const TextStyle(height: 1.5)),
              const SizedBox(height: Gap.md),
              TextField(
                key: const ValueKey('acct-year-reason'),
                controller: reason,
                maxLength: 200,
                decoration: InputDecoration(
                    labelText: t.acuReopenReason, border: const OutlineInputBorder()),
                onChanged: (_) => setSheet(() {}),
              ),
              SizedBox(
                height: 52,
                child: FilledButton.tonal(
                  key: const ValueKey('acct-year-reopen-confirm'),
                  onPressed: reason.text.trim().length >= 5 ? () => Navigator.pop(ctx, true) : null,
                  child: Text(t.acuReopenButton),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
    final why = reason.text.trim();
    if (ok != true || !mounted) return;
    await _send(() => _api.acctReopenYear(widget.businessId, end, why),
        (_) => t.lg2YearReopenedDone(day));
  }

  Future<void> _send(Future<Map<String, dynamic>> Function() call,
      String Function(Map<String, dynamic>) done) async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final r = await call();
      messenger.showSnackBar(SnackBar(
          content: Text(_ok(r) ? done(r) : pair(context, r['detail'], fallback: t.acuSaveFailed))));
      if (_ok(r)) widget.onChanged?.call();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(honestFailText(t, e))));
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final d = _d;
    if (_error != null) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.cloud_off_rounded),
          title: Text(t.lg2YearHeading),
          subtitle: Text(honestFailText(t, _error!)),
          trailing: TextButton(onPressed: _load, child: Text(t.retry)),
        ),
      );
    }
    if (d == null) return const SizedBox(height: 96, child: SkeletonList());
    final closes = (d['closes'] as List? ?? const []).cast<Map>();
    final sugg = (d['suggestions'] as List? ?? const []).cast<Map>();
    final live = closes.where((c) => c['status'] == 'posted').toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Semantics(
        header: true,
        child: Text(t.lg2YearHeading,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
      ),
      const SizedBox(height: Gap.xs),
      Text(t.lg2YearWhy, style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
      const SizedBox(height: Gap.sm),
      for (final c in live)
        Card(
          margin: const EdgeInsets.only(bottom: Gap.sm),
          color: scheme.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(t.lg2YearClosedOn(acctDay(context, c['end'])),
                  style: TextStyle(fontWeight: FontWeight.w700, color: scheme.onPrimaryContainer)),
              const SizedBox(height: Gap.sm),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: OutlinedButton.icon(
                  key: ValueKey('acct-year-reopen-${c['end']}'),
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 48),
                      foregroundColor: scheme.onPrimaryContainer,
                      side: BorderSide(color: scheme.onPrimaryContainer)),
                  onPressed: _busy || c != live.first ? null : () => _reopen('${c['end']}'),
                  icon: const Icon(Icons.lock_open_rounded),
                  label: Text(t.acuReopenButton),
                ),
              ),
            ]),
          ),
        ),
      for (final s in sugg)
        Card(
          margin: const EdgeInsets.only(bottom: Gap.sm),
          child: ListTile(
            key: ValueKey('acct-year-close-${s['end']}'),
            minVerticalPadding: Gap.sm,
            enabled: !_busy,
            leading: const Icon(Icons.event_available_rounded),
            title: Text(t.lg2YearCloseTitle(acctDay(context, s['end'])),
                style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(s['kind'] == 'tax' ? t.lg2YearTax : t.lg2YearCalendar),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _close('${s['end']}', '${s['kind']}'),
          ),
        ),
    ]);
  }
}

// ===================================================================== cost 0
/// The P&L banner: shown only when sales in the period were sold with cost
/// price 0 (their profit is overstated). One tap -> the affected products.
class AcctCostGapBanner extends StatelessWidget {
  final Map gaps;
  final int? businessId;
  final VoidCallback onFixed;
  const AcctCostGapBanner(
      {super.key, required this.gaps, required this.businessId, required this.onFixed});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final n = (gaps['sales'] as num?)?.toInt() ?? 0;
    if (n == 0) return const SizedBox.shrink();
    return Card(
      key: const ValueKey('acct-cost-banner'),
      color: scheme.errorContainer,
      margin: const EdgeInsets.only(top: Gap.sm, bottom: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Semantics(
                liveRegion: true,
                child: Text(
                    t.lg2CostBanner(acctDigits(context, n), acctMoney(context, gaps['revenue'])),
                    style: TextStyle(
                        color: scheme.onErrorContainer, fontWeight: FontWeight.w700, height: 1.4)),
              ),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              key: const ValueKey('acct-cost-open'),
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 48),
                  foregroundColor: scheme.onErrorContainer,
                  side: BorderSide(color: scheme.onErrorContainer)),
              onPressed: () async {
                var fixed = false;   // however the sheet is closed (drag too)
                await showAppSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  showDragHandle: true,
                  builder: (_) => AcctCostGapsSheet(
                      businessId: businessId, gaps: gaps, onFixed: () => fixed = true),
                );
                if (fixed) onFixed();
              },
              icon: const Icon(Icons.list_alt_rounded),
              label: Text(t.lg2CostOpen),
            ),
          ),
        ]),
      ),
    );
  }
}

class AcctCostGapsSheet extends StatefulWidget {
  final int? businessId;
  final Map gaps;
  final VoidCallback? onFixed;
  const AcctCostGapsSheet({super.key, this.businessId, required this.gaps, this.onFixed});

  @override
  State<AcctCostGapsSheet> createState() => _AcctCostGapsSheetState();
}

class _AcctCostGapsSheetState extends State<AcctCostGapsSheet> {
  late List<Map> _products =
      (widget.gaps['products'] as List? ?? const []).cast<Map>().toList();
  final Map<int, TextEditingController> _cost = {};
  int? _busy;

  @override
  void dispose() {
    for (final c in _cost.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _apply(Map p) async {
    final t = AppLocalizations.of(context);
    final id = (p['product_id'] as num?)?.toInt();
    if (id == null) return;
    final current = (p['current_cost'] as num?)?.toInt() ?? 0;
    int? cost;
    if (current <= 0) {
      cost = parseTakaToPoisha(_cost[id]?.text ?? '');
      if (cost == null) {
        _snack(context, t.acuErrCost);
        return;
      }
    }
    setState(() => _busy = id);
    try {
      final r = await context
          .read<AppState>()
          .api
          .acctApplyCost(widget.businessId, id, cost: cost);
      if (!mounted) return;
      if (_ok(r)) {
        widget.onFixed?.call();
        final fixed = (r['fixed'] as num?)?.toInt() ?? 0;
        final skipped = (r['skipped_locked'] as num?)?.toInt() ?? 0;
        _snack(
            context,
            skipped > 0
                ? t.lg2CostFixedSkipped(acctDigits(context, fixed), acctDigits(context, skipped))
                : t.lg2CostFixed(acctDigits(context, fixed)));
        setState(() => _products = _products.where((x) => x['product_id'] != id).toList());
      } else {
        _snack(context, pair(context, r['detail'], fallback: t.acuSaveFailed));
      }
    } catch (e) {
      if (mounted) _snack(context, honestFailText(t, e));
    }
    if (mounted) setState(() => _busy = null);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + MediaQuery.viewInsetsOf(context).bottom),
      child: ListView(
        shrinkWrap: true,
        children: [
          Text(t.lg2CostTitle, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Gap.sm),
          Text(t.lg2CostExplain, style: const TextStyle(height: 1.5)),
          const SizedBox(height: Gap.md),
          if (_products.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.lg),
              child: Text(t.lg2CostAllFixed,
                  style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w700)),
            ),
          for (final p in _products) _productCard(t, scheme, p),
        ],
      ),
    );
  }

  Widget _productCard(AppLocalizations t, ColorScheme scheme, Map p) {
    final id = (p['product_id'] as num?)?.toInt();
    final current = (p['current_cost'] as num?)?.toInt() ?? 0;
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${p['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
          Text(t.lg2CostSold(acctDigits(context, p['lines']), acctMoney(context, p['revenue'])),
              style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.sm),
          if (id == null)
            Text(t.lg2CostNoProduct, style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4))
          else ...[
            if (current <= 0)
              TextField(
                key: ValueKey('acct-cost-field-$id'),
                controller: _cost.putIfAbsent(id, TextEditingController.new),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                    prefixText: '৳ ',
                    labelText: t.lg2CostType,
                    border: const OutlineInputBorder()),
              ),
            const SizedBox(height: Gap.sm),
            SizedBox(
              height: 48,
              child: FilledButton.tonal(
                key: ValueKey('acct-cost-apply-$id'),
                onPressed: _busy != null ? null : () => _apply(p),
                child: Text(current > 0
                    ? t.lg2CostApplyKnown(acctMoney(context, current))
                    : t.lg2CostApplyTyped),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}
