import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'call_controller.dart';
import 'call_video.dart';
import 'call_log.dart';

/// [CallMedia] on flutter_webrtc — the ONLY call file that touches the
/// plugin. Loaded with `deferred as` from the call screen, so no WebRTC code
/// (and no native PeerConnectionFactory) is touched at app launch.
///
/// Audio: Android "communication" mode (echo cancellation, earpiece by
/// default, Bluetooth headsets routed by the plugin's audio switch). Speaker
/// ON prefers a connected Bluetooth headset (WhatsApp behaviour).
class WebRtcCallMedia implements CallMedia, CallVideoSurface {
  RTCPeerConnection? _pc;
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

  @override
  Future<void> open({required bool video}) async {
    try {
      await Helper.setAndroidAudioConfiguration(
          AndroidAudioConfiguration.communication);
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
    for (final d in await Helper.audiooutputs) {
      final r = audioRouteFromId(d.deviceId);
      if (r != null && !out.contains(r)) out.add(r);
    }
    out.sort((a, b) => a.index.compareTo(b.index));
    return out;
  }

  @override
  Future<void> setAudioRoute(AudioRoute r) async {
    if (r == AudioRoute.speaker) {
      await Helper.setSpeakerphoneOn(true);
    } else if (r == AudioRoute.earpiece) {
      await Helper.setSpeakerphoneOn(false);
    }
    await Helper.selectAudioOutput(audioRouteId(r));
  }

  @override
  Future<void> createPeer(List<Map<String, dynamic>> iceServers) async {
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
    await _peer.setLocalDescription(offer);
    return {'type': offer.type, 'sdp': offer.sdp};
  }

  @override
  Future<Map<String, dynamic>> acceptOffer(Map<String, dynamic> offer) async {
    await _peer.setRemoteDescription(RTCSessionDescription(
        offer['sdp'] as String?, offer['type'] as String?));
    final ans = await _peer.createAnswer({});
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

  @override
  Future<void> setSpeaker(bool on) async {
    if (on) {
      await Helper.setSpeakerphoneOnButPreferBluetooth();
    } else {
      await Helper.setSpeakerphoneOn(false);
    }
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
        relayed: relayed);
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
    try {
      await Helper.clearAndroidCommunicationDevice();
    } catch (e) {
      callLog('webrtc_media#6', e);
    }
  }
}

/// Factory used through the deferred import.
CallMedia createWebRtcCallMedia() => WebRtcCallMedia();
