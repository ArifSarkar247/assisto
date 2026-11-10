import 'dart:typed_data';

import 'package:assisto/widgets/app_sheet.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// sjstart2 (owner Safe Journey V2, item 6): an OPTIONAL photo of the
/// vehicle's number plate on the START screen (CNG, Uber, Pathao, bus). It is
/// sent to the watchers right after the journey starts through the same
/// POST /journey/<id>/vehicle-photo the live screen uses — one upload path,
/// one privacy rule (deleted with the journey's locations).
///
/// Camera intent / system photo picker only: no storage or camera
/// permission is added (owner 9 Nov 14:20 Play rule).
bool sj2PlatePhotoFits(String? mode, String? rideApp) =>
    rideApp != null ||
    const {null, 'cng', 'car', 'bike', 'bus', 'local_bus', 'long_bus', 'ride', 'rickshaw'}
        .contains(mode);

/// Picks one photo (camera or gallery), small enough for a phone upload.
/// [picker] is swappable for tests.
Future<Uint8List?> sj2PickPlatePhoto(BuildContext context,
    {Future<Uint8List?> Function(ImageSource src)? picker}) async {
  final t = AppLocalizations.of(context);
  final src = await showAppSheet<ImageSource>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
            key: const ValueKey('sj2_plate_camera'),
            leading: const Icon(Icons.photo_camera_rounded),
            title: Text(t.j100VehiclePhotoCamera),
            onTap: () => Navigator.pop(ctx, ImageSource.camera)),
        ListTile(
            key: const ValueKey('sj2_plate_gallery'),
            leading: const Icon(Icons.photo_library_rounded),
            title: Text(t.j100VehiclePhotoPick),
            onTap: () => Navigator.pop(ctx, ImageSource.gallery)),
      ]),
    ),
  );
  if (src == null) return null;
  if (picker != null) return picker(src);
  final x = await ImagePicker()
      .pickImage(source: src, maxWidth: 1280, maxHeight: 1280, imageQuality: 70);
  return x == null ? null : x.readAsBytes();
}

class JourneyPlatePhotoTile extends StatelessWidget {
  const JourneyPlatePhotoTile({
    super.key,
    required this.bytes,
    required this.onPick,
    required this.onRemove,
  });
  final Uint8List? bytes;
  final VoidCallback onPick;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final b = bytes;
    return Container(
      key: const ValueKey('sj2_plate_tile'),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        border: Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(Radii.sm),
          child: SizedBox(
            width: 64,
            height: 64,
            child: b == null
                ? ColoredBox(
                    color: cs.surfaceContainerHighest,
                    child: Icon(Icons.directions_car_filled_rounded, color: cs.onSurfaceVariant))
                : Image.memory(b, fit: BoxFit.cover, semanticLabel: t.sj2PlateAdded),
          ),
        ),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(b == null ? t.sj2PlateTitle : t.sj2PlateAdded,
                style: AType.titleSmall.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: Gap.xxs),
            Text(t.sj2PlateHint, style: AType.bodySmall.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: Gap.xs),
            Wrap(spacing: Gap.sm, children: [
              TextButton.icon(
                key: const ValueKey('sj2_plate_pick'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: onPick,
                icon: Icon(b == null ? Icons.add_a_photo_rounded : Icons.cached_rounded),
                label: Text(b == null ? t.sj2PlateAdd : t.sj2PlateChange),
              ),
              if (b != null)
                TextButton.icon(
                  key: const ValueKey('sj2_plate_remove'),
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: onRemove,
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: Text(t.sj2PlateRemove),
                ),
            ]),
          ]),
        ),
      ]),
    );
  }
}
