// perf2gb: image-cache cap on 2–3 GB phones (lib/perf/low_ram.dart).
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/perf/low_ram.dart';
import 'package:assisto/perf/perf_marks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('budget by RAM class', () {
    expect(LowRamTuning.budgetFor(ramMb: 1870, lowRam: false),
        const ImageCacheBudget(40 << 20, 300)); // "2 GB" phone
    expect(LowRamTuning.budgetFor(ramMb: 2800, lowRam: false),
        const ImageCacheBudget(64 << 20, 500)); // "3 GB" phone
    expect(LowRamTuning.budgetFor(ramMb: 5600, lowRam: false), isNull); // 6 GB: default
    expect(LowRamTuning.budgetFor(ramMb: 7600, lowRam: true),
        const ImageCacheBudget(40 << 20, 300)); // Android Go flag wins
    expect(LowRamTuning.budgetFor(ramMb: 0, lowRam: false), isNull); // unknown: default
  });

  test('a failing / slow device read keeps the defaults', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    LowRamTuning.resetForTest();
    final before = PaintingBinding.instance.imageCache.maximumSizeBytes;
    await LowRamTuning.apply(read: () => Future.error(StateError('no plugin')));
    expect(LowRamTuning.applied, isNull);
    expect(PaintingBinding.instance.imageCache.maximumSizeBytes, before);
  });

  test('not Android: nothing is read or changed', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    LowRamTuning.resetForTest();
    var called = false;
    await LowRamTuning.apply(read: () {
      called = true;
      return Future.error(StateError('x'));
    });
    expect(called, isFalse);
    expect(LowRamTuning.applied, isNull);
  });

  test('perf marks are compiled out of normal builds', () {
    expect(PerfMarks.enabled, isFalse);
    PerfMarks.once('x'); // no-op, never throws
  });
}
