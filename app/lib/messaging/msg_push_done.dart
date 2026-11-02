import 'package:shared_preferences/shared_preferences.dart';

/// notifs — "Dart handled this message push" marker for the NATIVE safety net.
///
/// Every My Circle message push also reaches the native AssistoFcmService
/// (push/AssistoFcmService.kt → messaging/MessageNotifier.kt). It waits a few
/// seconds; if Dart has neither drawn a notification for that chat nor
/// recorded the message id here (chat open on screen, already read on another
/// device, drawn by the plain fallback…), it draws "<sender>: নতুন মেসেজ"
/// itself — so a cold, blocked or crashing Dart isolate (ColorOS / MIUI) can
/// never lose a message notification.
///
/// Stored in FlutterSharedPreferences as `flutter.c3_push_done` (native reads
/// it): the last [keep] message ids, comma separated. Never throws.
class MsgPushDone {
  MsgPushDone._();

  static const key = 'c3_push_done';
  static const keep = 30;

  /// The new comma list after adding [id] (pure; unit-tested).
  static String add(String? raw, String id) {
    final ids = (raw ?? '')
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && e != id)
        .toList()
      ..add(id);
    final start = ids.length > keep ? ids.length - keep : 0;
    return ids.sublist(start).join(',');
  }

  static Future<void> mark(Map<String, dynamic> data) async {
    try {
      if ('${data['kind'] ?? ''}' != 'message') return;
      final id = '${data['message_id'] ?? ''}'.trim();
      if (id.isEmpty) return;
      final p = await SharedPreferences.getInstance();
      try {
        await p.reload(); // another isolate may have written meanwhile
      } catch (_) {}
      await p.setString(key, add(p.getString(key), id));
    } catch (_) {}
  }
}
