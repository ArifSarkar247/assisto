import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../voice/va_native.dart';
import '../voice/va_wake.dart';

/// Assisto Voice settings: make Assisto the phone's default digital
/// assistant, the optional "Hey Assisto" wake word (OFF by default, key-gated,
/// honest about battery/privacy), and spoken replies.
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
    if (widget.debugStatic) {
      if (mounted) {
        setState(() {
          _tts = tts;
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
    if (!mounted) return;
    setState(() {
      _tts = tts;
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
        icon: const Icon(Icons.hearing),
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
      } catch (_) {}
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
          _wakeCard(scheme),
          const SizedBox(height: Gap.lg),
          _ttsCard(scheme),
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
          Text(t.vaDefBody,
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
            child: Text(t.vaDefColorOs,
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
        ]);
  }

  Widget _wakeCard(ColorScheme scheme) {
    final running = _wake == _Wake.running;
    final canToggle = running || _wake == _Wake.ready;
    final note = switch (_wake) {
      _Wake.loading => t.vaWakeChecking,
      _Wake.keyMissing => t.vaWakeComing,
      _Wake.engineMissing => t.vaWakeEngineMissing,
      _Wake.ready => t.vaWakeOffNote,
      _Wake.running => t.vaWakeOnNote,
      _Wake.error => t.vaWakeStartFailed,
    };
    return _card(scheme,
        icon: Icons.hearing_outlined,
        title: t.vaWakeTitle,
        trailing: _busy
            ? const SizedBox(
                width: 24,
                height: 24,
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
            Icon(Icons.battery_alert_outlined,
                size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: Text(t.vaWakeBattery,
                    style: TextStyle(
                        color: scheme.onSurfaceVariant, fontSize: 13))),
          ]),
          const SizedBox(height: Gap.sm),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.lock_outline, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: Text(t.vaWakePrivacy,
                    style: TextStyle(
                        color: scheme.onSurfaceVariant, fontSize: 13))),
          ]),
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

  Widget _examplesCard(ColorScheme scheme) {
    final ex = [
      t.vaExCall,
      t.vaExSms,
      t.vaExYoutube,
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
