// Client-side natural-language date/time/recurrence parser for the reminders
// quick-add box. A faithful mirror of backend/core/logic/nlp_datetime.py so the
// user gets an INSTANT, offline preview of what Assisto understood before they
// confirm. The backend endpoint (POST /reminders/parse) remains the source of
// truth for AI-captured reminders; this is purely for responsive local preview.
// Parity is locked by test/reminders_golden_test.dart (shared golden JSON).
//
// Rules mirrored from the Python module docstring:
//  * Missing time: a date with no clock gets 09:00. For a one-off that resolves
//    to TODAY with no clock and no day-part, once 09:00 has passed we use the
//    next full hour; at/after 23:00 we use 23:59 and set needsTime (ask).
//  * Bare "kal" (yesterday OR tomorrow) is YESTERDAY in a past-tense sentence
//    (korechi / gelam / kinlam ...) with no future/imperative marker, else
//    TOMORROW. gotokal/yesterday always -1, agamikal/tomorrow always +1;
//    porshu + past = -2. "kal" is only matched as a standalone word.
//  * Time words: sare N (N:30), shoa N (N:15), poune N ((N-1):45), der-Ta
//    (13:30), arai-Ta (14:30; 01:30/02:30 with raat/bhor), Bangla number words.
//  * "masher sheshe" / end of month = last day of this month.
//  * preferPast (expense mode, see [expenseDate]): ambiguous day words resolve
//    backwards and the date is never later than today.
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
  final bool isPast; // phrase talks about the past (past tense / date < today)
  final bool needsTime; // "today" with no clock, too late for a slot -> ask
  const ParsedReminder({
    this.dateTime,
    this.dateOnly = true,
    this.recurrence,
    this.cleanTitle = '',
    this.confidence = 0,
    this.isPast = false,
    this.needsTime = false,
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

// Default clock for a date with no time (see the missing-time rule above).
const _defaultHour = 9;

// ---- Bangla keyword constants (escaped so no Bangla literals in source) ----
const _biTomorrow = ['\u0986\u0997\u09be\u09ae\u09c0\u0995\u09be\u09b2',
  '\u0986\u0997\u09be\u09ae\u09bf\u0995\u09be\u09b2', '\u0995\u09be\u09b2\u0995\u09c7',
  '\u0995\u09be\u09b2']; // agamikal, kalke, kal
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

// Bangla block for standalone-word look-arounds.
const _bnCls = '[\u0980-\u09ff]';
const _nb = '(?<!$_bnCls)';
const _na = '(?!$_bnCls)';

/// Fold decomposed nukta letters (ya/da/dha + nukta) to precomposed forms.
String _fold(String s) => s
    .replaceAll('\u09af\u09bc', '\u09df')
    .replaceAll('\u09a1\u09bc', '\u09dc')
    .replaceAll('\u09a2\u09bc', '\u09dd');

/// Regex for a Bangla word matching both nukta spellings.
String _nk(String word) {
  var out = RegExp.escape(_fold(word));
  for (final pd in const [
    ['\u09df', '\u09af\u09bc'],
    ['\u09dc', '\u09a1\u09bc'],
    ['\u09dd', '\u09a2\u09bc'],
  ]) {
    out = out.replaceAll(pd[0], '(?:${pd[0]}|${pd[1]})');
  }
  return out;
}

// Bangla number words 1..31 (mirror of _BN_NUMBER_WORDS).
const Map<String, int> _bnNumberWords = {
  '\u098f\u0995': 1, '\u09a6\u09c1\u0987': 2, '\u09a6\u09c1': 2, '\u09a4\u09bf\u09a8': 3, '\u099a\u09be\u09b0': 4, '\u09aa\u09be\u0981\u099a': 5, '\u099b\u09af\u09bc': 6,
  '\u099b': 6, '\u09b8\u09be\u09a4': 7, '\u0986\u099f': 8, '\u09a8\u09af\u09bc': 9, '\u09a6\u09b6': 10, '\u098f\u0997\u09be\u09b0\u09cb': 11, '\u098f\u0997\u09be\u09b0': 11,
  '\u09ac\u09be\u09b0\u09cb': 12, '\u09ac\u09be\u09b0': 12, '\u09a4\u09c7\u09b0\u09cb': 13, '\u09a4\u09c7\u09b0': 13, '\u099a\u09cb\u09a6\u09cd\u09a6': 14, '\u099a\u09cc\u09a6\u09cd\u09a6': 14,
  '\u09aa\u09a8\u09c7\u09b0\u09cb': 15, '\u09aa\u09a8\u09c7\u09b0': 15, '\u09b7\u09cb\u09b2\u09cb': 16, '\u09b7\u09cb\u09b2': 16, '\u09b8\u09a4\u09c7\u09b0\u09cb': 17, '\u09b8\u09a4\u09c7\u09b0': 17,
  '\u0986\u09a0\u09be\u09b0\u09cb': 18, '\u0986\u09a0\u09be\u09b0': 18, '\u0989\u09a8\u09bf\u09b6': 19, '\u09ac\u09bf\u09b6': 20, '\u0995\u09c1\u09a1\u09bc\u09bf': 20, '\u098f\u0995\u09c1\u09b6': 21,
  '\u09ac\u09be\u0987\u09b6': 22, '\u09a4\u09c7\u0987\u09b6': 23, '\u099a\u09ac\u09cd\u09ac\u09bf\u09b6': 24, '\u09aa\u0981\u099a\u09bf\u09b6': 25, '\u099b\u09be\u09ac\u09cd\u09ac\u09bf\u09b6': 26, '\u09b8\u09be\u09a4\u09be\u09b6': 27,
  '\u0986\u09a0\u09be\u09b6': 28, '\u0989\u09a8\u09a4\u09cd\u09b0\u09bf\u09b6': 29, '\u09a4\u09cd\u09b0\u09bf\u09b6': 30, '\u098f\u0995\u09a4\u09cd\u09b0\u09bf\u09b6': 31,
};

final String _numAlt = (() {
  final ws = _bnNumberWords.keys.map(_fold).toSet().toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  return ws.map(_nk).join('|');
})();

int? _numValue(String tok) {
  final d = int.tryParse(tok);
  if (d != null) return d;
  final f = _fold(tok);
  for (final e in _bnNumberWords.entries) {
    if (_fold(e.key) == f) return e.value;
  }
  return null;
}

final String _tay = _nk('\u099f\u09be\u09af\u09bc');
const _unitAfterNum = '(?:\u09a4\u09be\u09b0\u09bf\u0996|\u09a6\u09bf\u09a8|\u09b8\u09aa\u09cd\u09a4\u09be\u09b9|\u09ae\u09be\u09b8|\u0998\u09a3\u09cd\u099f\u09be|\u0998\u09a8\u09cd\u099f\u09be|\u09ae\u09bf\u09a8\u09bf\u099f)';
const _daypartAlt = '\u09b8\u0995\u09be\u09b2|\u09ad\u09cb\u09b0|\u09a6\u09c1\u09aa\u09c1\u09b0|\u09ac\u09bf\u0995\u09be\u09b2|\u09ac\u09bf\u0995\u09c7\u09b2|\u09b8\u09a8\u09cd\u09a7\u09cd\u09af\u09be|\u09b8\u09a8\u09cd\u09a7\u09cd\u09af\u09c7|\u09b0\u09be\u09a4';

final RegExp _halfRx = RegExp(
    '$_nb(${_nk('\u09b8\u09be\u09a1\u09bc\u09c7')}|${_nk('\u09b8\u09cb\u09af\u09bc\u09be')}|\u09aa\u09cc\u09a8\u09c7)\\s*(\\d{1,2}|$_numAlt)'
    '\\s*(?:$_tay|$_biTa(?:\\s*\u09ac\u09be\u099c\u09c7)?|\u09ac\u09be\u099c\u09c7)$_na');
final RegExp _derRx =
    RegExp('$_nb(${_nk('\u09a6\u09c7\u09a1\u09bc')}|${_nk('\u0986\u09a1\u09bc\u09be\u0987')})\\s*(?:$_tay|$_biTa)$_na');
final RegExp _numUnitRx = RegExp('$_nb($_numAlt)\\s*($_unitAfterNum)');
final RegExp _numTayRx = RegExp('$_nb($_numAlt)\\s*($_tay|$_biTa\\s*\u09ac\u09be\u099c\u09c7)');
final RegExp _numPartTaRx =
    RegExp('((?:$_daypartAlt)(?:\u09c7|\u09b0)?\\s+)($_numAlt)\\s*$_biTa');

/// Mirror of nlp_datetime._preprocess: Bangla time phrases / number words to
/// digit forms (only in clearly date/time contexts).
String _preprocess(String norm) {
  var out = norm.replaceAllMapped(_halfRx, (m) {
    final word = _fold(m.group(1)!);
    final n = _numValue(m.group(2)!);
    if (n == null || n == 0 || n > 12) return m.group(0)!;
    int h, mi;
    if (word.startsWith('\u09aa')) {
      h = (n - 1) == 0 ? 12 : n - 1;
      mi = 45;
    } else if (word.startsWith('\u09b8\u09cb')) {
      h = n;
      mi = 15;
    } else {
      h = n;
      mi = 30;
    }
    return '$h:${mi.toString().padLeft(2, '0')}';
  });
  final late = RegExp('\u09b0\u09be\u09a4|\u09ad\u09cb\u09b0|night').hasMatch(out);
  out = out.replaceAllMapped(_derRx, (m) {
    final der = m.group(1)!.startsWith('\u09a6');
    return der ? (late ? '1:30' : '13:30') : (late ? '2:30' : '14:30');
  });
  out = out.replaceAllMapped(
      _numUnitRx, (m) => '${_numValue(m.group(1)!)} ${m.group(2)}');
  out = out.replaceAllMapped(
      _numTayRx, (m) => '${_numValue(m.group(1)!)}${m.group(2)}');
  out = out.replaceAllMapped(
      _numPartTaRx, (m) => '${m.group(1)}${_numValue(m.group(2)!)}$_biTa');
  return out;
}

// ---- tense (mirror of is_past_tense / has_future_marker) ----
final RegExp _pastTokenRx = RegExp(
    '(?:\u09c7\u099b\u09bf(?:\u09b2\u09be\u09ae|\u09b2\u09c7|\u09b2\u09c7\u09a8|\u09b2|\u09b2\u09cb|\u09b8)?|\u09c7\u099b\u09c7(?:\u09a8)?|\u09b2\u09be\u09ae|\u099b\u09bf\u09b2|\u099b\u09bf\u09b2\u09cb|\u099b\u09bf\u09b2\u09be\u09ae|\u099b\u09bf\u09b2\u09c7\u09a8|\u099b\u09bf\u09b2\u09c7)\$');
final RegExp _pastStemRx = RegExp(
    '^(?:\u0995\u09b0|\u0997\u09c7|\u09a6\u09bf|\u09a8\u09bf|\u0996\u09c7|\u098f|\u0995\u09bf\u09a8|\u09aa\u09c7|\u09b9|\u09ac\u09b2|\u09a6\u09c7\u0996|\u09aa\u09be\u09a0\u09be|\u09ab\u09c7\u09b2|\u0986\u09b8|\u09ad\u09b0|\u09a4\u09c1|\u09b0\u09be\u0996|\u0995\u09be\u099f|\u09b6\u09c1\u09a8|${_nk('\u09aa\u09a1\u09bc')}|'
    '\u0998\u09c1\u09b0|\u099a\u09b2|\u09ab\u09bf\u09b0|\u0989\u09a0|\u0998\u09c1\u09ae\u09be|\u09ac\u09b8\u09be|${_nk('\u099b\u09be\u09a1\u09bc')}|\u09b9\u09be\u09b0\u09be|\u09aa\u09be\u09a0\u09bf)(?:\u09b2|\u09b2\u09cb|\u09b2\u09c7\u09a8|\u09b2\u09bf)\$');
final Set<String> _pastTokensExtra = {
  '\u09a6\u09bf\u099b\u09bf', '\u09a8\u09bf\u099b\u09bf', '\u0996\u09be\u0987\u099b\u09bf', '\u0997\u09c7\u099b\u09bf', '\u09aa\u09be\u0987\u099b\u09bf', '\u0986\u0987\u099b\u09bf', '\u0995\u09b0\u099b\u09bf\u09b2\u09be\u09ae', '\u09b9\u0987\u099b\u09c7', '\u0997\u09c7\u099b\u09bf\u09b2\u09be\u09ae',
}.map(_fold).toSet();
final Set<String> _pastExclude = {
  '\u09b8\u09be\u09b2\u09be\u09ae', '\u0987\u09b8\u09b2\u09be\u09ae', '\u0995\u09be\u09b2\u09be\u09ae', '\u0997\u09cb\u09b2\u09be\u09ae', '\u09ac\u09c7\u099b\u09c7', '\u0986\u099b\u09bf', '\u0986\u099b\u09c7', '\u0986\u099b\u09c7\u09a8', '\u09b8\u0995\u09be\u09b2',
  '\u09ac\u09bf\u0995\u09be\u09b2', '\u0995\u09be\u09b2',
}.map(_fold).toSet();
final RegExp _pastEnRx = RegExp(
    r'^[a-z]+(?:echi|esi|eche|echilam|esilam|chilam|silam|chilo|silo|chilen|lam)$');
const Set<String> _pastEnExtra = {
  'korsi', 'khaisi', 'disi', 'nisi', 'gesi', 'gelo', 'korlo', 'dilo', 'khelo',
  'kinlo', 'pelo', 'holo', 'korse', 'gese', 'khaise', 'hoise', 'spent', 'paid',
  'bought', 'went', 'was', 'did', 'yesterday',
};
const Set<String> _pastEnExclude = {'salam', 'islam', 'kalam', 'golam'};
const List<String> _futurePhrases = [
  '\u09ae\u09a8\u09c7 \u0995\u09b0\u09bf\u09af\u09bc\u09c7', '\u09ae\u09a8\u09c7 \u0995\u09b0\u09be\u0993', '\u09ae\u09a8\u09c7 \u0995\u09b0\u09be\u09ac\u09c7', '\u09b0\u09bf\u09ae\u09be\u0987\u09a8\u09cd\u09a1', 'remind', 'will ', 'going to',
];
final Set<String> _futureTokens = {
  '\u09a6\u09bf\u0993', '\u09a6\u09be\u0993', '\u09a6\u09bf\u09af\u09bc\u09cb', '\u09a6\u09bf\u09ac\u09c7\u09a8', '\u09a6\u09c7\u09ac\u09c7\u09a8', '\u0995\u09b0\u09cb', '\u0995\u09b0\u09c1\u09a8', '\u0995\u09cb\u09b0\u09cb', '\u09af\u09c7\u0993', '\u098f\u09b8\u09cb',
  '\u0986\u09b8\u09cb', '\u09a8\u09bf\u0993', '\u0996\u09c7\u0993', '\u0995\u09b0\u09ac', '\u0995\u09b0\u09ac\u09cb', '\u09af\u09be\u09ac', '\u09af\u09be\u09ac\u09cb', '\u09a6\u09c7\u09ac', '\u09a6\u09c7\u09ac\u09cb', '\u09a6\u09bf\u09ac', '\u09a6\u09bf\u09ac\u09cb',
  '\u0996\u09be\u09ac', '\u0996\u09be\u09ac\u09cb', '\u0995\u09bf\u09a8\u09ac', '\u0995\u09bf\u09a8\u09ac\u09cb', '\u09a8\u09c7\u09ac', '\u09a8\u09c7\u09ac\u09cb', '\u09a8\u09bf\u09ac', '\u09aa\u09be\u09ac', '\u0986\u09b8\u09ac', '\u0986\u09b8\u09ac\u09cb',
  '\u09ab\u09bf\u09b0\u09ac', '\u09a6\u09c7\u0996\u09ac', '\u09ac\u09b2\u09ac', '\u09aa\u09be\u09a0\u09be\u09ac', '\u09b9\u09ac\u09c7', '\u09af\u09be\u09ac\u09c7', '\u0995\u09b0\u09ac\u09c7', '\u0986\u09b8\u09ac\u09c7', '\u09a6\u09c7\u09ac\u09c7', '\u09a6\u09bf\u09ac\u09c7',
  '\u09a5\u09be\u0995\u09ac\u09c7', '\u09a5\u09be\u0995\u09ac', '\u09b6\u09c1\u09b0\u09c1', 'korbo', 'jabo', 'dibo', 'debo', 'khabo', 'kinbo',
  'nibo', 'asbo', 'hobe', 'jabe', 'korbe', 'dio', 'dao', 'koro',
}.map(_fold).toSet();

List<String> _tokens(String low) => low
    .split(RegExp('[\\s,\u0964!?.;:\\-]+'))
    .where((t) => t.isNotEmpty)
    .toList();

/// True when the phrase carries a future / imperative marker (reminder style).
bool hasFutureMarker(String text) {
  final low = _fold(_normalizeDigits(text).toLowerCase());
  if (_futurePhrases.any((p) => low.contains(_fold(p)))) return true;
  return _tokens(low).any(_futureTokens.contains);
}

/// True when the sentence uses a past-tense verb (Bangla or Banglish) and has
/// no future / imperative marker. Mirror of nlp_datetime.is_past_tense.
bool isPastTense(String text) {
  final low = _fold(_normalizeDigits(text).toLowerCase());
  if (hasFutureMarker(low)) return false;
  for (final t in _tokens(low)) {
    if (_pastExclude.contains(t) || _pastEnExclude.contains(t)) continue;
    if (_pastTokensExtra.contains(t) || _pastEnExtra.contains(t)) return true;
    if (_pastTokenRx.hasMatch(t) || _pastStemRx.hasMatch(t)) return true;
    final ascii = t.codeUnits.every((c) => c < 128);
    if (ascii && _pastEnRx.hasMatch(t)) return true;
  }
  return false;
}

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
  // Banglish (parity with agent/aieval nlp_datetime: "kal sokal 8tay")
  'sokal': [8, false], 'sokale': [8, false], 'bhor': [6, false],
  'dupur': [13, true], 'dupure': [13, true], 'bikel': [16, true],
  'bikale': [16, true], 'bikele': [16, true], 'bikal': [16, true],
  'sondha': [18, true], 'shondha': [18, true], 'sondhay': [18, true],
  'sondhar': [18, true], 'raat': [21, true], 'rat': [21, true],
  'raate': [21, true],
};

// Banglish day-parts match as whole words only ("rat" never in "karate").
const Set<String> _blParts = {
  'sokal', 'sokale', 'bhor', 'dupur', 'dupure', 'bikel', 'bikale', 'bikele',
  'bikal', 'sondha', 'shondha', 'sondhay', 'sondhar', 'raat', 'rat', 'raate',
};
const Set<String> _nightParts = {'\u09b0\u09be\u09a4', 'night', 'raat', 'rat', 'raate'};
const Set<String> _morningParts = {
  '\u09b8\u0995\u09be\u09b2', '\u09ad\u09cb\u09b0', 'morning', 'dawn', 'sokal', 'sokale', 'bhor',
};
// Banglish clock: "8tay" / "8 tae" / "8tar" always; a bare "8ta" only next to
// a Banglish day-part ("sokal 8ta") -- "2ta dim" is a count, not a time.
final RegExp _blTimeRx =
    RegExp(r'(?<!\d)(\d{1,2})\s*(?:tay|tae|tai|tar)\b', caseSensitive: false);
final RegExp _blTimeTaRx = RegExp(r'(?<!\d)(\d{1,2})\s*ta\b', caseSensitive: false);

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
  final y = d.year + (m / 12).floor(); // floor (negative n = months back)
  m = m % 12 + 1;
  return DateTime(y, m, d.day > _daysInMonth(y, m) ? _daysInMonth(y, m) : d.day);
}

DateTime _nextWeekday(DateTime from, int weekday, {bool allowToday = false}) {
  var delta = (weekday - (from.weekday - 1)) % 7;
  if (delta < 0) delta += 7;
  if (delta == 0 && !allowToday) delta = 7;
  return DateTime(from.year, from.month, from.day).add(Duration(days: delta));
}


DateTime _monthEnd(DateTime d) => DateTime(d.year, d.month, _daysInMonth(d.year, d.month));

const _monthEndEveryRx = '(?:\u09aa\u09cd\u09b0\u09a4\u09bf\\s*\u09ae\u09be\u09b8\u09c7\u09b0?\\s*\u09b6\u09c7\u09b7(?:\u09c7|\\s*\u09a6\u09bf\u09a8(?:\u09c7)?)?'
    '|every\\s+month\\s*end|(?:at\\s+the\\s+)?end\\s+of\\s+every\\s+month)';
const _monthEndRx = '(?:(?:\u098f\u0987\\s*)?\u09ae\u09be\u09b8\u09c7\u09b0?\\s*\u09b6\u09c7\u09b7(?:\u09c7|\\s*\u09a6\u09bf\u09a8(?:\u09c7)?)?'
    '|(?:at\\s+the\\s+)?end\\s+of\\s+(?:the\\s+|this\\s+)?month|month[\\s-]end)';

bool _monthEndHit(List<String> matched) => matched.any(
    (m) => m.isNotEmpty && RegExp('^$_monthEndRx\$').hasMatch(m.toLowerCase()));

/// Parse a natural-language reminder. `now` defaults to [DateTime.now].
/// `preferPast` is the expense/money-log mode (see [expenseDate]).
ParsedReminder parseReminder(String text, {DateTime? now, bool preferPast = false}) {
  now = now ?? DateTime.now();
  final norm = _preprocess(_normalizeDigits(text));
  final low = norm.toLowerCase();
  double conf = 0;
  final matched = <String>[];
  final future = hasFutureMarker(low);
  final past = isPastTense(low) || (preferPast && !future);

  // day-part + time
  String? partWord;
  int? partHour;
  bool partPm = false;
  _dayparts.forEach((w, v) {
    final hit = _blParts.contains(w)
        ? RegExp('(?<![a-z])${RegExp.escape(w)}(?![a-z])').hasMatch(low)
        : low.contains(w);
    if (partWord == null && hit) {
      partWord = w;
      partHour = v[0] as int;
      partPm = v[1] as bool;
    }
  });
  String? dpSpan;
  if (partWord != null) {
    final dm = RegExp('${RegExp.escape(partWord!)}(?:\u09c7\u09b0|\u09c7|\u09b0)?').firstMatch(low);
    dpSpan = dm?.group(0) ?? partWord;
  }

  final night = _nightParts.contains(partWord);
  final tod = _extractTime(norm, partPm, night, partWord);
  bool dateOnly = true;
  int? hour, minute;
  if (tod != null) {
    hour = tod[0] as int;
    minute = tod[1] as int;
    matched.add(tod[2].toString().trim());
    if (dpSpan != null) matched.add(dpSpan);
    dateOnly = false;
    conf += 0.35;
  } else if (partHour != null) {
    hour = partHour;
    minute = 0;
    matched.add(dpSpan!);
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

  // monthly at month end: "proti masher sheshe" / "every month end"
  if (rec == null) {
    final me = RegExp(_monthEndEveryRx).firstMatch(low);
    if (me != null) {
      rec = RecurrenceRule(freq: 'monthly', dayOfMonth: 31, time: todStr);
      baseDate = _monthEnd(now);
      matched.add(me.group(0)!);
      conf = 0.9;
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
    final r = _relativeDate(low, now, past);
    if (r != null) {
      baseDate = r.$1;
      matched.add(r.$2);
      conf = conf > r.$3 ? conf : r.$3;
    }
  }

  // "agami masher N tarikh" / bare "N tarikh"
  if (baseDate == null) {
    final r = _monthDate(low, now, past);
    if (r != null) {
      baseDate = r.$1;
      matched.add(r.$2);
      conf = conf > r.$3 ? conf : r.$3;
    }
  }

  // bare weekday one-off
  if (baseDate == null) {
    final r = _bareWeekday(low, now, past);
    if (r != null) {
      baseDate = r.$1;
      matched.add(r.$2);
      conf = conf > r.$3 ? conf : r.$3;
    }
  }

  // dd/mm[/yy]
  if (baseDate == null) {
    final r = _explicitDate(norm, now, past);
    if (r != null) {
      baseDate = r.$1;
      matched.add(r.$2);
      conf = conf > r.$3 ? conf : r.$3;
    }
  }

  // time only -> today or tomorrow if already past (past tense: today, or
  // yesterday when that time is still ahead)
  if (baseDate == null && hour != null) {
    final cand = DateTime(now.year, now.month, now.day, hour, minute!);
    if (past) {
      baseDate = cand.isAfter(now) ? now.subtract(const Duration(days: 1)) : now;
    } else {
      baseDate = cand.isAfter(now) ? now : now.add(const Duration(days: 1));
    }
    conf = conf > 0.5 ? conf : 0.5;
  }

  DateTime? result;
  bool needsTime = false;
  if (baseDate != null) {
    var dt = DateTime(baseDate.year, baseDate.month, baseDate.day,
        hour ?? _defaultHour, minute ?? 0);
    final monthEnd = _monthEndHit(matched) && rec == null && !past;
    if (monthEnd && !dt.isAfter(now) && (hour != null || now.hour >= 23)) {
      final nxt = _monthEnd(_addMonths(DateTime(now.year, now.month, 1), 1));
      dt = DateTime(nxt.year, nxt.month, nxt.day, hour ?? _defaultHour, minute ?? 0);
    }
    // Missing-time rule: "today" with no clock and no day-part never lands on
    // a moment that already passed.
    final sameDay =
        dt.year == now.year && dt.month == now.month && dt.day == now.day;
    if (hour == null && rec == null && !past && sameDay && !dt.isAfter(now)) {
      if (now.hour + 1 <= 23) {
        dt = DateTime(now.year, now.month, now.day, now.hour + 1);
      } else {
        dt = DateTime(now.year, now.month, now.day, 23, 59);
        needsTime = true;
      }
    }
    result = dt;
  }

  final today = DateTime(now.year, now.month, now.day);
  final resDay =
      result == null ? null : DateTime(result.year, result.month, result.day);
  final isPast = (past && (resDay == null || !resDay.isAfter(today))) ||
      (resDay != null && resDay.isBefore(today));

  if (conf > 1) conf = 1;
  return ParsedReminder(
    dateTime: result,
    dateOnly: dateOnly,
    recurrence: rec,
    cleanTitle: _cleanTitle(text, matched, pre: norm),
    confidence: double.parse(conf.toStringAsFixed(2)),
    isPast: isPast,
    needsTime: needsTime,
  );
}

/// Date an expense / income log refers to (money voice + chat expense).
/// Past-biased: bare "kal" = yesterday, "porshu" = 2 days ago, a weekday = the
/// most recent one, unless an explicit future word is used; never later than
/// today. No date words -> today. Mirror of nlp_datetime.expense_date.
DateTime expenseDate(String text, {DateTime? now}) {
  now = now ?? DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final r = parseReminder(text, now: now, preferPast: true);
  final dt = r.dateTime;
  if (dt == null || r.recurrence != null) return today;
  final d = DateTime(dt.year, dt.month, dt.day);
  return d.isAfter(today) ? today : d;
}

List<Object>? _extractTime(String norm, bool partPm,
    [bool night = false, String? part]) {
  final rx = RegExp(
      r'(\d{1,2})\s*[:.]\s*(\d{2})\s*(am|pm)?'
      r'|(\d{1,2})\s*(am|pm)'
      // Ta(y): "8Ta" / "8Tay" (the -y ending belongs to the time phrase, so it
      // never dangles in the title); never "50 Taka"
      '|(?<!\\d)(\\d{1,2})\\s*$_biTa(?!\u0995\u09be)(?:\u09af\u09bc|\u09df)?(?:\\s*(\\d{1,2})\\s*$_biMinute)?',
      caseSensitive: false);
  final m = rx.firstMatch(norm);
  if (m == null) {
    // Banglish clock (mirror of nlp_datetime._BL_TIME_RX / _BL_TIME_TA_RX)
    final asciiPart =
        part != null && part.codeUnits.every((c) => c < 128);
    final b = _blTimeRx.firstMatch(norm) ??
        (asciiPart ? _blTimeTaRx.firstMatch(norm) : null);
    if (b == null) return null;
    var bh = int.parse(b.group(1)!);
    if (bh > 24) return null;
    if (partPm && bh >= 1 && bh <= 11 && !(night && bh < 6)) {
      bh += 12;
    } else if (_morningParts.contains(part) && bh == 12) {
      bh = 0;
    }
    if (bh > 23) bh = 23;
    return [bh, 0, b.group(0) ?? ''];
  }
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
    if (h > 24) return null; // "50Ta" is a count, not a clock
  }
  if (h == null) return null;
  if (ampm.startsWith('p')) {
    if (h < 12) h = h + 12;
  } else if (ampm.startsWith('a')) {
    if (h == 12) h = 0;
  } else if (partPm && h >= 1 && h <= 11 && !(night && h < 6)) {
    // (raat/night: only 6..11 are evening hours -- "raat 1Ta" is 01:00)
    h = h + 12;
  } else if (_morningParts.contains(part) && h == 12) {
    h = 0;
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

/// Most recent date (<= from) whose day-of-month is dom.
DateTime _prevDom(DateTime from, int dom) {
  dom = dom.clamp(1, 31);
  final f = DateTime(from.year, from.month, from.day);
  var d = dom > _daysInMonth(f.year, f.month) ? _daysInMonth(f.year, f.month) : dom;
  var cand = DateTime(f.year, f.month, d);
  if (cand.isAfter(f)) {
    final pm = _addMonths(DateTime(f.year, f.month, 1), -1);
    d = dom > _daysInMonth(pm.year, pm.month) ? _daysInMonth(pm.year, pm.month) : dom;
    cand = DateTime(pm.year, pm.month, d);
  }
  return cand;
}

final RegExp _kalRx = RegExp('$_nb\u0995\u09be\u09b2(?:\u0995\u09c7|\u0995\u09c7\u0987|\u0995\u09c7\u09b0|\u0987)?$_na');
final RegExp _ajRx = RegExp('$_nb\u0986\u099c(?:\u0995\u09c7|\u0995\u09c7\u0987|\u0995\u09c7\u09b0|\u0987)?$_na');

(DateTime, String, double)? _relativeDate(String low, DateTime now, bool past) {
  final today = DateTime(now.year, now.month, now.day);
  DateTime plus(int d) => DateTime(today.year, today.month, today.day + d);
  // yesterday -- always past
  var m = RegExp(
          '\u0997\u09a4\u0995\u09be\u09b2(?:\u0995\u09c7|\u0995\u09c7\u09b0|\u0987)?|\u0997\u09a4\\s+\u0995\u09be\u09b2|\\byesterday\\b|\\bgotokal\\b|\\bgotokaal\\b')
      .firstMatch(low);
  if (m != null) return (plus(-1), m.group(0)!, 0.85);
  m = RegExp('\u0997\u09a4\\s*\u09aa\u09b0\u09b6\u09c1|day before yesterday').firstMatch(low);
  if (m != null) return (plus(-2), m.group(0)!, 0.85);
  // day after tomorrow (contains "tomorrow", so test it first -- aieval)
  m = RegExp('day after tomorrow').firstMatch(low);
  if (m != null) return (plus(2), m.group(0)!, 0.85);
  // explicit tomorrow (agamikal contains kal, so test it first)
  m = RegExp('\u0986\u0997\u09be\u09ae\u09c0\\s*\u0995\u09be\u09b2(?:\u0995\u09c7|\u0987)?|\u0986\u0997\u09be\u09ae\u09bf\\s*\u0995\u09be\u09b2|\\btomorrow\\b').firstMatch(low);
  if (m != null) return (plus(1), m.group(0)!, 0.85);
  // bare kal: yesterday in a past-tense sentence, tomorrow otherwise
  m = _kalRx.firstMatch(low) ?? RegExp(r'\bkalke\b|\bkal\b').firstMatch(low);
  if (m != null) return (plus(past ? -1 : 1), m.group(0)!, 0.85);
  // today
  m = _ajRx.firstMatch(low) ?? RegExp(r'\btoday\b|\bajke\b|\baj\b').firstMatch(low);
  if (m != null) return (today, m.group(0)!, 0.8);
  m = RegExp('\u09aa\u09b0\u09b6\u09c1(?:\u09a6\u09bf\u09a8)?').firstMatch(low);
  if (m != null) return (plus(past ? -2 : 2), m.group(0)!, 0.85);
  // N din age / N days ago
  m = RegExp('(\\d{1,3})\\s*\u09a6\u09bf\u09a8\\s*\u0986\u0997\u09c7').firstMatch(low) ??
      RegExp(r'(\d{1,3})\s*days?\s+ago').firstMatch(low);
  if (m != null) return (plus(-int.parse(m.group(1)!)), m.group(0)!, 0.85);
  m = RegExp('(\\d{1,3})\\s*\u09b8\u09aa\u09cd\u09a4\u09be\u09b9\\s*\u0986\u0997\u09c7').firstMatch(low) ??
      RegExp(r'(\d{1,3})\s*weeks?\s+ago').firstMatch(low);
  if (m != null) return (plus(-7 * int.parse(m.group(1)!)), m.group(0)!, 0.85);
  m = RegExp('(\\d{1,3})\\s*\u09ae\u09be\u09b8\\s*\u0986\u0997\u09c7').firstMatch(low) ??
      RegExp(r'(\d{1,3})\s*months?\s+ago').firstMatch(low);
  if (m != null) return (_addMonths(today, -int.parse(m.group(1)!)), m.group(0)!, 0.8);
  // N din por / in N days
  m = RegExp('(\\d{1,3})\\s*$_biDay\\s*(?:${_biAfter.join('|')})').firstMatch(low) ??
      RegExp(r'(?:in|after)\s+(\d{1,3})\s*days?').firstMatch(low);
  if (m != null) return (plus(int.parse(m.group(1)!)), m.group(0)!, 0.85);
  // N soptah por / in N weeks
  m = RegExp('(\\d{1,3})\\s*\u09b8\u09aa\u09cd\u09a4\u09be\u09b9\\s*(?:\u09aa\u09b0|\u09aa\u09b0\u09c7)').firstMatch(low) ??
      RegExp(r'(?:in|after)\s+(\d{1,3})\s*weeks?').firstMatch(low);
  if (m != null) return (plus(7 * int.parse(m.group(1)!)), m.group(0)!, 0.85);
  // N mash por / in N months
  m = RegExp('(\\d{1,3})\\s*\u09ae\u09be\u09b8\\s*(?:\u09aa\u09b0|\u09aa\u09b0\u09c7)').firstMatch(low) ??
      RegExp(r'(?:in|after)\s+(\d{1,3})\s*months?').firstMatch(low);
  if (m != null) return (_addMonths(today, int.parse(m.group(1)!)), m.group(0)!, 0.8);
  // next week
  m = RegExp('\u0986\u0997\u09be\u09ae\u09c0\\s*\u09b8\u09aa\u09cd\u09a4\u09be\u09b9|next\\s+week').firstMatch(low);
  if (m != null) return (plus(7), m.group(0)!, 0.7);
  // masher sheshe / end of the month
  m = RegExp(_monthEndRx).firstMatch(low);
  if (m != null) return (_monthEnd(today), m.group(0)!, 0.8);
  return null;
}

(DateTime, String, double)? _monthDate(String low, DateTime now, bool past) {
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
    final dom = int.parse(m.group(1)!);
    // past tense: this month's N, or last month's if still ahead
    return (past ? _prevDom(now, dom) : _nextDom(now, dom), m.group(0)!, 0.7);
  }
  return null;
}

// one-off weekday qualifiers that belong to the date phrase (mirror of
// nlp_datetime._WD_QUAL_RX): next/this/coming/upcoming/agami/samner/ei,
// agami, samner, ei, got, last.
const _wdQualRx = '(?:(?<![a-z])(?:next|this|coming|upcoming|agami|samner|ei)'
    '|\u0986\u0997\u09be\u09ae\u09c0|\u0986\u0997\u09be\u09ae\u09bf|\u09b8\u09be\u09ae\u09a8\u09c7\u09b0|\u098f\u0987|\u0997\u09a4|last)';

(DateTime, String, double)? _bareWeekday(String low, DateTime now, bool past) {
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
    // remmeter: the qualifier ("next friday", "agami shukrobar") is part of
    // the date phrase, so it leaves the title too (was "next call ammu")
    var span = tok;
    final qm = RegExp('$_wdQualRx\\s*${RegExp.escape(tok)}').firstMatch(low);
    if (qm != null) span = qm.group(0)!;
    if (past) {
      // "shukrobar giyechilam" -> the most recent past Friday
      var back = ((now.weekday - 1) - entry.value) % 7;
      if (back == 0) back = 7;
      return (DateTime(now.year, now.month, now.day - back), span, 0.65);
    }
    return (_nextWeekday(now, entry.value), span, 0.65);
  }
  return null;
}

(DateTime, String, double)? _explicitDate(String norm, DateTime now, bool past) {
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
  final today = DateTime(now.year, now.month, now.day);
  if (m.group(3) == null && past && cand.isAfter(today)) {
    final py = y - 1;
    cand = DateTime(py, mo, d > _daysInMonth(py, mo) ? _daysInMonth(py, mo) : d);
  } else if (m.group(3) == null && !past && cand.isBefore(today)) {
    cand = DateTime(y + 1, mo, day);
  }
  return (cand, m.group(0)!, 0.8);
}

// mirror of nlp_datetime._FILLER (same order)
const _fillers = [
  '\u0986\u09ae\u09be\u0995\u09c7',
  '\u09ae\u09a8\u09c7 \u0995\u09b0\u09bf\u09af\u09bc\u09c7 \u09a6\u09be\u0993',
  '\u09ae\u09a8\u09c7 \u0995\u09b0\u09bf\u09af\u09bc\u09c7 \u09a6\u09bf\u0993',
  '\u09ae\u09a8\u09c7 \u0995\u09b0\u09be\u0993',
  '\u09b0\u09bf\u09ae\u09be\u0987\u09a8\u09cd\u09a1\u09be\u09b0 \u09a6\u09be\u0993',
  'remind me to',
  'remind me',
  'reminder to',
  'set a reminder to',
  'set reminder',
  'please',
  '\u098f\u0995\u099f\u09be \u09b0\u09bf\u09ae\u09be\u0987\u09a8\u09cd\u09a1\u09be\u09b0',
  '\u09a8\u09bf\u0993',
];

String _cleanTitle(String raw, List<String> matched, {String? pre}) {
  var out = pre ?? _normalizeDigits(raw);
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
  // standalone "kal" only -- never the kal inside sokal / bikal
  if (_biTomorrow.take(2).any(low.contains) ||
      _kalRx.hasMatch(low) ||
      low.contains('tomorrow')) {
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
