import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../widgets/notif_models.dart' show notifLocalizeDigits;
import '../widgets/a11y_prefs.dart';

/// TRUE ACCESSIBILITY MODE (#200, SPEC v2.1 §20, ADVANCED).
///
/// A dedicated accessibility settings surface. Six real preferences, each
/// persisted to SharedPreferences via [A11yPrefs] and applied app-wide from
/// [AssistoApp]:
///   * Large text        — a 5-step scale (1.0–1.6×) overriding MediaQuery's
///                          textScaler; every Text in the app grows live.
///   * High contrast     — flips MediaQuery.highContrast + a higher-contrast
///                          theme (stronger outlines / pure fg-bg).
///   * Reduce motion     — sets MediaQuery.disableAnimations; implicit
///                          animations + page transitions soften.
///   * Simplified layout — an opt-in hint screens MAY honour (fewer decorative
///                          bits). Honestly labelled "where supported"; the app
///                          also ships a full Elderly simple-mode home.
///   * Screen-reader hints — adds extra in-app Semantics labels on icon-only
///                          controls. The OS reader (TalkBack/VoiceOver) must be
///                          enabled separately — the screen says so.
///   * Haptic feedback   — a preference other features check before buzzing;
///                          toggling it on fires a live confirmation buzz.
///
/// HONEST ABOUT REACH. Each toggle's subtitle states exactly what it does today.
/// Nothing claims an OS capability it can't deliver.
class AccessibilityModeScreen extends StatelessWidget {
  const AccessibilityModeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final a = A11yScope.of(context); // listens — rebuilds on every change
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(t.a11yTitle),
        actions: [
          if (a.anyActive)
            TextButton(
              onPressed: () => _resetConfirm(context, a, t),
              child: Text(t.a11yReset),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(0, Gap.sm, 0, Gap.xxl),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.lg),
            child: Text(t.a11yIntro,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant, height: 1.45)),
          ),

          // ---- Large text ----
          _SectionLabel(label: t.a11ySectionDisplay),
          _TextScaleTile(prefs: a, t: t),

          // live preview so the user sees the chosen scale before leaving
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.md),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(Radii.md),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.a11yPreviewLabel,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: cs.onSurfaceVariant)),
                  const SizedBox(height: Gap.xs),
                  Text(t.a11yPreviewSample,
                      style: Theme.of(context).textTheme.bodyLarge),
                ],
              ),
            ),
          ),

          _ToggleTile(
            icon: Icons.contrast_rounded,
            title: t.a11yHighContrast,
            subtitle: t.a11yHighContrastSub,
            value: a.highContrast,
            onChanged: (v) => _set(a, t, () => a.setHighContrast(v), v),
            prefs: a,
          ),

          const Divider(),
          _SectionLabel(label: t.a11ySectionMotion),
          _ToggleTile(
            icon: Icons.animation_rounded,
            title: t.a11yReduceMotion,
            subtitle: t.a11yReduceMotionSub,
            value: a.reduceMotion,
            onChanged: (v) => _set(a, t, () => a.setReduceMotion(v), v),
            prefs: a,
          ),

          const Divider(),
          _SectionLabel(label: t.a11ySectionLayout),
          _ToggleTile(
            icon: Icons.view_agenda_rounded,
            title: t.a11ySimplified,
            subtitle: t.a11ySimplifiedSub,
            value: a.simplifiedLayout,
            onChanged: (v) => _set(a, t, () => a.setSimplifiedLayout(v), v),
            prefs: a,
          ),

          const Divider(),
          _SectionLabel(label: t.a11ySectionAssist),
          _ToggleTile(
            icon: Icons.record_voice_over_rounded,
            title: t.a11yScreenReader,
            subtitle: t.a11yScreenReaderSub,
            value: a.screenReaderHints,
            onChanged: (v) => _set(a, t, () => a.setScreenReaderHints(v), v),
            prefs: a,
          ),
          _ToggleTile(
            icon: Icons.vibration_rounded,
            title: t.a11yHaptics,
            subtitle: t.a11yHapticsSub,
            value: a.haptics,
            onChanged: (v) async {
              await a.setHaptics(v);
              if (v) HapticFeedback.mediumImpact(); // live confirmation
            },
            prefs: a,
          ),

          const Divider(),
          Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Text(t.a11yHonestFooter,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant, height: 1.45)),
          ),
        ],
      ),
    );
  }

  /// Apply a change, firing a short haptic confirmation when the pref is turned
  /// ON *and* haptics are enabled (never when turning off, never for the haptic
  /// toggle itself which has its own buzz).
  void _set(A11yPrefs a, AppLocalizations t, Future<void> Function() apply,
      bool newValue) {
    apply();
    if (newValue && a.haptics) HapticFeedback.selectionClick();
  }

  Future<void> _resetConfirm(
      BuildContext context, A11yPrefs a, AppLocalizations t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.a11yResetTitle),
        content: Text(t.a11yResetBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.a11yReset)),
        ],
      ),
    );
    if (ok == true) a.resetAll();
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xs),
      child: Text(label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w700)),
    );
  }
}

/// A labelled SwitchListTile with an icon. Wrapped in Semantics so a screen
/// reader announces the toggle and its explanation together.
class _ToggleTile extends StatelessWidget {
  const _ToggleTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    required this.prefs,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final A11yPrefs prefs;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      toggled: value,
      label: title,
      hint: subtitle,
      child: SwitchListTile(
        secondary: Icon(icon),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle,
            style: Theme.of(context).textTheme.bodySmall),
        isThreeLine: subtitle.length > 40,
        value: value,
        onChanged: onChanged,
      ),
    );
  }
}

/// Large-text scale control: a labelled slider snapping to [A11yPrefs
/// .textScaleSteps], with a tap-to-cycle "A/A" helper.
class _TextScaleTile extends StatelessWidget {
  const _TextScaleTile({required this.prefs, required this.t});
  final A11yPrefs prefs;
  final AppLocalizations t;

  @override
  Widget build(BuildContext context) {
    final steps = A11yPrefs.textScaleSteps;
    final idx = steps.indexWhere((s) => (s - prefs.textScale).abs() < 0.001);
    final current = idx < 0 ? 0 : idx;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.format_size_rounded),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Text(t.a11yLargeText,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            Text(notifLocalizeDigits(context, '${(prefs.textScale * 100).round()}%'),
                style: TextStyle(
                    color: cs.primary, fontWeight: FontWeight.w700)),
          ]),
          Padding(
            padding: const EdgeInsets.only(left: 36),
            child: Text(t.a11yLargeTextSub,
                style: Theme.of(context).textTheme.bodySmall),
          ),
          Row(children: [
            Text(t.a11yTextSmallMark,
                style: AType.bodyMedium),
            Expanded(
              child: Slider(
                value: current.toDouble(),
                min: 0,
                max: (steps.length - 1).toDouble(),
                divisions: steps.length - 1,
                label: notifLocalizeDigits(context, '${(steps[current] * 100).round()}%'),
                onChanged: (v) {
                  prefs.setTextScale(steps[v.round()]);
                  if (prefs.haptics) HapticFeedback.selectionClick();
                },
              ),
            ),
            Text(t.a11yTextLargeMark,
                style: AType.headlineSmall),
          ]),
        ],
      ),
    );
  }
}
