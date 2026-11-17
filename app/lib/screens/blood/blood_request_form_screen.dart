import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../blood_panel_api.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../ds/ds.dart';
import '../../widgets/app_sheet.dart';
import 'bp_common.dart';
import '../../widgets/local_counter.dart';
import 'package:assisto/ads/ad_block_context.dart' show AdBlockedState;

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

class _BloodRequestFormScreenState extends State<BloodRequestFormScreen>
    with AdBlockedState<BloodRequestFormScreen> {
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
    final ds = DsTokens.of(context);
    final text = Theme.of(context).textTheme;
    final districts = bpRows(widget.config, 'districts');
    final radii = ((widget.config['radius_choices'] as List?) ?? const [2, 5, 10, 25]).whereType<int>();
    Widget err(String key, String msg) => _bad.contains(key)
        ? Padding(padding: const EdgeInsets.only(top: Gap.xs),
            child: Text(msg, style: text.bodyMedium?.copyWith(color: ds.dangerInk)))
        : const SizedBox.shrink();
    Widget title(String s) => Padding(
          padding: const EdgeInsets.only(bottom: Gap.sm),
          child: Semantics(header: true, child: Text(s,
              style: text.titleSmall?.copyWith(color: ds.text, fontWeight: FontWeight.w700))),
        );
    return Scaffold(
      appBar: AppBar(title: Text(t.bpRequestCta)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl)),
        children: [
          Text(t.bpReqLead, style: text.bodyMedium?.copyWith(color: ds.muted)),
          const SizedBox(height: Gap.md),
          DsCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              title(t.bpGroupNeeded),
              BpGroupGrid(
                keyPrefix: 'bp-req-g-',
                selected: _group,
                onTap: (g) => setState(() => _group = _group == g ? '' : g),
              ),
              err('blood_group', t.bpErrGroup),
              const SizedBox(height: Gap.sm),
              Row(children: [
                Expanded(child: Text(t.bpBags,
                    style: text.titleSmall?.copyWith(color: ds.text, fontWeight: FontWeight.w700))),
                IconButton(
                  key: const ValueKey('bp-units-minus'),
                  tooltip: t.bpLess,
                  onPressed: _units > 1 ? () => setState(() => _units--) : null,
                  icon: const Icon(Icons.remove_circle_outline_rounded),
                ),
                DsNumber(bpD(context, '$_units'), small: true),
                IconButton(
                  key: const ValueKey('bp-units-plus'),
                  tooltip: t.bpMore,
                  onPressed: _units < 10 ? () => setState(() => _units++) : null,
                  icon: const Icon(Icons.add_circle_outline_rounded),
                ),
              ]),
            ]),
          ),
          const SizedBox(height: Gap.md),
          DsCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TextField(
                key: const ValueKey('bp-req-hospital'),
                controller: _hospital,
                maxLength: 120,
                buildCounter: localCounter,
                decoration: InputDecoration(labelText: t.bpHospital, helperText: t.bpHospitalHelp,
                    helperMaxLines: 4),
              ),
              err('hospital', t.bpErrHospital),
              const SizedBox(height: Gap.sm),
              DropdownButtonFormField<String>(
                key: const ValueKey('bp-req-district'),
                initialValue: districts.any((d) => d['code'] == _district) ? _district : null,
                isExpanded: true,
                decoration: InputDecoration(labelText: t.bpDistrict),
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
                buildCounter: localCounter,
                decoration: InputDecoration(labelText: t.bpAreaLabel),
              ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: kMinTap),
                  child: TextButton.icon(
                    key: const ValueKey('bp-req-here'),
                    onPressed: _useHere,
                    icon: Icon(_point != null ? Icons.check_circle_rounded : Icons.my_location_rounded),
                    label: Text(_point != null ? t.bpPointSaved : t.bpUsePointReq),
                  ),
                ),
              ),
              err('area', t.bpErrArea),
            ]),
          ),
          const SizedBox(height: Gap.md),
          DsCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              title(t.bpNeededByTitle),
              DsChipRow(padding: EdgeInsets.zero, children: [
                for (final h in const [2, 6, 12, 24])
                  DsChip(
                    key: ValueKey('bp-req-in-$h'),
                    label: bpD(context, t.bpInHours(h)),
                    selected: _quick == h,
                    onSelected: (_) => setState(() {
                      _quick = h;
                      _neededBy = DateTime.now().add(Duration(hours: h));
                    }),
                  ),
                DsChip(
                  key: const ValueKey('bp-req-pick-time'),
                  icon: Icons.schedule_rounded,
                  label: _quick == 0 ? bpWhen(context, _neededBy.toIso8601String()) : t.bpPickTime,
                  selected: _quick == 0,
                  onSelected: (_) => unawaited(_pickTime()),
                ),
              ]),
              const SizedBox(height: Gap.lg),
              title(t.bpReachTitle),
              DsChipRow(padding: EdgeInsets.zero, children: [
                for (final r in radii)
                  DsChip(
                    key: ValueKey('bp-req-r-$r'),
                    label: bpD(context, t.bpKm(r)),
                    selected: _radius == r,
                    onSelected: (_) => setState(() => _radius = r),
                  ),
              ]),
              const SizedBox(height: Gap.sm),
              Text(t.bpReachSub, style: text.bodySmall?.copyWith(color: ds.muted)),
              // finish1 (push-area honesty): matched by the donor's SAVED area
              Text(t.bpReachHonest,
                  key: const ValueKey('bp-reach-honest'),
                  style: text.bodySmall?.copyWith(color: ds.muted)),
            ]),
          ),
          const SizedBox(height: Gap.md),
          DsCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TextField(
                key: const ValueKey('bp-req-note'),
                controller: _note,
                maxLength: 300,
                buildCounter: localCounter,
                minLines: 2,
                maxLines: 4,
                decoration: InputDecoration(labelText: t.bpNote, helperText: t.bpNoteHelp,
                    helperMaxLines: 4),
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
            ]),
          ),
          const SizedBox(height: Gap.lg),
          DsButton.danger(
            key: const ValueKey('bp-req-submit'),
            label: t.bpReqSubmit,
            icon: Icons.campaign_rounded,
            expand: true,
            busy: _busy,
            onPressed: _submit,
          ),
          const SizedBox(height: Gap.sm),
          Text(t.bpWhoGets, textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(color: ds.muted)),
        ],
      ),
    );
  }
}
