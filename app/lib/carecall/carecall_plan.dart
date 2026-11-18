import 'dart:convert';

import '../push/push_payload.dart' show PushPayload;

/// carecall (owner order 4 Nov 01:50) — Care Call. PURE rules
/// (no Flutter, no plugins, no I/O; unit-tested in test/carecall_test.dart),
/// mirrored 1:1 from the server (backend/core/carecall.py) so the phone's
/// own alarm and the server's ring land on the SAME slot:
///  * times are the RECEIVER's wall time (CcItem.tzOffsetMin; Dhaka UTC+6
///    by default) — the clock the server rings on (gap-carecall);
///  * slot = 'YYYYMMDDHHMM' of the scheduled time (before quiet-hour shift);
///  * ring #1 at the slot (moved to the end of the receiver's quiet window
///    when inside it), ring #2 ten minutes later (same rule);
///  * days: 0 = Monday … 6 = Sunday.

const int kCcRetryMin = 10;
const int kCcSnoozeMin = 10;
const int kCcLookAhead = 2; // the next 2 slots of every schedule
const int kCcMaxLocalAlarms = 24;
const Duration _bd = Duration(hours: 6);
const int kCcDhakaOffsetMin = 360; // gap-carecall

/// One Care Call schedule as the server sends it (GET /carecall).
class CcItem {
  CcItem({
    required this.id,
    required this.text,
    required this.time,
    required this.repeat,
    this.days = const [],
    this.date = '',
    this.active = true,
    this.hasVoice = false,
    this.voiceRev = 0,
    this.voiceSec = 0,
    this.setterId = 0,
    this.receiverId = 0,
    this.otherName = '',
    this.otherInitial = '?',
    this.link = 'none',
    this.quietStart = '',
    this.quietEnd = '',
    this.tzOffsetMin = kCcDhakaOffsetMin,
  });

  final int id;
  final String text;
  final String time; // 'HH:MM'
  final String repeat; // once | daily | days
  final List<int> days;
  final String date; // once: 'YYYY-MM-DD'
  final bool active;
  final bool hasVoice;
  final int voiceRev;
  final int voiceSec;
  final int setterId;
  final int receiverId;
  final String otherName;
  final String otherInitial;
  final String link;
  final String quietStart;
  final String quietEnd;

  /// gap-carecall: the RECEIVER's clock (UTC offset, minutes) — the server
  /// rings on it, so this phone's own alarms must too (Dhaka = 360).
  final int tzOffsetMin;

  static int _i(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;

  static CcItem fromJson(Map<String, dynamic> j) => CcItem(
        id: _i(j['id']),
        text: '${j['text'] ?? ''}',
        time: '${j['time'] ?? '09:00'}',
        repeat: '${j['repeat'] ?? 'daily'}',
        days: [for (final d in (j['days'] as List? ?? const [])) _i(d)],
        date: '${j['date'] ?? ''}',
        active: j['active'] != false,
        hasVoice: j['has_voice'] == true,
        voiceRev: _i(j['voice_rev']),
        voiceSec: _i(j['voice_sec']),
        setterId: _i(j['setter_id']),
        receiverId: _i(j['receiver_id']),
        otherName: '${j['other_name'] ?? ''}',
        otherInitial: '${j['other_initial'] ?? '?'}',
        link: '${j['link'] ?? 'none'}',
        quietStart: '${j['quiet_start'] ?? ''}',
        quietEnd: '${j['quiet_end'] ?? ''}',
        tzOffsetMin: j['receiver_offset_min'] is num
            ? (j['receiver_offset_min'] as num).toInt()
            : kCcDhakaOffsetMin,
      );

  Map<String, dynamic> toJson() => {
        'id': id, 'text': text, 'time': time, 'repeat': repeat, 'days': days,
        'date': date, 'active': active, 'has_voice': hasVoice,
        'voice_rev': voiceRev, 'voice_sec': voiceSec, 'setter_id': setterId,
        'receiver_id': receiverId, 'other_name': otherName,
        'other_initial': otherInitial, 'link': link,
        'quiet_start': quietStart, 'quiet_end': quietEnd,
        'receiver_offset_min': tzOffsetMin,
      };
}

/// 'HH:MM' -> minutes of the day, or null.
int? ccMinutes(String s) {
  final p = s.split(':');
  if (p.length != 2 || p[0].length != 2 || p[1].length != 2) return null;
  final h = int.tryParse(p[0]), m = int.tryParse(p[1]);
  if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) return null;
  return h * 60 + m;
}

String ccHhmm(int h, int m) =>
    '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';

/// Bangladesh wall clock of an instant (a UTC DateTime whose fields are BD).
DateTime ccBdWall(DateTime instant) => instant.toUtc().add(_bd);

/// The instant of a Bangladesh wall time.
DateTime ccBdInstant(int y, int mo, int d, int h, int mi) =>
    DateTime.utc(y, mo, d, h, mi).subtract(_bd);

/// gap-carecall: the wall clock of an instant on a clock [offsetMin] minutes
/// ahead of UTC (a UTC DateTime whose fields are that clock's).
DateTime ccWall(DateTime instant, int offsetMin) =>
    instant.toUtc().add(Duration(minutes: offsetMin));

/// The instant of a wall time on the clock [offsetMin] minutes ahead of UTC.
DateTime ccInstant(int y, int mo, int d, int h, int mi, int offsetMin) =>
    DateTime.utc(y, mo, d, h, mi).subtract(Duration(minutes: offsetMin));

/// gap-carecall: the date (YYYY-MM-DD, on the receiver's clock) of the NEXT
/// time [hhmm] comes there after [now] — today when still ahead, else
/// tomorrow. The server reads a once-call date on the receiver's calendar.
String ccOnceNextDate(DateTime now, int hhmm, {int offsetMin = kCcDhakaOffsetMin}) {
  final w = ccWall(now, offsetMin);
  var day = DateTime.utc(w.year, w.month, w.day);
  final at = ccInstant(day.year, day.month, day.day, hhmm ~/ 60, hhmm % 60, offsetMin);
  if (!at.isAfter(now)) day = day.add(const Duration(days: 1));
  return '${day.year}-${_p2(day.month)}-${_p2(day.day)}';
}

/// The receiver's "today" (00:00 of their calendar day, as a plain date).
DateTime ccToday(DateTime now, {int offsetMin = kCcDhakaOffsetMin}) {
  final w = ccWall(now, offsetMin);
  return DateTime(w.year, w.month, w.day);
}

/// True when a once-call's date + time is already past on the receiver's clock.
bool ccOncePast(String ymd, int hhmm, DateTime now, {int offsetMin = kCcDhakaOffsetMin}) {
  final d = DateTime.tryParse(ymd);
  if (d == null) return false;
  return !ccInstant(d.year, d.month, d.day, hhmm ~/ 60, hhmm % 60, offsetMin).isAfter(now);
}

/// Same as the server's in_quiet (overnight wrap; empty / equal = never).
bool ccInQuiet(DateTime instant, String qs, String qe, {int offsetMin = kCcDhakaOffsetMin}) {
  final a = ccMinutes(qs), b = ccMinutes(qe);
  if (a == null || b == null || a == b) return false;
  final w = ccWall(instant, offsetMin);
  final t = w.hour * 60 + w.minute;
  return a < b ? (t >= a && t < b) : (t >= a || t < b);
}

/// [instant] moved to the end of the quiet window when inside it.
DateTime ccAfterQuiet(DateTime instant, String qs, String qe, {int offsetMin = kCcDhakaOffsetMin}) {
  if (!ccInQuiet(instant, qs, qe, offsetMin: offsetMin)) return instant;
  final e = ccMinutes(qe)!;
  final w = ccWall(instant, offsetMin);
  var end = ccInstant(w.year, w.month, w.day, e ~/ 60, e % 60, offsetMin);
  if (!end.isAfter(instant)) end = end.add(const Duration(days: 1));
  return end;
}

/// The first scheduled slot strictly after [after] (instant), or null.
DateTime? ccNextSlot(CcItem it, DateTime after) {
  final m = ccMinutes(it.time);
  if (m == null) return null;
  final off = it.tzOffsetMin; // gap-carecall: the receiver's clock, as the server
  final w = ccWall(after, off);
  if (it.repeat == 'once') {
    final d = DateTime.tryParse(it.date);
    if (d == null) return null;
    final at = ccInstant(d.year, d.month, d.day, m ~/ 60, m % 60, off);
    return at.isAfter(after) ? at : null;
  }
  final wanted = it.repeat == 'daily' ? null : it.days.where((d) => d >= 0 && d <= 6).toSet();
  if (wanted != null && wanted.isEmpty) return null;
  for (var i = 0; i < 8; i++) {
    final day = DateTime.utc(w.year, w.month, w.day).add(Duration(days: i));
    final at = ccInstant(day.year, day.month, day.day, m ~/ 60, m % 60, off);
    if (!at.isAfter(after)) continue;
    if (wanted == null || wanted.contains(day.weekday - 1)) return at;
  }
  return null;
}

String _p2(int v) => v.toString().padLeft(2, '0');

/// 'YYYYMMDDHHMM' (Bangladesh time) — the server's slot key.
String ccSlotOf(DateTime instant) {
  final w = ccBdWall(instant);
  return '${w.year}${_p2(w.month)}${_p2(w.day)}${_p2(w.hour)}${_p2(w.minute)}';
}

DateTime? ccSlotInstant(String slot) {
  if (slot.length != 12) return null;
  final y = int.tryParse(slot.substring(0, 4)), mo = int.tryParse(slot.substring(4, 6)),
      d = int.tryParse(slot.substring(6, 8)), h = int.tryParse(slot.substring(8, 10)),
      mi = int.tryParse(slot.substring(10, 12));
  if ([y, mo, d, h, mi].contains(null)) return null;
  return ccBdInstant(y!, mo!, d!, h!, mi!);
}

/// Notification id of one ring (attempt 1, 2, or 9 = a local snooze ring).
/// The server push for the same slot + attempt uses the SAME id
/// (PushPayload.notificationId), so the two never show twice.
int ccNotifId(String slotKey, int attempt) =>
    PushPayload.stableHash('cc-$slotKey-$attempt');

/// One alarm the receiver's phone holds by itself.
class CcLocalRing {
  const CcLocalRing(this.item, this.slot, this.attempt, this.at);
  final CcItem item;
  final String slot;
  final int attempt;
  final DateTime at; // instant
  String get slotKey => '${item.id}-$slot';
  int get id => ccNotifId(slotKey, attempt);
}

/// The receiver's own alarms: for every ACCEPTED, active schedule, the next
/// [kCcLookAhead] slots, ring #1 and ring #2 (+10 min), quiet hours applied,
/// slots already answered ([handled]) skipped, soonest first, capped.
List<CcLocalRing> ccPlanLocal(List<CcItem> received, DateTime now,
    {Set<String> handled = const {}}) {
  final out = <CcLocalRing>[];
  for (final it in received) {
    if (!it.active || it.link != 'accepted') continue;
    var after = now.subtract(const Duration(minutes: kCcRetryMin + 1));
    for (var k = 0; k < kCcLookAhead; k++) {
      final s = ccNextSlot(it, after);
      if (s == null) break;
      after = s;
      final slot = ccSlotOf(s);
      if (handled.contains('${it.id}-$slot')) continue;
      final off = it.tzOffsetMin;
      final r1 = ccAfterQuiet(s, it.quietStart, it.quietEnd, offsetMin: off);
      final r2 = ccAfterQuiet(r1.add(const Duration(minutes: kCcRetryMin)), it.quietStart, it.quietEnd,
          offsetMin: off);
      if (r1.isAfter(now)) out.add(CcLocalRing(it, slot, 1, r1));
      if (r2.isAfter(now)) out.add(CcLocalRing(it, slot, 2, r2));
    }
  }
  out.sort((a, b) => a.at.compareTo(b.at));
  return out.length > kCcMaxLocalAlarms ? out.sublist(0, kCcMaxLocalAlarms) : out;
}

/// The ring payload (same keys as the server's "carecall" push data) — the
/// local alarm's notification payload and the ring screen's input.
Map<String, String> ccRingData(CcItem it, String slot, int attempt,
        {required String lang}) =>
    {
      'kind': 'carecall',
      'route': 'carecall',
      'care_call_id': '${it.id}',
      'slot': slot,
      'slot_key': '${it.id}-$slot',
      'attempt': '$attempt',
      'setter_id': '${it.setterId}',
      'setter_name': it.otherName,
      'setter_initial': it.otherInitial,
      'text': it.text,
      'voice_rev': '${it.hasVoice ? it.voiceRev : 0}',
      'lang': lang,
      'channel': 'calls',
      'local': '1',
    };

String ccEncode(Map<String, String> d) => jsonEncode(d);
