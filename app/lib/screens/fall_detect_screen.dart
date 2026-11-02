import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../services/antitheft_service.dart';
import '../services/safety_triggers_logic.dart';
import '../services/sos_trigger_settings.dart';
import '../sosat_api.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';
import '../widgets/notif_models.dart' show notifLocalizeDigits;
import 'always_on_protection_screen.dart';
import 'emergency_screen.dart';

/// sosat — EXPERIMENTAL fall detection (elders), for real now.
///
/// The phone's own accelerometer, read ONLY inside the already-running,
/// opt-in Always-on protection foreground service (no new background
/// service, no WorkManager). Rules: free fall -> impact -> lying still with a
/// new orientation (lib/services/safety_triggers_logic.dart, measured on
/// labelled traces by test/sosat_fall_harness_test.dart). On a detection the
/// phone asks "Are you OK?" (alarm-channel notification + "I'm OK"); the
/// SERVER holds the alert for the chosen window and then tells the family in
/// My Circle (full-screen, with the location) — even if the phone is broken
/// or switched off meanwhile. Assisto NEVER calls 999 by itself.
///
/// Off by default; the server flag `fall_detect` keeps the entry hidden until
/// real-phone traces are in (owner decision). Labelled "experimental"
/// everywhere; a dropped phone left on the floor also asks "Are you OK?".
class FallDetectScreen extends StatefulWidget {
  const FallDetectScreen({super.key, this.isRunning, this.pending});

  /// The detector engine now exists (sosat). Entry points stay behind the
  /// `fall_detect` feature flag (default OFF) until real-phone proof.
  static bool get engineShipped => true;

  /// Test seams.
  final Future<bool> Function()? isRunning;
  final Future<Map<String, dynamic>> Function()? pending;

  @override
  State<FallDetectScreen> createState() => _FallDetectScreenState();
}

class _FallDetectScreenState extends State<FallDetectScreen> {
  SosTriggerSettings? _s;
  bool _running = false;
  Map<String, dynamic>? _pending;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await SosTriggerSettings.load();
    final run = await (widget.isRunning ?? AntiTheftService.isRunning)();
    Map<String, dynamic>? p;
    try {
      final f = widget.pending ??
          () => context.read<AppState>().api.fallPending();
      final r = await f();
      p = (r['pending'] as Map?)?.cast<String, dynamic>();
    } catch (_) {} // best-effort: no held fall known offline; the server still holds it
    if (!mounted) return;
    setState(() {
      _s = s;
      _running = run;
      _pending = p;
    });
  }

  bool get _elderly => context.read<AppState>().user?.elderlyMode ?? false;

  Future<void> _toggle(bool on) async {
    final t = AppLocalizations.of(context);
    if (on) {
      // Elderly mode: a child may enable this for a parent ONLY with the
      // parent's explicit permission.
      if (_elderly && !await _confirm(t.fallParentPermissionTitle,
          t.fallParentPermissionBody, t.fallParentPermissionConfirm,
          Icons.family_restroom_rounded)) {
        return;
      }
      if (!mounted) return;
      // What happens + battery + location — before switching on.
      if (!await _confirm(t.saFallConsentTitle, t.saFallConsentBody,
          t.saFallConsentAgree, Icons.personal_injury_rounded)) {
        return;
      }
    }
    if (!mounted) return;
    setState(() => _s!.fallOn = on);
    await _s!.save(t);
    try {
      if (mounted) {
        await context.read<AppState>().saveProfile(
            {'fall_detect': on, 'fall_countdown_sec': _s!.fallWindowS});
      }
    } catch (_) {} // best-effort: profile copy only; the phone setting above is the truth
  }

  Future<bool> _confirm(String title, String body, String yes, IconData icon) async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // 200% text
        icon: Icon(icon, color: Brand.blue),
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(yes)),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _setWindow() async {
    final t = AppLocalizations.of(context);
    var v = _s!.fallWindowS;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          scrollable: true,
          title: Text(t.fallCountdownSettingTitle),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(t.fallCountdownValue(v % 60, v ~/ 60),
                style: Theme.of(ctx).textTheme.titleLarge),
            Slider(
              value: v.toDouble(),
              min: FallPolicy.windowMinS.toDouble(),
              max: FallPolicy.windowMaxS.toDouble(),
              divisions: (FallPolicy.windowMaxS - FallPolicy.windowMinS) ~/ 30,
              onChanged: (x) => setD(() => v = FallPolicy.clampWindow(x.round())),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.save)),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _s!.fallWindowS = v);
    await _s!.save(t);
  }

  Future<void> _practice() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => FallCheckScreen(practiceSeconds: _s!.fallWindowS)));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final s = _s;
    return Scaffold(
      appBar: AppBar(title: Text(t.saFallTitle)),
      body: s == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
              children: [
                if (_pending != null) ...[
                  FilledButton.icon(
                    key: const ValueKey('sosat-fall-pending'),
                    style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(56),
                        backgroundColor: Brand.danger,
                        foregroundColor: Colors.white),
                    onPressed: () async {
                      await Navigator.of(context).push(MaterialPageRoute<void>(
                          fullscreenDialog: true,
                          builder: (_) => FallCheckScreen(
                              clientId: '${_pending!['client_id'] ?? ''}',
                              seconds: (_pending!['seconds_left'] as num?)?.toInt() ?? 0)));
                      await _load();
                    },
                    icon: const Icon(Icons.personal_injury_rounded),
                    label: Text(t.saFallPendingOpen),
                  ),
                  const SizedBox(height: Gap.lg),
                ],
                Row(children: [
                  Expanded(child: Text(t.saFallBenefit, style: AType.titleMedium)),
                  const SizedBox(width: Gap.sm),
                  Chip(
                    key: const ValueKey('sosat-experimental'),
                    label: Text(t.saExperimental),
                    backgroundColor: Brand.warning.withValues(alpha: 0.18),
                  ),
                ]),
                const SizedBox(height: Gap.sm),
                Text(t.saFallHow, style: AType.bodyMedium),
                const SizedBox(height: Gap.lg),
                if (!_running) ...[
                  Text(t.saNeedsProtectionBody, style: AType.bodyMedium),
                  const SizedBox(height: Gap.sm),
                  FilledButton.icon(
                    key: const ValueKey('sosat-fall-protection'),
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                    onPressed: () async {
                      await Navigator.of(context).push(MaterialPageRoute<void>(
                          builder: (_) => const AlwaysOnProtectionScreen()));
                      await _load();
                    },
                    icon: const Icon(Icons.shield_rounded),
                    label: Text(t.saTurnOnProtection),
                  ),
                  const SizedBox(height: Gap.lg),
                ],
                Card(
                  child: Column(children: [
                    SwitchListTile(
                      key: const ValueKey('sosat-fall-switch'),
                      secondary: Icon(
                          s.fallOn ? Icons.shield_rounded : Icons.shield_outlined,
                          color: s.fallOn ? Brand.success : scheme.onSurfaceVariant),
                      title: Text(t.saFallSwitch,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text(s.fallOn ? t.saOn : t.saFallSwitchSub),
                      value: s.fallOn && _running,
                      onChanged: _running ? _toggle : null,
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.timer_rounded),
                      title: Text(t.fallCountdownLabel),
                      subtitle: Text(t.fallCountdownValue(
                          s.fallWindowS % 60, s.fallWindowS ~/ 60)),
                      trailing: TextButton(onPressed: _setWindow, child: Text(t.edit)),
                    ),
                  ]),
                ),
                const SizedBox(height: Gap.md),
                OutlinedButton.icon(
                  key: const ValueKey('sosat-fall-practice'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  onPressed: _practice,
                  icon: const Icon(Icons.play_circle_outline_rounded),
                  label: Text(t.saFallPractice),
                ),
                const SizedBox(height: Gap.lg),
                Text(t.saFallLimits,
                    style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
              ],
            ),
    );
  }
}

/// sosat — the "Are you OK?" screen after a detected fall (opened from the
/// notification), or a PRACTICE run that sends nothing. A huge "I'm OK";
/// "I need help" opens the Emergency screen (SOS stays one hold away).
class FallCheckScreen extends StatefulWidget {
  const FallCheckScreen({
    super.key,
    this.clientId,
    this.seconds = 0,
    this.practiceSeconds,
    this.imOk,
  });

  final String? clientId;
  final int seconds;

  /// Non-null = practice: nothing is sent anywhere.
  final int? practiceSeconds;

  /// Test seam (default: POST /family/fall/ok + clear the phone notification).
  final Future<void> Function(String? clientId)? imOk;

  @override
  State<FallCheckScreen> createState() => _FallCheckScreenState();
}

class _FallCheckScreenState extends State<FallCheckScreen> {
  late int _left = widget.practiceSeconds ?? widget.seconds;
  Timer? _tick;
  bool _busy = false;

  bool get _practice => widget.practiceSeconds != null;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_left <= 0) {
        _tick?.cancel();
        return;
      }
      setState(() => _left--);
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _ok() async {
    final t = AppLocalizations.of(context);
    final m = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    if (_practice) {
      m.showSnackBar(SnackBar(content: Text(t.saFallPracticeDone)));
      nav.pop();
      return;
    }
    setState(() => _busy = true);
    try {
      final f = widget.imOk ??
          (String? cid) async {
            await AntiTheftService.fallOk();
            await context.read<AppState>().api.fallOk(clientId: cid);
          };
      await f(widget.clientId);
      m.showSnackBar(SnackBar(content: Text(t.saFallOkSent)));
      nav.pop();
    } catch (_) {
      m.showSnackBar(SnackBar(content: Text(t.saFallOkFailed)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final mins = _left ~/ 60, secs = _left % 60;
    final clock = notifLocalizeDigits(
        context, '$mins:${secs.toString().padLeft(2, '0')}');
    return Scaffold(
      backgroundColor: Brand.dangerFill,
      body: SafeArea(
        child: ListView(
          padding: withNavBarInset(context, const EdgeInsets.all(Gap.xl)),
          children: [
            if (_practice)
              Text(t.saFallPracticeBanner,
                  key: const ValueKey('sosat-practice-banner'),
                  textAlign: TextAlign.center,
                  style: AType.labelLarge.copyWith(color: Colors.white)),
            const SizedBox(height: Gap.lg),
            const Icon(Icons.personal_injury_rounded, color: Colors.white, size: 56),
            const SizedBox(height: Gap.md),
            Text(t.saNotifFallTitle,
                textAlign: TextAlign.center,
                style: AType.headlineSmall.copyWith(
                    color: Colors.white, fontWeight: FontWeight.w800)),
            const SizedBox(height: Gap.sm),
            Text(_left > 0 ? t.saFallCheckBody(clock) : t.saFallCheckSent,
                key: const ValueKey('sosat-fall-clock'),
                textAlign: TextAlign.center,
                style: AType.bodyLarge.copyWith(color: Colors.white)),
            const SizedBox(height: Gap.xl),
            FilledButton(
              key: const ValueKey('sosat-im-ok'),
              style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Brand.dangerFill,
                  minimumSize: const Size.fromHeight(88)),
              onPressed: _busy ? null : _ok,
              child: Text(t.saNotifFallOk,
                  style: AType.headlineSmall.copyWith(fontWeight: FontWeight.w800)),
            ),
            const SizedBox(height: Gap.md),
            OutlinedButton.icon(
              key: const ValueKey('sosat-need-help'),
              style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white),
                  minimumSize: const Size.fromHeight(52)),
              onPressed: () => Navigator.of(context).pushReplacement(
                  MaterialPageRoute<void>(builder: (_) => const EmergencyScreen())),
              icon: const Icon(Icons.sos_rounded),
              label: Text(t.saNeedHelp),
            ),
            const SizedBox(height: Gap.lg),
            Text(t.saNever999,
                textAlign: TextAlign.center,
                style: AType.bodySmall.copyWith(color: Colors.white)),
          ],
        ),
      ),
    );
  }
}
