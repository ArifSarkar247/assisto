/// daily_brief_engine.dart — on-device Dart mirror of
/// `backend/core/logic/daily_brief.py` (MORNING BRIEF & NIGHT SUMMARY, #7, §6,
/// §21).
///
/// A DETERMINISTIC engine: `now` is always passed in (never a live clock inside
/// the pure functions), so the offline assembly matches the Python source of
/// truth. It is PURE — no network, no AI, no key. It assembles two cards from
/// the user's OWN data (reminders / payments / birthdays / events) and invents
/// NOTHING. Weather & news are honest key-gated slots (Integrations
/// `weather` / `news`) — never fabricated. A warm AI narration is a documented
/// key-gated seam (`anthropic`), out of scope here.

/// One normalised brief item (kind: reminder | payment | birthday | event).
class BriefItem {
  final String kind;
  final String title;
  final String? when; // ISO, or null if undated
  final num? amount; // integer poisha or null (payments)
  final bool done;
  const BriefItem({
    required this.kind,
    required this.title,
    this.when,
    this.amount,
    this.done = false,
  });
}

const List<String> kBriefKinds = ['reminder', 'payment', 'birthday', 'event'];

DateTime? _parse(dynamic v) {
  if (v == null) return null;
  if (v is DateTime) return v.toLocal();
  final d = DateTime.tryParse(v.toString());
  return d?.toLocal();
}

DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

String _s(dynamic v) => (v ?? '').toString().trim();

/// Normalise the four heterogeneous source lists into one flat list. Skips rows
/// without a title (honest: a malformed row contributes nothing).
List<BriefItem> normaliseBrief({
  List<Map<String, dynamic>>? reminders,
  List<Map<String, dynamic>>? payments,
  List<Map<String, dynamic>>? birthdays,
  List<Map<String, dynamic>>? events,
}) {
  final out = <BriefItem>[];
  for (final r in (reminders ?? const [])) {
    final title = _s(r['title'] ?? r['text']);
    if (title.isEmpty) continue;
    out.add(BriefItem(
      kind: 'reminder',
      title: title,
      when: _parse(r['due_at'] ?? r['when'])?.toIso8601String(),
      done: r['done'] == true,
    ));
  }
  for (final p in (payments ?? const [])) {
    final title = _s(p['title'] ?? p['name'] ?? p['label']);
    if (title.isEmpty) continue;
    out.add(BriefItem(
      kind: 'payment',
      title: title,
      when: _parse(p['due_date'] ?? p['due_at'])?.toIso8601String(),
      amount: p['amount'] is num ? p['amount'] as num : null,
      done: p['paid'] == true || p['done'] == true,
    ));
  }
  for (final b in (birthdays ?? const [])) {
    final title = _s(b['name'] ?? b['title']);
    if (title.isEmpty) continue;
    out.add(BriefItem(
      kind: 'birthday',
      title: title,
      when: _parse(b['next'] ?? b['date'])?.toIso8601String(),
    ));
  }
  for (final e in (events ?? const [])) {
    final title = _s(e['title'] ?? e['name']);
    if (title.isEmpty) continue;
    out.add(BriefItem(
      kind: 'event',
      title: title,
      when: _parse(e['start'] ?? e['when'])?.toIso8601String(),
    ));
  }
  return out;
}

const Map<String, int> _kindOrder = {
  'payment': 0,
  'event': 1,
  'reminder': 2,
  'birthday': 3,
};

int _sortCompare(BriefItem a, BriefItem b) {
  final da = _parse(a.when);
  final db = _parse(b.when);
  final ta = da != null ? da.hour * 60 + da.minute : 24 * 60 + 1;
  final tb = db != null ? db.hour * 60 + db.minute : 24 * 60 + 1;
  if (ta != tb) return ta.compareTo(tb);
  final ka = _kindOrder[a.kind] ?? 9;
  final kb = _kindOrder[b.kind] ?? 9;
  if (ka != kb) return ka.compareTo(kb);
  return a.title.toLowerCase().compareTo(b.title.toLowerCase());
}

/// overdue | today | tomorrow | future | undated relative to `today` (date).
String _bucket(BriefItem it, DateTime today) {
  final dt = _parse(it.when);
  if (dt == null) return 'undated';
  final diff = _dayOnly(dt).difference(today).inDays;
  if (it.kind == 'birthday') {
    if (diff < 0) return 'future';
    return diff == 0 ? 'today' : (diff == 1 ? 'tomorrow' : 'future');
  }
  if (diff < 0) return 'overdue';
  if (diff == 0) return 'today';
  if (diff == 1) return 'tomorrow';
  return 'future';
}

/// The assembled brief (morning or night). Lists are already sorted.
class DailyBrief {
  final String mode; // morning | night
  final String date; // YYYY-MM-DD
  // morning
  final List<BriefItem> overdue;
  final List<BriefItem> today;
  // night
  final List<BriefItem> doneToday;
  final List<BriefItem> openToday;
  final List<BriefItem> tomorrow;
  final int completionPct;
  // shared
  final bool empty;
  final bool weatherConnected;
  final bool newsConnected;

  const DailyBrief({
    required this.mode,
    required this.date,
    this.overdue = const [],
    this.today = const [],
    this.doneToday = const [],
    this.openToday = const [],
    this.tomorrow = const [],
    this.completionPct = 0,
    required this.empty,
    this.weatherConnected = false,
    this.newsConnected = false,
  });

  int get doneCount => doneToday.length;
  int get openCount => openToday.length;
  bool get aiEnhanced => false;
  bool get mock => true;
}

/// Single entry point. `mode` in {morning, night}; anything else → morning.
DailyBrief buildBrief({
  String mode = 'morning',
  required DateTime now,
  List<Map<String, dynamic>>? reminders,
  List<Map<String, dynamic>>? payments,
  List<Map<String, dynamic>>? birthdays,
  List<Map<String, dynamic>>? events,
}) {
  final today = _dayOnly(now.toLocal());
  final dateStr = today.toIso8601String().substring(0, 10);
  final items = normaliseBrief(
      reminders: reminders,
      payments: payments,
      birthdays: birthdays,
      events: events);

  if (mode == 'night') {
    final done = <BriefItem>[];
    final open = <BriefItem>[];
    final tomorrow = <BriefItem>[];
    for (final it in items) {
      final b = _bucket(it, today);
      if (b == 'today') {
        (it.done ? done : open).add(it);
      } else if (b == 'tomorrow' && !it.done) {
        tomorrow.add(it);
      }
    }
    done.sort(_sortCompare);
    open.sort(_sortCompare);
    tomorrow.sort(_sortCompare);
    final due = done.length + open.length;
    final pct = due == 0 ? 0 : (done.length / due * 100).round();
    return DailyBrief(
      mode: 'night',
      date: dateStr,
      doneToday: done,
      openToday: open,
      tomorrow: tomorrow,
      completionPct: pct,
      empty: due == 0 && tomorrow.isEmpty,
    );
  }

  // morning
  final overdue = <BriefItem>[];
  final dueToday = <BriefItem>[];
  for (final it in items) {
    if (it.done) continue;
    final b = _bucket(it, today);
    if (b == 'overdue') {
      overdue.add(it);
    } else if (b == 'today') {
      dueToday.add(it);
    }
  }
  overdue.sort(_sortCompare);
  dueToday.sort(_sortCompare);
  return DailyBrief(
    mode: 'morning',
    date: dateStr,
    overdue: overdue,
    today: dueToday,
    empty: overdue.isEmpty && dueToday.isEmpty,
  );
}

/// Plain-text share body. Mirrors `daily_brief.py::share_text`. `labels` carries
/// the localised section headers from the app's ARB.
String shareBriefText(DailyBrief b, {Map<String, String>? labels}) {
  final l = {
    'overdue': 'Overdue',
    'today': 'Today',
    'tomorrow': 'Tomorrow',
    'done': 'Done',
    'open': 'Still open',
    'nothing': 'Nothing scheduled',
    ...?labels,
  };
  String fmt(BriefItem it) {
    var when = '';
    final d = _parse(it.when);
    if (d != null && !(d.hour == 0 && d.minute == 0)) {
      when = ' ${d.hour.toString().padLeft(2, '0')}:'
          '${d.minute.toString().padLeft(2, '0')}';
    }
    return '  - ${it.title}$when';
  }

  final lines = <String>[];
  final sections = b.mode == 'night'
      ? [
          ['done', b.doneToday],
          ['open', b.openToday],
          ['tomorrow', b.tomorrow],
        ]
      : [
          ['overdue', b.overdue],
          ['today', b.today],
        ];
  for (final s in sections) {
    final key = s[0] as String;
    final rows = s[1] as List<BriefItem>;
    if (rows.isNotEmpty) {
      lines.add('${l[key]}:');
      lines.addAll(rows.map(fmt));
    }
  }
  if (lines.isEmpty) lines.add(l['nothing']!);
  return lines.join('\n');
}
