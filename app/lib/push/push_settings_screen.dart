import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../notifications.dart';
import '../screens/battery_guidance_screen.dart';
import '../state.dart';
import '../ds/ds.dart';
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
          final ds = DsTokens.of(context);
          final perm = _Card(
                icon: _permOn == false
                    ? Icons.notifications_off_rounded
                    : Icons.check_circle_outline_rounded,
                tint: _permOn == false ? ds.dangerInk : ds.successInk,
                title: t.pushSetPermTitle,
                body: _permOn == false ? t.pushSetPermOff : t.pushSetPermOn,
                action: _permOn == false
                    ? DsButton(onPressed: _allow, label: t.pushSetAllow)
                    : null,
              );
          return ListView(
            padding: const EdgeInsets.all(Gap.lg),
            children: [
              // designv2 page rule: a blocked permission is the urgent thing — first
              if (_permOn == false) ...[perm, const SizedBox(height: Gap.md)],
              _Card(
                icon: deliveryOk
                    ? Icons.notifications_active_rounded
                    : Icons.notifications_paused_rounded,
                tint: deliveryOk ? ds.successInk : Brand.warnInk(context),
                title: t.pushSetDeliveryTitle,
                body: deliveryBody,
              ),
              const SizedBox(height: Gap.md),
              if (_permOn != false) ...[perm, const SizedBox(height: Gap.md)],
              _Card(
                icon: Icons.ring_volume_rounded,
                tint: ds.primaryInk,
                title: t.pushSetFsiTitle,
                body: t.pushSetFsiBody,
                action: DsButton.secondary(
                  onPressed: () async {
                    if (!widget.probe) return;
                    if (Platform.isAndroid) {
                      await PushNotifier.requestFullScreenIntent();
                    }
                  },
                  icon: Icons.open_in_new_rounded,
                  label: t.pushSetFsiOpen,
                ),
              ),
              const SizedBox(height: Gap.md),
              _Card(
                icon: Icons.battery_alert_rounded,
                tint: Brand.warnInk(context),
                title: t.pushSetBatteryTitle,
                body: t.pushSetBatteryBody,
                action: DsButton.secondary(
                  onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const BatteryGuidanceScreen())),
                  label: t.pushSetBatteryOpen,
                ),
              ),
              const SizedBox(height: Gap.md),
              _Card(
                icon: Icons.tune_rounded,
                tint: ds.primaryInk,
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
    final ds = DsTokens.of(context);
    return DsCard(
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: tint.withValues(alpha: ds.isDark ? 0.22 : 0.12),
            borderRadius: BorderRadius.circular(DsRadius.card),
          ),
          child: Icon(icon, color: tint, size: 24),
        ),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700, color: ds.text)),
            const SizedBox(height: Gap.xs),
            Text(body,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: ds.muted, height: 1.4)),
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
