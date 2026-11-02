import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../blood_panel_api.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import 'bp_common.dart';

/// blood (owner 2 Nov) — urgent blood request (about 1 minute): group,
/// bags, hospital, area, needed-by, radius, optional note. No phone number
/// or address anywhere (the server refuses them): donors answer in the app.
/// Pops the new request id.
class BloodRequestFormScreen extends StatefulWidget {
  const BloodRequestFormScreen({super.key, this.config = const {}, this.initialGroup = '', this.locate});
  final Map<String, dynamic> config;
  final String initialGroup;
  final Future<({double lat, double lng})?> Function()? locate;

  @override
  State<BloodRequestFormScreen> createState() => _BloodRequestFormScreenState();
}

class _BloodRequestFormScreenState extends State<BloodRequestFormScreen> {
  late String _group = widget.initialGroup;
  int _units = 1;
  final _hospital = TextEditingController();
  final _area = TextEditingController();
  final _note = TextEditingController();
  late String _district = '${bpMap(widget.config['me'])['district'] ?? ''}';
  ({double lat, double lng})? _point;
  DateTime _neededBy = DateTime.now().add(const Duration(hours: 6));
  int _quick = 6;
  late int _radius = (widget.config['default_radius'] as int?) ?? 5;
  bool _real = false;
  bool _busy = false;
  Set<String> _bad = const {};

  @override
  void dispose() {
    _hospital.dispose();
    _area.dispose();
    _note.dispose();
    super.dispose();
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _pickTime() async {
    final now = DateTime.now();
    final d = await showDatePicker(
        context: context, initialDate: _neededBy, firstDate: now,
        lastDate: now.add(const Duration(days: 3)));
    if (d == null || !mounted) return;
    final tm = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_neededBy));
    if (tm == null) return;
    var at = DateTime(d.year, d.month, d.day, tm.hour, tm.minute);
    final max = now.add(const Duration(hours: 72));
    if (at.isAfter(max)) at = max;
    if (at.isBefore(now)) at = now.add(const Duration(minutes: 30));
    setState(() {
      _neededBy = at;
      _quick = 0;
    });
  }

  Future<void> _useHere() async {
    final t = AppLocalizations.of(context);
    final p = await (widget.locate ?? () => bpLocate(context))();
    if (!mounted) return;
    if (p == null) {
      _snack(t.bpLocationFailed);
      return;
    }
    setState(() => _point = (lat: bpCoarse(p.lat), lng: bpCoarse(p.lng)));
  }

  Future<void> _submit() async {
    final t = AppLocalizations.of(context);
    final bad = <String>{
      if (_group.isEmpty) 'blood_group',
      if (_hospital.text.trim().length < 3) 'hospital',
      if (_district.isEmpty && _point == null) 'area',
      if (!_real) 'real',
    };
    setState(() => _bad = bad);
    if (bad.isNotEmpty) {
      _snack(t.bpErrFields);
      return;
    }
    setState(() => _busy = true);
    try {
      final r = await context.read<AppState>().api.bpCreateRequest({
        'blood_group': _group,
        'units': _units,
        'hospital': _hospital.text.trim(),
        'area_text': _area.text.trim(),
        'district': _district,
        if (_point != null) ...{'lat': _point!.lat, 'lng': _point!.lng},
        'needed_by': _neededBy.toUtc().toIso8601String(),
        'radius_km': _radius,
        'note': _note.text.trim(),
      });
      if (!mounted) return;
      setState(() => _busy = false);
      final req = bpMap(r['request']);
      if (r['ok'] == true && req['id'] is int) {
        _snack(t.bpRequestSent);
        Navigator.of(context).pop(req['id'] as int);
      } else {
        final f = ((r['fields'] as List?) ?? const []).map((e) => '$e').toSet();
        setState(() => _bad = f);
        _snack(f.isNotEmpty && (f.contains('hospital') || f.contains('note') || f.contains('area_text'))
            ? t.bpErrNoContact
            : bpReason(t, r['reason'] as String?));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack(t.bpErrGeneric);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final districts = bpRows(widget.config, 'districts');
    final radii = ((widget.config['radius_choices'] as List?) ?? const [2, 5, 10, 25]).whereType<int>();
    Widget err(String key, String msg) => _bad.contains(key)
        ? Padding(padding: const EdgeInsets.only(top: Gap.xs), child: Text(msg, style: TextStyle(color: s.error)))
        : const SizedBox.shrink();
    return Scaffold(
      appBar: AppBar(title: Text(t.bpRequestCta)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl)),
        children: [
          Text(t.bpReqLead, style: text.bodyMedium),
          const SizedBox(height: Gap.lg),
          Text(t.bpGroupNeeded, style: text.titleSmall),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            for (final g in kBloodGroups)
              ChoiceChip(
                key: ValueKey('bp-req-g-$g'),
                label: Text(g),
                selected: _group == g,
                onSelected: (on) => setState(() => _group = on ? g : ''),
              ),
          ]),
          err('blood_group', t.bpErrGroup),
          const SizedBox(height: Gap.lg),
          Row(children: [
            Expanded(child: Text(t.bpBags, style: text.titleSmall)),
            IconButton(
              key: const ValueKey('bp-units-minus'),
              tooltip: t.bpLess,
              onPressed: _units > 1 ? () => setState(() => _units--) : null,
              icon: const Icon(Icons.remove_circle_outline_rounded),
            ),
            Text(bpD(context, '$_units'), style: text.titleLarge),
            IconButton(
              key: const ValueKey('bp-units-plus'),
              tooltip: t.bpMore,
              onPressed: _units < 10 ? () => setState(() => _units++) : null,
              icon: const Icon(Icons.add_circle_outline_rounded),
            ),
          ]),
          const SizedBox(height: Gap.md),
          TextField(
            key: const ValueKey('bp-req-hospital'),
            controller: _hospital,
            maxLength: 120,
            decoration: InputDecoration(labelText: t.bpHospital, helperText: t.bpHospitalHelp,
                helperMaxLines: 2, border: const OutlineInputBorder()),
          ),
          err('hospital', t.bpErrHospital),
          const SizedBox(height: Gap.sm),
          DropdownButtonFormField<String>(
            key: const ValueKey('bp-req-district'),
            initialValue: districts.any((d) => d['code'] == _district) ? _district : null,
            isExpanded: true,
            decoration: InputDecoration(labelText: t.bpDistrict, border: const OutlineInputBorder()),
            items: [
              for (final d in districts)
                DropdownMenuItem(value: '${d['code']}', child: Text('${d['name']}')),
            ],
            onChanged: (v) => setState(() => _district = v ?? ''),
          ),
          const SizedBox(height: Gap.sm),
          TextField(
            key: const ValueKey('bp-req-area'),
            controller: _area,
            maxLength: 60,
            decoration: InputDecoration(labelText: t.bpAreaLabel, border: const OutlineInputBorder()),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: TextButton.icon(
                key: const ValueKey('bp-req-here'),
                onPressed: _useHere,
                icon: const Icon(Icons.my_location_rounded),
                label: Text(_point != null ? t.bpPointSaved : t.bpUsePointReq),
              ),
            ),
          ),
          err('area', t.bpErrArea),
          const SizedBox(height: Gap.md),
          Text(t.bpNeededByTitle, style: text.titleSmall),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            for (final h in const [2, 6, 12, 24])
              ChoiceChip(
                key: ValueKey('bp-req-in-$h'),
                label: Text(bpD(context, t.bpInHours(h))),
                selected: _quick == h,
                onSelected: (_) => setState(() {
                  _quick = h;
                  _neededBy = DateTime.now().add(Duration(hours: h));
                }),
              ),
            ActionChip(
              key: const ValueKey('bp-req-pick-time'),
              avatar: const Icon(Icons.schedule_rounded, size: 18),
              label: Text(_quick == 0 ? bpWhen(context, _neededBy.toIso8601String()) : t.bpPickTime),
              onPressed: _pickTime,
            ),
          ]),
          const SizedBox(height: Gap.md),
          Text(t.bpReachTitle, style: text.titleSmall),
          Text(t.bpReachSub, style: text.bodySmall),
          // finish1 (push-area honesty): matched by the donor's SAVED area
          Text(t.bpReachHonest,
              key: const ValueKey('bp-reach-honest'), style: text.bodySmall),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            for (final r in radii)
              ChoiceChip(
                key: ValueKey('bp-req-r-$r'),
                label: Text(bpD(context, t.bpKm(r))),
                selected: _radius == r,
                onSelected: (_) => setState(() => _radius = r),
              ),
          ]),
          const SizedBox(height: Gap.md),
          TextField(
            key: const ValueKey('bp-req-note'),
            controller: _note,
            maxLength: 300,
            minLines: 2,
            maxLines: 4,
            decoration: InputDecoration(labelText: t.bpNote, helperText: t.bpNoteHelp,
                helperMaxLines: 2, border: const OutlineInputBorder()),
          ),
          CheckboxListTile(
            key: const ValueKey('bp-req-real'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(t.bpRealNeed),
            value: _real,
            onChanged: (v) => setState(() => _real = v == true),
          ),
          err('real', t.bpErrReal),
          const SizedBox(height: Gap.md),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: FilledButton.icon(
              key: const ValueKey('bp-req-submit'),
              onPressed: _busy ? null : _submit,
              icon: const Icon(Icons.campaign_rounded),
              label: _busy
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(t.bpReqSubmit),
            ),
          ),
          const SizedBox(height: Gap.md),
          Text(t.bpWhoGets, style: text.bodySmall),
        ],
      ),
    );
  }
}
