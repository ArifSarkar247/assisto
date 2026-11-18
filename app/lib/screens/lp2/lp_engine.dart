/// lpapp — Language Partner V2: pure logic (no Flutter), unit-tested.
///
/// * IELTS public raw-score -> band tables (Listening, Academic Reading,
///   General Training Reading) and the overall-band rounding rule.
/// * Answer comparison + mistake types for the book companion (OMR): the key
///   is the one the USER typed from his own book — nothing is stored here.
/// * Vocabulary spaced repetition (Leitner boxes 1..5) and the daily goal.
library;

import '../ielts_engine.dart' show leitnerNext, ieltsWords;

// ------------------------------------------------------------------ bands

/// (min raw out of 40, band) — public tables, highest first.
const List<(int, double)> kListeningBands = [
  (39, 9), (37, 8.5), (35, 8), (32, 7.5), (30, 7), (26, 6.5), (23, 6),
  (18, 5.5), (16, 5), (13, 4.5), (10, 4), (8, 3.5), (6, 3), (4, 2.5),
  (2, 2), (1, 1),
];
const List<(int, double)> kAcademicReadingBands = [
  (39, 9), (37, 8.5), (35, 8), (33, 7.5), (30, 7), (27, 6.5), (23, 6),
  (19, 5.5), (15, 5), (13, 4.5), (10, 4), (8, 3.5), (6, 3), (4, 2.5),
  (2, 2), (1, 1),
];
const List<(int, double)> kGeneralReadingBands = [
  (40, 9), (39, 8.5), (37, 8), (36, 7.5), (34, 7), (32, 6.5), (30, 6),
  (27, 5.5), (23, 5), (19, 4.5), (15, 4), (12, 3.5), (9, 3), (6, 2.5),
  (3, 2), (1, 1),
];

/// Band for [raw] correct answers out of [total] (scaled to 40 first, so a
/// shorter practice set still lands on the public table).
double rawToBand(String section, String variant, int raw, int total) {
  if (total <= 0 || raw <= 0) return 0;
  final r40 = total == 40 ? raw : (raw * 40 / total).round();
  final table = section == 'listening'
      ? kListeningBands
      : (variant == 'general' ? kGeneralReadingBands : kAcademicReadingBands);
  for (final (min, band) in table) {
    if (r40 >= min) return band;
  }
  return 0;
}

/// IELTS overall: mean of the four bands; .25 rounds up to .5, .75 up to the
/// next whole band. Null when any section is missing.
double? overallBand(Map<String, double?> bands) {
  const keys = ['listening', 'reading', 'writing', 'speaking'];
  final v = [for (final k in keys) bands[k]];
  if (v.any((b) => b == null)) return null;
  final mean = v.fold<double>(0, (a, b) => a + b!) / 4;
  final whole = mean.floorToDouble();
  final frac = mean - whole;
  if (frac < 0.25) return whole;
  if (frac < 0.75) return whole + 0.5;
  return whole + 1;
}

/// "6.5" / "7" style band text (ASCII; the UI passes it through ld()).
String bandText(double b) => b == b.roundToDouble() ? b.toStringAsFixed(0) : b.toStringAsFixed(1);

/// Weakest finished section (for the key-free comment), or null.
String? weakestSection(Map<String, double?> bands) {
  String? w;
  double? lo;
  bands.forEach((k, v) {
    if (v != null && (lo == null || v < lo!)) {
      lo = v;
      w = k;
    }
  });
  return w;
}

// ------------------------------------------------------------- answers

String normAnswer(String s) => s
    .toLowerCase()
    .replaceAll('’', "'")
    .replaceAll(RegExp(r'[.,;:!?"]'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

const Map<String, String> _tfngAlias = {
  't': 'true', 'true': 'true', 'f': 'false', 'false': 'false',
  'ng': 'not given', 'not given': 'not given', 'notgiven': 'not given',
  'y': 'yes', 'yes': 'yes', 'n': 'no', 'no': 'no',
};

bool isTfngKey(String key) => _tfngAlias.containsKey(normAnswer(key));

/// The key's accepted forms: "a/b" alternatives; "(the) bridge" = optional words.
List<String> keyForms(String key) {
  final out = <String>{};
  for (final alt in key.split('/')) {
    final a = alt.trim();
    if (a.isEmpty) continue;
    out.add(normAnswer(a.replaceAll(RegExp(r'[()]'), '')));
    out.add(normAnswer(a.replaceAll(RegExp(r'\([^)]*\)'), '')));
  }
  out.removeWhere((s) => s.isEmpty);
  return out.toList();
}

String _canon(String s) {
  final n = normAnswer(s);
  return _tfngAlias[n] ?? n;
}

bool answerMatches(String answer, String key) {
  final a = _canon(answer);
  if (a.isEmpty) return false;
  return keyForms(key).map(_canon).contains(a);
}

int _lev(String a, String b) {
  if (a == b) return 0;
  var prev = List<int>.generate(b.length + 1, (j) => j);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final c = a[i - 1] == b[j - 1] ? 0 : 1;
      cur[j] = [prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + c].reduce((x, y) => x < y ? x : y);
    }
    prev = cur;
  }
  return prev[b.length];
}

bool _pluralPair(String a, String b) {
  if (a == b) return false;
  String strip(String w) => w.endsWith('ies')
      ? '${w.substring(0, w.length - 3)}y'
      : w.endsWith('es') && w.length > 3
          ? w.substring(0, w.length - 2)
          : w.endsWith('s') && w.length > 2
              ? w.substring(0, w.length - 1)
              : w;
  final aw = a.split(' '), bw = b.split(' ');
  if (aw.length != bw.length) return false;
  var diff = 0;
  for (var i = 0; i < aw.length; i++) {
    if (aw[i] == bw[i]) continue;
    if (strip(aw[i]) == strip(bw[i]) || strip(aw[i]) == bw[i] || aw[i] == strip(bw[i])) {
      diff++;
    } else {
      return false;
    }
  }
  return diff > 0;
}

/// Mistake type for one wrong answer: blank · word_limit · tfng · plural ·
/// spelling · map · matching · other. Null when the answer is right.
/// [wordLimit] 0 = none; [isMap] = the user marked this question as a map/plan.
String? mistakeType(String answer, String key, {int wordLimit = 0, bool isMap = false}) {
  if (answerMatches(answer, key)) return null;
  final a = normAnswer(answer);
  if (a.isEmpty) return 'blank';
  if (isTfngKey(key)) return 'tfng';
  if (wordLimit > 0 && ieltsWords(a).length > wordLimit) return 'word_limit';
  if (isMap) return 'map';
  final forms = keyForms(key);
  if (forms.any((k) => _pluralPair(a, k))) return 'plural';
  if (forms.any((k) => k.length >= 4 && !RegExp(r'^[a-z]$').hasMatch(k) && _lev(a, k) <= (k.length >= 8 ? 2 : 1))) {
    return 'spelling';
  }
  if (forms.any((k) => RegExp(r'^[a-z]$').hasMatch(k) || RegExp(r'^(i|ii|iii|iv|v|vi|vii|viii|ix|x)$').hasMatch(k))) {
    return 'matching';
  }
  return 'other';
}

class OmrResult {
  final int raw, total;
  final double band;
  final Map<int, String?> mistakes; // n -> type (null = right)
  final Map<String, int> counts;
  const OmrResult(this.raw, this.total, this.band, this.mistakes, this.counts);
}

/// Marks a sheet: [answers]/[key] are n -> text. Only questions with a key
/// count toward the total. [mapFrom]..[mapTo] (inclusive) = map/plan questions.
OmrResult markSheet(String section, String variant, Map<int, String> answers, Map<int, String> key,
    {int wordLimit = 0, int? mapFrom, int? mapTo}) {
  var raw = 0;
  final mistakes = <int, String?>{};
  final counts = <String, int>{};
  final ns = key.keys.where((n) => key[n]!.trim().isNotEmpty).toList()..sort();
  for (final n in ns) {
    final isMap = mapFrom != null && mapTo != null && n >= mapFrom && n <= mapTo;
    final m = mistakeType(answers[n] ?? '', key[n]!, wordLimit: wordLimit, isMap: isMap);
    mistakes[n] = m;
    if (m == null) {
      raw++;
    } else {
      counts[m] = (counts[m] ?? 0) + 1;
    }
  }
  final total = ns.length;
  final scaled = total == 0 ? 0.0 : rawToBand(section, variant, raw, total);
  return OmrResult(raw, total, scaled, mistakes, counts);
}

// ------------------------------------------------------------- vocab SRS

class VocabState {
  final int box, due;
  const VocabState(this.box, this.due);
}

/// Words due today: studied words whose due day has come, then new words
/// (up to [newPerDay] a day — gap-lp: minus the [introducedToday] words
/// already started today, so the daily goal really ends) in list order.
List<String> dueWords(List<String> order, Map<String, VocabState> state, int today,
    {int newPerDay = 10, int introducedToday = 0}) {
  final due = [for (final id in order) if (state[id] != null && state[id]!.due <= today) id];
  final room = newPerDay - introducedToday;
  final fresh = [for (final id in order) if (state[id] == null) id].take(room < 0 ? 0 : room);
  return [...due, ...fresh];
}

VocabState vocabNext(VocabState? s, bool knew, int today) {
  final (b, d) = leitnerNext(s?.box ?? 0, knew, today);
  return VocabState(b, d);
}

/// Words that reached box >= 3 count as "learned".
int learnedCount(Map<String, VocabState> state) => state.values.where((s) => s.box >= 3).length;

// --------------------------------------------------------------- timer

/// mm:ss (ASCII; UI passes it through ld()).
String clock(int seconds) {
  final s = seconds < 0 ? 0 : seconds;
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, r = s % 60;
  final mm = m.toString().padLeft(2, '0'), ss = r.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

/// Word count for writing tasks.
int wordCount(String text) => ieltsWords(text).length;
