import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../audio/audio_route_service.dart' as ar;
import '../audio/webrtc_audio_fallback.dart';
import 'call_controller.dart';
import 'call_net_policy.dart';
import 'call_video.dart';
import 'call_log.dart';

/// [CallMedia] on flutter_webrtc — the ONLY call file that touches the
/// plugin. Loaded with `deferred as` from the call screen, so no WebRTC code
/// (and no native PeerConnectionFactory) is touched at app launch.
///
/// Audio (audioroute, owner 28 Oct): routing is owned by the ONE app-wide
/// [ar.AudioRouteService] — communication mode, headset > earpiece (voice) /
/// headset > speaker (video), live switch on connect / disconnect, restore on
/// every end. This file never calls the plugin's routing helpers (CI guard
/// test/audio_route_guard_test.dart).
///
/// callsbar: [AdaptiveCallMedia] — Opus FEC/DTX + bitrate caps in every local
/// SDP, sender caps (audio / video bitrate, fps, scale, video on/off on the
/// wire for the audio-only fallback) and TURN-relay-only ICE on demand.
class WebRtcCallMedia
    implements CallMedia, CallVideoSurface, AdaptiveCallMedia {
  RTCPeerConnection? _pc;
  RTCRtpSender? _audioSender;
  MediaPlan? _plan;
  List<Map<String, dynamic>> _iceServers = const [];
  MediaStream? _local;
  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  bool _renderersReady = false;
  final _cands = StreamController<Map<String, dynamic>>.broadcast();
  final _link = StreamController<MediaLinkState>.broadcast();
  @override
  final ValueNotifier<bool> hasRemoteVideo = ValueNotifier<bool>(false);
  int _lastLost = 0, _lastRecv = 0;

  @override
  Stream<Map<String, dynamic>> get localCandidates => _cands.stream;
  @override
  Stream<MediaLinkState> get linkState => _link.stream;

  ar.AudioRouteService get _audio => ar.AudioRouteService.instance;

  @override
  Future<void> open({required bool video}) async {
    // BEFORE getUserMedia: the mic must come from the headset too, and the
    // plugin's own audio switch must be off before it would start.
    try {
      installWebrtcAudioFallback(_audio);
      await _audio.beginCall(video: video);
      if (!_audio.nativeOwner) await prepareWebrtcAudioFallback();
    } catch (e) {
      callLog('webrtc_media#1', e);
    }
    try {
      await localRenderer.initialize();
      await remoteRenderer.initialize();
      _renderersReady = true;
    } catch (e) {
      callLog('webrtc_media#2', e);
    }
    try {
      _local = await navigator.mediaDevices.getUserMedia({
        'audio': _audioConstraints,
        'video': video ? _videoConstraints : false,
      });
    } catch (e) {
      if (!video) throw _openError(e);
      // b1-calls (reality run 39946885424): the camera can fail on its own
      // ("Failed to create new track" — busy, OEM HAL, emulator) while the
      // mic works. Join with the camera OFF instead of failing the call.
      callLog('webrtc_media#7', e);
      try {
        _local = await navigator.mediaDevices
            .getUserMedia({'audio': _audioConstraints, 'video': false});
        cameraUnavailable = true;
      } catch (e2) {
        throw _openError(e2);
      }
    }
    final v = _local?.getVideoTracks() ?? const <MediaStreamTrack>[];
    _videoTrack = v.isEmpty ? null : v.first;
    if (_videoTrack != null && _renderersReady) {
      localRenderer.srcObject = _local;
    }
  }

  static const Map<String, dynamic> _audioConstraints = {
    'echoCancellation': true,
    'noiseSuppression': true,
    'autoGainControl': true,
  };

  static const Map<String, dynamic> _videoConstraints = {
    'facingMode': 'user',
    'width': {'ideal': 640},
    'height': {'ideal': 480},
    'frameRate': {'ideal': 24},
  };

  static MediaOpenException _openError(Object e) {
    final s = '$e'.toLowerCase();
    return MediaOpenException(
        s.contains('permission') ||
            s.contains('notallowed') ||
            s.contains('denied'),
        '$e');
  }

  /// b1: the camera track in use (from [open] or [startVideo]) + its sender.
  MediaStreamTrack? _videoTrack;
  MediaStream? _cam;
  RTCRtpSender? _videoSender;

  @override
  bool cameraUnavailable = false;

  @override
  Future<void> startVideo() async {
    final pc = _peer;
    MediaStream cam;
    try {
      cam = await navigator.mediaDevices
          .getUserMedia({'audio': false, 'video': _videoConstraints});
    } catch (e) {
      throw _openError(e);
    }
    final tracks = cam.getVideoTracks();
    if (tracks.isEmpty) {
      await cam.dispose();
      throw MediaOpenException(false, 'no camera track');
    }
    // drop a previous camera (never two cameras open)
    await _releaseCamera();
    _cam = cam;
    final track = tracks.first;
    _videoTrack = track;
    final sender = _videoSender;
    if (sender != null) {
      // used before (video -> voice -> video): same m-line, same stream id
      await sender.replaceTrack(track);
    } else {
      // first time: reuses the receive-only video transceiver of the voice
      // offer and tags the track with the AUDIO stream id, so the other
      // phone's onTrack gets one stream with both (its renderer shows it).
      final local = _local;
      _videoSender = local != null
          ? await pc.addTrack(track, local)
          : await pc.addTrack(track, cam);
    }
    cameraUnavailable = false;
    if (_renderersReady) localRenderer.srcObject = cam;
    final plan = _plan;
    if (plan != null) await _capVideo(plan);
  }

  @override
  Future<void> stopVideo() async {
    try {
      await _videoSender?.replaceTrack(null);
    } catch (e) {
      callLog('webrtc_media#8', e);
    }
    await _releaseCamera();
    try {
      if (_renderersReady) localRenderer.srcObject = null;
    } catch (e) {
      callLog('webrtc_media#9', e);
    }
  }

  Future<void> _releaseCamera() async {
    final t = _videoTrack;
    _videoTrack = null;
    try {
      await t?.stop();
    } catch (e) {
      callLog('webrtc_media#10', e);
    }
    final cam = _cam;
    _cam = null;
    try {
      await cam?.dispose();
    } catch (e) {
      callLog('webrtc_media#11', e);
    }
  }

  @override
  Future<List<AudioRoute>> audioRoutes() async {
    final out = <AudioRoute>[];
    for (final o in _audio.outputs) {
      if (!out.contains(o.route)) out.add(o.route);
    }
    out.sort((a, b) => a.index.compareTo(b.index));
    return out;
  }

  @override
  Future<void> setAudioRoute(AudioRoute r) => _audio.select(r);

  @override
  Stream<AudioRoute> get routeChanges => _audio.routeChanges;

  @override
  Future<void> setVideoMode(bool on) => _audio.setVideo(on);

  @override
  Future<void> createPeer(List<Map<String, dynamic>> iceServers) async {
    _iceServers = iceServers;
    final pc = await createPeerConnection({
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
      'bundlePolicy': 'max-bundle',
      // x1-calls: no pre-gathered pool — each pooled candidate set holds an
      // extra TURN allocation (coturn user-quota); gathering starts with
      // setLocalDescription, which is early enough (the offer is pre-sent
      // while it rings).
      'iceCandidatePoolSize': 0,
    });
    _pc = pc;
    final local = _local;
    if (local != null) {
      for (final t in local.getTracks()) {
        final s = await pc.addTrack(t, local);
        if (t.kind == 'video') _videoSender = s;
        if (t.kind == 'audio') _audioSender = s;
      }
    }
    pc.onIceCandidate = (RTCIceCandidate c) {
      if (c.candidate == null || c.candidate!.isEmpty) return;
      _cands.add({
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      });
    };
    pc.onIceConnectionState = (RTCIceConnectionState s) {
      switch (s) {
        case RTCIceConnectionState.RTCIceConnectionStateConnected:
        case RTCIceConnectionState.RTCIceConnectionStateCompleted:
          _link.add(MediaLinkState.connected);
          break;
        case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
          _link.add(MediaLinkState.disconnected);
          break;
        case RTCIceConnectionState.RTCIceConnectionStateFailed:
          _link.add(MediaLinkState.failed);
          break;
        case RTCIceConnectionState.RTCIceConnectionStateChecking:
          _link.add(MediaLinkState.connecting);
          break;
        case RTCIceConnectionState.RTCIceConnectionStateClosed:
          _link.add(MediaLinkState.closed);
          break;
        default:
          break;
      }
    };
    pc.onTrack = (RTCTrackEvent e) {
      if (e.streams.isEmpty) return;
      final s = e.streams.first;
      if (e.track.kind == 'video') {
        // b1: a video track added mid-call (voice -> video) joins the SAME
        // remote stream as the audio: point the renderer at that track.
        if (_renderersReady) {
          unawaited(remoteRenderer
              .setSrcObject(stream: s, trackId: e.track.id)
              .catchError((Object err) => callLog('webrtc_media#12', err)));
        }
        hasRemoteVideo.value = true;
      } else if (_renderersReady && !hasRemoteVideo.value) {
        remoteRenderer.srcObject = s;
      }
    };
  }

  RTCPeerConnection get _peer {
    final p = _pc;
    if (p == null) throw StateError('no peer connection');
    return p;
  }

  @override
  Future<Map<String, dynamic>> createOffer({bool iceRestart = false}) async {
    final offer = await _peer.createOffer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': true,
      if (iceRestart) 'iceRestart': true,
    });
    final tuned = _tuned(offer);
    await _peer.setLocalDescription(tuned);
    return {'type': tuned.type, 'sdp': tuned.sdp};
  }

  /// callsbar: Opus FEC + DTX + the bitrate we want to RECEIVE. Never fails
  /// a call: an SDP the tuner can't read is used as it is.
  RTCSessionDescription _tuned(RTCSessionDescription d) {
    final sdp = d.sdp;
    if (sdp == null) return d;
    final cap = _plan?.opusMaxAverage ?? CallNetPolicy.audioNormal;
    return RTCSessionDescription(
        tuneOpusSdp(sdp, maxAverageBitrate: cap), d.type);
  }

  @override
  Future<void> applyPlan(MediaPlan plan) async {
    _plan = plan;
    final a = _audioSender;
    if (a != null) {
      try {
        await a.setParameters(RTCRtpParameters(encodings: [
          RTCRtpEncoding(
              active: true,
              maxBitrate: plan.audioMaxBps,
              // voice first when the uplink is tight (video yields)
              priority: RTCPriorityType.high,
              networkPriority: RTCPriorityType.high)
        ]));
      } catch (e) {
        callLog('webrtc_media#13', e);
      }
    }
    await _capVideo(plan);
  }

  Future<void> _capVideo(MediaPlan plan) async {
    final v = _videoSender;
    if (v == null || _videoTrack == null) return;
    try {
      await v.setParameters(RTCRtpParameters(
          degradationPreference: RTCDegradationPreference.BALANCED,
          encodings: [
            RTCRtpEncoding(
                active: plan.videoActive,
                maxBitrate: plan.videoMaxBps,
                maxFramerate: plan.videoMaxFps,
                scaleResolutionDownBy: plan.videoScaleDown)
          ]));
    } catch (e) {
      callLog('webrtc_media#14', e);
    }
  }

  @override
  Future<bool> forceRelay() async {
    final pc = _pc;
    final hasTurn = _iceServers.any((s) {
      final u = s['urls'];
      final list = u is List ? u : [u];
      return list.any((x) => '$x'.startsWith('turn'));
    });
    if (pc == null || !hasTurn) return false;
    try {
      await pc.setConfiguration({
        'iceServers': _iceServers,
        'iceTransportPolicy': 'relay',
      });
      return true;
    } catch (e) {
      callLog('webrtc_media#15', e);
      return false;
    }
  }

  @override
  Future<Map<String, dynamic>> acceptOffer(Map<String, dynamic> offer) async {
    await _peer.setRemoteDescription(RTCSessionDescription(
        offer['sdp'] as String?, offer['type'] as String?));
    final ans = _tuned(await _peer.createAnswer({}));
    await _peer.setLocalDescription(ans);
    return {'type': ans.type, 'sdp': ans.sdp};
  }

  @override
  Future<void> setAnswer(Map<String, dynamic> answer) =>
      _peer.setRemoteDescription(RTCSessionDescription(
          answer['sdp'] as String?, answer['type'] as String?));

  @override
  Future<void> addCandidate(Map<String, dynamic> c) =>
      _peer.addCandidate(RTCIceCandidate(c['candidate'] as String?,
          c['sdpMid'] as String?, (c['sdpMLineIndex'] as num?)?.toInt()));

  @override
  Future<void> setMuted(bool muted) async {
    for (final t in _local?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = !muted;
    }
  }

  @override
  Future<void> setCameraEnabled(bool on) async {
    final t = _videoTrack;
    if (t != null) t.enabled = on;
  }

  @override
  Future<void> switchCamera() async {
    final t = _videoTrack;
    if (t != null) await Helper.switchCamera(t);
  }

  /// Speaker toggle: ON = loudspeaker; OFF = the headset when one is
  /// connected (Bluetooth first), else the earpiece.
  @override
  Future<void> setSpeaker(bool on) {
    if (on) return _audio.select(AudioRoute.speaker);
    final a = _audio;
    final back = a.has(AudioRoute.bluetooth)
        ? AudioRoute.bluetooth
        : a.has(AudioRoute.wired)
            ? AudioRoute.wired
            : AudioRoute.earpiece;
    return a.select(back);
  }

  @override
  Future<MediaStats> stats() async {
    final reports = await _peer.getStats();
    final byId = <String, Map<dynamic, dynamic>>{};
    for (final r in reports) {
      byId[r.id] = r.values;
    }
    double? rtt, jitter, avail;
    var relayed = false;
    var lost = 0, recv = 0;
    int? sent, got;
    // x1-calls: the standard way to find the pair in use is
    // transport.selectedCandidatePairId (Android libwebrtc has no
    // `selected` flag on candidate-pair) — so `relayed` is reported right.
    final selectedIds = <String>{
      for (final r in reports)
        if (r.type == 'transport' && r.values['selectedCandidatePairId'] != null)
          '${r.values['selectedCandidatePairId']}'
    };
    for (final r in reports) {
      final v = r.values;
      if (r.type == 'candidate-pair') {
        final selected = selectedIds.isNotEmpty
            ? selectedIds.contains(r.id)
            : (v['selected'] == true ||
                (v['nominated'] == true && v['state'] == 'succeeded'));
        if (!selected) continue;
        final cr = v['currentRoundTripTime'];
        if (cr is num) rtt = cr * 1000;
        final ab = v['availableOutgoingBitrate'];
        if (ab is num && ab > 0) avail = ab / 1000;
        final l = byId['${v['localCandidateId']}'];
        final rm = byId['${v['remoteCandidateId']}'];
        if (l?['candidateType'] == 'relay' || rm?['candidateType'] == 'relay') {
          relayed = true;
        }
        // callsbar: data used (this pair; the transport below wins)
        final bs = v['bytesSent'], br = v['bytesReceived'];
        if (sent == null && bs is num) sent = bs.toInt();
        if (got == null && br is num) got = br.toInt();
      } else if (r.type == 'transport') {
        final bs = r.values['bytesSent'], br = r.values['bytesReceived'];
        if (bs is num) sent = bs.toInt();
        if (br is num) got = br.toInt();
      } else if (r.type == 'inbound-rtp') {
        final pl = v['packetsLost'];
        final pr = v['packetsReceived'];
        if (pl is num) lost += pl.toInt();
        if (pr is num) recv += pr.toInt();
        // jitter (seconds) of the AUDIO stream — what people hear
        final j = v['jitter'];
        final kind = v['kind'] ?? v['mediaType'];
        if (j is num && (kind == null || kind == 'audio')) {
          final ms = j * 1000.0;
          jitter = jitter == null ? ms : (ms > jitter ? ms : jitter);
        }
      }
    }
    final dl = lost - _lastLost, dr = recv - _lastRecv;
    _lastLost = lost;
    _lastRecv = recv;
    double? loss;
    if (dl + dr > 0) loss = 100.0 * dl.clamp(0, 1 << 30) / (dl + dr);
    return MediaStats(
        rttMs: rtt,
        lossPct: loss,
        jitterMs: jitter,
        availableKbps: avail,
        relayed: relayed,
        bytesSent: sent,
        bytesReceived: got);
  }

  @override
  Widget localView({bool mirror = true}) => _renderersReady
      ? RTCVideoView(localRenderer,
          mirror: mirror,
          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
      : const SizedBox.shrink();

  @override
  Widget remoteView() => _renderersReady
      ? RTCVideoView(remoteRenderer,
          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
      : const SizedBox.shrink();

  @override
  Future<void> dispose() async {
    await _releaseCamera();
    _videoSender = null;
    _audioSender = null;
    try {
      for (final t in _local?.getTracks() ?? const <MediaStreamTrack>[]) {
        await t.stop();
      }
      await _local?.dispose();
    } catch (e) {
      callLog('webrtc_media#3', e);
    }
    _local = null;
    try {
      await _pc?.close();
    } catch (e) {
      callLog('webrtc_media#4', e);
    }
    _pc = null;
    try {
      localRenderer.srcObject = null;
      remoteRenderer.srcObject = null;
      if (_renderersReady) {
        await localRenderer.dispose();
        await remoteRenderer.dispose();
      }
    } catch (e) {
      callLog('webrtc_media#5', e);
    }
    _renderersReady = false;
    // every call-end path (hang-up, remote end, failure, timeout, setup
    // aborted) ends here: back to normal audio, music never stuck.
    try {
      await _audio.endCall();
    } catch (e) {
      callLog('webrtc_media#6', e);
    }
  }
}

/// Factory used through the deferred import.
CallMedia createWebRtcCallMedia() => WebRtcCallMedia();
