/// bubbles (owner 2 Nov, part B) — WHEN a My Circle message notification
/// becomes a floating chat bubble (official Android Bubbles API, 11+).
///
/// This is the Dart MIRROR of `BubbleHelper.shouldAttach` in
/// android_overlay/.../messaging/BubbleHelper.kt (Kotlin is only compiled by
/// the daily APK build, so the rule is pinned here by tests). Keep the two
/// in step: same keys, same order of checks.
///
/// Do Not Disturb, the phone's own "allow bubbles" setting and drag-to-dismiss
/// are NOT checked here — Android applies them itself after we attach
/// BubbleMetadata. Android 10 and below: never (normal notification only).
class BubblePolicy {
  BubblePolicy._();

  /// Android 11 = API 30 (Build.VERSION_CODES.R).
  static const int minSdk = 30;

  /// "member:12" / "group:3" — the one chat key shared with Kotlin.
  static String chatKey(String kind, int id) =>
      '${kind == 'group' ? 'group' : 'member'}:$id';

  static Set<String> parse(String? raw) => (raw ?? '')
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toSet();

  /// Per-chat switch: every chat is ON unless the user turned it off.
  static bool chatOn(String key, Set<String> offChats) =>
      !offChats.contains(key);

  /// The whole decision. [globalOn] null = never set = ON (owner default).
  /// [locked] = the chat is locked (no name may leave the app);
  /// [hideContent] = "hide message content" privacy mode is on;
  /// [hasShortcut] = the notification carries a conversation shortcut id
  /// (Dart leaves it out for locked chats — Kotlin checks the same).
  static bool shouldAttach({
    required int sdkInt,
    required String kind,
    required int id,
    bool? globalOn,
    Set<String> offChats = const {},
    bool locked = false,
    bool hideContent = false,
    bool hasShortcut = true,
  }) {
    if (sdkInt < minSdk) return false;
    if (id <= 0) return false;
    if (globalOn == false) return false;
    if (locked || hideContent || !hasShortcut) return false;
    return chatOn(chatKey(kind, id), offChats);
  }
}
