import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../vehicle/veh_format.dart';
import '../vehicle/vehicle_api.dart';
import '../services/action_feedback.dart'; // db1

/// Owner-only tracker settings: alerts (over-speed, night ignition,
/// geofences), reporting interval, engine-cut family approval, who can see /
/// control the vehicle, and removal. Every rule is enforced SERVER-side.
class VehicleTrackerSettingsScreen extends StatefulWidget {
  final Map<String, dynamic> tracker;
  const VehicleTrackerSettingsScreen({super.key, required this.tracker});

  @override
  State<VehicleTrackerSettingsScreen> createState() =>
      _VehicleTrackerSettingsScreenState();
}

class _VehicleTrackerSettingsScreenState extends State<VehicleTrackerSettingsScreen> {
  late final TextEditingController _name;
  late int _speed;
  late bool _night;
  late String _nightStart, _nightEnd;
  late int _moving, _parked;
  late bool _approval;
  int? _approver;
  late List<Map<String, dynamic>> _fences;
  List<Map<String, dynamic>> _members = [];
  List<Map<String, dynamic>> _grants = [];
  bool _saving = false;

  int get _id => widget.tracker['id'] as int;

  @override
  void initState() {
    super.initState();
    final s = vehMap(widget.tracker['settings']);
    _name = TextEditingController(text: '${widget.tracker['name'] ?? ''}');
    _speed = vehInt(s['speed_limit_kmh']) ?? 0;
    _night = s['night_ignition_alert'] != false;
    _nightStart = '${s['night_start'] ?? '23:00'}';
    _nightEnd = '${s['night_end'] ?? '05:00'}';
    _moving = vehInt(s['moving_interval_s']) ?? 5;
    _parked = vehInt(s['parked_interval_s']) ?? 180;
    _approval = s['cutoff_requires_approval'] == true;
    _approver = vehInt(s['approver_member_id']);
    _fences = vehList(s['geofences']);
    _loadPeople();
  }

  Future<void> _loadPeople() async {
    final api = context.read<AppState>().api;
    try {
      final m = await api.getJson('/circle/members');
      _members = vehList(m['results']);
    } catch (_) {}
    try {
      _grants = vehList((await api.vehGrants(_id))['grants']);
    } catch (_) {}
    if (mounted) setState(() {});
  }

  void _snack(String m) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _save() async {
    final tr = AppLocalizations.of(context);
    setState(() => _saving = true);
    try {
      await context.read<AppState>().api.vehUpdate(_id, {
        'name': _name.text.trim(),
        'speed_limit_kmh': _speed,
        'night_ignition_alert': _night,
        'night_start': _nightStart,
        'night_end': _nightEnd,
        'moving_interval_s': _moving,
        'parked_interval_s': _parked,
        'geofences': _fences,
        'cutoff_requires_approval': _approval,
        'approver_member_id': _approval ? _approver : null,
      });
      _snack(tr.vehSaved);
    } catch (e) {
      _snack(vehReasonText(tr, e));
    }
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _pickTime(bool start) async {
    final cur = start ? _nightStart : _nightEnd;
    final parts = cur.split(':');
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
          hour: int.tryParse(parts.first) ?? 23,
          minute: int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0),
    );
    if (t == null) return;
    final s = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    setState(() => start ? _nightStart = s : _nightEnd = s);
  }

  Future<void> _addFenceHere() async {
    final tr = AppLocalizations.of(context);
    final live = vehMap(widget.tracker['live']);
    final lat = vehNum(live['lat']), lng = vehNum(live['lng']);
    if (lat == null || lng == null) {
      _snack(tr.vehErrNoFix);
      return;
    }
    final nameC = TextEditingController(text: tr.vehFenceDefaultName);
    var radius = 300;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(tr.vehFenceAddTitle),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(tr.vehFenceAddBody, style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: Gap.sm),
            TextField(
                controller: nameC,
                maxLength: 40,
                decoration: InputDecoration(labelText: tr.vehFenceName)),
            DropdownButtonFormField<int>(
              initialValue: radius,
              isExpanded: true,
              decoration: InputDecoration(labelText: tr.vehFenceRadius),
              items: [
                for (final r in [200, 300, 500, 1000, 5000])
                  DropdownMenuItem(
                      value: r, child: Text(tr.vehMeters(vehNumStr(ctx, r)))),
              ],
              onChanged: (v) => setD(() => radius = v ?? 300),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr.cancel)),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr.save)),
          ],
        ),
      ),
    );
    if (ok != true) return;
    setState(() => _fences = [
          ..._fences,
          {
            'id': '${DateTime.now().millisecondsSinceEpoch % 100000}',
            'name': nameC.text.trim(),
            'lat': lat,
            'lng': lng,
            'radius_m': radius,
          }
        ]);
  }

  Future<void> _addGrant() async {
    final tr = AppLocalizations.of(context);
    if (_members.isEmpty) {
      _snack(tr.vehNoCircleMembers);
      return;
    }
    int? pick;
    var canCmd = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(tr.vehShareTitle),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<int>(
              initialValue: pick,
              isExpanded: true,
              decoration: InputDecoration(labelText: tr.vehShareWho),
              items: [
                for (final m in _members)
                  DropdownMenuItem(
                      value: m['id'] as int,
                      child: Text('${m['name'] ?? ''}',
                          maxLines: 1, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => setD(() => pick = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: canCmd,
              onChanged: (v) => setD(() => canCmd = v),
              title: Text(tr.vehShareCanControl),
              subtitle: Text(tr.vehShareCanControlBody),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr.cancel)),
            FilledButton(
                onPressed: pick == null ? null : () => Navigator.pop(ctx, true),
                child: Text(tr.vehShareCta)),
          ],
        ),
      ),
    );
    if (ok != true || pick == null || !mounted) return;
    try {
      await context.read<AppState>().api.vehGrantFamily(_id, pick!, canCommand: canCmd);
      _loadPeople();
    } catch (e) {
      _snack(vehReasonText(tr, e));
    }
  }

  Future<void> _revoke(int gid) async {
    try {
      await context.read<AppState>().api.vehRevokeGrant(_id, gid);
    } catch (e) {
      showActionFailed(context, 'vehSettings.revoke', e); // db1
    }
    _loadPeople();
  }

  Future<void> _remove() async {
    final tr = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.vehRemoveTitle),
        content: Text(tr.vehRemoveBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr.cancel)),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error,
                  foregroundColor: Theme.of(ctx).colorScheme.onError),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr.delete)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context.read<AppState>().api.vehRemove(_id);
      if (mounted) Navigator.of(context)
        ..pop()
        ..pop();
    } catch (e) {
      _snack(vehReasonText(tr, e));
    }
  }

  String _memberName(int? id) {
    for (final m in _members) {
      if (m['id'] == id) return '${m['name'] ?? ''}';
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    Widget section(String title) => Padding(
          padding: const EdgeInsets.fromLTRB(0, Gap.lg, 0, Gap.xs),
          child: Text(title,
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700)),
        );
    return Scaffold(
      appBar: AppBar(title: Text(tr.vehSettingsTitle)),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(tr.save),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
        children: [
          const SizedBox(height: Gap.sm),
          TextField(
            controller: _name,
            maxLength: 40,
            decoration: InputDecoration(labelText: tr.vehNameLabel),
          ),
          section(tr.vehAlertsSection),
          Text(_speed == 0
              ? tr.vehSpeedLimitOff
              : tr.vehSpeedLimitOn(vehNumStr(context, _speed))),
          Slider(
            value: _speed.toDouble(),
            min: 0,
            max: 150,
            divisions: 15,
            label: _speed == 0 ? tr.vehOff : tr.vehKmh(vehNumStr(context, _speed)),
            onChanged: (v) => setState(() => _speed = v.round()),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _night,
            onChanged: (v) => setState(() => _night = v),
            title: Text(tr.vehNightAlert),
            subtitle: Text(tr.vehNightWindow(_nightStart, _nightEnd)),
          ),
          if (_night)
            Wrap(spacing: Gap.sm, children: [
              OutlinedButton(
                  onPressed: () => _pickTime(true), child: Text(tr.vehNightFrom(_nightStart))),
              OutlinedButton(
                  onPressed: () => _pickTime(false), child: Text(tr.vehNightTo(_nightEnd))),
            ]),
          section(tr.vehFencesSection),
          if (_fences.isEmpty)
            Text(tr.vehFencesEmpty, style: TextStyle(color: scheme.onSurfaceVariant)),
          for (final f in _fences)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.radio_button_checked, color: Brand.purple),
              title: Text('${f['name'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(tr.vehMeters(vehNumStr(context, vehInt(f['radius_m']) ?? 300))),
              trailing: IconButton(
                tooltip: tr.delete,
                icon: const Icon(Icons.delete_outline),
                onPressed: () => setState(() => _fences = [..._fences]..remove(f)),
              ),
            ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: _fences.length >= 10 ? null : _addFenceHere,
              icon: const Icon(Icons.add_location_alt_outlined),
              label: Text(tr.vehFenceAddHere),
            ),
          ),
          section(tr.vehIntervalSection),
          const SizedBox(height: Gap.sm),
          DropdownButtonFormField<int>(
            initialValue: [5, 10, 30, 60].contains(_moving) ? _moving : 5,
            isExpanded: true,
            decoration: InputDecoration(labelText: tr.vehIntervalMoving),
            items: [
              for (final s in [5, 10, 30, 60])
                DropdownMenuItem(value: s, child: Text(tr.vehEverySec(vehNumStr(context, s)))),
            ],
            onChanged: (v) => setState(() => _moving = v ?? 5),
          ),
          const SizedBox(height: Gap.sm),
          DropdownButtonFormField<int>(
            initialValue: [60, 180, 300, 600].contains(_parked) ? _parked : 180,
            isExpanded: true,
            decoration: InputDecoration(labelText: tr.vehIntervalParked),
            items: [
              for (final s in [60, 180, 300, 600])
                DropdownMenuItem(value: s, child: Text(tr.vehEverySec(vehNumStr(context, s)))),
            ],
            onChanged: (v) => setState(() => _parked = v ?? 180),
          ),
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Text(tr.vehIntervalNote,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5)),
          ),
          section(tr.vehApprovalSection),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _approval,
            onChanged: (v) => setState(() => _approval = v),
            title: Text(tr.vehApprovalToggle),
            subtitle: Text(tr.vehApprovalBody),
          ),
          if (_approval)
            DropdownButtonFormField<int>(
              key: ValueKey('approver-${_members.length}'),
              initialValue: _members.any((m) => m['id'] == _approver) ? _approver : null,
              isExpanded: true,
              decoration: InputDecoration(labelText: tr.vehApprover),
              items: [
                for (final m in _members)
                  DropdownMenuItem(
                      value: m['id'] as int,
                      child: Text('${m['name'] ?? ''}',
                          maxLines: 1, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => setState(() => _approver = v),
            ),
          if (_approval && _approver != null && _memberName(_approver).isEmpty)
            Text(tr.vehNoCircleMembers, style: TextStyle(color: scheme.error)),
          section(tr.vehSharingSection),
          Text(tr.vehSharingBody, style: TextStyle(color: scheme.onSurfaceVariant)),
          for (final g in _grants)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(g['can_command'] == true ? Icons.admin_panel_settings : Icons.visibility),
              title: Text('${g['name'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(g['can_command'] == true ? tr.vehShareCanControl : tr.vehShareViewOnly),
              trailing: IconButton(
                tooltip: tr.vehShareRevoke,
                icon: const Icon(Icons.person_remove_outlined),
                onPressed: () => _revoke(g['id'] as int),
              ),
            ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: _addGrant,
              icon: const Icon(Icons.person_add_alt),
              label: Text(tr.vehShareCta),
            ),
          ),
          const SizedBox(height: Gap.lg),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
            onPressed: _remove,
            icon: const Icon(Icons.link_off),
            label: Text(tr.vehRemoveTitle),
          ),
          const SizedBox(height: Gap.xl),
        ],
      ),
    );
  }
}
