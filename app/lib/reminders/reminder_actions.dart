import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../notifications.dart';
import '../widgets/reminders_nlp.dart' show nextOccurrence;
import 'alarm_plan.dart';
import 'reminder_alarms.dart' show ReminderAlarms;

/// remnotes — "Done" and "Snooze 10 min" right on a reminder's notification
/// (Google Keep / Samsung Reminder / TickTick all have them; we had none and
/// a tap only opened the home screen).
///
/// * Works with the app CLOSED: the action lands in the background isolate
///   ([assistoNotificationBackground]); it is recorded in SharedPreferences
///   and, for snooze, a one-shot alarm is set 10 minutes ahead right there
///   (title read from the notification itself — the alarm ledger keeps no
///   titles, by design).
/// * The next time the app runs (start / resume / the foreground tap), the
///   recorded actions are applied to the reminder list ([applyPending]) —
///   a recurring reminder advances to its next time instead of ending —
///   and the stand-in snooze alarm is cancelled (the real alarm takes over,
///   so it never rings twice).
/// * Everything is guarded: a failure never crashes, never loses the
///   reminder (worst case: it stays as it was and rings again).
class ReminderActions {
  ReminderActions._();

  static const done = 'rem_done';
  static const snooze = 'rem_snooze';
  static const pendingKey = 'remnotes_notif_actions_v1';
  static const snoozeMinutes = 10;
  static const _maxPending = 50;

  static bool isOurs(NotificationResponse r) =>
      (r.payload ?? '').startsWith(ReminderAlarms.payloadPrefix);

  static String keyOf(String? payload) {
    final p = payload ?? '';
    return p.startsWith(ReminderAlarms.payloadPrefix)
        ? p.substring(ReminderAlarms.payloadPrefix.length)
        : '';
  }

  /// The stand-in alarm id for a snoozed reminder (never the real alarm's).
  static int snoozeIdFor(String key) => alarmIdFor('snz-$key');

  /// Record a Done / Snooze tap (any isolate). Returns the recorded action
  /// or null (a plain tap / not ours). [plugin] is the background isolate's
  /// own initialised plugin; null = the UI isolate ([Notifications]).
  static Future<String?> record(NotificationResponse r,
      {FlutterLocalNotificationsPlugin? plugin, DateTime? now}) async {
    final key = keyOf(r.payload);
    final a = r.actionId;
    if (key.isEmpty || (a != done && a != snooze)) return null;
    final at = now ?? DateTime.now();
    try {
      String title = '', body = '';
      if (a == snooze) {
        final n = await _active(r.id, plugin);
        title = n?.title ?? '';
        body = n?.body ?? '';
        final when = at.add(const Duration(minutes: snoozeMinutes));
        await _schedule(plugin, snoozeIdFor(key), title, body, when, key);
      }
      if (r.id != null) await _cancel(plugin, r.id!);
      final prefs = await SharedPreferences.getInstance();
      try {
        await prefs.reload();
      } catch (_) {}
      final list = decode(prefs.getString(pendingKey));
      list.add({'a': a, 'k': key, 't': at.millisecondsSinceEpoch});
      while (list.length > _maxPending) {
        list.removeAt(0);
      }
      await prefs.setString(pendingKey, jsonEncode(list));
      return a;
    } catch (e) {
      if (kDebugMode) debugPrint('reminder action failed: $e');
      return null;
    }
  }

  static List<Map<String, dynamic>> decode(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final l = jsonDecode(raw);
      if (l is! List) return [];
      return [
        for (final e in l)
          if (e is Map && e['a'] is String && e['k'] is String && e['t'] is int)
            Map<String, dynamic>.from(e)
      ];
    } catch (_) {
      return [];
    }
  }

  /// The patch that "Done" means for reminder data [d] at [now]: a one-off
  /// is finished; a recurring one moves to its next time and stays open.
  static Map<String, dynamic> donePatch(Map<String, dynamic> d, DateTime now) {
    final rule = ruleOfData(d);
    if (rule == null) return {'done': true};
    final raw = d['due_at'];
    final anchor = raw == null ? null : DateTime.tryParse('$raw')?.toLocal();
    final next = nextOccurrence(anchor ?? now, rule, after: now);
    if (next == null) return {'done': true};
    return {'due_at': next.toUtc().toIso8601String(), 'done': false};
  }

  /// "Snooze" tapped at [tapped]: ring again [snoozeMinutes] later.
  static Map<String, dynamic> snoozePatch(DateTime tapped) => {
        'due_at': tapped
            .add(const Duration(minutes: snoozeMinutes))
            .toUtc()
            .toIso8601String(),
        'done': false,
      };

  /// Apply every recorded action to [items] through [update]; returns how
  /// many were applied. Unknown keys (deleted meanwhile) are dropped.
  static Future<int> applyTo(
    List<Map<String, dynamic>> items,
    Future<void> Function(Map<String, dynamic> item, Map<String, dynamic> patch)
        update, {
    DateTime? now,
  }) async {
    SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      try {
        await prefs.reload();
      } catch (_) {}
    } catch (_) {
      return 0;
    }
    final pending = decode(prefs.getString(pendingKey));
    if (pending.isEmpty) return 0;
    await prefs.remove(pendingKey);
    var n = 0;
    final at = now ?? DateTime.now();
    for (final p in pending) {
      final key = p['k'] as String;
      Map<String, dynamic>? item;
      for (final it in items) {
        if (reminderKeyOf(it) == key) {
          item = it;
          break;
        }
      }
      if (item == null) continue;
      final d = Map<String, dynamic>.from(item['data'] as Map);
      final tapped = DateTime.fromMillisecondsSinceEpoch(p['t'] as int);
      final Map<String, dynamic> patch;
      if (p['a'] == done) {
        patch = donePatch(d, at);
        // Done after a snooze: the stand-in must not ring again
        await Notifications.cancelId(snoozeIdFor(key));
      } else if (ruleOfData(d) != null) {
        // recurring: its schedule stays as it is; the stand-in alarm alone
        // rings in 10 minutes (moving due_at would shift every later day)
        n++;
        continue;
      } else {
        // one-off: the reminder itself moves; the real alarm takes over at
        // the same minute, so drop the stand-in (never rings twice)
        patch = snoozePatch(tapped);
        await Notifications.cancelId(snoozeIdFor(key));
      }
      try {
        await update(item, patch);
        n++;
      } catch (_) {}
    }
    return n;
  }

  // ---------------------------------------------------------------- plugin
  static Future<ActiveNotification?> _active(
      int? id, FlutterLocalNotificationsPlugin? plugin) async {
    if (id == null) return null;
    try {
      final p = plugin ?? FlutterLocalNotificationsPlugin();
      final l = await p
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.getActiveNotifications();
      for (final n in l ?? const <ActiveNotification>[]) {
        if (n.id == id) return n;
      }
    } catch (_) {}
    return null;
  }

  static Future<void> _cancel(FlutterLocalNotificationsPlugin? plugin, int id) async {
    if (plugin == null) return Notifications.cancelId(id);
    try {
      await plugin.cancel(id);
    } catch (_) {}
  }

  static Future<void> _schedule(FlutterLocalNotificationsPlugin? plugin, int id,
      String title, String body, DateTime when, String key) async {
    if (plugin == null) {
      final exact = Notifications.exactAllowedCached ?? await Notifications.canScheduleExact();
      await Notifications.scheduleAlarm(id, title, body, when,
          mode: exact ? AlarmMode.exact : AlarmMode.inexact,
          payload: '${ReminderAlarms.payloadPrefix}$key');
      return;
    }
    try {
      tzdata.initializeTimeZones();
      try {
        tz.setLocalLocation(tz.getLocation('Asia/Dhaka'));
      } catch (_) {}
    } catch (_) {}
    await Notifications.scheduleAlarm(id, title, body, when,
        mode: AlarmMode.exact,
        payload: '${ReminderAlarms.payloadPrefix}$key',
        plugin: plugin);
  }
}
