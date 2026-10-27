import 'dart:async';

import 'package:flutter/material.dart';

import '../calls/call_avatar.dart';
import '../calls/call_launch.dart'; // calls-a
import '../calls/call_native.dart'; // calls-a
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
/// calls-a test seam: answers "is the native ring still posted?".
@visibleForTesting
Future<bool?> Function(String callId)? debugRingActive;

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
    // calls-a: an Accept from the notification while this screen is up
    // answers HERE (this screen replaces itself) — never a second screen.
    CallLaunchRouter.instance.registerRinging(p.callId, _accept);
    // c2-calls: the caller hung up / it rang out (real-time queue)
    _rtSub = CallRuntime.instance.endedCalls.listen((id) {
      if (id == p.callId) _end();
    });
    if (widget.ringInApp) {
      unawaited(CallRuntime.instance.startRinging(p));
    } else {
      // launched from the notification: still confirm we are ringing
      unawaited(PushNotifier.ackRinging(p.callId));
      unawaited(_keepRinging());
    }
    _timeout = Timer(const Duration(seconds: 60), _end);
  }

  /// calls-a: opened from the call notification (tap / full-screen, also
  /// over the lock screen). The phone must KEEP ringing until Accept /
  /// Decline: normally the native ring notification is still sounding; if it
  /// is gone (an OEM dropped it, or it was cleared), ring in-app instead —
  /// never a silent ringing screen.
  bool _ringingInApp = false;

  Future<void> _keepRinging() async {
    bool? native;
    try {
      native = await (debugRingActive ?? CallNative.ringActive)(p.callId);
    } catch (_) {
      native = null;
    }
    if (!mounted || _accepted || _ended) return;
    if (native == false) {
      _ringingInApp = true;
      debugPrint('RING_INAPP_START id=${p.callId}');
      // no second "ringing" ack: startRinging sends it with retries
      unawaited(CallRuntime.instance.startRinging(p));
    } else if (native == true) {
      debugPrint('RING_NATIVE_KEPT id=${p.callId}');
    }
  }

  @visibleForTesting
  bool get ringingInApp => _ringingInApp;

  @override
  void dispose() {
    CallLaunchRouter.instance.unregisterRinging(p.callId, _accept);
    _sub?.cancel();
    _rtSub?.cancel();
    _timeout?.cancel();
    unawaited(CallRuntime.instance.stopRinging());
    // accepted -> CircleCallScreen releases when the call ends
    if (!_accepted) LockScreenGuard.release();
    super.dispose();
  }

  void _end() {
    // calls-a: answered here -> never a "Call ended" frame for it
    if (!mounted || _ended || _accepted) return;
    unawaited(CallRuntime.instance.stopRinging());
    // calls-a: caller hung up / rang out / answered elsewhere: the native
    // ring (kept alive while this screen showed) stops too
    unawaited(PushNotifier.cancelCall(p.callId));
    setState(() => _ended = true);
    Future<void>.delayed(const Duration(milliseconds: 1200), () {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  void _accept() {
    if (_accepted || _ended || !mounted) return;
    _accepted = true;
    _timeout?.cancel();
    unawaited(CallRuntime.instance.stopRinging());
    unawaited(PushNotifier.cancelCall(p.callId));
    CallLaunchRouter.instance.noteInAppAccept(p);
    // calls-a: INSTANT swap to the call screen (no zoom transition: the
    // half-drawn "split" frame came from a transition snapshot taken while
    // the window was still waking over the lock screen).
    Navigator.of(context).pushReplacement(instantCallRoute<void>(
      (_) => CircleCallScreen(
        member: {
          'id': int.tryParse(p.chatId),
          'name': p.callerName,
          'photo_url': p.callerPhoto,
        },
        kind: p.isVideo ? 'video' : 'voice',
        outgoing: false,
        callId: int.tryParse(p.callId),
      ),
      name: CallLaunchRouter.acceptRouteName,
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
    } catch (_) {
      // best-effort: the call is already declined above; if opening the chat
      // fails the user simply lands where they were — nothing to undo or retry.
    }
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
