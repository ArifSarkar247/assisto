// quranread: "I read, check me" - letter matching between what the learner
// should read and what the phone's speech-to-text heard.
//
// HONEST SCOPE (shown in the UI as "a helper, not a replacement for a
// teacher"): speech-to-text returns plain Arabic WITHOUT vowel marks, so this
// compares the LETTERS (the consonant skeleton) only. It cannot judge
// harakat, madd length, ghunnah, qalqalah or makhraj precision. Alif and
// hamza are ignored on both sides because Uthmani spelling and everyday
// spelling differ there (ٱلرَّحْمَٰنِ vs الرحمن).

/// Arabic letters reduced to a comparable skeleton: vowel marks, Quranic
/// annotation signs, tatweel, alif and hamza removed; letter variants unified.
String qlSkeleton(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    final c = _unify(r);
    if (c != null) b.writeCharCode(c);
  }
  return b.toString();
}

int? _unify(int r) {
  switch (r) {
    case 0x0622: // آ
    case 0x0623: // أ
    case 0x0625: // إ
    case 0x0627: // ا
    case 0x0671: // ٱ
    case 0x0621: // ء
      return null;
    case 0x0624: // ؤ
      return 0x0648; // و
    case 0x0626: // ئ
    case 0x0649: // ى
    case 0x06CC: // Farsi ya
      return 0x064A; // ي
    case 0x0629: // ة
      return 0x0647; // ه
    case 0x06A9: // Farsi kaf
      return 0x0643; // ك
  }
  if (r >= 0x0628 && r <= 0x064A && r != 0x0640) return r; // letters, no tatweel
  return null; // marks (064B-065F, 0670, 06D6-06ED), digits, Latin, spaces
}

/// Longest common subsequence: which positions of [e] appear, in order, in [h].
List<bool> _lcsMatch(String e, String h) {
  final n = e.length, m = h.length;
  final dp = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      dp[i][j] = e.codeUnitAt(i) == h.codeUnitAt(j)
          ? dp[i + 1][j + 1] + 1
          : (dp[i + 1][j] > dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1]);
    }
  }
  final ok = List<bool>.filled(n, false);
  var i = 0, j = 0;
  while (i < n && j < m) {
    if (e.codeUnitAt(i) == h.codeUnitAt(j)) {
      ok[i] = true;
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      i++;
    } else {
      j++;
    }
  }
  return ok;
}

enum ReciteVerdict { good, close, retry }

class ReciteWord {
  final String text;
  final bool ok;
  const ReciteWord(this.text, this.ok);
}

class ReciteResult {
  /// 0-100, letters only.
  final int score;
  final ReciteVerdict verdict;

  /// The expected words with a matched / missed flag (for colouring).
  final List<ReciteWord> words;
  final String heard;
  const ReciteResult(this.score, this.verdict, this.words, this.heard);
}

/// True when the item has letters the helper can compare.
bool qlCanCheck(String expected) => qlSkeleton(expected).isNotEmpty;

int _score(String e, String h) {
  if (e.isEmpty || h.isEmpty) return 0;
  final hit = _lcsMatch(e, h).where((x) => x).length;
  // Short drills (a syllable, a letter name): the engine often adds a vowel
  // letter (با / بي / بو) - judge coverage of the expected letters.
  if (e.length <= 3 && h.length <= e.length + 2) {
    return (hit * 100 / e.length).round();
  }
  // Longer text: the weaker of coverage (missed letters) and precision
  // (extra letters), so skipping a word or adding one both cost.
  final cover = hit / e.length, precise = hit / h.length;
  return ((cover < precise ? cover : precise) * 100).round();
}

ReciteVerdict verdictOf(int score) => score >= 85
    ? ReciteVerdict.good
    : (score >= 60 ? ReciteVerdict.close : ReciteVerdict.retry);

/// Compare [expected] (Arabic shown to the learner) with [heard] (what the
/// speech engine returned). [alsoAccept] are other acceptable readings - for a
/// single letter its NAME (ب is read "باء").
ReciteResult checkRecitation(String expected, String heard,
    {List<String> alsoAccept = const []}) {
  final h = qlSkeleton(heard);
  final words = expected.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  final skels = [for (final w in words) qlSkeleton(w)];
  final e = skels.join();
  var best = _score(e, h);
  for (final a in alsoAccept) {
    final s = _score(qlSkeleton(a), h);
    if (s > best) best = s;
  }
  // Per-word colouring from one alignment of the whole text.
  final ok = _lcsMatch(e, h);
  final out = <ReciteWord>[];
  var k = 0;
  final wholeOk = best >= 85;
  for (var i = 0; i < words.length; i++) {
    final len = skels[i].length;
    var hit = 0;
    for (var j = 0; j < len; j++) {
      if (ok[k + j]) hit++;
    }
    k += len;
    out.add(ReciteWord(words[i], wholeOk || (len == 0 ? true : hit * 4 >= len * 3)));
  }
  return ReciteResult(best, verdictOf(best), out, heard);
}
