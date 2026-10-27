import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// healthfit (owner decision 27 Oct): the health & fitness screens
/// (Water/sleep/food, Fitness partner, Smartwatch & fitness, Mood & energy
/// journal) stay SHOWN in Play as "Health and Fitness" — never medical. Every
/// one of them shows this "not medical advice" line in a fixed strip at the
/// bottom of the screen, in every state (loading, empty, error, data), so it
/// is always visible and never hidden in a menu. Wraps at any font size.
///
/// Use as `Scaffold(bottomNavigationBar: const HealthDisclaimerBar())`.
class HealthDisclaimerBar extends StatelessWidget {
  const HealthDisclaimerBar({super.key});

  /// Finder key for tests (one per screen).
  static const Key barKey = Key('health-not-medical-advice');

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Material(
      key: barKey,
      color: scheme.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        child: Semantics(
          container: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: Gap.md, vertical: Gap.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded,
                    size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(
                    tr.hfNotMedicalAdvice,
                    style: AType.bodySmall.copyWith(
                        color: scheme.onSurface, height: 1.35),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
