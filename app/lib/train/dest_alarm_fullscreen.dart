import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../notifications.dart';
import 'dest_alarm_service.dart';

/// sjtrain (Safe Journey V2, DESTINATION ALARM): when the alarm rings, a
/// full-screen notification wakes the screen and shows the alarm over the
/// LOCK SCREEN — the same per-launch path a Care Call ring uses (MainActivity
/// allows the keyguard only for a launch whose payload kind is "carecall" /
/// "dest_alarm"; nothing in the manifest shows the app on a locked phone).
/// The sound + vibration come from the alarm itself (DestAlarmSound, alarm
/// stream, loud on silent) — this notification is silent so it never
/// competes with it. Never throws (best-effort; the alarm rings anyway).
class DestAlarmFullScreen implements DestRingNotice {
  DestAlarmFullScreen({this.plugin});

  static const int notificationId = 470118;
  static const String kind = 'dest_alarm';
  static const String channelId = 'dest_alarm_ring';
  static const String actionAwake = 'da_awake';

  /// Test seam (null = the app's singleton).
  final FlutterLocalNotificationsPlugin? plugin;

  FlutterLocalNotificationsPlugin get _p => plugin ?? FlutterLocalNotificationsPlugin();

  static String payloadFor(DestPlan plan) =>
      jsonEncode({'kind': kind, 'route': 'dest_alarm', 'stop': plan.target.name});

  /// A tap / full-screen launch of OUR notification (PushService routes it).
  static bool isOurs(NotificationResponse r) {
    try {
      final j = jsonDecode(r.payload ?? '');
      return j is Map && j['kind'] == kind;
    } catch (_) {
      return false;
    }
  }

  static NotificationDetails details(DestAlarmTexts texts) => NotificationDetails(
        android: AndroidNotificationDetails(channelId, texts.notifTitle,
            channelDescription: texts.notifTitle,
            importance: Importance.max,
            priority: Priority.max,
            category: AndroidNotificationCategory.alarm,
            fullScreenIntent: true,
            ongoing: true,
            autoCancel: false,
            playSound: false,
            enableVibration: false,
            visibility: NotificationVisibility.public,
            actions: <AndroidNotificationAction>[
              AndroidNotificationAction(actionAwake, texts.stop,
                  cancelNotification: true, showsUserInterface: true),
            ]),
      );

  @override
  Future<void> show(DestPlan plan, DestAlarmTexts texts) async {
    if (plugin == null && !Notifications.ready) return;
    try {
      await _p.show(notificationId, texts.notifTitle, texts.spoken(plan.target.name, ''),
          details(texts),
          payload: payloadFor(plan));
    } catch (e) {
      if (kDebugMode) debugPrint('dest alarm full screen: $e');
    }
  }

  @override
  Future<void> cancel() async {
    if (plugin == null && !Notifications.ready) return;
    try {
      await _p.cancel(notificationId);
    } catch (_) {}
  }
}
