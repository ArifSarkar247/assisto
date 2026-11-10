import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import 'circle_people_filter.dart';

/// sjstart2 (owner Safe Journey V2, item 5): "Who watches" as one-tap chips
/// of the family — more than one allowed. Family first (circlea grouping),
/// then the rest of My Circle; a search field only for a long circle. The
/// last choice is remembered on the phone ([JourneyWatcherMemory]) so the
/// daily trip needs no picking at all.
class JourneyWatcherChips extends StatefulWidget {
  const JourneyWatcherChips({
    super.key,
    required this.rows,
    required this.selected,
    required this.onChanged,
    this.searchAt = 10,
  });

  /// Accepted My Circle rows ({id, name, phone, relation, circle_group}).
  final List<Map<String, dynamic>> rows;
  final Set<int> selected;
  final ValueChanged<Set<int>> onChanged;
  final int searchAt;

  @override
  State<JourneyWatcherChips> createState() => _JourneyWatcherChipsState();
}

class _JourneyWatcherChipsState extends State<JourneyWatcherChips> {
  String _q = '';

  static String _name(Map m) => '${m['name'] ?? m['phone'] ?? ''}'.trim();

  void _toggle(int id) {
    final next = {...widget.selected};
    if (!next.remove(id)) next.add(id);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final q = _q.trim().toLowerCase();
    final shown = q.isEmpty
        ? widget.rows
        : [
            for (final r in widget.rows)
              if ('${_name(r)} ${r['phone'] ?? ''} ${r['relation'] ?? ''}'
                  .toLowerCase()
                  .contains(q))
                r
          ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.rows.length >= widget.searchAt)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm),
            child: TextField(
              key: const ValueKey('sj2_w_search'),
              onChanged: (v) => setState(() => _q = v),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search_rounded),
                hintText: AppLocalizations.of(context).cfaSearchPeople,
                isDense: true,
              ),
            ),
          ),
        for (final (g, rows) in sectionPeople(shown)) ...[
          PeopleSectionHeader(g, count: rows.length),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            for (final m in rows) _chip(m, cs),
          ]),
        ],
      ],
    );
  }

  Widget _chip(Map<String, dynamic> m, ColorScheme cs) {
    final id = (m['id'] as num?)?.toInt();
    final name = _name(m);
    final on = id != null && widget.selected.contains(id);
    return FilterChip(
      key: ValueKey('j100_w_$id'),
      selected: on,
      showCheckmark: true,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      avatar: on
          ? null
          : CircleAvatar(
              backgroundColor: cs.primaryContainer,
              child: Text(name.isEmpty ? '?' : name.characters.first.toUpperCase(),
                  style: AType.bodySmall.copyWith(color: cs.onPrimaryContainer, fontSize: 12)),
            ),
      label: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 220),
        child: Text(name, overflow: TextOverflow.ellipsis, maxLines: 2),
      ),
      onSelected: id == null ? null : (_) => _toggle(id),
    );
  }
}

/// The last watcher choice, on the phone only (ids of My Circle members).
class JourneyWatcherMemory {
  static const key = 'sj2_last_watchers';

  static Future<Set<int>> load() async {
    final s = await Settings.getString(key) ?? '';
    return {
      for (final p in s.split(','))
        if (int.tryParse(p.trim()) != null) int.parse(p.trim())
    };
  }

  static Future<void> save(Set<int> ids) =>
      Settings.setString(key, (ids.toList()..sort()).join(','));

  /// Remembered ids that are still in the circle (a removed member never
  /// silently stays a watcher).
  static Set<int> stillThere(Set<int> remembered, List<Map<String, dynamic>> rows) {
    final ids = {for (final r in rows) (r['id'] as num?)?.toInt()}..remove(null);
    return {for (final i in remembered) if (ids.contains(i)) i};
  }
}
