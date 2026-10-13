import 'dart:async';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';

/// A full-screen SOS countdown overlay. Mirrors core.logic.safety.sos_phase:
/// counts down `seconds` (0 = fire immediately); a large Cancel button stops it.
/// Pops `true` when the countdown fires (caller then alerts contacts), `false`
/// if cancelled. Loud/large by design — this is an emergency control.
class SafetySosCountdown extends StatefulWidget {
  final int seconds;
  const SafetySosCountdown({super.key, required this.seconds});

  /// Shows the overlay; returns true if SOS should fire, false if cancelled.
  static Future<bool> show(BuildContext context, int seconds) async {
    final r = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => SafetySosCountdown(seconds: seconds),
    );
    return r ?? false;
  }

  @override
  State<SafetySosCountdown> createState() => _SafetySosCountdownState();
}

class _SafetySosCountdownState extends State<SafetySosCountdown> {
  late int _remaining;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _remaining = widget.seconds;
    if (_remaining <= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _fire());
    } else {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        setState(() => _remaining--);
        if (_remaining <= 0) _fire();
      });
    }
  }

  void _fire() {
    _timer?.cancel();
    if (mounted) Navigator.pop(context, true);
  }

  void _cancel() {
    _timer?.cancel();
    if (mounted) Navigator.pop(context, false);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Dialog(
      backgroundColor: Colors.red,
      insetPadding: const EdgeInsets.all(24),
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.sos, color: Colors.white, size: 48),
          const SizedBox(height: 12),
          Text(t.sosSending,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          Text('$_remaining',
              style: const TextStyle(color: Colors.white, fontSize: 64, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.red,
                padding: const EdgeInsets.symmetric(vertical: 18),
              ),
              onPressed: _cancel,
              child: Text(t.sosCancel, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            ),
          ),
        ]),
      ),
    );
  }
}
