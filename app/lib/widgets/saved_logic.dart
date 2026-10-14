/// saved_logic.dart — pure SAVED / BOOKMARKS helpers, a VERBATIM mirror of
/// backend/core/logic/saved_items.py (#18, §21). Deterministic normalisation,
/// search (title+note+tag+ref), tag + kind filtering, recent-sort, tag counts,
/// and the honest empty-vs-no-results state machine. No Flutter, no Bangla —
/// pure Dart so the screen and backend agree exactly offline.

class SavedResult {
  final List<Map<String, dynamic>> items;
  final bool empty; // nothing saved at all
  final bool noResults; // has items but filter/search matched none
  const SavedResult(this.items, this.empty, this.noResults);
}

class SavedLogic {
  static const List<String> kinds = ['note', 'answer', 'doc', 'link'];
  static const String defaultKind = 'note';
  static const int maxTitle = 120;
  static const int maxTag = 40;
  static const int maxNote = 4000;

  static String _s(dynamic v) => v == null ? '' : v.toString();

  static String normaliseTag(dynamic tag) {
    var t = _s(tag).trim();
    if (t.isEmpty) return '';
    if (t.startsWith('#')) t = t.substring(1);
    t = t.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ').toLowerCase();
    return t.length > maxTag ? t.substring(0, maxTag) : t;
  }

  static String normaliseKind(dynamic kind) {
    final k = _s(kind).trim().toLowerCase();
    return kinds.contains(k) ? k : defaultKind;
  }

  /// Problem codes ([] == ok): title_required, bad_kind, ref_required_for_link.
  static List<String> validate(dynamic title,
      [String kind = defaultKind, dynamic ref = '']) {
    final problems = <String>[];
    if (_s(title).trim().isEmpty) problems.add('title_required');
    final k = _s(kind).trim().toLowerCase();
    if (!kinds.contains(k)) problems.add('bad_kind');
    if (k == 'link' && _s(ref).trim().isEmpty) {
      problems.add('ref_required_for_link');
    }
    return problems;
  }

  /// Cross-app "save this" entry point: normalise inputs into a storable row
  /// (WITHOUT id — the collection assigns it). Throws [ArgumentError] with the
  /// comma-joined problem codes if invalid, so a bad save never stores junk.
  static Map<String, dynamic> makeItem(
    dynamic title, {
    dynamic note = '',
    dynamic tag = '',
    String kind = defaultKind,
    dynamic ref = '',
    dynamic created = '',
  }) {
    final problems = validate(title, kind, ref);
    if (problems.isNotEmpty) throw ArgumentError(problems.join(','));
    var t = _s(title).trim();
    if (t.length > maxTitle) t = t.substring(0, maxTitle);
    var n = _s(note).trim();
    if (n.length > maxNote) n = n.substring(0, maxNote);
    return {
      'title': t,
      'note': n,
      'tag': normaliseTag(tag),
      'kind': normaliseKind(kind),
      'ref': _s(ref).trim(),
      'created': _s(created).trim(),
    };
  }

  static String _hay(Map<String, dynamic> it) => [
        _s(it['title']),
        _s(it['note']),
        _s(it['tag']),
        _s(it['ref']),
      ].join(' ').toLowerCase();

  /// AND-of-terms, case-insensitive. Blank query returns all (not no-results).
  static List<Map<String, dynamic>> search(
      List<Map<String, dynamic>> items, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return List.of(items);
    final terms = q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    return items.where((it) {
      final hay = _hay(it);
      return terms.every((term) => hay.contains(term));
    }).toList();
  }

  static List<Map<String, dynamic>> filterByTag(
      List<Map<String, dynamic>> items, String tag) {
    final want = normaliseTag(tag);
    if (want.isEmpty) return List.of(items);
    return items.where((it) => normaliseTag(it['tag']) == want).toList();
  }

  static List<Map<String, dynamic>> filterByKind(
      List<Map<String, dynamic>> items, String kind) {
    final k = kind.trim().toLowerCase();
    if (k.isEmpty || !kinds.contains(k)) return List.of(items);
    return items.where((it) => normaliseKind(it['kind']) == k).toList();
  }

  /// Sorted (tag, count) — most-used first, then A→Z. Untagged excluded.
  static List<MapEntry<String, int>> tagCounts(
      List<Map<String, dynamic>> items) {
    final counts = <String, int>{};
    for (final it in items) {
      final t = normaliseTag(it['tag']);
      if (t.isNotEmpty) counts[t] = (counts[t] ?? 0) + 1;
    }
    final entries = counts.entries.toList()
      ..sort((a, b) {
        final c = b.value.compareTo(a.value);
        return c != 0 ? c : a.key.compareTo(b.key);
      });
    return entries;
  }

  /// Newest first by `created` (ISO string compare); blank created sorts last.
  static List<Map<String, dynamic>> sortRecent(
      List<Map<String, dynamic>> items) {
    final out = List.of(items);
    // stable sort (List.sort is not guaranteed stable; decorate with index)
    final indexed = [
      for (var i = 0; i < out.length; i++) MapEntry(i, out[i])
    ];
    indexed.sort((a, b) {
      final ca = _s(a.value['created']).trim();
      final cb = _s(b.value['created']).trim();
      final c = cb.compareTo(ca); // desc
      return c != 0 ? c : a.key.compareTo(b.key);
    });
    return [for (final e in indexed) e.value];
  }

  /// Full pipeline: tag -> kind -> search -> recent-sort, with honest states.
  static SavedResult apply(
    List<Map<String, dynamic>> items, {
    String query = '',
    String tag = '',
    String kind = '',
  }) {
    final base = List<Map<String, dynamic>>.of(items);
    var out = filterByTag(base, tag);
    out = filterByKind(out, kind);
    out = search(out, query);
    out = sortRecent(out);
    final hasFilter = query.trim().isNotEmpty ||
        normaliseTag(tag).isNotEmpty ||
        kinds.contains(kind.trim().toLowerCase());
    return SavedResult(
      out,
      base.isEmpty,
      base.isNotEmpty && out.isEmpty && hasFilter,
    );
  }
}
