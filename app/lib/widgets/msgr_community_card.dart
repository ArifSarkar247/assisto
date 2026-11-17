import 'package:flutter/material.dart';

import '../theme.dart';
import '../ds/ds.dart';

/// A community / group card — name, photo (or branded fallback), description.
/// ORIGINAL identity: uses only Assisto brand tokens and Material icons; no
/// third-party assets or wording.
class MsgrCommunityCard extends StatelessWidget {
  final String name;
  final String description;
  final String? photoRef;

  /// Count label already localised by the caller (e.g. "12 members"); null hides it.
  final String? countLabel;

  /// Right-aligned action (Open / Join / Request / Requested chip).
  final Widget? trailing;

  /// Small badge above the name (e.g. announcements group marker).
  final Widget? badge;

  final VoidCallback? onTap;

  const MsgrCommunityCard({
    super.key,
    required this.name,
    this.description = '',
    this.photoRef,
    this.countLabel,
    this.trailing,
    this.badge,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    // launchsweep: at a big font the action button moves under the text
    // (beside it, it squeezed the name off a 360 dp screen).
    final big = MediaQuery.textScalerOf(context).scale(10) > 13;
    // designv2: a flat bordered DS surface (community lists can be long —
    // one shadow less per row keeps them GPU-light)
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.xs, Gap.lg, Gap.xs),
      child: DsSurface(
        flat: true,
        borderColor: scheme.ds.border,
        onTap: onTap,
        padding: const EdgeInsets.all(Gap.md),
          child: LayoutBuilder(builder: (context, box) => Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _avatar(scheme),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (badge != null) ...[
                      badge!,
                      const SizedBox(height: Gap.xs),
                    ],
                    // the name wraps (never "…")
                    Text(name,
                        style: text.titleMedium
                            ?.copyWith(color: scheme.ds.text, fontWeight: FontWeight.w700)),
                    if (description.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(description,
                          style: text.bodySmall
                              ?.copyWith(color: scheme.ds.muted),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                    ],
                    if (countLabel != null) ...[
                      const SizedBox(height: Gap.xs),
                      Text(countLabel!,
                          style: text.labelMedium
                              ?.copyWith(color: scheme.ds.muted)),
                    ],
                    if (big && trailing != null) ...[
                      const SizedBox(height: Gap.sm),
                      trailing!,
                    ],
                  ],
                ),
              ),
              if (!big && trailing != null) ...[
                const SizedBox(width: Gap.sm),
                // launchsweep: never wider than the text column; the
                // button label wraps instead of pushing the row off screen.
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: box.maxWidth * 0.4),
                  child: trailing!,
                ),
              ],
            ],
          )),
      ),
    );
  }

  Widget _avatar(ColorScheme scheme) {
    final hasPhoto = photoRef != null && photoRef!.isNotEmpty;
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.md),
        color: hasPhoto ? scheme.ds.cardHighest : scheme.ds.primarySoft,
        image: hasPhoto
            ? DecorationImage(
                image: NetworkImage(photoRef!), fit: BoxFit.cover)
            : null,
      ),
      alignment: Alignment.center,
      child: hasPhoto
          ? null
          : Icon(Icons.groups_2_rounded, color: scheme.ds.primaryInk),
    );
  }
}

/// Small pill chip used for Join / Request / Requested / Open actions.
class MsgrActionChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  /// When true the chip is a passive state marker (e.g. "Requested") not a button.
  final bool muted;

  const MsgrActionChip({
    super.key,
    required this.label,
    required this.icon,
    this.onPressed,
    this.muted = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (muted) {
      return Chip(
        avatar: Icon(icon, size: 16, color: scheme.onSurfaceVariant),
        label: Text(label),
        labelStyle: AType.labelMedium.copyWith(color: scheme.ds.muted),
        backgroundColor: scheme.ds.cardHighest,
        side: BorderSide.none,
        visualDensity: VisualDensity.compact,
      );
    }
    return FilledButton.tonalIcon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48), // launchsweep: 48 dp target
        tapTargetSize: MaterialTapTargetSize.padded,
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
      ),
    );
  }
}
