import 'package:flutter/material.dart';

import '../theme.dart';
import '../l10n/app_localizations.dart';

/// Per-chat wallpaper + theme picker (M2 item 9). ON-DEVICE preference only —
/// nothing is uploaded. The chosen wallpaper id + theme are persisted locally by
/// the caller (SharedPreferences, keyed by chat id). Mirrors
/// core/logic/circle_extras.BUILTIN_WALLPAPERS / CHAT_THEMES /
/// build_chat_settings — the ids here MUST match the backend catalog.
class WallpaperChoice {
  final String id;
  final List<Color> colors; // original gradient we ship (not copied art)
  final Brightness? forceBrightness;
  const WallpaperChoice(this.id, this.colors, {this.forceBrightness});
}

/// The ORIGINAL built-in wallpapers — brand gradients (cyan -> blue -> purple)
/// plus a few calm neutrals. ids match circle_extras.BUILTIN_WALLPAPERS.
const kBuiltinWallpapers = <WallpaperChoice>[
  WallpaperChoice('default', [Color(0xFF0E1116), Color(0xFF161B22)],
      forceBrightness: Brightness.dark),
  WallpaperChoice('cyan_blue', [Brand.cyan, Brand.blue]),
  WallpaperChoice('blue_purple', [Brand.blue, Brand.purple]),
  WallpaperChoice('night_ink', [Color(0xFF05060A), Color(0xFF14203A)],
      forceBrightness: Brightness.dark),
  WallpaperChoice('paper_warm', [Color(0xFFF6EFE4), Color(0xFFEADFC9)],
      forceBrightness: Brightness.light),
  WallpaperChoice('forest_calm', [Color(0xFF123B2E), Color(0xFF1E6B4F)]),
];

WallpaperChoice wallpaperById(String id) => kBuiltinWallpapers.firstWhere(
      (w) => w.id == id,
      orElse: () => kBuiltinWallpapers.first,
    );

/// A decoration the chat screen can paint behind the message list.
BoxDecoration wallpaperDecoration(String id) {
  final w = wallpaperById(id);
  return BoxDecoration(
    gradient: LinearGradient(
      colors: w.colors,
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ),
  );
}

class WallpaperThemePicker extends StatelessWidget {
  final String wallpaperId;
  final String themeId; // 'system' | 'light' | 'dark'
  final ValueChanged<String> onWallpaper;
  final ValueChanged<String> onTheme;
  final VoidCallback? onFromPhoto;
  const WallpaperThemePicker({
    super.key,
    required this.wallpaperId,
    required this.themeId,
    required this.onWallpaper,
    required this.onTheme,
    this.onFromPhoto,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    String label(String id) {
      switch (id) {
        case 'cyan_blue':
          return t.circleExtrasWpCyanBlue;
        case 'blue_purple':
          return t.circleExtrasWpBluePurple;
        case 'night_ink':
          return t.circleExtrasWpNightInk;
        case 'paper_warm':
          return t.circleExtrasWpPaperWarm;
        case 'forest_calm':
          return t.circleExtrasWpForestCalm;
        default:
          return t.circleExtrasWpDefault;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xs),
          child: Text(t.circleExtrasWallpaperHint,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ),
        // QA a6: fixed 112px overflowed (label 2 lines) and clipped at
        // large font — height grows with the user's text size.
        SizedBox(
          height: 88 + MediaQuery.textScalerOf(context).scale(34),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
            itemCount: kBuiltinWallpapers.length,
            separatorBuilder: (_, __) => const SizedBox(width: Gap.md),
            itemBuilder: (_, i) {
              final w = kBuiltinWallpapers[i];
              final selected = w.id == wallpaperId;
              return GestureDetector(
                onTap: () => onWallpaper(w.id),
                child: Column(
                  children: [
                    Container(
                      width: 64,
                      height: 80,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                            colors: w.colors,
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight),
                        borderRadius: BorderRadius.circular(Radii.md),
                        border: Border.all(
                          color: selected ? scheme.primary : scheme.outlineVariant,
                          width: selected ? 2.5 : 1,
                        ),
                      ),
                      child: selected
                          ? const Icon(Icons.check, color: Colors.white, size: 20)
                          : null,
                    ),
                    const SizedBox(height: Gap.xs),
                    SizedBox(
                      width: 68,
                      child: Text(label(w.id),
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 10)),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        if (onFromPhoto != null)
          ListTile(
            leading: const Icon(Icons.add_photo_alternate_outlined),
            title: Text(t.circleExtrasFromMyPhoto),
            subtitle: Text(t.circleExtrasOnDeviceOnly,
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
            onTap: onFromPhoto,
          ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xs),
          child: Text(t.circleExtrasChatTheme,
              style: Theme.of(context).textTheme.titleSmall),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.md),
          child: SegmentedButton<String>(
            segments: [
              // one line per label, scaled to fit ("Syste m" at 1.5x)
              for (final (v, l) in [
                ('system', t.circleExtrasThemeSystem),
                ('light', t.circleExtrasThemeLight),
                ('dark', t.circleExtrasThemeDark),
              ])
                ButtonSegment(
                    value: v,
                    label: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(l, maxLines: 1, softWrap: false))),
            ],
            selected: {themeId},
            onSelectionChanged: (s) => onTheme(s.first),
          ),
        ),
      ],
    );
  }
}
