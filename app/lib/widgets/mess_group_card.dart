import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../mess_v2_api.dart';
import '../screens/mess/mess_detail_screen.dart';
import '../screens/mess/mess_store.dart';
import '../state.dart';
import '../theme.dart';

/// messv2 (owner order C): the pinned "Today" card on top of a mess group
/// chat — total meals today, bazar today, who has not set tomorrow's meals,
/// and an "Open mess" button. Shows NOTHING for a normal group, for a closed
/// mess, or when the server can't be reached (the chat never waits for it).
class MessGroupCard extends StatefulWidget {
  const MessGroupCard({super.key, required this.groupId});
  final int groupId;

  @override
  State<MessGroupCard> createState() => _MessGroupCardState();
}

class _MessGroupCardState extends State<MessGroupCard> {
  Map<String, dynamic>? _card;
  bool _collapsed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await context.read<AppState>().api.messByGroup(widget.groupId);
      final c = r['card'];
      if (mounted) setState(() => _card = c is Map ? c.cast<String, dynamic>() : null);
    } catch (_) {
      // not a mess group / offline: no card (never a dead or broken card)
    }
  }

  Future<void> _open() async {
    final id = (_card?['mess_id'] as num?)?.toInt();
    if (id == null) return;
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => MessDetailScreen(messId: id, fromGroup: true)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = _card;
    if (c == null) return const SizedBox.shrink();
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final notSet = ((c['not_set_tomorrow'] as List?) ?? const []).map((e) => '$e').toList();
    final turn = '${c['bazar_turn_today'] ?? ''}';
    return Semantics(
      container: true,
      label: t.mv2CardA11y,
      child: Container(
        key: const ValueKey('mess-group-card'),
        margin: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 0),
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.restaurant_rounded, color: scheme.onSecondaryContainer),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(t.mv2CardTitle,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700, color: scheme.onSecondaryContainer)),
            ),
            IconButton(
              tooltip: _collapsed ? t.mv2CardExpand : t.mv2CardCollapse,
              icon: Icon(_collapsed ? Icons.expand_more_rounded : Icons.expand_less_rounded),
              onPressed: () => setState(() => _collapsed = !_collapsed),
            ),
          ]),
          if (!_collapsed) ...[
            Wrap(spacing: Gap.md, runSpacing: Gap.xs, children: [
              Text(t.mv2CardMeals(messDigits(context, c['meals_today'])),
                  style: TextStyle(color: scheme.onSecondaryContainer)),
              Text(t.mv2CardBazar(messDigits(context, c['bazar_today_display'])),
                  style: TextStyle(color: scheme.onSecondaryContainer)),
              if (turn.isNotEmpty)
                Text(t.mv2CardTurn(turn), style: TextStyle(color: scheme.onSecondaryContainer)),
            ]),
            const SizedBox(height: Gap.xs),
            Text(
              notSet.isEmpty ? t.mv2CardAllSet : t.mv2CardNotSet(notSet.join(', ')),
              style: TextStyle(color: scheme.onSecondaryContainer),
            ),
            const SizedBox(height: Gap.sm),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton.icon(
                key: const ValueKey('mess-group-open'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: _open,
                icon: const Icon(Icons.open_in_new_rounded),
                label: Text(t.mv2OpenMess),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}
