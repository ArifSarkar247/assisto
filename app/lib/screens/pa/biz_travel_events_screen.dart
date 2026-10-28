import '../../feature_gates.dart' show kShowKeySeams;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
import 'package:assisto/widgets/app_sheet.dart';
import '../../services/error_kind.dart' show honestFailText; // qa2

/// PA SECRETARY MODE — CORPORATE BUSINESS TRAVEL & EVENTS (#119, §14, ADVANCED).
///
/// This is the COMPANY / TEAM counterpart to the personal boss-trip builder
/// (#112, pa_travel_screen.dart) and is deliberately DISTINCT: the PA
/// coordinates a multi-attendee EVENT (name, date, venue), per-attendee TRAVEL
/// arrangements, a shared AGENDA, a BUDGET (৳ estimated vs actual), a logistics
/// CHECKLIST and a countdown — delegate coordination, not one person's trip.
///
/// HONEST, KEY-GATED (NEVER FABRICATES):
///   * Live booking / live prices are a DOCUMENTED key-gated seam shown as an
///     honest "connect a booking key" card (_BookingSeamCard). This screen
///     NEVER invents a flight, price or confirmation. Every ৳ figure is only a
///     value the PA typed as a manual estimate; nothing is booked, no money is
///     held, nothing is settled.
///
/// All math mirrors backend/core/logic/pa_biztravel.py (inclusive day span,
/// passed-in-today countdown, budget estimated/actual/variance, attendee
/// rollup, checklist %, chronological ordering) so the views are deterministic
/// and identical offline.
///
/// Honest states: welcome (no events) · loading · error. ZERO Bangla literals —
/// every string is an AppLocalizations getter (৳ exempt).
///
/// Persistence (generic api helpers, no api.dart edit):
///   listItems('pa/bizevents') → mixed rows tagged by {kind}:
///     {id, kind:'event',  name, date, end, venue, city, note}
///     {id, kind:'agenda', event_id, title, at, speaker, note}
///     {id, kind:'budget', event_id, label, category, estimated, actual}
///     {id, kind:'task',   event_id, label, done}
///   listItems('pa/bizattendees') → attendee rows {event_id}:
///     {id, event_id, name, role, mode, from_place, depart, ref, status, cost,
///      note}
///   create/update/delete on both paths; rows round-trip as {id, ...data}
///   through the PaCollectionItem flexible per-user JSON store.
class BizTravelEventsScreen extends StatefulWidget {
  const BizTravelEventsScreen({super.key});
  @override
  State<BizTravelEventsScreen> createState() => _BizTravelEventsScreenState();
}

const String _eventsPath = 'pa/bizevents';
const String _attendeesPath = 'pa/bizattendees';

const List<String> _travelModes = [
  'flight', 'train', 'car', 'bus', 'launch', 'local'
];
const List<String> _arrStates = ['pending', 'booked', 'confirmed', 'cancelled'];
const List<String> _budgetCats = [
  'travel', 'venue', 'lodging', 'catering', 'materials', 'other'
];

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

int _daySpan(String date, String end) {
  final s = _parse(date);
  if (s == null) return 0;
  final e = _parse(end);
  if (e == null) return 1;
  if (e.isBefore(s)) return 0;
  return DateTime(e.year, e.month, e.day)
          .difference(DateTime(s.year, s.month, s.day))
          .inDays +
      1;
}

int? _countdown(String date, String todayIso) {
  final s = _parse(date), n = _parse(todayIso);
  if (s == null || n == null) return null;
  return DateTime(s.year, s.month, s.day)
      .difference(DateTime(n.year, n.month, n.day))
      .inDays;
}

double _money(dynamic v) {
  if (v is num) return v < 0 ? 0 : v.toDouble();
  final f = double.tryParse('$v'.trim());
  if (f == null || f < 0) return 0;
  return f;
}

/// ৳ formatter with grouped thousands + 2 decimals (matches expense voucher).
String _fmtMoney(double amount) {
  final neg = amount < 0;
  final cents = (amount.abs() * 100).round();
  final whole = cents ~/ 100;
  final paisa = cents % 100;
  final digits = whole.toString();
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
    buf.write(digits[i]);
  }
  return '${neg ? '-' : ''}৳$buf.${paisa.toString().padLeft(2, '0')}';
}

const String _far = '9999-12-31T23:59:59';

String _eventKey(Map<String, dynamic> e, String field) =>
    _parse('${e[field] ?? ''}')?.toIso8601String() ?? _far;

List<Map<String, dynamic>> _ordered(
    Iterable<Map<String, dynamic>> rows, String field) {
  final out = rows.toList();
  out.sort((a, b) => _eventKey(a, field).compareTo(_eventKey(b, field)));
  return out;
}

class _BizTravelEventsScreenState extends State<BizTravelEventsScreen> {
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
      _rows = await context.read<AppState>().api.listItems(_eventsPath);
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  List<Map<String, dynamic>> get _events =>
      _rows.where((r) => '${r['kind']}' == 'event').toList();

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _openEventEditor([Map<String, dynamic>? existing]) async {
    final result = await showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _EventEditor(existing: existing),
    );
    if (result == null) return;
    final api = context.read<AppState>().api;
    try {
      if (existing != null && existing['id'] is int) {
        await api.updateItem(_eventsPath, existing['id'] as int, result);
      } else {
        await api.createItem(_eventsPath, {...result, 'kind': 'event'});
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
          appBar: AppBar(title: Text(t.paBizTitle)),
          body: const SkeletonList());
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text(t.paBizTitle)),
        body: StateMessage(
          icon: Icons.cloud_off_rounded,
          tint: scheme.error,
          title: t.loadFailed,
          message: honestFailText(t, _failCause, otherwise: t.paBizLoadError),
          action: FilledButton.tonalIcon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(t.retry)),
        ),
      );
    }
    final events = _events;
    return Scaffold(
      appBar: AppBar(title: Text(t.paBizTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEventEditor(),
        icon: const Icon(Icons.add_rounded),
        label: Text(t.paBizNewEvent),
      ),
      body: events.isEmpty
          ? StateMessage(
              icon: Icons.groups_3_rounded,
              tint: Brand.blue,
              title: t.paBizWelcomeTitle,
              message: t.paBizWelcomeBody,
              action: FilledButton.icon(
                onPressed: () => _openEventEditor(),
                icon: const Icon(Icons.add_rounded),
                label: Text(t.paBizNewEvent),
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
                children: [
                  const _BookingSeamCard(),
                  const SizedBox(height: Gap.sm),
                  for (final ev in events)
                    _EventCard(
                      event: ev,
                      onOpen: () async {
                        await Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => _EventDetailScreen(event: ev),
                        ));
                        await _load();
                      },
                      onEdit: () => _openEventEditor(ev),
                    ),
                ],
              ),
            ),
    );
  }
}

// ======================= event card + countdown =======================
class _EventCard extends StatelessWidget {
  final Map<String, dynamic> event;
  final VoidCallback onOpen, onEdit;
  const _EventCard(
      {required this.event, required this.onOpen, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final date = '${event['date'] ?? ''}';
    final end = '${event['end'] ?? ''}';
    final venue = '${event['venue'] ?? ''}'.trim();
    final city = '${event['city'] ?? ''}'.trim();
    final days = _daySpan(date, end);
    final cd = _countdown(date, _today());
    String cdText;
    if (cd == null) {
      cdText = '';
    } else if (cd > 0) {
      cdText = t.paBizCountdown(cd);
    } else if (cd == 0) {
      cdText = t.paBizToday;
    } else {
      cdText = t.paBizPast(-cd);
    }
    final place = [venue, city].where((x) => x.isNotEmpty).join(' · ');
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: ListTile(
        onTap: onOpen,
        leading: CircleAvatar(
          backgroundColor: scheme.primaryContainer,
          child: Icon(Icons.event_available_rounded, color: scheme.onPrimaryContainer),
        ),
        title: Text('${event['name'] ?? ''}',
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (date.isNotEmpty)
              Text(end.isEmpty ? date : '$date → $end',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            if (place.isNotEmpty)
              Text(place, maxLines: 1, overflow: TextOverflow.ellipsis),
            Wrap(spacing: 6, children: [
              if (days > 0) _chip(t.paBizDaysCount(days), scheme.secondary),
              if (cdText.isNotEmpty) _chip(cdText, scheme.primary),
            ]),
          ],
        ),
        trailing: IconButton(
            icon: const Icon(Icons.edit_rounded),
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

// ======================= event detail =======================
class _EventDetailScreen extends StatefulWidget {
  final Map<String, dynamic> event;
  const _EventDetailScreen({required this.event});
  @override
  State<_EventDetailScreen> createState() => _EventDetailScreenState();
}

class _EventDetailScreenState extends State<_EventDetailScreen> {
  List<Map<String, dynamic>> _children = []; // agenda/budget/task
  List<Map<String, dynamic>> _attendees = [];
  bool _loading = true;

  AppLocalizations get t => AppLocalizations.of(context);
  int get _eventId => widget.event['id'] as int;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final api = context.read<AppState>().api;
    try {
      final all = await api.listItems(_eventsPath);
      _children = all.where((r) => r['event_id'] == _eventId).toList();
    } catch (_) {
      _children = [];
    }
    try {
      final atts = await api.listItems(_attendeesPath);
      _attendees = atts.where((r) => r['event_id'] == _eventId).toList();
    } catch (_) {
      _attendees = [];
    }
    if (mounted) setState(() => _loading = false);
  }

  List<Map<String, dynamic>> _ofKind(String k) =>
      _children.where((r) => '${r['kind']}' == k).toList();

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _createChild(Map<String, dynamic> body) async {
    try {
      await context
          .read<AppState>()
          .api
          .createItem(_eventsPath, {...body, 'event_id': _eventId});
      await _load();
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
    }
  }

  Future<void> _updateChild(int id, Map<String, dynamic> body) async {
    try {
      await context
          .read<AppState>()
          .api
          .updateItem(_eventsPath, id, {...body, 'event_id': _eventId});
      await _load();
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
    }
  }

  Future<void> _deleteChild(int id) async {
    try {
      await context.read<AppState>().api.deleteItem(_eventsPath, id);
      await _load();
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
    }
  }

  Future<void> _createAttendee(Map<String, dynamic> body) async {
    try {
      await context
          .read<AppState>()
          .api
          .createItem(_attendeesPath, {...body, 'event_id': _eventId});
      await _load();
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
    }
  }

  Future<void> _updateAttendee(int id, Map<String, dynamic> body) async {
    try {
      await context
          .read<AppState>()
          .api
          .updateItem(_attendeesPath, id, {...body, 'event_id': _eventId});
      await _load();
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
    }
  }

  Future<void> _deleteAttendee(int id) async {
    try {
      await context.read<AppState>().api.deleteItem(_attendeesPath, id);
      await _load();
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
    }
  }

  String _modeLabel(String mode) {
    switch (mode) {
      case 'flight':
        return t.paBizModeFlight;
      case 'train':
        return t.paBizModeTrain;
      case 'car':
        return t.paBizModeCar;
      case 'bus':
        return t.paBizModeBus;
      case 'launch':
        return t.paBizModeLaunch;
      default:
        return t.paBizModeLocal;
    }
  }

  String _statusLabel(String s) {
    switch (s) {
      case 'booked':
        return t.paBizArrBooked;
      case 'confirmed':
        return t.paBizArrConfirmed;
      case 'cancelled':
        return t.paBizArrCancelled;
      default:
        return t.paBizArrPending;
    }
  }

  String _catLabel(String c) {
    switch (c) {
      case 'travel':
        return t.paBizCatTravel;
      case 'venue':
        return t.paBizCatVenue;
      case 'lodging':
        return t.paBizCatLodging;
      case 'catering':
        return t.paBizCatCatering;
      case 'materials':
        return t.paBizCatMaterials;
      default:
        return t.paBizCatOther;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final agenda = _ordered(_ofKind('agenda'), 'at');
    final budget = _ofKind('budget');
    final tasks = _ofKind('task');
    final attendees = _ordered(_attendees, 'depart');

    // deterministic rollups (mirror pa_biztravel.py)
    final confirmed =
        attendees.where((a) => '${a['status']}' == 'confirmed').length;
    final pending =
        attendees.where((a) => '${a['status']}' == 'pending').length;
    double est = 0, act = 0, travelEst = 0;
    for (final b in budget) {
      est += _money(b['estimated']);
      act += _money(b['actual']);
    }
    for (final a in attendees) {
      travelEst += _money(a['cost']);
    }
    final variance = act - est;
    final grandEst = est + travelEst;
    final doneTasks = tasks.where((x) => x['done'] == true).length;
    final chkPct = tasks.isEmpty ? 0 : (doneTasks * 100 ~/ tasks.length);

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.event['name'] ?? ''}',
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

                  // ---- attendees (coordination) ----
                  _SectionHeader(
                      icon: Icons.groups_2_rounded,
                      label: t.paBizAttendeesHeader,
                      onAdd: () => _editAttendee()),
                  if (attendees.isNotEmpty)
                    _RollupBar(
                      confirmed: confirmed,
                      pending: pending,
                      total: attendees.length,
                    ),
                  if (attendees.isEmpty)
                    _EmptyLine(t.paBizNoAttendees)
                  else
                    for (final a in attendees)
                      _AttendeeTile(
                        attendee: a,
                        modeLabel: _modeLabel('${a['mode']}'),
                        statusLabel: _statusLabel('${a['status']}'),
                        costText: _money(a['cost']) > 0
                            ? _fmtMoney(_money(a['cost']))
                            : '',
                        onEdit: () => _editAttendee(a),
                        onDelete: () => _deleteAttendee(a['id'] as int),
                      ),
                  const SizedBox(height: Gap.lg),

                  // ---- agenda ----
                  _SectionHeader(
                      icon: Icons.schedule_rounded,
                      label: t.paBizAgendaHeader,
                      onAdd: () => _editAgenda()),
                  if (agenda.isEmpty)
                    _EmptyLine(t.paBizNoAgenda)
                  else
                    for (final g in agenda)
                      _TwoLineTile(
                        icon: Icons.article_rounded,
                        title: '${g['title'] ?? ''}',
                        subtitle: [
                          '${g['at'] ?? ''}',
                          '${g['speaker'] ?? ''}'
                        ].where((x) => x.trim().isNotEmpty).join(' · '),
                        onEdit: () => _editAgenda(g),
                        onDelete: () => _deleteChild(g['id'] as int),
                      ),
                  const SizedBox(height: Gap.lg),

                  // ---- budget (৳ estimated vs actual) ----
                  _SectionHeader(
                      icon: Icons.account_balance_wallet_rounded,
                      label: t.paBizBudgetHeader,
                      onAdd: () => _editBudget()),
                  if (budget.isEmpty)
                    _EmptyLine(t.paBizNoBudget)
                  else ...[
                    for (final b in budget)
                      _BudgetTile(
                        label: '${b['label'] ?? ''}',
                        catLabel: _catLabel('${b['category']}'),
                        estimated: _fmtMoney(_money(b['estimated'])),
                        actual: _fmtMoney(_money(b['actual'])),
                        onEdit: () => _editBudget(b),
                        onDelete: () => _deleteChild(b['id'] as int),
                      ),
                    const SizedBox(height: Gap.sm),
                    _BudgetTotals(
                      estimated: _fmtMoney(est),
                      actual: _fmtMoney(act),
                      variance: _fmtMoney(variance),
                      overBudget: act > est,
                      travelEstimate:
                          travelEst > 0 ? _fmtMoney(travelEst) : '',
                      grandEstimate: _fmtMoney(grandEst),
                    ),
                  ],
                  // honest reminder: nothing priced/booked/settled here
                  Padding(
                    padding: const EdgeInsets.only(top: Gap.xs),
                    child: Text(t.paBizBudgetDisclaimer,
                        style: TextStyle(
                            fontSize: 11.5,
                            color: scheme.onSurfaceVariant,
                            height: 1.35)),
                  ),
                  const SizedBox(height: Gap.lg),

                  // ---- logistics checklist ----
                  _SectionHeader(
                      icon: Icons.checklist_rounded,
                      label: t.paBizChecklistHeader,
                      onAdd: () => _addTask()),
                  if (tasks.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
                      child: Row(children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(Radii.pill),
                            child: LinearProgressIndicator(
                                value: chkPct / 100,
                                minHeight: 8,
                                backgroundColor:
                                    scheme.surfaceContainerHighest),
                          ),
                        ),
                        const SizedBox(width: Gap.sm),
                        Text(t.paBizChecklistProgress(doneTasks, tasks.length),
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)),
                      ]),
                    ),
                  if (tasks.isEmpty)
                    _EmptyLine(t.paBizNoTasks)
                  else
                    for (final x in tasks)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        value: x['done'] == true,
                        onChanged: (v) => _updateChild(x['id'] as int,
                            {'kind': 'task', 'label': x['label'], 'done': v}),
                        title: Text('${x['label'] ?? ''}'),
                        secondary: IconButton(
                            icon: const Icon(Icons.close_rounded, size: 18),
                            tooltip: t.delete,
                            onPressed: () => _deleteChild(x['id'] as int)),
                      ),
                  const SizedBox(height: Gap.xl),

                  // ---- printable summary ----
                  OutlinedButton.icon(
                    icon: const Icon(Icons.summarize_rounded),
                    label: Text(t.paBizSummaryButton),
                    onPressed: () => showAppSheet(
                      context: context,
                      isScrollControlled: true,
                      showDragHandle: true,
                      builder: (_) => _EventSummarySheet(
                        event: widget.event,
                        attendees: attendees,
                        agenda: agenda,
                        confirmed: confirmed,
                        pending: pending,
                        estimated: _fmtMoney(est),
                        actual: _fmtMoney(act),
                        grandEstimate: _fmtMoney(grandEst),
                        doneTasks: doneTasks,
                        taskTotal: tasks.length,
                        statusLabel: _statusLabel,
                        modeLabel: _modeLabel,
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  // ---- editors ----
  Future<void> _editAttendee([Map<String, dynamic>? e]) async {
    final r = await showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AttendeeEditor(
          existing: e, modeLabel: _modeLabel, statusLabel: _statusLabel),
    );
    if (r == null) return;
    if (e != null && e['id'] is int) {
      await _updateAttendee(e['id'] as int, r);
    } else {
      await _createAttendee(r);
    }
  }

  Future<void> _editAgenda([Map<String, dynamic>? e]) async {
    final r = await showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AgendaEditor(existing: e),
    );
    if (r == null) return;
    if (e != null && e['id'] is int) {
      await _updateChild(e['id'] as int, r);
    } else {
      await _createChild(r);
    }
  }

  Future<void> _editBudget([Map<String, dynamic>? e]) async {
    final r = await showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _BudgetEditor(existing: e, catLabel: _catLabel),
    );
    if (r == null) return;
    if (e != null && e['id'] is int) {
      await _updateChild(e['id'] as int, r);
    } else {
      await _createChild(r);
    }
  }

  Future<void> _addTask() async {
    final label = await _promptText(context, t.paBizTaskLabel);
    if (label == null || label.trim().isEmpty) return;
    await _createChild({'kind': 'task', 'label': label.trim(), 'done': false});
  }
}

// ======================= booking seam (key-gated) =======================
class _BookingSeamCard extends StatelessWidget {
  const _BookingSeamCard();
  @override
  Widget build(BuildContext context) {
    if (!kShowKeySeams) return const SizedBox.shrink(); // truth: no key dead end
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.secondaryContainer.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.confirmation_number_rounded,
              size: 20, color: scheme.secondary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.paBizBookingSeamTitle,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(t.paBizBookingSeamBody,
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

// ======================= rollup bar =======================
class _RollupBar extends StatelessWidget {
  final int confirmed, pending, total;
  const _RollupBar(
      {required this.confirmed, required this.pending, required this.total});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm, top: Gap.xs),
      child: Wrap(spacing: 6, runSpacing: 6, children: [
        _pill(t.paBizRollupTotal(total), scheme.secondary),
        _pill(t.paBizRollupConfirmed(confirmed), Brand.success),
        if (pending > 0) _pill(t.paBizRollupPending(pending), Brand.warning),
      ]),
    );
  }

  Widget _pill(String label, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
            color: c.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(Radii.pill)),
        child: Text(label,
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w700, color: c)),
      );
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
          icon: const Icon(Icons.add_circle_outline_rounded),
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

class _AttendeeTile extends StatelessWidget {
  final Map<String, dynamic> attendee;
  final String modeLabel, statusLabel, costText;
  final VoidCallback onEdit, onDelete;
  const _AttendeeTile(
      {required this.attendee,
      required this.modeLabel,
      required this.statusLabel,
      required this.costText,
      required this.onEdit,
      required this.onDelete});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final role = '${attendee['role'] ?? ''}'.trim();
    final from = '${attendee['from_place'] ?? ''}'.trim();
    final depart = '${attendee['depart'] ?? ''}'.trim();
    final ref = '${attendee['ref'] ?? ''}'.trim();
    final status = '${attendee['status']}';
    Color sc;
    switch (status) {
      case 'confirmed':
        sc = Brand.success;
        break;
      case 'cancelled':
        sc = scheme.error;
        break;
      case 'booked':
        sc = Brand.blue;
        break;
      default:
        sc = Brand.warning;
    }
    final line2 = <String>[
      modeLabel,
      if (from.isNotEmpty) from,
      if (depart.isNotEmpty) depart,
      if (ref.isNotEmpty) t.paBizRefLabel(ref),
      if (costText.isNotEmpty) costText,
    ].join(' · ');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: const Icon(Icons.person_outline_rounded),
      title: Row(children: [
        Expanded(
          child: Text(
              role.isEmpty
                  ? '${attendee['name'] ?? ''}'
                  : '${attendee['name'] ?? ''} · $role',
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
              color: sc.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(Radii.pill)),
          child: Text(statusLabel,
              style: TextStyle(
                  fontSize: 10.5, fontWeight: FontWeight.w800, color: sc)),
        ),
      ]),
      subtitle: Text(line2, maxLines: 2, overflow: TextOverflow.ellipsis),
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

class _BudgetTile extends StatelessWidget {
  final String label, catLabel, estimated, actual;
  final VoidCallback onEdit, onDelete;
  const _BudgetTile(
      {required this.label,
      required this.catLabel,
      required this.estimated,
      required this.actual,
      required this.onEdit,
      required this.onDelete});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: const Icon(Icons.receipt_rounded),
      title: Text(label.isEmpty ? catLabel : label,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('$catLabel · ${t.paBizEstVsAct(/* (actual, estimated) */ actual, estimated)}',
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

class _BudgetTotals extends StatelessWidget {
  final String estimated, actual, variance, grandEstimate, travelEstimate;
  final bool overBudget;
  const _BudgetTotals(
      {required this.estimated,
      required this.actual,
      required this.variance,
      required this.grandEstimate,
      required this.travelEstimate,
      required this.overBudget});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final varColor = overBudget ? scheme.error : Brand.success;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.md)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _row(context, t.paBizTotalEstimated, estimated, null),
        _row(context, t.paBizTotalActual, actual, null),
        _row(context, t.paBizTotalVariance, variance, varColor),
        if (travelEstimate.isNotEmpty)
          _row(context, t.paBizTravelEstimate, travelEstimate, null),
        const Divider(),
        _row(context, t.paBizGrandEstimate, grandEstimate, scheme.primary,
            bold: true),
      ]),
    );
  }

  Widget _row(BuildContext context, String label, String value, Color? color,
          {bool bold = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Expanded(
              child: Text(label,
                  style: TextStyle(
                      fontWeight: bold ? FontWeight.w800 : FontWeight.w500))),
          Text(value,
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: color ?? Theme.of(context).colorScheme.onSurface)),
        ]),
      );
}

// ======================= editors =======================
class _EventEditor extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _EventEditor({this.existing});
  @override
  State<_EventEditor> createState() => _EventEditorState();
}

class _EventEditorState extends State<_EventEditor> {
  late final TextEditingController _name =
      TextEditingController(text: '${widget.existing?['name'] ?? ''}');
  late final TextEditingController _venue =
      TextEditingController(text: '${widget.existing?['venue'] ?? ''}');
  late final TextEditingController _city =
      TextEditingController(text: '${widget.existing?['city'] ?? ''}');
  late final TextEditingController _note =
      TextEditingController(text: '${widget.existing?['note'] ?? ''}');
  late String _date = '${widget.existing?['date'] ?? ''}';
  late String _end = '${widget.existing?['end'] ?? ''}';

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void dispose() {
    _name.dispose();
    _venue.dispose();
    _city.dispose();
    _note.dispose();
    super.dispose();
  }

  void _save() {
    if (_name.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.paBizNameRequired)));
      return;
    }
    Navigator.pop(context, {
      'kind': 'event',
      'name': _name.text.trim(),
      'date': _date,
      'end': _end,
      'venue': _venue.text.trim(),
      'city': _city.text.trim(),
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
          Text(widget.existing == null ? t.paBizNewEvent : t.edit,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: Gap.lg),
          TextField(
            controller: _name,
            autofocus: true,
            decoration: InputDecoration(
                labelText: t.paBizEventNameLabel,
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          _DateField(
              label: t.paBizDateLabel,
              value: _date,
              onPick: (v) => setState(() => _date = v)),
          const SizedBox(height: Gap.md),
          _DateField(
              label: t.paBizEndLabel,
              value: _end,
              onPick: (v) => setState(() => _end = v)),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _venue,
            decoration: InputDecoration(
                labelText: t.paBizVenueLabel,
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _city,
            decoration: InputDecoration(
                labelText: t.paBizCityLabel,
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _note,
            maxLines: 2,
            decoration: InputDecoration(
                labelText: t.paBizNoteLabel,
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

class _AttendeeEditor extends StatefulWidget {
  final Map<String, dynamic>? existing;
  final String Function(String) modeLabel;
  final String Function(String) statusLabel;
  const _AttendeeEditor(
      {this.existing, required this.modeLabel, required this.statusLabel});
  @override
  State<_AttendeeEditor> createState() => _AttendeeEditorState();
}

class _AttendeeEditorState extends State<_AttendeeEditor> {
  late final TextEditingController _name =
      TextEditingController(text: '${widget.existing?['name'] ?? ''}');
  late final TextEditingController _role =
      TextEditingController(text: '${widget.existing?['role'] ?? ''}');
  late final TextEditingController _from =
      TextEditingController(text: '${widget.existing?['from_place'] ?? ''}');
  late final TextEditingController _ref =
      TextEditingController(text: '${widget.existing?['ref'] ?? ''}');
  late final TextEditingController _cost = TextEditingController(
      text: () {
    final c = _money(widget.existing?['cost']);
    return c > 0 ? (c == c.roundToDouble() ? c.toInt().toString() : '$c') : '';
  }());
  late String _mode = _travelModes.contains('${widget.existing?['mode']}')
      ? '${widget.existing!['mode']}'
      : 'local';
  late String _status = _arrStates.contains('${widget.existing?['status']}')
      ? '${widget.existing!['status']}'
      : 'pending';
  late String _depart = '${widget.existing?['depart'] ?? ''}';

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void dispose() {
    _name.dispose();
    _role.dispose();
    _from.dispose();
    _ref.dispose();
    _cost.dispose();
    super.dispose();
  }

  void _save() {
    if (_name.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.paBizAttendeeNameRequired)));
      return;
    }
    Navigator.pop(context, {
      'name': _name.text.trim(),
      'role': _role.text.trim(),
      'mode': _mode,
      'from_place': _from.text.trim(),
      'depart': _depart,
      'ref': _ref.text.trim(),
      'status': _status,
      'cost': _money(_cost.text),
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
              Text(t.paBizAttendeesHeader,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: Gap.md),
              TextField(
                  controller: _name,
                  autofocus: true,
                  decoration: InputDecoration(
                      labelText: t.paBizAttendeeNameLabel,
                      border: const OutlineInputBorder())),
              const SizedBox(height: Gap.md),
              TextField(
                  controller: _role,
                  decoration: InputDecoration(
                      labelText: t.paBizAttendeeRoleLabel,
                      border: const OutlineInputBorder())),
              const SizedBox(height: Gap.md),
              Text(t.paBizModeLabel,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.xs),
              Wrap(spacing: Gap.sm, children: [
                for (final m in _travelModes)
                  ChoiceChip(
                    label: Text(widget.modeLabel(m)),
                    selected: _mode == m,
                    onSelected: (_) => setState(() => _mode = m),
                  ),
              ]),
              const SizedBox(height: Gap.md),
              TextField(
                  controller: _from,
                  decoration: InputDecoration(
                      labelText: t.paBizFromLabel,
                      border: const OutlineInputBorder())),
              const SizedBox(height: Gap.md),
              _DateField(
                  label: t.paBizDepartLabel,
                  value: _depart,
                  withTime: true,
                  onPick: (v) => setState(() => _depart = v)),
              const SizedBox(height: Gap.md),
              TextField(
                  controller: _ref,
                  decoration: InputDecoration(
                      labelText: t.paBizRefFieldLabel,
                      helperText: t.paBizRefHelper,
                      border: const OutlineInputBorder())),
              const SizedBox(height: Gap.md),
              TextField(
                  controller: _cost,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: InputDecoration(
                      labelText: t.paBizCostLabel,
                      helperText: t.paBizCostHelper,
                      prefixText: '৳ ',
                      border: const OutlineInputBorder())),
              const SizedBox(height: Gap.md),
              Text(t.paBizStatusLabel,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.xs),
              Wrap(spacing: Gap.sm, children: [
                for (final s in _arrStates)
                  ChoiceChip(
                    label: Text(widget.statusLabel(s)),
                    selected: _status == s,
                    onSelected: (_) => setState(() => _status = s),
                  ),
              ]),
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

class _AgendaEditor extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _AgendaEditor({this.existing});
  @override
  State<_AgendaEditor> createState() => _AgendaEditorState();
}

class _AgendaEditorState extends State<_AgendaEditor> {
  late final TextEditingController _title =
      TextEditingController(text: '${widget.existing?['title'] ?? ''}');
  late final TextEditingController _speaker =
      TextEditingController(text: '${widget.existing?['speaker'] ?? ''}');
  late String _at = '${widget.existing?['at'] ?? ''}';

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void dispose() {
    _title.dispose();
    _speaker.dispose();
    super.dispose();
  }

  void _save() {
    if (_title.text.trim().isEmpty) {
      Navigator.pop(context);
      return;
    }
    Navigator.pop(context, {
      'kind': 'agenda',
      'title': _title.text.trim(),
      'at': _at,
      'speaker': _speaker.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(t.paBizAgendaHeader,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: Gap.md),
          TextField(
              controller: _title,
              autofocus: true,
              decoration: InputDecoration(
                  labelText: t.paBizAgendaTitleLabel,
                  border: const OutlineInputBorder())),
          const SizedBox(height: Gap.md),
          _DateField(
              label: t.paBizAgendaAtLabel,
              value: _at,
              withTime: true,
              onPick: (v) => setState(() => _at = v)),
          const SizedBox(height: Gap.md),
          TextField(
              controller: _speaker,
              decoration: InputDecoration(
                  labelText: t.paBizAgendaSpeakerLabel,
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

class _BudgetEditor extends StatefulWidget {
  final Map<String, dynamic>? existing;
  final String Function(String) catLabel;
  const _BudgetEditor({this.existing, required this.catLabel});
  @override
  State<_BudgetEditor> createState() => _BudgetEditorState();
}

class _BudgetEditorState extends State<_BudgetEditor> {
  late final TextEditingController _label =
      TextEditingController(text: '${widget.existing?['label'] ?? ''}');
  late final TextEditingController _est = TextEditingController(
      text: _num(widget.existing?['estimated']));
  late final TextEditingController _act = TextEditingController(
      text: _num(widget.existing?['actual']));
  late String _cat = _budgetCats.contains('${widget.existing?['category']}')
      ? '${widget.existing!['category']}'
      : 'other';

  AppLocalizations get t => AppLocalizations.of(context);

  static String _num(dynamic v) {
    final c = _money(v);
    if (c <= 0) return '';
    return c == c.roundToDouble() ? c.toInt().toString() : '$c';
  }

  @override
  void dispose() {
    _label.dispose();
    _est.dispose();
    _act.dispose();
    super.dispose();
  }

  void _save() {
    Navigator.pop(context, {
      'kind': 'budget',
      'label': _label.text.trim(),
      'category': _cat,
      'estimated': _money(_est.text),
      'actual': _money(_act.text),
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
              Text(t.paBizBudgetHeader,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: Gap.md),
              TextField(
                  controller: _label,
                  autofocus: true,
                  decoration: InputDecoration(
                      labelText: t.paBizBudgetLabelLabel,
                      border: const OutlineInputBorder())),
              const SizedBox(height: Gap.md),
              Text(t.paBizCategoryLabel,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.xs),
              Wrap(spacing: Gap.sm, children: [
                for (final c in _budgetCats)
                  ChoiceChip(
                    label: Text(widget.catLabel(c)),
                    selected: _cat == c,
                    onSelected: (_) => setState(() => _cat = c),
                  ),
              ]),
              const SizedBox(height: Gap.md),
              TextField(
                  controller: _est,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: InputDecoration(
                      labelText: t.paBizEstimatedLabel,
                      prefixText: '৳ ',
                      border: const OutlineInputBorder())),
              const SizedBox(height: Gap.md),
              TextField(
                  controller: _act,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: InputDecoration(
                      labelText: t.paBizActualLabel,
                      prefixText: '৳ ',
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

// ======================= event summary sheet =======================
class _EventSummarySheet extends StatelessWidget {
  final Map<String, dynamic> event;
  final List<Map<String, dynamic>> attendees, agenda;
  final int confirmed, pending, doneTasks, taskTotal;
  final String estimated, actual, grandEstimate;
  final String Function(String) statusLabel, modeLabel;
  const _EventSummarySheet(
      {required this.event,
      required this.attendees,
      required this.agenda,
      required this.confirmed,
      required this.pending,
      required this.estimated,
      required this.actual,
      required this.grandEstimate,
      required this.doneTasks,
      required this.taskTotal,
      required this.statusLabel,
      required this.modeLabel});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final days = _daySpan('${event['date'] ?? ''}', '${event['end'] ?? ''}');
    final place = ['${event['venue'] ?? ''}', '${event['city'] ?? ''}']
        .where((x) => x.trim().isNotEmpty)
        .join(' · ');
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      builder: (_, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          Text('${event['name'] ?? ''}',
              style:
                  const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(
              '${event['date'] ?? ''}${'${event['end'] ?? ''}'.trim().isEmpty ? '' : ' → ${event['end']}'}'),
          if (place.isNotEmpty) Text(place),
          if (days > 0) Text(t.paBizDaysCount(days)),
          const Divider(height: Gap.xl),
          Text(t.paBizRollupConfirmed(confirmed),
              style: const TextStyle(fontWeight: FontWeight.w700)),
          if (pending > 0) Text(t.paBizRollupPending(pending)),
          _summarySection(context, t.paBizAttendeesHeader, [
            for (final a in attendees)
              '${a['name'] ?? ''} · ${modeLabel('${a['mode']}')} · ${statusLabel('${a['status']}')}',
          ]),
          _summarySection(context, t.paBizAgendaHeader, [
            for (final g in agenda)
              '${g['title'] ?? ''}'
                  '${'${g['at'] ?? ''}'.trim().isEmpty ? '' : '  (${g['at']})'}',
          ]),
          const SizedBox(height: Gap.sm),
          Text(t.paBizBudgetHeader,
              style: const TextStyle(fontWeight: FontWeight.w800)),
          Text(t.paBizEstVsAct(/* (actual, estimated) */ actual, estimated)),
          Text('${t.paBizGrandEstimate}: $grandEstimate'),
          if (taskTotal > 0)
            Text(t.paBizChecklistProgress(doneTasks, taskTotal),
                style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.md),
          Text(t.paBizBudgetDisclaimer,
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: Gap.sm),
          Text(t.paBizBookingSeamBody,
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
      icon: const Icon(Icons.event_rounded, size: 18),
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
      scrollable: true, // insets: 200% text / keyboard
      title: Text(label),
      content: TextField(
          controller: c,
          autofocus: true,
          decoration: InputDecoration(labelText: label)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t.cancel)),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text), child: Text(t.save)),
      ],
    ),
  );
}
