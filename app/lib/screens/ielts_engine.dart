/// p2lang — the on-device mirror of backend/core/logic/ielts.py (pure Dart, no
/// Flutter, no network, no clock). Runs OFFLINE so the pronunciation check
/// works without the internet. Shared vectors: backend core/tests_p2lang.py
/// ALIGN_VECTORS == test/ielts_engine_test.dart.
library;

final RegExp _wordRe = RegExp(r"[a-z0-9']+");

/// Lowercase word tokens (letters, digits, apostrophes) — same as ielts.words.
List<String> ieltsWords(String? text) => _wordRe
    .allMatches((text ?? '').toLowerCase().replaceAll('’', "'"))
    .map((m) => m.group(0)!)
    .toList();

class AlignRow {
  final String word;
  final String status; // ok | sub | miss
  final String heard;
  const AlignRow(this.word, this.status, this.heard);
}

class AlignResult {
  final List<AlignRow> rows;
  final int score; // 0..100
  const AlignResult(this.rows, this.score);
}

/// Word-level alignment of [target] vs what the recogniser [heard]
/// (Levenshtein on words; backtrace: exact match, then an extra heard word,
/// then a missed target word, then a substitution). An ESTIMATE of how much of
/// the sentence the phone understood — not phoneme analysis.
AlignResult alignWords(String target, String heard) {
  final t = ieltsWords(target);
  final h = ieltsWords(heard);
  final n = t.length, m = h.length;
  if (n == 0) return const AlignResult([], 0);
  final d = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = 0; i <= n; i++) {
    d[i][0] = i;
  }
  for (var j = 0; j <= m; j++) {
    d[0][j] = j;
  }
  for (var i = 1; i <= n; i++) {
    for (var j = 1; j <= m; j++) {
      final cost = t[i - 1] == h[j - 1] ? 0 : 1;
      var best = d[i - 1][j - 1] + cost;
      if (d[i - 1][j] + 1 < best) best = d[i - 1][j] + 1;
      if (d[i][j - 1] + 1 < best) best = d[i][j - 1] + 1;
      d[i][j] = best;
    }
  }
  final rows = <AlignRow>[];
  var i = n, j = m;
  while (i > 0) {
    if (j > 0 && t[i - 1] == h[j - 1] && d[i][j] == d[i - 1][j - 1]) {
      rows.add(AlignRow(t[i - 1], 'ok', h[j - 1]));
      i--;
      j--;
    } else if (j > 0 && d[i][j] == d[i][j - 1] + 1) {
      j--; // an extra heard word — not a target word
    } else if (d[i][j] == d[i - 1][j] + 1) {
      rows.add(AlignRow(t[i - 1], 'miss', ''));
      i--;
    } else {
      rows.add(AlignRow(t[i - 1], 'sub', h[j - 1]));
      i--;
      j--;
    }
  }
  final ordered = rows.reversed.toList();
  final ok = ordered.where((r) => r.status == 'ok').length;
  return AlignResult(ordered, (100 * ok / n).round());
}

class Streak {
  final int current, best;
  final bool todayDone;
  const Streak(this.current, this.best, this.todayDone);
}

/// Current + best run of consecutive practice day-numbers (current counts if
/// the last practice was today or yesterday) — same as ielts.streak.
Streak ieltsStreak(Iterable<int> days, int today) {
  final s = days.toSet().toList()..sort();
  var best = 0, run = 0;
  int? prev;
  for (final d in s) {
    run = (prev != null && d == prev + 1) ? run + 1 : 1;
    if (run > best) best = run;
    prev = d;
  }
  final current = s.isNotEmpty && s.last >= today - 1 ? run : 0;
  return Streak(current, best, s.isNotEmpty && s.last == today);
}

/// Leitner boxes 1..5 -> days until the next review (same table as
/// language_partner.py _BOX_DAYS).
const Map<int, int> kLeitnerDays = {1: 1, 2: 2, 3: 4, 4: 7, 5: 15};

/// (newBox, nextDueDay): a pass promotes one box (max 5), a miss resets to 1.
(int, int) leitnerNext(int box, bool passed, int today) {
  final b = passed ? (box + 1).clamp(1, 5) : 1;
  return (b, today + kLeitnerDays[b]!);
}

/// Day-number since the Unix epoch (UTC) — computed once at the UI edge.
int ieltsToday([DateTime? now]) =>
    (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch ~/ 86400000;
