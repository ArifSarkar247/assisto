import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../voice/va_actions.dart';
import '../voice/va_native.dart';
import '../voice/va_wake.dart';
import '../voice/va_wake_logic.dart';
import 'wake_disclosure_screen.dart';
import 'wake_oem_guide_screen.dart';

/// Assisto Voice settings: make Assisto the phone's default digital
/// assistant, the optional hands-free "Hey Assisto" wake word (k1-wake:
/// openWakeWord, on-device; OFF by default, prominent disclosure before the
/// first enable, sensitivity, pause, honest limits), and spoken replies.
class VoiceAssistantSettingsScreen extends StatefulWidget {
  /// Gallery/tests: skip native + network probes.
  final bool debugStatic;

  /// Gallery/tests: the wake-word state to render with [debugStatic]
  /// (default: model available, switched off).
  final WakeStatus? debugWake;
  const VoiceAssistantSettingsScreen(
      {super.key, this.debugStatic = false, this.debugWake});

  @override
  State<VoiceAssistantSettingsScreen> createState() =>
      _VoiceAssistantSettingsScreenState();
}


class _VoiceAssistantSettingsScreenState
    extends State<VoiceAssistantSettingsScreen> with WidgetsBindingObserver {
  bool? _isDefault; // null = unknown
  bool _native = false;
  bool _loaded = false;
  VaWakeConfig _cfg = const VaWakeConfig();
  WakeStatus _wake = WakeStatus.unknown;
  WakeLevel _level = WakeLevel.normal;
  bool _engine = false;
  double? _progress; // model download
  String? _wakeError;
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
    final level = await VaWake.level();
    if (widget.debugStatic) {
      if (mounted) {
        setState(() {
          _tts = tts;
          _music = music;
          _level = level;
          _loaded = true;
          _engine = true;
          _cfg = const VaWakeConfig(available: true, reason: '');
          _wake = widget.debugWake ?? const WakeStatus(WakeRun.off);
        });
      }
      return;
    }
    final native = await VaNative.available();
    final isDef = native ? await VaNative.isDefaultAssistant() : null;
    if (!mounted) return;
    final cfg = await VaWake.fetchConfig(context.read<AppState>().api);
    final st = native ? await VaWake.status() : WakeStatus.unknown;
    final installed = native ? await VaNative.musicApps() : const <String>[];
    if (!mounted) return;
    setState(() {
      _tts = tts;
      _music = music;
      _installed = installed;
      _native = native;
      _isDefault = isDef;
      _cfg = cfg;
      _wake = st;
      _level = level;
      _engine = native && st.run != WakeRun.engineMissing && st.run != WakeRun.unknown;
      _loaded = true;
    });
  }

  WakeBlock _block({required bool disclosure}) => VaWakeGate.check(
        modelAvailable: _cfg.available,
        serverReason: _cfg.reason,
        engineBundled: _engine,
        disclosureAccepted: disclosure,
      );

  Future<void> _toggleWake(bool on) async {
    if (_busy) return;
    if (!on) {
      setState(() => _busy = true);
      if (!widget.debugStatic) await VaWake.stop();
      if (mounted) setState(() => _busy = false);
      await _load();
      return;
    }
    // Prominent disclosure BEFORE the permission prompt (Play policy).
    if (!await VaWake.disclosureAccepted()) {
      if (!mounted) return;
      final ok = await WakeDisclosureScreen.show(context);
      if (!ok) return;
      await VaWake.acceptDisclosure();
    }
    if (_block(disclosure: true) != WakeBlock.none || !mounted) return;
    if (widget.debugStatic) {
      // gallery/tests: no plugins — show the "listening" state
      setState(() => _wake = const WakeStatus(WakeRun.listening, wanted: true));
      return;
    }
    setState(() {
      _busy = true;
      _wakeError = null;
    });
    try {
      final mic = await Permission.microphone.request();
      if (!mic.isGranted) {
        _snack(t.voiceNoPermission);
        return;
      }
      try {
        await Permission.notification.request();
      } catch (_) {}
      if (!mounted) return;
      final r = await VaWake.start(_cfg, _level, VaWake.texts(t),
          onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      });
      if (r == 'running') return;
      _wakeError = switch (r) {
        'engine_missing' || null => t.vaWkStatusEngineMissing,
        'error:download' || 'error:model_hash' => t.vaWkDownloadFailed,
        _ => t.vaWkStatusError,
      };
      _snack(_wakeError!);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
      await Future.delayed(const Duration(milliseconds: 600));
      await _load();
    }
  }

  Future<void> _setLevel(WakeLevel l) async {
    setState(() => _level = l);
    await VaWake.setLevel(l);
    if (widget.debugStatic || !_wake.isOn) return;
    // apply now: restart the listener with the new threshold
    await VaWake.start(_cfg, l, VaWake.texts(t));
    await _load();
  }

  Future<void> _pause(bool pause) async {
    if (widget.debugStatic) return;
    if (pause) {
      await VaNative.wakePause(60);
    } else {
      await VaNative.wakeResume();
    }
    await Future.delayed(const Duration(milliseconds: 400));
    await _load();
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
          _wakeCard(scheme),
          const SizedBox(height: Gap.lg),
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
        ? (Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF7BE0B0)
            : const Color(0xFF1B6E4A))
        : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: 6),
      decoration: BoxDecoration(
          color: bg, borderRadius: BorderRadius.circular(Radii.pill)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(good ? Icons.check_circle : Icons.info_outline, size: 16, color: fg),
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
                style: TextStyle(
                    color: scheme.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                    fontSize: 12)),
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
        icon: Icons.assistant_outlined,
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
            child: Text(
                '${t.vaDefColorOs}\n\n${t.vaDefSamsungNote}\n\n${t.vaDefXiaomiNote}\n\n${t.vaDefPowerNote}',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
          ),
          const SizedBox(height: Gap.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: !_native && !widget.debugStatic
                  ? () => _snack(t.vaNeedsUpdate)
                  : () async {
                      final ok = await VaNative.openAssistantSettings();
                      if (!ok) _snack(t.vaNeedsUpdate);
                    },
              icon: const Icon(Icons.open_in_new),
              label: Text(t.vaDefOpenSettings),
            ),
          ),
          const SizedBox(height: Gap.sm),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: widget.debugStatic
                  ? () {}
                  : () async {
                      final r = await VaNative.openPowerKeySettings();
                      if (r == null || r == 'none') _snack(t.vaDefOpenFailed);
                    },
              icon: const Icon(Icons.power_settings_new),
              label: Text(t.vaDefPowerKey),
            ),
          ),
        ]);
  }

  String _pausedUntilLabel(DateTime? at) => at == null
      ? ''
      : MaterialLocalizations.of(context)
          .formatTimeOfDay(TimeOfDay.fromDateTime(at));

  /// Status line of the wake card + whether it is a "good" state.
  (String, bool) _wakeNote() {
    if (!_loaded) return (t.vaWakeChecking, false);
    switch (_block(disclosure: true)) {
      case WakeBlock.modelPending:
        return (t.vaWkStatusPending, false);
      case WakeBlock.licencePending:
        return (t.vaWkStatusLicence, false);
      case WakeBlock.engineMissing:
        return (t.vaWkStatusEngineMissing, false);
      case WakeBlock.needsDisclosure:
      case WakeBlock.none:
        break;
    }
    if (_progress != null) return (t.vaWkStatusDownloading, false);
    final w = _wake;
    if (w.run == WakeRun.listening) return (t.vaWkStatusListening, true);
    if (w.run == WakeRun.paused) {
      return (
        switch (w.reason) {
          'user' => t.vaWkStatusPausedUser(_pausedUntilLabel(w.pausedUntil)),
          'battery' => t.vaWkStatusPausedBattery,
          'call' => t.vaWkStatusPausedCall,
          'mic_busy' => t.vaWkStatusPausedMic,
          _ => t.vaWkStatusPausedWake,
        },
        false
      );
    }
    if (w.needsRestart) return (t.vaWkStatusBlocked, false);
    if (w.run == WakeRun.error) return (_wakeError ?? t.vaWkStatusError, false);
    return (t.vaWkStatusOff, false);
  }

  Widget _note(ColorScheme scheme, IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.sm),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.sm),
          Expanded(
              child: Text(text,
                  style:
                      TextStyle(color: scheme.onSurfaceVariant, fontSize: 13))),
        ]),
      );

  Widget _wakeCard(ColorScheme scheme) {
    final on = _wake.isOn;
    final blocked = _block(disclosure: true) != WakeBlock.none;
    final (note, good) = _wakeNote();
    final levelSub = switch (_level) {
      WakeLevel.low => t.vaWkSensLowSub,
      WakeLevel.normal => t.vaWkSensNormalSub,
      WakeLevel.high => t.vaWkSensHighSub,
    };
    return _card(scheme,
        icon: Icons.hearing_outlined,
        title: t.vaWkTitle,
        trailing: _busy
            ? SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                    strokeWidth: 2, value: _progress))
            : Switch(
                key: const Key('va-wake-switch'),
                value: on,
                onChanged: blocked && !on ? null : _toggleWake,
              ),
        children: [
          Text(t.vaWkBody, style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.md),
          _statusChip(scheme, note, good: good),
          if (on) ...[
            const SizedBox(height: Gap.sm),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: _wake.run == WakeRun.paused && _wake.reason == 'user'
                  ? TextButton.icon(
                      onPressed: () => _pause(false),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: Text(t.vaWkResume))
                  : TextButton.icon(
                      onPressed: () => _pause(true),
                      icon: const Icon(Icons.pause_rounded),
                      label: Text(t.vaWkPause1h)),
            ),
          ],
          if (!blocked) ...[
            const SizedBox(height: Gap.md),
            Text(t.vaWkSensitivity,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: Gap.sm),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<WakeLevel>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: WakeLevel.low, label: Text(t.vaWkSensLow)),
                  ButtonSegment(
                      value: WakeLevel.normal, label: Text(t.vaWkSensNormal)),
                  ButtonSegment(value: WakeLevel.high, label: Text(t.vaWkSensHigh)),
                ],
                selected: {_level},
                onSelectionChanged: _busy ? null : (v) => _setLevel(v.first),
              ),
            ),
            const SizedBox(height: Gap.xs),
            Text(levelSub,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
          ],
          const SizedBox(height: Gap.md),
          _note(scheme, Icons.lock_outline, t.vaWkPrivacy),
          _note(scheme, Icons.pause_circle_outline, t.vaWkAutoPause),
          _note(scheme, Icons.battery_alert_outlined, t.vaWkBatteryNote),
          _note(scheme, Icons.screen_lock_portrait_outlined, t.vaWkLockedNote),
          _note(scheme, Icons.verified_user_outlined, t.vaWkLockRules),
          _note(scheme, Icons.restart_alt, t.vaWkRebootNote),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => WakeOemGuideScreen(
                          debugMaker: widget.debugStatic ? 'realme' : null))),
              icon: const Icon(Icons.battery_saver_outlined),
              label: Text(t.vaWkOemGuide),
            ),
          ),
        ]);
  }

  Widget _ttsCard(ColorScheme scheme) {
    return _card(scheme,
        icon: Icons.record_voice_over_outlined,
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
                if (!ok) _snack(t.vaNeedsUpdate);
              },
              icon: const Icon(Icons.download_outlined),
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
        icon: Icons.library_music_outlined,
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
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
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
        icon: Icons.tips_and_updates_outlined,
        title: t.vaTryTitle,
        children: [
          for (final e in ex)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.sm),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.mic_none, size: 18, color: scheme.primary),
                const SizedBox(width: Gap.sm),
                Expanded(child: Text('“$e”')),
              ]),
            ),
          const SizedBox(height: Gap.xs),
          Text(t.vaConfirmNote,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
        ]);
  }
}
