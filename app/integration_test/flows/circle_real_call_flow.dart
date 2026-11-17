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
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/api.dart';
import 'package:assisto/calls/api_call_signaling.dart';
import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/calls/call_runtime.dart';
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

/// B's media: real WebRTC, but its camera is "blocked" so it never fights A
/// for the emulator's single front camera. gatefix (gate run 44133650344):
/// this used to open as a VOICE call (open(video: false)), so B's video-call
/// offer had no video m-line at all; now B is a real VIDEO call whose camera
/// cannot open — the app's own cameraUnavailable path — and must still
/// RECEIVE A's video.
class _AudioOnlyMedia extends WebRtcCallMedia {
  _AudioOnlyMedia() : super(cameraBlocked: true);
}

final _timer = RegExp(r'^\d{2}:\d{2}$');

String _status(RFlow f) {
  final w = find.byKey(const Key('call-status'));
  if (w.evaluate().isEmpty) return '';
  return (w.evaluate().first.widget as Text).data ?? '';
}

/// gatefix (lead, 17 Nov): ICE "connected" is not enough — prove MEDIA
/// flows both ways. Two getStats() samples >= 6 s apart on BOTH peers (A =
/// the app's live call, B = the second client): each side's inbound-rtp
/// AUDIO packets and payload bytes must grow. With [videoToB] (the video
/// call: A's camera — the gate's circle leg runs an EMULATED front camera)
/// B must have decoded video frames, and more of them in the second sample.
Future<String> _proveMediaFlows(RFlow f, String what, CallController b,
    {bool videoToB = false}) async {
  final a = CallRuntime.instance.currentCall;
  if (a == null) throw TestFailure('$what: no live call on A to read stats from');
  final a1 = await f.net(() => a.media.stats());
  final b1 = await f.net(() => b.media.stats());
  await f.pumpFor(const Duration(seconds: 6));
  final a2 = await f.net(() => a.media.stats());
  final b2 = await f.net(() => b.media.stats());
  String grew(String who, MediaStats s1, MediaStats s2) {
    final p1 = s1.audioPacketsIn, p2 = s2.audioPacketsIn;
    final y1 = s1.audioBytesIn, y2 = s2.audioBytesIn;
    if (p1 == null || p2 == null || y1 == null || y2 == null) {
      throw TestFailure('$what: $who reported no inbound audio stats');
    }
    if (p2 <= p1 || y2 <= y1) {
      throw TestFailure('$what: $who received no audio over 6 s '
          '(packets $p1->$p2, bytes $y1->$y2)');
    }
    return '$who audio in +${p2 - p1} pkts/+${y2 - y1} B';
  }
  final na = grew('A', a1, a2), nb = grew('B', b1, b2);
  // gatefix: A's OUTBOUND video next to B's INBOUND, so a failure says where
  // the picture stopped (never encoded / never sent / never decoded).
  final vid = 'A video out: framesEncoded ${a1.videoFramesEncoded}->${a2.videoFramesEncoded}, '
      'packetsSent ${a1.videoPacketsSent}->${a2.videoPacketsSent}; '
      'B video in: framesDecoded ${b1.videoFramesDecoded}->${b2.videoFramesDecoded}';
  if (videoToB) {
    final v1 = b1.videoFramesDecoded ?? 0, v2 = b2.videoFramesDecoded ?? 0;
    if (v2 <= 0 || v2 <= v1) {
      throw TestFailure('$what: B decoded no video from A\'s camera over 6 s ($vid)');
    }
  }
  return '$what media: $na, $nb; $vid';
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
      // gatefix: first open of My Circle offers chat bubbles (bubbles2 sheet)
      // over the list — tap "Later" like a user (key, not text).
      if (await f.appears(find.byKey(const Key('bbl2-later')), seconds: 4)) {
        await f.tap(find.byKey(const Key('bbl2-later')), settleSeconds: 2);
      }
      await f.waitFor(find.text(Seed.nameB), what: 'B in the chat list');
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
      // rf1: each client POSTs its "connected" event only AFTER reading its
      // WebRTC stats (relayed or not), so the server lags the on-screen
      // timer by a moment. Run 40216392274 read it once, too early
      // ("phase: accepted"). Poll; a server that never records the connect
      // (duration 0 in the call log) still fails here.
      Map<String, dynamic> st = const {};
      try {
        await f.eventually('server records the call as connected', () async {
          st = await apiB.getJson('/circle/calls/${callId()}');
          return st['phase'] == 'connected';
        }, seconds: 15);
      } on TestFailure {
        throw TestFailure('server phase: $st');
      }
      await f.tester.pump(const Duration(seconds: 2));
      await f.shot('voice-connected');
      f.note('voice: ICE connected both sides (host candidates, one emulator)');
      f.note(await _proveMediaFlows(f, 'voice', callB!));
    });

    await f.step('B hangs up -> A shows "Call ended"; call log has the call', () async {
      await f.net(() => callB!.hangup());
      // gatefix: wa-polish ends a CONNECTED call with its talk time
      // ("Call ended · 0:03", WhatsApp-style), so the status line (Key
      // call-status) must read exactly waCallEndedAfter(<m:ss>) — this voice
      // call connected in the step above, so the talk time is required.
      final endedRe = RegExp('^${RegExp.escape(f.t.waCallEndedAfter('@T@')).replaceAll('@T@', '[0-9০-৯]+:[0-9০-৯]{2}')}\$');
      await f.waitFor(
          find.byWidgetPredicate((w) =>
              w is Text &&
              w.key == const Key('call-status') &&
              endedRe.hasMatch(w.data ?? '')),
          seconds: 10,
          what: 'Call ended · <talk time> on A');
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
      try {
        await f.waitFor(find.byType(IncomingCallScreen), seconds: 20,
            what: 'incoming call screen on A');
      } catch (e) {
        // rt1: say WHY (B's side) — "ringing" = the server never queued
        // call.incoming for A; "ended/offline" = A looked unreachable.
        throw TestFailure('$e (B phase=${callB?.phase}, end=${callB?.endReason})');
      }
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
      // gatefix: the gate's circle leg now runs an EMULATED front camera
      // (with -camera-front none, gate run 44091251063, A's camera track
      // failed and the call silently carried audio only) — so B must decode
      // A's video frames.
      f.note('video: ICE connected; A sends the emulated camera, B audio-only');
      f.note(await _proveMediaFlows(f, 'video', callB!, videoToB: true));
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
    // gatefix (owner 17 Nov "stronger test + phone list"): CI proved signalling,
    // ring, connect, media packets both ways, decoded video, ended + talk
    // time and decline. What only two REAL phones show is the owner's
    // checklist (closed-testing build, before production) — not a downgrade.
    f.ownerCheck('Call with Assisto CLOSED on the other phone: it rings (FCM full-screen ring)');
    f.ownerCheck('Voice call: both people really HEAR each other');
    f.ownerCheck('Video call: both see each other\'s real camera picture');
    f.ownerCheck('Wi-Fi on one phone, mobile data on the other: call connects (TURN relay)');
  }, timeout: const Duration(minutes: 8));

  // ------------------------------------------------------------------------
  // gatefix (owner P0, 18 Nov): video must flow BOTH ways in every way a
  // video call can start. ONE emulator, TWO emulated cameras (gate circle
  // leg: -camera-front emulated -camera-back emulated): A (this app, UI)
  // uses the front camera, B (second client, real CallController +
  // WebRtcCallMedia) the back one. Every case is REQUIRED: on each receiving
  // side framesDecoded > 0 at t=3 s and growing by t=10 s. Evidence (both
  // sides' SDP offer/answer, transceivers, video rtp stats at 3 s and 10 s)
  // is printed to logcat as GATEFIX_EVIDENCE lines (the circle artifact).
  realityFlow('18v_video_both_ways', 'My Circle',
      'Video both ways: (a) both cameras, (b) caller camera off -> on, (c) voice -> video; frames decoded on each side',
      (f) async {
    await f.home();
    late ApiClient apiB;
    late PollRealtimeTransport rtB;
    final incomingB = <Map<String, dynamic>>[];
    CallController? callB;
    await f.step('B (second client) signs in, real-time channel open', () async {
      apiB = await f.net(() => f.h.backend(userB: true));
      rtB = PollRealtimeTransport.forApi(apiB);
      rtB.events.listen((e) {
        if (e.topic == 'call.incoming') incomingB.add(e.payload);
      });
      await f.net(() => rtB.connect());
      rtB.setFast(true);
    });
    Future<int> edgeToA() async {
      final members = await f.net(() => apiB.getJson('/circle/members'));
      return (((members['results'] ?? members['members']) as List)
          .cast<Map>()
          .firstWhere((m) => '${m['name']}'.contains('Rahim'))['id'] as num)
          .toInt();
    }

    Future<WebRtcCallMedia> bCalls({required bool video, bool cameraBlocked = false}) async {
      final media = WebRtcCallMedia(cameraBlocked: cameraBlocked, facing: 'environment');
      final edge = await edgeToA();
      await f.net(() async {
        final c = CallController(
          media: media,
          signaling: ApiCallSignaling(apiB, rtB),
          sounds: _Silent(),
          video: video,
          outgoing: true,
          memberId: edge,
        );
        callB = c;
        unawaited(c.start());
      });
      await f.waitFor(find.byType(IncomingCallScreen), seconds: 20, what: 'incoming call screen on A');
      await f.tap(find.byKey(const Key('incoming-accept')), settleSeconds: 2);
      await f.waitFor(find.byType(CircleCallScreen), what: 'call screen on A');
      await f.eventually('B connected', () async => callB!.phase == CallPhase.connected, seconds: 40);
      await f.eventually('A connected', () async =>
          CallRuntime.instance.currentCall?.phase == CallPhase.connected, seconds: 20);
      return media;
    }

    Future<void> dump(String kase, String t) async {
      final a = CallRuntime.instance.currentCall?.media;
      final b = callB?.media;
      for (final side in [('A', a), ('B', b)]) {
        final m = side.$2;
        final ev = m is WebRtcCallMedia ? await f.net(() => m.debugEvidence()) : {'media': '${m.runtimeType}'};
        final js = jsonEncode(ev);
        const n = 700;
        final parts = (js.length + n - 1) ~/ n;
        for (var i = 0; i < parts; i++) {
          // ignore: avoid_print
          print('GATEFIX_EVIDENCE $kase ${side.$1} $t ${i + 1}/$parts '
              '${js.substring(i * n, (i + 1) * n > js.length ? js.length : (i + 1) * n)}');
        }
      }
    }

    /// Both directions: framesDecoded > 0 at 3 s and growing by 10 s on BOTH
    /// receiving sides; A-out / B-out encoded frames printed next to them.
    Future<void> proveBothWays(String kase) async {
      final a = CallRuntime.instance.currentCall;
      if (a == null) throw TestFailure('$kase: no live call on A');
      await f.pumpFor(const Duration(seconds: 3));
      await dump(kase, 't3');
      final a3 = await f.net(() => a.media.stats());
      final b3 = await f.net(() => callB!.media.stats());
      await f.pumpFor(const Duration(seconds: 7));
      await dump(kase, 't10');
      final a10 = await f.net(() => a.media.stats());
      final b10 = await f.net(() => callB!.media.stats());
      final line = '$kase: A out enc ${a3.videoFramesEncoded}->${a10.videoFramesEncoded} '
          '-> B in dec ${b3.videoFramesDecoded}->${b10.videoFramesDecoded}; '
          'B out enc ${b3.videoFramesEncoded}->${b10.videoFramesEncoded} '
          '-> A in dec ${a3.videoFramesDecoded}->${a10.videoFramesDecoded}';
      f.note(line);
      bool ok(int? x3, int? x10) => (x3 ?? 0) > 0 && (x10 ?? 0) > (x3 ?? 0);
      if (!ok(b3.videoFramesDecoded, b10.videoFramesDecoded)) {
        throw TestFailure('A->B video not flowing. $line');
      }
      if (!ok(a3.videoFramesDecoded, a10.videoFramesDecoded)) {
        throw TestFailure('B->A video not flowing. $line');
      }
    }

    Future<void> endCall() async {
      await f.tap(find.byKey(const Key('call-hangup')), settleSeconds: 3);
      await f.eventually('B saw the end', () async => callB!.isEnded, seconds: 10);
      callB?.dispose();
      callB = null;
      await f.backToHome();
      await f.pumpFor(const Duration(seconds: 2));
    }

    await f.step('(a) video call, both cameras on -> frames both ways', () async {
      await bCalls(video: true);
      await f.shot('a-connected');
      await proveBothWays('a');
      await endCall();
    });

    await f.step('(b) caller camera off at start, then on mid-call -> frames both ways', () async {
      final mb = await bCalls(video: true, cameraBlocked: true);
      if (!mb.cameraUnavailable) throw TestFailure('(b) B camera should start unavailable');
      mb.cameraBlocked = false;
      await f.net(() => callB!.toggleCamera());
      if (!callB!.cameraOn) throw TestFailure('(b) B camera did not turn on (log ${callB!.log})');
      await f.shot('b-camera-on');
      await proveBothWays('b');
      await endCall();
    });

    await f.step('(c) voice call switched to video mid-call -> frames both ways', () async {
      await bCalls(video: false);
      await f.net(() => callB!.requestVideo());
      final a = CallRuntime.instance.currentCall!;
      await f.eventually('A sees the video request', () async => a.upgrade == VideoUpgrade.incoming,
          seconds: 15);
      await f.net(() => a.acceptVideo());
      await f.eventually('both on video', () async => a.videoOn && callB!.videoOn, seconds: 20);
      await f.shot('c-video');
      await proveBothWays('c');
      await endCall();
    });
    await rtB.close();
  }, timeout: const Duration(minutes: 10));
}
