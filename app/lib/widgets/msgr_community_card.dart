import 'package:flutter/material.dart';

import '../theme.dart';

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
    return Card(
      margin: const EdgeInsets.fromLTRB(Gap.lg, Gap.xs, Gap.lg, Gap.xs),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Row(
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
                    Text(name,
                        style: text.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                    if (description.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(description,
                          style: text.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                    ],
                    if (countLabel != null) ...[
                      const SizedBox(height: Gap.xs),
                      Text(countLabel!,
                          style: text.labelSmall
                              ?.copyWith(color: scheme.onSurfaceVariant)),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: Gap.sm),
                trailing!,
              ],
            ],
          ),
        ),
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
        gradient: hasPhoto ? null : Brand.gradient,
        color: hasPhoto ? scheme.surfaceContainerHighest : null,
        image: hasPhoto
            ? DecorationImage(
                image: NetworkImage(photoRef!), fit: BoxFit.cover)
            : null,
      ),
      alignment: Alignment.center,
      child: hasPhoto
          ? null
          : const Icon(Icons.groups_2_rounded, color: Colors.white),
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
        labelStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
        backgroundColor: scheme.surfaceContainerHighest,
        side: BorderSide.none,
        visualDensity: VisualDensity.compact,
      );
    }
    return FilledButton.tonalIcon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: FilledButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
      ),
    );
  }
}
