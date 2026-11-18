// proof-notif: a reminder made elsewhere (AI on another device, a family
// task, the website) while Assisto is open used to get NO phone alarm until a
// cold start — the list was never re-fetched on push / resume. The
// ReminderFreshness rules: which pushes mean "list changed", the resume
// throttle, force for pushes, one sync at a time, never throws.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/reminders/reminder_freshness.dart';

void main() {
  test('reminder-change pushes are recognised; others are not', () {
    expect(ReminderFreshness.isReminderChange({'kind': 'reminder'}), isTrue);
    expect(ReminderFreshness.isReminderChange({'kind': 'family_task', 'route': 'reminders'}), isTrue);
    expect(ReminderFreshness.isReminderChange({'kind': 'x', 'route': 'reminders'}), isTrue);
    expect(ReminderFreshness.isReminderChange({'kind': 'message', 'route': 'circle'}), isFalse);
    expect(ReminderFreshness.isReminderChange({'kind': 'sos'}), isFalse);
    expect(ReminderFreshness.isReminderChange(const {}), isFalse);
  });

  test('resume is throttled (60 s); a push forces a sync', () async {
    var now = DateTime(2026, 11, 18, 9);
    var n = 0;
    final f = ReminderFreshness(sync: () async => n++, clock: () => now);
    expect(await f.kick(), isTrue);
    now = now.add(const Duration(seconds: 20));
    expect(await f.kick(), isFalse, reason: 'resume 20 s later: no second GET');
    expect(await f.kick(force: true), isTrue, reason: 'a reminder push always syncs');
    now = now.add(const Duration(seconds: 61));
    expect(await f.kick(), isTrue);
    expect(n, 3);
  });

  test('one sync at a time', () async {
    final gate = Completer<void>();
    var n = 0;
    final f = ReminderFreshness(sync: () async {
      n++;
      await gate.future;
    });
    final first = f.kick(force: true);
    expect(await f.kick(force: true), isFalse);
    gate.complete();
    expect(await first, isTrue);
    expect(n, 1);
  });

  test('a failing sync (offline) never throws and the next trigger retries', () async {
    var now = DateTime(2026, 11, 18, 9);
    var n = 0;
    final f = ReminderFreshness(
        sync: () async {
          n++;
          throw Exception('offline');
        },
        clock: () => now);
    expect(await f.kick(), isTrue);
    now = now.add(const Duration(minutes: 2));
    expect(await f.kick(), isTrue);
    expect(n, 2);
  });

  test('no periodic timer inside widget tests (no pending-timer failures)', () {
    final f = ReminderFreshness(sync: () async {});
    f.startPeriodic();
    expect(f.periodicOn, isFalse);
    f.stopPeriodic();
  });
}
