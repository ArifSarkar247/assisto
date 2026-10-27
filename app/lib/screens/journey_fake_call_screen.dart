import 'dart:async';
import '../theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../l10n/app_localizations.dart';

/// Fake incoming call (item 9). After a user-chosen delay, a realistic
/// full-screen call UI appears so the traveller can "take a call" to leave an
/// uncomfortable situation. Purely local — no network, no real call. Mirrors
/// core.logic.safety_journey.fake_call_plan (caller name + delay).
class JourneyFakeCallScreen extends StatefulWidget {
  final String caller;
  final int delaySeconds;
  const JourneyFakeCallScreen({
    super.key,
    required this.caller,
    this.delaySeconds = 15,
  });

  @override
  State<JourneyFakeCallScreen> createState() => _JourneyFakeCallScreenState();
}

class _JourneyFakeCallScreenState extends State<JourneyFakeCallScreen> {
  Timer? _delayTimer;
  bool _ringing = false;
  bool _answered = false;
  int _talkSeconds = 0;
  Timer? _talkTimer;
  Timer? _buzz; // journey100: vibrate like a real incoming call

  @override
  void initState() {
    super.initState();
    if (widget.delaySeconds <= 0) {
      _ring();
    } else {
      _delayTimer = Timer(Duration(seconds: widget.delaySeconds), _ring);
    }
  }

  void _ring() {
    if (!mounted) return;
    setState(() => _ringing = true);
    HapticFeedback.vibrate();
    _buzz = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      if (!_answered) HapticFeedback.vibrate();
    });
  }

  @override
  void dispose() {
    _delayTimer?.cancel();
    _talkTimer?.cancel();
    _buzz?.cancel();
    super.dispose();
  }

  void _answer() {
    _buzz?.cancel();
    setState(() => _answered = true);
    _talkTimer = Timer.periodic(const Duration(seconds: 1),
        (_) => setState(() => _talkSeconds++));
  }

  void _hangUp() {
    _talkTimer?.cancel();
    _buzz?.cancel();
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (!_ringing) {
      // armed, counting down silently
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.phone_in_talk_rounded, color: Colors.white54, size: 48),
            const SizedBox(height: Gap.lg),
            Text(t.fakeCallArmed(widget.delaySeconds),
                style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: Gap.lg),
            TextButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: Text(t.cancel,
                    style: const TextStyle(color: Colors.white54))),
          ]),
        ),
      );
    }
    final mm = (_talkSeconds ~/ 60).toString().padLeft(2, '0');
    final ss = (_talkSeconds % 60).toString().padLeft(2, '0');
    return Scaffold(
      backgroundColor: Brand.ink,
      body: SafeArea(
        child: Column(children: [
          const Spacer(flex: 2),
          const CircleAvatar(
              radius: 52,
              backgroundColor: Colors.white24,
              child: Icon(Icons.person_rounded, size: 60, color: Colors.white)),
          const SizedBox(height: 20),
          Text(widget.caller,
              style: AType.displaySmall.copyWith(color: Colors.white, fontWeight: FontWeight.w600)),
          const SizedBox(height: Gap.sm),
          Text(_answered ? '$mm:$ss' : t.fakeCallIncoming,
              style: AType.bodyLarge.copyWith(
                  color: Colors.white70, fontFeatures: AFonts.tabular)),
          const Spacer(flex: 3),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 40),
            child: _answered
                ? Center(
                    child: _CallBtn(
                        key: const ValueKey('j100_fake_end'),
                        color: Brand.dangerFill,
                        icon: Icons.call_end_rounded,
                        label: t.fakeCallEnd,
                        onTap: _hangUp),
                  )
                : Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                    _CallBtn(
                        key: const ValueKey('j100_fake_decline'),
                        color: Brand.dangerFill,
                        icon: Icons.call_end_rounded,
                        label: t.fakeCallDecline,
                        onTap: _hangUp),
                    _CallBtn(
                        key: const ValueKey('j100_fake_answer'),
                        color: Brand.successFill,
                        icon: Icons.call_rounded,
                        label: t.fakeCallAnswer,
                        onTap: _answer),
                  ]),
          ),
        ]),
      ),
    );
  }
}

class _CallBtn extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _CallBtn(
      {super.key,
      required this.color,
      required this.icon,
      required this.label,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    // One button node: "Answer"/"Decline" read with the circle's tap action.
    return MergeSemantics(
        child: Semantics(
            button: true,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
      GestureDetector(
        onTap: onTap,
        child: CircleAvatar(
            radius: 36, backgroundColor: color, child: Icon(icon, color: Colors.white, size: 32)),
      ),
      const SizedBox(height: Gap.sm),
      Text(label, style: const TextStyle(color: Colors.white70)),
    ])));
  }
}
