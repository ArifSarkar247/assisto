import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../services/error_kind.dart' show honestFailText; // qa2

/// ELECTRICITY & GAS PREPAID-METER TRACKER — ADVANCED (#193, SPEC v2.1 §20).
///
/// A prepaid-meter balance tracker: add meters (electricity / gas), log each
/// recharge (token amount, ৳), track the estimated daily consumption implied by
/// the recharge history, project when the balance will run low, and show a
/// low-balance warning. All estimates are DETERMINISTIC from entered data —
/// there is NO live utility API (that seam is documented in
/// backend/core/logic/prepaid_meter.py::live_balance_seam).
///
/// All MONEY is INTEGER POISHA. The on-screen math mirrors
/// backend/core/logic/prepaid_meter.py VERBATIM (closed-interval burn rate +
/// integer projection) so the same history always yields the same day count,
/// online or offline. The app buys NO token and HOLDS NO money.
///
/// Honest states: welcome (first use) · loading · error · 'unknown' projection
/// when history is too thin to estimate. ZERO Bangla literals — every string is
/// an AppLocalizations getter; the ৳ sign is a currency glyph.
///
/// Persistence (generic api helpers, no api.dart edit):
///   listItems('meter/meters')    → [{id, name, kind, balance, balance_date}]
///   listItems('meter/recharges') → [{id, meter, amount, date}]
///   create/update/deleteItem on the same paths; rows round-trip as
///   {id, ...data} through flexible per-user JSON collections.
class PrepaidMeterScreen extends StatefulWidget {
  const PrepaidMeterScreen({super.key});
  @override
  State<PrepaidMeterScreen> createState() => _PrepaidMeterScreenState();
}

const String _metersPath = 'meter/meters';
const String _rechargesPath = 'meter/recharges';

const List<String> _kinds = ['electricity', 'gas'];
const int _defaultLowDays = 5;

class _PrepaidMeterScreenState extends State<PrepaidMeterScreen> {
  List<Map<String, dynamic>> _meters = [];
  List<Map<String, dynamic>> _recharges = [];
  bool _loading = true, _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

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
    final api = context.read<AppState>().api;
    try {
      final res = await Future.wait(
          [api.listItems(_metersPath), api.listItems(_rechargesPath)]);
      _meters = res[0];
      _recharges = res[1];
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  List<Map<String, dynamic>> _rechargesFor(dynamic meterId) =>
      _recharges.where((r) => r['meter'] == meterId).toList();

  void _toast(String m) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
          appBar: AppBar(title: Text(tr.meterTitle)),
          body: const SkeletonList());
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.meterTitle)),
        body: StateMessage(
          icon: Icons.cloud_off_rounded,
          tint: scheme.error,
          title: tr.loadFailed,
          message: honestFailText(tr, _failCause, otherwise: tr.meterLoadError),
          action: FilledButton.tonalIcon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(tr.retry)),
        ),
      );
    }
    if (_meters.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.meterTitle)),
        body: StateMessage(
          icon: Icons.bolt_rounded,
          tint: Brand.blue,
          title: tr.meterWelcomeTitle,
          message: tr.meterWelcomeBody,
          action: FilledButton.icon(
            onPressed: _addMeter,
            icon: const Icon(Icons.add_rounded),
            label: Text(tr.meterAddMeter),
          ),
        ),
      );
    }
    final overview = _Meter.overview(_meters, (id) => _rechargesFor(id));
    return Scaffold(
      appBar: AppBar(title: Text(tr.meterTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addMeter,
        icon: const Icon(Icons.add_rounded),
        label: Text(tr.meterAddMeter),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
          children: [
            for (final row in overview)
              _MeterCard(
                row: row,
                onRecharge: () => _addRecharge(row),
                onEdit: () => _editMeter(row.raw),
                onDelete: () => _deleteMeter(row.raw),
                onViewRecharges: () => _viewRecharges(row),
              ),
            const SizedBox(height: Gap.md),
            _TrackerNote(),
          ],
        ),
      ),
    );
  }

  Future<void> _addMeter() async => _meterForm();
  Future<void> _editMeter(Map<String, dynamic> m) async => _meterForm(m);

  Future<void> _meterForm([Map<String, dynamic>? existing]) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _MeterForm(existing: existing),
    );
    if (result == null) return;
    try {
      if (existing != null && existing['id'] is int) {
        await api.updateItem(_metersPath, existing['id'] as int, result);
      } else {
        await api.createItem(_metersPath, result);
      }
      await _load();
      if (mounted) _toast(tr.meterSaved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _deleteMeter(Map<String, dynamic> m) async {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final api = context.read<AppState>().api;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.meterDeleteTitle),
        content: Text(tr.meterDeleteBody((m['name'] ?? '').toString())),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr.cancel)),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: scheme.error, foregroundColor: scheme.onError),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr.delete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final id = m['id'];
    if (id is int) {
      // Remove the meter's recharges too, to keep the collection honest.
      for (final r in _rechargesFor(id)) {
        if (r['id'] is int) await api.deleteItem(_rechargesPath, r['id'] as int);
      }
      await api.deleteItem(_metersPath, id);
    }
    await _load();
  }

  Future<void> _addRecharge(_MeterView row) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _RechargeForm(meterName: row.name),
    );
    if (result == null) return;
    try {
      await api.createItem(_rechargesPath, {...result, 'meter': row.id});
      await _load();
      if (mounted) _toast(tr.meterSaved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _viewRecharges(_MeterView row) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _RechargeHistorySheet(
        row: row,
        recharges: _rechargesFor(row.id),
        onDelete: (r) async {
          final api = context.read<AppState>().api;
          if (r['id'] is int) {
            await api.deleteItem(_rechargesPath, r['id'] as int);
          }
          if (ctx.mounted) Navigator.pop(ctx);
          await _load();
        },
      ),
    );
  }
}

// ======================= METER CARD =======================
class _MeterCard extends StatelessWidget {
  final _MeterView row;
  final VoidCallback onRecharge;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onViewRecharges;
  const _MeterCard({
    required this.row,
    required this.onRecharge,
    required this.onEdit,
    required this.onDelete,
    required this.onViewRecharges,
  });

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (Color stateColor, IconData stateIcon, String stateLabel) =
        switch (row.state) {
      'empty' => (scheme.error, Icons.error_outline_rounded, tr.meterStateEmpty),
      'low' => (Brand.warning, Icons.warning_amber_rounded, tr.meterStateLow),
      'ok' => (Brand.success, Icons.check_circle_outline_rounded, tr.meterStateOk),
      _ => (
          scheme.onSurfaceVariant,
          Icons.help_outline_rounded,
          tr.meterStateUnknown
        ),
    };
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.md),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.xs, Gap.sm),
          child: Row(children: [
            CircleAvatar(
              backgroundColor: Brand.blue.withValues(alpha: 0.12),
              child: Icon(
                  row.kind == 'gas'
                      ? Icons.local_fire_department_rounded
                      : Icons.bolt_rounded,
                  color: Brand.blue),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child:
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(row.name.isEmpty ? '—' : row.name,
                    style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                Text(row.kind == 'gas' ? tr.meterKindGas : tr.meterKindElec,
                    style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
              ]),
            ),
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'edit') onEdit();
                if (v == 'delete') onDelete();
                if (v == 'history') onViewRecharges();
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'history', child: Text(tr.meterHistory)),
                PopupMenuItem(value: 'edit', child: Text(tr.edit)),
                PopupMenuItem(value: 'delete', child: Text(tr.delete)),
              ],
            ),
          ]),
        ),
        // Balance + projection band
        Container(
          width: double.infinity,
          color: stateColor.withValues(alpha: 0.08),
          padding: const EdgeInsets.all(Gap.md),
          child: Row(children: [
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tr.meterEstBalance,
                        style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
                    const SizedBox(height: Gap.xxs),
                    Text(row.balanceDisplay,
                        style: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.copyWith(fontWeight: FontWeight.bold)),
                  ]),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(stateIcon, size: 16, color: stateColor),
                const SizedBox(width: Gap.xs),
                Text(stateLabel,
                    style: TextStyle(
                        color: stateColor, fontWeight: FontWeight.w600)),
              ]),
              const SizedBox(height: Gap.xxs),
              Text(
                row.daysLeft == null
                    ? tr.meterDaysUnknown
                    : (row.state == 'empty'
                        ? tr.meterRanOut
                        : tr.meterDaysLeft(row.daysLeft!)),
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant),
              ),
            ]),
          ]),
        ),
        // Detail chips
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.xs),
          child: Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            _chip(
                context,
                Icons.speed_rounded,
                row.state == 'unknown'
                    ? tr.meterRateUnknown
                    : tr.meterRatePerDay(row.rateDisplay)),
            if (row.runoutDate != null)
              _chip(context, Icons.event_busy_rounded,
                  tr.meterRunsOutOn(row.runoutDate!)),
            _chip(context, Icons.payments_rounded,
                tr.meterTotalRecharged(row.totalRechargedDisplay)),
          ]),
        ),
        const Divider(height: 1),
        Row(children: [
          Expanded(
            child: TextButton.icon(
              onPressed: onViewRecharges,
              icon: const Icon(Icons.history_rounded, size: 18),
              label: Text(tr.meterHistory),
            ),
          ),
          Container(
              width: 1, height: 24, color: scheme.outlineVariant),
          Expanded(
            child: TextButton.icon(
              onPressed: onRecharge,
              icon: const Icon(Icons.add_card_rounded, size: 18),
              label: Text(tr.meterLogRecharge),
            ),
          ),
        ]),
      ]),
    );
  }

  Widget _chip(BuildContext context, IconData icon, String label) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xs),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13, color: scheme.onSurfaceVariant),
        const SizedBox(width: Gap.xs),
        Text(label,
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
      ]),
    );
  }
}

class _TrackerNote extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(children: [
          Icon(Icons.info_outline_rounded, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(tr.meterTrackerNote,
                style:
                    AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          ),
        ]),
      ),
    );
  }
}

// ======================= METER FORM =======================
class _MeterForm extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _MeterForm({this.existing});
  @override
  State<_MeterForm> createState() => _MeterFormState();
}

class _MeterFormState extends State<_MeterForm> {
  late final TextEditingController _name =
      TextEditingController(text: widget.existing?['name']?.toString() ?? '');
  late final TextEditingController _balance = TextEditingController(
      text: widget.existing?['balance']?.toString() ?? '');
  late String _kind = _normKind(widget.existing?['kind']);
  DateTime? _balanceDate;

  static String _normKind(dynamic v) {
    final s = (v ?? 'electricity').toString();
    return _kinds.contains(s) ? s : 'electricity';
  }

  @override
  void initState() {
    super.initState();
    final bd = widget.existing?['balance_date'];
    if (bd != null) _balanceDate = DateTime.tryParse(bd.toString());
  }

  @override
  void dispose() {
    _name.dispose();
    _balance.dispose();
    super.dispose();
  }

  bool get _valid => _name.text.trim().isNotEmpty;

  Map<String, dynamic> _result() {
    final base = <String, dynamic>{
      'name': _name.text.trim(),
      'kind': _kind,
    };
    if (_balance.text.trim().isNotEmpty) {
      base['balance'] = _balance.text.trim();
      base['balance_date'] =
          (_balanceDate ?? DateTime.now()).toIso8601String().split('T').first;
    }
    return base;
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final insets = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                widget.existing == null
                    ? tr.meterAddMeter
                    : tr.meterEditMeter,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Gap.lg),
            TextField(
              controller: _name,
              autofocus: widget.existing == null,
              textCapitalization: TextCapitalization.words,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                  labelText: tr.meterName,
                  hintText: tr.meterNameHint,
                  border: const OutlineInputBorder()),
            ),
            const SizedBox(height: Gap.md),
            Text(tr.meterKindLabel,
                style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: Gap.xs),
            Wrap(spacing: Gap.sm, children: [
              for (final k in _kinds)
                ChoiceChip(
                  avatar: Icon(
                      k == 'gas'
                          ? Icons.local_fire_department_rounded
                          : Icons.bolt_rounded,
                      size: 18),
                  label: Text(k == 'gas' ? tr.meterKindGas : tr.meterKindElec),
                  selected: _kind == k,
                  onSelected: (_) => setState(() => _kind = k),
                ),
            ]),
            const SizedBox(height: Gap.md),
            TextField(
              controller: _balance,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                  labelText: tr.meterCurrentReading,
                  hintText: tr.meterCurrentReadingHint,
                  prefixText: '৳ ',
                  border: const OutlineInputBorder()),
            ),
            const SizedBox(height: Gap.xs),
            Text(tr.meterReadingOptional,
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.lg),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(tr.cancel)),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: FilledButton(
                  onPressed:
                      _valid ? () => Navigator.pop(context, _result()) : null,
                  child: Text(tr.save),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

// ======================= RECHARGE FORM =======================
class _RechargeForm extends StatefulWidget {
  final String meterName;
  const _RechargeForm({required this.meterName});
  @override
  State<_RechargeForm> createState() => _RechargeFormState();
}

class _RechargeFormState extends State<_RechargeForm> {
  final TextEditingController _amount = TextEditingController();
  DateTime _date = DateTime.now();

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  bool get _valid => _Meter.toPoisha(_amount.text) > 0;

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final insets = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr.meterLogRecharge,
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Gap.xs),
          Text(widget.meterName,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: Gap.lg),
          TextField(
            controller: _amount,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
                labelText: tr.meterRechargeAmount,
                prefixText: '৳ ',
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          InkWell(
            borderRadius: BorderRadius.circular(Radii.sm),
            onTap: () async {
              final now = DateTime.now();
              final picked = await showDatePicker(
                context: context,
                initialDate: _date,
                firstDate: DateTime(now.year - 3),
                lastDate: now,
              );
              if (picked != null) setState(() => _date = picked);
            },
            child: InputDecorator(
              decoration: InputDecoration(
                  labelText: tr.meterRechargeDate,
                  prefixIcon: const Icon(Icons.event_rounded),
                  border: const OutlineInputBorder()),
              child: Text(_date.toIso8601String().split('T').first),
            ),
          ),
          const SizedBox(height: Gap.lg),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(tr.cancel)),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: FilledButton(
                onPressed: _valid
                    ? () => Navigator.pop(context, {
                          'amount': _amount.text.trim(),
                          'date': _date.toIso8601String().split('T').first,
                        })
                    : null,
                child: Text(tr.save),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}

// ======================= RECHARGE HISTORY =======================
class _RechargeHistorySheet extends StatelessWidget {
  final _MeterView row;
  final List<Map<String, dynamic>> recharges;
  final Future<void> Function(Map<String, dynamic>) onDelete;
  const _RechargeHistorySheet(
      {required this.row, required this.recharges, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final sorted = [...recharges]
      ..sort((a, b) =>
          (b['date'] ?? '').toString().compareTo((a['date'] ?? '').toString()));
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr.meterHistoryTitle(row.name),
              style: Theme.of(context).textTheme.titleLarge,
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: Gap.md),
          if (sorted.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.lg),
              child: Text(tr.meterNoRecharges,
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            )
          else
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: sorted.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final r = sorted[i];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.add_card_rounded),
                    title: Text(_Meter.fmtPoisha(_Meter.toPoisha(r['amount'])),
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text((r['date'] ?? '').toString()),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline_rounded, size: 20),
                      tooltip: tr.delete,
                      onPressed: () => onDelete(r),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

// ===================================================================
// _Meter — deterministic mirror of backend/core/logic/prepaid_meter.py.
// Integer poisha; closed-interval burn rate; integer projection. No I/O.
// ===================================================================
class _MeterView {
  final Map<String, dynamic> raw;
  final dynamic id;
  final String name;
  final String kind;
  final int balance;
  final String balanceDisplay;
  final int rate;
  final String rateDisplay;
  final int? daysLeft;
  final String? runoutDate;
  final String state; // ok | low | empty | unknown
  final int totalRecharged;
  final String totalRechargedDisplay;
  _MeterView({
    required this.raw,
    required this.id,
    required this.name,
    required this.kind,
    required this.balance,
    required this.balanceDisplay,
    required this.rate,
    required this.rateDisplay,
    required this.daysLeft,
    required this.runoutDate,
    required this.state,
    required this.totalRecharged,
    required this.totalRechargedDisplay,
  });
}

class _Meter {
  static int toPoisha(dynamic v) {
    if (v == null || v == '') return 0;
    if (v is bool) return 0;
    if (v is int) return v;
    if (v is double) v = v.toString();
    var s = v.toString().trim().replaceAll(',', '');
    final neg = s.startsWith('-');
    if (neg) s = s.substring(1);
    String whole, frac;
    if (s.contains('.')) {
      final parts = s.split('.');
      whole = parts[0];
      frac = parts.sublist(1).join();
    } else {
      whole = s;
      frac = '';
    }
    if (whole.isEmpty) whole = '0';
    frac = (frac + '00').substring(0, 3);
    final taka = int.tryParse(whole);
    final milli = int.tryParse(frac);
    if (taka == null || milli == null) return 0;
    var poisha = taka * 100 + milli ~/ 10;
    if (milli % 10 >= 5) poisha += 1;
    return neg ? -poisha : poisha;
  }

  static String _group(int n) {
    final s = n.toString();
    if (s.length <= 3) return s;
    var head = s.substring(0, s.length - 3);
    final tail = s.substring(s.length - 3);
    final parts = <String>[];
    while (head.length > 2) {
      parts.insert(0, head.substring(head.length - 2));
      head = head.substring(0, head.length - 2);
    }
    if (head.isNotEmpty) parts.insert(0, head);
    return '${parts.join(',')},$tail';
  }

  static String fmtPoisha(int p) {
    final neg = p < 0;
    p = p.abs();
    return '${neg ? '-' : ''}৳${_group(p ~/ 100)}.${(p % 100).toString().padLeft(2, '0')}';
  }

  static DateTime? _parse(dynamic v) {
    if (v == null || v == '') return null;
    final s = v.toString().split('T').first.split(' ').first;
    final d = DateTime.tryParse(s);
    return d == null ? null : DateTime(d.year, d.month, d.day);
  }

  static List<({DateTime date, int amount})> _rows(
      List<Map<String, dynamic>> recharges) {
    final rows = <({DateTime date, int amount})>[];
    for (final r in recharges) {
      final d = _parse(r['date']);
      final a = toPoisha(r['amount']);
      if (d == null || a <= 0) continue;
      rows.add((date: d, amount: a));
    }
    rows.sort((x, y) => x.date.compareTo(y.date));
    return rows;
  }

  /// (rate poisha/day, confident).
  static (int, bool) _dailyRate(List<Map<String, dynamic>> recharges) {
    final rows = _rows(recharges);
    if (rows.length < 2) return (0, false);
    final span = rows.last.date.difference(rows.first.date).inDays;
    if (span <= 0) return (0, false);
    var consumed = 0;
    for (var i = 0; i < rows.length - 1; i++) {
      consumed += rows[i].amount;
    }
    final rate = consumed ~/ span;
    return (rate, rate > 0);
  }

  static _MeterView project(
      Map<String, dynamic> meter, List<Map<String, dynamic>> recharges,
      {DateTime? asOf, int lowDays = _defaultLowDays}) {
    asOf ??= DateTime.now();
    final asOfD = DateTime(asOf.year, asOf.month, asOf.day);
    final (rate, confident) = _dailyRate(recharges);
    final rows = _rows(recharges);

    // balance: explicit reading (decayed) else last recharge (decayed)
    int balance = 0;
    final reading = toPoisha(meter['balance']);
    final readingDate = _parse(meter['balance_date']);
    if (reading > 0 && readingDate != null) {
      final days = asOfD.difference(readingDate).inDays;
      balance = reading - rate * (days < 0 ? 0 : days);
    } else if (rows.isNotEmpty) {
      final last = rows.last;
      final days = asOfD.difference(last.date).inDays;
      balance = last.amount - rate * (days < 0 ? 0 : days);
    }
    if (balance < 0) balance = 0;

    int? daysLeft;
    String? runout;
    String state;
    if (balance <= 0) {
      state = 'empty';
      daysLeft = 0;
      runout = asOfD.toIso8601String().split('T').first;
    } else if (!confident || rate <= 0) {
      state = 'unknown';
    } else {
      daysLeft = balance ~/ rate;
      runout = asOfD
          .add(Duration(days: daysLeft))
          .toIso8601String()
          .split('T')
          .first;
      state = daysLeft < lowDays ? 'low' : 'ok';
    }

    var kind = (meter['kind'] ?? 'electricity').toString();
    if (!_kinds.contains(kind)) kind = 'electricity';
    final total = rows.fold<int>(0, (a, r) => a + r.amount);

    return _MeterView(
      raw: meter,
      id: meter['id'],
      name: (meter['name'] ?? '').toString().trim(),
      kind: kind,
      balance: balance,
      balanceDisplay: fmtPoisha(balance),
      rate: rate,
      rateDisplay: fmtPoisha(rate),
      daysLeft: daysLeft,
      runoutDate: runout,
      state: state,
      totalRecharged: total,
      totalRechargedDisplay: fmtPoisha(total),
    );
  }

  static List<_MeterView> overview(List<Map<String, dynamic>> meters,
      List<Map<String, dynamic>> Function(dynamic) rechargesFor) {
    final rows = [for (final m in meters) project(m, rechargesFor(m['id']))];
    const order = {'empty': 0, 'low': 1, 'ok': 2, 'unknown': 3};
    rows.sort((a, b) {
      final oa = order[a.state] ?? 4;
      final ob = order[b.state] ?? 4;
      if (oa != ob) return oa.compareTo(ob);
      final da = a.daysLeft ?? 1000000000;
      final db = b.daysLeft ?? 1000000000;
      if (da != db) return da.compareTo(db);
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return rows;
  }
}
