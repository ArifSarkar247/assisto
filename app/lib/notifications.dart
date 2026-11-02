import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'l10n/app_localizations.dart';
import 'push/push_notifier.dart' show assistoNotificationBackground;
import 'reminders/alarm_plan.dart' show AlarmMode, AlarmRepeat;

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
      const android = AndroidInitializationSettings('@drawable/ic_stat_assisto');
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
      unawaited(canScheduleExact());
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
      category: AndroidNotificationCategory.reminder,
    ),
  );

  // remnotes: reminder alarms carry "Done" / "Snooze 10 min" buttons in the
  // app's language (AppState sets it before each reconcile). Neither opens
  // the app: they land in the background isolate when it is closed
  // (reminders/reminder_actions.dart). Ids must match ReminderActions.
  static String actionLang = 'bn';
  static const reminderPayloadPrefix = 'remalarm:';
  static const actionDone = 'rem_done';
  static const actionSnooze = 'rem_snooze';

  @visibleForTesting
  static NotificationDetails detailsFor(String? payload) {
    if (!(payload ?? '').startsWith(reminderPayloadPrefix)) return _details;
    AppLocalizations t;
    try {
      t = lookupAppLocalizations(Locale(actionLang == 'en' ? 'en' : 'bn'));
    } catch (_) {
      t = lookupAppLocalizations(const Locale('en'));
    }
    return NotificationDetails(
      android: AndroidNotificationDetails(
        'assisto_reminders', 'Reminders',
        channelDescription: 'Assisto reminders',
        importance: Importance.max, priority: Priority.high,
        category: AndroidNotificationCategory.reminder,
        actions: <AndroidNotificationAction>[
          AndroidNotificationAction(actionDone, t.rnNotifDone,
              cancelNotification: false, showsUserInterface: false),
          AndroidNotificationAction(actionSnooze, t.rnNotifSnooze10,
              cancelNotification: false, showsUserInterface: false),
        ],
      ),
    );
  }

  static int idFor(String localId) => localId.hashCode & 0x7fffffff;

  /// Whether local scheduling is up (false in tests / when init failed).
  static bool get ready => _ready;

  // remmeter: exact alarms. Android 12+ needs the user-granted "Alarms &
  // reminders" special access (SCHEDULE_EXACT_ALARM; on Android 14+ it is
  // OFF by default for new installs). We never declare USE_EXACT_ALARM
  // (Play: alarm-clock / calendar apps only). Cached; refreshed on init and
  // whenever [canScheduleExact] is asked.
  static bool? _exactAllowed;

  /// Last known exact-alarm permission (null = not asked yet / unknown).
  static bool? get exactAllowedCached => _exactAllowed;

  /// True below Android 12 (always allowed there). Never throws; unknown ->
  /// false so we pick the honest inexact path instead of a throwing one.
  static Future<bool> canScheduleExact() async {
    if (!_ready) return _exactAllowed ?? false;
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android == null) return _exactAllowed = false;
      final v = await android.canScheduleExactNotifications();
      return _exactAllowed = v ?? false;
    } catch (e) {
      if (kDebugMode) print('canScheduleExact failed: $e');
      return _exactAllowed = false;
    }
  }

  /// Opens Android's "Alarms & reminders" page for Assisto (Android 12+).
  /// Returns whether exact alarms are allowed afterwards. Guarded.
  static Future<bool> requestExact() async {
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.requestExactAlarmsPermission();
    } catch (e) {
      if (kDebugMode) print('requestExact failed: $e');
    }
    return canScheduleExact();
  }

  static AndroidScheduleMode _androidMode(AlarmMode m) => switch (m) {
        AlarmMode.alarm => AndroidScheduleMode.alarmClock,
        AlarmMode.exact => AndroidScheduleMode.exactAllowWhileIdle,
        AlarmMode.inexact => AndroidScheduleMode.inexactAllowWhileIdle,
      };

  /// Schedule one alarm by numeric id in [mode]; if the OS refuses the exact
  /// path (permission revoked meanwhile) it falls back to inexact. Returns
  /// the mode actually used, or null when nothing could be scheduled.
  static Future<AlarmMode?> scheduleAlarm(int id, String title, String body,
      DateTime whenLocal,
      {AlarmMode mode = AlarmMode.exact,
      AlarmRepeat repeat = AlarmRepeat.none,
      String? payload,
      FlutterLocalNotificationsPlugin? plugin}) async {
    // remnotes: [plugin] = the background isolate's own initialised plugin
    // (a notification "Snooze" while the app is closed).
    final pl = plugin ?? _plugin;
    if (plugin == null && !_ready) return null;
    if (!whenLocal.isAfter(DateTime.now())) return null;
    final match = switch (repeat) {
      AlarmRepeat.daily => DateTimeComponents.time,
      AlarmRepeat.weekly => DateTimeComponents.dayOfWeekAndTime,
      AlarmRepeat.none => null,
    };
    for (final m in mode == AlarmMode.inexact
        ? const [AlarmMode.inexact]
        : [mode, AlarmMode.inexact]) {
      try {
        await pl.zonedSchedule(
          id, title, body.isEmpty ? null : body,
          tz.TZDateTime.from(whenLocal, tz.local), detailsFor(payload),
          androidScheduleMode: _androidMode(m),
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
          matchDateTimeComponents: match,
          payload: payload,
        );
        if (m == AlarmMode.inexact && mode != AlarmMode.inexact) {
          _exactAllowed = false;
        }
        return m;
      } catch (e) {
        if (kDebugMode) print('scheduleAlarm($m) failed: $e');
      }
    }
    return null;
  }

  /// Generic one-shot used by bills, birthdays, meetings, subscriptions...
  /// Exact when the phone allows it, honest inexact otherwise.
  static Future<void> schedule(String localId, String title, String body,
      DateTime whenLocal) async {
    if (!_ready) return;
    try {
      if (whenLocal.isBefore(DateTime.now())) return;
      final exact = _exactAllowed ?? await canScheduleExact();
      await scheduleAlarm(idFor(localId), title, body, whenLocal,
          mode: exact ? AlarmMode.exact : AlarmMode.inexact);
    } catch (e) {
      if (kDebugMode) print('schedule failed: $e');
    }
  }

  /// Ids the OS still holds for us (null = unknown). Guarded.
  static Future<Set<int>?> pendingIds() async {
    if (!_ready) return null;
    try {
      final l = await _plugin.pendingNotificationRequests();
      return {for (final r in l) r.id};
    } catch (_) {
      return null;
    }
  }

  /// Pending requests (id + title + payload) — the one-time migration of
  /// old `localId.hashCode` reminder alarms needs the titles. Guarded.
  static Future<List<PendingNotificationRequest>> pending() async {
    if (!_ready) return const [];
    try {
      return await _plugin.pendingNotificationRequests();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> cancelId(int id) async {
    if (!_ready) return;
    try {
      await _plugin.cancel(id);
    } catch (_) {}
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
