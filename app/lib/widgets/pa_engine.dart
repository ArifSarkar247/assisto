import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';

/// PA (Personal Assistant / Secretary) engine — the on-device DETERMINISTIC
/// mirror of backend/core/logic/pa_schedule.py + pa_brief.py (SPEC §14
/// #103/#104, advanced §21).
///
/// Everything here is PURE Dart: no network, no AI, and `now` is always passed
/// in so previews/tests are deterministic and match the server. There is ZERO
/// Bangla in this file — all user-facing strings come from AppLocalizations
/// getters at the call site (this file only computes data + ints).

// ---------------------------------------------------------------------------
// slot kinds / statuses (mirror pa_schedule KIND_* / STATUS_*)
// ---------------------------------------------------------------------------
const kKindMeeting = 'meeting';
const kKindAppointment = 'appointment';
const kKindCall = 'call';
const kKindTask = 'task';
const kKindBlock = 'block';
const List<String> kKinds = [
  kKindMeeting,
  kKindAppointment,
  kKindCall,
  kKindTask,
  kKindBlock,
];

const kStatusTentative = 'tentative';
const kStatusConfirmed = 'confirmed';
const kStatusDone = 'done';
const kStatusCancelled = 'cancelled';

const int kDurationDefaultMin = 30;
const int kDurationMin = 5;
const int kDurationMax = 24 * 60;

/// Reminder lead options (minutes before start). Mirrors pa_brief.LEAD_OPTIONS.
const List<int> kLeadOptions = [1440, 60, 30, 15, 0];
const List<int> kDefaultLeads = [1440, 60];

int clampDuration(dynamic minutes) {
  final m = minutes is int ? minutes : int.tryParse('$minutes');
  if (m == null) return kDurationDefaultMin;
  if (m < kDurationMin) return kDurationMin;
  if (m > kDurationMax) return kDurationMax;
  return m;
}

String cleanKind(dynamic v) {
  final s = '${v ?? kKindMeeting}'.trim().toLowerCase();
  return kKinds.contains(s) ? s : kKindMeeting;
}

String statusOf(Map<String, dynamic> s) {
  final v = '${s['status'] ?? kStatusConfirmed}'.trim().toLowerCase();
  const all = [
    kStatusTentative,
    kStatusConfirmed,
    kStatusDone,
    kStatusCancelled
  ];
  return all.contains(v) ? v : kStatusConfirmed;
}

bool isActive(Map<String, dynamic> s) => statusOf(s) != kStatusCancelled;

DateTime? parseDt(dynamic v) {
  if (v == null) return null;
  if (v is DateTime) return v;
  return DateTime.tryParse('$v');
}

DateTime? startOf(Map<String, dynamic> s) => parseDt(s['start']);

DateTime? endOf(Map<String, dynamic> s) {
  final st = startOf(s);
  if (st == null) return null;
  return st.add(Duration(minutes: clampDuration(s['duration_min'])));
}

// ---------------------------------------------------------------------------
// validation
// ---------------------------------------------------------------------------
List<String> validateSlot(Map<String, dynamic> s) {
  final out = <String>[];
  if ('${s['title'] ?? ''}'.trim().isEmpty) out.add('title_required');
  if (parseDt(s['start']) == null) out.add('start_required');
  final d = s['duration_min'];
  if (d != null) {
    final n = d is int ? d : int.tryParse('$d');
    if (n == null || n <= 0) out.add('bad_duration');
  }
  return out;
}

// ---------------------------------------------------------------------------
// conflict (overlap) detection — mirrors pa_schedule.conflicts
// ---------------------------------------------------------------------------
class Conflict {
  final int a;
  final int b;
  final int overlapMin;
  const Conflict(this.a, this.b, this.overlapMin);
}

List<Conflict> conflicts(List<Map<String, dynamic>> slots) {
  final items = <List<dynamic>>[]; // [index, start, end]
  for (var i = 0; i < slots.length; i++) {
    final s = slots[i];
    if (!isActive(s)) continue;
    final st = startOf(s);
    if (st == null) continue;
    final en = st.add(Duration(minutes: clampDuration(s['duration_min'])));
    items.add([i, st, en]);
  }
  items.sort((x, y) => (x[1] as DateTime).compareTo(y[1] as DateTime));
  final out = <Conflict>[];
  for (var p = 0; p < items.length; p++) {
    final ip = items[p][0] as int;
    final sp = items[p][1] as DateTime;
    final ep = items[p][2] as DateTime;
    for (var q = p + 1; q < items.length; q++) {
      final iq = items[q][0] as int;
      final sq = items[q][1] as DateTime;
      final eq = items[q][2] as DateTime;
      if (!sq.isBefore(ep)) break; // sorted; no later item overlaps p
      if (sp.isBefore(eq) && sq.isBefore(ep)) {
        final ovStart = sp.isAfter(sq) ? sp : sq;
        final ovEnd = ep.isBefore(eq) ? ep : eq;
        final overlap = ovEnd.difference(ovStart).inMinutes;
        if (overlap <= 0) continue;
        final lo = ip < iq ? ip : iq;
        final hi = ip < iq ? iq : ip;
        out.add(Conflict(lo, hi, overlap));
      }
    }
  }
  out.sort((x, y) => x.a != y.a ? x.a.compareTo(y.a) : x.b.compareTo(y.b));
  return out;
}

Set<int> conflictingIndexes(List<Map<String, dynamic>> slots) {
  final s = <int>{};
  for (final c in conflicts(slots)) {
    s.add(c.a);
    s.add(c.b);
  }
  return s;
}

// ---------------------------------------------------------------------------
// agenda bucketing (day / week) — mirrors pa_schedule.agenda
// ---------------------------------------------------------------------------
class AgendaItem {
  final Map<String, dynamic> slot;
  final int index;
  const AgendaItem(this.slot, this.index);
}

class AgendaDay {
  final String date; // YYYY-MM-DD
  final List<AgendaItem> items;
  const AgendaDay(this.date, this.items);
}

({DateTime start, DateTime end}) _window(String scope, DateTime anchor) {
  final a = DateTime(anchor.year, anchor.month, anchor.day);
  if (scope == 'week') {
    final start = a.subtract(Duration(days: a.weekday - 1)); // Monday
    return (start: start, end: start.add(const Duration(days: 7)));
  }
  return (start: a, end: a.add(const Duration(days: 1)));
}

List<AgendaDay> agenda(
  List<Map<String, dynamic>> slots, {
  String scope = 'day',
  DateTime? anchor,
  bool includeCancelled = false,
}) {
  final now = DateTime.now();
  final win = _window(scope, anchor ?? now);
  final buckets = <String, List<List<dynamic>>>{}; // key -> [start,title,i,slot]
  for (var i = 0; i < slots.length; i++) {
    final s = slots[i];
    if (!includeCancelled && !isActive(s)) continue;
    final sd = startOf(s);
    if (sd == null) continue;
    if (sd.isBefore(win.start) || !sd.isBefore(win.end)) continue;
    final key = DateFormat('yyyy-MM-dd').format(sd);
    buckets.putIfAbsent(key, () => []).add([sd, '${s['title'] ?? ''}', i, s]);
  }
  final out = <AgendaDay>[];
  for (final key in buckets.keys.toList()..sort()) {
    final rows = buckets[key]!
      ..sort((x, y) {
        final c = (x[0] as DateTime).compareTo(y[0] as DateTime);
        return c != 0 ? c : (x[1] as String).compareTo(y[1] as String);
      });
    out.add(AgendaDay(key,
        rows.map((r) => AgendaItem(r[3] as Map<String, dynamic>, r[2] as int)).toList()));
  }
  return out;
}

// ---------------------------------------------------------------------------
// "next up" — mirrors pa_schedule.next_up
// ---------------------------------------------------------------------------
class NextUp {
  final bool hasNext;
  final int? index;
  final Map<String, dynamic>? slot;
  final bool inProgress;
  final int? minutesUntil;
  const NextUp(
      {required this.hasNext,
      this.index,
      this.slot,
      this.inProgress = false,
      this.minutesUntil});
}

NextUp nextUp(List<Map<String, dynamic>> slots, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final cand = <List<dynamic>>[]; // [start, end, index, slot]
  for (var i = 0; i < slots.length; i++) {
    final s = slots[i];
    final st = statusOf(s);
    if (st == kStatusCancelled || st == kStatusDone) continue;
    final sd = startOf(s);
    if (sd == null) continue;
    final ed = sd.add(Duration(minutes: clampDuration(s['duration_min'])));
    if (!ed.isAfter(n)) continue; // finished
    cand.add([sd, ed, i, s]);
  }
  if (cand.isEmpty) return const NextUp(hasNext: false);
  cand.sort((x, y) {
    final c = (x[0] as DateTime).compareTo(y[0] as DateTime);
    return c != 0 ? c : (x[2] as int).compareTo(y[2] as int);
  });
  final sd = cand[0][0] as DateTime;
  final idx = cand[0][2] as int;
  final slot = cand[0][3] as Map<String, dynamic>;
  final inProg = !sd.isAfter(n); // started (and not finished per filter)
  final mins = inProg ? 0 : sd.difference(n).inMinutes;
  return NextUp(
      hasNext: true,
      index: idx,
      slot: slot,
      inProgress: inProg,
      minutesUntil: mins);
}

// ---------------------------------------------------------------------------
// brief assembly — mirrors pa_brief.assemble_brief
// ---------------------------------------------------------------------------
List<String> splitBullets(dynamic raw) {
  final items = <String>[];
  if (raw is List) {
    items.addAll(raw.map((e) => '$e'));
  } else if (raw != null && '$raw'.isNotEmpty) {
    for (final part in '$raw'.replaceAll('•', '\n').split('\n')) {
      items.add(part);
    }
  }
  final out = <String>[];
  final seen = <String>{};
  for (final it in items) {
    var t = it.trim();
    // strip common leading bullet chars the user may have typed
    while (t.isNotEmpty && (t[0] == '-' || t[0] == '*' || t[0] == '•')) {
      t = t.substring(1).trim();
    }
    if (t.isNotEmpty && seen.add(t)) out.add(t);
  }
  return out;
}

class Brief {
  final String title;
  final bool hasCore;
  final DateTime? start;
  final DateTime? end;
  final int durationMin;
  final String where;
  final List<String> who;
  final String what;
  final List<String> agenda;
  final List<String> prep;
  final String note;
  final List<String> missing;
  const Brief({
    required this.title,
    required this.hasCore,
    required this.start,
    required this.end,
    required this.durationMin,
    required this.where,
    required this.who,
    required this.what,
    required this.agenda,
    required this.prep,
    required this.note,
    required this.missing,
  });
}

Brief assembleBrief(Map<String, dynamic> m) {
  final title = '${m['title'] ?? ''}'.trim();
  final start = parseDt(m['start']);
  var duration = clampDuration(m['duration_min']);
  if (m['duration_min'] == null) duration = kDurationDefaultMin;
  final end = start?.add(Duration(minutes: duration));

  final organiser = '${m['organiser'] ?? ''}'.trim();
  final who = <String>[];
  final seen = <String>{};
  for (final n in [
    if (organiser.isNotEmpty) organiser,
    ...((m['people'] as List?) ?? const [])
  ]) {
    final nm = '$n'.trim();
    if (nm.isNotEmpty && seen.add(nm)) who.add(nm);
  }

  final where = '${m['place'] ?? ''}'.trim();
  final what = '${m['purpose'] ?? m['what'] ?? ''}'.trim();
  final agenda = splitBullets(m['agenda']);
  final prep = splitBullets(m['prep']);
  final note = '${m['note'] ?? ''}'.trim();

  final missing = <String>[];
  if (where.isEmpty) missing.add('where');
  if (who.isEmpty) missing.add('who');
  if (what.isEmpty) missing.add('what');
  if (agenda.isEmpty) missing.add('agenda');
  if (prep.isEmpty) missing.add('prep');

  return Brief(
    title: title,
    hasCore: title.isNotEmpty && start != null,
    start: start,
    end: end,
    durationMin: duration,
    where: where,
    who: who,
    what: what,
    agenda: agenda,
    prep: prep,
    note: note,
    missing: missing,
  );
}

int briefCompleteness(Map<String, dynamic> m) {
  final b = assembleBrief(m);
  if (!b.hasCore) return 0;
  final filled = 5 - b.missing.length;
  const base = 20;
  return base + ((filled / 5.0) * (100 - base)).round();
}

// ---------------------------------------------------------------------------
// reminder leads — mirrors pa_brief.clean_leads / reminder_times
// ---------------------------------------------------------------------------
List<int> cleanLeads(List<int>? offsets) {
  if (offsets == null) return List.of(kDefaultLeads);
  final allowed = kLeadOptions.toSet();
  final seen = <int>{};
  final out = <int>[];
  for (final o in offsets) {
    if (allowed.contains(o) && seen.add(o)) out.add(o);
  }
  if (out.isEmpty) return List.of(kDefaultLeads);
  out.sort((a, b) => b.compareTo(a)); // descending
  return out;
}

List<DateTime> reminderTimes(DateTime? start, List<int>? leads, {DateTime? now}) {
  if (start == null) return [];
  final n = now ?? DateTime.now();
  final seen = <String>{};
  final out = <DateTime>[];
  for (final off in cleanLeads(leads)) {
    final t = start.subtract(Duration(minutes: off));
    if (!t.isAfter(n)) continue;
    if (seen.add(t.toIso8601String())) out.add(t);
  }
  out.sort();
  return out;
}

class ReminderSummary {
  final int count;
  final DateTime? next;
  final bool allPast;
  const ReminderSummary(this.count, this.next, this.allPast);
}

ReminderSummary reminderSummary(DateTime? start, List<int>? leads,
    {DateTime? now}) {
  final chosen = cleanLeads(leads);
  final times = reminderTimes(start, leads, now: now);
  final allPast = chosen.isNotEmpty && start != null && times.isEmpty;
  return ReminderSummary(times.length, times.isEmpty ? null : times.first, allPast);
}

/// Build the plain-text brief for share/export. Labels come from the ARB so the
/// body is localized; this function emits NO Bangla itself.
String briefShareText(BuildContext context, Map<String, dynamic> m) {
  final t = AppLocalizations.of(context);
  final b = assembleBrief(m);
  final df = DateFormat('yyyy-MM-dd HH:mm');
  final hf = DateFormat('HH:mm');
  final lines = <String>[];
  if (b.title.isNotEmpty) lines.add(b.title);
  if (b.start != null) {
    var when = df.format(b.start!);
    if (b.end != null) when += '–${hf.format(b.end!)}';
    lines.add('${t.paBriefWhen}: $when');
  }
  if (b.where.isNotEmpty) lines.add('${t.paBriefWhere}: ${b.where}');
  if (b.who.isNotEmpty) lines.add('${t.paBriefWho}: ${b.who.join(', ')}');
  if (b.what.isNotEmpty) lines.add('${t.paBriefWhat}: ${b.what}');
  if (b.agenda.isNotEmpty) {
    lines.add('${t.paBriefAgenda}:');
    lines.addAll(b.agenda.map((x) => '  - $x'));
  }
  if (b.prep.isNotEmpty) {
    lines.add('${t.paBriefPrep}:');
    lines.addAll(b.prep.map((x) => '  [ ] $x'));
  }
  if (b.note.isNotEmpty) lines.add('${t.paBriefNote}: ${b.note}');
  return lines.join('\n');
}

// ---------------------------------------------------------------------------
// localized label helpers (map engine keys -> ARB getters)
// ---------------------------------------------------------------------------
String kindLabel(AppLocalizations t, String kind) {
  switch (kind) {
    case kKindAppointment:
      return t.paKindAppointment;
    case kKindCall:
      return t.paKindCall;
    case kKindTask:
      return t.paKindTask;
    case kKindBlock:
      return t.paKindBlock;
    case kKindMeeting:
    default:
      return t.paKindMeeting;
  }
}

String statusLabel(AppLocalizations t, String status) {
  switch (status) {
    case kStatusTentative:
      return t.paStatusTentative;
    case kStatusDone:
      return t.paStatusDone;
    case kStatusCancelled:
      return t.paStatusCancelled;
    case kStatusConfirmed:
    default:
      return t.paStatusConfirmed;
  }
}

String leadLabel(AppLocalizations t, int minutes) {
  switch (minutes) {
    case 1440:
      return t.paLead1Day;
    case 60:
      return t.paLead1Hour;
    case 30:
      return t.paLead30Min;
    case 15:
      return t.paLead15Min;
    case 0:
      return t.paLeadAtTime;
    default:
      return '$minutes';
  }
}

String slotProblemLabel(AppLocalizations t, String key) {
  switch (key) {
    case 'start_required':
      return t.paErrStart;
    case 'bad_duration':
      return t.paErrDuration;
    case 'title_required':
    default:
      return t.paErrTitle;
  }
}
