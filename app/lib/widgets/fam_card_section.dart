import 'dart:convert';

import 'package:flutter/material.dart';
import '../theme.dart';
import '../feature_gates.dart' show kMedicalFeaturesAllowed;
import '../l10n/app_localizations.dart';
import '../security/secret_store.dart';
import 'app_sheet.dart';
import 'circle_relation.dart' show CircleRelation;
import 'fam_empty.dart';
import 'fam_sharing_strings.dart';
import 'wrapped_share.dart';

/// #73 FAMILY CARD — famcare rebuild (owner decision 3, 28 Oct).
///
/// An emergency card for the family: blood group, emergency contacts (up to
/// 3), home address and the family members. It is SAVED ON THIS PHONE
/// (SecretStore — encrypted, no backup, falls back safely) so it opens with
/// no internet, and it is shared as an image or as plain text (SMS-able).
///
/// Before famcare the emergency fields were never saved (gone when you left
/// the tab), the "Print" button only shared a picture, and with no members the
/// tab was a dead end. Now every field persists, the members part has an
/// "add family" action, and the card works with emergency info alone.
class FamCardStore {
  static const _key = 'famcare_card_v1';

  static Future<Map<String, dynamic>> load() async {
    try {
      final s = await SecretStore.instance.read(_key);
      if (s == null || s.isEmpty) return {};
      final d = jsonDecode(s);
      return d is Map ? d.cast<String, dynamic>() : {};
    } catch (_) {
      return {};
    }
  }

  static Future<bool> save(Map<String, dynamic> data) async {
    try {
      return await SecretStore.instance.write(_key, jsonEncode(data));
    } catch (_) {
      return false;
    }
  }

  /// The family list as last seen online (so the card opens offline).
  static Future<void> cacheMembers(List<Map<String, dynamic>> members) async {
    final d = await load();
    d['members'] = [
      for (final m in members)
        {'name': '${m['name'] ?? ''}', 'relation': '${m['relation'] ?? ''}',
         'phone': '${m['phone'] ?? ''}'}
    ];
    await save(d);
  }
}

class FamCardSection extends StatefulWidget {
  /// null = offline: use the members cached on this phone.
  final List<Map<String, dynamic>>? members;
  final VoidCallback? onAddMember;
  const FamCardSection({super.key, required this.members, this.onAddMember});

  @override
  State<FamCardSection> createState() => _FamCardSectionState();
}

class _FamCardSectionState extends State<FamCardSection> {
  final GlobalKey _boundaryKey = GlobalKey();
  bool _dark = false;
  // Online (members known) the card renders at once; the saved emergency
  // info fills in when the phone store answers. Offline waits for the store.
  late bool _loaded = widget.members != null;
  Map<String, dynamic> _data = {};

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void didUpdateWidget(FamCardSection old) {
    super.didUpdateWidget(old);
    final m = widget.members;
    if (m != null && !identical(m, old.members)) FamCardStore.cacheMembers(m);
  }

  Future<void> _init() async {
    final d = await FamCardStore.load();
    if (mounted) setState(() { _data = d; _loaded = true; });
    final m = widget.members;
    if (m != null) await FamCardStore.cacheMembers(m);
  }

  List<Map<String, dynamic>> get _members => widget.members ??
      (_data['members'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();

  String _s(String k) => '${_data[k] ?? ''}'.trim();

  String get _blood => kMedicalFeaturesAllowed ? _s('blood') : '';

  List<Map<String, String>> get _contacts => (_data['contacts'] as List? ?? const [])
      .whereType<Map>()
      .map((e) => {'name': '${e['name'] ?? ''}'.trim(), 'phone': '${e['phone'] ?? ''}'.trim()})
      .where((e) => e['name']!.isNotEmpty || e['phone']!.isNotEmpty)
      .toList();

  bool get _hasEmergency => _blood.isNotEmpty || _s('address').isNotEmpty || _contacts.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (!_loaded) return const Center(child: CircularProgressIndicator());
    final members = _members;
    if (members.isEmpty && !_hasEmergency) {
      return FamEmptyState(
        icon: Icons.badge_rounded,
        title: t.fcCardEmptyTitle,
        benefit: t.fcCardEmptyBenefit,
        primaryLabel: t.fcCardFill,
        primaryIcon: Icons.edit_rounded,
        onPrimary: _editEmergency,
        secondaryLabel: widget.onAddMember == null ? null : t.fcPickFromCircle,
        onSecondary: widget.onAddMember,
        steps: [t.fcCardStep1, t.fcCardStep2, t.fcCardStep3],
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xl)),
      children: [
        Row(children: [
          Expanded(
            child: Text(famLabel(context, 'famCardTitle'),
                style: Theme.of(context).textTheme.titleLarge),
          ),
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: false, label: Text(famLabel(context, 'famCardLight'))),
              ButtonSegment(value: true, label: Text(famLabel(context, 'famCardDark'))),
            ],
            selected: {_dark},
            onSelectionChanged: (s) => setState(() => _dark = s.first),
          ),
        ]),
        const SizedBox(height: Gap.xs),
        Row(children: [
          Icon(Icons.offline_pin_rounded, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.xs),
          Expanded(
            child: Text(widget.members == null ? t.fcCardOfflineNow : t.fcCardSavedOnPhone,
                key: const ValueKey('fc-card-offline'),
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          ),
        ]),
        const SizedBox(height: Gap.md),
        RepaintBoundary(key: _boundaryKey, child: _card(members)),
        const SizedBox(height: Gap.md),
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          FilledButton.icon(
            key: const ValueKey('fc-card-edit'),
            onPressed: _editEmergency,
            icon: const Icon(Icons.edit_rounded),
            label: Text(famLabel(context, 'famCardEditEmergency')),
          ),
          OutlinedButton.icon(
            onPressed: _shareImage,
            icon: const Icon(Icons.image_rounded),
            label: Text(famLabel(context, 'famCardShareImage')),
          ),
          OutlinedButton.icon(
            key: const ValueKey('fc-card-text'),
            onPressed: _shareText,
            icon: const Icon(Icons.sms_rounded),
            label: Text(t.fcCardShareText),
          ),
          if (members.isEmpty && widget.onAddMember != null)
            OutlinedButton.icon(
              onPressed: widget.onAddMember,
              icon: const Icon(Icons.group_add_rounded),
              label: Text(t.fcPickFromCircle),
            ),
        ]),
      ],
    );
  }

  Widget _card(List<Map<String, dynamic>> members) {
    final t = AppLocalizations.of(context);
    // Fixed card colours (not theme) so the captured PNG is deterministic.
    final bg = _dark ? const Color(0xFF13161C) : Colors.white;
    final fg = _dark ? Colors.white : const Color(0xFF13161C);
    final sub = _dark ? Colors.white70 : Colors.black54;
    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: _dark ? Colors.white24 : Colors.black12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(Gap.lg),
          decoration: const BoxDecoration(
            gradient: Brand.gradient,
            borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.lg)),
          ),
          child: Row(children: [
            const Icon(Icons.family_restroom_rounded, color: Colors.white),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Text(famLabel(context, 'famCardMyFamily'),
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700, fontSize: 18)),
            ),
            if (members.isNotEmpty)
              Text(t.famCardMembers(famNum(context, members.length)),
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (_hasEmergency) ...[
              Text(famLabel(context, 'famCardEmergency'),
                  style: TextStyle(fontWeight: FontWeight.w700, color: fg)),
              const SizedBox(height: Gap.xs),
              if (_blood.isNotEmpty) _emRow(famLabel(context, 'famCardBlood'), _blood, fg, sub),
              for (final c in _contacts)
                _emRow(famLabel(context, 'famCardEmContact'),
                    [c['name']!, famDigits(context, c['phone']!)].where((s) => s.isNotEmpty).join(' · '),
                    fg, sub),
              if (_s('address').isNotEmpty)
                _emRow(famLabel(context, 'famCardAddress'), _s('address'), fg, sub),
              if (_s('notes').isNotEmpty) _emRow(t.fcCardNotes, _s('notes'), fg, sub),
              if (members.isNotEmpty)
                Divider(height: Gap.xl, color: _dark ? Colors.white24 : Colors.black12),
            ],
            for (final m in members) _memberRow(m, fg, sub),
          ]),
        ),
      ]),
    );
  }

  Widget _memberRow(Map<String, dynamic> m, Color fg, Color sub) {
    final t = AppLocalizations.of(context);
    final name = (m['name'] ?? '').toString();
    final r = '${m['relation'] ?? ''}'.trim();
    final rel = CircleRelation.catalog.any((c) => c.code == r) ? CircleRelation.labelFor(t, r) : r;
    final phone = famDigits(context, (m['phone'] ?? '').toString());
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Icon(Icons.person_outline_rounded, size: 18, color: sub),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
            if (rel.isNotEmpty || phone.isNotEmpty)
              Text([rel, phone].where((s) => s.isNotEmpty).join(' · '),
                  style: TextStyle(color: sub, fontSize: 13)),
          ]),
        ),
      ]),
    );
  }

  Widget _emRow(String label, String value, Color fg, Color sub) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: RichText(
          textScaler: MediaQuery.textScalerOf(context),
          text: TextSpan(children: [
            TextSpan(text: '$label: ', style: TextStyle(color: sub, fontSize: 14)),
            TextSpan(
                text: value,
                style: TextStyle(color: fg, fontSize: 14, fontWeight: FontWeight.w600)),
          ]),
        ),
      );

  /// Plain text for SMS / WhatsApp — works on any phone.
  String cardText() {
    final t = AppLocalizations.of(context);
    final b = StringBuffer(famLabel(context, 'famCardMyFamily'))..writeln();
    if (_blood.isNotEmpty) b.writeln('${famLabel(context, 'famCardBlood')}: $_blood');
    for (final c in _contacts) {
      b.writeln('${famLabel(context, 'famCardEmContact')}: '
          '${[c['name']!, c['phone']!].where((s) => s.isNotEmpty).join(' ')}');
    }
    if (_s('address').isNotEmpty) b.writeln('${famLabel(context, 'famCardAddress')}: ${_s('address')}');
    if (_s('notes').isNotEmpty) b.writeln('${t.fcCardNotes}: ${_s('notes')}');
    for (final m in _members) {
      b.writeln('• ${[m['name'], m['relation'], m['phone']].where((x) => '${x ?? ''}'.isNotEmpty).join(' · ')}');
    }
    return famDigits(context, b.toString().trim());
  }

  Future<void> _shareText() async {
    try {
      await WrappedShare.shareAsText(cardText());
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(famLabel(context, 'famCardShareFailed'))));
      }
    }
  }

  Future<void> _shareImage() async {
    final ok = await WrappedShare.shareAsImage(
        _boundaryKey, famLabel(context, 'famCardMyFamily'));
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(famLabel(context, 'famCardShareFailed'))));
    }
  }

  Future<void> _editEmergency() async {
    final saved = await showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _EmergencyForm(initial: _data),
    );
    if (saved == null) return;
    final next = {..._data, ...saved};
    final ok = await FamCardStore.save(next);
    if (!mounted) return;
    setState(() => _data = next);
    final t = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? t.fcCardSaved : t.fcCardSaveFailed)));
  }
}

class _EmergencyForm extends StatefulWidget {
  const _EmergencyForm({required this.initial});
  final Map<String, dynamic> initial;
  @override
  State<_EmergencyForm> createState() => _EmergencyFormState();
}

class _EmergencyFormState extends State<_EmergencyForm> {
  static const _groups = ['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'];
  late String _blood = '${widget.initial['blood'] ?? ''}';
  late final _address = TextEditingController(text: '${widget.initial['address'] ?? ''}');
  late final _notes = TextEditingController(text: '${widget.initial['notes'] ?? ''}');
  late final List<(TextEditingController, TextEditingController)> _contacts = [
    for (var i = 0; i < 3; i++)
      (
        TextEditingController(text: _c(i, 'name')),
        TextEditingController(text: _c(i, 'phone')),
      )
  ];

  String _c(int i, String k) {
    final l = widget.initial['contacts'];
    if (l is List && i < l.length && l[i] is Map) return '${(l[i] as Map)[k] ?? ''}';
    if (i == 0 && k == 'name') return '${widget.initial['em_name'] ?? ''}';
    return '';
  }

  @override
  void dispose() {
    _address.dispose();
    _notes.dispose();
    for (final c in _contacts) {
      c.$1.dispose();
      c.$2.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return AppSheetBody(
      primary: SizedBox(
        height: 52,
        child: FilledButton(
          key: const ValueKey('fc-card-save'),
          onPressed: () => Navigator.pop(context, {
            'blood': _blood,
            'address': _address.text.trim(),
            'notes': _notes.text.trim(),
            'contacts': [
              for (final c in _contacts)
                if (c.$1.text.trim().isNotEmpty || c.$2.text.trim().isNotEmpty)
                  {'name': c.$1.text.trim(), 'phone': c.$2.text.trim()}
            ],
          }),
          child: Text(t.save),
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(famLabel(context, 'famCardEditEmergency'),
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.xs),
        Text(t.fcCardPrivacyNote, style: AType.bodySmall),
        if (kMedicalFeaturesAllowed) ...[
          const SizedBox(height: Gap.md),
          Text(famLabel(context, 'famCardBlood'), style: AType.titleSmall),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            for (final g in _groups)
              ChoiceChip(
                label: Text(g),
                selected: _blood == g,
                onSelected: (on) => setState(() => _blood = on ? g : ''),
              ),
          ]),
        ],
        const SizedBox(height: Gap.md),
        Text(famLabel(context, 'famCardEmContact'), style: AType.titleSmall),
        for (var i = 0; i < _contacts.length; i++)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Row(children: [
              Expanded(
                  child: TextField(
                      key: ValueKey('fc-card-c$i-name'),
                      controller: _contacts[i].$1,
                      decoration: InputDecoration(labelText: t.name))),
              const SizedBox(width: Gap.sm),
              Expanded(
                  child: TextField(
                      key: ValueKey('fc-card-c$i-phone'),
                      controller: _contacts[i].$2,
                      keyboardType: TextInputType.phone,
                      decoration: InputDecoration(labelText: t.phoneOptional))),
            ]),
          ),
        const SizedBox(height: Gap.md),
        TextField(
            key: const ValueKey('fc-card-address'),
            controller: _address,
            maxLines: 2,
            decoration: InputDecoration(labelText: famLabel(context, 'famCardAddress'))),
        const SizedBox(height: Gap.sm),
        TextField(
            controller: _notes,
            maxLines: 2,
            decoration: InputDecoration(labelText: t.fcCardNotes, hintText: t.fcCardNotesHint)),
      ]),
    );
  }
}

/// The card on its own screen — opened from the Family screen's offline
/// state, so it shows with no internet at all.
class FamCardScreen extends StatelessWidget {
  const FamCardScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(famLabel(context, 'famShareTabCard'))),
        body: const FamCardSection(members: null),
      );
}
