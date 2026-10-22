import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../widgets/offline_banner.dart';
import '../widgets/rem_notes.dart';
import '../widgets/bn_day_periods.dart' show appDateLocale;

/// Advanced Notes + To-Do (#22, SPEC v2.1 §21).
///
/// Notes are now checklist-capable, pinnable, taggable, searchable, can carry a
/// due date (so they appear on the combined reminders calendar) and can be
/// turned into a reminder in one tap. To-dos gain priority + due dates. All ten
/// §21 pillars: empty / loading / offline / no-search-results / bilingual /
/// WCAG. Zero Bangla glyph literals in source.
class NotesTodosScreen extends StatelessWidget {
  const NotesTodosScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
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
    final items = all.where((it) => _matches(it['data'], _query)).toList();

    return Scaffold(
      floatingActionButton: FloatingActionButton(
          onPressed: () => editNote(context), child: const Icon(Icons.add)),
      body: Column(children: [
        if (all.isNotEmpty) _SearchBar(controller: _search, onChanged: (v) => setState(() => _query = v)),
        Expanded(
          child: all.isEmpty
              ? StateMessage(
                  icon: Icons.sticky_note_2_outlined,
                  title: t.notesEmptyNotes,
                  message: t.notesEmptyNotesHint,
                )
              : items.isEmpty
                  ? StateMessage(
                      icon: Icons.search_off,
                      title: t.notesNoMatch,
                      message: t.notesNoMatchHint,
                    )
                  : ListView(
                      padding:
                          const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 96),
                      children: [
                        for (final it in items) _NoteCard(item: it),
                      ],
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
    final linked = d['reminder_local_id'] != null;
    final titleText = (d['title'] ?? '').toString().isEmpty
        ? (d['body'] ?? '').toString()
        : (d['title']).toString();

    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Card(
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
                          ? Icons.push_pin
                          : Icons.sticky_note_2_outlined,
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
                      child: Icon(Icons.flag, size: 16, color: Brand.warning),
                    ),
                  PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'pin') {
                        app.notes.update(item, {'pinned': !pinned});
                      } else if (v == 'remind') {
                        noteToReminder(context, item);
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
                              const Icon(Icons.alarm_add, size: 18),
                              const SizedBox(width: Gap.sm),
                              Text(t.notesMakeReminder),
                            ])),
                      PopupMenuItem(value: 'del', child: Text(t.delete)),
                    ],
                  ),
                ]),
                if ((d['body'] ?? '').toString().isNotEmpty &&
                    (d['title'] ?? '').toString().isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Padding(
                    padding: const EdgeInsets.only(left: 28),
                    child: Text((d['body']).toString(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: scheme.onSurfaceVariant, fontSize: 13)),
                  ),
                ],
                // checklist preview: first 3 lines, tappable to tick
                if (checklist.isNotEmpty) ...[
                  const SizedBox(height: Gap.xs),
                  for (var i = 0; i < checklist.length && i < 3; i++)
                    Padding(
                      padding: const EdgeInsets.only(left: 24),
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
                                  ? Icons.check_box
                                  : Icons.check_box_outline_blank,
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
                                  ? TextStyle(
                                      decoration: TextDecoration.lineThrough,
                                      color: Theme.of(context).disabledColor,
                                      fontSize: 13)
                                  : const TextStyle(fontSize: 13),
                            ),
                          ),
                        ]),
                      ),
                    ),
                  if (checklist.length > 3)
                    Padding(
                      padding: const EdgeInsets.only(left: 24, top: 2),
                      child: Text(t.notesMoreItems(checklist.length - 3),
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant)),
                    ),
                ],
                // meta chip row: progress / due / link / tags
                if (checklist.isNotEmpty ||
                    due != null ||
                    linked ||
                    tags.isNotEmpty) ...[
                  const SizedBox(height: Gap.xs),
                  Padding(
                    padding: const EdgeInsets.only(left: 24),
                    child: Wrap(
                      spacing: Gap.sm,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (checklist.isNotEmpty)
                          _chip(Icons.checklist, '$done/${checklist.length}',
                              Brand.success),
                        if (due != null)
                          _chip(Icons.event,
                              DateFormat('d MMM, h:mm a', appDateLocale(context)).format(due),
                              Brand.blue),
                        if (linked)
                          _chip(Icons.alarm_on, t.notesHasReminder,
                              Brand.purple),
                        for (final tag in tags.take(3))
                          _chip(Icons.label_outline, tag.toString(),
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
        Text(label, style: TextStyle(fontSize: 12, color: tint)),
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
      floatingActionButton: FloatingActionButton(
          onPressed: () => editTodo(context), child: const Icon(Icons.add)),
      body: items.isEmpty
          ? StateMessage(
              icon: Icons.checklist_outlined,
              title: t.notesEmptyTasks,
              message: t.notesEmptyTasksHint,
            )
          : Column(
              children: [
                Padding(
                  padding:
                      const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, 0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(t.notesOpenCount(open),
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
                  child: ListView(
                    padding:
                        const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 96),
                    children: [
                      for (final it in items) _TodoTile(item: it),
                    ],
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

    return CheckboxListTile(
      value: done,
      onChanged: (v) => app.todos.update(item, {'done': v ?? false}),
      title: Text((d['title'] ?? '').toString(),
          style: done
              ? TextStyle(
                  decoration: TextDecoration.lineThrough,
                  color: Theme.of(context).disabledColor)
              : null),
      subtitle: (due != null || high)
          ? Wrap(spacing: Gap.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
              if (high)
                _chip(Icons.flag, t.remPriorityHigh, Brand.warning),
              if (due != null)
                _chip(
                    Icons.event,
                    DateFormat('d MMM, h:mm a', appDateLocale(context)).format(due),
                    overdue ? Brand.danger : Brand.blue),
              if (overdue) _chip(Icons.warning_amber_rounded, t.remGroupOverdue, Brand.danger),
            ])
          : null,
      secondary: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          tooltip: t.edit,
          icon: const Icon(Icons.edit_outlined),
          onPressed: () => editTodo(context, item: item),
        ),
        IconButton(
          tooltip: t.delete,
          icon: const Icon(Icons.delete_outline),
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

  Widget _chip(IconData icon, String label, Color tint) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12, color: tint),
        const SizedBox(width: 2),
        Text(label, style: TextStyle(fontSize: 11, color: tint)),
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
          prefixIcon: const Icon(Icons.search, size: 20),
          hintText: t.notesSearchHint,
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear, size: 18),
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
