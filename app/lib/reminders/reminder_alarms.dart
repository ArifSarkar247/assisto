import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notifications.dart';
import 'alarm_plan.dart';

/// remmeter — keeps the phone's reminder alarms in step with the reminder
/// list (see alarm_plan.dart for what was wrong and the pure rules).
///
/// * [request] — called whenever the reminders repo changes (AppState
///   listener) and on app start / resume. Coalesced to one run per burst
///   with a microtask (no Timer: widget tests never see a pending timer).
/// * [onReminderPush] — the server's backup push asks "did the local alarm
///   already ring?" (works in the background push isolate too).
/// * [measure] — on resume, reads when our reminder notifications were
///   really POSTED (native StatusBarNotification.postTime) and logs
///   scheduled-vs-fired lateness. Local only; no titles stored.
class ReminderAlarms {
  ReminderAlarms._();

  static const ledgerKey = 'remmeter_alarm_ledger_v1';
  static const logKey = 'remmeter_delivery_log_v1';
  static const legacyKey = 'remmeter_legacy_migrated_v1'; // gitleaks:allow (prefs key)
  static const askedKey = 'remmeter_exact_asked_ms';
  static const payloadPrefix = 'remalarm:';

  static bool _queued = false;
  static bool _running = false;
  static List<Map<String, dynamic>> Function()? _source;

  /// Ask for a reconcile soon (coalesced). Never throws.
  static void request(List<Map<String, dynamic>> Function() items) {
    _source = items;
    if (_queued) return;
    _queued = true;
    scheduleMicrotask(() async {
      _queued = false;
      final src = _source;
      if (src == null) return;
      try {
        await reconcile(src());
      } catch (e) {
        if (kDebugMode) debugPrint('reminder reconcile failed: $e');
      }
    });
  }

  /// Bring the OS alarms in line with [items]. Safe to call often.
  static Future<void> reconcile(List<Map<String, dynamic>> items,
      {DateTime? now}) async {
    if (!Notifications.ready || _running) return;
    _running = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final exact = await Notifications.canScheduleExact();
      final ledger = decodeLedger(prefs.getString(ledgerKey));
      final plans = planReminderAlarms(items, now: now ?? DateTime.now());
      await _migrateLegacy(prefs, items);
      final ops = diffAlarms(
        plans: plans,
        ledger: ledger,
        exactAllowed: exact,
        pendingIds: await Notifications.pendingIds(),
      );
      if (ops.isEmpty) return;
      for (final id in ops.cancel) {
        await Notifications.cancelId(id);
        ledger.remove(id);
      }
      for (final p in ops.schedule) {
        final want = modeFor(p, exactAllowed: exact);
        final used = await Notifications.scheduleAlarm(
            p.id, p.title, p.body, p.at,
            mode: want, repeat: p.repeat, payload: '$payloadPrefix${p.key}');
        if (used == null) {
          ledger.remove(p.id);
          continue;
        }
        ledger[p.id] = LedgerEntry(
          key: p.key,
          at: p.at.millisecondsSinceEpoch,
          mode: used,
          repeat: p.repeat,
          sig: p.sig(used),
        );
      }
      await prefs.setString(ledgerKey, encodeLedger(ledger));
    } finally {
      _running = false;
    }
  }

  /// Builds before remmeter keyed reminder alarms by `localId.hashCode`.
  /// Once: cancel those (by id, and by matching title for alarms whose
  /// localId has since changed to `srv-<id>`), so nobody gets the old copy
  /// AND the new one.
  static Future<void> _migrateLegacy(
      SharedPreferences prefs, List<Map<String, dynamic>> items) async {
    if (prefs.getBool(legacyKey) == true || items.isEmpty) return;
    final titles = <String>{};
    for (final it in items) {
      final lid = it['localId'];
      if (lid is String) await Notifications.cancelId(Notifications.idFor(lid));
      final d = it['data'];
      if (d is Map) {
        final t = '${d['title'] ?? ''}'.trim();
        if (t.isNotEmpty) titles.add(t);
      }
    }
    for (final r in await Notifications.pending()) {
      final ours = (r.payload ?? '').startsWith(payloadPrefix);
      if (!ours && (r.payload ?? '').isEmpty && titles.contains(r.title)) {
        await Notifications.cancelId(r.id);
      }
    }
    await prefs.setBool(legacyKey, true);
  }

  // ------------------------------------------------------------ push dedupe
  /// Decide what to do with a server reminder push. Runs in the UI isolate
  /// or the background push isolate. Any failure -> [PushDecision.show]
  /// (a reminder is never silently lost).
  static Future<PushDecision> onReminderPush(Map<String, String> data,
      {FlutterLocalNotificationsPlugin? plugin}) async {
    try {
      final rid = data['reminder_id'] ?? '';
      if (rid.isEmpty) return PushDecision.show;
      final key = 'rem-$rid';
      final id = alarmIdFor(key);
      final fireIso = data['fire_at'] ?? data['due_at'] ?? '';
      final fireMs = DateTime.tryParse(fireIso)?.millisecondsSinceEpoch;
      final prefs = await SharedPreferences.getInstance();
      try {
        await prefs.reload(); // the UI isolate may have written since
      } catch (_) {}
      final entry = decodeLedger(prefs.getString(ledgerKey))[id];
      bool? pending;
      try {
        final l = await (plugin ?? FlutterLocalNotificationsPlugin())
            .pendingNotificationRequests();
        pending = l.any((r) => r.id == id);
      } catch (_) {
        pending = null;
      }
      final d = decideReminderPush(
          entry: entry, fireMs: fireMs, pending: pending);
      if (d == PushDecision.showAndCancelLocal && entry != null) {
        try {
          await (plugin ?? FlutterLocalNotificationsPlugin()).cancel(id);
        } catch (_) {}
        await _logSample(
            prefs,
            DeliverySample(
              scheduledMs: entry.at,
              observedMs: DateTime.now().millisecondsSinceEpoch,
              source: 'push',
              mode: entry.mode,
              lowerBound: true,
            ));
        final l = decodeLedger(prefs.getString(ledgerKey))..remove(id);
        await prefs.setString(ledgerKey, encodeLedger(l));
      }
      return d;
    } catch (_) {
      return PushDecision.show;
    }
  }

  // ------------------------------------------------------------ lateness
  static const _oem = MethodChannel('com.assisto/oem_guide');

  /// Foreground only: compare each delivered reminder notification's real
  /// post time with the time we scheduled it for. Guarded, cheap.
  static Future<void> measure() async {
    if (!Notifications.ready) return;
    try {
      final raw = await _oem.invokeMethod<Map>('activePostTimes');
      if (raw == null || raw.isEmpty) return;
      final prefs = await SharedPreferences.getInstance();
      final ledger = decodeLedger(prefs.getString(ledgerKey));
      // the Delivery check's 1-minute test alarm counts too
      final test = LedgerEntry.fromJson(
          _tryJson(prefs.getString(testKey)));
      if (test != null) ledger[alarmIdFor('remtest')] = test;
      final fresh = <DeliverySample>[];
      final seen = (prefs.getStringList('${logKey}_seen') ?? const <String>[])
          .toSet();
      raw.forEach((k, v) {
        final id = k is int ? k : int.tryParse('$k');
        final post = v is int ? v : int.tryParse('$v');
        final e = id == null ? null : ledger[id];
        if (e == null || post == null || e.repeat != AlarmRepeat.none) return;
        final tag = '$id@${e.at}';
        if (seen.contains(tag) || post < e.at - 60000) return;
        seen.add(tag);
        fresh.add(DeliverySample(
            scheduledMs: e.at, observedMs: post, source: 'local', mode: e.mode));
      });
      for (final s in fresh) {
        await _logSample(prefs, s);
      }
      if (fresh.isNotEmpty) {
        final keep = seen.toList();
        await prefs.setStringList('${logKey}_seen',
            keep.length > 80 ? keep.sublist(keep.length - 80) : keep);
      }
    } catch (_) {}
  }

  static const testKey = 'remmeter_test_alarm_v1';

  static dynamic _tryJson(String? s) {
    try {
      return s == null ? null : jsonDecode(s);
    } catch (_) {
      return null;
    }
  }

  /// Remember the Delivery check's test alarm so [measure] can time it.
  static Future<void> rememberTest(DateTime at, AlarmMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          testKey,
          jsonEncode(LedgerEntry(
                  key: 'remtest',
                  at: at.millisecondsSinceEpoch,
                  mode: mode,
                  repeat: AlarmRepeat.none,
                  sig: '')
              .toJson()));
    } catch (_) {}
  }

  static Future<void> _logSample(
      SharedPreferences prefs, DeliverySample s) async {
    try {
      final log = loadLog(prefs);
      await prefs.setString(logKey,
          jsonEncode([for (final x in appendSample(log, s)) x.toJson()]));
    } catch (_) {}
  }

  static List<DeliverySample> loadLog(SharedPreferences prefs) {
    try {
      final j = jsonDecode(prefs.getString(logKey) ?? '[]');
      if (j is! List) return [];
      return [
        for (final x in j)
          if (DeliverySample.fromJson(x) case final s?) s,
      ];
    } catch (_) {
      return [];
    }
  }

  // ------------------------------------------------------------ asking
  /// Whether to show the "allow exact alarms" explanation now: only when
  /// exact is NOT allowed and we have not asked in the last 3 days.
  static Future<bool> shouldExplainExact({DateTime? now}) async {
    if (!Notifications.ready) return false;
    if (await Notifications.canScheduleExact()) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getInt(askedKey) ?? 0;
      final t = (now ?? DateTime.now()).millisecondsSinceEpoch;
      return t - last > const Duration(days: 3).inMilliseconds;
    } catch (_) {
      return true;
    }
  }

  static Future<void> markExplained() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(askedKey, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }
}
