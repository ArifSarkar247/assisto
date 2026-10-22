import '../api.dart';

/// c3-msg endpoints (backend/core/views_c3_msg.py). Metadata only — message
/// bodies stay ciphertext both ways.
extension C3MsgApi on ApiClient {
  /// "This device is online and has fetched": delivered for everything
  /// addressed to me without a receipt yet (app open / resume).
  Future<Map<String, dynamic>> c3ReceiptsSync() =>
      postJson('/circle/receipts/sync');

  /// Batch acks from this device.
  Future<Map<String, dynamic>> c3Receipts(
          {List<int> delivered = const [], List<int> seen = const []}) =>
      postJson('/circle/receipts', {'delivered': delivered, 'seen': seen});

  /// The chat is open: delivered + seen for every incoming message (the
  /// sender gets blue ticks unless read receipts are off).
  Future<Map<String, dynamic>> c3ChatSeen(String kind, int id) =>
      postJson(kind == 'group' ? '/circle/groups/$id/seen' : '/circle/$id/seen');

  /// Chat-list "Mark as unread" (true) / "Mark as read" (false).
  Future<Map<String, dynamic>> c3MarkUnread(String kind, int id, bool unread) =>
      postJson('/circle/chats/unread',
          {'chat_kind': kind, 'chat_id': id, 'unread': unread});

  /// Sender-only per-recipient delivered/seen times.
  Future<Map<String, dynamic>> c3MessageInfo(String id) =>
      getJson('/circle/messages/$id/info');

  /// Notification window (ciphertext) + delivered ack.
  Future<Map<String, dynamic>> c3NotifyPull(String kind, int id,
          {int limit = 5}) =>
      postJson('/circle/notify/pull',
          {'chat_kind': kind, 'chat_id': id, 'limit': limit});

  // Live presence / typing go through the shared real-time queue
  // (POST /rt/send presence.set / typing.set — RealtimeChannel); only the
  // snapshot stays a c3 endpoint.
  Future<Map<String, dynamic>> c3Presence(bool online) => postJson('/rt/send', {
        'topic': 'presence.set',
        'payload': {'state': online ? 'online' : 'away'}
      });

  Future<Map<String, dynamic>> c3Typing(String kind, int id, String state) =>
      postJson('/rt/send', {
        'topic': 'typing.set',
        'payload': {'chat_kind': kind, 'chat_id': id, 'state': state}
      });

  Future<Map<String, dynamic>> c3RtState({bool online = false}) =>
      getJson(online ? '/circle/rt/state?online=1' : '/circle/rt/state');
}
