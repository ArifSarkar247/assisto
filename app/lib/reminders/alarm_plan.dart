import 'dart:convert';

import '../push/push_payload.dart' show PushPayload;
import '../widgets/reminders_nlp.dart' show RecurrenceRule, nextOccurrence;

/// remmeter — PURE planning for on-time reminder alarms (no Flutter, no
/// plugins, no I/O; unit-tested in test/remmeter_alarm_plan_test.dart).
///
/// What was wrong before (27 Oct audit):
///  1. Every reminder was scheduled `inexactAllowWhileIdle` — Android may
///     deliver it many minutes late (Doze, Xiaomi/Realme/Oppo/Vivo savers).
///  2. The alarm id was `localId.hashCode`, but after the first sync the
///     reminder's localId changes (`srv-<id>`), so editing / finishing /
///     deleting a synced reminder could not cancel its original alarm.
///  3. A recurring reminder only ever had its NEXT fire scheduled; nothing
///     scheduled the one after unless the user reopened the screen.
///  4. The server backup push and the local alarm were two different
///     notifications — a double alert whenever both worked.
///
/// The fix: the alarm id is derived from a STABLE key — `rem-<serverId>`
/// once synced (the SAME id the server's reminder push uses, see
/// PushPayload.notificationId), `remloc-<localId>` before that — and the
/// whole set is RECONCILED against a small ledger (what we scheduled, when,
/// in which mode) every time the reminder list changes and on app resume.

/// How an alarm is scheduled on Android.
///  * `alarm`   — AlarmManager.setAlarmClock: the most reliable (never
///                deferred by Doze/OEM savers); used only for reminders the
///                user marked important (it shows the alarm icon).
///  * `exact`   — setExactAndAllowWhileIdle.
///  * `inexact` — the honest fallback when "Alarms & reminders" is not
///                allowed (Android 12+): may arrive a few minutes late.
enum AlarmMode { alarm, exact, inexact }

AlarmMode alarmModeFromName(String? s) => switch (s) {
      'alarm' => AlarmMode.alarm,
      'exact' => AlarmMode.exact,
      _ => AlarmMode.inexact,
    };

/// Native repeat the plugin can carry forward by itself after each fire
/// (so a daily pill reminder keeps ringing even if the app is never opened).
/// Only the simple, exactly-representable rules: every day / every week on
/// one weekday. Everything else is scheduled one occurrence at a time.
enum AlarmRepeat { none, daily, weekly }

class AlarmPlan {
  const AlarmPlan({
    required this.key,
    required this.at,
    required this.title,
    required this.body,
    this.repeat = AlarmRepeat.none,
    this.important = false,
  });

  /// Stable key: `rem-<serverId>` or `remloc-<localId>`.
  final String key;

  /// Local wall-clock fire time (due_at minus remind_before_min).
  final DateTime at;
  final String title;
  final String body;
  final AlarmRepeat repeat;
  final bool important;

  int get id => alarmIdFor(key);

  /// Signature used by the ledger to decide "already scheduled exactly so".
  String sig(AlarmMode mode) =>
      '${at.millisecondsSinceEpoch}|${repeat.name}|${mode.name}|'
      '${PushPayload.stableHash('$title\u0000$body')}';
}

/// The notification id for a reminder key. Identical to the id the server
/// push for the same reminder is drawn with (PushPayload.notificationId uses
/// `rem-<reminder_id>`), so even an un-deduplicated push REPLACES the local
/// alarm's notification instead of adding a second one.
int alarmIdFor(String key) => PushPayload.stableHash(key);

String reminderKeyOf(Map<String, dynamic> item) {
  final sid = item['serverId'];
  if (sid != null && '$sid'.isNotEmpty) return 'rem-$sid';
  return 'remloc-${item['localId']}';
}

DateTime? _anchor(Map<String, dynamic> d) {
  final v = d['due_at'];
  if (v == null) return null;
  return DateTime.tryParse('$v')?.toLocal();
}

int _leadMin(Map<String, dynamic> d) {
  final v = d['remind_before_min'];
  final n = v is int ? v : int.tryParse('${v ?? ''}') ?? 0;
  if (n < 0) return 0;
  return n > 60 * 24 * 7 ? 60 * 24 * 7 : n;
}

/// Mirror of reminders_screen.ruleFromData (kept pure here).
RecurrenceRule? ruleOfData(Map<String, dynamic> d) {
  final raw = d['recurrence_rule'];
  if (raw is Map && raw['freq'] != null && '${raw['freq']}'.isNotEmpty) {
    int? i(dynamic v) => v is int ? v : int.tryParse('${v ?? ''}');
    return RecurrenceRule(
      freq: '${raw['freq']}',
      interval: i(raw['interval']) ?? 1,
      weekday: i(raw['weekday']),
      dayOfMonth: i(raw['day_of_month']),
      month: i(raw['month']),
      time: raw['time'] as String?,
    );
  }
  final freq = '${d['recurrence'] ?? 'none'}';
  if (freq == 'none' || freq.isEmpty) return null;
  final a = _anchor(d);
  return RecurrenceRule(
    freq: freq,
    time: a == null
        ? null
        : '${a.hour.toString().padLeft(2, '0')}:'
            '${a.minute.toString().padLeft(2, '0')}',
  );
}

/// Most alarms we keep with the OS at once (Android allows ~500 per app;
/// other features schedule too). The soonest win.
const int kMaxReminderAlarms = 64;

/// The alarms the reminder list SHOULD have right now.
List<AlarmPlan> planReminderAlarms(List<Map<String, dynamic>> items,
    {required DateTime now}) {
  final out = <AlarmPlan>[];
  for (final it in items) {
    final raw = it['data'];
    if (raw is! Map) continue;
    final d = Map<String, dynamic>.from(raw);
    if (d['done'] == true) continue;
    if (it['pendingOp'] == 'delete') continue;
    final anchor = _anchor(d);
    if (anchor == null) continue;
    final lead = Duration(minutes: _leadMin(d));
    final rule = ruleOfData(d);
    DateTime? fire;
    var repeat = AlarmRepeat.none;
    if (rule == null) {
      fire = anchor.subtract(lead);
      if (!fire.isAfter(now)) continue;
    } else {
      // first occurrence whose (occurrence - lead) is still ahead
      final occ = nextOccurrence(anchor, rule, after: now.add(lead));
      if (occ == null) continue;
      fire = occ.subtract(lead);
      if (rule.interval <= 1 && lead == Duration.zero) {
        if (rule.freq == 'daily') repeat = AlarmRepeat.daily;
        if (rule.freq == 'weekly') repeat = AlarmRepeat.weekly;
      }
    }
    out.add(AlarmPlan(
      key: reminderKeyOf(it),
      at: fire,
      title: '${d['title'] ?? ''}'.trim(),
      body: '${d['notes'] ?? ''}'.trim(),
      repeat: repeat,
      important: '${d['priority'] ?? ''}' == 'high',
    ));
  }
  out.sort((a, b) => a.at.compareTo(b.at));
  return out.length > kMaxReminderAlarms
      ? out.sublist(0, kMaxReminderAlarms)
      : out;
}

/// The mode a plan gets on this phone.
AlarmMode modeFor(AlarmPlan p, {required bool exactAllowed}) {
  if (!exactAllowed) return AlarmMode.inexact;
  return p.important ? AlarmMode.alarm : AlarmMode.exact;
}

// ---------------------------------------------------------------- ledger
/// One alarm we handed to the OS. Stored (no titles — privacy) in
/// SharedPreferences so the background push isolate can read it.
class LedgerEntry {
  const LedgerEntry({
    required this.key,
    required this.at,
    required this.mode,
    required this.repeat,
    required this.sig,
  });
  final String key;
  final int at; // ms since epoch (first fire)
  final AlarmMode mode;
  final AlarmRepeat repeat;
  final String sig;

  Map<String, dynamic> toJson() =>
      {'k': key, 'at': at, 'm': mode.name, 'r': repeat.name, 's': sig};

  static LedgerEntry? fromJson(dynamic j) {
    if (j is! Map) return null;
    final at = j['at'];
    if (at is! int || j['k'] is! String) return null;
    return LedgerEntry(
      key: j['k'] as String,
      at: at,
      mode: alarmModeFromName(j['m'] as String?),
      repeat: switch (j['r']) {
        'daily' => AlarmRepeat.daily,
        'weekly' => AlarmRepeat.weekly,
        _ => AlarmRepeat.none,
      },
      sig: '${j['s'] ?? ''}',
    );
  }
}

Map<int, LedgerEntry> decodeLedger(String? s) {
  final out = <int, LedgerEntry>{};
  if (s == null || s.isEmpty) return out;
  try {
    final m = jsonDecode(s);
    if (m is! Map) return out;
    m.forEach((k, v) {
      final id = int.tryParse('$k');
      final e = LedgerEntry.fromJson(v);
      if (id != null && e != null) out[id] = e;
    });
  } catch (_) {}
  return out;
}

String encodeLedger(Map<int, LedgerEntry> l) =>
    jsonEncode({for (final e in l.entries) '${e.key}': e.value.toJson()});

/// What reconciling must do.
class ReconcileOps {
  ReconcileOps(this.cancel, this.schedule);
  final List<int> cancel;
  final List<AlarmPlan> schedule;
  bool get isEmpty => cancel.isEmpty && schedule.isEmpty;
}

/// Diff the wanted plans against the ledger + what the OS still holds.
/// An alarm is re-handed to the OS when its time/title/mode changed, or when
/// the OS no longer has it (the plugin DROPS cached exact alarms at boot if
/// "Alarms & reminders" was revoked) — [pendingIds] null = unknown, trust
/// the ledger.
ReconcileOps diffAlarms({
  required List<AlarmPlan> plans,
  required Map<int, LedgerEntry> ledger,
  required bool exactAllowed,
  Set<int>? pendingIds,
}) {
  final wanted = {for (final p in plans) p.id: p};
  final cancel = <int>[
    for (final id in ledger.keys)
      if (!wanted.containsKey(id)) id,
  ];
  final schedule = <AlarmPlan>[];
  for (final p in plans) {
    final e = ledger[p.id];
    final sig = p.sig(modeFor(p, exactAllowed: exactAllowed));
    final stillThere = pendingIds == null || pendingIds.contains(p.id);
    if (e != null && e.sig == sig && stillThere) continue;
    schedule.add(p);
  }
  return ReconcileOps(cancel, schedule);
}

// ---------------------------------------------------------------- dedupe
/// What to do with a server reminder push on a phone that may ALSO have the
/// local alarm for it.
enum PushDecision {
  /// No local alarm for this fire (other device created it, never synced
  /// here, app not opened since) — show the push.
  show,

  /// The local alarm is still waiting = it is LATE (inexact / OEM delay).
  /// Show the push now and cancel the waiting alarm (no second ring later).
  showAndCancelLocal,

  /// The local alarm already rang for this exact fire — stay silent.
  suppress,
}

/// [fireMs] = the fire time the server pushed for. [pending] = the OS still
/// holds the local alarm id (null = unknown). A fire within 90 s of the
/// ledger time is "the same fire".
PushDecision decideReminderPush({
  required LedgerEntry? entry,
  required int? fireMs,
  required bool? pending,
}) {
  if (entry == null || fireMs == null) return PushDecision.show;
  if (entry.repeat != AlarmRepeat.none) {
    // A native repeat is always pending (the plugin re-arms the next day),
    // so "pending" says nothing. Same time of day + exact = it rang.
    final a = DateTime.fromMillisecondsSinceEpoch(entry.at);
    final f = DateTime.fromMillisecondsSinceEpoch(fireMs);
    final sameTod = (a.hour * 60 + a.minute) == (f.hour * 60 + f.minute);
    if (sameTod && entry.mode != AlarmMode.inexact) {
      return PushDecision.suppress;
    }
    return PushDecision.show;
  }
  if ((entry.at - fireMs).abs() > 90 * 1000) return PushDecision.show;
  if (pending == null) {
    return entry.mode == AlarmMode.inexact
        ? PushDecision.show
        : PushDecision.suppress;
  }
  return pending ? PushDecision.showAndCancelLocal : PushDecision.suppress;
}

// ---------------------------------------------------------------- lateness
/// One measured delivery (local only; no titles, no ids that leave the phone).
class DeliverySample {
  const DeliverySample({
    required this.scheduledMs,
    required this.observedMs,
    required this.source,
    required this.mode,
    this.lowerBound = false,
  });

  final int scheduledMs;
  final int observedMs;

  /// `local` (the alarm's own notification post time) or `push` (the
  /// server backup arrived first while the local alarm was still waiting).
  final String source;
  final AlarmMode mode;

  /// True when we only know the alarm was AT LEAST this late.
  final bool lowerBound;

  int get lateSeconds {
    final s = ((observedMs - scheduledMs) / 1000).round();
    return s < 0 ? 0 : s;
  }

  Map<String, dynamic> toJson() => {
        's': scheduledMs,
        'o': observedMs,
        'src': source,
        'm': mode.name,
        if (lowerBound) 'lb': true,
      };

  static DeliverySample? fromJson(dynamic j) {
    if (j is! Map || j['s'] is! int || j['o'] is! int) return null;
    return DeliverySample(
      scheduledMs: j['s'] as int,
      observedMs: j['o'] as int,
      source: '${j['src'] ?? 'local'}',
      mode: alarmModeFromName(j['m'] as String?),
      lowerBound: j['lb'] == true,
    );
  }
}

class DeliveryStats {
  const DeliveryStats({
    required this.count,
    required this.onTime,
    required this.medianSeconds,
    required this.worstSeconds,
  });
  final int count;

  /// Delivered within 60 s (the owner's quality bar for alerts).
  final int onTime;
  final int medianSeconds;
  final int worstSeconds;

  static DeliveryStats of(List<DeliverySample> s) {
    if (s.isEmpty) {
      return const DeliveryStats(
          count: 0, onTime: 0, medianSeconds: 0, worstSeconds: 0);
    }
    final late = [for (final x in s) x.lateSeconds]..sort();
    return DeliveryStats(
      count: late.length,
      onTime: late.where((x) => x <= 60).length,
      medianSeconds: late[late.length ~/ 2],
      worstSeconds: late.last,
    );
  }
}

/// Keep the newest [max] samples.
List<DeliverySample> appendSample(
    List<DeliverySample> log, DeliverySample s, {int max = 40}) {
  final out = [...log, s];
  return out.length > max ? out.sublist(out.length - max) : out;
}
