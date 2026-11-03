import 'package:shared_preferences/shared_preferences.dart';

import '../calls/call_sound_prefs.dart';
import 'bubble_policy.dart';
import 'msg_channel.dart'; // circlebub

/// c3-msg — device-level message-notification + bubble preferences.
///
/// Stored in SharedPreferences so the FCM background isolate, the
/// notification-action isolate AND the native bubble helper
/// (messaging/BubbleHelper.kt reads `FlutterSharedPreferences`:
/// `flutter.c3_bubbles_on`, `flutter.c3_bubble_off_chats`,
/// `flutter.c3_msg_hide_content`) see the same values.
/// Plain strings/bools only (the native side parses them).
class MsgPrefs {
  MsgPrefs._();

  static const kHideContent = 'c3_msg_hide_content';
  static const kBubblesOn = 'c3_bubbles_on';
  /// Chats whose bubble the user turned OFF ("member:12,group:3").
  static const kBubbleOffChats = 'c3_bubble_off_chats';
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

  static Set<String> parseChats(String? raw) => BubblePolicy.parse(raw);

  /// bubbles (owner 2 Nov): EVERY chat bubbles by default; this is the list
  /// of chats the user turned OFF ("member:12,group:3"). The old opt-in list
  /// (`c3_bubble_chats`) is no longer read — opted-in chats stay on anyway.
  static Future<Set<String>> bubbleOffChats() async =>
      parseChats((await _p())?.getString(kBubbleOffChats));

  static Future<bool> isBubbleChat(String kind, int id) async =>
      BubblePolicy.chatOn(BubblePolicy.chatKey(kind, id), await bubbleOffChats());

  static Future<void> setBubbleChat(String kind, int id, bool on) async {
    final p = await _p();
    if (p == null) return;
    final key = BubblePolicy.chatKey(kind, id);
    final s = parseChats(p.getString(kBubbleOffChats));
    on ? s.remove(key) : s.add(key);
    await p.setString(kBubbleOffChats, (s.toList()..sort()).join(','));
  }

  /// "Turn all back on" (My Circle → Settings → Notifications).
  static Future<void> clearBubbleOffChats() async =>
      (await _p())?.setString(kBubbleOffChats, '');

  /// null = phone default, '' = silent, else the picked uri.
  static Future<String?> soundUri() async => (await _p())?.getString(kSoundUri);
  static Future<String> soundTitle() async =>
      (await _p())?.getString(kSoundTitle) ?? '';

  /// Android notification channels can't change their sound after creation,
  /// so each sound has its own channel id: MsgChannel.id = Assisto's own pop
  /// (circlebub; replaced the old 'messages' = phone default channel),
  /// 'messages_silent', or 'messages_<hash of uri>'.
  static String channelIdFor(String? uri) {
    if (uri == null) return MsgChannel.id; // circlebub: Assisto pop
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
