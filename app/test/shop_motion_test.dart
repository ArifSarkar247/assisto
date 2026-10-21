import 'dart:typed_data';

import 'package:assisto/shop_motion.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _frame(int w, int h, int v, {Rect? box, int boxV = 255}) {
  final b = Uint8List(w * h)..fillRange(0, w * h, v);
  if (box != null) {
    for (var y = box.top.toInt(); y < box.bottom.toInt(); y++) {
      for (var x = box.left.toInt(); x < box.right.toInt(); x++) {
        b[y * w + x] = boxV;
      }
    }
  }
  return b;
}

class Rect {
  final double left, top, right, bottom;
  const Rect(this.left, this.top, this.right, this.bottom);
}

void main() {
  const w = 320, h = 240;

  test('static scene never reports motion', () {
    final d = MotionDetector();
    for (var i = 0; i < 6; i++) {
      final r = d.feed(_frame(w, h, 100), w, h, w);
      expect(r.motion, isFalse);
    }
  });

  test('a moving blob is confirmed only after 2 consecutive frames', () {
    final d = MotionDetector();
    d.feed(_frame(w, h, 100), w, h, w); // background
    final f = _frame(w, h, 100, box: const Rect(100, 80, 180, 160));
    final r1 = d.feed(f, w, h, w);
    expect(r1.motion, isFalse); // one frame is never enough
    final r2 = d.feed(f, w, h, w);
    expect(r2.motion, isTrue);
  });

  test('global lighting change resets the background, no motion', () {
    final d = MotionDetector();
    d.feed(_frame(w, h, 60), w, h, w);
    final r = d.feed(_frame(w, h, 200), w, h, w);
    expect(r.reset, isTrue);
    expect(r.motion, isFalse);
    expect(d.feed(_frame(w, h, 200), w, h, w).motion, isFalse);
  });

  test('zone: motion outside the cash zone is not "in zone"', () {
    final d = MotionDetector(zone: const ZoneRect(0.0, 0.0, 0.3, 0.3));
    d.feed(_frame(w, h, 100), w, h, w);
    final f = _frame(w, h, 100, box: const Rect(220, 160, 310, 230));
    d.feed(f, w, h, w);
    final r = d.feed(f, w, h, w);
    expect(r.motion, isTrue);
    expect(r.inZone, isFalse);
  });

  test('zone: motion inside the cash zone is reported', () {
    final d = MotionDetector(zone: const ZoneRect(0.25, 0.25, 0.75, 0.75));
    d.feed(_frame(w, h, 100), w, h, w);
    final f = _frame(w, h, 100, box: const Rect(110, 90, 210, 150));
    d.feed(f, w, h, w);
    expect(d.feed(f, w, h, w).inZone, isTrue);
  });

  test('row stride larger than width is handled', () {
    final d = MotionDetector();
    const stride = 384;
    final b = Uint8List(stride * h)..fillRange(0, stride * h, 90);
    expect(d.feed(b, w, h, stride).motion, isFalse);
  });

  test('isAfterHours mirrors the server rule', () {
    final hours = {'open': '09:00', 'close': '22:00'};
    expect(isAfterHours(hours, DateTime(2026, 10, 21, 8, 59)), isTrue);
    expect(isAfterHours(hours, DateTime(2026, 10, 21, 9, 0)), isFalse);
    expect(isAfterHours(hours, DateTime(2026, 10, 21, 22, 0)), isTrue);
    final night = {'open': '18:00', 'close': '02:00'};
    expect(isAfterHours(night, DateTime(2026, 10, 21, 1, 0)), isFalse);
    expect(isAfterHours(night, DateTime(2026, 10, 21, 3, 0)), isTrue);
    expect(isAfterHours(null, DateTime(2026, 10, 21, 3, 0)), isFalse);
    expect(isAfterHours({'open': '9', 'close': 'x'}, DateTime(2026, 10, 21, 3)), isFalse);
  });

  test('decideEvent: closed -> after_hours; open+zone -> motion; open no zone -> none', () {
    const moved = MotionResult(motion: true, inZone: true, changedFrac: 0.1);
    final a = decideEvent(moved, afterHours: true, hasZone: false);
    expect(a!.type, 'after_hours');
    expect(a.signals['after_hours'], isTrue);
    final b = decideEvent(moved, afterHours: false, hasZone: true);
    expect(b!.type, 'motion');
    expect(b.signals['zone_breach'], isTrue);
    expect(decideEvent(moved, afterHours: false, hasZone: false), isNull);
    const still = MotionResult(motion: false, inZone: false, changedFrac: 0);
    expect(decideEvent(still, afterHours: true, hasZone: true), isNull);
  });

  test('ZoneRect json round trip + validation', () {
    const z = ZoneRect(0.1, 0.2, 0.6, 0.9);
    expect(ZoneRect.fromJson(z.toJson())!.right, 0.6);
    expect(ZoneRect.fromJson({'left': 0.5, 'top': 0, 'right': 0.2, 'bottom': 1}), isNull);
  });
}
