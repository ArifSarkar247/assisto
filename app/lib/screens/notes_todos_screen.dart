import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';

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
            Tab(child: Text(t.notesTabNotes, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
            Tab(child: Text(t.notesTabTodos, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
          ]),
        ),
        body: const TabBarView(children: [_NotesTab(), _TodosTab()]),
      ),
    );
  }
}

class _NotesTab extends StatelessWidget {
  const _NotesTab();

  Future<void> _edit(BuildContext context, {Map<String, dynamic>? item}) async {
    final t = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final d = (item?['data'] as Map<String, dynamic>?) ?? {};
    final title = TextEditingController(text: d['title'] ?? '');
    final body = TextEditingController(text: d['body'] ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(item == null ? t.memoryNewItemTitle : t.memoryEditItemTitle),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: title,
                autofocus: item == null,
                decoration: InputDecoration(labelText: t.title)),
            const SizedBox(height: Gap.md),
            TextField(
                controller: body,
                maxLines: 5,
                decoration: InputDecoration(labelText: t.notesBody)),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: Text(t.save)),
        ],
      ),
    );
    if (ok == true &&
        (title.text.trim().isNotEmpty || body.text.trim().isNotEmpty)) {
      final payload = {
        'title': title.text.trim(),
        'body': body.text.trim(),
        'pinned': d['pinned'] ?? false,
      };
      if (item == null) {
        await app.notes.add(payload);
      } else {
        await app.notes.update(item, payload);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    final items = [...app.notes.items];
    // pinned first (stable)
    items.sort((a, b) {
      final pa = (a['data']['pinned'] == true) ? 0 : 1;
      final pb = (b['data']['pinned'] == true) ? 0 : 1;
      return pa.compareTo(pb);
    });
    return Scaffold(
      floatingActionButton: FloatingActionButton(
          onPressed: () => _edit(context), child: const Icon(Icons.add)),
      body: items.isEmpty
          ? StateMessage(
              icon: Icons.sticky_note_2_outlined,
              title: t.notesEmptyNotes,
              message: t.notesEmptyNotesHint,
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
              children: [
                for (final it in items)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Gap.sm),
                    child: Card(
                      child: ListTile(
                        leading: it['data']['pinned'] == true
                            ? const Icon(Icons.push_pin, color: Brand.warning)
                            : const Icon(Icons.sticky_note_2_outlined),
                        title: Text((it['data']['title'] ?? '').toString().isEmpty
                            ? (it['data']['body'] ?? '').toString()
                            : it['data']['title'].toString()),
                        subtitle: (it['data']['title'] ?? '')
                                .toString()
                                .isNotEmpty
                            ? Text((it['data']['body'] ?? '').toString(),
                                maxLines: 2, overflow: TextOverflow.ellipsis)
                            : null,
                        onTap: () => _edit(context, item: it),
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) {
                            if (v == 'pin') {
                              app.notes.update(it, {
                                'pinned': !(it['data']['pinned'] == true),
                              });
                            } else if (v == 'del') {
                              app.notes.remove(it);
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                content: Text(t.commonDeleted),
                                action: SnackBarAction(
                                    label: t.undo,
                                    onPressed: () => app.undoLast()),
                              ));
                            }
                          },
                          itemBuilder: (_) => [
                            PopupMenuItem(
                                value: 'pin',
                                child: Text(it['data']['pinned'] == true
                                    ? t.notesUnpin
                                    : t.notesPin)),
                            PopupMenuItem(value: 'del', child: Text(t.delete)),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _TodosTab extends StatelessWidget {
  const _TodosTab();

  Future<void> _add(BuildContext context) async {
    final t = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final title = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.notesNewTask),
        content: TextField(
            controller: title,
            autofocus: true,
            decoration: InputDecoration(labelText: t.notesTaskField)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: Text(t.add)),
        ],
      ),
    );
    if (ok == true && title.text.trim().isNotEmpty) {
      await app.todos.add({'title': title.text.trim(), 'done': false});
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    final items = [...app.todos.items];
    // open first, done last (stable)
    items.sort((a, b) {
      final da = (a['data']['done'] == true) ? 1 : 0;
      final db = (b['data']['done'] == true) ? 1 : 0;
      return da.compareTo(db);
    });
    final open = items.where((i) => i['data']['done'] != true).length;
    return Scaffold(
      floatingActionButton: FloatingActionButton(
          onPressed: () => _add(context), child: const Icon(Icons.add)),
      body: items.isEmpty
          ? StateMessage(
              icon: Icons.checklist_outlined,
              title: t.notesEmptyTasks,
              message: t.notesEmptyTasksHint,
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, 0),
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
                      for (final it in items)
                        CheckboxListTile(
                          value: it['data']['done'] == true,
                          onChanged: (v) =>
                              app.todos.update(it, {'done': v ?? false}),
                          title: Text((it['data']['title'] ?? '').toString(),
                              style: it['data']['done'] == true
                                  ? TextStyle(
                                      decoration: TextDecoration.lineThrough,
                                      color: Theme.of(context).disabledColor)
                                  : null),
                          secondary: IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () {
                              app.todos.remove(it);
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                content: Text(t.commonDeleted),
                                action: SnackBarAction(
                                    label: t.undo,
                                    onPressed: () => app.undoLast()),
                              ));
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
