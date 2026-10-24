import 'package:shared_preferences/shared_preferences.dart';

import '../notifications.dart';

/// f6 — Ramadan sehri wake-up alarm + iftar heads-up, made REAL.
///
/// Before f6 the two sliders only changed a number on screen: nothing was
/// saved and nothing ever rang. Now each alarm has an on/off switch and its
/// offset is saved on this phone; while on, LOCAL notifications are scheduled
/// for today and tomorrow (sehri end / iftar minus the offset). The plan is
/// re-made every time the Ramadan screen loads the day's times, so it follows
/// the daily shift of the times.
class RamadanAlarmPrefs {
  final bool sehriOn;
  final int sehriMin;
  final bool iftarOn;
  final int iftarMin;
  const RamadanAlarmPrefs(
      {this.sehriOn = false,
      this.sehriMin = 60,
      this.iftarOn = false,
      this.iftarMin = 10});
}

class RamadanAlarm {
  final String localId;
  final DateTime when;
  final bool sehri;
  const RamadanAlarm(this.localId, this.when, this.sehri);
}

class RamadanAlarms {
  RamadanAlarms._();

  static const _kSehriOn = 'ramadan_sehri_alarm_on';
  static const _kSehriMin = 'ramadan_sehri_alarm_min';
  static const _kIftarOn = 'ramadan_iftar_alert_on';
  static const _kIftarMin = 'ramadan_iftar_alert_min';
  static const ids = [
    'ramadan-sehri-0', 'ramadan-sehri-1', 'ramadan-iftar-0', 'ramadan-iftar-1'
  ];

  static Future<RamadanAlarmPrefs> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      return RamadanAlarmPrefs(
        sehriOn: p.getBool(_kSehriOn) ?? false,
        sehriMin: p.getInt(_kSehriMin) ?? 60,
        iftarOn: p.getBool(_kIftarOn) ?? false,
        iftarMin: p.getInt(_kIftarMin) ?? 10,
      );
    } catch (_) {
      return const RamadanAlarmPrefs();
    }
  }

  static Future<void> save(RamadanAlarmPrefs v) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kSehriOn, v.sehriOn);
      await p.setInt(_kSehriMin, v.sehriMin);
      await p.setBool(_kIftarOn, v.iftarOn);
      await p.setInt(_kIftarMin, v.iftarMin);
    } catch (_) {}
  }

  static DateTime? _at(String hhmm, DateTime day, int minusMin) {
    final parts = hhmm.split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0].trim());
    final m = int.tryParse(parts[1].trim().split(' ').first);
    if (h == null || m == null) return null;
    return DateTime(day.year, day.month, day.day, h, m)
        .subtract(Duration(minutes: minusMin));
  }

  /// Pure plan for today + tomorrow. Only future moments.
  static List<RamadanAlarm> plan(
      {required String sehriEnd,
      required String iftar,
      required RamadanAlarmPrefs prefs,
      required DateTime now}) {
    final out = <RamadanAlarm>[];
    for (var d = 0; d < 2; d++) {
      final day = DateTime(now.year, now.month, now.day + d);
      if (prefs.sehriOn) {
        final w = _at(sehriEnd, day, prefs.sehriMin);
        if (w != null && w.isAfter(now)) {
          out.add(RamadanAlarm('ramadan-sehri-$d', w, true));
        }
      }
      if (prefs.iftarOn) {
        final w = _at(iftar, day, prefs.iftarMin);
        if (w != null && w.isAfter(now)) {
          out.add(RamadanAlarm('ramadan-iftar-$d', w, false));
        }
      }
    }
    return out;
  }

  /// Cancel all four slots, then schedule the plan. Never throws.
  static Future<int> sync({
    required String sehriEnd,
    required String iftar,
    required RamadanAlarmPrefs prefs,
    required String sehriTitle,
    required String iftarTitle,
    DateTime? now,
    Future<void> Function(String id, String title, String body, DateTime when)?
        schedule,
    Future<void> Function(String id)? cancel,
  }) async {
    final sch = schedule ?? Notifications.schedule;
    final can = cancel ?? Notifications.cancel;
    try {
      for (final id in ids) {
        await can(id);
      }
      final list = plan(
          sehriEnd: sehriEnd,
          iftar: iftar,
          prefs: prefs,
          now: now ?? DateTime.now());
      for (final a in list) {
        await sch(a.localId, a.sehri ? sehriTitle : iftarTitle, '', a.when);
      }
      return list.length;
    } catch (_) {
      return 0;
    }
  }
}
