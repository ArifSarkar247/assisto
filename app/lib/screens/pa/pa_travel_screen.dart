import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
import '../../services/error_kind.dart' show honestFailText; // qa2

/// PA SECRETARY MODE — BOSS TRAVEL & ITINERARY builder (#112, §14, ADVANCED).
///
/// The PA builds the boss's trip entirely by hand, offline, with NO key: a trip
/// (title + dates), ordered LEGS (flight/train/car/bus/launch with from→to and
/// depart/arrive), STAYS (hotel + check-in/out), MEETINGS on the road, and a
/// packing/prep CHECKLIST — plus a deterministic printable itinerary summary and
/// a day-count / countdown.
///
/// HONEST, KEY-GATED (NEVER FABRICATES):
///   * Live booking / live prices are a DOCUMENTED key-gated seam shown as an
///     honest "connect a booking key" card (_BookingSeamCard). This screen NEVER
///     invents a flight, a price or a confirmation. Any ref shown is only text
///     the PA typed; nothing is ever booked, no money is held.
///
/// All math mirrors backend/core/logic/pa_travel.py (inclusive day span,
/// passed-in-today countdown, packing %, chronological event ordering) so the
/// views are deterministic and identical offline.
///
/// Honest states: welcome (no trips) · loading · error. ZERO Bangla literals —
/// every string is an AppLocalizations getter (৳ exempt).
///
/// Persistence (generic api helpers, no api.dart edit):
///   listItems('pa/travel')  → mixed rows tagged by {kind}:
///     {id, kind:'trip',    title, start, end, note}
///     {id, kind:'leg',     trip_id, mode, from_place, to_place, depart, arrive,
///                          ref, note}
///     {id, kind:'stay',    trip_id, name, address, check_in, check_out, note}
///     {id, kind:'meeting', trip_id, title, place, at, with_whom, note}
///     {id, kind:'pack',    trip_id, label, checked}
///   create/update/delete on 'pa/travel'; rows round-trip as {id, ...data}
///   through one flexible per-user JSON collection (PaCollectionItem precedent).
class PaTravelScreen extends StatefulWidget {
  const PaTravelScreen({super.key});
  @override
  State<PaTravelScreen> createState() => _PaTravelScreenState();
}

const String _path = 'pa/travel';

const List<String> _legModes = ['flight', 'train', 'car', 'bus', 'launch'];

String _today() {
  final n = DateTime.now();
  return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
}

DateTime? _parse(String s) {
  var x = s.trim();
  if (x.isEmpty) return null;
  if (x.endsWith('Z')) x = x.substring(0, x.length - 1);
  return DateTime.tryParse(x) ?? DateTime.tryParse('${x}T00:00:00');
}

int _daySpan(String start, String end) {
  final s = _parse(start), e = _parse(end);
  if (s == null || e == null || e.isBefore(s)) return 0;
  return DateTime(e.year, e.month, e.day)
          .difference(DateTime(s.year, s.month, s.day))
          .inDays +
      1;
}

int? _countdown(String start, String todayIso) {
  final s = _parse(start), n = _parse(todayIso);
  if (s == null || n == null) return null;
  return DateTime(s.year, s.month, s.day)
      .difference(DateTime(n.year, n.month, n.day))
      .inDays;
}

const String _far = '9999-12-31T23:59:59';

String _eventKey(Map<String, dynamic> e, String field) {
  final t = _parse('${e[field] ?? ''}');
  return t?.toIso8601String() ?? _far;
}

List<Map<String, dynamic>> _ordered(
    Iterable<Map<String, dynamic>> rows, String field) {
  final out = rows.toList();
  out.sort((a, b) => _eventKey(a, field).compareTo(_eventKey(b, field)));
  return out;
}

class _PaTravelScreenState extends State<PaTravelScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  bool _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

  AppLocalizations get t => AppLocalizations.of(context);

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
      _rows = await context.read<AppState>().api.listItems(_path);
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  List<Map<String, dynamic>> get _trips =>
      _rows.where((r) => '${r['kind']}' == 'trip').toList();

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _openTripEditor([Map<String, dynamic>? existing]) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _TripEditor(existing: existing),
    );
    if (result == null) return;
    final api = context.read<AppState>().api;
    try {
      if (existing != null && existing['id'] is int) {
        await api.updateItem(_path, existing['id'] as int, result);
      } else {
        await api.createItem(_path, {...result, 'kind': 'trip'});
      }
      await _load();
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
          appBar: AppBar(title: Text(t.paTravelTitle)),
          body: const SkeletonList());
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text(t.paTravelTitle)),
        body: StateMessage(
          icon: Icons.cloud_off,
          tint: scheme.error,
          title: t.loadFailed,
          message: honestFailText(t, _failCause, otherwise: t.paTravelLoadError),
          action: FilledButton.tonalIcon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: Text(t.retry)),
        ),
      );
    }
    final trips = _trips;
    return Scaffold(
      appBar: AppBar(title: Text(t.paTravelTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openTripEditor(),
        icon: const Icon(Icons.add),
        label: Text(t.paTravelNewTrip),
      ),
      body: trips.isEmpty
          ? StateMessage(
              icon: Icons.flight_takeoff,
              tint: Brand.blue,
              title: t.paTravelWelcomeTitle,
              message: t.paTravelWelcomeBody,
              action: FilledButton.icon(
                onPressed: () => _openTripEditor(),
                icon: const Icon(Icons.add),
                label: Text(t.paTravelNewTrip),
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
                children: [
                  const _BookingSeamCard(),
                  const SizedBox(height: Gap.sm),
                  for (final tr in trips)
                    _TripCard(
                      trip: tr,
                      onOpen: () async {
                        await Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => _TripDetailScreen(trip: tr),
                        ));
                        await _load();
                      },
                      onEdit: () => _openTripEditor(tr),
                    ),
                ],
              ),
            ),
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
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final start = '${trip['start'] ?? ''}';
    final end = '${trip['end'] ?? ''}';
    final days = _daySpan(start, end);
    final cd = _countdown(start, _today());
    String cdText;
    if (cd == null) {
      cdText = '';
    } else if (cd > 0) {
      cdText = t.paTravelCountdown(cd);
    } else if (cd == 0) {
      cdText = t.paTravelStartsToday;
    } else {
      cdText = t.paTravelOngoingPast(-cd);
    }
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: ListTile(
        onTap: onOpen,
        leading: CircleAvatar(
          backgroundColor: scheme.primaryContainer,
          child: Icon(Icons.card_travel, color: scheme.onPrimaryContainer),
        ),
        title: Text('${trip['title'] ?? ''}',
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (start.isNotEmpty || end.isNotEmpty)
              Text('$start → $end',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            Wrap(spacing: 6, children: [
              if (days > 0)
                _chip(t.paTravelDaysCount(days), scheme.secondary),
              if (cdText.isNotEmpty) _chip(cdText, scheme.primary),
            ]),
          ],
        ),
        trailing: IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: t.edit,
            onPressed: onEdit),
      ),
    );
  }

  Widget _chip(String label, Color c) => Container(
        margin: const EdgeInsets.only(top: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
            color: c.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(Radii.pill)),
        child: Text(label,
            style: TextStyle(
                fontSize: 11.5, fontWeight: FontWeight.w700, color: c)),
      );
}

// ======================= trip detail =======================
class _TripDetailScreen extends StatefulWidget {
  final Map<String, dynamic> trip;
  const _TripDetailScreen({required this.trip});
  @override
  State<_TripDetailScreen> createState() => _TripDetailScreenState();
}

class _TripDetailScreenState extends State<_TripDetailScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;

  AppLocalizations get t => AppLocalizations.of(context);
  int get _tripId => widget.trip['id'] as int;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final all = await context.read<AppState>().api.listItems(_path);
      _rows = all.where((r) => r['trip_id'] == _tripId).toList();
    } catch (_) {
      _rows = [];
    }
    if (mounted) setState(() => _loading = false);
  }

  List<Map<String, dynamic>> _ofKind(String k) =>
      _rows.where((r) => '${r['kind']}' == k).toList();

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _create(Map<String, dynamic> body) async {
    try {
      await context
          .read<AppState>()
          .api
          .createItem(_path, {...body, 'trip_id': _tripId});
      await _load();
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
    }
  }

  Future<void> _update(int id, Map<String, dynamic> body) async {
    try {
      await context
          .read<AppState>()
          .api
          .updateItem(_path, id, {...body, 'trip_id': _tripId});
      await _load();
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
    }
  }

  Future<void> _delete(int id) async {
    try {
      await context.read<AppState>().api.deleteItem(_path, id);
      await _load();
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final legs = _ordered(_ofKind('leg'), 'depart');
    final stays = _ordered(_ofKind('stay'), 'check_in');
    final meetings = _ordered(_ofKind('meeting'), 'at');
    final packing = _ofKind('pack');
    final checked = packing.where((p) => p['checked'] == true).length;
    final pct = packing.isEmpty ? 0 : (checked * 100 ~/ packing.length);

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.trip['title'] ?? ''}',
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: _loading
          ? const SkeletonList()
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 40),
                children: [
                  const _BookingSeamCard(),
                  const SizedBox(height: Gap.lg),

                  // ---- legs ----
                  _SectionHeader(
                      icon: Icons.alt_route,
                      label: t.paTravelLegsHeader,
                      onAdd: () => _editLeg()),
                  if (legs.isEmpty)
                    _EmptyLine(t.paTravelNoLegs)
                  else
                    for (final l in legs)
                      _LegTile(
                        leg: l,
                        modeLabel: _modeLabel(l),
                        onEdit: () => _editLeg(l),
                        onDelete: () => _delete(l['id'] as int),
                      ),
                  const SizedBox(height: Gap.lg),

                  // ---- stays ----
                  _SectionHeader(
                      icon: Icons.hotel,
                      label: t.paTravelStaysHeader,
                      onAdd: () => _editStay()),
                  if (stays.isEmpty)
                    _EmptyLine(t.paTravelNoStays)
                  else
                    for (final s in stays)
                      _TwoLineTile(
                        icon: Icons.hotel_outlined,
                        title: '${s['name'] ?? ''}',
                        subtitle:
                            '${s['check_in'] ?? ''} → ${s['check_out'] ?? ''}',
                        onEdit: () => _editStay(s),
                        onDelete: () => _delete(s['id'] as int),
                      ),
                  const SizedBox(height: Gap.lg),

                  // ---- meetings ----
                  _SectionHeader(
                      icon: Icons.groups_2_outlined,
                      label: t.paTravelMeetingsHeader,
                      onAdd: () => _editMeeting()),
                  if (meetings.isEmpty)
                    _EmptyLine(t.paTravelNoMeetings)
                  else
                    for (final m in meetings)
                      _TwoLineTile(
                        icon: Icons.event_outlined,
                        title: '${m['title'] ?? ''}',
                        subtitle: [
                          '${m['at'] ?? ''}',
                          '${m['place'] ?? ''}',
                          '${m['with_whom'] ?? ''}'
                        ].where((x) => x.trim().isNotEmpty).join(' · '),
                        onEdit: () => _editMeeting(m),
                        onDelete: () => _delete(m['id'] as int),
                      ),
                  const SizedBox(height: Gap.lg),

                  // ---- packing ----
                  _SectionHeader(
                      icon: Icons.checklist,
                      label: t.paTravelPackingHeader,
                      onAdd: () => _addPack()),
                  if (packing.isNotEmpty) ...[
                    Padding(
                      padding:
                          const EdgeInsets.symmetric(vertical: Gap.xs),
                      child: Row(children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(Radii.pill),
                            child: LinearProgressIndicator(
                                value: pct / 100,
                                minHeight: 8,
                                backgroundColor:
                                    scheme.surfaceContainerHighest),
                          ),
                        ),
                        const SizedBox(width: Gap.sm),
                        Text(t.paTravelPackingProgress(checked, packing.length),
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)),
                      ]),
                    ),
                  ],
                  if (packing.isEmpty)
                    _EmptyLine(t.paTravelNoPacking)
                  else
                    for (final p in packing)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        value: p['checked'] == true,
                        onChanged: (v) => _update(p['id'] as int,
                            {'kind': 'pack', 'label': p['label'], 'checked': v}),
                        title: Text('${p['label'] ?? ''}'),
                        secondary: IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            tooltip: t.delete,
                            onPressed: () => _delete(p['id'] as int)),
                      ),
                  const SizedBox(height: Gap.xl),

                  // ---- printable summary ----
                  OutlinedButton.icon(
                    icon: const Icon(Icons.summarize_outlined),
                    label: Text(t.paTravelSummaryButton),
                    onPressed: () => showModalBottomSheet(
                      context: context,
                      isScrollControlled: true,
                      showDragHandle: true,
                      builder: (_) => _ItinerarySummarySheet(
                        trip: widget.trip,
                        legs: legs,
                        stays: stays,
                        meetings: meetings,
                        checked: checked,
                        packTotal: packing.length,
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  String _modeLabel(Map<String, dynamic> l) {
    switch ('${l['mode']}') {
      case 'flight':
        return t.paTravelModeFlight;
      case 'train':
        return t.paTravelModeTrain;
      case 'bus':
        return t.paTravelModeBus;
      case 'launch':
        return t.paTravelModeLaunch;
      default:
        return t.paTravelModeCar;
    }
  }

  // ---- editors ----
  Future<void> _editLeg([Map<String, dynamic>? e]) async {
    final r = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _LegEditor(existing: e, modeLabel: _modeLabel),
    );
    if (r == null) return;
    if (e != null && e['id'] is int) {
      await _update(e['id'] as int, r);
    } else {
      await _create(r);
    }
  }

  Future<void> _editStay([Map<String, dynamic>? e]) async {
    final r = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _StayEditor(existing: e),
    );
    if (r == null) return;
    if (e != null && e['id'] is int) {
      await _update(e['id'] as int, r);
    } else {
      await _create(r);
    }
  }

  Future<void> _editMeeting([Map<String, dynamic>? e]) async {
    final r = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _MeetingEditor(existing: e),
    );
    if (r == null) return;
    if (e != null && e['id'] is int) {
      await _update(e['id'] as int, r);
    } else {
      await _create(r);
    }
  }

  Future<void> _addPack() async {
    final label = await _promptText(context, t.paTravelPackLabel);
    if (label == null || label.trim().isEmpty) return;
    await _create({'kind': 'pack', 'label': label.trim(), 'checked': false});
  }
}

// ======================= booking seam (key-gated) =======================
class _BookingSeamCard extends StatelessWidget {
  const _BookingSeamCard();
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.secondaryContainer.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.confirmation_number_outlined,
              size: 20, color: scheme.secondary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.paTravelBookingSeamTitle,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(t.paTravelBookingSeamBody,
                  style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                      height: 1.35)),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ======================= small shared widgets =======================
class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onAdd;
  const _SectionHeader(
      {required this.icon, required this.label, required this.onAdd});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(children: [
      Icon(icon, size: 18, color: scheme.primary),
      const SizedBox(width: Gap.sm),
      Expanded(
          child: Text(label,
              style:
                  const TextStyle(fontWeight: FontWeight.w800, fontSize: 15))),
      IconButton(
          icon: const Icon(Icons.add_circle_outline),
          tooltip: AppLocalizations.of(context).add,
          onPressed: onAdd),
    ]);
  }
}

class _EmptyLine extends StatelessWidget {
  final String text;
  const _EmptyLine(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.sm),
        child: Text(text,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 13)),
      );
}

class _TwoLineTile extends StatelessWidget {
  final IconData icon;
  final String title, subtitle;
  final VoidCallback onEdit, onDelete;
  const _TwoLineTile(
      {required this.icon,
      required this.title,
      required this.subtitle,
      required this.onEdit,
      required this.onDelete});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(icon),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle.trim().isEmpty
          ? null
          : Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: PopupMenuButton<String>(
        onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
        itemBuilder: (_) => [
          PopupMenuItem(value: 'edit', child: Text(t.edit)),
          PopupMenuItem(value: 'delete', child: Text(t.delete)),
        ],
      ),
    );
  }
}

class _LegTile extends StatelessWidget {
  final Map<String, dynamic> leg;
  final String modeLabel;
  final VoidCallback onEdit, onDelete;
  const _LegTile(
      {required this.leg,
      required this.modeLabel,
      required this.onEdit,
      required this.onDelete});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final ref = '${leg['ref'] ?? ''}'.trim();
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: const Icon(Icons.swap_horiz),
      title: Text('${leg['from_place'] ?? ''} → ${leg['to_place'] ?? ''}',
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(<String>[
        modeLabel,
        '${leg['depart'] ?? ''}',
        if (ref.isNotEmpty) t.paTravelRefLabel(ref),
      ].where((x) => x.trim().isNotEmpty).join(' · '),
          maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: PopupMenuButton<String>(
        onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
        itemBuilder: (_) => [
          PopupMenuItem(value: 'edit', child: Text(t.edit)),
          PopupMenuItem(value: 'delete', child: Text(t.delete)),
        ],
      ),
    );
  }
}

// ======================= editors =======================
class _TripEditor extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _TripEditor({this.existing});
  @override
  State<_TripEditor> createState() => _TripEditorState();
}

class _TripEditorState extends State<_TripEditor> {
  late final TextEditingController _title =
      TextEditingController(text: '${widget.existing?['title'] ?? ''}');
  late final TextEditingController _note =
      TextEditingController(text: '${widget.existing?['note'] ?? ''}');
  late String _start = '${widget.existing?['start'] ?? ''}';
  late String _end = '${widget.existing?['end'] ?? ''}';

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  void _save() {
    if (_title.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.paTravelTitleRequired)));
      return;
    }
    Navigator.pop(context, {
      'kind': 'trip',
      'title': _title.text.trim(),
      'start': _start,
      'end': _end,
      'note': _note.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(widget.existing == null ? t.paTravelNewTrip : t.edit,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: Gap.lg),
          TextField(
            controller: _title,
            autofocus: true,
            decoration: InputDecoration(
                labelText: t.paTravelTripTitleLabel,
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          _DateField(
              label: t.paTravelStartLabel,
              value: _start,
              onPick: (v) => setState(() => _start = v)),
          const SizedBox(height: Gap.md),
          _DateField(
              label: t.paTravelEndLabel,
              value: _end,
              onPick: (v) => setState(() => _end = v)),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _note,
            maxLines: 2,
            decoration: InputDecoration(
                labelText: t.paTravelNoteLabel,
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.lg),
          SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: _save, child: Text(t.save))),
        ]),
      ),
    );
  }
}

class _LegEditor extends StatefulWidget {
  final Map<String, dynamic>? existing;
  final String Function(Map<String, dynamic>) modeLabel;
  const _LegEditor({this.existing, required this.modeLabel});
  @override
  State<_LegEditor> createState() => _LegEditorState();
}

class _LegEditorState extends State<_LegEditor> {
  late final TextEditingController _from =
      TextEditingController(text: '${widget.existing?['from_place'] ?? ''}');
  late final TextEditingController _to =
      TextEditingController(text: '${widget.existing?['to_place'] ?? ''}');
  late final TextEditingController _ref =
      TextEditingController(text: '${widget.existing?['ref'] ?? ''}');
  late String _mode = _legModes.contains('${widget.existing?['mode']}')
      ? '${widget.existing!['mode']}'
      : 'flight';
  late String _depart = '${widget.existing?['depart'] ?? ''}';

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    _ref.dispose();
    super.dispose();
  }

  void _save() {
    if (_from.text.trim().isEmpty || _to.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.paTravelLegFromToRequired)));
      return;
    }
    Navigator.pop(context, {
      'kind': 'leg',
      'mode': _mode,
      'from_place': _from.text.trim(),
      'to_place': _to.text.trim(),
      'depart': _depart,
      'ref': _ref.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + bottom),
      child: SingleChildScrollView(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.paTravelLegsHeader,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: Gap.md),
              Wrap(spacing: Gap.sm, children: [
                for (final m in _legModes)
                  ChoiceChip(
                    label: Text(widget.modeLabel({'mode': m})),
                    selected: _mode == m,
                    onSelected: (_) => setState(() => _mode = m),
                  ),
              ]),
              const SizedBox(height: Gap.md),
              TextField(
                  controller: _from,
                  decoration: InputDecoration(
                      labelText: t.paTravelFromLabel,
                      border: const OutlineInputBorder())),
              const SizedBox(height: Gap.md),
              TextField(
                  controller: _to,
                  decoration: InputDecoration(
                      labelText: t.paTravelToLabel,
                      border: const OutlineInputBorder())),
              const SizedBox(height: Gap.md),
              _DateField(
                  label: t.paTravelDepartLabel,
                  value: _depart,
                  withTime: true,
                  onPick: (v) => setState(() => _depart = v)),
              const SizedBox(height: Gap.md),
              TextField(
                  controller: _ref,
                  decoration: InputDecoration(
                      labelText: t.paTravelRefFieldLabel,
                      helperText: t.paTravelRefHelper,
                      border: const OutlineInputBorder())),
              const SizedBox(height: Gap.lg),
              SizedBox(
                  width: double.infinity,
                  child:
                      FilledButton(onPressed: _save, child: Text(t.save))),
            ]),
      ),
    );
  }
}

class _StayEditor extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _StayEditor({this.existing});
  @override
  State<_StayEditor> createState() => _StayEditorState();
}

class _StayEditorState extends State<_StayEditor> {
  late final TextEditingController _name =
      TextEditingController(text: '${widget.existing?['name'] ?? ''}');
  late final TextEditingController _addr =
      TextEditingController(text: '${widget.existing?['address'] ?? ''}');
  late String _in = '${widget.existing?['check_in'] ?? ''}';
  late String _out = '${widget.existing?['check_out'] ?? ''}';

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void dispose() {
    _name.dispose();
    _addr.dispose();
    super.dispose();
  }

  void _save() {
    if (_name.text.trim().isEmpty) {
      Navigator.pop(context);
      return;
    }
    Navigator.pop(context, {
      'kind': 'stay',
      'name': _name.text.trim(),
      'address': _addr.text.trim(),
      'check_in': _in,
      'check_out': _out,
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(t.paTravelStaysHeader,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: Gap.md),
          TextField(
              controller: _name,
              autofocus: true,
              decoration: InputDecoration(
                  labelText: t.paTravelStayNameLabel,
                  border: const OutlineInputBorder())),
          const SizedBox(height: Gap.md),
          TextField(
              controller: _addr,
              decoration: InputDecoration(
                  labelText: t.paTravelStayAddressLabel,
                  border: const OutlineInputBorder())),
          const SizedBox(height: Gap.md),
          _DateField(
              label: t.paTravelCheckInLabel,
              value: _in,
              onPick: (v) => setState(() => _in = v)),
          const SizedBox(height: Gap.md),
          _DateField(
              label: t.paTravelCheckOutLabel,
              value: _out,
              onPick: (v) => setState(() => _out = v)),
          const SizedBox(height: Gap.lg),
          SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: _save, child: Text(t.save))),
        ]),
      ),
    );
  }
}

class _MeetingEditor extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _MeetingEditor({this.existing});
  @override
  State<_MeetingEditor> createState() => _MeetingEditorState();
}

class _MeetingEditorState extends State<_MeetingEditor> {
  late final TextEditingController _title =
      TextEditingController(text: '${widget.existing?['title'] ?? ''}');
  late final TextEditingController _place =
      TextEditingController(text: '${widget.existing?['place'] ?? ''}');
  late final TextEditingController _with =
      TextEditingController(text: '${widget.existing?['with_whom'] ?? ''}');
  late String _at = '${widget.existing?['at'] ?? ''}';

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void dispose() {
    _title.dispose();
    _place.dispose();
    _with.dispose();
    super.dispose();
  }

  void _save() {
    if (_title.text.trim().isEmpty) {
      Navigator.pop(context);
      return;
    }
    Navigator.pop(context, {
      'kind': 'meeting',
      'title': _title.text.trim(),
      'place': _place.text.trim(),
      'with_whom': _with.text.trim(),
      'at': _at,
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(t.paTravelMeetingsHeader,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: Gap.md),
          TextField(
              controller: _title,
              autofocus: true,
              decoration: InputDecoration(
                  labelText: t.paTravelMeetingTitleLabel,
                  border: const OutlineInputBorder())),
          const SizedBox(height: Gap.md),
          _DateField(
              label: t.paTravelMeetingAtLabel,
              value: _at,
              withTime: true,
              onPick: (v) => setState(() => _at = v)),
          const SizedBox(height: Gap.md),
          TextField(
              controller: _place,
              decoration: InputDecoration(
                  labelText: t.paTravelMeetingPlaceLabel,
                  border: const OutlineInputBorder())),
          const SizedBox(height: Gap.md),
          TextField(
              controller: _with,
              decoration: InputDecoration(
                  labelText: t.paTravelMeetingWithLabel,
                  border: const OutlineInputBorder())),
          const SizedBox(height: Gap.lg),
          SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: _save, child: Text(t.save))),
        ]),
      ),
    );
  }
}

// ======================= itinerary summary sheet =======================
class _ItinerarySummarySheet extends StatelessWidget {
  final Map<String, dynamic> trip;
  final List<Map<String, dynamic>> legs, stays, meetings;
  final int checked, packTotal;
  const _ItinerarySummarySheet(
      {required this.trip,
      required this.legs,
      required this.stays,
      required this.meetings,
      required this.checked,
      required this.packTotal});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final days = _daySpan('${trip['start'] ?? ''}', '${trip['end'] ?? ''}');
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      builder: (_, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          Text('${trip['title'] ?? ''}',
              style:
                  const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('${trip['start'] ?? ''} → ${trip['end'] ?? ''}'),
          if (days > 0) Text(t.paTravelDaysCount(days)),
          const Divider(height: Gap.xl),
          _summarySection(context, t.paTravelLegsHeader, [
            for (final l in legs)
              '${l['from_place'] ?? ''} → ${l['to_place'] ?? ''}'
                  '${'${l['depart'] ?? ''}'.trim().isEmpty ? '' : '  (${l['depart']})'}',
          ]),
          _summarySection(context, t.paTravelStaysHeader, [
            for (final s in stays)
              '${s['name'] ?? ''}'
                  '${'${s['check_in'] ?? ''}'.trim().isEmpty ? '' : '  (${s['check_in']} → ${s['check_out'] ?? ''})'}',
          ]),
          _summarySection(context, t.paTravelMeetingsHeader, [
            for (final m in meetings)
              '${m['title'] ?? ''}'
                  '${'${m['at'] ?? ''}'.trim().isEmpty ? '' : '  (${m['at']})'}',
          ]),
          const SizedBox(height: Gap.sm),
          if (packTotal > 0)
            Text(t.paTravelPackingProgress(checked, packTotal),
                style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.md),
          Text(t.paTravelBookingSeamBody,
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _summarySection(
      BuildContext context, String title, List<String> lines) {
    if (lines.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: Gap.sm),
        Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
        for (final l in lines) Text('• $l'),
      ],
    );
  }
}

// ======================= date field + text prompt =======================
class _DateField extends StatelessWidget {
  final String label;
  final String value;
  final bool withTime;
  final ValueChanged<String> onPick;
  const _DateField(
      {required this.label,
      required this.value,
      required this.onPick,
      this.withTime = false});
  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      icon: const Icon(Icons.event, size: 18),
      label: Align(
        alignment: Alignment.centerLeft,
        child: Text(value.isEmpty ? label : '$label: $value'),
      ),
      style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          alignment: Alignment.centerLeft),
      onPressed: () async {
        final now = DateTime.now();
        final initial = _parse(value) ?? now;
        final picked = await showDatePicker(
          context: context,
          initialDate: initial,
          firstDate: DateTime(now.year - 1),
          lastDate: DateTime(now.year + 5),
        );
        if (picked == null) return;
        var out = picked;
        if (withTime && context.mounted) {
          final tm = await showTimePicker(
              context: context,
              initialTime: TimeOfDay.fromDateTime(initial));
          if (tm != null) {
            out = DateTime(
                picked.year, picked.month, picked.day, tm.hour, tm.minute);
          }
        }
        final y = out.year.toString().padLeft(4, '0');
        final mo = out.month.toString().padLeft(2, '0');
        final d = out.day.toString().padLeft(2, '0');
        onPick(withTime
            ? '$y-$mo-${d}T${out.hour.toString().padLeft(2, '0')}:${out.minute.toString().padLeft(2, '0')}'
            : '$y-$mo-$d');
      },
    );
  }
}

Future<String?> _promptText(BuildContext context, String label) {
  final c = TextEditingController();
  final t = AppLocalizations.of(context);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(label),
      content: TextField(
          controller: c,
          autofocus: true,
          decoration: InputDecoration(labelText: label)),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: Text(t.cancel)),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text), child: Text(t.save)),
      ],
    ),
  );
}
