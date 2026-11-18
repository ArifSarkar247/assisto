// cctv-accuracy: the IP-camera Guard Box night person check (owner-facing
// bug found by tools/cctvacc/run_clips.py on real IR clips: a person at
// night on an IP camera never alerted).
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/ipcam/ipcam_logic.dart';
import 'package:assisto/shop_motion.dart' show NightConfirm;

void main() {
  group('checkPersonOnce (ipcam night re-check)', () {
    // a fake guard detector: the real NightConfirm on top of raw boxes,
    // exactly like guardPersonDetector() in guard_box_model.dart
    ({Future<List<List<double>>?> Function(double t) detect, NightConfirm c}) night(
        List<bool> rawFound) {
      final c = NightConfirm();
      var i = 0;
      return (
        detect: (double t) async {
          final found = i < rawFound.length && rawFound[i];
          i++;
          final ok = c.check(found, night: true, now: t);
          return ok ? [<double>[0.1, 0.1, 0.4, 0.9, 0.5]] : <List<double>>[];
        },
        c: c,
      );
    }

    test('night: a person on two pictures in a row alerts (the next picture is checked at once)', () async {
      final n = night([true, true]);
      var asked = 0;
      final (boxes, pic) = await checkPersonOnce<double>(n.detect, 100.0, next: () async {
        asked++;
        return 100.33;
      }, nightPending: () => n.c.hits > 0 && n.c.hits < n.c.frames);
      expect(asked, 1);
      expect(boxes, isNotEmpty);
      expect(pic, 100.33, reason: 'the alert photo is the confirming picture');
    });

    test('night, the old 5-s spacing: two checks 5 s apart never confirm (the bug)', () async {
      final n = night([true, true]);
      expect(await n.detect(100.0), isEmpty);
      expect(await n.detect(105.0), isEmpty, reason: 'NightConfirm gap is 2 s');
    });

    test('night: one lucky frame (a moth, a reflection) is not an alert', () async {
      final n = night([true, false]);
      final (boxes, pic) = await checkPersonOnce<double>(n.detect, 1.0,
          next: () async => 1.33, nightPending: () => n.c.hits > 0 && n.c.hits < n.c.frames);
      expect(boxes, isEmpty);
      expect(pic, 1.0);
    });

    test('day: a found person returns at once, no second picture', () async {
      var asked = 0;
      final (boxes, _) = await checkPersonOnce<int>((_) async => [
            <double>[0, 0, 1, 1, 0.8]
          ], 1, next: () async {
        asked++;
        return 2;
      }, nightPending: () => false);
      expect(boxes, hasLength(1));
      expect(asked, 0);
    });

    test('no person and nothing pending: no second picture; a lost camera is safe', () async {
      var asked = 0;
      final (b1, _) = await checkPersonOnce<int>((_) async => <List<double>>[], 1, next: () async {
        asked++;
        return 2;
      }, nightPending: () => false);
      expect(b1, isEmpty);
      expect(asked, 0);
      final (b2, p2) = await checkPersonOnce<int>((_) async => <List<double>>[], 1,
          next: () async => null, nightPending: () => true);
      expect(b2, isEmpty);
      expect(p2, 1);
      final (b3, _) = await checkPersonOnce<int>((_) async => null, 1,
          next: () async => 2, nightPending: () => true);
      expect(b3, isNull, reason: 'a detector error stays an error (motion-only honesty)');
    });
  });
}
