import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// c3-msg — thin, crash-guarded bridge to messaging/C3MessagingChannel.kt
/// (registered by MainActivity and BubbleActivity on the UI engine only).
/// Every call degrades to null/false when the native side is missing (tests,
/// an older build, iOS).
class MsgNative {
  MsgNative._();
  static const _ch = MethodChannel('com.assisto/c3_messaging');

  static Future<T?> _call<T>(String m, [Map<String, dynamic>? a]) async {
    try {
      return await _ch.invokeMethod<T>(m, a);
    } catch (e) {
      if (kDebugMode) debugPrint('c3 native $m: $e');
      return null;
    }
  }

  /// Android 11+ has bubbles; returns false on older phones.
  static Future<bool> bubblesSupported() async =>
      (await _call<bool>('bubblesSupported')) ?? false;

  /// Has the user allowed Assisto to show bubbles (system setting)?
  /// null = unknown.
  static Future<bool?> bubblesAllowed() => _call<bool>('bubblesAllowed');

  /// System page: Settings → Apps → Assisto → Notifications → Bubbles.
  static Future<bool> openBubbleSettings() async =>
      (await _call<bool>('openBubbleSettings')) ?? false;

  /// bubbles2: the raw facts for the "Turn on floating chat bubbles?" card
  /// (see BubbleStatus.fromMap); null when the native side is missing.
  static Future<Map<String, dynamic>?> bubbleStatus() async {
    final r = await _call<Map<Object?, Object?>>('bubbleStatus');
    return r?.map((k, v) => MapEntry('$k', v));
  }

  /// bubbles2: our own active My Circle chat notifications, newest first:
  /// [{key: "member:12", bubble: showing as a bubble now, meta, at}].
  static Future<List<Map<String, dynamic>>> activeChats() async {
    final r = await _call<List<Object?>>('activeChats');
    return (r ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map((m) => m.map((k, v) => MapEntry('$k', v)))
        .toList();
  }

  /// The chat a bubble / conversation shortcut / notification asked to open,
  /// as "member:12" / "group:3" (consumed once), or null.
  static Future<String?> takeLaunchChat() => _call<String>('takeLaunchChat');

  /// True when this engine runs inside a bubble (expanded floating window).
  static Future<bool> inBubble() async => (await _call<bool>('inBubble')) ?? false;

  /// Native → Dart: a conversation shortcut / bubble intent arrived while the
  /// app was already running.
  static void onOpenChat(void Function(String key) cb) {
    try {
      _ch.setMethodCallHandler((call) async {
        if (call.method == 'openChat' && call.arguments is String) {
          cb(call.arguments as String);
        }
        return null;
      });
    } catch (_) {}
  }

  /// Drop a chat's conversation shortcut + bubble (per-chat bubble off).
  static Future<void> removeBubble(String kind, int id) =>
      _call<void>('removeBubble', {'chat': '$kind:$id'});

  /// bubbles: upgrade the conversation notification just drawn in THIS (UI)
  /// isolate to a bubble at once (native re-checks every gate). Background
  /// isolates have no channel — the FCM service schedules those itself.
  static Future<void> attachBubble(String kind, int id, String name) =>
      _call<bool>('attachBubble', {'kind': kind, 'id': id, 'name': name});

  // circlebub ------------------------------------------------------------
  /// The chat was opened / read: while Android shows it as a BUBBLE the
  /// notification is kept (only hidden from the shade) — cancelling it would
  /// remove the bubble. true = kept as a bubble (do NOT cancel it);
  /// false / null (no native side, background isolate, not a bubble) =
  /// cancel as before.
  static Future<bool> clearChat(String kind, int id) async =>
      (await _call<bool>('clearChat', {'kind': kind, 'id': id})) ?? false;

  /// The soft in-app tick for a message in the OPEN chat (native, played as
  /// a notification sound: Android mutes it on silent / DND).
  static Future<bool> playTick() async =>
      (await _call<bool>('playTick')) ?? false;
  // /circlebub ----------------------------------------------------------

  /// bubbles: from the bubble window, open this chat in the full app.
  static Future<bool> openInApp(String kind, int id) async =>
      (await _call<bool>('openInApp', {'chat': '$kind:$id'})) ?? false;

  // ---- md1: My Circle media -------------------------------------------------

  /// Is the active network metered (mobile data / metered Wi-Fi)?
  /// null = unknown (callers treat it as metered: careful with data).
  static Future<bool?> isMetered() => _call<bool>('isMetered');

  /// The phone's own document picker (any file type). The chosen file is
  /// copied into the app cache: {path, name, size, mime}; {error: 'too_big',
  /// size, name} when larger than [maxBytes]; null when cancelled/failed.
  static Future<Map<String, dynamic>?> pickDocument(int maxBytes) async {
    final r = await _call<Map<Object?, Object?>>('pickDocument', {'max': maxBytes});
    return r?.map((k, v) => MapEntry('$k', v));
  }

  /// Save a decrypted file the user chose to keep: photos go to Pictures/
  /// Assisto (gallery), everything else to Download/Assisto. Android 10+;
  /// returns 'ok', 'unsupported' (older phone: use Share) or 'error'.
  static Future<String> saveToPhone(String path, String mime, String name) async =>
      (await _call<String>('saveToPhone', {'path': path, 'mime': mime, 'name': name})) ??
      'error';

  /// mc-media2: {w, h, ms, png} of an app-owned video clip (png = a 32 px
  /// first frame, may be missing); null when the phone can't read it.
  static Future<Map<String, dynamic>?> videoMeta(String path) async {
    final r = await _call<Map<Object?, Object?>>('videoMeta', {'path': path});
    return r?.map((k, v) => MapEntry('$k', v));
  }
}
