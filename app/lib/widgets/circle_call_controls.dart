import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// In-call control bar for the Connected Circle voice/video call screen.
///
/// Mirrors the server-side control flags in core/logic/circle_calls.py
/// (default_controls / toggle_control): mute, speaker, camera on/off,
/// switch-camera, low-data mode. The screen owns the state; this widget only
/// renders + reports taps. No Bangla literals — every label is an
/// AppLocalizations key (the integrator adds them from the report's ARB JSON).
class CircleCallControls extends StatelessWidget {
  final bool isVideo;
  final bool muted;
  final bool speakerOn;
  final bool cameraOn;
  final bool lowData;
  final VoidCallback onToggleMute;
  final VoidCallback onToggleSpeaker;
  final VoidCallback onToggleCamera;
  final VoidCallback onSwitchCamera;
  final VoidCallback onToggleLowData;
  final VoidCallback onHangup;

  const CircleCallControls({
    super.key,
    required this.isVideo,
    required this.muted,
    required this.speakerOn,
    required this.cameraOn,
    required this.lowData,
    required this.onToggleMute,
    required this.onToggleSpeaker,
    required this.onToggleCamera,
    required this.onSwitchCamera,
    required this.onToggleLowData,
    required this.onHangup,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              alignment: WrapAlignment.center,
              spacing: Gap.lg,
              runSpacing: Gap.md,
              children: [
                _CallButton(
                  icon: muted ? Icons.mic_off : Icons.mic,
                  label: t.circleCallMute,
                  active: muted,
                  onTap: onToggleMute,
                ),
                _CallButton(
                  icon: speakerOn ? Icons.volume_up : Icons.volume_down,
                  label: t.circleCallSpeaker,
                  active: speakerOn,
                  onTap: onToggleSpeaker,
                ),
                if (isVideo) ...[
                  _CallButton(
                    icon: cameraOn ? Icons.videocam : Icons.videocam_off,
                    label: t.circleCallCamera,
                    active: !cameraOn,
                    onTap: onToggleCamera,
                  ),
                  _CallButton(
                    icon: Icons.cameraswitch_outlined,
                    label: t.circleCallSwitchCamera,
                    active: false,
                    onTap: onSwitchCamera,
                  ),
                ],
                _CallButton(
                  icon: lowData ? Icons.data_saver_on : Icons.data_saver_off,
                  label: t.circleCallLowData,
                  active: lowData,
                  onTap: onToggleLowData,
                ),
              ],
            ),
            const SizedBox(height: Gap.xl),
            FloatingActionButton(
              heroTag: 'circle_call_hangup',
              backgroundColor: Brand.danger,
              foregroundColor: Colors.white,
              onPressed: onHangup,
              child: const Icon(Icons.call_end),
            ),
          ],
        ),
      ),
    );
  }
}

class _CallButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _CallButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = active ? scheme.primary : scheme.surfaceContainerHighest;
    final fg = active ? scheme.onPrimary : scheme.onSurface;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: bg,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Icon(icon, color: fg),
            ),
          ),
        ),
        const SizedBox(height: Gap.xs),
        SizedBox(
          width: 64,
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

/// A small banner stating exactly what call transport works right now — mirrors
/// core/logic/circle_calls.py transport_status(). Honest: "works while the app
/// is open"; app-closed ring + TURN are key-gated.
class CircleCallTransportBanner extends StatelessWidget {
  final bool pushReady;
  final bool turnReady;
  const CircleCallTransportBanner({
    super.key,
    this.pushReady = false,
    this.turnReady = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.all(Gap.sm),
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline,
              size: 16, color: scheme.onSecondaryContainer),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(
              pushReady && turnReady
                  ? t.circleCallTransportFull
                  : pushReady
                      ? t.circleCallTransportPush
                      : t.circleCallTransportAppOpen,
              style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSecondaryContainer,
                  height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
}
