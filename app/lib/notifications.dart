import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'push/push_notifier.dart' show assistoNotificationBackground;

/// Best-effort device reminders. Everything is wrapped so failures never crash
/// the app — reminders still work in-app/offline without notifications.
class Notifications {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  /// Set by PushService: called for every tap / action on our notifications.
  static void Function(NotificationResponse r)? onResponse;

  /// The tap/action that cold-started the app, if any (consumed by
  /// PushService once it is ready to navigate). Guarded.
  static Future<NotificationResponse?> launchResponse() async {
    try {
      final d = await _plugin.getNotificationAppLaunchDetails();
      if (d != null && d.didNotificationLaunchApp) {
        return d.notificationResponse;
      }
    } catch (_) {}
    return null;
  }

  static Future<void> init() async {
    try {
      tzdata.initializeTimeZones();
      try {
        tz.setLocalLocation(tz.getLocation('Asia/Dhaka'));
      } catch (_) {}
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      await _plugin.initialize(
        const InitializationSettings(android: android),
        // Push taps/actions (calls: Accept/Decline). PushService sets
        // [onResponse]; Decline with the app closed goes to the background
        // entry point instead.
        onDidReceiveNotificationResponse: (r) {
          try {
            onResponse?.call(r);
          } catch (_) {}
        },
        onDidReceiveBackgroundNotificationResponse:
            assistoNotificationBackground,
      );
      // POST_NOTIFICATIONS (Android 13+) is NOT requested here any more — the
      // cold-start path stays prompt-free. PushService asks once after
      // sign-in; Reminders/Settings offer it again when it is off.
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

  /// Whether the OS currently permits us to post notifications. On Android 13+
  /// (POST_NOTIFICATIONS runtime permission — Realme/ColorOS, Xiaomi, …) a user
  /// who denied the prompt gets NO reminders; the UI uses this to warn them.
  /// On Android<13 and iOS the permission is effectively auto-granted, so this
  /// returns true there. Fully guarded — never throws; on any query failure we
  /// assume enabled so we never nag a user we can't actually diagnose (e.g. in
  /// a test/gallery environment where the platform channel is absent).
  static Future<bool> isEnabled() async {
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android != null) {
        final enabled = await android.areNotificationsEnabled();
        if (enabled != null) return enabled;
      }
      // Fallback (and iOS): permission_handler's unified status. `isDenied`
      // only ever returns true where a runtime prompt exists (Android 13+).
      final status = await Permission.notification.status;
      if (status.isGranted || status.isLimited || status.isProvisional) {
        return true;
      }
      if (status.isPermanentlyDenied || status.isDenied) return false;
      return true;
    } catch (e) {
      if (kDebugMode) print('notif isEnabled failed: $e');
      return true; // degrade gracefully: never show a banner we can't justify
    }
  }

  /// Re-prompt for the notification permission (Android 13+). Returns whether it
  /// is granted afterwards. Guarded — never throws.
  static Future<bool> requestPermission() async {
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.requestNotificationsPermission();
      // Re-check through the same path we query with, so callers get the truth
      // regardless of which layer actually granted it.
      final granted = await isEnabled();
      _ready = _ready || granted;
      return granted;
    } catch (e) {
      if (kDebugMode) print('notif requestPermission failed: $e');
      return false;
    }
  }

  /// Open the OS app-settings page so the user can flip notifications on when
  /// the runtime prompt can no longer be shown (permanently denied). Guarded.
  static Future<void> openSettings() async {
    try {
      await openAppSettings();
    } catch (e) {
      if (kDebugMode) print('notif openSettings failed: $e');
    }
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
