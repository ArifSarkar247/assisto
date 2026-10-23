/// a1-circle — ONE chat-list row per person, always (owner bug: "Abul
/// Kashem" twice). Mirrors the server's a1_circle.dedupe_chat_rows so a
/// stale/mixed payload (request thread + circle edge, both directions) can
/// never draw a person twice.
///
/// 1:1 rows are keyed by `member.peer_user_id` (the other person's ACCOUNT);
/// the survivor is the row with the newest activity (`at`), an accepted edge
/// winning a tie over a request row. Its unread count becomes the max of the
/// duplicates (they read the same conversation). Groups and rows with no
/// known peer account pass through. Order is preserved.
///
/// Two DIFFERENT accounts with the same name are never merged — see
/// [sameNameKeys] for the WhatsApp-style second identifier.
library;

bool _isGroup(Map<String, dynamic> r) =>
    r['is_group'] == true || r['kind'] == 'group';

String? _peerKey(Map<String, dynamic> r) {
  if (_isGroup(r)) return null;
  final m = r['member'];
  if (m is! Map) return null;
  final id = m['peer_user_id'];
  if (id == null || '$id'.isEmpty) return null;
  return '$id';
}

int _unread(Map<String, dynamic> r) =>
    r['unread'] is int ? r['unread'] as int : int.tryParse('${r['unread'] ?? 0}') ?? 0;

List<Map<String, dynamic>> dedupeChatRows(List<Map<String, dynamic>> rows) {
  final best = <String, int>{};
  final maxUnread = <String, int>{};
  for (var i = 0; i < rows.length; i++) {
    final k = _peerKey(rows[i]);
    if (k == null) continue;
    final u = _unread(rows[i]);
    if (u > (maxUnread[k] ?? 0)) maxUnread[k] = u;
    final cur = best[k];
    if (cur == null) {
      best[k] = i;
      continue;
    }
    final a = rows[cur], b = rows[i];
    final ta = '${a['at'] ?? ''}', tb = '${b['at'] ?? ''}';
    final c = tb.compareTo(ta);
    if (c > 0 || (c == 0 && a['request'] != null && b['request'] == null)) {
      best[k] = i;
    }
  }
  final keep = best.values.toSet();
  final out = <Map<String, dynamic>>[];
  for (var i = 0; i < rows.length; i++) {
    final k = _peerKey(rows[i]);
    if (k != null && !keep.contains(i)) continue;
    final r = rows[i];
    if (k != null && (maxUnread[k] ?? 0) > _unread(r)) {
      try {
        r['unread'] = maxUnread[k];
      } catch (_) {} // an unmodifiable (test) row
    }
    out.add(r);
  }
  return out;
}

String _norm(String s) => s.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

/// Normalised display names that appear on MORE than one 1:1 row.
Set<String> sameNameKeys(Iterable<Map<String, dynamic>> rows) {
  final n = <String, int>{};
  for (final r in rows) {
    if (_isGroup(r)) continue;
    final k = _norm('${(r['member'] as Map?)?['name'] ?? ''}');
    if (k.isEmpty) continue;
    n[k] = (n[k] ?? 0) + 1;
  }
  return {for (final e in n.entries) if (e.value > 1) e.key};
}

/// The subtle second identifier for a row whose name is shared: the custom
/// label I gave them, else the masked number tail ("…888"), else ''.
/// [digits] localises the tail (Bangla digits in bn).
String sameNameHint(Map<String, dynamic> row, Set<String> dupNames,
    {String Function(String)? digits}) {
  if (_isGroup(row)) return '';
  final m = (row['member'] as Map?) ?? const {};
  if (!dupNames.contains(_norm('${m['name'] ?? ''}'))) return '';
  final label = '${m['custom_label'] ?? ''}'.trim();
  if (label.isNotEmpty) return label;
  final tail = '${m['phone_tail'] ?? ''}'.trim();
  if (tail.isNotEmpty) return '…${digits == null ? tail : digits(tail)}';
  return '';
}
