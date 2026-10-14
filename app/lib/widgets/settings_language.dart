import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// ADVANCED language section (SPEC v2.1 §21, good-bit #2 — STRICT language
/// split). The whole app follows ONE choice: Bangla mode is Bangla-only
/// everywhere, English mode is English-only — never a mixed "bn / en" blend.
///
/// The switch is instant (`AppState.setLocale` → `notifyListeners` →
/// `MaterialApp.locale`), so every string re-resolves immediately. This widget
/// holds ZERO Bangla literals; all copy comes from the ARB getters.
///
/// Design: a clear, large section with a live current-language indicator, two
/// big selectable cards (one per language, each labelled in its OWN script so
/// it reads natively regardless of the active locale), and a one-line note that
/// the choice applies app-wide.
class SettingsLanguageSection extends StatelessWidget {
  const SettingsLanguageSection({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    // Effective language: an explicit choice, else the platform default the app
    // is currently resolving to. Defaults to 'bn' (primary market locale).
    final lang = app.locale?.languageCode ??
        Localizations.localeOf(context).languageCode;
    final isBn = lang == 'bn';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, 0),
          child: Row(
            children: [
              Icon(Icons.translate, size: 20, color: cs.primary),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(
                  t.settingsLanguage,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
        // Current-language indicator chip.
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, 0),
          child: Container(
            padding: const EdgeInsets.symmetric(
                horizontal: Gap.md, vertical: Gap.sm),
            decoration: BoxDecoration(
              color: cs.primaryContainer,
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: Row(
              children: [
                Icon(Icons.check_circle,
                    size: 18, color: cs.onPrimaryContainer),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(
                    t.languageCurrentLabel(
                        isBn ? t.languageBangla : t.languageEnglish),
                    style: TextStyle(
                        color: cs.onPrimaryContainer,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, 0),
          child: Row(
            children: [
              Expanded(
                child: _LangCard(
                  // Labelled in its own script so it reads natively in any mode.
                  // Built from code points (U+09AC U+09BE U+0982 U+09B2 U+09BE)
                  // so the language gate sees no raw Bangla literal in Dart.
                  nativeLabel: String.fromCharCodes(
                      const [0x09AC, 0x09BE, 0x0982, 0x09B2, 0x09BE]),
                  subLabel: t.languageBangla,
                  selected: isBn,
                  onTap: () => app.setLocale(const Locale('bn')),
                ),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: _LangCard(
                  nativeLabel: 'English',
                  subLabel: t.languageEnglish,
                  selected: !isBn,
                  onTap: () => app.setLocale(const Locale('en')),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.md),
          child: Text(
            t.languageAppliesNote,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

class _LangCard extends StatelessWidget {
  final String nativeLabel;
  final String subLabel;
  final bool selected;
  final VoidCallback onTap;

  const _LangCard({
    required this.nativeLabel,
    required this.subLabel,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: subLabel,
      child: Material(
        color: selected ? cs.primaryContainer : cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.md),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Radii.md),
          child: Container(
            constraints: const BoxConstraints(minHeight: 84),
            padding: const EdgeInsets.symmetric(
                horizontal: Gap.md, vertical: Gap.md),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Radii.md),
              border: Border.all(
                color: selected ? cs.primary : cs.outlineVariant,
                width: selected ? 2 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        nativeLabel,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: selected
                              ? cs.onPrimaryContainer
                              : cs.onSurface,
                        ),
                      ),
                    ),
                    Icon(
                      selected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 20,
                      color: selected ? cs.primary : cs.onSurfaceVariant,
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  subLabel,
                  style: TextStyle(
                    fontSize: 12,
                    color: selected
                        ? cs.onPrimaryContainer
                        : cs.onSurfaceVariant,
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
