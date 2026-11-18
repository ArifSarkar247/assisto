// calls-2emu — VIDEO CALLS BETWEEN TWO EMULATORS (owner, 17 Nov: prove video
// calls with two real app instances calling each other).
//
//   A = this app (Reality Rahim) on emulator-5554, driven through its UI.
//   B = the call peer (integration_test/call_peer_app.dart, Reality Karim) on
//       emulator-5556 — a SEPARATE app process on a SEPARATE emulator with its
//       own emulated camera, using the app's real call stack.
// A tells B what to do (answer, place a call, camera on/off, accept video,
// read stats) through the runner's test-only control channel
// (tools/calls2emu/control.py at 10.0.2.2:8710); signalling and media go
// through the throw-away Django exactly like two phones.
//
// Every case is REQUIRED (one flow id each, so one failure never hides the
// others): on each receiving side framesDecoded > 0 at 3 s and growing by
// 10 s; audio packets grow both ways. Evidence per case and side (SDP
// offer/answer, transceivers, in/out video rtp stats at 3 s and 10 s) is
// saved by the control channel as artifacts (calls2emu/evidence/*.json), and
// both screens are recorded per case (calls2emu/videos/*.mp4, best effort).
//
//   18w_a  video call A -> B, both cameras on
//   18w_b  caller camera off -> on mid-call: B calls with its camera off,
//          A answers, B turns it on; then A (caller) turns its camera off and
//          on again with the call-camera button
//   18w_c  voice call A -> B, A switches to video (call-to-video), B accepts
//   18w_d  camera unavailable: B answers A's video call with NO camera — A's
//          video still reaches B and audio flows both ways; then B's camera
//          becomes available and video flows both ways
//
// HONEST LIMIT: both emulators run on one CI host (ICE over the host network,
// no TURN) and their cameras are the emulator's virtual scene — decoded frames
// prove the picture travels; the owner's two-phone list still covers real
// cameras, mobile data and an app that is closed.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/calls/call_runtime.dart';
import 'package:assisto/calls/webrtc_media.dart';
import 'package:assisto/push/incoming_call_screen.dart';
import 'package:assisto/screens/circle_call_screen.dart';

import '../support/harness.dart';

const _ctl = String.fromEnvironment('CALLS2EMU_CTL', defaultValue: 'http://10.0.2.2:8710');
final _http = HttpClient()..connectionTimeout = const Duration(seconds: 10);

Future<Map<String, dynamic>> _req(String method, String path, [Map<String, dynamic>? body]) async {
  final rq = await _http.openUrl(method, Uri.parse('$_ctl$path')).timeout(const Duration(seconds: 15));
  if (body != null) {
    // calls-2emu run 44173136049: without a length HttpClient sends the body
    // chunked and the control channel read nothing.
    final bytes = utf8.encode(jsonEncode(body));
    rq.headers.contentType = ContentType.json;
    rq.contentLength = bytes.length;
    rq.add(bytes);
  }
  final rs = await rq.close().timeout(const Duration(seconds: 20));
  final txt = await rs.transform(utf8.decoder).join();
  final j = jsonDecode(txt.isEmpty ? '{}' : txt);
  return j is Map<String, dynamic> ? j : <String, dynamic>{};
}

/// One stats sample of both sides.
class _Sample {
  _Sample(this.a, this.b);
  final MediaStats a;
  final Map<String, dynamic> b;
  int? get bDec => (b['videoFramesDecoded'] as num?)?.toInt();
  int? get bEnc => (b['videoFramesEncoded'] as num?)?.toInt();
  int? get bAudio => (b['audioPacketsIn'] as num?)?.toInt();
}

class _TwoEmu {
  _TwoEmu(this.f);
  final RFlow f;

  /// Post a command to B; returns its id (B runs it while A keeps going).
  Future<int> send(String cmd, [Map<String, dynamic> args = const {}]) async {
    final r = await f.net(() => _req('POST', '/cmd', {'cmd': cmd, 'args': args}));
    return (r['id'] as num).toInt();
  }

  /// Wait for B's answer to command [id]; a failure on B fails the case with
  /// B's own message. The UI keeps pumping while A waits.
  Future<Map<String, dynamic>> result(int id, String what, {int seconds = 60}) async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    Object? last;
    while (DateTime.now().isBefore(end)) {
      try {
        final r = await f.net(() => _req('GET', '/result?id=$id&wait=1'));
        if (r['pending'] != true) {
          if (r['ok'] != true) throw TestFailure('peer B failed "$what": ${r['error']}');
          return (r['result'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
        }
      } on TestFailure {
        rethrow;
      } catch (e) {
        last = e;
      }
      await f.tester.pump(const Duration(milliseconds: 400));
    }
    throw TestFailure('peer B did not finish "$what" in $seconds s'
        '${last != null ? ' (control channel: $last)' : ''} — see calls2emu/peer_B.log');
  }

  Future<Map<String, dynamic>> b(String cmd, [Map<String, dynamic> args = const {}, int seconds = 60]) async =>
      result(await send(cmd, args), cmd, seconds: seconds);

  Future<void> rec(String kase, bool on) async {
    try {
      await f.net(() => _req('POST', '/rec', {'case': kase, 'on': on}));
    } catch (_) {} // recordings are evidence only
  }

  /// Clean slate: B idle and A without a live call (a failed earlier case may
  /// have left one), A on home.
  Future<void> reset() async {
    await f.step('B (peer on emulator 2) is signed in and idle; A has no live call', () async {
      final st = await f.net(() => _req('GET', '/state'));
      if ((st['hello'] as Map?)?['side'] != 'B') {
        throw TestFailure('peer B never said hello on the control channel (state $st) — see calls2emu/peer_B.log');
      }
      await b('reset', const {}, 30);
      final live = CallRuntime.instance.currentCall;
      if (live != null && !live.isEnded) await f.net(() => live.hangup());
      await f.backToHome();
    });
  }

  Future<void> openChatWithB() async {
    await f.openRoute('circle');
    if (await f.appears(find.byKey(const Key('bbl2-later')), seconds: 4)) {
      await f.tap(find.byKey(const Key('bbl2-later')), settleSeconds: 2);
    }
    await f.waitFor(find.text(Seed.nameB), what: 'B in the chat list');
    await f.tap(find.text(Seed.nameB), settleSeconds: 3);
  }

  /// A places a call from the chat screen; B answers it on emulator 2.
  Future<Map<String, dynamic>> aCallsB({required bool video, bool bCameraUnavailable = false}) async {
    await openChatWithB();
    final seen = ((await b('incomingCount'))['count'] as num).toInt();
    final ans = await send('answer', {'seen': seen, 'cameraBlocked': bCameraUnavailable, 'timeout': 40});
    await f.tap(find.byTooltip(video ? f.t.circleVideo : f.t.circleVoiceCall), settleSeconds: 2);
    await f.waitFor(find.byType(CircleCallScreen), what: 'call screen on A');
    final r = await result(ans, 'answer A\'s ${video ? 'video' : 'voice'} call', seconds: 75);
    await connectedOnA();
    return r;
  }

  /// B places a call; A answers in its own incoming-call screen.
  Future<Map<String, dynamic>> bCallsA({required bool video, bool bCameraUnavailable = false}) async {
    await f.backToHome();
    await b('call', {'video': video, 'cameraBlocked': bCameraUnavailable});
    await f.waitFor(find.byType(IncomingCallScreen), seconds: 30, what: 'incoming call screen on A');
    await f.tap(find.byKey(const Key('incoming-accept')), settleSeconds: 2);
    await f.waitFor(find.byType(CircleCallScreen), what: 'call screen on A');
    final r = await b('waitConnected', const {}, 60);
    await connectedOnA();
    return r;
  }

  Future<void> connectedOnA() async {
    final end = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(end)) {
      if (CallRuntime.instance.currentCall?.phase == CallPhase.connected) return;
      await f.tester.pump(const Duration(milliseconds: 300));
    }
    final c = CallRuntime.instance.currentCall;
    throw TestFailure('A never reached connected (phase ${c?.phase}, log ${c?.log})');
  }

  CallController get a {
    final c = CallRuntime.instance.currentCall;
    if (c == null || c.isEnded) throw TestFailure('A has no live call');
    return c;
  }

  Future<_Sample> sample(String kase, String t) async {
    final c = a;
    final sa = await f.net(() => c.media.stats());
    final m = c.media;
    if (m is WebRtcCallMedia) {
      final ev = await f.net(() => m.debugEvidence());
      await f.net(() => _req('POST', '/evidence', {'case': kase, 'side': 'A', 't': t, 'data': ev}));
    }
    final bs = await b('stats', {'case': kase, 't': t}, 30);
    return _Sample(sa, bs);
  }

  /// framesDecoded > 0 at 3 s and growing by 10 s on each REQUIRED receiving
  /// side; audio grows both ways. Never retried.
  Future<void> prove(String kase, {bool aToB = true, bool bToA = true}) async {
    await f.pumpFor(const Duration(seconds: 3));
    final s3 = await sample(kase, 't3');
    await f.pumpFor(const Duration(seconds: 7));
    final s10 = await sample(kase, 't10');
    final line = '$kase: A out enc ${s3.a.videoFramesEncoded}->${s10.a.videoFramesEncoded} '
        '-> B in dec ${s3.bDec}->${s10.bDec}; '
        'B out enc ${s3.bEnc}->${s10.bEnc} -> A in dec ${s3.a.videoFramesDecoded}->${s10.a.videoFramesDecoded}; '
        'audio in A ${s3.a.audioPacketsIn}->${s10.a.audioPacketsIn}, B ${s3.bAudio}->${s10.bAudio}';
    f.note(line);
    bool grew(int? x3, int? x10) => (x3 ?? 0) > 0 && (x10 ?? 0) > (x3 ?? 0);
    final abOk = grew(s3.bDec, s10.bDec), baOk = grew(s3.a.videoFramesDecoded, s10.a.videoFramesDecoded);
    final audioOk = grew(s3.a.audioPacketsIn, s10.a.audioPacketsIn) && grew(s3.bAudio, s10.bAudio);
    try {
      await f.net(() => _req('POST', '/sample', {
            'case': kase, 'line': line, 'a_to_b': abOk, 'b_to_a': baOk, 'audio': audioOk,
            'need_a_to_b': aToB, 'need_b_to_a': bToA,
          }));
    } catch (_) {}
    if (aToB && !abOk) throw TestFailure('A->B video NOT flowing (B decoded no growing frames). $line');
    if (bToA && !baOk) throw TestFailure('B->A video NOT flowing (A decoded no growing frames). $line');
    if (!audioOk) throw TestFailure('audio NOT flowing both ways. $line');
  }

  /// B just turned its camera on: B's encoder must produce frames within 12 s
  /// and A must decode B's first frame within 12 s of B's camera tap (the
  /// time a user waits for the other person's picture). Numbers in the note.
  Future<void> bCameraOnAndFirstFrame(String kase) async {
    final sw = Stopwatch()..start();
    final r = await b('cameraOn', const {}, 30);
    if (r['cameraOn'] != true || r['cameraUnavailable'] == true) {
      throw TestFailure('$kase: B camera did not turn on: $r');
    }
    if (((r['framesEncoded'] as num?) ?? 0) <= 0) {
      throw TestFailure('$kase: B camera on but its encoder made no frame in 12 s: $r');
    }
    int dec = 0;
    while (sw.elapsed < const Duration(seconds: 12)) {
      dec = (await f.net(() => a.media.stats())).videoFramesDecoded ?? 0;
      if (dec > 0) break;
      await f.tester.pump(const Duration(milliseconds: 300));
    }
    f.note('$kase: B camera on -> B first encoded frame ${r['firstFrameMs']} ms, '
        'A first decoded frame ${dec > 0 ? '${sw.elapsedMilliseconds} ms' : 'NONE in 12 s'}');
    if (dec <= 0) {
      throw TestFailure('$kase: B turned its camera on but A decoded no frame of it in 12 s ($r)');
    }
    // calls-camfast: camera on mid-call must NOT renegotiate (the fix; it
    // cost ~4.3 s of signalling). The camera-to-picture gap is measured and
    // reported (A's clock starts earlier than B's: an upper bound). On the CI
    // emulators it is dominated by software VP8 at 3-5 fps (encode ~300 ms a
    // frame) and the decoder start, so it is a number here, not a bar.
    final gap = sw.elapsedMilliseconds - ((r['firstFrameMs'] as num?)?.toInt() ?? 0);
    f.note('$kase: camera first frame -> A first decoded frame <= $gap ms; '
        'replaceTrack=${r['replaceTrack']} renegotiated=${r['renegotiated']}');
    if (r['replaceTrack'] != true || r['renegotiated'] == true) {
      throw TestFailure('$kase: camera on renegotiated instead of using the ready video slot ($r)');
    }
    final ca = a;
    if (ca.log.any((e) => e.startsWith('reneg'))) {
      throw TestFailure('$kase: A renegotiated for B\'s camera (log ${ca.log})');
    }
  }

  Future<void> aHangsUp() async {
    await f.tap(find.byKey(const Key('call-hangup')), settleSeconds: 3);
    await b('waitEnded', const {}, 30);
    await f.backToHome();
    await f.pumpFor(const Duration(seconds: 2));
  }

  /// One case: screen recording of both emulators around it (always stopped).
  Future<void> kase(String id, Future<void> Function() body) async {
    await rec(id, true);
    try {
      await body();
    } finally {
      await rec(id, false);
    }
  }
}

void registerCallsTwoEmuFlows() {
  const t = Duration(minutes: 6);
  realityFlow('18w_a', 'My Circle', 'Two emulators: video call A->B, both cameras on, frames both ways',
      (f) async {
    await f.home();
    final e = _TwoEmu(f);
    await e.reset();
    await e.kase('a', () async {
      await f.step('A video-calls B from the chat; B answers on emulator 2', () async {
        final r = await e.aCallsB(video: true);
        if (r['video'] != true || r['cameraOn'] != true) throw TestFailure('B answered without video/camera: $r');
        await f.shot('a-connected');
      });
      await f.step('video both ways (framesDecoded > 0 at 3 s, growing at 10 s, each side)',
          () => e.prove('a'));
      await f.step('A hangs up -> B sees the end', e.aHangsUp);
    });
  }, timeout: t);

  realityFlow('18w_b', 'My Circle', 'Two emulators: caller camera off -> on mid-call, frames both ways',
      (f) async {
    await f.home();
    final e = _TwoEmu(f);
    await e.reset();
    await e.kase('b', () async {
      await f.step('B video-calls A with its camera OFF; A answers in the app', () async {
        final r = await e.bCallsA(video: true, bCameraUnavailable: true);
        if (r['cameraUnavailable'] != true) throw TestFailure('B camera should start off: $r');
        await f.shot('b-caller-camera-off');
      });
      await f.step('camera off: A\'s video still reaches B', () => e.prove('b_off', bToA: false));
      await f.step('B turns its camera ON mid-call; A sees B\'s first frame within 12 s',
          () => e.bCameraOnAndFirstFrame('b_on'));
      await f.step('video both ways after camera on', () => e.prove('b_on'));
      await f.step('B hangs up', () async {
        await e.b('hangup', const {}, 30);
        await f.backToHome();
      });
    });
    await e.kase('b2', () async {
      await f.step('A (caller) video-calls B; B answers', () => e.aCallsB(video: true));
      await f.step('A taps the camera button OFF, then ON again', () async {
        await f.tap(find.byKey(const Key('call-camera')), settleSeconds: 2);
        if (e.a.cameraOn) throw TestFailure('A camera still on after the camera button');
        await f.shot('b2-camera-off');
        await f.pumpFor(const Duration(seconds: 3));
        await f.tap(find.byKey(const Key('call-camera')), settleSeconds: 2);
        if (!e.a.cameraOn) throw TestFailure('A camera did not come back on');
      });
      await f.step('video both ways after A\'s camera came back', () => e.prove('b2'));
      await f.step('A hangs up', e.aHangsUp);
    });
  }, timeout: t);

  realityFlow('18w_c', 'My Circle', 'Two emulators: voice call switched to video mid-call, frames both ways',
      (f) async {
    await f.home();
    final e = _TwoEmu(f);
    await e.reset();
    await e.kase('c', () async {
      await f.step('A voice-calls B; B answers', () async {
        final r = await e.aCallsB(video: false);
        if (r['video'] == true) throw TestFailure('voice call answered as video: $r');
      });
      await f.step('A taps "Switch to video"; B accepts on emulator 2', () async {
        final acc = await e.send('acceptVideo');
        await f.tap(find.byKey(const Key('call-to-video')), settleSeconds: 2);
        final r = await e.result(acc, 'accept the video request', seconds: 45);
        if (r['video'] != true) throw TestFailure('B not on video: $r');
        final end = DateTime.now().add(const Duration(seconds: 20));
        while (!e.a.videoOn && DateTime.now().isBefore(end)) {
          await f.tester.pump(const Duration(milliseconds: 300));
        }
        if (!e.a.videoOn) throw TestFailure('A never switched to video (upgrade ${e.a.upgrade}, log ${e.a.log})');
        await f.shot('c-video');
      });
      await f.step('video both ways after the switch', () => e.prove('c'));
      await f.step('A hangs up', e.aHangsUp);
    });
  }, timeout: t);

  realityFlow('18w_d', 'My Circle', 'Two emulators: camera unavailable on B — call works, A\'s video reaches B; camera back -> both ways',
      (f) async {
    await f.home();
    final e = _TwoEmu(f);
    await e.reset();
    await e.kase('d', () async {
      await f.step('A video-calls B; B answers with NO camera available', () async {
        final r = await e.aCallsB(video: true, bCameraUnavailable: true);
        if (r['cameraUnavailable'] != true) throw TestFailure('B camera should be unavailable: $r');
        await f.shot('d-b-no-camera');
      });
      await f.step('no camera on B: A->B video + audio both ways still flow', () => e.prove('d_nocam', bToA: false));
      await f.step('B\'s camera becomes available and turns on; A sees it within 12 s',
          () => e.bCameraOnAndFirstFrame('d_back'));
      await f.step('video both ways after the camera came back', () => e.prove('d_back'));
      await f.step('A hangs up', e.aHangsUp);
    });
  }, timeout: t);
}
