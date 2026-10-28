import 'dart:math' as math;

import 'route_canvas.dart';

/// e2e-vehicle: PURE Car Mode engine (no Flutter, no GPS, no clock) — the
/// phone-side twin of the server's `vehicle_tracking.evaluate_alerts`.
/// Feed it GPS fixes while Car Mode is on; it keeps the live speed, the
/// moving / stopped state and raises the same alert kinds the hardware
/// tracker does: `overspeed` (2 fixes over the limit, re-arms 10 km/h below),
/// `off_route` (3 fixes outside the planned-route corridor, only after the car
/// was ON the route; re-arms when back), `long_stop` (stopped >= stopAlertMin
/// while following the route). Arriving at the route's end disarms it.
enum CarAlertKind { overspeed, offRoute, longStop }

class CarAlert {
  final CarAlertKind kind;
  final DateTime at;
  final double speedKmh;
  final int distanceM;
  final int minutes;
  const CarAlert(this.kind, this.at,
      {this.speedKmh = 0, this.distanceM = 0, this.minutes = 0});
}

double haversineM(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  final p1 = lat1 * math.pi / 180, p2 = lat2 * math.pi / 180;
  final dp = p2 - p1, dl = (lng2 - lng1) * math.pi / 180;
  final a = math.pow(math.sin(dp / 2), 2) +
      math.cos(p1) * math.cos(p2) * math.pow(math.sin(dl / 2), 2);
  return 2 * r * math.asin(math.min(1.0, math.sqrt(a)));
}

double _segDistM(double lat, double lng, GeoPt a, GeoPt b) {
  final k = math.cos(lat * math.pi / 180);
  final ax = (a.lng - lng) * k * 111320.0, ay = (a.lat - lat) * 110574.0;
  final bx = (b.lng - lng) * k * 111320.0, by = (b.lat - lat) * 110574.0;
  final dx = bx - ax, dy = by - ay;
  final l2 = dx * dx + dy * dy;
  final t = l2 == 0 ? 0.0 : (-(ax * dx + ay * dy) / l2).clamp(0.0, 1.0);
  final px = ax + t * dx, py = ay + t * dy;
  return math.sqrt(px * px + py * py);
}

/// Metres from a point to a polyline (infinity for an empty route).
double routeDistanceM(List<GeoPt> route, double lat, double lng) {
  if (route.isEmpty) return double.infinity;
  if (route.length == 1) return haversineM(route[0].lat, route[0].lng, lat, lng);
  var best = double.infinity;
  for (var i = 0; i < route.length - 1; i++) {
    best = math.min(best, _segDistM(lat, lng, route[i], route[i + 1]));
  }
  return best;
}

class CarModeEngine {
  static const movingKmh = 5.0;
  static const offRouteFixes = 3;

  /// 0 = no speed alert.
  int speedLimitKmh;
  List<GeoPt> route;
  double corridorM;
  int stopAlertMin;

  CarModeEngine({
    this.speedLimitKmh = 0,
    this.route = const [],
    this.corridorM = 300,
    this.stopAlertMin = 10,
  });

  final List<GeoPt> trail = [];
  double speedKmh = 0;
  double maxSpeedKmh = 0;
  DateTime? stoppedSince;
  DateTime? lastAt;
  double? distanceToRouteM;
  bool armed = false, offRoute = false;
  int _overN = 0, _offN = 0;
  bool _overAlerted = false, _offAlerted = false, _stopAlerted = false;
  final List<CarAlert> alerts = [];

  bool get moving => speedKmh >= movingKmh;
  GeoPt? get live => trail.isEmpty ? null : trail.last;

  /// Whole minutes stopped as of the latest fix (0 while moving).
  int get stoppedMinutes => (stoppedSince == null || lastAt == null)
      ? 0
      : lastAt!.difference(stoppedSince!).inMinutes;

  /// Feed one GPS fix. Returns the alerts this fix raised (also appended to
  /// [alerts]). [speedKmh] < 0 / NaN (no GPS speed) is derived from the
  /// previous fix.
  List<CarAlert> add(double lat, double lng, DateTime at, double speedKmh) {
    var spd = speedKmh;
    final prev = live;
    if (!spd.isFinite || spd < 0) {
      spd = 0;
      if (prev?.at != null) {
        final dt = at.difference(prev!.at!).inMilliseconds / 1000.0;
        if (dt > 0) spd = haversineM(prev.lat, prev.lng, lat, lng) / dt * 3.6;
      }
    }
    spd = spd.clamp(0, 400).toDouble();
    if (trail.length >= 5000) trail.removeAt(0);
    trail.add(GeoPt(lat, lng, at: at, speed: spd));
    this.speedKmh = spd;
    lastAt = at;
    if (spd > maxSpeedKmh) maxSpeedKmh = spd;
    final out = <CarAlert>[];

    // overspeed (same debounce + hysteresis as the server)
    if (speedLimitKmh > 0) {
      if (spd > speedLimitKmh) {
        _overN++;
        if (_overN >= 2 && !_overAlerted) {
          _overAlerted = true;
          out.add(CarAlert(CarAlertKind.overspeed, at, speedKmh: spd));
        }
      } else {
        _overN = 0;
        if (spd < speedLimitKmh - 10) _overAlerted = false;
      }
    }

    // stop tracking
    if (spd < movingKmh) {
      stoppedSince ??= at;
    } else {
      stoppedSince = null;
      _stopAlerted = false;
    }

    // planned route
    if (route.length >= 2) {
      final d = routeDistanceM(route, lat, lng);
      distanceToRouteM = d;
      final end = route.last;
      final atEnd = haversineM(end.lat, end.lng, lat, lng) <= corridorM;
      if (d <= corridorM) {
        _offN = 0;
        _offAlerted = false;
        offRoute = false;
        if (atEnd) {
          armed = false;
          _stopAlerted = false;
        } else {
          armed = true;
        }
      } else if (armed) {
        _offN++;
        if (_offN >= offRouteFixes) {
          offRoute = true;
          if (!_offAlerted) {
            _offAlerted = true;
            out.add(CarAlert(CarAlertKind.offRoute, at, distanceM: d.round()));
          }
        }
      }
      if (armed && stopAlertMin > 0 && stoppedSince != null && !_stopAlerted) {
        final m = at.difference(stoppedSince!).inMinutes;
        if (m >= stopAlertMin) {
          _stopAlerted = true;
          out.add(CarAlert(CarAlertKind.longStop, at, minutes: m));
        }
      }
    } else {
      distanceToRouteM = null;
    }
    alerts.addAll(out);
    return out;
  }

  /// Down-sampled copy of a trail for saving as a planned route (<= max pts).
  static List<GeoPt> simplify(List<GeoPt> pts, {int max = 200}) {
    if (pts.length <= max) return List.of(pts);
    final step = (pts.length - 1) / (max - 1);
    return [for (var i = 0; i < max; i++) pts[(i * step).round()]];
  }
}
