import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../l10n/app_localizations.dart';
import '../widgets/app_sheet.dart';
import 'audio_route_service.dart';

/// audioroute: icon + bn/en label of a route (route button + sheet).
IconData audioRouteIcon(AudioRoute r) => switch (r) {
      AudioRoute.earpiece => Icons.phone_in_talk_rounded,
      AudioRoute.speaker => Icons.volume_up_rounded,
      AudioRoute.bluetooth => Icons.bluetooth_audio_rounded,
      AudioRoute.wired => Icons.headphones_rounded,
    };

String audioRouteLabel(AppLocalizations t, AudioRoute r) => switch (r) {
      AudioRoute.earpiece => t.arRouteEarpiece,
      AudioRoute.speaker => t.arRouteSpeaker,
      AudioRoute.bluetooth => t.arRouteBluetooth,
      AudioRoute.wired => t.arRouteWired,
    };

/// The route picker: earpiece / speaker / Bluetooth (device name) / wired.
/// The active one is ticked (and "selected" for TalkBack); every row is a
/// ≥48 dp tap target; labels wrap (never clipped at 200 % text).
class AudioRouteSheet extends StatelessWidget {
  const AudioRouteSheet({
    super.key,
    required this.routes,
    required this.active,
    required this.onPick,
    this.bluetoothName,
    this.bluetoothDenied = false,
  });

  final List<AudioRoute> routes;
  final AudioRoute? active;
  final ValueChanged<AudioRoute> onPick;

  /// "AirPods Pro" — shown as the Bluetooth row's title when known.
  final String? bluetoothName;

  /// Android 12+ "Nearby devices" refused: honest note + Settings button.
  final bool bluetoothDenied;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final name = (bluetoothName ?? '').trim();
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Semantics(
                header: true,
                child: Text(t.arRouteSheetTitle,
                    style: theme.textTheme.titleMedium),
              ),
            ),
            for (final r in routes)
              ListTile(
                key: Key('call-route-${r.name}'),
                minTileHeight: 56,
                selected: r == active,
                leading: Icon(audioRouteIcon(r)),
                title: Text(
                  r == AudioRoute.bluetooth && name.isNotEmpty
                      ? name
                      : audioRouteLabel(t, r),
                ),
                subtitle: r == AudioRoute.bluetooth && name.isNotEmpty
                    ? Text(t.arRouteBluetooth)
                    : null,
                trailing: r == active
                    ? Icon(Icons.check_rounded,
                        semanticLabel: t.arRouteSelected)
                    : null,
                onTap: () => onPick(r),
              ),
            if (bluetoothDenied)
              Padding(
                key: const Key('call-route-bt-denied'),
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.arBtDenied, style: theme.textTheme.bodyMedium),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () => openAppSettings(),
                      child: Text(t.arOpenSettings),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// Android 12+ "Nearby devices" (BLUETOOTH_CONNECT) — asked ONLY when a
/// Bluetooth audio device is connected (or the user tapped Bluetooth), after
/// a short bn/en reason sheet. Refused = the call goes on (earpiece/speaker).
Future<bool> askNearbyDevicesForAudio(BuildContext context) async {
  try {
    if (await Permission.bluetoothConnect.isGranted) return true;
  } catch (_) {
    return true; // can't tell: don't block the call
  }
  if (!context.mounted) return false;
  final t = AppLocalizations.of(context);
  final go = await showAppSheet<bool>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          key: const Key('audio-bt-permission-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.bluetooth_audio_rounded),
              const SizedBox(width: 12),
              Expanded(
                child: Text(t.arBtPermTitle,
                    style: Theme.of(ctx).textTheme.titleMedium),
              ),
            ]),
            const SizedBox(height: 12),
            Text(t.arBtPermBody),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                TextButton(
                  key: const Key('audio-bt-permission-later'),
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text(t.arBtPermNotNow),
                ),
                FilledButton(
                  key: const Key('audio-bt-permission-allow'),
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: Text(t.arBtPermAllow),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  if (go != true) return false;
  try {
    return (await Permission.bluetoothConnect.request()).isGranted;
  } catch (_) {
    return false;
  }
}
