import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../voice/va_actions.dart';
import '../voice/va_native.dart';
import 'battery_guidance_screen.dart';
import '../voice/va_wake.dart';

/// Assisto Voice settings: make Assisto the phone's default digital
/// assistant, the optional "Hey Assisto" wake word (OFF by default, honest
/// about battery/privacy — HIDDEN until [VaWake.shipped] and the engine is
/// really ready on this phone), and spoken replies.
class VoiceAssistantSettingsScreen extends StatefulWidget {
  /// Gallery/tests: skip native + network probes.
  final bool debugStatic;
  const VoiceAssistantSettingsScreen({super.key, this.debugStatic = false});

  @override
  State<VoiceAssistantSettingsScreen> createState() =>
      _VoiceAssistantSettingsScreenState();
}

enum _Wake { loading, keyMissing, engineMissing, ready, running, error }

class _VoiceAssistantSettingsScreenState
    extends State<VoiceAssistantSettingsScreen> with WidgetsBindingObserver {
  bool? _isDefault; // null = unknown
  bool _native = false;
  _Wake _wake = _Wake.loading;
  VaWakeConfig _cfg = const VaWakeConfig();
  bool _tts = true;
  bool _busy = false;
  String _music = 'auto';
  List<String> _installed = const [];

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final tts = await Settings.getBool(VaWake.ttsKey, true);
    final music = await Settings.getString(VaExecutor.musicPrefKey) ?? 'auto';
    if (widget.debugStatic) {
      if (mounted) {
        setState(() {
          _tts = tts;
          _music = music;
          _wake = _Wake.keyMissing;
        });
      }
      return;
    }
    final native = await VaNative.available();
    final isDef = native ? await VaNative.isDefaultAssistant() : null;
    if (!mounted) return;
    final cfg = await VaWake.fetchConfig(context.read<AppState>().api);
    final st = native ? await VaNative.wakeStatus() : null;
    final installed = native ? await VaNative.musicApps() : const <String>[];
    if (!mounted) return;
    setState(() {
      _tts = tts;
      _music = music;
      _installed = installed;
      _native = native;
      _isDefault = isDef;
      _cfg = cfg;
      if (st == 'running') {
        _wake = _Wake.running;
      } else if (!cfg.available) {
        _wake = _Wake.keyMissing;
      } else if (st == null || st == 'engine_missing') {
        _wake = _Wake.engineMissing;
      } else {
        _wake = _Wake.ready;
      }
    });
  }

  Future<void> _toggleWake(bool on) async {
    if (_busy) return;
    if (!on) {
      setState(() => _busy = true);
      await VaNative.wakeStop();
      await VaWake.setWanted(false);
      if (mounted) setState(() => _busy = false);
      await _load();
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.hearing_rounded),
        title: Text(t.vaWakeConfirmTitle),
        content: SingleChildScrollView(child: Text(t.vaWakeConfirmBody)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.vaWakeTurnOn)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final mic = await Permission.microphone.request();
      if (!mic.isGranted) {
        _snack(t.voiceNoPermission);
        return;
      }
      try {
        await Permission.notification.request();
      } catch (_) {} // best-effort: optional; the wake listener works without it
      if (!mounted) return;
      final r = await VaWake.start(_cfg,
          title: t.vaWakeNotifTitle,
          body: t.vaWakeNotifBody,
          stopLabel: t.vaStop,
          tapText: t.vaWakeTapToTalk);
      if (r == 'running') {
        await VaWake.setWanted(true);
      } else if (r == 'engine_missing' || r == null) {
        _snack(t.vaWakeEngineMissing);
      } else if (r == 'error:download') {
        _snack(t.vaWakeDownloadFailed);
      } else {
        _snack(t.vaWakeStartFailed);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.vaSettingsTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xxl),
        children: [
          _defaultCard(scheme),
          const SizedBox(height: Gap.lg),
          if (_showWake) ...[
            _wakeCard(scheme),
            const SizedBox(height: Gap.lg),
          ],
          _ttsCard(scheme),
          const SizedBox(height: Gap.lg),
          _musicCard(scheme),
          const SizedBox(height: Gap.lg),
          _examplesCard(scheme),
        ],
      ),
    );
  }

  Widget _card(ColorScheme scheme,
      {required IconData icon,
      required String title,
      Widget? trailing,
      required List<Widget> children}) {
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHigh,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.lg)),
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    shape: BoxShape.circle),
                child: Icon(icon, color: scheme.primary, size: 22),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Text(title,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ),
              if (trailing != null) trailing,
            ]),
            const SizedBox(height: Gap.md),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _statusChip(ColorScheme scheme, String label, {required bool good}) {
    final bg = good ? Brand.success.withValues(alpha: 0.16) : scheme.surfaceContainerHighest;
    final fg = good
        ? AssistoTokens.of(context).success
        : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: 6),
      decoration: BoxDecoration(
          color: bg, borderRadius: BorderRadius.circular(Radii.pill)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(good ? Icons.check_circle_rounded : Icons.info_outline_rounded, size: 16, color: fg),
        const SizedBox(width: 6),
        Flexible(
            child: Text(label,
                style: TextStyle(color: fg, fontWeight: FontWeight.w600))),
      ]),
    );
  }

  Widget _step(ColorScheme scheme, int n, String text) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.sm),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: scheme.primaryContainer, shape: BoxShape.circle),
            child: Text('$n',
                style: AType.bodySmall.copyWith(color: scheme.onPrimaryContainer, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(child: Text(text)),
        ]),
      );

  Widget _defaultCard(ColorScheme scheme) {
    final status = _isDefault == true
        ? _statusChip(scheme, t.vaDefIsDefault, good: true)
        : _statusChip(scheme,
            _isDefault == false ? t.vaDefNotDefault : t.vaDefUnknown,
            good: false);
    return _card(scheme,
        icon: Icons.assistant_rounded,
        title: t.vaDefTitle,
        children: [
          Text(t.vaDefBody2,
              style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.md),
          status,
          const SizedBox(height: Gap.md),
          _step(scheme, 1, t.vaDefStep1),
          _step(scheme, 2, t.vaDefStep2),
          _step(scheme, 3, t.vaDefStep3),
          Container(
            margin: const EdgeInsets.only(top: Gap.xs),
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: Text('${t.vaDefColorOs}\n\n${t.vaDefPowerNote}',
                style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
          ),
          // NO SHOWPIECES: without the native bridge the button could only
          // say "needs an update" -> hide it; the steps above still guide.
          if (_native || widget.debugStatic) ...[
            const SizedBox(height: Gap.md),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () async {
                  final ok = await VaNative.openAssistantSettings();
                  if (!ok) _snack(t.vaSettingsOpenFailed);
                },
                icon: const Icon(Icons.open_in_new_rounded),
                label: Text(t.vaDefOpenSettings),
              ),
            ),
          ],
        ]);
  }

  /// NO SHOWPIECES: the wake-word card shows only when the feature has
  /// shipped AND it can really be switched on (or is running) on this phone.
  /// Key missing / engine missing / still checking -> no card at all.
  bool get _showWake =>
      VaWake.shipped &&
      (_wake == _Wake.ready ||
          _wake == _Wake.running ||
          _wake == _Wake.error);

  Widget _wakeCard(ColorScheme scheme) {
    final running = _wake == _Wake.running;
    final canToggle = running || _wake == _Wake.ready;
    final note = switch (_wake) {
      _Wake.loading => t.vaWakeChecking,
      _Wake.keyMissing || _Wake.engineMissing => t.vaWakeEngineMissing,
      _Wake.ready => t.vaWakeOffNote,
      _Wake.running => t.vaWakeOnNote,
      _Wake.error => t.vaWakeStartFailed,
    };
    return _card(scheme,
        icon: Icons.hearing_rounded,
        title: t.vaWakeTitle2,
        trailing: _busy
            ? const SizedBox(
                width: Gap.xl,
                height: Gap.xl,
                child: CircularProgressIndicator(strokeWidth: 2))
            : Switch(
                value: running,
                onChanged: canToggle ? _toggleWake : null,
              ),
        children: [
          Text(t.vaWakeBody, style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.md),
          _statusChip(scheme, note, good: running),
          const SizedBox(height: Gap.md),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.battery_alert_rounded,
                size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: Text(t.vaWakeBattery,
                    style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant))),
          ]),
          const SizedBox(height: Gap.sm),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.lock_outline_rounded, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: Text(t.vaWakePrivacy,
                    style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant))),
          ]),
          const SizedBox(height: Gap.sm),
          Text(t.vaWakeRealmeNote,
              style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const BatteryGuidanceScreen())),
              icon: const Icon(Icons.battery_saver_rounded),
              label: Text(t.vaWakeBatteryGuide),
            ),
          ),
        ]);
  }

  Widget _ttsCard(ColorScheme scheme) {
    return _card(scheme,
        icon: Icons.record_voice_over_rounded,
        title: t.vaTtsTitle,
        trailing: Switch(
          value: _tts,
          onChanged: (v) async {
            setState(() => _tts = v);
            await Settings.setBool(VaWake.ttsKey, v);
          },
        ),
        children: [
          Text(t.vaTtsBody, style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.sm),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () async {
                final ok = await VaNative.openTtsSettings();
                if (!ok) _snack(t.vaSettingsOpenFailed);
              },
              icon: const Icon(Icons.download_rounded),
              label: Text(t.vaTtsInstallBn),
            ),
          ),
        ]);
  }

  Widget _musicCard(ColorScheme scheme) {
    final opts = <(String, String, String?)>[
      ('auto', t.vaMusicAuto, null),
      ('youtube', 'YouTube', VaNative.pkgYoutube),
      ('ytmusic', 'YouTube Music', VaNative.pkgYtMusic),
      ('spotify', 'Spotify', VaNative.pkgSpotify),
    ];
    return _card(scheme,
        icon: Icons.library_music_rounded,
        title: t.vaMusicTitle,
        children: [
          Text(t.vaMusicBody, style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.sm),
          RadioGroup<String>(
            groupValue: _music,
            onChanged: (v) async {
              if (v == null) return;
              setState(() => _music = v);
              await Settings.setString(VaExecutor.musicPrefKey, v);
            },
            child: Column(children: [
              for (final o in opts)
                RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  value: o.$1,
                  title: Text(o.$2),
                  subtitle: o.$3 == null
                      ? Text(t.vaMusicAutoSub)
                      : (widget.debugStatic
                          ? null
                          : Text(_installed.contains(o.$3)
                              ? t.vaMusicInstalled
                              : t.vaMusicNotInstalled)),
                ),
            ]),
          ),
          Text(t.vaMusicHonest,
              style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
        ]);
  }

  Widget _examplesCard(ColorScheme scheme) {
    final ex = [
      t.vaExCall,
      t.vaExSms,
      t.vaExYoutube,
      t.vaExSong,
      t.vaExAlarm,
      t.vaExTimer,
      t.vaExTorch,
      t.vaExMaps,
      t.vaExReminder,
      t.vaExExpense,
      t.vaExOpenApp,
      t.vaExSos,
    ];
    return _card(scheme,
        icon: Icons.tips_and_updates_rounded,
        title: t.vaTryTitle,
        children: [
          for (final e in ex)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.sm),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.mic_none_rounded, size: 18, color: scheme.primary),
                const SizedBox(width: Gap.sm),
                Expanded(child: Text('“$e”')),
              ]),
            ),
          const SizedBox(height: Gap.xs),
          Text(t.vaConfirmNote,
              style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
        ]);
  }
}
