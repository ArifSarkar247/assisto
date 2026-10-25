import 'package:flutter_test/flutter_test.dart';
import 'package:assisto/services/antitheft_logic.dart';

/// b6-antitheft — pure logic tests (no Flutter widgets, no plugins), covering
/// the snatch pattern + the store-and-forward queue that the native Kotlin
/// engine mirrors. This is the "Kotlin-free logic test" the brief asks for.
void main() {
  group('heartbeatIntervalMin', () {
    test('battery-aware, matches native/backend', () {
      expect(
          heartbeatIntervalMin(batteryPct: 80, charging: true, lostMode: false),
          10);
      expect(
          heartbeatIntervalMin(batteryPct: 10, charging: false, lostMode: false),
          60);
      expect(
          heartbeatIntervalMin(batteryPct: 25, charging: false, lostMode: false),
          30);
      expect(
          heartbeatIntervalMin(batteryPct: 90, charging: false, lostMode: true),
          5);
      // critical battery wins even in lost mode
      expect(
          heartbeatIntervalMin(batteryPct: 5, charging: false, lostMode: true),
          60);
    });
  });

  // grab-guard (owner 25 Oct): only a real grab-and-run may fire.
  group('SnatchDetector + SnatchPolicy', () {
    const dt = 20; // ~50 Hz (SENSOR_DELAY_GAME)

    /// Feeds [ms] of samples from [t0]; returns how many times it fired.
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
    double grab(int _) => 34.0; // a hard yank (> both thresholds)
    double run(int i) => i % 4 == 0 ? 4.0 : 11.0; // ~75 % moving
    double jiggle(int i) => i % 3 == 0 ? 7.0 : 2.0; // ~33 % moving

    const inUse = SnatchContext(
        screenOn: true, unlocked: true, msSinceUnlock: 5 * 60000, hour: 14);
    const onTable = SnatchContext(hour: 14); // screen off, day
    const nightTable = SnatchContext(hour: 1); // 01:54-style

    int scenario(SnatchContext ctx, List<(int, double Function(int))> parts,
        {SnatchDetector? det}) {
      final d = det ?? SnatchDetector();
      var t = 0;
      var n = 0;
      for (final (ms, f) in parts) {
        n += feed(d, t, ms, f, ctx);
        t += ms;
      }
      return n;
    }

    test('pick-up from the table does not fire', () {
      expect(
          scenario(onTable, [
            (5000, still),
            (60, grab),
            (500, (_) => 3.0),
            (4000, still),
          ]),
          0);
    });

    test('put-down (even a slam) does not fire', () {
      expect(
          scenario(inUse, [
            (2000, (_) => 2.0),
            (60, grab),
            (4000, still),
          ]),
          0);
    });

    test('in-hand use: fresh unlock suppresses even a hard shake + walk', () {
      const fresh = SnatchContext(
          screenOn: true, unlocked: true, msSinceUnlock: 20000, hour: 14);
      expect(scenario(fresh, [(60, grab), (4000, run)]), 0);
    });

    test('in-hand use: a jolt then normal handling does not fire', () {
      expect(scenario(inUse, [(60, grab), (4000, jiggle), (500, still)]), 0);
    });

    test('charging never fires', () {
      const charging = SnatchContext(charging: true, hour: 14);
      expect(
          scenario(charging, [(5000, still), (60, grab), (4500, run)]), 0);
    });

    test('night bump by the bed does not fire', () {
      expect(
          scenario(nightTable, [(5000, still), (60, grab), (6000, still)]), 0);
      // a bump + a short shuffle that settles
      expect(
          scenario(nightTable, [
            (5000, still),
            (60, grab),
            (1500, run),
            (5000, still),
          ]),
          0);
    });

    test('night: a screen-on phone or one already moving never fires', () {
      const nightOn = SnatchContext(screenOn: true, unlocked: true, hour: 2);
      expect(scenario(nightOn, [(5000, still), (60, grab), (6000, run)]), 0);
      // no rest before the jolt (it was already moving, e.g. in a pocket)
      expect(scenario(nightTable, [(5000, run), (60, grab), (6000, run)]), 0);
    });

    test('night: a day-strength grab is not enough', () {
      expect(
          scenario(nightTable, [
            (5000, still),
            (60, (_) => 27.0),
            (6000, run),
          ]),
          0);
    });

    test('day screen off in a pocket (no rest) does not fire', () {
      expect(scenario(onTable, [(5000, run), (60, grab), (4000, run)]), 0);
    });

    test('a single-sample spike is debounced', () {
      expect(scenario(inUse, [(20, grab), (4000, run)]), 0);
    });

    test('REAL grab-and-run fires exactly once (then cooldown)', () {
      final d = SnatchDetector();
      expect(
          scenario(inUse, [(2000, (_) => 1.0), (60, grab), (4000, run)],
              det: d),
          1);
      // a second yank right after: cooldown, no second alert
      final t0 = 6060;
      expect(feed(d, t0, 60, grab, inUse) + feed(d, t0 + 60, 4000, run, inUse),
          0);
    });

    test('REAL night snatch from the nightstand fires', () {
      expect(
          scenario(nightTable, [(5000, still), (60, grab), (5600, run)]), 1);
    });

    test('day: grabbed off the table and carried away fires', () {
      expect(scenario(onTable, [(5000, still), (60, grab), (5600, run)]), 1);
      // the day-strength (3.5 s) pattern is not enough for a screen-off phone
      expect(scenario(onTable, [(5000, still), (60, grab), (3800, run)]), 0);
    });

    test('unlocking mid-window aborts', () {
      final d = SnatchDetector();
      var t = 0;
      var n = feed(d, t, 60, grab, inUse);
      t += 60;
      const unlockedNow = SnatchContext(
          screenOn: true, unlocked: true, msSinceUnlock: 100, hour: 14);
      n += feed(d, t, 4000, run, unlockedNow);
      expect(n, 0);
    });

    test('policy: night hours and profiles', () {
      expect(SnatchPolicy.isNight(23), isTrue);
      expect(SnatchPolicy.isNight(1), isTrue);
      expect(SnatchPolicy.isNight(6), isFalse);
      expect(SnatchPolicy.isNight(22), isFalse);
      expect(SnatchPolicy.profileFor(nightTable, restBefore: true)?.name,
          'night');
      expect(SnatchPolicy.profileFor(inUse, restBefore: false)?.name, 'day');
      expect(SnatchPolicy.profileFor(onTable, restBefore: true)?.name, 'night');
      expect(SnatchPolicy.profileFor(onTable, restBefore: false), isNull);
      expect(SnatchPolicy.confirmWindowMs, 60000);
    });
  });


  group('StoreAndForwardQueue', () {
    QueuedEvent ev(String id, int at) =>
        QueuedEvent(id: id, kind: 'offline', atMs: at);

    test('dedupes by id', () {
      final q = StoreAndForwardQueue();
      expect(q.add(ev('a', 10)), isTrue);
      expect(q.add(ev('a', 10)), isFalse);
      expect(q.length, 1);
    });

    test('batch is oldest-first regardless of insert order', () {
      final q = StoreAndForwardQueue();
      q.add(ev('new', 300));
      q.add(ev('old', 100));
      q.add(ev('mid', 200));
      final ids = q.batch().map((e) => e.id).toList();
      expect(ids, ['old', 'mid', 'new']);
    });

    test('ack removes accepted + duplicate ids', () {
      final q = StoreAndForwardQueue();
      q.add(ev('a', 1));
      q.add(ev('b', 2));
      q.add(ev('c', 3));
      q.ack(['a', 'c']);
      expect(q.batch().map((e) => e.id).toList(), ['b']);
    });

    test('caps size, dropping the oldest', () {
      final q = StoreAndForwardQueue(maxSize: 3);
      for (var i = 0; i < 5; i++) {
        q.add(ev('e$i', i));
      }
      expect(q.length, 3);
      // oldest (e0, e1) dropped
      expect(q.batch().map((e) => e.id).toList(), ['e2', 'e3', 'e4']);
    });

    test('toJson carries only the set fields', () {
      final e = QueuedEvent(
          id: 'x', kind: 'sim_change', atMs: 5, data: {'state': 'removed'},
          lat: 23.0, lng: 90.0, battery: 44);
      final j = e.toJson();
      expect(j['id'], 'x');
      expect(j['kind'], 'sim_change');
      expect(j['at'], 5);
      expect(j['data'], {'state': 'removed'});
      expect(j['lat'], 23.0);
      expect(j['battery'], 44);
    });
  });
}
