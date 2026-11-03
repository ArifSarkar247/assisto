// p3faith (owner PART 3, 3 Nov 2026): offline Quran data.
//
// Sources (assets/quran/SOURCES.txt):
//   * Arabic — Tanzil Quran Text, CC BY 3.0, Hafs (Medina mushaf). UTHMANI
//     1.1 is the reading text; SIMPLE 1.1 is used for search. Both stored
//     VERBATIM (gzip only, notice kept). We only READ them; nothing changes.
//   * English — Pickthall, "The Meaning of the Glorious Koran" (1930), public
//     domain; digital text from Tanzil.net, verbatim.
//   * Bangla — NOT bundled: no licence for app redistribution yet. The UI
//     shows "awaiting licence" honestly; it never invents a translation.
//   * Sura names / aya counts / juz starts — Tanzil metadata (cc-by).
// No audio (no clearly licensed recitation verified).
import 'dart:convert';
import 'dart:io' show gzip;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

class QuranSura {
  final int index; // 1..114
  final int ayas;
  final int start; // 0-based global aya index of aya 1
  final String nameAr;
  final String tname; // Latin transliteration (Tanzil metadata)
  final String ename; // English meaning of the name (Tanzil metadata)
  final bool meccan;
  const QuranSura(this.index, this.ayas, this.start, this.nameAr, this.tname,
      this.ename, this.meccan);
}

/// A (sura, aya) reference.
class AyaRef {
  final int sura;
  final int aya;
  const AyaRef(this.sura, this.aya);
  String get key => '$sura:$aya';
  static AyaRef? parse(String? s) {
    final p = (s ?? '').split(':');
    if (p.length != 2) return null;
    final a = int.tryParse(p[0]);
    final b = int.tryParse(p[1]);
    if (a == null || b == null || a < 1 || a > 114 || b < 1) return null;
    return AyaRef(a, b);
  }

  @override
  bool operator ==(Object o) => o is AyaRef && o.sura == sura && o.aya == aya;
  @override
  int get hashCode => sura * 1000 + aya;
}

class QuranHit {
  final AyaRef ref;
  final String text; // the matched line (Arabic or English)
  final bool arabic;
  const QuranHit(this.ref, this.text, this.arabic);
}

class QuranData {
  final List<QuranSura> suras;
  final List<AyaRef> juzStarts; // 30
  final List<String> arabic; // Tanzil SIMPLE, 6236 — used for SEARCH
  final List<String> uthmani; // Tanzil UTHMANI, 6236 — shown for reading
  final List<String> english; // 6236, global order
  final String arabicNotice; // Tanzil copyright notice (Uthmani), verbatim
  List<String>? _arNorm;

  QuranData(this.suras, this.juzStarts, this.arabic, this.english,
      this.arabicNotice, {List<String>? uthmani})
      : uthmani = uthmani ?? arabic;

  int globalIndex(AyaRef r) => suras[r.sura - 1].start + r.aya - 1;

  /// Reading text: Tanzil Uthmani (Hafs), verbatim.
  String ar(AyaRef r) => uthmani[globalIndex(r)];

  /// Tanzil Simple, verbatim (search / matching).
  String arSimple(AyaRef r) => arabic[globalIndex(r)];
  String en(AyaRef r) => english[globalIndex(r)];

  /// Juz (1..30) an aya belongs to.
  int juzOf(AyaRef r) {
    final g = globalIndex(r);
    var j = 1;
    for (var i = 0; i < juzStarts.length; i++) {
      if (globalIndex(juzStarts[i]) <= g) j = i + 1;
    }
    return j;
  }

  /// Sura matches for a query: number ("18"), transliteration ("kahf"),
  /// English meaning ("cave") or Arabic name (diacritics ignored).
  List<QuranSura> findSuras(String q) {
    final s = q.trim().toLowerCase();
    if (s.isEmpty) return suras;
    final n = int.tryParse(s);
    if (n != null) {
      return [if (n >= 1 && n <= 114) suras[n - 1]];
    }
    final latin = s.replaceAll(RegExp(r"[^a-z]"), '');
    final arQ = normalizeArabic(s);
    return suras.where((x) {
      final t = x.tname.toLowerCase().replaceAll(RegExp(r"[^a-z]"), '');
      return (latin.isNotEmpty &&
              (t.contains(latin) || x.ename.toLowerCase().contains(s))) ||
          (arQ.isNotEmpty && normalizeArabic(x.nameAr).contains(arQ));
    }).toList();
  }

  /// Full-text search in the English meaning and the Arabic text (Arabic is
  /// matched without diacritics). At most [limit] hits, Quran order.
  List<QuranHit> search(String q, {int limit = 200}) {
    final s = q.trim();
    if (s.length < 2) return const [];
    final hits = <QuranHit>[];
    final isAr = RegExp(r'[؀-ۿ]').hasMatch(s);
    if (isAr) {
      final nq = normalizeArabic(s);
      if (nq.isEmpty) return const [];
      final norm = _arNorm ??= arabic.map(normalizeArabic).toList();
      for (var i = 0; i < norm.length && hits.length < limit; i++) {
        if (norm[i].contains(nq)) hits.add(QuranHit(refAt(i), uthmani[i], true));
      }
    } else {
      final lq = s.toLowerCase();
      for (var i = 0; i < english.length && hits.length < limit; i++) {
        if (english[i].toLowerCase().contains(lq)) {
          hits.add(QuranHit(refAt(i), english[i], false));
        }
      }
    }
    return hits;
  }

  AyaRef refAt(int global) {
    var lo = 0, hi = suras.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      if (suras[mid].start <= global) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return AyaRef(lo + 1, global - suras[lo].start + 1);
  }
}

/// Arabic search key: drop harakat / Quranic marks / tatweel, unify alef,
/// ya and ta-marbuta forms. Used ONLY to match; the shown text is verbatim.
String normalizeArabic(String s) {
  final b = StringBuffer();
  for (final c in s.runes) {
    if ((c >= 0x064B && c <= 0x065F) ||
        c == 0x0670 ||
        (c >= 0x06D6 && c <= 0x06ED) ||
        c == 0x0640) {
      continue;
    }
    if (c == 0x0623 || c == 0x0625 || c == 0x0622 || c == 0x0671) {
      b.writeCharCode(0x0627);
    } else if (c == 0x0649) {
      b.writeCharCode(0x064A);
    } else if (c == 0x0629) {
      b.writeCharCode(0x0647);
    } else {
      b.writeCharCode(c);
    }
  }
  return b.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Parse a Tanzil "sura|aya|text" file into global order. Comment lines
/// (# ...) are the licence notice and are returned separately.
({List<String> lines, String notice}) parseTanzil(String raw, int expected) {
  final out = List<String>.filled(expected, '');
  final notice = StringBuffer();
  var n = 0;
  for (final line in const LineSplitter().convert(raw)) {
    if (line.startsWith('#')) {
      notice.writeln(line.replaceFirst(RegExp(r'^#\s?'), ''));
      continue;
    }
    if (line.trim().isEmpty) continue;
    final p1 = line.indexOf('|');
    final p2 = p1 < 0 ? -1 : line.indexOf('|', p1 + 1);
    if (p2 < 0) continue;
    if (n < expected) out[n] = line.substring(p2 + 1);
    n++;
  }
  if (n != expected) {
    throw FormatException('quran: expected $expected ayas, got $n');
  }
  return (lines: out, notice: notice.toString().trim());
}

class QuranStore {
  QuranStore._();
  static Future<QuranData>? _loading;

  static const metaAsset = 'assets/quran/quran_meta.json';
  static const arabicAsset = 'assets/quran/quran-simple.txt.gz';
  static const uthmaniAsset = 'assets/quran/quran-uthmani.txt.gz';
  static const englishAsset = 'assets/quran/en.pickthall.txt.gz';
  static const totalAyas = 6236;

  /// Loads once (offline, from the app bundle).
  static Future<QuranData> load() => _loading ??= _load().catchError((Object e) {
        _loading = null;
        throw e;
      });

  static Future<String> _gz(String asset) async {
    final bd = await rootBundle.load(asset);
    final bytes =
        bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
    return utf8.decode(gzip.decode(bytes));
  }

  static Future<QuranData> _load() async => fromRaw(
      await rootBundle.loadString(metaAsset),
      await _gz(arabicAsset),
      await _gz(englishAsset),
      uthmaniRaw: await _gz(uthmaniAsset));

  /// Parse the bundled files (meta JSON + the two decompressed Tanzil texts).
  static QuranData fromRaw(String metaJson, String arabicRaw, String englishRaw,
      {String? uthmaniRaw}) {
    final meta = jsonDecode(metaJson) as Map<String, dynamic>;
    final suras = [
      for (final m in (meta['suras'] as List).cast<Map<String, dynamic>>())
        QuranSura(m['i'] as int, m['ayas'] as int, m['start'] as int,
            '${m['name']}', '${m['tname']}', '${m['ename']}',
            m['type'] == 'Meccan'),
    ];
    final juz = [
      for (final j in (meta['juz'] as List).cast<List>())
        AyaRef(j[0] as int, j[1] as int),
    ];
    final ar = parseTanzil(arabicRaw, totalAyas);
    final en = parseTanzil(englishRaw, totalAyas);
    final uth = uthmaniRaw == null ? null : parseTanzil(uthmaniRaw, totalAyas);
    return QuranData(suras, juz, ar.lines, en.lines, uth?.notice ?? ar.notice,
        uthmani: uth?.lines);
  }

  /// Tests / gallery: use already-parsed data (the real bundled files).
  @visibleForTesting
  static void debugPreload(QuranData? d) =>
      _loading = d == null ? null : Future.value(d);
}

/// Translation choice. 'bn' = Bangla (awaiting licence — nothing shown).
enum QuranTrans { en, bn, none }

/// Reader prefs: bookmarks, last read, translation, Arabic size. Local only.
class QuranPrefs {
  static const _kBookmarks = 'quran_bookmarks_v1';
  static const _kLast = 'quran_last_read_v1';
  static const _kTrans = 'quran_translation_v1';
  static const _kSize = 'quran_ar_size_v1';
  static const double minSize = 20, maxSize = 40, defaultSize = 26;

  static Future<List<AyaRef>> bookmarks() async {
    final p = await SharedPreferences.getInstance();
    return (p.getStringList(_kBookmarks) ?? const [])
        .map(AyaRef.parse)
        .whereType<AyaRef>()
        .toList();
  }

  /// Toggles [r]; returns true when it is now bookmarked.
  static Future<bool> toggleBookmark(AyaRef r) async {
    final p = await SharedPreferences.getInstance();
    final list = p.getStringList(_kBookmarks) ?? <String>[];
    final had = list.remove(r.key);
    if (!had) list.insert(0, r.key);
    await p.setStringList(_kBookmarks, list);
    return !had;
  }

  static Future<AyaRef?> lastRead() async {
    final p = await SharedPreferences.getInstance();
    return AyaRef.parse(p.getString(_kLast));
  }

  static Future<void> setLastRead(AyaRef r) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kLast, r.key);
  }

  static Future<QuranTrans?> translation() async {
    final p = await SharedPreferences.getInstance();
    final v = p.getString(_kTrans);
    for (final t in QuranTrans.values) {
      if (t.name == v) return t;
    }
    return null;
  }

  static Future<void> setTranslation(QuranTrans t) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kTrans, t.name);
  }

  static Future<double> arabicSize() async {
    final p = await SharedPreferences.getInstance();
    return (p.getDouble(_kSize) ?? defaultSize).clamp(minSize, maxSize);
  }

  static Future<void> setArabicSize(double v) async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kSize, v.clamp(minSize, maxSize));
  }
}
