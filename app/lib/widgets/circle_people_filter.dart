import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'app_sheet.dart';

/// circlea — "Family / Others" everywhere people are listed.
///
/// Every My Circle row from the server carries `circle_group` ("family" |
/// "others") + `circle_group_auto` (true = suggested from the relation /
/// Family Care / guardian link, false = the user marked it). This file is
/// the ONE place the app reads it, filters by it and sections by it:
///   * [circleGroupOf]        the row's group (falls back to the relation)
///   * [PeopleFilter] + [PeopleFilterStore]  chip choice, remembered per list
///   * [filterPeople] / [sectionPeople]      chips + search, Family first
///   * [PeopleFilterBar]      "All / Family / Others" chips + search field
///   * [CirclePeopleList]     a picker body: chips + search + sections
///   * [markCircleGroup]      the "Family / Others / Automatic" sheet + save
/// Used by the chat list, My Circle people, and every My Circle picker (SOS,
/// CCTV viewers, vehicle drivers, forward, share, journeys, kids watch,
/// school mode …). Missing-person alert (agent/missing) reuses it too.

enum PeopleFilter { all, family, others }

const String kGroupFamily = 'family';
const String kGroupOthers = 'others';

/// Mirrors backend core/logic/circle_family.FAMILY_RELATIONS.
const Set<String> kFamilyRelations = {
  'father', 'mother', 'child', 'parent', 'husband', 'wife', 'spouse',
  'brother', 'sister', 'sibling', 'relative', 'grandparent', 'grandchild',
  'uncle', 'aunt', 'cousin', 'family',
};

/// The row's group. Server field first; an older server (no field) falls
/// back to the relation so Family still comes first.
String circleGroupOf(Map row) {
  final g = '${row['circle_group'] ?? ''}'.trim().toLowerCase();
  if (g == kGroupFamily || g == kGroupOthers) return g;
  final rel = '${row['relation'] ?? ''}'.trim().toLowerCase();
  return kFamilyRelations.contains(rel) ? kGroupFamily : kGroupOthers;
}

bool isFamilyRow(Map row) => circleGroupOf(row) == kGroupFamily;

String _norm(String s) => s.toLowerCase().trim();

/// Default searchable text of a row (name, nickname, phone, relation).
String peopleSearchText(Map row) => [
      row['name'], row['display_name'], row['nickname'], row['my_nickname'],
      row['phone'], row['relation_label'], row['custom_label'], row['contact'],
    ].where((x) => x != null && '$x'.isNotEmpty).join(' ');

/// Chips + search. [textOf] picks what the search looks at.
List<T> filterPeople<T extends Map>(List<T> rows, PeopleFilter f, String query,
    {String Function(T row)? textOf}) {
  return [
    for (final r in rows)
      if ((f == PeopleFilter.all ||
              (f == PeopleFilter.family) == (circleGroupOf(r) == kGroupFamily)) &&
          peopleTextMatches(textOf?.call(r) ?? peopleSearchText(r), query))
        r
  ];
}

/// circlefam: the ONE text matcher for people search (chat list, pickers,
/// message search): case-insensitive substring, and a number typed in
/// Bangla or English digits (>= 3 digits) matches the other script too —
/// a Bangla-digit "01711" finds "01711-…". An empty query matches everything.
bool peopleTextMatches(String hay, String query) {
  final q = _norm(query);
  if (q.isEmpty) return true;
  final h = _norm(hay);
  if (h.contains(q)) return true;
  final latinQ = _toLatinDigits(q);
  final latinH = _toLatinDigits(h);
  // a word with Bangla digits inside still finds the English-digit text
  if (latinH.contains(latinQ)) return true;
  // a phone number typed with spaces / dashes / +: digits only, >= 3
  if (!RegExp(r'^[0-9\s\-+()]+$').hasMatch(latinQ)) return false;
  final digitsQ = latinQ.replaceAll(RegExp(r'\D'), '');
  return digitsQ.length >= 3 &&
      latinH.replaceAll(RegExp(r'\D'), '').contains(digitsQ);
}

/// Bangla digits (U+09E6..U+09EF) -> 0-9 so Bangla-digit numbers finds "01711".
String _toLatinDigits(String s) {
  final b = StringBuffer();
  for (final c in s.codeUnits) {
    b.writeCharCode(c >= 0x09E6 && c <= 0x09EF ? 0x30 + (c - 0x09E6) : c);
  }
  return b.toString();
}

/// [(group, rows)] with Family first; empty sections dropped.
List<(String, List<T>)> sectionPeople<T extends Map>(List<T> rows) {
  final fam = [for (final r in rows) if (circleGroupOf(r) == kGroupFamily) r];
  final oth = [for (final r in rows) if (circleGroupOf(r) != kGroupFamily) r];
  return [
    if (fam.isNotEmpty) (kGroupFamily, fam),
    if (oth.isNotEmpty) (kGroupOthers, oth),
  ];
}

/// The chip choice, remembered per list ("chats", "pick-sos", …).
class PeopleFilterStore {
  static String _k(String list) => 'cfa_filter_$list';

  static Future<PeopleFilter> load(String list) async {
    try {
      final p = await SharedPreferences.getInstance();
      final v = p.getString(_k(list)) ?? '';
      return PeopleFilter.values.firstWhere((e) => e.name == v,
          orElse: () => PeopleFilter.all);
    } catch (_) {
      return PeopleFilter.all;
    }
  }

  static Future<void> save(String list, PeopleFilter f) async {
    try {
      await (await SharedPreferences.getInstance()).setString(_k(list), f.name);
    } catch (_) {}
  }
}

String peopleFilterLabel(AppLocalizations t, PeopleFilter f) => switch (f) {
      PeopleFilter.all => t.cfaAll,
      PeopleFilter.family => t.cfaFamily,
      PeopleFilter.others => t.cfaOthers,
    };

String groupLabel(AppLocalizations t, String group) =>
    group == kGroupFamily ? t.cfaFamily : t.cfaOthers;

/// "All / Family / Others" chips (+ an optional search field). Wraps at 200 %
/// font; every chip is ≥ 48 dp tall for TalkBack.
class PeopleFilterBar extends StatelessWidget {
  const PeopleFilterBar({
    super.key,
    required this.filter,
    required this.onFilter,
    this.onQuery,
    this.query,
    this.keyPrefix = 'cfa',
  });
  final PeopleFilter filter;
  final ValueChanged<PeopleFilter> onFilter;
  final ValueChanged<String>? onQuery; // null = no search field
  final TextEditingController? query;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min,
        children: [
      if (onQuery != null)
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.sm),
          child: TextField(
            key: Key('$keyPrefix-search'),
            controller: query,
            onChanged: onQuery,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: t.cfaSearchPeople,
              prefixIcon: const Icon(Icons.search_rounded),
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
      Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
        for (final f in PeopleFilter.values)
          ChoiceChip(
            key: Key('$keyPrefix-chip-${f.name}'),
            label: Text(peopleFilterLabel(t, f)),
            avatar: f == PeopleFilter.family
                ? const Icon(Icons.family_restroom_rounded, size: 18)
                : null,
            selected: filter == f,
            materialTapTargetSize: MaterialTapTargetSize.padded,
            onSelected: (_) => onFilter(f),
          ),
      ]),
    ]);
  }
}

/// Section title (Family / Others) inside a picker.
class PeopleSectionHeader extends StatelessWidget {
  const PeopleSectionHeader(this.group, {super.key, this.count});
  final String group;
  final int? count;
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.md, Gap.xs, Gap.xs),
        child: Row(children: [
          Icon(group == kGroupFamily ? Icons.family_restroom_rounded : Icons.people_alt_rounded,
              size: 18, color: scheme.primary),
          const SizedBox(width: Gap.xs),
          Flexible(
            child: Text(groupLabel(t, group),
                key: Key('cfa-section-$group'),
                style: AType.titleSmall.copyWith(
                    color: scheme.primary, fontWeight: FontWeight.w700)),
          ),
        ]),
      ),
    );
  }
}

/// A picker body: chips + search + "Family" then "Others" sections, the
/// chip remembered under [listKey]. [rowBuilder] draws one person.
/// [emptyFamily] is shown when the Family chip has nobody (benefit line +
/// how-to; never a dead end).
class CirclePeopleList extends StatefulWidget {
  const CirclePeopleList({
    super.key,
    required this.rows,
    required this.listKey,
    required this.rowBuilder,
    this.textOf,
    this.searchAt = 6,
    this.initialFilter,
  });
  final List<Map<String, dynamic>> rows;
  final String listKey;
  final Widget Function(BuildContext context, Map<String, dynamic> row) rowBuilder;
  final String Function(Map<String, dynamic> row)? textOf;

  /// Show the search field from this many people (small lists stay calm).
  final int searchAt;

  /// Start on this chip instead of the remembered one (tests / gallery).
  final PeopleFilter? initialFilter;

  @override
  State<CirclePeopleList> createState() => _CirclePeopleListState();
}

class _CirclePeopleListState extends State<CirclePeopleList> {
  PeopleFilter _filter = PeopleFilter.all;
  String _q = '';
  final _qc = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.initialFilter != null) {
      _filter = widget.initialFilter!;
      return;
    }
    PeopleFilterStore.load(widget.listKey).then((f) {
      if (mounted) setState(() => _filter = f);
    });
  }

  @override
  void dispose() {
    _qc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final shown = filterPeople(widget.rows, _filter, _q, textOf: widget.textOf);
    final sections = sectionPeople(shown);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min,
        children: [
      PeopleFilterBar(
        keyPrefix: 'cfa-${widget.listKey}',
        filter: _filter,
        query: _qc,
        onQuery: widget.rows.length >= widget.searchAt ? (v) => setState(() => _q = v) : null,
        onFilter: (f) {
          setState(() => _filter = f);
          PeopleFilterStore.save(widget.listKey, f);
        },
      ),
      if (shown.isEmpty)
        Padding(
          key: const Key('cfa-empty'),
          padding: const EdgeInsets.symmetric(vertical: Gap.lg),
          child: Column(children: [
            Icon(_filter == PeopleFilter.family
                    ? Icons.family_restroom_rounded
                    : Icons.search_off_rounded,
                size: 36, color: scheme.primary),
            const SizedBox(height: Gap.sm),
            Text(
                _q.isNotEmpty
                    ? t.cfaNoMatch
                    : (_filter == PeopleFilter.family ? t.cfaNoFamilyYet : t.cfaNoOthersYet),
                textAlign: TextAlign.center,
                style: AType.bodyMedium),
            const SizedBox(height: Gap.sm),
            if (_q.isEmpty && _filter != PeopleFilter.all)
              Text(t.cfaHowToMark,
                  textAlign: TextAlign.center,
                  style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.sm),
            FilledButton.tonalIcon(
              key: const Key('cfa-show-all'),
              onPressed: () {
                _qc.clear();
                setState(() {
                  _q = '';
                  _filter = PeopleFilter.all;
                });
                PeopleFilterStore.save(widget.listKey, PeopleFilter.all);
              },
              icon: const Icon(Icons.people_rounded),
              label: Text(t.cfaShowEveryone),
            ),
          ]),
        ),
      for (final (g, rows) in sections) ...[
        if (_filter == PeopleFilter.all) PeopleSectionHeader(g),
        for (final r in rows) widget.rowBuilder(context, r),
      ],
    ]);
  }
}

/// "Family / Others / Automatic" for one Circle member. Saves through
/// POST /circle/<id>/people-group and returns the server's member row
/// (null = cancelled / failed — a snackbar says so).
Future<Map<String, dynamic>?> markCircleGroup(
    BuildContext context, ApiClient api, Map<String, dynamic> member) async {
  final t = AppLocalizations.of(context);
  final id = int.tryParse('${member['id'] ?? member['circle_id'] ?? ''}');
  if (id == null) return null;
  final auto = member['circle_group_auto'] != false;
  final current = auto ? 'auto' : circleGroupOf(member);
  final name = '${member['display_name'] ?? member['name'] ?? ''}'.trim();
  final pick = await showAppSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min,
            children: [
          Text(t.cfaMarkTitle(name),
              style: AType.titleLarge.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.xs),
          Text(t.cfaMarkWhy, style: AType.bodyMedium),
          const SizedBox(height: Gap.md),
          for (final (v, label, icon) in [
            (kGroupFamily, t.cfaFamily, Icons.family_restroom_rounded),
            (kGroupOthers, t.cfaOthers, Icons.people_alt_rounded),
            ('auto', t.cfaAutomatic, Icons.auto_awesome_rounded),
          ])
            ListTile(
              key: Key('cfa-mark-$v'),
              minTileHeight: 56,
              leading: Icon(icon),
              title: Text(label),
              subtitle: v == 'auto' ? Text(t.cfaAutomaticSub) : null,
              trailing: current == v ? const Icon(Icons.check_rounded) : null,
              onTap: () => Navigator.pop(ctx, v),
            ),
        ]),
      ),
    ),
  );
  if (pick == null || pick == current) return null;
  try {
    final r = await api.postJson('/circle/$id/people-group', {'group': pick});
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          content: Text(t.cfaMarkedAs(groupLabel(t, circleGroupOf(r))))));
    }
    return r;
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(t.cfaMarkFailed)));
    }
    return null;
  }
}
