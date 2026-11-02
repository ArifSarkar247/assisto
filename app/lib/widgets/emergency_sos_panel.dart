import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import '../family_alerts_api.dart'; // family100
import '../state.dart';
import 'notif_models.dart' show notifLocalizeDigits;
import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'safety_sos_countdown.dart';
import 'sos_ladder_card.dart'; // sosat

/// Emergency-screen SOS (sosat: hold-to-send + escalation ladder).
///
/// HOLD the big button ~1.2 s (a ring fills; a plain tap only explains
/// "hold to send" so a pocket/mis-tap never starts it — with TalkBack /
/// Switch Access a double-tap starts it directly). Then the shared countdown
/// (mirrors core.logic.safety.sos_phase) with a big Cancel. When it fires:
///   1. the SERVER rings every family member in My Circle (full-screen, DND
///      too) — this works even with NO emergency number saved (the old
///      "add a contact first" dead end is gone);
///   2. the escalation ladder card shows who has seen it and the next steps
///      in order: call family -> SMS from your own SIM (you tap send) -> 999.
///      Assisto never opens the dialer or a share sheet by itself any more.
/// No internet: the ladder starts at the SMS step (message + map link ready).
///
/// The big button is the ONLY place a combined-language label would be wrong,
/// so its text comes from a single active-language getter (never "bn / en").
class EmergencySosPanel extends StatefulWidget {
  /// Ordered emergency contacts (for the Call / SMS steps).
  final List<Map<String, dynamic>> contacts;

  /// Countdown seconds (shared with Safe Journey; 0 = fire immediately).
  final int countdownSeconds;

  /// "Add emergency numbers" (shown after an SOS when none are saved).
  final VoidCallback onNoContact;

  const EmergencySosPanel({
    super.key,
    required this.contacts,
    required this.countdownSeconds,
    required this.onNoContact,
    this.sendSos,
    this.locate,
    this.ladderLoad,
  });

  /// family100 test seam: the server SOS (default: POST /family/sos).
  final Future<Map<String, dynamic>> Function(double? lat, double? lng)?
      sendSos;

  /// sosat test seams: location fix (lat,lng) and the ladder loader.
  final Future<(double, double)?> Function()? locate;
  final Future<Map<String, dynamic>> Function()? ladderLoad;

  /// How long to hold the button.
  static const holdMs = 1200;

  @override
  State<EmergencySosPanel> createState() => _EmergencySosPanelState();
}

class _EmergencySosPanelState extends State<EmergencySosPanel>
    with SingleTickerProviderStateMixin {
  bool _loud = true;
  bool _busy = false;
  bool _sent = false;
  bool _offline = false;
  String? _smsBody;
  Timer? _buzz;
  late final AnimationController _hold = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: EmergencySosPanel.holdMs))
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        _hold.value = 0;
        _onSos();
      }
    });

  @override
  void dispose() {
    _buzz?.cancel();
    _hold.dispose();
    super.dispose();
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

  Future<(double, double)?> _maybePosition() async {
    if (widget.locate != null) return widget.locate!();
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
      final p = await Geolocator.getCurrentPosition()
          .timeout(const Duration(seconds: 8));
      return (p.latitude, p.longitude);
    } catch (_) {
      return null;
    }
  }

  /// family100: the SERVER alerts every consenting family member at once
  /// (push rings their phone even when Assisto is closed). Honest result:
  /// how many were alerted / nobody in My Circle / offline. Returns false
  /// when the server could not be reached.
  Future<bool> _alertFamilyServer(
      AppLocalizations t, ScaffoldMessengerState m, (double, double)? pos) async {
    try {
      final send = widget.sendSos ??
          (double? la, double? ln) => context.read<AppState>().api.familySos(
              lat: la, lng: ln, source: 'emergency', clientId: newSosClientId());
      final r = await send(pos?.$1, pos?.$2)
          .timeout(const Duration(seconds: 12));
      final n = (r['recipients'] as num?)?.toInt() ?? 0;
      if (!mounted) return true;
      final count = notifLocalizeDigits(context, '$n');
      m.showSnackBar(SnackBar(
          content: Text(n > 0 ? t.fa100SosSent(count) : t.fa100SosNoCircle)));
      return true;
    } catch (_) {
      m.showSnackBar(SnackBar(content: Text(t.saSosOfflineSms)));
      return false;
    }
  }

  Future<void> _fire(AppLocalizations t) async {
    final m = ScaffoldMessenger.of(context);
    final pos = await _maybePosition();
    final ok = await _alertFamilyServer(t, m, pos);
    final link = pos == null
        ? null
        : 'https://maps.google.com/?q=${pos.$1},${pos.$2}';
    if (!mounted) return;
    setState(() {
      _sent = true;
      _offline = !ok;
      _smsBody = link == null ? t.emergencySosAlertText : t.sosShareText(link);
    });
  }

  Future<void> _onSos() async {
    if (_busy) return;
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
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
      await _fire(t);
    } finally {
      _stopBuzz();
      if (mounted) setState(() => _busy = false);
    }
  }

  void _tap() {
    // TalkBack / Switch Access: a double-tap is the whole gesture.
    if (MediaQuery.accessibleNavigationOf(context)) {
      _onSos();
      return;
    }
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).saHoldHint)));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    // High-contrast red SOS surface for the emergency state (WCAG: white on
    // Brand.danger well exceeds AA for large text).
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.all(Gap.lg),
        decoration: BoxDecoration(
          color: Brand.danger.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: Brand.danger.withValues(alpha: 0.3)),
        ),
        child: Column(children: [
          Semantics(
            button: true,
            label: t.emergencySosBigButton,
            hint: t.saHoldHint,
            onTap: _busy ? null : _onSos,
            excludeSemantics: true,
            child: Listener(
              onPointerDown: _busy ? null : (_) => _hold.forward(from: 0),
              onPointerUp: (_) {
                if (_hold.status != AnimationStatus.completed) _hold.reset();
              },
              onPointerCancel: (_) => _hold.reset(),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const ValueKey('sosat-sos-hold'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Brand.danger,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: Gap.xl),
                  ),
                  onPressed: _busy ? null : _tap,
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    SizedBox(
                      width: 40,
                      height: 40,
                      child: Stack(alignment: Alignment.center, children: [
                        AnimatedBuilder(
                          animation: _hold,
                          builder: (ctx, child) => CircularProgressIndicator(
                              value: _hold.value,
                              strokeWidth: 4,
                              color: Colors.white,
                              backgroundColor: Colors.white24),
                        ),
                        const Icon(Icons.sos_rounded, size: 26),
                      ]),
                    ),
                    const SizedBox(width: Gap.sm),
                    // Active-language-only label (never a combined literal).
                    Flexible(
                      child: Text(t.emergencySosBigButton,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 22, fontWeight: FontWeight.w800)),
                    ),
                  ]),
                ),
              ),
            ),
          ),
          const SizedBox(height: Gap.sm),
          Text(t.saSosExplainer,
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
              secondary: Icon(_loud ? Icons.vibration_rounded : Icons.mobile_off_rounded,
                  color: Brand.danger),
              title: Text(t.emergencyLoudMode,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(t.emergencyLoudModeDesc,
                  style: const TextStyle(fontSize: 12)),
            ),
          ),
        ]),
      ),
      if (_sent) ...[
        const SizedBox(height: Gap.md),
        SosLadderCard(
          contacts: widget.contacts,
          smsBody: _smsBody,
          offline: _offline,
          load: widget.ladderLoad,
        ),
        if (widget.contacts
            .every((c) => '${c['phone'] ?? ''}'.trim().isEmpty))
          TextButton.icon(
            key: const ValueKey('sosat-add-numbers'),
            onPressed: widget.onNoContact,
            icon: const Icon(Icons.person_add_alt_rounded),
            label: Text(t.saAddNumbersForSms),
          ),
      ],
    ]);
  }
}
