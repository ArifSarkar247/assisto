import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import '../ads/ad_banner_slot.dart' show AdBannerSlot;
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../notifications.dart';
import '../widgets/life_leave_now_card.dart';
import '../widgets/meet_model.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// Meetings / appointments (module-5 "Life") — ADVANCED (SPEC v2.1 §21).
///
/// Benchmarked vs Google / Apple Calendar + Calendly:
///   - create (title, when, where+coords, with-whom, note, reminder lead-times,
///     recurrence) via a rich editor
///   - calendar/agenda views: Day / Week / Month / List, upcoming & past
///   - reminders REUSE the shared reminders engine (recurrence + lead offsets
///     flow through meetings.appointment_reminders -> reminders_engine)
///   - "Leave now" (bn via l10n) with an HONEST key-gated travel estimate
///     (Maps 🔑 — no key wired -> static mock ETA flagged as an estimate; we
///     never fake live traffic) + Maps directions deep-link
///   - conflict (overlap) detection, invite/share, mark done / cancel / reopen.
///
/// Logic mirrors core.logic.meetings. All Bangla is codepoints/ARB only
/// (meet_model.dart) — zero Bangla glyphs in this file.
class MeetingsScreen extends StatefulWidget {
  const MeetingsScreen({super.key});
  @override
  State<MeetingsScreen> createState() => _MeetingsScreenState();
}

enum _View { list, day, week, month }

class _MeetingsScreenState extends State<MeetingsScreen> {
  bool _loading = true;
  bool _error = false;
  bool _offline = false;
  List<Map<String, dynamic>> _appts = [];

  _View _view = _View.list;
  bool _showPast = false;
  DateTime _anchor = DateTime.now();

  // Entered travel estimate per appointment (survives list rebuilds).
  final Map<String, int> _travelMinByAppt = {};
  String _apptKey(Map<String, dynamic> a) => '${a['start']}|${a['title'] ?? ''}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  AppState get _app => context.read<AppState>();

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final rows = await _app.api.listItems('appointments');
      _appts =
          rows.map((r) => (r['data'] as Map<String, dynamic>?) ?? r).toList();
      _offline = false;
    } catch (_) {
      // Keep whatever we already had so the user isn't stranded; flag the state.
      if (_appts.isNotEmpty) {
        _offline = true;
      } else {
        _error = true;
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    try {
      await _app.api.createItem('appointments', {'items': _appts});
      if (mounted && _offline) setState(() => _offline = false);
    } catch (_) {
      if (mounted) {
        setState(() => _offline = true);
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(mStr(context, 'mSavedOffline'))));
      }
    }
  }

  Future<void> _add() async {
    final result = await showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _AppointmentEditor(),
    );
    if (result != null) {
      if (mounted) _syncReminders(result);
      setState(() => _appts = [..._appts, result]);
      await _save();
    }
  }

  Future<void> _edit(Map<String, dynamic> a) async {
    final result = await showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _AppointmentEditor(existing: a),
    );
    if (result != null) {
      // Drop the pre-edit reminders first (start/title/leads may have changed),
      // then schedule the edited meeting fresh.
      _cancelReminders(a);
      if (mounted) _syncReminders(result);
      setState(() =>
          _appts = _appts.map((x) => identical(x, a) ? result : x).toList());
      await _save();
    }
  }

  Future<void> _delete(Map<String, dynamic> a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        content: Text(mStr(ctx, 'mDeleteQ')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(AppLocalizations.of(ctx).cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(AppLocalizations.of(ctx).delete)),
        ],
      ),
    );
    if (ok != true) return;
    _cancelReminders(a);
    setState(() => _appts = _appts.where((x) => !identical(x, a)).toList());
    await _save();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(mStr(context, 'mDeleted'))));
    }
  }

  // ---------------------------------------------------------------- reminders

  /// Stable notification id prefix for a meeting. Uses the backend id when one
  /// exists, else a hash of start+title (the same identity `_apptKey` uses), so
  /// a given meeting keeps the same id across rebuilds.
  String _reminderBase(Map<String, dynamic> a) {
    final id = a['id'];
    return 'appt-${id ?? _apptKey(a)}';
  }

  /// Honour the lead-time reminders the editor collected. For each lead offset
  /// (minutes before start) we schedule a local notification at
  /// start − lead, with the STABLE id 'appt-<id>-<lead>' so re-scheduling an
  /// edit replaces (never duplicates) the alert. Cancelled/done meetings and
  /// fire-times already in the past are skipped. Fully guarded — notifications
  /// are best-effort and must never break the save UX.
  void _syncReminders(Map<String, dynamic> a) {
    try {
      // Always clear any previously-scheduled leads for this meeting first.
      _cancelReminders(a);
      if (statusOf(a) == kStatusCancelled || statusOf(a) == kStatusDone) return;
      final start = nextStart(a);
      if (start == null) return;
      final title = '${a['title'] ?? ''}'.trim();
      if (title.isEmpty) return;
      // Body = the meeting's localized date/time (no literals in .dart).
      final locale = Localizations.localeOf(context).languageCode;
      final body = DateFormat('EEE d MMM, h:mm a', locale).format(start);
      final base = _reminderBase(a);
      final now = DateTime.now();
      final leads = (a['reminder_offsets'] as List?)
              ?.map((x) => (x as num).toInt())
              .toList() ??
          const <int>[];
      for (final lead in leads) {
        if (lead < 0) continue;
        final when = start.subtract(Duration(minutes: lead));
        if (!when.isAfter(now)) continue; // past — nothing to fire
        Notifications.schedule('$base-$lead', title, body, when);
      }
    } catch (_) {
      // best-effort only
    }
  }

  /// Drop every reminder we might have scheduled for a meeting (one per known
  /// lead option). Guarded — safe on delete and before re-scheduling.
  void _cancelReminders(Map<String, dynamic> a) {
    try {
      final base = _reminderBase(a);
      for (final lead in kLeadOptions) {
        Notifications.cancel('$base-$lead');
      }
    } catch (_) {}
  }

  Future<void> _setStatus(Map<String, dynamic> a, String status) async {
    setState(() => _appts = _appts
        .map((x) => identical(x, a) ? {...x, 'status': status} : x)
        .toList());
    await _save();
  }

  Future<void> _share(Map<String, dynamic> a) async {
    await Share.share(shareText(context, a));
  }

  int? _travelFor(Map<String, dynamic> a) {
    final key = _apptKey(a);
    if (_travelMinByAppt.containsKey(key)) return _travelMinByAppt[key];
    // truth: only a LIVE travel time (none wired yet) or the user's own value.
    final e = travelEta(
      place: '${a['place'] ?? ''}',
      lat: (a['place_lat'] as num?)?.toDouble(),
      lng: (a['place_lng'] as num?)?.toDouble(),
    );
    return e.source == 'none' ? null : e.etaMin;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      // banners-everywhere (owner 26 Oct): one bottom banner, Free only
      bottomNavigationBar: const AdBannerSlot(screen: 'meetings'),
      appBar: AppBar(
        title: Text(t.meetingsTitle),
        actions: [
          IconButton(
            tooltip: mStr(context, _showPast ? 'mUpcoming' : 'mPast'),
            icon: Icon(_showPast ? Icons.upcoming_rounded : Icons.history_rounded),
            onPressed: () => setState(() => _showPast = !_showPast),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: _ViewSwitcher(
            view: _view,
            onChanged: (v) => setState(() => _view = v),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add_rounded),
        label: Text(t.meetingsAdd),
      ),
      body: _body(t),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error) {
      return _ErrorState(onRetry: _load);
    }
    final part = _partition();
    final list = _showPast ? part.past : part.upcoming;
    final conflicts = conflictIndices(list);

    final banner = _offline
        ? Container(
            width: double.infinity,
            color: Brand.warning.withOpacity(0.15),
            padding: const EdgeInsets.symmetric(
                horizontal: Gap.md, vertical: Gap.sm),
            child: Row(children: [
              Icon(Icons.cloud_off_rounded, size: 16, color: Brand.warnInk(context)),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(mStr(context, 'mOffline'),
                    style: AType.bodySmall.copyWith(color: Brand.warnInk(context))),
              ),
            ]),
          )
        : const SizedBox.shrink();

    final content = _view == _View.list
        ? _buildList(list, conflicts)
        : _buildCalendar(_activeAppts());

    return Column(children: [banner, Expanded(child: content)]);
  }

  // Active (non-cancelled) appointments for calendar scopes.
  List<Map<String, dynamic>> _activeAppts() =>
      _appts.where((a) => statusOf(a) != kStatusCancelled).toList();

  ({List<Map<String, dynamic>> upcoming, List<Map<String, dynamic>> past})
      _partition() {
    final now = DateTime.now();
    final up = <MapEntry<DateTime, Map<String, dynamic>>>[];
    final past = <MapEntry<DateTime, Map<String, dynamic>>>[];
    for (final a in _appts) {
      // Cancelled meetings drop out of both lists (mirrors meetings.partition).
      if (statusOf(a) == kStatusCancelled) continue;
      final ns = nextStart(a, after: now);
      if (ns == null) continue;
      (ns.isBefore(now) ? past : up).add(MapEntry(ns, a));
    }
    up.sort((a, b) => a.key.compareTo(b.key));
    past.sort((a, b) => b.key.compareTo(a.key));
    return (
      upcoming: up.map((e) => e.value).toList(),
      past: past.map((e) => e.value).toList(),
    );
  }

  Widget _buildList(
      List<Map<String, dynamic>> list, Set<int> conflicts) {
    if (list.isEmpty) {
      return _showPast
          ? _EmptyPast()
          : _Empty(t: AppLocalizations.of(context), onAdd: _add);
    }
    final locale = Localizations.localeOf(context).languageCode;
    final fmt = DateFormat('EEE d MMM, h:mm a', locale);
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
      itemCount: list.length + 1,
      separatorBuilder: (_, __) => const SizedBox(height: Gap.sm),
      itemBuilder: (ctx, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: Gap.xs),
            child: Text(
                list.length == 1
                    ? AppLocalizations.of(ctx).a1MeetCountOne
                    : mStrNum(ctx, 'mCount', list.length),
                // a11y1: outline is a border token (4.29:1 as text).
                style: AType.bodySmall.copyWith(color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
          );
        }
        final a = list[i - 1];
        final start = nextStart(a) ?? DateTime.now();
        return _MeetingCard(
          appt: a,
          whenLabel: fmt.format(start),
          start: start,
          conflict: conflicts.contains(i - 1),
          past: _showPast,
          travelMin: _travelFor(a),
          onTravelChanged: (m) => setState(() {
            final key = _apptKey(a);
            if (m == null) {
              _travelMinByAppt.remove(key);
            } else {
              _travelMinByAppt[key] = m;
            }
          }),
          onDelete: () => _delete(a),
          onEdit: () => _edit(a),
          onShare: () => _share(a),
          onStatus: (s) => _setStatus(a, s),
        );
      },
    );
  }

  // Day/Week/Month agenda: group active appts into the window's days.
  Widget _buildCalendar(List<Map<String, dynamic>> active) {
    final buckets = _agenda(active, _view, _anchor);
    return Column(children: [
      _AnchorBar(
        view: _view,
        anchor: _anchor,
        onPrev: () => setState(() => _anchor = _shiftAnchor(-1)),
        onNext: () => setState(() => _anchor = _shiftAnchor(1)),
        onToday: () => setState(() => _anchor = DateTime.now()),
      ),
      Expanded(
        child: buckets.isEmpty
            ? Center(
                child: Text(mStr(context, 'mNoneToday'),
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.outline)),
              )
            : ListView(
                padding:
                    const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
                children: [
                  for (final b in buckets) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
                      child: Text(_dayHeader(b.date),
                          style: AType.titleMedium.copyWith(fontWeight: FontWeight.bold)),
                    ),
                    for (final a in b.items)
                      Padding(
                        padding: const EdgeInsets.only(bottom: Gap.sm),
                        child: _AgendaRow(
                          appt: a,
                          onTap: () => _edit(a),
                        ),
                      ),
                  ],
                ],
              ),
      ),
    ]);
  }

  DateTime _shiftAnchor(int dir) {
    switch (_view) {
      case _View.week:
        return _anchor.add(Duration(days: 7 * dir));
      case _View.month:
        return DateTime(_anchor.year, _anchor.month + dir, 1);
      case _View.day:
      default:
        return _anchor.add(Duration(days: dir));
    }
  }

  // Mirrors meetings.agenda (expands recurrence into each window day).
  List<({DateTime date, List<Map<String, dynamic>> items})> _agenda(
      List<Map<String, dynamic>> active, _View view, DateTime anchor) {
    DateTime start, end;
    if (view == _View.week) {
      start = DateTime(anchor.year, anchor.month, anchor.day)
          .subtract(Duration(days: anchor.weekday - 1));
      end = start.add(const Duration(days: 7));
    } else if (view == _View.month) {
      start = DateTime(anchor.year, anchor.month, 1);
      end = DateTime(anchor.year, anchor.month + 1, 1);
    } else {
      start = DateTime(anchor.year, anchor.month, anchor.day);
      end = start.add(const Duration(days: 1));
    }
    final map = <DateTime, List<MapEntry<DateTime, Map<String, dynamic>>>>{};
    for (final a in active) {
      final s = DateTime.tryParse('${a['start']}');
      if (s == null) continue;
      final r = a['recurrence'];
      final occs = <DateTime>[];
      if (r is Map && r['freq'] != null) {
        var cursor = start.subtract(const Duration(seconds: 1));
        for (var i = 0; i < 100; i++) {
          final nx = nextOccurrence(s, r, after: cursor);
          if (nx == null || !nx.isBefore(end)) break;
          if (!nx.isBefore(start)) occs.add(nx);
          cursor = nx;
        }
      } else if (!s.isBefore(start) && s.isBefore(end)) {
        occs.add(s);
      }
      for (final occ in occs) {
        final day = DateTime(occ.year, occ.month, occ.day);
        map.putIfAbsent(day, () => []).add(MapEntry(occ, a));
      }
    }
    final days = map.keys.toList()..sort();
    return [
      for (final d in days)
        (
          date: d,
          items: (map[d]!..sort((x, y) => x.key.compareTo(y.key)))
              .map((e) => e.value)
              .toList(),
        ),
    ];
  }

  String _dayHeader(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    if (day == today) return mStr(context, 'mToday');
    if (day == today.add(const Duration(days: 1))) {
      return mStr(context, 'mTomorrow');
    }
    return DateFormat('EEE d MMM', Localizations.localeOf(context).languageCode)
        .format(d);
  }
}

// ===========================================================================
// view switcher + anchor bar
// ===========================================================================
class _ViewSwitcher extends StatelessWidget {
  final _View view;
  final ValueChanged<_View> onChanged;
  const _ViewSwitcher({required this.view, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final items = <(_View, String)>[
      (_View.list, mStr(context, 'mViewAgenda')),
      (_View.day, mStr(context, 'mViewDay')),
      (_View.week, mStr(context, 'mViewWeek')),
      (_View.month, mStr(context, 'mViewMonth')),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.sm),
      child: Row(
        children: [
          for (final it in items)
            Padding(
              padding: const EdgeInsets.only(right: Gap.sm),
              child: ChoiceChip(
                label: Text(it.$2),
                selected: view == it.$1,
                onSelected: (_) => onChanged(it.$1),
              ),
            ),
        ],
      ),
    );
  }
}

class _AnchorBar extends StatelessWidget {
  final _View view;
  final DateTime anchor;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onToday;
  const _AnchorBar({
    required this.view,
    required this.anchor,
    required this.onPrev,
    required this.onNext,
    required this.onToday,
  });

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).languageCode;
    String label;
    if (view == _View.month) {
      label = DateFormat('MMMM yyyy', locale).format(anchor);
    } else if (view == _View.week) {
      final start = anchor.subtract(Duration(days: anchor.weekday - 1));
      final end = start.add(const Duration(days: 6));
      label =
          '${DateFormat('d MMM', locale).format(start)} – ${DateFormat('d MMM', locale).format(end)}';
    } else {
      label = DateFormat('EEE d MMM', locale).format(anchor);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 0),
      child: Row(children: [
        IconButton(
            tooltip: AppLocalizations.of(context).remCalPrev,
            icon: const Icon(Icons.chevron_left_rounded),
            onPressed: onPrev),
        Expanded(
          child: Text(label,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        IconButton(
            tooltip: AppLocalizations.of(context).remCalNext,
            icon: const Icon(Icons.chevron_right_rounded),
            onPressed: onNext),
        TextButton(onPressed: onToday, child: Text(mStr(context, 'mToday'))),
      ]),
    );
  }
}

// ===========================================================================
// agenda row (compact, calendar views)
// ===========================================================================
class _AgendaRow extends StatelessWidget {
  final Map<String, dynamic> appt;
  final VoidCallback onTap;
  const _AgendaRow({required this.appt, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = DateTime.tryParse('${appt['start']}');
    final time = s == null
        ? ''
        : DateFormat('h:mm a', Localizations.localeOf(context).languageCode)
            .format(s);
    final done = statusOf(appt) == kStatusDone;
    final recurring = freqOf(appt) != kFreqNone;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.all(Gap.sm),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withOpacity(0.5),
          borderRadius: BorderRadius.circular(10),
          border: Border(left: BorderSide(color: scheme.primary, width: 3)),
        ),
        child: Row(children: [
          SizedBox(
            width: 64,
            child: Text(time,
                style: AType.bodySmall.copyWith(color: scheme.primary, fontWeight: FontWeight.w600)),
          ),
          Expanded(
            child: Text('${appt['title']}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    decoration: done ? TextDecoration.lineThrough : null,
                    color: done ? scheme.outline : null)),
          ),
          if (recurring)
            Icon(Icons.repeat_rounded, size: 14, color: scheme.outline),
        ]),
      ),
    );
  }
}

// ===========================================================================
// full meeting card (list view)
// ===========================================================================
class _MeetingCard extends StatelessWidget {
  final Map<String, dynamic> appt;
  final String whenLabel;
  final DateTime start;
  final bool conflict;
  final bool past;
  final int? travelMin;
  final ValueChanged<int?> onTravelChanged;
  final VoidCallback onDelete;
  final VoidCallback onEdit;
  final VoidCallback onShare;
  final ValueChanged<String> onStatus;
  const _MeetingCard({
    required this.appt,
    required this.whenLabel,
    required this.start,
    required this.conflict,
    required this.past,
    required this.travelMin,
    required this.onTravelChanged,
    required this.onDelete,
    required this.onEdit,
    required this.onShare,
    required this.onStatus,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final place = '${appt['place'] ?? ''}'.trim();
    final note = '${appt['note'] ?? ''}'.trim();
    final people = withList(appt);
    final status = statusOf(appt);
    final done = status == kStatusDone;
    final recurring = freqOf(appt) != kFreqNone;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text('${appt['title']}',
                  style: AType.titleMedium.copyWith(fontWeight: FontWeight.bold, decoration: done ? TextDecoration.lineThrough : null, color: done ? scheme.outline : null)),
            ),
            if (done)
              _Chip(
                  label: mStr(context, 'mStatusDone'),
                  color: Brand.success,
                  icon: Icons.check_circle_rounded),
            _OverflowMenu(
              done: done,
              onEdit: onEdit,
              onShare: onShare,
              onDelete: onDelete,
              onStatus: onStatus,
            ),
          ]),
          Row(children: [
            Icon(Icons.schedule_rounded, size: 15, color: scheme.primary),
            const SizedBox(width: 6),
            Expanded(
                child: Text(whenLabel, style: TextStyle(color: scheme.primary))),
            if (recurring) ...[
              const SizedBox(width: 6),
              Icon(Icons.repeat_rounded, size: 14, color: scheme.outline),
              const SizedBox(width: Gap.xxs),
              Text(freqLabel(context, freqOf(appt)),
                  style: AType.labelSmall.copyWith(color: scheme.outline)),
            ],
          ]),
          if (place.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Row(children: [
              Icon(Icons.place_rounded, size: 15, color: scheme.outline),
              const SizedBox(width: 6),
              Expanded(
                  child: Text(place, style: TextStyle(color: scheme.outline))),
            ]),
          ],
          if (people.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.group_rounded, size: 15, color: scheme.outline),
              const SizedBox(width: 6),
              Expanded(
                  child: Text('${mStr(context, "mWith")}: ${people.join(", ")}',
                      style: AType.bodyMedium.copyWith(color: scheme.outline))),
            ]),
          ],
          if (note.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Text(note, style: AType.bodyMedium),
          ],
          if (conflict) ...[
            const SizedBox(height: 6),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xs),
              decoration: BoxDecoration(
                color: Brand.warning.withOpacity(0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.warning_amber_rounded,
                    size: 15, color: Brand.warnInk(context)),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(t.meetingsConflict,
                      style: AType.bodySmall.copyWith(color: Brand.warnInk(context))),
                ),
              ]),
            ),
          ],
          if (!past && !done) ...[
            const SizedBox(height: Gap.sm),
            LifeLeaveNowCard(
              start: start,
              placeName: place.isEmpty ? null : place,
              placeLat: (appt['place_lat'] as num?)?.toDouble(),
              placeLng: (appt['place_lng'] as num?)?.toDouble(),
              travelMin: travelMin,
              onTravelChanged: onTravelChanged,
            ),
          ],
        ]),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final Color color;
  final IconData icon;
  const _Chip({required this.label, required this.color, required this.icon});
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: Gap.xs),
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: Gap.xs),
        Text(label,
            style: AType.labelSmall.copyWith(color: color, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

class _OverflowMenu extends StatelessWidget {
  final bool done;
  final VoidCallback onEdit;
  final VoidCallback onShare;
  final VoidCallback onDelete;
  final ValueChanged<String> onStatus;
  const _OverflowMenu({
    required this.done,
    required this.onEdit,
    required this.onShare,
    required this.onDelete,
    required this.onStatus,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return PopupMenuButton<String>(
      tooltip: t.msgrChatMore, // a11y1: TalkBack needs a name
      icon: const Icon(Icons.more_vert_rounded, size: 20),
      onSelected: (v) {
        switch (v) {
          case 'edit':
            onEdit();
            break;
          case 'share':
            onShare();
            break;
          case 'done':
            onStatus(kStatusDone);
            break;
          case 'reopen':
            onStatus(kStatusScheduled);
            break;
          case 'cancel':
            onStatus(kStatusCancelled);
            break;
          case 'delete':
            onDelete();
            break;
        }
      },
      itemBuilder: (ctx) => [
        PopupMenuItem(
            value: 'edit',
            child: _Row(Icons.edit_rounded, t.edit)),
        PopupMenuItem(
            value: 'share',
            child: _Row(Icons.ios_share_rounded, mStr(ctx, 'mShare'))),
        if (done)
          PopupMenuItem(
              value: 'reopen',
              child: _Row(Icons.undo_rounded, mStr(ctx, 'mReopen')))
        else
          PopupMenuItem(
              value: 'done',
              child: _Row(Icons.check_circle_outline_rounded, mStr(ctx, 'mMarkDone'))),
        PopupMenuItem(
            value: 'cancel',
            child: _Row(Icons.event_busy_rounded, mStr(ctx, 'mMarkCancelled'))),
        PopupMenuItem(
            value: 'delete',
            child: _Row(Icons.delete_outline_rounded, t.delete)),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  final IconData icon;
  final String label;
  const _Row(this.icon, this.label);
  @override
  Widget build(BuildContext context) => Row(children: [
        Icon(icon, size: 18),
        const SizedBox(width: Gap.sm),
        Text(label),
      ]);
}

// ===========================================================================
// editor
// ===========================================================================
class _AppointmentEditor extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _AppointmentEditor({this.existing});
  @override
  State<_AppointmentEditor> createState() => _AppointmentEditorState();
}

class _AppointmentEditorState extends State<_AppointmentEditor> {
  late final TextEditingController _title;
  late final TextEditingController _place;
  late final TextEditingController _with;
  late final TextEditingController _note;
  late DateTime _date;
  late TimeOfDay _time;
  int _duration = 60;
  late Set<int> _leads;
  String _freq = kFreqNone;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _title = TextEditingController(text: '${e?['title'] ?? ''}');
    _place = TextEditingController(text: '${e?['place'] ?? ''}');
    _with = TextEditingController(
        text: e == null ? '' : withList(e).join(', '));
    _note = TextEditingController(text: '${e?['note'] ?? ''}');
    final s = e == null
        ? DateTime.now().add(const Duration(days: 1))
        : (DateTime.tryParse('${e['start']}') ??
            DateTime.now().add(const Duration(days: 1)));
    _date = s;
    _time = TimeOfDay(hour: s.hour, minute: s.minute);
    _duration = ((e?['duration_min'] ?? 60) as num).toInt().clamp(15, 240);
    final raw = (e?['reminder_offsets'] as List?)
        ?.map((x) => (x as num).toInt())
        .toList();
    _leads = {...(raw == null || raw.isEmpty ? kDefaultLeads : raw)};
    _freq = e == null ? kFreqNone : freqOf(e);
  }

  @override
  void dispose() {
    _title.dispose();
    _place.dispose();
    _with.dispose();
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
    final out = <String, dynamic>{
      'title': _title.text.trim(),
      'start': _start.toIso8601String(),
      'duration_min': _duration.clamp(5, 1440),
      'place': _place.text.trim(),
      'note': _note.text.trim(),
      'with': parseWith(_with.text),
      'reminder_offsets': cleanOffsets(_leads),
      'recurrence': recurrenceFor(_freq, _start),
      'status': widget.existing?['status'] ?? kStatusScheduled,
    };
    // Preserve coords if we're editing an entry that had them.
    if (widget.existing?['place_lat'] != null) {
      out['place_lat'] = widget.existing!['place_lat'];
      out['place_lng'] = widget.existing!['place_lng'];
    }
    Navigator.pop(context, out);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final df = DateFormat('EEE d MMM', Localizations.localeOf(context).languageCode);
    return Padding(
      padding: EdgeInsets.only(
        left: Gap.lg,
        right: Gap.lg,
        top: Gap.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg,
      ),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(t.meetingsAdd,
              style:
                  AType.titleLarge.copyWith(fontWeight: FontWeight.bold)),
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
                icon: const Icon(Icons.calendar_today_rounded, size: 16),
                label: Text(df.format(_date)),
                onPressed: () async {
                  final d = await showDatePicker(
                    context: context,
                    initialDate: _date,
                    firstDate:
                        DateTime.now().subtract(const Duration(days: 1)),
                    lastDate: DateTime.now().add(const Duration(days: 730)),
                  );
                  if (d != null) setState(() => _date = d);
                },
              ),
            ),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.schedule_rounded, size: 16),
                label: Text(_time.format(context)),
                onPressed: () async {
                  final p =
                      await showTimePicker(context: context, initialTime: _time);
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
          TextField(
            controller: _with,
            decoration: InputDecoration(
              labelText: mStr(context, 'mWith'),
              hintText: mStr(context, 'mWithHint'),
            ),
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
          // Repeat
          Align(
            alignment: Alignment.centerLeft,
            child: Text(mStr(context, 'mRecurrence'),
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: Gap.xs),
          Wrap(
            spacing: Gap.sm,
            children: [
              for (final f in kFreqOrder)
                ChoiceChip(
                  label: Text(freqLabel(context, f)),
                  selected: _freq == f,
                  onSelected: (_) => setState(() => _freq = f),
                ),
            ],
          ),
          const SizedBox(height: Gap.md),
          // Reminder lead-times (reuse reminders engine on the backend).
          Align(
            alignment: Alignment.centerLeft,
            child: Text(mStr(context, 'mReminderLead'),
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: Gap.xs),
          Wrap(
            spacing: Gap.sm,
            children: [
              for (final lead in kLeadOptions)
                FilterChip(
                  label: Text(leadLabel(context, lead)),
                  selected: _leads.contains(lead),
                  onSelected: (sel) => setState(() {
                    if (sel) {
                      _leads.add(lead);
                    } else {
                      _leads.remove(lead);
                    }
                  }),
                ),
            ],
          ),
          const SizedBox(height: Gap.lg),
          SizedBox(
            width: double.infinity,
            child: FilledButton(onPressed: _submit, child: Text(t.save)),
          ),
        ]),
      ),
    );
  }
}

// ===========================================================================
// empty / error states
// ===========================================================================
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
          const Icon(Icons.event_available_rounded,
              size: 56, color: Colors.grey),
          const SizedBox(height: Gap.md),
          Text(t.meetingsEmptyTitle,
              textAlign: TextAlign.center,
              style:
                  AType.titleMedium.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: Gap.xs),
          Text(t.meetingsEmptyBody,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey)),
          const SizedBox(height: Gap.lg),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add_rounded),
            label: Text(mStr(context, 'mAddFirst')),
          ),
        ]),
      ),
    );
  }
}

class _EmptyPast extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.history_rounded, size: 48, color: Colors.grey),
          const SizedBox(height: Gap.md),
          Text(mStr(context, 'mPast'),
              style: TextStyle(color: Theme.of(context).colorScheme.outline)),
        ]),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final VoidCallback onRetry;
  const _ErrorState({required this.onRetry});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline_rounded, size: 48, color: Brand.danger),
          const SizedBox(height: Gap.md),
          Text(mStr(context, 'mLoadError'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: Gap.md),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(t.retry),
          ),
        ]),
      ),
    );
  }
}
