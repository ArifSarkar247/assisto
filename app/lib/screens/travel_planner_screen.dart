import '../feature_gates.dart' show kShowKeySeams;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../services/error_kind.dart' show honestFailText; // qa2

/// TRAVEL PLANNER — ADVANCED, KEY-GATED (#35, SPEC v2.1 §21).
///
/// Plan a trip fully by hand, offline, with NO key: destination + dates, a
/// day-by-day itinerary (activities/places per day), a packing checklist, a ৳
/// budget (estimated vs actual per category) and a live countdown.
///
/// HONEST, KEY-GATED (NEVER FABRICATES):
///   * AI itinerary suggestions are a DOCUMENTED key-gated seam shown as an
///     honest "connect an AI key for suggestions" card (_AiSeamCard). This
///     screen never invents activities or places.
///   * Live booking / live prices are a DOCUMENTED key-gated seam shown as an
///     honest "connect a booking key" card (_BookingSeamCard). Prices shown are
///     only the ESTIMATES the user typed; nothing is ever booked, no money held.
///
/// All math mirrors backend/core/logic/travel_planner.py (inclusive date span,
/// passed-in-today countdown, integer-poisha budget with no drift, packing %,
/// itinerary counts) so the views are deterministic and identical offline.
///
/// Honest states: welcome (no trips) · loading · error. ZERO Bangla literals —
/// every string is an AppLocalizations getter (৳ exempt).
///
/// Persistence (generic api helpers, no api.dart edit):
///   listItems('travel/trips')   → [{id, destination, start, end}]
///   listItems('travel/days')    → [{id, trip_id, day, title,
///                                    activities:[{what, place, time}]}]
///   listItems('travel/budget')  → [{id, trip_id, category, estimate, actual}]
///   listItems('travel/packing') → [{id, trip_id, label, checked}]
/// create/update/delete on each path; rows round-trip as {id, ...data} through
/// one flexible per-user JSON collection (PaCollectionItem precedent).
class TravelPlannerScreen extends StatefulWidget {
  const TravelPlannerScreen({super.key});
  @override
  State<TravelPlannerScreen> createState() => _TravelPlannerScreenState();
}

const String _tripsPath = 'travel/trips';
const List<String> _budgetCategories = [
  'transport',
  'stay',
  'food',
  'activities',
  'shopping',
  'other',
];

String _today() {
  final n = DateTime.now();
  return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
}

DateTime? _parseDate(String? s) {
  final t = (s ?? '').trim();
  if (t.isEmpty) return null;
  final p = t.split('-');
  if (p.length != 3) return null;
  final y = int.tryParse(p[0]), m = int.tryParse(p[1]), d = int.tryParse(p[2]);
  if (y == null || m == null || d == null) return null;
  try {
    return DateTime(y, m, d);
  } catch (_) {
    return null;
  }
}

/// Inclusive day span — mirror of travel_planner.trip_days.
int _tripDays(String? start, String? end) {
  final a = _parseDate(start), b = _parseDate(end);
  if (a == null || b == null || b.isBefore(a)) return 0;
  return b.difference(a).inDays + 1;
}

String _catLabel(AppLocalizations tr, String c) {
  switch (c) {
    case 'transport':
      return tr.tvCatTransport;
    case 'stay':
      return tr.tvCatStay;
    case 'food':
      return tr.tvCatFood;
    case 'activities':
      return tr.tvCatActivities;
    case 'shopping':
      return tr.tvCatShopping;
    default:
      return tr.tvCatOther;
  }
}

class _TravelPlannerScreenState extends State<TravelPlannerScreen> {
  List<Map<String, dynamic>> _trips = [];
  bool _loading = true, _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      _trips = await context.read<AppState>().api.listItems(_tripsPath);
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _openTripEditor([Map<String, dynamic>? existing]) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _TripEditorSheet(existing: existing),
    );
    if (result == null) return;
    final api = context.read<AppState>().api;
    try {
      if (existing != null && existing['id'] is int) {
        await api.updateItem(_tripsPath, existing['id'] as int, result);
      } else {
        await api.createItem(_tripsPath, result);
      }
      await _load();
    } catch (_) {
      if (mounted) _toast(AppLocalizations.of(context).saveFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
          appBar: AppBar(title: Text(tr.tvTitle)),
          body: const SkeletonList());
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.tvTitle)),
        body: StateMessage(
          icon: Icons.cloud_off_rounded,
          tint: scheme.error,
          title: tr.loadFailed,
          message: honestFailText(tr, _failCause, otherwise: tr.tvLoadError),
          action: FilledButton.tonalIcon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(tr.retry)),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(tr.tvTitle)),
      // empty state has its own CTA: no duplicate FAB
      floatingActionButton: _trips.isEmpty ? null : FloatingActionButton.extended(
        onPressed: () => _openTripEditor(),
        icon: const Icon(Icons.add_rounded),
        label: Text(tr.tvNewTrip),
      ),
      body: _trips.isEmpty
          ? _Welcome(onAdd: () => _openTripEditor())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
                children: [
                  for (final t in _trips)
                    _TripCard(
                      trip: t,
                      onOpen: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => _TripDetailScreen(trip: t),
                        ),
                      ),
                      onEdit: () => _openTripEditor(t),
                    ),
                ],
              ),
            ),
    );
  }
}

// ======================= welcome =======================
class _Welcome extends StatelessWidget {
  final VoidCallback onAdd;
  const _Welcome({required this.onAdd});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(Gap.lg),
      children: [
        const SizedBox(height: Gap.xl),
        Icon(Icons.luggage_rounded, size: 56, color: scheme.primary),
        const SizedBox(height: Gap.md),
        Text(tr.tvWelcomeTitle,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.sm),
        Text(tr.tvWelcomeBody,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
        const SizedBox(height: Gap.xl),
        Center(
          child: FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add_rounded),
            label: Text(tr.tvNewTrip),
          ),
        ),
      ],
    );
  }
}

// ======================= trip card + countdown =======================
class _TripCard extends StatelessWidget {
  final Map<String, dynamic> trip;
  final VoidCallback onOpen, onEdit;
  const _TripCard(
      {required this.trip, required this.onOpen, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final start = '${trip['start'] ?? ''}';
    final end = '${trip['end'] ?? ''}';
    final days = _tripDays(start, end);
    final cd = _countdown(start, end, _today());
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: ListTile(
        onTap: onOpen,
        leading: CircleAvatar(
          backgroundColor: scheme.primaryContainer,
          child: Icon(Icons.place_rounded, color: scheme.onPrimaryContainer),
        ),
        title: Text('${trip['destination'] ?? ''}',
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: Gap.xxs),
            if (start.isNotEmpty && end.isNotEmpty)
              Text('$start → $end',
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.xs),
            Wrap(spacing: Gap.sm, children: [
              if (days > 0)
                _CountChip(
                    icon: Icons.event_note_rounded,
                    label: tr.tvDaysCount(days),
                    tint: scheme.tertiary),
              _CountdownChip(cd: cd),
            ]),
          ],
        ),
        trailing: IconButton(
          icon: const Icon(Icons.edit_rounded),
          tooltip: tr.edit,
          onPressed: onEdit,
        ),
        isThreeLine: true,
      ),
    );
  }
}

/// Countdown relative to today — mirror of travel_planner.countdown.
class _Countdown {
  final String status; // upcoming / ongoing / past
  final int days, totalDays;
  const _Countdown(this.status, this.days, this.totalDays);
}

_Countdown _countdown(String start, String end, String today) {
  final a = _parseDate(start), b = _parseDate(end), t = _parseDate(today);
  final total = _tripDays(start, end);
  if (a == null || b == null || t == null || b.isBefore(a)) {
    return _Countdown('upcoming', 0, total);
  }
  if (t.isBefore(a)) {
    return _Countdown('upcoming', a.difference(t).inDays, total);
  }
  if (t.isAfter(b)) {
    return _Countdown('past', t.difference(b).inDays, total);
  }
  return _Countdown('ongoing', b.difference(t).inDays + 1, total);
}

class _CountdownChip extends StatelessWidget {
  final _Countdown cd;
  const _CountdownChip({required this.cd});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    String label;
    IconData icon;
    Color tint;
    switch (cd.status) {
      case 'ongoing':
        label = tr.tvOngoing(cd.days);
        icon = Icons.flight_takeoff_rounded;
        tint = scheme.primary;
        break;
      case 'past':
        label = tr.tvPast(cd.days);
        icon = Icons.history_rounded;
        tint = scheme.onSurfaceVariant;
        break;
      default:
        label = tr.tvCountdown(cd.days);
        icon = Icons.hourglass_bottom_rounded;
        tint = scheme.secondary;
    }
    return _CountChip(icon: icon, label: label, tint: tint);
  }
}

class _CountChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color tint;
  const _CountChip(
      {required this.icon, required this.label, required this.tint});
  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 14, color: tint),
      const SizedBox(width: 3),
      Text(label,
          style: AType.bodySmall.copyWith(color: tint, fontWeight: FontWeight.w600)),
    ]);
  }
}

// ======================= trip detail (tabs) =======================
class _TripDetailScreen extends StatefulWidget {
  final Map<String, dynamic> trip;
  const _TripDetailScreen({required this.trip});
  @override
  State<_TripDetailScreen> createState() => _TripDetailScreenState();
}

class _TripDetailScreenState extends State<_TripDetailScreen> {
  List<Map<String, dynamic>> _days = [];
  List<Map<String, dynamic>> _budget = [];
  List<Map<String, dynamic>> _packing = [];
  bool _loading = true, _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

  static const _daysPath = 'travel/days';
  static const _budgetPath = 'travel/budget';
  static const _packingPath = 'travel/packing';

  int get _tripId => widget.trip['id'] is int ? widget.trip['id'] as int : -1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final api = context.read<AppState>().api;
      final days = await api.listItems(_daysPath);
      final budget = await api.listItems(_budgetPath);
      final packing = await api.listItems(_packingPath);
      bool mine(Map<String, dynamic> r) => r['trip_id'] == _tripId;
      _days = days.where(mine).toList();
      _budget = budget.where(mine).toList();
      _packing = packing.where(mine).toList();
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _create(String path, Map<String, dynamic> body) async {
    try {
      await context.read<AppState>().api.createItem(path, {...body, 'trip_id': _tripId});
      await _load();
    } catch (_) {
      if (mounted) _toast(AppLocalizations.of(context).saveFailed);
    }
  }

  Future<void> _update(String path, int id, Map<String, dynamic> body) async {
    try {
      await context.read<AppState>().api.updateItem(path, id, {...body, 'trip_id': _tripId});
      await _load();
    } catch (_) {
      if (mounted) _toast(AppLocalizations.of(context).saveFailed);
    }
  }

  Future<void> _delete(String path, int id) async {
    try {
      await context.read<AppState>().api.deleteItem(path, id);
      await _load();
    } catch (_) {
      if (mounted) _toast(AppLocalizations.of(context).saveFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
          appBar: AppBar(title: Text('${widget.trip['destination'] ?? ''}')),
          body: const SkeletonList());
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text('${widget.trip['destination'] ?? ''}')),
        body: StateMessage(
          icon: Icons.cloud_off_rounded,
          tint: scheme.error,
          title: tr.loadFailed,
          message: honestFailText(tr, _failCause, otherwise: tr.tvLoadError),
          action: FilledButton.tonalIcon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(tr.retry)),
        ),
      );
    }
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text('${widget.trip['destination'] ?? ''}'),
          bottom: TabBar(tabs: [
            Tab(text: tr.tvTabItinerary),
            Tab(text: tr.tvTabPacking),
            Tab(text: tr.tvTabBudget),
          ]),
        ),
        body: TabBarView(children: [
          _ItineraryTab(
            days: _days,
            onAddDay: (body) => _create(_daysPath, body),
            onUpdateDay: (id, body) => _update(_daysPath, id, body),
            onDeleteDay: (id) => _delete(_daysPath, id),
            trip: widget.trip,
          ),
          _PackingTab(
            items: _packing,
            onAdd: (body) => _create(_packingPath, body),
            onToggle: (id, body) => _update(_packingPath, id, body),
            onDelete: (id) => _delete(_packingPath, id),
          ),
          _BudgetTab(
            rows: _budget,
            onAdd: (body) => _create(_budgetPath, body),
            onUpdate: (id, body) => _update(_budgetPath, id, body),
            onDelete: (id) => _delete(_budgetPath, id),
          ),
        ]),
      ),
    );
  }
}

// ======================= itinerary tab =======================
class _ItineraryTab extends StatelessWidget {
  final List<Map<String, dynamic>> days;
  final Map<String, dynamic> trip;
  final void Function(Map<String, dynamic>) onAddDay;
  final void Function(int, Map<String, dynamic>) onUpdateDay;
  final void Function(int) onDeleteDay;
  const _ItineraryTab(
      {required this.days,
      required this.trip,
      required this.onAddDay,
      required this.onUpdateDay,
      required this.onDeleteDay});

  Future<void> _editDay(BuildContext context,
      [Map<String, dynamic>? existing]) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _DayEditorSheet(
          existing: existing, dayNumber: existing == null ? days.length + 1 : null),
    );
    if (result == null) return;
    if (existing != null && existing['id'] is int) {
      onUpdateDay(existing['id'] as int, result);
    } else {
      onAddDay(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    var totalActivities = 0;
    for (final d in days) {
      final acts = (d['activities'] as List?) ?? const [];
      totalActivities += acts
          .where((a) => '${(a as Map?)?['what'] ?? ''}'.trim().isNotEmpty)
          .length;
    }
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editDay(context),
        icon: const Icon(Icons.add_rounded),
        label: Text(tr.tvAddDay),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
        children: [
          const _AiSeamCard(),
          const SizedBox(height: Gap.sm),
          if (days.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xl),
              child: StateMessage(
                icon: Icons.event_note_rounded,
                title: tr.tvNoDaysTitle,
                message: tr.tvNoDaysBody,
              ),
            )
          else ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.sm),
              child: Text(
                  tr.tvItinerarySummary(/* (activities, days) */ totalActivities, days.length),
                  style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600)),
            ),
            for (final d in days)
              _DayCard(
                day: d,
                onEdit: () => _editDay(context, d),
                onDelete: () =>
                    d['id'] is int ? onDeleteDay(d['id'] as int) : null,
              ),
          ],
        ],
      ),
    );
  }
}

class _DayCard extends StatelessWidget {
  final Map<String, dynamic> day;
  final VoidCallback onEdit, onDelete;
  const _DayCard(
      {required this.day, required this.onEdit, required this.onDelete});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final acts = ((day['activities'] as List?) ?? const [])
        .whereType<Map>()
        .where((a) => '${a['what'] ?? ''}'.trim().isNotEmpty)
        .toList();
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: scheme.primaryContainer,
              child: Text('${day['day'] ?? ''}',
                  style: TextStyle(
                      color: scheme.onPrimaryContainer,
                      fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(
                  '${day['title'] ?? ''}'.trim().isEmpty
                      ? tr.tvDayN('${day['day'] ?? ''}')
                      : '${day['title']}',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
            IconButton(
                icon: const Icon(Icons.edit_rounded, size: 20),
                tooltip: tr.edit,
                onPressed: onEdit),
            IconButton(
                icon: const Icon(Icons.delete_outline_rounded, size: 20),
                tooltip: tr.delete,
                onPressed: onDelete),
          ]),
          if (acts.isEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 40, top: Gap.xs),
              child: Text(tr.tvNoActivities,
                  style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic)),
            )
          else
            for (final a in acts)
              Padding(
                padding: const EdgeInsets.only(left: 40, top: 6),
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.fiber_manual_record_rounded,
                          size: 8, color: scheme.primary),
                      const SizedBox(width: Gap.sm),
                      Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${a['what'] ?? ''}'),
                              if ('${a['place'] ?? ''}'.trim().isNotEmpty ||
                                  '${a['time'] ?? ''}'.trim().isNotEmpty)
                                Text(
                                    [
                                      '${a['time'] ?? ''}'.trim(),
                                      '${a['place'] ?? ''}'.trim(),
                                    ].where((e) => e.isNotEmpty).join(' · '),
                                    style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
                            ]),
                      ),
                    ]),
              ),
        ]),
      ),
    );
  }
}

// ======================= packing tab =======================
class _PackingTab extends StatelessWidget {
  final List<Map<String, dynamic>> items;
  final void Function(Map<String, dynamic>) onAdd;
  final void Function(int, Map<String, dynamic>) onToggle;
  final void Function(int) onDelete;
  const _PackingTab(
      {required this.items,
      required this.onAdd,
      required this.onToggle,
      required this.onDelete});

  Future<void> _add(BuildContext context) async {
    final tr = AppLocalizations.of(context);
    final ctl = TextEditingController();
    final label = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(tr.tvAddPacking),
        content: TextField(
          controller: ctl,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(labelText: tr.tvPackingItem),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: Text(tr.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctl.text.trim()),
              child: Text(tr.add)),
        ],
      ),
    );
    if (label != null && label.isNotEmpty) {
      onAdd({'label': label, 'checked': false});
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final rows =
        items.where((i) => '${i['label'] ?? ''}'.trim().isNotEmpty).toList();
    final checked = rows.where((i) => i['checked'] == true).length;
    final total = rows.length;
    final pct = total > 0 ? (checked * 100 ~/ total) : 0;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _add(context),
        icon: const Icon(Icons.add_rounded),
        label: Text(tr.tvAddPacking),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
        children: [
          if (total > 0) ...[
            Row(children: [
              Expanded(
                child: LinearProgressIndicator(
                  value: pct / 100,
                  minHeight: 8,
                  borderRadius: BorderRadius.circular(Radii.xs),
                ),
              ),
              const SizedBox(width: Gap.sm),
              Text(tr.tvPackingProgress(checked, total),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: Gap.md),
          ],
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xl),
              child: StateMessage(
                icon: Icons.checklist_rounded,
                title: tr.tvNoPackingTitle,
                message: tr.tvNoPackingBody,
              ),
            )
          else
            for (final i in rows)
              Card(
                margin: const EdgeInsets.only(bottom: Gap.xs),
                child: CheckboxListTile(
                  value: i['checked'] == true,
                  onChanged: (v) => i['id'] is int
                      ? onToggle(i['id'] as int,
                          {'label': i['label'], 'checked': v ?? false})
                      : null,
                  title: Text('${i['label'] ?? ''}',
                      style: i['checked'] == true
                          ? TextStyle(
                              decoration: TextDecoration.lineThrough,
                              color: scheme.onSurfaceVariant)
                          : null),
                  secondary: IconButton(
                    icon: const Icon(Icons.delete_outline_rounded),
                    tooltip: tr.delete,
                    onPressed: () =>
                        i['id'] is int ? onDelete(i['id'] as int) : null,
                  ),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              ),
        ],
      ),
    );
  }
}

// ======================= budget tab =======================
/// Parse a BDT amount string to integer poisha — mirror of travel_planner.to_poisha.
int _toPoisha(dynamic v) {
  if (v == null || v == '') return 0;
  if (v is bool) return 0;
  var s = '$v'.trim().replaceAll(',', '');
  if (s.startsWith('-')) return 0; // negatives clamped
  String whole, frac;
  if (s.contains('.')) {
    final parts = s.split('.');
    whole = parts[0];
    frac = parts.sublist(1).join();
  } else {
    whole = s;
    frac = '';
  }
  if (whole.isEmpty) whole = '0';
  frac = (frac + '000').substring(0, 3); // remmeter: was '00' -> RangeError on whole amounts
  final major = int.tryParse(whole);
  final milli = int.tryParse(frac);
  if (major == null || milli == null) return 0;
  var poisha = major * 100 + milli ~/ 10;
  if (milli % 10 >= 5) poisha += 1;
  return poisha;
}

String _fmtBdt(int poisha) {
  final neg = poisha < 0;
  var p = poisha.abs();
  final taka = p ~/ 100;
  final paisa = p % 100;
  final s = taka.toString();
  String grouped;
  if (s.length <= 3) {
    grouped = s;
  } else {
    var head = s.substring(0, s.length - 3);
    final tail = s.substring(s.length - 3);
    final parts = <String>[];
    while (head.length > 2) {
      parts.insert(0, head.substring(head.length - 2));
      head = head.substring(0, head.length - 2);
    }
    if (head.isNotEmpty) parts.insert(0, head);
    grouped = '${parts.join(',')},$tail';
  }
  return '${neg ? '-' : ''}৳$grouped.${paisa.toString().padLeft(2, '0')}';
}

class _BudgetTab extends StatelessWidget {
  final List<Map<String, dynamic>> rows;
  final void Function(Map<String, dynamic>) onAdd;
  final void Function(int, Map<String, dynamic>) onUpdate;
  final void Function(int) onDelete;
  const _BudgetTab(
      {required this.rows,
      required this.onAdd,
      required this.onUpdate,
      required this.onDelete});

  Future<void> _edit(BuildContext context,
      [Map<String, dynamic>? existing]) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _BudgetEditorSheet(existing: existing),
    );
    if (result == null) return;
    if (existing != null && existing['id'] is int) {
      onUpdate(existing['id'] as int, result);
    } else {
      onAdd(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    var totEst = 0, totAct = 0;
    for (final r in rows) {
      totEst += _toPoisha(r['estimate']);
      totAct += _toPoisha(r['actual']);
    }
    final overspent = totAct > totEst;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context),
        icon: const Icon(Icons.add_rounded),
        label: Text(tr.tvAddBudget),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
        children: [
          Card(
            color: (overspent ? scheme.errorContainer : scheme.primaryContainer)
                .withValues(alpha: 0.35),
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(children: [
                Row(children: [
                  Expanded(
                      child: _BudgetStat(
                          label: tr.tvBudgetEstimated,
                          value: _fmtBdt(totEst))),
                  Expanded(
                      child: _BudgetStat(
                          label: tr.tvBudgetActual, value: _fmtBdt(totAct))),
                  Expanded(
                      child: _BudgetStat(
                          label: tr.tvBudgetRemaining,
                          value: _fmtBdt(totEst - totAct),
                          tint: overspent ? scheme.error : null)),
                ]),
                if (overspent) ...[
                  const SizedBox(height: Gap.sm),
                  Text(tr.tvOverspent,
                      style: AType.bodySmall.copyWith(color: scheme.error, fontWeight: FontWeight.w600)),
                ],
              ]),
            ),
          ),
          const SizedBox(height: Gap.sm),
          const _BookingSeamCard(),
          const SizedBox(height: Gap.sm),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xl),
              child: StateMessage(
                icon: Icons.account_balance_wallet_rounded,
                title: tr.tvNoBudgetTitle,
                message: tr.tvNoBudgetBody,
              ),
            )
          else
            for (final r in rows)
              Card(
                margin: const EdgeInsets.only(bottom: Gap.xs),
                child: ListTile(
                  onTap: () => _edit(context, r),
                  title: Text(_catLabel(tr, '${r['category'] ?? 'other'}')),
                  subtitle: Text(tr.tvBudgetLine(/* (actual, estimate) */
                      _fmtBdt(_toPoisha(r['actual'])),
                      _fmtBdt(_toPoisha(r['estimate'])))),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline_rounded),
                    tooltip: tr.delete,
                    onPressed: () =>
                        r['id'] is int ? onDelete(r['id'] as int) : null,
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

class _BudgetStat extends StatelessWidget {
  final String label, value;
  final Color? tint;
  const _BudgetStat({required this.label, required this.value, this.tint});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(children: [
      Text(value,
          style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700, color: tint)),
      const SizedBox(height: Gap.xxs),
      Text(label,
          textAlign: TextAlign.center,
          style: AType.labelSmall.copyWith(color: scheme.onSurfaceVariant)),
    ]);
  }
}

// ======================= AI + booking seams (key-gated) =======================
class _AiSeamCard extends StatelessWidget {
  const _AiSeamCard();
  @override
  Widget build(BuildContext context) {
    if (!kShowKeySeams) return const SizedBox.shrink(); // truth: no key dead end
    final tr = AppLocalizations.of(context);
    return _SeamCard(
      icon: Icons.auto_awesome_rounded,
      title: tr.tvAiSeamTitle,
      body: tr.tvAiSeamBody,
    );
  }
}

class _BookingSeamCard extends StatelessWidget {
  const _BookingSeamCard();
  @override
  Widget build(BuildContext context) {
    if (!kShowKeySeams) return const SizedBox.shrink(); // truth: no key dead end
    final tr = AppLocalizations.of(context);
    return _SeamCard(
      icon: Icons.confirmation_number_rounded,
      title: tr.tvBookingSeamTitle,
      body: tr.tvBookingSeamBody,
    );
  }
}

class _SeamCard extends StatelessWidget {
  final IconData icon;
  final String title, body;
  const _SeamCard(
      {required this.icon, required this.title, required this.body});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.secondaryContainer.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 20, color: scheme.secondary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: Gap.xxs),
                  Text(body,
                      style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.35)),
                ]),
          ),
        ]),
      ),
    );
  }
}

// ======================= trip editor sheet =======================
class _TripEditorSheet extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _TripEditorSheet({this.existing});
  @override
  State<_TripEditorSheet> createState() => _TripEditorSheetState();
}

class _TripEditorSheetState extends State<_TripEditorSheet> {
  late final TextEditingController _dest;
  late final TextEditingController _start;
  late final TextEditingController _end;

  @override
  void initState() {
    super.initState();
    final e = widget.existing ?? {};
    _dest = TextEditingController(text: '${e['destination'] ?? ''}');
    _start = TextEditingController(
        text: '${e['start'] ?? ''}'.isEmpty ? _today() : '${e['start']}');
    _end = TextEditingController(text: '${e['end'] ?? ''}');
  }

  @override
  void dispose() {
    _dest.dispose();
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  void _save() {
    final tr = AppLocalizations.of(context);
    if (_dest.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(tr.tvDestRequired)));
      return;
    }
    Navigator.pop(context, {
      'destination': _dest.text.trim(),
      'start': _start.text.trim(),
      'end': _end.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: Gap.lg,
        right: Gap.lg,
        top: Gap.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg,
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(widget.existing == null ? tr.tvNewTrip : tr.tvEditTrip,
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.md),
        TextField(
          controller: _dest,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
              labelText: tr.tvFieldDestination,
              border: const OutlineInputBorder()),
        ),
        const SizedBox(height: Gap.md),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _start,
              decoration: InputDecoration(
                  labelText: tr.tvFieldStart,
                  hintText: 'YYYY-MM-DD',
                  border: const OutlineInputBorder()),
            ),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: TextField(
              controller: _end,
              decoration: InputDecoration(
                  labelText: tr.tvFieldEnd,
                  hintText: 'YYYY-MM-DD',
                  border: const OutlineInputBorder()),
            ),
          ),
        ]),
        const SizedBox(height: Gap.lg),
        Row(children: [
          Expanded(
            child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                child: Text(tr.cancel)),
          ),
          const SizedBox(width: Gap.md),
          Expanded(
            child: FilledButton(onPressed: _save, child: Text(tr.save)),
          ),
        ]),
      ]),
    );
  }
}

// ======================= day editor sheet =======================
class _DayEditorSheet extends StatefulWidget {
  final Map<String, dynamic>? existing;
  final int? dayNumber;
  const _DayEditorSheet({this.existing, this.dayNumber});
  @override
  State<_DayEditorSheet> createState() => _DayEditorSheetState();
}

class _DayEditorSheetState extends State<_DayEditorSheet> {
  late final TextEditingController _dayNum;
  late final TextEditingController _title;
  late List<Map<String, String>> _activities;

  @override
  void initState() {
    super.initState();
    final e = widget.existing ?? {};
    _dayNum = TextEditingController(
        text: '${e['day'] ?? widget.dayNumber ?? 1}');
    _title = TextEditingController(text: '${e['title'] ?? ''}');
    _activities = ((e['activities'] as List?) ?? const [])
        .whereType<Map>()
        .map((a) => {
              'what': '${a['what'] ?? ''}',
              'place': '${a['place'] ?? ''}',
              'time': '${a['time'] ?? ''}',
            })
        .toList();
    if (_activities.isEmpty) {
      _activities.add({'what': '', 'place': '', 'time': ''});
    }
  }

  @override
  void dispose() {
    _dayNum.dispose();
    _title.dispose();
    super.dispose();
  }

  void _save() {
    final acts = _activities
        .where((a) => (a['what'] ?? '').trim().isNotEmpty)
        .map((a) => {
              'what': (a['what'] ?? '').trim(),
              'place': (a['place'] ?? '').trim(),
              'time': (a['time'] ?? '').trim(),
            })
        .toList();
    Navigator.pop(context, {
      'day': int.tryParse(_dayNum.text.trim()) ?? 1,
      'title': _title.text.trim(),
      'activities': acts,
    });
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: Gap.lg,
        right: Gap.lg,
        top: Gap.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg,
      ),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(widget.existing == null ? tr.tvAddDay : tr.tvEditDay,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.md),
          Row(children: [
            SizedBox(
              width: 80,
              child: TextField(
                controller: _dayNum,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                    labelText: tr.tvFieldDayNum,
                    border: const OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: TextField(
                controller: _title,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                    labelText: tr.tvFieldDayTitle,
                    border: const OutlineInputBorder()),
              ),
            ),
          ]),
          const SizedBox(height: Gap.md),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(tr.tvActivitiesLabel,
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: Gap.sm),
          for (int idx = 0; idx < _activities.length; idx++)
            _ActivityRow(
              key: ValueKey(idx),
              activity: _activities[idx],
              onRemove: _activities.length > 1
                  ? () => setState(() => _activities.removeAt(idx))
                  : null,
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(
                  () => _activities.add({'what': '', 'place': '', 'time': ''})),
              icon: const Icon(Icons.add_rounded),
              label: Text(tr.tvAddActivity),
            ),
          ),
          const SizedBox(height: Gap.md),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(tr.cancel)),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: FilledButton(onPressed: _save, child: Text(tr.save)),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  final Map<String, String> activity;
  final VoidCallback? onRemove;
  const _ActivityRow({super.key, required this.activity, this.onRemove});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Column(children: [
        Row(children: [
          Expanded(
            child: TextField(
              controller: TextEditingController(text: activity['what'])
                ..selection = TextSelection.collapsed(
                    offset: (activity['what'] ?? '').length),
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                  labelText: tr.tvActivityWhat,
                  isDense: true,
                  border: const OutlineInputBorder()),
              onChanged: (v) => activity['what'] = v,
            ),
          ),
          if (onRemove != null)
            IconButton(
                icon: const Icon(Icons.remove_circle_outline_rounded),
                tooltip: tr.delete,
                onPressed: onRemove),
        ]),
        const SizedBox(height: Gap.xs),
        Row(children: [
          Expanded(
            child: TextField(
              controller: TextEditingController(text: activity['time'])
                ..selection = TextSelection.collapsed(
                    offset: (activity['time'] ?? '').length),
              decoration: InputDecoration(
                  labelText: tr.tvActivityTime,
                  isDense: true,
                  border: const OutlineInputBorder()),
              onChanged: (v) => activity['time'] = v,
            ),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: TextField(
              controller: TextEditingController(text: activity['place'])
                ..selection = TextSelection.collapsed(
                    offset: (activity['place'] ?? '').length),
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                  labelText: tr.tvActivityPlace,
                  isDense: true,
                  border: const OutlineInputBorder()),
              onChanged: (v) => activity['place'] = v,
            ),
          ),
        ]),
      ]),
    );
  }
}

// ======================= budget editor sheet =======================
class _BudgetEditorSheet extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _BudgetEditorSheet({this.existing});
  @override
  State<_BudgetEditorSheet> createState() => _BudgetEditorSheetState();
}

class _BudgetEditorSheetState extends State<_BudgetEditorSheet> {
  late String _category;
  late final TextEditingController _estimate;
  late final TextEditingController _actual;

  @override
  void initState() {
    super.initState();
    final e = widget.existing ?? {};
    _category = _budgetCategories.contains('${e['category'] ?? ''}')
        ? '${e['category']}'
        : 'transport';
    _estimate = TextEditingController(text: '${e['estimate'] ?? ''}');
    _actual = TextEditingController(text: '${e['actual'] ?? ''}');
  }

  @override
  void dispose() {
    _estimate.dispose();
    _actual.dispose();
    super.dispose();
  }

  void _save() {
    Navigator.pop(context, {
      'category': _category,
      'estimate': _estimate.text.trim(),
      'actual': _actual.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: Gap.lg,
        right: Gap.lg,
        top: Gap.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg,
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(widget.existing == null ? tr.tvAddBudget : tr.tvEditBudget,
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.md),
        DropdownButtonFormField<String>(
          initialValue: _category,
          decoration: InputDecoration(
              labelText: tr.tvFieldCategory,
              border: const OutlineInputBorder()),
          items: [
            for (final c in _budgetCategories)
              DropdownMenuItem(value: c, child: Text(_catLabel(tr, c))),
          ],
          onChanged: (v) => setState(() => _category = v ?? 'transport'),
        ),
        const SizedBox(height: Gap.md),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _estimate,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                  labelText: tr.tvFieldEstimate,
                  prefixText: '৳ ',
                  border: const OutlineInputBorder()),
            ),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: TextField(
              controller: _actual,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                  labelText: tr.tvFieldActual,
                  prefixText: '৳ ',
                  border: const OutlineInputBorder()),
            ),
          ),
        ]),
        const SizedBox(height: Gap.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(tr.tvBudgetEstimateNote,
              style: AType.labelSmall.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
        const SizedBox(height: Gap.lg),
        Row(children: [
          Expanded(
            child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                child: Text(tr.cancel)),
          ),
          const SizedBox(width: Gap.md),
          Expanded(
            child: FilledButton(onPressed: _save, child: Text(tr.save)),
          ),
        ]),
      ]),
    );
  }
}
