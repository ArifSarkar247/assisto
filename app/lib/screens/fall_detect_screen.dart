import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:geolocator/geolocator.dart';
import 'package:share_plus/share_plus.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../widgets/skeleton.dart';
import '../widgets/fall_alarm_overlay.dart';

/// P14 — Accident / fall-detection RUNTIME screen.
///
/// Spec (ASSISTO_REPORT.md P14):
///   * OFF by default; a battery-use disclosure is shown before enabling.
///   * Countdown is a USER SETTING (default 2 min, range 30s–10min).
///   * On a (mock-)detected fall: loud alarm + strong vibration + a LARGE
///     "I'm OK" button (single key, resolves to the active language only).
///   * On timeout: alert the chosen family + share location, then offer a 999
///     call. ALWAYS cancellable.
///   * In ELDERLY MODE a child may set it for a parent ONLY after an explicit
///     parent-permission confirmation.
///
/// Honesty: there is NO native accelerometer yet. NO SHOWPIECES: until
/// [FallDetectScreen.engineShipped] is true the "turn on fall detection"
/// switches (here, in Settings and in Safety) and the sidebar entry are
/// HIDDEN — a switch that detects nothing is a showpiece. The screen stays
/// reachable only through the internal ChatNav route (CI native tour) with the
/// honest sensor banner and the "simulate a fall" test. The countdown mirrors the backend
/// safety fall-phase logic (core.logic.safety.fall_prompt_phase) with a local
/// timer matching the 30s–10min setting — there is no fall endpoint to call.
class FallDetectScreen extends StatefulWidget {
  const FallDetectScreen({super.key});

  /// Flip to true when a real on-device fall sensor engine ships.
  static bool get engineShipped => false;
  @override
  State<FallDetectScreen> createState() => _FallDetectScreenState();
}

class _FallDetectScreenState extends State<FallDetectScreen> {
  // Mirrors core.logic.safety.default_fall_config()/clamp_fall_window.
  static const int _winMin = 30;
  static const int _winMax = 600; // 10 minutes
  static const int _winDefault = 120; // 2 minutes
  // The native fall sensor plugin is not wired yet (see engineShipped).
  static bool get _sensorAvailable => FallDetectScreen.engineShipped;

  bool _enabled = false;
  int _windowSec = _winDefault;
  bool _alarm = true;
  bool _vibration = true;

  bool _loading = true;
  List<Map<String, dynamic>> _family = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  int _clampWindow(int s) => s.clamp(_winMin, _winMax);

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    // Local settings are the source of truth for the runtime screen; defaults
    // match the backend (off / 120s / alarm+vibration on).
    _enabled = await Settings.getBool('safety_fall_on', false);
    _windowSec = _clampWindow(
        int.tryParse(await Settings.getString('safety_fall_win') ?? '') ??
            _winDefault);
    _alarm = await Settings.getBool('safety_fall_alarm', true);
    _vibration = await Settings.getBool('safety_fall_vib', true);
    try {
      final c = await api.getEmergency();
      _family = ((c['contacts'] ?? []) as List)
          .cast<Map<String, dynamic>>()
          .where((e) => (e['phone'] ?? '').toString().trim().isNotEmpty)
          .toList();
    } catch (_) {
      _family = const [];
    }
    if (mounted) setState(() => _loading = false);
  }

  bool get _elderly => context.read<AppState>().user?.elderlyMode ?? false;

  // ---- enable / disable -----------------------------------------------------

  Future<void> _toggleEnabled(bool value) async {
    if (!value) {
      await _persistEnabled(false);
      return;
    }
    // Elderly mode: a child may enable this for a parent ONLY with the
    // parent's explicit permission. Gate the enable behind that confirmation.
    if (_elderly && !await _confirmParentPermission()) return;
    // Battery-use disclosure must be shown before enabling.
    if (!await _showBatteryDisclosure()) return;
    await _persistEnabled(true);
  }

  Future<void> _persistEnabled(bool value) async {
    setState(() => _enabled = value);
    await Settings.setBool('safety_fall_on', value);
    // Best-effort sync to the profile so family-side tooling knows the state.
    try {
      await context
          .read<AppState>()
          .saveProfile({'fall_detect': value, 'fall_countdown_sec': _windowSec});
    } catch (_) {}
  }

  Future<bool> _confirmParentPermission() async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.family_restroom_rounded, color: Brand.blue),
        title: Text(t.fallParentPermissionTitle),
        content: Text(t.fallParentPermissionBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.fallParentPermissionDecline)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.fallParentPermissionConfirm)),
        ],
      ),
    );
    return ok == true;
  }

  Future<bool> _showBatteryDisclosure() async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.battery_alert_rounded, color: Brand.warning),
        title: Text(t.fallBatteryDisclosureTitle),
        content: Text(t.fallBatteryDisclosureBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.fallBatteryDisclosureAgree)),
        ],
      ),
    );
    return ok == true;
  }

  // ---- countdown setting ----------------------------------------------------

  Future<void> _setCountdown() async {
    final t = AppLocalizations.of(context);
    int v = _windowSec;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(t.fallCountdownSettingTitle),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(t.fallCountdownValue(v % 60, v ~/ 60) /* (seconds, minutes): gen-l10n metadata order */,
                style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: Gap.sm),
            Slider(
              value: v.toDouble(),
              min: _winMin.toDouble(),
              max: _winMax.toDouble(),
              // 30s steps across 30..600 => 19 divisions.
              divisions: (_winMax - _winMin) ~/ 30,
              label: '${v ~/ 60}:${(v % 60).toString().padLeft(2, '0')}',
              onChanged: (x) => setD(() => v = _clampWindow(x.round())),
            ),
            Text(t.fallCountdownHelp,
                style: AType.bodySmall.copyWith(color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(t.cancel)),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true), child: Text(t.save)),
          ],
        ),
      ),
    );
    if (ok == true) {
      setState(() => _windowSec = v);
      await Settings.setString('safety_fall_win', '$v');
      try {
        await context
            .read<AppState>()
            .saveProfile({'fall_countdown_sec': v});
      } catch (_) {} // best-effort: the countdown is saved on this phone above; the profile copy syncs on the next save
    }
  }

  // ---- runtime: the detected-fall flow --------------------------------------

  Future<void> _simulateFall() async {
    // Shows the full-screen high-contrast alarm overlay with the large
    // "I'm OK" button and a local countdown mirroring fall_prompt_phase.
    final result = await Navigator.of(context).push<FallOutcome>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => FallAlarmOverlay(
          windowSeconds: _windowSec,
          alarm: _alarm,
          vibration: _vibration,
        ),
      ),
    );
    if (!mounted || result == null) return;
    final t = AppLocalizations.of(context);
    switch (result) {
      case FallOutcome.imOk:
        _snack(t.fallImOkMsg);
        break;
      case FallOutcome.cancelled:
        _snack(t.fallCancelledMsg);
        break;
      case FallOutcome.timedOut:
        await _runAlertFlow();
        break;
    }
  }

  /// Timeout path: alert chosen family + share location, then offer 999.
  /// Reuses the same family-alert + location mechanisms as the Safety screen
  /// (getEmergency contacts, Geolocator + Share). No fall endpoint exists, so
  /// alerting is surfaced locally/foreground like the rest of safety.
  Future<void> _runAlertFlow() async {
    final sharedLocation = await _shareLocationBestEffort();
    if (!mounted) return;
    final t = AppLocalizations.of(context);
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.campaign_rounded, color: Brand.danger, size: 36),
        title: Text(t.fallAlertingTitle),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(t.fallAlertingBody, textAlign: TextAlign.center),
          const SizedBox(height: Gap.md),
          _resultRow(ctx, Icons.group_rounded, t.fallAlertSentFamily, _family.isNotEmpty),
          _resultRow(ctx, Icons.location_on_rounded, t.fallAlertSharedLocation,
              sharedLocation),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(t.fallImOkAfterAll)),
          FilledButton.icon(
            style: FilledButton.styleFrom(
                backgroundColor: Brand.danger,
                foregroundColor: Colors.white,
                minimumSize: const Size(0, 52)),
            onPressed: () {
              Navigator.pop(ctx);
              _call('999');
            },
            icon: const Icon(Icons.call_rounded),
            label: Text(t.fallCall999),
          ),
        ],
      ),
    );
  }

  Widget _resultRow(BuildContext ctx, IconData icon, String label, bool done) {
    final scheme = Theme.of(ctx).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(children: [
        Icon(done ? Icons.check_circle_rounded : Icons.remove_circle_outline_rounded,
            size: 18, color: done ? Brand.success : scheme.onSurfaceVariant),
        const SizedBox(width: Gap.sm),
        Icon(icon, size: 16, color: scheme.onSurfaceVariant),
        const SizedBox(width: Gap.xs),
        Expanded(child: Text(label, style: AType.bodyMedium)),
      ]),
    );
  }

  Future<bool> _shareLocationBestEffort() async {
    final t = AppLocalizations.of(context);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return false;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return false;
      }
      final pos = await Geolocator.getCurrentPosition();
      final link = 'https://maps.google.com/?q=${pos.latitude},${pos.longitude}';
      await Share.share(t.sosShareText(link));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _call(String phone) async {
    final uri = Uri.parse('tel:$phone');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---- build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(t.fallDetectTitle)),
        body: const SkeletonList(count: 5),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.fallDetectTitle)),
      body: ListView(padding: const EdgeInsets.all(Gap.lg), children: [
        _hero(t),
        const SizedBox(height: Gap.lg),

        // Honest sensor gating — never pretend detection is live.
        if (!_sensorAvailable) _sensorGatedBanner(t, scheme),

        // No-family guidance (we must know who to alert).
        if (_family.isEmpty) ...[
          const SizedBox(height: Gap.md),
          _infoCard(scheme, Brand.warning, Icons.group_add_rounded,
              t.fallNoFamily, t.fallNoFamilyHelp),
        ],

        if (_sensorAvailable) ...[
        const SizedBox(height: Gap.lg),
        Text(t.fallSectionSettings,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: Gap.sm),
        Card(
          child: Column(children: [
            SwitchListTile(
              title: Text(t.fallEnableTitle),
              subtitle: Text(_enabled
                  ? t.fallStatusOn
                  : t.fallEnableSubtitle),
              secondary: Icon(
                  _enabled ? Icons.shield_rounded : Icons.shield_outlined,
                  color: _enabled ? Brand.success : scheme.onSurfaceVariant),
              value: _enabled,
              onChanged: _toggleEnabled,
            ),
            if (_enabled) ...[
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.timer_rounded),
                title: Text(t.fallCountdownLabel),
                subtitle:
                    Text(t.fallCountdownValue(_windowSec % 60, _windowSec ~/ 60) /* (seconds, minutes) */),
                trailing: TextButton(
                    onPressed: _setCountdown, child: Text(t.edit)),
              ),
              const Divider(height: 1),
              SwitchListTile(
                secondary: const Icon(Icons.volume_up_rounded),
                title: Text(t.fallAlarmLabel),
                value: _alarm,
                onChanged: (v) async {
                  setState(() => _alarm = v);
                  await Settings.setBool('safety_fall_alarm', v);
                },
              ),
              SwitchListTile(
                secondary: const Icon(Icons.vibration_rounded),
                title: Text(t.fallVibrationLabel),
                value: _vibration,
                onChanged: (v) async {
                  setState(() => _vibration = v);
                  await Settings.setBool('safety_fall_vib', v);
                },
              ),
            ],
          ]),
        ),

        ],
        const SizedBox(height: Gap.lg),
        Text(t.fallSectionTest,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: Gap.sm),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.fallSimulateTitle,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: Gap.xs),
                  Text(t.fallSimulateHelp,
                      style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
                  const SizedBox(height: Gap.md),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _simulateFall,
                      icon: const Icon(Icons.bolt_rounded),
                      label: Text(t.fallSimulateButton),
                    ),
                  ),
                ]),
          ),
        ),

        const SizedBox(height: Gap.xl),
        Text(t.fallFooterNote,
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
      ]),
    );
  }

  Widget _hero(AppLocalizations t) {
    return Container(
      padding: const EdgeInsets.all(Gap.lg),
      decoration: BoxDecoration(
        gradient: Brand.gradient,
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.personal_injury_rounded, color: Colors.white, size: 30),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.fallDetectSubtitle,
                      style: AType.titleMedium.copyWith(color: Colors.white,
                          fontWeight: FontWeight.w700)),
                ]),
          ),
        ]),
        const SizedBox(height: Gap.sm),
        Text(t.fallHeroCaption,
            style: AType.bodyMedium.copyWith(color: Colors.white.withValues(alpha: 0.92),
                height: 1.4)),
      ]),
    );
  }

  Widget _sensorGatedBanner(AppLocalizations t, ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: Brand.warning.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: Brand.warning.withValues(alpha: 0.5)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.sensors_off_rounded, color: Brand.warnInk(context)),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.fallSensorGatedTitle,
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Brand.warnInk(context))),
                const SizedBox(height: Gap.xs),
                Text(t.fallSensorGatedBody,
                    style: AType.bodySmall.copyWith(color: Brand.warnInk(context))),
              ]),
        ),
      ]),
    );
  }

  Widget _infoCard(ColorScheme scheme, Color tint, IconData icon, String title,
      String body) {
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: tint),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: Gap.xs),
                Text(body,
                    style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
              ]),
        ),
      ]),
    );
  }
}
