// group-calls: the mesh engine on the phone, against an in-memory server
// with the same rules as core/views_group_calls.py (group_call_fakes.dart).
// Every pair of people must end up with ONE connected leg and media flowing
// both ways (the strict proof of the 1:1 release gate), through joins, late
// joins, leaves, a failed leg, and a handed-over 1:1 call.
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/calls/call_controller.dart' show MediaLinkState;
import 'package:assisto/calls/group_call_controller.dart';

import 'group_call_fakes.dart';

Future<void> proveAll(Hub hub, List<GroupCallController> phones) async {
  for (var i = 0; i < 8; i++) {
    hub.clock.tick();
    for (final p in phones) {
      await p.sampleStatsNow();
    }
  }
}

void main() {
  group('pure rules', () {
    LegStats st(int p, {int v = 0}) =>
        LegStats(audioPacketsIn: p, audioBytesIn: p * 80, videoFramesDecoded: v);
    final t0 = DateTime(2026, 11, 17);
    List<(DateTime, LegStats)> run(List<int> pk, {int v = 0}) => [
          for (var i = 0; i < pk.length; i++)
            (t0.add(Duration(seconds: i)), st(pk[i], v: v))
        ];

    test('media proof: audio grows for >= 6 s at every step', () {
      expect(mediaFlowProven(run([0, 50, 100, 150, 200, 250, 300])), isTrue);
      // only 5 s of samples
      expect(mediaFlowProven(run([0, 50, 100, 150, 200, 250])), isFalse);
      // stalled for one second -> not proven
      expect(mediaFlowProven(run([0, 50, 100, 100, 200, 250, 300])), isFalse);
      // nothing received
      expect(mediaFlowProven(run([0, 0, 0, 0, 0, 0, 0])), isFalse);
      expect(mediaFlowProven(const []), isFalse);
    });

    test('media proof: video expected needs decoded AND growing frames',
        () {
      final a = run([0, 50, 100, 150, 200, 250, 300]);
      expect(mediaFlowProven(a, expectVideo: true), isFalse);
      // frames decoded once, then frozen -> not proven (gatefix bar)
      final b = run([0, 50, 100, 150, 200, 250, 300], v: 30);
      expect(mediaFlowProven(b, expectVideo: true), isFalse);
      final c = [
        for (var i = 0; i < 7; i++)
          (t0.add(Duration(seconds: i)), st(i * 50, v: i * 15))
      ];
      expect(mediaFlowProven(c, expectVideo: true), isTrue);
    });

    test('grid shape for 1..8 people', () {
      expect(gridShape(1), (1, 1));
      expect(gridShape(2), (1, 2));
      expect(gridShape(3), (2, 2));
      expect(gridShape(4), (2, 2));
      expect(gridShape(5), (2, 3));
      expect(gridShape(8), (2, 4));
    });
  });

  group('mesh engine', () {
    Future<(Hub, GroupCallController, GroupCallController,
        GroupCallController)> threeInCall() async {
      final hub = Hub();
      final a = phoneFor(hub, 1);
      await a.start(initial: hub.hostStart(1, [2, 3]));
      final b = phoneFor(hub, 2, answer: 9001);
      await b.start();
      await settle();
      final c = phoneFor(hub, 3, answer: 9002);
      await c.start();
      await settle();
      return (hub, a, b, c);
    }

    test('3 people: every pair connects; media flows both ways for every '
        'pair (strict proof)', () async {
      final (hub, a, b, c) = await threeInCall();
      for (final p in [a, b, c]) {
        expect(p.isLive, isTrue);
        expect(p.legIds.length, 2, reason: p.log.join('\n'));
        for (final l in p.legIds) {
          expect(p.legConnected(l), isTrue, reason: '${p.myId} leg $l');
        }
        expect(p.inCallCount, 3);
      }
      // each leg was reported connected to the server by both phones
      for (final l in hub.legs.keys) {
        expect(hub.serverEvents.where((e) => e.endsWith(':$l:connected')),
            hasLength(2));
      }
      await proveAll(hub, [a, b, c]);
      for (final p in [a, b, c]) {
        final proof = p.mediaProof;
        expect(proof.length, 2);
        expect(proof.values.every((v) => v), isTrue, reason: '$proof');
      }
      for (final p in [a, b, c]) {
        p.dispose();
      }
    });

    test('VIDEO, 3 people: decoded frames grow both ways for every pair '
        '(gatefix 25f02670 bar)', () async {
      final hub = Hub(kind: 'video');
      final a = phoneFor(hub, 1, video: true);
      await a.start(initial: hub.hostStart(1, [2, 3]));
      final b = phoneFor(hub, 2, video: true);
      await b.start();
      await settle();
      final c = phoneFor(hub, 3, video: true);
      await c.start();
      await settle();
      for (final p in [a, b, c]) {
        await p.refresh(); // every tile knows the others' cameras are on
      }
      expect(hub.camera.values.every((v) => v), isTrue);
      await proveAll(hub, [a, b, c]);
      for (final p in [a, b, c]) {
        expect(p.mediaProof.length, 2);
        expect(p.mediaProof.values.every((v) => v), isTrue,
            reason: '${p.myId}: ${p.mediaProof}');
        expect((await p.evidence()).length, 2);
      }
      // a camera that is on but frozen -> that pair is NOT proven any more
      hub.frozenVideo.add(2);
      await proveAll(hub, [a]);
      expect(a.mediaProof[2], isFalse);
      for (final p in [a, b, c]) {
        p.dispose();
      }
    });

    test('leave: the call goes on; the last two keep talking; the last '
        'one out ends it', () async {
      final (hub, a, b, c) = await threeInCall();
      await b.leave();
      await settle();
      expect(b.isEnded, isTrue);
      expect(b.endReason, GroupEndReason.left);
      for (final p in [a, c]) {
        expect(p.isLive, isTrue);
        expect(p.legIds.length, 1);
        expect(p.legPeer(p.legIds.single), p == a ? 3 : 1);
        expect(p.legConnected(p.legIds.single), isTrue);
        expect(p.tiles.map((t) => t.userId), isNot(contains(2)));
      }
      await proveAll(hub, [a, c]);
      expect(a.mediaProof[3], isTrue);
      expect(c.mediaProof[1], isTrue);
      await c.leave();
      await settle();
      expect(a.isEnded, isTrue);
      expect(a.endReason, GroupEndReason.ended);
      expect(hub.live, isFalse);
      a.dispose();
    });

    test('late join: a 4th person joins a live call and gets a leg with '
        'everyone', () async {
      final (hub, a, b, c) = await threeInCall();
      hub.state[4] = 'declined';
      final d = phoneFor(hub, 4);
      await d.start();
      await settle();
      expect(d.legIds.length, 3);
      for (final p in [a, b, c, d]) {
        expect(p.legIds.length, 3, reason: '${p.myId}: ${p.log}');
        expect(p.legIds.every(p.legConnected), isTrue);
      }
      await proveAll(hub, [a, b, c, d]);
      for (final p in [a, b, c, d]) {
        expect(p.mediaProof.values.every((v) => v), isTrue);
      }
      for (final p in [a, b, c, d]) {
        p.dispose();
      }
    });

    test('a failed leg re-offers (new generation) and reconnects', () async {
      final (hub, a, b, c) = await threeInCall();
      final ab = a.legIds.firstWhere((l) => a.legPeer(l) == 2);
      hub.medias[2]!.link(ab, MediaLinkState.failed);
      await settle();
      expect(b.log, contains('ask-offer $ab'));
      expect(a.log, contains('offer $ab g=2'));
      expect(a.legConnected(ab), isTrue);
      expect(b.legConnected(ab), isTrue);
      for (final p in [a, b, c]) {
        p.dispose();
      }
    });

    test('a handed-over 1:1 call never uses its stale offer', () async {
      final hub = Hub();
      hub.state[1] = 'joined';
      hub.state[2] = 'joined';
      hub.legs[900] = (1, 2);
      hub.sent[2] = [
        {
          'seq': 50,
          'topic': 'call.signal',
          'payload': {
            'call_id': 900,
            'kind': 'offer',
            'data': {'type': 'offer', 'sdp': 'STALE'}
          }
        }
      ];
      hub.seq = 60;
      final b = phoneFor(hub, 2, adopt: 900, since: 60);
      await b.start();
      final a = phoneFor(hub, 1, adopt: 900, since: 60);
      await a.start(initial: hub.snap(1));
      await settle();
      final peer = hub.medias[2]!.peers[900]!;
      expect(peer.lastRemoteSdp, startsWith('o-1-900'));
      expect(b.legConnected(900), isTrue);
      expect(a.legConnected(900), isTrue);
      a.dispose();
      b.dispose();
    });

    test('full call -> clear end reason; mic refused -> honest reason',
        () async {
      final hub = Hub();
      hub.hostStart(1, [2]);
      hub.joinError = 'full';
      final b = phoneFor(hub, 2);
      await b.start();
      expect(b.endReason, GroupEndReason.full);
      final hub2 = Hub();
      hub2.hostStart(1, [2]);
      final c = phoneFor(hub2, 2, denyMic: true);
      await c.start();
      expect(c.endReason, GroupEndReason.mediaDenied);
    });

    test('add person: results per person, ringing tile, blocked refused',
        () async {
      final (hub, a, b, c) = await threeInCall();
      hub.blocked.add(6);
      final res = await a.invite([5, 6]);
      expect(res.firstWhere((r) => r['user_id'] == 5)['ok'], isTrue);
      expect(res.firstWhere((r) => r['user_id'] == 6)['code'], 'unavailable');
      expect(a.tiles.firstWhere((t) => t.userId == 5).ringing, isTrue);
      expect(a.seatedUserIds, containsAll([1, 2, 3, 5]));
      for (final p in [a, b, c]) {
        p.dispose();
      }
    });

    test('active speaker = the loudest unmuted person', () async {
      final (hub, a, b, c) = await threeInCall();
      hub.medias[1]!.levels[2] = 0.4;
      hub.medias[1]!.levels[3] = 0.1;
      hub.clock.tick();
      await a.sampleStatsNow();
      expect(a.activeSpeakerId, 2);
      await b.toggleMute();
      hub.clock.tick();
      await a.sampleStatsNow();
      expect(a.activeSpeakerId, 3);
      expect(hub.muted[2], isTrue);
      for (final p in [a, b, c]) {
        p.dispose();
      }
    });

    test('low data: 5+ people on mobile data start camera-off', () async {
      final hub = Hub(kind: 'video');
      final a = phoneFor(hub, 1, video: true, mobile: true);
      await a.start(initial: hub.hostStart(1, [2, 3, 4, 5]));
      expect(a.isVideo, isTrue);
      expect(a.cameraOn, isFalse);
      expect(hub.camera[1], isFalse);
      expect(a.videoKbps, 80);
      final hub2 = Hub(kind: 'video');
      final b = phoneFor(hub2, 1, video: true, mobile: false);
      await b.start(initial: hub2.hostStart(1, [2, 3, 4, 5]));
      expect(b.cameraOn, isTrue);
      a.dispose();
      b.dispose();
    });
  });
}
