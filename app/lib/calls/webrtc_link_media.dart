part of 'webrtc_media.dart';

/// callsB: ONE pair link of a group call (its own RTCPeerConnection) that
/// sends the host's mic + camera (or shared screen) — every link of the
/// mesh shares the same local tracks, so the camera / mic open only once.
/// Driven by its own [CallController] exactly like a 1:1 call.
class _WebRtcLinkMedia
    implements
        CallMedia,
        CallVideoSurface,
        ScreenShareSurface,
        AudioLevelMedia {
  _WebRtcLinkMedia(this.host);

  final WebRtcCallMedia host;
  RTCPeerConnection? _pc;
  RTCRtpSender? _videoSender;
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  bool _rendererReady = false;
  bool _closed = false;
  bool _sendingScreen = false;
  final _cands = StreamController<Map<String, dynamic>>.broadcast();
  final _link = StreamController<MediaLinkState>.broadcast();
  int _lastLost = 0, _lastRecv = 0;

  @override
  final ValueNotifier<bool> hasRemoteVideo = ValueNotifier<bool>(false);

  @override
  Stream<Map<String, dynamic>> get localCandidates => _cands.stream;
  @override
  Stream<MediaLinkState> get linkState => _link.stream;

  @override
  Future<void> open({required bool video}) async {
    await host.openLocal(video: video);
    try {
      await remoteRenderer.initialize();
      _rendererReady = true;
    } catch (e) {
      callLog('webrtc_link#1', e);
    }
  }

  @override
  bool get cameraUnavailable => host.cameraUnavailable;

  @override
  Future<void> createPeer(List<Map<String, dynamic>> iceServers) async {
    final pc = await createPeerConnection({
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
      'bundlePolicy': 'max-bundle',
      'iceCandidatePoolSize': 0,
    });
    _pc = pc;
    final local = host._local;
    if (local != null) {
      for (final t in local.getAudioTracks()) {
        await pc.addTrack(t, local);
      }
      final v = host._sendTrack;
      if (v != null) {
        _videoSender = await pc.addTrack(v, local);
        _sendingScreen = host._screenTrack != null;
        await _tuneSender(_videoSender!,
            screen: _sendingScreen, low: host._low);
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
      final m = switch (s) {
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
      if (m != null && !_link.isClosed) _link.add(m);
    };
    pc.onTrack = (RTCTrackEvent e) {
      if (e.streams.isEmpty) return;
      final s = e.streams.first;
      if (e.track.kind == 'video') {
        if (_rendererReady) {
          unawaited(remoteRenderer
              .setSrcObject(stream: s, trackId: e.track.id)
              .catchError((Object err) => callLog('webrtc_link#2', err)));
        }
        hasRemoteVideo.value = true;
      } else if (_rendererReady && !hasRemoteVideo.value) {
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

  // the mic / camera / speaker are the HOST's (shared by every link)
  @override
  Future<void> setMuted(bool muted) => host.setMuted(muted);
  @override
  Future<void> setCameraEnabled(bool on) => host.setCameraEnabled(on);
  @override
  Future<void> switchCamera() => host.switchCamera();
  @override
  Future<void> setSpeaker(bool on) => host.setSpeaker(on);
  @override
  Future<List<AudioRoute>> audioRoutes() => host.audioRoutes();
  @override
  Future<void> setAudioRoute(AudioRoute r) => host.setAudioRoute(r);

  @override
  Future<void> startVideo() async {
    if (host._videoTrack == null) await host.startVideo();
    await _sendVideo(host._sendTrack, screen: host._screenTrack != null);
  }

  @override
  Future<void> stopVideo() async {
    try {
      if (host._screenTrack == null) await _videoSender?.replaceTrack(null);
    } catch (e) {
      callLog('webrtc_link#3', e);
    }
  }

  /// Send [track] as this link's video. true = a sender was ADDED
  /// (renegotiation needed).
  Future<bool> _sendVideo(MediaStreamTrack? track,
      {required bool screen, bool addIfMissing = true}) async {
    final pc = _pc;
    if (pc == null || _closed) return false;
    _sendingScreen = screen;
    final sender = _videoSender;
    if (sender != null) {
      await sender.replaceTrack(track);
      await _tuneSender(sender, screen: screen, low: host._low);
      return false;
    }
    if (!addIfMissing || track == null) return false;
    final local = host._local ?? host._screen;
    if (local == null) return false;
    _videoSender = await pc.addTrack(track, local);
    await _tuneSender(_videoSender!, screen: screen, low: host._low);
    return true;
  }

  Future<void> _retune() async {
    final s = _videoSender;
    if (s != null) {
      await _tuneSender(s, screen: _sendingScreen, low: host._low);
    }
  }

  @override
  Future<double?> remoteAudioLevel() async {
    final pc = _pc;
    if (pc == null) return null;
    return _audioLevel(pc, 'inbound-rtp');
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
  Widget localView({bool mirror = true}) => host.localView(mirror: mirror);

  @override
  Widget remoteView() => _rendererReady
      ? RTCVideoView(remoteRenderer,
          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
      : const SizedBox.shrink();

  @override
  Widget remoteScreenView() => _rendererReady
      ? RTCVideoView(remoteRenderer,
          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain)
      : const SizedBox.shrink();

  /// Closes THIS link only; the host's tracks stay for the other links.
  @override
  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    try {
      await _pc?.close();
    } catch (e) {
      callLog('webrtc_link#4', e);
    }
    _pc = null;
    _videoSender = null;
    try {
      remoteRenderer.srcObject = null;
      if (_rendererReady) await remoteRenderer.dispose();
    } catch (e) {
      callLog('webrtc_link#5', e);
    }
    _rendererReady = false;
    await host._linkClosed(this);
  }
}
