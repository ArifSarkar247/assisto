import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';

/// "What did I tell you about X?" — the memory brain.
///
/// Advanced vs Keep/Any.do: a natural-language retrieval box ("what is the wifi
/// password", "ammur oshudh niye ki bolechilam") that ranks memory items by a
/// deterministic keyword/fuzzy score (mirror of reminders_engine.search_memory),
/// plus category filter chips and AI/manual provenance tags.
class MemoryScreen extends StatefulWidget {
  const MemoryScreen({super.key});
  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  final _q = TextEditingController();
  String _query = '';
  String? _category; // active category filter

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    final all = app.memory;

    // category chips from the data
    final categories = <String>{
      for (final m in all)
        if (m.category.trim().isNotEmpty) m.category.trim()
    }.toList()
      ..sort();

    // filter + rank
    List<MemoryItem> shown = all;
    if (_category != null) {
      shown = shown.where((m) => m.category.trim() == _category).toList();
    }
    List<_Ranked> ranked;
    if (_query.trim().isNotEmpty) {
      ranked = searchMemory(_query, shown);
    } else {
      ranked = [for (final m in shown) _Ranked(m, 0, const [])];
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(t.memoryScreenTitle),
        actions: [
          IconButton(onPressed: () => app.sync(), icon: const Icon(Icons.sync)),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context),
        icon: const Icon(Icons.add),
        label: Text(t.add),
      ),
      body: Column(
        children: [
          // retrieval box
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.sm),
            child: TextField(
              controller: _q,
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: t.memorySearchHint,
                prefixIcon: const Icon(Icons.psychology_alt_outlined),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => setState(() {
                          _q.clear();
                          _query = '';
                        }),
                      ),
              ),
            ),
          ),
          if (categories.isNotEmpty)
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: Gap.sm),
                    child: ChoiceChip(
                      label: Text(t.all),
                      selected: _category == null,
                      onSelected: (_) => setState(() => _category = null),
                    ),
                  ),
                  for (final c in categories)
                    Padding(
                      padding: const EdgeInsets.only(right: Gap.sm),
                      child: ChoiceChip(
                        label: Text(c),
                        selected: _category == c,
                        onSelected: (_) => setState(
                            () => _category = _category == c ? null : c),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: all.isEmpty
                ? StateMessage(
                    icon: Icons.psychology_outlined,
                    title: t.memoryEmptyTitle,
                    message: t.memoryEmptyHint,
                  )
                : ranked.isEmpty
                    ? StateMessage(
                        icon: Icons.search_off,
                        title: t.memoryNoResultsTitle,
                        message: t.memoryNoResultsHint,
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(
                            Gap.md, Gap.sm, Gap.md, 96),
                        itemCount: ranked.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: Gap.sm),
                        itemBuilder: (_, i) =>
                            _MemoryCard(ranked: ranked[i], onEdit: _edit),
                      ),
          ),
        ],
      ),
    );
  }

  Future<void> _edit(BuildContext context, {MemoryItem? item}) async {
    final t = AppLocalizations.of(context);
    final title = TextEditingController(text: item?.title ?? '');
    final category = TextEditingController(text: item?.category ?? '');
    final detail = TextEditingController(text: item?.detail ?? '');
    final app = context.read<AppState>();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(item == null
            ? t.memoryNewItemTitle
            : t.memoryEditItemTitle),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: title,
                autofocus: item == null,
                decoration:
                    InputDecoration(labelText: t.memoryTitleLabel)),
            const SizedBox(height: Gap.md),
            TextField(
                controller: category,
                decoration:
                    InputDecoration(labelText: t.memoryCategoryLabel)),
            const SizedBox(height: Gap.md),
            TextField(
                controller: detail,
                maxLines: 3,
                decoration:
                    InputDecoration(labelText: t.memoryDetailLabel)),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.save)),
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
}

// ---------------------------------------------------------------- card
class _MemoryCard extends StatelessWidget {
  final _Ranked ranked;
  final Future<void> Function(BuildContext, {MemoryItem? item}) onEdit;
  const _MemoryCard({required this.ranked, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final m = ranked.item;
    return Card(
      child: ListTile(
        onTap: () => onEdit(context, item: m),
        title: Text(m.title),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (m.detail.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: Gap.xs),
                child: Text(m.detail),
              ),
            Wrap(spacing: Gap.sm, runSpacing: 4, children: [
              if (m.category.isNotEmpty) _tag(m.category, Colors.blueGrey),
              _tag(m.isAi ? t.memoryTagAi : t.memoryTagManual,
                  m.isAi ? Brand.cyan : Brand.blue),
              if (m.pendingOp != 'none')
                _tag(t.memoryTagSyncing, Brand.warning),
            ]),
          ],
        ),
        isThreeLine: m.detail.isNotEmpty,
        trailing: PopupMenuButton<String>(
          onSelected: (v) {
            if (v == 'edit') onEdit(context, item: m);
            if (v == 'del') {
              app.removeMemory(m);
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(t.commonDeleted),
                action: SnackBarAction(
                    label: t.undo, onPressed: () => app.undoLast()),
              ));
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(value: 'edit', child: Text(t.edit)),
            PopupMenuItem(value: 'del', child: Text(t.delete)),
          ],
        ),
      ),
    );
  }

  Widget _tag(String text, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 2),
        decoration: BoxDecoration(
            color: c.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(Radii.pill)),
        child: Text(text, style: TextStyle(fontSize: 11, color: c)),
      );
}

// ---------------------------------------------------------------- search
class _Ranked {
  final MemoryItem item;
  final double score;
  final List<String> matched;
  _Ranked(this.item, this.score, this.matched);
}

const _memoryStop = {
  'what', 'did', 'i', 'tell', 'you', 'about', 'me', 'my', 'the', 'a', 'an',
  'do', 'know', 'remember', 'said', 'was', 'is', 'of', 'for',
};

List<String> _tokens(String s) {
  const bn = '\u09e6\u09e7\u09e8\u09e9\u09ea\u09eb\u09ec\u09ed\u09ee\u09ef';
  final buf = StringBuffer();
  for (final ch in s.runes) {
    final i = bn.runes.toList().indexOf(ch);
    buf.writeCharCode(i >= 0 ? 0x30 + i : ch);
  }
  return buf
      .toString()
      .toLowerCase()
      .split(RegExp(r'''[\s,.!?;:\-/()"']+'''))
      .where((x) => x.isNotEmpty)
      .toList();
}

bool _fuzzy(String hay, String needle) {
  if (hay.contains(needle)) return true;
  if (needle.length >= 4 && (hay.startsWith(needle) || needle.startsWith(hay))) {
    return true;
  }
  return false;
}

/// Deterministic ranking mirror of backend reminders_engine.search_memory.
List<_Ranked> searchMemory(String query, List<MemoryItem> items) {
  final terms =
      _tokens(query).where((x) => !_memoryStop.contains(x) && x.length > 1).toList();
  final effective = terms.isEmpty ? _tokens(query) : terms;
  final scored = <_Ranked>[];
  for (final m in items) {
    final titleToks = _tokens(m.title);
    final detailToks = _tokens(m.detail);
    final catToks = _tokens(m.category);
    double score = 0;
    final matched = <String>[];
    for (final term in effective) {
      bool hit = false;
      if (titleToks.contains(term)) {
        score += 3;
        hit = true;
      } else if (titleToks.any((x) => _fuzzy(x, term))) {
        score += 2;
        hit = true;
      }
      if (catToks.contains(term)) {
        score += 2;
        hit = true;
      } else if (catToks.any((x) => _fuzzy(x, term))) {
        score += 1;
        hit = true;
      }
      if (detailToks.contains(term)) {
        score += 1;
        hit = true;
      } else if (detailToks.any((x) => _fuzzy(x, term))) {
        score += 0.5;
        hit = true;
      }
      if (hit) matched.add(term);
    }
    if (score > 0) scored.add(_Ranked(m, score, matched));
  }
  scored.sort((a, b) => b.score.compareTo(a.score));
  return scored;
}
