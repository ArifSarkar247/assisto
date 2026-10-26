import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../widgets/notif_models.dart' show notifLocalizeDigits;
import 'call_avatar.dart';
import 'call_controller.dart';
import 'call_native.dart';
import 'call_runtime.dart';

/// b1-calls + calls-a: WhatsApp-style "use Assisto during a call".
/// Wraps the whole app (MaterialApp.builder), so it is on EVERY screen —
/// home v2, the old home, My Circle chats, every feature:
///  * the green "tap to return to the call" bar at the top (its text sits
///    below the status bar; the green runs behind it like WhatsApp);
///  * a VIDEO call also floats as a small draggable video window over the
///    app (tap -> the full call);
///  * in Android picture-in-picture (the user left Assisto during a video
///    call) the whole window shows just the call's video.
/// With no minimized call it is just [child]. The widget tree keeps the same
/// shape either way, so the Navigator below never loses its state (and the
/// call's controller lives in [CallRuntime], never in a route).
class CallMiniBarHost extends StatelessWidget {
  const CallMiniBarHost({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<OngoingCall?>(
        valueListenable: CallRuntime.instance.ongoing,
        builder: (context, o, _) {
          final show = o != null && !o.controller.isEnded;
          if (!show) return _frame(context, null, false, false);
          final surface = o.surface;
          return ListenableBuilder(
            listenable: Listenable.merge([
              o.controller,
              CallNative.inPip,
              if (surface != null) surface.hasRemoteVideo,
            ]),
            builder: (context, _) {
              final ended = o.controller.isEnded;
              final pip = !ended && CallNative.inPip.value;
              final float = !ended && !pip && o.controller.videoOn;
              return _frame(context, ended ? null : o, float, pip);
            },
          );
        },
      );

  Widget _frame(BuildContext context, OngoingCall? o, bool float, bool pip) {
    final show = o != null;
    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(
          offstage: pip,
          child: Column(
            children: [
              if (show) CallMiniBar(call: o) else const SizedBox.shrink(),
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    MediaQuery.removePadding(
                      context: context,
                      removeTop: show,
                      child: child,
                    ),
                    if (show && float) CallFloatingVideo(call: o),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (show && pip) Positioned.fill(child: CallPipView(call: o)),
      ],
    );
  }
}

/// calls-a: the live video of a minimized call as the WHOLE window while
/// Android shows Assisto in picture-in-picture.
class CallPipView extends StatelessWidget {
  const CallPipView({super.key, required this.call});
  final OngoingCall call;

  @override
  Widget build(BuildContext context) {
    final c = call.controller;
    final s = call.surface;
    final remote =
        s != null && c.isLive && c.remoteCameraOn && s.hasRemoteVideo.value;
    return ColoredBox(
      key: const Key('call-pip-view'),
      color: Brand.ink,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: remote
                ? s.remoteView()
                : CallAvatar(
                    name: call.name,
                    photoUrl: '${call.member['photo_url'] ?? ''}',
                    radius: 32),
          ),
          if (c.isLive && !c.remoteMicOn)
            const Positioned(
              left: Gap.sm,
              bottom: Gap.sm,
              child: Icon(Icons.mic_off_rounded, color: CallInk.text, size: 20),
            ),
        ],
      ),
    );
  }
}

/// calls-a: WhatsApp's floating video window — the other person's video
/// over whatever Assisto screen is open. Drag it anywhere (it settles at the
/// nearest side, never under the status bar, the keyboard or the gesture
/// bar); tap it for the full call. TalkBack: one button.
class CallFloatingVideo extends StatefulWidget {
  const CallFloatingVideo({super.key, required this.call});
  final OngoingCall call;

  static const Size size = Size(104, 152);

  @override
  State<CallFloatingVideo> createState() => CallFloatingVideoState();
}

class CallFloatingVideoState extends State<CallFloatingVideo> {
  /// Top-left of the window inside the app area; null = the default corner
  /// (top right, below the green bar).
  Offset? _pos;
  bool _dragging = false;

  @visibleForTesting
  Offset? get position => _pos;

  Offset _clamp(Offset p, Size area, EdgeInsets safe) {
    const w = CallFloatingVideo.size;
    final minX = safe.left + Gap.sm;
    final maxX = area.width - safe.right - w.width - Gap.sm;
    final minY = Gap.sm;
    final maxY = area.height - safe.bottom - w.height - Gap.sm;
    return Offset(p.dx.clamp(minX, maxX < minX ? minX : maxX),
        p.dy.clamp(minY, maxY < minY ? minY : maxY));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final mq = MediaQuery.of(context);
    // the keyboard (chat reply) and the gesture bar stay uncovered
    final safe = EdgeInsets.only(
      left: mq.padding.left,
      right: mq.padding.right,
      bottom: mq.padding.bottom + mq.viewInsets.bottom,
    );
    return LayoutBuilder(builder: (context, box) {
      final area = Size(box.maxWidth, box.maxHeight);
      final start = Offset(
          area.width - safe.right - CallFloatingVideo.size.width - Gap.md,
          Gap.md);
      final pos = _clamp(_pos ?? start, area, safe);
      return Stack(
        children: [
          AnimatedPositioned(
            duration: _dragging || mq.disableAnimations
                ? Duration.zero
                : const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            left: pos.dx,
            top: pos.dy,
            width: CallFloatingVideo.size.width,
            height: CallFloatingVideo.size.height,
            child: Semantics(
              button: true,
              label: t.callsAFloatLabel(widget.call.name),
              excludeSemantics: true,
              onTap: () => CallRuntime.instance.restoreOngoing(context),
              child: GestureDetector(
                key: const Key('call-float'),
                behavior: HitTestBehavior.opaque,
                onTap: () => CallRuntime.instance.restoreOngoing(context),
                onPanStart: (_) => setState(() {
                  _dragging = true;
                  _pos = pos;
                }),
                onPanUpdate: (d) => setState(
                    () => _pos = _clamp((_pos ?? pos) + d.delta, area, safe)),
                onPanEnd: (_) => setState(() {
                  _dragging = false;
                  // settle at the nearer side, like WhatsApp
                  final p = _pos ?? pos;
                  final mid = p.dx + CallFloatingVideo.size.width / 2;
                  final x = mid < area.width / 2 ? 0.0 : area.width;
                  _pos = _clamp(Offset(x, p.dy), area, safe);
                }),
                child: _FloatTile(call: widget.call),
              ),
            ),
          ),
        ],
      );
    });
  }
}

class _FloatTile extends StatelessWidget {
  const _FloatTile({required this.call});
  final OngoingCall call;

  @override
  Widget build(BuildContext context) {
    final c = call.controller;
    final s = call.surface;
    final remote =
        s != null && c.isLive && c.remoteCameraOn && s.hasRemoteVideo.value;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Brand.ink,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: CallInk.glassHigh),
        boxShadow: const [
          BoxShadow(color: CallInk.tileShadow, blurRadius: 12, offset: Offset(0, 4)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.md),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (remote)
              s.remoteView()
            else
              DecoratedBox(
                decoration: const BoxDecoration(gradient: Brand.heroDark),
                child: Center(
                  child: CallAvatar(
                      name: call.name,
                      photoUrl: '${call.member['photo_url'] ?? ''}',
                      radius: 28),
                ),
              ),
            Positioned(
              left: Gap.xs,
              bottom: Gap.xs,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: CallInk.chip,
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(Gap.xs),
                  child: Icon(
                      c.isLive && !c.remoteMicOn
                          ? Icons.mic_off_rounded
                          : Icons.videocam_rounded,
                      color: CallInk.text,
                      size: 14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CallMiniBar extends StatefulWidget {
  const CallMiniBar({super.key, required this.call});
  final OngoingCall call;

  @override
  State<CallMiniBar> createState() => _CallMiniBarState();
}

class _CallMiniBarState extends State<CallMiniBar> {
  Timer? _tick;

  CallController get _c => widget.call.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_changed);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _changed());
  }

  @override
  void didUpdateWidget(CallMiniBar old) {
    super.didUpdateWidget(old);
    if (!identical(old.call.controller, _c)) {
      old.call.controller.removeListener(_changed);
      _c.addListener(_changed);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tick?.cancel();
    _c.removeListener(_changed);
    super.dispose();
  }

  String _time(BuildContext context) {
    final s = _c.elapsed.inSeconds;
    String two(int n) => n.toString().padLeft(2, '0');
    final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
    final raw = h > 0 ? '$h:${two(m)}:${two(sec)}' : '${two(m)}:${two(sec)}';
    return notifLocalizeDigits(context, raw);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final c = _c;
    final top = MediaQuery.paddingOf(context).top;
    final status = c.phase == CallPhase.reconnecting
        ? t.circleCallReconnecting
        : c.isLive
            ? _time(context)
            : t.circleCallConnecting;
    // WCAG: white on CallInk.miniBar is 6.4:1; light status-bar icons on it
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: _bar(context, t, c, top, status),
    );
  }

  Widget _bar(BuildContext context, AppLocalizations t, CallController c,
      double top, String status) {
    return Material(
      color: CallInk.miniBar,
      child: InkWell(
        key: const Key('call-mini-bar'),
        onTap: () => CallRuntime.instance.restoreOngoing(context),
        child: Padding(
          padding: EdgeInsets.fromLTRB(Gap.lg, top + 6, Gap.xs, 6),
          // calls-a: the whole bar is one >= 48 dp tap target
          child: ConstrainedBox(
           constraints: const BoxConstraints(minHeight: Gap.xxxl),
           child: Row(
            children: [
              Icon(c.videoOn ? Icons.videocam_rounded : Icons.call_rounded,
                  color: CallInk.text, size: 20),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${widget.call.name} · $status',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      // the live timer: tabular figures (no jitter)
                      style: AType.titleSmall.copyWith(
                          color: CallInk.text,
                          fontWeight: FontWeight.w600,
                          fontFeatures: AFonts.tabular),
                    ),
                    Text(t.b1CallOngoingTap,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AType.bodySmall.copyWith(color: CallInk.text)),
                  ],
                ),
              ),
              if (c.muted)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.xs),
                  child: Icon(Icons.mic_off_rounded,
                      color: CallInk.text, size: 18, semanticLabel: t.circleCallMute),
                ),
              // no Tooltip: the bar sits ABOVE the Navigator (no Overlay)
              Semantics(
                button: true,
                label: t.c2CallHangup,
                child: InkResponse(
                  key: const Key('call-mini-hangup'),
                  radius: 24,
                  onTap: () => unawaited(c.hangup()),
                  child: const SizedBox(
                      width: Gap.xxxl,
                      height: Gap.xxxl,
                      child: Icon(Icons.call_end_rounded, color: CallInk.miniHangup)),
                ),
              ),
            ],
          ),
          ),
        ),
      ),
    );
  }
}
