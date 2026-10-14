import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import 'offline_strings.dart';

/// Reusable OFFLINE indicator (#12, SPEC v2.1 §21). Any screen can drop this in
/// to tell the user — honestly and consistently — that it is showing a saved
/// copy. It listens to [AppState.online] and renders NOTHING while online, so a
/// screen can place it unconditionally at the top of its body.
///
/// Two forms:
///   • [OfflineBanner] — a full-width strip for the top of a screen body.
///   • [OfflineBanner.chip] — a compact pill for an app-bar / dense layout.
///
/// WCAG: uses the theme's tertiaryContainer / onTertiaryContainer pair (AA in
/// both light and dark) rather than a hard-coded colour, and pairs the icon
/// with text (never colour-only). NO Bangla glyph literals (SPEC §21).
class OfflineBanner extends StatelessWidget {
  /// Optional override text (e.g. a module-specific "showing saved list"); when
  /// null the generic offline subtitle is used.
  final String? message;

  /// Compact pill variant for tight spaces.
  final bool _chip;

  const OfflineBanner({super.key, this.message}) : _chip = false;
  const OfflineBanner.chip({super.key, this.message}) : _chip = true;

  @override
  Widget build(BuildContext context) {
    final online = context.select<AppState, bool>((s) => s.online);
    if (online) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final text = message ?? oStr(context, 'offStatusOfflineSub');

    if (_chip) {
      return Semantics(
        liveRegion: true,
        label: oStr(context, 'offStatusOffline'),
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xs),
          decoration: BoxDecoration(
            color: scheme.tertiaryContainer,
            borderRadius: BorderRadius.circular(Radii.pill),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.cloud_off_outlined,
                size: 14, color: scheme.onTertiaryContainer),
            const SizedBox(width: Gap.xs),
            Text(oStr(context, 'offStatusOffline'),
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: scheme.onTertiaryContainer)),
          ]),
        ),
      );
    }

    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: scheme.tertiaryContainer,
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Row(children: [
          Icon(Icons.cloud_off_outlined,
              size: 18, color: scheme.onTertiaryContainer),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 13, color: scheme.onTertiaryContainer)),
          ),
        ]),
      ),
    );
  }
}
