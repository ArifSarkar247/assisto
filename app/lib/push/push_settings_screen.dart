import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../notifications.dart';
import '../screens/battery_guidance_screen.dart';
import '../state.dart';
import '../theme.dart';
import 'push_api.dart';
import 'push_notifier.dart';
import 'push_service.dart';

/// Settings → Notifications & calls. States the push situation HONESTLY:
/// whether this build has Firebase, whether the server has push keys, whether
/// Android lets us post notifications, and (Android 14+) how to allow
/// full-screen incoming calls.
class PushSettingsScreen extends StatefulWidget {
  const PushSettingsScreen({super.key, this.probe = true});

  /// false in widget tests/gallery: skip platform + network probes.
  final bool probe;

  @override
  State<PushSettingsScreen> createState() => _PushSettingsScreenState();
}

class _PushSettingsScreenState extends State<PushSettingsScreen> {
  bool? _permOn;
  bool? _serverOn;

  @override
  void initState() {
    super.initState();
    if (widget.probe) _load();
  }

  Future<void> _load() async {
    final perm = await Notifications.isEnabled();
    bool? server;
    try {
      final r = await context.read<AppState>().api.pushStatus();
      server = r['available'] == true;
    } catch (_) {
      server = null;
    }
    if (!mounted) return;
    setState(() {
      _permOn = perm;
      _serverOn = server;
    });
  }

  Future<void> _allow() async {
    final ok = await Notifications.requestPermission();
    if (!ok) await Notifications.openSettings();
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.pushSetTitle)),
      body: ValueListenableBuilder<bool>(
        valueListenable: PushService.instance.available,
        builder: (context, buildOn, _) {
          final String deliveryBody;
          final bool deliveryOk;
          if (!buildOn) {
            deliveryBody = t.pushSetDeliveryOffBuild;
            deliveryOk = false;
          } else if (_serverOn == false) {
            deliveryBody = t.pushSetDeliveryOffServer;
            deliveryOk = false;
          } else {
            deliveryBody = t.pushSetDeliveryOn;
            deliveryOk = true;
          }
          return ListView(
            padding: const EdgeInsets.all(Gap.lg),
            children: [
              _Card(
                icon: deliveryOk
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_paused_outlined,
                tint: deliveryOk ? Brand.success : Brand.warning,
                title: t.pushSetDeliveryTitle,
                body: deliveryBody,
              ),
              const SizedBox(height: Gap.md),
              _Card(
                icon: _permOn == false
                    ? Icons.notifications_off_outlined
                    : Icons.check_circle_outline,
                tint: _permOn == false ? Brand.danger : scheme.primary,
                title: t.pushSetPermTitle,
                body: _permOn == false ? t.pushSetPermOff : t.pushSetPermOn,
                action: _permOn == false
                    ? FilledButton(
                        onPressed: _allow, child: Text(t.pushSetAllow))
                    : null,
              ),
              const SizedBox(height: Gap.md),
              _Card(
                icon: Icons.ring_volume_outlined,
                tint: scheme.tertiary,
                title: t.pushSetFsiTitle,
                body: t.pushSetFsiBody,
                action: OutlinedButton.icon(
                  onPressed: () async {
                    if (!widget.probe) return;
                    if (Platform.isAndroid) {
                      await PushNotifier.requestFullScreenIntent();
                    }
                  },
                  icon: const Icon(Icons.open_in_new),
                  label: Text(t.pushSetFsiOpen),
                ),
              ),
              const SizedBox(height: Gap.md),
              _Card(
                icon: Icons.battery_alert_outlined,
                tint: scheme.secondary,
                title: t.pushSetBatteryTitle,
                body: t.pushSetBatteryBody,
                action: OutlinedButton(
                  onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const BatteryGuidanceScreen())),
                  child: Text(t.pushSetBatteryOpen),
                ),
              ),
              const SizedBox(height: Gap.md),
              _Card(
                icon: Icons.tune,
                tint: scheme.primary,
                title: t.pushSetChannelsTitle,
                body: t.pushSetChannelsBody,
                action: TextButton(
                  onPressed: () =>
                      widget.probe ? Notifications.openSettings() : null,
                  child: Text(t.pushSetOpenSystem),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.icon,
    required this.tint,
    required this.title,
    required this.body,
    this.action,
  });

  final IconData icon;
  final Color tint;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.lg),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: tint, size: 26),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: Gap.xs),
            Text(body,
                style:
                    TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
            if (action != null) ...[
              const SizedBox(height: Gap.md),
              Align(alignment: AlignmentDirectional.centerStart, child: action!),
            ],
          ]),
        ),
      ]),
    );
  }
}
