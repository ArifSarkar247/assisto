import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../calls/api_call_signaling.dart';
import '../calls/call_avatar.dart';
import '../calls/call_controller.dart';
import '../calls/call_keepalive.dart';
import '../calls/call_native.dart';
import '../calls/call_runtime.dart';
import '../calls/call_video.dart';
import '../calls/webrtc_media.dart' deferred as rtc;
import '../l10n/app_localizations.dart';
import '../push/lock_screen_guard.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/robo_id.dart';
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

  const CircleCallScreen({
    super.key,
    required this.member,
    required this.kind,
    this.outgoing = true,
    this.callId,
    this.controller,
    this.surface,
  });

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
  bool _beginning = false;
  bool _claimed = false;

  /// Direction of the CURRENT controller: an incoming call that failed can
  /// be called back ("Call again" places a new outgoing call).
  late bool _outgoing = widget.outgoing;

  bool get _isVideo => widget.kind == 'video';
  String get _name => '${widget.member['name'] ?? ''}';
  String get _photo =>
      '${widget.member['photo_url'] ?? widget.member['photo'] ?? widget.member['caller_photo'] ?? ''}';
  String get _photoV => '${widget.member['photo_v'] ?? ''}';
  AppLocalizations get _t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    CallNative.inPip.addListener(_onPip);
    if (widget.controller != null) {
      _attach(widget.controller!, widget.surface, initial: true);
    } else {
      _owns = true;
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

  Future<void> _beginOnce() async {
    final app = context.read<AppState>();
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
      video: _isVideo,
      outgoing: _outgoing,
      memberId: widget.member['id'] as int?,
      callId: _outgoing ? null : widget.callId,
    );
    _attach(c, media is CallVideoSurface ? media as CallVideoSurface : null);
    if (_isVideo) unawaited(CallNative.keepScreenOn(true));
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
    if (!initial) setState(() {});
  }

  void _onChange() {
    final c = _c;
    if (c == null || !mounted) return;
    if (_owns) {
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
            text: t.c2CallOngoingText));
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
    Navigator.of(context).maybePop();
  }

  @override
  void dispose() {
    CallNative.inPip.removeListener(_onPip);
    _ticker?.cancel();
    _autoClose?.cancel();
    _surface?.hasRemoteVideo.removeListener(_onChange);
    final c = _c;
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
        return endReasonLabel(t, c.endReason, outgoing: c.outgoing);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) LockScreenGuard.release();
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
        body: Center(child: remoteVideo ? surface.remoteView() : _avatar(40)),
      );
    }
    final showSelf =
        _isVideo && c != null && c.cameraOn && !c.isEnded && surface != null;
    return Scaffold(
      backgroundColor: Brand.ink,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (remoteVideo)
            Positioned.fill(child: surface.remoteView())
          else
            const DecoratedBox(
                decoration: BoxDecoration(gradient: Brand.heroDark)),
          if (remoteVideo)
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x99000000),
                      Color(0x00000000),
                      Color(0x00000000),
                      Color(0xB3000000)
                    ],
                    stops: [0, 0.25, 0.65, 1],
                  ),
                ),
              ),
            ),
          SafeArea(
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
                        style: TextStyle(
                            fontSize: 12,
                            color: Colors.white.withValues(alpha: 0.7))),
                  ),
                const Spacer(flex: 2),
                if (c == null || !c.isEnded) _controls(c),
              ],
            ),
          ),
          if (showSelf)
            Positioned(
              right: Gap.lg,
              top: MediaQuery.paddingOf(context).top + 64,
              width: 104,
              height: 150,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: ColoredBox(
                  color: Colors.black,
                  child: surface.localView(mirror: c.frontCamera),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _topBar(CallController? c) {
    final t = _t;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xs),
      child: Row(
        children: [
          if (_isVideo && _pipSupported && c != null && c.isLive)
            IconButton(
              key: const Key('call-pip'),
              tooltip: t.c2CallPip,
              color: Colors.white,
              icon: const Icon(Icons.picture_in_picture_alt_outlined),
              onPressed: () => CallNative.enterPip(w: 9, h: 16),
            )
          else
            const SizedBox(width: 48),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.lock_outline,
                    size: 13, color: Colors.white.withValues(alpha: 0.7)),
                const SizedBox(width: Gap.xs),
                Flexible(
                  child: Text(t.c2CallEncrypted,
                      maxLines: 2,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.7))),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 48,
            child: c != null && c.isLive ? _QualityBars(c.quality) : null,
          ),
        ],
      ),
    );
  }

  Widget _avatar(double r) =>
      CallAvatar(name: _name, photoUrl: _photo, version: _photoV, radius: r);

  Widget _nameAndStatus(CallController? c) {
    final ended = c?.isEnded ?? false;
    final bad = c != null && ended && isFailureReason(c.endReason);
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
              style: const TextStyle(
                  fontSize: 26,
                  color: Colors.white,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.sm),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!ended)
                Icon(_isVideo ? Icons.videocam_outlined : Icons.call_outlined,
                    size: 16, color: Colors.white.withValues(alpha: 0.8)),
              if (bad)
                const Icon(Icons.error_outline,
                    size: 16, color: Color(0xFFFFB3BB)),
              const SizedBox(width: Gap.xs),
              Flexible(
                child: Text(_status(c),
                    key: const Key('call-status'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 16,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: bad
                            ? const Color(0xFFFFB3BB)
                            : Colors.white.withValues(alpha: 0.85))),
              ),
            ],
          ),
          if (c != null && c.phase == CallPhase.reconnecting)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text(_t.c2CallReconnectHint,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 12,
                      color: Colors.white.withValues(alpha: 0.7))),
            ),
          if (c != null && c.isLive && _isVideo && !c.remoteCameraOn)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text(_t.c2CallRemoteCameraOff,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 12,
                      color: Colors.white.withValues(alpha: 0.7))),
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
              icon: const Icon(Icons.settings_outlined),
              label: Text(t.c2CallOpenSettings),
              onPressed: () => openAppSettings(),
            ),
          if (canCallAgain(c, hasMember: widget.member['id'] is int))
            FilledButton.icon(
              key: const Key('call-again'),
              style: Brand.successButton(), // qa1: white on success was 3.4:1
              icon: Icon(_isVideo ? Icons.videocam : Icons.call),
              label: Text(t.c2CallAgain),
              onPressed: _retry,
            ),
          OutlinedButton(
            key: const Key('call-close'),
            style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: BorderSide(color: Colors.white.withValues(alpha: 0.5))),
            onPressed: _close,
            child: Text(t.close),
          ),
        ],
      ),
    );
  }

  Widget _controls(CallController? c) {
    final t = _t;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
                vertical: Gap.md, horizontal: Gap.sm),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(28),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _CtlButton(
                  key: const Key('call-speaker'),
                  icon: (c?.speakerOn ?? false)
                      ? Icons.volume_up
                      : Icons.phone_in_talk_outlined,
                  label: (c?.speakerOn ?? false)
                      ? t.circleCallSpeaker
                      : t.c2CallEarpiece,
                  active: c?.speakerOn ?? false,
                  onTap: c == null ? null : c.toggleSpeaker,
                ),
                if (_isVideo)
                  _CtlButton(
                    key: const Key('call-camera'),
                    icon: (c?.cameraOn ?? true)
                        ? Icons.videocam_outlined
                        : Icons.videocam_off_outlined,
                    label: t.circleCallCamera,
                    active: !(c?.cameraOn ?? true),
                    onTap: c == null ? null : c.toggleCamera,
                  ),
                if (_isVideo)
                  _CtlButton(
                    key: const Key('call-flip'),
                    icon: Icons.cameraswitch_outlined,
                    label: t.c2CallFlip,
                    active: false,
                    onTap: c == null || !c.cameraOn ? null : c.switchCamera,
                  ),
                _CtlButton(
                  key: const Key('call-mute'),
                  icon: (c?.muted ?? false) ? Icons.mic_off : Icons.mic_none,
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
                    child: Icon(Icons.call_end, color: Colors.white, size: 32)),
              ),
            ),
          ),
          ),
        ],
      ),
    );
  }

  /// The SERVER refused video for a free caller: upgrade / points path.
  Widget _gateScreen(ColorScheme scheme) => Scaffold(
        appBar: AppBar(title: Text(_t.circleCallVideoPremiumTitle)),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Gap.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.workspace_premium_outlined,
                    size: 56, color: scheme.primary),
                const SizedBox(height: Gap.lg),
                Text(_t.circleCallVideoPremiumTitle,
                    style: Theme.of(context).textTheme.titleLarge,
                    textAlign: TextAlign.center),
                const SizedBox(height: Gap.sm),
                Text(_t.circleCallVideoPremiumBody,
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
                const SizedBox(height: Gap.xl),
                FilledButton.icon(
                  icon: const Icon(Icons.workspace_premium),
                  label: Text(_t.circleCallGetPremium),
                  onPressed: () => Navigator.of(context).pop('upgrade'),
                ),
                const SizedBox(height: Gap.sm),
                OutlinedButton.icon(
                  icon: const Icon(Icons.redeem_outlined),
                  label: Text(_t.circleCallUnlockWithPoints),
                  onPressed: () => Navigator.of(context).pop('points'),
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
      return t.circleCallServerBusy;
    case CallEndReason.unavailable:
      return t.c2CallUnavailable;
    case CallEndReason.network:
      return t.c2CallNetwork;
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
      CallQuality.good => (const Color(0xFF5BD69A), 3, t.c2CallQualityGood),
      CallQuality.fair => (const Color(0xFFFFC857), 2, t.c2CallQualityFair),
      CallQuality.poor => (const Color(0xFFFF6B78), 1, t.c2CallQualityPoor),
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
                  borderRadius: BorderRadius.circular(2),
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
        ? Colors.white
        : Colors.white.withValues(alpha: enabled ? 0.16 : 0.06);
    final fg =
        active ? Brand.ink : Colors.white.withValues(alpha: enabled ? 1 : 0.45);
    return Expanded(
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
              style: TextStyle(
                  fontSize: 12, color: Colors.white.withValues(alpha: 0.85))),
        ],
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
}
