import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../ads/ad_banner_slot.dart' show AdBannerSlot;
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../ads/ad_placements.dart' show AdMoments;
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../widgets/offline_banner.dart';
import '../widgets/rem_notes.dart';
import '../widgets/bn_day_periods.dart' show appDateLocale;
import '../widgets/fam_empty.dart' show FamEmptyState; // remnotes
import '../widgets/rn_bits.dart';

/// Advanced Notes + To-Do (#22, SPEC v2.1 §21).
///
/// Notes are now checklist-capable, pinnable, taggable, searchable, can carry a
/// due date (so they appear on the combined reminders calendar) and can be
/// turned into a reminder in one tap. To-dos gain priority + due dates. All ten
/// §21 pillars: empty / loading / offline / no-search-results / bilingual /
/// WCAG. Zero Bangla glyph literals in source.
class NotesTodosScreen extends StatelessWidget {
  const NotesTodosScreen({super.key, this.initialIndex = 0});

  /// 0 = Notes, 1 = To-do (remnotes: gallery / deep links).
  final int initialIndex;
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return DefaultTabController(
      length: 2,
      initialIndex: initialIndex.clamp(0, 1),
      child: Scaffold(
        // banners-everywhere (owner 26 Oct): one bottom banner, Free only
        bottomNavigationBar: const AdBannerSlot(screen: 'notes_todos'),
        appBar: AppBar(
          title: Text(t.notesTitle),
          bottom: TabBar(tabs: [
            Tab(
                child: Text(t.notesTabNotes,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis)),
            Tab(
                child: Text(t.notesTabTodos,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis)),
          ]),
        ),
        body: const Column(children: [
          OfflineBanner(),
          Expanded(child: TabBarView(children: [_NotesTab(), _TodosTab()])),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- notes tab
class _NotesTab extends StatefulWidget {
  const _NotesTab();
  @override
  State<_NotesTab> createState() => _NotesTabState();
}

class _NotesTabState extends State<_NotesTab> {
  final _search = TextEditingController();
  String _query = '';
  String? _label; // remnotes: filter by one label

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Match a note against the search query across title, body, tags and
  /// checklist lines (case-insensitive, all-terms-must-match).
  bool _matches(Map<String, dynamic> d, String q) {
    if (q.isEmpty) return true;
    final hay = StringBuffer()
      ..write((d['title'] ?? '').toString().toLowerCase())
      ..write(' ')
      ..write((d['body'] ?? '').toString().toLowerCase());
    if (d['tags'] is List) {
      hay.write(' ${(d['tags'] as List).join(' ').toLowerCase()}');
    }
    if (d['checklist'] is List) {
      for (final c in d['checklist'] as List) {
        hay.write(' ${(c['text'] ?? '').toString().toLowerCase()}');
      }
    }
    final text = hay.toString();
    return q
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .every(text.contains);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    final all = [...app.notes.items];
    // pinned first, then most-recent-created (localId is time-prefixed) stable.
    all.sort((a, b) {
      final pa = (a['data']['pinned'] == true) ? 0 : 1;
      final pb = (b['data']['pinned'] == true) ? 0 : 1;
      return pa.compareTo(pb);
    });
    // remnotes: every label in use, for the one-tap filter row
    final labels = <String>{
      for (final it in all)
        if (it['data']['tags'] is List)
          for (final tg in it['data']['tags'] as List) '$tg',
    }.toList()
      ..sort();
    if (_label != null && !labels.contains(_label)) _label = null;
    final items = all
        .where((it) => _matches(it['data'], _query))
        .where((it) =>
            _label == null ||
            (it['data']['tags'] is List &&
                (it['data']['tags'] as List).map((e) => '$e').contains(_label)))
        .toList();

    return Scaffold(
      floatingActionButton: all.isEmpty
          ? null // the empty state's big button does it
          : FloatingActionButton(
              tooltip: AppLocalizations.of(context).add,
              onPressed: () => editNote(context),
              child: const Icon(Icons.add_rounded)),
      body: Column(children: [
        SyncRefusalStrip(message: app.notes.refusal),
        if (all.isNotEmpty) _SearchBar(controller: _search, onChanged: (v) => setState(() => _query = v)),
        if (labels.isNotEmpty)
          // grows with the text size (200% never clips a chip)
          SingleChildScrollView(
            key: const ValueKey('rn-label-row'),
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
            child: Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: Gap.xs),
                  child: ChoiceChip(
                    label: Text(t.rnAllLabels),
                    selected: _label == null,
                    onSelected: (_) => setState(() => _label = null),
                  ),
                ),
                for (final l in labels)
                  Padding(
                    padding: const EdgeInsets.only(right: Gap.xs),
                    child: Tooltip(
                      message: t.rnFilterByLabel,
                      child: ChoiceChip(
                        key: ValueKey('rn-label-$l'),
                        avatar: const Icon(Icons.label_outline_rounded, size: 16),
                        label: Text(l),
                        selected: _label == l,
                        onSelected: (on) => setState(() => _label = on ? l : null),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: all.isEmpty
              ? FamEmptyState(
                  key: const ValueKey('rn-notes-empty'),
                  icon: Icons.sticky_note_2_rounded,
                  title: t.notesEmptyNotes,
                  benefit: t.rnNotesBenefit,
                  primaryLabel: t.rnNotesAddFirst,
                  onPrimary: () => editNote(context),
                  steps: [t.rnNotesStep1, t.rnNotesStep2, t.rnNotesStep3],
                )
              : items.isEmpty
                  ? StateMessage(
                      icon: Icons.search_off_rounded,
                      title: t.notesNoMatch,
                      message: t.notesNoMatchHint,
                    )
                  // perf2gb-style: only the cards on screen are built
                  : ListView.builder(
                      padding:
                          const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 96),
                      itemCount: items.length,
                      itemBuilder: (_, i) => _NoteCard(item: items[i]),
                    ),
        ),
      ]),
    );
  }
}

class _NoteCard extends StatelessWidget {
  final Map<String, dynamic> item;
  const _NoteCard({required this.item});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final d = item['data'] as Map<String, dynamic>;
    final pinned = d['pinned'] == true;
    final high = (d['priority'] ?? 'none') == 'high';
    final checklist = d['checklist'] is List ? d['checklist'] as List : const [];
    final done =
        checklist.where((c) => c['done'] == true).length;
    final tags = d['tags'] is List ? d['tags'] as List : const [];
    final due = d['due_at'] != null
        ? DateTime.tryParse(d['due_at'])?.toLocal()
        : null;
    final linked = '${d['reminder_local_id'] ?? ''}'.isNotEmpty;
    final attachments =
        d['attachments'] is List ? (d['attachments'] as List).length : 0;
    final from = d['shared_from'] is Map ? '${(d['shared_from'] as Map)['name'] ?? ''}' : '';
    final titleText = (d['title'] ?? '').toString().isEmpty
        ? (d['body'] ?? '').toString()
        : (d['title']).toString();

    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Card(
        color: noteFill(context, d['color'] as String?), // remnotes
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.md),
          onTap: () => editNote(context, item: item),
          child: Padding(
            padding: const EdgeInsets.all(Gap.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(
                      pinned
                          ? Icons.push_pin_rounded
                          : Icons.sticky_note_2_rounded,
                      size: 20,
                      color: pinned ? Brand.warning : scheme.onSurfaceVariant),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Text(titleText,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                  ),
                  if (high)
                    const Padding(
                      padding: EdgeInsets.only(left: Gap.xs),
                      child: Icon(Icons.flag_rounded, size: 16, color: Brand.warning),
                    ),
                  PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'pin') {
                        app.notes.update(item, {'pinned': !pinned});
                      } else if (v == 'remind') {
                        noteToReminder(context, item);
                      } else if (v == 'share') {
                        shareNote(context, item);
                      } else if (v == 'del') {
                        app.notes.remove(item);
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(t.commonDeleted),
                          action: SnackBarAction(
                              label: t.undo, onPressed: () => app.undoLast()),
                        ));
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                          value: 'pin',
                          child: Text(pinned ? t.notesUnpin : t.notesPin)),
                      if (!linked)
                        PopupMenuItem(
                            value: 'remind',
                            child: Row(children: [
                              const Icon(Icons.alarm_add_rounded, size: 18),
                              const SizedBox(width: Gap.sm),
                              Text(t.notesMakeReminder),
                            ])),
                      PopupMenuItem(
                          value: 'share',
                          child: Row(children: [
                            const Icon(Icons.share_rounded, size: 18),
                            const SizedBox(width: Gap.sm),
                            Text(t.rnShare),
                          ])),
                      PopupMenuItem(value: 'del', child: Text(t.delete)),
                    ],
                  ),
                ]),
                if ((d['body'] ?? '').toString().isNotEmpty &&
                    (d['title'] ?? '').toString().isNotEmpty) ...[
                  const SizedBox(height: Gap.xxs),
                  Padding(
                    padding: const EdgeInsets.only(left: 28),
                    child: Text((d['body']).toString(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
                  ),
                ],
                // checklist preview: first 3 lines, tappable to tick
                if (checklist.isNotEmpty) ...[
                  const SizedBox(height: Gap.xs),
                  for (var i = 0; i < checklist.length && i < 3; i++)
                    Padding(
                      padding: const EdgeInsets.only(left: Gap.xl),
                      child: InkWell(
                        onTap: () {
                          final list = [
                            for (final c in checklist)
                              {'text': c['text'], 'done': c['done'] == true}
                          ];
                          list[i]['done'] = !(list[i]['done'] == true);
                          app.notes.update(item, {'checklist': list});
                        },
                        child: Row(children: [
                          Icon(
                              checklist[i]['done'] == true
                                  ? Icons.check_box_rounded
                                  : Icons.check_box_outline_blank_rounded,
                              size: 18,
                              color: checklist[i]['done'] == true
                                  ? Brand.success
                                  : scheme.onSurfaceVariant),
                          const SizedBox(width: Gap.xs),
                          Expanded(
                            child: Text(
                              (checklist[i]['text'] ?? '').toString(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: checklist[i]['done'] == true
                                  ? AType.bodyMedium.copyWith(decoration: TextDecoration.lineThrough, color: Theme.of(context).disabledColor)
                                  : AType.bodyMedium,
                            ),
                          ),
                        ]),
                      ),
                    ),
                  if (checklist.length > 3)
                    Padding(
                      padding: const EdgeInsets.only(left: Gap.xl, top: Gap.xxs),
                      child: Text(t.notesMoreItems(rnDigits(t, checklist.length - 3)),
                          style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
                    ),
                ],
                // meta chip row: progress / due / link / tags
                if (checklist.isNotEmpty ||
                    due != null ||
                    linked ||
                    attachments > 0 ||
                    from.isNotEmpty ||
                    tags.isNotEmpty) ...[
                  const SizedBox(height: Gap.xs),
                  Padding(
                    padding: const EdgeInsets.only(left: Gap.xl),
                    child: Wrap(
                      spacing: Gap.sm,
                      runSpacing: Gap.xxs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (checklist.isNotEmpty)
                          _chip(Icons.checklist_rounded,
                              rnDigits(t, '$done/${checklist.length}'),
                              Brand.onTint(context, Brand.success)),
                        if (from.isNotEmpty)
                          _chip(Icons.person_rounded, t.rnSharedFrom(from),
                              Brand.onTint(context, Brand.blue)),
                        if (attachments > 0)
                          _chip(Icons.attach_file_rounded, rnDigits(t, attachments),
                              scheme.onSurfaceVariant),
                        if (due != null)
                          _chip(Icons.event_rounded,
                              DateFormat('d MMM, h:mm a', appDateLocale(context)).format(due),
                              Brand.blue),
                        if (linked)
                          _chip(Icons.alarm_on_rounded, t.notesHasReminder,
                              Brand.purple),
                        for (final tag in tags.take(3))
                          _chip(Icons.label_outline_rounded, tag.toString(),
                              Brand.cyan),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _chip(IconData icon, String label, Color tint) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13, color: tint),
        const SizedBox(width: 3),
        Text(label, style: AType.bodySmall.copyWith(color: tint)),
      ]);
}

// ---------------------------------------------------------------- todos tab
class _TodosTab extends StatelessWidget {
  const _TodosTab();

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    final items = [...app.todos.items];
    // high-priority open first, then open, then done (stable).
    int rank(Map<String, dynamic> it) {
      final d = it['data'];
      if (d['done'] == true) return 2;
      return (d['priority'] ?? 'none') == 'high' ? 0 : 1;
    }

    items.sort((a, b) => rank(a).compareTo(rank(b)));
    final open = items.where((i) => i['data']['done'] != true).length;

    return Scaffold(
      floatingActionButton: items.isEmpty
          ? null
          : FloatingActionButton(
              tooltip: AppLocalizations.of(context).add,
              onPressed: () => editTodo(context),
              child: const Icon(Icons.add_rounded)),
      body: items.isEmpty
          ? Column(children: [
              SyncRefusalStrip(message: app.todos.refusal),
              Expanded(
                child: FamEmptyState(
                  key: const ValueKey('rn-todos-empty'),
                  icon: Icons.checklist_rounded,
                  title: t.notesEmptyTasks,
                  benefit: t.rnTodosBenefit,
                  primaryLabel: t.rnTodosAddFirst,
                  onPrimary: () => editTodo(context),
                  steps: [t.rnTodosStep1, t.rnTodosStep2, t.rnTodosStep3],
                ),
              ),
            ])
          : Column(
              children: [
                SyncRefusalStrip(message: app.todos.refusal),
                Padding(
                  padding:
                      const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, 0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(t.notesOpenCount(rnDigits(t, open)),
                        style: Theme.of(context)
                            .textTheme
                            .labelLarge
                            ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant)),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    padding:
                        const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 96),
                    itemCount: items.length,
                    itemBuilder: (_, i) => _TodoTile(item: items[i]),
                  ),
                ),
              ],
            ),
    );
  }
}

class _TodoTile extends StatelessWidget {
  final Map<String, dynamic> item;
  const _TodoTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final d = item['data'] as Map<String, dynamic>;
    final done = d['done'] == true;
    final high = (d['priority'] ?? 'none') == 'high';
    final due = d['due_at'] != null
        ? DateTime.tryParse(d['due_at'])?.toLocal()
        : null;
    final overdue = !done && due != null && due.isBefore(DateTime.now());
    final rule = d['recurrence_rule'] is Map &&
            (d['recurrence_rule'] as Map)['freq'] != null
        ? d['recurrence_rule'] as Map
        : null;

    return CheckboxListTile(
      value: done,
      onChanged: (v) {
        // remnotes: a repeating task moves to its next date and stays open
        final next = v == true ? todoNextDue(d) : null;
        if (next != null) {
          app.todos.update(item, {'due_at': next.toUtc().toIso8601String(), 'done': false});
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(t.rnTodoRepeated(
                  DateFormat('d MMM', appDateLocale(context)).format(next)))));
          AdMoments.report('task_done');
          return;
        }
        app.todos.update(item, {'done': v ?? false});
        // admob: finishing a task is a natural break (Free only, capped)
        if (v == true) AdMoments.report('task_done');
      },
      title: Text((d['title'] ?? '').toString(),
          style: done
              ? TextStyle(
                  decoration: TextDecoration.lineThrough,
                  color: Theme.of(context).disabledColor)
              : null),
      subtitle: (due != null || high || rule != null)
          ? Wrap(spacing: Gap.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
              if (high)
                _chip(Icons.flag_rounded, t.remPriorityHigh, Brand.warning),
              if (rule != null)
                _chip(Icons.repeat_rounded, _todoRepeatLabel(t, '${rule['freq']}'),
                    Brand.onTint(context, Brand.purple)),
              if (due != null)
                _chip(
                    Icons.event_rounded,
                    DateFormat('d MMM, h:mm a', appDateLocale(context)).format(due),
                    overdue ? Brand.danger : Brand.blue),
              if (overdue) _chip(Icons.warning_amber_rounded, t.remGroupOverdue, Brand.danger),
            ])
          : null,
      secondary: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          tooltip: t.edit,
          icon: const Icon(Icons.edit_rounded),
          onPressed: () => editTodo(context, item: item),
        ),
        IconButton(
          tooltip: t.delete,
          icon: const Icon(Icons.delete_outline_rounded),
          onPressed: () {
            app.todos.remove(item);
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(t.commonDeleted),
              action: SnackBarAction(
                  label: t.undo, onPressed: () => app.undoLast()),
            ));
          },
        ),
      ]),
    );
  }

  String _todoRepeatLabel(AppLocalizations t, String f) => switch (f) {
        'daily' => t.remRecurDaily,
        'weekly' => t.remRecurWeekly,
        'monthly' => t.remRecurMonthly,
        'yearly' => t.remRecurYearly,
        _ => '',
      };

  Widget _chip(IconData icon, String label, Color tint) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12, color: tint),
        const SizedBox(width: Gap.xxs),
        Text(label, style: AType.labelSmall.copyWith(color: tint)),
      ]);
}

// ---------------------------------------------------------------- search bar
class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  const _SearchBar({required this.controller, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 0),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: const Icon(Icons.search_rounded, size: 20),
          hintText: t.notesSearchHint,
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  tooltip: AppLocalizations.of(context).f2ClearSearch,
                  icon: const Icon(Icons.clear_rounded, size: 18),
                  onPressed: () {
                    controller.clear();
                    onChanged('');
                  },
                ),
        ),
      ),
    );
  }
}
