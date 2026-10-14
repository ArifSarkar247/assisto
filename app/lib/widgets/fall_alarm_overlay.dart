import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// Outcome of the fall-alarm overlay, consumed by FallDetectScreen.
enum FallOutcome { imOk, cancelled, timedOut }

/// Full-screen high-contrast alarm shown when a fall is (mock-)detected.
///
/// Mirrors core.logic.safety.fall_prompt_phase: a local countdown of
/// [windowSeconds]; tapping the large "I'm OK" button => FallOutcome.imOk;
/// cancelling => FallOutcome.cancelled; the window elapsing => timedOut (the
/// caller then alerts family + offers 999).
///
/// High-contrast danger surface + a very large tap target (WCAG). The real
/// "loud alarm" is a native sound plugin that isn't wired yet — honestly
/// key-gated; here we use the available HapticFeedback + SystemSound so the
/// test flow is faithful without pretending a siren is playing.
class FallAlarmOverlay extends StatefulWidget {
  final int windowSeconds;
  final bool alarm;
  final bool vibration;
  const FallAlarmOverlay({
    super.key,
    required this.windowSeconds,
    this.alarm = true,
    this.vibration = true,
  });

  @override
  State<FallAlarmOverlay> createState() => _FallAlarmOverlayState();
}

class _FallAlarmOverlayState extends State<FallAlarmOverlay> {
  late int _remaining;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _remaining = widget.windowSeconds;
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_remaining <= 1) {
        _stopFeedback();
        Navigator.of(context).pop(FallOutcome.timedOut);
        return;
      }
      setState(() => _remaining--);
      _pulse();
    });
    _pulse();
  }

  // Strong vibration + attention sound each second. The native loud-alarm
  // plugin is not wired (coming soon); these are the honest available hooks.
  void _pulse() {
    if (widget.vibration) HapticFeedback.heavyImpact();
    if (widget.alarm) SystemSound.play(SystemSoundType.alert);
  }

  void _stopFeedback() {
    _tick?.cancel();
    _tick = null;
  }

  void _resolve(FallOutcome outcome) {
    _stopFeedback();
    Navigator.of(context).pop(outcome);
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    // High-contrast danger surface; white text/controls => AA on this red.
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Brand.danger,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(Gap.xl),
            child: Column(children: [
              const Spacer(),
              const Icon(Icons.personal_injury,
                  color: Colors.white, size: 72),
              const SizedBox(height: Gap.lg),
              Text(t.fallDetectedTitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      height: 1.25)),
              const SizedBox(height: Gap.md),
              Text(t.fallDetectedBody(_remaining),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.95),
                      fontSize: 16,
                      height: 1.4)),
              const Spacer(),
              // LARGE "I'm OK" button — single key, active language only.
              SizedBox(
                width: double.infinity,
                height: 96,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Brand.danger,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(Radii.lg)),
                  ),
                  onPressed: () => _resolve(FallOutcome.imOk),
                  child: Text(t.fallImOk,
                      style: const TextStyle(
                          fontSize: 30, fontWeight: FontWeight.w900)),
                ),
              ),
              const SizedBox(height: Gap.md),
              // Always cancellable.
              SizedBox(
                width: double.infinity,
                height: 56,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white, width: 1.5),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(Radii.md)),
                  ),
                  onPressed: () => _resolve(FallOutcome.cancelled),
                  child: Text(t.fallCancel,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(height: Gap.sm),
            ]),
          ),
        ),
      ),
    );
  }
}
