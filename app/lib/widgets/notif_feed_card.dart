import 'package:flutter/material.dart';
import '../theme.dart';
import 'notif_models.dart';

/// One feed event: type-icon + title + body + relative time, with an unseen
/// dot. Tapping deep-links to the source and marks it seen (handled by the
/// [onTap] the screen passes).
class NotifFeedCard extends StatelessWidget {
  final NotifEvent event;
  final VoidCallback onTap;

  const NotifFeedCard({super.key, required this.event, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final vis = notifTypeVisual(event.type, scheme);
    final title = pickText(context, event.title);
    final body = pickText(context, event.body);
    final time = notifAgo(context, event.timeIso);

    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      clipBehavior: Clip.antiAlias,
      color: event.seen
          ? null
          : scheme.primaryContainer.withValues(alpha: 0.18),
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 40,
                width: 40,
                decoration: BoxDecoration(
                  color: vis.tint.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: Icon(vis.icon, color: vis.tint, size: 22),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(
                                    fontWeight: event.seen
                                        ? FontWeight.w600
                                        : FontWeight.w700),
                          ),
                        ),
                        if (!event.seen) ...[
                          const SizedBox(width: Gap.sm),
                          Container(
                            margin: const EdgeInsets.only(top: 6),
                            height: 8,
                            width: 8,
                            decoration: BoxDecoration(
                              color: scheme.primary,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (body.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        body,
                        style: TextStyle(
                            color: scheme.onSurfaceVariant, height: 1.3),
                      ),
                    ],
                    if (time.isNotEmpty) ...[
                      const SizedBox(height: Gap.xs),
                      Text(
                        time,
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
