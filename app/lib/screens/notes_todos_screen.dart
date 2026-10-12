import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';

class NotesTodosScreen extends StatelessWidget {
  const NotesTodosScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('নোট ও কাজ'),
          bottom: const TabBar(tabs: [Tab(text: 'নোট'), Tab(text: 'To-Do')]),
        ),
        body: const TabBarView(children: [_NotesTab(), _TodosTab()]),
      ),
    );
  }
}

class _NotesTab extends StatelessWidget {
  const _NotesTab();

  Future<void> _edit(BuildContext context, {Map<String, dynamic>? item}) async {
    final app = context.read<AppState>();
    final d = (item?['data'] as Map<String, dynamic>?) ?? {};
    final title = TextEditingController(text: d['title'] ?? '');
    final body = TextEditingController(text: d['body'] ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(item == null ? 'নতুন নোট' : 'নোট এডিট'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: title,
                decoration: const InputDecoration(labelText: 'শিরোনাম')),
            const SizedBox(height: 10),
            TextField(controller: body, maxLines: 5,
                decoration: const InputDecoration(labelText: 'লেখা')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('বাতিল')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('সেভ')),
        ],
      ),
    );
    if (ok == true && (title.text.trim().isNotEmpty || body.text.trim().isNotEmpty)) {
      final payload = {'title': title.text.trim(), 'body': body.text.trim(),
        'pinned': d['pinned'] ?? false};
      if (item == null) {
        await app.notes.add(payload);
      } else {
        await app.notes.update(item, payload);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final items = app.notes.items;
    return Scaffold(
      floatingActionButton: FloatingActionButton(
          onPressed: () => _edit(context), child: const Icon(Icons.add)),
      body: items.isEmpty
          ? const Center(child: Text('কোনো নোট নেই।', style: TextStyle(color: Colors.grey)))
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
              children: [
                for (final it in items)
                  Card(
                    child: ListTile(
                      title: Text((it['data']['title'] ?? '').toString().isEmpty
                          ? (it['data']['body'] ?? '')
                          : it['data']['title']),
                      subtitle: (it['data']['title'] ?? '').toString().isNotEmpty
                          ? Text(it['data']['body'] ?? '', maxLines: 2,
                              overflow: TextOverflow.ellipsis)
                          : null,
                      onTap: () => _edit(context, item: it),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () {
                          app.notes.remove(it);
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: const Text('মুছে ফেলা হয়েছে'),
                            action: SnackBarAction(
                                label: 'ফিরিয়ে আনুন', onPressed: () => app.undoLast()),
                          ));
                        },
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
    final app = context.read<AppState>();
    final title = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('নতুন কাজ'),
        content: TextField(controller: title, autofocus: true,
            decoration: const InputDecoration(labelText: 'কাজ')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('বাতিল')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('যোগ')),
        ],
      ),
    );
    if (ok == true && title.text.trim().isNotEmpty) {
      await app.todos.add({'title': title.text.trim(), 'done': false});
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final items = app.todos.items;
    return Scaffold(
      floatingActionButton: FloatingActionButton(
          onPressed: () => _add(context), child: const Icon(Icons.add)),
      body: items.isEmpty
          ? const Center(child: Text('কোনো কাজ নেই।', style: TextStyle(color: Colors.grey)))
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
              children: [
                for (final it in items)
                  CheckboxListTile(
                    value: it['data']['done'] == true,
                    onChanged: (v) => app.todos.update(it, {'done': v ?? false}),
                    title: Text(it['data']['title'] ?? '',
                        style: it['data']['done'] == true
                            ? const TextStyle(
                                decoration: TextDecoration.lineThrough, color: Colors.grey)
                            : null),
                    secondary: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () {
                        app.todos.remove(it);
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: const Text('মুছে ফেলা হয়েছে'),
                          action: SnackBarAction(
                              label: 'ফিরিয়ে আনুন', onPressed: () => app.undoLast()),
                        ));
                      },
                    ),
                  ),
              ],
            ),
    );
  }
}
