import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
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
        title: Text(item == null ? AppLocalizations.of(context).memoryNewItemTitle : AppLocalizations.of(context).memoryEditItemTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                  controller: title,
                  decoration: InputDecoration(
                      labelText: AppLocalizations.of(context).memoryTitleLabel)),
              const SizedBox(height: 10),
              TextField(
                  controller: category,
                  decoration: InputDecoration(
                      labelText: AppLocalizations.of(context).memoryCategoryLabel)),
              const SizedBox(height: 10),
              TextField(
                  controller: detail,
                  maxLines: 3,
                  decoration:
                      InputDecoration(labelText: AppLocalizations.of(context).memoryDetailLabel)),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(AppLocalizations.of(context).cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(AppLocalizations.of(context).save)),
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
        title: Text(AppLocalizations.of(context).memoryScreenTitle),
        actions: [
          IconButton(
              onPressed: () => app.sync(),
              icon: const Icon(Icons.sync)),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context),
        icon: const Icon(Icons.add),
        label: Text(AppLocalizations.of(context).add),
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
                            _tag(m.isAi ? AppLocalizations.of(context).memoryTagAi : AppLocalizations.of(context).memoryTagManual,
                                m.isAi ? Colors.teal : Colors.indigo),
                            if (m.pendingOp != 'none')
                              _tag(AppLocalizations.of(context).memoryTagSyncing, Colors.orange),
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
                      itemBuilder: (_) => [
                        PopupMenuItem(value: 'edit', child: Text(AppLocalizations.of(context).edit)),
                        PopupMenuItem(value: 'del', child: Text(AppLocalizations.of(context).delete)),
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
    return Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.psychology_outlined, size: 56, color: Colors.grey),
            SizedBox(height: 12),
            Text(AppLocalizations.of(context).memoryEmptyTitle,
                style: TextStyle(fontSize: 16)),
            SizedBox(height: 6),
            Text(
              AppLocalizations.of(context).memoryEmptyHint,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
