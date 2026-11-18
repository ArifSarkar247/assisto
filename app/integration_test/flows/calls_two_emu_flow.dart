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

import 'package:assisto/audio/audio_route_service.dart'; // calls-quality
import 'package:assisto/calls/call_native.dart'; // calls-quality
import 'package:assisto/calls/call_video_profile.dart'; // calls-quality
import 'package:assisto/perf/low_ram.dart'; // calls-quality

import '../support/call_quality_watch.dart'; // calls-quality
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
    // calls-2emu (gate 44256598783): a stalled direction is often the app's
    // weak-network policy pausing the SENDER's video (estimate < 40 kbps since calls-quality; 120 on
    // an overloaded CI host) — say so in the failure, it is not a lost m-line.
    final aPaused = a.videoPausedForNet, bPaused = s10.b['pausedForNet'] == true;
    final why = (aPaused || bPaused)
        ? ' [weak-network pause: A ${aPaused ? 'PAUSED' : 'sending'} (${s10.a.availableKbps?.round()} kbps), '
            'B ${bPaused ? 'PAUSED' : 'sending'} (${(s10.b['availableKbps'] as num?)?.round()} kbps)]'
        : '';
    f.note('$line$why');
    bool grew(int? x3, int? x10) => (x3 ?? 0) > 0 && (x10 ?? 0) > (x3 ?? 0);
    final abOk = grew(s3.bDec, s10.bDec), baOk = grew(s3.a.videoFramesDecoded, s10.a.videoFramesDecoded);
    final audioOk = grew(s3.a.audioPacketsIn, s10.a.audioPacketsIn) && grew(s3.bAudio, s10.bAudio);
    try {
      await f.net(() => _req('POST', '/sample', {
            'case': kase, 'line': line, 'a_to_b': abOk, 'b_to_a': baOk, 'audio': audioOk,
            'need_a_to_b': aToB, 'need_b_to_a': bToA,
          }));
    } catch (_) {}
    if (aToB && !abOk) throw TestFailure('A->B video NOT flowing (B decoded no growing frames). $line$why');
    if (bToA && !baOk) throw TestFailure('B->A video NOT flowing (A decoded no growing frames). $line$why');
    if (!audioOk) throw TestFailure('audio NOT flowing both ways. $line');
  }

  /// B just turned its camera on: B's encoder must produce frames within 12 s
  /// and A must decode B's first frame within 12 s of B's camera tap (the
  /// time a user waits for the other person's picture). Numbers in the note.
  /// calls-quality: this device's clock minus the runner's (ms), NTP-style.
  Future<int> clockOffset() async {
    final t0 = DateTime.now().millisecondsSinceEpoch;
    final h = await f.net(() => _req('GET', '/clock'));
    final t1 = DateTime.now().millisecondsSinceEpoch;
    return (t0 + t1) ~/ 2 - (h['host_ms'] as num).toInt();
  }

  Future<void> bCameraOnAndFirstFrame(String kase) async {
    // calls-quality: both phones' own clocks, put on the runner's clock
    final offA = await clockOffset();
    final offB = ((await b('clock'))['offset_ms'] as num).toInt();
    final dec0 = (await f.net(() => a.media.stats())).videoFramesDecoded ?? 0;
    final sw = Stopwatch()..start();
    // A watches for B's first decoded frame WHILE B turns its camera on
    final id = await send('cameraOn');
    int dec = dec0;
    int? aFirstAt;
    while (sw.elapsed < const Duration(seconds: 15)) {
      dec = (await f.net(() => a.media.stats())).videoFramesDecoded ?? 0;
      if (dec > dec0) {
        aFirstAt = DateTime.now().millisecondsSinceEpoch;
        break;
      }
      await f.tester.pump(const Duration(milliseconds: 100));
    }
    final r = await result(id, 'cameraOn', seconds: 30);
    if (r['cameraOn'] != true || r['cameraUnavailable'] == true) {
      throw TestFailure('$kase: B camera did not turn on: $r');
    }
    if (((r['framesEncoded'] as num?) ?? 0) <= 0) {
      throw TestFailure('$kase: B camera on but its encoder made no frame in 12 s: $r');
    }
    f.note('$kase: B camera on -> B first encoded frame ${r['firstFrameMs']} ms, '
        'A first decoded frame ${aFirstAt != null ? '${sw.elapsedMilliseconds} ms' : 'NONE in 15 s'}');
    if (aFirstAt == null) {
      throw TestFailure('$kase: B turned its camera on but A decoded no frame of it in 15 s ($r)');
    }
    // calls-quality (lead 18 Nov): HARD 3 s bar — B's camera first frame (B's
    // own clock) -> A's first decoded frame (A's own clock), both on the
    // runner's clock.
    final bAt = (r['firstFrameAt'] as num?)?.toInt();
    if (bAt == null) throw TestFailure('$kase: B reported no first-frame time ($r)');
    final camToPicture = (aFirstAt - offA) - (bAt - offB);
    f.note('$kase: CAMERA FIRST FRAME -> PEER FIRST DECODED FRAME = $camToPicture ms '
        '(phones\' clocks; offsets A $offA ms, B $offB ms; bar 3000 ms)');
    try {
      await f.net(() => _req('POST', '/sample', {
            'case': '${kase}_cam', 'line': '$kase camera->picture $camToPicture ms', 'cam_to_picture_ms': camToPicture,
          }));
    } catch (_) {}
    if (camToPicture > 3000) {
      throw TestFailure('$kase: camera first frame -> A first decoded frame took $camToPicture ms (> 3 s bar)');
    }
    // calls-camfast: camera on mid-call must NOT renegotiate (the fix; it
    // cost ~4.3 s of signalling). The camera-to-picture gap is measured and
    // reported (A's clock starts earlier than B's: an upper bound). On the CI
    // emulators it is dominated by software VP8 at 3-5 fps (encode ~300 ms a
    // frame) and the decoder start, so it is a number here, not a bar.
    f.note('$kase: replaceTrack=${r['replaceTrack']} renegotiated=${r['renegotiated']}');
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

// ======================================================== calls-quality
// Opt-in quality cases on the same two emulators (calls2emu.yml with the
// quality id set: push ci/calls-quality-run** or dispatch with ids=...). The
// job runs a real coturn on the runner for these (TURN_HOST 10.0.2.2 =
// the runner), and the control channel's /host actions change the network.
//
//   18q_relay      TURN relay ONLY on both sides: the call connects through the
//                  TURN server and media flows both ways (pair = relay on both)
//   18q_lossy      3G-like link on the TURN legs (tc netem: ~300 ms RTT, ~3 %
//                  loss each way, 3 Mbit shared): audio keeps flowing, video
//                  keeps moving — no freeze > 2 s on either side; measured
//   18q_netswitch  Wi-Fi -> mobile data -> Wi-Fi on A mid-call: the call
//                  survives through an ICE restart (A caller, then A callee)
//   18q_pip        Home mid video call: picture-in-picture shows and video
//                  keeps flowing both ways; back to the app restores the call
//   18q_audio      voice call: speaker <-> earpiece toggling changes the
//                  phone's REAL communication device (AudioManager), audio
//                  keeps flowing; a video call starts on the speaker
//
// HONEST LIMIT: emulators on one host; netem shapes only the TURN legs; the
// emulator's "cellular" is a virtual radio; there is no real earpiece/speaker
// sound (the route is read back from Android's AudioManager).
extension _Quality on _TwoEmu {
  /// A places a call with extra answer options for B (relayOnly, ...).
  Future<Map<String, dynamic>> qCall({required bool video, Map<String, dynamic> bArgs = const {}}) async {
    await openChatWithB();
    final seen = ((await b('incomingCount'))['count'] as num).toInt();
    final ans = await send('answer', {'seen': seen, 'cameraBlocked': false, 'timeout': 40, ...bArgs});
    await f.tap(find.byTooltip(video ? f.t.circleVideo : f.t.circleVoiceCall), settleSeconds: 2);
    await f.waitFor(find.byType(CircleCallScreen), what: 'call screen on A');
    final r = await result(ans, 'answer A\'s ${video ? 'video' : 'voice'} call', seconds: 90);
    await connectedOnA();
    return r;
  }

  /// Control-channel request that survives this phone's network switching
  /// (Wi-Fi off -> mobile data takes a few seconds; run 44254417569 lost a
  /// request there). Retried for ~20 s, never inside a failing runAsync.
  Future<Map<String, dynamic>> ctl(String method, String path, [Map<String, dynamic>? body]) async {
    final r = await f.net(() async {
      Object? last;
      for (var i = 0; i < 40; i++) {
        try {
          return await _req(method, path, body);
        } catch (e) {
          last = e;
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      }
      return <String, dynamic>{'_error': 'control channel unreachable: $last'};
    });
    if (r == null) throw TestFailure('control channel request $path failed');
    if (r['_error'] != null) throw TestFailure('${r['_error']} ($path)');
    return r;
  }

  Future<Map<String, dynamic>> host(String op, [Map<String, dynamic> args = const {}]) =>
      ctl('POST', '/host', {'op': op, ...args});

  /// [send] / [b] through [ctl] (for steps where A's network changes).
  Future<int> sendR(String cmd, [Map<String, dynamic> args = const {}]) async =>
      ((await ctl('POST', '/cmd', {'cmd': cmd, 'args': args}))['id'] as num).toInt();

  Future<Map<String, dynamic>> bR(String cmd, [Map<String, dynamic> args = const {}, int seconds = 60]) async =>
      result(await sendR(cmd, args), cmd, seconds: seconds);

  /// Wait until BOTH sides decoded a first video frame (TURN / slow starts);
  /// returns ms until then. Fails after [seconds].
  Future<int> firstFramesBoth(String label, {int seconds = 15}) async {
    final sw = Stopwatch()..start();
    while (sw.elapsed < Duration(seconds: seconds)) {
      final da = (await f.net(() => a.media.stats())).videoFramesDecoded ?? 0;
      final db = ((await b('quality', const {}, 20))['vin_frames'] as num?)?.toInt() ?? 0;
      if (da > 0 && db > 0) {
        f.note('$label: first video frame on both sides after ${sw.elapsedMilliseconds} ms (from connected)');
        return sw.elapsedMilliseconds;
      }
      await f.tester.pump(const Duration(milliseconds: 300));
    }
    throw TestFailure('$label: no first video frame on both sides in $seconds s');
  }

  WebRtcCallMedia get aMedia {
    final m = a.media;
    if (m is! WebRtcCallMedia) throw TestFailure('A media is not WebRTC');
    return m;
  }

  /// Both sides measured over the SAME window: A here, B on emulator 2.
  /// [pumping] false = A waits without pumping frames (picture-in-picture).
  Future<(Map<String, dynamic>, Map<String, dynamic>)> watchBoth(String label, int seconds,
      {bool pumping = true}) async {
    final m = aMedia;
    final id = await sendR('watch', {'seconds': seconds, 'label': label});
    final wa = await watchQuality(() => f.net(m.debugQuality), Duration(seconds: seconds),
        tick: pumping
            ? () => f.tester.pump(const Duration(milliseconds: 250))
            : () => f.net(() => Future<void>.delayed(const Duration(milliseconds: 250))));
    final wb = await result(id, 'watch $label', seconds: seconds + 30);
    final line = '$label: A sees [${qualityLine(wa)}] | B sees [${qualityLine(wb)}]';
    f.note(line);
    try {
      await f.net(() => _req('POST', '/sample', {'case': label, 'line': line, 'a': wa, 'b': wb}));
    } catch (_) {}
    return (wa, wb);
  }

  void needMoving(String label, Map<String, dynamic> wa, Map<String, dynamic> wb,
      {int maxVideoGapMs = 0, int maxAudioGapMs = 0}) {
    for (final (side, w) in [('A', wa), ('B', wb)]) {
      if (((w['video_frames'] as num?) ?? 0) <= 0) {
        throw TestFailure('$label: $side decoded NO new video frame (${qualityLine(w)})');
      }
      if (((w['audio_packets'] as num?) ?? 0) <= 0) {
        throw TestFailure('$label: $side received NO audio (${qualityLine(w)})');
      }
      final vg = (w['video_max_gap_ms'] as num?) ?? 0, ag = (w['audio_max_gap_ms'] as num?) ?? 0;
      if (maxVideoGapMs > 0 && vg > maxVideoGapMs) {
        throw TestFailure('$label: $side video froze $vg ms (> $maxVideoGapMs) (${qualityLine(w)})');
      }
      if (maxAudioGapMs > 0 && ag > maxAudioGapMs) {
        throw TestFailure('$label: $side audio stopped $ag ms (> $maxAudioGapMs) (${qualityLine(w)})');
      }
    }
  }

  Future<void> waitLive(String what, {int seconds = 30, CallController? call}) async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    while (DateTime.now().isBefore(end)) {
      final c = call ?? CallRuntime.instance.currentCall;
      if (c != null && c.phase == CallPhase.connected) return;
      if (c == null || c.isEnded) throw TestFailure('$what: the call ENDED (${c?.endReason}, log ${c?.log})');
      await f.tester.pump(const Duration(milliseconds: 300));
    }
    final c = call ?? CallRuntime.instance.currentCall;
    throw TestFailure('$what: not connected again in $seconds s (phase ${c?.phase}, log ${c?.log})');
  }

  Future<AudioRoute?> osRoute() => f.net(() => MethodChannelAudioRoutePlatform().active());

  /// Resolution state of both sides: camera (source) size, sent size, the
  /// policy's ladder rung / target height, smoothed uplink.
  Future<(Map<String, dynamic>, Map<String, dynamic>)> resolution(String label) async {
    final c = a;
    final Map<String, dynamic> qa = {
      ...await f.net(aMedia.debugQuality),
      'rung': c.netPolicy.rung, 'targetHeight': c.netPolicy.targetHeight,
      'uplinkKbps': c.netPolicy.uplinkKbps, 'ramMb': LowRamTuning.ramMb,
    };
    final qb = await b('quality', const {}, 20);
    String one(Map<String, dynamic> q) => 'ram ${q['ramMb']} MB, capture ${q['capture']}, camera '
        '${q['src_w']}x${q['src_h']}, sent ${q['vout_w']}x${q['vout_h']}@${q['vout_fps']} '
        '(limit ${q['vout_limit']}), ladder ${q['targetHeight']}p, uplink ${(q['uplinkKbps'] as num?)?.round()} kbps, '
        'plan ${q['plan']}';
    final line = '$label: A [${one(qa)}] | B [${one(qb)}]';
    f.note(line);
    try {
      await f.net(() => _req('POST', '/sample', {'case': label, 'line': line, 'res_a': qa, 'res_b': qb}));
    } catch (_) {}
    return (qa, qb);
  }
}

int _longEdge(Map<String, dynamic> q, String w, String h) {
  final x = (q[w] as num?)?.toInt() ?? 0, y = (q[h] as num?)?.toInt() ?? 0;
  return x > y ? x : y;
}

void registerCallsQualityFlows() {
  const t = Duration(minutes: 8);
  realityFlow('18q_res', 'My Circle', 'Two emulators: adaptive camera size — 2 GB phone 480p, 4 GB phone 720p',
      (f) async {
    await f.home();
    await f.net(() => LowRamTuning.apply()); // no-op when the app already read it
    final e = _TwoEmu(f);
    await e.reset();
    await e.kase('q_res', () async {
      await f.step('A (2 GB) video-calls B (4 GB); B answers', () async {
        // a new app session on both phones: no weak uplink remembered from
        // the earlier cases (the emulators' uplink is ~300 kbit/s)
        CallVideoProfile.lastUplinkKbps = null;
        await e.qCall(video: true, bArgs: {'freshProfile': true});
      });
      await f.step('video both ways', () => e.prove('q_res'));
      await f.step('A opened its camera at 480p, B at 720p (RAM decides)', () async {
        final (qa, qb) = await e.resolution('q_res');
        final ra = (qa['ramMb'] as num?)?.toInt() ?? 0, rb = (qb['ramMb'] as num?)?.toInt() ?? 0;
        if (ra <= 0 || ra > 3328) throw TestFailure('A should read as a <= 3 GB phone (ram $ra MB)');
        if (rb <= 3328) throw TestFailure('B should read as a > 3 GB phone (ram $rb MB)');
        if (qa['capture'] != 'sd480' || _longEdge(qa, 'src_w', 'src_h') > 640) {
          throw TestFailure('A (2 GB) camera not 480p: ${qa['capture']} ${qa['src_w']}x${qa['src_h']}');
        }
        if (qb['capture'] != 'hd720' || _longEdge(qb, 'src_w', 'src_h') < 1280) {
          throw TestFailure('B (4 GB) camera not 720p: ${qb['capture']} ${qb['src_w']}x${qb['src_h']}');
        }
        if ((qa['targetHeight'] as num) > 480) throw TestFailure('A ladder above its 480p camera: $qa');
        await f.shot('q-res');
      });
      await f.step('A hangs up', e.aHangsUp);
    });
  }, timeout: t);

  realityFlow('18q_relay', 'My Circle', 'Two emulators: TURN relay only on both sides, media both ways',
      (f) async {
    await f.home();
    final e = _TwoEmu(f);
    await e.reset();
    await e.kase('q_relay', () async {
      WebRtcCallMedia.debugIcePolicy = 'relay';
      try {
        await f.step('A video-calls B with relay-only ICE on BOTH sides; B answers', () async {
          await e.qCall(video: true, bArgs: {'relayOnly': true});
          if (!e.a.turnAvailable) {
            throw TestFailure('the backend gave A no TURN server (rtc config not configured)');
          }
        });
        await f.step('video + audio both ways through TURN', () async {
          await e.firstFramesBoth('q_relay');
          await e.prove('q_relay');
        });
        await f.step('the pair in use is a TURN relay on both sides', () async {
          final (wa, wb) = await e.watchBoth('q_relay_path', 6);
          if (!isRelayed(wa) || !isRelayed(wb)) {
            throw TestFailure('not relayed: A ${wa['local']}->${wa['remote']}, B ${wb['local']}->${wb['remote']}');
          }
          e.needMoving('q_relay_path', wa, wb);
          await f.shot('q-relay');
        });
        await f.step('A hangs up', e.aHangsUp);
      } finally {
        WebRtcCallMedia.debugIcePolicy = null;
      }
    });
  }, timeout: t);

  realityFlow('18q_lossy', 'My Circle', 'Two emulators: 3G-like lossy link (300 ms RTT, 3 % loss) — audio flows, video never freezes > 2 s',
      (f) async {
    await f.home();
    final e = _TwoEmu(f);
    await e.reset();
    await e.kase('q_lossy', () async {
      WebRtcCallMedia.debugIcePolicy = 'relay'; // all media on the shaped TURN legs
      try {
        await f.step('A video-calls B (through TURN); B answers', () async {
          await e.qCall(video: true, bArgs: {'relayOnly': true});
        });
        late (Map<String, dynamic>, Map<String, dynamic>) clean;
        late (Map<String, dynamic>, Map<String, dynamic>) cleanW;
        await f.step('baseline: 15 s on a clean link', () async {
          await e.firstFramesBoth('q_lossy');
          cleanW = await e.watchBoth('q_lossy_clean', 15);
          e.needMoving('q_lossy_clean', cleanW.$1, cleanW.$2);
          clean = await e.resolution('q_res_clean');
        });
        await f.step('3G-like link: ~300 ms RTT, ~3 % loss each way, 3 Mbit — 30 s measured', () async {
          // run 44254417569: netem jitter (10 ms) REORDERS packets, the
          // bandwidth estimate collapsed to 41 kbit/s and both phones paused
          // their video (audio-only fallback) for 20 s — a reordering
          // artefact, not 3G. Constant delay + random loss here.
          final n = await e.host('netem', {'on': true, 'delay_ms': 75, 'jitter_ms': 0, 'loss_pct': 1.5, 'rate_kbit': 3000});
          if ((n['errors'] as List?)?.isNotEmpty ?? true) throw TestFailure('netem not applied: $n');
          await f.pumpFor(const Duration(seconds: 5)); // let congestion control react
          final (wa, wb) = await e.watchBoth('q_lossy_3g', 30);
          final rtt = (wa['rtt_median_ms'] as num?) ?? 0;
          if (rtt < 200) throw TestFailure('netem had no effect (A rtt $rtt ms) — not a lossy test');
          if (e.a.videoPausedForNet) throw TestFailure('A paused its video on the 3G link (${qualityLine(wa)})');
          final qb = await e.b('quality', const {}, 20);
          f.note('q_lossy_3g: B plan ${qb['plan']}');
          // the 2 s freeze bar: libwebrtc's own freeze counter (a freeze =
          // a frame gap > 3x the average, > avg + 150 ms) must stay <= 2 s in
          // the whole 30 s window; our own sampled gap may not grow beyond
          // the clean link's (the CI emulators decode at 1-6 fps in software
          // with clean-link gaps up to ~5 s — run 44254417569 — so an
          // absolute 2 s sampled gap is the emulator's CPU, not the network).
          e.needMoving('q_lossy_3g', wa, wb, maxAudioGapMs: 2000);
          for (final (side, w, c) in [('A', wa, cleanW.$1), ('B', wb, cleanW.$2)]) {
            // libwebrtc counts a freeze only when a frame gap exceeds
            // max(3 x average, average + 150 ms): every freeze is > 150 ms, so
            // the LONGEST one is at most total - (count - 1) x 150 ms
            final fz = (w['freeze_ms'] as num?)?.toInt() ?? 0, fc = (w['freezes'] as num?)?.toInt() ?? 0;
            final longest = fc <= 1 ? fz : fz - (fc - 1) * 150;
            f.note('q_lossy_3g $side: libwebrtc freezes $fc, total $fz ms, longest <= $longest ms');
            if (longest > 2000) {
              throw TestFailure('$side video froze up to $longest ms on 3G (libwebrtc $fc freezes / $fz ms) (${qualityLine(w)})');
            }
            final g = (w['video_max_gap_ms'] as num).toInt(), g0 = (c['video_max_gap_ms'] as num).toInt();
            final allowed = (g0 * 1.5).round() + 500 < 2000 ? 2000 : (g0 * 1.5).round() + 500;
            if (g > allowed) {
              throw TestFailure('$side picture stood still $g ms on 3G (clean link $g0 ms, allowed $allowed) (${qualityLine(w)})');
            }
          }
          if (!e.a.isLive) throw TestFailure('call not live on the lossy link (${e.a.phase})');
          await e.resolution('q_res_3g');
        });
        await f.step('the uplink drops (400 kbit shared): both phones step their video DOWN live', () async {
          final n = await e.host('netem', {'on': true, 'delay_ms': 75, 'jitter_ms': 0, 'loss_pct': 1.5, 'rate_kbit': 400});
          if ((n['errors'] as List?)?.isNotEmpty ?? true) throw TestFailure('netem not applied: $n');
          final (wa, wb) = await e.watchBoth('q_lossy_tight', 24);
          e.needMoving('q_lossy_tight', wa, wb); // still moving (no 2 s bar while it adapts)
          // honest label on A's call screen while the picture is small
          await f.tester.pump(const Duration(milliseconds: 300));
          final lbl = find.byKey(const Key('call-quality-text'));
          if (lbl.evaluate().isEmpty) {
            throw TestFailure('no "weak connection" label on A while its video steps down (quality ${e.a.quality})');
          }
          final txt = (lbl.evaluate().first.widget as Text).data;
          f.note('q_lossy_tight: A screen label "$txt" (quality ${e.a.quality}), video paused=${e.a.videoPausedForNet}');
          if (e.a.videoPausedForNet) throw TestFailure('A paused its video at 400 kbit/s (should step down, not pause)');
          await f.shot('q-lossy-weak-label');
          final (qa, qb) = await e.resolution('q_res_tight');
          final (ca, cb) = clean;
          for (final (side, c0, c1, w0, w1) in [('A', ca, qa, cleanW.$1, wa), ('B', cb, qb, cleanW.$2, wb)]) {
            final h0 = (c0['targetHeight'] as num).toInt(), h1 = (c1['targetHeight'] as num).toInt();
            // the encoder's own target (what it really sends at) must drop
            // with the uplink, or the ladder must step down
            final t0 = (w0['out_target_kbps'] as num?)?.toInt() ?? 0, t1 = (w1['out_target_kbps'] as num?)?.toInt() ?? 0;
            f.note('q_lossy_tight $side: ladder ${h0}p -> ${h1}p, encoder target $t0 -> $t1 kbps');
            if (!(h1 < h0 || (t0 > 0 && t1 > 0 && t1 <= t0 * 0.8))) {
              throw TestFailure('$side did not adapt down: ladder ${h0}p -> ${h1}p, encoder $t0 -> $t1 kbps '
                  '(uplink ${c1['uplinkKbps']} kbps, plan ${c1['plan']})');
            }
            final s0 = _longEdge(c0, 'vout_w', 'vout_h'), s1 = _longEdge(c1, 'vout_w', 'vout_h');
            if (s0 > 0 && s1 > s0) throw TestFailure('$side sends a BIGGER picture on the tight link ($s0 -> $s1)');
          }
        });
      } finally {
        await e.host('netem', {'on': false});
        WebRtcCallMedia.debugIcePolicy = null;
      }
      await f.step('link clean again: media recovers (8 s)', () async {
        final (wa, wb) = await e.watchBoth('q_lossy_after', 8);
        e.needMoving('q_lossy_after', wa, wb, maxVideoGapMs: 2000);
      });
      await f.step('A hangs up', e.aHangsUp);
    });
  }, timeout: t);

  realityFlow('18q_netswitch', 'My Circle', 'Two emulators: Wi-Fi <-> mobile data mid-call, the call survives (ICE restart)',
      (f) async {
    await f.home();
    final e = _TwoEmu(f);
    await e.reset();
    Future<void> switchAndSurvive(String label, bool wifiOn) async {
      final call = e.a; // this call object, whatever the screens do
      final before = call.log.length;
      Future<String?> ufrag() async {
        final ev = await f.net((call.media as WebRtcCallMedia).debugEvidence);
        return RegExp(r'a=ice-ufrag:(\S+)').firstMatch('${ev['local_sdp'] ?? ''}')?.group(1);
      }
      final u0 = await ufrag();
      final n0 = await e.host('net', {'side': 'A'});
      final sw = Stopwatch()..start();
      final h = await e.host('wifi', {'side': 'A', 'on': wifiOn});
      // B measures the outage as the user on the other phone sees it
      final id = await e.sendR('watch', {'seconds': 30, 'label': label});
      // the phone reports the switch (Android default-network callback) ->
      // "Reconnecting" + ICE restart; then the call must be connected again
      final seenBy = DateTime.now().add(const Duration(seconds: 12));
      while (DateTime.now().isBefore(seenBy) && !call.log.skip(before).any((x) => x.startsWith('net:'))) {
        await f.tester.pump(const Duration(milliseconds: 250));
      }
      await e.waitLive(label, seconds: 45, call: call);
      final wa = await watchQuality(() => f.net((call.media as WebRtcCallMedia).debugQuality), const Duration(seconds: 8),
          tick: () => f.tester.pump(const Duration(milliseconds: 250)));
      final wb = await e.result(id, 'watch $label', seconds: 70);
      final n1 = await e.host('net', {'side': 'A'});
      final u1 = await ufrag();
      final newLog = call.log.skip(before).toList();
      final restarted = newLog.any((x) => x.startsWith('restart_offer') || x.startsWith('restart_request') ||
          x.contains('restart'));
      final line = '$label: wifi ${wifiOn ? 'ON' : 'OFF'} (${h['svc']}) default ${n0['lines']} -> ${n1['lines']}; '
          'live again ${sw.elapsedMilliseconds} ms; ICE ufrag $u0 -> $u1; B outage (max video gap) ${wb['video_max_gap_ms']} ms, '
          'audio gap ${wb['audio_max_gap_ms']} ms; A after [${qualityLine(wa)}]; A log $newLog';
      f.note(line);
      try {
        await f.net(() => _req('POST', '/sample', {'case': label, 'line': line, 'a': wa, 'b': wb}));
      } catch (_) {}
      if (!newLog.any((x) => x.startsWith('net:'))) {
        throw TestFailure('$label: A never saw the network change (log $newLog)');
      }
      if (!restarted) throw TestFailure('$label: no ICE restart after the switch (log $newLog)');
      // a REAL restart has new ICE credentials (calls2emu 44272508208: the
      // ufrag never changed — the restart was a no-op on Android)
      if (u0 != null && u0 == u1) {
        throw TestFailure('$label: ICE "restart" kept the old credentials (ufrag $u0) (log $newLog)');
      }
      if (((wa['video_frames'] as num?) ?? 0) <= 0 || ((wa['audio_packets'] as num?) ?? 0) <= 0) {
        throw TestFailure('$label: media did not come back on A (${qualityLine(wa)})');
      }
      final q = await e.bR('quality', const {}, 20);
      if (q['phase'] != '${CallPhase.connected}') throw TestFailure('$label: B not connected ($q)');
    }

    await e.kase('q_net', () async {
      try {
        await f.step('A (caller) video-calls B; B answers', () => e.qCall(video: true));
        await f.step('media both ways on Wi-Fi', () => e.prove('q_net_wifi'));
        await f.step('A: Wi-Fi OFF -> mobile data; the call survives', () => switchAndSurvive('q_net_to_cell', false));
        await f.step('A: Wi-Fi back ON; the call survives', () => switchAndSurvive('q_net_to_wifi', true));
        await f.step('media both ways after both switches', () => e.prove('q_net_after'));
        await f.step('A hangs up', e.aHangsUp);
        await f.step('B (caller) video-calls A; A answers', () => e.bCallsA(video: true));
        await f.step('A (callee): Wi-Fi OFF -> mobile data; B restarts ICE on A\'s request',
            () => switchAndSurvive('q_net_callee_to_cell', false));
        await f.step('B hangs up', () async {
          await e.b('hangup', const {}, 30);
          await f.backToHome();
        });
      } finally {
        await e.host('wifi', {'side': 'A', 'on': true});
      }
    });
  }, timeout: const Duration(minutes: 10));

  realityFlow('18q_audio', 'My Circle', 'Two emulators: speaker <-> earpiece toggling changes the real audio route, audio keeps flowing',
      (f) async {
    await f.home();
    final e = _TwoEmu(f);
    await e.reset();
    Future<void> expectRoute(String label, AudioRoute want) async {
      AudioRoute? os;
      final end = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(end)) {
        os = await e.osRoute();
        if (e.a.route == want && os == want) break;
        await f.tester.pump(const Duration(milliseconds: 250));
      }
      final d = await e.host('audio', {'side': 'A'});
      f.note('$label: app route ${e.a.route.name}, Android route ${os?.name}, routes ${e.a.routes}; '
          'dumpsys ${(d['lines'] as List?)?.take(8).toList()}');
      if (e.a.route != want || os != want) {
        throw TestFailure('$label: wanted ${want.name}, app ${e.a.route.name}, Android ${os?.name}');
      }
    }

    await e.kase('q_audio', () async {
      await f.step('A voice-calls B; B answers', () => e.qCall(video: false));
      // calls-quality: the CI emulator (like a tablet) has NO earpiece in
      // Android's communication devices — then the honest result is "speaker,
      // and the screen says speaker" (run 44261908414: the screen said
      // earpiece while Android played on the speaker).
      final hasEar = AudioRouteService.instance.has(AudioRoute.earpiece);
      final quiet = hasEar ? AudioRoute.earpiece : AudioRoute.speaker;
      f.note('q_audio: Android communication outputs ${AudioRouteService.instance.outputs.map((o) => o.route.name).toList()}');
      await f.step('a voice call starts on the ${quiet.name} (screen = Android)', () => expectRoute('q_audio_start', quiet));
      await f.step('tap Speaker: the loudspeaker', () async {
        await f.tap(find.byKey(const Key('call-speaker')), settleSeconds: 1);
        await expectRoute('q_audio_speaker', AudioRoute.speaker);
      });
      await f.step('tap again: back to the ${quiet.name}', () async {
        await f.tap(find.byKey(const Key('call-speaker')), settleSeconds: 1);
        await expectRoute('q_audio_back', quiet);
      });
      await f.step('speaker once more, then audio still flows both ways', () async {
        await f.tap(find.byKey(const Key('call-speaker')), settleSeconds: 1);
        await expectRoute('q_audio_speaker2', AudioRoute.speaker);
        final s = await e.sample('q_audio', 't1');
        await f.pumpFor(const Duration(seconds: 4));
        final s2 = await e.sample('q_audio', 't2');
        if ((s2.a.audioPacketsIn ?? 0) <= (s.a.audioPacketsIn ?? 0) || (s2.bAudio ?? 0) <= (s.bAudio ?? 0)) {
          throw TestFailure('audio stopped after route changes: A ${s.a.audioPacketsIn}->${s2.a.audioPacketsIn}, '
              'B ${s.bAudio}->${s2.bAudio}');
        }
      });
      await f.step('A hangs up: Android leaves call audio mode', () async {
        await e.aHangsUp();
        final d = await e.host('audio', {'side': 'A'});
        f.note('q_audio_end: dumpsys ${(d['lines'] as List?)?.take(8).toList()}');
      });
    });
    await e.kase('q_audio_v', () async {
      await f.step('A video-calls B: a video call starts on the speaker', () async {
        await e.qCall(video: true);
        await expectRoute('q_audio_video', AudioRoute.speaker);
      });
      await f.step('A hangs up', e.aHangsUp);
    });
  }, timeout: t);

  realityFlow('18q_pip', 'My Circle', 'Two emulators: Home mid video call -> picture-in-picture, video keeps flowing, return restores',
      (f) async {
    await f.home();
    CallNative.listen(); // the app's own start-up does this (main.dart)
    final e = _TwoEmu(f);
    await e.reset();
    String? flagProblem;
    await e.kase('q_pip', () async {
      try {
        await f.step('A video-calls B; B answers', () => e.qCall(video: true));
        await f.step('video both ways', () async {
          await e.firstFramesBoth('q_pip');
          await e.prove('q_pip_before');
        });
        await f.step('A presses Home: the call shrinks into picture-in-picture', () async {
          await e.host('key', {'side': 'A', 'key': 'HOME'});
          final sw = Stopwatch()..start();
          while (!CallNative.inPip.value && sw.elapsed < const Duration(seconds: 8)) {
            await f.net(() => Future<void>.delayed(const Duration(milliseconds: 200)));
          }
          final st = await e.host('pip', {'side': 'A'});
          final view = WidgetsBinding.instance.platformDispatcher.views.first;
          f.note('q_pip: app inPip=${CallNative.inPip.value} after ${sw.elapsedMilliseconds} ms; '
              'Android pinned=${st['pinned']}; Flutter view ${view.physicalSize}, '
              'lifecycle ${WidgetsBinding.instance.lifecycleState}');
          if (st['pinned'] != true) throw TestFailure('Android shows no pinned task after Home ($st, log ${e.a.log})');
          if (!CallNative.inPip.value) {
            // keep measuring (video in PiP, the way back) — fail at the end
            flagProblem = 'Android shows the call in PiP but the app was never told (CallNative.inPip false, '
                'view ${view.physicalSize}) — see AssistoCalls lines in logcat';
          }
        });
        await f.step('in PiP: video + audio still flow both ways (camera not paused)', () async {
          final (wa, wb) = await e.watchBoth('q_pip_in', 8, pumping: false);
          e.needMoving('q_pip_in', wa, wb);
          if (e.a.cameraPausedBg) throw TestFailure('A paused its camera in PiP');
        });
        await f.step('A returns to the app: full-screen call again', () async {
          final sw = Stopwatch()..start();
          final r = await e.host('launch', {'side': 'A'});
          var pinned = true;
          while (sw.elapsed < const Duration(seconds: 10)) {
            await f.net(() => Future<void>.delayed(const Duration(milliseconds: 400)));
            pinned = (await e.host('pip', {'side': 'A'}))['pinned'] == true;
            if (!pinned && !CallNative.inPip.value) break;
          }
          if (pinned) throw TestFailure('Android still shows PiP after returning ($r)');
          if (CallNative.inPip.value) throw TestFailure('the app still thinks it is in PiP after returning');
          await f.waitFor(find.byType(CircleCallScreen), seconds: 10, what: 'call screen after PiP');
          await e.waitLive('after PiP', seconds: 10);
          f.note('q_pip: back full screen in ${sw.elapsedMilliseconds} ms');
          await f.shot('q-pip-back');
        });
        await f.step('video both ways after PiP', () => e.prove('q_pip_after'));
        await f.step('A hangs up', e.aHangsUp);
        await f.step('the app knew it was in PiP', () async {
          if (flagProblem != null) throw TestFailure(flagProblem!);
        });
      } finally {
        // never leave A's app pinned for the next case (run 44254417569:
        // the driver died after a failed PiP case)
        try {
          if ((await e.host('pip', {'side': 'A'}))['pinned'] == true) await e.host('launch', {'side': 'A'});
        } catch (_) {}
      }
    });
  }, timeout: t);
}
