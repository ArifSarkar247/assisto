import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';

import '../l10n/app_localizations.dart';
import '../notifications.dart';
import '../state.dart';
import '../widgets/journey_api.dart';
import '../widgets/journey_ride.dart' show jDistanceM;

/// sjstart2 (owner Safe Journey V2 "Auto suggest"): when the user leaves the
/// place a usual trip starts from (Home) at the usual time, ONE notification
/// "Going to Office? Tell family?" — a tap opens Safe Journey filled in, the
/// "Start" button starts it at once.
///
/// Owner 9 Nov 14:20 (Play rule): NO background location and NO new
/// permission. So this runs ONLY while Assisto is open (on resume + every
/// [_every] in the foreground), and only when location is ALREADY allowed —
/// it never asks. Everything is learned and kept ON THE PHONE: the last
/// [_keep] trips (start point, destination, mode, start time). Nothing is
/// sent to the server until the user starts a journey.
class JourneyHabitTrip {
  const JourneyHabitTrip({
    required this.fLat,
    required this.fLng,
    required this.dLat,
    required this.dLng,
    required this.name,
    required this.at,
    this.kind,
    this.mode,
  });
  final double fLat, fLng, dLat, dLng;
  final String name;
  final String? kind, mode;
  final DateTime at; // local start time

  Map<String, dynamic> toJson() => {
        'f': [fLat, fLng],
        'd': [dLat, dLng],
        'n': name,
        if (kind != null) 'k': kind,
        if (mode != null) 'm': mode,
        't': at.millisecondsSinceEpoch,
      };

  static JourneyHabitTrip? fromJson(Object? o) {
    if (o is! Map) return null;
    final f = o['f'], d = o['d'], t = o['t'];
    if (f is! List || d is! List || f.length != 2 || d.length != 2 || t is! num) return null;
    return JourneyHabitTrip(
      fLat: (f[0] as num).toDouble(),
      fLng: (f[1] as num).toDouble(),
      dLat: (d[0] as num).toDouble(),
      dLng: (d[1] as num).toDouble(),
      name: '${o['n'] ?? ''}',
      kind: o['k'] as String?,
      mode: o['m'] as String?,
      at: DateTime.fromMillisecondsSinceEpoch(t.toInt()),
    );
  }
}

/// A usual trip that fits right now.
class JourneySuggestion {
  const JourneySuggestion({
    required this.oLat,
    required this.oLng,
    required this.dLat,
    required this.dLng,
    required this.name,
    required this.usualMin,
    required this.times,
    this.kind,
    this.mode,
  });
  final double oLat, oLng, dLat, dLng;
  final String name;
  final String? kind, mode;
  final int usualMin; // minute of the day the trip usually starts
  final int times; // how many past trips back it

  /// One suggestion per usual trip per day.
  String get key => '${dLat.toStringAsFixed(3)}_${dLng.toStringAsFixed(3)}';

  Map<String, dynamic> toJson() => {
        'o': [oLat, oLng],
        'd': [dLat, dLng],
        'n': name,
        'u': usualMin,
        'c': times,
        if (kind != null) 'k': kind,
        if (mode != null) 'm': mode,
      };

  static JourneySuggestion? fromJson(Object? o) {
    if (o is! Map) return null;
    final a = o['o'], d = o['d'];
    if (a is! List || d is! List || a.length != 2 || d.length != 2) return null;
    return JourneySuggestion(
      oLat: (a[0] as num).toDouble(),
      oLng: (a[1] as num).toDouble(),
      dLat: (d[0] as num).toDouble(),
      dLng: (d[1] as num).toDouble(),
      name: '${o['n'] ?? ''}',
      usualMin: (o['u'] as num?)?.toInt() ?? 0,
      times: (o['c'] as num?)?.toInt() ?? 0,
      kind: o['k'] as String?,
      mode: o['m'] as String?,
    );
  }
}

/// Bangladesh weekend = Friday + Saturday; a weekday habit is not a
/// weekend one.
bool sj2Weekend(DateTime d) => d.weekday == DateTime.friday || d.weekday == DateTime.saturday;

int _minOfDay(DateTime d) => d.hour * 60 + d.minute;

/// Circular minute distance (23:50 and 00:10 are 20 minutes apart).
int _minGap(int a, int b) {
  final g = (a - b).abs() % 1440;
  return math.min(g, 1440 - g);
}

/// The usual trips that START near the current time of day, on the same kind
/// of day, from at least [minDays] different days in the last [days] days.
/// Pure (tests).
List<JourneySuggestion> sj2UsualTrips(List<JourneyHabitTrip> trips, DateTime now,
    {int minDays = 2, int days = 42, int windowMin = 45, double sameM = 300}) {
  final fresh = [
    for (final t in trips)
      if (now.difference(t.at).inDays <= days &&
          !t.at.isAfter(now) &&
          sj2Weekend(t.at) == sj2Weekend(now) &&
          _minGap(_minOfDay(t.at), _minOfDay(now)) <= windowMin)
        t
  ];
  final groups = <List<JourneyHabitTrip>>[];
  for (final t in fresh) {
    List<JourneyHabitTrip>? g;
    for (final x in groups) {
      final h = x.first;
      if (jDistanceM(h.fLat, h.fLng, t.fLat, t.fLng) <= sameM &&
          jDistanceM(h.dLat, h.dLng, t.dLat, t.dLng) <= sameM) {
        g = x;
        break;
      }
    }
    g == null ? groups.add([t]) : g.add(t);
  }
  final out = <JourneySuggestion>[];
  for (final g in groups) {
    final dayKeys = {for (final t in g) '${t.at.year}-${t.at.month}-${t.at.day}'};
    if (dayKeys.length < minDays) continue;
    g.sort((a, b) => b.at.compareTo(a.at)); // newest first: its name / mode win
    final mins = [for (final t in g) _minOfDay(t.at)]..sort();
    double avg(Iterable<double> v) => v.reduce((a, b) => a + b) / v.length;
    out.add(JourneySuggestion(
      oLat: avg(g.map((t) => t.fLat)),
      oLng: avg(g.map((t) => t.fLng)),
      dLat: g.first.dLat,
      dLng: g.first.dLng,
      name: g.first.name,
      kind: g.first.kind,
      mode: g.first.mode,
      usualMin: mins[mins.length ~/ 2],
      times: g.length,
    ));
  }
  out.sort((a, b) => b.times.compareTo(a.times));
  return out;
}

/// Has the user just LEFT the usual start point? Out of its 250 m ring, and
/// either seen inside it in the last 90 minutes (the app was open at home)
/// or still within 2.5 km of it (just left). Not when already near the
/// destination. Pure (tests).
bool sj2JustLeft(JourneySuggestion s, double lat, double lng, DateTime now,
    {DateTime? seenAtOrigin}) {
  final fromO = jDistanceM(s.oLat, s.oLng, lat, lng);
  if (fromO <= 250) return false;
  if (jDistanceM(s.dLat, s.dLng, lat, lng) <= 1000) return false;
  final seen = seenAtOrigin != null && now.difference(seenAtOrigin).inMinutes <= 90;
  return seen || fromO <= 2500;
}

class JourneyHabits {
  JourneyHabits._();
  static const kTripsKey = 'sj2_habit_trips';
  static const kOnKey = 'sj2_suggest_on';
  static const kShownKey = 'sj2_suggest_shown'; // "<yyyy-mm-dd>|<key>,<key>"
  static const kSeenKey = 'sj2_seen_origin'; // ms of the last fix at a start point
  static const payloadPrefix = 'jsuggest:';
  static const actionGo = 'sj2_go';
  static const _keep = 60;
  static const _every = Duration(minutes: 3);
  static const _notifId = 0x5a2f01;

  static Timer? _timer;
  static bool _busy = false;
  @visibleForTesting
  static Future<({double lat, double lng})?> Function()? debugFix;

  static Future<bool> enabled() => Settings.getBool(kOnKey, true);
  static Future<void> setEnabled(bool on) => Settings.setBool(kOnKey, on);

  static Future<List<JourneyHabitTrip>> trips() async {
    try {
      final raw = jsonDecode(await Settings.getString(kTripsKey) ?? '[]');
      if (raw is! List) return [];
      return raw.map(JourneyHabitTrip.fromJson).whereType<JourneyHabitTrip>().toList();
    } catch (_) {
      return [];
    }
  }

  /// The user starts a journey: remember where from / to / when (phone only).
  static Future<void> record(JourneyHabitTrip t) async {
    try {
      final all = [...await trips(), t];
      final keep = all.length > _keep ? all.sublist(all.length - _keep) : all;
      await Settings.setString(kTripsKey, jsonEncode([for (final x in keep) x.toJson()]));
    } catch (_) {} // best-effort: a lost habit is never an error
  }

  static Future<void> forget() async {
    await Settings.setString(kTripsKey, '[]');
    await Settings.setString(kShownKey, '');
  }

  static String _day(DateTime d) => '${d.year}-${d.month}-${d.day}';

  /// App came to the foreground: check now, then every few minutes until
  /// it goes to the background. Never throws.
  static void onForeground(AppState app) {
    _timer?.cancel();
    // widget tests pump the whole app: no periodic timer left pending there
    try {
      if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    } catch (_) {}
    _timer = Timer.periodic(_every, (_) => unawaited(tick(app)));
    unawaited(tick(app));
  }

  static void onBackground() {
    _timer?.cancel();
    _timer = null;
  }

  static Future<({double lat, double lng})?> _fix() async {
    if (debugFix != null) return debugFix!();
    final perm = await Geolocator.checkPermission(); // never asks
    if (perm != LocationPermission.whileInUse && perm != LocationPermission.always) return null;
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    var p = await Geolocator.getLastKnownPosition();
    if (p == null || DateTime.now().difference(p.timestamp).inMinutes > 4) {
      p = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.medium, timeLimit: Duration(seconds: 10)));
    }
    return (lat: p.latitude, lng: p.longitude);
  }

  /// One check. Returns the suggestion shown (tests), else null.
  static Future<JourneySuggestion?> tick(AppState app, {DateTime? now}) async {
    if (_busy) return null;
    _busy = true;
    try {
      if (!app.loggedIn || !await enabled()) return null;
      final at = now ?? DateTime.now();
      final usual = sj2UsualTrips(await trips(), at);
      if (usual.isEmpty) return null;
      final fix = await _fix();
      if (fix == null) return null;
      for (final s in usual) {
        if (jDistanceM(s.oLat, s.oLng, fix.lat, fix.lng) <= 250) {
          await Settings.setString(kSeenKey, '${at.millisecondsSinceEpoch}');
          return null; // still at the start point
        }
      }
      final seenMs = int.tryParse(await Settings.getString(kSeenKey) ?? '');
      final seen = seenMs == null ? null : DateTime.fromMillisecondsSinceEpoch(seenMs);
      final shown = (await Settings.getString(kShownKey) ?? '').split('|');
      final today = _day(at);
      final done = shown.length == 2 && shown[0] == today ? shown[1].split(',').toSet() : <String>{};
      JourneySuggestion? pick;
      for (final s in usual) {
        if (done.contains(s.key)) continue;
        if (sj2JustLeft(s, fix.lat, fix.lng, at, seenAtOrigin: seen)) {
          pick = s;
          break;
        }
      }
      if (pick == null) return null;
      // a journey already running: nothing to suggest
      try {
        final a = await app.api.journeyActive();
        if (a['id'] != null) return null;
      } catch (_) {
        return null; // offline: starting would fail anyway
      }
      await Settings.setString(kShownKey, '$today|${[...done, pick.key].join(',')}');
      await _notify(app, pick);
      return pick;
    } catch (_) {
      return null;
    } finally {
      _busy = false;
    }
  }

  static Future<void> _notify(AppState app, JourneySuggestion s) async {
    final lang = app.locale?.languageCode == 'en' ? 'en' : 'bn';
    final t = lookupAppLocalizations(Locale(lang));
    await Notifications.showPayload(
      _notifId,
      t.sj2SuggestTitle(s.name),
      t.sj2SuggestBody,
      '$payloadPrefix${jsonEncode(s.toJson())}',
      actions: [
        AndroidNotificationAction(actionGo, t.sj2SuggestGo, showsUserInterface: true),
      ],
    );
  }

  static bool isOurs(NotificationResponse r) => (r.payload ?? '').startsWith(payloadPrefix);

  static JourneySuggestion? parse(String? payload) {
    final p = payload ?? '';
    if (!p.startsWith(payloadPrefix)) return null;
    try {
      return JourneySuggestion.fromJson(jsonDecode(p.substring(payloadPrefix.length)));
    } catch (_) {
      return null;
    }
  }
}
