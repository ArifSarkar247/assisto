// circle-screenshare — REAL screen-share proof on the CI emulator (gate
// circle leg: emulated front camera, API 33), against the seeded Django:
//
//   A = Reality Rahim — the app under test, driven through the UI
//   B = Reality Karim — an independent second client in the same process
//       (its own ApiClient + real-time + CallController + RTCPeerConnection)
//
//   1  B video-calls A (B's camera "blocked" = the gatefix path: B has NO
//      video sender, only the recv-only video transceiver), A accepts.
//   2  A taps Share screen -> our sheet -> Continue -> Android's consent (the
//      CI host allows it: tools/reality/run_flows.sh REALITY_PROJECTION) ->
//      the red bar. PROOF: A's outbound video frames grow AND B decodes more
//      frames over 6 s, and B's controller knows it is a screen.
//      (A HAD a camera sender -> replaceTrack, no renegotiation.)
//   3  A taps Stop -> the bar goes, A's camera is back: B still decodes.
//   4  B shares (no sender -> the screen is ADDED, B the caller re-offers) ->
//      A decodes B's frames and shows "<B> is sharing their screen".
//   5  B stops; A hangs up.
//
// HONEST LIMITS: both clients share ONE emulator screen and ONE MediaProjection
// grant at a time; frames prove the media path, not what a human sees (the
// owner's two-phone checklist: owner_actions/FEATURE_CARD_SCREEN_SHARE_BN.md).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/api.dart';
import 'package:assisto/calls/api_call_signaling.dart';
import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/calls/call_runtime.dart';
import 'package:assisto/calls/screen_share.dart';
import 'package:assisto/calls/webrtc_media.dart';
import 'package:assisto/push/incoming_call_screen.dart';
import 'package:assisto/realtime/realtime_transport.dart';
import 'package:assisto/screens/circle_call_screen.dart';

import '../support/harness.dart';

class _Quiet implements CallSounds {
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

/// B: a real VIDEO call whose camera cannot open (one emulator camera).
class _NoCameraMedia extends WebRtcCallMedia {
  _NoCameraMedia() : super(cameraBlocked: true);
}

/// Tell the CI host Android's consent dialog is about to show.
void _askHostForProjection(String tag) {
  // ignore: avoid_print
  print('REALITY_PROJECTION ss_$tag');
}

/// [sender]'s outbound video and [receiver]'s decoded frames must BOTH grow
/// over 6 s (a ticking call timer keeps the shared screen changing).
Future<String> _framesFlow(RFlow f, String what, CallController sender,
    CallController receiver) async {
  final s1 = await f.net(() => sender.media.stats());
  final r1 = await f.net(() => receiver.media.stats());
  await f.pumpFor(const Duration(seconds: 6));
  final s2 = await f.net(() => sender.media.stats());
  final r2 = await f.net(() => receiver.media.stats());
  final line = '$what: out framesEncoded ${s1.videoFramesEncoded}->${s2.videoFramesEncoded}, '
      'packetsSent ${s1.videoPacketsSent}->${s2.videoPacketsSent}; '
      'in framesDecoded ${r1.videoFramesDecoded}->${r2.videoFramesDecoded}';
  final e1 = s1.videoFramesEncoded ?? 0, e2 = s2.videoFramesEncoded ?? 0;
  final d1 = r1.videoFramesDecoded ?? 0, d2 = r2.videoFramesDecoded ?? 0;
  if (e2 <= e1) throw TestFailure('$what: nothing encoded over 6 s ($line)');
  if (d2 <= 0 || d2 <= d1) {
    throw TestFailure('$what: the other side decoded no frames over 6 s ($line)');
  }
  return line;
}

void registerCircleScreenShareFlows() {
  realityFlow('18s_circle_screen_share', 'My Circle',
      'REAL screen share in a video call: A shares (replaceTrack) -> B decodes; '
      'Stop -> camera back; B without camera shares (added + re-offer) -> A decodes',
      (f) async {
    await f.home();
    late ApiClient apiB;
    late PollRealtimeTransport rtB;
    CallController? callB;
    final tag = DateTime.now().millisecondsSinceEpoch.toString();

    await f.step('B signs in; B video-calls A; A accepts; connected', () async {
      apiB = await f.net(() => f.h.backend(userB: true));
      rtB = PollRealtimeTransport.forApi(apiB);
      await f.net(() => rtB.connect());
      rtB.setFast(true);
      final members = await f.net(() => apiB.getJson('/circle/members'));
      final edge = ((members['results'] ?? members['members']) as List)
          .cast<Map>()
          .firstWhere((m) => '${m['name']}'.contains('Rahim'));
      await f.net(() async {
        final c = CallController(
          media: _NoCameraMedia(),
          signaling: ApiCallSignaling(apiB, rtB),
          sounds: _Quiet(),
          video: true,
          outgoing: true,
          memberId: (edge['id'] as num).toInt(),
        );
        callB = c;
        unawaited(c.start());
      });
      await f.waitFor(find.byType(IncomingCallScreen), seconds: 25,
          what: 'incoming call screen on A');
      await f.tap(find.byKey(const Key('incoming-accept')), settleSeconds: 2);
      await f.waitFor(find.byType(CircleCallScreen), what: 'call screen');
      await f.eventually('B reached ICE connected',
          () async => callB!.phase == CallPhase.connected,
          seconds: 40);
      await f.eventually('A is live', () async => CallRuntime.instance.currentCall?.isLive == true,
          seconds: 20);
      await f.shot('ss-connected');
    });

    await f.step('A: Share screen -> our sheet -> Android consent -> red bar', () async {
      await f.waitFor(find.byKey(const Key('cssh-share')), what: 'Share screen button');
      await f.tap(find.byKey(const Key('cssh-share')), settleSeconds: 2);
      await f.waitFor(find.byKey(const Key('cssh-consent')), what: 'our consent sheet');
      await f.shot('ss-consent-sheet');
      _askHostForProjection('a_$tag');
      await f.pumpFor(const Duration(seconds: 2)); // host: appops first
      await f.tap(find.byKey(const Key('cssh-consent-go')), settleSeconds: 1);
      try {
        await f.waitFor(find.byKey(const Key('cssh-sharing-bar')), seconds: 60,
            what: 'the red sharing bar');
      } catch (e) {
        final a = CallRuntime.instance.currentCall;
        final ss = a == null ? null : ScreenShareController.of(a);
        throw TestFailure('$e (state=${ss?.state}, notice=${ss?.notice}, log=${ss?.log})');
      }
      await f.shot('ss-a-sharing');
    });

    await f.step('PROOF: A\'s screen frames reach B (replaceTrack, no renegotiation)',
        () async {
      final a = CallRuntime.instance.currentCall!;
      await f.eventually('B knows it is a shared screen',
          () async => callB!.remoteScreen, seconds: 15);
      f.note(await _framesFlow(f, 'A screen -> B', a, callB!));
      final reneg = a.log.where((l) => l.startsWith('reneg')).toList();
      if (reneg.isNotEmpty) f.note('A renegotiation log: $reneg');
    });

    await f.step('A: Stop -> bar gone, camera back, B still gets video', () async {
      await f.tap(find.byKey(const Key('cssh-stop')), settleSeconds: 3);
      await f.waitFor(find.byKey(const Key('cssh-share')), seconds: 15,
          what: 'Share screen button again');
      final a = CallRuntime.instance.currentCall!;
      if (a.screenSharing) throw TestFailure('A still marked as sharing');
      await f.eventually('B: no longer a screen', () async => !callB!.remoteScreen,
          seconds: 15);
      if (a.media.cameraUnavailable || !a.cameraOn) {
        // an emulator without a camera (reality legs with -camera-front none)
        f.note('A has no camera on this emulator: camera-back not measurable');
      } else {
        f.note(await _framesFlow(f, 'A camera after Stop -> B', a, callB!));
      }
      await f.shot('ss-a-stopped');
    });

    await f.step('B (no camera sender) shares -> added + re-offer -> A decodes, chip',
        () async {
      final ssB = ScreenShareController.of(callB!)!;
      await f.net(() => ssB.request());
      if (ssB.state != ScreenShareState.consent) {
        throw TestFailure('B: no consent state (${ssB.state}, ${ssB.notice})');
      }
      _askHostForProjection('b_$tag');
      await f.pumpFor(const Duration(seconds: 2));
      // live binding: real async; f.eventually below pumps while Android asks
      unawaited(ssB.confirm());
      await f.eventually('B is sharing', () async => ssB.sharing, seconds: 60);
      final a = CallRuntime.instance.currentCall!;
      await f.eventually('A sees a shared screen', () async => a.remoteScreen,
          seconds: 20);
      await f.waitFor(find.byKey(const Key('cssh-remote-chip')), seconds: 20,
          what: '"<B> is sharing their screen" on A');
      await f.shot('ss-b-sharing-on-a');
      f.note('B log: ${callB!.log.where((l) => l.startsWith('reneg') || l.startsWith('screen')).toList()}');
      f.note(await _framesFlow(f, 'B screen -> A', callB!, a));
      await f.net(() => ssB.stop());
      await f.eventually('A: no longer a screen', () async => !a.remoteScreen,
          seconds: 15);
    });

    await f.step('A hangs up', () async {
      await f.tap(find.byKey(const Key('call-hangup')), settleSeconds: 3);
      await f.eventually('B saw the end', () async => callB!.isEnded, seconds: 10);
      callB?.dispose();
      callB = null;
      await rtB.close();
    });

    f.ownerCheck('Screen share on two real phones: the other person sees my whole screen (not cropped)');
    f.ownerCheck('Screen share: status-bar / notification "Stop sharing" brings my camera back');
  }, timeout: const Duration(minutes: 6));
}
