// fcscreen (Family Care v3, owner order 9 Nov 10:50) — PURE member status
// rules, the Dart mirror of backend/core/logic/family_status.py. One case
// table (backend/core/logic/fc_status_cases.json) drives both test suites.
//
// The phone re-runs these rules at RENDER time with its own clock, so a card
// fetched green at 10:00 turns gray at 13:00 without any network call
// (owner: "green only when fresh data proves it" — zero false green).

const int fcDefaultIntervalS = 3 * 3600;
const int fcMinIntervalS = 15 * 60;
const int fcMaxIntervalS = 24 * 3600;
const int fcClockSkewS = 5 * 60;
const int fcLowBattery = 15;
const int fcDeadBattery = 5;
const List<String> fcAmberFlags = ['watch', 'carecall_missed', 'journey_overdue'];

/// ISO string (naive = UTC) / DateTime / epoch seconds -> UTC DateTime or null.
DateTime? fcParseTs(Object? v) {
  if (v == null || v == '') return null;
  try {
    if (v is DateTime) return v.toUtc();
    if (v is num && v is! bool) {
      return DateTime.fromMillisecondsSinceEpoch((v * 1000).round(), isUtc: true);
    }
    var s = '$v'.trim();
    // naive ISO = UTC (Python mirror does the same)
    final hasZone = RegExp(r'(Z|[+-]\d\d:?\d\d)$').hasMatch(s);
    if (!hasZone && s.contains('T')) s = '${s}Z';
    return DateTime.parse(s).toUtc();
  } catch (_) {
    return null;
  }
}

int fcClampInterval(Object? v) {
  int? n;
  if (v is int) {
    n = v;
  } else if (v is num) {
    n = v.toInt();
  } else if (v is String) {
    n = int.tryParse(v);
  }
  if (n == null || n <= 0) return fcDefaultIntervalS;
  return n.clamp(fcMinIntervalS, fcMaxIntervalS);
}

int? _int(Object? v) {
  if (v == null || v is bool) return null;
  if (v is num) return v.toInt();
  final d = double.tryParse('$v');
  return d?.toInt();
}

String _iso(DateTime d) {
  final s = d.toUtc().toIso8601String();
  // Python: 2026-11-09T12:30:00Z (no millis when zero)
  return s.replaceFirst(RegExp(r'\.000Z$'), 'Z').replaceFirst(RegExp(r'\.0+Z$'), 'Z');
}

class FcStatus {
  final String state; // sos | paused | stale | check | ok
  final String reason;
  final DateTime? freshUntil;
  final int? ageS;
  const FcStatus(this.state, this.reason, {this.freshUntil, this.ageS});
  String? get freshUntilIso => freshUntil == null ? null : _iso(freshUntil!);
  bool get isGreen => state == 'ok';
  @override
  String toString() => 'FcStatus($state, $reason)';
}

/// brain: last_seen, battery, charging, net, bg_restricted, paused_until,
/// interval_s. flags: sos, watch, carecall_missed, journey_overdue, amber_reason.
FcStatus fcMemberStatus(Map? brain, DateTime now, [Map? flags]) {
  final b = brain ?? const {};
  final f = flags ?? const {};
  now = now.toUtc();
  final seen = fcParseTs(b['last_seen']);
  final interval = fcClampInterval(b['interval_s']);
  final freshUntil = seen?.add(Duration(seconds: interval));
  final age = seen == null ? null : now.difference(seen).inSeconds;

  if (f['sos'] == true) return FcStatus('sos', 'sos', ageS: age);
  final paused = fcParseTs(b['paused_until']);
  if (paused != null && paused.isAfter(now)) {
    return FcStatus('paused', 'paused', ageS: age);
  }
  if (seen == null) return const FcStatus('stale', 'never');
  if (age! < -fcClockSkewS) return FcStatus('stale', 'clock', ageS: age);
  final battery = _int(b['battery']);
  final charging = b['charging'] == true;
  if (now.isAfter(freshUntil!)) {
    final String reason;
    if (battery != null && battery <= fcDeadBattery && !charging) {
      reason = 'battery_off';
    } else if ('${b['net'] ?? ''}' == 'none') {
      reason = 'no_internet';
    } else {
      reason = 'background_killed';
    }
    return FcStatus('stale', reason, freshUntil: freshUntil, ageS: age);
  }
  for (final k in fcAmberFlags) {
    if (f[k] == true) return FcStatus('check', k, freshUntil: freshUntil, ageS: age);
  }
  final ar = f['amber_reason'];
  if (ar != null && '$ar'.isNotEmpty) {
    final s = '$ar';
    return FcStatus('check', s.length > 24 ? s.substring(0, 24) : s,
        freshUntil: freshUntil, ageS: age);
  }
  if (battery != null && battery <= fcLowBattery && !charging) {
    return FcStatus('check', 'battery_low', freshUntil: freshUntil, ageS: age);
  }
  return FcStatus('ok', 'ok', freshUntil: freshUntil, ageS: age);
}

/// The server sends `status` computed at server time; the phone re-checks
/// with ITS clock: a server green whose fresh_until has passed is gray now.
/// Never upgrades a server non-green to green.
FcStatus fcRecheck(Map member, DateTime now) {
  final st = (member['status'] as Map?) ?? const {};
  final server = '${st['state'] ?? 'stale'}';
  final reason = '${st['reason'] ?? 'never'}';
  if (server == 'ok' || server == 'check') {
    final brain = (member['brain'] as Map?) ?? const {};
    final local = fcMemberStatus(brain, now);
    if (local.state == 'stale') return local;
    final fu = fcParseTs(st['fresh_until']);
    if (fu != null && now.toUtc().isAfter(fu)) {
      return FcStatus('stale', 'background_killed', freshUntil: fu);
    }
    return FcStatus(server, reason, freshUntil: fu ?? local.freshUntil, ageS: local.ageS);
  }
  return FcStatus(server, reason, freshUntil: fcParseTs(st['fresh_until']));
}

class FcLine {
  final String state; // sos | check | stale | ok | empty
  final String reason;
  final String name;
  final int? userId;
  final int count;
  const FcLine(this.state, {this.reason = '', this.name = '', this.userId, this.count = 0});
}

/// rows: other members [{user_id, name, state, reason}].
FcLine fcFamilyLine(List<Map> rows) {
  if (rows.isEmpty) return const FcLine('empty');
  for (final want in const ['sos', 'check', 'stale', 'paused']) {
    final hit = rows.where((r) => r['state'] == want).toList();
    if (hit.isNotEmpty) {
      final r = hit.first;
      return FcLine(want == 'paused' ? 'stale' : want,
          reason: '${r['reason'] ?? ''}', name: '${r['name'] ?? ''}',
          userId: r['user_id'] as int?, count: hit.length);
    }
  }
  if (rows.every((r) => r['state'] == 'ok')) return FcLine('ok', reason: 'ok', count: rows.length);
  final r = rows.firstWhere((x) => x['state'] != 'ok');
  return FcLine('stale', reason: 'never', name: '${r['name'] ?? ''}',
      userId: r['user_id'] as int?, count: 1);
}

int fcStateRank(String s) => switch (s) {
      'sos' => 0,
      'check' => 1,
      'stale' => 2,
      'paused' => 3,
      'ok' => 4,
      _ => 2,
    };
