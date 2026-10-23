import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
import '../../services/error_kind.dart' show honestFailText; // qa2

/// PA Secretary Mode · CELEBRITY tier — Personal lifestyle manager (#125, §14).
///
/// A private, on-device lifestyle organiser for a public figure's PA:
/// APPOINTMENTS (salon/gym/wellness/stylist/spa — place, date/time, split into
/// upcoming/past), standing PREFERENCES (grouped by topic), daily ROUTINES
/// (grouped by morning→night slot). Deterministic; conservative privacy —
/// nothing is shared, published or geolocated. Reminders are a documented,
/// opt-in seam that never sends on its own.
///
/// Mirrors backend/core/logic/pa_lifestyle.py. ZERO Bangla literals.
/// Endpoints: listItems('star/lifestyle') / createItem / updateItem / delete.
/// Rows tagged {kind: 'appt' | 'pref' | 'routine'}.
class LifestyleScreen extends StatefulWidget {
  const LifestyleScreen({super.key});
  @override
  State<LifestyleScreen> createState() => _LifestyleScreenState();
}

// ---- constants (mirror pa_lifestyle.py) -----------------------------------
const String _kAppt = 'appt';
const String _kPref = 'pref';
const String _kRoutine = 'routine';

const List<String> _apptCats = [
  'salon', 'gym', 'wellness', 'stylist', 'spa', 'other'
];
const List<String> _slots = ['morning', 'afternoon', 'evening', 'night'];

class _LifestyleScreenState extends State<LifestyleScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true, _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

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
    try {
      _rows = await context.read<AppState>().api.listItems('star/lifestyle');
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  // ---- mirror helpers ------------------------------------------------------
  String _kind(Map<String, dynamic> r) => (r['kind'] ?? _kAppt).toString();

  String _cat(Map<String, dynamic> r) {
    final v = (r['category'] ?? '').toString().toLowerCase();
    return _apptCats.contains(v) ? v : 'other';
  }

  String _slot(Map<String, dynamic> r) {
    final v = (r['slot'] ?? '').toString().toLowerCase();
    return _slots.contains(v) ? v : 'morning';
  }

  DateTime? _parseAt(Map<String, dynamic> r) {
    final s = (r['at'] ?? '').toString().trim();
    if (s.isEmpty) return null;
    return DateTime.tryParse(s.endsWith('Z') ? s.substring(0, s.length - 1) : s);
  }

  List<Map<String, dynamic>> get _appts {
    final list = _rows.where((r) => _kind(r) == _kAppt).toList();
    list.sort((a, b) {
      final da = _parseAt(a);
      final db = _parseAt(b);
      final ka = da?.toIso8601String() ?? '9999';
      final kb = db?.toIso8601String() ?? '9999';
      return ka.compareTo(kb);
    });
    return list;
  }

  List<Map<String, dynamic>> get _prefs =>
      _rows.where((r) => _kind(r) == _kPref && (r['text'] ?? '').toString().trim().isNotEmpty).toList();

  List<Map<String, dynamic>> get _routines =>
      _rows.where((r) => _kind(r) == _kRoutine).toList();

  // ---- actions -------------------------------------------------------------
  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _addOrEdit(AppLocalizations tr, String kind,
      {Map<String, dynamic>? existing}) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _LifestyleForm(kind: kind, existing: existing),
    );
    if (result == null) return;
    try {
      if (existing != null && existing['id'] is int) {
        await context.read<AppState>().api.updateItem('star/lifestyle', existing['id'] as int, result);
      } else {
        await context.read<AppState>().api.createItem('star/lifestyle', result);
      }
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _delete(Map<String, dynamic> r, AppLocalizations tr) async {
    final id = r['id'];
    try {
      if (id is int) await context.read<AppState>().api.deleteItem('star/lifestyle', id);
      await _load();
    } catch (_) {
      if (mounted) _toast(tr.deleteFailed);
    }
  }

  // ---- build ---------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr.lifestyleTitle),
        bottom: TabBar(controller: _tabs, tabs: [
          Tab(text: tr.lifestyleTabAppts),
          Tab(text: tr.lifestyleTabPrefs),
          Tab(text: tr.lifestyleTabRoutines),
        ]),
      ),
      floatingActionButton: _loading || _error
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _addOrEdit(
                  tr, [_kAppt, _kPref, _kRoutine][_tabs.index]),
              icon: const Icon(Icons.add),
              label: Text(tr.lifestyleAdd),
            ),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off,
                  tint: scheme.error,
                  title: tr.loadFailed,
                  message: honestFailText(tr, _failCause, otherwise: tr.lifestyleLoadError),
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: Text(tr.retry)),
                )
              : TabBarView(controller: _tabs, children: [
                  _apptsTab(tr, scheme),
                  _prefsTab(tr, scheme),
                  _routinesTab(tr, scheme),
                ]),
    );
  }

  // ---- appointments tab ----------------------------------------------------
  Widget _apptsTab(AppLocalizations tr, ColorScheme scheme) {
    final list = _appts;
    if (list.isEmpty) {
      return _welcome(tr, Icons.spa_outlined, tr.lifestyleWelcomeTitle,
          tr.lifestyleWelcomeBody, _kAppt, true);
    }
    final now = DateTime.now();
    final upcoming = list.where((r) {
      final at = _parseAt(r);
      return at == null || !at.isBefore(now);
    }).toList();
    final past = list.where((r) {
      final at = _parseAt(r);
      return at != null && at.isBefore(now);
    }).toList();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
        children: [
          _privacyNote(tr, scheme),
          const SizedBox(height: Gap.md),
          if (upcoming.isNotEmpty) ...[
            _sectionLabel(tr.lifestyleUpcoming('${upcoming.length}'), scheme),
            for (final r in upcoming) _apptCard(r, tr, scheme, false),
          ],
          if (past.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            _sectionLabel(tr.lifestylePast('${past.length}'), scheme),
            for (final r in past) _apptCard(r, tr, scheme, true),
          ],
        ],
      ),
    );
  }

  Widget _privacyNote(AppLocalizations tr, ColorScheme scheme) => Container(
        padding: const EdgeInsets.all(Gap.sm),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        child: Row(children: [
          Icon(Icons.lock_outline, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(tr.lifestylePrivacyNote,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12, height: 1.3)),
          ),
        ]),
      );

  Widget _apptCard(Map<String, dynamic> r, AppLocalizations tr, ColorScheme scheme, bool past) {
    final cat = _cat(r);
    final title = (r['title'] ?? '').toString();
    final place = (r['place'] ?? '').toString().trim();
    final at = (r['at'] ?? '').toString().trim();
    final note = (r['note'] ?? '').toString().trim();
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(_catIcon(cat), size: 18,
                color: past ? scheme.onSurfaceVariant : scheme.primary),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(title,
                  style: TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 14,
                      color: past ? scheme.onSurfaceVariant : scheme.onSurface),
                  maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
            _pill(_catLabel(tr, cat), scheme.primary),
            _menu(r, tr, _kAppt),
          ]),
          const SizedBox(height: 2),
          Wrap(spacing: Gap.md, runSpacing: Gap.xs, children: [
            if (at.isNotEmpty) _meta(Icons.schedule, at, scheme),
            if (place.isNotEmpty) _meta(Icons.place_outlined, place, scheme),
          ]),
          if (note.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Text(note,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5, height: 1.3),
                maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
        ]),
      ),
    );
  }

  // ---- preferences tab -----------------------------------------------------
  Widget _prefsTab(AppLocalizations tr, ColorScheme scheme) {
    final list = _prefs;
    if (list.isEmpty) {
      return _welcome(tr, Icons.favorite_outline, tr.lifestyleNoPrefsTitle,
          tr.lifestyleNoPrefsBody, _kPref, false);
    }
    // group by topic
    final topics = <String, List<Map<String, dynamic>>>{};
    for (final r in list) {
      final t = (r['topic'] ?? '').toString().trim();
      topics.putIfAbsent(t.isEmpty ? '' : t, () => []).add(r);
    }
    final keys = topics.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
        children: [
          for (final k in keys) ...[
            _sectionLabel(k.isEmpty ? tr.lifestyleTopicGeneral : k, scheme),
            for (final r in topics[k]!)
              Card(
                margin: const EdgeInsets.only(bottom: Gap.xs),
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.check_circle_outline),
                  title: Text((r['text'] ?? '').toString()),
                  trailing: _menu(r, tr, _kPref),
                ),
              ),
          ],
        ],
      ),
    );
  }

  // ---- routines tab --------------------------------------------------------
  Widget _routinesTab(AppLocalizations tr, ColorScheme scheme) {
    final list = _routines;
    if (list.isEmpty) {
      return _welcome(tr, Icons.schedule_outlined, tr.lifestyleNoRoutinesTitle,
          tr.lifestyleNoRoutinesBody, _kRoutine, false);
    }
    final buckets = <String, List<Map<String, dynamic>>>{for (final s in _slots) s: []};
    for (final r in list) {
      buckets[_slot(r)]!.add(r);
    }
    for (final b in buckets.values) {
      b.sort((a, b) {
        final ta = (a['time'] ?? '').toString();
        final tb = (b['time'] ?? '').toString();
        if (ta.isEmpty && tb.isEmpty) return 0;
        if (ta.isEmpty) return 1;
        if (tb.isEmpty) return -1;
        return ta.compareTo(tb);
      });
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
        children: [
          for (final s in _slots)
            if (buckets[s]!.isNotEmpty) ...[
              _sectionLabel(_slotLabel(tr, s), scheme),
              for (final r in buckets[s]!)
                Card(
                  margin: const EdgeInsets.only(bottom: Gap.xs),
                  child: ListTile(
                    dense: true,
                    leading: Text((r['time'] ?? '').toString().trim().isEmpty
                        ? '—'
                        : (r['time']).toString().trim(),
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                    title: Text((r['label'] ?? '').toString(),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: _menu(r, tr, _kRoutine),
                  ),
                ),
            ],
        ],
      ),
    );
  }

  // ---- shared --------------------------------------------------------------
  Widget _welcome(AppLocalizations tr, IconData icon, String title, String body,
          String kind, bool withPrivacy) =>
      ListView(
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          const SizedBox(height: Gap.xl),
          StateMessage(
            icon: icon,
            title: title,
            message: body,
            action: FilledButton.icon(
              onPressed: () => _addOrEdit(tr, kind),
              icon: const Icon(Icons.add),
              label: Text(tr.lifestyleAdd),
            ),
          ),
          if (withPrivacy) ...[
            const SizedBox(height: Gap.lg),
            _privacyNote(tr, Theme.of(context).colorScheme),
          ],
        ],
      );

  Widget _menu(Map<String, dynamic> r, AppLocalizations tr, String kind) =>
      PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert),
        onSelected: (v) {
          if (v == 'edit') _addOrEdit(tr, kind, existing: r);
          if (v == 'delete') _delete(r, tr);
        },
        itemBuilder: (_) => [
          PopupMenuItem(value: 'edit', child: Text(tr.edit)),
          PopupMenuItem(value: 'delete', child: Text(tr.delete)),
        ],
      );

  Widget _sectionLabel(String text, ColorScheme scheme) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.sm, top: 2),
        child: Text(text,
            style: TextStyle(
                color: scheme.onSurfaceVariant, fontWeight: FontWeight.w700, fontSize: 13)),
      );

  Widget _meta(IconData icon, String text, ColorScheme scheme) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: scheme.onSurfaceVariant),
        const SizedBox(width: 3),
        Flexible(
          child: Text(text,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
              maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ]);

  Widget _pill(String text, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Text(text,
            style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w700)),
      );

  IconData _catIcon(String c) {
    switch (c) {
      case 'salon':
        return Icons.content_cut;
      case 'gym':
        return Icons.fitness_center;
      case 'wellness':
        return Icons.self_improvement;
      case 'stylist':
        return Icons.checkroom;
      case 'spa':
        return Icons.spa_outlined;
      default:
        return Icons.event_outlined;
    }
  }

  String _catLabel(AppLocalizations tr, String c) {
    switch (c) {
      case 'salon':
        return tr.lifestyleCatSalon;
      case 'gym':
        return tr.lifestyleCatGym;
      case 'wellness':
        return tr.lifestyleCatWellness;
      case 'stylist':
        return tr.lifestyleCatStylist;
      case 'spa':
        return tr.lifestyleCatSpa;
      default:
        return tr.lifestyleCatOther;
    }
  }

  String _slotLabel(AppLocalizations tr, String s) {
    switch (s) {
      case 'afternoon':
        return tr.lifestyleSlotAfternoon;
      case 'evening':
        return tr.lifestyleSlotEvening;
      case 'night':
        return tr.lifestyleSlotNight;
      default:
        return tr.lifestyleSlotMorning;
    }
  }
}

/// Add / edit an appointment, preference, or routine.
class _LifestyleForm extends StatefulWidget {
  final String kind;
  final Map<String, dynamic>? existing;
  const _LifestyleForm({required this.kind, this.existing});
  @override
  State<_LifestyleForm> createState() => _LifestyleFormState();
}

class _LifestyleFormState extends State<_LifestyleForm> {
  late final Map<String, TextEditingController> _c = {
    'title': TextEditingController(text: widget.existing?['title']?.toString() ?? ''),
    'place': TextEditingController(text: widget.existing?['place']?.toString() ?? ''),
    'at': TextEditingController(text: widget.existing?['at']?.toString() ?? ''),
    'note': TextEditingController(text: widget.existing?['note']?.toString() ?? ''),
    'topic': TextEditingController(text: widget.existing?['topic']?.toString() ?? ''),
    'text': TextEditingController(text: widget.existing?['text']?.toString() ?? ''),
    'label': TextEditingController(text: widget.existing?['label']?.toString() ?? ''),
    'time': TextEditingController(text: widget.existing?['time']?.toString() ?? ''),
  };
  late String _cat = _apptCats.contains((widget.existing?['category'] ?? '').toString())
      ? widget.existing!['category'].toString()
      : 'salon';
  late String _slot = _slots.contains((widget.existing?['slot'] ?? '').toString())
      ? widget.existing!['slot'].toString()
      : 'morning';

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _catLabel(AppLocalizations tr, String c) {
    switch (c) {
      case 'salon':
        return tr.lifestyleCatSalon;
      case 'gym':
        return tr.lifestyleCatGym;
      case 'wellness':
        return tr.lifestyleCatWellness;
      case 'stylist':
        return tr.lifestyleCatStylist;
      case 'spa':
        return tr.lifestyleCatSpa;
      default:
        return tr.lifestyleCatOther;
    }
  }

  String _slotLabel(AppLocalizations tr, String s) {
    switch (s) {
      case 'afternoon':
        return tr.lifestyleSlotAfternoon;
      case 'evening':
        return tr.lifestyleSlotEvening;
      case 'night':
        return tr.lifestyleSlotNight;
      default:
        return tr.lifestyleSlotMorning;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final isAppt = widget.kind == _kAppt;
    final isPref = widget.kind == _kPref;
    final valid = isAppt
        ? _c['title']!.text.trim().isNotEmpty
        : isPref
            ? _c['text']!.text.trim().isNotEmpty
            : _c['label']!.text.trim().isNotEmpty;

    String title() {
      if (widget.existing != null) return tr.lifestyleEdit;
      if (isAppt) return tr.lifestyleAddAppt;
      if (isPref) return tr.lifestyleAddPref;
      return tr.lifestyleAddRoutine;
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title(), style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Gap.lg),
          if (isAppt) ...[
            Text(tr.lifestyleCategoryLabel, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: Gap.xs),
            Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
              for (final c in _apptCats)
                ChoiceChip(
                  label: Text(_catLabel(tr, c)),
                  selected: _cat == c,
                  onSelected: (_) => setState(() => _cat = c),
                ),
            ]),
            const SizedBox(height: Gap.md),
            TextField(
              controller: _c['title'],
              onChanged: (_) => setState(() {}),
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: tr.lifestyleApptTitleField, border: const OutlineInputBorder()),
            ),
            const SizedBox(height: Gap.md),
            TextField(
              controller: _c['place'],
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(labelText: tr.lifestylePlaceField, border: const OutlineInputBorder()),
            ),
            const SizedBox(height: Gap.md),
            TextField(
              controller: _c['at'],
              decoration: InputDecoration(labelText: tr.lifestyleAtField, hintText: 'YYYY-MM-DD HH:MM', border: const OutlineInputBorder()),
            ),
            const SizedBox(height: Gap.md),
            TextField(
              controller: _c['note'],
              maxLines: 2,
              decoration: InputDecoration(labelText: tr.lifestyleNoteField, border: const OutlineInputBorder(), alignLabelWithHint: true),
            ),
          ] else if (isPref) ...[
            TextField(
              controller: _c['topic'],
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: tr.lifestyleTopicField, border: const OutlineInputBorder()),
            ),
            const SizedBox(height: Gap.md),
            TextField(
              controller: _c['text'],
              maxLines: 3,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(labelText: tr.lifestylePrefTextField, border: const OutlineInputBorder(), alignLabelWithHint: true),
            ),
          ] else ...[
            Text(tr.lifestyleSlotLabel, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: Gap.xs),
            Wrap(spacing: Gap.sm, children: [
              for (final s in _slots)
                ChoiceChip(
                  label: Text(_slotLabel(tr, s)),
                  selected: _slot == s,
                  onSelected: (_) => setState(() => _slot = s),
                ),
            ]),
            const SizedBox(height: Gap.md),
            TextField(
              controller: _c['label'],
              onChanged: (_) => setState(() {}),
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: tr.lifestyleRoutineLabelField, border: const OutlineInputBorder()),
            ),
            const SizedBox(height: Gap.md),
            TextField(
              controller: _c['time'],
              decoration: InputDecoration(labelText: tr.lifestyleTimeField, hintText: 'HH:MM', border: const OutlineInputBorder()),
            ),
          ],
          const SizedBox(height: Gap.lg),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                child: Text(tr.cancel),
              ),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: FilledButton(
                onPressed: valid ? () => Navigator.pop(context, _payload()) : null,
                child: Text(tr.save),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  Map<String, dynamic> _payload() {
    final base = <String, dynamic>{'kind': widget.kind};
    if (widget.kind == _kAppt) {
      base.addAll({
        'category': _cat,
        'title': _c['title']!.text.trim(),
        'place': _c['place']!.text.trim(),
        'at': _c['at']!.text.trim(),
        'note': _c['note']!.text.trim(),
      });
    } else if (widget.kind == _kPref) {
      base.addAll({
        'topic': _c['topic']!.text.trim(),
        'text': _c['text']!.text.trim(),
      });
    } else {
      base.addAll({
        'slot': _slot,
        'label': _c['label']!.text.trim(),
        'time': _c['time']!.text.trim(),
      });
    }
    return base;
  }
}
