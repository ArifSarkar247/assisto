import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:geolocator/geolocator.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../state.dart';
import '../theme.dart';
import '../feature_gates.dart' show kMedicalFeaturesAllowed;
import '../l10n/app_localizations.dart';
import '../widgets/emergency_card_view.dart';
import '../widgets/emergency_helplines.dart';
import '../widgets/emergency_first_aid.dart';
import '../widgets/emergency_nearest_help.dart';
import '../widgets/emergency_sos_panel.dart';
import '../famcare_api.dart'; // sosat: pick emergency numbers from My Circle
import '../widgets/circle_relation.dart';
import 'safety_screen.dart';
import 'package:assisto/widgets/app_sheet.dart';
import '../services/action_feedback.dart'; // db1

/// ADVANCED Emergency + SOS screen.
///
/// - A proper, high-contrast EMERGENCY CARD (blood group, allergies,
///   conditions, meds, doctor, insurance, NID ref, organ-donor, contacts) that
///   is editable, cached OFFLINE (shared_preferences), and shareable to a lock
///   screen as text OR image.
/// - One-tap SOS (calls 999 + alerts family with live location, countdown-
///   cancel, loud mode) via EmergencySosPanel.
/// - Verified BD helpline directory, nearest-help (reuses /nearby) and
///   source-named first-aid quick cards.
///
/// All strings via AppLocalizations. Bangla digits via the locale-digit helper
/// (code points) so no Bangla literal lives in this file.
class EmergencyScreen extends StatefulWidget {
  const EmergencyScreen({super.key});
  @override
  State<EmergencyScreen> createState() => _EmergencyScreenState();
}

class _EmergencyScreenState extends State<EmergencyScreen> {
  static const _cacheKey = 'emergency_card_cache';

  final _name = TextEditingController();
  final _blood = TextEditingController();
  final _allergies = TextEditingController();
  final _meds = TextEditingController();
  final _conditions = TextEditingController();
  final _doctor = TextEditingController();
  final _insurance = TextEditingController();
  final _nid = TextEditingController();
  bool _organDonor = false;
  List<Map<String, dynamic>> _contacts = [];

  final _cardKey = GlobalKey();

  bool _loading = true;
  bool _saving = false;
  bool _offline = false; // served from cache (no network)
  bool _editing = false;
  int _sosCountdown = 5;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _blood,
      _allergies,
      _meds,
      _conditions,
      _doctor,
      _insurance,
      _nid
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  // --- locale digit helper (Bangla numerals from code points; no literal) ---
  String _digits(String latin) {
    final name = AppLocalizations.of(context).localeName;
    if (!name.startsWith('bn')) return latin;
    const bnZero = 0x09E6;
    final b = StringBuffer();
    for (final ch in latin.runes) {
      if (ch >= 0x30 && ch <= 0x39) {
        b.writeCharCode(bnZero + (ch - 0x30));
      } else {
        b.writeCharCode(ch);
      }
    }
    return b.toString();
  }

  void _apply(Map<String, dynamic> c) {
    _name.text = '${c['name'] ?? ''}';
    _blood.text = '${c['blood_group'] ?? ''}';
    _allergies.text = '${c['allergies'] ?? ''}';
    _meds.text = '${c['medicines'] ?? ''}';
    _conditions.text = '${c['conditions'] ?? ''}';
    _doctor.text = '${c['doctor'] ?? ''}';
    _insurance.text = '${c['insurance'] ?? ''}';
    _nid.text = '${c['nid'] ?? ''}';
    _organDonor = c['organ_donor'] == true;
    _contacts = ((c['contacts'] ?? []) as List).cast<Map<String, dynamic>>();
  }

  Map<String, dynamic> _collect() => {
        'name': _name.text.trim(),
        'blood_group': _blood.text.trim(),
        'allergies': _allergies.text.trim(),
        'medicines': _meds.text.trim(),
        'conditions': _conditions.text.trim(),
        'doctor': _doctor.text.trim(),
        'insurance': _insurance.text.trim(),
        'nid': _nid.text.trim(),
        'organ_donor': _organDonor,
        'contacts': _contacts,
      };

  Future<void> _load() async {
    // Offline-first: show cache instantly, then refresh from the server.
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_cacheKey);
    if (cached != null) {
      try {
        _apply(jsonDecode(cached) as Map<String, dynamic>);
        _offline = true;
      } catch (_) {} // best-effort: corrupt cache is ignored; the server copy loads next
    }
    _sosCountdown = int.tryParse(await Settings.getString('safety_sos_cd') ?? '') ?? 5;
    try {
      final c = await context.read<AppState>().api.getEmergency();
      _apply(c);
      _offline = false;
      await prefs.setString(_cacheKey, jsonEncode(_collect()));
    } catch (_) {
      // best-effort: keep whatever cache we had; _offline stays true if we had cache,
      // and empty state shows if we didn't.
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    final body = _collect();
    // Always persist to the offline cache first so the card survives offline.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cacheKey, jsonEncode(body));
    try {
      await context.read<AppState>().api.putEmergency(body);
      _offline = false;
      messenger.showSnackBar(SnackBar(content: Text(t.emergencySaved)));
    } catch (_) {
      _offline = true;
      messenger.showSnackBar(SnackBar(content: Text(t.emergencySavedOffline)));
    } finally {
      if (mounted) setState(() {
        _saving = false;
        _editing = false;
      });
    }
  }

  Future<void> _call(String phone) async {
    // db1: an emergency call that cannot start must SAY so, never stay silent.
    await openForUser(context, Uri.parse('tel:$phone'), where: 'emergency.call');
  }

  // Build the shareable plain-text (mirrors safety.emergency_card_text order).
  String _cardText() {
    final t = AppLocalizations.of(context);
    final lines = <String>[t.emergencyCardBanner];
    void add(String label, String v) {
      if (v.trim().isNotEmpty) lines.add('$label: ${v.trim()}');
    }

    // play-nomed: no medical record in the Play flavour's shared card.
    final med = kMedicalFeaturesAllowed;
    add(t.name, _name.text);
    if (med) {
      add(t.emergencyBloodGroup, _blood.text);
      add(t.emergencyAllergies, _allergies.text);
      add(t.emergencyConditions, _conditions.text);
      add(t.emergencyMedicines, _meds.text);
      add(t.emergencyDoctor, _doctor.text);
      add(t.emergencyInsurance, _insurance.text);
    }
    add(t.emergencyNid, _nid.text);
    if (med && _organDonor) {
      lines.add('${t.emergencyOrganDonor}: ${t.emergencyYes}');
    }
    final callable =
        _contacts.where((c) => '${c['phone'] ?? ''}'.trim().isNotEmpty);
    if (callable.isNotEmpty) {
      lines.add('${t.emergencyContactTitle}:');
      for (final c in callable) {
        final nm = '${c['name'] ?? ''}'.trim();
        final rel = '${c['relation'] ?? ''}'.trim();
        final who = nm + (rel.isNotEmpty && rel != nm ? ' ($rel)' : '');
        lines.add('  • ${who.isEmpty ? '' : '$who — '}${c['phone']}');
      }
    }
    return lines.join('\n');
  }

  Future<void> _shareCard() async {
    final t = AppLocalizations.of(context);
    final choice = await showAppSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.image_rounded),
            title: Text(t.emergencyShareAsImage),
            onTap: () => Navigator.pop(ctx, 'image'),
          ),
          ListTile(
            leading: const Icon(Icons.text_snippet_rounded),
            title: Text(t.emergencyShareAsText),
            onTap: () => Navigator.pop(ctx, 'text'),
          ),
        ]),
      ),
    );
    if (choice == null) return;
    if (choice == 'text') {
      await EmergencyCardView.shareAsText(_cardText());
    } else {
      final ok = await EmergencyCardView.shareAsImage(_cardKey, _cardText());
      if (!ok) await EmergencyCardView.shareAsText(_cardText());
    }
  }

  Future<void> _shareLocation() async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        messenger.showSnackBar(SnackBar(content: Text(t.locationOff)));
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        messenger.showSnackBar(SnackBar(content: Text(t.locationNeeded)));
        return;
      }
      final pos = await Geolocator.getCurrentPosition();
      await Share.share(t.sosShareText(
          'https://maps.google.com/?q=${pos.latitude},${pos.longitude}'));
    } catch (_) {
      // sosat: never a raw (English) exception text on screen
      messenger.showSnackBar(SnackBar(content: Text(t.saLocationFailed)));
    }
  }

  /// sosat: emergency numbers come from My Circle in ONE tap (nobody is
  /// typed twice); "Add by hand" stays for someone outside the circle. A
  /// picked or typed number is SAVED at once (it used to need a separate
  /// Save tap and was lost when the screen was left).
  Future<void> _addContact() async {
    final t = AppLocalizations.of(context);
    final picked = await showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CirclePickSheet(
          already: {for (final c in _contacts) '${c['phone'] ?? ''}'.trim()}),
    );
    if (!mounted || picked == null) return;
    if (picked['hand'] == true) {
      await _addByHand();
      return;
    }
    final phone = '${picked['phone'] ?? ''}'.trim();
    if (phone.isEmpty || _contacts.any((c) => '${c['phone'] ?? ''}'.trim() == phone)) return;
    setState(() {
      _contacts.add({
        'name': '${picked['name'] ?? ''}',
        'phone': phone,
        'relation': CircleRelation.labelFor(t, '${picked['relation'] ?? ''}',
            custom: '${picked['custom_label'] ?? ''}'),
      });
    });
    await _save();
  }

  Future<void> _addByHand() async {
    final t = AppLocalizations.of(context);
    final name = TextEditingController();
    final phone = TextEditingController();
    final rel = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        title: Text(t.emergencyContactTitle),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: name,
              decoration: InputDecoration(labelText: t.name)),
          TextField(
              controller: phone,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(labelText: t.phone)),
          TextField(
              controller: rel,
              decoration:
                  InputDecoration(labelText: t.familyRelationLabel)),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: Text(t.add)),
        ],
      ),
    );
    if (ok == true && phone.text.trim().isNotEmpty) {
      setState(() {
        _contacts.add({
          'name': name.text.trim(),
          'phone': phone.text.trim(),
          'relation': rel.text.trim()
        });
      });
      await _save(); // sosat: saved at once
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(t.emergencyCard)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(t.emergencyCard), actions: [
        IconButton(
          tooltip: t.emergencyShare,
          onPressed: _shareCard,
          icon: const Icon(Icons.ios_share_rounded),
        ),
        _saving
            ? const Padding(
                padding: EdgeInsets.all(14),
                child: SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2)))
            : IconButton(
                tooltip: _editing ? t.save : t.edit,
                onPressed: _editing
                    ? _save
                    : () => setState(() => _editing = true),
                icon: Icon(_editing ? Icons.save_rounded : Icons.edit_rounded),
              ),
      ]),
      body: ListView(padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)), children: [
        if (_offline)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm),
            child: Row(children: [
              const Icon(Icons.cloud_off_rounded, size: 16, color: Colors.grey),
              const SizedBox(width: Gap.xs),
              Expanded(
                  child: Text(t.emergencyOfflineBadge,
                      style: AType.bodySmall.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant))),
            ]),
          ),

        // ---- one-tap SOS ----
        EmergencySosPanel(
          contacts: _contacts,
          countdownSeconds: _sosCountdown,
          // sosat: SOS no longer needs a saved number (it goes to My
          // Circle); after it, this adds numbers for the Call/SMS steps.
          onNoContact: _addContact,
        ),
        const SizedBox(height: Gap.sm),
        // QA a6: side-by-side these wrapped to 3 lines in Bangla and the text
        // spilled outside the pill. Full-width, stacked.
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              padding: const EdgeInsets.symmetric(
                  horizontal: Gap.lg, vertical: Gap.sm)),
          onPressed: _shareLocation,
          icon: const Icon(Icons.my_location_rounded, size: 18),
          label: Text(t.shareMyLocation, textAlign: TextAlign.center),
        ),
        const SizedBox(height: Gap.sm),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              padding: const EdgeInsets.symmetric(
                  horizontal: Gap.lg, vertical: Gap.sm)),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const SafetyScreen())),
          icon: const Icon(Icons.health_and_safety_rounded, size: 18),
          label: Text(t.safetyToolsButton, textAlign: TextAlign.center),
        ),

        const Divider(height: Gap.xxl),

        // ---- the emergency card (preview or editor) ----
        _sectionTitle(t.emergencyCardSection),
        const SizedBox(height: Gap.sm),
        if (_editing) _editor(t) else _preview(t),

        const Divider(height: Gap.xxl),

        // ---- verified helpline directory ----
        _sectionTitle(t.emergencyHelplinesSection),
        const SizedBox(height: Gap.sm),
        EmergencyHelplineList(onCall: _call, localeDigits: _digits),

        const Divider(height: Gap.xxl),

        // ---- nearest help ----
        _sectionTitle(t.emergencyNearestSection),
        const SizedBox(height: Gap.sm),
        const EmergencyNearestHelp(),

        const Divider(height: Gap.xxl),

        // ---- first-aid quick cards ----
        // play-nomed: first-aid guidance is medical advice — not in Play.
        if (kMedicalFeaturesAllowed) ...[
          _sectionTitle(t.emergencyFirstAidSection),
          const SizedBox(height: Gap.sm),
          FirstAidList(localeDigits: _digits),
        ],

        const SizedBox(height: Gap.lg),
        Text(t.emergencyFooterNote,
            style: AType.bodySmall.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ]),
    );
  }

  Widget _sectionTitle(String s) =>
      Text(s, style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700));

  Widget _preview(AppLocalizations t) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      EmergencyCardView(
        boundaryKey: _cardKey,
        name: _name.text,
        bloodGroup: _blood.text,
        allergies: _allergies.text,
        conditions: _conditions.text,
        medicines: _meds.text,
        doctor: _doctor.text,
        insurance: _insurance.text,
        nid: _nid.text,
        organDonor: _organDonor,
        contacts: _contacts,
      ),
      const SizedBox(height: Gap.sm),
      Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => setState(() => _editing = true),
            icon: const Icon(Icons.edit_rounded, size: 18),
            label: Text(t.edit),
          ),
        ),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: FilledButton.tonalIcon(
            onPressed: _shareCard,
            icon: const Icon(Icons.ios_share_rounded, size: 18),
            label: Text(t.emergencyShare),
          ),
        ),
      ]),
    ]);
  }

  Widget _editor(AppLocalizations t) {
    InputDecoration dec(String l) => InputDecoration(labelText: l);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(controller: _name, decoration: dec(t.name)),
      const SizedBox(height: Gap.sm),
      // play-nomed: the medical-record fields (blood group .. organ donor) are
      // edited only where medical features are allowed (not in Play). Their
      // stored values are kept untouched on save.
      if (kMedicalFeaturesAllowed) ...[
        TextField(controller: _blood, decoration: dec(t.emergencyBloodGroup)),
        const SizedBox(height: Gap.sm),
        TextField(
            controller: _allergies,
            maxLines: 2,
            decoration: dec(t.emergencyAllergies)),
        const SizedBox(height: Gap.sm),
        TextField(
            controller: _conditions,
            maxLines: 2,
            decoration: dec(t.emergencyConditions)),
        const SizedBox(height: Gap.sm),
        TextField(
            controller: _meds, maxLines: 2, decoration: dec(t.emergencyMedicines)),
        const SizedBox(height: Gap.sm),
        TextField(controller: _doctor, decoration: dec(t.emergencyDoctor)),
        const SizedBox(height: Gap.sm),
        TextField(controller: _insurance, decoration: dec(t.emergencyInsurance)),
        const SizedBox(height: Gap.sm),
      ],
      TextField(controller: _nid, decoration: dec(t.emergencyNid)),
      if (kMedicalFeaturesAllowed)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _organDonor,
          onChanged: (v) => setState(() => _organDonor = v),
          title: Text(t.emergencyOrganDonor),
        ),
      const SizedBox(height: Gap.sm),
      Row(children: [
        Text(t.emergencyContactTitle,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        const Spacer(),
        TextButton.icon(
            onPressed: _addContact,
            icon: const Icon(Icons.add_rounded),
            label: Text(t.add)),
      ]),
      for (int i = 0; i < _contacts.length; i++)
        Card(
          margin: const EdgeInsets.only(bottom: Gap.xs),
          child: ListTile(
            title: Text('${_contacts[i]['name'] ?? ''}'),
            subtitle:
                Text('${_digits('${_contacts[i]['phone']}')} · ${_contacts[i]['relation'] ?? ''}'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(tooltip: AppLocalizations.of(context).call,
                  icon: const Icon(Icons.call_rounded, color: Brand.success),
                  onPressed: () => _call('${_contacts[i]['phone']}')),
              IconButton(tooltip: MaterialLocalizations.of(context).deleteButtonTooltip,
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () =>
                      setState(() => _contacts.removeAt(i))),
            ]),
          ),
        ),
      const SizedBox(height: Gap.sm),
      Row(children: [
        Expanded(
          child: OutlinedButton(
            onPressed: () => setState(() {
              _editing = false;
              _load(); // discard unsaved edits by reloading
            }),
            child: Text(t.cancel),
          ),
        ),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save_rounded, size: 18),
            label: Text(t.save),
          ),
        ),
      ]),
    ]);
  }
}


/// sosat: My Circle members who have a phone number, one tap each.
class _CirclePickSheet extends StatefulWidget {
  const _CirclePickSheet({required this.already});
  final Set<String> already;
  @override
  State<_CirclePickSheet> createState() => _CirclePickSheetState();
}

class _CirclePickSheetState extends State<_CirclePickSheet> {
  List<Map<String, dynamic>>? _rows;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final r = await context.read<AppState>().api.famCirclePick();
      if (!mounted) return;
      setState(() => _rows = famPickRows(r)
          .where((e) => '${e['phone'] ?? ''}'.trim().isNotEmpty)
          .toList());
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    Widget body;
    if (_failed) {
      body = Column(mainAxisSize: MainAxisSize.min, children: [
        Text(t.loadFailed, textAlign: TextAlign.center),
        const SizedBox(height: Gap.md),
        FilledButton.icon(
            onPressed: _load, icon: const Icon(Icons.refresh_rounded), label: Text(t.retry)),
      ]);
    } else if (_rows == null) {
      body = const Padding(
          padding: EdgeInsets.all(Gap.xl), child: Center(child: CircularProgressIndicator()));
    } else if (_rows!.isEmpty) {
      body = Text(t.saPickCircleEmpty,
          key: const ValueKey('sosat-pick-empty'),
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant));
    } else {
      body = Column(mainAxisSize: MainAxisSize.min, children: [
        for (final r in _rows!)
          ListTile(
            key: ValueKey('sosat-pick-${r['circle_id']}'),
            minTileHeight: 56,
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
                child: Text(('${r['name'] ?? ''}'.trim().isEmpty
                        ? '?'
                        : '${r['name']}'.trim()[0])
                    .toUpperCase())),
            title: Text('${r['name'] ?? ''}'),
            subtitle: Text(CircleRelation.labelFor(t, '${r['relation'] ?? ''}',
                custom: '${r['custom_label'] ?? ''}')),
            trailing: widget.already.contains('${r['phone']}'.trim())
                ? Semantics(
                    label: t.fcAlreadyAdded,
                    child: const Icon(Icons.check_circle_rounded, color: Brand.success))
                : const Icon(Icons.add_circle_outline_rounded),
            onTap: widget.already.contains('${r['phone']}'.trim())
                ? null
                : () => Navigator.pop(context, r),
          ),
      ]);
    }
    return AppSheetBody(
      primary: SizedBox(
        height: 48,
        child: OutlinedButton.icon(
            key: const ValueKey('sosat-pick-hand'),
            onPressed: () => Navigator.pop(context, <String, dynamic>{'hand': true}),
            icon: const Icon(Icons.person_add_alt_rounded),
            label: Text(t.fcAddByHand)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.saPickCircleTitle,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.xs),
        Text(t.saPickCircleSub, style: TextStyle(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.md),
        body,
      ]),
    );
  }
}
