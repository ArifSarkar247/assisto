import 'package:shared_preferences/shared_preferences.dart';

/// circlebub (owner 3 Nov, part B) — "this chat is OPEN inside its expanded
/// bubble right now", shared across Flutter engines (the bubble runs its own
/// engine; the main app's push handler runs in another).
///
/// Why: a new message for that chat used to be re-drawn by the main app's
/// notification code WITHOUT bubble data, and Android then dropped the
/// expanded bubble mid-reading. While this mark is fresh, the push handler
/// skips the redraw (the open bubble chat shows the message itself) and only
/// plays the soft in-app tick.
///
/// A TIME, never a stuck flag: the bubble refreshes it every [refresh] while
/// visible; a crash or kill can hide notifications for at most [ttl].
class BubbleOpenMark {
  BubbleOpenMark._();

  static const kKey = 'c3_bubble_open_chat';
  static const ttl = Duration(seconds: 45);
  static const refresh = Duration(seconds: 20);

  /// Stored value "member:12|<epoch ms until>".
  static String encode(String chatKey, DateTime until) =>
      '$chatKey|${until.millisecondsSinceEpoch}';

  /// Is [chatKey] open in a bubble at [now] according to [raw]? (pure)
  static bool isOpenIn(String? raw, String chatKey, DateTime now) {
    if (raw == null || raw.isEmpty) return false;
    final i = raw.lastIndexOf('|');
    if (i <= 0) return false;
    if (raw.substring(0, i) != chatKey) return false;
    final until = int.tryParse(raw.substring(i + 1)) ?? 0;
    final left = until - now.millisecondsSinceEpoch;
    // a far-future value (clock change / tampering) never counts
    return left > 0 && left <= ttl.inMilliseconds;
  }

  static Future<void> mark(String chatKey, {DateTime? now}) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(kKey, encode(chatKey, (now ?? DateTime.now()).add(ttl)));
    } catch (_) {}
  }

  static Future<void> clear(String chatKey) async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(kKey) ?? '';
      if (raw.startsWith('$chatKey|')) await p.remove(kKey);
    } catch (_) {}
  }

  /// Fresh read (another engine wrote it). Never throws.
  static Future<bool> isOpen(String chatKey, {DateTime? now}) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.reload();
      return isOpenIn(p.getString(kKey), chatKey, now ?? DateTime.now());
    } catch (_) {
      return false;
    }
  }
}
