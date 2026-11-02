import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import '../services/journey_tracker.dart' show readBatteryLevel;
import 'dest_alarm_math.dart';
import 'dest_alarm_sound.dart';
import 'train_fgs.dart';

/// train: DESTINATION ALARM — works WITHOUT internet: the distance to the
/// stop is computed on the phone from GPS (stations are bundled). Adaptive
/// GPS interval (far = slow, near = fast). While an alarm is on, a location
/// foreground service with a Stop button keeps it alive with the screen off;
/// nothing runs when no alarm is set.
class DestFix {
  final double lat, lng, accuracy;
  final double? speedMps;
  const DestFix(this.lat, this.lng, {this.accuracy = 0, this.speedMps});
}

typedef DestPositionFn = Future<DestFix?> Function();
typedef DestBatteryFn = Future<int?> Function();

class DestTarget {
  final String name; // spoken / shown, already in the user's language
  final double lat, lng;
  const DestTarget(this.name, this.lat, this.lng);
}

/// Text the alarm needs, already localised by the screen.
class DestAlarmTexts {
  final String notifTitle, notifText, stop, spoken;
  final String lang;
  const DestAlarmTexts(
      {required this.notifTitle,
      required this.notifText,
      required this.stop,
      required this.spoken,
      required this.lang});
}

enum DestAlarmPhase { off, watching, ringing }

@immutable
class DestAlarmState {
  final DestAlarmPhase phase;
  final DestTarget? target;
  final int radiusM;
  final double? distanceM;
  final bool locationOff;
  final Duration interval;
  final bool serviceOn;
  const DestAlarmState(
      {this.phase = DestAlarmPhase.off,
      this.target,
      this.radiusM = 1000,
      this.distanceM,
      this.locationOff = false,
      this.interval = kMinInterval,
      this.serviceOn = false});

  DestAlarmState copyWith(
          {DestAlarmPhase? phase,
          double? distanceM,
          bool? locationOff,
          Duration? interval,
          bool? serviceOn}) =>
      DestAlarmState(
          phase: phase ?? this.phase,
          target: target,
          radiusM: radiusM,
          distanceM: distanceM ?? this.distanceM,
          locationOff: locationOff ?? this.locationOff,
          interval: interval ?? this.interval,
          serviceOn: serviceOn ?? this.serviceOn);
}

class DestAlarmController extends ValueNotifier<DestAlarmState> {
  DestAlarmController({
    DestPositionFn? position,
    DestBatteryFn? battery,
    DestAlarmSound? sound,
    this.useService = true,
  })  : _position = position ?? _gps,
        _battery = battery ?? readBatteryLevel,
        _sound = sound ?? NativeDestAlarmSound(),
        super(const DestAlarmState());

  static DestAlarmController I = DestAlarmController();

  final DestPositionFn _position;
  final DestBatteryFn _battery;
  final DestAlarmSound _sound;
  final bool useService;
  Timer? _timer;
  Timer? _autoStop;
  bool _busy = false;
  DestAlarmTexts? _texts;

  bool get on => value.phase != DestAlarmPhase.off;

  Future<void> start(DestTarget target, int radiusM, DestAlarmTexts texts) async {
    await stop();
    _texts = texts;
    value = DestAlarmState(
        phase: DestAlarmPhase.watching, target: target, radiusM: clampRadius(radiusM));
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

  /// One GPS check; schedules the next one adaptively.
  Future<void> tick() async {
    if (_busy || value.phase != DestAlarmPhase.watching) return;
    _busy = true;
    _timer?.cancel();
    _timer = null;
    try {
      DestFix? fix;
      try {
        fix = await _position();
      } catch (_) {
        fix = null; // best-effort: shown as "location off"
      }
      final t = value.target!;
      if (fix == null) {
        value = value.copyWith(locationOff: true, interval: kMinInterval * 2);
      } else {
        final d = haversineM(fix.lat, fix.lng, t.lat, t.lng);
        int? batt;
        try {
          batt = await _battery();
        } catch (_) {
          batt = null; // best-effort: optional
        }
        final iv = adaptiveInterval(d, value.radiusM, speedMps: fix.speedMps, batteryPct: batt);
        value = value.copyWith(distanceM: d, locationOff: false, interval: iv);
        if (insideZone(d, value.radiusM, accuracyM: fix.accuracy)) {
          await _ring();
          return;
        }
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

  Future<void> _ring() async {
    value = value.copyWith(phase: DestAlarmPhase.ringing);
    await _sound.start();
    try {
      await HapticFeedback.vibrate();
    } catch (_) {
      // best-effort: no vibrator
    }
    final tx = _texts;
    if (tx != null) await _sound.speak(tx.spoken, tx.lang);
    // never ring forever (battery / a phone left on a seat): 5 minutes
    _autoStop = Timer(const Duration(minutes: 5), () => unawaited(stop()));
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _autoStop?.cancel();
    _autoStop = null;
    final wasRinging = value.phase == DestAlarmPhase.ringing;
    value = const DestAlarmState();
    if (wasRinging) await _sound.stop();
    if (useService) await TrainFgs.I.release('alarm');
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
