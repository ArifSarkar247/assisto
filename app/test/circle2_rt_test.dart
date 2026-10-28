// circle2 — the shared real-time loop's cadence tiers, the call's hints
// (steady / network switch), ICE re-send, the ✓✓ boost window, and a
// 15-minute replay that MEASURES rt/events polls per phone before vs after
// (printed into the CI log; the owner saw ~1,350 polls in 15 min from 3
// phones on 28 Oct).
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/api.dart';
import 'package:assisto/calls/api_call_signaling.dart';
import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/messaging/receipt_bus.dart';
import 'package:assisto/realtime/realtime_transport.dart';

import 'c2_calls_fakes.dart';

Future<void> settle() => pumpEventQueue(times: 30);

class _Clock {
  DateTime t = DateTime(2026, 10, 28, 10);
  DateTime call() => t;
  void add(Duration d) => t = t.add(d);
}

PollRealtimeTransport _t(_Clock c, {Duration? quiet}) => PollRealtimeTransport(
      get: (_) async => {'events': [], 'seq': 0},
      post: (_, __) async => {'ok': true},
      quietInterval: quiet,
      now: c.call,
    );

class _HintSig extends FakeSignaling implements RealtimeHints {
  final steady = <bool>[];
  final nets = <String>[];
  @override
  void setSteady(bool on) => steady.add(on);
  @override
  void networkChanged(String kind) => nets.add(kind);
}

/// The PRE-circle2 cadence, for the before/after replay only:
/// call 0.3 s; tick wait = the call cadence (0.3 s), re-armed while any of my
/// messages in the open chat is unread (+90 s after the last re-arm); idle
/// 5 s with FCM (no My Circle distinction).
Duration _oldInterval({required bool call, required bool tickWait}) {
  if (call) return const Duration(milliseconds: 300);
  if (tickWait) return const Duration(milliseconds: 300);
  return const Duration(seconds: 5);
}

class _Seg {
  const _Seg(this.secs,
      {this.circle = false,
      this.sendsEvery = 0,
      this.readAfter = 30,
      this.setup = 0,
      this.callEventEvery = 0});
  final int secs;
  final bool circle; // a My Circle chat is on screen
  final int sendsEvery; // I send a message every N s (0 = none)
  final int readAfter; // the peer reads N s after my send (0 = never)
  final int setup; // a call: first N s are setup (ring + ICE)
  final int callEventEvery; // in a connected call: an event every N s
  bool get isCall => setup > 0;
}

/// Count polls for one phone over [segs]: (before, after).
(int, int) _replay(List<_Seg> segs) {
  var before = 0, after = 0;
  // ---- before: interval-stepping with the old rules
  for (final s in segs) {
    var x = 0.0;
    double? lastSend;
    while (x < s.secs) {
      var tickWait = false;
      if (s.sendsEvery > 0) {
        final ls = (x ~/ s.sendsEvery) * s.sendsEvery.toDouble();
        lastSend = ls;
        final unread = s.readAfter == 0 || x - ls < s.readAfter;
        tickWait = unread || x - lastSend < 90;
      }
      x += _oldInterval(call: s.isCall, tickWait: tickWait)
              .inMilliseconds /
          1000;
      before++;
    }
  }
  // ---- after: the REAL transport's currentInterval under the same story
  final c = _Clock();
  final t = _t(c, quiet: const Duration(seconds: 10));
  for (final s in segs) {
    final end = c.t.add(Duration(seconds: s.secs));
    final start = c.t;
    t.heartbeat = s.circle;
    if (s.isCall) t.setFast(true);
    var steady = false, boost = false;
    DateTime? nextEvent;
    while (c.t.isBefore(end)) {
      final el = c.t.difference(start).inMilliseconds / 1000;
      if (s.isCall) {
        if (!steady && el >= s.setup) {
          t.setSteady(true);
          steady = true;
          nextEvent = c.t.add(Duration(seconds: s.callEventEvery));
        }
        if (steady && s.callEventEvery > 0 && !c.t.isBefore(nextEvent!)) {
          t.debugEvent();
          nextEvent = c.t.add(Duration(seconds: s.callEventEvery));
        }
      }
      if (s.sendsEvery > 0) {
        final since = el % s.sendsEvery;
        final win = ReceiptBus.boostFor.inSeconds;
        // a send arms [boostFor]; while my message stays unread the chat's
        // re-checks arm one more window per [watchEvery]
        final unreadStays = s.readAfter == 0;
        final want = since < win ||
            (unreadStays && el % ReceiptBus.watchEvery.inSeconds < win);
        if (want != boost) {
          t.setBoost(want);
          boost = want;
        }
      }
      c.add(t.currentInterval);
      after++;
    }
    if (boost) t.setBoost(false);
    if (steady) t.setSteady(false);
    if (s.isCall) t.setFast(false);
  }
  return (before, after);
}

void main() {
  group('cadence tiers', () {
    test('quiet 10 s outside My Circle with FCM; 2.5 s in My Circle; idle '
        '2.5 s without FCM', () {
      final c = _Clock();
      final t = _t(c, quiet: const Duration(seconds: 10));
      expect(t.currentInterval, const Duration(seconds: 10));
      expect(t.tier, 'quiet');
      t.heartbeat = true;
      expect(t.currentInterval, const Duration(milliseconds: 2500));
      expect(t.tier, 'circle');
      final noPush = _t(c);
      expect(noPush.currentInterval, const Duration(milliseconds: 2500));
      expect(noPush.tier, 'idle');
    });

    test('a ✓✓ wait polls at 1 s — never the 0.3 s call cadence', () {
      final c = _Clock();
      final t = _t(c, quiet: const Duration(seconds: 10))..heartbeat = true;
      t.setBoost(true);
      expect(t.currentInterval, const Duration(seconds: 1));
      expect(t.tier, 'boost');
      t.setBoost(false);
      expect(t.currentInterval, const Duration(milliseconds: 2500));
    });

    test('call: 0.3 s while setting up, 0.8 s connected and quiet, 0.3 s for '
        '3 s after any event or signal', () async {
      final c = _Clock();
      final t = _t(c);
      t.setFast(true);
      expect(t.currentInterval, const Duration(milliseconds: 300));
      t.setSteady(true);
      // setFast's own burst is still running
      expect(t.tier, 'fast');
      c.add(const Duration(seconds: 4));
      expect(t.currentInterval, const Duration(milliseconds: 800));
      expect(t.tier, 'steady');
      t.debugEvent(); // e.g. video_request arrives
      expect(t.currentInterval, const Duration(milliseconds: 300));
      c.add(const Duration(seconds: 4));
      expect(t.tier, 'steady');
      await t.send('call.signal', {'kind': 'restart_offer'});
      expect(t.tier, 'fast', reason: 'an answer is expected — poll fast');
      c.add(const Duration(seconds: 4));
      t.setSteady(false); // reconnecting
      expect(t.currentInterval, const Duration(milliseconds: 300));
      t.setFast(false);
      expect(t.tier, 'idle');
    });

    test('error backoff is capped at 2 s in a call / tick wait, 15 s idle',
        () {
      final c = _Clock();
      final t = _t(c);
      for (var i = 0; i < 8; i++) {
        t.debugFail();
      }
      expect(t.currentInterval, const Duration(seconds: 15));
      t.setFast(true);
      expect(t.currentInterval, const Duration(seconds: 2));
      t.setFast(false);
      t.setBoost(true);
      expect(t.currentInterval, const Duration(seconds: 2));
    });

    test('networkChanged drops the backoff and polls at once', () async {
      var n = 0;
      var fail = true;
      final t = PollRealtimeTransport(
        get: (_) async {
          n++;
          if (fail) throw Exception('offline');
          return {'events': [], 'seq': 0};
        },
        post: (_, __) async => {},
        idleInterval: const Duration(seconds: 30),
      );
      await t.connect();
      t.debugFail();
      t.debugFail();
      t.debugFail();
      expect(t.connected.value, isFalse);
      final before = n;
      fail = false;
      await t.networkChanged();
      expect(n, before + 1, reason: 'polled now, not after the backoff');
      expect(t.connected.value, isTrue);
      expect(t.tier, 'idle', reason: 'backoff forgotten');
      await t.close();
    });

    test('opening My Circle while quiet polls within 50 ms', () async {
      var n = 0;
      final t = PollRealtimeTransport(
        get: (_) async {
          n++;
          return {'events': [], 'seq': 0};
        },
        post: (_, __) async => {},
        quietInterval: const Duration(seconds: 10),
      );
      await t.connect();
      final before = n;
      t.heartbeat = true;
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(n, greaterThan(before));
      await t.close();
    });
  });

  group('call hints', () {
    test('connected -> steady; reconnecting -> not steady; network switch '
        '-> the loop is kicked', () async {
      final m = FakeCallMedia(), s = _HintSig(), snd = FakeSounds();
      final c = CallController(
        media: m,
        signaling: s,
        sounds: snd,
        video: false,
        outgoing: true,
        memberId: 7,
        reconnectGrace: const Duration(milliseconds: 20),
        reconnectGiveUp: const Duration(seconds: 5),
        statusEvery: const Duration(seconds: 30),
        statsEvery: const Duration(seconds: 30),
        setupRetryDelays: const [Duration.zero, Duration.zero],
      );
      await c.start();
      m.link.add(MediaLinkState.connected);
      await settle();
      expect(c.phase, CallPhase.connected);
      expect(s.steady, [true]);
      c.onNetworkChanged('cellular');
      await settle();
      expect(c.phase, CallPhase.reconnecting);
      expect(s.nets, ['cellular']);
      expect(s.steady, [true, false]);
      c.onNetworkChanged('lost');
      expect(s.nets, ['cellular'], reason: 'no point polling with no network');
      m.link.add(MediaLinkState.connected);
      await settle();
      expect(c.phase, CallPhase.connected);
      expect(s.steady, [true, false, true]);
      await c.hangup();
      expect(s.steady.last, isFalse);
      c.dispose();
    });

    test('ICE candidates are re-sent after a network blip; offers are not',
        () async {
      var posts = 0;
      var failFirst = 1;
      final t = PollRealtimeTransport(
        get: (_) async => {'events': [], 'seq': 0},
        post: (p, b) async {
          posts++;
          if (failFirst > 0) {
            failFirst--;
            throw ApiException('no network', 0);
          }
          return {'ok': true};
        },
      );
      final sig = ApiCallSignaling(ApiClient.detached('t'), t)
        ..iceRetry = const [Duration.zero, Duration.zero];
      await sig.signal(42, 'ice', {'candidate': 'c1'});
      expect(posts, 2);
      failFirst = 1;
      posts = 0;
      await expectLater(sig.signal(42, 'offer', {'sdp': 'x'}),
          throwsA(isA<ApiException>()));
      expect(posts, 1, reason: 'a duplicate offer could break the call');
      // a 4xx refusal is final even for ICE
      failFirst = 0;
      posts = 0;
      final t2 = PollRealtimeTransport(
        get: (_) async => {'events': [], 'seq': 0},
        post: (p, b) async {
          posts++;
          throw ApiException('ended', 410);
        },
      );
      final sig2 = ApiCallSignaling(ApiClient.detached('t'), t2)
        ..iceRetry = const [Duration.zero, Duration.zero];
      await expectLater(sig2.signal(42, 'ice', {'candidate': 'c1'}),
          throwsA(isA<ApiException>()));
      expect(posts, 1);
    });
  });

  group('✓✓ boost window', () {
    tearDown(ReceiptBus.instance.reset);

    test('a re-check arms at most one window per 2 min and never extends one',
        () {
      final calls = <bool>[];
      var now = DateTime(2026, 10, 28, 10);
      ReceiptBus.instance
        ..attach(const Stream.empty(), setFast: calls.add)
        ..clock = () => now;
      ReceiptBus.instance.expect(fresh: false);
      expect(calls, [true]);
      ReceiptBus.instance.relax();
      expect(calls, [true, false]);
      now = now.add(const Duration(seconds: 30));
      ReceiptBus.instance.expect(fresh: false); // chat refresh: no new window
      expect(calls, [true, false]);
      ReceiptBus.instance.expect(); // a SEND always arms
      expect(calls, [true, false, true]);
      ReceiptBus.instance.relax();
      now = now.add(const Duration(minutes: 3));
      ReceiptBus.instance.expect(fresh: false);
      expect(calls, [true, false, true, false, true]);
      expect(ReceiptBus.boostFor, const Duration(seconds: 20));
    });
  });

  group('15-minute replay (per phone)', () {
    test('owner test-day mix: polls before vs after', () {
      // 2 min elsewhere, 5 min in a chat sending every 60 s (read after
      // 30 s), a 5-min voice call (20 s setup, an event every 60 s), 3 min
      // elsewhere.
      const day = [
        _Seg(120),
        _Seg(300, circle: true, sendsEvery: 60, readAfter: 30),
        _Seg(300, setup: 20, callEventEvery: 60),
        _Seg(180),
      ];
      final (b, a) = _replay(day);
      // ignore: avoid_print
      print('circle2 measure: test-day mix, 15 min, 1 phone: '
          'before=$b after=$a (${(100 - a * 100 / b).round()}% fewer)');
      expect(a, lessThan(b * 0.4));
    });

    test('peer away: chat open 10 min with one unread message', () {
      const away = [
        _Seg(600, circle: true, sendsEvery: 600, readAfter: 0),
        _Seg(300),
      ];
      final (b, a) = _replay(away);
      // ignore: avoid_print
      print('circle2 measure: peer away, 15 min, 1 phone: '
          'before=$b after=$a (${(100 - a * 100 / b).round()}% fewer)');
      expect(a, lessThan(b * 0.5));
    });

    test('a 10-minute connected call', () {
      final (b, a) = _replay(const [_Seg(600, setup: 15, callEventEvery: 45)]);
      // ignore: avoid_print
      print('circle2 measure: 10-min call: before=$b after=$a '
          '(${(100 - a * 100 / b).round()}% fewer)');
      // hang-up still reaches the phone within 0.8 s + RTT
      expect(a, lessThan(b * 0.5));
    });
  });
}
