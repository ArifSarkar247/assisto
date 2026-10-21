import 'package:flutter/material.dart';
import '../theme.dart';

/// Shared onboarding building blocks (progress dots, selectable "choice" tiles,
/// section headers). Kept here so every onboarding step looks identical and the
/// screen file stays about FLOW, not pixels.
///
/// All text is passed in by the caller from AppLocalizations — this file holds
/// ZERO user-facing strings (and zero Bangla), per the project language rule.

/// Resumable progress dots. The current dot stretches; completed dots fill.
class OnbDots extends StatelessWidget {
  final int count;
  final int index;
  const OnbDots({super.key, required this.count, required this.index});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (int i = 0; i < count; i++)
          AnimatedContainer(
            duration: Motion.fast,
            margin: const EdgeInsets.all(3),
            height: 8,
            width: index == i ? 22 : 8,
            decoration: BoxDecoration(
              color: i <= index ? scheme.primary : scheme.outlineVariant,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
      ],
    );
  }
}

/// A centered hero header (gradient circle + title + subtitle) used at the top
/// of most onboarding steps.
class OnbHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final double iconSize;
  const OnbHeader({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.iconSize = 84,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(children: [
      Container(
        height: iconSize,
        width: iconSize,
        decoration: const BoxDecoration(
            gradient: Brand.gradient, shape: BoxShape.circle),
        child: Icon(icon, size: iconSize * 0.48, color: Colors.white),
      ),
      const SizedBox(height: Gap.lg),
      Text(title,
          textAlign: TextAlign.center,
          style: Theme.of(context)
              .textTheme
              .headlineSmall
              ?.copyWith(fontWeight: FontWeight.w800)),
      if (subtitle != null) ...[
        const SizedBox(height: Gap.sm),
        Text(subtitle!,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.5)),
      ],
    ]);
  }
}

/// A big, tappable choice tile (icon + title + sub + optional "recommended"
/// ribbon + selected check). Used by the role picker and first-win steps.
/// Min height 64 and a 44+ touch target keep it WCAG-friendly for elders.
class OnbChoiceTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final String? badge; // e.g. "Recommended for you" (already localized)
  final VoidCallback onTap;
  const OnbChoiceTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.selected = false,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: subtitle.isEmpty ? title : '$title. $subtitle',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.md),
        child: AnimatedContainer(
          duration: Motion.fast,
          padding: const EdgeInsets.all(Gap.lg),
          constraints: const BoxConstraints(minHeight: 64),
          decoration: BoxDecoration(
            color: selected
                ? scheme.primaryContainer
                : scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(Radii.md),
            border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(children: [
            Container(
              height: 44,
              width: 44,
              decoration: BoxDecoration(
                color: selected ? scheme.primary : scheme.primaryContainer,
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Icon(icon,
                  color: selected ? Colors.white : scheme.onPrimaryContainer),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (badge != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(badge!,
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: scheme.primary)),
                      ),
                    Text(title,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 15)),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(subtitle,
                          style: TextStyle(
                              fontSize: 12.5,
                              height: 1.35,
                              color: scheme.onSurfaceVariant)),
                    ],
                  ]),
            ),
            const SizedBox(width: Gap.sm),
            Icon(
              selected ? Icons.check_circle : Icons.chevron_right,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ]),
        ),
      ),
    );
  }
}
