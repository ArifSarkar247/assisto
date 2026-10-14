import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// ADVANCED AI autonomy dial (SPEC v2.1 §21, good-bit #8).
///
/// Four levels — remind-only (1) → suggest (2) → approve (3) → auto (4) — shown
/// as a visual stepped dial/slider. As you move the dial the active level's
/// title + a plain-language description of what the AI WILL and WON'T do
/// without asking updates live. A per-module override hint and a standing
/// "you're always in control" reassurance make the ceiling explicit.
///
/// Persists through `AppState.setAutonomy` → `ApiClient.updateProfile`
/// (`autonomy_level`), with an offline-optimistic fallback. Zero Bangla
/// literals — all copy is from ARB getters.
class SettingsAutonomySection extends StatelessWidget {
  const SettingsAutonomySection({super.key});

  static Map<int, List<String>> _levels(AppLocalizations t) => {
        1: [t.autonomyRemindOnlyTitle, t.autonomyRemindOnlyDesc],
        2: [t.autonomySuggestTitle, t.autonomySuggestDesc],
        3: [t.autonomyApproveTitle, t.autonomyApproveDesc],
        4: [t.autonomyAutoTitle, t.autonomyAutoDesc],
      };

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final level = (app.user?.autonomyLevel ?? 2).clamp(1, 4);
    final levels = _levels(t);
    final current = levels[level]!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, 0),
          child: Row(
            children: [
              Icon(Icons.smart_toy_outlined, size: 20, color: cs.primary),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(
                  t.autonomyDialTitle,
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
          padding: const EdgeInsets.fromLTRB(Gap.lg, 2, Gap.lg, 0),
          child: Text(
            t.autonomyDialHint,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ),
        // Stepped dial with a tick label under each notch.
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 0),
          child: Column(
            children: [
              Slider(
                value: level.toDouble(),
                min: 1,
                max: 4,
                divisions: 3,
                label: current[0],
                onChanged: (v) => app.setAutonomy(v.round()),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    for (var i = 1; i <= 4; i++)
                      Expanded(
                        child: Align(
                          alignment: i == 1
                              ? Alignment.centerLeft
                              : i == 4
                                  ? Alignment.centerRight
                                  : Alignment.center,
                          child: Text(
                            '$i',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: i == level
                                  ? FontWeight.w800
                                  : FontWeight.w400,
                              color: i == level
                                  ? cs.primary
                                  : cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        // Live card: active level title + what it will / won't do.
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, 0),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(
              color: cs.primaryContainer,
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.tune, size: 18, color: cs.onPrimaryContainer),
                    const SizedBox(width: Gap.sm),
                    Expanded(
                      child: Text(
                        current[0],
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          color: cs.onPrimaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Gap.xs),
                Text(
                  current[1],
                  style: TextStyle(
                      fontSize: 13, color: cs.onPrimaryContainer, height: 1.4),
                ),
              ],
            ),
          ),
        ),
        // Per-module override hint.
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.dashboard_customize_outlined,
                  size: 16, color: cs.onSurfaceVariant),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(
                  t.autonomyPerModuleHint,
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
        // Standing "you're always in control" reassurance.
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.verified_user_outlined, size: 16, color: cs.primary),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(
                  t.autonomyInControlNote,
                  style: TextStyle(
                      fontSize: 12,
                      color: cs.primary,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
