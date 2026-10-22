// x1-calls (build-183 call fixes): no double start, idempotency key, glare
// merge, early-signal queue, 20 s connect fail on both sides, Call again,
// one call screen at a time, grouped call log, cached caller photo.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/calls/call_avatar.dart';
import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/calls/call_runtime.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/push/push_payload.dart';
import 'package:assisto/screens/circle_call_history_screen.dart';
import 'package:assisto/screens/circle_call_screen.dart';

import 'c2_calls_fakes.dart';
import 'x1_calls_fixtures.dart';

Future<void> settle() => pumpEventQueue(times: 30);

CallController mk(FakeCallMedia m, FakeSignaling s,
        {bool outgoing = true,
        Duration connect = const Duration(seconds: 20)}) =>
    CallController(
      media: m,
      signaling: s,
      sounds: FakeSounds(),
      video: false,
      outgoing: outgoing,
      memberId: 7,
      callId: outgoing ? null : 42,
      statusEvery: const Duration(seconds: 30),
      statsEvery: const Duration(seconds: 30),
      connectTimeout: connect,
    );

Map<String, dynamic> _sig(int seq, String kind, Map<String, dynamic> data) => {
      'seq': seq,
      'topic': 'call.signal',
      'payload': {'call_id': 42, 'kind': kind, 'from': 'caller', 'data': data}
    };

void main() {
  group('A1-a: one call per tap', () {
    test('start() twice (rebuild / route event / 2nd frame) places ONE call',
        () async {
      final s = FakeSignaling();
      final c = mk(FakeCallMedia(), s);
      await Future.wait([c.start(), c.start()]);
      await c.start();
      expect(s.eventLog.where((e) => e.startsWith('place:')).length, 1);
      expect(c.log, contains('start-ignored'));
      c.dispose();
    });

    test('every placement carries an idempotency key; Call again = new key',
        () async {
      final s = FakeSignaling();
      final a = mk(FakeCallMedia(), s);
      await a.start();
      final b = mk(FakeCallMedia(), s);
      await b.start();
      expect(s.placeKeys.length, 2);
      expect(s.placeKeys[0], hasLength(32));
      expect(s.placeKeys[0], isNot(s.placeKeys[1]));
      a.dispose();
      b.dispose();
    });

    test('only ONE call screen may be live at a time', () {
      final rt = CallRuntime.instance;
      final first = Object(), second = Object();
      var firstLive = true;
      expect(rt.acquireScreen(first, () => firstLive), isTrue);
      expect(rt.acquireScreen(second, () => true), isFalse,
          reason: 'double tap must not open a 2nd call');
      firstLive = false; // the first call ended ("Busy", "Call again")
      expect(rt.acquireScreen(second, () => true), isTrue);
      rt.releaseScreen(second);
      rt.releaseScreen(first);
    });
  });

  group('A1-f: glare merge', () {
    test('server merged my tap into the peer call -> I am its callee',
        () async {
      final m = FakeCallMedia();
      final s = FakeSignaling(placeBody: {
        'allowed': true,
        'call_id': 42,
        'phase': 'accepted',
        'side': 'callee',
        'merged': true,
        'role': 'callee',
        'end_reason': '',
      });
      s.backlogItems.add(_sig(9, 'offer', {'type': 'offer', 'sdp': 'v=0 P'}));
      final c = mk(m, s);
      await c.start();
      await settle();
      expect(c.merged, isTrue);
      expect(c.outgoing, isFalse);
      expect(c.phase, CallPhase.accepted);
      expect(s.eventLog, isNot(contains('accept:42')),
          reason: 'the server already accepted it');
      expect(m.log, contains('accept-offer:v=0 P'));
      expect(s.signals.map((e) => e.$1), ['answer']);
      expect(c.endReason, isNot(CallEndReason.busy));
      c.dispose();
    });
  });

  group('A1-c: early signals are queued', () {
    test('ICE + offer that arrive live before the peer exists are replayed',
        () async {
      final m = FakeCallMedia();
      final s = _EarlySignaling();
      final c = mk(m, s, outgoing: false);
      await c.start();
      await settle();
      final i = m.log.indexOf('accept-offer:v=0 L');
      expect(i, greaterThan(m.log.indexOf('peer')));
      expect(m.log.indexOf('cand:candidate:early typ host'), greaterThan(i),
          reason: 'candidate applied only after the remote description');
      expect(s.signals.first.$1, 'answer');
      c.dispose();
    });
  });

  group('A1-d: 20 s connect timeout', () {
    test('callee: accepted but never connected -> fail on both sides',
        () async {
      final s = FakeSignaling();
      final c = mk(FakeCallMedia(), s,
          outgoing: false, connect: const Duration(milliseconds: 200));
      await c.start();
      expect(c.phase, CallPhase.accepted);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await settle();
      expect(c.endReason, CallEndReason.connectFailed);
      expect(s.eventLog, contains('fail'),
          reason: 'the server ends it for the other phone too');
      c.dispose();
    });

    test('caller: the server ended the answered call as failed -> '
        '"Couldn\'t connect"', () async {
      final s = FakeSignaling();
      final c = mk(FakeCallMedia(), s);
      await c.start();
      s.state('accepted');
      await settle();
      s.state('ended', endReason: 'failed');
      await settle();
      expect(c.endReason, CallEndReason.connectFailed);
      c.dispose();
    });

    test('connected in time: the timer never fires', () async {
      final m = FakeCallMedia(), s = FakeSignaling();
      final c = mk(m, s, outgoing: false, connect: const Duration(milliseconds: 150));
      await c.start();
      m.link.add(MediaLinkState.connected);
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await settle();
      expect(c.phase, CallPhase.connected);
      expect(s.eventLog, isNot(contains('fail')));
      c.dispose();
    });

    test('hang-up tells the server before releasing media', () async {
      final m = FakeCallMedia(), s = FakeSignaling();
      final c = mk(m, s, outgoing: false);
      await c.start();
      m.link.add(MediaLinkState.connected);
      await settle();
      await c.hangup();
      expect(s.eventLog, contains('hangup'));
      expect(m.disposed, isTrue);
      c.dispose();
    });

    test('Call again on both sides after a connect failure', () {
      final caller = previewController(
          video: false,
          outgoing: true,
          phase: CallPhase.ended,
          reason: CallEndReason.connectFailed);
      final callee = previewController(
          video: false,
          outgoing: false,
          phase: CallPhase.ended,
          reason: CallEndReason.connectFailed);
      final hung = previewController(
          video: false,
          outgoing: false,
          phase: CallPhase.ended,
          reason: CallEndReason.hangup);
      expect(canCallAgain(caller, hasMember: true), isTrue);
      expect(canCallAgain(callee, hasMember: true), isTrue);
      expect(canCallAgain(hung, hasMember: true), isFalse);
      expect(canCallAgain(callee, hasMember: false), isFalse);
      expect(isFailureReason(CallEndReason.connectFailed), isTrue);
    });
  });

  group('screens', () {
    Widget app(Widget home, {String lang = 'en'}) => MaterialApp(
          locale: Locale(lang),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: home,
        );

    testWidgets('connect failure: label + Call again, callee side too, 360 px',
        (tester) async {
      tester.view.physicalSize = const Size(360 * 3, 740 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      for (final lang in ['en', 'bn']) {
        final t = lookupAppLocalizations(Locale(lang));
        for (final outgoing in [true, false]) {
          final c = previewController(
              video: false,
              outgoing: outgoing,
              phase: CallPhase.ended,
              reason: CallEndReason.connectFailed);
          await tester.pumpWidget(app(
              CircleCallScreen(
                key: ObjectKey(c),
                member: const {'id': 7, 'name': 'T Shanto BD'},
                kind: 'voice',
                outgoing: outgoing,
                controller: c,
              ),
              lang: lang));
          await tester.pump();
          expect(find.text(t.x1CallConnectFailed), findsOneWidget);
          expect(find.byKey(const Key('call-again')), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('call screen shows the cached profile photo', (tester) async {
      CallPhotoCache.instance.seed('/api/v1/m/avatars/x.png', x1TestPhoto);
      final c = previewController(
          video: false, outgoing: true, phase: CallPhase.ringing);
      await tester.pumpWidget(app(CircleCallScreen(
        member: const {
          'id': 7,
          'name': 'Nadia',
          'photo': '/api/v1/m/avatars/x.png?e=1&s=abc'
        },
        kind: 'voice',
        controller: c,
      )));
      await tester.pump();
      expect(find.byKey(const Key('call-avatar-photo')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      CallPhotoCache.instance.clear();
    });

    test('photo cache key ignores the hourly signature, follows the file', () {
      final a = CallPhotoCache.keyFor('/api/v1/m/avatars/a.jpg?e=1&s=x');
      final b = CallPhotoCache.keyFor('/api/v1/m/avatars/a.jpg?e=2&s=y');
      final n = CallPhotoCache.keyFor('/api/v1/m/avatars/new.jpg?e=2&s=y');
      expect(a, b);
      expect(a, isNot(n));
      expect(CallPhotoCache.keyFor(''), '');
    });
  });

  group('A1-g: grouping', () {
    test('call log groups repeats "T Shanto BD (6)"', () {
      final rows = [
        for (var i = 0; i < 6; i++)
          {
            'id': 20 - i,
            'state': 'missed',
            'end_reason': 'no_answer',
            'outgoing': false,
            'peer_id': 20,
            'name': 'T Shanto BD',
            'started_at': '2026-10-22T07:3${5 - i}:00Z',
          },
        {
          'id': 3,
          'state': 'ended',
          'end_reason': 'hangup',
          'outgoing': true,
          'peer_id': 20,
          'name': 'T Shanto BD',
          'started_at': '2026-10-22T07:20:00Z',
        },
      ];
      final g = groupCallRows(rows);
      expect(g.map((r) => r['count']), [6, 1]);
    });

    test('missed-call notifications collapse per caller', () {
      PushPayload p(String id) => PushPayload.fromData({
            'kind': 'missed_call',
            'call_id': id,
            'group_key': 'caller-20',
          });
      expect(p('1').notificationId, p('2').notificationId);
      final other = PushPayload.fromData(
          {'kind': 'missed_call', 'call_id': '3', 'group_key': 'caller-21'});
      expect(other.notificationId, isNot(p('1').notificationId));
      expect(PushPayload.fromData({'kind': 'call_signal'}).isCallNudge, isTrue);
    });
  });
}

/// Delivers the caller's ICE + offer LIVE while accept() is in flight
/// (before this phone has a peer connection).
class _EarlySignaling extends FakeSignaling {
  @override
  Future<Map<String, dynamic>> accept(int callId) async {
    remoteSignal('ice', {'candidate': 'candidate:early typ host'},
        from: 'caller');
    remoteSignal('offer', {'type': 'offer', 'sdp': 'v=0 L'}, from: 'caller');
    await pumpEventQueue(times: 5);
    return super.accept(callId);
  }
}
