// fcelder — Silent Watch brain: window math, 7-day learning, ring time, and
// the SYNTHETIC-DAY SIMULATION that measures the false-alarm rate the owner
// set as the target (< 1 false family alert per family per month) and how
// fast a real emergency reaches the family.
//
// The simulator feeds the brain ONLY what the phone can really see (owner
// rule: no new sensitive permission): a ~15-min check that sees the screen in
// use at that instant, charger in/out (time-stamped conservatively at the
// previous check), Assisto opens / Care Call answers (exact). Then the same
// ladder as the phone: 3 rings 10 min apart, then the family.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/eldercare/silent_watch_brain.dart';

const _cfg = SwConfig(hours: 4, dayStartMin: 7 * 60, dayEndMin: 22 * 60);

DateTime _d(int day, int min) => DateTime(2026, 3, 1).add(Duration(days: day, minutes: min));

class _Interval {
  final DateTime a, b;
  _Interval(this.a, this.b);
  bool has(DateTime t) => !t.isBefore(a) && t.isBefore(b);
}

class _Day {
  late DateTime wake, sleep;
  final sessions = <_Interval>[];
  final away = <_Interval>[]; // out without the phone: cannot answer
  final nap = <_Interval>[];
  final exact = <DateTime>[]; // Assisto opens, Care Call answered
  late DateTime plugIn, unplug;
}

class _Elder {
  final math.Random r;
  final double perHour; // phone sessions per awake hour
  final double awayProb, napProb;
  _Elder(this.r)
      : perHour = 0.5 + r.nextDouble() * 1.5,
        awayProb = 0.05 + r.nextDouble() * 0.15,
        napProb = 0.3 + r.nextDouble() * 0.5;

  double _u(double a, double b) => a + r.nextDouble() * (b - a);

  _Day day(int d, {DateTime? stopAt}) {
    final x = _Day();
    x.wake = _d(d, _u(5 * 60 + 30, 7 * 60 + 30).round());
    x.sleep = _d(d, _u(21 * 60, 23 * 60).round());
    x.unplug = x.wake.add(Duration(minutes: _u(0, 60).round()));
    x.plugIn = x.sleep.subtract(Duration(minutes: _u(0, 40).round()));
    if (r.nextDouble() < napProb) {
      final s = _d(d, _u(13 * 60, 14 * 60 + 30).round());
      x.nap.add(_Interval(s, s.add(Duration(minutes: _u(40, 120).round()))));
    }
    if (r.nextDouble() < awayProb) {
      final s = _d(d, _u(9 * 60, 17 * 60).round());
      x.away.add(_Interval(s, s.add(Duration(minutes: _u(60, 240).round()))));
    }
    bool busy(DateTime t) => x.nap.any((i) => i.has(t)) || x.away.any((i) => i.has(t));
    var t = x.wake;
    while (t.isBefore(x.sleep)) {
      t = t.add(Duration(minutes: (-math.log(1 - r.nextDouble()) * 60 / perHour).round() + 1));
      if (t.isBefore(x.sleep) && !busy(t)) {
        x.sessions.add(_Interval(t, t.add(Duration(minutes: _u(2, 15).round()))));
      }
    }
    final opens = r.nextDouble() < 0.5 ? 1 : 2;
    for (var i = 0; i < opens; i++) {
      final o = x.wake.add(Duration(minutes: _u(0, x.sleep.difference(x.wake).inMinutes.toDouble()).round()));
      if (!busy(o)) x.exact.add(o);
    }
    final cc = _d(d, 10 * 60);
    if (cc.isAfter(x.wake) && !busy(cc)) x.exact.add(cc.add(const Duration(minutes: 1)));
    if (stopAt != null) {
      x.sessions.removeWhere((s) => !s.a.isBefore(stopAt));
      x.exact.removeWhere((e) => !e.isBefore(stopAt));
      if (!x.unplug.isBefore(stopAt)) x.unplug = _d(d + 400, 0);
      if (!x.plugIn.isBefore(stopAt)) x.plugIn = _d(d + 400, 0);
    }
    return x;
  }

  /// Does the elder answer one "Are you OK?" ring at [t]?
  bool answers(_Day x, DateTime t, DateTime? stopAt) {
    if (stopAt != null && !t.isBefore(stopAt)) return false;
    if (x.away.any((i) => i.has(t))) return false;
    if (t.isBefore(x.wake) || !t.isBefore(x.sleep)) return r.nextDouble() < 0.3;
    if (x.nap.any((i) => i.has(t))) return r.nextDouble() < 0.6;
    return r.nextDouble() < 0.8;
  }
}

/// What the phone observes on day [d] (probe instants within the window).
List<DateTime> _observe(_Day x, int d, math.Random r) {
  final out = <DateTime>[...x.exact];
  var plugged = true; // charged overnight
  DateTime? prevProbe = _d(d - 1, _cfg.dayEndMin - 15);
  for (var m = _cfg.dayStartMin; m < _cfg.dayEndMin; m += 15) {
    final p = _d(d, m + r.nextInt(9)); // inexact alarm: up to 9 min late
    if (x.sessions.any((s) => s.has(p))) out.add(p);
    final now = !p.isBefore(x.plugIn) || p.isBefore(x.unplug);
    if (now != plugged) out.add(prevProbe ?? p); // charger change: stamped at the previous check
    plugged = now;
    prevProbe = p;
  }
  return out..sort();
}

class _Result {
  int ringRuns = 0, familyAlerts = 0, familyDays = 0;
  final detect = <int>[];
}

_Result _simulate({required int families, required int seed, bool incident = false}) {
  final res = _Result();
  for (var f = 0; f < families; f++) {
    final r = math.Random(seed * 7919 + f);
    final e = _Elder(r);
    final log = <DateTime>[];
    final stopDay = 20;
    final stopAt = incident ? _d(stopDay, (9 * 60 + r.nextInt(9 * 60))) : null;
    final days = incident ? 22 : 37;
    final plan = <int, _Day>{};
    for (var d = 0; d < days; d++) {
      plan[d] = e.day(d, stopAt: (stopAt != null && d >= stopDay) ? stopAt : null);
      if (stopAt != null && d > stopDay) {
        plan[d]!
          ..sessions.clear()
          ..exact.clear();
      }
    }
    DateTime last = _d(0, 7 * 60);
    var alerted = false;
    for (var d = 0; d < days; d++) {
      final x = plan[d]!;
      final learned = SilentWatchBrain.learn(log, _d(d, 0), _cfg);
      final signals = _observe(x, d, r).where((s) => !s.isBefore(_d(d, 0))).toList();
      if (stopAt != null) signals.removeWhere((s) => !s.isBefore(stopAt));
      final dayEnd = _d(d + 1, 0);
      var i = 0;
      while (true) {
        final ring = SilentWatchBrain.ringAt(last, learned.tableMin, _cfg);
        final next = i < signals.length ? signals[i] : null;
        if (next != null && !next.isAfter(ring)) {
          if (next.isAfter(last)) {
            last = next;
            log.add(next);
          }
          i++;
          continue;
        }
        if (!ring.isBefore(dayEnd)) break;
        // the ladder on the phone: 3 rings, 10 min apart
        DateTime? answered;
        for (var k = 0; k < SilentWatchBrain.rings; k++) {
          final rt = ring.add(Duration(minutes: k * SilentWatchBrain.ringGapMin));
          final xd = plan[rt.difference(_d(0, 0)).inDays] ?? x;
          if (e.answers(xd, rt, stopAt)) {
            answered = rt;
            break;
          }
        }
        if (d >= SilentWatchBrain.learnDays) res.ringRuns++;
        if (answered != null) {
          last = answered;
          log.add(answered);
          continue;
        }
        final told = SilentWatchBrain.familyAt(ring);
        if (stopAt != null && !told.isBefore(stopAt)) {
          if (!alerted) res.detect.add(told.difference(stopAt).inMinutes);
          alerted = true;
          break;
        }
        if (d >= SilentWatchBrain.learnDays) res.familyAlerts++;
        // the family calls / the elder turns up later: the next real sign resets
        last = told;
        log.add(told);
      }
      if (alerted) break;
      if (d >= SilentWatchBrain.learnDays) res.familyDays++;
    }
  }
  return res;
}

void main() {
  group('window math', () {
    test('silence counts only inside the day window', () {
      expect(SilentWatchBrain.windowMinutesBetween(_d(0, 21 * 60), _d(1, 8 * 60), _cfg), 120);
      expect(SilentWatchBrain.windowMinutesBetween(_d(0, 8 * 60), _d(0, 9 * 60), _cfg), 60);
      expect(SilentWatchBrain.windowMinutesBetween(_d(0, 23 * 60), _d(1, 6 * 60), _cfg), 0);
    });

    test('adding in-window minutes skips the night', () {
      expect(SilentWatchBrain.addWindowMinutes(_d(0, 21 * 60), 240, _cfg), _d(1, 10 * 60));
      expect(SilentWatchBrain.addWindowMinutes(_d(0, 3 * 60), 60, _cfg), _d(0, 8 * 60));
    });

    test('a ring never falls at night', () {
      final l = SilentWatchBrain.learn(const [], _d(0, 0), _cfg);
      for (var m = 0; m < 24 * 60; m += 7) {
        final ring = SilentWatchBrain.ringAt(_d(0, m), l.tableMin, _cfg);
        final mm = ring.hour * 60 + ring.minute;
        expect(mm >= _cfg.dayStartMin && mm < _cfg.dayEndMin, isTrue, reason: '$m -> $ring');
        expect(ring.isAfter(_d(0, m)), isTrue);
      }
    });
  });

  group('learning (7 days, on the phone)', () {
    test('before 7 days: exactly N hours', () {
      final l = SilentWatchBrain.learn([_d(0, 8 * 60), _d(2, 9 * 60)], _d(3, 0), _cfg);
      expect(l.learned, isFalse);
      expect(l.allowanceMin.toSet(), {240});
      expect(SilentWatchBrain.ringAt(_d(3, 9 * 60), l.tableMin, _cfg).difference(_d(3, 9 * 60)).inMinutes,
          inInclusiveRange(225, 255));
    });

    test('a normal long afternoon nap is learned; never more sensitive than N', () {
      final log = <DateTime>[];
      for (var d = 0; d < 8; d++) {
        for (var m = 8 * 60; m <= 13 * 60; m += 30) {
          log.add(_d(d, m));
        }
        for (var m = 18 * 60 + 30; m <= 21 * 60; m += 30) {
          log.add(_d(d, m)); // 13:00 -> 18:30 quiet every day (330 min)
        }
      }
      final l = SilentWatchBrain.learn(log, _d(8, 0), _cfg);
      expect(l.learned, isTrue);
      expect(l.allowanceMin[SilentWatchBrain.slotOf(_d(0, 13 * 60))], greaterThanOrEqualTo(330 * 12 ~/ 10));
      expect(l.allowanceMin.every((a) => a >= 240 && a <= 480), isTrue);
    });
  });

  group('SIMULATION — synthetic day logs', () {
    test('false family alerts < 1 per family per month (measured)', () {
      final r = _simulate(families: 150, seed: 11);
      final months = r.familyDays / 30.0;
      final perMonth = r.familyAlerts / months;
      final ringsPerMonth = r.ringRuns / months;
      // ignore: avoid_print
      print('FCELDER_SIM false family alerts per family-month = ${perMonth.toStringAsFixed(3)} '
          '(${r.familyAlerts} in ${r.familyDays} family-days); '
          '"Are you OK?" ring runs per family-month = ${ringsPerMonth.toStringAsFixed(2)}');
      expect(perMonth, lessThan(1.0));
    });

    test('a real emergency reaches the family (detection delay measured)', () {
      final r = _simulate(families: 150, seed: 23, incident: true);
      final d = [...r.detect]..sort();
      expect(d.length, 150, reason: 'every incident must reach the family');
      final median = d[d.length ~/ 2], p90 = d[(d.length * 9) ~/ 10];
      // ignore: avoid_print
      print('FCELDER_SIM detection: median ${median}m, p90 ${p90}m (wall clock; '
          'nights are never counted as silence)');
      expect(median, lessThan(12 * 60));
    });
  });
}
