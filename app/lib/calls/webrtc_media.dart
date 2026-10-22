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
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'video': video
            ? {
                'facingMode': 'user',
                'width': {'ideal': 640},
                'height': {'ideal': 480},
                'frameRate': {'ideal': 24},
              }
            : false,
      });
    } catch (e) {
      final s = '$e'.toLowerCase();
      throw MediaOpenException(
          s.contains('permission') ||
              s.contains('notallowed') ||
              s.contains('denied'),
          '$e');
    }
    if (video && _renderersReady) localRenderer.srcObject = _local;
  }

  @override
  Future<void> createPeer(List<Map<String, dynamic>> iceServers) async {
    final pc = await createPeerConnection({
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
      'bundlePolicy': 'max-bundle',
      'iceCandidatePoolSize': 2,
    });
    _pc = pc;
    final local = _local;
    if (local != null) {
      for (final t in local.getTracks()) {
        await pc.addTrack(t, local);
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
      if (_renderersReady) remoteRenderer.srcObject = e.streams.first;
      if (e.track.kind == 'video') hasRemoteVideo.value = true;
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
    for (final t in _local?.getVideoTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = on;
    }
  }

  @override
  Future<void> switchCamera() async {
    final v = _local?.getVideoTracks() ?? const <MediaStreamTrack>[];
    if (v.isNotEmpty) await Helper.switchCamera(v.first);
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
    double? rtt;
    var relayed = false;
    var lost = 0, recv = 0;
    for (final r in reports) {
      final v = r.values;
      if (r.type == 'candidate-pair') {
        final selected = v['selected'] == true ||
            (v['nominated'] == true && v['state'] == 'succeeded');
        if (!selected) continue;
        final cr = v['currentRoundTripTime'];
        if (cr is num) rtt = cr * 1000;
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
      }
    }
    final dl = lost - _lastLost, dr = recv - _lastRecv;
    _lastLost = lost;
    _lastRecv = recv;
    double? loss;
    if (dl + dr > 0) loss = 100.0 * dl.clamp(0, 1 << 30) / (dl + dr);
    return MediaStats(rttMs: rtt, lossPct: loss, relayed: relayed);
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
