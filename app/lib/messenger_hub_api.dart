import 'api.dart';

/// Thin, additive API surface for the MY CIRCLE HUB top-level UI
/// (SPEC .phaseB/MESSENGER_UI_FULL.md §2). Kept OUT of the core [ApiClient] so
/// the hub can evolve without touching `api.dart`; every method is a fixed
/// helper over the public [ApiClient.getJson] / [ApiClient.postJson].
///
/// The hub codes against the paths the backend agent is landing concurrently
/// (starred messages, read-all, custom lists, device QR link-start). Each
/// screen degrades to an honest loading / empty / error state when a path is
/// not yet live — never a dead tap, never a crash.
///
/// Server contract (all opaque to the relay; chat content stays E2E):
///   GET  /circle/lists            -> {results:[{id, name, count?}]}
///   GET  /circle/starred          -> {results:[{id, peer_id, peer_name,
///                                      message_id, preview?, at?}]}
///   POST /circle/read-all         -> {ok, cleared?}
///   GET  /circle/devices          -> {devices:[{id|device_id, name, platform,
///                                      last_active?, linked_at?, revoked}]}
///   POST /circle/devices/link-start -> {token, qr?, expires_at?}
///   POST /circle/devices/<id>/revoke -> {ok}
extension MessengerHubApi on ApiClient {
  /// The user's own custom chat lists (feed the hub filter chips alongside the
  /// built-in All · Unread · Favourites · Groups chips).
  Future<List<Map<String, dynamic>>> hubCustomLists() async {
    final r = await getJson('messenger/lists');
    return ((r['lists'] ?? r['results'] ?? const []) as List)
        .cast<Map<String, dynamic>>();
  }

  /// Every starred message across chats. Each row carries the peer + the
  /// message id so [StarredMessagesScreen] can jump to it in the thread.
  Future<List<Map<String, dynamic>>> hubStarredMessages() async {
    final r = await getJson('messenger/starred');
    return ((r['starred'] ?? r['results'] ?? const []) as List)
        .cast<Map<String, dynamic>>();
  }

  /// Mark every chat read. Returns the server ack (optionally a cleared count).
  Future<Map<String, dynamic>> hubReadAll() => postJson('messenger/read-all');

  /// Linked devices for the Linked-devices screen. Normalises the two shapes
  /// the backend may return (`devices` / `results`).
  Future<List<Map<String, dynamic>>> hubLinkedDevices() async {
    final r = await getJson('messenger/linked-devices');
    return ((r['devices'] ?? r['results'] ?? const []) as List)
        .cast<Map<String, dynamic>>();
  }

  /// Begin a device-link session — the server mints a short-lived token the
  /// web/desktop client scans as a QR. Payload is non-secret (never a key).
  Future<Map<String, dynamic>> hubLinkStart() =>
      postJson('messenger/link/start');

  /// Revoke (log out) a single linked device by its server id.
  Future<Map<String, dynamic>> hubRevokeDevice(String deviceId) =>
      postJson('messenger/linked-devices/$deviceId/revoke');
}
