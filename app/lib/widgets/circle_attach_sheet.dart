import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// The "+" attach sheet for a circle chat. Lists every media kind
/// (gallery/camera/voice/video/document/contact/current+live location). Each
/// kind is KEY-GATED until encrypted blob storage is enabled (mirrors
/// core/logic/circle_media.py media_gate_notice + circle.py media_available):
/// gated rows show a lock and, on tap, a "Available when encrypted storage
/// enabled" notice instead of opening a (non-existent) picker.
enum CircleAttachKind { gallery, camera, voice, video, document, contact, location, liveLocation }

/// Returns the chosen attach kind (the screen decides gated vs live). Only
/// kinds whose storage is available actually proceed; the rest surface a
/// gated-reason snackbar handled by the caller.
Future<CircleAttachKind?> showCircleAttachSheet(BuildContext context) {
  final t = AppLocalizations.of(context);
  final scheme = Theme.of(context).colorScheme;

  Widget grid(IconData icon, String label, CircleAttachKind kind, {bool gated = true}) {
    return InkWell(
      borderRadius: BorderRadius.circular(Radii.md),
      onTap: () => Navigator.pop(context, kind),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                CircleAvatar(
                  radius: 26,
                  backgroundColor: scheme.secondaryContainer,
                  child: Icon(icon, color: scheme.onSecondaryContainer),
                ),
                if (gated)
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: CircleAvatar(
                      radius: 9,
                      backgroundColor: scheme.surface,
                      child: Icon(Icons.lock_clock_outlined,
                          size: 12, color: scheme.onSurfaceVariant),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: Gap.xs),
            SizedBox(
              width: 72,
              child: Text(label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  style: const TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }

  return showModalBottomSheet<CircleAttachKind>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
        child: GridView.count(
          crossAxisCount: 4,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          // db1: 0.82 clipped two-line labels by 12px at 360dp (tap sweep).
          childAspectRatio: 0.68,
          children: [
            grid(Icons.photo_library_outlined, t.circleAttachGallery, CircleAttachKind.gallery),
            grid(Icons.photo_camera_outlined, t.circleAttachCamera, CircleAttachKind.camera),
            grid(Icons.mic_none_outlined, t.circleVoiceNote, CircleAttachKind.voice),
            grid(Icons.videocam_outlined, t.circleVideo, CircleAttachKind.video),
            grid(Icons.insert_drive_file_outlined, t.circleAttachDocument, CircleAttachKind.document),
            grid(Icons.contact_page_outlined, t.circleAttachContact, CircleAttachKind.contact),
            grid(Icons.location_on_outlined, t.circleAttachLocation, CircleAttachKind.location),
            grid(Icons.my_location_outlined, t.circleAttachLiveLocation, CircleAttachKind.liveLocation),
          ],
        ),
      ),
    ),
  );
}

/// The live-location duration chooser (15m / 1h / 8h) — mirrors
/// circle_media.LIVE_DURATIONS_MIN. Returns the duration key.
Future<String?> showLiveLocationDurations(BuildContext context) {
  final t = AppLocalizations.of(context);
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.timer_outlined),
            title: Text(t.circleLive15m),
            onTap: () => Navigator.pop(ctx, '15m'),
          ),
          ListTile(
            leading: const Icon(Icons.timer_outlined),
            title: Text(t.circleLive1h),
            onTap: () => Navigator.pop(ctx, '1h'),
          ),
          ListTile(
            leading: const Icon(Icons.timer_outlined),
            title: Text(t.circleLive8h),
            onTap: () => Navigator.pop(ctx, '8h'),
          ),
        ],
      ),
    ),
  );
}
