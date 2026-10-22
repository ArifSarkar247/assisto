import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/circle_media_gate.dart';
import '../theme.dart';

/// The "+" attach sheet for a circle chat.
///
/// mr1 — NO SHOWPIECES: every kind here needs My Circle's encrypted media
/// storage ([kCircleMediaStorageOn]); none of them can really be sent until
/// that ships (see .phaseB/proposals/mr1-media.md). So [circleAttachKinds]
/// lists ONLY kinds that really work today — currently none — and the chat
/// hides the attach button entirely when the list is empty. Nothing in the
/// sheet ever answers "available when encrypted storage is enabled".
enum CircleAttachKind { gallery, camera, voice, video, document, contact, location, liveLocation }

/// The kinds that can really be sent right now, in sheet order.
List<CircleAttachKind> circleAttachKinds({bool? storageOn}) {
  final on = storageOn ?? kCircleMediaStorageOn;
  if (!on) return const [];
  return const [
    CircleAttachKind.gallery,
    CircleAttachKind.camera,
    CircleAttachKind.voice,
    CircleAttachKind.video,
    CircleAttachKind.document,
    CircleAttachKind.contact,
    CircleAttachKind.location,
    CircleAttachKind.liveLocation,
  ];
}

/// Returns the chosen attach kind, or null. Only shows [circleAttachKinds].
Future<CircleAttachKind?> showCircleAttachSheet(BuildContext context,
    {List<CircleAttachKind>? kinds}) {
  final t = AppLocalizations.of(context);
  final scheme = Theme.of(context).colorScheme;
  final list = kinds ?? circleAttachKinds();

  (IconData, String) look(CircleAttachKind k) => switch (k) {
        CircleAttachKind.gallery => (Icons.photo_library_outlined, t.circleAttachGallery),
        CircleAttachKind.camera => (Icons.photo_camera_outlined, t.circleAttachCamera),
        CircleAttachKind.voice => (Icons.mic_none_outlined, t.circleVoiceNote),
        CircleAttachKind.video => (Icons.videocam_outlined, t.circleVideo),
        CircleAttachKind.document => (Icons.insert_drive_file_outlined, t.circleAttachDocument),
        CircleAttachKind.contact => (Icons.contact_page_outlined, t.circleAttachContact),
        CircleAttachKind.location => (Icons.location_on_outlined, t.circleAttachLocation),
        CircleAttachKind.liveLocation => (Icons.my_location_outlined, t.circleAttachLiveLocation),
      };

  Widget grid(BuildContext ctx, CircleAttachKind kind) {
    final (icon, label) = look(kind);
    return InkWell(
      key: Key('attach-${kind.name}'),
      borderRadius: BorderRadius.circular(Radii.md),
      onTap: () => Navigator.pop(ctx, kind),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: scheme.secondaryContainer,
              child: Icon(icon, color: scheme.onSecondaryContainer),
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

  if (list.isEmpty) return Future.value(null);
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
          children: [for (final k in list) grid(ctx, k)],
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
