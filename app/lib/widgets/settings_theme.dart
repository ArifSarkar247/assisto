import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// ADVANCED theme picker (SPEC v2.1 §21, good-bit #19).
///
/// Three options — follow system (default) / light / dark — shown as visual
/// preview cards. Each card paints a MINIATURE of the real app surfaces built
/// from the matching [AssistoTheme] ColorScheme (a tiny bar + two bubbles), so
/// the choice is seen, not just read. The "follow system" preview splits
/// light|dark to signal it tracks the OS.
///
/// Applies instantly via `AppState.setThemeMode` (persists to prefs and calls
/// `notifyListeners`, which rebuilds `MaterialApp.themeMode`). Zero Bangla
/// literals — copy comes from ARB getters.
class SettingsThemeSection extends StatelessWidget {
  const SettingsThemeSection({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final mode = app.themeMode;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, 0),
          child: Row(
            children: [
              Icon(Icons.palette_outlined, size: 20, color: cs.primary),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(
                  t.settingsAppearance,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, 0),
          child: Row(
            children: [
              Expanded(
                child: _ThemeCard(
                  label: t.themeSystem,
                  mode: ThemeMode.system,
                  selected: mode == ThemeMode.system,
                  onTap: () => app.setThemeMode(ThemeMode.system),
                ),
              ),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: _ThemeCard(
                  label: t.themeLight,
                  mode: ThemeMode.light,
                  selected: mode == ThemeMode.light,
                  onTap: () => app.setThemeMode(ThemeMode.light),
                ),
              ),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: _ThemeCard(
                  label: t.themeDark,
                  mode: ThemeMode.dark,
                  selected: mode == ThemeMode.dark,
                  onTap: () => app.setThemeMode(ThemeMode.dark),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.md),
          child: Text(
            t.themeFollowSystemNote,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

class _ThemeCard extends StatelessWidget {
  final String label;
  final ThemeMode mode;
  final bool selected;
  final VoidCallback onTap;

  const _ThemeCard({
    required this.label,
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Radii.md),
          child: Container(
            padding: const EdgeInsets.all(Gap.sm),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Radii.md),
              border: Border.all(
                color: selected ? cs.primary : cs.outlineVariant,
                width: selected ? 2 : 1,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _preview(),
                const SizedBox(height: Gap.sm),
                // Radio on its own line so the (sometimes long, e.g. Bangla
                // "ডিফল্ট (ফোন অনুযায়ী)") label gets the FULL card width and
                // wraps instead of truncating.
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 16,
                  color: selected ? cs.primary : cs.onSurfaceVariant,
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  softWrap: true,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.15,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? cs.primary : cs.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// A mini app-surface rendered from the REAL target ColorScheme. For
  /// [ThemeMode.system] it shows a diagonal light|dark split.
  Widget _preview() {
    final light = AssistoTheme.light.colorScheme;
    final dark = AssistoTheme.dark.colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(Radii.sm),
      child: SizedBox(
        height: 54,
        width: double.infinity,
        child: mode == ThemeMode.system
            ? Row(
                children: [
                  Expanded(child: _swatch(light)),
                  Expanded(child: _swatch(dark)),
                ],
              )
            : _swatch(mode == ThemeMode.dark ? dark : light),
      ),
    );
  }

  Widget _swatch(ColorScheme s) {
    return Container(
      color: s.surface,
      padding: const EdgeInsets.all(6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Faux app bar.
          Container(
            height: 6,
            width: double.infinity,
            decoration: BoxDecoration(
              color: s.primary,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(height: 5),
          // Incoming bubble.
          Container(
            height: 8,
            width: 26,
            decoration: BoxDecoration(
              color: s.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(height: 4),
          // Outgoing (brand) bubble, right-aligned.
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              height: 8,
              width: 22,
              decoration: BoxDecoration(
                color: s.secondary,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
