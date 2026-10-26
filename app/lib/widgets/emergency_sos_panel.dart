import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:share_plus/share_plus.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'safety_sos_countdown.dart';
import '../services/action_feedback.dart'; // db1

/// Advanced one-tap SOS control for the Emergency screen.
///
/// Tapping the big SOS button runs the shared countdown (mirrors
/// core.logic.safety.sos_phase — a mis-tap can be cancelled before anything
/// fires). When it fires it:
///   1. calls 999 (the national line), and
///   2. alerts the chosen family contact(s) with a live-location maps link
///      (reuses the same Geolocator + share path as Safe Journey).
///
/// A "loud mode" flag makes the device vibrate/haptic-buzz while armed so the
/// user — and anyone nearby — notices. (A full siren needs a native audio
/// plugin, surfaced in the integration note; haptics work now.)
///
/// The big button is the ONLY place a combined-language label would be wrong,
/// so its text comes from a single active-language getter (never "bn / en").
class EmergencySosPanel extends StatefulWidget {
  /// Ordered emergency contacts (first callable one is the primary).
  final List<Map<String, dynamic>> contacts;

  /// Countdown seconds (shared with Safe Journey; 0 = fire immediately).
  final int countdownSeconds;

  /// Called when there is no callable contact so the parent can prompt the
  /// user to add one.
  final VoidCallback onNoContact;

  const EmergencySosPanel({
    super.key,
    required this.contacts,
    required this.countdownSeconds,
    required this.onNoContact,
  });

  @override
  State<EmergencySosPanel> createState() => _EmergencySosPanelState();
}

class _EmergencySosPanelState extends State<EmergencySosPanel> {
  bool _loud = true;
  bool _busy = false;
  Timer? _buzz;

  @override
  void dispose() {
    _buzz?.cancel();
    super.dispose();
  }

  Map<String, dynamic>? _firstCallable() {
    for (final c in widget.contacts) {
      if ('${c['phone'] ?? ''}'.trim().isNotEmpty) return c;
    }
    return null;
  }

  void _startBuzz() {
    if (!_loud) return;
    HapticFeedback.heavyImpact();
    _buzz?.cancel();
    _buzz = Timer.periodic(const Duration(milliseconds: 800), (_) {
      HapticFeedback.heavyImpact();
    });
  }

  void _stopBuzz() {
    _buzz?.cancel();
    _buzz = null;
  }

  Future<String?> _maybeLocationLink(AppLocalizations t) async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return null;
      }
      final pos = await Geolocator.getCurrentPosition();
      return 'https://maps.google.com/?q=${pos.latitude},${pos.longitude}';
    } catch (_) {
      return null;
    }
  }

  Future<void> _call(String phone) async {
    await openForUser(context, Uri.parse('tel:$phone'), where: 'sos.call'); // db1
  }

  Future<void> _fire(AppLocalizations t, Map<String, dynamic> primary) async {
    // 1) alert family with a live-location link (best-effort, non-blocking UX)
    final link = await _maybeLocationLink(t);
    final msg = link == null ? t.emergencySosAlertText : t.sosShareText(link);
    // Share sheet lets the user fire it to the family contact / any channel;
    // the SMS/push auto-send is the integrator's native path (see note).
    try {
      await Share.share(msg,
          subject: t.emergencySosAlertSubject(primary['name'] ?? ''));
    } catch (_) {}
    // 2) call the national emergency line.
    await _call('999');
  }

  Future<void> _onSos() async {
    if (_busy) return;
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final primary = _firstCallable();
    if (primary == null) {
      widget.onNoContact();
      return;
    }
    setState(() => _busy = true);
    _startBuzz();
    try {
      final fire =
          await SafetySosCountdown.show(context, widget.countdownSeconds);
      if (!mounted) return;
      if (!fire) {
        messenger.showSnackBar(
            SnackBar(content: Text(t.emergencySosCancelled)));
        return;
      }
      await _fire(t, primary);
    } finally {
      _stopBuzz();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    // High-contrast red SOS surface for the emergency state (WCAG: white on
    // Brand.danger well exceeds AA for large text).
    return Container(
      padding: const EdgeInsets.all(Gap.lg),
      decoration: BoxDecoration(
        color: Brand.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: Brand.danger.withValues(alpha: 0.3)),
      ),
      child: Column(children: [
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Brand.danger,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: Gap.xl),
            ),
            onPressed: _busy ? null : _onSos,
            icon: const Icon(Icons.sos_rounded, size: 32),
            // Active-language-only label (never a combined literal).
            label: Text(t.emergencySosBigButton,
                style: const TextStyle(
                    fontSize: 22, fontWeight: FontWeight.w800)),
          ),
        ),
        const SizedBox(height: Gap.sm),
        Text(t.emergencySosExplainer,
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 12,
                // a11y1: black54 on the SOS tint was 4.45:1.
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
        // Wrapped in a transparent Material so the tile's ink splash paints
        // above the decorated red SOS surface (it otherwise would be hidden).
        Material(
          type: MaterialType.transparency,
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _loud,
            onChanged: (v) => setState(() => _loud = v),
            secondary: Icon(_loud ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                color: Brand.danger),
            title: Text(t.emergencyLoudMode,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(t.emergencyLoudModeDesc,
                style: const TextStyle(fontSize: 12)),
          ),
        ),
      ]),
    );
  }
}
