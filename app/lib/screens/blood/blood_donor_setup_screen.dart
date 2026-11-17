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

/// blood (owner 2 Nov) — become / edit a donor. The SEPARATE consent lives
/// here (the Family card's blood group is never read): what others see, what
/// stays private, self-declared basics (age, weight, health). Group + area
/// are required; last donation date sets "available again on"; phone and
/// e-mail stay private unless switched on. Pops `true` when saved.
class BloodDonorSetupScreen extends StatefulWidget {
  const BloodDonorSetupScreen({super.key, this.initial = const {}, this.config = const {}, this.locate});
  final Map<String, dynamic> initial;
  final Map<String, dynamic> config;
  final Future<({double lat, double lng})?> Function()? locate;

  @override
  State<BloodDonorSetupScreen> createState() => _BloodDonorSetupScreenState();
}

class _BloodDonorSetupScreenState extends State<BloodDonorSetupScreen>
    with AdBlockedState<BloodDonorSetupScreen> {
  late String _group = '${widget.initial['blood_group'] ?? ''}';
  late String _sex = '${widget.initial['sex'] ?? ''}';
  late DateTime? _last = DateTime.tryParse('${widget.initial['last_donation'] ?? ''}');
  late bool _never = widget.initial['consented'] == true && widget.initial['last_donation'] == null;
  late String _district = '${widget.initial['district'] ?? ''}';
  late final TextEditingController _area =
      TextEditingController(text: '${widget.initial['area_text'] ?? ''}');
  late bool _phonePublic = widget.initial['phone_public'] == true;
  late bool _emailPublic = widget.initial['email_public'] == true;
  ({double lat, double lng})? _point;
  late bool _consent = widget.initial['consented'] == true;
  late bool _basics = widget.initial['consented'] == true;
  bool _busy = false;
  Set<String> _bad = const {};

  @override
  void dispose() {
    _area.dispose();
    super.dispose();
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _last ?? now,
      firstDate: DateTime(now.year - 10),
      lastDate: now,
    );
    if (d != null) {
      setState(() {
        _last = d;
        _never = false;
      });
    }
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

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    final bad = <String>{
      if (_group.isEmpty) 'blood_group',
      if (_district.isEmpty && _point == null && widget.initial['has_point'] != true) 'area',
      if (!_never && _last == null) 'last_donation',
      if (!_consent || !_basics) 'consent',
    };
    setState(() => _bad = bad);
    if (bad.isNotEmpty) {
      _snack(bad.contains('consent') ? t.bpErrConsent : t.bpErrFields);
      return;
    }
    setState(() => _busy = true);
    final body = <String, dynamic>{
      'consent': true,
      'enabled': true,
      'available': widget.initial['enabled'] == true ? (widget.initial['available'] != false) : true,
      'blood_group': _group,
      'sex': _sex,
      'last_donation': _never || _last == null
          ? null
          : '${_last!.year.toString().padLeft(4, '0')}-${_last!.month.toString().padLeft(2, '0')}-${_last!.day.toString().padLeft(2, '0')}',
      'district': _district,
      'area_text': _area.text.trim(),
      'phone_public': _phonePublic,
      'email_public': _emailPublic,
      if (_point != null) ...{'lat': _point!.lat, 'lng': _point!.lng},
    };
    try {
      final r = await context.read<AppState>().api.bpSaveMe(body);
      if (!mounted) return;
      setState(() => _busy = false);
      if (r['ok'] == true) {
        _snack(t.bpSaved);
        Navigator.of(context).pop(true);
      } else {
        final f = ((r['fields'] as List?) ?? const []).map((e) => '$e').toSet();
        setState(() => _bad = f);
        _snack(f.contains('area_text') ? t.bpErrAreaText : bpReason(t, r['reason'] as String?));
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
    Widget err(String key, String msg) => _bad.contains(key)
        ? Padding(padding: const EdgeInsets.only(top: Gap.xs),
            child: Text(msg, style: text.bodyMedium?.copyWith(color: ds.dangerInk)))
        : const SizedBox.shrink();
    Widget title(String s) => Semantics(header: true, child: Text(s,
        style: text.titleSmall?.copyWith(color: ds.text, fontWeight: FontWeight.w700)));
    Widget sub(String s) => Padding(
          padding: const EdgeInsets.only(top: 2, bottom: Gap.sm),
          child: Text(s, style: text.bodySmall?.copyWith(color: ds.muted)),
        );
    // designv2: one card per step, the main action (save) last and full width
    return Scaffold(
      appBar: AppBar(title: Text(widget.initial['enabled'] == true ? t.bpEdit : t.bpBecomeTitle)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl)),
        children: [
          Text(t.bpSetupLead, style: text.bodyMedium?.copyWith(color: ds.muted)),
          const SizedBox(height: Gap.md),
          DsCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              title(t.bpGroupMine),
              sub(t.bpGroupNotFamily),
              BpGroupGrid(
                keyPrefix: 'bp-setup-g-',
                selected: _group,
                onTap: (g) => setState(() => _group = _group == g ? '' : g),
              ),
              err('blood_group', t.bpErrGroup),
            ]),
          ),
          const SizedBox(height: Gap.md),
          DsCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              title(t.bpSex),
              sub(t.bpSexWhy),
              DsChipRow(padding: EdgeInsets.zero, children: [
                for (final o in [('m', t.bpSexMale), ('f', t.bpSexFemale), ('', t.bpSexSkip)])
                  DsChip(
                    key: ValueKey('bp-sex-${o.$1}'),
                    label: o.$2,
                    selected: _sex == o.$1,
                    onSelected: (_) => setState(() => _sex = o.$1),
                  ),
              ]),
              const SizedBox(height: Gap.lg),
              title(t.bpLastDonation),
              const SizedBox(height: Gap.sm),
              DsChipRow(padding: EdgeInsets.zero, children: [
                DsChip(
                  key: const ValueKey('bp-last-pick'),
                  icon: Icons.event_rounded,
                  label: _last != null && !_never ? bpDate(context, _last!.toIso8601String()) : t.bpPickDate,
                  selected: _last != null && !_never,
                  onSelected: (_) => unawaited(_pickDate()),
                ),
                DsChip(
                  key: const ValueKey('bp-last-never'),
                  label: t.bpNeverDonated,
                  selected: _never,
                  onSelected: (on) => setState(() {
                    _never = on;
                    if (on) _last = null;
                  }),
                ),
              ]),
              err('last_donation', t.bpErrLast),
            ]),
          ),
          const SizedBox(height: Gap.md),
          DsCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              title(t.bpAreaTitle),
              sub(t.bpAreaWhy),
              DropdownButtonFormField<String>(
                key: const ValueKey('bp-setup-district'),
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
                key: const ValueKey('bp-setup-area'),
                controller: _area,
                maxLength: 60,
                buildCounter: localCounter,
                decoration: InputDecoration(
                    labelText: t.bpAreaLabel, helperText: t.bpAreaHelp, helperMaxLines: 5),
              ),
              err('area_text', t.bpErrAreaText),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: kMinTap),
                  child: TextButton.icon(
                    key: const ValueKey('bp-setup-here'),
                    onPressed: _useHere,
                    icon: Icon(_point != null || widget.initial['has_point'] == true
                        ? Icons.check_circle_rounded
                        : Icons.my_location_rounded),
                    label: Text(_point != null || widget.initial['has_point'] == true ? t.bpPointSaved : t.bpUsePoint),
                  ),
                ),
              ),
              err('area', t.bpErrArea),
            ]),
          ),
          const SizedBox(height: Gap.md),
          DsCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              title(t.bpContactTitle),
              SwitchListTile(
                key: const ValueKey('bp-phone-public'),
                contentPadding: EdgeInsets.zero,
                title: Text(t.bpPhonePublic),
                subtitle: Text(t.bpPhonePublicSub),
                value: _phonePublic,
                onChanged: (v) => setState(() => _phonePublic = v),
              ),
              SwitchListTile(
                key: const ValueKey('bp-email-public'),
                contentPadding: EdgeInsets.zero,
                title: Text(t.bpEmailPublic),
                subtitle: Text(t.bpEmailPublicSub),
                value: _emailPublic,
                onChanged: (v) => setState(() => _emailPublic = v),
              ),
            ]),
          ),
          const SizedBox(height: Gap.md),
          DsCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Icon(Icons.verified_user_rounded, color: ds.primaryInk, size: 22),
                const SizedBox(width: Gap.sm),
                Expanded(child: title(t.bpConsentTitle)),
              ]),
              const SizedBox(height: Gap.xs),
              Text(t.bpConsentBody, style: text.bodyMedium?.copyWith(color: ds.muted)),
              CheckboxListTile(
                key: const ValueKey('bp-consent'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(t.bpConsentCheck),
                value: _consent,
                onChanged: (v) => setState(() => _consent = v == true),
              ),
              CheckboxListTile(
                key: const ValueKey('bp-basics'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(bpD(context, t.bpBasicsCheck)),
                value: _basics,
                onChanged: (v) => setState(() => _basics = v == true),
              ),
              err('consent', t.bpErrConsent),
            ]),
          ),
          const SizedBox(height: Gap.lg),
          DsButton(
            key: const ValueKey('bp-setup-save'),
            label: widget.initial['enabled'] == true ? t.bpSave : t.bpJoin,
            icon: Icons.volunteer_activism_rounded,
            expand: true,
            busy: _busy,
            onPressed: _save,
          ),
        ],
      ),
    );
  }
}
