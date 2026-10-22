/// md2 — no "send-to-poll flicker".
///
/// A sent message keeps its LOCAL bubble until the server copy is really in
/// the fetched list: matched by the server id the send returned, or by the
/// client_msg_id the server echoes back on my own rows. Only then is the
/// local bubble dropped — in the same frame the server row appears, so
/// there is never a frame where the message is missing (and never one where
/// it shows twice).
///
/// Pure (no Flutter): screens call [track] after a send succeeds and
/// [awaiting] whenever they merge a fetched page.
class SentEchoes {
  SentEchoes({this.ttl = const Duration(minutes: 2)});

  /// A server copy that never shows (e.g. a server without client_msg_id
  /// and an unknown server id) stops being held after this long.
  final Duration ttl;

  final Map<String, ({String cmid, DateTime at})> _byLocalId = {};

  bool get isEmpty => _byLocalId.isEmpty;

  /// The local bubble [localId] (its server id when known, else the
  /// client_msg_id) waits for the server row of [cmid].
  void track(String localId, String cmid, {DateTime? now}) {
    if (localId.isEmpty) return;
    _byLocalId[localId] = (cmid: cmid, at: now ?? DateTime.now());
  }

  bool isTracked(String localId) => _byLocalId.containsKey(localId);

  void forget(String localId) => _byLocalId.remove(localId);

  /// True when a fetched page ([ids] = server ids, [cmids] = the
  /// client_msg_ids on my rows) already holds the server copy of [localId].
  bool matched(String localId,
      {required Set<String> ids, required Set<String> cmids}) {
    final e = _byLocalId[localId];
    if (ids.contains(localId)) return true;
    if (e == null) return cmids.contains(localId);
    return e.cmid.isNotEmpty && cmids.contains(e.cmid);
  }

  /// The local ids still waiting after a fetched page; matched or expired
  /// ones are forgotten.
  Set<String> awaiting(
      {required Set<String> ids, required Set<String> cmids, DateTime? now}) {
    final t = now ?? DateTime.now();
    _byLocalId.removeWhere((k, v) =>
        matched(k, ids: ids, cmids: cmids) || t.difference(v.at) > ttl);
    return _byLocalId.keys.toSet();
  }
}

/// The client_msg_ids on MY rows of a fetched page (the server sends them
/// only to the sender).
Set<String> fetchedClientIds(Iterable<Map<String, dynamic>> rows) => {
      for (final r in rows)
        if ('${r['client_msg_id'] ?? ''}'.isNotEmpty) '${r['client_msg_id']}'
    };
