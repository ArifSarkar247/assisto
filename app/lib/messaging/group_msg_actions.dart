// gap-circle (17 Nov gap sweep): the group-chat basics every good messenger
// has and our group chat lacked — edit my text inside the window, delete for
// everyone, star from the long-press menu, the quoted reply, the send time
// and "edited" on every text bubble, and a "This message was deleted." line
// instead of an empty bubble. Pure rules here (unit-tested); the screen only
// wires them.

/// Same edit window as the 1:1 chat and the server
/// (core/logic/circle_messaging.EDIT_WINDOW_MIN).
const int kGroupEditWindowMin = 15;

/// Server default delete-for-everyone window (chat_actions.DEFAULT_WINDOW_MIN,
/// 2 days); the server still has the last word (403 → "too late").
const int kGroupDeleteEveryoneWindowMin = 60 * 24 * 2;

DateTime? groupMsgAt(Map<String, dynamic> m) =>
    DateTime.tryParse('${m['created_at'] ?? m['at'] ?? ''}');

bool groupMsgDeleted(Map<String, dynamic> m) =>
    '${m['deleted'] ?? ''}' == 'everyone';

/// A server message (not a local echo / queued / media job).
bool groupMsgOnServer(Map<String, dynamic> m) =>
    int.tryParse('${m['id'] ?? ''}') != null && m['md1_job'] == null;

/// Edit: my own plain text, on the server, not deleted, not view-once,
/// inside the window. [isSpecial] = a card / control line (never editable).
bool groupCanEdit(Map<String, dynamic> m,
    {DateTime? now, bool isSpecial = false}) {
  if (m['mine'] != true || isSpecial) return false;
  if ('${m['content_type'] ?? 'text'}' != 'text') return false;
  if (groupMsgDeleted(m) || m['view_once'] == true) return false;
  if (!groupMsgOnServer(m)) return false;
  final at = groupMsgAt(m);
  if (at == null) return false;
  return (now ?? DateTime.now()).difference(at).inMinutes < kGroupEditWindowMin;
}

/// Delete for everyone: my own message on the server inside the window.
bool groupCanDeleteEveryone(Map<String, dynamic> m,
    {DateTime? now, int windowMin = kGroupDeleteEveryoneWindowMin}) {
  if (m['mine'] != true || groupMsgDeleted(m) || !groupMsgOnServer(m)) {
    return false;
  }
  final at = groupMsgAt(m);
  if (at == null) return false;
  return (now ?? DateTime.now()).difference(at).inMinutes < windowMin;
}

/// The quoted text of the message [m] replies to, resolved from what this
/// phone already has (the server only keeps the id — never the text).
/// Null when [m] is not a reply or the original is not loaded.
String? groupReplyQuote(
  Map<String, dynamic> m,
  List<Map<String, dynamic>> messages,
  String? Function(Map<String, dynamic>) open, {
  required String deletedText,
  required String mediaText,
}) {
  final rid = '${m['reply_to'] ?? ''}';
  if (rid.isEmpty || rid == 'null') return null;
  for (final o in messages) {
    if ('${o['id']}' != rid) continue;
    if (groupMsgDeleted(o)) return deletedText;
    if (o['view_once'] == true) return mediaText;
    final t = (open(o) ?? '').trim();
    if (t.isNotEmpty) return t;
    final kind = '${o['content_type'] ?? 'text'}';
    return kind == 'text' ? null : mediaText;
  }
  return null;
}

/// The new per-recipient envelope body for an edit (ciphertext only).
Map<String, dynamic> groupEditBody(
        Map<String, dynamic> perRecipient, String senderKeyId) =>
    {'per_recipient': perRecipient, 'sender_key_id': senderKeyId};
