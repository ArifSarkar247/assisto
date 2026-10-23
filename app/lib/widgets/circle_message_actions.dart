import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// The set of actions a user can take on a single message (long-press menu):
/// reply, react, copy, forward, star, pin, edit (own + in window), delete.
/// Mirrors core/logic/circle_messaging.py semantics; the screen wires the
/// callbacks. No Bangla literals here (labels via AppLocalizations).
enum CircleMsgAction { reply, react, copy, forward, star, pin, edit, deleteMe, deleteEveryone, info, moreReactions }

/// A compact emoji strip shown above the long-press action sheet. The emoji are
/// unicode graphemes (NOT Bangla text), allowed as quick-reaction tokens.
// c3-msg order (WhatsApp): 😂 ❤️ 👍 😮 😢 🙏, then "+" for more.
const List<String> kQuickReactions = ['\u{1F602}', '\u{2764}\u{FE0F}', '\u{1F44D}', '\u{1F62E}', '\u{1F622}', '\u{1F64F}'];

/// Shows the long-press menu for a message. Returns the chosen action, or a
/// reaction emoji via [onReact] (handled inline so the sheet can close fast).
Future<CircleMsgAction?> showCircleMessageActions(
  BuildContext context, {
  required bool mine,
  required bool canEdit,
  required bool isStarred,
  required bool isPinned,
  required bool canDeleteEveryone,
  required ValueChanged<String> onReact,
  bool showInfo = false,
  List<String>? reactions, // cde-chat: the chat theme's own quick emoji
}) {
  final t = AppLocalizations.of(context);
  return showModalBottomSheet<CircleMsgAction>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Quick-reaction strip.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                for (final e in reactions ?? kQuickReactions)
                  InkResponse(
                    onTap: () {
                      onReact(e);
                      Navigator.pop(ctx);
                    },
                    radius: 28,
                    child: Padding(
                      padding: const EdgeInsets.all(Gap.xs),
                      child: Text(e, style: const TextStyle(fontSize: 26)),
                    ),
                  ),
                IconButton(
                  key: const Key('c3-react-more'),
                  tooltip: t.c3ReactMore,
                  icon: const Icon(Icons.add_reaction_outlined),
                  onPressed: () =>
                      Navigator.pop(ctx, CircleMsgAction.moreReactions),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          _tile(ctx, Icons.reply_outlined, t.circleActionReply, CircleMsgAction.reply),
          _tile(ctx, Icons.copy_outlined, t.copy, CircleMsgAction.copy),
          _tile(ctx, Icons.forward_outlined, t.circleActionForward, CircleMsgAction.forward),
          _tile(ctx, isStarred ? Icons.star : Icons.star_border,
              isStarred ? t.circleActionUnstar : t.circleActionStar, CircleMsgAction.star),
          _tile(ctx, isPinned ? Icons.push_pin : Icons.push_pin_outlined,
              isPinned ? t.circleActionUnpin : t.circleActionPin, CircleMsgAction.pin),
          if (mine && canEdit)
            _tile(ctx, Icons.edit_outlined, t.circleActionEdit, CircleMsgAction.edit),
          if (showInfo)
            _tile(ctx, Icons.info_outline, t.c3InfoTitle, CircleMsgAction.info),
          _tile(ctx, Icons.delete_outline, t.circleActionDeleteMe, CircleMsgAction.deleteMe),
          if (mine && canDeleteEveryone)
            _tile(ctx, Icons.delete_forever_outlined, t.circleActionDeleteEveryone,
                CircleMsgAction.deleteEveryone,
                danger: true),
        ],
      ),
      ),
    ),
  );
}

Widget _tile(BuildContext ctx, IconData icon, String label, CircleMsgAction a,
    {bool danger = false}) {
  final color = danger ? Theme.of(ctx).colorScheme.error : null;
  return ListTile(
    dense: true,
    leading: Icon(icon, color: color),
    title: Text(label, style: TextStyle(color: color)),
    onTap: () => Navigator.pop(ctx, a),
  );
}

/// A small pill that renders the aggregated reactions under a bubble.
class CircleReactionChips extends StatelessWidget {
  /// Ordered {emoji: count}.
  final Map<String, int> counts;
  final VoidCallback? onTap;
  const CircleReactionChips({super.key, required this.counts, this.onTap});

  @override
  Widget build(BuildContext context) {
    if (counts.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Wrap(
        spacing: Gap.xs,
        children: [
          for (final e in counts.entries)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(Radii.pill),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Text(
                e.value > 1 ? '${e.key} ${e.value}' : e.key,
                style: const TextStyle(fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}
