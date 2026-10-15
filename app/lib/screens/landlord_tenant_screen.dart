import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../widgets/skeleton.dart';
import '../widgets/samity_rent_common.dart';

/// LANDLORD-TENANT rent tracker (Bariwala-Bharatiya, feature #185, SPEC v2.1
/// section 20, built to the section 21 ADVANCED standard).
///
/// Tracks UNITS (flats/rooms/shops) + their tenants, the monthly rent + utility
/// shares, each month's paid/due status per tenant with a receipt note, and an
/// honest ARREARS summary across months. The bill + arrears math is a PURE
/// function computed client-side by samity_rent_common.dart (mirrors
/// backend/core/logic/landlord_tenant.py) so it works OFFLINE and matches server.
///
/// HONESTY (structural): we NEVER hold money (kHoldsMoney=false) and NEVER
/// charge (kChargesMoney=false). The landlord collects rent their own way; the
/// app only RECORDS what was paid and keeps a receipt note. Each month
/// reconciles: bill == paid + outstanding (overpayment shown as credit, never
/// silently applied).
///
/// PERSISTENCE: generic owned collections via the existing api helpers —
///   rent_units     : {label, rent_poisha, tenant_name, active, utilities:[...]}
///   rent_payments  : {unit_id, month "YYYY-MM", paid_poisha, note, method, paid_at}
/// See .phaseB/up_samityrent_integration.md for row shapes, the viewsets the
/// integrator registers, and the documented due-rent REMINDER seam.
class LandlordTenantScreen extends StatefulWidget {
  const LandlordTenantScreen({super.key});
  @override
  State<LandlordTenantScreen> createState() => _LandlordTenantScreenState();
}

class _LandlordTenantScreenState extends State<LandlordTenantScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this)
    ..addListener(() => setState(() {}));

  List<Map<String, dynamic>> _units = [];
  List<Map<String, dynamic>> _payments = [];
  bool _loading = true;
  bool _error = false;
  bool _offline = false;
  late String _month = isoMonth(DateTime.now());

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    final api = context.read<AppState>().api;
    try {
      final all = await Future.wait([
        api.listItems(kColRentUnit),
        api.listItems(kColRentPayment),
      ]);
      _units = all[0];
      _payments = all[1];
      _offline = false;
    } catch (_) {
      if (_units.isEmpty) {
        _error = true;
      } else {
        _offline = true;
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _addOrEditUnit([Map<String, dynamic>? u]) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (_) => _UnitEditSheet(unit: u),
    );
    if (result == null || !mounted) return;
    final api = context.read<AppState>().api;
    if (u != null && u['id'] != null) {
      await api.updateItem(kColRentUnit, u['id'] as int, result);
    } else {
      await api.createItem(kColRentUnit, result);
    }
    await _load();
  }

  Future<void> _deleteUnit(Map<String, dynamic> u) async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.rentDeleteUnitTitle),
        content: Text(t.rentDeleteUnitBody('${u['label'] ?? ''}')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: Text(t.delete)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await context.read<AppState>().api.deleteItem(kColRentUnit, u['id'] as int);
    await _load();
  }

  Future<void> _recordPayment(Map<String, dynamic> unitMonth) async {
    final t = AppLocalizations.of(context);
    final outstanding = unitMonth['outstanding_poisha'] as int;
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (_) => _PaymentSheet(
        label: '${unitMonth['label'] ?? ''}',
        month: _month,
        suggestedPoisha: outstanding,
      ),
    );
    if (result == null || !mounted) return;
    await context.read<AppState>().api.createItem(kColRentPayment, {
      'unit_id': unitMonth['unit_id'],
      'month': _month,
      'paid_poisha': result['paid_poisha'],
      'note': result['note'],
      'method': result['method'],
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(t.rentPaymentRecorded)));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.rentTitle),
        bottom: TabBar(
          controller: _tabs,
          tabs: [Tab(text: t.rentTabThisMonth), Tab(text: t.rentTabArrears)],
        ),
      ),
      floatingActionButton:
          (_tabs.index == 0 && rentActiveUnits(_units).isNotEmpty)
              ? FloatingActionButton.extended(
                  onPressed: () => _addOrEditUnit(),
                  icon: const Icon(Icons.add_home_work_outlined),
                  label: Text(t.rentAddUnit),
                )
              : null,
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off,
                  tint: Theme.of(context).colorScheme.error,
                  title: t.rentLoadFailed,
                  message: t.commonLoadFailedBody,
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: Text(t.retry)),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child:
                      _tabs.index == 0 ? _monthBody(t) : _arrearsBody(t)),
    );
  }

  // ---------------------------------------------------------------- month tab

  Widget _monthBody(AppLocalizations t) {
    final active = rentActiveUnits(_units);
    if (active.isEmpty) {
      return ListView(children: [
        const SizedBox(height: Gap.xxl),
        StateMessage(
          icon: Icons.home_work_outlined,
          title: t.rentEmptyTitle,
          message: t.rentEmptyBody,
          action: FilledButton.icon(
            onPressed: () => _addOrEditUnit(),
            icon: const Icon(Icons.add),
            label: Text(t.rentAddUnit),
          ),
        ),
      ]);
    }
    final summary = rentMonthSummary(_units, _payments, _month);
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
      children: [
        if (_offline) ...[
          _OfflineBar(text: t.commonOffline),
          const SizedBox(height: Gap.sm),
        ],
        NoMoneyBanner(text: t.rentNoMoneyBanner),
        const SizedBox(height: Gap.md),
        _MonthPicker(
          month: _month,
          onPrev: () => setState(() => _month = shiftMonth(_month, -1)),
          onNext: () => setState(() => _month = shiftMonth(_month, 1)),
        ),
        const SizedBox(height: Gap.md),
        _MonthHero(summary: summary),
        const SizedBox(height: Gap.md),
        for (final r in (summary['units'] as List).cast<Map<String, dynamic>>())
          _UnitCard(
            data: r,
            onRecord: r['status'] == 'paid'
                ? null
                : () => _recordPayment(r),
            onEdit: () {
              final u = active.firstWhere((e) => e['id'] == r['unit_id'],
                  orElse: () => {});
              if (u.isNotEmpty) _addOrEditUnit(u);
            },
            onDelete: () {
              final u = active.firstWhere((e) => e['id'] == r['unit_id'],
                  orElse: () => {});
              if (u.isNotEmpty) _deleteUnit(u);
            },
          ),
      ],
    );
  }

  // --------------------------------------------------------------- arrears tab

  Widget _arrearsBody(AppLocalizations t) {
    final active = rentActiveUnits(_units);
    if (active.isEmpty) {
      return ListView(children: [
        const SizedBox(height: Gap.xxl),
        StateMessage(
          icon: Icons.receipt_long_outlined,
          title: t.rentArrearsEmptyTitle,
          message: t.rentArrearsEmptyBody,
        ),
      ]);
    }
    // Honest 6-month trailing window ending at the selected month.
    final start = shiftMonth(_month, -5);
    final months = <String>[];
    var cur = start;
    for (var i = 0; i < 6; i++) {
      months.add(cur);
      cur = shiftMonth(cur, 1);
    }
    // Per-unit outstanding across the window (mirrors engine's arrears()).
    var grand = 0;
    final rows = <Map<String, dynamic>>[];
    for (final u in active) {
      var out = 0;
      var inArrears = 0;
      for (final mo in months) {
        final um = rentUnitMonth(u, _payments, mo);
        final o = um['outstanding_poisha'] as int;
        out += o;
        if (o > 0) inArrears++;
      }
      grand += out;
      rows.add({
        'unit_id': u['id'],
        'label': u['label'],
        'tenant_name': u['tenant_name'],
        'outstanding_poisha': out,
        'months_in_arrears': inArrears,
      });
    }
    rows.sort((a, b) =>
        (b['outstanding_poisha'] as int) - (a['outstanding_poisha'] as int));

    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
      children: [
        if (_offline) ...[
          _OfflineBar(text: t.commonOffline),
          const SizedBox(height: Gap.sm),
        ],
        Container(
          padding: const EdgeInsets.all(Gap.lg),
          decoration: BoxDecoration(
            color: grand > 0
                ? Brand.danger.withValues(alpha: 0.12)
                : Brand.success.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(Radii.lg),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.rentArrearsWindow(monthLabel(context, start),
                monthLabel(context, _month)),
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12)),
            const SizedBox(height: 4),
            Text(t.rentTotalArrears,
                style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 2),
            Text(taka(context, grand),
                style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    color: grand > 0 ? Brand.danger : Brand.success)),
          ]),
        ),
        const SizedBox(height: Gap.md),
        if (grand == 0)
          StateMessage(
            icon: Icons.verified_outlined,
            tint: Brand.success,
            title: t.rentNoArrearsTitle,
            message: t.rentNoArrearsBody,
          )
        else
          for (final r in rows.where((e) => (e['outstanding_poisha'] as int) > 0))
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.sm),
              child: Container(
                padding: const EdgeInsets.all(Gap.md),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest
                      .withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(Radii.md),
                ),
                child: Row(children: [
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${r['label'] ?? ''}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700)),
                          if ('${r['tenant_name'] ?? ''}'.isNotEmpty)
                            Text('${r['tenant_name']}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant)),
                          Text(
                              t.rentMonthsInArrears(fmtInt(
                                  context, r['months_in_arrears'] as int)),
                              style: const TextStyle(
                                  fontSize: 12, color: Brand.danger)),
                        ]),
                  ),
                  Text(taka(context, r['outstanding_poisha'] as int),
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, color: Brand.danger)),
                ]),
              ),
            ),
      ],
    );
  }
}

// ---------------------------------------------------------------- month hero

class _MonthHero extends StatelessWidget {
  final Map<String, dynamic> summary;
  const _MonthHero({required this.summary});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final billed = summary['billed_poisha'] as int;
    final collected = summary['collected_poisha'] as int;
    final outstanding = summary['outstanding_poisha'] as int;
    final pct = billed > 0 ? collected / billed : 0.0;
    return Container(
      padding: const EdgeInsets.all(Gap.lg),
      decoration: BoxDecoration(
        gradient: Brand.gradient,
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t.rentCollectedThisMonth,
            style: const TextStyle(color: Colors.white70, fontSize: 13)),
        const SizedBox(height: 4),
        Text(taka(context, collected),
            style: const TextStyle(
                color: Colors.white, fontSize: 30, fontWeight: FontWeight.w800)),
        const SizedBox(height: Gap.sm),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: pct.clamp(0.0, 1.0),
            minHeight: 8,
            backgroundColor: Colors.white24,
            valueColor: const AlwaysStoppedAnimation(Colors.white),
          ),
        ),
        const SizedBox(height: Gap.sm),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(t.rentBilledLabel(taka(context, billed)),
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
          Text(t.rentDueLabel(taka(context, outstanding)),
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 2),
        Text(
          t.rentStatusCounts(
              fmtInt(context, summary['paid_count'] as int),
              fmtInt(context, summary['partial_count'] as int),
              fmtInt(context, summary['due_count'] as int)),
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ]),
    );
  }
}

class _MonthPicker extends StatelessWidget {
  final String month;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  const _MonthPicker(
      {required this.month, required this.onPrev, required this.onNext});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(children: [
        IconButton(onPressed: onPrev, icon: const Icon(Icons.chevron_left)),
        Expanded(
          child: Text(monthLabel(context, month),
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
        IconButton(onPressed: onNext, icon: const Icon(Icons.chevron_right)),
      ]),
    );
  }
}

// ---------------------------------------------------------------- unit card

class _UnitCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final VoidCallback? onRecord;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  const _UnitCard(
      {required this.data,
      required this.onRecord,
      required this.onEdit,
      required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final status = data['status'] as String;
    final color = statusColor(status);
    final breakdown =
        (data['breakdown'] as List? ?? const []).cast<Map<String, dynamic>>();
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.md),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding:
                const EdgeInsets.symmetric(horizontal: Gap.md, vertical: 2),
            childrenPadding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.md),
            title: Row(children: [
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${data['label'] ?? ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              const TextStyle(fontWeight: FontWeight.w700)),
                      if ('${data['tenant_name'] ?? ''}'.isNotEmpty)
                        Text('${data['tenant_name']}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12,
                                color: scheme.onSurfaceVariant)),
                    ]),
              ),
              StatusPill(
                text: status == 'paid'
                    ? t.rentStatusPaid
                    : status == 'partial'
                        ? t.rentStatusPartial
                        : t.rentStatusDue,
                color: color,
                icon: status == 'paid'
                    ? Icons.check_circle
                    : status == 'partial'
                        ? Icons.timelapse
                        : Icons.error_outline,
              ),
            ]),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                t.rentBillPaid(taka(context, data['paid_poisha'] as int),
                    taka(context, data['bill_poisha'] as int)),
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
              ),
            ),
            children: [
              StatLine(t.rentBaseRent,
                  taka(context, data['rent_poisha'] as int)),
              for (final b in breakdown)
                StatLine('${b['name'] ?? ''}',
                    taka(context, b['amount_poisha'] as int)),
              const Divider(height: Gap.lg),
              StatLine(t.rentMonthlyBill,
                  taka(context, data['bill_poisha'] as int),
                  strong: true),
              if ((data['outstanding_poisha'] as int) > 0)
                StatLine(t.rentOutstanding,
                    taka(context, data['outstanding_poisha'] as int),
                    valueColor: Brand.danger, strong: true),
              if ((data['credit_poisha'] as int) > 0)
                StatLine(t.rentCredit,
                    taka(context, data['credit_poisha'] as int),
                    valueColor: Brand.success),
              const SizedBox(height: Gap.sm),
              Row(children: [
                if (onRecord != null)
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: onRecord,
                      icon: const Icon(Icons.payments_outlined, size: 18),
                      label: Text(t.rentRecordPayment),
                    ),
                  ),
                if (onRecord != null) const SizedBox(width: Gap.sm),
                IconButton(
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit_outlined),
                    tooltip: t.edit),
                IconButton(
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete_outline),
                    tooltip: t.delete),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- unit sheet

class _UnitEditSheet extends StatefulWidget {
  final Map<String, dynamic>? unit;
  const _UnitEditSheet({this.unit});
  @override
  State<_UnitEditSheet> createState() => _UnitEditSheetState();
}

class _UnitEditSheetState extends State<_UnitEditSheet> {
  late final TextEditingController _label =
      TextEditingController(text: '${widget.unit?['label'] ?? ''}');
  late final TextEditingController _tenant =
      TextEditingController(text: '${widget.unit?['tenant_name'] ?? ''}');
  late final TextEditingController _rent = TextEditingController(
      text: widget.unit?['rent_poisha'] != null
          ? ((widget.unit!['rent_poisha'] as int) / 100).toStringAsFixed(2)
          : '');
  late List<Map<String, dynamic>> _utils = [
    for (final u in (widget.unit?['utilities'] as List? ?? const []))
      Map<String, dynamic>.from(u as Map),
  ];

  void _addUtil() {
    setState(() => _utils.add({'name': '', 'amount_poisha': 0}));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final rentP = takaToPoisha(_rent.text);
    final valid = _label.text.trim().isNotEmpty && rentP > 0;
    return Padding(
      padding: EdgeInsets.only(
        left: Gap.lg,
        right: Gap.lg,
        top: Gap.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg,
      ),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(widget.unit == null ? t.rentNewUnit : t.rentEditUnit,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.lg),
          TextField(
            controller: _label,
            decoration: InputDecoration(labelText: t.rentFieldLabel),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _tenant,
            decoration: InputDecoration(labelText: t.rentFieldTenant),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _rent,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
                labelText: t.rentFieldRent, prefixText: '৳ '),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: Gap.lg),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(t.rentUtilities,
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(t.rentUtilitiesHint,
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
          const SizedBox(height: Gap.sm),
          for (var i = 0; i < _utils.length; i++) _utilRow(t, i),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _addUtil,
              icon: const Icon(Icons.add, size: 18),
              label: Text(t.rentAddUtility),
            ),
          ),
          const SizedBox(height: Gap.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: valid
                  ? () => Navigator.pop(context, {
                        'label': _label.text.trim(),
                        'tenant_name': _tenant.text.trim(),
                        'rent_poisha': rentP,
                        'active': true,
                        'utilities': _utils
                            .where((u) =>
                                '${u['name'] ?? ''}'.trim().isNotEmpty)
                            .toList(),
                      })
                  : null,
              child: Text(t.save),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _utilRow(AppLocalizations t, int i) {
    final u = _utils[i];
    final nameCtl = TextEditingController(text: '${u['name'] ?? ''}');
    final amtCtl = TextEditingController(
        text: u['amount_poisha'] != null && (u['amount_poisha'] as int) > 0
            ? ((u['amount_poisha'] as int) / 100).toStringAsFixed(2)
            : '');
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Row(children: [
        Expanded(
          flex: 3,
          child: TextField(
            controller: nameCtl,
            decoration: InputDecoration(
                isDense: true, labelText: t.rentUtilityName),
            onChanged: (v) => u['name'] = v.trim(),
          ),
        ),
        const SizedBox(width: Gap.sm),
        Expanded(
          flex: 2,
          child: TextField(
            controller: amtCtl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
                isDense: true, labelText: t.rentUtilityAmount, prefixText: '৳'),
            onChanged: (v) => u['amount_poisha'] = takaToPoisha(v),
          ),
        ),
        IconButton(
          onPressed: () => setState(() => _utils.removeAt(i)),
          icon: const Icon(Icons.close, size: 18),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------- payment sheet

class _PaymentSheet extends StatefulWidget {
  final String label;
  final String month;
  final int suggestedPoisha;
  const _PaymentSheet(
      {required this.label,
      required this.month,
      required this.suggestedPoisha});
  @override
  State<_PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends State<_PaymentSheet> {
  late final TextEditingController _amount = TextEditingController(
      text: widget.suggestedPoisha > 0
          ? (widget.suggestedPoisha / 100).toStringAsFixed(2)
          : '');
  final TextEditingController _note = TextEditingController();
  String _method = 'cash';

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final paid = takaToPoisha(_amount.text);
    final valid = paid > 0;
    return Padding(
      padding: EdgeInsets.only(
        left: Gap.lg,
        right: Gap.lg,
        top: Gap.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg,
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(t.rentRecordFor(widget.label, monthLabel(context, widget.month)),
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.lg),
        TextField(
          controller: _amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
              labelText: t.rentPaidAmount, prefixText: '৳ '),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: Gap.md),
        TextField(
          controller: _note,
          decoration: InputDecoration(
              labelText: t.rentReceiptNote, hintText: t.rentReceiptNoteHint),
        ),
        const SizedBox(height: Gap.md),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(t.rentMethod,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
        const SizedBox(height: Gap.sm),
        Wrap(spacing: Gap.sm, children: [
          for (final m in kRentMethods)
            ChoiceChip(
              label: Text(_methodLabel(t, m)),
              selected: _method == m,
              onSelected: (_) => setState(() => _method = m),
            ),
        ]),
        const SizedBox(height: Gap.lg),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: valid
                ? () => Navigator.pop(context, {
                      'paid_poisha': paid,
                      'note': _note.text.trim(),
                      'method': _method,
                    })
                : null,
            child: Text(t.rentSavePayment),
          ),
        ),
      ]),
    );
  }
}

String _methodLabel(AppLocalizations t, String m) {
  switch (m) {
    case 'cash':
      return t.rentMethodCash;
    case 'bkash':
      return t.rentMethodBkash;
    case 'nagad':
      return t.rentMethodNagad;
    case 'bank':
      return t.rentMethodBank;
    default:
      return t.rentMethodOther;
  }
}

class _OfflineBar extends StatelessWidget {
  final String text;
  const _OfflineBar({required this.text});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.sm),
      decoration: BoxDecoration(
        color: Brand.warning.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(children: [
        const Icon(Icons.wifi_off, size: 16, color: Brand.warning),
        const SizedBox(width: Gap.sm),
        Expanded(
            child: Text(text,
                style: TextStyle(color: scheme.onSurface, fontSize: 12))),
      ]),
    );
  }
}
