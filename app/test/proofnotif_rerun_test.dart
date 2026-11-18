// proof-notif: the reminder-alarm reconcile used to DROP a change that came
// in while a reconcile was running (`if (_running) return`). On app start a
// Snooze tapped while the app was closed patches the reminder during the
// start-up reconcile -> its new alarm was never set. SerialRerun keeps one
// run at a time and re-runs the LATEST queued list right after.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/reminders/reminder_alarms.dart';

void main() {
  test('a call while running is re-run after it, with the newest argument',
      () async {
    final g = SerialRerun<String>();
    final gate = Completer<void>();
    final seen = <String>[];
    Future<void> body(String a) async {
      seen.add(a);
      if (a == 'start') await gate.future;
    }

    final first = g.run('start', body);
    expect(g.busy, isTrue);
    // two changes arrive while the first run waits on the platform
    await g.run('list+R1', body);
    await g.run('list+R1+R2', body);
    expect(seen, ['start'], reason: 'nothing runs in parallel');
    gate.complete();
    await first;
    expect(seen, ['start', 'list+R1+R2'],
        reason: 'the newest list runs once; the older queued one is superseded');
    expect(g.busy, isFalse);
  });

  test('no queued call -> exactly one run', () async {
    final g = SerialRerun<int>();
    var n = 0;
    await g.run(1, (_) async => n++);
    await g.run(2, (_) async => n++);
    expect(n, 2);
  });

  test('a throwing run still re-runs the queued change, then rethrows',
      () async {
    final g = SerialRerun<String>();
    final gate = Completer<void>();
    final seen = <String>[];
    Future<void> body(String a) async {
      seen.add(a);
      if (a == 'boom') {
        await gate.future;
        throw StateError('platform channel failed');
      }
    }

    final first = g.run('boom', body);
    await g.run('after', body);
    gate.complete();
    await expectLater(first, throwsStateError);
    expect(seen, ['boom', 'after']);
    expect(g.busy, isFalse);
  });

  test('ReminderAlarms.reconcile is a no-op (and never busy) when local '
      'notifications are not initialised', () async {
    await ReminderAlarms.reconcile(const []);
    expect(ReminderAlarms.rerun.busy, isFalse);
  });
}
