// sosat — pure rules: power-button counter, fall window clamp, fall detector
// edge cases, SOS ladder mirror (backend core/logic/sos_ladder.py).
import 'package:assisto/services/safety_triggers_logic.dart';
import 'package:assisto/services/sos_ladder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PowerPressCounter', () {
    test('5 toggles within 4 s fire once, then cool down', () {
      final c = PowerPressCounter();
      final hits = [0, 500, 1000, 1500, 2000].map(c.onToggle).toList();
      expect(hits, [false, false, false, false, true]);
      // more presses right after: cooldown
      expect([2300, 2600, 2900, 3200, 3500].map(c.onToggle).any((x) => x), isFalse);
    });
    test('slow presses (normal screen use) never fire', () {
      final c = PowerPressCounter();
      final fired = List.generate(40, (i) => c.onToggle(i * 1500)).any((x) => x);
      expect(fired, isFalse);
    });
    test('the 4 s window slides', () {
      final c = PowerPressCounter();
      expect([0, 1000, 2000, 3000].map(c.onToggle).any((x) => x), isFalse);
      expect(c.onToggle(4500), isFalse); // the first press left the window
      expect(c.onToggle(4800), isTrue);
    });
  });

  test('fall window is clamped like the server (30 s – 10 min)', () {
    expect(FallPolicy.clampWindow(5), 30);
    expect(FallPolicy.clampWindow(60), 60);
    expect(FallPolicy.clampWindow(9999), 600);
  });

  group('FallDetector', () {
    List<List<double>> still(int n, List<double> g) => List.filled(n, g);
    int t = 0;
    bool feed(FallDetector d, List<List<double>> xs) {
      var f = false;
      for (final v in xs) {
        if (d.onSample(v[0], v[1], v[2], t)) f = true;
        t += 20;
      }
      return f;
    }

    test('free fall + impact + still with a new orientation = fall', () {
      t = 0;
      final d = FallDetector();
      var f = feed(d, still(100, [0, kGravity, 0]));
      f |= feed(d, still(15, [0, 1.0, 0])); // 300 ms free fall
      f |= feed(d, still(3, [0, 30.0, 0])); // impact
      f |= feed(d, still(250, [0, 0, kGravity])); // lying flat 5 s
      expect(f, isTrue);
    });
    test('same orientation afterwards (jump, lands standing) = no fall', () {
      t = 0;
      final d = FallDetector();
      var f = feed(d, still(100, [0, kGravity, 0]));
      f |= feed(d, still(15, [0, 1.0, 0]));
      f |= feed(d, still(3, [0, 30.0, 0]));
      f |= feed(d, still(250, [0, kGravity, 0]));
      expect(f, isFalse);
    });
    test('too short a free fall (bump) = no fall', () {
      t = 0;
      final d = FallDetector();
      var f = feed(d, still(100, [0, kGravity, 0]));
      f |= feed(d, still(2, [0, 1.0, 0])); // 40 ms
      f |= feed(d, still(3, [0, 30.0, 0]));
      f |= feed(d, still(250, [0, 0, kGravity]));
      expect(f, isFalse);
    });
    test('no impact (soft landing) = no fall', () {
      t = 0;
      final d = FallDetector();
      var f = feed(d, still(100, [0, kGravity, 0]));
      f |= feed(d, still(15, [0, 1.0, 0]));
      f |= feed(d, still(250, [0, 0, kGravity]));
      expect(f, isFalse);
    });
  });

  group('SosLadder mirror', () {
    final sent = [
      {'status': 'sent', 'received': false, 'seen': false}
    ];
    test('stages', () {
      expect(SosLadder.stage(sent, null), SosLadder.none);
      expect(SosLadder.stage(sent, 10), SosLadder.waiting);
      expect(SosLadder.stage(sent, 120), SosLadder.rerung);
      expect(SosLadder.stage(sent, 300), SosLadder.call999);
      expect(SosLadder.stage([{'status': 'sent', 'seen': true}], 300), SosLadder.seen);
      expect(SosLadder.stage(sent, 10, isResolved: true), SosLadder.resolved);
      expect(SosLadder.stage([{'status': 'no_device'}], 10), SosLadder.noOne);
      expect(SosLadder.stage(sent, SosLadder.windowS + 1), SosLadder.none);
    });
  });
}
