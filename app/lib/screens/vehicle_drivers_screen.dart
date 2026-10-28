import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../vehicle/veh_format.dart';
import '../vehicle/vehicle_api.dart';
import '../widgets/skeleton.dart';

/// veh100: the owner's drivers (name, phone, licence number + expiry — the
/// licence expiry gets its own reminder push) and WHO drives this vehicle
/// now. Trips are split per driver on the server by these shifts, so each
/// driver has a monthly report and score. Drivers need no app or login.
class VehicleDriversScreen extends StatefulWidget {
  final int? trackerId;
  final bool canAssign;
  final int? currentDriverId;
  const VehicleDriversScreen(
      {super.key, this.trackerId, this.canAssign = false, this.currentDriverId});

  @override
  State<VehicleDriversScreen> createState() => _VehicleDriversScreenState();
}

const String _drivers = 'vehicle/drivers';

class _VehicleDriversScreenState extends State<VehicleDriversScreen> {
  List<Map<String, dynamic>> _list = const [];
  bool _loading = true, _error = false, _busy = false;
  int? _current;

  @override
  void initState() {
    super.initState();
    _current = widget.currentDriverId;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      _list = await context.read<AppState>().api.listItems(_drivers);
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _assign(int? id) async {
    final tr = AppLocalizations.of(context);
    final tid = widget.trackerId;
    if (tid == null) return;
    setState(() => _busy = true);
    try {
      await context.read<AppState>().api.vehAssignDriver(tid, id);
      setState(() => _current = id);
      _snack(id == null ? tr.v100DriverCleared : tr.v100DriverSet);
    } catch (e) {
      _snack(vehReasonText(tr, e));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _edit([Map<String, dynamic>? d]) async {
    final tr = AppLocalizations.of(context);
    final res = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _DriverForm(initial: d ?? const {}),
    );
    if (res == null || !mounted) return;
    final api = context.read<AppState>().api;
    try {
      if (d != null && d['id'] is int) {
        await api.updateItem(_drivers, d['id'] as int, res);
      } else {
        await api.createItem(_drivers, res);
      }
      await _load();
      _snack(tr.vehSaved);
    } catch (e) {
      _snack(vehReasonText(tr, e));
    }
  }

  Future<void> _delete(Map<String, dynamic> d) async {
    final tr = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.v100DriverDeleteTitle),
        content: Text(tr.v100DriverDeleteBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr.delete)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context.read<AppState>().api.deleteItem(_drivers, d['id'] as int);
      await _load();
    } catch (e) {
      _snack(vehReasonText(tr, e));
    }
  }

  Future<void> _report(Map<String, dynamic> d) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _DriverMonthSheet(driverId: d['id'] as int, name: '${d['name'] ?? ''}'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr.v100DriversTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.person_add_alt_1_rounded),
        label: Text(tr.v100DriverAdd),
      ),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off_rounded,
                  tint: scheme.error,
                  title: tr.loadFailed,
                  message: tr.vehLoadError,
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(tr.retry)),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
                      children: [
                    Text(tr.v100DriversIntro,
                        style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35)),
                    const SizedBox(height: Gap.md),
                    if (widget.canAssign && widget.trackerId != null)
                      Card(
                        margin: EdgeInsets.zero,
                        child: RadioGroup<int?>(
                          groupValue: _current,
                          onChanged: (v) {
                            if (!_busy) _assign(v);
                          },
                          child: Column(children: [
                            ListTile(
                              title: Text(tr.v100DriverWhoNow,
                                  style: Theme.of(context).textTheme.titleMedium),
                            ),
                            RadioListTile<int?>(value: null, title: Text(tr.v100DriverNobody)),
                            for (final d in _list)
                              RadioListTile<int?>(
                                value: d['id'] as int?,
                                title: Text('${d['name'] ?? ''}',
                                    maxLines: 1, overflow: TextOverflow.ellipsis),
                              ),
                          ]),
                        ),
                      ),
                    if (_list.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: Gap.lg),
                        child: StateMessage(
                          icon: Icons.badge_outlined,
                          tint: scheme.primary,
                          title: tr.v100DriversEmptyTitle,
                          message: tr.v100DriversEmptyBody,
                        ),
                      )
                    else ...[
                      const SizedBox(height: Gap.md),
                      for (final d in _list) _driverTile(tr, scheme, d),
                    ],
                  ]),
                ),
    );
  }

  Widget _driverTile(AppLocalizations tr, ColorScheme scheme, Map<String, dynamic> d) {
    final exp = DateTime.tryParse('${d['licence_expiry'] ?? ''}');
    final days = exp == null ? null : DateUtils.dateOnly(exp)
        .difference(DateUtils.dateOnly(DateTime.now())).inDays;
    final sub = <String>[
      if ('${d['phone'] ?? ''}'.trim().isNotEmpty) '${d['phone']}',
      if (days != null)
        days < 0
            ? tr.v100LicenceExpired
            : tr.v100LicenceIn(vehNumStr(context, days)),
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: ListTile(
        leading: Icon(Icons.badge_rounded,
            color: (days != null && days <= 30) ? scheme.error : scheme.primary),
        title: Text('${d['name'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: sub.isEmpty ? null : Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis),
        onTap: () => _report(d),
        trailing: PopupMenuButton<String>(
          tooltip: tr.v100More,
          onSelected: (v) => v == 'edit' ? _edit(d) : _delete(d),
          itemBuilder: (_) => [
            PopupMenuItem(value: 'edit', child: Text(tr.edit)),
            PopupMenuItem(value: 'delete', child: Text(tr.delete)),
          ],
        ),
      ),
    );
  }
}

class _DriverForm extends StatefulWidget {
  final Map<String, dynamic> initial;
  const _DriverForm({required this.initial});

  @override
  State<_DriverForm> createState() => _DriverFormState();
}

class _DriverFormState extends State<_DriverForm> {
  late final _name = TextEditingController(text: '${widget.initial['name'] ?? ''}');
  late final _phone = TextEditingController(text: '${widget.initial['phone'] ?? ''}');
  late final _lic = TextEditingController(text: '${widget.initial['licence_no'] ?? ''}');
  DateTime? _exp;
  String? _err;

  @override
  void initState() {
    super.initState();
    _exp = DateTime.tryParse('${widget.initial['licence_expiry'] ?? ''}');
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _lic.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final lc = Localizations.localeOf(context).languageCode;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr.v100DriverFormTitle, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Gap.sm),
          TextField(controller: _name, maxLength: 60,
              decoration: InputDecoration(labelText: tr.v100DriverName, errorText: _err)),
          TextField(controller: _phone, maxLength: 20, keyboardType: TextInputType.phone,
              decoration: InputDecoration(labelText: tr.v100DriverPhone)),
          TextField(controller: _lic, maxLength: 30,
              decoration: InputDecoration(labelText: tr.v100DriverLicenceNo)),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: const Icon(Icons.event_rounded),
            label: Text(_exp == null
                ? tr.v100DriverLicenceExpiry
                : tr.v100DriverLicenceExpiryOn(DateFormat.yMMMd(lc).format(_exp!))),
            onPressed: () async {
              final now = DateTime.now();
              final d = await showDatePicker(
                  context: context,
                  initialDate: _exp ?? now.add(const Duration(days: 365)),
                  firstDate: DateTime(now.year - 5),
                  lastDate: DateTime(now.year + 15));
              if (d != null) setState(() => _exp = d);
            },
          ),
          const SizedBox(height: Gap.xs),
          Text(tr.v100DriverLicenceHint,
              style: AType.bodySmall.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant, height: 1.35)),
          const SizedBox(height: Gap.md),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () {
              if (_name.text.trim().isEmpty) {
                setState(() => _err = tr.v100DriverNameNeeded);
                return;
              }
              Navigator.pop(context, {
                'name': _name.text.trim(),
                'phone': _phone.text.trim(),
                'licence_no': _lic.text.trim(),
                if (_exp != null) 'licence_expiry': DateFormat('yyyy-MM-dd').format(_exp!),
              });
            },
            child: Text(tr.save),
          ),
        ]),
      ),
    );
  }
}

/// One driver's current month across every vehicle they drove.
class _DriverMonthSheet extends StatefulWidget {
  final int driverId;
  final String name;
  const _DriverMonthSheet({required this.driverId, required this.name});

  @override
  State<_DriverMonthSheet> createState() => _DriverMonthSheetState();
}

class _DriverMonthSheetState extends State<_DriverMonthSheet> {
  Map<String, dynamic>? _r;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await context.read<AppState>().api.vehDriverReport(widget.driverId);
      if (mounted) setState(() => _r = r);
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final r = _r;
    final tot = vehMap(r?['totals']);
    final sc = vehInt(tot['score']);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
        Text(widget.name, style: Theme.of(context).textTheme.titleLarge),
        Text(tr.v100DriverMonth, style: TextStyle(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.md),
        if (_error)
          Text(tr.vehLoadError, style: TextStyle(color: scheme.error))
        else if (r == null)
          const Center(child: CircularProgressIndicator())
        else if ((vehNum(tot['km']) ?? 0) <= 0)
          Text(tr.v100DriverNoTrips, style: TextStyle(color: scheme.onSurfaceVariant))
        else ...[
          Text(
              '${tr.vehKm(vehNumStr(context, vehNum(tot['km']) ?? 0, decimals: 1))} · '
              '${tr.v100TripsN(vehNumStr(context, vehInt(tot['trips']) ?? 0))} · '
              '${tr.v100ScoreShort(sc == null ? '-' : vehNumStr(context, sc))}',
              style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.xs),
          Text(
              '${tr.v100HarshBrake}: ${vehNumStr(context, vehInt(tot['harsh_brake']) ?? 0)} · '
              '${tr.v100HarshAccel}: ${vehNumStr(context, vehInt(tot['harsh_accel']) ?? 0)}'),
          for (final v in vehList(r['vehicles']))
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.directions_car_rounded),
              title: Text('${v['name'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(tr.vehKm(vehNumStr(context,
                  vehNum(vehMap(v['totals'])['km']) ?? 0, decimals: 1))),
            ),
        ],
      ]),
    );
  }
}
