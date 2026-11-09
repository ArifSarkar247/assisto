// fcelder — Silent Watch brain (Family Care V3, Brain 1). PURE Dart, no I/O:
// the same functions drive the phone, the synthetic-day simulator test and
// the deadline table the native alarm reads.
//
// What counts as "the elder is up and about" (all ON THE PHONE, nothing is
// sent to the server): the screen in use (unlocked) when a check runs, the
// charger plugged in / pulled out, Assisto used (Easy Home, Care Call
// answered, "I am OK"). No movement sensor: ACTIVITY_RECOGNITION is removed
// from the app's manifest and the owner rule is no new sensitive permission.
//
// Silence is counted ONLY inside the elder's day window (default 07:00-22:00):
// a long night's sleep is never "silence".
//
// LEARNING (7 days, on the phone): for every half hour of the day the brain
// looks at the quiet stretches the elder had starting within 2 hours of it
// (an after-lunch nap, Friday prayers, a long TV evening) and takes the 4th
// longest of the week — one odd day (a long outing) does not count as
// "normal". After 7 days it rings when today's silence is LONGER than that
// (x1.2 + 30 min): never sooner than 90 min, never later than 2 x N hours.
// So at a busy time of day the first "Are you OK?" comes much sooner than N
// hours; at a normally quiet time it waits. Until day 7: exactly N hours.
//
// FALSE-ALARM GUARD: if the family was told in the last 14 days (and the
// elder then turned out fine — else nobody is re-learning), the brain goes
// back to the cautious table (single longest stretch, never sooner than N
// hours) for that elder. "I am going out" (Easy Home) pauses the asking
// until the chosen time + 30 min; any later sign of life ends the pause.
//
// The ladder on the phone: 4 rings 5 min apart (rings only ever happen in
// the day window), then the family — 20 min instead of 30.
//
// The output is a 48-entry table: for a last sign of life in half-hour slot
// s, ring "Are you OK?" table[s] wall-clock minutes later. The native alarm
// only does deadline = last + table[slot(last)] — no logic duplicated there.
import 'dart:math' as math;

class SwConfig {
  /// Never alert sooner than this many hours of in-day silence.
  final int hours;

  /// Day window, minutes after midnight (start < end).
  final int dayStartMin;
  final int dayEndMin;

  const SwConfig({this.hours = 4, this.dayStartMin = 7 * 60, this.dayEndMin = 22 * 60});

  static int? parseHhmm(String? s) {
    final m = RegExp(r'^(\d{2}):(\d{2})$').firstMatch(s ?? '');
    if (m == null) return null;
    final h = int.parse(m.group(1)!), mi = int.parse(m.group(2)!);
    if (h > 23 || mi > 59) return null;
    return h * 60 + mi;
  }

  factory SwConfig.fromJson(Map<String, dynamic> j) {
    final h = (j['hours'] is num) ? (j['hours'] as num).toInt() : 4;
    final s = parseHhmm('${j['day_start'] ?? ''}') ?? 7 * 60;
    final e = parseHhmm('${j['day_end'] ?? ''}') ?? 22 * 60;
    return SwConfig(
        hours: h.clamp(2, 12),
        dayStartMin: s < e ? s : 7 * 60,
        dayEndMin: s < e ? e : 22 * 60);
  }

  int get windowMin => dayEndMin - dayStartMin;
}

class SwLearned {
  /// Days of history behind the table (0..7).
  final int daysLearned;

  /// In-window minutes of silence allowed per slot.
  final List<int> allowanceMin;

  /// Wall-clock minutes from a sign of life in slot s to the first ring.
  final List<int> tableMin;

  const SwLearned(this.daysLearned, this.allowanceMin, this.tableMin);

  bool get learned => daysLearned >= SilentWatchBrain.learnDays;
}

class SilentWatchBrain {
  SilentWatchBrain._();

  static const slots = 48;
  static const slotMin = 30;
  static const learnDays = 7;

  /// Rings before the family is told, and the gap between them.
  static const rings = 4;
  static const ringGapMin = 5;

  /// After learning: the k-th longest quiet stretch within [nearSlots]
  /// half-hours (either side) is "normal" for that time of day.
  static const rankK = 4;
  static const nearSlots = 4;

  /// Never ask sooner than this after learning (minutes of in-day silence).
  static const minAllowanceMin = 90;

  /// A family alert within this many days -> the cautious table.
  static const guardDays = 14;

  /// "I am going out": ask again only this long after the chosen time.
  static const awayGraceMin = 30;

  static int slotOf(DateTime t) => (t.hour * 60 + t.minute) ~/ slotMin;

  static DateTime _day(DateTime t, int addDays) => DateTime(t.year, t.month, t.day + addDays);

  /// Minutes between [a] and [b] that fall inside the day window.
  static int windowMinutesBetween(DateTime a, DateTime b, SwConfig c) {
    if (!b.isAfter(a)) return 0;
    var total = 0;
    for (var d = _day(a, 0); d.isBefore(b); d = _day(d, 1)) {
      final ws = d.add(Duration(minutes: c.dayStartMin));
      final we = d.add(Duration(minutes: c.dayEndMin));
      final s = a.isAfter(ws) ? a : ws;
      final e = b.isBefore(we) ? b : we;
      if (e.isAfter(s)) total += e.difference(s).inMinutes;
    }
    return total;
  }

  /// [t] moved forward by [minutes] of in-window time.
  static DateTime addWindowMinutes(DateTime t, int minutes, SwConfig c) {
    var cur = t;
    var left = math.max(0, minutes);
    for (var guard = 0; guard < 400; guard++) {
      final d = _day(cur, 0);
      final ws = d.add(Duration(minutes: c.dayStartMin));
      final we = d.add(Duration(minutes: c.dayEndMin));
      if (cur.isBefore(ws)) cur = ws;
      if (!cur.isBefore(we)) {
        cur = _day(cur, 1).add(Duration(minutes: c.dayStartMin));
        continue;
      }
      final avail = we.difference(cur).inMinutes;
      if (left <= avail) return cur.add(Duration(minutes: left));
      left -= avail;
      cur = _day(cur, 1).add(Duration(minutes: c.dayStartMin));
    }
    return cur;
  }

  static int floorMin(SwConfig c) => c.hours * 60;
  static int capMin(SwConfig c) => math.max(floorMin(c), math.min(2 * floorMin(c), 12 * 60));

  /// True when the family was told within [guardDays] before [now].
  static bool cautious(List<DateTime> told, DateTime now) =>
      told.any((t) => !t.isAfter(now) && now.difference(t).inMinutes < guardDays * 24 * 60);

  /// Learns the elder's normal day from the activity log (any order, may
  /// hold duplicates). Only the last [learnDays] days are used. [told] =
  /// when the family was told (the false-alarm guard).
  static SwLearned learn(List<DateTime> log, DateTime now, SwConfig c,
      {List<DateTime> told = const []}) {
    final acts = log.where((t) => !t.isAfter(now)).toList()..sort();
    final floor = floorMin(c), cap = capMin(c);
    var days = 0;
    if (acts.isNotEmpty) {
      days = math.min(learnDays, now.difference(acts.first).inHours ~/ 24);
    }
    final allowance = List<int>.filled(slots, floor);
    if (days >= learnDays) {
      final from = now.subtract(const Duration(days: learnDays));
      final recent = acts.where((t) => t.isAfter(from)).toList();
      final careful = cautious(told, now);
      final near = careful ? 1 : nearSlots;
      final gaps = List<List<int>>.generate(slots, (_) => <int>[]);
      for (var i = 0; i + 1 < recent.length; i++) {
        final g = windowMinutesBetween(recent[i], recent[i + 1], c);
        if (g <= 0) continue;
        final s = slotOf(recent[i]);
        for (var k = s - near; k <= s + near; k++) {
          if (k >= 0 && k < slots) gaps[k].add(g);
        }
      }
      for (var s = 0; s < slots; s++) {
        final v = gaps[s]..sort((a, b) => b.compareTo(a));
        final int normal;
        if (careful) {
          normal = v.isEmpty ? 0 : v.first;
        } else {
          // Too few stretches to know this time of day: stay at N hours.
          normal = v.length >= rankK ? v[rankK - 1] : floor;
        }
        final want = (normal * 1.2).round() + 30;
        allowance[s] = want.clamp(careful ? floor : math.min(floor, minAllowanceMin), cap);
      }
    }
    final table = List<int>.generate(slots, (s) {
      final mid = DateTime(2026, 1, 5).add(Duration(minutes: s * slotMin + slotMin ~/ 2));
      return math.max(slotMin, addWindowMinutes(mid, allowance[s], c).difference(mid).inMinutes);
    });
    return SwLearned(days, allowance, table);
  }

  /// When the first "Are you OK?" rings after a sign of life at [last].
  /// A ring that would land outside the day window (the table is per half
  /// hour, so it can spill a few minutes) waits until 30 min after the next
  /// day start — never a night ring. Mirrored 1:1 in SilentWatch.kt ringAt.
  static DateTime ringAt(DateTime last, List<int> table, SwConfig c) {
    final t = last.add(Duration(minutes: table[slotOf(last)]));
    final m = t.hour * 60 + t.minute;
    if (m >= c.dayStartMin && m < c.dayEndMin) return t;
    final day = m >= c.dayEndMin ? _day(t, 1) : _day(t, 0);
    return day.add(Duration(minutes: c.dayStartMin + 30));
  }

  /// [ringAt] when the elder tapped "I am going out" at [tapped] until
  /// [awayUntil] (no later sign of life): never before awayUntil + 30 min.
  /// Mirrored 1:1 in SilentWatch.kt schedule.
  static DateTime ringAtAway(DateTime last, List<int> table, SwConfig c, DateTime awayUntil) {
    final r = ringAt(last, table, c);
    final a = awayUntil.add(const Duration(minutes: awayGraceMin));
    if (!a.isAfter(r)) return r;
    final m = a.hour * 60 + a.minute;
    if (m >= c.dayStartMin && m < c.dayEndMin) return a;
    final day = m >= c.dayEndMin ? _day(a, 1) : _day(a, 0);
    return day.add(Duration(minutes: c.dayStartMin + 30));
  }

  /// The family hears only after every ring went unanswered.
  static DateTime familyAt(DateTime firstRing) =>
      firstRing.add(const Duration(minutes: rings * ringGapMin));
}
