// group-calls — REAL 3-way group call proof on the CI emulator against the
// seeded Django (owner order 17 Nov; gatefix 18v pattern):
//
//   A = Reality Rahim — the app under test, driven through the UI
//   B = Reality Karim — an in-process second client (own ApiClient +
//       PollRealtimeTransport + CallController, then GroupCallController +
//       GroupMeshMedia: real flutter_webrtc peers through our server)
//   D = Reality Dipu (seed user "e", 01700000006) — an in-process third client (GroupCallController)
//
//   1  B voice-calls A; A accepts in the app -> 1:1 connected.
//   2  A taps "Add person" (যোগ করুন), picks D in the My Circle picker,
//      Ring -> D gets a normal ring that names the room -> D answers.
//      A's screen and B's client hand the 1:1 call over to the group engine.
//   3  REQUIRED: every phone has a connected leg with BOTH others, and on
//      EVERY leg of EVERY phone the inbound audio packets AND bytes grow over
//      >= 6 s (3 pairs x 2 directions). Per-leg debugEvidence (SDP,
//      transceivers, rtp counters) is printed as GROUPCALL_EVIDENCE lines.
//   4  D leaves -> A and B keep their leg and media still flows both ways.
//   5  A leaves -> B's call ends.
//
// HONEST LIMITS: all three peers run on ONE emulator (host ICE candidates,
// TURN not exercised); audio only (one emulated mic). Video both ways per
// pair is proven at unit level (group_call_controller_test) and for 1:1 by
// 18v. Three real phones: owner_actions/GROUP_CALLS_PLAN_BN.md §7.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/api.dart';
import 'package:assisto/calls/api_call_signaling.dart';
import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/calls/call_runtime.dart';
import 'package:assisto/calls/group_call_api.dart';
import 'package:assisto/calls/group_call_controller.dart';
import 'package:assisto/calls/group_mesh_media.dart';
import 'package:assisto/calls/webrtc_media.dart';
import 'package:assisto/config.dart';
import 'package:assisto/push/incoming_call_screen.dart';
import 'package:assisto/realtime/realtime_transport.dart';
import 'package:assisto/screens/circle_call_screen.dart';
import 'package:assisto/screens/group_call_screen.dart';

import '../support/harness.dart';

const _phoneD = '01700000006'; // seed_reality user "e" (D is the flagproof user)

class _Silent implements CallSounds {
  @override
  Future<void> startRingback() async {}
  @override
  Future<void> stopRingback() async {}
  @override
  Future<void> playBusy() async {}
  @override
  Future<void> playDeclined() async {}
  @override
  Future<void> playEnded() async {}
  @override
  Future<void> stopAll() async {}
  @override
  Future<void> setProximity(bool on) async {}
}

void registerGroupCallFlows() {
  realityFlow('18g_group_call_3way', 'My Circle',
      'Group call: 1:1 -> Add person -> 3 people; audio both ways on every pair; leave -> the last two go on',
      (f) async {
    await f.home();
    late ApiClient apiB, apiD;
    late PollRealtimeTransport rtB, rtD;
    late int idD;
    final incomingB = <Map<String, dynamic>>[];
    final incomingD = <Map<String, dynamic>>[];
    CallController? callB;
    GroupCallController? gB, gD;

    await f.step('B and D (in-process clients) sign in, real-time open', () async {
      apiB = await f.net(() => f.h.backend(userB: true));
      rtB = PollRealtimeTransport.forApi(apiB);
      rtB.events.listen((e) {
        if (e.topic == 'call.incoming') incomingB.add(e.payload);
      });
      await f.net(() => rtB.connect());
      rtB.setFast(true);
      // D on its own harness device id: never revokes the app's session
      await f.net(() async {
        final c = ApiClient();
        final dev = AppConfig.deviceId;
        AppConfig.deviceId = 'reality-harness-d';
        try {
          final r = await c.login(identifier: _phoneD, password: Seed.password);
          c.token = r.token;
          idD = r.user.id;
        } finally {
          AppConfig.deviceId = dev;
        }
        c.lang = 'en';
        apiD = c;
      });
      rtD = PollRealtimeTransport.forApi(apiD);
      rtD.events.listen((e) {
        if (e.topic == 'call.incoming') incomingD.add(e.payload);
      });
      await f.net(() => rtD.connect());
      rtD.setFast(true);
    });

    await f.step('B voice-calls A; A accepts -> 1:1 connected', () async {
      final members = await f.net(() => apiB.getJson('/circle/members'));
      final edge = (((members['results'] ?? members['members']) as List)
              .cast<Map>()
              .firstWhere((m) => '${m['name']}'.contains('Rahim'))['id'] as num)
          .toInt();
      await f.net(() async {
        final c = CallController(
          media: WebRtcCallMedia(cameraBlocked: true),
          signaling: ApiCallSignaling(apiB, rtB),
          sounds: _Silent(),
          video: false,
          outgoing: true,
          memberId: edge,
        );
        callB = c;
        unawaited(c.start());
      });
      await f.waitFor(find.byType(IncomingCallScreen), seconds: 20,
          what: 'incoming call screen on A');
      await f.tap(find.byKey(const Key('incoming-accept')), settleSeconds: 2);
      await f.waitFor(find.byType(CircleCallScreen), what: 'call screen on A');
      await f.eventually('B connected',
          () async => callB!.phase == CallPhase.connected, seconds: 40);
      await f.eventually('A connected', () async =>
          CallRuntime.instance.currentCall?.phase == CallPhase.connected,
          seconds: 20);
    });

    await f.step('A: Add person -> pick D in My Circle -> Ring', () async {
      await f.waitFor(find.byKey(const Key('call-add-person')),
          what: 'Add person button');
      await f.tap(find.byKey(const Key('call-add-person')), settleSeconds: 3);
      final row = find.byKey(Key('gcall-pick-$idD'));
      await f.waitFor(row, seconds: 15, what: 'D in the My Circle picker');
      await f.tap(row, settleSeconds: 1);
      await f.shot('add-person-picker');
      await f.tap(find.byKey(const Key('gcall-pick-ring')), settleSeconds: 3);
      await f.waitFor(find.byType(GroupCallScreen), seconds: 20,
          what: 'A moved to the group call screen');
      await f.eventually('D got a ring into the group call',
          () async => incomingD.any((r) => r['room_id'] != null), seconds: 20);
    });

    final ringD = () => incomingD.lastWhere((r) => r['room_id'] != null);
    final room = () => (ringD()['room_id'] as num).toInt();

    await f.step('D answers; B hands its 1:1 over to the group engine', () async {
      await f.net(() async {
        final d = GroupCallController(
          media: GroupMeshMedia(),
          signaling: ApiGroupSignaling(GroupCallApi(apiD), rtD),
          roomId: room(),
          myId: idD,
          answerCallId: (ringD()['call_id'] as num).toInt(),
        );
        gD = d;
        unawaited(d.start());
      });
      await f.eventually('B learned its call is a group call',
          () async => callB!.roomId == room(), seconds: 20);
      final adopt = callB!.callId;
      final since = rtB.seq;
      await f.net(() async {
        await callB!.handover();
        final b = GroupCallController(
          media: GroupMeshMedia(),
          signaling: ApiGroupSignaling(GroupCallApi(apiB), rtB),
          roomId: room(),
          myId: 0,
          adoptCallId: adopt,
          sinceSeq: since,
        );
        gB = b;
        unawaited(b.start());
      });
    });

    GroupCallController a() {
      final c = GroupCallScreen.live;
      if (c == null) throw TestFailure('no live group call on A');
      return c;
    }

    Future<void> dump(String t) async {
      for (final side in [('A', GroupCallScreen.live), ('B', gB), ('D', gD)]) {
        final c = side.$2;
        if (c == null) continue;
        final ev = await f.net(() => c.evidence());
        for (final e in ev.entries) {
          final js = jsonEncode({'peer': c.legPeer(e.key), ...e.value});
          const n = 700;
          final parts = (js.length + n - 1) ~/ n;
          for (var i = 0; i < parts; i++) {
            // ignore: avoid_print
            print('GROUPCALL_EVIDENCE ${side.$1} leg=${e.key} $t ${i + 1}/$parts '
                '${js.substring(i * n, (i + 1) * n > js.length ? js.length : (i + 1) * n)}');
          }
        }
      }
    }

    /// Every leg of every phone: inbound audio packets AND bytes grow >= 6 s.
    Future<void> proveAllPairs(String kase, Map<String, GroupCallController> phones,
        int legsEach) async {
      for (final p in phones.entries) {
        await f.eventually('${p.key} has $legsEach connected legs', () async {
          final c = p.value;
          return c.legIds.length == legsEach && c.legIds.every(c.legConnected);
        }, seconds: 60);
      }
      final first = <String, LegStats>{};
      for (final p in phones.entries) {
        for (final l in p.value.legIds) {
          first['${p.key}:$l'] = await f.net(() => p.value.media.stats(l));
        }
      }
      await f.pumpFor(const Duration(seconds: 7));
      final lines = <String>[];
      final bad = <String>[];
      for (final p in phones.entries) {
        for (final l in p.value.legIds) {
          final s1 = first['${p.key}:$l'];
          final s2 = await f.net(() => p.value.media.stats(l));
          final peer = p.value.legPeer(l);
          final line = '${p.key}<-$peer audio pkts ${s1?.audioPacketsIn}->${s2.audioPacketsIn} '
              'bytes ${s1?.audioBytesIn}->${s2.audioBytesIn}';
          lines.add(line);
          final ok = s1 != null &&
              (s1.audioPacketsIn ?? -1) >= 0 &&
              (s2.audioPacketsIn ?? 0) > (s1.audioPacketsIn ?? 0) &&
              (s2.audioBytesIn ?? 0) > (s1.audioBytesIn ?? 0);
          if (!ok) bad.add(line);
        }
      }
      f.note('$kase: ${lines.join('; ')}');
      if (bad.isNotEmpty) {
        await dump('$kase-fail');
        throw TestFailure('$kase: no audio on ${bad.join('; ')}');
      }
      await dump(kase);
    }

    await f.step('3 people: every pair connected, audio flows both ways on every pair',
        () async {
      await f.shot('group-3');
      await proveAllPairs('3way', {'A': a(), 'B': gB!, 'D': gD!}, 2);
      if (find.byKey(const Key('gcall-grid')).evaluate().isEmpty) {
        throw TestFailure('A shows no group grid');
      }
    });

    await f.step('D leaves -> A and B go on, audio still both ways', () async {
      await f.net(() => gD!.leave());
      await proveAllPairs('after-leave', {'A': a(), 'B': gB!}, 1);
      await f.shot('after-leave');
    });

    await f.step('A leaves -> B\'s call ends', () async {
      await f.tap(find.byKey(const Key('gcall-leave')), settleSeconds: 3);
      await f.eventually('B saw the call end', () async => gB!.isEnded,
          seconds: 20);
    });
    gB?.dispose();
    gD?.dispose();
    callB?.dispose();
    await rtB.close();
    await rtD.close();
    await f.backToHome();
  }, timeout: const Duration(minutes: 8));
}
