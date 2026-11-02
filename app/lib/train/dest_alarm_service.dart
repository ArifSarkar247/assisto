import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../services/journey_tracker.dart' show readBatteryLevel;
import '../state.dart';
import 'dest_alarm_decide.dart';
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

  /// sjalarm: My Circle members (circle ids) told "arrived" when the user
  /// confirms "I am awake" after the alarm rang. Empty = nobody (default).
  final List<int> notifyCircleIds;
  const DestPlan(
      {required this.mode,
      required this.target,
      required this.setM,
      this.alerts = const AlertPrefs(),
      this.prevStation,
      this.metro = const [],
      this.metroFrom = 0,
      this.metroTo = 0,
      this.metroLeftAt,
      this.notifyCircleIds = const []});

  DestPlan withMetroFrom(int from, DateTime leftAt) => DestPlan(
      mode: mode,
      target: target,
      setM: setM,
      alerts: alerts,
      metro: metro,
      metroFrom: from,
      metroTo: metroTo,
      metroLeftAt: leftAt,
      notifyCircleIds: notifyCircleIds);
}

/// Sends the optional "arrived" notice (set by the screen: needs internet;
/// the alarm itself never does). Returns true when the server accepted it.
typedef DestArrivedFn = Future<bool> Function(DestPlan plan);

/// Localised text builders (the screen passes them in).
class DestAlarmTexts {
  final String notifTitle, notifText, stop, lang;

  /// "Wake up! <stop> — <distance>" (distance phrase may be empty).
  final String Function(String stop, String distance) spoken;
  final String Function(String stop, String distance) ready;

  /// Spoken distance words (e.g. "2 kilometres") from ARB strings.
  final String Function(double metres) distance;
  const DestAlarmTexts(
      {required this.distance,
      required this.notifTitle,
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

  /// sjalarm: smoothed speed, why it rang, snooze end (null = not snoozed).
  final double speedMps;
  final RingReason reason;
  final DateTime? snoozedUntil;

  /// null = no family notice asked / not yet; true sent; false failed (offline).
  final bool? arrivedSent;
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
      this.lastEvent = AlarmEvent.none,
      this.speedMps = 0,
      this.reason = RingReason.none,
      this.snoozedUntil,
      this.arrivedSent});

  DestAlarmState copyWith(
          {DestAlarmPhase? phase,
          double? distanceM,
          double? accuracyM,
          bool? locationOff,
          bool? serviceOn,
          Duration? interval,
          int? metroAt,
          DateTime? metroRingAt,
          AlarmEvent? lastEvent,
          double? speedMps,
          RingReason? reason,
          DateTime? snoozedUntil,
          bool clearSnooze = false}) =>
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
          lastEvent: lastEvent ?? this.lastEvent,
          speedMps: speedMps ?? this.speedMps,
          reason: reason ?? this.reason,
          snoozedUntil: clearSnooze ? null : (snoozedUntil ?? this.snoozedUntil),
          arrivedSent: arrivedSent);
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
    DestPositionFn? lowPowerPosition,
    DestBatteryFn? battery,
    DestAlarmSound? sound,
    DateTime Function()? clock,
    this.useService = true,
    this.repeatEvery = const Duration(seconds: 10),
  })  : _position = position ?? _gps,
        // a test that injects [position] gets it for both (no real GPS)
        _lowPower = lowPowerPosition ?? (position == null ? _gpsLow : position),
        _battery = battery ?? readBatteryLevel,
        _sound = sound ?? NativeDestAlarmSound(),
        _clock = clock ?? DateTime.now,
        super(const DestAlarmState());

  static DestAlarmController I = DestAlarmController();

  final DestPositionFn _position, _lowPower;

  /// sjalarm: optional family "arrived" notice (the screen sets it).
  static DestArrivedFn? arrivedNotifier;

  /// Snooze length ("I am awake" stops for good).
  static const Duration kSnooze = Duration(minutes: 1);
  final DestBatteryFn _battery;
  final DestAlarmSound _sound;
  final DateTime Function() _clock;
  final bool useService;
  final Duration repeatEvery;
  Timer? _timer, _repeat, _snooze;
  DestEngine? _eng;
  SpeedSmoother _trainSpeed = SpeedSmoother();
  bool _lowNext = false;
  String _lastDist = '';
  bool _busy = false;
  DestAlarmTexts? _texts;
  DistanceWatch? _dw;
  TrainLegWatch? _tw;

  bool get on => value.phase != DestAlarmPhase.off;

  Future<void> start(DestPlan plan, DestAlarmTexts texts) async {
    await stop();
    _texts = texts;
    _dw = null;
    _tw = null;
    _eng = null;
    _trainSpeed = SpeedSmoother();
    _lowNext = false;
    final pv = plan.prevStation;
    if (plan.mode == TransportMode.train && pv != null &&
        trainLegUsable(pv.lat, pv.lng, plan.target.lat, plan.target.lng)) {
      final p = pv;
      _tw = TrainLegWatch(haversineM(p.lat, p.lng, plan.target.lat, plan.target.lng),
          fallbackM: plan.setM);
    } else if (plan.mode != TransportMode.metro) {
      _eng = DestEngine(plan.mode, plan.setM, plan.target.lat, plan.target.lng);
      _dw = _eng!.watch;
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
    // Stop in the notification while ringing = "I am awake"
    if (msg == kTrainStopMsg) {
      unawaited(value.phase == DestAlarmPhase.ringing ? confirmAwake() : stop());
    }
    if (msg == kTrainTickMsg && _timer == null && value.phase == DestAlarmPhase.watching) {
      unawaited(tick());
    }
  }

  /// Metro: the user says "the train is leaving station X now" — recount.
  Future<void> metroResync(int stationIdx) async {
    final p = value.plan;
    if (p == null || p.mode != TransportMode.metro) return;
    final np = p.withMetroFrom(stationIdx, _clock());
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
      // battery: a coarse fix while the ringing zone is far away; never used
      // to ring — near (or when it says "near") a high-accuracy fix decides
      fix = await (_lowNext ? _lowPower() : _position());
      if (_lowNext && fix != null &&
          !lowPowerGpsOk(haversineM(fix.lat, fix.lng, p.target.lat, p.target.lng), fix.accuracy,
              p.setM, _eng?.speed.mps ?? _trainSpeed.mps)) {
        fix = await _position();
      }
    } catch (_) {
      fix = null; // best-effort: shown as "location off"
    }
    if (fix == null) {
      _lowNext = false;
      value = value.copyWith(locationOff: true, interval: kMinInterval * 2);
      return;
    }
    final t = p.target;
    final now = _clock();
    final d = haversineM(fix.lat, fix.lng, t.lat, t.lng);
    int? batt;
    try {
      batt = await _battery();
    } catch (_) {
      batt = null; // best-effort: optional
    }
    AlarmEvent ev;
    Duration iv;
    double v;
    if (_tw != null) {
      v = _trainSpeed.update(fix.lat, fix.lng, fix.accuracy, now, gpsSpeedMps: fix.speedMps);
      final toPrev = haversineM(fix.lat, fix.lng, p.prevStation!.lat, p.prevStation!.lng);
      iv = adaptiveInterval(math.min(toPrev, d), TrainLegWatch.atM,
          accuracyM: fix.accuracy, speedMps: v, batteryPct: batt);
      ev = _tw!.update(toPrev, d, fix.accuracy, speedMps: v);
      _lowNext = false;
    } else {
      final st = _eng!.step(fix.lat, fix.lng, fix.accuracy, now,
          gpsSpeedMps: fix.speedMps, batteryPct: batt);
      ev = st.event;
      iv = st.next;
      v = st.speedMps;
      _lowNext = st.lowPowerNext;
    }
    value = value.copyWith(
        distanceM: d,
        accuracyM: fix.accuracy,
        locationOff: false,
        interval: iv,
        lastEvent: ev,
        speedMps: v,
        reason: _eng?.watch.reason ?? (ev == AlarmEvent.ring ? RingReason.distance : null));
    final dist = _texts?.distance(d) ?? '';
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
    _snooze?.cancel();
    _snooze = null;
    _lastDist = dist;
    value = value.copyWith(phase: DestAlarmPhase.ringing, clearSnooze: true);
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

  /// sjalarm: "Snooze" — quiet for [kSnooze], then it rings again (the stop
  /// is near; only "I am awake" ends it).
  Future<void> snooze() async {
    if (value.phase != DestAlarmPhase.ringing || value.snoozedUntil != null) return;
    _repeat?.cancel();
    _repeat = null;
    await _sound.stop();
    value = value.copyWith(snoozedUntil: _clock().add(kSnooze));
    _snooze = Timer(kSnooze, () {
      _snooze = null;
      if (value.phase == DestAlarmPhase.ringing) unawaited(_ring(_lastDist));
    });
  }

  /// The big "I am awake" button (and the notification's Stop while
  /// ringing): stops, then sends the optional family "arrived" notice.
  Future<void> confirmAwake() async {
    final plan = value.plan;
    final rang = value.phase == DestAlarmPhase.ringing;
    await stop();
    final fn = arrivedNotifier;
    if (rang && plan != null && plan.notifyCircleIds.isNotEmpty && fn != null) {
      bool ok;
      try {
        ok = await fn(plan);
      } catch (_) {
        ok = false; // offline: the alarm already did its job; the screen says so
      }
      value = DestAlarmState(arrivedSent: ok);
    }
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _repeat?.cancel();
    _repeat = null;
    _snooze?.cancel();
    _snooze = null;
    final wasRinging = value.phase == DestAlarmPhase.ringing;
    final plan = value.plan;
    value = const DestAlarmState();
    if (wasRinging) await _sound.stop();
    if (useService && plan != null) {
      await TrainFgs.I.release('alarm');
    }
  }
}

Future<DestFix?> _gps() => _fix(LocationAccuracy.high);

/// Battery-saving fix while the stop is far away (decides only the interval).
Future<DestFix?> _gpsLow() => _fix(LocationAccuracy.medium);

Future<DestFix?> _fix(LocationAccuracy accuracy) async {
  if (!await Geolocator.isLocationServiceEnabled()) return null;
  final perm = await Geolocator.checkPermission();
  if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
    return null;
  }
  final p = await Geolocator.getCurrentPosition(
      locationSettings:
          LocationSettings(accuracy: accuracy, timeLimit: const Duration(seconds: 20)));
  return DestFix(p.latitude, p.longitude,
      accuracy: p.accuracy, speedMps: p.speed >= 0 ? p.speed : null);
}
