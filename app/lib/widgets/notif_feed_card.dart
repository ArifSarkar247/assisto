import 'package:flutter/material.dart';
import '../ds/ds.dart';
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

    final ds = DsTokens.of(context);
    // designv2: alive DS card; unread = soft primary tint + pulsing dot
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: DsSurface(
        onTap: onTap,
        color: event.seen ? null : ds.primarySoft,
        padding: const EdgeInsets.all(Gap.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 40,
                width: 40,
                decoration: BoxDecoration(
                  color: vis.tint.withValues(alpha: ds.isDark ? 0.22 : 0.12),
                  borderRadius: BorderRadius.circular(DsRadius.card),
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
                                    color: ds.text,
                                    fontWeight: event.seen
                                        ? FontWeight.w600
                                        : FontWeight.w700),
                          ),
                        ),
                        if (!event.seen) ...[
                          const SizedBox(width: Gap.sm),
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: DsStatusDot(color: ds.primary, size: 8, pulse: false), // a list: static (cheap)
                          ),
                        ],
                      ],
                    ),
                    if (body.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        body,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: ds.muted, height: 1.3),
                      ),
                    ],
                    if (time.isNotEmpty) ...[
                      const SizedBox(height: Gap.xs),
                      Text(
                        time,
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(color: ds.muted),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
      ),
    );
  }
}
