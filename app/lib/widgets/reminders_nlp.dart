// Client-side natural-language date/time/recurrence parser for the reminders
// quick-add box. A faithful mirror of backend/core/logic/nlp_datetime.py so the
// user gets an INSTANT, offline preview of what Assisto understood before they
// confirm. The backend endpoint (POST /reminders/parse) remains the source of
// truth for AI-captured reminders; this is purely for responsive local preview.
//
// NOTE: no Bangla characters appear literally in this file (language gate) --
// every Bangla keyword is written with \u escapes.

/// Result of parsing a natural-language reminder phrase.
class ParsedReminder {
  final DateTime? dateTime; // next concrete occurrence (local)
  final bool dateOnly; // true when no explicit clock time was given
  final RecurrenceRule? recurrence;
  final String cleanTitle; // phrase with date/time words stripped
  final double confidence; // 0..1
  const ParsedReminder({
    this.dateTime,
    this.dateOnly = true,
    this.recurrence,
    this.cleanTitle = '',
    this.confidence = 0,
  });

  bool get hasSchedule => dateTime != null || recurrence != null;
}

class RecurrenceRule {
  final String freq; // daily | weekly | monthly | yearly
  final int interval;
  final int? weekday; // 0=Mon .. 6=Sun
  final int? dayOfMonth; // 1..31
  final int? month; // 1..12
  final String? time; // HH:MM
  const RecurrenceRule({
    required this.freq,
    this.interval = 1,
    this.weekday,
    this.dayOfMonth,
    this.month,
    this.time,
  });

  Map<String, dynamic> toJson() => {
        'freq': freq,
        'interval': interval,
        'weekday': weekday,
        'day_of_month': dayOfMonth,
        'month': month,
        'time': time,
      };
}

const _defaultHour = 9;

// ---- Bangla keyword constants (escaped so no Bangla literals in source) ----
const _biTomorrow = ['\u0986\u0997\u09be\u09ae\u09c0\u0995\u09be\u09b2',
  '\u0986\u0997\u09be\u09ae\u09bf\u0995\u09be\u09b2', '\u0995\u09be\u09b2\u0995\u09c7',
  '\u0995\u09be\u09b2']; // agamikal, kalke, kal
const _biToday = ['\u0986\u099c\u0995\u09c7', '\u0986\u099c']; // ajke, aj
const _biDayAfter = '\u09aa\u09b0\u09b6\u09c1'; // porshu
const _biDaily = ['\u09aa\u09cd\u09b0\u09a4\u09bf\u09a6\u09bf\u09a8',
  '\u09b0\u09cb\u099c']; // protidin, roj
const _biEvery = '\u09aa\u09cd\u09b0\u09a4\u09bf'; // proti
const _biMonthOf = '\u09ae\u09be\u09b8'; // mash (prefix of masher)
const _biDateWord = '\u09a4\u09be\u09b0\u09bf\u0996'; // tarikh
const _biNextWord = '\u0986\u0997\u09be\u09ae\u09c0'; // agami
const _biDay = '\u09a6\u09bf\u09a8'; // din
const _biAfter = ['\u09aa\u09b0\u09c7', '\u09aa\u09b0']; // pore, por
const _biTa = '\u099f\u09be'; // Ta (o'clock)
const _biMinute = '\u09ae\u09bf\u09a8\u09bf\u099f'; // minit
const _biHour = ['\u0998\u09a3\u09cd\u099f\u09be', '\u0998\u09a8\u09cd\u099f\u09be']; // ghonta
const _biHalf = ['\u0986\u09a7\u09be', '\u0986\u09a7']; // adha
const _biThisMonth = ['\u098f\u0987', '\u099a\u09b2\u09a4\u09bf']; // ei, cholti


// day-part -> default hour; the bool marks PM-ish parts for bare-hour handling.
const Map<String, List<Object>> _dayparts = {
  '\u09b8\u0995\u09be\u09b2': [8, false], // sokal
  '\u09ad\u09cb\u09b0': [6, false], // bhor
  '\u09a6\u09c1\u09aa\u09c1\u09b0': [13, true], // dupur
  '\u09ac\u09bf\u0995\u09be\u09b2': [16, true], // bikal
  '\u09ac\u09bf\u0995\u09c7\u09b2': [16, true], // bikel
  '\u09b8\u09a8\u09cd\u09a7\u09cd\u09af\u09be': [18, true], // sondhya
  '\u09b8\u09a8\u09cd\u09a7\u09cd\u09af\u09c7': [18, true], // sondhye
  '\u09b0\u09be\u09a4': [21, true], // raat
  'morning': [8, false],
  'noon': [12, true],
  'afternoon': [15, true],
  'evening': [18, true],
  'night': [21, true],
  'dawn': [6, false],
};

// weekday -> 0=Mon..6=Sun
const Map<String, int> _weekdays = {
  'monday': 0, 'mon': 0, 'tuesday': 1, 'tue': 1, 'wednesday': 2, 'wed': 2,
  'thursday': 3, 'thu': 3, 'friday': 4, 'fri': 4, 'saturday': 5, 'sat': 5,
  'sunday': 6, 'sun': 6,
  '\u09b8\u09cb\u09ae\u09ac\u09be\u09b0': 0, // sombar
  '\u09ae\u0999\u09cd\u0997\u09b2\u09ac\u09be\u09b0': 1, // mongolbar
  '\u09ac\u09c1\u09a7\u09ac\u09be\u09b0': 2, // budhbar
  '\u09ac\u09c3\u09b9\u09b8\u09cd\u09aa\u09a4\u09bf\u09ac\u09be\u09b0': 3, // brihoshpotibar
  '\u09b6\u09c1\u0995\u09cd\u09b0\u09ac\u09be\u09b0': 4, // shukrobar
  '\u099c\u09c1\u09ae\u09cd\u09ae\u09be': 4, // jumma
  '\u099c\u09c1\u09ae\u09be': 4, // juma
  '\u09b6\u09a8\u09bf\u09ac\u09be\u09b0': 5, // shonibar
  '\u09b0\u09ac\u09bf\u09ac\u09be\u09b0': 6, // robibar
};

// month-name -> 1..12 (English + common Bangla Gregorian names)
const Map<String, int> _months = {
  'january': 1, 'jan': 1, 'february': 2, 'feb': 2, 'march': 3, 'mar': 3,
  'april': 4, 'apr': 4, 'may': 5, 'june': 6, 'jun': 6, 'july': 7, 'jul': 7,
  'august': 8, 'aug': 8, 'september': 9, 'sep': 9, 'sept': 9,
  'october': 10, 'oct': 10, 'november': 11, 'nov': 11, 'december': 12, 'dec': 12,
  '\u099c\u09be\u09a8\u09c1\u09af\u09bc\u09be\u09b0\u09bf': 1, // january
  '\u09ab\u09c7\u09ac\u09cd\u09b0\u09c1\u09af\u09bc\u09be\u09b0\u09bf': 2, // february
  '\u09ae\u09be\u09b0\u09cd\u099a': 3, // march
  '\u098f\u09aa\u09cd\u09b0\u09bf\u09b2': 4, // april
  '\u09ae\u09c7': 5, // may
  '\u099c\u09c1\u09a8': 6, // june
  '\u099c\u09c1\u09b2\u09be\u0987': 7, // july
  '\u0986\u0997\u09b8\u09cd\u099f': 8, // august
  '\u09b8\u09c7\u09aa\u09cd\u099f\u09c7\u09ae\u09cd\u09ac\u09b0': 9, // september
  '\u0985\u0995\u09cd\u099f\u09cb\u09ac\u09b0': 10, // october
  '\u09a8\u09ad\u09c7\u09ae\u09cd\u09ac\u09b0': 11, // november
  '\u09a1\u09bf\u09b8\u09c7\u09ae\u09cd\u09ac\u09b0': 12, // december
};

String _normalizeDigits(String s) {
  const bn = '\u09e6\u09e7\u09e8\u09e9\u09ea\u09eb\u09ec\u09ed\u09ee\u09ef';
  final b = StringBuffer();
  for (final ch in s.runes) {
    final i = bn.runes.toList().indexOf(ch);
    b.writeCharCode(i >= 0 ? 0x30 + i : ch);
  }
  return b.toString();
}

int _daysInMonth(int y, int m) => DateTime(y, m + 1, 0).day;

DateTime _addMonths(DateTime d, int n) {
  var m = d.month - 1 + n;
  final y = d.year + (m ~/ 12);
  m = m % 12 + 1;
  return DateTime(y, m, d.day > _daysInMonth(y, m) ? _daysInMonth(y, m) : d.day);
}

DateTime _nextWeekday(DateTime from, int weekday, {bool allowToday = false}) {
  var delta = (weekday - (from.weekday - 1)) % 7;
  if (delta < 0) delta += 7;
  if (delta == 0 && !allowToday) delta = 7;
  return DateTime(from.year, from.month, from.day).add(Duration(days: delta));
}

/// Parse a natural-language reminder. `now` defaults to [DateTime.now].
ParsedReminder parseReminder(String text, {DateTime? now}) {
  now = now ?? DateTime.now();
  final norm = _normalizeDigits(text);
  final low = norm.toLowerCase();
  double conf = 0;
  final matched = <String>[];

  // day-part + time
  String? partWord;
  int? partHour;
  bool partPm = false;
  _dayparts.forEach((w, v) {
    if (partWord == null && low.contains(w)) {
      partWord = w;
      partHour = v[0] as int;
      partPm = v[1] as bool;
    }
  });

  final tod = _extractTime(norm, partPm);
  bool dateOnly = true;
  int? hour, minute;
  if (tod != null) {
    hour = tod[0] as int;
    minute = tod[1] as int;
    matched.add(tod[2].toString());
    dateOnly = false;
    conf += 0.35;
  } else if (partHour != null) {
    hour = partHour;
    minute = 0;
    matched.add(partWord!);
    conf += 0.15;
  }
  final todStr = hour != null
      ? '${hour.toString().padLeft(2, '0')}:${minute!.toString().padLeft(2, '0')}'
      : null;

  RecurrenceRule? rec;
  DateTime? baseDate;

  // weekly "proti <weekday>" / "every <weekday>"
  final everyM = RegExp('(?:$_biEvery|every|each)\\s+([^\\s,\u0964]+)').firstMatch(low);
  if (everyM != null) {
    final tok = everyM.group(1)!;
    if (_weekdays.containsKey(tok)) {
      final wd = _weekdays[tok]!;
      rec = RecurrenceRule(freq: 'weekly', weekday: wd, time: todStr);
      baseDate = _nextWeekday(now, wd, allowToday: true);
      matched.add(everyM.group(0)!);
      conf = (conf > 0.6 ? conf : 0.6) + 0.3;
    } else if (tok == _biDay || tok == 'day') {
      rec = RecurrenceRule(freq: 'daily', time: todStr);
      baseDate = now;
      matched.add(everyM.group(0)!);
      conf = (conf > 0.6 ? conf : 0.6) + 0.3;
    }
  }

  // monthly "proti masher N tarikh" / "every month on the Nth"
  if (rec == null) {
    final mM = RegExp(
            '(?:$_biEvery\\s*$_biMonthOf[^0-9]*|every\\s+month(?:\\s+on)?(?:\\s+the)?\\s*)(\\d{1,2})')
        .firstMatch(low);
    if (mM != null) {
      final dom = int.parse(mM.group(1)!);
      rec = RecurrenceRule(freq: 'monthly', dayOfMonth: dom, time: todStr);
      baseDate = _nextDom(now, dom);
      matched.add(mM.group(0)!);
      conf = 0.9;
    }
  }

  // plain freq words
  if (rec == null) {
    if (_biDaily.any(low.contains) || low.contains('daily') || low.contains('everyday')) {
      rec = RecurrenceRule(freq: 'daily', time: todStr);
      baseDate = now;
      conf = conf > 0.75 ? conf : 0.75;
    } else if (low.contains('weekly')) {
      rec = RecurrenceRule(freq: 'weekly', time: todStr);
      baseDate = now;
      conf = conf > 0.75 ? conf : 0.75;
    } else if (low.contains('monthly')) {
      rec = RecurrenceRule(freq: 'monthly', time: todStr);
      baseDate = now;
      conf = conf > 0.75 ? conf : 0.75;
    } else if (low.contains('yearly') || low.contains('annually')) {
      rec = RecurrenceRule(freq: 'yearly', time: todStr);
      baseDate = now;
      conf = conf > 0.75 ? conf : 0.75;
    }
  }

  // one-off relative
  if (baseDate == null) {
    final r = _relativeDate(low, now);
    if (r != null) {
      baseDate = r.$1;
      matched.add(r.$2);
      conf = conf > r.$3 ? conf : r.$3;
    }
  }

  // "agami masher N tarikh" / bare "N tarikh"
  if (baseDate == null) {
    final r = _monthDate(low, now);
    if (r != null) {
      baseDate = r.$1;
      matched.add(r.$2);
      conf = conf > r.$3 ? conf : r.$3;
    }
  }

  // bare weekday one-off
  if (baseDate == null) {
    final r = _bareWeekday(low, now);
    if (r != null) {
      baseDate = r.$1;
      matched.add(r.$2);
      conf = conf > r.$3 ? conf : r.$3;
    }
  }

  // dd/mm[/yy]
  if (baseDate == null) {
    final r = _explicitDate(norm, now);
    if (r != null) {
      baseDate = r.$1;
      matched.add(r.$2);
      conf = conf > r.$3 ? conf : r.$3;
    }
  }

  // time only -> today or tomorrow if already past
  if (baseDate == null && hour != null) {
    final cand = DateTime(now.year, now.month, now.day, hour, minute!);
    baseDate = cand.isAfter(now) ? now : now.add(const Duration(days: 1));
    conf = conf > 0.5 ? conf : 0.5;
  }

  DateTime? result;
  if (baseDate != null) {
    result = DateTime(baseDate.year, baseDate.month, baseDate.day,
        hour ?? _defaultHour, minute ?? 0);
  }

  if (conf > 1) conf = 1;
  return ParsedReminder(
    dateTime: result,
    dateOnly: dateOnly,
    recurrence: rec,
    cleanTitle: _cleanTitle(text, matched),
    confidence: double.parse(conf.toStringAsFixed(2)),
  );
}

List<Object>? _extractTime(String norm, bool partPm) {
  final rx = RegExp(
      r'(\d{1,2})\s*[:.]\s*(\d{2})\s*(am|pm)?'
      r'|(\d{1,2})\s*(am|pm)'
      r'|(\d{1,2})\s*' + _biTa + r'(?:\s*(\d{1,2})\s*' + _biMinute + r')?',
      caseSensitive: false);
  final m = rx.firstMatch(norm);
  if (m == null) return null;
  int? h, mi;
  String ampm = '';
  if (m.group(1) != null) {
    h = int.parse(m.group(1)!);
    mi = int.parse(m.group(2)!);
    ampm = (m.group(3) ?? '').toLowerCase();
  } else if (m.group(4) != null) {
    h = int.parse(m.group(4)!);
    mi = 0;
    ampm = (m.group(5) ?? '').toLowerCase();
  } else if (m.group(6) != null) {
    h = int.parse(m.group(6)!);
    mi = m.group(7) != null ? int.parse(m.group(7)!) : 0;
  }
  if (h == null) return null;
  if (ampm.startsWith('p')) {
    if (h < 12) h = h + 12;
  } else if (ampm.startsWith('a')) {
    if (h == 12) h = 0;
  } else if (partPm && h >= 1 && h <= 11) {
    h = h + 12;
  }
  if (h > 23) h = 23;
  if (mi! > 59) mi = 59;
  return [h, mi, m.group(0) ?? ''];
}

DateTime _nextDom(DateTime from, int dom) {
  dom = dom.clamp(1, 31);
  var y = from.year, m = from.month;
  var d = dom > _daysInMonth(y, m) ? _daysInMonth(y, m) : dom;
  var cand = DateTime(y, m, d);
  if (cand.isBefore(DateTime(from.year, from.month, from.day))) {
    final nm = _addMonths(DateTime(y, m, 1), 1);
    d = dom > _daysInMonth(nm.year, nm.month) ? _daysInMonth(nm.year, nm.month) : dom;
    cand = DateTime(nm.year, nm.month, d);
  }
  return cand;
}

(DateTime, String, double)? _relativeDate(String low, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  for (final w in _biTomorrow) {
    if (low.contains(w)) return (today.add(const Duration(days: 1)), w, 0.85);
  }
  if (low.contains('tomorrow')) {
    return (today.add(const Duration(days: 1)), 'tomorrow', 0.85);
  }
  for (final w in _biToday) {
    if (low.contains(w)) return (today, w, 0.8);
  }
  if (RegExp(r'\btoday\b').hasMatch(low)) return (today, 'today', 0.8);
  if (low.contains(_biDayAfter) || low.contains('day after tomorrow')) {
    return (today.add(const Duration(days: 2)),
        low.contains(_biDayAfter) ? _biDayAfter : 'day after tomorrow', 0.85);
  }
  // N din por / in N days
  var m = RegExp('(\\d{1,3})\\s*$_biDay\\s*(?:${_biAfter.join('|')})').firstMatch(low) ??
      RegExp(r'(?:in|after)\s+(\d{1,3})\s*days?').firstMatch(low);
  if (m != null) {
    return (today.add(Duration(days: int.parse(m.group(1)!))), m.group(0)!, 0.85);
  }
  // in N weeks
  m = RegExp(r'(?:in|after)\s+(\d{1,3})\s*weeks?').firstMatch(low);
  if (m != null) {
    return (today.add(Duration(days: 7 * int.parse(m.group(1)!))), m.group(0)!, 0.85);
  }
  // next week
  if (RegExp('$_biNextWord\\s*\\S*week|next\\s+week').hasMatch(low) ||
      low.contains('next week')) {
    return (today.add(const Duration(days: 7)), 'next week', 0.7);
  }
  return null;
}

(DateTime, String, double)? _monthDate(String low, DateTime now) {
  // agami masher N tarikh
  var m = RegExp('$_biNextWord\\s*$_biMonthOf[^0-9]*(\\d{1,2})\\s*$_biDateWord')
      .firstMatch(low);
  if (m != null) {
    final dom = int.parse(m.group(1)!);
    final nm = _addMonths(DateTime(now.year, now.month, 1), 1);
    final d = dom > _daysInMonth(nm.year, nm.month) ? _daysInMonth(nm.year, nm.month) : dom;
    return (DateTime(nm.year, nm.month, d), m.group(0)!, 0.9);
  }
  m = RegExp(r'next\s+month(?:\s+on)?(?:\s+the)?\s*(\d{1,2})').firstMatch(low);
  if (m != null) {
    final dom = int.parse(m.group(1)!);
    final nm = _addMonths(DateTime(now.year, now.month, 1), 1);
    final d = dom > _daysInMonth(nm.year, nm.month) ? _daysInMonth(nm.year, nm.month) : dom;
    return (DateTime(nm.year, nm.month, d), m.group(0)!, 0.9);
  }
  // this month, day N: "ei/cholti masher N tarikh"
  m = RegExp('(?:${_biThisMonth.join('|')})\\s*$_biMonthOf[^0-9]*(\\d{1,2})\\s*$_biDateWord')
      .firstMatch(low);
  if (m != null) {
    final dom = int.parse(m.group(1)!);
    final d = dom > _daysInMonth(now.year, now.month) ? _daysInMonth(now.year, now.month) : dom;
    return (DateTime(now.year, now.month, d), m.group(0)!, 0.85);
  }
  // "<month name> N" (e.g. "may 5", bengali month + day)
  m = RegExp('([a-z\u0980-\u09ff]+)\\s+(\\d{1,2})(?:\\s*$_biDateWord)?').firstMatch(low);
  if (m != null && _months.containsKey(m.group(1))) {
    final mo = _months[m.group(1)]!;
    final dom = int.parse(m.group(2)!);
    final y = now.year +
        ((mo < now.month || (mo == now.month && dom < now.day)) ? 1 : 0);
    final d = dom > _daysInMonth(y, mo) ? _daysInMonth(y, mo) : dom;
    return (DateTime(y, mo, d), m.group(0)!, 0.85);
  }
  // "N <month name>" (e.g. "25 december", "N tarikh december")
  m = RegExp('(\\d{1,2})\\s*(?:$_biDateWord\\s*)?([a-z\u0980-\u09ff]+)').firstMatch(low);
  if (m != null && _months.containsKey(m.group(2))) {
    final mo = _months[m.group(2)]!;
    final dom = int.parse(m.group(1)!);
    final y = now.year +
        ((mo < now.month || (mo == now.month && dom < now.day)) ? 1 : 0);
    final d = dom > _daysInMonth(y, mo) ? _daysInMonth(y, mo) : dom;
    return (DateTime(y, mo, d), m.group(0)!, 0.85);
  }
  // bare "N tarikh" (optional trailing "e" vowel sign U+09C7 -> "tarikhe"),
  // matching the Python regex (\d{1,2})\s*<tarikh>(?:<e>)? so the whole date
  // phrase is stripped from the title (no dangling connector left).
  m = RegExp('(\\d{1,2})\\s*$_biDateWord(?:\u09c7)?').firstMatch(low);
  if (m != null) {
    return (_nextDom(now, int.parse(m.group(1)!)), m.group(0)!, 0.7);
  }
  return null;
}

(DateTime, String, double)? _bareWeekday(String low, DateTime now) {
  for (final entry in _weekdays.entries) {
    final tok = entry.key;
    final isAscii = tok.codeUnits.every((c) => c < 128);
    if (isAscii) {
      if (!RegExp('\\b${RegExp.escape(tok)}\\b').hasMatch(low)) continue;
    } else if (!low.contains(tok)) {
      continue;
    }
    if (RegExp('(?:$_biEvery|every|each)\\s+${RegExp.escape(tok)}').hasMatch(low)) {
      return null;
    }
    return (_nextWeekday(now, entry.value), tok, 0.65);
  }
  return null;
}

(DateTime, String, double)? _explicitDate(String norm, DateTime now) {
  final m = RegExp(r'(?<!\d)(\d{1,2})[/\-.](\d{1,2})(?:[/\-.](\d{2,4}))?(?!\d)')
      .firstMatch(norm);
  if (m == null) return null;
  final d = int.parse(m.group(1)!);
  final mo = int.parse(m.group(2)!);
  var y = m.group(3) != null ? int.parse(m.group(3)!) : now.year;
  if (m.group(3) != null && y < 100) y += 2000;
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  final day = d > _daysInMonth(y, mo) ? _daysInMonth(y, mo) : d;
  var cand = DateTime(y, mo, day);
  if (m.group(3) == null && cand.isBefore(DateTime(now.year, now.month, now.day))) {
    cand = DateTime(y + 1, mo, day);
  }
  return (cand, m.group(0)!, 0.8);
}

const _fillers = [
  'remind me to', 'remind me', 'reminder to', 'set a reminder to',
  'set reminder', 'please',
];

String _cleanTitle(String raw, List<String> matched) {
  var out = _normalizeDigits(raw);
  final sorted = matched.where((m) => m.isNotEmpty).toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final p in sorted) {
    final idx = out.toLowerCase().indexOf(p.toLowerCase());
    if (idx >= 0) out = out.substring(0, idx) + out.substring(idx + p.length);
  }
  for (final f in _fillers) {
    out = out.replaceAll(RegExp(RegExp.escape(f), caseSensitive: false), '');
  }
  out = out.replaceAll(RegExp(r'\s+'), ' ').trim();
  out = out.replaceAll(RegExp(r'^[,\-:;\u0964]+|[,\-:;\u0964]+$'), '').trim();
  // drop dangling connectors left where a date/time phrase was removed:
  //   "pay bill on 25/12" -> "pay bill on" -> "pay bill"
  //   "call mom at 5pm"   -> "call mom at" -> "call mom"
  //   Bangla connectors (longest-first): tarikhe, tarikh, te, e (\u-escaped).
  const enConn = r'(?:at|on|by|to)';
  // tarikhe | tarikh | te | e
  const bnConn =
      '(?:\u09a4\u09be\u09b0\u09bf\u0996\u09c7|\u09a4\u09be\u09b0\u09bf\u0996|\u09a4\u09c7|\u098f)';
  const punct = '^[,\\-:;\u0964]+|[,\\-:;\u0964]+\$';
  String prev = '';
  while (prev != out) {
    prev = out;
    out = out.replaceAll(RegExp('\\s+$enConn\$', caseSensitive: false), '');
    out = out.replaceAll(RegExp('^$enConn\\s+', caseSensitive: false), '');
    out = out.replaceAll(RegExp('^$bnConn\\s+'), '');
    out = out.replaceAll(RegExp('\\s+$bnConn\$'), '');
    out = out.replaceAll(RegExp(punct), '').trim();
  }
  return out.isEmpty ? _normalizeDigits(raw).trim() : out;
}

// ---- recurrence next-occurrence (mirror of reminders_engine.next_occurrence) --
DateTime? nextOccurrence(DateTime? anchor, RecurrenceRule? rule, {DateTime? after}) {
  after = after ?? DateTime.now();
  if (anchor == null) return null;
  if (rule == null) return anchor.isAfter(after) ? anchor : null;
  final interval = rule.interval < 1 ? 1 : rule.interval;
  final h = rule.time != null ? int.parse(rule.time!.split(':')[0]) : anchor.hour;
  final mi = rule.time != null ? int.parse(rule.time!.split(':')[1]) : anchor.minute;
  switch (rule.freq) {
    case 'daily':
      var d = anchor.isAfter(after) ? anchor : after;
      var cand = DateTime(d.year, d.month, d.day, h, mi);
      while (!cand.isAfter(after)) {
        cand = cand.add(Duration(days: interval));
      }
      return cand;
    case 'weekly':
      final wd = rule.weekday ?? (anchor.weekday - 1);
      var d = _nextWeekday(after, wd, allowToday: true);
      var cand = DateTime(d.year, d.month, d.day, h, mi);
      while (!cand.isAfter(after)) {
        cand = cand.add(Duration(days: 7 * interval));
      }
      return cand;
    case 'monthly':
      final dom = rule.dayOfMonth ?? anchor.day;
      final base = DateTime(after.year, after.month, 1);
      for (var step = 0; step < 48; step++) {
        final m = _addMonths(base, step);
        final day = dom > _daysInMonth(m.year, m.month) ? _daysInMonth(m.year, m.month) : dom;
        final cand = DateTime(m.year, m.month, day, h, mi);
        if (cand.isAfter(after)) {
          // respect interval: only every `interval` months from the anchor
          if (interval > 1) {
            final monthsFromAnchor =
                (m.year - anchor.year) * 12 + (m.month - anchor.month);
            if (monthsFromAnchor % interval != 0) continue;
          }
          return cand;
        }
      }
      return null;
    case 'yearly':
      final mo = rule.month ?? anchor.month;
      final dom = rule.dayOfMonth ?? anchor.day;
      for (var y = after.year; y < after.year + 20; y++) {
        final day = dom > _daysInMonth(y, mo) ? _daysInMonth(y, mo) : dom;
        final cand = DateTime(y, mo, day, h, mi);
        if (cand.isAfter(after)) {
          if (interval > 1 && (y - anchor.year) % interval != 0) continue;
          return cand;
        }
      }
      return null;
    default:
      return anchor.isAfter(after) ? anchor : null;
  }
}

/// Resolve a natural-language snooze request. Mirror of
/// reminders_engine.snooze. Returns null if nothing parseable.
DateTime? snoozeReminder(DateTime? currentDue, String text, {DateTime? now}) {
  now = now ?? DateTime.now();
  final low = _normalizeDigits(text).toLowerCase().trim();
  // day-after-tomorrow ("porshu") -> +2 days at the requested daypart (default 9)
  if (low.contains(_biDayAfter) || low.contains('day after tomorrow')) {
    final d = now.add(const Duration(days: 2));
    return DateTime(d.year, d.month, d.day, _partHour(low, _defaultHour), 0);
  }
  if (_biTomorrow.any(low.contains) || low.contains('tomorrow')) {
    final d = now.add(const Duration(days: 1));
    return DateTime(d.year, d.month, d.day, _partHour(low, 8), 0);
  }
  if (low.contains('tonight')) {
    return DateTime(now.year, now.month, now.day, 21, 0);
  }
  if (low.contains('next week') ||
      RegExp('$_biNextWord\\s*\\S*week').hasMatch(low)) {
    final d = now.add(const Duration(days: 7));
    return DateTime(d.year, d.month, d.day, _partHour(low, 9), 0);
  }
  var m = RegExp('(\\d+)\\s*(?:min|minute|$_biMinute)').firstMatch(low);
  if (m != null) return now.add(Duration(minutes: int.parse(m.group(1)!)));
  m = RegExp('(\\d+)\\s*(?:hour|hr|${_biHour.join('|')})').firstMatch(low);
  if (m != null) return now.add(Duration(hours: int.parse(m.group(1)!)));
  m = RegExp('(\\d+)\\s*(?:day|$_biDay)').firstMatch(low);
  if (m != null) return now.add(Duration(days: int.parse(m.group(1)!)));
  if (_biHalf.any(low.contains) && _biHour.any(low.contains)) {
    return now.add(const Duration(minutes: 30));
  }
  final ph = _partHourOrNull(low);
  if (ph != null) {
    var cand = DateTime(now.year, now.month, now.day, ph, 0);
    if (!cand.isAfter(now)) cand = cand.add(const Duration(days: 1));
    return cand;
  }
  return null;
}

int _partHour(String low, int fallback) => _partHourOrNull(low) ?? fallback;

int? _partHourOrNull(String low) {
  if (low.contains('morning') || low.contains('\u09b8\u0995\u09be\u09b2')) return 8;
  if (low.contains('noon') || low.contains('\u09a6\u09c1\u09aa\u09c1\u09b0')) return 13;
  if (low.contains('afternoon') ||
      low.contains('\u09ac\u09bf\u0995\u09be\u09b2') ||
      low.contains('\u09ac\u09bf\u0995\u09c7\u09b2')) {
    return 16;
  }
  if (low.contains('evening') || low.contains('\u09b8\u09a8\u09cd\u09a7\u09cd\u09af\u09be')) {
    return 18;
  }
  if (low.contains('night') || low.contains('\u09b0\u09be\u09a4')) return 21;
  return null;
}
