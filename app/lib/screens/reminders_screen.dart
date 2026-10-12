import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../state.dart';
import '../notifications.dart';

const _recOptions = {
  'none': 'একবার',
  'daily': 'প্রতিদিন',
  'weekly': 'সাপ্তাহিক',
  'monthly': 'মাসিক',
  'yearly': 'বার্ষিক',
};

class RemindersScreen extends StatelessWidget {
  const RemindersScreen({super.key});

  Future<void> _edit(BuildContext context, {Map<String, dynamic>? item}) async {
    final app = context.read<AppState>();
    final data = (item?['data'] as Map<String, dynamic>?) ?? {};
    final title = TextEditingController(text: data['title'] ?? '');
    final notes = TextEditingController(text: data['notes'] ?? '');
    DateTime? due =
        data['due_at'] != null ? DateTime.tryParse(data['due_at'])?.toLocal() : null;
    String rec = data['recurrence'] ?? 'none';

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        return AlertDialog(
          title: Text(item == null ? 'নতুন রিমাইন্ডার' : 'রিমাইন্ডার এডিট'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: title,
                  decoration: const InputDecoration(labelText: 'কী মনে করাব? *')),
              const SizedBox(height: 10),
              TextField(controller: notes, maxLines: 2,
                  decoration: const InputDecoration(labelText: 'নোট (ঐচ্ছিক)')),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.schedule, size: 18),
                    label: Text(due == null
                        ? 'সময় দিন'
                        : DateFormat('d MMM, h:mm a').format(due!)),
                    onPressed: () async {
                      final d = await showDatePicker(
                          context: ctx, initialDate: due ?? DateTime.now(),
                          firstDate: DateTime.now().subtract(const Duration(days: 1)),
                          lastDate: DateTime.now().add(const Duration(days: 3650)));
                      if (d == null) return;
                      final t = await showTimePicker(
                          context: ctx,
                          initialTime: TimeOfDay.fromDateTime(due ?? DateTime.now()));
                      setD(() => due = DateTime(d.year, d.month, d.day,
                          t?.hour ?? 9, t?.minute ?? 0));
                    },
                  ),
                ),
                if (due != null)
                  IconButton(onPressed: () => setD(() => due = null),
                      icon: const Icon(Icons.clear)),
              ]),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                value: rec,
                decoration: const InputDecoration(labelText: 'পুনরাবৃত্তি'),
                items: _recOptions.entries
                    .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                    .toList(),
                onChanged: (v) => setD(() => rec = v ?? 'none'),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('বাতিল')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('সেভ')),
          ],
        );
      }),
    );

    if (saved == true && title.text.trim().isNotEmpty) {
      final payload = {
        'title': title.text.trim(),
        'notes': notes.text.trim(),
        'due_at': due?.toUtc().toIso8601String(),
        'recurrence': rec,
        'done': data['done'] ?? false,
      };
      if (item == null) {
        await app.reminders.add(payload);
      } else {
        await app.reminders.update(item, payload);
      }
      // best-effort device reminder
      final lid = item?['localId'] ?? app.reminders.items.first['localId'];
      if (due != null) {
        Notifications.schedule(lid, title.text.trim(), notes.text.trim(), due!);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final items = app.reminders.items;
    final fmt = DateFormat('d MMM, h:mm a');
    return Scaffold(
      appBar: AppBar(title: const Text('রিমাইন্ডার'), actions: [
        IconButton(onPressed: () => app.reminders.sync(), icon: const Icon(Icons.sync)),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context),
        icon: const Icon(Icons.add_alarm), label: const Text('যোগ করুন')),
      body: items.isEmpty
          ? const _Empty(icon: Icons.alarm, text: 'কোনো রিমাইন্ডার নেই।\n"যোগ করুন" চাপুন।')
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(height: 6),
              itemBuilder: (_, i) {
                final it = items[i];
                final d = it['data'] as Map<String, dynamic>;
                final done = d['done'] == true;
                final due = d['due_at'] != null
                    ? DateTime.tryParse(d['due_at'])?.toLocal() : null;
                return Card(
                  child: ListTile(
                    leading: Checkbox(
                      value: done,
                      onChanged: (v) {
                        app.reminders.update(it, {'done': v ?? false});
                        if (v == true) Notifications.cancel(it['localId']);
                      },
                    ),
                    title: Text(d['title'] ?? '',
                        style: done
                            ? const TextStyle(decoration: TextDecoration.lineThrough,
                                color: Colors.grey)
                            : null),
                    subtitle: Text([
                      if (due != null) '⏰ ${fmt.format(due)}',
                      if ((d['recurrence'] ?? 'none') != 'none')
                        '🔁 ${_recOptions[d['recurrence']]}',
                      if ((d['notes'] ?? '').toString().isNotEmpty) d['notes'],
                    ].join('  ')),
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) {
                        if (v == 'edit') _edit(context, item: it);
                        if (v == 'del') _del(context, it);
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('এডিট')),
                        PopupMenuItem(value: 'del', child: Text('মুছুন')),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }

  void _del(BuildContext context, Map<String, dynamic> it) {
    final app = context.read<AppState>();
    Notifications.cancel(it['localId']);
    app.reminders.remove(it);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text('মুছে ফেলা হয়েছে'),
      action: SnackBarAction(label: 'ফিরিয়ে আনুন', onPressed: () => app.undoLast()),
    ));
  }
}

class _Empty extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Empty({required this.icon, required this.text});
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 54, color: Colors.grey),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey)),
          ]),
        ),
      );
}
