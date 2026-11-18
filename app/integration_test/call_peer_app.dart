// calls-2emu — the CALL PEER (user B) for the two-emulator video call test
// (.github/workflows/calls2emu.yml, tools/calls2emu/run.sh).
//
// A SECOND app instance on its OWN emulator (emulator-5556, its own emulated
// front camera): the app's real call stack — ApiClient + PollRealtimeTransport
// + CallController + WebRtcCallMedia (flutter_webrtc), exactly the code a
// phone runs — signed in as the seeded CI user B (Reality Karim). It does
// nothing by itself: it executes commands that the flow driver on emulator A
// (integration_test/flows/calls_two_emu_flow.dart) posts to the runner's
// test-only control channel (tools/calls2emu/control.py, 10.0.2.2:8710) and
// posts each result back. Never the live server: REALITY_API_BASE is the
// throw-away Django inside the runner.
//
// The screen shows B's own camera and A's video (so the per-case screen
// recording of emulator B shows what B "sees").
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:assisto/api.dart';
import 'package:assisto/calls/api_call_signaling.dart';
import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/calls/webrtc_media.dart';
import 'package:assisto/config.dart';
import 'package:assisto/perf/low_ram.dart'; // calls-quality
import 'package:assisto/realtime/realtime_transport.dart';

import 'support/call_quality_watch.dart'; // calls-quality

const _ctl = String.fromEnvironment('CALLS2EMU_CTL', defaultValue: 'http://10.0.2.2:8710');
const _phoneB = String.fromEnvironment('REALITY_PHONE_B', defaultValue: '01700000002');
const _password = String.fromEnvironment('REALITY_PASSWORD', defaultValue: 'Reality#2026');

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
  final rs = await rq.close().timeout(const Duration(seconds: 30));
  final txt = await rs.transform(utf8.decoder).join();
  final j = jsonDecode(txt.isEmpty ? '{}' : txt);
  return j is Map<String, dynamic> ? j : <String, dynamic>{};
}

void _log(String line) {
  // ignore: avoid_print
  print('CALLS2EMU_PEER $line');
  unawaited(_req('POST', '/log', {'side': 'B', 'line': line}).catchError((_) => <String, dynamic>{}));
}

Map<String, dynamic> _statsJson(MediaStats s) => {
      'audioPacketsIn': s.audioPacketsIn,
      'audioBytesIn': s.audioBytesIn,
      'videoFramesDecoded': s.videoFramesDecoded,
      'videoFramesEncoded': s.videoFramesEncoded,
      'videoPacketsSent': s.videoPacketsSent,
      'relayed': s.relayed,
    };

/// One peer = one signed-in user B with its real-time channel.
class Peer extends ChangeNotifier {
  late ApiClient api;
  late PollRealtimeTransport rt;
  final incoming = <Map<String, dynamic>>[];
  CallController? call;
  WebRtcCallMedia? media;
  String status = 'starting';

  void _set(String s) {
    status = s;
    _log(s);
    notifyListeners();
  }

  Future<void> signIn() async {
    AppConfig.deviceId = 'calls2emu-peer-b';
    api = ApiClient();
    final r = await api.login(identifier: _phoneB, password: _password).timeout(const Duration(seconds: 60));
    api.token = r.token;
    api.lang = 'en';
    rt = PollRealtimeTransport.forApi(api);
    rt.events.listen((e) {
      if (e.topic == 'call.incoming') {
        incoming.add(e.payload);
        _log('call.incoming ${e.payload['call_id']} video=${e.payload['video']}');
      }
    });
    await rt.connect();
    rt.setFast(true);
    _set('signed in as B (${r.user.name})');
  }

  Future<T> _until<T>(String what, FutureOr<T?> Function() probe, int seconds) async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    while (DateTime.now().isBefore(end)) {
      final v = await probe();
      if (v != null && v != false) return v;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw TimeoutException('B: $what not reached in $seconds s (phase ${call?.phase}, log ${call?.log})');
  }

  CallController _need() {
    final c = call;
    if (c == null || c.isEnded) throw StateError('B has no live call (phase ${c?.phase}, log ${c?.log})');
    return c;
  }

  Future<void> _reset() async {
    final c = call;
    call = null;
    if (c != null) {
      if (!c.isEnded) {
        try {
          await c.hangup();
        } catch (_) {}
      }
      c.dispose();
    }
    media = null;
    notifyListeners();
  }

  /// Executes one command from A; returns the result body.
  Future<Map<String, dynamic>> run(String cmd, Map<String, dynamic> a) async {
    final video = a['video'] == true;
    final blocked = a['cameraBlocked'] == true;
    switch (cmd) {
      case 'ping': {
        return {'status': status};
      }
      case 'answer': { // wait for A's call to ring here, accept it, reach connected
        await _reset();
        final seen = (a['seen'] as num?)?.toInt() ?? 0;
        final inc = await _until('A\'s call ringing on B', () => incoming.length > seen ? incoming.last : null,
            (a['timeout'] as num?)?.toInt() ?? 30);
        final id = (inc['call_id'] as num).toInt();
        // calls-quality: relay-only ICE when A asks for the TURN proof
        WebRtcCallMedia.debugIcePolicy = a['relayOnly'] == true ? 'relay' : null;
        _set('answering call $id (video=${inc['video']}, camera ${blocked ? 'UNAVAILABLE' : 'ok'})');
        await api.postJson('/circle/calls/$id/event', {'event': 'ringing'});
        final m = media = WebRtcCallMedia(cameraBlocked: blocked);
        final c = call = CallController(
          media: m,
          signaling: ApiCallSignaling(api, rt),
          sounds: _Silent(),
          video: inc['video'] == true,
          outgoing: false,
          callId: id,
        );
        c.addListener(notifyListeners);
        unawaited(c.start());
        await _until('B connected', () => c.phase == CallPhase.connected ? true : null, 45);
        _set('connected call $id');
        return {'call_id': id, 'video': c.videoOn, 'cameraOn': c.cameraOn, 'cameraUnavailable': m.cameraUnavailable};
      }
      case 'call': { // B places a call to A (A answers in its UI)
        await _reset();
        final members = await api.getJson('/circle/members');
        final edge = (((members['results'] ?? members['members']) as List).cast<Map>())
            .firstWhere((m) => '${m['name']}'.contains('Rahim'));
        WebRtcCallMedia.debugIcePolicy = a['relayOnly'] == true ? 'relay' : null; // calls-quality
        final m = media = WebRtcCallMedia(cameraBlocked: blocked);
        final c = call = CallController(
          media: m,
          signaling: ApiCallSignaling(api, rt),
          sounds: _Silent(),
          video: video,
          outgoing: true,
          memberId: (edge['id'] as num).toInt(),
        );
        c.addListener(notifyListeners);
        unawaited(c.start());
        _set('calling A (video=$video, camera ${blocked ? 'UNAVAILABLE' : 'ok'})');
        return {'placed': true};
      }
      case 'waitConnected': {
        final c = call;
        if (c == null) throw StateError('B placed no call');
        await _until('B connected', () => c.phase == CallPhase.connected ? true : null, 45);
        _set('connected call ${c.callId}');
        return {'call_id': c.callId, 'video': c.videoOn, 'cameraOn': c.cameraOn,
            'cameraUnavailable': media?.cameraUnavailable};
      }
      case 'cameraOn': {
        final c = _need();
        media?.cameraBlocked = false;
        if (!c.cameraOn || (media?.cameraUnavailable ?? false)) await c.toggleCamera();
        await _until('B camera on', () => c.cameraOn ? true : null, 15);
        // calls-2emu run 44181263539: the emulated camera needs ~3 s to deliver
        // its first frame; report when B's encoder really produces frames so
        // A times the TRANSPORT (and the warm-up is a number of its own).
        final sw = Stopwatch()..start();
        var enc = 0;
        int? firstAt; // calls-quality: B's own clock at its camera's first encoded frame
        while (sw.elapsed < const Duration(seconds: 12)) {
          enc = (await c.media.stats()).videoFramesEncoded ?? 0;
          if (enc > 0) {
            firstAt = DateTime.now().millisecondsSinceEpoch;
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        _log('CALLQ camera_first_frame device_ms=$firstAt');
        _set('camera ON (first encoded frame after ${sw.elapsedMilliseconds} ms)');
        return {'cameraOn': c.cameraOn, 'cameraUnavailable': media?.cameraUnavailable,
            'framesEncoded': enc, 'firstFrameMs': enc > 0 ? sw.elapsedMilliseconds : null,
            'firstFrameAt': firstAt, // calls-quality
            // calls-camfast: the camera went out on the pre-negotiated slot
            // (no reneg_request / reneg_offer round trips)
            'replaceTrack': c.log.contains('camera-on:replace-track'),
            'renegotiated': c.log.any((e) => e.startsWith('reneg'))};
      }
      case 'cameraOff': {
        final c = _need();
        if (c.cameraOn) await c.toggleCamera();
        _set('camera OFF');
        return {'cameraOn': c.cameraOn};
      }
      case 'acceptVideo': {
        final c = _need();
        await _until('A\'s video request on B', () => c.upgrade == VideoUpgrade.incoming ? true : null, 20);
        await c.acceptVideo();
        await _until('B on video', () => c.videoOn ? true : null, 20);
        _set('accepted video');
        return {'video': c.videoOn, 'cameraOn': c.cameraOn};
      }
      case 'requestVideo': {
        final c = _need();
        await c.requestVideo();
        return {'upgrade': '${c.upgrade}'};
      }
      case 'stats': { // B's receive/send numbers + full evidence for this sample
        final c = _need();
        final s = await c.media.stats();
        final ev = await (c.media as WebRtcCallMedia).debugEvidence();
        await _req('POST', '/evidence', {'case': a['case'], 'side': 'B', 't': a['t'], 'data': ev});
        return {
          ..._statsJson(s),
          'phase': '${c.phase}',
          'video': c.videoOn,
          'cameraOn': c.cameraOn,
          'remoteCameraOn': c.remoteCameraOn,
        };
      }
      case 'waitEnded': {
        final c = call;
        if (c != null) await _until('B saw the end', () => c.isEnded ? true : null, 15);
        final why = '${c?.endReason}';
        await _reset();
        _set('idle');
        return {'endReason': why};
      }
      case 'hangup': {
        final c = _need();
        await c.hangup();
        final why = '${c.endReason}';
        await _reset();
        _set('idle');
        return {'endReason': why};
      }
      case 'reset': {
        await _reset();
        incoming.clear();
        _set('idle');
        return {'incoming': incoming.length};
      }
      case 'incomingCount': {
        return {'count': incoming.length};
      }
      // calls-quality: one quality snapshot / a measured window on B
      case 'quality': {
        final c = _need();
        return {...await (c.media as WebRtcCallMedia).debugQuality(), 'phase': '${c.phase}',
            'rung': c.netPolicy.rung, 'targetHeight': c.netPolicy.targetHeight,
            'uplinkKbps': c.netPolicy.uplinkKbps, 'ramMb': LowRamTuning.ramMb};
      }
      case 'clock': { // device clock - host clock (ms), NTP-style midpoint
        final t0 = DateTime.now().millisecondsSinceEpoch;
        final h = await _req('GET', '/clock');
        final t1 = DateTime.now().millisecondsSinceEpoch;
        return {'offset_ms': (t0 + t1) ~/ 2 - (h['host_ms'] as num).toInt(), 'rtt_ms': t1 - t0};
      }
      case 'watch': {
        final c = _need();
        final m = c.media as WebRtcCallMedia;
        final secs = (a['seconds'] as num?)?.toInt() ?? 10;
        final w = await watchQuality(m.debugQuality, Duration(seconds: secs));
        _set('watch ${a['label'] ?? ''}: ${qualityLine(w)}');
        return {...w, 'phase': '${c.phase}', 'log': c.log.skip(c.log.length > 80 ? c.log.length - 80 : 0).toList()};
      }
    }
    throw ArgumentError('unknown command $cmd');
  }
}

Future<void> _loop(Peer p) async {
  // sign-in: retried (the backend may still be warming up) — never a case retry
  for (var i = 1;; i++) {
    try {
      await p.signIn();
      break;
    } catch (e) {
      p._set('sign-in attempt $i failed: $e');
      if (i >= 10) return;
      await Future<void>.delayed(const Duration(seconds: 5));
    }
  }
  var after = 0;
  for (;;) {
    try {
      final h = await _req('POST', '/hello', {'side': 'B', 'status': p.status});
      after = (h['last_id'] as num?)?.toInt() ?? 0;
      break;
    } catch (_) {
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }
  for (;;) {
    Map<String, dynamic> c;
    try {
      c = await _req('GET', '/next?after=$after&wait=8');
    } catch (_) {
      await Future<void>.delayed(const Duration(seconds: 1));
      continue;
    }
    if (c['id'] == null) continue;
    final id = (c['id'] as num).toInt();
    after = id;
    final cmd = '${c['cmd']}';
    final args = (c['args'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    _log('#$id $cmd ${jsonEncode(args)}');
    Map<String, dynamic> body;
    try {
      final r = await p.run(cmd, args);
      body = {'id': id, 'ok': true, 'result': r};
    } catch (e) {
      body = {'id': id, 'ok': false, 'error': '$cmd: $e'};
    }
    for (var i = 0; i < 5; i++) {
      try {
        await _req('POST', '/done', body);
        break;
      } catch (_) {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // calls-quality: read this emulator's RAM (the 720p / 480p camera decision)
  try {
    await LowRamTuning.apply();
  } catch (_) {}
  final p = Peer();
  runApp(_PeerApp(p));
  unawaited(_loop(p));
}

class _PeerApp extends StatelessWidget {
  const _PeerApp(this.p);
  final Peer p;

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            child: ListenableBuilder(
              listenable: p,
              builder: (_, __) {
                final m = p.media;
                return Column(children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text('PEER B — ${p.status}',
                        style: const TextStyle(color: Colors.white, fontSize: 16)),
                  ),
                  Expanded(
                    flex: 3,
                    child: Container(
                      color: const Color(0xFF202020),
                      child: m == null ? const SizedBox.shrink() : m.remoteView(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    flex: 2,
                    child: Container(
                      color: const Color(0xFF303030),
                      child: m == null ? const SizedBox.shrink() : m.localView(),
                    ),
                  ),
                ]);
              },
            ),
          ),
        ),
      );
}
