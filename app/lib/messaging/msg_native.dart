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

  /// Opens the phone's own notification-sound picker. Returns
  /// {uri, title} or null (cancelled / unavailable). '' uri = "Default".
  static Future<Map<String, String>?> pickSound(String current) async {
    final r = await _call<Map<dynamic, dynamic>>('pickSound', {'current': current});
    if (r == null) return null;
    return {'uri': '${r['uri'] ?? ''}', 'title': '${r['title'] ?? ''}'};
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
}
