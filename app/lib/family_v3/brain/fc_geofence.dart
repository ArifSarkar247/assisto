import 'dart:math' as math;

/// fcbrain — the ON-PHONE geofence rule for automatic "arrived / left"
/// (Family Care v3 BRAIN 2). Pure Dart, no plugin, no network, no Google
/// API (zero Google cost).
///
/// The native FamilyWatchService.kt runs the SAME rule with the SAME
/// constants (kept in step by fc_brain_test.dart's constant check against
/// the Kotlin source). This file is what the CI measures: the fake-GPS trip
/// simulation in fc_brain_test.dart drives [FcFenceEngine] + [FcFencePolicy]
/// over hundreds of seeded trips and asserts the owner's target — arrival
/// news within 2 minutes in at least 95 % of arrivals.
///
/// Rule (same radius as the Safe Journey / school arrival check, 150 m):
///  * ENTER when distance <= r + min(accuracy, 50 m) — one fix is enough;
///  * LEAVE when distance > r + 100 m + min(accuracy, 100 m) on TWO fixes in
///    a row (hysteresis: no flapping at the gate);
///  * a fix worse than 250 m decides nothing;
///  * the first fix after switching on only learns where we are (no
///    "arrived Home" the moment you turn it on).
/// Next check (battery): far from every fence -> sleep until we could
/// possibly reach the nearest edge at 60 km/h (min 60 s, max 15 min);
/// inside a fence -> every 5 min, 15 min when the phone is still.

class FcFenceK {
  static const double vmaxMps = 16.7; // 60 km/h: Dhaka road speed bound
  static const int minDelayS = 60;
  static const int maxDelayS = 900;
  static const int insideDelayS = 300;
  static const int stillDelayS = 900;
  static const double leaveMarginM = 100;
  static const double enterAccCapM = 50;
  static const double leaveAccCapM = 100;
  static const double maxAccM = 250;
  static const double nearM = 600; // closer than this -> precise (GPS) fix
  static const double stillM = 30;
  static const int defaultRadiusM = 150;
}

class FcFence {
  final int id;
  final String kind; // home | school | office | place
  final String label;
  final double lat, lng;
  final double r;
  const FcFence(this.id, this.kind, this.lat, this.lng,
      {this.label = '', this.r = 150});

  static FcFence? fromJson(Object? m) {
    if (m is! Map) return null;
    final id = (m['id'] as num?)?.toInt();
    final lat = (m['lat'] as num?)?.toDouble();
    final lng = (m['lng'] as num?)?.toDouble();
    if (id == null || lat == null || lng == null) return null;
    return FcFence(id, (m['kind'] ?? 'place').toString(), lat, lng,
        label: (m['label'] ?? '').toString(),
        r: ((m['r'] as num?) ?? FcFenceK.defaultRadiusM).toDouble());
  }
}

class FcFix {
  final double lat, lng, acc;
  final DateTime at;
  const FcFix(this.lat, this.lng, this.acc, this.at);
}

class FcFenceEvent {
  final String kind; // arrive | leave
  final FcFence fence;
  final DateTime at;
  const FcFenceEvent(this.kind, this.fence, this.at);
}

/// Great-circle distance in metres (haversine).
double fcDistanceM(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  final p1 = lat1 * math.pi / 180, p2 = lat2 * math.pi / 180;
  final dp = (lat2 - lat1) * math.pi / 180, dl = (lng2 - lng1) * math.pi / 180;
  final a = math.sin(dp / 2) * math.sin(dp / 2) +
      math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2 * r * math.asin(math.min(1.0, math.sqrt(a)));
}

class FcFenceEngine {
  final List<FcFence> fences;
  final Set<int> inside = {};
  final Map<int, int> _outStreak = {};
  bool primed = false;
  FcFix? _prev;
  int stillCount = 0;

  FcFenceEngine(this.fences);

  /// Feed one fix; returns the arrive / leave events it proves.
  List<FcFenceEvent> step(FcFix f) {
    final out = <FcFenceEvent>[];
    final prev = _prev;
    if (prev != null) {
      stillCount = fcDistanceM(prev.lat, prev.lng, f.lat, f.lng) < FcFenceK.stillM
          ? stillCount + 1
          : 0;
    }
    _prev = f;
    if (f.acc > FcFenceK.maxAccM || f.acc.isNaN) return out;
    for (final fe in fences) {
      final d = fcDistanceM(f.lat, f.lng, fe.lat, fe.lng);
      final isIn = inside.contains(fe.id);
      if (!isIn) {
        if (d <= fe.r + math.min(f.acc, FcFenceK.enterAccCapM)) {
          inside.add(fe.id);
          _outStreak[fe.id] = 0;
          if (primed) out.add(FcFenceEvent('arrive', fe, f.at));
        }
      } else {
        if (d > fe.r + FcFenceK.leaveMarginM + math.min(f.acc, FcFenceK.leaveAccCapM)) {
          final s = (_outStreak[fe.id] ?? 0) + 1;
          _outStreak[fe.id] = s;
          if (s >= 2 || !primed) {
            inside.remove(fe.id);
            _outStreak[fe.id] = 0;
            if (primed) out.add(FcFenceEvent('leave', fe, f.at));
          }
        } else {
          _outStreak[fe.id] = 0;
        }
      }
    }
    primed = true;
    return out;
  }

  /// Distance to the nearest fence EDGE we could cross next (0 = at it).
  double edgeM(FcFix f) {
    var best = double.infinity;
    for (final fe in fences) {
      final d = fcDistanceM(f.lat, f.lng, fe.lat, fe.lng);
      final e = inside.contains(fe.id)
          ? (fe.r + FcFenceK.leaveMarginM) - d
          : d - fe.r;
      best = math.min(best, math.max(0.0, e));
    }
    return best;
  }

  /// Seconds until the next fix (the battery policy).
  int nextDelayS(FcFix f) {
    if (fences.isEmpty) return FcFenceK.maxDelayS;
    if (inside.isNotEmpty) {
      return stillCount >= 2 ? FcFenceK.stillDelayS : FcFenceK.insideDelayS;
    }
    final s = (edgeM(f) / FcFenceK.vmaxMps).floor();
    return math.min(math.max(s, FcFenceK.minDelayS), FcFenceK.maxDelayS);
  }

  /// true -> ask for a precise (GPS) fix; false -> a cheap network fix.
  bool wantPrecise(FcFix f) => inside.isEmpty && edgeM(f) < FcFenceK.nearM;
}

/// Battery: 15 % -> share the last location ONCE per discharge.
class FcLowBattery {
  static const int low = 15;
  static const int rearm = 30;
  bool armed = true;

  /// true when this reading should share the last location now.
  bool check(int? pct, bool charging) {
    if (pct == null) return false;
    if (charging || pct >= rearm) {
      armed = true;
      return false;
    }
    if (pct <= low && armed) {
      armed = false;
      return true;
    }
    return false;
  }
}
