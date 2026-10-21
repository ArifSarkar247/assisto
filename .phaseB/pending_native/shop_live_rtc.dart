import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// The ONLY file that touches flutter_webrtc. Screens import it with
/// `deferred as` and call `loadLibrary()` right before a live session, so no
/// WebRTC code (and no native PeerConnectionFactory) is touched at app launch.
///
/// Media flows peer-to-peer (or through TURN when P2P is impossible); our
/// server only relays the SDP/ICE text. NOTHING is recorded on either side.
///
/// Everything here is crash-guarded by the callers (try/catch around every
/// call) — a WebRTC failure ends the session with an honest message, never the
/// app.
class LivePeer {
  final RTCPeerConnection _pc;
  final RTCVideoRenderer? _renderer; // owner (viewer) side
  MediaStream? _local; // device (sender) side
  final bool sender;

  LivePeer._(this._pc, this._renderer, this.sender);

  /// [ice] = the server's `ice_servers` list (STUN, plus TURN only when the
  /// owner can pay for relayed minutes).
  static Future<LivePeer> create(
    List<Map<String, dynamic>> ice, {
    required bool sender,
    required void Function(Map<String, dynamic> candidate) onCandidate,
    void Function()? onRemoteVideo,
    void Function(String state)? onState,
  }) async {
    final pc = await createPeerConnection({
      'iceServers': ice,
      'sdpSemantics': 'unified-plan',
    });
    RTCVideoRenderer? renderer;
    if (!sender) {
      renderer = RTCVideoRenderer();
      await renderer.initialize();
    }
    final peer = LivePeer._(pc, renderer, sender);
    pc.onIceCandidate = (RTCIceCandidate c) {
      if (c.candidate == null) return;
      onCandidate({
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      });
    };
    pc.onConnectionState = (RTCPeerConnectionState s) {
      onState?.call(s.name);
    };
    pc.onTrack = (RTCTrackEvent e) {
      if (renderer != null && e.streams.isNotEmpty) {
        renderer.srcObject = e.streams.first;
        onRemoteVideo?.call();
      }
    };
    return peer;
  }

  /// Owner: a receive-only video offer (we never send the owner's camera/mic).
  Future<Map<String, dynamic>> createOffer() async {
    await _pc.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
    );
    final offer = await _pc.createOffer({});
    await _pc.setLocalDescription(offer);
    return {'type': offer.type, 'sdp': offer.sdp};
  }

  /// Device: open the back camera (video only, modest size) and answer.
  Future<Map<String, dynamic>> answer(Map<String, dynamic> offer) async {
    await _pc.setRemoteDescription(
        RTCSessionDescription(offer['sdp'] as String?, offer['type'] as String?));
    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': false,
      'video': {
        'facingMode': 'environment',
        'width': 640,
        'height': 480,
        'frameRate': 15,
      },
    });
    _local = stream;
    for (final t in stream.getVideoTracks()) {
      await _pc.addTrack(t, stream);
    }
    final ans = await _pc.createAnswer({});
    await _pc.setLocalDescription(ans);
    return {'type': ans.type, 'sdp': ans.sdp};
  }

  Future<void> setRemote(Map<String, dynamic> sdp) => _pc.setRemoteDescription(
      RTCSessionDescription(sdp['sdp'] as String?, sdp['type'] as String?));

  Future<void> addCandidate(Map<String, dynamic> c) => _pc.addCandidate(RTCIceCandidate(
      c['candidate'] as String?,
      c['sdpMid'] as String?,
      (c['sdpMLineIndex'] as num?)?.toInt()));

  /// True when the SELECTED candidate pair goes through our TURN relay (that is
  /// the only case that costs credits). Unknown -> false is never assumed by
  /// the caller once it has seen `true` (it latches).
  Future<bool> isRelayed() async {
    final reports = await _pc.getStats();
    final byId = <String, Map<dynamic, dynamic>>{};
    for (final r in reports) {
      byId[r.id] = r.values;
    }
    for (final r in reports) {
      if (r.type != 'candidate-pair') continue;
      final v = r.values;
      final selected = v['selected'] == true ||
          (v['nominated'] == true && v['state'] == 'succeeded');
      if (!selected) continue;
      final local = byId[v['localCandidateId']?.toString() ?? ''];
      final remote = byId[v['remoteCandidateId']?.toString() ?? ''];
      if (local?['candidateType'] == 'relay' || remote?['candidateType'] == 'relay') {
        return true;
      }
    }
    return false;
  }

  /// The remote video (owner side). Contain-fit so nothing is cropped.
  Widget view() {
    final r = _renderer;
    if (r == null) return const SizedBox.shrink();
    return RTCVideoView(r, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain);
  }

  Future<void> dispose() async {
    try {
      for (final t in _local?.getTracks() ?? const <MediaStreamTrack>[]) {
        await t.stop();
      }
      await _local?.dispose();
    } catch (_) {}
    try {
      _renderer?.srcObject = null;
      await _renderer?.dispose();
    } catch (_) {}
    try {
      await _pc.close();
    } catch (_) {}
  }
}
