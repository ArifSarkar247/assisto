// c2-calls — REAL call proof on the CI emulator against the seeded Django:
//
//   A = Reality Rahim — the app under test, driven through the UI
//   B = Reality Karim — an INDEPENDENT second client in the same process:
//       its own ApiClient + PollRealtimeTransport + CallController + its own
//       flutter_webrtc RTCPeerConnection (real offer/answer/ICE through our
//       server, exactly what B's phone would do).
//
//   1  A voice-calls B: "Calling…" -> B's client reports ringing -> A shows
//      "Ringing…" -> B accepts -> both peers reach ICE connected -> A shows
//      the timer -> B hangs up -> A shows "Call ended"; call log row.
//   2  B video-calls A: A's app (no FCM on CI) gets call.incoming over the
//      real-time queue -> in-app incoming screen -> Accept -> connected.
//   3  B calls, A declines -> B's caller side ends "declined".
//
// HONEST LIMITS: both peers run on ONE emulator, so ICE connects over host
// candidates (TURN is not exercised: CI has no coturn secret) and the
// emulator's virtual mic/camera prove the media pipeline opens, NOT that a
// human hears/sees the other side. That needs the two-phone checklist
// (owner_actions/PHONE_TEST_CHECKLIST.md: Wi-Fi <-> mobile data, app closed).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/api.dart';
import 'package:assisto/calls/api_call_signaling.dart';
import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/calls/webrtc_media.dart';
import 'package:assisto/push/incoming_call_screen.dart';
import 'package:assisto/realtime/realtime_transport.dart';
import 'package:assisto/screens/circle_call_screen.dart';

import '../support/harness.dart';

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

/// B's media: real WebRTC, but audio-only capture so it never fights A for
/// the emulator's single front camera (B still RECEIVES A's video).
class _AudioOnlyMedia extends WebRtcCallMedia {
  @override
  Future<void> open({required bool video}) => super.open(video: false);
}

final _timer = RegExp(r'^\d{2}:\d{2}$');

String _status(RFlow f) {
  final w = find.byKey(const Key('call-status'));
  if (w.evaluate().isEmpty) return '';
  return (w.evaluate().first.widget as Text).data ?? '';
}

void registerCircleRealCallFlows() {
  realityFlow('18_circle_real_call', 'My Circle',
      'REAL calls: A->B voice connects (ICE), B->A video rings in-app + connects, decline',
      (f) async {
    await f.home();
    late ApiClient apiB;
    late PollRealtimeTransport rtB;
    final incomingB = <Map<String, dynamic>>[];
    StreamSubscription<RealtimeEvent>? subB;
    CallController? callB;

    await f.step('B (second client) signs in and keeps its real-time channel open',
        () async {
      apiB = await f.net(() => f.h.backend(userB: true));
      rtB = PollRealtimeTransport.forApi(apiB);
      subB = rtB.events.listen((e) {
        if (e.topic == 'call.incoming') incomingB.add(e.payload);
      });
      await f.net(() => rtB.connect());
      rtB.setFast(true);
    });

    // -------------------------------------------------------------- 1 voice
    await f.step('A voice-calls B: "Calling…" until B\'s phone rings', () async {
      await f.openRoute('circle');
      await f.tap(find.text(Seed.nameB), settleSeconds: 3);
      final mark = f.httpMark;
      await f.tap(find.byTooltip(f.t.circleVoiceCall), settleSeconds: 2);
      await f.waitFor(find.byType(CircleCallScreen), what: 'call screen');
      f.expectHttp('GET', '/rtc/turn', since: mark);
      await f.eventually('A placed a call', () async => incomingB.isNotEmpty,
          seconds: 15);
      final st = _status(f);
      if (st != f.t.c2CallCalling && st != f.t.c2CallRinging) {
        throw TestFailure('caller status was "$st", wanted Calling…');
      }
      await f.shot('voice-calling');
    });

    final callId = () => (incomingB.last['call_id'] as num).toInt();

    await f.step('B\'s phone reports ringing -> A shows "Ringing…"', () async {
      await f.net(() => apiB.postJson(
          '/circle/calls/${callId()}/event', {'event': 'ringing'}));
      await f.waitFor(find.text(f.t.c2CallRinging), seconds: 10,
          what: 'Ringing… on the caller');
      await f.shot('voice-ringing');
    });

    await f.step('B accepts with its own WebRTC peer -> both ICE connected, A timer',
        () async {
      await f.net(() async {
        final c = CallController(
          media: _AudioOnlyMedia(),
          signaling: ApiCallSignaling(apiB, rtB),
          sounds: _Silent(),
          video: false,
          outgoing: false,
          callId: callId(),
        );
        callB = c;
        unawaited(c.start());
      });
      await f.eventually('B reached ICE connected',
          () async => callB!.phase == CallPhase.connected,
          seconds: 40);
      for (var i = 0; i < 40 && !_timer.hasMatch(_status(f)); i++) {
        await f.tester.pump(const Duration(milliseconds: 500));
      }
      if (!_timer.hasMatch(_status(f))) {
        throw TestFailure('A never showed the call timer (status "${_status(f)}")');
      }
      final st = await f.net(() => apiB.getJson('/circle/calls/${callId()}'));
      if (st['phase'] != 'connected') throw TestFailure('server phase: $st');
      await f.tester.pump(const Duration(seconds: 2));
      await f.shot('voice-connected');
      f.note('voice: ICE connected both sides (host candidates, one emulator)');
    });

    await f.step('B hangs up -> A shows "Call ended"; call log has the call', () async {
      await f.net(() => callB!.hangup());
      await f.waitFor(find.text(f.t.circleCallEnded), seconds: 10,
          what: 'Call ended on A');
      await f.shot('voice-ended');
      await f.tester.pump(const Duration(seconds: 2));
      final hist = await f.net(() => f.h.backend().then((a) => a.getJson('/circle/calls')));
      final row = (hist['calls'] as List).first as Map;
      if (row['kind'] != 'voice' || row['state'] != 'ended') {
        throw TestFailure('call log row: $row');
      }
      callB?.dispose();
      callB = null;
    });

    // -------------------------------------------------------------- 2 video
    await f.step('B video-calls A -> in-app incoming screen on A (no FCM)', () async {
      await f.backToHome();
      final members = await f.net(() => apiB.getJson('/circle/members'));
      final edge = ((members['results'] ?? members['members']) as List)
          .cast<Map>()
          .firstWhere((m) => '${m['name']}'.contains('Rahim'));
      await f.net(() async {
        final c = CallController(
          media: _AudioOnlyMedia(),
          signaling: ApiCallSignaling(apiB, rtB),
          sounds: _Silent(),
          video: true,
          outgoing: true,
          memberId: (edge['id'] as num).toInt(),
        );
        callB = c;
        unawaited(c.start());
      });
      await f.waitFor(find.byType(IncomingCallScreen), seconds: 20,
          what: 'incoming call screen on A');
      await f.shot('video-incoming');
      await f.eventually('B sees "ringing" (A\'s phone acked)',
          () async => callB!.phase == CallPhase.ringing, seconds: 15);
    });

    await f.step('A accepts -> video call connects (A camera + B audio)', () async {
      await f.tap(find.byKey(const Key('incoming-accept')), settleSeconds: 2);
      await f.waitFor(find.byType(CircleCallScreen), what: 'call screen');
      await f.eventually('B (caller) reached ICE connected',
          () async => callB!.phase == CallPhase.connected,
          seconds: 40);
      for (var i = 0; i < 40 && !_timer.hasMatch(_status(f)); i++) {
        await f.tester.pump(const Duration(milliseconds: 500));
      }
      if (!_timer.hasMatch(_status(f))) {
        throw TestFailure('A video never connected (status "${_status(f)}")');
      }
      await f.tester.pump(const Duration(seconds: 2));
      await f.shot('video-connected');
      f.note('video: ICE connected; A sends camera, B audio-only (one emulator camera)');
    });

    await f.step('A hangs up from the call screen', () async {
      await f.tap(find.byKey(const Key('call-hangup')), settleSeconds: 3);
      await f.eventually('B saw the end', () async => callB!.isEnded, seconds: 10);
      callB?.dispose();
      callB = null;
    });

    // ------------------------------------------------------------ 3 decline
    await f.step('B calls again, A declines -> B ends "Declined"', () async {
      final members = await f.net(() => apiB.getJson('/circle/members'));
      final edge = ((members['results'] ?? members['members']) as List)
          .cast<Map>()
          .firstWhere((m) => '${m['name']}'.contains('Rahim'));
      await f.net(() async {
        final c = CallController(
          media: _AudioOnlyMedia(),
          signaling: ApiCallSignaling(apiB, rtB),
          sounds: _Silent(),
          video: false,
          outgoing: true,
          memberId: (edge['id'] as num).toInt(),
        );
        callB = c;
        unawaited(c.start());
      });
      await f.waitFor(find.byType(IncomingCallScreen), seconds: 20,
          what: 'incoming call screen on A');
      await f.tap(find.byKey(const Key('incoming-decline')), settleSeconds: 2);
      await f.eventually('B ended as declined',
          () async => callB!.endReason == CallEndReason.declined, seconds: 15);
      await f.shot('declined');
      callB?.dispose();
      callB = null;
    });

    await subB?.cancel();
    await rtB.close();
    f.note('media CONTENT (hearing/seeing each other), TURN relay and app-closed '
        'ring are NOT provable on one CI emulator — two-phone checklist');
    f.needsKey('two real phones (Wi-Fi <-> mobile data) for audio/video + TURN + FCM ring');
  }, timeout: const Duration(minutes: 8));
}
