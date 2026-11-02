import 'dart:math' as math;

import 'dest_alarm_math.dart';

/// sjalarm (owner Safe Journey order 3 Nov, Card 2 "REAL LIFE"): ring when the
/// distance reaches the setting OR the time to arrive at the current speed is
/// about [kEtaRingS] seconds — whichever comes first — so nobody passes the
/// stop because the bus was fast or GPS fixes were sparse. Pure Dart, no
/// plugins: the live controller AND the CI trace replay
/// (test/dest_trace_replay_test.dart) both run exactly this code.

/// Seconds before arrival at which the speed rule rings.
const int kEtaRingS = 45;

/// Below this smoothed speed (m/s) the phone is treated as standing still:
/// GPS jitter in a traffic jam never rings the speed rule.
const double kStillMps = 1.2;

/// Faster than this (≈250 km/h) is a GPS glitch in Bangladesh.
const double kMaxPlausibleMps = 70;

/// Speed smoothing time constant (seconds): sparse fixes adopt the new speed
/// faster, dense 1 Hz fixes are averaged over ~6 s.
const double kSpeedTauS = 6;

/// Fastest believable speed-up (m/s per second) — a single jumped fix cannot
/// make a standing bus look fast.
const double kMaxAccelMps2 = 4;

/// Window (seconds) for speed from positions when the phone gives no
/// Doppler speed.
const int kSpeedWindowS = 15;

/// Beyond this margin (metres to the edge of the ringing zone) the battery
/// saving GPS is enough; nearer, high accuracy.
const double kLowPowerBeyondM = 3000;

enum RingReason { none, distance, eta }

class _Pt {
  final double lat, lng, acc;
  final DateTime at;
  const _Pt(this.lat, this.lng, this.acc, this.at);
}

/// Smoothed ground speed from GPS fixes. Uses the phone's own (Doppler)
/// speed when given; otherwise displacement over a short window, counted as
/// zero while the displacement is inside the GPS uncertainty (jitter).
class SpeedSmoother {
  final List<_Pt> _win = [];
  double _v = 0;
  bool _has = false;
  DateTime? _last;

  double get mps => _has ? _v : 0;

  double update(double lat, double lng, double accuracyM, DateTime at, {double? gpsSpeedMps}) {
    final acc = math.max(0.0, accuracyM);
    final prevAt = _last;
    if (prevAt != null && !at.isAfter(prevAt)) return mps; // duplicate / out of order
    _win.add(_Pt(lat, lng, acc, at));
    while (_win.length > 2 && at.difference(_win[1].at).inSeconds >= kSpeedWindowS) {
      _win.removeAt(0);
    }
    double? raw;
    if (gpsSpeedMps != null && gpsSpeedMps >= 0 && gpsSpeedMps <= kMaxPlausibleMps) {
      raw = gpsSpeedMps;
    } else if (_win.length >= 2) {
      final a = _win.first, b = _win.last;
      final dt = b.at.difference(a.at).inMilliseconds / 1000.0;
      if (dt > 0) {
        final d = haversineM(a.lat, a.lng, b.lat, b.lng);
        // moved less than the two fixes' uncertainty: no evidence of motion
        raw = d <= 0.5 * (a.acc + b.acc) ? 0.0 : math.min(d / dt, kMaxPlausibleMps);
      }
    }
    _last = at;
    if (raw == null) return mps;
    if (!_has) {
      _v = raw;
      _has = true;
      return _v;
    }
    final dt = prevAt == null ? 1.0 : math.max(0.001, at.difference(prevAt).inMilliseconds / 1000.0);
    raw = math.min(raw, _v + kMaxAccelMps2 * dt); // one jumped fix cannot spike
    final alpha = 1 - math.exp(-dt / kSpeedTauS);
    _v = _v + alpha * (raw - _v);
    return _v;
  }
}

/// THE decision: ring now? (distance − accuracy) ≤ setting, or the nearest
/// possible position is reached within [etaS] seconds at [speedMps].
RingReason decideRing(
    {required double distanceM,
    required double accuracyM,
    required int setM,
    double speedMps = 0,
    int etaS = kEtaRingS}) {
  if (neverLate(distanceM, accuracyM, setM)) return RingReason.distance;
  if (speedMps >= kStillMps) {
    final nearest = math.max(0.0, distanceM - math.max(0.0, accuracyM));
    if (nearest / speedMps <= etaS) return RingReason.eta;
  }
  return RingReason.none;
}

/// The ringing zone's radius right now (for the GPS interval).
int effectiveSetM(int setM, double speedMps, {int etaS = kEtaRingS}) =>
    math.max(setM, speedMps >= kStillMps ? (speedMps * etaS).round() : 0);

/// Battery: is a coarse (low-power) fix enough for this check? Only when the
/// ringing zone is far away even at a fast assumed speed.
bool lowPowerGpsOk(double distanceM, double accuracyM, int setM, double speedMps) {
  final v = math.max(speedMps, kAssumeSpeedMps);
  return distanceM - math.max(0.0, accuracyM) - effectiveSetM(setM, v) > kLowPowerBeyondM;
}

class DestStep {
  final AlarmEvent event;
  final RingReason reason;
  final Duration next;
  final double distanceM, speedMps;
  final bool lowPowerNext;
  const DestStep(this.event, this.reason, this.next, this.distanceM, this.speedMps, this.lowPowerNext);
}

/// One alarm's distance logic (city bus / long bus / launch / train without a
/// usable previous station): pre-alerts, the decision, the next GPS interval
/// and whether the next fix may be a battery-saving one.
class DestEngine {
  final TransportMode mode;
  final int setM;
  final double targetLat, targetLng;
  final DistanceWatch watch;
  final SpeedSmoother speed = SpeedSmoother();
  final int etaS;
  DestEngine(this.mode, this.setM, this.targetLat, this.targetLng, {this.etaS = kEtaRingS})
      : watch = DistanceWatch(mode, setM)..etaS = etaS;

  DestStep step(double lat, double lng, double accuracyM, DateTime at,
      {double? gpsSpeedMps, int? batteryPct}) {
    final v = speed.update(lat, lng, accuracyM, at, gpsSpeedMps: gpsSpeedMps);
    final d = haversineM(lat, lng, targetLat, targetLng);
    final ev = watch.update(d, accuracyM, speedMps: v);
    final next = adaptiveInterval(d, effectiveSetM(setM, v, etaS: etaS),
        accuracyM: accuracyM, speedMps: v, batteryPct: batteryPct);
    return DestStep(ev, watch.reason, next, d, v, lowPowerGpsOk(d, accuracyM, setM, v));
  }
}
