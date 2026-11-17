import 'dart:math' as math;

import 'package:assisto/services/antitheft_logic.dart';
import 'package:flutter_test/flutter_test.dart';

/// flag-antitheft (17 Nov) — the stronger grab rule, Kotlin-free (the native
/// SnatchPolicy.kt / SnatchDetector.kt mirror these 1:1):
///   * a grab counts only with motion through all three thirds of the follow
///     window AND a steady running rhythm (GaitRules);
///   * the owner's sensitivity (low = never from the unlocked hand);
///   * unlocking with the phone's own secure lock inside the 15 s window
///     cancels (GrabCancel).
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
  double grab(int _) => 36.0;
  // a fleeing thief: |sin| stride rhythm, ~2.8 steps/s, strong
  double run(int i) => 2.0 + 13.0 * math.sin(i * dt / 1000 * math.pi * 2.8).abs();
  // a bumpy rickshaw / bus: strong but IRREGULAR (seeded)
  final rnd = math.Random(7);
  final bumpy = List<double>.generate(2000, (_) => 3.0 + rnd.nextDouble() * 12.0);
  double rickshaw(int i) => bumpy[i % bumpy.length];

  const inUse = SnatchContext(
      screenOn: true, unlocked: true, msSinceUnlock: 5 * 60000, hour: 19);
  const onTable = SnatchContext(hour: 17);

  int scenario(SnatchContext ctx, double Function(int) after,
      {String sens = SnatchSensitivity.normal, SnatchDetector? det}) {
    final d = det ?? SnatchDetector(sensitivity: sens);
    var n = feed(d, 0, 5000, ctx == onTable ? still : (_) => 2.0, ctx);
    n += feed(d, 5000, 60, grab, ctx);
    n += feed(d, 5060, 6000, after, ctx);
    return n;
  }

  group('GaitRules.rhythm', () {
    test('a running rhythm is high, irregular shaking is low', () {
      final r = GaitRules.rhythm([for (var i = 0; i < 200; i++) run(i)], 20);
      expect(r.rhythm, greaterThan(0.6));
      expect(r.hz, inInclusiveRange(1.5, 6.0));
      final b = GaitRules.rhythm(bumpy.sublist(0, 200), 20);
      expect(b.rhythm, lessThan(0.35));
    });

    test('too few samples, flat or bad rate -> 0 (never crashes)', () {
      expect(GaitRules.rhythm([1, 2, 3], 20).rhythm, 0);
      expect(GaitRules.rhythm(List.filled(100, 5.0), 20).rhythm, 0);
      expect(GaitRules.rhythm(List.filled(100, 5.0), 0).rhythm, 0);
    });
  });

  group('SnatchDetector flag-antitheft rule', () {
    test('grab then a real run fires, with motion-only features', () {
      final d = SnatchDetector();
      expect(scenario(inUse, run, det: d), 1);
      final f = d.lastFeatures;
      expect(f['v'], 3);
      expect(f['in_use'], isTrue);
      expect(f['profile'], 'day');
      expect((f['rhythm'] as double), greaterThanOrEqualTo(0.5));
      expect((f['thirds'] as List).length, 3);
      for (final k in ['lat', 'lng', 'wifi', 'audio']) {
        expect(f.containsKey(k), isFalse);
      }
    });

    test('a bumpy rickshaw ride after a jolt never fires (any level)', () {
      for (final s in SnatchSensitivity.all) {
        expect(scenario(inUse, rickshaw, sens: s), 0, reason: s);
      }
    });

    test('motion that stops in the last third never fires', () {
      double runThenStop(int i) => i < 110 ? run(i) : 0.3;
      expect(scenario(inUse, runThenStop), 0);
    });

    test('table grab and run fires at every level', () {
      for (final s in SnatchSensitivity.all) {
        expect(scenario(onTable, run, sens: s), 1, reason: s);
      }
    });

    test('low never counts a grab from the unlocked hand', () {
      expect(scenario(inUse, run, sens: SnatchSensitivity.low), 0);
      expect(
          SnatchPolicy.profileFor(inUse,
              restBefore: false, sensitivity: SnatchSensitivity.low),
          isNull);
      // a phone lying still with the screen on still counts on low
      expect(
          SnatchPolicy.profileFor(inUse,
                  restBefore: true, sensitivity: SnatchSensitivity.low)
              ?.name,
          'day');
    });

    test('high lowers thresholds by 10 %', () {
      final p = SnatchPolicy.profileFor(inUse,
          restBefore: false, sensitivity: SnatchSensitivity.high)!;
      expect(p.grabThreshold, closeTo(SnatchPolicy.day.grabThreshold * 0.9, 1e-9));
      expect(p.runThreshold, closeTo(SnatchPolicy.day.runThreshold * 0.9, 1e-9));
      expect(GaitRules.minRhythm(SnatchSensitivity.high),
          lessThan(GaitRules.minRhythm(SnatchSensitivity.normal)));
    });

    test('unknown sensitivity falls back to normal', () {
      expect(SnatchSensitivity.clean('max'), SnatchSensitivity.normal);
      expect(SnatchSensitivity.clean(null), SnatchSensitivity.normal);
      expect(SnatchDetector(sensitivity: 'x').sensitivity,
          SnatchSensitivity.normal);
    });
  });

  group('GrabCancel + window', () {
    test('the "Are you OK?" window is 10-20 s', () {
      expect(SnatchPolicy.confirmWindowMs, inInclusiveRange(10000, 20000));
    });

    test('owner unlock with a secure lock inside the window cancels', () {
      expect(
          GrabCancel.ownerUnlockCancels(
              grabAtMs: 1000, unlockAtMs: 9000, deviceSecure: true),
          isTrue);
      // no secure lock: an unlock proves nothing
      expect(
          GrabCancel.ownerUnlockCancels(
              grabAtMs: 1000, unlockAtMs: 9000, deviceSecure: false),
          isFalse);
      // after the window / before the grab
      expect(
          GrabCancel.ownerUnlockCancels(
              grabAtMs: 1000,
              unlockAtMs: 1000 + SnatchPolicy.confirmWindowMs + 1,
              deviceSecure: true),
          isFalse);
      expect(
          GrabCancel.ownerUnlockCancels(
              grabAtMs: 1000, unlockAtMs: 900, deviceSecure: true),
          isFalse);
    });
  });
}
