import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../models.dart';

class MemoryScreen extends StatelessWidget {
  const MemoryScreen({super.key});

  Future<void> _edit(BuildContext context, {MemoryItem? item}) async {
    final title = TextEditingController(text: item?.title ?? '');
    final category = TextEditingController(text: item?.category ?? '');
    final detail = TextEditingController(text: item?.detail ?? '');
    final app = context.read<AppState>();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(item == null ? 'নতুন তথ্য' : 'তথ্য সম্পাদনা'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                  controller: title,
                  decoration: const InputDecoration(
                      labelText: 'কী মনে রাখব? *')),
              const SizedBox(height: 10),
              TextField(
                  controller: category,
                  decoration: const InputDecoration(
                      labelText: 'ধরন (পরিবার / কাজ / স্বাস্থ্য...)')),
              const SizedBox(height: 10),
              TextField(
                  controller: detail,
                  maxLines: 3,
                  decoration:
                      const InputDecoration(labelText: 'বিস্তারিত (ঐচ্ছিক)')),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('বাতিল')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('সেভ')),
        ],
      ),
    );

    if (ok == true && title.text.trim().isNotEmpty) {
      if (item == null) {
        await app.addMemory(
            title: title.text.trim(),
            category: category.text.trim(),
            detail: detail.text.trim());
      } else {
        await app.editMemory(item,
            title: title.text.trim(),
            category: category.text.trim(),
            detail: detail.text.trim());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI কী জানে'),
        actions: [
          IconButton(
              onPressed: () => app.sync(),
              icon: const Icon(Icons.sync)),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context),
        icon: const Icon(Icons.add),
        label: const Text('যোগ করুন'),
      ),
      body: app.memory.isEmpty
          ? const _Empty()
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
              itemCount: app.memory.length,
              separatorBuilder: (_, __) => const SizedBox(height: 6),
              itemBuilder: (_, i) {
                final m = app.memory[i];
                return Card(
                  child: ListTile(
                    title: Text(m.title),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (m.detail.isNotEmpty) Text(m.detail),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 6,
                          children: [
                            if (m.category.isNotEmpty)
                              _tag(m.category, Colors.blueGrey),
                            _tag(m.isAi ? 'AI ধরেছে' : 'নিজে লিখেছেন',
                                m.isAi ? Colors.teal : Colors.indigo),
                            if (m.pendingOp != 'none')
                              _tag('সিঙ্ক হচ্ছে…', Colors.orange),
                          ],
                        ),
                      ],
                    ),
                    isThreeLine: m.detail.isNotEmpty,
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) {
                        if (v == 'edit') _edit(context, item: m);
                        if (v == 'del') app.removeMemory(m);
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('সম্পাদনা')),
                        PopupMenuItem(value: 'del', child: Text('মুছে ফেলুন')),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }

  Widget _tag(String text, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
            color: c.withOpacity(0.12),
            borderRadius: BorderRadius.circular(10)),
        child: Text(text, style: TextStyle(fontSize: 11, color: c)),
      );
}

class _Empty extends StatelessWidget {
  const _Empty();
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.psychology_outlined, size: 56, color: Colors.grey),
            SizedBox(height: 12),
            Text('এখনো কিছু সেভ করা হয়নি।',
                style: TextStyle(fontSize: 16)),
            SizedBox(height: 6),
            Text(
              'নিচের "যোগ করুন" চেপে AI-কে কিছু মনে রাখতে বলুন — '
              'যেমন "আব্বুর প্রেশারের ওষুধ সকাল ৮টা"।',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
