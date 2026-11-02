import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../services/journey_tracker.dart' show readBatteryLevel;
import '../state.dart';
import 'dest_alarm_math.dart';
import 'dest_alarm_sound.dart';
import 'train_fgs.dart';

/// train: DESTINATION ALARM (owner final order 2 Nov). Rings BEFORE the
/// stop; works WITHOUT internet (distance on the phone; stations, bus stops
/// and the metro order are bundled). Modes:
///  * city bus — set distance (default 10 m), gentle vibration ~200 m before;
///  * long-distance bus / launch — default 2 km, "get ready" at ~10 km on
///    trips over 30 km;
///  * train — when the train LEAVES the station before yours; GPS distance
///    fallback;
///  * Dhaka Metro — one station before, by counting stations + time (no GPS).
/// NEVER-LATE: (distance − accuracy) ≤ set distance. Keeps ringing /
/// vibrating until "I'm awake". A location foreground service (with Stop)
/// runs only while an alarm is on (metro: GPS only corrects the count when a
/// fix happens to be at a station — the count itself needs no GPS).
class DestFix {
  final double lat, lng, accuracy;
  final double? speedMps;
  const DestFix(this.lat, this.lng, {this.accuracy = 0, this.speedMps});
}

typedef DestPositionFn = Future<DestFix?> Function();
typedef DestBatteryFn = Future<int?> Function();

class DestTarget {
  final String name; // shown / spoken, already in the user's language
  final double lat, lng;
  const DestTarget(this.name, this.lat, this.lng);
}

/// Everything one alarm needs.
class DestPlan {
  final TransportMode mode;
  final DestTarget target;
  final int setM;
  final AlertPrefs alerts;

  /// train: the station before yours (from the train's stop order).
  final DestTarget? prevStation;

  /// metro: station list + indexes + when the train left [metroFrom].
  final List<MetroStation> metro;
  final int metroFrom, metroTo;
  final DateTime? metroLeftAt;
  const DestPlan(
      {required this.mode,
      required this.target,
      required this.setM,
      this.alerts = const AlertPrefs(),
      this.prevStation,
      this.metro = const [],
      this.metroFrom = 0,
      this.metroTo = 0,
      this.metroLeftAt});
}

/// Localised text builders (the screen passes them in).
class DestAlarmTexts {
  final String notifTitle, notifText, stop, lang;

  /// "Wake up! <stop> — <distance>" (distance phrase may be empty).
  final String Function(String stop, String distance) spoken;
  final String Function(String stop, String distance) ready;
  const DestAlarmTexts(
      {required this.notifTitle,
      required this.notifText,
      required this.stop,
      required this.lang,
      required this.spoken,
      required this.ready});
}

enum DestAlarmPhase { off, watching, ringing }

@immutable
class DestAlarmState {
  final DestAlarmPhase phase;
  final DestPlan? plan;
  final double? distanceM, accuracyM;
  final bool locationOff, serviceOn;
  final Duration interval;
  final int? metroAt;          // metro: station index by the clock
  final DateTime? metroRingAt;
  final AlarmEvent lastEvent;
  const DestAlarmState(
      {this.phase = DestAlarmPhase.off,
      this.plan,
      this.distanceM,
      this.accuracyM,
      this.locationOff = false,
      this.serviceOn = false,
      this.interval = kMinInterval,
      this.metroAt,
      this.metroRingAt,
      this.lastEvent = AlarmEvent.none});

  DestAlarmState copyWith(
          {DestAlarmPhase? phase,
          double? distanceM,
          double? accuracyM,
          bool? locationOff,
          bool? serviceOn,
          Duration? interval,
          int? metroAt,
          DateTime? metroRingAt,
          AlarmEvent? lastEvent}) =>
      DestAlarmState(
          phase: phase ?? this.phase,
          plan: plan,
          distanceM: distanceM ?? this.distanceM,
          accuracyM: accuracyM ?? this.accuracyM,
          locationOff: locationOff ?? this.locationOff,
          serviceOn: serviceOn ?? this.serviceOn,
          interval: interval ?? this.interval,
          metroAt: metroAt ?? this.metroAt,
          metroRingAt: metroRingAt ?? this.metroRingAt,
          lastEvent: lastEvent ?? this.lastEvent);
}

/// Per-mode memory: the distance and the alert switches are remembered for
/// each transport mode separately (on the phone).
class DestModeMemory {
  static Future<(int, AlertPrefs)> load(TransportMode m) async {
    final spec = kModeSpecs[m]!;
    try {
      final raw = await Settings.getString(modeKey(m));
      if (raw == null || raw.isEmpty) return (spec.defaultM, const AlertPrefs());
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return (
        clampFor(m, (j['m'] as num?)?.toInt() ?? spec.defaultM),
        AlertPrefs.fromJson((j['alerts'] as Map?)?.cast<String, dynamic>())
      );
    } catch (_) {
      return (spec.defaultM, const AlertPrefs()); // best-effort: defaults
    }
  }

  static Future<void> save(TransportMode m, int setM, AlertPrefs a) =>
      Settings.setString(modeKey(m), jsonEncode({'m': clampFor(m, setM), 'alerts': a.toJson()}));
}

class DestAlarmController extends ValueNotifier<DestAlarmState> {
  DestAlarmController({
    DestPositionFn? position,
    DestBatteryFn? battery,
    DestAlarmSound? sound,
    DateTime Function()? clock,
    this.useService = true,
    this.repeatEvery = const Duration(seconds: 10),
  })  : _position = position ?? _gps,
        _battery = battery ?? readBatteryLevel,
        _sound = sound ?? NativeDestAlarmSound(),
        _clock = clock ?? DateTime.now,
        super(const DestAlarmState());

  static DestAlarmController I = DestAlarmController();

  final DestPositionFn _position;
  final DestBatteryFn _battery;
  final DestAlarmSound _sound;
  final DateTime Function() _clock;
  final bool useService;
  final Duration repeatEvery;
  Timer? _timer, _repeat;
  bool _busy = false;
  DestAlarmTexts? _texts;
  DistanceWatch? _dw;
  TrainLegWatch? _tw;
  bool _bn = true;

  bool get on => value.phase != DestAlarmPhase.off;

  Future<void> start(DestPlan plan, DestAlarmTexts texts) async {
    await stop();
    _texts = texts;
    _bn = texts.lang == 'bn';
    _dw = null;
    _tw = null;
    if (plan.mode == TransportMode.train && plan.prevStation != null) {
      final p = plan.prevStation!;
      _tw = TrainLegWatch(haversineM(p.lat, p.lng, plan.target.lat, plan.target.lng),
          fallbackM: plan.setM);
    } else if (plan.mode != TransportMode.metro) {
      _dw = DistanceWatch(plan.mode, plan.setM);
    }
    value = DestAlarmState(phase: DestAlarmPhase.watching, plan: plan);
    if (useService) {
      final ok = await TrainFgs.I.acquire('alarm', _onFgs,
          title: texts.notifTitle, text: texts.notifText, stopLabel: texts.stop);
      value = value.copyWith(serviceOn: ok);
    }
    await tick();
  }

  void _onFgs(String msg) {
    if (msg == kTrainStopMsg) unawaited(stop());
    if (msg == kTrainTickMsg && _timer == null && value.phase == DestAlarmPhase.watching) {
      unawaited(tick());
    }
  }

  /// Metro: the user says "the train is leaving station X now" — recount.
  Future<void> metroResync(int stationIdx) async {
    final p = value.plan;
    if (p == null || p.mode != TransportMode.metro) return;
    final np = DestPlan(
        mode: p.mode,
        target: p.target,
        setM: p.setM,
        alerts: p.alerts,
        metro: p.metro,
        metroFrom: stationIdx,
        metroTo: p.metroTo,
        metroLeftAt: _clock());
    value = DestAlarmState(phase: DestAlarmPhase.watching, plan: np, serviceOn: value.serviceOn);
    if (_busy) {
      await _metroCount(np);
    } else {
      await tick();
    }
  }

  Future<void> tick() async {
    if (_busy || value.phase != DestAlarmPhase.watching) return;
    _busy = true;
    _timer?.cancel();
    _timer = null;
    try {
      final plan = value.plan!;
      if (plan.mode == TransportMode.metro) {
        await _metroTick(plan);
      } else {
        await _gpsTick(plan);
      }
      if (value.phase == DestAlarmPhase.watching) {
        _timer = Timer(value.interval, () {
          _timer = null;
          unawaited(tick());
        });
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _metroTick(DestPlan p) async {
    // optional: a GPS fix AT a later station (in the travel direction)
    // corrects the count; no fix / no GPS = pure station + time counting
    try {
      final fix = await _position();
      if (fix != null && fix.accuracy <= 150) {
        final step = p.metroTo > p.metroFrom ? 1 : -1;
        for (var i = p.metroFrom + step; i != p.metroTo + step; i += step) {
          final s = p.metro[i];
          if (haversineM(fix.lat, fix.lng, s.lat, s.lng) <= 120) {
            if (i != p.metroFrom) {
              await metroResync(i);
              return;
            }
          }
        }
      }
    } catch (_) {
      // best-effort: counting continues without GPS
    }
    await _metroCount(p);
  }

  Future<void> _metroCount(DestPlan p) async {
    final left = p.metroLeftAt ?? _clock();
    final at = metroRingAt(p.metro, p.metroFrom, p.metroTo, left);
    final now = _clock();
    value = value.copyWith(
        metroAt: metroStationAt(p.metro, p.metroFrom, p.metroTo, left, now),
        metroRingAt: at,
        interval: const Duration(seconds: 10));
    if (!now.isBefore(at)) await _ring('');
  }

  Future<void> _gpsTick(DestPlan p) async {
    DestFix? fix;
    try {
      fix = await _position();
    } catch (_) {
      fix = null; // best-effort: shown as "location off"
    }
    if (fix == null) {
      value = value.copyWith(locationOff: true, interval: kMinInterval * 2);
      return;
    }
    final t = p.target;
    final d = haversineM(fix.lat, fix.lng, t.lat, t.lng);
    int? batt;
    try {
      batt = await _battery();
    } catch (_) {
      batt = null; // best-effort: optional
    }
    final watchM = _tw != null ? TrainLegWatch.atM : p.setM;
    final iv = adaptiveInterval(_tw != null ? haversineM(fix.lat, fix.lng, p.prevStation!.lat, p.prevStation!.lng) : d,
        watchM, accuracyM: fix.accuracy, speedMps: fix.speedMps, batteryPct: batt);
    AlarmEvent ev;
    if (_tw != null) {
      final toPrev = haversineM(fix.lat, fix.lng, p.prevStation!.lat, p.prevStation!.lng);
      ev = _tw!.update(toPrev, d, fix.accuracy);
    } else {
      ev = _dw!.update(d, fix.accuracy);
    }
    value = value.copyWith(
        distanceM: d, accuracyM: fix.accuracy, locationOff: false, interval: iv, lastEvent: ev);
    final dist = spokenDistance(d, _bn);
    switch (ev) {
      case AlarmEvent.ring:
        await _ring(dist);
      case AlarmEvent.gentle:
        await _sound.vibrateOnce();
      case AlarmEvent.ready:
        await _sound.vibrateOnce();
        if (p.alerts.voice && _texts != null) {
          await _sound.speak(_texts!.ready(t.name, dist), _texts!.lang);
        }
      case AlarmEvent.none:
        break;
    }
  }

  Future<void> _ring(String dist) async {
    final p = value.plan!;
    _timer?.cancel();
    _timer = null;
    value = value.copyWith(phase: DestAlarmPhase.ringing);
    await _sound.start(sound: p.alerts.sound, vibrate: p.alerts.vibrate);
    Future<void> say() async {
      if (!p.alerts.voice || value.phase != DestAlarmPhase.ringing) return;
      final clip = p.alerts.personalClip;
      if (clip != null && clip.isNotEmpty) {
        await _sound.playClip(clip);
      } else if (_texts != null) {
        await _sound.speak(_texts!.spoken(p.target.name, dist), _texts!.lang);
      }
    }

    await say();
    // keeps going until the user confirms "I'm awake"
    _repeat = Timer.periodic(repeatEvery, (_) => unawaited(say()));
  }

  /// The big "আমি জেগে আছি" button (and the notification's Stop).
  Future<void> confirmAwake() => stop();

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _repeat?.cancel();
    _repeat = null;
    final wasRinging = value.phase == DestAlarmPhase.ringing;
    final plan = value.plan;
    value = const DestAlarmState();
    if (wasRinging) await _sound.stop();
    if (useService && plan != null) {
      await TrainFgs.I.release('alarm');
    }
  }
}

Future<DestFix?> _gps() async {
  if (!await Geolocator.isLocationServiceEnabled()) return null;
  final perm = await Geolocator.checkPermission();
  if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
    return null;
  }
  final p = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 20)));
  return DestFix(p.latitude, p.longitude,
      accuracy: p.accuracy, speedMps: p.speed >= 0 ? p.speed : null);
}
