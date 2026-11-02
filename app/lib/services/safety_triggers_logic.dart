import 'dart:math' as math;

/// sosat — PURE rules for the SOS triggers that run inside the existing
/// Always-on protection foreground service (AntiTheftService). Kotlin mirror:
/// android_overlay/.../antitheft/SafetyTriggers.kt (keep the numbers in
/// sync). Unit-tested here, and measured on labelled sensor traces by
/// test/sosat_fall_harness_test.dart + test/sosat_snatch_harness_test.dart.
///
/// Nothing here dials 999. A fall or a power-button SOS only ever goes to the
/// family, after a countdown the person can cancel.

/// Standard gravity (m/s²) — Android SensorManager.GRAVITY_EARTH.
const double kGravity = 9.80665;

/// EXPERIMENTAL fall detector: free fall -> impact -> lying still, with the
/// phone's orientation changed (a jump or a stumble that ends standing is
/// not a fall). Fed RAW accelerometer samples (gravity included).
///
/// Honest limits (also in the feature card): a phone DROPPED on a hard floor
/// and left there looks exactly like this — that is why every detection first
/// asks "Are you OK?" and waits; a slow slump to the floor (no free fall) is
/// MISSED; a person who moves a lot right after the fall is MISSED (they can
/// press SOS themselves).
class FallPolicy {
  static const double freeFallMax = 0.5 * kGravity; // m/s²
  static const int freeFallMinMs = 120;
  static const double impactMin = 2.5 * kGravity;
  static const int impactWithinMs = 800; // after the free fall ends
  static const int settleMs = 1000; // bounce / roll after the impact
  static const int stillMs = 3000; // then this long lying still
  static const double stillTol = 1.2; // |m - g| for a "still" sample
  static const double stillFraction = 0.85;
  static const double orientChangeDeg = 35;
  static const int cooldownMs = 60000;

  /// "Are you OK?" countdown (seconds) — the user's setting, clamped like
  /// the server (core/sos_triggers.py).
  static const int windowDefaultS = 60;
  static const int windowMinS = 30;
  static const int windowMaxS = 600;
  static int clampWindow(int s) => s.clamp(windowMinS, windowMaxS);
}

enum _FallPhase { idle, falling, awaitImpact, settling, still }

class FallDetector {
  _FallPhase _phase = _FallPhase.idle;
  int _ffStart = 0;
  int _ffEnd = 0;
  int _impactAt = 0;
  int _cooldownUntil = 0;
  int _stillN = 0;
  int _stillOk = 0;
  // low-passed gravity direction before the fall and while lying still
  List<double> _grav = const [0, 0, kGravity];
  List<double> _before = const [0, 0, kGravity];
  List<double> _after = const [0, 0, 0];

  static double mag(double x, double y, double z) =>
      math.sqrt(x * x + y * y + z * z);

  static double angleDeg(List<double> a, List<double> b) {
    final na = mag(a[0], a[1], a[2]), nb = mag(b[0], b[1], b[2]);
    if (na < 1e-6 || nb < 1e-6) return 0;
    final c = ((a[0] * b[0] + a[1] * b[1] + a[2] * b[2]) / (na * nb))
        .clamp(-1.0, 1.0);
    return math.acos(c) * 180 / math.pi;
  }

  void reset() {
    _phase = _FallPhase.idle;
    _stillN = 0;
    _stillOk = 0;
  }

  /// Feed one raw sample; returns true exactly once when a fall completes.
  bool onSample(double x, double y, double z, int tMs) {
    final m = mag(x, y, z);
    if (tMs < _cooldownUntil) return false;
    if (_phase == _FallPhase.idle) {
      // slow gravity estimate while nothing is happening
      if ((m - kGravity).abs() < 2.0) {
        _grav = [
          _grav[0] * 0.9 + x * 0.1,
          _grav[1] * 0.9 + y * 0.1,
          _grav[2] * 0.9 + z * 0.1,
        ];
      }
      if (m < FallPolicy.freeFallMax) {
        _phase = _FallPhase.falling;
        _ffStart = tMs;
        _before = List.of(_grav);
      }
      return false;
    }
    if (_phase == _FallPhase.falling) {
      if (m < FallPolicy.freeFallMax) return false;
      _ffEnd = tMs;
      if (_ffEnd - _ffStart < FallPolicy.freeFallMinMs) {
        reset();
        return false;
      }
      _phase = _FallPhase.awaitImpact; // this sample may be the impact
    }
    if (_phase == _FallPhase.awaitImpact) {
      if (m >= FallPolicy.impactMin) {
        _phase = _FallPhase.settling;
        _impactAt = tMs;
      } else if (tMs - _ffEnd > FallPolicy.impactWithinMs) {
        reset();
      }
      return false;
    }
    if (_phase == _FallPhase.settling) {
      if (tMs - _impactAt >= FallPolicy.settleMs) {
        _phase = _FallPhase.still;
        _stillN = 0;
        _stillOk = 0;
        _after = [0, 0, 0];
      }
      return false;
    }
    // _FallPhase.still
    _stillN++;
    if ((m - kGravity).abs() <= FallPolicy.stillTol) _stillOk++;
    _after = [_after[0] + x, _after[1] + y, _after[2] + z];
    if (tMs - _impactAt < FallPolicy.settleMs + FallPolicy.stillMs) {
      return false;
    }
    final still =
        _stillN > 0 && _stillOk / _stillN >= FallPolicy.stillFraction;
    final turned = angleDeg(_before, _after) >= FallPolicy.orientChangeDeg;
    reset();
    if (still && turned) {
      _cooldownUntil = tMs + FallPolicy.cooldownMs;
      return true;
    }
    return false;
  }
}

/// Power button pressed 5 times within 4 s (each press toggles the screen,
/// which the running protection service already hears) -> a 10 s countdown
/// the person can cancel -> SOS to the family. Opt-in, default OFF.
class PowerPressPolicy {
  static const int presses = 5;
  static const int windowMs = 4000;
  static const int cooldownMs = 60000;

  /// Lock-screen and power-button SOS: seconds to cancel before it goes.
  static const int cancelWindowS = 10;
}

class PowerPressCounter {
  final List<int> _t = [];
  int _cooldownUntil = 0;

  /// One screen on/off toggle at [tMs]; true when the pattern completes.
  bool onToggle(int tMs) {
    if (tMs < _cooldownUntil) return false;
    _t.add(tMs);
    _t.removeWhere((x) => tMs - x > PowerPressPolicy.windowMs);
    if (_t.length >= PowerPressPolicy.presses) {
      _t.clear();
      _cooldownUntil = tMs + PowerPressPolicy.cooldownMs;
      return true;
    }
    return false;
  }
}
