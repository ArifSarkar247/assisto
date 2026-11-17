import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../audio/audio_route_service.dart' as ar;
import '../audio/webrtc_audio_fallback.dart';
import 'call_controller.dart' show MediaLinkState, MediaOpenException;
import 'call_log.dart';
import 'call_net_policy.dart' show CallNetPolicy, tuneOpusSdp;
import 'group_call_controller.dart';

/// group-calls: [GroupMedia] on flutter_webrtc — ONE microphone (+ camera)
/// stream sent on one peer connection per person (mesh). Loaded with
/// `deferred as` from the group call screen, like webrtc_media.dart, so no
/// WebRTC code runs at app launch.
///
/// Audio routing is owned by the app-wide [ar.AudioRouteService] (beginCall
/// / select / endCall) — never the plugin's own helpers (CI guard
/// test/audio_route_guard_test.dart). Opus FEC/DTX at 32 kbps per leg; video
/// capped per leg (240p ~150 kbps, 120p ~80 kbps from 5 people).
class _Peer {
  _Peer(this.pc);
  final RTCPeerConnection pc;
  RTCRtpSender? audio;
  RTCRtpSender? video;
  bool recvVideoAdded = false;
  RTCVideoRenderer? renderer;
  bool hasVideo = false;
}

class GroupMeshMedia implements GroupMedia, GroupVideoSurface {
  final Map<int, _Peer> _peers = {};
  final _cands = StreamController<LegCandidate>.broadcast();
  final _links = StreamController<LegLink>.broadcast();
  MediaStream? _local;
  MediaStreamTrack? _videoTrack;
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  bool _localReady = false;
  bool _video = false;
  int _videoKbps = 150;

  final ValueNotifier<int> _videoChanged = ValueNotifier<int>(0);

  @override
  Listenable get videoChanged => _videoChanged;

  ar.AudioRouteService get _audio => ar.AudioRouteService.instance;

  @override
  bool cameraUnavailable = false;

  static const Map<String, dynamic> _audioConstraints = {
    'echoCancellation': true,
    'noiseSuppression': true,
    'autoGainControl': true,
  };

  // 320x240 @ 15 fps: the mesh sends one copy per person
  static const Map<String, dynamic> _videoConstraints = {
    'facingMode': 'user',
    'width': {'ideal': 320},
    'height': {'ideal': 240},
    'frameRate': {'ideal': 15},
  };

  @override
  Future<void> open({required bool video}) async {
    _video = video;
    try {
      installWebrtcAudioFallback(_audio);
      await _audio.beginCall(video: video);
      if (!_audio.nativeOwner) await prepareWebrtcAudioFallback();
    } catch (e) {
      callLog('group_mesh#1', e);
    }
    try {
      _local = await navigator.mediaDevices.getUserMedia({
        'audio': _audioConstraints,
        'video': video ? _videoConstraints : false,
      });
    } catch (e) {
      if (!video) throw _openError(e);
      callLog('group_mesh#2', e);
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
    if (_videoTrack != null) {
      try {
        await _localRenderer.initialize();
        _localReady = true;
        _localRenderer.srcObject = _local;
      } catch (e) {
        callLog('group_mesh#3', e);
      }
    }
  }

  static MediaOpenException _openError(Object e) {
    final s = '$e'.toLowerCase();
    return MediaOpenException(
        s.contains('permission') || s.contains('denied') ||
            s.contains('notallowed'),
        '$e');
  }

  @override
  Future<void> addPeer(int legId, List<Map<String, dynamic>> iceServers,
      {required bool video}) async {
    final pc = await createPeerConnection({
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
      'bundlePolicy': 'max-bundle',
      'iceCandidatePoolSize': 0,
    });
    final p = _Peer(pc);
    _peers[legId] = p;
    final local = _local;
    if (local != null) {
      for (final t in local.getTracks()) {
        final s = await pc.addTrack(t, local);
        if (t.kind == 'video') p.video = s;
        if (t.kind == 'audio') p.audio = s;
      }
    }
    pc.onIceCandidate = (RTCIceCandidate c) {
      if (c.candidate == null || c.candidate!.isEmpty) return;
      _cands.add(LegCandidate(legId, {
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      }));
    };
    pc.onIceConnectionState = (RTCIceConnectionState s) {
      final st = switch (s) {
        RTCIceConnectionState.RTCIceConnectionStateConnected ||
        RTCIceConnectionState.RTCIceConnectionStateCompleted =>
          MediaLinkState.connected,
        RTCIceConnectionState.RTCIceConnectionStateDisconnected =>
          MediaLinkState.disconnected,
        RTCIceConnectionState.RTCIceConnectionStateFailed =>
          MediaLinkState.failed,
        RTCIceConnectionState.RTCIceConnectionStateChecking =>
          MediaLinkState.connecting,
        RTCIceConnectionState.RTCIceConnectionStateClosed =>
          MediaLinkState.closed,
        _ => null,
      };
      if (st != null && _peers[legId] == p) _links.add(LegLink(legId, st));
    };
    pc.onTrack = (RTCTrackEvent e) {
      if (e.track.kind != 'video' || e.streams.isEmpty) return;
      unawaited(_showRemote(p, e.streams.first, e.track.id));
    };
    await _capVideo(p);
  }

  Future<void> _showRemote(_Peer p, MediaStream s, String? trackId) async {
    try {
      final r = p.renderer ??= RTCVideoRenderer();
      if (r.textureId == null) await r.initialize();
      await r.setSrcObject(stream: s, trackId: trackId);
      p.hasVideo = true;
      _videoChanged.value++;
    } catch (e) {
      callLog('group_mesh#4', e);
    }
  }

  _Peer _peer(int legId) {
    final p = _peers[legId];
    if (p == null) throw StateError('no peer for leg $legId');
    return p;
  }

  RTCSessionDescription _tuned(RTCSessionDescription d) {
    final sdp = d.sdp;
    if (sdp == null) return d;
    return RTCSessionDescription(
        tuneOpusSdp(sdp, maxAverageBitrate: CallNetPolicy.audioNormal),
        d.type);
  }

  @override
  Future<Map<String, dynamic>> createOffer(int legId) async {
    final p = _peer(legId);
    if (legOfferNeedsRecvOnlyVideo(
        videoCall: _video,
        hasLocalVideo: p.video != null,
        alreadyAdded: p.recvVideoAdded)) {
      try {
        await p.pc.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
          init: RTCRtpTransceiverInit(
              direction: TransceiverDirection.RecvOnly),
        );
        p.recvVideoAdded = true;
      } catch (e) {
        callLog('group_mesh#5', e);
      }
    }
    final offer = await p.pc.createOffer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': _video,
    });
    final tuned = _tuned(offer);
    await p.pc.setLocalDescription(tuned);
    return {'type': tuned.type, 'sdp': tuned.sdp};
  }

  @override
  Future<Map<String, dynamic>> acceptOffer(
      int legId, Map<String, dynamic> offer) async {
    final p = _peer(legId);
    await p.pc.setRemoteDescription(RTCSessionDescription(
        offer['sdp'] as String?, offer['type'] as String?));
    final ans = _tuned(await p.pc.createAnswer({}));
    await p.pc.setLocalDescription(ans);
    return {'type': ans.type, 'sdp': ans.sdp};
  }

  @override
  Future<void> setAnswer(int legId, Map<String, dynamic> answer) =>
      _peer(legId).pc.setRemoteDescription(RTCSessionDescription(
          answer['sdp'] as String?, answer['type'] as String?));

  @override
  Future<void> addCandidate(int legId, Map<String, dynamic> c) =>
      _peer(legId).pc.addCandidate(RTCIceCandidate(
          c['candidate'] as String?,
          c['sdpMid'] as String?,
          (c['sdpMLineIndex'] as num?)?.toInt()));

  @override
  Future<void> closePeer(int legId) async {
    final p = _peers.remove(legId);
    if (p == null) return;
    try {
      await p.pc.close();
    } catch (e) {
      callLog('group_mesh#6', e);
    }
    try {
      final r = p.renderer;
      if (r != null) {
        r.srcObject = null;
        await r.dispose();
      }
    } catch (e) {
      callLog('group_mesh#7', e);
    }
    _videoChanged.value++;
  }

  @override
  Stream<LegCandidate> get localCandidates => _cands.stream;

  @override
  Stream<LegLink> get linkStates => _links.stream;

  @override
  Future<LegStats> stats(int legId) async {
    final reports = await _peer(legId).pc.getStats();
    int? pkts, bytes, frames, sent, got;
    double? level;
    for (final r in reports) {
      final v = r.values;
      if (r.type == 'inbound-rtp') {
        final kind = v['kind'] ?? v['mediaType'];
        if (kind == 'audio') {
          final pr = v['packetsReceived'], br = v['bytesReceived'];
          if (pr is num) pkts = (pkts ?? 0) + pr.toInt();
          if (br is num) bytes = (bytes ?? 0) + br.toInt();
          final al = v['audioLevel'];
          if (al is num) level = al.toDouble();
        } else if (kind == 'video') {
          final fd = v['framesDecoded'];
          if (fd is num) frames = (frames ?? 0) + fd.toInt();
        }
      } else if (r.type == 'transport') {
        final bs = v['bytesSent'], br = v['bytesReceived'];
        if (bs is num) sent = bs.toInt();
        if (br is num) got = br.toInt();
      }
    }
    return LegStats(
        audioPacketsIn: pkts,
        audioBytesIn: bytes,
        videoFramesDecoded: frames,
        audioLevel: level,
        bytesSent: sent,
        bytesReceived: got);
  }

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

  @override
  Future<void> setSpeaker(bool on) {
    if (on) return _audio.select(ar.AudioRoute.speaker);
    final a = _audio;
    final back = a.has(ar.AudioRoute.bluetooth)
        ? ar.AudioRoute.bluetooth
        : a.has(ar.AudioRoute.wired)
            ? ar.AudioRoute.wired
            : ar.AudioRoute.earpiece;
    return a.select(back);
  }

  @override
  Future<void> setVideoKbps(int kbps) async {
    _videoKbps = kbps;
    for (final p in _peers.values) {
      await _capVideo(p);
    }
  }

  Future<void> _capVideo(_Peer p) async {
    final v = p.video;
    if (v == null) return;
    try {
      await v.setParameters(RTCRtpParameters(
          degradationPreference: RTCDegradationPreference.BALANCED,
          encodings: [
            RTCRtpEncoding(
                active: true,
                maxBitrate: _videoKbps * 1000,
                maxFramerate: 15,
                // 320x240 capture: /2 = 160x120 when many people share it
                scaleResolutionDownBy: _videoKbps <= 80 ? 2.0 : 1.0)
          ]));
    } catch (e) {
      callLog('group_mesh#8', e);
    }
  }

  @override
  Widget localView() => _localReady
      ? RTCVideoView(_localRenderer,
          mirror: true,
          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
      : const SizedBox.shrink();

  @override
  Widget? remoteView(int legId) {
    final p = _peers[legId];
    final r = p?.renderer;
    if (p == null || r == null || !p.hasVideo) return null;
    return RTCVideoView(r,
        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover);
  }

  @override
  bool hasRemoteVideo(int legId) => _peers[legId]?.hasVideo ?? false;

  @override
  Future<void> dispose() async {
    for (final id in _peers.keys.toList()) {
      await closePeer(id);
    }
    try {
      for (final t in _local?.getTracks() ?? const <MediaStreamTrack>[]) {
        await t.stop();
      }
      await _local?.dispose();
    } catch (e) {
      callLog('group_mesh#9', e);
    }
    _local = null;
    _videoTrack = null;
    try {
      if (_localReady) {
        _localRenderer.srcObject = null;
        await _localRenderer.dispose();
      }
    } catch (e) {
      callLog('group_mesh#10', e);
    }
    _localReady = false;
    try {
      await _audio.endCall();
    } catch (e) {
      callLog('group_mesh#11', e);
    }
  }
}

/// Factory used through the deferred import.
GroupMedia createGroupMeshMedia() => GroupMeshMedia();
