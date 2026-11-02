// notifs — Dart MIRROR of the native message safety net's decisions
// (android_overlay/.../messaging/MessageNotifier.kt `specFor` /
// `doneContains`). Kotlin is not compiled in CI checks, so the rules live
// here too and are unit-tested (test/notifs_message_push_test.dart). Keep
// both in sync.
//
// When Dart draws nothing for a message push within a few seconds, the
// native side shows: title = sender name (only when previews are allowed,
// the phone's "hide content" switch is off and the chat is not locked),
// else "Assisto"; text = the c3NotifEncrypted string in the push language
// ("New message" / its Bangla) — never message text (it is end-to-end
// encrypted); Reply only for unlocked chats.
import 'msg_notify.dart' show msgL10n;

typedef FallbackSpec = ({String title, String text, bool canReply});

FallbackSpec fallbackSpec(Map<String, dynamic> data,
    {bool hideContent = false, bool locked = false}) {
  final en = '${data['lang'] ?? ''}' == 'en';
  final hidden = hideContent || locked || '${data['preview'] ?? ''}' == '0';
  final name = '${data['sender_name'] ?? ''}'.trim();
  return (
    title: (hidden || name.isEmpty) ? 'Assisto' : name,
    text: msgL10n(en ? 'en' : 'bn').c3NotifEncrypted,
    canReply: !locked,
  );
}

/// Did Dart record [messageId] as handled (`flutter.c3_push_done`)?
bool fallbackDoneContains(String? raw, String messageId) =>
    messageId.isNotEmpty &&
    (raw ?? '').split(',').any((e) => e.trim() == messageId);
