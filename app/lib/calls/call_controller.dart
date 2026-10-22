import 'dart:async';

import 'package:flutter/foundation.dart';

/// REAL 1:1 call state machine (c2-calls). Pure Dart: media, signalling and
/// sounds are injected, so it is unit-tested with fakes and driven in the app
/// by flutter_webrtc ([WebRtcCallMedia]) + the server ([ApiCallSignaling]).
///
/// Phases (mirrors backend core/logic/call_signal.py):
///   starting -> calling -> ringing -> accepted -> connected (<-> reconnecting)
///   -> ended(reason)
/// The caller hears ringback ONLY in `ringing` (the callee's phone confirmed
/// it rings). `connected` is entered ONLY when ICE really connects — there is
/// no other path to it. A media failure ends the call as `failed` / `media`.
enum CallPhase { starting, calling, ringing, accepted, connected, reconnecting, ended }

/// Why a call ended (server end_reason + client-only reasons).
enum CallEndReason {
  none,
  hangup,
  noAnswer,
  busy,
  declined,
  offline,
  canceled,
  failed,
  lost,
  // client-side
  mediaDenied, // mic / camera permission refused
  mediaError, // getUserMedia / RTCPeerConnection failed
  serverBusy, // TURN/box throttled
  unavailable, // callee switched off calls / blocked (neutral)
  upgrade, // video needs Premium (server gate)
  network, // could not reach our server
}

CallEndReason endReasonFromServer(String s) {
  switch (s) {
    case 'hangup':
      return CallEndReason.hangup;
    case 'no_answer':
      return CallEndReason.noAnswer;
    case 'busy':
      return CallEndReason.busy;
    case 'declined':
      return CallEndReason.declined;
    case 'offline':
      return CallEndReason.offline;
    case 'canceled':
      return CallEndReason.canceled;
    case 'failed':
      return CallEndReason.failed;
    case 'lost':
      return CallEndReason.lost;
    default:
      return s.isEmpty ? CallEndReason.none : CallEndReason.hangup;
  }
}

CallPhase phaseFromServer(String s) {
  switch (s) {
    case 'calling':
      return CallPhase.calling;
    case 'ringing':
      return CallPhase.ringing;
    case 'accepted':
      return CallPhase.accepted;
    case 'connected':
      return CallPhase.connected;
    case 'reconnecting':
      return CallPhase.reconnecting;
    default:
      return CallPhase.ended;
  }
}

enum CallQuality { unknown, good, fair, poor }

class MediaStats {
  const MediaStats({this.rttMs, this.lossPct, this.relayed = false});
  final double? rttMs;
  final double? lossPct;
  final bool relayed;

  CallQuality get quality {
    final r = rttMs, l = lossPct;
    if (r == null && l == null) return CallQuality.unknown;
    if ((l ?? 0) > 8 || (r ?? 0) > 600) return CallQuality.poor;
    if ((l ?? 0) > 2.5 || (r ?? 0) > 300) return CallQuality.fair;
    return CallQuality.good;
  }
}

/// ICE / peer-connection state as the media layer reports it.
enum MediaLinkState { idle, connecting, connected, disconnected, failed, closed }

class MediaOpenException implements Exception {
  MediaOpenException(this.denied, [this.detail = '']);
  final bool denied;
  final String detail;
  @override
  String toString() => 'MediaOpenException(denied: $denied, $detail)';
}

/// The media side (flutter_webrtc in the app, a fake in tests).
abstract class CallMedia {
  /// getUserMedia (audio, + camera for video). Throws [MediaOpenException].
  Future<void> open({required bool video});
  Future<void> createPeer(List<Map<String, dynamic>> iceServers);
  Future<Map<String, dynamic>> createOffer({bool iceRestart = false});
  Future<Map<String, dynamic>> acceptOffer(Map<String, dynamic> offer);
  Future<void> setAnswer(Map<String, dynamic> answer);
  Future<void> addCandidate(Map<String, dynamic> c);
  Stream<Map<String, dynamic>> get localCandidates;
  Stream<MediaLinkState> get linkState;
  Future<void> setMuted(bool muted);
  Future<void> setCameraEnabled(bool on);
  Future<void> switchCamera();
  Future<void> setSpeaker(bool on);
  Future<MediaStats> stats();
  Future<void> dispose();
}

/// Server signalling + call events (ApiCallSignaling in the app).
abstract class CallSignaling {
  /// POST /circle/<member>/call. Returns the server body.
  Future<Map<String, dynamic>> place(int memberId, String kind);

  /// POST /circle/calls/<id>/event {event:'answer'} (callee).
  Future<Map<String, dynamic>> accept(int callId);
  Future<Map<String, dynamic>> event(int callId, String event,
      {bool? relayed});
  Future<void> signal(int callId, String kind, Map<String, dynamic> data);
  Future<Map<String, dynamic>> status(int callId);

  /// The ICE config + throttle decision (GET /rtc/turn). null = unknown.
  Future<Map<String, dynamic>?> rtcConfig();

  /// call.state + call.signal events for [callId] (live, from the transport).
  Stream<Map<String, dynamic>> events(int callId);

  /// Signals for [callId] that arrived before we listened (callee offer).
  Future<List<Map<String, dynamic>>> backlog(int callId);

  /// Ask the transport for fast polling while this call lives.
  void setFast(bool on);
}

/// Sounds + small platform hooks (native channel in the app).
abstract class CallSounds {
  Future<void> startRingback();
  Future<void> stopRingback();
  Future<void> playBusy();
  Future<void> playDeclined();
  Future<void> playEnded();
  Future<void> stopAll();
  Future<void> setProximity(bool on);
}

class CallController extends ChangeNotifier {
  CallController({
    required this.media,
    required this.signaling,
    required this.sounds,
    required this.video,
    required this.outgoing,
    this.memberId,
    this.callId,
    this.now = DateTime.now,
    this.statusEvery = const Duration(seconds: 4),
    this.reconnectGrace = const Duration(seconds: 2),
    this.reconnectGiveUp = const Duration(seconds: 20),
    this.statsEvery = const Duration(seconds: 2),
  });

  final CallMedia media;
  final CallSignaling signaling;
  final CallSounds sounds;
  final bool video;
  final bool outgoing;
  final int? memberId;
  int? callId;
  final DateTime Function() now;
  final Duration statusEvery;
  final Duration reconnectGrace;
  final Duration reconnectGiveUp;
  final Duration statsEvery;

  CallPhase phase = CallPhase.starting;
  CallEndReason endReason = CallEndReason.none;
  bool turnAvailable = false;
  bool muted = false;
  late bool speakerOn = video;
  late bool cameraOn = video;
  bool frontCamera = true;
  bool remoteCameraOn = true;
  CallQuality quality = CallQuality.unknown;
  bool relayed = false;
  DateTime? connectedAt;
  Map<String, dynamic>? upgradePrompt;

  final List<String> log = []; // event trace (debug + tests)

  StreamSubscription<Map<String, dynamic>>? _evSub;
  StreamSubscription<Map<String, dynamic>>? _candSub;
  StreamSubscription<MediaLinkState>? _linkSub;
  Timer? _statusTimer;
  Timer? _statsTimer;
  Timer? _reconnectTimer;
  Timer? _giveUpTimer;
  bool _remoteSet = false;
  bool _offerHandled = false;
  bool _disposed = false;
  final List<Map<String, dynamic>> _pendingCandidates = [];
  final Set<int> _seenSeq = {};
  List<Map<String, dynamic>> _ice = const [];

  bool get isEnded => phase == CallPhase.ended;
  bool get isLive => phase == CallPhase.connected || phase == CallPhase.reconnecting;

  Duration get elapsed =>
      connectedAt == null ? Duration.zero : now().difference(connectedAt!);

  void _set(CallPhase p) {
    if (_disposed || phase == p || phase == CallPhase.ended) return;
    final prev = phase;
    phase = p;
    log.add('phase:${p.name}');
    _onPhase(prev, p);
    notifyListeners();
  }

  void _onPhase(CallPhase prev, CallPhase p) {
    if (outgoing) {
      if (p == CallPhase.ringing) {
        unawaited(sounds.startRingback());
      } else {
        unawaited(sounds.stopRingback()); // idempotent
      }
    }
    if (p == CallPhase.connected && connectedAt == null) {
      connectedAt = now();
      if (!video) unawaited(sounds.setProximity(true));
      _statsTimer ??= Timer.periodic(statsEvery, (_) => unawaited(_pollStats()));
    }
  }

  // ------------------------------------------------------------------ start
  /// Caller: place the call. Callee: accept [callId].
  Future<void> start() async {
    signaling.setFast(true);
    try {
      final cfg = await signaling.rtcConfig();
      if (cfg != null && cfg['throttled'] == true) {
        return _finish(CallEndReason.serverBusy);
      }
      final turnIce = ((cfg?['ice_servers'] ?? const []) as List)
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      turnAvailable = cfg?['configured'] == true && turnIce.isNotEmpty;
      if (outgoing) {
        await _startOutgoing(turnIce);
      } else {
        await _startIncoming(turnIce);
      }
    } on MediaOpenException catch (e) {
      log.add('media-open-failed:${e.denied}');
      await _hangupWith(
          'fail', e.denied ? CallEndReason.mediaDenied : CallEndReason.mediaError);
    } catch (e) {
      log.add('start-failed:$e');
      if (!isEnded) {
        await _hangupWith('fail',
            callId == null ? CallEndReason.network : CallEndReason.mediaError);
      }
    }
  }

  List<Map<String, dynamic>> _iceFrom(Map<String, dynamic> body,
      List<Map<String, dynamic>> turnIce) {
    if (turnIce.isNotEmpty) return turnIce;
    final ice = body['ice'];
    if (ice is Map && ice['iceServers'] is List) {
      return (ice['iceServers'] as List)
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    }
    return const [
      {'urls': ['stun:stun.l.google.com:19302']}
    ];
  }

  Future<void> _startOutgoing(List<Map<String, dynamic>> turnIce) async {
    final r = await signaling.place(memberId!, video ? 'video' : 'voice');
    if (r['allowed'] == false) {
      if (r['upgrade_required'] == true) {
        upgradePrompt = (r['prompt'] as Map?)?.cast<String, dynamic>() ?? {};
        return _finish(CallEndReason.upgrade);
      }
      return _finish(CallEndReason.unavailable);
    }
    callId = (r['call_id'] as num?)?.toInt();
    if (callId == null) return _finish(CallEndReason.network);
    log.add('placed:$callId');
    _listen();
    final p = phaseFromServer('${r['phase'] ?? 'calling'}');
    if (p == CallPhase.ended) {
      return _finish(endReasonFromServer('${r['end_reason'] ?? ''}'));
    }
    _set(p);
    _ice = _iceFrom(r, turnIce);
    // Open the mic/camera while it rings, then pre-send the offer so the
    // call connects the moment the callee accepts.
    await media.open(video: video);
    if (isEnded) return;
    await media.setSpeaker(speakerOn);
    await media.createPeer(_ice);
    _wireMedia();
    final offer = await media.createOffer();
    if (isEnded) return;
    await signaling.signal(callId!, 'offer', offer);
    log.add('offer-sent');
  }

  Future<void> _startIncoming(List<Map<String, dynamic>> turnIce) async {
    final id = callId;
    if (id == null) return _finish(CallEndReason.network);
    _listen();
    final r = await signaling.accept(id);
    final p = phaseFromServer('${r['phase'] ?? ''}');
    if (p == CallPhase.ended || p == CallPhase.calling || p == CallPhase.ringing) {
      // already over (caller hung up, rang out) — never fake a connect
      return _finish(p == CallPhase.ended
          ? endReasonFromServer('${r['end_reason'] ?? ''}')
          : CallEndReason.failed);
    }
    _set(CallPhase.accepted);
    _ice = _iceFrom(r, turnIce);
    await media.open(video: video);
    if (isEnded) return;
    await media.setSpeaker(speakerOn);
    await media.createPeer(_ice);
    _wireMedia();
    for (final s in await signaling.backlog(id)) {
      await _onEvent(s);
    }
  }

  void _listen() {
    _evSub ??= signaling.events(callId!).listen((e) => unawaited(_onEvent(e)));
    _statusTimer ??= Timer.periodic(statusEvery, (_) => unawaited(_pollStatus()));
  }

  void _wireMedia() {
    _candSub ??= media.localCandidates.listen((c) {
      final id = callId;
      if (id == null || isEnded) return;
      unawaited(signaling.signal(id, 'ice', c).catchError((_) {}));
    });
    _linkSub ??= media.linkState.listen(_onLink);
  }

  // ----------------------------------------------------------------- events
  Future<void> _onEvent(Map<String, dynamic> e) async {
    if (_disposed) return;
    final seq = (e['seq'] as num?)?.toInt();
    if (seq != null && !_seenSeq.add(seq)) return;
    final topic = '${e['topic'] ?? ''}';
    final p = (e['payload'] is Map)
        ? (e['payload'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    if (topic == 'call.state') return _onServerState(p);
    if (topic != 'call.signal') return;
    final kind = '${p['kind'] ?? ''}';
    final data = (p['data'] is Map)
        ? (p['data'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    log.add('signal:$kind');
    try {
      switch (kind) {
        case 'offer':
        case 'restart_offer':
          if (outgoing) return;
          if (kind == 'offer' && _offerHandled) return;
          _offerHandled = true;
          final ans = await media.acceptOffer(data);
          _remoteSet = true;
          await _flushCandidates();
          await signaling.signal(
              callId!, kind == 'offer' ? 'answer' : 'restart_answer', ans);
          log.add('${kind == 'offer' ? 'answer' : 'restart_answer'}-sent');
          break;
        case 'answer':
        case 'restart_answer':
          if (!outgoing) return;
          await media.setAnswer(data);
          _remoteSet = true;
          await _flushCandidates();
          break;
        case 'ice':
          if (_remoteSet) {
            await media.addCandidate(data);
          } else {
            _pendingCandidates.add(data);
          }
          break;
        case 'media':
          remoteCameraOn = data['camera'] != false;
          notifyListeners();
          break;
      }
    } catch (err) {
      log.add('signal-error:$kind:$err');
      if (!isLive) {
        await _hangupWith('fail', CallEndReason.mediaError);
      }
    }
  }

  Future<void> _flushCandidates() async {
    final list = List<Map<String, dynamic>>.from(_pendingCandidates);
    _pendingCandidates.clear();
    for (final c in list) {
      try {
        await media.addCandidate(c);
      } catch (_) {}
    }
  }

  void _onServerState(Map<String, dynamic> s) {
    final p = phaseFromServer('${s['phase'] ?? ''}');
    if (p == CallPhase.ended) {
      unawaited(_finish(endReasonFromServer('${s['end_reason'] ?? ''}')));
      return;
    }
    // The server never moves us INTO connected — only our own ICE does.
    if (p == CallPhase.connected || p == CallPhase.reconnecting) return;
    if (p.index > phase.index && phase != CallPhase.ended) _set(p);
  }

  Future<void> _pollStatus() async {
    final id = callId;
    if (id == null || isEnded) return;
    try {
      final s = await signaling.status(id);
      _onServerState(s);
    } catch (_) {}
  }

  void _onLink(MediaLinkState s) {
    if (isEnded) return;
    log.add('link:${s.name}');
    switch (s) {
      case MediaLinkState.connected:
        _reconnectTimer?.cancel();
        _giveUpTimer?.cancel();
        _giveUpTimer = null;
        final first = connectedAt == null;
        if (phase == CallPhase.reconnecting || phase.index < CallPhase.connected.index) {
          phase = CallPhase.accepted; // allow the forward move below
        }
        _set(CallPhase.connected);
        unawaited(_reportConnected(first));
        break;
      case MediaLinkState.disconnected:
        if (!isLive) return;
        _reconnectTimer?.cancel();
        _reconnectTimer = Timer(reconnectGrace, _beginReconnect);
        break;
      case MediaLinkState.failed:
        if (isLive) {
          _beginReconnect();
        } else {
          unawaited(_hangupWith('fail', CallEndReason.failed));
        }
        break;
      default:
        break;
    }
  }

  Future<void> _reportConnected(bool first) async {
    try {
      final st = await media.stats();
      relayed = relayed || st.relayed;
      quality = st.quality;
    } catch (_) {}
    try {
      await signaling.event(callId!, 'connected', relayed: relayed);
    } catch (_) {}
    if (!first) notifyListeners();
  }

  void _beginReconnect() {
    if (isEnded || phase == CallPhase.reconnecting) return;
    if (phase != CallPhase.connected) return;
    phase = CallPhase.reconnecting;
    log.add('phase:reconnecting');
    notifyListeners();
    unawaited(signaling.event(callId!, 'reconnect').catchError((_) => <String, dynamic>{}));
    unawaited(restartIce());
    _giveUpTimer?.cancel();
    _giveUpTimer = Timer(reconnectGiveUp, () {
      if (phase == CallPhase.reconnecting) {
        unawaited(_hangupWith('fail', CallEndReason.failed));
      }
    });
  }

  /// Network changed: the CALLER restarts ICE (one side only, no glare).
  Future<void> restartIce() async {
    if (!outgoing || isEnded || callId == null) return;
    try {
      final offer = await media.createOffer(iceRestart: true);
      await signaling.signal(callId!, 'restart_offer', offer);
      log.add('restart_offer-sent');
    } catch (e) {
      log.add('restart-failed:$e');
    }
  }

  Future<void> _pollStats() async {
    if (!isLive) return;
    try {
      final st = await media.stats();
      relayed = relayed || st.relayed;
      final q = st.quality;
      if (q != quality) {
        quality = q;
        notifyListeners();
      }
    } catch (_) {}
  }

  // --------------------------------------------------------------- controls
  Future<void> toggleMute() async {
    muted = !muted;
    notifyListeners();
    try {
      await media.setMuted(muted);
    } catch (_) {}
  }

  Future<void> toggleSpeaker() async {
    speakerOn = !speakerOn;
    notifyListeners();
    try {
      await media.setSpeaker(speakerOn);
    } catch (_) {}
    if (!video) unawaited(sounds.setProximity(isLive && !speakerOn));
  }

  Future<void> toggleCamera() async {
    if (!video) return;
    cameraOn = !cameraOn;
    notifyListeners();
    try {
      await media.setCameraEnabled(cameraOn);
      if (callId != null) {
        await signaling.signal(callId!, 'media', {'camera': cameraOn});
      }
    } catch (_) {}
  }

  Future<void> switchCamera() async {
    if (!video) return;
    try {
      await media.switchCamera();
      frontCamera = !frontCamera;
      notifyListeners();
    } catch (_) {}
  }

  /// The red button. Before connect: caller cancels; callee hangs up.
  Future<void> hangup() => _hangupWith(
      isLive || !outgoing ? 'hangup' : 'cancel', CallEndReason.hangup);

  Future<void> _hangupWith(String event, CallEndReason reason) async {
    if (isEnded) return;
    final id = callId;
    await _finish(reason, tone: event == 'fail');
    if (id != null) {
      try {
        await signaling.event(id, event);
      } catch (_) {}
    }
  }

  Future<void> _finish(CallEndReason reason, {bool tone = true}) async {
    if (phase == CallPhase.ended) return;
    endReason = reason;
    phase = CallPhase.ended;
    log.add('ended:${reason.name}');
    _stopTimers();
    signaling.setFast(false);
    try {
      await sounds.stopAll();
      await sounds.setProximity(false);
    } catch (_) {}
    await _closeMedia();
    if (!_disposed) notifyListeners();
    // the caller hears WHY it ended (generated tones; never blocks the UI)
    if (tone && outgoing) {
      final Future<void> Function()? play = switch (reason) {
        CallEndReason.busy => sounds.playBusy,
        CallEndReason.declined => sounds.playDeclined,
        CallEndReason.hangup || CallEndReason.upgrade => null,
        _ => sounds.playEnded,
      };
      if (play != null) unawaited(play().catchError((_) {}));
    }
  }

  Future<void> _closeMedia() async {
    await _candSub?.cancel();
    await _linkSub?.cancel();
    _candSub = null;
    _linkSub = null;
    try {
      await media.dispose();
    } catch (_) {}
  }

  void _stopTimers() {
    _statusTimer?.cancel();
    _statsTimer?.cancel();
    _reconnectTimer?.cancel();
    _giveUpTimer?.cancel();
    _evSub?.cancel();
    _evSub = null;
  }

  @override
  void dispose() {
    if (!isEnded) {
      unawaited(hangup());
    }
    _disposed = true;
    _stopTimers();
    super.dispose();
  }
}
