import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'msgr_channel_common.dart';

/// Assisto Messenger — a single CHANNEL POST card (Step 3).
///
/// One-to-many broadcast content: text / photo / video / link / poll. Followers
/// get READ + REACT only — there is deliberately NO reply box, NO comment
/// field and NO "message admin" affordance anywhere on this card (the server
/// has no such path; `can_follower_reply` / `can_follower_dm_admin` are always
/// false). Reactions use our own original set and the server stores per-emoji
/// aggregate counts only. Original Assisto identity — no copied UI/assets.
class MsgrChannelPostCard extends StatelessWidget {
  final Map<String, dynamic> post;

  /// Follower reacting with an emoji (on=true to add, false to remove).
  final void Function(String emoji, bool on)? onReact;

  /// Voting on an attached poll, by option INDEX (multi may send >1).
  final void Function(List<int> choices)? onVote;

  /// Admin-only pin toggle; null hides the control for followers.
  final void Function(bool pinned)? onTogglePin;

  /// Admin-only; whether to show the views line (followers never see per-post
  /// view counts — those live only in the aggregate analytics screen).
  final bool showViews;

  const MsgrChannelPostCard({
    super.key,
    required this.post,
    this.onReact,
    this.onVote,
    this.onTogglePin,
    this.showViews = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final bn = msgrIsBn(context);
    final cs = Theme.of(context).colorScheme;
    final kind = '${post['kind'] ?? 'text'}';
    final text = '${post['text'] ?? ''}';
    final pinned = post['pinned'] == true;

    return Card(
      margin: const EdgeInsets.symmetric(
          horizontal: Gap.lg, vertical: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (pinned || onTogglePin != null)
              Row(
                children: [
                  if (pinned) ...[
                    Icon(Icons.push_pin_rounded, size: 16, color: cs.primary),
                    const SizedBox(width: Gap.xs),
                    Text(t.channelPinned,
                        style: Theme.of(context)
                            .textTheme
                            .labelMedium
                            ?.copyWith(color: cs.primary)),
                  ],
                  const Spacer(),
                  if (onTogglePin != null)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip:
                          pinned ? t.channelUnpin : t.channelPin,
                      icon: Icon(pinned
                          ? Icons.push_pin_rounded
                          : Icons.push_pin_outlined),
                      onPressed: () => onTogglePin!(!pinned),
                    ),
                ],
              ),
            if (text.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.sm),
                child: Text(text,
                    style: Theme.of(context).textTheme.bodyLarge),
              ),
            _media(context, kind),
            if (kind == 'poll' && post['poll'] is Map)
              _poll(context, (post['poll'] as Map).cast<String, dynamic>()),
            const SizedBox(height: Gap.sm),
            _reactionBar(context),
            const SizedBox(height: Gap.xs),
            _footer(context, t, bn),
          ],
        ),
      ),
    );
  }

  Widget _media(BuildContext context, String kind) {
    final cs = Theme.of(context).colorScheme;
    if (kind == 'photo' || kind == 'video') {
      return ClipRRect(
        borderRadius: BorderRadius.circular(Radii.sm),
        child: Container(
          height: 180,
          width: double.infinity,
          color: cs.surfaceContainerHighest,
          alignment: Alignment.center,
          child: Icon(
            kind == 'video'
                ? Icons.play_circle_outline_rounded
                : Icons.image_rounded,
            size: 40,
            color: cs.onSurfaceVariant,
          ),
        ),
      );
    }
    if (kind == 'link') {
      final url = '${post['link_url'] ?? ''}';
      if (url.isEmpty) return const SizedBox.shrink();
      return Container(
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        child: Row(
          children: [
            Icon(Icons.link_rounded, color: cs.primary),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: Text(url,
                    maxLines: 1, overflow: TextOverflow.ellipsis)),
          ],
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _poll(BuildContext context, Map<String, dynamic> poll) {
    final t = AppLocalizations.of(context);
    final bn = msgrIsBn(context);
    final cs = Theme.of(context).colorScheme;
    final options = ((poll['options'] as List?) ?? const [])
        .map((e) => '$e')
        .toList();
    final tally = ((poll['tally'] as List?) ?? const [])
        .map((e) => (e as num?)?.toInt() ?? 0)
        .toList();
    final total = (poll['total_votes'] as num?)?.toInt() ?? 0;
    final myChoices = ((poll['my_choices'] as List?) ?? const [])
        .map((e) => (e as num?)?.toInt() ?? -1)
        .toSet();
    final multi = poll['multi'] == true;
    final closed = poll['closed'] == true;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if ((poll['question'] ?? '').toString().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm),
            child: Text('${poll['question']}',
                style: Theme.of(context).textTheme.titleMedium),
          ),
        for (var i = 0; i < options.length; i++)
          _pollOption(
            context,
            index: i,
            label: options[i],
            votes: i < tally.length ? tally[i] : 0,
            total: total,
            mine: myChoices.contains(i),
            enabled: !closed && onVote != null,
            multi: multi,
          ),
        const SizedBox(height: Gap.xs),
        Row(
          children: [
            Text(
              msgrLocalizeDigits(t.channelPollVotes(total.toString()), bn),
              style: Theme.of(context)
                  .textTheme
                  .labelMedium
                  ?.copyWith(color: cs.onSurfaceVariant),
            ),
            if (closed) ...[
              const SizedBox(width: Gap.sm),
              Text('· ${t.channelPollClosed}',
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(color: cs.onSurfaceVariant)),
            ],
          ],
        ),
      ],
    );
  }

  Widget _pollOption(
    BuildContext context, {
    required int index,
    required String label,
    required int votes,
    required int total,
    required bool mine,
    required bool enabled,
    required bool multi,
  }) {
    final cs = Theme.of(context).colorScheme;
    final frac = total == 0 ? 0.0 : votes / total;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.sm),
        onTap: enabled ? () => onVote!([index]) : null,
        child: Stack(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(Radii.sm),
              child: LinearProgressIndicator(
                value: frac,
                minHeight: 44,
                backgroundColor: cs.surfaceContainerHighest,
                color: mine
                    ? cs.primary.withValues(alpha: 0.35)
                    : cs.secondaryContainer,
              ),
            ),
            Positioned.fill(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: Gap.md),
                child: Row(
                  children: [
                    if (mine)
                      Padding(
                        padding: const EdgeInsets.only(right: Gap.xs),
                        child: Icon(
                            multi
                                ? Icons.check_box_rounded
                                : Icons.radio_button_checked_rounded,
                            size: 18,
                            color: cs.primary),
                      ),
                    Expanded(
                      child: Text(label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ),
                    Text('${(frac * 100).round()}%',
                        style: Theme.of(context).textTheme.labelLarge),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _reactionBar(BuildContext context) {
    final reactions = (post['reactions'] is Map)
        ? (post['reactions'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    final mine = '${post['my_reaction'] ?? ''}';
    return Wrap(
      spacing: Gap.sm,
      runSpacing: Gap.xs,
      children: [
        for (final emoji in msgrChannelReactions)
          _reactionChip(
            context,
            emoji: emoji,
            count: (reactions[emoji] as num?)?.toInt() ?? 0,
            selected: mine == emoji,
          ),
      ],
    );
  }

  Widget _reactionChip(
    BuildContext context, {
    required String emoji,
    required int count,
    required bool selected,
  }) {
    final bn = msgrIsBn(context);
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(Radii.pill),
      onTap: onReact == null ? null : () => onReact!(emoji, !selected),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: Gap.md, vertical: Gap.xs),
        decoration: BoxDecoration(
          color: selected
              ? cs.primaryContainer
              : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.pill),
          border: selected
              ? Border.all(color: cs.primary, width: 1.2)
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 15)),
            if (count > 0) ...[
              const SizedBox(width: Gap.xs),
              Text(msgrLocalizeDigits(count.toString(), bn),
                  style: Theme.of(context).textTheme.labelMedium),
            ],
          ],
        ),
      ),
    );
  }

  Widget _footer(BuildContext context, AppLocalizations t, bool bn) {
    final cs = Theme.of(context).colorScheme;
    final views = (post['views'] as num?)?.toInt() ?? 0;
    if (!showViews) return const SizedBox.shrink();
    return Text(
      msgrLocalizeDigits(t.channelViews(views.toString()), bn),
      style: Theme.of(context)
          .textTheme
          .labelMedium
          ?.copyWith(color: cs.onSurfaceVariant),
    );
  }
}
