import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'inbox_item_card.dart';
import 'inbox_mock.dart';

/// Inbox filter model: an optional category, optional source, and the
/// "needs reply" toggle. null category/source = All.
class InboxFilter {
  final InboxCategory? category;
  final InboxSource? source;
  final bool needsReplyOnly;
  const InboxFilter({this.category, this.source, this.needsReplyOnly = false});

  InboxFilter copyWith({
    InboxCategory? category, bool clearCategory = false,
    InboxSource? source, bool clearSource = false,
    bool? needsReplyOnly,
  }) =>
      InboxFilter(
        category: clearCategory ? null : (category ?? this.category),
        source: clearSource ? null : (source ?? this.source),
        needsReplyOnly: needsReplyOnly ?? this.needsReplyOnly,
      );
}

/// Horizontally scrolling filter chips: All / Needs reply / per-category
/// (with counts) / per-source. WCAG: selected state uses fill + bold, not
/// colour alone; each chip carries text.
class InboxFilterBar extends StatelessWidget {
  final InboxFilter filter;
  final Map<InboxCategory, int> counts;
  final int needsReplyCount;
  final ValueChanged<InboxFilter> onChanged;

  const InboxFilterBar({
    super.key,
    required this.filter,
    required this.counts,
    required this.needsReplyCount,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final noFilter = filter.category == null && filter.source == null && !filter.needsReplyOnly;

    Widget chip(String label, bool selected, VoidCallback onTap, {Color? color}) =>
        Padding(
          padding: const EdgeInsets.only(right: Gap.sm),
          child: FilterChip(
            label: Text(label),
            selected: selected,
            onSelected: (_) => onTap(),
            showCheckmark: false,
            avatar: color == null
                ? null
                : Container(width: 10, height: 10,
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          ),
        );

    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
        children: [
          chip(tr.inboxFilterAll, noFilter,
              () => onChanged(const InboxFilter())),
          chip('${tr.inboxNeedsReply} ($needsReplyCount)', filter.needsReplyOnly,
              () => onChanged(filter.needsReplyOnly
                  ? filter.copyWith(needsReplyOnly: false)
                  : const InboxFilter(needsReplyOnly: true))),
          for (final c in InboxCategory.values)
            chip(
              '${InboxItemCard.categoryLabel(tr, c)} (${counts[c] ?? 0})',
              filter.category == c,
              () => onChanged(filter.category == c
                  ? filter.copyWith(clearCategory: true)
                  : filter.copyWith(category: c, needsReplyOnly: false)),
              color: InboxItemCard.categoryColor(c),
            ),
          for (final s in InboxSource.values)
            chip(
              _sourceLabel(tr, s),
              filter.source == s,
              () => onChanged(filter.source == s
                  ? filter.copyWith(clearSource: true)
                  : filter.copyWith(source: s)),
            ),
        ],
      ),
    );
  }

  String _sourceLabel(AppLocalizations tr, InboxSource s) {
    switch (s) {
      case InboxSource.email:
        return tr.inboxSrcEmail;
      case InboxSource.notification:
        return tr.inboxSrcNotification;
      case InboxSource.message:
        return tr.inboxSrcMessage;
    }
  }
}
