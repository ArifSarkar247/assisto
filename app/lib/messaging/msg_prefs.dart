import 'package:shared_preferences/shared_preferences.dart';

import '../calls/call_sound_prefs.dart';

/// c3-msg — device-level message-notification + bubble preferences.
///
/// Stored in SharedPreferences so the FCM background isolate, the
/// notification-action isolate AND the native bubble helper
/// (messaging/BubbleHelper.kt reads `FlutterSharedPreferences`:
/// `flutter.c3_bubbles_on`, `flutter.c3_bubble_chats`) see the same values.
/// Plain strings/bools only (the native side parses them).
class MsgPrefs {
  MsgPrefs._();

  static const kHideContent = 'c3_msg_hide_content';
  static const kBubblesOn = 'c3_bubbles_on';
  static const kBubbleChats = 'c3_bubble_chats'; // "member:12,group:3"
  /// Message sound — the ONE shared key pair (c2-calls' CallSoundPrefs,
  /// picked in Settings → Notifications): absent = the phone's default
  /// notification sound, '' = silent, else a content:// uri.
  static const kSoundUri = CallSoundPrefs.msgUri; // 'snd_msg_uri'
  static const kSoundTitle = CallSoundPrefs.msgTitle; // 'snd_msg_title'

  static Future<SharedPreferences?> _p() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  static Future<bool> hideContent() async =>
      (await _p())?.getBool(kHideContent) ?? false;
  static Future<void> setHideContent(bool v) async =>
      (await _p())?.setBool(kHideContent, v);

  /// Global bubbles switch (default ON — Android still asks the user to allow
  /// bubbles for Assisto / per conversation in its own settings).
  static Future<bool> bubblesOn() async =>
      (await _p())?.getBool(kBubblesOn) ?? true;
  static Future<void> setBubblesOn(bool v) async =>
      (await _p())?.setBool(kBubblesOn, v);

  static Set<String> parseChats(String? raw) => (raw ?? '')
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toSet();

  static Future<Set<String>> bubbleChats() async =>
      parseChats((await _p())?.getString(kBubbleChats));

  static Future<bool> isBubbleChat(String kind, int id) async =>
      (await bubbleChats()).contains('${kind == 'group' ? 'group' : 'member'}:$id');

  static Future<void> setBubbleChat(String kind, int id, bool on) async {
    final p = await _p();
    if (p == null) return;
    final key = '${kind == 'group' ? 'group' : 'member'}:$id';
    final s = parseChats(p.getString(kBubbleChats));
    on ? s.add(key) : s.remove(key);
    await p.setString(kBubbleChats, (s.toList()..sort()).join(','));
  }

  /// null = phone default, '' = silent, else the picked uri.
  static Future<String?> soundUri() async => (await _p())?.getString(kSoundUri);
  static Future<String> soundTitle() async =>
      (await _p())?.getString(kSoundTitle) ?? '';

  /// Android notification channels can't change their sound after creation,
  /// so each sound has its own channel id: 'messages' = phone default (the
  /// original channel), 'messages_silent', or 'messages_<hash of uri>'.
  static String channelIdFor(String? uri) {
    if (uri == null) return 'messages';
    if (uri.isEmpty) return 'messages_silent';
    return CallSoundPrefs.channelIdFor(uri).replaceFirst('calls_', 'messages_');
  }

  static Future<String> channelId() async => channelIdFor(await soundUri());

  /// [uri] null = back to the phone default; '' = silent.
  static Future<void> setSound(String? uri, String title) async {
    final p = await _p();
    if (p == null) return;
    if (uri == null) {
      await p.remove(kSoundUri);
      await p.remove(kSoundTitle);
      return;
    }
    await p.setString(kSoundUri, uri);
    await p.setString(kSoundTitle, title);
  }
}
