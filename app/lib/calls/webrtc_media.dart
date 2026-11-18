import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../audio/audio_route_service.dart' as ar;
import '../audio/webrtc_audio_fallback.dart';
import 'call_controller.dart';
import 'call_log.dart';
import 'call_net_policy.dart';
import 'call_video_profile.dart'; // calls-quality
import 'call_video.dart';
import 'media_ext.dart'; // circle-screenshare

/// gatefix: the SDP rule for an offer. A VIDEO call's offer must carry a
/// video m-line even when this phone has no camera track (busy / failed /
/// audio-only) — then as receive-only, so the other person's camera can still
/// reach us. A voice call's offer gets none (a later camera switch
/// renegotiates). Never added twice.
@visibleForTesting
bool offerNeedsRecvOnlyVideo(
        {required bool videoCall,
        required bool hasLocalVideo,
        required bool alreadyAdded}) =>
    videoCall && !hasLocalVideo && !alreadyAdded;

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
    implements
        CallMedia,
        CallVideoSurface,
        AdaptiveCallMedia,
        VideoSizeSource,
        // circle-screenshare
        ScreenShareMedia,
        ScreenShareSurface {
  WebRtcCallMedia({this.cameraBlocked = false, this.facing = 'user'});

  /// gatefix: behave as if the camera cannot open (busy / failed HAL) —
  /// takes the REAL fallback below (join with the camera off,
  /// cameraUnavailable). The release gate's second client uses it: one
  /// emulator has one camera, and that is exactly the path whose video
  /// m-line was missing (gate run 44133650344).
  /// Not final: the gate turns the camera "back on" mid-call (case b).
  bool cameraBlocked;

  /// gatefix: which camera this side opens ('user' = front, the app's only
  /// value; the gate's second client uses 'environment' so ONE emulator
  /// with two emulated cameras can run a video call with both cameras on).
  final String facing;

  Map<String, dynamic> get _videoConstraints => {
        ..._videoConstraintsBase,
        // calls-quality: 720p on a capable phone, else 480p (decided once)
        ...CallVideoProfile.constraintsFor(capture),
        'facingMode': facing,
      };

  /// calls-quality: this call's camera size (the first decision sticks for
  /// the whole call — the controller's resolution ladder uses the same one).
  VideoCapture get capture => _capture ??= CallVideoProfile.capture;
  VideoCapture? _capture;

  RTCPeerConnection? _pc;
  RTCRtpSender? _audioSender;
  MediaPlan? _plan;
  List<Map<String, dynamic>> _iceServers = const [];

  /// calls-quality (two-emulator TURN proof): 'relay' makes every NEW peer
  /// gather TURN relay candidates only, so the call must go through the TURN
  /// server. Tests only; null (the app) = normal ICE (host, srflx, relay).
  @visibleForTesting
  static String? debugIcePolicy;
  MediaStream? _local;
  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  bool _renderersReady = false;

  // callpip: the remote video's size -> the PiP window's shape
  @override
  int? get remoteVideoWidth {
    if (!_renderersReady) return null;
    try {
      final v = remoteRenderer.value;
      final w = (_turned(v.rotation) ? v.height : v.width).toInt();
      return w > 0 ? w : null;
    } catch (_) {
      return null;
    }
  }

  @override
  int? get remoteVideoHeight {
    if (!_renderersReady) return null;
    try {
      final v = remoteRenderer.value;
      final h = (_turned(v.rotation) ? v.width : v.height).toInt();
      return h > 0 ? h : null;
    } catch (_) {
      return null;
    }
  }

  // a phone held upright sends landscape frames + rotation 90/270
  static bool _turned(int r) => r == 90 || r == 270;

  @override
  Listenable get remoteSizeChanges => remoteRenderer;
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
    _videoCall = video;
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
      if (video && cameraBlocked) throw StateError('camera blocked');
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

  // calls-camfast: PLAIN numbers. flutter_webrtc 1.6 on Android reads an
  // {'ideal': n} map from the wrong level (GetUserMediaImpl.getConstrainInt
  // checks "ideal" on the OUTER map), so every call opened the camera at its
  // 1280x720@30 default (calls2emu run 44216427178: "Target: 1280x720@30")
  // — a slow first keyframe and needless CPU on a low-end phone.
  static const Map<String, dynamic> _videoConstraintsBase = {
    'facingMode': 'user',
    'width': 640,
    'height': 480,
    'frameRate': 24,
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

  /// gatefix: this is a VIDEO call (open(video: true)), and whether the
  /// offer already carries a receive-only video m-line (see createOffer).
  bool _videoCall = false;
  bool _recvVideoAdded = false;

  /// calls-camfast: [_videoSender] sits on a video m-line that is ALREADY
  /// negotiated as send-capable (a camera-less VIDEO call keeps a sendrecv
  /// m-line with no track). Turning the camera on is then a replaceTrack —
  /// no renegotiation round trips (calls2emu run 44216427178: those took
  /// ~4.3 s of the 6-9.6 s before the other phone saw the picture).
  bool _sendSlot = false;

  @override
  bool videoSendReady = false;

  @override
  Future<void> startVideo() async {
    final pc = _peer;
    MediaStream cam;
    try {
      if (cameraBlocked) throw StateError('camera blocked');
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
    videoSendReady = sender != null && _sendSlot;
    if (_screenTrack != null && sender != null) {
      // circle-screenshare: the screen stays on the sender; the camera is
      // put back by stopScreenShare
    } else if (sender != null) {
      // calls-quality: the size / bitrate caps BEFORE the first frame — a
      // 720p first keyframe at full size on a low estimate took 3.4 s to the
      // other phone (calls2emu 44261908414 18w_b b_on)
      final plan = _plan;
      if (plan != null) await _capVideo(plan);
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
      videoSendReady = false; // a NEW sender: the caller must re-offer
    }
    cameraUnavailable = false;
    if (_renderersReady) localRenderer.srcObject = cam;
    final plan = _plan;
    if (plan != null) await _capVideo(plan);
  }

  @override
  Future<void> stopVideo() async {
    try {
      // circle-screenshare: never blank a shared screen from here
      if (_screenTrack == null) await _videoSender?.replaceTrack(null);
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

  /// calls-quality: starts with the route in use NOW — the controller
  /// listens only after open(), when the first route was already chosen
  /// (calls2emu 44261908414: the screen said "earpiece", Android played on
  /// the speaker).
  @override
  Stream<AudioRoute> get routeChanges async* {
    final now = _audio.active;
    if (now != null) yield now;
    yield* _audio.routeChanges;
  }

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
      if (debugIcePolicy != null) 'iceTransportPolicy': debugIcePolicy, // calls-quality
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
    // gatefix (release gate run 44115922433): flutter_webrtc on Android drops
    // the top-level offerToReceiveVideo below (it reads only mandatory /
    // optional), so a VIDEO call whose caller has no camera track (camera
    // busy / failed -> cameraUnavailable, or audio-only) offered NO video
    // m-line — only MID 0 (audio) was negotiated and the other person's
    // camera never reached the caller. A receive-only video transceiver
    // gives the answerer's camera its m-line (startVideo's addTrack reuses it).
    // calls-camfast: the m-line is SEND-capable (sendrecv, no track yet,
    // tagged with the audio stream id): a camera turned on later goes out
    // with replaceTrack, no renegotiation. Nothing is sent until then.
    if (offerNeedsRecvOnlyVideo(
        videoCall: _videoCall,
        hasLocalVideo: _videoSender != null,
        alreadyAdded: _recvVideoAdded)) {
      try {
        final local = _local;
        final t = await _peer.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
          init: RTCRtpTransceiverInit(
              direction: TransceiverDirection.SendRecv,
              streams: local != null ? [local] : null),
        );
        _recvVideoAdded = true;
        _videoSender = t.sender;
        _sendSlot = true;
      } catch (e) {
        callLog('webrtc_media#16', e);
      }
    }
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
        tuneOpusSdp(sdp,
            maxAverageBitrate: cap, ptimeMs: _plan?.opusPtimeMs),
        d.type);
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
              // video-only fields stay unset for the audio sender
              numTemporalLayers: null,
              scaleResolutionDownBy: null,
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
    if (v != null && _screenTrack != null) {
      return _capScreen(v, plan); // circle-screenshare
    }
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
    if (_videoCall && _videoSender == null) await _keepVideoSendSlot();
    final ans = _tuned(await _peer.createAnswer({}));
    await _peer.setLocalDescription(ans);
    return {'type': ans.type, 'sdp': ans.sdp};
  }

  /// calls-camfast: a VIDEO call answered WITHOUT a camera (busy / refused /
  /// unavailable) answers its video m-line sendrecv (no track yet, the audio
  /// stream id) instead of recvonly, so the camera turned on later is a
  /// replaceTrack — no reneg_request -> offer -> answer (3 signalling hops).
  Future<void> _keepVideoSendSlot() async {
    try {
      for (final t in await _peer.getTransceivers()) {
        if (t.receiver.track?.kind != 'video') continue;
        if (t.sender.track != null) return;
        await t.setDirection(TransceiverDirection.SendRecv);
        final local = _local;
        if (local != null) await t.sender.setStreams([local]);
        _videoSender = t.sender;
        _sendSlot = true;
        return;
      }
    } catch (e) {
      callLog('webrtc_media#30', e); // fall back to the renegotiation path
    }
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
    int? aPk, aBy, vFr; // gatefix: inbound media actually received
    int? vEnc, vOutPk; // gatefix: my outbound video (encoded frames, packets)
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
      } else if (r.type == 'outbound-rtp' &&
          (v['kind'] ?? v['mediaType']) == 'video') {
        final fe = v['framesEncoded'], ps = v['packetsSent'];
        if (fe is num) vEnc = (vEnc ?? 0) + fe.toInt();
        if (ps is num) vOutPk = (vOutPk ?? 0) + ps.toInt();
      } else if (r.type == 'inbound-rtp') {
        final pl = v['packetsLost'];
        final pr = v['packetsReceived'];
        if (pl is num) lost += pl.toInt();
        if (pr is num) recv += pr.toInt();
        final mk = v['kind'] ?? v['mediaType'];
        if (mk == 'audio') {
          final by = v['bytesReceived'];
          if (pr is num) aPk = (aPk ?? 0) + pr.toInt();
          if (by is num) aBy = (aBy ?? 0) + by.toInt();
        } else if (mk == 'video') {
          final fd = v['framesDecoded'];
          if (fd is num) vFr = (vFr ?? 0) + fd.toInt();
        }
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
        bytesReceived: got,
        audioPacketsIn: aPk,
        audioBytesIn: aBy,
        videoFramesDecoded: vFr,
        videoFramesEncoded: vEnc,
        videoPacketsSent: vOutPk);
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

  /// gatefix (owner P0, video calls): the WHOLE negotiated state of this side
  /// for the release gate's evidence — local/remote SDP, every transceiver
  /// (mid, kind, direction, currentDirection, sender/receiver track) and the
  /// video rtp stats. Read-only; never called by the app itself.
  @visibleForTesting
  Future<Map<String, dynamic>> debugEvidence() async {
    final pc = _pc;
    if (pc == null) return {'pc': null};
    final out = <String, dynamic>{};
    try {
      out['local_sdp'] = (await pc.getLocalDescription())?.sdp;
      out['remote_sdp'] = (await pc.getRemoteDescription())?.sdp;
    } catch (e) {
      out['sdp_error'] = '$e';
    }
    final tx = <Map<String, dynamic>>[];
    try {
      for (final t in await pc.getTransceivers()) {
        String? dir, cur;
        try {
          dir = '${await t.getDirection()}';
          cur = '${await t.getCurrentDirection()}';
        } catch (_) {}
        final st = t.sender.track, rt = t.receiver.track;
        tx.add({
          'mid': t.mid, 'direction': dir, 'current': cur,
          'sender_track': st == null ? null : {'id': st.id, 'kind': st.kind, 'enabled': st.enabled},
          'receiver_track': rt == null ? null : {'id': rt.id, 'kind': rt.kind},
        });
      }
    } catch (e) {
      out['transceivers_error'] = '$e';
    }
    out['transceivers'] = tx;
    final rtp = <Map<String, dynamic>>[];
    try {
      for (final r in await pc.getStats()) {
        if (r.type != 'inbound-rtp' && r.type != 'outbound-rtp') continue;
        final v = r.values;
        rtp.add({
          'type': r.type, 'kind': v['kind'] ?? v['mediaType'], 'mid': v['mid'],
          for (final k in const ['framesEncoded', 'framesSent', 'packetsSent', 'framesDecoded',
              'framesReceived', 'packetsReceived', 'bytesReceived', 'frameWidth', 'frameHeight'])
            if (v[k] != null) k: v[k],
        });
      }
    } catch (e) {
      out['stats_error'] = '$e';
    }
    out['rtp'] = rtp;
    out['local_video_track'] = _videoTrack?.id;
    out['has_remote_video'] = hasRemoteVideo.value;
    return out;
  }

  /// calls-quality: ONE read-only snapshot of what a viewer sees and hears —
  /// the ICE pair in use (relay or direct, Wi-Fi or cellular, RTT, available
  /// bitrate), inbound video (frames decoded, libwebrtc freeze counters,
  /// size, fps, loss), inbound audio (packets, loss, concealment), outbound
  /// video (frames, size, fps, why the quality is limited). Never changes
  /// any state (stats() keeps its own loss counters). Never called by the app.
  @visibleForTesting
  Future<Map<String, dynamic>> debugQuality() async {
    final pc = _pc;
    if (pc == null) return {'pc': null};
    final reports = await pc.getStats();
    final byId = <String, Map<dynamic, dynamic>>{for (final r in reports) r.id: r.values};
    String? sel;
    for (final r in reports) {
      if (r.type == 'transport' && r.values['selectedCandidatePairId'] != null) {
        sel = '${r.values['selectedCandidatePairId']}';
      }
    }
    num n(Object? v) => v is num ? v : 0;
    Map<String, dynamic> cand(Object? id) {
      final c = byId['$id'];
      if (c == null) return const {};
      return {
        'type': c['candidateType'],
        'protocol': c['protocol'],
        'relayProtocol': c['relayProtocol'],
        'networkType': c['networkType'],
        'address': c['address'] ?? c['ip'],
        'port': c['port'],
      };
    }
    final out = <String, dynamic>{
      't_ms': DateTime.now().millisecondsSinceEpoch,
      'capture': capture.name,
      if (_plan != null) 'plan': '$_plan',
    };
    var vinFrames = 0, vinFreezes = 0, vinLost = 0, vinRecv = 0;
    var vinFreezeS = 0.0;
    var ainPk = 0, ainLost = 0, aoutPk = 0, voutFrames = 0;
    var ainConcealed = 0, ainSamples = 0;
    for (final r in reports) {
      final v = r.values;
      final kind = v['kind'] ?? v['mediaType'];
      if (r.type == 'candidate-pair') {
        final isSel = sel != null
            ? r.id == sel
            : (v['nominated'] == true && v['state'] == 'succeeded');
        if (!isSel) continue;
        final rtt = v['currentRoundTripTime'];
        final ab = v['availableOutgoingBitrate'];
        out['pair'] = {
          'state': v['state'],
          'rtt_ms': rtt is num ? (rtt * 1000).round() : null,
          'avail_kbps': ab is num ? (ab / 1000).round() : null,
          'local': cand(v['localCandidateId']),
          'remote': cand(v['remoteCandidateId']),
        };
      } else if (r.type == 'inbound-rtp' && kind == 'video') {
        vinFrames += n(v['framesDecoded']).toInt();
        vinFreezes += n(v['freezeCount']).toInt();
        vinFreezeS += n(v['totalFreezesDuration']).toDouble();
        vinLost += n(v['packetsLost']).toInt();
        vinRecv += n(v['packetsReceived']).toInt();
        if (v['frameWidth'] != null) out['vin_w'] = v['frameWidth'];
        if (v['frameHeight'] != null) out['vin_h'] = v['frameHeight'];
        if (v['framesPerSecond'] != null) out['vin_fps'] = v['framesPerSecond'];
      } else if (r.type == 'inbound-rtp' && kind == 'audio') {
        ainPk += n(v['packetsReceived']).toInt();
        ainLost += n(v['packetsLost']).toInt();
        ainConcealed += n(v['concealedSamples']).toInt();
        ainSamples += n(v['totalSamplesReceived']).toInt();
        if (v['jitter'] is num) out['a_jitter_ms'] = ((v['jitter'] as num) * 1000).round();
      } else if (r.type == 'outbound-rtp' && kind == 'video') {
        voutFrames += n(v['framesEncoded']).toInt();
        if (v['frameWidth'] != null) out['vout_w'] = v['frameWidth'];
        if (v['frameHeight'] != null) out['vout_h'] = v['frameHeight'];
        if (v['framesPerSecond'] != null) out['vout_fps'] = v['framesPerSecond'];
        if (v['qualityLimitationReason'] != null) out['vout_limit'] = v['qualityLimitationReason'];
        if (v['targetBitrate'] is num) out['vout_target_kbps'] = ((v['targetBitrate'] as num) / 1000).round();
      } else if (r.type == 'outbound-rtp' && kind == 'audio') {
        aoutPk += n(v['packetsSent']).toInt();
      } else if (r.type == 'media-source' && kind == 'video') {
        // what the CAMERA delivers (before any encoder scaling)
        if (v['width'] != null) out['src_w'] = v['width'];
        if (v['height'] != null) out['src_h'] = v['height'];
        if (v['framesPerSecond'] != null) out['src_fps'] = v['framesPerSecond'];
      }
    }
    out.addAll({
      'vin_frames': vinFrames, 'vin_freezes': vinFreezes,
      'vin_freeze_ms': (vinFreezeS * 1000).round(),
      'vin_lost': vinLost, 'vin_recv': vinRecv,
      'ain_packets': ainPk, 'ain_lost': ainLost,
      'ain_concealed': ainConcealed, 'ain_samples': ainSamples,
      'aout_packets': aoutPk, 'vout_frames': voutFrames,
    });
    return out;
  }

  @override
  Future<void> dispose() async {
    await _releaseScreen(); // circle-screenshare
    await _releaseCamera();
    _videoSender = null;
    _sendSlot = false;
    videoSendReady = false;
    _audioSender = null;
    _recvVideoAdded = false;
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

  // ------------------------------------------- circle-screenshare (1:1)
  // Contract agreed with gatefix (17 Nov): a video sender exists ->
  // replaceTrack (no renegotiation); no sender (camera never opened) ->
  // addTrack exactly like startVideo (reuses the recv-only video
  // transceiver) and the controller renegotiates. createOffer / acceptOffer
  // / createPeer / onTrack are not touched here.
  MediaStream? _screen;
  MediaStreamTrack? _screenTrack;

  @override
  bool get screenSharing => _screenTrack != null;

  @override
  Future<bool> startScreenShare(
      {required Future<bool> Function() beforeCapture}) async {
    if (_screenTrack != null) return false;
    final pc = _peer;
    bool consent;
    try {
      // the SYSTEM MediaProjection dialog, every time (Android 14 tokens are
      // single-use; flutter_webrtc keeps the result for getDisplayMedia)
      // (no activity / a refused fragment never answers: give up after 2
      // minutes instead of a "Starting…" that never ends)
      consent = await Helper.requestCapturePermission()
          .timeout(const Duration(minutes: 2));
    } on TimeoutException {
      throw const ScreenShareFailed('consent:timeout');
    } catch (e) {
      final m = '$e'.toLowerCase();
      if (m.contains('permission') || m.contains('denied')) {
        throw const ScreenShareDenied();
      }
      throw ScreenShareFailed('consent:$e');
    }
    if (!consent) throw const ScreenShareDenied();
    // Android 14+: the mediaProjection foreground service must run NOW —
    // after consent, before getMediaProjection (inside getDisplayMedia).
    if (!await beforeCapture()) throw const ScreenShareFailed('service');
    MediaStream s;
    try {
      s = await navigator.mediaDevices
          .getDisplayMedia({'video': true, 'audio': false});
    } catch (e) {
      final m = '$e'.toLowerCase();
      if (m.contains('permission') || m.contains('revoked')) {
        throw const ScreenShareDenied();
      }
      throw ScreenShareFailed('capture:$e');
    }
    final tracks = s.getVideoTracks();
    if (tracks.isEmpty) {
      await s.dispose();
      throw const ScreenShareFailed('no screen track');
    }
    final track = tracks.first;
    _screen = s;
    _screenTrack = track;
    var added = false;
    try {
      final sender = _videoSender;
      if (sender != null) {
        await sender.replaceTrack(track);
      } else {
        // the audio stream id: the other phone's onTrack joins it to the
        // same remote stream (its renderer shows it)
        final local = _local;
        _videoSender = local != null
            ? await pc.addTrack(track, local)
            : await pc.addTrack(track, s);
        added = true;
      }
    } catch (e) {
      await _releaseScreen();
      throw ScreenShareFailed('send:$e');
    }
    final plan = _plan;
    if (plan != null && !added) await _capScreen(_videoSender!, plan);
    return added;
  }

  @override
  Future<void> stopScreenShare() async {
    if (_screenTrack == null) return;
    final sender = _videoSender;
    final cam = _videoTrack;
    _screenTrack = null; // startVideo / stopVideo / _capVideo: camera again
    try {
      await sender?.replaceTrack(cam);
    } catch (e) {
      callLog('webrtc_media#ss1', e);
    }
    final plan = _plan;
    if (plan != null) await _capVideo(plan);
    await _releaseScreen();
  }

  Future<void> _releaseScreen() async {
    final s = _screen;
    final t = _screenTrack;
    _screen = null;
    _screenTrack = null;
    try {
      await t?.stop();
      for (final x in s?.getTracks() ?? const <MediaStreamTrack>[]) {
        if (!identical(x, t)) await x.stop();
      }
      await s?.dispose();
    } catch (e) {
      callLog('webrtc_media#ss2', e);
    }
  }

  /// Screen caps on the video sender (half resolution, 10 fps, 1 Mbit/s;
  /// low-data: a third, 5 fps, 450 kbit/s; never above the network plan).
  /// Applied again after every renegotiation by applyPlan.
  Future<void> _capScreen(RTCRtpSender v, MediaPlan plan) async {
    final caps = ScreenShareCaps.forPlan(
        lowData: plan.opusPtimeMs != null,
        planMaxBps: plan.videoMaxBps,
        planMaxFps: plan.videoMaxFps,
        planScale: plan.videoScaleDown);
    try {
      await v.setParameters(RTCRtpParameters(
          // text stays sharp: lower the frame rate first, not the resolution
          degradationPreference: RTCDegradationPreference.MAINTAIN_RESOLUTION,
          encodings: [
            RTCRtpEncoding(
                active: plan.videoActive,
                maxBitrate: caps.maxBitrate,
                maxFramerate: caps.maxFramerate,
                scaleResolutionDownBy: caps.scaleDown)
          ]));
    } catch (e) {
      callLog('webrtc_media#ss3', e);
    }
  }

  @override
  Widget remoteScreenView() => _renderersReady
      ? RTCVideoView(remoteRenderer,
          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain)
      : const SizedBox.shrink();
}

/// Factory used through the deferred import.
CallMedia createWebRtcCallMedia() => WebRtcCallMedia();
