import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// Seasonal health highlights (BD-specific: dengue / heat / winter / flood),
/// shown as a horizontally scrollable strip at the top of the library. The
/// backend returns only the highlights active for the current month, each one
/// SOURCE-NAMED (DGHS / IEDCR) with a review date. Educational awareness only —
/// never a diagnosis. Tapping a card filters the library to its topic.
class HtipsSeasonal extends StatelessWidget {
  final List<Map<String, dynamic>> highlights;
  final void Function(String topicId)? onOpenTopic;
  const HtipsSeasonal({super.key, required this.highlights, this.onOpenTopic});

  @override
  Widget build(BuildContext context) {
    if (highlights.isEmpty) return const SizedBox.shrink();
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(Icons.wb_sunny_outlined, size: 18, color: scheme.primary),
        const SizedBox(width: Gap.xs),
        Text(t.htipsSeasonalTitle,
            style: Theme.of(context).textTheme.titleSmall),
      ]),
      const SizedBox(height: Gap.sm),
      SizedBox(
        height: 164,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: highlights.length,
          separatorBuilder: (_, __) => const SizedBox(width: Gap.sm),
          itemBuilder: (context, i) =>
              _SeasonalCard(data: highlights[i], onOpenTopic: onOpenTopic),
        ),
      ),
    ]);
  }
}

class _SeasonalCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final void Function(String topicId)? onOpenTopic;
  const _SeasonalCard({required this.data, this.onOpenTopic});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final title = (data['title'] ?? '').toString();
    final body = (data['body'] ?? '').toString();
    final sourceName = (data['source_name'] ?? '').toString();
    final reviewed = (data['reviewed'] ?? '').toString();
    final topicId = (data['topic'] ?? '').toString();
    return SizedBox(
      width: 280,
      child: Card(
        color: scheme.primaryContainer,
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.md),
          onTap: topicId.isEmpty || onOpenTopic == null
              ? null
              : () => onOpenTopic!(topicId),
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(Icons.campaign_outlined, size: 18, color: scheme.onPrimaryContainer),
                const SizedBox(width: Gap.xs),
                Expanded(
                  child: Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: scheme.onPrimaryContainer)),
                ),
              ]),
              const SizedBox(height: Gap.xs),
              Expanded(
                child: Text(body,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12.5,
                        height: 1.4,
                        color: scheme.onPrimaryContainer)),
              ),
              const SizedBox(height: Gap.xs),
              if (sourceName.isNotEmpty)
                Text(
                  reviewed.isEmpty
                      ? t.healthTipSourceLine(sourceName)
                      : t.htipsSourceDateLine(sourceName, reviewed),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10.5, color: scheme.onPrimaryContainer),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}
