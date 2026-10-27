import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import '../api.dart' show ApiException;
import '../services/error_kind.dart';
import 'call_log.dart';

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
enum CallPhase {
  starting,
  calling,
  ringing,
  accepted,
  connected,
  reconnecting,
  ended
}

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
  connectFailed, // x1: never reached ICE connected within the timeout
  mediaDenied, // mic / camera permission refused
  mediaError, // getUserMedia / RTCPeerConnection failed
  serverBusy, // TURN/box throttled
  unavailable, // callee switched off calls / blocked (neutral)
  upgrade, // video needs Premium (server gate)
  network, // could not reach our server
  serverError, // rt2: our server ANSWERED with a 5xx (not the user's internet)
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

/// b1-calls: one getStats() sample of the pair in use. Every field is
/// optional (an OEM libwebrtc may not report it); only reported numbers are
/// judged, so a missing value can never make a call look bad.
class MediaStats {
  const MediaStats(
      {this.rttMs,
      this.lossPct,
      this.jitterMs,
      this.availableKbps,
      this.relayed = false});
  final double? rttMs;
  final double? lossPct;
  final double? jitterMs;

  /// availableOutgoingBitrate of the selected candidate pair (kbit/s).
  final double? availableKbps;
  final bool relayed;

  CallQuality get quality => qualityFor();

  /// Good / Fair / Poor (WhatsApp-like thresholds). Video needs more
  /// bandwidth than voice before it is called "good".
  CallQuality qualityFor({bool video = false}) {
    final r = rttMs, l = lossPct, j = jitterMs, b = availableKbps;
    if (r == null && l == null && j == null && b == null) {
      return CallQuality.unknown;
    }
    if ((l ?? 0) > 8 ||
        (r ?? 0) > 600 ||
        (j ?? 0) > 100 ||
        (b != null && b < (video ? 150 : 24))) {
      return CallQuality.poor;
    }
    if ((l ?? 0) > 2.5 ||
        (r ?? 0) > 300 ||
        (j ?? 0) > 40 ||
        (b != null && b < (video ? 400 : 48))) {
      return CallQuality.fair;
    }
    return CallQuality.good;
  }
}

/// b1-calls: where the call audio plays. Ids match flutter_webrtc's
/// audiooutput deviceIds (Twilio AudioSwitch kinds).
enum AudioRoute { earpiece, speaker, bluetooth, wired }

AudioRoute? audioRouteFromId(String id) => switch (id) {
      'earpiece' => AudioRoute.earpiece,
      'speaker' => AudioRoute.speaker,
      'bluetooth' => AudioRoute.bluetooth,
      'wired-headset' => AudioRoute.wired,
      _ => null,
    };

String audioRouteId(AudioRoute r) => switch (r) {
      AudioRoute.earpiece => 'earpiece',
      AudioRoute.speaker => 'speaker',
      AudioRoute.bluetooth => 'bluetooth',
      AudioRoute.wired => 'wired-headset',
    };

/// b1-calls voice <-> video switch (WhatsApp-style request + accept).
///   none       — nothing pending
///   requesting — I asked; waiting for the other person (times out)
///   incoming   — they asked; my screen shows Accept / Not now
///   switching  — accepted; camera opening + SDP renegotiation
enum VideoUpgrade { none, requesting, incoming, switching }

/// One short, honest in-call message (the screen shows it for a few
/// seconds). [CallController.noticeSeq] increments on every new notice.
enum CallNotice {
  none,
  videoDeclined, // they tapped "Not now"
  videoNoAnswer, // no reply within the timeout
  videoFailed, // renegotiation failed -> stayed on voice
  videoPremium, // the server gate: my plan can't start video
  cameraBlocked, // my camera permission off / camera busy
  remoteSwitchedToVoice, // they turned video off for both
  reconnected, // the network came back
}

/// The server refused a mid-call video request (plan gate). Thrown by
/// [CallSignaling.signal] for kind `video_request`.
class CallUpgradeRequired implements Exception {
  const CallUpgradeRequired();
}

/// ICE / peer-connection state as the media layer reports it.
enum MediaLinkState {
  idle,
  connecting,
  connected,
  disconnected,
  failed,
  closed
}

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

  /// b1-calls: true when [open] (video) could NOT start the camera but the
  /// microphone works — the call goes on with the camera off (WhatsApp
  /// behaviour) instead of failing (reality run 39946885424: the CI
  /// emulator's camera refused, so the whole video call ended as a failure).
  bool get cameraUnavailable;

  /// b1-calls voice -> video: open the camera and attach it to the existing
  /// peer connection (reuses the video transceiver; renegotiation follows).
  /// Throws [MediaOpenException] when the camera can't start.
  Future<void> startVideo();

  /// b1-calls video -> voice: stop the camera; no renegotiation needed (the
  /// sender just stops sending). Remote video views are cleared too.
  Future<void> stopVideo();

  /// Audio outputs available right now (always at least earpiece/speaker on
  /// a phone). Empty = unknown (the screen then offers a plain toggle).
  Future<List<AudioRoute>> audioRoutes();
  Future<void> setAudioRoute(AudioRoute r);
}

/// Server signalling + call events (ApiCallSignaling in the app).
abstract class CallSignaling {
  /// POST /circle/<member>/call. Returns the server body. [clientCallId] is
  /// the idempotency key of THIS tap: the server returns the same call for a
  /// repeated request (x1-calls), never a second "busy" record.
  Future<Map<String, dynamic>> place(int memberId, String kind,
      {String? clientCallId});

  /// POST /circle/calls/<id>/event {event:'answer'} (callee).
  Future<Map<String, dynamic>> accept(int callId);
  Future<Map<String, dynamic>> event(int callId, String event, {bool? relayed});
  /// Relay a call.signal. Throws [CallUpgradeRequired] when the server's plan
  /// gate refuses a `video_request`.
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
    this.reconnectGiveUp = const Duration(seconds: 30),
    this.statsEvery = const Duration(seconds: 2),
    this.connectTimeout = const Duration(seconds: 20),
    this.upgradeTimeout = const Duration(seconds: 30),
    this.renegTimeout = const Duration(seconds: 15),
    this.restartEvery = const Duration(seconds: 6),
    this.setupRetryDelays = defaultSetupRetryDelays,
    this.networkEvents,
    this.onSetupFailure,
    this.preplaced = false,
    String? clientCallId,
  })  : clientCallId = clientCallId ?? newClientCallId(),
        videoOn = video;

  /// callsB: a group-call PAIR link the SERVER already created ([callId]
  /// given): as the offerer ([outgoing]) this phone skips placing and goes
  /// straight to "open media, create the peer, send the offer" — the same
  /// path a normal outgoing call takes after it was placed.
  final bool preplaced;

  /// callsB: I share my screen in this (video) call right now — sent to the
  /// other side in the `media` signal (`screen`), so it shows the whole
  /// screen (not cropped) and "X is sharing their screen".
  bool screenSharing = false;

  /// callsB: the other person shares their screen.
  bool remoteScreen = false;

  /// calls-presence (owner 24 Oct "Call server busy — try again"): every
  /// call-setup step (rtc config, placing, accepting) is retried SILENTLY on
  /// a throttled answer, a 5xx or a network error / timeout — 3 tries within
  /// ~6 s — before the user sees an honest "Weak network" / "Server problem".
  static const defaultSetupRetryDelays = [
    Duration(milliseconds: 1500),
    Duration(milliseconds: 3000),
  ];

  /// Waits between setup tries (tries = length + 1). Tests pass zeros.
  final List<Duration> setupRetryDelays;

  /// calls-presence: the phone's default network changed ('wifi', 'cellular',
  /// 'other') or was lost ('lost') — Wi-Fi <-> mobile data. A live call goes
  /// to "Reconnecting…" and restarts ICE at once instead of waiting for ICE
  /// to notice; it is never dropped for the switch itself.
  final Stream<String>? networkEvents;

  /// calls-presence: a setup step failed for good after its silent retries
  /// (step: rtc_config | place | accept; code: throttled | server | network)
  /// — the app reports it for Owner Admin -> Call health (best effort).
  final void Function(String step, String code, int? callId)? onSetupFailure;

  /// Silent setup retries used by this call (debug + tests).
  int setupRetries = 0;

  final CallMedia media;
  final CallSignaling signaling;
  final CallSounds sounds;
  final bool video;

  /// true = this phone is the CALLER (offerer). Starts as "I tapped call";
  /// becomes false when the server merges a glare (both called each other
  /// at once) into the peer's call, where this phone is the callee.
  bool outgoing;

  /// true when the server merged this tap into the peer's ringing call.
  bool merged = false;

  /// Idempotency key of this placement (one per tap / Call again).
  final String clientCallId;

  /// A1-d: not connected within this after accept -> a real "fail" on both
  /// sides (server ends the call, both screens say "Couldn't connect").
  final Duration connectTimeout;
  final int? memberId;
  int? callId;
  final DateTime Function() now;
  final Duration statusEvery;
  final Duration reconnectGrace;
  final Duration reconnectGiveUp;
  final Duration statsEvery;

  /// b1: how long a voice->video request waits for the other person.
  final Duration upgradeTimeout;

  /// b1: how long the caller waits for the renegotiation answer.
  final Duration renegTimeout;

  /// b1: while reconnecting, the ICE restart (caller) / restart request
  /// (callee) is repeated this often until media is back or we give up.
  final Duration restartEvery;

  CallPhase phase = CallPhase.starting;
  CallEndReason endReason = CallEndReason.none;
  bool turnAvailable = false;
  bool muted = false;
  late bool speakerOn = video;
  late bool cameraOn = video;
  bool frontCamera = true;
  bool remoteCameraOn = true;

  /// b1: the other person's microphone (from their `media` signal).
  bool remoteMicOn = true;

  /// b1: the call is in VIDEO mode right now ([video] is how it started).
  bool videoOn;
  VideoUpgrade upgrade = VideoUpgrade.none;

  /// b1: the latest in-call notice (+ a counter so the same notice twice is
  /// still shown twice).
  CallNotice notice = CallNotice.none;
  int noticeSeq = 0;

  /// b1: the audio output in use and what is available (route picker).
  late AudioRoute route = video ? AudioRoute.speaker : AudioRoute.earpiece;
  List<AudioRoute> routes = const [];

  CallQuality quality = CallQuality.unknown;
  MediaStats lastStats = const MediaStats();
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
  Timer? _connectTimer;
  Timer? _upgradeTimer;
  Timer? _renegTimer;
  Timer? _restartTimer;
  bool _wasReconnecting = false;
  Future<void> _evChain = Future<void>.value();
  bool _started = false;
  bool _peerReady = false;
  int _preConnectRestarts = 0;
  final List<Map<String, dynamic>> _early = [];
  bool _remoteSet = false;
  bool _offerHandled = false;
  bool _disposed = false;
  final List<Map<String, dynamic>> _pendingCandidates = [];
  final Set<int> _seenSeq = {};
  List<Map<String, dynamic>> _ice = const [];

  bool get isEnded => phase == CallPhase.ended;
  bool get isLive =>
      phase == CallPhase.connected || phase == CallPhase.reconnecting;

  /// wa-polish: when the call ended — the talk time freezes here, so the
  /// "Call ended · 04:07" summary never keeps counting.
  DateTime? endedAt;

  Duration get elapsed => connectedAt == null
      ? Duration.zero
      : (endedAt ?? now()).difference(connectedAt!);

  /// wa-polish: how long we actually talked (null = never connected).
  Duration? get talkTime => connectedAt == null ? null : elapsed;

  void _set(CallPhase p) {
    if (_disposed || phase == p || phase == CallPhase.ended) return;
    final prev = phase;
    phase = p;
    log.add('phase:${p.name}');
    _onPhase(prev, p);
    notifyListeners();
  }

  /// Random idempotency key (no extra dependency).
  static String newClientCallId() {
    final r = Random.secure();
    return List<String>.generate(
        16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  void _armConnectTimer() {
    if (_connectTimer != null || connectedAt != null || isEnded) return;
    _connectTimer = Timer(connectTimeout, () {
      if (connectedAt == null && !isEnded) {
        log.add('connect-timeout');
        unawaited(_hangupWith('fail', CallEndReason.connectFailed));
      }
    });
  }

  void _onPhase(CallPhase prev, CallPhase p) {
    if (p == CallPhase.accepted) _armConnectTimer();
    if (outgoing) {
      if (p == CallPhase.ringing) {
        unawaited(sounds.startRingback());
      } else {
        unawaited(sounds.stopRingback()); // idempotent
      }
    }
    if (p == CallPhase.connected && connectedAt == null) {
      connectedAt = now();
      _connectTimer?.cancel();
      if (!videoOn && !speakerOn) unawaited(sounds.setProximity(true));
      _statsTimer ??=
          Timer.periodic(statsEvery, (_) => unawaited(_pollStats()));
    }
  }

  // ------------------------------------------------------------------ start
  /// Caller: place the call. Callee: accept [callId]. Runs ONCE per
  /// controller — rebuilds, route events or a second tap can never place a
  /// second call (x1-calls root cause: the call was POSTed twice).
  Future<void> start() async {
    if (_started || _disposed) {
      log.add('start-ignored');
      return;
    }
    _started = true;
    signaling.setFast(true);
    _watchNetwork();
    try {
      var cfg = await signaling.rtcConfig();
      for (var i = 0;
          cfg != null &&
              cfg['throttled'] == true &&
              i < setupRetryDelays.length &&
              !isEnded;
          i++) {
        setupRetries++;
        log.add('retry:rtc_config:${i + 1}');
        await Future<void>.delayed(setupRetryDelays[i]);
        if (isEnded) return;
        cfg = await signaling.rtcConfig();
      }
      if (isEnded) return;
      if (cfg != null && cfg['throttled'] == true) {
        _reportSetup('rtc_config', 'throttled');
        await _finish(CallEndReason.serverBusy);
        return;
      }
      final turnIce = ((cfg?['ice_servers'] ?? const []) as List)
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      turnAvailable = cfg?['configured'] == true && turnIce.isNotEmpty;
      if (outgoing && preplaced && callId != null) {
        await _startPreplaced(turnIce);
      } else if (outgoing) {
        await _startOutgoing(turnIce);
      } else {
        await _startIncoming(turnIce);
      }
    } on MediaOpenException catch (e) {
      log.add('media-open-failed:${e.denied}');
      await _hangupWith('fail',
          e.denied ? CallEndReason.mediaDenied : CallEndReason.mediaError);
    } catch (e) {
      log.add('start-failed:$e');
      if (!isEnded) {
        // rt2: a 5xx while placing/accepting is OUR server, never the user's
        // internet (reality run 39859999833: POST /circle/1/call 500 showed
        // "Couldn't reach Assisto. Please check your internet").
        await _hangupWith(
            'fail',
            callId == null
                ? (isServerFailure(e)
                    ? CallEndReason.serverError
                    : CallEndReason.network)
                : (isServerFailure(e)
                    ? CallEndReason.serverError
                    : CallEndReason.mediaError));
      }
    }
  }

  List<Map<String, dynamic>> _iceFrom(
      Map<String, dynamic> body, List<Map<String, dynamic>> turnIce) {
    if (turnIce.isNotEmpty) return turnIce;
    final ice = body['ice'];
    if (ice is Map && ice['iceServers'] is List) {
      return (ice['iceServers'] as List)
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    }
    return const [
      {
        'urls': ['stun:stun.l.google.com:19302']
      }
    ];
  }

  Future<void> _startOutgoing(List<Map<String, dynamic>> turnIce) async {
    // the SAME client_call_id on every try: the server returns the same call
    // for a repeated POST (x1 idempotency), so a retry never rings twice.
    final r = await _retrying(
        'place',
        () => signaling.place(memberId!, video ? 'video' : 'voice',
            clientCallId: clientCallId));
    if (isEnded) return;
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
    if (r['merged'] == true && r['role'] == 'callee') {
      // glare: the peer called me at the same moment — the server joined me
      // to THEIR call as its callee (already accepted). Never "busy".
      merged = true;
      outgoing = false;
      log.add('merged:$callId');
      return _startIncoming(turnIce, accepted: r);
    }
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
    _afterOpen();
    if (await _endedDuringSetup()) return;
    await media.setSpeaker(speakerOn);
    await media.createPeer(_ice);
    if (await _endedDuringSetup()) return;
    _wireMedia();
    final offer = await media.createOffer();
    if (await _endedDuringSetup()) return;
    await signaling.signal(callId!, 'offer', offer);
    log.add('offer-sent');
    await _peerUp();
  }

  /// callsB: the offerer of a server-created pair link (group call).
  Future<void> _startPreplaced(List<Map<String, dynamic>> turnIce) async {
    final id = callId!;
    _listen();
    final r = await _retrying<Map<String, dynamic>>(
        'status', () => signaling.status(id));
    if (isEnded) return;
    final p = phaseFromServer('${r['phase'] ?? ''}');
    if (p == CallPhase.ended) {
      return _finish(endReasonFromServer('${r['end_reason'] ?? ''}'));
    }
    log.add('preplaced:$id');
    _set(p);
    _ice = _iceFrom(r, turnIce);
    await media.open(video: video);
    _afterOpen();
    if (await _endedDuringSetup()) return;
    await media.setSpeaker(speakerOn);
    await media.createPeer(_ice);
    if (await _endedDuringSetup()) return;
    _wireMedia();
    final offer = await media.createOffer();
    if (await _endedDuringSetup()) return;
    await signaling.signal(id, 'offer', offer);
    log.add('offer-sent');
    await _peerUp();
  }

  /// The call ended (hang-up, server end, timeout) while the mic / peer
  /// connection was still being created: release them NOW, so no mic stays
  /// open and no TURN allocation leaks (coturn counts allocations per user).
  Future<bool> _endedDuringSetup() async {
    if (!isEnded) return false;
    log.add('setup-after-end:released');
    await _closeMedia();
    return true;
  }

  /// b1: a video call whose camera could not start goes on as "camera off"
  /// (the mic works) instead of failing the whole call.
  void _afterOpen() {
    if (video && media.cameraUnavailable) {
      cameraOn = false;
      log.add('camera-unavailable');
      _notify(CallNotice.cameraBlocked);
    }
  }

  /// The peer connection exists: replay signals that arrived before it.
  Future<void> _peerUp() async {
    _peerReady = true;
    final early = List<Map<String, dynamic>>.from(_early)
      ..sort((a, b) => ((a['seq'] as num?) ?? 0).compareTo((b['seq'] as num?) ?? 0));
    _early.clear();
    for (final e in early) {
      await _onEvent(e, replay: true);
    }
  }

  Future<void> _startIncoming(List<Map<String, dynamic>> turnIce,
      {Map<String, dynamic>? accepted}) async {
    final id = callId;
    if (id == null) return _finish(CallEndReason.network);
    _listen();
    final Map<String, dynamic> r = accepted ??
        await _retrying<Map<String, dynamic>>(
            'accept', () => signaling.accept(id));
    if (isEnded) return;
    final p = phaseFromServer('${r['phase'] ?? ''}');
    if (p == CallPhase.ended ||
        p == CallPhase.calling ||
        p == CallPhase.ringing) {
      // already over (caller hung up, rang out) — never fake a connect
      return _finish(p == CallPhase.ended
          ? endReasonFromServer('${r['end_reason'] ?? ''}')
          : CallEndReason.failed);
    }
    _set(CallPhase.accepted);
    _ice = _iceFrom(r, turnIce);
    await media.open(video: video);
    _afterOpen();
    if (await _endedDuringSetup()) return;
    await media.setSpeaker(speakerOn);
    await media.createPeer(_ice);
    if (await _endedDuringSetup()) return;
    _wireMedia();
    for (final s in await signaling.backlog(id)) {
      _early.add(s);
    }
    await _peerUp();
  }

  /// A transient setup failure worth a silent retry: our server answered 5xx
  /// / 429, or never answered (socket, DNS, TLS, timeout). A 4xx refusal is
  /// final (validation, gate, not found) and is never retried.
  static bool isTransientSetupError(Object e) {
    if (e is MediaOpenException || e is CallUpgradeRequired) return false;
    if (failKindOf(e) == FailKind.refused) {
      return e is ApiException && e.status == 429;
    }
    return true;
  }

  Future<T> _retrying<T>(String step, Future<T> Function() fn) async {
    for (var i = 0;; i++) {
      try {
        return await fn();
      } catch (e) {
        if (isEnded || !isTransientSetupError(e)) rethrow;
        if (i >= setupRetryDelays.length) {
          _reportSetup(step, isServerFailure(e) ? 'server' : 'network');
          rethrow;
        }
        setupRetries++;
        log.add('retry:$step:${i + 1}');
        await Future<void>.delayed(setupRetryDelays[i]);
        if (isEnded) rethrow;
      }
    }
  }

  bool _setupReported = false;
  void _reportSetup(String step, String code) {
    if (_setupReported) return;
    _setupReported = true;
    log.add('setup-failed:$step:$code');
    try {
      onSetupFailure?.call(step, code, callId);
    } catch (e) {
      callLog('call_controller#21', e);
    }
  }

  // ------------------------------------------------- network switch (Wi-Fi)
  StreamSubscription<String>? _netSub;

  void _watchNetwork() {
    final s = networkEvents;
    if (s == null || _netSub != null) return;
    _netSub = s.listen(onNetworkChanged, onError: (Object e) {
      callLog('call_controller#22', e);
    });
  }

  /// The phone switched networks (or lost its network). Live call ->
  /// "Reconnecting…" now + ICE restart (repeated every [restartEvery] until
  /// media is back; given up only after [reconnectGiveUp]). Before connect,
  /// the caller restarts ICE once on a NEW network (fresh candidates).
  void onNetworkChanged(String kind) {
    if (isEnded || _disposed) return;
    log.add('net:$kind');
    if (phase == CallPhase.connected) {
      _reconnectTimer?.cancel();
      _beginReconnect();
      return;
    }
    if (phase == CallPhase.reconnecting) {
      if (kind != 'lost') _kickRestart();
      return;
    }
    if (kind != 'lost' &&
        outgoing &&
        phase == CallPhase.accepted &&
        _peerReady &&
        connectedAt == null) {
      unawaited(restartIce());
    }
  }

  void _listen() {
    // b1: events are handled ONE AT A TIME in arrival order — a
    // `video_accept` (camera opens) must finish before the `reneg_offer`
    // that follows it is answered.
    _evSub ??= signaling.events(callId!).listen((e) {
      _evChain = _evChain.then((_) => _onEvent(e)).catchError((Object err) {
        callLog('call_controller#13', err);
      });
    });
    _statusTimer ??=
        Timer.periodic(statusEvery, (_) => unawaited(_pollStatus()));
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
  Future<void> _onEvent(Map<String, dynamic> e, {bool replay = false}) async {
    if (_disposed) return;
    final topic = '${e['topic'] ?? ''}';
    if (topic == 'call.signal' && !_peerReady && !replay) {
      // A1-c: an offer / ICE candidate that arrives before our peer
      // connection exists is queued, never dropped or applied to nothing.
      _early.add(e);
      return;
    }
    final seq = (e['seq'] as num?)?.toInt();
    if (seq != null && !_seenSeq.add(seq)) return;
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
          remoteMicOn = data['mic'] != false;
          remoteScreen = data['screen'] == true;
          notifyListeners();
          break;
        // ---- b1-calls: voice <-> video + reconnect -----------------------
        case 'video_request':
          await _onVideoRequest();
          break;
        case 'video_accept':
          await _onVideoAccepted();
          break;
        case 'video_decline':
          _onVideoDeclined('${data['reason'] ?? ''}');
          break;
        case 'video_cancel':
          if (upgrade == VideoUpgrade.incoming) {
            _setUpgrade(VideoUpgrade.none);
          }
          break;
        case 'video_off':
          await _onRemoteVideoOff();
          break;
        case 'reneg_offer':
          if (outgoing) return;
          final ans = await media.acceptOffer(data);
          _remoteSet = true;
          await signaling.signal(callId!, 'reneg_answer', ans);
          log.add('reneg_answer-sent');
          if (upgrade == VideoUpgrade.switching) {
            _setUpgrade(VideoUpgrade.none);
          }
          break;
        case 'reneg_answer':
          if (!outgoing) return;
          await media.setAnswer(data);
          _renegTimer?.cancel();
          _renegTimer = null;
          if (upgrade == VideoUpgrade.switching) {
            _setUpgrade(VideoUpgrade.none);
          }
          break;
        case 'reneg_request':
          // the callee opened its camera late: the caller re-offers
          if (outgoing && isLive) await _renegotiate();
          break;
        case 'restart_request':
          // the callee's network changed first: the caller restarts ICE
          if (outgoing && isLive) unawaited(restartIce());
          break;
      }
    } catch (err) {
      log.add('signal-error:$kind:$err');
      if (isLive && kind.startsWith('reneg_')) {
        // the video switch could not be negotiated: honest fallback to voice
        await _videoFailedBackToVoice();
      } else if (!isLive) {
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
      } catch (e) {
        callLog('call_controller#1', e);
      }
    }
  }

  void _onServerState(Map<String, dynamic> s) {
    final p = phaseFromServer('${s['phase'] ?? ''}');
    if (p == CallPhase.ended) {
      var reason = endReasonFromServer('${s['end_reason'] ?? ''}');
      if (connectedAt == null &&
          (reason == CallEndReason.failed || reason == CallEndReason.lost) &&
          phase.index >= CallPhase.accepted.index) {
        reason = CallEndReason.connectFailed; // answered, never connected
      }
      unawaited(_finish(reason));
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
    } catch (e) {
      callLog('call_controller#2', e);
    }
  }

  void _onLink(MediaLinkState s) {
    if (isEnded) return;
    log.add('link:${s.name}');
    switch (s) {
      case MediaLinkState.connected:
        _reconnectTimer?.cancel();
        _giveUpTimer?.cancel();
        _giveUpTimer = null;
        _restartTimer?.cancel();
        _restartTimer = null;
        final first = connectedAt == null;
        final back = phase == CallPhase.reconnecting || _wasReconnecting;
        _wasReconnecting = false;
        if (phase == CallPhase.reconnecting ||
            phase.index < CallPhase.connected.index) {
          phase = CallPhase.accepted; // allow the forward move below
        }
        _set(CallPhase.connected);
        if (back) _notify(CallNotice.reconnected);
        unawaited(_reportConnected(first));
        // b1: my mic / camera state survives a reconnect (and a callee that
        // joined muted / camera-off tells the other side at once).
        if (back || muted || (videoOn && !cameraOn) || screenSharing) {
          unawaited(_sendMediaState());
        }
        break;
      case MediaLinkState.disconnected:
        if (!isLive) return;
        _reconnectTimer?.cancel();
        _reconnectTimer = Timer(reconnectGrace, _beginReconnect);
        break;
      case MediaLinkState.failed:
        if (isLive) {
          _beginReconnect();
        } else if (outgoing && _preConnectRestarts < 1) {
          // first ICE attempt failed before connecting: one ICE restart
          // (fresh candidates incl. TURN/TCP) inside the 20 s window.
          _preConnectRestarts++;
          unawaited(restartIce());
        } else {
          // the 20 s connect timer turns this into a real fail on both sides
          _armConnectTimer();
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
      lastStats = st;
      quality = st.qualityFor(video: videoOn);
    } catch (e) {
      callLog('call_controller#3', e);
    }
    try {
      await signaling.event(callId!, 'connected', relayed: relayed);
    } catch (e) {
      callLog('call_controller#4', e);
    }
    if (!first) notifyListeners();
  }

  void _beginReconnect() {
    if (isEnded || phase == CallPhase.reconnecting) return;
    if (phase != CallPhase.connected) return;
    phase = CallPhase.reconnecting;
    log.add('phase:reconnecting');
    notifyListeners();
    unawaited(signaling
        .event(callId!, 'reconnect')
        .catchError((_) => <String, dynamic>{}));
    _wasReconnecting = true;
    _kickRestart();
    // b1: keep trying while the network settles (the first restart offer is
    // often lost while the phone is between Wi-Fi and mobile data).
    _restartTimer?.cancel();
    _restartTimer = Timer.periodic(restartEvery, (_) {
      if (phase == CallPhase.reconnecting) {
        _kickRestart();
      } else {
        _restartTimer?.cancel();
        _restartTimer = null;
      }
    });
    _giveUpTimer?.cancel();
    _giveUpTimer = Timer(reconnectGiveUp, () {
      if (phase == CallPhase.reconnecting) {
        log.add('reconnect-gave-up');
        // honest: the call was up and the connection could not come back
        unawaited(_hangupWith('fail', CallEndReason.lost));
      }
    });
  }

  /// Caller: a fresh ICE-restart offer. Callee: ask the caller for one (only
  /// the caller offers, so the two phones never collide).
  void _kickRestart() {
    if (outgoing) {
      unawaited(restartIce());
    } else if (callId != null) {
      unawaited(signaling
          .signal(callId!, 'restart_request', const {})
          .catchError((Object e) => callLog('call_controller#14', e)));
      log.add('restart_request-sent');
    }
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
      lastStats = st;
      final q = st.qualityFor(video: videoOn);
      if (q != quality) {
        quality = q;
        notifyListeners();
      }
    } catch (e) {
      callLog('call_controller#5', e);
    }
  }

  // --------------------------------------------------------------- controls
  Future<void> toggleMute() async {
    muted = !muted;
    notifyListeners();
    try {
      await media.setMuted(muted);
    } catch (e) {
      callLog('call_controller#6', e);
    }
    unawaited(_sendMediaState());
  }

  Future<void> toggleSpeaker() async {
    speakerOn = !speakerOn;
    route = speakerOn ? AudioRoute.speaker : AudioRoute.earpiece;
    notifyListeners();
    try {
      await media.setSpeaker(speakerOn);
    } catch (e) {
      callLog('call_controller#7', e);
    }
    if (!videoOn) unawaited(sounds.setProximity(isLive && !speakerOn));
  }

  /// b1: what the route picker offers right now (earpiece / speaker /
  /// Bluetooth / wired). Never throws; empty = unknown.
  Future<List<AudioRoute>> refreshRoutes() async {
    try {
      routes = await media.audioRoutes();
    } catch (e) {
      callLog('call_controller#15', e);
      routes = const [];
    }
    if (!_disposed) notifyListeners();
    return routes;
  }

  /// b1: the route picker chose [r].
  Future<void> setRoute(AudioRoute r) async {
    route = r;
    speakerOn = r == AudioRoute.speaker;
    notifyListeners();
    try {
      await media.setAudioRoute(r);
    } catch (e) {
      callLog('call_controller#16', e);
    }
    // the proximity sensor blanks the screen only at the ear
    if (!videoOn) {
      unawaited(sounds.setProximity(isLive && r == AudioRoute.earpiece));
    }
  }

  Future<void> toggleCamera() async {
    if (!videoOn) return;
    final on = !cameraOn;
    if (on && media.cameraUnavailable) {
      // the camera never opened (busy / refused at start): open it now and
      // let the other side receive it (renegotiation through the caller).
      if (!await _openCamera()) return;
      cameraOn = true;
      notifyListeners();
      await _renegotiateOrAsk();
      unawaited(_sendMediaState());
      return;
    }
    cameraOn = on;
    notifyListeners();
    try {
      await media.setCameraEnabled(cameraOn);
    } catch (e) {
      callLog('call_controller#8', e);
    }
    await _sendMediaState();
  }

  Future<void> switchCamera() async {
    if (!videoOn) return;
    try {
      await media.switchCamera();
      frontCamera = !frontCamera;
      notifyListeners();
    } catch (e) {
      callLog('call_controller#9', e);
    }
  }

  // ------------------------------------------------- b1: voice <-> video
  void _notify(CallNotice n) {
    notice = n;
    noticeSeq++;
    log.add('notice:${n.name}');
    if (!_disposed) notifyListeners();
  }

  void _setUpgrade(VideoUpgrade u) {
    if (upgrade == u) return;
    upgrade = u;
    log.add('upgrade:${u.name}');
    if (u == VideoUpgrade.none || u == VideoUpgrade.switching) {
      _upgradeTimer?.cancel();
      _upgradeTimer = null;
    }
    if (!_disposed) notifyListeners();
  }

  /// My mic / camera / mode, so the other screen shows "mic off" and the
  /// camera-off placeholder. Old builds read only `camera`.
  Future<void> _sendMediaState() async {
    final id = callId;
    if (id == null || isEnded) return;
    try {
      await signaling.signal(id, 'media', {
        'camera': videoOn && cameraOn,
        'mic': !muted,
        'video': videoOn,
        if (screenSharing) 'screen': true,
      });
    } catch (e) {
      callLog('call_controller#18', e);
    }
  }

  /// callsB: my screen share started / stopped on this link (the media
  /// layer already swapped the video track) — tell the other side.
  Future<void> setScreenSharing(bool on) async {
    if (screenSharing == on || isEnded) return;
    screenSharing = on;
    log.add('screen:${on ? 'on' : 'off'}');
    notifyListeners();
    await _sendMediaState();
  }

  /// callsB: a new video track had no sender on this link yet (the camera
  /// never opened): renegotiate so the other side receives it.
  Future<void> renegotiateForNewTrack() => _renegotiateOrAsk();

  /// Ask to switch this voice call to video (the other person must accept).
  Future<void> requestVideo() async {
    if (!isLive || videoOn || upgrade != VideoUpgrade.none) return;
    _setUpgrade(VideoUpgrade.requesting);
    try {
      await signaling.signal(callId!, 'video_request', const {});
      log.add('video_request-sent');
    } on CallUpgradeRequired {
      _setUpgrade(VideoUpgrade.none);
      _notify(CallNotice.videoPremium);
      return;
    } catch (e) {
      callLog('call_controller#19', e);
      _setUpgrade(VideoUpgrade.none);
      _notify(CallNotice.videoFailed);
      return;
    }
    if (upgrade != VideoUpgrade.requesting) return; // answered already
    _upgradeTimer?.cancel();
    _upgradeTimer = Timer(upgradeTimeout, () {
      if (upgrade != VideoUpgrade.requesting || isEnded) return;
      log.add('video-request-timeout');
      _setUpgrade(VideoUpgrade.none);
      _notify(CallNotice.videoNoAnswer);
      unawaited(signaling
          .signal(callId!, 'video_cancel', const {})
          .catchError((Object e) => callLog('call_controller#20', e)));
    });
  }

  /// I withdraw my pending request ("Cancel" on the waiting banner).
  Future<void> cancelVideoRequest() async {
    if (upgrade != VideoUpgrade.requesting) return;
    _setUpgrade(VideoUpgrade.none);
    try {
      await signaling.signal(callId!, 'video_cancel', const {});
    } catch (e) {
      callLog('call_controller#21', e);
    }
  }

  Future<void> _onVideoRequest() async {
    if (!isLive) return;
    if (videoOn) {
      // already on video (a late duplicate): just say yes again
      await signaling.signal(callId!, 'video_accept', const {});
      return;
    }
    if (upgrade == VideoUpgrade.requesting) {
      // we BOTH asked at the same moment: that is a yes from both sides
      log.add('video-request-glare');
      await acceptVideo();
      return;
    }
    if (upgrade != VideoUpgrade.none) return;
    _setUpgrade(VideoUpgrade.incoming);
    _upgradeTimer?.cancel();
    _upgradeTimer = Timer(upgradeTimeout, () {
      if (upgrade != VideoUpgrade.incoming || isEnded) return;
      _setUpgrade(VideoUpgrade.none);
      unawaited(signaling
          .signal(callId!, 'video_decline', const {'reason': 'timeout'})
          .catchError((Object e) => callLog('call_controller#22', e)));
    });
  }

  /// "Accept" on the in-call prompt (or the both-asked case above).
  Future<void> acceptVideo() async {
    if (!isLive || videoOn) return;
    if (upgrade != VideoUpgrade.incoming &&
        upgrade != VideoUpgrade.requesting) {
      return;
    }
    _setUpgrade(VideoUpgrade.switching);
    if (!await _openCamera()) {
      _setUpgrade(VideoUpgrade.none);
      await signaling
          .signal(callId!, 'video_decline', const {'reason': 'camera'})
          .catchError((Object e) => callLog('call_controller#23', e));
      return;
    }
    try {
      await signaling.signal(callId!, 'video_accept', const {});
    } catch (e) {
      callLog('call_controller#24', e);
    }
    await _enterVideoMode();
    if (outgoing) await _renegotiate();
  }

  /// "Not now" on the prompt.
  Future<void> declineVideo() async {
    if (upgrade != VideoUpgrade.incoming) return;
    _setUpgrade(VideoUpgrade.none);
    try {
      await signaling
          .signal(callId!, 'video_decline', const {'reason': 'declined'});
    } catch (e) {
      callLog('call_controller#25', e);
    }
  }

  Future<void> _onVideoAccepted() async {
    if (upgrade != VideoUpgrade.requesting || videoOn) return;
    _setUpgrade(VideoUpgrade.switching);
    if (!await _openCamera()) {
      // they said yes but my camera can't start: stay on voice for both
      _setUpgrade(VideoUpgrade.none);
      await signaling
          .signal(callId!, 'video_off', const {})
          .catchError((Object e) => callLog('call_controller#26', e));
      return;
    }
    await _enterVideoMode();
    if (outgoing) await _renegotiate();
  }

  void _onVideoDeclined(String reason) {
    if (upgrade != VideoUpgrade.requesting) return;
    _setUpgrade(VideoUpgrade.none);
    _notify(switch (reason) {
      'timeout' => CallNotice.videoNoAnswer,
      'camera' => CallNotice.videoFailed,
      _ => CallNotice.videoDeclined,
    });
  }

  Future<bool> _openCamera() async {
    try {
      await media.startVideo();
      return true;
    } on MediaOpenException catch (e) {
      log.add('camera-open-failed:${e.denied}');
      _notify(CallNotice.cameraBlocked);
      return false;
    } catch (e) {
      callLog('call_controller#27', e);
      _notify(CallNotice.cameraBlocked);
      return false;
    }
  }

  Future<void> _enterVideoMode() async {
    videoOn = true;
    cameraOn = true;
    frontCamera = true;
    // a video call plays on the speaker (or the headset), like WhatsApp
    if (route == AudioRoute.earpiece) {
      speakerOn = true;
      route = AudioRoute.speaker;
      try {
        await media.setSpeaker(true);
      } catch (e) {
        callLog('call_controller#28', e);
      }
    }
    unawaited(sounds.setProximity(false));
    log.add('video-mode:on');
    notifyListeners();
    unawaited(_sendMediaState());
  }

  /// The CALLER renegotiates (it is the only offerer — no glare). The callee
  /// asks the caller with `reneg_request`.
  Future<void> _renegotiateOrAsk() async {
    if (outgoing) {
      await _renegotiate();
    } else {
      try {
        await signaling.signal(callId!, 'reneg_request', const {});
      } catch (e) {
        callLog('call_controller#29', e);
      }
    }
  }

  Future<void> _renegotiate() async {
    final id = callId;
    if (id == null || isEnded) return;
    try {
      final offer = await media.createOffer();
      await signaling.signal(id, 'reneg_offer', offer);
      log.add('reneg_offer-sent');
    } catch (e) {
      log.add('reneg-failed:$e');
      await _videoFailedBackToVoice();
      return;
    }
    _renegTimer?.cancel();
    _renegTimer = Timer(renegTimeout, () {
      _renegTimer = null;
      if (isEnded) return;
      log.add('reneg-timeout');
      unawaited(_videoFailedBackToVoice());
    });
  }

  Future<void> _videoFailedBackToVoice() async {
    if (isEnded) return;
    _setUpgrade(VideoUpgrade.none);
    await _leaveVideoMode();
    _notify(CallNotice.videoFailed);
    try {
      await signaling.signal(callId!, 'video_off', const {});
    } catch (e) {
      callLog('call_controller#30', e);
    }
  }

  Future<void> _leaveVideoMode() async {
    if (!videoOn) return;
    videoOn = false;
    cameraOn = false;
    remoteCameraOn = true;
    try {
      await media.stopVideo();
    } catch (e) {
      callLog('call_controller#31', e);
    }
    log.add('video-mode:off');
    notifyListeners();
  }

  /// "Switch to voice": instant, for BOTH people (no question asked).
  Future<void> switchToVoice() async {
    if (!videoOn || isEnded) return;
    _renegTimer?.cancel();
    _renegTimer = null;
    _setUpgrade(VideoUpgrade.none);
    await _leaveVideoMode();
    try {
      await signaling.signal(callId!, 'video_off', const {});
    } catch (e) {
      callLog('call_controller#32', e);
    }
    unawaited(_sendMediaState());
  }

  Future<void> _onRemoteVideoOff() async {
    _renegTimer?.cancel();
    _renegTimer = null;
    final was = videoOn || upgrade != VideoUpgrade.none;
    _setUpgrade(VideoUpgrade.none);
    await _leaveVideoMode();
    if (was) _notify(CallNotice.remoteSwitchedToVoice);
  }

  /// The red button. Before connect: caller cancels; callee hangs up.
  Future<void> hangup() => _hangupWith(
      isLive || !outgoing ? 'hangup' : 'cancel', CallEndReason.hangup);

  Future<void> _hangupWith(String event, CallEndReason reason) async {
    if (isEnded) return;
    final id = callId;
    // A1-h: tell the server FIRST (the other phone ends within one poll),
    // then release our media.
    final told = id == null
        ? Future<void>.value()
        : signaling.event(id, event).then<void>((_) {}, onError: (Object e) {
            callLog('call_controller#10', e);
          });
    await _finish(reason, tone: event == 'fail');
    await told;
  }

  Future<void> _finish(CallEndReason reason, {bool tone = true}) async {
    if (phase == CallPhase.ended) return;
    endReason = reason;
    phase = CallPhase.ended;
    endedAt = now();
    log.add('ended:${reason.name}');
    _stopTimers();
    signaling.setFast(false);
    try {
      await sounds.stopAll();
      await sounds.setProximity(false);
    } catch (e) {
      callLog('call_controller#11', e);
    }
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
    } catch (e) {
      callLog('call_controller#12', e);
    }
  }

  void _stopTimers() {
    _upgradeTimer?.cancel();
    _renegTimer?.cancel();
    _restartTimer?.cancel();
    _connectTimer?.cancel();
    _statusTimer?.cancel();
    _statsTimer?.cancel();
    _reconnectTimer?.cancel();
    _giveUpTimer?.cancel();
    _evSub?.cancel();
    _evSub = null;
    _netSub?.cancel();
    _netSub = null;
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
