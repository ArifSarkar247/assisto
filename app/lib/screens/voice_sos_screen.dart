import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../widgets/permission_reason.dart';
import '../widgets/voice_sos_config.dart';
import '../widgets/voice_sos_service.dart';

/// Hands-free Voice SOS opt-in screen (feature #79).
///
/// Lets the user turn on always-listening SOS, pick a safe wake phrase, and
/// clearly understand the trade-offs (persistent notification, battery, and
/// on-device privacy). OFF by default. Enabling runs an honest permission flow
/// (microphone + notifications), then starts the foreground service. The
/// service, on hearing the phrase, fires the EXISTING SOS (see
/// VoiceSosManager._fireSos -> api.journeySos).
///
/// No Bangla literals — all copy comes from AppLocalizations.
class VoiceSosScreen extends StatefulWidget {
  const VoiceSosScreen({super.key});
  @override
  State<VoiceSosScreen> createState() => _VoiceSosScreenState();
}

class _VoiceSosScreenState extends State<VoiceSosScreen>
    with WidgetsBindingObserver {
  bool _loading = true;
  bool _enabled = false;
  bool _running = false;
  bool _busy = false;
  bool _micBlocked = false; // permanently denied -> show "Open settings"
  bool _unavailable = false; // no on-device speech engine
  String _phrase = VoiceSosConfig.defaultPhrases.first;

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    VoiceSosManager.instance.onUnavailable = () {
      if (mounted) setState(() => _unavailable = true);
    };
    VoiceSosManager.instance.onListening = () {
      if (mounted) setState(() => _unavailable = false);
    };
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    VoiceSosManager.instance.onUnavailable = null;
    VoiceSosManager.instance.onListening = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !Platform.isIOS) _refreshMic();
  }

  Future<void> _load() async {
    // iOS: the always-on foreground service does not exist. Don't query it or
    // the mic status for a feature we won't offer here; just render the honest
    // Android-only state.
    if (Platform.isIOS) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    _enabled = await VoiceSosConfig.isEnabled();
    _phrase = await VoiceSosConfig.phrase();
    _running = await VoiceSosManager.instance.isRunning();
    await _refreshMic();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _refreshMic() async {
    final s = await Permission.microphone.status;
    if (mounted) setState(() => _micBlocked = s.isPermanentlyDenied);
  }

  Future<void> _toggle(bool on) async {
    if (Platform.isIOS) return; // no always-on foreground service on iOS
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      if (on) {
        // 1) Honest reason dialog BEFORE the OS prompt.
        final wants = await showPermissionReason(context, PermKind.mic);
        if (!wants || !mounted) return;
        // 2) Request microphone.
        final mic = await Permission.microphone.request();
        if (!mounted) return;
        if (!mic.isGranted) {
          setState(() => _micBlocked = mic.isPermanentlyDenied);
          messenger.showSnackBar(SnackBar(content: Text(t.vsosMicDenied)));
          return;
        }
        // 3) Notification permission (Android 13+) — the FGS notification.
        await VoiceSosManager.instance.init(
          t.vsosNotifChannelName,
          t.vsosNotifChannelDesc,
          t.vsosNotifTitle,
          t.vsosNotifText,
        );
        VoiceSosManager.instance.attach(context.read<AppState>());
        // 4) Start the service.
        final ok = await VoiceSosManager.instance
            .start(t.vsosNotifTitle, t.vsosNotifText);
        if (!mounted) return;
        if (!ok) {
          messenger.showSnackBar(SnackBar(content: Text(t.vsosStartFailed)));
          return;
        }
        await VoiceSosConfig.setEnabled(true);
        setState(() {
          _enabled = true;
          _running = true;
        });
      } else {
        await VoiceSosManager.instance.stop();
        await VoiceSosConfig.setEnabled(false);
        setState(() {
          _enabled = false;
          _running = false;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickPhrase() async {
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return SimpleDialog(
          title: Text(t.vsosPhraseTitle),
          children: [
            for (final p in VoiceSosConfig.defaultPhrases)
              ListTile(
                leading: Icon(p == _phrase
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked),
                title: Text(p),
                onTap: () => Navigator.pop(ctx, p),
              ),
          ],
        );
      },
    );
    if (chosen == null) return;
    await VoiceSosConfig.setPhrase(chosen);
    VoiceSosManager.instance.updatePhrase(chosen);
    if (mounted) setState(() => _phrase = chosen);
  }

  @override
  Widget build(BuildContext context) {
    // iOS: an always-listening foreground microphone service is not possible
    // (background audio is restricted). Show an honest Android-only state; the
    // foreground-service plugin is never started here. Manual SOS still works.
    if (Platform.isIOS) {
      return Scaffold(
        appBar: AppBar(title: Text(t.vsosTitle)),
        body: _iosOnly(),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(t.vsosTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(Gap.lg),
              children: [
                _header(),
                const SizedBox(height: Gap.lg),
                _mainToggle(),
                if (_unavailable) ...[
                  const SizedBox(height: Gap.md),
                  _notice(Icons.mic_off_outlined, Brand.warning,
                      t.vsosUnavailable),
                ],
                if (_micBlocked) ...[
                  const SizedBox(height: Gap.md),
                  _blockedCard(),
                ],
                const SizedBox(height: Gap.lg),
                _phraseTile(),
                const SizedBox(height: Gap.lg),
                _batteryNote(),
                const SizedBox(height: Gap.md),
                _privacyNote(),
                const SizedBox(height: Gap.md),
                _runningNote(),
              ],
            ),
    );
  }

  /// Honest iOS state: hands-free Voice SOS is Android-only for now.
  Widget _iosOnly() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.hearing_disabled,
                size: 56, color: cs.onSurfaceVariant),
            const SizedBox(height: Gap.md),
            Text(
              t.iosAndroidOnlyTitle,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: Gap.sm),
            Text(
              t.vsosIosOnlyBody,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: cs.onSurfaceVariant, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    final cs = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(Icons.record_voice_over_outlined, color: cs.primary, size: 28),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(t.vsosHeadline,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800)),
        ),
      ]),
      const SizedBox(height: Gap.sm),
      Text(t.vsosIntro,
          style: TextStyle(color: cs.onSurfaceVariant, height: 1.4)),
    ]);
  }

  Widget _mainToggle() {
    return Card(
      child: SwitchListTile(
        value: _enabled,
        onChanged: _busy ? null : _toggle,
        secondary: Icon(_enabled ? Icons.hearing : Icons.hearing_disabled,
            color: _enabled ? Brand.danger : Colors.grey),
        title: Text(t.vsosEnableTitle,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(_enabled ? t.vsosStateOn : t.vsosStateOff),
      ),
    );
  }

  Widget _phraseTile() {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.campaign_outlined),
        title: Text(t.vsosPhraseLabel),
        subtitle: Text('"$_phrase"',
            style: const TextStyle(fontWeight: FontWeight.w700)),
        trailing: TextButton(
            onPressed: _pickPhrase, child: Text(t.vsosChange)),
      ),
    );
  }

  Widget _batteryNote() =>
      _notice(Icons.battery_alert_outlined, Brand.warning, t.vsosBatteryNote);

  Widget _privacyNote() =>
      _notice(Icons.lock_outline, Brand.success, t.vsosPrivacyNote);

  Widget _runningNote() {
    if (!_enabled) return const SizedBox.shrink();
    return _notice(
        Icons.notifications_active_outlined,
        Theme.of(context).colorScheme.primary,
        _running ? t.vsosRunningNote : t.vsosNotRunningNote);
  }

  Widget _notice(IconData icon, Color color, String text) {
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: Gap.sm),
        Expanded(
            child: Text(text,
                style: const TextStyle(fontSize: 13, height: 1.4))),
      ]),
    );
  }

  Widget _blockedCard() {
    return Container(
      padding: const EdgeInsets.all(Gap.lg),
      decoration: BoxDecoration(
        color: Brand.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: Brand.danger.withValues(alpha: 0.3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.mic_off, color: Brand.danger, size: 20),
          const SizedBox(width: Gap.sm),
          Expanded(
              child: Text(t.vsosMicBlocked,
                  style: const TextStyle(fontWeight: FontWeight.w700))),
        ]),
        const SizedBox(height: Gap.sm),
        Text(t.vsosMicBlockedBody, style: const TextStyle(fontSize: 13)),
        const SizedBox(height: Gap.md),
        FilledButton.icon(
          onPressed: openAppSettings,
          icon: const Icon(Icons.settings, size: 18),
          label: Text(t.vsosOpenSettings),
        ),
      ]),
    );
  }
}
