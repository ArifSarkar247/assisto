import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../widgets/life_leave_now_card.dart';

/// Meetings / appointments (module-5 "Life"). Benchmarked vs Google / Apple
/// Calendar + Calendly:
///   - schedule a meeting (title, time, place, duration, note)
///   - reminders before it fire (1 day + 1 hour by default)
///   - "Leave now" (bn label via l10n): with a best-effort travel estimate the user
///     types (we never invent traffic), we compute when to leave + a Maps
///     directions deep-link.
///
/// Logic mirrors core.logic.meetings (reminder_times / leave_now_phase /
/// conflicts). Appointments persist locally and sync to the backend
/// `appointments` collection (integrator wires the model — see report).
class MeetingsScreen extends StatefulWidget {
  const MeetingsScreen({super.key});
  @override
  State<MeetingsScreen> createState() => _MeetingsScreenState();
}

class _MeetingsScreenState extends State<MeetingsScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _appts = [];

  // Entered travel estimate per appointment, keyed by a stable appointment key,
  // so a list rebuild (add/delete/reschedule) does NOT reset what the user
  // typed into the "Leave now" card. Owned by the parent (the cards are
  // rebuilt stateless children).
  final Map<String, int> _travelMinByAppt = {};

  // Stable-enough key for an appointment map (no server id is present): start
  // time + title uniquely identify a row within the local list.
  String _apptKey(Map<String, dynamic> a) => '${a['start']}|${a['title'] ?? ''}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  AppState get _app => context.read<AppState>();

  Future<void> _load() async {
    try {
      final rows = await _app.api.listItems('appointments');
      _appts = rows.map((r) => (r['data'] as Map<String, dynamic>?) ?? r).toList();
    } catch (_) {
      _appts = [];
    }
    if (mounted) setState(() => _loading = false);
  }

  // Mirror meetings.upcoming: future only, sorted ascending.
  List<Map<String, dynamic>> get _upcoming {
    final now = DateTime.now();
    final list = _appts.where((a) {
      final s = DateTime.tryParse('${a['start']}');
      return s != null && s.isAfter(now);
    }).toList()
      ..sort((a, b) => DateTime.parse('${a['start']}')
          .compareTo(DateTime.parse('${b['start']}')));
    return list;
  }

  // Mirror meetings.conflicts: index pairs whose [start,end) ranges overlap.
  Set<int> _conflictingIds(List<Map<String, dynamic>> list) {
    final out = <int>{};
    for (var i = 0; i < list.length; i++) {
      final si = DateTime.tryParse('${list[i]['start']}');
      if (si == null) continue;
      final ei = si.add(Duration(minutes: ((list[i]['duration_min'] ?? 60) as num).toInt()));
      for (var j = i + 1; j < list.length; j++) {
        final sj = DateTime.tryParse('${list[j]['start']}');
        if (sj == null) continue;
        final ej = sj.add(Duration(minutes: ((list[j]['duration_min'] ?? 60) as num).toInt()));
        if (si.isBefore(ej) && sj.isBefore(ei)) {
          out.add(i);
          out.add(j);
        }
      }
    }
    return out;
  }

  Future<void> _save() async {
    try {
      await _app.api.createItem('appointments', {'items': _appts});
    } catch (_) {}
  }

  Future<void> _add() async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _AppointmentEditor(),
    );
    if (result != null) {
      setState(() => _appts = [..._appts, result]);
      await _save();
    }
  }

  Future<void> _delete(Map<String, dynamic> a) async {
    setState(() => _appts = _appts.where((x) => x != a).toList());
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(t.meetingsTitle)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final list = _upcoming;
    final conflicts = _conflictingIds(list);
    final fmt = DateFormat('EEE d MMM, h:mm a');
    return Scaffold(
      appBar: AppBar(title: Text(t.meetingsTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: Text(t.meetingsAdd),
      ),
      body: list.isEmpty
          ? _Empty(t: t, onAdd: _add)
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
              itemCount: list.length,
              separatorBuilder: (_, __) => const SizedBox(height: Gap.sm),
              itemBuilder: (ctx, i) {
                final a = list[i];
                final start = DateTime.parse('${a['start']}');
                final key = _apptKey(a);
                return _MeetingCard(
                  title: '${a['title']}',
                  whenLabel: fmt.format(start),
                  place: '${a['place'] ?? ''}',
                  note: '${a['note'] ?? ''}',
                  start: start,
                  placeLat: (a['place_lat'] as num?)?.toDouble(),
                  placeLng: (a['place_lng'] as num?)?.toDouble(),
                  conflict: conflicts.contains(i),
                  onDelete: () => _delete(a),
                  travelMin: _travelMinByAppt[key],
                  onTravelChanged: (m) => setState(() {
                    if (m == null) {
                      _travelMinByAppt.remove(key);
                    } else {
                      _travelMinByAppt[key] = m;
                    }
                  }),
                );
              },
            ),
    );
  }
}

class _MeetingCard extends StatelessWidget {
  final String title;
  final String whenLabel;
  final String place;
  final String note;
  final DateTime start;
  final double? placeLat;
  final double? placeLng;
  final bool conflict;
  final VoidCallback onDelete;
  final int? travelMin;
  final ValueChanged<int?> onTravelChanged;
  const _MeetingCard({
    required this.title,
    required this.whenLabel,
    required this.place,
    required this.note,
    required this.start,
    required this.placeLat,
    required this.placeLng,
    required this.conflict,
    required this.onDelete,
    required this.travelMin,
    required this.onTravelChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(title,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: onDelete,
            ),
          ]),
          Row(children: [
            Icon(Icons.schedule, size: 15, color: scheme.primary),
            const SizedBox(width: 6),
            Text(whenLabel, style: TextStyle(color: scheme.primary)),
          ]),
          if (place.isNotEmpty) ...[
            const SizedBox(height: 4),
            Row(children: [
              const Icon(Icons.place_outlined, size: 15, color: Colors.grey),
              const SizedBox(width: 6),
              Expanded(child: Text(place, style: const TextStyle(color: Colors.grey))),
            ]),
          ],
          if (note.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(note, style: const TextStyle(fontSize: 13)),
          ],
          if (conflict) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Brand.warning.withOpacity(0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.warning_amber_rounded, size: 15, color: Color(0xFF8A6D00)),
                const SizedBox(width: 6),
                Text(t.meetingsConflict,
                    style: const TextStyle(fontSize: 12, color: Color(0xFF8A6D00))),
              ]),
            ),
          ],
          const SizedBox(height: Gap.sm),
          LifeLeaveNowCard(
            start: start,
            placeName: place.isEmpty ? null : place,
            placeLat: placeLat,
            placeLng: placeLng,
            travelMin: travelMin,
            onTravelChanged: onTravelChanged,
          ),
        ]),
      ),
    );
  }
}

/// Bottom-sheet editor for a new appointment. Mirrors
/// meetings.normalise_appointment (title + start required, duration clamped).
class _AppointmentEditor extends StatefulWidget {
  const _AppointmentEditor();
  @override
  State<_AppointmentEditor> createState() => _AppointmentEditorState();
}

class _AppointmentEditorState extends State<_AppointmentEditor> {
  final _title = TextEditingController();
  final _place = TextEditingController();
  final _note = TextEditingController();
  DateTime _date = DateTime.now().add(const Duration(days: 1));
  TimeOfDay _time = const TimeOfDay(hour: 10, minute: 0);
  int _duration = 60;

  @override
  void dispose() {
    _title.dispose();
    _place.dispose();
    _note.dispose();
    super.dispose();
  }

  DateTime get _start =>
      DateTime(_date.year, _date.month, _date.day, _time.hour, _time.minute);

  void _submit() {
    final t = AppLocalizations.of(context);
    if (_title.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.meetingsTitleRequired)));
      return;
    }
    Navigator.pop(context, {
      'title': _title.text.trim(),
      'start': _start.toIso8601String(),
      'duration_min': _duration.clamp(5, 1440),
      'place': _place.text.trim(),
      'note': _note.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final df = DateFormat('EEE d MMM');
    return Padding(
      padding: EdgeInsets.only(
        left: Gap.lg,
        right: Gap.lg,
        top: Gap.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg,
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(t.meetingsAdd, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        const SizedBox(height: Gap.md),
        TextField(
          controller: _title,
          decoration: InputDecoration(labelText: t.meetingsFieldTitle),
          textCapitalization: TextCapitalization.sentences,
        ),
        const SizedBox(height: Gap.sm),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.calendar_today, size: 16),
              label: Text(df.format(_date)),
              onPressed: () async {
                final d = await showDatePicker(
                  context: context,
                  initialDate: _date,
                  firstDate: DateTime.now().subtract(const Duration(days: 1)),
                  lastDate: DateTime.now().add(const Duration(days: 730)),
                );
                if (d != null) setState(() => _date = d);
              },
            ),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.schedule, size: 16),
              label: Text(_time.format(context)),
              onPressed: () async {
                final p = await showTimePicker(context: context, initialTime: _time);
                if (p != null) setState(() => _time = p);
              },
            ),
          ),
        ]),
        const SizedBox(height: Gap.sm),
        TextField(
          controller: _place,
          decoration: InputDecoration(labelText: t.meetingsFieldPlace),
        ),
        const SizedBox(height: Gap.sm),
        Row(children: [
          Text(t.meetingsFieldDuration),
          Expanded(
            child: Slider(
              value: _duration.toDouble(),
              min: 15,
              max: 240,
              divisions: 15,
              label: '$_duration',
              onChanged: (v) => setState(() => _duration = v.round()),
            ),
          ),
          Text(t.meetingsMinutes(_duration)),
        ]),
        TextField(
          controller: _note,
          decoration: InputDecoration(labelText: t.meetingsFieldNote),
          maxLines: 2,
        ),
        const SizedBox(height: Gap.md),
        SizedBox(
          width: double.infinity,
          child: FilledButton(onPressed: _submit, child: Text(t.save)),
        ),
      ]),
    );
  }
}

class _Empty extends StatelessWidget {
  final AppLocalizations t;
  final VoidCallback onAdd;
  const _Empty({required this.t, required this.onAdd});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.event_available_outlined, size: 56, color: Colors.grey),
          const SizedBox(height: Gap.md),
          Text(t.meetingsEmptyTitle,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: Gap.xs),
          Text(t.meetingsEmptyBody,
              textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)),
          const SizedBox(height: Gap.lg),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: Text(t.meetingsAdd),
          ),
        ]),
      ),
    );
  }
}
