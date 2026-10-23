import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../business_khata_api.dart';
import '../../widgets/skeleton.dart';
import 'business_common.dart';
import '../../services/error_kind.dart' show honestFailText; // qa2

/// Cashbox (plan §2): one business day's drawer — opening cash, cash in/out
/// entries, and end-of-day reconciliation (expected vs counted + variance).
/// Allowed for staff (no cost/profit exposure). Defaults to today; the owner
/// can step to earlier days.
class CashboxScreen extends StatefulWidget {
  final Map<String, dynamic> business;
  const CashboxScreen({super.key, required this.business});
  @override
  State<CashboxScreen> createState() => _CashboxScreenState();
}

class _CashboxScreenState extends State<CashboxScreen> {
  int get _bizId => (widget.business['id'] as num?)?.toInt() ?? 0;
  DateTime _day = DateTime.now();
  Map<String, dynamic>? _summary;
  bool _loading = true;
  bool _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

  String get _dayKey =>
      '${_day.year}-${_day.month.toString().padLeft(2, '0')}-${_day.day.toString().padLeft(2, '0')}';

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
      _summary =
          await context.read<AppState>().api.cashboxDay(_bizId, _dayKey);
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _stepDay(int days) {
    final next = _day.add(Duration(days: days));
    if (next.isAfter(DateTime.now())) return;
    setState(() => _day = next);
    _load();
  }

  Future<void> _setOpening() async {
    final t = AppLocalizations.of(context);
    final poisha = await _amountDialog(context, t.cashboxOpening);
    if (poisha == null) return;
    try {
      _summary = await context
          .read<AppState>()
          .api
          .cashboxSetOpening(businessId: _bizId, day: _dayKey, openingPoisha: poisha);
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) _load();
    }
  }

  Future<void> _addEntry(String kind) async {
    final t = AppLocalizations.of(context);
    final res = await showModalBottomSheet<(int, String)>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CashEntrySheet(
          title: kind == 'in' ? t.cashboxCashIn : t.cashboxCashOut),
    );
    if (res == null) return;
    try {
      _summary = await context.read<AppState>().api.cashboxAddEntry(
            businessId: _bizId,
            day: _dayKey,
            kind: kind,
            amountPoisha: res.$1,
            note: res.$2,
          );
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) _load();
    }
  }

  Future<void> _reconcile() async {
    final t = AppLocalizations.of(context);
    final poisha = await _amountDialog(context, t.cashboxCounted);
    if (poisha == null) return;
    try {
      _summary = await context
          .read<AppState>()
          .api
          .cashboxReconcile(businessId: _bizId, day: _dayKey, countedPoisha: poisha);
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final s = _summary ?? const {};
    final reconciled = s['reconciled'] == true;

    return Scaffold(
      appBar: AppBar(
        title: Text(t.cashboxTitle),
      ),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off_outlined,
                  title: t.cashboxTitle,
                  message: honestFailText(t, _failCause, otherwise: t.businessLoadFailed),
                  action:
                      FilledButton(onPressed: _load, child: Text(t.retry)),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(Gap.lg),
                    children: [
                      // Day stepper.
                      Row(children: [
                        IconButton(
                            onPressed: () => _stepDay(-1),
                            icon: const Icon(Icons.chevron_left)),
                        Expanded(
                          child: Text(
                              DateFormat.yMMMEd(Localizations.localeOf(context).toLanguageTag())
                                  .format(_day),
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.titleMedium),
                        ),
                        IconButton(
                            onPressed: _isToday ? null : () => _stepDay(1),
                            icon: const Icon(Icons.chevron_right)),
                      ]),
                      const SizedBox(height: Gap.sm),

                      // Expected-cash hero.
                      BrandBand(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(t.cashboxExpected,
                                  style: const TextStyle(fontSize: 13)),
                              const SizedBox(height: 2),
                              Text(
                                  pair(context, s['expected_display'],
                                      fallback: '৳0'),
                                  style: const TextStyle(
                                      fontSize: 28,
                                      fontWeight: FontWeight.w700)),
                            ]),
                      ),
                      const SizedBox(height: Gap.lg),

                      // Breakdown.
                      Card(
                        child: Column(children: [
                          _Line(
                              label: t.cashboxOpening,
                              value: pair(context, s['opening_display'],
                                  fallback: '৳0'),
                              trailing: TextButton(
                                  onPressed: reconciled ? null : _setOpening,
                                  child: Text(t.edit))),
                          const Divider(height: 1),
                          _Line(
                              label: t.cashboxTotalIn,
                              value: pair(context, s['total_in_display'],
                                  fallback: '৳0'),
                              valueColor: Brand.success),
                          const Divider(height: 1),
                          _Line(
                              label: t.cashboxTotalOut,
                              value: pair(context, s['total_out_display'],
                                  fallback: '৳0'),
                              valueColor: Brand.danger),
                        ]),
                      ),
                      const SizedBox(height: Gap.md),

                      // Cash in / out actions.
                      if (!reconciled)
                        Row(children: [
                          Expanded(
                            child: FilledButton.icon(
                              style: Brand.successButton(),
                              icon: const Icon(Icons.add),
                              label: Text(t.cashboxCashIn),
                              onPressed: () => _addEntry('in'),
                            ),
                          ),
                          const SizedBox(width: Gap.md),
                          Expanded(
                            child: FilledButton.icon(
                              style: Brand.dangerButton(),
                              icon: const Icon(Icons.remove),
                              label: Text(t.cashboxCashOut),
                              onPressed: () => _addEntry('out'),
                            ),
                          ),
                        ]),
                      const SizedBox(height: Gap.lg),

                      // Reconciliation.
                      if (reconciled)
                        _ReconciledCard(summary: s)
                      else
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.fact_check_outlined),
                            label: Text(t.cashboxReconcile),
                            onPressed: _reconcile,
                          ),
                        ),
                      const SizedBox(height: Gap.lg),

                      // Entries list.
                      Text(t.stmtParticulars,
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: Gap.sm),
                      ...(() {
                        final entries = ((s['entries'] ?? []) as List)
                            .cast<Map<String, dynamic>>();
                        if (entries.isEmpty) {
                          return [
                            Padding(
                              padding: const EdgeInsets.all(Gap.xl),
                              child: Center(
                                child: Text(t.cashboxNoEntries,
                                    style: TextStyle(
                                        color: scheme.onSurfaceVariant)),
                              ),
                            )
                          ];
                        }
                        return [
                          for (final e in entries) _CashEntryTile(entry: e),
                        ];
                      })(),
                    ],
                  ),
                ),
    );
  }

  bool get _isToday {
    final now = DateTime.now();
    return _day.year == now.year &&
        _day.month == now.month &&
        _day.day == now.day;
  }
}

class _Line extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  final Widget? trailing;
  const _Line(
      {required this.label,
      required this.value,
      this.valueColor,
      this.trailing});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: Gap.lg, vertical: Gap.md),
      child: Row(children: [
        Expanded(child: Text(label)),
        Text(value,
            style: TextStyle(
                fontWeight: FontWeight.w700, color: valueColor)),
        if (trailing != null) trailing!,
      ]),
    );
  }
}

class _ReconciledCard extends StatelessWidget {
  final Map<String, dynamic> summary;
  const _ReconciledCard({required this.summary});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final variancePoisha = (summary['variance_poisha'] as num?)?.toInt() ?? 0;
    final color = variancePoisha == 0
        ? Brand.success
        : (variancePoisha > 0 ? Brand.warning : Brand.danger);
    final icon = variancePoisha == 0
        ? Icons.check_circle_outline
        : (variancePoisha > 0
            ? Icons.trending_up
            : Icons.trending_down);
    return Card(
      color: color.withValues(alpha: 0.10),
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, color: color),
            const SizedBox(width: Gap.sm),
            Text(pair(context, summary['variance_status'],
                fallback: t.cashboxBalanced),
                style: TextStyle(fontWeight: FontWeight.w700, color: color)),
          ]),
          const SizedBox(height: Gap.md),
          _MiniRow(
              label: t.cashboxCounted,
              value:
                  pair(context, summary['counted_display'], fallback: '৳0')),
          _MiniRow(
              label: t.cashboxExpected,
              value: pair(context, summary['expected_display'],
                  fallback: '৳0')),
          _MiniRow(
              label: t.cashboxVariance,
              value: pair(context, summary['variance_display'],
                  fallback: '৳0'),
              color: color),
        ]),
      ),
    );
  }
}

class _MiniRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;
  const _MiniRow({required this.label, required this.value, this.color});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Expanded(
            child: Text(label,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant))),
        Text(value,
            style: TextStyle(fontWeight: FontWeight.w700, color: color)),
      ]),
    );
  }
}

class _CashEntryTile extends StatelessWidget {
  final Map<String, dynamic> entry;
  const _CashEntryTile({required this.entry});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isIn = (entry['kind'] ?? '') == 'in';
    final note = (entry['note'] ?? '').toString();
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: ListTile(
        leading: Icon(isIn ? Icons.south_west : Icons.north_east,
            color: isIn ? Brand.success : Brand.danger),
        title: Text(note.isEmpty
            ? (isIn
                ? AppLocalizations.of(context).cashboxCashIn
                : AppLocalizations.of(context).cashboxCashOut)
            : note),
        subtitle: (entry['ref'] ?? '').toString().isEmpty
            ? null
            : Text(entry['ref'].toString()),
        trailing: Text(pair(context, entry['amount_display']),
            style: TextStyle(
                fontWeight: FontWeight.w700,
                color: isIn ? Brand.success : Brand.danger)),
      ),
    );
  }
}

// ========================= sheets / dialogs ==============================

class _CashEntrySheet extends StatefulWidget {
  final String title;
  const _CashEntrySheet({required this.title});
  @override
  State<_CashEntrySheet> createState() => _CashEntrySheetState();
}

class _CashEntrySheetState extends State<_CashEntrySheet> {
  final _amount = TextEditingController();
  final _note = TextEditingController();

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: Gap.lg,
        right: Gap.lg,
        top: Gap.sm,
        bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg,
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: Gap.lg),
        TextField(
          controller: _amount,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: t.entryAmount, prefixText: '৳ '),
        ),
        const SizedBox(height: Gap.md),
        TextField(
          controller: _note,
          decoration: InputDecoration(
              labelText: t.entryNote,
              prefixIcon: const Icon(Icons.notes_outlined)),
        ),
        const SizedBox(height: Gap.lg),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () {
              final poisha = takaToPoisha(_amount.text);
              if (poisha == null || poisha <= 0) return;
              Navigator.pop(context, (poisha, _note.text.trim()));
            },
            child: Text(t.save),
          ),
        ),
      ]),
    );
  }
}

Future<int?> _amountDialog(BuildContext context, String label) {
  final t = AppLocalizations.of(context);
  final ctrl = TextEditingController();
  return showDialog<int>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(label),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: t.entryAmount, prefixText: '৳ '),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: Text(t.cancel)),
        FilledButton(
          onPressed: () {
            final poisha = takaToPoisha(ctrl.text);
            if (poisha == null || poisha < 0) return;
            Navigator.pop(ctx, poisha);
          },
          child: Text(t.save),
        ),
      ],
    ),
  );
}
