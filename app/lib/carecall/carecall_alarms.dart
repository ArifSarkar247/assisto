import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../config.dart';
import '../l10n/app_localizations.dart';
import '../notifications.dart';
import '../push/push_payload.dart';
import '../security/secret_store.dart';
import 'carecall_api.dart';
import 'carecall_plan.dart';

/// carecall — the receiver phone's side of Care Call, all guarded (never
/// throws, never blocks app start; no WorkManager, no new native code):
///
///  * [CareCallSync.run] (app open / resume, Care Call screen): flushes the
///    offline answer queue, reads the schedules, downloads the setter's
///    voice clip once (so a ring plays it even with no internet) and keeps
///    the phone's OWN alarms in step ([CareCallAlarms.reconcile]).
///  * The alarms are flutter_local_notifications zonedSchedule (AlarmManager
///    setAlarmClock when exact alarms are allowed — never deferred by Doze /
///    OEM battery savers; the honest inexact path otherwise). The plugin's
///    ScheduledNotificationBootReceiver re-arms them after a reboot or an
///    app update (android.yml manifest patch), so a Care Call rings after a
///    restart without the app being opened.
///  * The server's "carecall" push and the local alarm can both arrive for
///    one ring: [CareCallAlarms.onPush] keeps exactly one.
///  * Done / "Remind me in 10 minutes" — from the ring screen or right on
///    the notification (background isolate) — are recorded at once
///    ([CareCallActions.answer]), the slot's other alarms are cancelled, and
///    the answer is sent now or queued until the phone is online.
class CareCallAlarms {
  CareCallAlarms._();

  static const ledgerKey = 'carecall_alarm_ledger_v1';
  static const handledKey = 'carecall_handled_v1';
  static const actionDone = 'cc_done';
  static const actionSnooze = 'cc_snooze';
  static const _flagInsistent = 4;

  /// Test hook: the plugin (null = the app's singleton).
  @visibleForTesting
  static FlutterLocalNotificationsPlugin? debugPlugin;

  static FlutterLocalNotificationsPlugin get _plugin =>
      debugPlugin ?? FlutterLocalNotificationsPlugin();

  static AppLocalizations _t(String lang) {
    try {
      return lookupAppLocalizations(Locale(lang == 'en' ? 'en' : 'bn'));
    } catch (_) {
      return lookupAppLocalizations(const Locale('en'));
    }
  }

  /// The ring's notification: call-style, full-screen (lock screen too),
  /// rings like a call until answered or 60 s pass, with Done / Snooze.
  static NotificationDetails details(String lang) {
    final t = _t(lang);
    return NotificationDetails(
      android: AndroidNotificationDetails(PushChannels.calls, t.pushChCalls,
          channelDescription: t.pushChCallsDesc,
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.call,
          fullScreenIntent: true,
          ongoing: true,
          autoCancel: false,
          timeoutAfter: 60000,
          visibility: NotificationVisibility.public,
          audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
          additionalFlags: Int32List.fromList(const [_flagInsistent]),
          actions: <AndroidNotificationAction>[
            AndroidNotificationAction(actionSnooze, t.ccRingSnooze,
                cancelNotification: true, showsUserInterface: false),
            AndroidNotificationAction(actionDone, t.ccRingDone,
                cancelNotification: true, showsUserInterface: false),
          ]),
    );
  }

  // ------------------------------------------------------------ ledger
  static Map<String, dynamic> _ledger(SharedPreferences p) {
    try {
      final j = jsonDecode(p.getString(ledgerKey) ?? '{}');
      return j is Map<String, dynamic> ? j : {};
    } catch (_) {
      return {};
    }
  }

  static Map<String, int> _handled(SharedPreferences p, {DateTime? now}) {
    try {
      final j = jsonDecode(p.getString(handledKey) ?? '{}') as Map<String, dynamic>;
      final cut = (now ?? DateTime.now()).subtract(const Duration(days: 3)).millisecondsSinceEpoch;
      return {for (final e in j.entries) if ((e.value as num) > cut) e.key: (e.value as num).toInt()};
    } catch (_) {
      return {};
    }
  }

  static Future<bool> isHandled(String slotKey) async {
    try {
      final p = await SharedPreferences.getInstance();
      return _handled(p).containsKey(slotKey);
    } catch (_) {
      return false;
    }
  }

  static Future<void> markHandled(String slotKey) async {
    try {
      final p = await SharedPreferences.getInstance();
      final h = _handled(p)..[slotKey] = DateTime.now().millisecondsSinceEpoch;
      await p.setString(handledKey, jsonEncode(h));
    } catch (_) {}
  }

  // ------------------------------------------------------------ schedule
  /// Bring the phone's own Care Call alarms in line with [received].
  static Future<int> reconcile(List<CcItem> received, {required String lang, DateTime? now}) async {
    if (!Notifications.ready && debugPlugin == null) return 0;
    try {
      final p = await SharedPreferences.getInstance();
      final ledger = _ledger(p);
      final plan = ccPlanLocal(received, now ?? DateTime.now(),
          handled: _handled(p).keys.toSet());
      final want = {for (final r in plan) '${r.id}': r};
      // cancel what is no longer planned (edited / stopped / answered). An
      // alarm whose time has PASSED is never cancelled here (that would
      // dismiss a ring on screen): it stays 30 min for the push de-dup.
      final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
      for (final id in ledger.keys.toList()) {
        final e = ledger[id] as Map? ?? const {};
        final at = (e['at'] as num? ?? 0).toInt();
        if (at <= nowMs) {
          if (at < nowMs - 30 * 60000) ledger.remove(id);
          continue;
        }
        if ((e['k'] ?? '') == 'snooze') continue; // a snooze ring stays until it rings
        if (!want.containsKey(id)) {
          await _cancel(int.tryParse(id) ?? 0);
          ledger.remove(id);
        }
      }
      final exact = await Notifications.canScheduleExact();
      // remhbar lesson: an OEM cleaner / force-stop can drop alarms; one
      // that is in the ledger but no longer pending is put back.
      Set<int>? pending;
      try {
        pending = {for (final q in await _plugin.pendingNotificationRequests()) q.id};
      } catch (_) {}
      var n = 0;
      for (final r in plan) {
        final sig = '${r.at.millisecondsSinceEpoch}|${PushPayload.stableHash(r.item.text)}|${r.item.voiceRev}|${r.item.otherName}|$lang';
        final old = ledger['${r.id}'] as Map?;
        if (old != null && old['sig'] == sig && (pending == null || pending.contains(r.id))) continue;
        final ok = await _schedule(r.id, ccRingData(r.item, r.slot, r.attempt, lang: lang), r.at,
            lang: lang, exact: exact);
        if (ok) {
          ledger['${r.id}'] = {'sig': sig, 'at': r.at.millisecondsSinceEpoch, 'sk': r.slotKey, 'k': 'ring'};
          n++;
        }
      }
      await p.setString(ledgerKey, jsonEncode(ledger));
      return n;
    } catch (e) {
      if (kDebugMode) debugPrint('carecall reconcile failed: $e');
      return 0;
    }
  }

  static Future<bool> _schedule(int id, Map<String, String> data, DateTime at,
      {required String lang, required bool exact, FlutterLocalNotificationsPlugin? plugin}) async {
    final t = _t(lang);
    final title = t.ccRingTitle(data['setter_name'] ?? '');
    final body = data['text'] ?? '';
    for (final m in exact
        ? const [AndroidScheduleMode.alarmClock, AndroidScheduleMode.inexactAllowWhileIdle]
        : const [AndroidScheduleMode.inexactAllowWhileIdle]) {
      try {
        await (plugin ?? _plugin).zonedSchedule(
            id, title, body.isEmpty ? t.ccRingVoiceOnly : body,
            tz.TZDateTime.from(at, tz.local), details(lang),
            androidScheduleMode: m,
            uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
            payload: ccEncode({...data, 'title': title, 'body': body}));
        return true;
      } catch (e) {
        if (kDebugMode) debugPrint('carecall schedule($m) failed: $e');
      }
    }
    return false;
  }

  static Future<void> _cancel(int id, {FlutterLocalNotificationsPlugin? plugin}) async {
    try {
      await (plugin ?? _plugin).cancel(id);
    } catch (_) {}
  }

  /// Cancel every ring of one slot (shown or waiting): ids 1, 2, 9 and the
  /// push's own attempt id.
  static Future<void> cancelSlot(String slotKey,
      {int? attempt, FlutterLocalNotificationsPlugin? plugin}) async {
    for (final a in {1, 2, 3, 4, 9, if (attempt != null) attempt}) {
      await _cancel(ccNotifId(slotKey, a), plugin: plugin);
    }
    try {
      final p = await SharedPreferences.getInstance();
      final l = _ledger(p)..removeWhere((k, v) => (v as Map?)?['sk'] == slotKey);
      await p.setString(ledgerKey, jsonEncode(l));
    } catch (_) {}
  }

  /// "Remind me in 10 minutes": this phone rings again by itself (offline
  /// too); the server's snooze ring for the same slot is de-duplicated.
  static Future<void> scheduleSnooze(Map<String, String> data,
      {FlutterLocalNotificationsPlugin? plugin, DateTime? now}) async {
    final sk = data['slot_key'] ?? '';
    if (sk.isEmpty) return;
    final at = (now ?? DateTime.now()).add(const Duration(minutes: kCcSnoozeMin));
    final lang = data['lang'] ?? 'bn';
    final exact = await Notifications.canScheduleExact();
    final ok = await _schedule(ccNotifId(sk, 9), {...data, 'attempt': '9'}, at,
        lang: lang, exact: exact || plugin != null, plugin: plugin);
    if (!ok) return;
    try {
      final p = await SharedPreferences.getInstance();
      final l = _ledger(p)
        ..['${ccNotifId(sk, 9)}'] = {'sig': 'snooze', 'at': at.millisecondsSinceEpoch, 'sk': sk, 'k': 'snooze'};
      await p.setString(ledgerKey, jsonEncode(l));
    } catch (_) {}
  }

  /// A "carecall" push arrived: show it, or stay silent because this phone's
  /// own alarm already rang for the same slot (or the slot is answered).
  /// When the own alarm is still WAITING (late), the push rings now and the
  /// late alarm is cancelled — exactly one ring either way.
  static Future<bool> onPush(PushPayload p,
      {FlutterLocalNotificationsPlugin? plugin, DateTime? now}) async {
    try {
      final sk = p.data['slot_key'] ?? '';
      if (sk.isEmpty) return true;
      if (await isHandled(sk)) return false;
      final t = now ?? DateTime.now();
      final prefs = await SharedPreferences.getInstance();
      final near = <int>[];
      for (final e in _ledger(prefs).entries) {
        final v = e.value as Map? ?? const {};
        if (v['sk'] != sk) continue;
        final at = DateTime.fromMillisecondsSinceEpoch((v['at'] as num? ?? 0).toInt());
        if (at.isAfter(t.subtract(const Duration(minutes: 6))) &&
            at.isBefore(t.add(const Duration(minutes: 3)))) {
          near.add(int.tryParse(e.key) ?? 0);
        }
      }
      if (near.isEmpty) return true;
      Set<int> pending = {};
      try {
        pending = {for (final r in await (plugin ?? _plugin).pendingNotificationRequests()) r.id};
      } catch (_) {}
      final waiting = near.where(pending.contains).toList();
      if (waiting.length < near.length) return false; // the own alarm rang
      for (final id in waiting) {
        await _cancel(id, plugin: plugin);
      }
      return true;
    } catch (_) {
      return true; // when unsure, ring
    }
  }
}

/// The answer queue (offline-safe) + the two answers.
class CareCallActions {
  CareCallActions._();

  static const outboxKey = 'carecall_outbox_v1';

  static bool isOurs(NotificationResponse r) =>
      r.actionId == CareCallAlarms.actionDone || r.actionId == CareCallAlarms.actionSnooze;

  static Map<String, String>? dataOf(String? payload) {
    try {
      final j = jsonDecode(payload ?? '');
      if (j is! Map || j['kind'] != 'carecall') return null;
      return {for (final e in j.entries) '${e.key}': '${e.value}'};
    } catch (_) {
      return null;
    }
  }

  static Future<List<Map<String, dynamic>>> outbox() async {
    try {
      final p = await SharedPreferences.getInstance();
      final j = jsonDecode(p.getString(outboxKey) ?? '[]');
      return [for (final x in (j as List)) Map<String, dynamic>.from(x as Map)];
    } catch (_) {
      return [];
    }
  }

  static Future<void> _saveOutbox(List<Map<String, dynamic>> q) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(outboxKey, jsonEncode(q.length > 100 ? q.sublist(q.length - 100) : q));
    } catch (_) {}
  }

  /// Record Done / Snooze for one ring: queued first (never lost), slot
  /// alarms cancelled, a snooze re-armed locally, then sent when possible.
  static Future<void> answer(Map<String, String> data, String action,
      {CareCallApi? api, FlutterLocalNotificationsPlugin? plugin, DateTime? now}) async {
    final sk = data['slot_key'] ?? '';
    final id = int.tryParse(data['care_call_id'] ?? '') ?? 0;
    final slot = data['slot'] ?? '';
    if (sk.isEmpty || id == 0 || slot.isEmpty) return;
    final q = await outbox()
      ..add({'care_call_id': id, 'slot': slot, 'action': action,
             'at': (now ?? DateTime.now()).millisecondsSinceEpoch});
    await _saveOutbox(q);
    await CareCallAlarms.cancelSlot(sk, attempt: int.tryParse(data['attempt'] ?? ''), plugin: plugin);
    if (action == 'done') {
      await CareCallAlarms.markHandled(sk);
    } else {
      await CareCallAlarms.scheduleSnooze(data, plugin: plugin, now: now);
    }
    await flush(api: api);
  }

  static bool _flushing = false;

  /// Send the queue (the app's API, or — in the background isolate — the
  /// stored token). Sent answers leave the queue; a failure keeps them.
  static Future<bool> flush({CareCallApi? api}) async {
    if (_flushing) return false;
    _flushing = true;
    try {
      final q = await outbox();
      if (q.isEmpty) return true;
      final batch = q.take(50).toList();
      bool ok;
      if (api != null) {
        try {
          await api.acks(batch);
          ok = true;
        } catch (_) {
          ok = false;
        }
      } else {
        ok = await _postWithToken(batch);
      }
      if (ok) {
        final rest = await outbox();
        rest.removeWhere((x) => batch.any((b) =>
            b['slot'] == x['slot'] && b['care_call_id'] == x['care_call_id'] &&
            b['action'] == x['action'] && b['at'] == x['at']));
        await _saveOutbox(rest);
      }
      return ok;
    } catch (_) {
      return false;
    } finally {
      _flushing = false;
    }
  }

  static Future<bool> _postWithToken(List<Map<String, dynamic>> batch) async {
    try {
      final token = await SecretStore.instance.read('token');
      if (token == null || token.isEmpty) return false;
      final r = await http
          .post(AppConfig.api('/carecall/acks'),
              headers: {'Authorization': 'Token $token', 'Content-Type': 'application/json'},
              body: jsonEncode({'acks': batch}))
          .timeout(const Duration(seconds: 10));
      return r.statusCode >= 200 && r.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  /// Notification button with the app closed (background isolate).
  static Future<void> handleBackground(NotificationResponse r) async {
    try {
      final d = dataOf(r.payload);
      if (d == null) return;
      try {
        tzdata.initializeTimeZones();
        tz.setLocalLocation(tz.getLocation('Asia/Dhaka'));
      } catch (_) {}
      final pl = FlutterLocalNotificationsPlugin();
      await pl.initialize(const InitializationSettings(
          android: AndroidInitializationSettings('@drawable/ic_stat_assisto')));
      await answer(d, r.actionId == CareCallAlarms.actionDone ? 'done' : 'snooze', plugin: pl);
    } catch (_) {}
  }
}

/// The setter's own voice clip, cached on the phone (never sent anywhere
/// else, never given to any AI).
class CareCallVoice {
  CareCallVoice._();

  static Future<String> pathFor(int id, int rev) async {
    final dir = await getApplicationDocumentsDirectory();
    final d = Directory('${dir.path}/carecall');
    if (!d.existsSync()) d.createSync(recursive: true);
    return '${d.path}/v_${id}_$rev.m4a';
  }

  /// The local file for this clip (downloaded once), or null.
  static Future<String?> ensure(CareCallApi api, int id, int rev) async {
    if (rev <= 0) return null;
    try {
      final path = await pathFor(id, rev);
      final f = File(path);
      if (f.existsSync() && f.lengthSync() > 0) return path;
      final bytes = await api.voice(id).timeout(const Duration(seconds: 12));
      if (bytes.isEmpty) return null;
      await f.writeAsBytes(bytes, flush: true);
      return path;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> cached(int id, int rev) async {
    if (rev <= 0) return null;
    try {
      final path = await pathFor(id, rev);
      return File(path).existsSync() ? path : null;
    } catch (_) {
      return null;
    }
  }
}

/// Keeps a phone's Care Calls in step (app open / resume / the screen).
class CareCallSync {
  CareCallSync._();
  static DateTime? _last;
  static bool _running = false;

  /// Last server answer (the hub screen shows it at once next time).
  static Map<String, dynamic>? lastMine;

  /// Throttled (2 min) unless [force]. Never throws.
  static Future<void> run(CareCallApi api, {required String lang, bool force = false}) async {
    if (_running) return;
    final now = DateTime.now();
    if (!force && _last != null && now.difference(_last!) < const Duration(minutes: 2)) return;
    _running = true;
    _last = now;
    try {
      await CareCallActions.flush(api: api);
      final m = await api.mine().timeout(const Duration(seconds: 15));
      lastMine = m;
      await apply(api, m, lang: lang);
    } catch (_) {
      // offline: the alarms already on the phone keep ringing
    } finally {
      _running = false;
    }
  }

  /// Download voices + reconcile alarms from one /carecall answer.
  static Future<void> apply(CareCallApi api, Map<String, dynamic> m, {required String lang}) async {
    final received = [
      for (final x in (m['received'] as List? ?? const []))
        CcItem.fromJson(Map<String, dynamic>.from(x as Map))
    ];
    for (final it in received) {
      if (it.hasVoice) await CareCallVoice.ensure(api, it.id, it.voiceRev);
    }
    await CareCallAlarms.reconcile(received, lang: lang);
  }
}
