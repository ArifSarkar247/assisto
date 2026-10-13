import 'dart:async';
import 'package:flutter/material.dart';
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

  @override
  void initState() {
    super.initState();
    if (widget.delaySeconds <= 0) {
      _ringing = true;
    } else {
      _delayTimer = Timer(Duration(seconds: widget.delaySeconds),
          () => setState(() => _ringing = true));
    }
  }

  @override
  void dispose() {
    _delayTimer?.cancel();
    _talkTimer?.cancel();
    super.dispose();
  }

  void _answer() {
    setState(() => _answered = true);
    _talkTimer = Timer.periodic(const Duration(seconds: 1),
        (_) => setState(() => _talkSeconds++));
  }

  void _hangUp() {
    _talkTimer?.cancel();
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
            const Icon(Icons.phone_in_talk, color: Colors.white54, size: 48),
            const SizedBox(height: 16),
            Text(t.fakeCallArmed(widget.delaySeconds),
                style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 16),
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
      backgroundColor: const Color(0xFF101418),
      body: SafeArea(
        child: Column(children: [
          const Spacer(flex: 2),
          const CircleAvatar(
              radius: 52,
              backgroundColor: Colors.white24,
              child: Icon(Icons.person, size: 60, color: Colors.white)),
          const SizedBox(height: 20),
          Text(widget.caller,
              style: const TextStyle(
                  color: Colors.white, fontSize: 30, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(_answered ? '$mm:$ss' : t.fakeCallIncoming,
              style: const TextStyle(color: Colors.white70, fontSize: 16)),
          const Spacer(flex: 3),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 40),
            child: _answered
                ? Center(
                    child: _CallBtn(
                        color: Colors.red,
                        icon: Icons.call_end,
                        label: t.fakeCallEnd,
                        onTap: _hangUp),
                  )
                : Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                    _CallBtn(
                        color: Colors.red,
                        icon: Icons.call_end,
                        label: t.fakeCallDecline,
                        onTap: _hangUp),
                    _CallBtn(
                        color: Colors.green,
                        icon: Icons.call,
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
      {required this.color,
      required this.icon,
      required this.label,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      GestureDetector(
        onTap: onTap,
        child: CircleAvatar(
            radius: 36, backgroundColor: color, child: Icon(icon, color: Colors.white, size: 32)),
      ),
      const SizedBox(height: 8),
      Text(label, style: const TextStyle(color: Colors.white70)),
    ]);
  }
}
