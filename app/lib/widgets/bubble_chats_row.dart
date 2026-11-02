import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../messaging/date_separators.dart' show localDigits;
import '../messaging/in_call_bubbles.dart' show BubbleFace;
import '../theme.dart';

/// bubbles2 (owner FINAL bubbles order, point 5) — at the top of My Circle,
/// one row of round photos for the chats that have a floating bubble right
/// now (our own active conversation notifications, read from Android), with
/// their unread counts; tap opens that chat. Hidden when there are none.

@immutable
class BubbleRowEntry {
  const BubbleRowEntry({
    required this.key,
    required this.name,
    this.photo = '',
    this.photoV = '',
    this.group = false,
    this.unread = 0,
    this.floating = false,
  });

  final String key;
  final String name;
  final String photo;
  final String photoV;
  final bool group;
  final int unread;

  /// Showing as a system bubble right now.
  final bool floating;
}

/// The order (pinned by tests): the chats with an active conversation
/// notification right now (= the bubbles on screen), newest first. Only
/// chats in [known] (the visible, unlocked list), each once, at most [max].
/// [unread] only feeds the badges — an unread chat without a live
/// notification is already at the top of the list below, so the row never
/// duplicates the list (and stays hidden when nothing floats).
List<String> bubbleRowKeys({
  required List<Map<String, dynamic>> active,
  required Map<String, int> unread,
  required Set<String> known,
  int max = 12,
}) {
  final out = <String>[];
  for (final a in active) {
    final k = '${a['key'] ?? ''}';
    if (known.contains(k) && !out.contains(k)) out.add(k);
  }
  return out.take(max).toList(growable: false);
}

class BubbleChatsRow extends StatelessWidget {
  const BubbleChatsRow({super.key, required this.entries, required this.onOpen});

  final List<BubbleRowEntry> entries;
  final void Function(String key) onOpen;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final lang = Localizations.localeOf(context).languageCode;
    // the names under the photos stay one line; the row grows with the text
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
    return Column(
      key: const Key('bbl2-circle-row'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, 0),
          child: Semantics(
            header: true,
            child: Text(t.bbl2RowTitle,
                style: AType.labelLarge.copyWith(
                    color: scheme.onSurfaceVariant, fontWeight: FontWeight.w700)),
          ),
        ),
        SizedBox(
          height: 80 + 20 * scale,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
            itemCount: entries.length,
            separatorBuilder: (_, __) => const SizedBox(width: Gap.xs),
            itemBuilder: (context, i) {
              final e = entries[i];
              return Semantics(
                button: true,
                label: t.bbl2FaceA11y(e.name, localDigits('${e.unread}', lang)),
                excludeSemantics: true,
                child: InkWell(
                  key: ValueKey('bbl2-row-${e.key}'),
                  borderRadius: BorderRadius.circular(Radii.md),
                  onTap: () => onOpen(e.key),
                  child: SizedBox(
                    width: 72,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      BubbleFace(
                        name: e.name,
                        photo: e.photo,
                        photoV: e.photoV,
                        group: e.group,
                        unread: e.unread,
                        size: 54,
                      ),
                      const SizedBox(height: Gap.xxs),
                      Text(e.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: AType.labelSmall.copyWith(
                              color: scheme.onSurface,
                              fontWeight:
                                  e.unread > 0 ? FontWeight.w700 : FontWeight.w500)),
                    ]),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
