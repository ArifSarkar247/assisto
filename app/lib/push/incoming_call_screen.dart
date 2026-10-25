import 'dart:async';

import 'package:flutter/material.dart';

import '../calls/call_avatar.dart';
import '../calls/call_reply.dart';
import '../calls/call_runtime.dart';
import '../l10n/app_localizations.dart';
import '../screens/circle_call_screen.dart';
import '../theme.dart';
import 'lock_screen_guard.dart';
import 'push_notifier.dart';
import 'push_payload.dart';
import 'push_service.dart';

/// Ringing screen for a My Circle call that arrived by push (the full-screen
/// intent or a tap on the call notification). Accept hands over to the
/// existing [CircleCallScreen] (incoming); Decline tells the server. Closes
/// itself on `call_cancel` or after the ring window.
class IncomingCallScreen extends StatefulWidget {
  const IncomingCallScreen(
      {super.key,
      required this.payload,
      this.ringInApp = false,
      this.onReply});

  final PushPayload payload;

  /// true when the app was OPEN and showed this screen itself (real-time /
  /// foreground push): we ring with the chosen ringtone natively. false when
  /// launched from the call notification, which is already ringing.
  final bool ringInApp;

  /// call-reply: what Reply does AFTER the normal decline (tests inject it).
  /// Default: [PushService.onCallReply] opens the chat + quick-reply sheet.
  final void Function(PushPayload p)? onReply;

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen> {
  StreamSubscription<String>? _sub;
  StreamSubscription<String>? _rtSub;
  Timer? _timeout;
  bool _ended = false;
  bool _accepted = false;

  PushPayload get p => widget.payload;

  @override
  void initState() {
    super.initState();
    _sub = PushService.instance.callCancelled.listen((id) {
      if (id == p.callId) _end();
    });
    CallRuntime.instance.markShown(p.callId);
    // c2-calls: the caller hung up / it rang out (real-time queue)
    _rtSub = CallRuntime.instance.endedCalls.listen((id) {
      if (id == p.callId) _end();
    });
    if (widget.ringInApp) {
      unawaited(CallRuntime.instance.startRinging(p));
    } else {
      // launched from the notification: still confirm we are ringing
      unawaited(PushNotifier.ackRinging(p.callId));
    }
    _timeout = Timer(const Duration(seconds: 60), _end);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _rtSub?.cancel();
    _timeout?.cancel();
    unawaited(CallRuntime.instance.stopRinging());
    // accepted -> CircleCallScreen releases when the call ends
    if (!_accepted) LockScreenGuard.release();
    super.dispose();
  }

  void _end() {
    if (!mounted || _ended) return;
    unawaited(CallRuntime.instance.stopRinging());
    setState(() => _ended = true);
    Future<void>.delayed(const Duration(milliseconds: 1200), () {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  void _accept() {
    _accepted = true;
    unawaited(CallRuntime.instance.stopRinging());
    unawaited(PushNotifier.cancelCall(p.callId));
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => CircleCallScreen(
        member: {
          'id': int.tryParse(p.chatId),
          'name': p.callerName,
          'photo_url': p.callerPhoto,
        },
        kind: p.isVideo ? 'video' : 'voice',
        outgoing: false,
        callId: int.tryParse(p.callId),
      ),
    ));
  }

  void _decline() {
    unawaited(CallRuntime.instance.stopRinging());
    unawaited(PushNotifier.declineCall(p.callId));
    unawaited(PushNotifier.cancelCall(p.callId));
    Navigator.of(context).maybePop();
  }

  /// call-reply: exactly Decline (same server path, caller sees declined),
  /// then that person's chat opens with the quick-reply sheet.
  void _reply() {
    _decline();
    final cb = widget.onReply ??
        (PushPayload x) => PushService.instance.onCallReply(x, decline: false);
    try {
      cb(p);
    } catch (_) {}
  }

  // Release the lock screen as the pop STARTS (decline, ring timeout or the
  // system back gesture), so the screen underneath never shows on a locked
  // phone. Accept replaces this route; the call screen releases later.
  @override
  Widget build(BuildContext context) => PopScope(
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) LockScreenGuard.release();
        },
        child: _body(context),
      );

  Widget _body(BuildContext context) {
    final t = AppLocalizations.of(context);
    final name = p.callerName.isNotEmpty ? p.callerName : p.title;
    return Scaffold(
      backgroundColor: Brand.ink,
      body: Container(
        decoration: const BoxDecoration(gradient: Brand.heroDark),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: Gap.xl, vertical: Gap.xxl),
            child: Column(
              children: [
                const Spacer(),
                // x1-calls A3: the caller's real photo (cached)
                CallAvatar(name: name, photoUrl: p.callerPhoto, radius: 64),
                const SizedBox(height: Gap.lg),
                Text(name,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AType.headlineMedium.copyWith(
                        color: CallInk.text, fontWeight: FontWeight.w700)),
                const SizedBox(height: Gap.sm),
                Text(
                  _ended
                      ? t.pushCallEnded
                      : (p.isVideo ? t.pushIncomingVideo : t.pushIncomingVoice),
                  textAlign: TextAlign.center,
                  style: AType.bodyLarge.copyWith(color: CallInk.textSoft),
                ),
                const Spacer(flex: 2),
                if (!_ended)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _RoundAction(
                        key: const Key('incoming-decline'),
                        color: Brand.danger,
                        icon: Icons.call_end_rounded,
                        label: t.pushCallDecline,
                        onTap: _decline,
                      ),
                      if (CallReply.canReply(p))
                        _RoundAction(
                          key: const Key('incoming-reply'),
                          color: CallInk.glassHigh,
                          icon: Icons.message_rounded,
                          label: t.callReplyAction,
                          onTap: _reply,
                        ),
                      _RoundAction(
                        key: const Key('incoming-accept'),
                        color: Brand.success,
                        icon: p.isVideo ? Icons.videocam_rounded : Icons.call_rounded,
                        label: t.pushCallAccept,
                        onTap: _accept,
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    super.key,
    required this.color,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final Color color;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // QA a6: Flexible let the pair clump in the middle; Expanded gives each
    // half of the width so Decline/Accept sit apart like a phone dialer.
    return Expanded(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Semantics(
          button: true,
          label: label,
          child: Material(
            color: color,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox(
                  width: 72,
                  height: 72,
                  child: Icon(icon, color: CallInk.text, size: 32)),
            ),
          ),
        ),
        const SizedBox(height: Gap.sm),
        Text(label,
            textAlign: TextAlign.center,
            maxLines: 2,
            style: AType.bodyMedium.copyWith(color: CallInk.text)),
      ]),
    );
  }
}
