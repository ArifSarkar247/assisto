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

  group('SnatchDetector', () {
    test('ignores a sample stream when the screen is locked', () {
      final d = SnatchDetector();
      var fired = false;
      for (var t = 0; t < 3000; t += 50) {
        fired |= d.onSample(magnitude: 40, tMs: t, unlocked: false);
      }
      expect(fired, isFalse);
    });

    test('a grab with no follow-through does NOT fire (dropped phone)', () {
      final d = SnatchDetector();
      // one big spike, then stillness
      expect(d.onSample(magnitude: 40, tMs: 0, unlocked: true), isFalse);
      var fired = false;
      for (var t = 100; t <= 3000; t += 100) {
        fired |= d.onSample(magnitude: 0.5, tMs: t, unlocked: true);
      }
      expect(fired, isFalse);
    });

    test('grab + sustained running fires exactly once', () {
      final d = SnatchDetector();
      final fires = <int>[];
      // grab
      if (d.onSample(magnitude: 40, tMs: 0, unlocked: true)) fires.add(0);
      // sustained motion through the whole follow window
      for (var t = 100; t <= 2600; t += 100) {
        if (d.onSample(magnitude: 10, tMs: t, unlocked: true)) fires.add(t);
      }
      expect(fires.length, 1);
    });

    test('below the grab threshold never arms', () {
      final d = SnatchDetector();
      var fired = false;
      for (var t = 0; t <= 3000; t += 100) {
        fired |= d.onSample(magnitude: 20, tMs: t, unlocked: true);
      }
      expect(fired, isFalse);
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
