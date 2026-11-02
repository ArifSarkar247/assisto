import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../calls/api_call_signaling.dart';
import '../calls/call_avatar.dart';
import '../calls/call_controller.dart';
import '../calls/call_keepalive.dart';
import '../calls/call_launch.dart'; // calls-a
import '../calls/fullscreen_call_prompt.dart'; // play-fsi
import '../calls/call_native.dart';
import '../calls/call_runtime.dart';
import '../calls/call_video.dart';
import '../calls/video_stage.dart'; // cde-chat
import '../messaging/chat_decor/decor_store.dart';
import '../calls/webrtc_media.dart' deferred as rtc;
import '../l10n/app_localizations.dart';
import '../push/lock_screen_guard.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/robo_id.dart';
import '../widgets/paywall_sheet.dart'; // circle2
import 'referral_screen.dart'; // circle2
import 'package:assisto/widgets/app_sheet.dart';
import '../widgets/notif_models.dart' show notifLocalizeDigits; // qa1

/// My Circle 1:1 voice / video call — REAL media (c2-calls).
///
/// flutter_webrtc RTCPeerConnection + getUserMedia (mic; + camera for video),
/// ICE from GET /rtc/turn (our coturn: STUN + TURN with time-limited
/// credentials), signalling through our server's real-time queue. The phase
/// shown is the TRUE one ([CallController]): "Calling…" until the callee's
/// phone reports ringing, "Ringing…" (+ generated 425 Hz ringback), then
/// "Connecting…" after accept and "Connected" + timer ONLY when ICE really
/// connects. Any failure is shown as what it is — there is no fake path.
///
/// The video gate stays SERVER-SIDE (POST /circle/<id>/call runs
/// circle_calls.can_place_call); a free caller gets the upgrade screen.
class CircleCallScreen extends StatefulWidget {
  final Map<String, dynamic> member;

  /// 'voice' | 'video'.
  final String kind;

  /// true when THIS user placed the call.
  final bool outgoing;

  /// The ringing call to accept (incoming).
  final int? callId;

  /// Pre-built controller (gallery / widget tests). When given, the screen
  /// renders it and starts nothing itself.
  final CallController? controller;

  /// Optional video surface for [controller] (tests / gallery).
  final CallVideoSurface? surface;

  /// b1: re-opened from the minimized-call bar — this screen takes the LIVE
  /// [controller] back from [CallRuntime] and owns it again.
  final bool resumed;

  /// cde-chat gallery / tests: open the video stage swapped / full screen.
  final bool previewSwapped;
  final bool previewFullscreen;

  const CircleCallScreen({
    super.key,
    required this.member,
    required this.kind,
    this.outgoing = true,
    this.callId,
    this.controller,
    this.surface,
    this.resumed = false,
    this.previewSwapped = false,
    this.previewFullscreen = false,
  });

  /// circle2 test seam: the video gate's navigation ('voice' | 'video' |
  /// 'points') goes here instead of pushing real screens.
  @visibleForTesting
  static void Function(String action)? debugGateAction;

  /// b1: how the mini call bar re-opens a minimized call.
  static void registerReopen() {
    // calls-a: back to the full call INSTANTLY (no zoom snapshot of the
    // live video texture)
    CallRuntime.instance.reopenCall ??= (nav, o) => nav.push(instantCallRoute<void>(
        (_) => CircleCallScreen(
            member: o.member,
            kind: o.kind,
            outgoing: o.controller.outgoing,
            callId: o.controller.callId,
            controller: o.controller,
            surface: o.surface,
            resumed: true),
        name: CallLaunchRouter.acceptRouteName));
  }

  @override
  State<CircleCallScreen> createState() => _CircleCallScreenState();
}

class _CircleCallScreenState extends State<CircleCallScreen> {
  CallController? _c;
  CallVideoSurface? _surface;
  bool _owns = false;
  Timer? _ticker;
  Timer? _autoClose;
  bool _pip = false;
  bool _pipSupported = false;
  bool _closed = false;
  late bool _full = widget.previewFullscreen; // cde-chat: double-tap
  bool _beginning = false;
  bool _claimed = false;

  /// b1: the live call went to the mini bar (minimized) — this screen must
  /// not hang it up or stop its foreground service when it is disposed.
  bool _handedOff = false;
  int _noticeSeq = 0;
  CallNotice _noticeShown = CallNotice.none;
  Timer? _noticeTimer;
  bool? _screenOnSent;

  /// Direction of the CURRENT controller: an incoming call that failed can
  /// be called back ("Call again" places a new outgoing call).
  late bool _outgoing = widget.outgoing;

  /// How the call STARTED (the controller is created with this).
  bool get _startsVideo => widget.kind == 'video';

  /// b1: the call is in VIDEO mode right now (voice <-> video switch).
  bool get _isVideo => _c?.videoOn ?? _startsVideo;
  // cde-chat: the chat's nickname first (the real name stays in contact info)
  String get _name {
    final nick = '${widget.member['nickname'] ?? ''}'.trim();
    if (nick.isNotEmpty) return nick;
    final real = '${widget.member['name'] ?? ''}';
    final id = widget.member['id'];
    return id == null ? real : DecorStore.instance.peerName('member:$id', real);
  }
  String get _photo =>
      '${widget.member['photo_url'] ?? widget.member['photo'] ?? widget.member['caller_photo'] ?? ''}';
  String get _photoV => '${widget.member['photo_v'] ?? ''}';
  AppLocalizations get _t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    CallNative.inPip.addListener(_onPip);
    CircleCallScreen.registerReopen();
    if (widget.controller != null && widget.resumed) {
      // b1: back from the mini bar — own the live call again
      CallRuntime.instance.takeOngoing();
      _owns = true;
      CallRuntime.instance.acquireScreen(this, _screenLive);
      _noticeSeq = widget.controller!.noticeSeq; // no stale notice
      _attach(widget.controller!, widget.surface, initial: true);
      unawaited(CallNative.pipSupported().then((v) {
        if (mounted) setState(() => _pipSupported = v);
      }));
      WidgetsBinding.instance.addPostFrameCallback((_) => _onChange());
    } else if (widget.controller != null) {
      _attach(widget.controller!, widget.surface, initial: true);
    } else {
      _owns = true;
      final incomingId = widget.outgoing ? null : widget.callId;
      if (incomingId != null) {
        // calls-a: this phone is IN call [incomingId] from this frame on — a
        // resume check / real-time ring / second Accept for it never stacks a
        // ringing screen ("Call ended") over this one.
        CallLaunchRouter.instance.claim('$incomingId', CallLaunch.actionAccept);
        CallRuntime.instance.activeCallId ??= incomingId;
      }
      if (!CallRuntime.instance.acquireScreen(this, _screenLive)) {
        // another call screen is already live: never place a second call
        _owns = false;
        _duplicate = true;
        WidgetsBinding.instance.addPostFrameCallback((_) => _close());
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) => _begin());
    }
  }

  bool _duplicate = false;
  bool _screenLive() => mounted && !_closed && (_c == null || !_c!.isEnded);

  void _onPip() {
    if (mounted) setState(() => _pip = CallNative.inPip.value);
  }

  Future<void> _begin() async {
    // x1-calls: ONE controller start per screen / per "Call again" — a
    // rebuild, a route event or a second frame callback can never place a
    // second call.
    if (!mounted || _beginning || _c != null) return;
    _beginning = true;
    try {
      await _beginOnce();
    } finally {
      _beginning = false;
    }
  }

  /// calls-a: a cold-start Accept draws this screen on the FIRST frame,
  /// while AppState is still loading. The call needs only the session token
  /// (read from secure storage in the first few hundred ms) — never the
  /// profile sync behind `loading`, which could take seconds on mobile data.
  Future<bool> _sessionReady(AppState app) async {
    final until = DateTime.now().add(const Duration(seconds: 15));
    while (mounted) {
      final tok = app.api.token;
      if (tok != null && tok.isNotEmpty) return true;
      if (!app.loading) return app.loggedIn;
      if (DateTime.now().isAfter(until)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    return false;
  }

  Future<void> _beginOnce() async {
    final app = context.read<AppState>();
    if (!await _sessionReady(app)) {
      // signed out: nothing to answer with (the login screen shows)
      debugPrint('CALL_SCREEN closed reason=signed_out');
      if (CallRuntime.instance.activeCallId == widget.callId) {
        CallRuntime.instance.activeCallId = null;
      }
      _close();
      return;
    }
    if (!mounted) return;
    final transport = CallRuntime.instance.transportFor(app);
    CallMedia media;
    try {
      await rtc.loadLibrary();
      media = rtc.createWebRtcCallMedia();
    } catch (_) {
      media = _BrokenMedia();
    }
    if (!mounted) return;
    final c = CallController(
      media: media,
      signaling: ApiCallSignaling(app.api, transport),
      sounds: NativeCallSounds(),
      video: _startsVideo,
      outgoing: _outgoing,
      memberId: widget.member['id'] as int?,
      callId: _outgoing ? null : widget.callId,
      // calls-presence: Wi-Fi <-> mobile data -> "Reconnecting…" + ICE
      // restart at once; a setup step that failed after the silent retries
      // is reported for Owner Admin -> Call health (best effort, never awaited)
      networkEvents: CallNative.networkChanges(),
      onSetupFailure: (step, code, id) => unawaited(app.api.postJson(
          '/rtc/health', {
        'step': step,
        'code': code,
        if (id != null) 'call_id': id,
      }).then((_) {}, onError: (Object _) {})),
    );
    _attach(c, media is CallVideoSurface ? media as CallVideoSurface : null);
    if (_startsVideo) unawaited(CallNative.keepScreenOn(true));
    unawaited(CallNative.pipSupported().then((v) {
      if (mounted) setState(() => _pipSupported = v);
    }));
    await c.start();
  }

  void _attach(CallController c, CallVideoSurface? s, {bool initial = false}) {
    _c = c;
    _surface = s;
    c.addListener(_onChange);
    s?.hasRemoteVideo.addListener(_onChange);
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && (_c?.isLive ?? false)) setState(() {});
    });
    _syncNotice(c);
    if (!initial) setState(() {});
  }

  /// b1: show a NEW controller notice for a few seconds.
  void _syncNotice(CallController c) {
    if (c.noticeSeq == _noticeSeq) return;
    _noticeSeq = c.noticeSeq;
    _noticeShown = c.notice;
    _noticeTimer?.cancel();
    _noticeTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _noticeShown = CallNotice.none);
    });
  }

  /// b1: back / "Minimize" during a live call. A video call shrinks into
  /// picture-in-picture when the phone supports it; otherwise (and for voice)
  /// the call moves to the in-app bar and the user can use the app.
  Future<void> _minimizeOrPip() async {
    final c = _c;
    if (c == null || !c.isLive || !_owns) {
      _close();
      return;
    }
    // calls-a (owner: "use the app during a call, like WhatsApp"): back /
    // Minimize ALWAYS stays inside Assisto — voice -> the green bar, video ->
    // the green bar + a floating video window. System picture-in-picture is
    // only for LEAVING the app (Home / Recents: auto-enter).
    _handOff(c);
  }

  void _handOff(CallController c) {
    if (_handedOff || !mounted) return;
    _handedOff = true;
    _owns = false;
    c.removeListener(_onChange);
    CallRuntime.instance.releaseScreen(this);
    // calls-a: a locked phone goes back to its lock screen (the call keeps
    // running) — the app underneath never shows over the keyguard.
    LockScreenGuard.release();
    CallRuntime.instance.minimize(OngoingCall(
        controller: c,
        surface: _surface,
        member: widget.member,
        kind: widget.kind));
    _closed = true;
    _popSelf();
  }

  void _onChange() {
    final c = _c;
    if (c == null || !mounted) return;
    _syncNotice(c);
    if (_owns) {
      // b1: video mode keeps the screen on and allows Home -> PiP
      final screenOn = c.videoOn && !c.isEnded;
      if (_screenOnSent != screenOn) {
        _screenOnSent = screenOn;
        unawaited(CallNative.keepScreenOn(screenOn));
      }
      unawaited(
          CallNative.setAutoPip(_pipSupported && c.videoOn && c.isLive));
      if (c.callId != null && !c.isEnded) {
        CallRuntime.instance.activeCallId = c.callId;
        if (c.merged && !_claimed) {
          // glare merged into the peer's call: drop its ringing screen
          _claimed = true;
          CallRuntime.instance.claim('${c.callId}');
        }
      }
      // keep the mic alive if the user leaves the app mid-call
      if (c.phase == CallPhase.accepted || c.isLive) {
        final t = _t;
        unawaited(CallKeepAlive.start(
            channelName: t.c2ChOngoing,
            title: t.c2CallOngoingTitle(_name),
            text: t.c2CallOngoingText,
            hangupLabel: t.c2CallHangup,
            onHangup: () async {
              final cc = _c;
              if (cc != null) await cc.hangup();
            }));
      }
      if (c.isEnded) {
        if (CallRuntime.instance.activeCallId == c.callId) {
          CallRuntime.instance.activeCallId = null;
        }
        unawaited(CallNative.keepScreenOn(false));
        unawaited(CallKeepAlive.stop());
        if (c.endReason == CallEndReason.hangup) {
          _autoClose ??= Timer(const Duration(milliseconds: 1400), _close);
        }
      }
    }
    setState(() {});
  }

  void _close() {
    if (_closed || !mounted) return;
    _closed = true;
    _popSelf();
    // play-fsi: after an incoming call, ask once for full-screen calls
    if (!widget.outgoing) FullScreenCallPrompt.maybeShowAfterCall();
  }

  /// Pops THIS route even while its PopScope still says "can't pop" (the
  /// scope only guards the system back gesture during a live call).
  void _popSelf() {
    final route = ModalRoute.of(context);
    final nav = Navigator.of(context);
    if (route != null && route.isCurrent && nav.canPop()) {
      nav.pop();
    } else if (route != null && route.isActive && !route.isCurrent) {
      nav.removeRoute(route);
    } else {
      nav.maybePop();
    }
  }

  @override
  void dispose() {
    CallNative.inPip.removeListener(_onPip);
    _ticker?.cancel();
    _autoClose?.cancel();
    _noticeTimer?.cancel();
    _surface?.hasRemoteVideo.removeListener(_onChange);
    final c = _c;
    if (_handedOff) {
      // b1: the call lives on in the mini bar — nothing to stop here
      if (!_duplicate) LockScreenGuard.release();
      super.dispose();
      return;
    }
    if (_owns) unawaited(CallNative.setAutoPip(false));
    if (c != null) {
      c.removeListener(_onChange);
      if (_owns) {
        if (CallRuntime.instance.activeCallId == c.callId) {
          CallRuntime.instance.activeCallId = null;
        }
        c.dispose(); // hangs up if still live
      }
    }
    if (_owns) {
      unawaited(CallNative.keepScreenOn(false));
      unawaited(CallKeepAlive.stop());
    }
    CallRuntime.instance.releaseScreen(this);
    if (!_duplicate) LockScreenGuard.release();
    super.dispose();
  }

  void _retry() {
    final old = _c;
    old?.removeListener(_onChange);
    _surface?.hasRemoteVideo.removeListener(_onChange);
    _ticker?.cancel();
    _autoClose?.cancel();
    _autoClose = null;
    setState(() => _c = null);
    if (_owns) old?.dispose();
    _owns = true;
    _outgoing = true; // "Call again" always places a NEW call
    _claimed = false;
    _begin();
  }

  String _fmt(Duration d) {
    final s = d.inSeconds;
    String two(int n) => n.toString().padLeft(2, '0');
    final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
    final raw = h > 0 ? '$h:${two(m)}:${two(sec)}' : '${two(m)}:${two(sec)}';
    // qa1: the call timer in the UI's digits (Latin "04:07" in the Bangla UI)
    return mounted ? notifLocalizeDigits(context, raw) : raw;
  }

  String _status(CallController? c) {
    final t = _t;
    if (c == null) return t.c2CallStarting;
    switch (c.phase) {
      case CallPhase.starting:
        return t.c2CallStarting;
      case CallPhase.calling:
        return c.outgoing ? t.c2CallCalling : t.circleCallConnecting;
      case CallPhase.ringing:
        return c.outgoing ? t.c2CallRinging : t.circleCallConnecting;
      case CallPhase.accepted:
        return t.circleCallConnecting;
      case CallPhase.connected:
        return _fmt(c.elapsed);
      case CallPhase.reconnecting:
        return t.circleCallReconnecting;
      case CallPhase.ended:
        // wa-polish: a call that really connected ends with its talk time
        // ("Call ended · 04:07"), like WhatsApp's call-ended summary.
        final talk = c.talkTime;
        if (talk != null &&
            talk.inSeconds > 0 &&
            (c.endReason == CallEndReason.hangup ||
                c.endReason == CallEndReason.none)) {
          return t.waCallEndedAfter(_fmt(talk));
        }
        return endReasonLabel(t, c.endReason, outgoing: c.outgoing);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        // b1: back during a LIVE call never hangs up — it minimizes (PiP for
        // video, the in-app call bar otherwise), like WhatsApp.
        canPop: !(_owns && !_closed && (_c?.isLive ?? false)),
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) {
            LockScreenGuard.release();
          } else {
            unawaited(_minimizeOrPip());
          }
        },
        child: AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle.light,
          child: _body(context),
        ),
      );

  Widget _body(BuildContext context) {
    final c = _c;
    if (c != null && c.isEnded && c.endReason == CallEndReason.upgrade) {
      return _gateScreen(Theme.of(context).colorScheme);
    }
    final surface = _surface;
    final remoteVideo = _isVideo &&
        c != null &&
        c.isLive &&
        c.remoteCameraOn &&
        surface != null &&
        surface.hasRemoteVideo.value;
    if (_pip) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            Center(child: remoteVideo ? surface.remoteView() : _avatar(40)),
            if (c != null && c.isLive && !c.remoteMicOn)
              const Positioned(
                left: Gap.sm,
                bottom: Gap.sm,
                child: Icon(Icons.mic_off_rounded, color: CallInk.text, size: 20),
              ),
          ],
        ),
      );
    }
    final live = c != null && c.isLive;
    final showSelf = _isVideo && c != null && !c.isEnded && surface != null;
    final full = _full && showSelf;
    final dim = remoteVideo
        ? const Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      CallInk.scrimTop,
                      Colors.transparent,
                      Colors.transparent,
                      CallInk.scrimBottom
                    ],
                    stops: [0, 0.25, 0.65, 1],
                  ),
                ),
              ),
            ),
          )
        : null;
    final column = SafeArea(
      child: Column(
        children: [
          _topBar(c),
          const Spacer(),
          if (!remoteVideo) ...[
            _avatar(56),
            const SizedBox(height: Gap.lg),
          ],
          _nameAndStatus(c),
          if (c != null && c.isEnded) _endedActions(c),
          if (c != null &&
              !c.isEnded &&
              !c.turnAvailable &&
              c.phase != CallPhase.starting &&
              c.phase.index <= CallPhase.accepted.index)
            Padding(
              padding:
                  const EdgeInsets.fromLTRB(Gap.xl, Gap.md, Gap.xl, 0),
              child: Text(_t.c2CallNoRelay,
                  key: const Key('call-no-relay'),
                  textAlign: TextAlign.center,
                  style: AType.bodySmall.copyWith(color: CallInk.textHint)),
            ),
          const Spacer(flex: 2),
          if (live) _noticeBanner(c),
          if (live) _upgradeCard(c),
          if (c == null || !c.isEnded) _controls(c),
        ],
      ),
    );
    const gradient = DecoratedBox(decoration: BoxDecoration(gradient: Brand.heroDark));
    if (showSelf) {
      // cde-chat (order 6 C): swap / drag-to-corner / pinch-zoom /
      // double-tap full screen.
      final pad = MediaQuery.paddingOf(context);
      final t = _t;
      return Scaffold(
        backgroundColor: Brand.ink,
        body: VideoStage(
          key: const Key('call-video-stage'),
          remote: remoteVideo ? surface.remoteView() : gradient,
          local: c.cameraOn
              ? surface.localView(mirror: c.frontCamera)
              : Center(
                  key: const Key('call-self-camera-off'),
                  child: Semantics(
                    label: t.b1CallCameraOffSelf,
                    child: const Icon(Icons.videocam_off_rounded,
                        color: CallInk.textHint, size: 32),
                  ),
                ),
          canSwap: remoteVideo,
          initialSwapped: widget.previewSwapped,
          fullscreen: full,
          onToggleFullscreen: () => setState(() => _full = !_full),
          topInset: pad.top + (full ? Gap.lg : 64),
          bottomInset: pad.bottom + (full ? Gap.lg : 250),
          localLabel: t.cdeCallSwapHint,
          remoteLabel: t.cdeCallSwapHintRemote,
          bigLabel: t.cdeCallFullHint,
          overlay: full
              ? null
              : Stack(fit: StackFit.expand, children: [
                  if (dim != null) dim,
                  column,
                ]),
        ),
      );
    }
    return Scaffold(
      backgroundColor: Brand.ink,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (remoteVideo)
            Positioned.fill(child: surface.remoteView())
          else
            gradient,
          if (dim != null) dim,
          column,
        ],
      ),
    );
  }

  Widget _topBar(CallController? c) {
    final t = _t;
    final live = c != null && c.isLive;
    Widget lead;
    if (live && _owns) {
      // b1: keep talking while using the rest of the app
      lead = IconButton(
        key: const Key('call-minimize'),
        tooltip: t.b1CallMinimize,
        color: CallInk.text,
        icon: const Icon(Icons.keyboard_arrow_down_rounded),
        onPressed: () => _handOff(c),
      );
    } else {
      lead = const SizedBox(width: Gap.xxxl);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xs),
      child: Row(
        children: [
          lead,
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.lock_outline_rounded,
                    size: 14, color: CallInk.textHint),
                const SizedBox(width: Gap.xs),
                Flexible(
                  child: Text(t.c2CallEncrypted,
                      maxLines: 2,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: AType.bodySmall.copyWith(color: CallInk.textHint)),
                ),
              ],
            ),
          ),
          SizedBox(
            width: Gap.xxxl,
            child: live ? _QualityBars(c.quality) : null,
          ),
        ],
      ),
    );
  }

  Widget _avatar(double r) =>
      CallAvatar(name: _name, photoUrl: _photo, version: _photoV, radius: r);

  TextStyle get _hintStyle => AType.bodySmall.copyWith(color: CallInk.textHint);

  Widget _nameAndStatus(CallController? c) {
    final t = _t;
    final ended = c?.isEnded ?? false;
    final bad = c != null && ended && isFailureReason(c.endReason);
    final live = c != null && c.isLive;
    final q = c?.quality ?? CallQuality.unknown;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_name,
              key: const Key('call-name'),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AType.headlineMedium
                  .copyWith(color: CallInk.text, fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.sm),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!ended)
                Icon(_isVideo ? Icons.videocam_rounded : Icons.call_rounded,
                    size: 16, color: CallInk.textSoft),
              if (bad)
                const Icon(Icons.error_outline_rounded,
                    size: 16, color: CallInk.failure),
              const SizedBox(width: Gap.xs),
              Flexible(
                child: Text(_status(c),
                    key: const Key('call-status'),
                    textAlign: TextAlign.center,
                    // the live timer: tabular figures so it never jitters
                    style: AType.bodyLarge.copyWith(
                        fontFeatures: AFonts.tabular,
                        color: bad ? CallInk.failure : CallInk.textSoft)),
              ),
            ],
          ),
          if (c != null && c.phase == CallPhase.reconnecting)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text(t.c2CallReconnectHint,
                  key: const Key('call-reconnect-hint'),
                  textAlign: TextAlign.center,
                  style: _hintStyle),
            ),
          // b1: short quality text when the network is weak (bars always)
          if (live &&
              c.phase == CallPhase.connected &&
              (q == CallQuality.fair || q == CallQuality.poor))
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text(
                  q == CallQuality.poor
                      ? t.c2CallQualityPoor
                      : t.c2CallQualityFair,
                  key: const Key('call-quality-text'),
                  textAlign: TextAlign.center,
                  style: _hintStyle),
            ),
          if (live && kDebugMode)
            Text(c.relayed ? t.b1CallDebugRelay : t.b1CallDebugDirect,
                key: const Key('call-debug-path'),
                style: _hintStyle.merge(AType.labelSmall)),
          if (live && _isVideo && !c.remoteCameraOn)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: _badge(Icons.videocam_off_rounded,
                  t.c2CallRemoteCameraOff, const Key('call-remote-camera-off')),
            ),
          if (live && !c.remoteMicOn)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: _badge(Icons.mic_off_rounded, t.b1CallRemoteMuted(_name),
                  const Key('call-remote-muted')),
            ),
        ],
      ),
    );
  }

  Widget _badge(IconData icon, String text, Key key) => Container(
        key: key,
        padding:
            const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
        decoration: BoxDecoration(
          color: CallInk.chip,
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: CallInk.text),
            const SizedBox(width: Gap.xs),
            Flexible(
              child: Text(text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AType.bodySmall.copyWith(color: CallInk.text)),
            ),
          ],
        ),
      );

  /// b1: the honest one-line notice (declined, no answer, camera, …).
  Widget _noticeBanner(CallController c) {
    final t = _t;
    final String? text = switch (_noticeShown) {
      CallNotice.none => null,
      CallNotice.videoDeclined => t.b1CallNoticeDeclined(_name),
      CallNotice.videoNoAnswer => t.b1CallNoticeNoAnswer,
      CallNotice.videoFailed => t.b1CallNoticeVideoFailed,
      CallNotice.videoPremium => t.b1CallNoticePremium,
      CallNotice.cameraBlocked => t.b1CallNoticeCamera,
      CallNotice.remoteSwitchedToVoice => t.b1CallNoticeRemoteVoice(_name),
      CallNotice.reconnected => t.b1CallNoticeReconnected,
    };
    if (text == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.md),
      child: Semantics(
        liveRegion: true,
        child: Container(
          key: const Key('call-notice'),
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
              horizontal: Gap.md, vertical: Gap.sm),
          decoration: BoxDecoration(
            color: CallInk.notice,
            borderRadius: BorderRadius.circular(Radii.lg),
          ),
          child: Text(text,
              textAlign: TextAlign.center,
              style: AType.bodyMedium.copyWith(color: CallInk.text)),
        ),
      ),
    );
  }

  /// b1: voice -> video request states (incoming prompt / waiting).
  Widget _upgradeCard(CallController c) {
    final t = _t;
    switch (c.upgrade) {
      case VideoUpgrade.none:
        return const SizedBox.shrink();
      case VideoUpgrade.switching:
        return Padding(
          padding: const EdgeInsets.only(bottom: Gap.md),
          child: Text(t.b1CallVideoSwitching,
              key: const Key('call-video-switching'),
              textAlign: TextAlign.center,
              style: _hintStyle.merge(AType.bodyMedium)),
        );
      case VideoUpgrade.requesting:
        return Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.md),
          child: Row(
            key: const Key('call-video-waiting'),
            children: [
              const SizedBox(
                  width: Gap.lg,
                  height: Gap.lg,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: CallInk.text)),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(t.b1CallVideoWaiting(_name),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: AType.bodyMedium.copyWith(color: CallInk.text)),
              ),
              TextButton(
                key: const Key('call-video-cancel'),
                style: TextButton.styleFrom(foregroundColor: CallInk.text),
                onPressed: c.cancelVideoRequest,
                child: Text(t.b1CallVideoCancel),
              ),
            ],
          ),
        );
      case VideoUpgrade.incoming:
        return Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.md),
          child: Container(
            key: const Key('call-video-prompt'),
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(
              color: CallInk.glassHigh,
              borderRadius: BorderRadius.circular(Radii.xl),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Icon(Icons.videocam_rounded, color: CallInk.text),
                    const SizedBox(width: Gap.sm),
                    Expanded(
                      child: Text(t.b1CallVideoAsk(_name),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: AType.titleMedium.copyWith(
                              color: CallInk.text,
                              fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
                const SizedBox(height: Gap.sm),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: Gap.sm,
                  runSpacing: Gap.xs,
                  children: [
                    OutlinedButton(
                      key: const Key('call-video-decline'),
                      style: OutlinedButton.styleFrom(
                          foregroundColor: CallInk.text,
                          side: const BorderSide(color: CallInk.textHint)),
                      onPressed: c.declineVideo,
                      child: Text(t.b1CallVideoNotNow),
                    ),
                    FilledButton.icon(
                      key: const Key('call-video-accept'),
                      style: Brand.successButton(),
                      icon: const Icon(Icons.videocam_rounded),
                      onPressed: c.acceptVideo,
                      label: Text(t.b1CallVideoAccept),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
    }
  }

  IconData _routeIcon(AudioRoute r) => switch (r) {
        AudioRoute.earpiece => Icons.phone_in_talk_rounded,
        AudioRoute.speaker => Icons.volume_up_rounded,
        AudioRoute.bluetooth => Icons.bluetooth_audio_rounded,
        AudioRoute.wired => Icons.headphones_rounded,
      };

  String _routeLabel(AudioRoute r) => switch (r) {
        AudioRoute.earpiece => _t.c2CallEarpiece,
        AudioRoute.speaker => _t.circleCallSpeaker,
        AudioRoute.bluetooth => _t.b1CallRouteBluetooth,
        AudioRoute.wired => _t.b1CallRouteWired,
      };

  /// b1: Bluetooth / wired headset connected -> a picker; otherwise the
  /// classic earpiece <-> speaker toggle.
  Future<void> _onRouteTap(CallController c) async {
    final routes = await c.refreshRoutes();
    if (!mounted) return;
    final extra = routes
        .any((r) => r == AudioRoute.bluetooth || r == AudioRoute.wired);
    if (!extra) {
      await c.toggleSpeaker();
      return;
    }
    final picked = await showAppSheet<AudioRoute>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
              child: Text(_t.b1CallRouteTitle,
                  style: Theme.of(ctx).textTheme.titleMedium),
            ),
            for (final r in routes)
              ListTile(
                key: Key('call-route-${r.name}'),
                leading: Icon(_routeIcon(r)),
                title: Text(_routeLabel(r)),
                trailing: r == c.route ? const Icon(Icons.check_rounded) : null,
                onTap: () => Navigator.of(ctx).pop(r),
              ),
          ],
        ),
      ),
    );
    if (picked != null) await c.setRoute(picked);
  }

  Widget _controls(CallController? c) {
    final t = _t;
    final live = c != null && c.isLive;
    final route = c?.route ??
        (_startsVideo ? AudioRoute.speaker : AudioRoute.earpiece);
    final waitingVideo = c != null && c.upgrade != VideoUpgrade.none;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
                vertical: Gap.md, horizontal: Gap.sm),
            decoration: BoxDecoration(
              color: CallInk.glass,
              borderRadius: BorderRadius.circular(Radii.xl),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _CtlButton(
                  key: const Key('call-speaker'),
                  icon: _routeIcon(route),
                  label: _routeLabel(route),
                  active: route != AudioRoute.earpiece,
                  onTap: c == null ? null : () => unawaited(_onRouteTap(c)),
                ),
                if (_isVideo)
                  _CtlButton(
                    key: const Key('call-camera'),
                    icon: (c?.cameraOn ?? true)
                        ? Icons.videocam_rounded
                        : Icons.videocam_off_rounded,
                    label: t.circleCallCamera,
                    active: !(c?.cameraOn ?? true),
                    onTap: c == null ? null : c.toggleCamera,
                  ),
                if (_isVideo)
                  _CtlButton(
                    key: const Key('call-flip'),
                    icon: Icons.cameraswitch_rounded,
                    label: t.c2CallFlip,
                    active: false,
                    onTap: c == null || !c.cameraOn ? null : c.switchCamera,
                  ),
                // b1: voice -> video (asks the other person) / video -> voice
                if (!_isVideo && live)
                  _CtlButton(
                    key: const Key('call-to-video'),
                    icon: Icons.videocam_rounded,
                    label: t.b1CallToVideo,
                    active: waitingVideo,
                    onTap: waitingVideo ? null : c.requestVideo,
                  ),
                if (_isVideo && live)
                  _CtlButton(
                    key: const Key('call-to-voice'),
                    icon: Icons.phone_rounded,
                    label: t.b1CallToVoice,
                    active: false,
                    onTap: c.switchToVoice,
                  ),
                _CtlButton(
                  key: const Key('call-mute'),
                  icon: (c?.muted ?? false) ? Icons.mic_off_rounded : Icons.mic_none_rounded,
                  label: t.circleCallMute,
                  active: c?.muted ?? false,
                  onTap: c == null ? null : c.toggleMute,
                ),
              ],
            ),
          ),
          const SizedBox(height: Gap.lg),
          RoboId(id: 'tl_call_hangup', // tl1: Test Lab Robo target
            child: Semantics(
            button: true,
            label: t.c2CallHangup,
            child: Material(
              color: Brand.danger,
              shape: const CircleBorder(),
              child: InkWell(
                key: const Key('call-hangup'),
                customBorder: const CircleBorder(),
                onTap: () async {
                  final cc = _c;
                  if (cc != null) await cc.hangup();
                  _close();
                },
                child: const SizedBox(
                    width: 68,
                    height: 68,
                    child: Icon(Icons.call_end_rounded, color: CallInk.text, size: 32)),
              ),
            ),
          ),
          ),
        ],
      ),
    );
  }

  Widget _endedActions(CallController c) {
    final t = _t;
    final denied = c.endReason == CallEndReason.mediaDenied;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.xl, Gap.lg, 0),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: Gap.md,
        runSpacing: Gap.sm,
        children: [
          if (denied)
            FilledButton.tonalIcon(
              icon: const Icon(Icons.settings_rounded),
              label: Text(t.c2CallOpenSettings),
              onPressed: () => openAppSettings(),
            ),
          if (canCallAgain(c, hasMember: widget.member['id'] is int))
            FilledButton.icon(
              key: const Key('call-again'),
              style: Brand.successButton(), // qa1: white on success was 3.4:1
              icon: Icon(_startsVideo ? Icons.videocam_rounded : Icons.call_rounded),
              label: Text(t.c2CallAgain),
              onPressed: _retry,
            ),
          OutlinedButton(
            key: const Key('call-close'),
            style: OutlinedButton.styleFrom(
                foregroundColor: CallInk.text,
                side: const BorderSide(color: CallInk.textHint)),
            onPressed: _close,
            child: Text(t.close),
          ),
        ],
      ),
    );
  }

  /// The SERVER refused video for a free caller: an HONEST paywall moment.
  ///
  /// circle2 (owner checklist "dead buttons"): "Get Premium" and "Unlock
  /// with points" used to pop('upgrade') / pop('points') — and no caller read
  /// the result, so both buttons just closed the screen. Now: who pays (only
  /// the caller), the free alternative one tap away (voice call to the same
  /// person), the real price + free trial (PaywallSheet, server offer), and
  /// the points screen. The video RULE is unchanged (owner decision).
  Widget _gateScreen(ColorScheme scheme) => Scaffold(
        appBar: AppBar(title: Text(_t.circleCallVideoPremiumTitle)),
        body: Center(
          child: SingleChildScrollView(
            padding: withNavBarInset(context, const EdgeInsets.all(Gap.xl)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.workspace_premium_rounded,
                    size: 56, color: scheme.primary),
                const SizedBox(height: Gap.lg),
                Text(_t.circleCallVideoPremiumTitle,
                    style: Theme.of(context).textTheme.titleLarge,
                    textAlign: TextAlign.center),
                const SizedBox(height: Gap.sm),
                Text(_t.circleCallVideoPremiumBody,
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant)),
                const SizedBox(height: Gap.sm),
                Text(_t.circle2VideoWhoPays(_name),
                    key: const Key('circle2-gate-who-pays'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: scheme.onSurface, height: 1.4)),
                const SizedBox(height: Gap.xl),
                // the free path first: the person still gets their call
                FilledButton.icon(
                  key: const Key('circle2-gate-voice'),
                  style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52)),
                  icon: const Icon(Icons.call_rounded),
                  label: Text(_t.circle2VoiceInstead),
                  onPressed: () => _redial('voice'),
                ),
                const SizedBox(height: Gap.sm),
                OutlinedButton.icon(
                  key: const Key('circle2-gate-premium'),
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48)),
                  icon: const Icon(Icons.workspace_premium_rounded),
                  label: Text(_t.circleCallGetPremium),
                  onPressed: _openPremium,
                ),
                const SizedBox(height: Gap.sm),
                OutlinedButton.icon(
                  key: const Key('circle2-gate-points'),
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48)),
                  icon: const Icon(Icons.redeem_rounded),
                  label: Text(_t.circleCallUnlockWithPoints),
                  onPressed: _openPoints,
                ),
                const SizedBox(height: Gap.md),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(_t.close),
                ),
              ],
            ),
          ),
        ),
      );

  /// circle2: place a NEW call to the same person (this screen's call ended
  /// at the gate, so nothing live is replaced).
  void _redial(String kind) {
    final seam = CircleCallScreen.debugGateAction;
    if (seam != null) return seam(kind);
    Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => CircleCallScreen(
            member: widget.member, kind: kind, outgoing: true)));
  }

  void _openPoints() {
    final seam = CircleCallScreen.debugGateAction;
    if (seam != null) return seam('points');
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ReferralScreen()));
  }

  /// circle2: the real offer (price, yearly saving, one free trial) — a
  /// started trial unlocks video at once, so try the video call again.
  Future<void> _openPremium() async {
    final started = await PaywallSheet.show(context, PaywallReason.videoCall);
    if (started == true && mounted) _redial('video');
  }
}

/// A failure the user should notice (red status), vs a normal outcome.
bool isFailureReason(CallEndReason r) => const {
      CallEndReason.failed,
      CallEndReason.connectFailed,
      CallEndReason.lost,
      CallEndReason.mediaDenied,
      CallEndReason.mediaError,
      CallEndReason.serverBusy,
      CallEndReason.network,
      CallEndReason.serverError,
    }.contains(r);

/// "Call again" (A1-d): the caller after any unsuccessful end; the callee
/// too when the call could not connect / dropped (calls the person back).
bool canCallAgain(CallController c, {required bool hasMember}) {
  if (!hasMember || c.endReason == CallEndReason.hangup) return false;
  if (c.outgoing) return true;
  return const {
    CallEndReason.connectFailed,
    CallEndReason.failed,
    CallEndReason.lost,
    CallEndReason.network,
    CallEndReason.serverError,
  }.contains(c.endReason);
}

String endReasonLabel(AppLocalizations t, CallEndReason r,
    {required bool outgoing}) {
  switch (r) {
    case CallEndReason.noAnswer:
      return outgoing ? t.c2CallNoAnswer : t.c2CallMissed;
    case CallEndReason.busy:
      return outgoing ? t.c2CallBusy : t.c2CallMissed;
    case CallEndReason.declined:
      return t.c2CallDeclined;
    case CallEndReason.offline:
      return outgoing ? t.c2CallOffline : t.c2CallMissed;
    case CallEndReason.canceled:
      return outgoing ? t.c2CallCanceled : t.c2CallMissed;
    case CallEndReason.failed:
      return t.c2CallFailedMedia;
    case CallEndReason.connectFailed:
      return t.x1CallConnectFailed;
    case CallEndReason.lost:
      return t.c2CallLost;
    case CallEndReason.mediaDenied:
      return t.c2CallPermission;
    case CallEndReason.mediaError:
      return t.c2CallMediaError;
    case CallEndReason.serverBusy:
      // calls-presence: only after 3 silent tries — honest "server problem"
      return t.cpCallServerProblem;
    case CallEndReason.unavailable:
      return t.c2CallUnavailable;
    case CallEndReason.network:
      // calls-presence: no answer from our server after 3 silent tries
      return t.cpCallWeakNetwork;
    case CallEndReason.serverError:
      return t.cpCallServerProblem; // 5xx after the silent retries
    case CallEndReason.upgrade:
      return t.circleCallVideoPremiumTitle;
    case CallEndReason.hangup:
    case CallEndReason.none:
      return t.circleCallEnded;
  }
}

class _QualityBars extends StatelessWidget {
  const _QualityBars(this.q);
  final CallQuality q;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final (Color color, int bars, String label) = switch (q) {
      CallQuality.good => (CallInk.good, 3, t.c2CallQualityGood),
      CallQuality.fair => (CallInk.fair, 2, t.c2CallQualityFair),
      CallQuality.poor => (CallInk.poor, 1, t.c2CallQualityPoor),
      CallQuality.unknown => (Colors.white54, 0, ''),
    };
    if (bars == 0) return const SizedBox.shrink();
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        child: Row(
          key: Key('call-quality-${q.name}'),
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var i = 0; i < 3; i++)
              Container(
                width: 4,
                height: 6.0 + i * 4,
                margin: const EdgeInsets.symmetric(horizontal: 1),
                decoration: BoxDecoration(
                  color: i < bars ? color : Colors.white24,
                  borderRadius: BorderRadius.circular(Gap.xxs),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CtlButton extends StatelessWidget {
  const _CtlButton({
    super.key,
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final bg = active
        ? CallInk.text
        : CallInk.text.withValues(alpha: enabled ? 0.16 : 0.06);
    final fg =
        active ? Brand.ink : CallInk.text.withValues(alpha: enabled ? 1 : 0.45);
    return Expanded(
      // b1: the label is part of the tap target too (2-line labels at 1.5x)
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            button: true,
            toggled: active,
            label: label,
            child: Material(
              color: bg,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onTap,
                child: SizedBox(
                    width: 52, height: 52, child: Icon(icon, color: fg)),
              ),
            ),
          ),
          const SizedBox(height: Gap.xs),
          Text(label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AType.bodySmall.copyWith(color: CallInk.textSoft)),
        ],
      ),
      ),
    );
  }
}

/// Used only if the WebRTC library can't load: every call fails honestly.
class _BrokenMedia implements CallMedia {
  @override
  Future<void> open({required bool video}) async =>
      throw MediaOpenException(false, 'webrtc unavailable');
  @override
  Future<void> createPeer(List<Map<String, dynamic>> iceServers) async =>
      throw StateError('webrtc unavailable');
  @override
  Future<Map<String, dynamic>> createOffer({bool iceRestart = false}) async =>
      throw StateError('webrtc unavailable');
  @override
  Future<Map<String, dynamic>> acceptOffer(Map<String, dynamic> offer) async =>
      throw StateError('webrtc unavailable');
  @override
  Future<void> setAnswer(Map<String, dynamic> answer) async {}
  @override
  Future<void> addCandidate(Map<String, dynamic> c) async {}
  @override
  Stream<Map<String, dynamic>> get localCandidates => const Stream.empty();
  @override
  Stream<MediaLinkState> get linkState => const Stream.empty();
  @override
  Future<void> setMuted(bool muted) async {}
  @override
  Future<void> setCameraEnabled(bool on) async {}
  @override
  Future<void> switchCamera() async {}
  @override
  Future<void> setSpeaker(bool on) async {}
  @override
  Future<MediaStats> stats() async => const MediaStats();
  @override
  Future<void> dispose() async {}
  @override
  bool get cameraUnavailable => true;
  @override
  Future<void> startVideo() async =>
      throw MediaOpenException(false, 'webrtc unavailable');
  @override
  Future<void> stopVideo() async {}
  @override
  Future<List<AudioRoute>> audioRoutes() async => const [];
  @override
  Future<void> setAudioRoute(AudioRoute r) async {}
}
