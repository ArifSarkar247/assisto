import 'dart:convert';
import '../state.dart';

/// Dictionary ADVANCED — local, offline-first store + shared model
/// (feature 39, SPEC v2.1 §21). Mirrors the deterministic backend in
/// backend/core/logic/dictionary.py.
///
/// LICENSING: the rendered CONTENT (bn headwords, examples, synonyms,
/// antonyms, pronunciation) comes ONLY from the backend open-license / tiny
/// hand-written sample dataset — NEVER Bangla Academy or any proprietary
/// dictionary. This store never fabricates meanings; it only persists words the
/// user actually looked up so they stay available OFFLINE, plus their search
/// history and saved/favourite words. All persisted via [Settings]
/// (SharedPreferences), no server round-trip needed to read them.

/// A single rendered dictionary entry. All fields are DATA from the backend;
/// no meaning is ever constructed client-side.
class DictEntry {
  final String bn, en, pos, example, ipa;
  final List<String> syn, ant;
  const DictEntry({
    required this.bn,
    required this.en,
    this.pos = '',
    this.example = '',
    this.ipa = '',
    this.syn = const [],
    this.ant = const [],
  });

  /// Stable identity for saved/history de-dup (direction-agnostic pair).
  String get key => '$bn$en';

  static List<String> _list(dynamic v) =>
      (v is List) ? v.map((e) => '$e').where((e) => e.isNotEmpty).toList() : const [];

  factory DictEntry.fromJson(Map<String, dynamic> j) => DictEntry(
        bn: '${j['bn'] ?? ''}',
        en: '${j['en'] ?? ''}',
        pos: '${j['pos'] ?? ''}',
        example: '${j['example'] ?? ''}',
        ipa: '${j['ipa'] ?? ''}',
        syn: _list(j['syn']),
        ant: _list(j['ant']),
      );

  Map<String, dynamic> toJson() => {
        'bn': bn,
        'en': en,
        'pos': pos,
        'example': example,
        'ipa': ipa,
        'syn': syn,
        'ant': ant,
      };

  bool get isEmpty => bn.isEmpty && en.isEmpty;
}

/// Local, offline-first persistence for history / saved / word-cache.
/// Keys are namespaced so they never collide with other modules.
class DictStore {
  static const _kHistory = 'dict_history_v1'; // recently searched query strings
  static const _kSaved = 'dict_saved_v1'; // favourite entries (json list)
  static const _kCache = 'dict_cache_v1'; // looked-up entries by key (offline)
  static const _maxHistory = 30;
  static const _maxCache = 400;

  // ---- search history (query strings) ------------------------------------
  Future<List<String>> history() async {
    final raw = await Settings.getString(_kHistory);
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List).map((e) => '$e').toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<String>> pushHistory(String q) async {
    q = q.trim();
    if (q.isEmpty) return history();
    final list = await history();
    list.removeWhere((e) => e.toLowerCase() == q.toLowerCase());
    list.insert(0, q);
    if (list.length > _maxHistory) list.removeRange(_maxHistory, list.length);
    await Settings.setString(_kHistory, jsonEncode(list));
    return list;
  }

  Future<void> clearHistory() async => Settings.setString(_kHistory, jsonEncode([]));

  // ---- saved / favourite entries -----------------------------------------
  Future<List<DictEntry>> saved() async {
    final raw = await Settings.getString(_kSaved);
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => DictEntry.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<bool> isSaved(DictEntry e) async =>
      (await saved()).any((s) => s.key == e.key);

  /// Toggle save. Returns the new saved-state (true = now saved).
  Future<bool> toggleSaved(DictEntry e) async {
    final list = await saved();
    final i = list.indexWhere((s) => s.key == e.key);
    final nowSaved = i < 0;
    if (nowSaved) {
      list.insert(0, e);
    } else {
      list.removeAt(i);
    }
    await Settings.setString(_kSaved, jsonEncode(list.map((x) => x.toJson()).toList()));
    return nowSaved;
  }

  // ---- offline cache of looked-up entries --------------------------------
  Future<Map<String, DictEntry>> _cacheMap() async {
    final raw = await Settings.getString(_kCache);
    if (raw == null || raw.isEmpty) return {};
    try {
      final m = (jsonDecode(raw) as Map).cast<String, dynamic>();
      return m.map((k, v) =>
          MapEntry(k, DictEntry.fromJson((v as Map).cast<String, dynamic>())));
    } catch (_) {
      return {};
    }
  }

  /// Persist every entry returned for a query so a later OFFLINE lookup of the
  /// same word (or words with that query as their source side) still resolves.
  Future<void> cacheResults(String query, List<DictEntry> entries) async {
    if (entries.isEmpty) return;
    final map = await _cacheMap();
    final qKey = _qKey(query);
    // index by normalised query AND by each result's source headwords
    for (final e in entries) {
      map[qKey] = e; // first result represents the query
      break;
    }
    map[qKey] = entries.first;
    _storeByHeadword(map, entries);
    await _trimAndSave(map);
  }

  void _storeByHeadword(Map<String, DictEntry> map, List<DictEntry> entries) {
    for (final e in entries) {
      if (e.en.isNotEmpty) map[_qKey(e.en)] = e;
      if (e.bn.isNotEmpty) map[_qKey(e.bn)] = e;
    }
  }

  Future<void> _trimAndSave(Map<String, DictEntry> map) async {
    if (map.length > _maxCache) {
      final keys = map.keys.toList();
      for (final k in keys.take(map.length - _maxCache)) {
        map.remove(k);
      }
    }
    await Settings.setString(
        _kCache, jsonEncode(map.map((k, v) => MapEntry(k, v.toJson()))));
  }

  /// Offline lookup: returns cached entries whose query/headword matches, or [].
  Future<List<DictEntry>> cachedFor(String query) async {
    final map = await _cacheMap();
    final hit = map[_qKey(query)];
    if (hit != null) return [hit];
    // prefix fallback over cached headwords
    final q = _qKey(query);
    final out = <DictEntry>[];
    final seen = <String>{};
    for (final entry in map.entries) {
      if (entry.key.startsWith(q) && seen.add(entry.value.key)) {
        out.add(entry.value);
      }
    }
    return out;
  }

  Future<bool> hasAnyCache() async => (await _cacheMap()).isNotEmpty;

  static String _qKey(String s) => s.trim().toLowerCase();
}
