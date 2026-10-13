import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Best-effort device reminders. Everything is wrapped so failures never crash
/// the app — reminders still work in-app/offline without notifications.
class Notifications {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static Future<void> init() async {
    try {
      tzdata.initializeTimeZones();
      try {
        tz.setLocalLocation(tz.getLocation('Asia/Dhaka'));
      } catch (_) {}
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      await _plugin.initialize(const InitializationSettings(android: android));
      final android13 = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android13?.requestNotificationsPermission();
      _ready = true;
    } catch (e) {
      if (kDebugMode) print('notif init failed: $e');
      _ready = false;
    }
  }

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'assisto_reminders', 'Reminders',
      channelDescription: 'Assisto reminders',
      importance: Importance.max, priority: Priority.high,
    ),
  );

  static int idFor(String localId) => localId.hashCode & 0x7fffffff;

  static Future<void> schedule(String localId, String title, String body,
      DateTime whenLocal) async {
    if (!_ready) return;
    try {
      if (whenLocal.isBefore(DateTime.now())) return;
      await _plugin.zonedSchedule(
        idFor(localId), title, body,
        tz.TZDateTime.from(whenLocal, tz.local), _details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
    } catch (e) {
      if (kDebugMode) print('schedule failed: $e');
    }
  }

  static Future<void> cancel(String localId) async {
    if (!_ready) return;
    try {
      await _plugin.cancel(idFor(localId));
    } catch (_) {}
  }

  /// Show a notification immediately (used by the background family poller).
  static Future<void> show(int id, String title, String body) async {
    if (!_ready) return;
    try {
      await _plugin.show(id, title, body, _details);
    } catch (e) {
      if (kDebugMode) print('show failed: $e');
    }
  }
}
