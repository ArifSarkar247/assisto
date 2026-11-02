import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../missing_alert_api.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/permission_reason.dart';
import 'ma_common.dart';

/// missing (owner 2 Nov) — post a missing person alert. One screen, top to
/// bottom: who (My Circle family / a Family entry / someone else in the
/// family), photo (optional, re-encoded without location data on the
/// server), name, age, what they wore, last seen (time + AREA — never a
/// house address), radius; ADULT: police GD number + thana + date (with the
/// honest "we do not verify it" line); CHILD: the guardian check (verified
/// parent link, or a second family member confirms, or a GD number); three
/// promises; post. Every refusal from the server is shown in one sentence.
class MissingPostScreen extends StatefulWidget {
  const MissingPostScreen({super.key, this.pickPhoto, this.locate});

  final Future<Uint8List?> Function()? pickPhoto;
  final Future<({double lat, double lng})?> Function()? locate;

  @override
  State<MissingPostScreen> createState() => _MissingPostScreenState();
}

class _MissingPostScreenState extends State<MissingPostScreen> {
  ApiClient get _api => context.read<AppState>().api;
  bool _loading = true;
  bool _failed = false;
  bool _busy = false;
  Map<String, dynamic> _cfg = const {};

  // who
  String _who = 'other'; // 'u:<id>' | 'm:<id>' | 'other'
  final _name = TextEditingController();
  final _age = TextEditingController();
  final _relation = TextEditingController();
  final _desc = TextEditingController();
  final _area = TextEditingController();
  final _gdNum = TextEditingController();
  final _gdThana = TextEditingController();
  DateTime _gdDate = DateTime.now();
  DateTime _seen = DateTime.now();
  String _district = '';
  int _radius = 10;
  bool _useHere = false;
  ({double lat, double lng})? _here;
  Uint8List? _photo;
  int? _cosigner;
  bool _childGd = false;
  bool _c1 = false, _c2 = false, _c3 = false;
  List<String> _bad = const [];

  @override
  void initState() {
    super.initState();
    _age.addListener(() => setState(() {}));
    unawaited(_load());
  }

  @override
  void dispose() {
    for (final c in [_name, _age, _relation, _desc, _area, _gdNum, _gdThana]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final r = await _api.maConfig();
      if (!mounted) return;
      setState(() {
        _cfg = r;
        _radius = (r['default_radius'] as int?) ?? 10;
        final optin = r['optin'];
        if (optin is Map && (optin['district'] ?? '') != '') _district = '${optin['district']}';
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  int? get _ageVal => int.tryParse(maAsciiDigits(_age.text.trim()));
  int get _childUnder => (_cfg['child_under'] as int?) ?? 18;
  bool get _isChild => _ageVal != null && _ageVal! < _childUnder;

  Map<String, dynamic>? get _whoUser {
    if (!_who.startsWith('u:')) return null;
    final id = int.tryParse(_who.substring(2));
    return maRows(_cfg, 'family_users').where((u) => u['id'] == id).firstOrNull;
  }

  void _pickWho(String key, String name) {
    setState(() {
      _who = key;
      if (name.isNotEmpty) _name.text = name;
    });
  }

  Future<void> _addPhoto() async {
    Uint8List? b;
    try {
      if (widget.pickPhoto != null) {
        b = await widget.pickPhoto!();
      } else {
        final x = await ImagePicker()
            .pickImage(source: ImageSource.gallery, maxWidth: 1280, imageQuality: 85);
        b = x == null ? null : await x.readAsBytes();
      }
    } catch (_) {
      b = null;
    }
    if (!mounted || b == null) return;
    setState(() => _photo = b);
  }

  Future<({double lat, double lng})?> _locate() async {
    if (widget.locate != null) return widget.locate!();
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      // Play: in-app disclosure before Android's prompt (play_disclosure_guard)
      final perm = await askLocationWithReason(context);
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return null;
      final p = await Geolocator.getCurrentPosition().timeout(const Duration(seconds: 10));
      return (lat: p.latitude, lng: p.longitude);
    } catch (_) {
      return null;
    }
  }

  Future<void> _toggleHere(bool v) async {
    final t = AppLocalizations.of(context);
    if (!v) {
      setState(() {
        _useHere = false;
        _here = null;
      });
      return;
    }
    final p = await _locate();
    if (!mounted) return;
    if (p == null) {
      _snack(t.maLocationFailed);
      return;
    }
    setState(() {
      _useHere = true;
      _here = (lat: maCoarse(p.lat), lng: maCoarse(p.lng));
    });
  }

  Future<void> _pickSeen() async {
    final now = DateTime.now();
    final d = await showDatePicker(
        context: context,
        initialDate: _seen,
        firstDate: now.subtract(const Duration(days: 30)),
        lastDate: now);
    if (d == null || !mounted) return;
    final tm = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_seen));
    if (!mounted) return;
    final v = DateTime(d.year, d.month, d.day, tm?.hour ?? _seen.hour, tm?.minute ?? _seen.minute);
    setState(() => _seen = v.isAfter(now) ? now : v);
  }

  Future<void> _pickGdDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
        context: context,
        initialDate: _gdDate,
        firstDate: now.subtract(const Duration(days: 60)),
        lastDate: now);
    if (d != null && mounted) setState(() => _gdDate = d);
  }

  List<String> _localProblems() {
    final bad = <String>[];
    if (_name.text.trim().length < 2) bad.add('name');
    final a = _ageVal;
    if (a == null || a < 0 || a > 110) bad.add('age');
    if (_who == 'other' && _relation.text.trim().isEmpty) bad.add('relation');
    if (_area.text.trim().length < 3) bad.add('area_text');
    if (_district.isEmpty && _here == null) bad.add('district');
    final needGd = !_isChild || _childGd;
    if (needGd) {
      if (maCleanGd(_gdNum.text) == null) bad.add('gd_number');
      if (_gdThana.text.trim().length < 2) bad.add('gd_thana');
    }
    if (!_c1) bad.add('confirm_is_family');
    if (!_c2) bad.add('confirm_no_address');
    if (!_c3) bad.add('confirm_false_post');
    return bad;
  }

  Future<void> _submit() async {
    final t = AppLocalizations.of(context);
    final bad = _localProblems();
    setState(() => _bad = bad);
    if (bad.isNotEmpty) {
      _snack(t.maFixFields);
      return;
    }
    final needGd = !_isChild || _childGd;
    final body = <String, dynamic>{
      'name': _name.text.trim(),
      'age': _ageVal,
      'description': _desc.text.trim(),
      'area_text': _area.text.trim(),
      'district': _district,
      'radius_km': _radius,
      'last_seen_at': _seen.toUtc().toIso8601String(),
      if (_here != null) 'lat': _here!.lat,
      if (_here != null) 'lng': _here!.lng,
      if (_who.startsWith('u:')) 'subject_user_id': int.tryParse(_who.substring(2)),
      if (_who.startsWith('m:')) 'family_member_id': int.tryParse(_who.substring(2)),
      if (_who == 'other') 'relation': _relation.text.trim(),
      if (needGd) 'gd_number': maCleanGd(_gdNum.text),
      if (needGd) 'gd_thana': _gdThana.text.trim(),
      if (needGd) 'gd_date': _gdDate.toIso8601String().substring(0, 10),
      if (_isChild && _cosigner != null) 'cosigner_id': _cosigner,
      if (_photo != null) 'photo_b64': base64Encode(_photo!),
      'confirm_is_family': _c1,
      'confirm_no_address': _c2,
      'confirm_false_post': _c3,
    };
    setState(() => _busy = true);
    try {
      final r = await _api.maCreate(body);
      if (!mounted) return;
      setState(() => _busy = false);
      if (r['ok'] == true) {
        _snack(r['needs'] == 'cosign' ? t.maPostedPendingV2 : t.maPosted);
        Navigator.of(context).maybePop(true);
        return;
      }
      final f = r['fields'];
      setState(() => _bad = f is List ? [for (final x in f) '$x'] : const []);
      var msg = maReason(t, r['reason'] as String?);
      if (_bad.contains('address')) msg = t.maErrAddress;
      if (_bad.contains('phone')) msg = t.maErrPhone;
      _snack(msg);
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack(t.maErrGeneric);
    }
  }

  String? _err(String field, String msg) => _bad.contains(field) ? msg : null;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.maPostTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _failed
              ? Center(child: MaError(onRetry: _load))
              : ListView(
                  padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xl)),
                  children: _form(context),
                ),
    );
  }

  List<Widget> _form(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final users = maRows(_cfg, 'family_users');
    final members = maRows(_cfg, 'family_members');
    final cosigners = maRows(_cfg, 'cosigners');
    final districts = maRows(_cfg, 'districts');
    final radii = (_cfg['radius_choices'] is List)
        ? [for (final r in _cfg['radius_choices'] as List) if (r is int) r]
        : const [5, 10, 25];
    final loc = MaterialLocalizations.of(context);
    final whoUser = _whoUser;
    final verifiedParent = whoUser != null && whoUser['relation'] == 'child';
    Widget gap([double h = Gap.md]) => SizedBox(height: h);
    return [
      Text(t.maPostIntro, style: text.bodyMedium),
      gap(),
      Text(t.maWho, style: text.titleSmall),
      gap(Gap.sm),
      Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
        for (final u in users)
          ChoiceChip(
            label: Text('${u['name']}'),
            selected: _who == 'u:${u['id']}',
            onSelected: (_) => _pickWho('u:${u['id']}', '${u['name']}'),
          ),
        for (final m in members)
          ChoiceChip(
            label: Text('${m['name']}'),
            selected: _who == 'm:${m['id']}',
            onSelected: (_) => _pickWho('m:${m['id']}', '${m['name']}'),
          ),
        ChoiceChip(
          key: const ValueKey('ma-who-other'),
          label: Text(t.maWhoOther),
          selected: _who == 'other',
          onSelected: (_) => _pickWho('other', ''),
        ),
      ]),
      if (users.isEmpty) ...[
        gap(Gap.xs),
        Text(t.maWhoCircleHint, style: text.bodySmall),
      ],
      if (_who == 'other') ...[
        gap(Gap.sm),
        TextField(
          key: const ValueKey('ma-relation'),
          controller: _relation,
          decoration: InputDecoration(
              labelText: t.maRelation,
              helperText: t.maRelationHelp,
              errorText: _err('relation', t.maRequired),
              border: const OutlineInputBorder()),
        ),
      ],
      gap(),
      Row(children: [
        _photo == null
            ? Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                    color: s.surfaceContainerHighest, borderRadius: BorderRadius.circular(Radii.md)),
                child: Icon(Icons.person_rounded, size: 44, color: s.onSurfaceVariant),
              )
            : ClipRRect(
                borderRadius: BorderRadius.circular(Radii.md),
                child: Image.memory(_photo!, width: 88, height: 88, fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox(width: 88, height: 88)),
              ),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            OutlinedButton.icon(
              key: const ValueKey('ma-photo'),
              onPressed: _addPhoto,
              icon: const Icon(Icons.add_a_photo_rounded),
              label: Text(_photo == null ? t.maAddPhoto : t.maChangePhoto),
            ),
            if (_photo != null)
              TextButton(onPressed: () => setState(() => _photo = null), child: Text(t.maRemovePhoto)),
            Text(t.maPhotoHelp, style: text.bodySmall),
          ]),
        ),
      ]),
      gap(),
      TextField(
        key: const ValueKey('ma-name'),
        controller: _name,
        maxLength: 80,
        decoration: InputDecoration(
            labelText: t.maName, errorText: _err('name', t.maRequired), border: const OutlineInputBorder()),
      ),
      gap(Gap.sm),
      TextField(
        key: const ValueKey('ma-age'),
        controller: _age,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[0-9\\u09E6-\\u09EF]')),
          LengthLimitingTextInputFormatter(3)],
        decoration: InputDecoration(
            labelText: t.maAge,
            helperText: _ageVal == null ? null : (_isChild ? t.maAgeChild : t.maAgeAdultV2),
            errorText: _err('age', t.maRequired),
            border: const OutlineInputBorder()),
      ),
      gap(Gap.sm),
      TextField(
        key: const ValueKey('ma-desc'),
        controller: _desc,
        minLines: 2,
        maxLines: 5,
        maxLength: 500,
        decoration: InputDecoration(
            labelText: t.maDescription, helperText: t.maDescriptionHelp, border: const OutlineInputBorder()),
      ),
      gap(),
      Text(t.maLastSeenTitle, style: text.titleSmall),
      gap(Gap.sm),
      OutlinedButton.icon(
        key: const ValueKey('ma-seen'),
        onPressed: _pickSeen,
        icon: const Icon(Icons.schedule_rounded),
        label: Text(maD(context, '${loc.formatMediumDate(_seen)}, ${loc.formatTimeOfDay(TimeOfDay.fromDateTime(_seen))}')),
      ),
      gap(Gap.sm),
      TextField(
        key: const ValueKey('ma-area'),
        controller: _area,
        maxLength: 120,
        decoration: InputDecoration(
            labelText: t.maAreaLabel,
            helperText: t.maAreaHelp,
            helperMaxLines: 3,
            errorText: _bad.contains('address') ? t.maErrAddress : _err('area_text', t.maRequired),
            border: const OutlineInputBorder()),
      ),
      gap(Gap.sm),
      DropdownButtonFormField<String>(
        key: const ValueKey('ma-district'),
        initialValue: _district.isEmpty ? null : _district,
        isExpanded: true,
        decoration: InputDecoration(
            labelText: t.maDistrict, errorText: _err('district', t.maRequired), border: const OutlineInputBorder()),
        items: [
          for (final d in districts)
            DropdownMenuItem(value: '${d['code']}', child: Text('${d['name']}')),
        ],
        onChanged: (v) => setState(() => _district = v ?? ''),
      ),
      SwitchListTile(
        key: const ValueKey('ma-here'),
        contentPadding: EdgeInsets.zero,
        value: _useHere,
        onChanged: _toggleHere,
        title: Text(t.maUseHere),
        subtitle: Text(t.maUseHereSub),
      ),
      gap(Gap.sm),
      Text(t.maRadiusTitle, style: text.titleSmall),
      gap(Gap.sm),
      Wrap(spacing: Gap.sm, children: [
        for (final r in radii)
          ChoiceChip(
            label: Text(maD(context, t.maRadiusKm(r))),
            selected: _radius == r,
            onSelected: (_) => setState(() => _radius = r),
          ),
      ]),
      gap(),
      if (_ageVal != null && !_isChild) ..._gdFields(context, adult: true),
      if (_isChild) ...[
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.maGuardianTitle, style: text.titleSmall),
              gap(Gap.xs),
              Text(verifiedParent ? t.maGuardianVerified : t.maGuardianNeedsV2),
              if (!verifiedParent) ...[
                gap(Gap.sm),
                if (cosigners.isEmpty)
                  Text(t.maGuardianNoCosignerV2, style: text.bodySmall)
                else
                  DropdownButtonFormField<int>(
                    key: const ValueKey('ma-cosigner'),
                    initialValue: _cosigner,
                    isExpanded: true,
                    decoration: InputDecoration(labelText: t.maCosignerPick, border: const OutlineInputBorder()),
                    items: [
                      for (final c in cosigners)
                        DropdownMenuItem(value: c['id'] as int, child: Text('${c['name']}')),
                    ],
                    onChanged: (v) => setState(() => _cosigner = v),
                  ),
                SwitchListTile(
                  key: const ValueKey('ma-child-gd'),
                  contentPadding: EdgeInsets.zero,
                  value: _childGd,
                  onChanged: (v) => setState(() => _childGd = v),
                  title: Text(t.maChildGdToggleV2),
                ),
              ],
            ]),
          ),
        ),
        gap(),
        if (_childGd && !verifiedParent) ..._gdFields(context, adult: false),
      ],
      CheckboxListTile(
        key: const ValueKey('ma-c1'),
        contentPadding: EdgeInsets.zero,
        value: _c1,
        onChanged: (v) => setState(() => _c1 = v == true),
        title: Text(t.maConfirmFamily),
        isError: _bad.contains('confirm_is_family'),
      ),
      CheckboxListTile(
        key: const ValueKey('ma-c2'),
        contentPadding: EdgeInsets.zero,
        value: _c2,
        onChanged: (v) => setState(() => _c2 = v == true),
        title: Text(t.maConfirmNoAddress),
        isError: _bad.contains('confirm_no_address'),
      ),
      CheckboxListTile(
        key: const ValueKey('ma-c3'),
        contentPadding: EdgeInsets.zero,
        value: _c3,
        onChanged: (v) => setState(() => _c3 = v == true),
        title: Text(t.maConfirmFalse),
        isError: _bad.contains('confirm_false_post'),
      ),
      gap(Gap.sm),
      const MaWhoGetsCard(),
      gap(),
      ConstrainedBox(constraints: const BoxConstraints(minHeight: 56),
        child: FilledButton.icon(
          key: const ValueKey('ma-submit'),
          onPressed: _busy ? null : _submit,
          icon: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.campaign_rounded),
          label: Text(t.maPostSubmit),
        ),
      ),
      gap(Gap.sm),
      Text(t.maPost999Line, style: text.bodySmall),
      const Align(alignment: Alignment.centerLeft, child: Ma999Button()),
    ];
  }

  List<Widget> _gdFields(BuildContext context, {required bool adult}) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final loc = MaterialLocalizations.of(context);
    return [
      Text(t.maGdTitleV2, style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: Gap.xs),
      Text(adult ? t.maGdAdultWhyV2 : t.maGdHelpV2, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: Gap.xs),
      Text(t.maGdUnverifiedV2, style: TextStyle(color: s.error, fontWeight: FontWeight.w600)),
      const SizedBox(height: Gap.sm),
      TextField(
        key: const ValueKey('ma-gd-number'),
        controller: _gdNum,
        decoration: InputDecoration(
            labelText: t.maGdNumberV2,
            helperText: t.maGdNumberHelp,
            errorText: _err('gd_number', t.maErrGdV2),
            border: const OutlineInputBorder()),
      ),
      const SizedBox(height: Gap.sm),
      TextField(
        key: const ValueKey('ma-gd-thana'),
        controller: _gdThana,
        decoration: InputDecoration(
            labelText: t.maGdThana, errorText: _err('gd_thana', t.maRequired), border: const OutlineInputBorder()),
      ),
      const SizedBox(height: Gap.sm),
      OutlinedButton.icon(
        onPressed: _pickGdDate,
        icon: const Icon(Icons.event_rounded),
        label: Text(maD(context, t.maGdDateV2(loc.formatMediumDate(_gdDate)))),
      ),
      if (_bad.contains('gd_date'))
        Text(t.maErrGdDateV2, style: TextStyle(color: s.error)),
      const SizedBox(height: Gap.md),
    ];
  }
}
