import 'dart:convert';
import '../state.dart';

/// Local persistence for the ADVANCED Medicine-DB module — all on-device,
/// non-sensitive (public drug facts only), SharedPreferences-backed via the
/// shared [Settings] store. Three lists:
///   - favourites: drugs the user saved (starred)
///   - recents: recently-viewed drugs (most-recent first, capped)
///   - offline cache: the FULL localised record of every drug the user opened,
///     so saved/recent drugs render completely with no network.
///
/// Records are stored as the raw localised maps returned by the backend
/// (`/medicine-db/search` / `/medicine-db/lookup`). We key a drug by its brand
/// (case-insensitive) — the sample set has unique brands; if a licensed feed
/// later has collisions the key can be widened to brand+strength without
/// changing callers.
class MedDbStore {
  static const _kFav = 'meddb_favourites_v1';
  static const _kRecent = 'meddb_recents_v1';
  static const _kCache = 'meddb_cache_v1';
  static const _recentCap = 20;
  static const _cacheCap = 60;

  static String keyOf(Map<String, dynamic> rec) =>
      '${(rec['brand'] ?? '').toString().trim().toLowerCase()}'
      '|${(rec['strength'] ?? '').toString().trim().toLowerCase()}';

  // ---- raw list helpers ----

  static Future<List<Map<String, dynamic>>> _readList(String k) async {
    try {
      final raw = await Settings.getString(k);
      if (raw == null || raw.isEmpty) return [];
      return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _writeList(String k, List<Map<String, dynamic>> v) async {
    try {
      await Settings.setString(k, jsonEncode(v));
    } catch (_) {/* best-effort */}
  }

  // ---- offline cache (full record for every viewed drug) ----

  static Future<void> cache(Map<String, dynamic> rec) async {
    if ((rec['brand'] ?? '').toString().trim().isEmpty) return;
    final key = keyOf(rec);
    final list = await _readList(_kCache);
    list.removeWhere((e) => keyOf(e) == key);
    list.insert(0, rec);
    if (list.length > _cacheCap) list.removeRange(_cacheCap, list.length);
    await _writeList(_kCache, list);
  }

  static Future<Map<String, dynamic>?> cached(String key) async {
    final list = await _readList(_kCache);
    for (final e in list) {
      if (keyOf(e) == key) return e;
    }
    return null;
  }

  // ---- recently viewed ----

  static Future<void> addRecent(Map<String, dynamic> rec) async {
    if ((rec['brand'] ?? '').toString().trim().isEmpty) return;
    await cache(rec);
    final key = keyOf(rec);
    final list = await _readList(_kRecent);
    list.removeWhere((e) => keyOf(e) == key);
    list.insert(0, rec);
    if (list.length > _recentCap) list.removeRange(_recentCap, list.length);
    await _writeList(_kRecent, list);
  }

  static Future<List<Map<String, dynamic>>> recents() => _readList(_kRecent);

  static Future<void> clearRecents() async => _writeList(_kRecent, []);

  // ---- favourites ----

  static Future<List<Map<String, dynamic>>> favourites() => _readList(_kFav);

  static Future<bool> isFavourite(String key) async {
    final list = await _readList(_kFav);
    return list.any((e) => keyOf(e) == key);
  }

  /// Toggle; returns the new favourite state (true = now saved).
  static Future<bool> toggleFavourite(Map<String, dynamic> rec) async {
    await cache(rec);
    final key = keyOf(rec);
    final list = await _readList(_kFav);
    final had = list.any((e) => keyOf(e) == key);
    if (had) {
      list.removeWhere((e) => keyOf(e) == key);
    } else {
      list.insert(0, rec);
    }
    await _writeList(_kFav, list);
    return !had;
  }
}
