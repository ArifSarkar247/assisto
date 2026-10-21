import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../screens/circle_call_screen.dart';
import '../theme.dart';
import 'push_notifier.dart';
import 'push_payload.dart';
import 'push_service.dart';

/// Ringing screen for a My Circle call that arrived by push (the full-screen
/// intent or a tap on the call notification). Accept hands over to the
/// existing [CircleCallScreen] (incoming); Decline tells the server. Closes
/// itself on `call_cancel` or after the ring window.
class IncomingCallScreen extends StatefulWidget {
  const IncomingCallScreen({super.key, required this.payload});

  final PushPayload payload;

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen> {
  StreamSubscription<String>? _sub;
  Timer? _timeout;
  bool _ended = false;

  PushPayload get p => widget.payload;

  @override
  void initState() {
    super.initState();
    _sub = PushService.instance.callCancelled.listen((id) {
      if (id == p.callId) _end();
    });
    _timeout = Timer(const Duration(seconds: 45), _end);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _timeout?.cancel();
    super.dispose();
  }

  void _end() {
    if (!mounted || _ended) return;
    setState(() => _ended = true);
    Future<void>.delayed(const Duration(milliseconds: 1200), () {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  void _accept() {
    unawaited(PushNotifier.cancelCall(p.callId));
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => CircleCallScreen(
        member: {'id': int.tryParse(p.chatId), 'name': p.callerName},
        kind: p.isVideo ? 'video' : 'voice',
        outgoing: false,
      ),
    ));
  }

  void _decline() {
    unawaited(PushNotifier.declineCall(p.callId));
    unawaited(PushNotifier.cancelCall(p.callId));
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final name = p.callerName.isNotEmpty ? p.callerName : p.title;
    final initial = name.isNotEmpty ? name.characters.first.toUpperCase() : '?';
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
                CircleAvatar(
                  radius: 52,
                  backgroundColor: Colors.white.withValues(alpha: 0.14),
                  child: Text(initial,
                      style: const TextStyle(
                          fontSize: 42,
                          color: Colors.white,
                          fontWeight: FontWeight.w700)),
                ),
                const SizedBox(height: Gap.lg),
                Text(name,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 26,
                        color: Colors.white,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: Gap.sm),
                Text(
                  _ended
                      ? t.pushCallEnded
                      : (p.isVideo ? t.pushIncomingVideo : t.pushIncomingVoice),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 16, color: Colors.white.withValues(alpha: 0.8)),
                ),
                const Spacer(flex: 2),
                if (!_ended)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _RoundAction(
                        key: const Key('incoming-decline'),
                        color: Brand.danger,
                        icon: Icons.call_end,
                        label: t.pushCallDecline,
                        onTap: _decline,
                      ),
                      _RoundAction(
                        key: const Key('incoming-accept'),
                        color: Brand.success,
                        icon: p.isVideo ? Icons.videocam : Icons.call,
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
    return Flexible(
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
                  child: Icon(icon, color: Colors.white, size: 32)),
            ),
          ),
        ),
        const SizedBox(height: Gap.sm),
        Text(label,
            textAlign: TextAlign.center,
            maxLines: 2,
            style: const TextStyle(color: Colors.white, fontSize: 14)),
      ]),
    );
  }
}
