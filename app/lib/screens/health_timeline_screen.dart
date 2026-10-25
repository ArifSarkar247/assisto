import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../services/error_kind.dart' show honestFailText; // qa2

/// HEALTH TIMELINE — ADVANCED (#69, SPEC v2.1 §10).
///
/// A chronological personal health RECORD. The user logs events (doctor visit,
/// test result, prescription, vaccination, symptom, hospitalisation, other)
/// with a date and notes, then views them as a filterable, month-grouped
/// timeline — or regrouped by category.
///
/// This is a RECORD, not a medical opinion: we never diagnose, score or advise.
/// A gentle "not medical advice — consult a doctor" note is always shown. Any
/// medicine reference belongs to the DGDA-sourced medicine module; nothing here
/// invents drug data.
///
/// The on-screen ordering/grouping mirrors backend/core/logic/health_timeline.py
/// VERBATIM (newest-first by date then created-at then id; undated last) so the
/// timeline is identical online or offline.
///
/// Honest states: welcome (first use) · loading · error · empty-filter. ZERO
/// Bangla literals — every string is an AppLocalizations getter.
///
/// Persistence (generic api helpers, no api.dart edit):
///   listItems('health/timeline') → [{id, category, title, date (YYYY-MM-DD),
///       notes, doctor, place, created_at}]
///   create/update/deleteItem on the same path; each row round-trips as
///   {id, ...data} through one flexible per-user JSON collection.
class HealthTimelineScreen extends StatefulWidget {
  const HealthTimelineScreen({super.key});
  @override
  State<HealthTimelineScreen> createState() => _HealthTimelineScreenState();
}

const String _timelinePath = 'health/timeline';

const List<String> _categories = [
  'visit',
  'test',
  'prescription',
  'vaccination',
  'symptom',
  'hospitalization',
  'other',
];

class _HealthTimelineScreenState extends State<HealthTimelineScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true, _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

  // filter state
  final Set<String> _selected = {};
  final TextEditingController _search = TextEditingController();
  bool _byCategory = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    final api = context.read<AppState>().api;
    try {
      _rows = await api.listItems(_timelinePath);
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String m) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
          appBar: AppBar(title: Text(tr.htlTitle)),
          body: const SkeletonList());
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.htlTitle)),
        body: StateMessage(
          icon: Icons.cloud_off_rounded,
          tint: scheme.error,
          title: tr.loadFailed,
          message: honestFailText(tr, _failCause, otherwise: tr.htlLoadError),
          action: FilledButton.tonalIcon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(tr.retry)),
        ),
      );
    }
    if (_rows.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.htlTitle)),
        body: ListView(children: [
          StateMessage(
            icon: Icons.timeline_rounded,
            tint: Brand.blue,
            title: tr.htlWelcomeTitle,
            message: tr.htlWelcomeBody,
            action: FilledButton.icon(
              onPressed: _addOrEdit,
              icon: const Icon(Icons.add_rounded),
              label: Text(tr.htlAddEvent),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(Gap.lg, Gap.xl, Gap.lg, Gap.lg),
            child: _Disclaimer(),
          ),
        ]),
      );
    }

    final events = _HealthView.filter(
      _rows,
      selected: _selected,
      query: _search.text,
    );
    final counts = _HealthView.categoryCounts(_rows);

    return Scaffold(
      appBar: AppBar(
        title: Text(tr.htlTitle),
        actions: [
          IconButton(
            tooltip: _byCategory ? tr.htlGroupByMonth : tr.htlGroupByCategory,
            icon: Icon(_byCategory
                ? Icons.calendar_month_rounded
                : Icons.category_rounded),
            onPressed: () => setState(() => _byCategory = !_byCategory),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addOrEdit,
        icon: const Icon(Icons.add_rounded),
        label: Text(tr.htlAddEvent),
      ),
      body: Column(children: [
        _FilterBar(
          selected: _selected,
          counts: counts,
          search: _search,
          onChanged: () => setState(() {}),
        ),
        Expanded(
          child: events.isEmpty
              ? StateMessage(
                  icon: Icons.filter_alt_off_rounded,
                  tint: scheme.onSurfaceVariant,
                  title: tr.htlNoneMatchTitle,
                  message: tr.htlNoneMatchBody,
                  action: OutlinedButton.icon(
                    onPressed: () => setState(() {
                      _selected.clear();
                      _search.clear();
                    }),
                    icon: const Icon(Icons.clear_all_rounded),
                    label: Text(tr.htlClearFilters),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: _byCategory
                      ? _CategoryList(events: events, onEdit: _addOrEdit)
                      : _MonthList(events: events, onEdit: _addOrEdit),
                ),
        ),
      ]),
    );
  }

  Future<void> _addOrEdit([Map<String, dynamic>? existing]) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _EventForm(existing: existing),
    );
    if (result == null) return;
    // a delete sentinel from the form
    if (result['_delete'] == true && existing?['id'] is int) {
      try {
        await api.deleteItem(_timelinePath, existing!['id'] as int);
        await _load();
        if (mounted) _toast(tr.htlDeleted);
      } catch (_) {
        if (mounted) _toast(tr.saveFailed);
      }
      return;
    }
    try {
      if (existing != null && existing['id'] is int) {
        await api.updateItem(_timelinePath, existing['id'] as int, result);
      } else {
        await api.createItem(_timelinePath, result);
      }
      await _load();
      if (mounted) _toast(tr.htlSaved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }
}

// ======================= FILTER BAR =======================
class _FilterBar extends StatelessWidget {
  final Set<String> selected;
  final Map<String, int> counts;
  final TextEditingController search;
  final VoidCallback onChanged;
  const _FilterBar(
      {required this.selected,
      required this.counts,
      required this.search,
      required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 0),
      child: Column(children: [
        TextField(
          controller: search,
          onChanged: (_) => onChanged(),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            isDense: true,
            hintText: tr.htlSearchHint,
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: search.text.isEmpty
                ? null
                : IconButton(tooltip: MaterialLocalizations.of(context).clearButtonTooltip,
                    icon: const Icon(Icons.clear_rounded, size: 18),
                    onPressed: () {
                      search.clear();
                      onChanged();
                    },
                  ),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: Gap.sm),
        SizedBox(
          height: 38,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final c in _categories)
                if ((counts[c] ?? 0) > 0)
                  Padding(
                    padding: const EdgeInsets.only(right: Gap.sm),
                    child: FilterChip(
                      label: Text('${_catLabel(tr, c)} (${counts[c]})'),
                      selected: selected.contains(c),
                      onSelected: (v) {
                        if (v) {
                          selected.add(c);
                        } else {
                          selected.remove(c);
                        }
                        onChanged();
                      },
                    ),
                  ),
            ],
          ),
        ),
        const SizedBox(height: Gap.sm),
      ]),
    );
  }
}

// ======================= MONTH-GROUPED LIST =======================
class _MonthList extends StatelessWidget {
  final List<Map<String, dynamic>> events;
  final Future<void> Function([Map<String, dynamic>? existing]) onEdit;
  const _MonthList({required this.events, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final groups = _HealthView.groupByMonth(events);
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, 96),
      children: [
        for (final g in groups) ...[
          _SectionHeader(
            label: g.key == 'undated'
                ? tr.htlUndated
                : _HealthView.monthLabel(context, g.year!, g.month!),
            count: g.count,
          ),
          for (final e in g.events) _EventCard(event: e, onEdit: onEdit),
          const SizedBox(height: Gap.sm),
        ],
        const _Disclaimer(),
      ],
    );
  }
}

// ======================= CATEGORY-GROUPED LIST =======================
class _CategoryList extends StatelessWidget {
  final List<Map<String, dynamic>> events;
  final Future<void> Function([Map<String, dynamic>? existing]) onEdit;
  const _CategoryList({required this.events, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final groups = _HealthView.groupByCategory(events);
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, 96),
      children: [
        for (final entry in groups) ...[
          _SectionHeader(
              label: _catLabel(tr, entry.key), count: entry.value.length),
          for (final e in entry.value) _EventCard(event: e, onEdit: onEdit),
          const SizedBox(height: Gap.sm),
        ],
        const _Disclaimer(),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  final int count;
  const _SectionHeader({required this.label, required this.count});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.xxs, Gap.md, Gap.xxs, Gap.xs),
      child: Row(children: [
        Text(label,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w700, color: Brand.blue)),
        const SizedBox(width: Gap.sm),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xxs),
          decoration: BoxDecoration(
            color: Brand.blue.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text('$count',
              style: AType.labelSmall.copyWith(color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }
}

// ======================= EVENT CARD =======================
class _EventCard extends StatelessWidget {
  final Map<String, dynamic> event;
  final Future<void> Function([Map<String, dynamic>? existing]) onEdit;
  const _EventCard({required this.event, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final cat = (event['category'] ?? 'other').toString();
    final color = _catColor(cat);
    final title = (event['title'] ?? '').toString();
    final notes = (event['notes'] ?? '').toString();
    final doctor = (event['doctor'] ?? '').toString();
    final place = (event['place'] ?? '').toString();
    final dateStr = event['date']?.toString();

    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: () => onEdit(event),
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child:
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              height: 40,
              width: 40,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(_catIcon(cat), size: 20, color: color),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(
                        child: Text(title.isEmpty ? _catLabel(tr, cat) : title,
                            style:
                                const TextStyle(fontWeight: FontWeight.w700),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis),
                      ),
                      const SizedBox(width: Gap.sm),
                      Text(
                        dateStr == null
                            ? tr.htlUndated
                            : _HealthView.dateLabel(context, dateStr),
                        style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ]),
                    const SizedBox(height: Gap.xxs),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: Gap.xxs),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(_catLabel(tr, cat),
                          style: AType.labelSmall.copyWith(color: color)),
                    ),
                    if (doctor.isNotEmpty || place.isNotEmpty) ...[
                      const SizedBox(height: Gap.xs),
                      Row(children: [
                        if (doctor.isNotEmpty) ...[
                          Icon(Icons.person_outline_rounded,
                              size: 13, color: scheme.onSurfaceVariant),
                          const SizedBox(width: 3),
                          Flexible(
                            child: Text(doctor,
                                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                          ),
                          const SizedBox(width: Gap.sm),
                        ],
                        if (place.isNotEmpty) ...[
                          Icon(Icons.place_rounded,
                              size: 13, color: scheme.onSurfaceVariant),
                          const SizedBox(width: 3),
                          Flexible(
                            child: Text(place,
                                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                          ),
                        ],
                      ]),
                    ],
                    if (notes.isNotEmpty) ...[
                      const SizedBox(height: Gap.xs),
                      Text(notes,
                          style: AType.bodyMedium.copyWith(color: scheme.onSurface)),
                    ],
                  ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Disclaimer extends StatelessWidget {
  const _Disclaimer();
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(children: [
          Icon(Icons.info_outline_rounded, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(tr.htlDisclaimer,
                style:
                    AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          ),
        ]),
      ),
    );
  }
}

// ======================= ADD / EDIT FORM =======================
class _EventForm extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _EventForm({this.existing});
  @override
  State<_EventForm> createState() => _EventFormState();
}

class _EventFormState extends State<_EventForm> {
  late final TextEditingController _title =
      TextEditingController(text: widget.existing?['title']?.toString() ?? '');
  late final TextEditingController _notes =
      TextEditingController(text: widget.existing?['notes']?.toString() ?? '');
  late final TextEditingController _doctor = TextEditingController(
      text: widget.existing?['doctor']?.toString() ?? '');
  late final TextEditingController _place =
      TextEditingController(text: widget.existing?['place']?.toString() ?? '');
  late String _category = _normCat(widget.existing?['category']);
  DateTime? _date;

  static String _normCat(dynamic v) {
    final s = (v ?? 'visit').toString();
    return _categories.contains(s) ? s : 'other';
  }

  @override
  void initState() {
    super.initState();
    final d = widget.existing?['date'];
    if (d != null) _date = DateTime.tryParse(d.toString());
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    _doctor.dispose();
    _place.dispose();
    super.dispose();
  }

  bool get _valid => _title.text.trim().isNotEmpty;

  Map<String, dynamic> _result() => {
        'category': _category,
        'title': _title.text.trim(),
        'notes': _notes.text.trim(),
        'doctor': _doctor.text.trim(),
        'place': _place.text.trim(),
        if (_date != null)
          'date': _date!.toIso8601String().split('T').first,
      };

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final editing = widget.existing != null && widget.existing!['id'] is int;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(editing ? tr.htlEditEvent : tr.htlAddEvent,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Gap.lg),
            Text(tr.htlCategory,
                style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: Gap.xs),
            Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
              for (final c in _categories)
                ChoiceChip(
                  avatar: Icon(_catIcon(c),
                      size: 16,
                      color: _category == c ? Colors.white : _catColor(c)),
                  label: Text(_catLabel(tr, c)),
                  selected: _category == c,
                  selectedColor: _catColor(c),
                  labelStyle: AType.bodyMedium.copyWith(color: _category == c ? Colors.white : null),
                  onSelected: (_) => setState(() => _category = c),
                ),
            ]),
            const SizedBox(height: Gap.md),
            TextField(
              controller: _title,
              autofocus: !editing,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                  labelText: tr.htlEventTitle,
                  hintText: tr.htlEventTitleHint,
                  border: const OutlineInputBorder()),
            ),
            const SizedBox(height: Gap.md),
            InkWell(
              borderRadius: BorderRadius.circular(Radii.sm),
              onTap: () async {
                final now = DateTime.now();
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _date ?? now,
                  firstDate: DateTime(now.year - 10),
                  lastDate: DateTime(now.year + 1),
                );
                if (picked != null) setState(() => _date = picked);
              },
              child: InputDecorator(
                decoration: InputDecoration(
                    labelText: tr.htlEventDate,
                    prefixIcon: const Icon(Icons.event_rounded),
                    border: const OutlineInputBorder()),
                child: Row(children: [
                  Expanded(
                    child: Text(_date == null
                        ? tr.htlNoDate
                        : _date!.toIso8601String().split('T').first),
                  ),
                  if (_date != null)
                    IconButton(tooltip: MaterialLocalizations.of(context).clearButtonTooltip,
                      icon: const Icon(Icons.clear_rounded, size: 18),
                      onPressed: () => setState(() => _date = null),
                    ),
                ]),
              ),
            ),
            const SizedBox(height: Gap.md),
            TextField(
              controller: _doctor,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                  labelText: tr.htlDoctor,
                  prefixIcon: const Icon(Icons.person_outline_rounded),
                  border: const OutlineInputBorder()),
            ),
            const SizedBox(height: Gap.md),
            TextField(
              controller: _place,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                  labelText: tr.htlPlace,
                  prefixIcon: const Icon(Icons.place_rounded),
                  border: const OutlineInputBorder()),
            ),
            const SizedBox(height: Gap.md),
            TextField(
              controller: _notes,
              minLines: 2,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                  labelText: tr.htlNotes,
                  hintText: tr.htlNotesHint,
                  alignLabelWithHint: true,
                  border: const OutlineInputBorder()),
            ),
            const SizedBox(height: Gap.md),
            Text(tr.htlDisclaimer,
                style: AType.bodySmall.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: Gap.lg),
            Row(children: [
              if (editing)
                IconButton(
                  tooltip: tr.delete,
                  onPressed: () async {
                    final ok = await _confirmDelete(context);
                    if (ok == true && context.mounted) {
                      Navigator.pop(context, {'_delete': true});
                    }
                  },
                  icon: Icon(Icons.delete_outline_rounded,
                      color: Theme.of(context).colorScheme.error),
                ),
              Expanded(
                child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(tr.cancel)),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: FilledButton(
                  onPressed:
                      _valid ? () => Navigator.pop(context, _result()) : null,
                  child: Text(tr.save),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Future<bool?> _confirmDelete(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.htlDeleteTitle),
        content: Text(tr.htlDeleteBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr.cancel)),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr.delete),
          ),
        ],
      ),
    );
  }
}

// ======================= helpers (labels / icons / colours) =======================
String _catLabel(AppLocalizations tr, String c) => switch (c) {
      'visit' => tr.htlCatVisit,
      'test' => tr.htlCatTest,
      'prescription' => tr.htlCatPrescription,
      'vaccination' => tr.htlCatVaccination,
      'symptom' => tr.htlCatSymptom,
      'hospitalization' => tr.htlCatHospitalization,
      _ => tr.htlCatOther,
    };

IconData _catIcon(String c) => switch (c) {
      'visit' => Icons.medical_services_rounded,
      'test' => Icons.science_rounded,
      'prescription' => Icons.receipt_long_rounded,
      'vaccination' => Icons.vaccines_rounded,
      'symptom' => Icons.sick_rounded,
      'hospitalization' => Icons.local_hospital_rounded,
      _ => Icons.note_alt_rounded,
    };

Color _catColor(String c) => switch (c) {
      'visit' => Brand.blue,
      'test' => Brand.purple,
      'prescription' => const Color(0xFF0E8A6E),
      'vaccination' => Brand.success,
      'symptom' => Brand.warning,
      'hospitalization' => Brand.danger,
      _ => const Color(0xFF6B7280),
    };

// ===================================================================
// _HealthView — deterministic mirror of core/logic/health_timeline.py.
// Newest-first ordering (date, created_at, id desc; undated last), filter,
// month & category grouping. No I/O.
// ===================================================================
class _HealthView {
  static DateTime? _parse(dynamic v) {
    if (v == null || v == '') return null;
    final s = v.toString().split('T').first.split(' ').first;
    return DateTime.tryParse(s);
  }

  static String _normCat(dynamic c) {
    final s = (c ?? '').toString().trim().toLowerCase();
    return _categories.contains(s) ? s : 'other';
  }

  static Map<String, dynamic> _normalize(Map<String, dynamic> r) {
    final d = _parse(r['date']);
    final created = _parse(r['created_at']) ?? d;
    return {
      'id': r['id'],
      'category': _normCat(r['category']),
      'title': (r['title'] ?? '').toString().trim(),
      'notes': (r['notes'] ?? '').toString().trim(),
      'doctor': (r['doctor'] ?? '').toString().trim(),
      'place': (r['place'] ?? '').toString().trim(),
      'date': d == null ? null : d.toIso8601String().split('T').first,
      'undated': d == null,
      '_d': d,
      '_c': created,
    };
  }

  static int _cmp(Map<String, dynamic> a, Map<String, dynamic> b) {
    final da = a['_d'] as DateTime?;
    final db = b['_d'] as DateTime?;
    final ao = da?.millisecondsSinceEpoch ?? -62135596800000; // ~date.min
    final bo = db?.millisecondsSinceEpoch ?? -62135596800000;
    if (ao != bo) return bo.compareTo(ao); // newest first
    final ca = a['_c'] as DateTime?;
    final cb = b['_c'] as DateTime?;
    final co = ca?.millisecondsSinceEpoch ?? -62135596800000;
    final cco = cb?.millisecondsSinceEpoch ?? -62135596800000;
    if (co != cco) return cco.compareTo(co);
    final ia = a['id'] is int ? a['id'] as int : -1;
    final ib = b['id'] is int ? b['id'] as int : -1;
    return ib.compareTo(ia);
  }

  static List<Map<String, dynamic>> order(List<Map<String, dynamic>> rows) {
    final out = [for (final r in rows) _normalize(r)];
    out.sort(_cmp);
    return out;
  }

  static List<Map<String, dynamic>> filter(
    List<Map<String, dynamic>> rows, {
    Set<String>? selected,
    String? query,
  }) {
    final q = (query ?? '').trim().toLowerCase();
    final want = (selected != null && selected.isNotEmpty) ? selected : null;
    final out = <Map<String, dynamic>>[];
    for (final e in order(rows)) {
      if (want != null && !want.contains(e['category'])) continue;
      if (q.isNotEmpty) {
        final hay = [e['title'], e['notes'], e['doctor'], e['place']]
            .join(' ')
            .toLowerCase();
        if (!hay.contains(q)) continue;
      }
      out.add(e);
    }
    return out;
  }

  static Map<String, int> categoryCounts(List<Map<String, dynamic>> rows) {
    final c = {for (final k in _categories) k: 0};
    for (final r in rows) {
      c[_normCat(r['category'])] = (c[_normCat(r['category'])] ?? 0) + 1;
    }
    return c;
  }

  // Events must already be filtered/ordered (newest-first).
  static List<_MonthGroup> groupByMonth(List<Map<String, dynamic>> events) {
    final out = <_MonthGroup>[];
    final index = <String, _MonthGroup>{};
    for (final e in events) {
      String key;
      int? year, month;
      final ds = e['date']?.toString();
      if (ds != null) {
        final d = DateTime.parse(ds);
        year = d.year;
        month = d.month;
        key = '${d.year}-${d.month.toString().padLeft(2, '0')}';
      } else {
        key = 'undated';
      }
      var g = index[key];
      if (g == null) {
        g = _MonthGroup(key: key, year: year, month: month);
        index[key] = g;
        out.add(g);
      }
      g.events.add(e);
    }
    return out;
  }

  static List<MapEntry<String, List<Map<String, dynamic>>>> groupByCategory(
      List<Map<String, dynamic>> events) {
    final by = {for (final c in _categories) c: <Map<String, dynamic>>[]};
    for (final e in events) {
      by[e['category']]!.add(e);
    }
    return [
      for (final c in _categories)
        if (by[c]!.isNotEmpty) MapEntry(c, by[c]!),
    ];
  }

  static const List<String> _months = [
    '', 'January', 'February', 'March', 'April', 'May', 'June', 'July',
    'August', 'September', 'October', 'November', 'December'
  ];

  static String monthLabel(BuildContext context, int year, int month) {
    final loc = Localizations.localeOf(context).languageCode;
    // Localised month names via the ARB bundle would be ideal, but to avoid
    // 12 new keys we use MaterialLocalizations' formatted month+year which is
    // already localised by Flutter (no Bangla literal in this file).
    final ml = MaterialLocalizations.of(context);
    final label = ml.formatMonthYear(DateTime(year, month));
    // Fallback to English constant month if the platform gives an empty label.
    if (label.trim().isEmpty) return '${_months[month]} $year ($loc)';
    return label;
  }

  static String dateLabel(BuildContext context, String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    return MaterialLocalizations.of(context).formatShortDate(d);
  }
}

class _MonthGroup {
  final String key;
  final int? year;
  final int? month;
  final List<Map<String, dynamic>> events = [];
  _MonthGroup({required this.key, this.year, this.month});
  int get count => events.length;
}
