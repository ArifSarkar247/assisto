import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/circle_media_gate.dart';
import '../theme.dart';

/// The "+" attach sheet for a circle chat.
///
/// NO SHOWPIECES: [circleAttachKinds] lists ONLY kinds that really send end
/// to end (md1: photo from the gallery or camera, voice message, document;
/// mc-media2: video, contact card, location, live location —
/// [kCircleChatMediaKinds]); anything else stays hidden until really built. The chat hides the "+" button when the list is empty
/// (and during a message request: media only after acceptance).
enum CircleAttachKind { gallery, camera, voice, video, document, contact, location, liveLocation }

/// The kinds that can really be sent right now, in sheet order.
List<CircleAttachKind> circleAttachKinds({Set<String>? kinds}) {
  final on = kinds ?? kCircleChatMediaKinds;
  return [
    if (on.contains('photo')) CircleAttachKind.gallery,
    if (on.contains('photo')) CircleAttachKind.camera,
    if (on.contains('voice')) CircleAttachKind.voice,
    if (on.contains('video')) CircleAttachKind.video,
    if (on.contains('document')) CircleAttachKind.document,
    if (on.contains('contact')) CircleAttachKind.contact,
    if (on.contains('location')) CircleAttachKind.location,
    if (on.contains('live_location')) CircleAttachKind.liveLocation,
  ];
}

/// Returns the chosen attach kind, or null. Only shows [circleAttachKinds].
Future<CircleAttachKind?> showCircleAttachSheet(BuildContext context,
    {List<CircleAttachKind>? kinds}) {
  final list = kinds ?? circleAttachKinds();
  if (list.isEmpty) return Future.value(null);
  return showModalBottomSheet<CircleAttachKind>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: CircleAttachGrid(kinds: list, onPick: (k) => Navigator.pop(ctx, k)),
    ),
  );
}

/// The sheet's grid (also used by the gallery shot).
class CircleAttachGrid extends StatelessWidget {
  final List<CircleAttachKind> kinds;
  final ValueChanged<CircleAttachKind> onPick;
  const CircleAttachGrid({super.key, required this.kinds, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    (IconData, String) look(CircleAttachKind k) => switch (k) {
          CircleAttachKind.gallery => (Icons.photo_library_rounded, t.circleAttachGallery),
          CircleAttachKind.camera => (Icons.photo_camera_rounded, t.circleAttachCamera),
          CircleAttachKind.voice => (Icons.mic_none_rounded, t.circleVoiceNote),
          CircleAttachKind.video => (Icons.videocam_rounded, t.circleVideo),
          CircleAttachKind.document => (Icons.insert_drive_file_rounded, t.circleAttachDocument),
          CircleAttachKind.contact => (Icons.contact_page_rounded, t.circleAttachContact),
          CircleAttachKind.location => (Icons.location_on_rounded, t.circleAttachLocation),
          CircleAttachKind.liveLocation => (Icons.my_location_rounded, t.circleAttachLiveLocation),
        };

    Widget cell(CircleAttachKind kind) {
      final (icon, label) = look(kind);
      return InkWell(
        key: Key('attach-${kind.name}'),
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: () => onPick(kind),
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

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
      child: LayoutBuilder(builder: (context, c) {
        // a11y1: the two label lines grow with the phone's font size; give
        // the cell that extra height (identical at 1.0, overflowed at 1.3).
        final cellW = c.maxWidth / 4;
        final grow = (MediaQuery.textScalerOf(context).scale(12) - 12) * 2 * 1.7;
        return GridView.count(
          crossAxisCount: 4,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          // db1: 0.82 clipped two-line labels by 12px at 360dp (tap sweep).
          childAspectRatio: cellW / (cellW / 0.68 + (grow > 0 ? grow : 0)),
          children: [for (final k in kinds) cell(k)],
        );
      }),
    );
  }
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
            leading: const Icon(Icons.timer_rounded),
            title: Text(t.circleLive15m),
            onTap: () => Navigator.pop(ctx, '15m'),
          ),
          ListTile(
            leading: const Icon(Icons.timer_rounded),
            title: Text(t.circleLive1h),
            onTap: () => Navigator.pop(ctx, '1h'),
          ),
          ListTile(
            leading: const Icon(Icons.timer_rounded),
            title: Text(t.circleLive8h),
            onTap: () => Navigator.pop(ctx, '8h'),
          ),
        ],
      ),
    ),
  );
}
