import '../l10n/app_localizations.dart';
// Photo Enhance (ADVANCED, SPEC §21) — one-tap presets.
//
// Presets are just NAMED BUNDLES of the same faithful adjustments the manual
// sliders expose (brightness / contrast / saturation / sharpness) — nothing is
// fabricated, nothing is invented. The "Passport / ID size" preset does NOT
// edit identity; it links out to the existing web passport-size tool (exact
// mm/px crop + resize), keeping the honest "we never alter IDs" promise.
import 'package:flutter/material.dart';
import 'photo_strings.dart';

/// A faithful adjustment bundle. Values match the editor's slider ranges:
///   brightness/contrast/saturation: multiplier around 1.0
///   sharpness: 0..1 overlay strength
class PhotoAdjustments {
  const PhotoAdjustments({
    this.brightness = 1.0,
    this.contrast = 1.0,
    this.saturation = 1.0,
    this.sharpness = 0.0,
    this.rotationQuarters = 0,
    this.straightenDeg = 0.0,
    this.squareCrop = false,
  });

  final double brightness;
  final double contrast;
  final double saturation;
  final double sharpness;
  final int rotationQuarters; // 0..3 (×90°)
  final double straightenDeg; // -15..15
  final bool squareCrop;

  PhotoAdjustments copyWith({
    double? brightness,
    double? contrast,
    double? saturation,
    double? sharpness,
    int? rotationQuarters,
    double? straightenDeg,
    bool? squareCrop,
  }) =>
      PhotoAdjustments(
        brightness: brightness ?? this.brightness,
        contrast: contrast ?? this.contrast,
        saturation: saturation ?? this.saturation,
        sharpness: sharpness ?? this.sharpness,
        rotationQuarters: rotationQuarters ?? this.rotationQuarters,
        straightenDeg: straightenDeg ?? this.straightenDeg,
        squareCrop: squareCrop ?? this.squareCrop,
      );

  bool get isNeutral =>
      brightness == 1.0 &&
      contrast == 1.0 &&
      saturation == 1.0 &&
      sharpness == 0.0 &&
      rotationQuarters == 0 &&
      straightenDeg == 0.0 &&
      !squareCrop;
}

/// A single preset: id, labels (via string keys), icon, and the bundle it
/// applies. `linksToWebTool` presets don't apply pixels locally — they open an
/// external exact-size tool instead (passport/ID).
class PhotoPreset {
  const PhotoPreset(
    this.id,
    this.labelKey,
    this.descKey,
    this.icon,
    this.adjustments, {
    this.linksToWebTool = false,
  });
  final String id;
  final String labelKey;
  final String descKey;
  final IconData icon;
  final PhotoAdjustments adjustments;
  final bool linksToWebTool;
}

const List<PhotoPreset> kPhotoPresets = [
  PhotoPreset(
    'document',
    'phPresetDoc',
    'phPresetDocDesc',
    Icons.description_outlined,
    PhotoAdjustments(
        brightness: 1.08, contrast: 1.35, saturation: 0.85, sharpness: 0.6),
  ),
  PhotoPreset(
    'portrait',
    'phPresetPortrait',
    'phPresetPortraitDesc',
    Icons.face_outlined,
    PhotoAdjustments(
        brightness: 1.05, contrast: 1.05, saturation: 1.08, sharpness: 0.2),
  ),
  PhotoPreset(
    'passport',
    'phPresetPassport',
    'phPresetPassportDesc',
    Icons.badge_outlined,
    PhotoAdjustments(),
    linksToWebTool: true,
  ),
];

class PhotoPresetBar extends StatelessWidget {
  const PhotoPresetBar({
    super.key,
    required this.selectedId,
    required this.onApply,
    required this.onOpenWebTool,
  });

  final String? selectedId;
  final void Function(PhotoPreset) onApply;
  final VoidCallback onOpenWebTool;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final p in kPhotoPresets)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _PresetTile(
              preset: p,
              selected: selectedId == p.id,
              scheme: scheme,
              onTap: () => p.linksToWebTool ? onOpenWebTool() : onApply(p),
            ),
          ),
      ],
    );
  }
}

class _PresetTile extends StatelessWidget {
  const _PresetTile({
    required this.preset,
    required this.selected,
    required this.scheme,
    required this.onTap,
  });
  final PhotoPreset preset;
  final bool selected;
  final ColorScheme scheme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = phLabel(context, preset.labelKey);
    final desc = phLabel(context, preset.descKey);
    return Semantics(
      button: true,
      selected: selected,
      label: '$label. $desc',
      child: Material(
        color: selected
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Icon(preset.icon,
                  color: selected
                      ? scheme.onPrimaryContainer
                      : scheme.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: selected
                                ? scheme.onPrimaryContainer
                                : scheme.onSurface)),
                    const SizedBox(height: 2),
                    Text(desc,
                        style: TextStyle(
                            fontSize: 12,
                            color: selected
                                ? scheme.onPrimaryContainer
                                : scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              if (preset.linksToWebTool)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(AppLocalizations.of(context).phPresetPassportOpen,
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: scheme.primary)),
                  const SizedBox(width: 2),
                  Icon(Icons.open_in_new, size: 15, color: scheme.primary),
                ])
              else if (selected)
                Icon(Icons.check_circle, color: scheme.primary, size: 20),
            ]),
          ),
        ),
      ),
    );
  }
}
