import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Sound choices for calls (and the message sound c3-msg reads), stored in
/// SharedPreferences so the FCM BACKGROUND isolate can read them too.
///
/// SHARED KEYS (documented for c3-msg — message notifications):
///   snd_msg_uri      message notification sound uri; absent = phone default
///                    notification sound; '' = silent
///   snd_msg_title    its display title
/// Call keys:
///   snd_call_uri               incoming ringtone; absent = phone default
///   snd_call_title
///   snd_call_signature         bool — use the Assisto melody
///   snd_call_signature_uri     content uri of the installed melody
///   snd_call_contact_<chatId>  per-contact ringtone uri (chatId = MY circle
///                              edge id for that person = push `chat_id`)
///   snd_call_contact_title_<chatId>
class CallSoundPrefs {
  CallSoundPrefs._();

  static const msgUri = 'snd_msg_uri';
  static const msgTitle = 'snd_msg_title';
  static const callUri = 'snd_call_uri';
  static const callTitle = 'snd_call_title';
  static const signature = 'snd_call_signature';
  static const signatureUri = 'snd_call_signature_uri';
  static String contactUri(String chatId) => 'snd_call_contact_$chatId';
  static String contactTitle(String chatId) => 'snd_call_contact_title_$chatId';

  /// The ringtone uri to ring for a call from [chatId]: per-contact first,
  /// then the Assisto melody (if chosen + installed), then the user's pick.
  /// null = the phone's DEFAULT ringtone.
  static String? resolveRingtone(SharedPreferences p, String chatId) {
    if (chatId.isNotEmpty) {
      final c = p.getString(contactUri(chatId));
      if (c != null && c.isNotEmpty) return c;
    }
    if (p.getBool(signature) == true) {
      final s = p.getString(signatureUri);
      if (s != null && s.isNotEmpty) return s;
    }
    final u = p.getString(callUri);
    return (u == null || u.isEmpty) ? null : u;
  }

  static Future<String?> ringtoneFor(String chatId) async {
    try {
      return resolveRingtone(await SharedPreferences.getInstance(), chatId);
    } catch (_) {
      return null;
    }
  }

  /// Android notification channels can't change their sound after creation,
  /// so each distinct ringtone gets its own call channel id.
  static String channelIdFor(String? uri) {
    if (uri == null || uri.isEmpty) return 'calls';
    var h = 0x811c9dc5;
    for (final c in utf8.encode(uri)) {
      h ^= c;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return 'calls_${(h & 0x7fffffff).toRadixString(36)}';
  }
}
