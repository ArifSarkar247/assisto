// quranview (owner order 9 Nov 21:55, lane 14): server calls + phone cache
// for the bilingual ayah view. Spec: owner_actions/QURAN_BILINGUAL_SPEC_BN.md.
//
//  * Meaning / tafsir (QuranEnc.com): publisher text VERBATIM; the server
//    keeps it at the publisher's latest version; the phone keeps a copy for
//    1 day in memory (offline: the last copy is still shown).
//  * Quran Foundation (word-by-word, transliteration, audio URL, reciters):
//    the phone NEVER keeps it longer than [qfMaxAge] (6 days; QF terms: 7).
//    Nothing from QF is bundled in the app.
//  * Bangla pronunciation: lane 15's rule engine (/quran/pron/<surah>), no AI;
//    cached per surah; shown "under review" unless review == approved.
// No AI is called from here, ever.

/// One GET returning JSON (the app's ApiClient.getJson, or a test fake).
typedef QvGet = Future<Map<String, dynamic>> Function(String path);

const Duration qfMaxAge = Duration(days: 6);
const Duration _qeAge = Duration(days: 1);

class _Entry {
  final DateTime at;
  final Map<String, dynamic> data;
  _Entry(this.at, this.data);
}

class QuranBilingualApi {
  final QvGet _get;
  final DateTime Function() _now;
  QuranBilingualApi(this._get, {DateTime Function()? now})
      : _now = now ?? DateTime.now;

  // Shared across screens (one process); QF entries expire after [qfMaxAge].
  static final Map<String, _Entry> _mem = {};

  static void clearForTest() => _mem.clear();

  Future<Map<String, dynamic>?> _cached(String path, Duration maxAge,
      {bool staleOk = false}) async {
    final hit = _mem[path];
    final fresh = hit != null && _now().difference(hit.at) < maxAge;
    if (fresh) return hit.data;
    if (hit != null && !staleOk) _mem.remove(path); // QF: never past max age
    try {
      final d = await _get(path);
      if (d['ok'] == false) return staleOk ? hit?.data : null;
      _mem[path] = _Entry(_now(), d);
      return d;
    } catch (_) {
      return staleOk ? hit?.data : null;
    }
  }

  /// Bangla + English meaning of a whole surah (QuranEnc, verbatim).
  Future<Map<String, dynamic>?> meaning(int surah) =>
      _cached('/quran/meaning/$surah', _qeAge, staleOk: true);

  /// Tafsir sheet data for one ayah (licensed sources only).
  Future<Map<String, dynamic>?> tafsir(int surah, int ayah) =>
      _cached('/quran/tafsir/$surah/$ayah', _qeAge, staleOk: true);

  /// Lane 15 pronunciation for a surah (cached per surah).
  Future<Map<String, dynamic>?> pron(int surah) =>
      _cached('/quran/pron/$surah', _qeAge, staleOk: true);

  /// Quran Foundation: words, transliteration, audio for one ayah.
  Future<Map<String, dynamic>?> qf(int surah, int ayah, {int? reciter}) =>
      _cached('/quran/qf/$surah/$ayah${reciter == null ? '' : '?reciter=$reciter'}',
          qfMaxAge);

  Future<Map<String, dynamic>?> reciters() =>
      _cached('/quran/reciters', qfMaxAge);
}

/// The item of [ayah] inside a surah-level list (meaning / pron), or null.
Map<String, dynamic>? qvItem(Map<String, dynamic>? block, int ayah) {
  final items = block?['items'];
  if (items is! List) return null;
  for (final x in items) {
    if (x is Map && x['ayah'] == ayah) return Map<String, dynamic>.from(x);
  }
  return null;
}

/// Publisher footnotes may carry <b>…</b>; returns (text, bold) runs with
/// every other tag dropped. The words themselves are never changed.
List<(String, bool)> qvRuns(String s) {
  final out = <(String, bool)>[];
  final re = RegExp(r'<b>(.*?)</b>', dotAll: true, caseSensitive: false);
  var i = 0;
  String clean(String x) => x.replaceAll(RegExp(r'<[^>]+>'), '');
  for (final m in re.allMatches(s)) {
    if (m.start > i) out.add((clean(s.substring(i, m.start)), false));
    out.add((clean(m.group(1) ?? ''), true));
    i = m.end;
  }
  if (i < s.length) out.add((clean(s.substring(i)), false));
  return out.where((r) => r.$1.isNotEmpty).toList();
}
