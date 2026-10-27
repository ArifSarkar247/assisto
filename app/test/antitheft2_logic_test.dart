import 'package:flutter_test/flutter_test.dart';
import 'package:assisto/services/antitheft_logic.dart';

/// antitheft2 (owner 27 Oct) — Kotlin-free tests of the rules the native
/// engine mirrors (SnatchPolicy.kt, FlushPolicy.kt):
///   * fewer false grabs: face-down + still, night on the home Wi-Fi unless
///     Night guard is ON (charging was already off);
///   * the store-and-forward queue is flushed when connectivity returns and
///     retried with backoff, never only on the next heartbeat / app open.
void main() {
  const dt = 20; // ~50 Hz

  int feed(SnatchDetector d, int t0, int ms, double Function(int i) mag,
      SnatchContext ctx) {
    var n = 0;
    var i = 0;
    for (var t = t0; t < t0 + ms; t += dt) {
      if (d.onSample(magnitude: mag(i++), tMs: t, ctx: ctx)) n++;
    }
    return n;
  }

  double still(int _) => 0.2;
  double grab(int _) => 34.0;
  double run(int i) => i % 4 == 0 ? 4.0 : 11.0;

  int grabAndRun(SnatchContext ctx) {
    final d = SnatchDetector();
    var n = feed(d, 0, 5000, still, ctx);
    n += feed(d, 5000, 60, grab, ctx);
    n += feed(d, 5060, 6000, run, ctx);
    return n;
  }

  group('SnatchPolicy antitheft2 suppression', () {
    test('baseline: a real grab-and-run at night (screen off) fires', () {
      expect(grabAndRun(const SnatchContext(hour: 1)), 1);
    });

    test('charging never fires', () {
      expect(grabAndRun(const SnatchContext(hour: 1, charging: true)), 0);
      expect(grabAndRun(const SnatchContext(hour: 14, charging: true)), 0);
    });

    test('face-down and still never fires (a toss on the bed)', () {
      expect(grabAndRun(const SnatchContext(hour: 1, faceDown: true)), 0);
      expect(grabAndRun(const SnatchContext(hour: 14, faceDown: true)), 0);
      expect(
          SnatchPolicy.profileFor(const SnatchContext(hour: 14, faceDown: true),
              restBefore: true),
          isNull);
    });

    test('face-down but NOT still (in a bag) is not the toss rule', () {
      // day, screen on, moving: the face-down rule needs restBefore
      expect(
          SnatchPolicy.profileFor(
              const SnatchContext(hour: 14, screenOn: true, faceDown: true),
              restBefore: false),
          SnatchPolicy.day);
    });

    test('night on the home Wi-Fi never fires while Night guard is OFF', () {
      expect(
          grabAndRun(const SnatchContext(hour: 1, onHomeWifi: true)), 0);
      expect(SnatchPolicy.homeNight(const SnatchContext(hour: 23, onHomeWifi: true)),
          isTrue);
    });

    test('Night guard ON keeps watching at home at night', () {
      expect(
          grabAndRun(const SnatchContext(
              hour: 1, onHomeWifi: true, nightGuard: true)),
          1);
    });

    test('home Wi-Fi in the DAY is not suppressed', () {
      expect(grabAndRun(const SnatchContext(hour: 14, onHomeWifi: true)), 1);
    });

    test('night away from home still fires', () {
      expect(grabAndRun(const SnatchContext(hour: 2)), 1);
    });
  });

  group('FlushPolicy (store-and-forward latency)', () {
    test('connectivity back with a queue -> flush in seconds', () {
      expect(FlushPolicy.flushOnConnectivity(connected: true, queued: 3),
          isTrue);
      expect(FlushPolicy.flushOnConnectivity(connected: true, queued: 0),
          isFalse);
      expect(FlushPolicy.flushOnConnectivity(connected: false, queued: 3),
          isFalse);
      expect(FlushPolicy.connectivityDelayMs, lessThanOrEqualTo(5000));
    });

    test('failed upload retries with backoff capped at 5 minutes', () {
      expect(FlushPolicy.retryDelayMs(1), 30000);
      expect(FlushPolicy.retryDelayMs(2), 60000);
      expect(FlushPolicy.retryDelayMs(3), 120000);
      expect(FlushPolicy.retryDelayMs(4), 240000);
      expect(FlushPolicy.retryDelayMs(5), 300000);
      expect(FlushPolicy.retryDelayMs(50), 300000);
      expect(FlushPolicy.retryDelayMs(0), 30000);
    });

    test('retry only when something is still queued', () {
      expect(FlushPolicy.scheduleRetry(uploadOk: false, queued: 1), isTrue);
      expect(FlushPolicy.scheduleRetry(uploadOk: false, queued: 0), isFalse);
      expect(FlushPolicy.scheduleRetry(uploadOk: true, queued: 5), isFalse);
    });

    test('a queued event reaches the server within 1 minute of reconnecting',
        () {
      // reconnect -> flush after connectivityDelayMs; if that first try
      // fails (network not ready yet) the first retry is 30 s later.
      expect(FlushPolicy.connectivityDelayMs + FlushPolicy.retryDelayMs(1),
          lessThan(60000));
    });
  });
}
