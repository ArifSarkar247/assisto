import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../widgets/notif_models.dart' show notifLocalizeDigits;
import 'call_controller.dart';
import 'call_runtime.dart';

/// b1-calls: WhatsApp-style "tap to return to the call" bar. Wraps the whole
/// app (MaterialApp.builder). With no minimized call it is just [child] —
/// the widget tree stays the same shape either way, so the Navigator below
/// never loses its state when the bar appears or goes.
class CallMiniBarHost extends StatelessWidget {
  const CallMiniBarHost({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<OngoingCall?>(
        valueListenable: CallRuntime.instance.ongoing,
        builder: (context, o, _) {
          final show = o != null && !o.controller.isEnded;
          return Column(
            children: [
              if (show) CallMiniBar(call: o) else const SizedBox.shrink(),
              Expanded(
                child: MediaQuery.removePadding(
                  context: context,
                  removeTop: show,
                  child: child,
                ),
              ),
            ],
          );
        },
      );
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
    // WCAG: white on CallInk.miniBar is 6.4:1
    return Material(
      color: CallInk.miniBar,
      child: InkWell(
        key: const Key('call-mini-bar'),
        onTap: CallRuntime.instance.restoreOngoing,
        child: Padding(
          padding: EdgeInsets.fromLTRB(Gap.lg, top + 6, Gap.xs, 6),
          child: Row(
            children: [
              Icon(c.videoOn ? Icons.videocam : Icons.call,
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
                  child: Icon(Icons.mic_off,
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
                      child: Icon(Icons.call_end, color: CallInk.miniHangup)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
