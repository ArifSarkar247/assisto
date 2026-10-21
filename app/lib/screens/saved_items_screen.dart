import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../widgets/saved_logic.dart';

/// SAVED / BOOKMARKS — ADVANCED (#18, §21).
///
/// A universal "save this" surface: bookmark any item — a note, a saved chat
/// answer, a document reference, or a link — with a title, an optional note, an
/// optional tag and a source kind. Browse, SEARCH (title+note+tag+ref), filter
/// by TAG or kind, and delete with confirm.
///
/// Honest states: welcome (first use, nothing saved) is DISTINCT from
/// search/filter no-results (you have items but the current query matched
/// none). ZERO Bangla literals — every string is an AppLocalizations getter.
///
/// The search / tag + kind filter / recent-sort / state logic mirrors
/// backend/core/logic/saved_items.py VERBATIM via widgets/saved_logic.dart.
///
/// CROSS-APP "SAVE THIS" SEAM: any screen can offer a Save action by building a
/// row with [SavedLogic.makeItem] and POSTing it to 'saved/items' through the
/// existing ApiClient.createItem — e.g. the chat screen saves an answer with
/// kind='answer' + the text as the note. There is no special endpoint; the same
/// generic per-user JSON collection backs every save. See the integration note.
///
/// Persistence (generic api helpers, no api.dart edit):
///   listItems('saved/items') → [{id, title, note, tag, kind, ref, created}]
///   create/update/deleteItem on the same path (PaCollectionItem precedent).
class SavedItemsScreen extends StatefulWidget {
  const SavedItemsScreen({super.key});
  @override
  State<SavedItemsScreen> createState() => _SavedItemsScreenState();
}

const String _savedPath = 'saved/items';

String _today() {
  final n = DateTime.now();
  return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
}

class _SavedItemsScreenState extends State<SavedItemsScreen> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true, _error = false;
  String _query = '';
  String _tag = ''; // '' == All
  final _searchCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    final api = context.read<AppState>().api;
    try {
      _items = await api.listItems(_savedPath);
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.savedTitle)),
        body: const SkeletonList(),
      );
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.savedTitle)),
        body: StateMessage(
          icon: Icons.cloud_off,
          tint: scheme.error,
          title: tr.loadFailed,
          message: tr.savedLoadError,
          action: FilledButton.tonalIcon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: Text(tr.retry)),
        ),
      );
    }

    final result = SavedLogic.apply(_items, query: _query, tag: _tag);
    final tagCounts = SavedLogic.tagCounts(_items);

    return Scaffold(
      appBar: AppBar(title: Text(tr.savedTitle)),
      // empty state has its own CTA: no duplicate FAB
      floatingActionButton: result.empty ? null : FloatingActionButton.extended(
        onPressed: _addItem,
        icon: const Icon(Icons.bookmark_add_outlined),
        label: Text(tr.savedAdd),
      ),
      body: result.empty
          ? _welcome(context)
          : Column(children: [
              _searchBar(context),
              if (tagCounts.isNotEmpty) _tagChips(context, tagCounts),
              Expanded(child: _list(context, result)),
            ]),
    );
  }

  Widget _welcome(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return StateMessage(
      icon: Icons.bookmarks_outlined,
      title: tr.savedWelcomeTitle,
      message: tr.savedWelcomeBody,
      action: FilledButton.icon(
        onPressed: _addItem,
        icon: const Icon(Icons.bookmark_add_outlined),
        label: Text(tr.savedAdd),
      ),
    );
  }

  Widget _searchBar(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.sm),
      child: TextField(
        controller: _searchCtl,
        onChanged: (v) => setState(() => _query = v),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: tr.savedSearchHint,
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear),
                  tooltip: tr.close,
                  onPressed: () {
                    _searchCtl.clear();
                    setState(() => _query = '');
                  },
                ),
          isDense: true,
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(Radii.md)),
        ),
      ),
    );
  }

  Widget _tagChips(BuildContext context, List<MapEntry<String, int>> counts) {
    final tr = AppLocalizations.of(context);
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: Gap.sm),
            child: ChoiceChip(
              label: Text(tr.savedAllTag(_items.length)),
              selected: _tag.isEmpty,
              onSelected: (_) => setState(() => _tag = ''),
            ),
          ),
          for (final e in counts)
            Padding(
              padding: const EdgeInsets.only(right: Gap.sm),
              child: ChoiceChip(
                label: Text('${e.key} (${e.value})'),
                selected: SavedLogic.normaliseTag(_tag) == e.key,
                onSelected: (_) => setState(() => _tag = e.key),
              ),
            ),
        ],
      ),
    );
  }

  Widget _list(BuildContext context, SavedResult result) {
    final tr = AppLocalizations.of(context);
    if (result.noResults) {
      return StateMessage(
        icon: Icons.search_off,
        title: tr.savedNoResultsTitle,
        message: tr.savedNoResultsBody,
        action: OutlinedButton.icon(
          onPressed: () {
            _searchCtl.clear();
            setState(() {
              _query = '';
              _tag = '';
            });
          },
          icon: const Icon(Icons.clear_all),
          label: Text(tr.savedClearFilters),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, 96),
        itemCount: result.items.length,
        itemBuilder: (_, i) => _SavedCard(
          item: result.items[i],
          onEdit: () => _editItem(result.items[i]),
          onDelete: () => _confirmDelete(result.items[i]),
        ),
      ),
    );
  }

  Future<void> _addItem() async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final row = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _SavedForm(),
    );
    if (row == null) return;
    row['created'] = _today();
    try {
      await api.createItem(_savedPath, row);
      await _load();
      if (mounted) _toast(tr.savedSaved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _editItem(Map<String, dynamic> item) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final row = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _SavedForm(existing: item),
    );
    if (row == null) return;
    final id = item['id'];
    if (id is! int) return;
    try {
      await api.updateItem(_savedPath, id, row);
      await _load();
      if (mounted) _toast(tr.savedSaved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _confirmDelete(Map<String, dynamic> item) async {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final api = context.read<AppState>().api;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.savedDeleteTitle),
        content: Text(tr.savedDeleteBody((item['title'] ?? '').toString())),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr.cancel)),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: scheme.error,
                foregroundColor: scheme.onError),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr.delete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final id = item['id'];
    if (id is! int) return;
    try {
      await api.deleteItem(_savedPath, id);
      await _load();
      if (mounted) _toast(tr.savedDeleted);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }
}

// ===================== saved card =====================
class _SavedCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  const _SavedCard(
      {required this.item, required this.onEdit, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final kind = SavedLogic.normaliseKind(item['kind']);
    final tag = SavedLogic.normaliseTag(item['tag']);
    final note = (item['note'] ?? '').toString();
    final ref = (item['ref'] ?? '').toString();
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(_kindIcon(kind), size: 18, color: scheme.primary),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text((item['title'] ?? '').toString(),
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                tooltip: tr.delete,
                onPressed: onDelete,
              ),
            ]),
            if (note.isNotEmpty) ...[
              const SizedBox(height: Gap.xs),
              Text(note,
                  style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis),
            ],
            if (ref.isNotEmpty) ...[
              const SizedBox(height: Gap.xs),
              Row(children: [
                Icon(kind == 'link' ? Icons.link : Icons.description_outlined,
                    size: 14, color: scheme.onSurfaceVariant),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(ref,
                      style: TextStyle(
                          fontSize: 12,
                          color: scheme.primary,
                          decoration: kind == 'link'
                              ? TextDecoration.underline
                              : null),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
              ]),
            ],
            const SizedBox(height: Gap.sm),
            Row(children: [
              _kindChip(context, kind),
              if (tag.isNotEmpty) ...[
                const SizedBox(width: Gap.xs),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 2),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(Radii.pill),
                  ),
                  child: Text('#$tag',
                      style: TextStyle(
                          fontSize: 11.5, color: scheme.onSurfaceVariant)),
                ),
              ],
              const Spacer(),
              if ((item['created'] ?? '').toString().isNotEmpty)
                Text((item['created']).toString(),
                    style: TextStyle(
                        fontSize: 11, color: scheme.onSurfaceVariant)),
            ]),
          ]),
        ),
      ),
    );
  }
}

IconData _kindIcon(String kind) {
  switch (kind) {
    case 'answer':
      return Icons.chat_bubble_outline;
    case 'doc':
      return Icons.description_outlined;
    case 'link':
      return Icons.link;
    default:
      return Icons.sticky_note_2_outlined;
  }
}

String _kindLabel(AppLocalizations tr, String kind) {
  switch (kind) {
    case 'answer':
      return tr.savedKindAnswer;
    case 'doc':
      return tr.savedKindDoc;
    case 'link':
      return tr.savedKindLink;
    default:
      return tr.savedKindNote;
  }
}

Widget _kindChip(BuildContext context, String kind) {
  final tr = AppLocalizations.of(context);
  final scheme = Theme.of(context).colorScheme;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 2),
    decoration: BoxDecoration(
      color: scheme.secondaryContainer.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(Radii.pill),
    ),
    child: Text(_kindLabel(tr, kind),
        style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: scheme.onSecondaryContainer)),
  );
}

// ===================== add / edit form =====================
class _SavedForm extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _SavedForm({this.existing});
  @override
  State<_SavedForm> createState() => _SavedFormState();
}

class _SavedFormState extends State<_SavedForm> {
  late final TextEditingController _title;
  late final TextEditingController _note;
  late final TextEditingController _tag;
  late final TextEditingController _ref;
  late String _kind;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _title = TextEditingController(text: (e?['title'] ?? '').toString());
    _note = TextEditingController(text: (e?['note'] ?? '').toString());
    _tag = TextEditingController(text: (e?['tag'] ?? '').toString());
    _ref = TextEditingController(text: (e?['ref'] ?? '').toString());
    _kind = SavedLogic.normaliseKind(e?['kind']);
  }

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    _tag.dispose();
    _ref.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final problems = SavedLogic.validate(_title.text, _kind, _ref.text);
    final ok = problems.isEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
      child: SingleChildScrollView(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.existing == null ? tr.savedAdd : tr.savedEdit,
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: Gap.lg),
              TextField(
                controller: _title,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                    labelText: tr.savedTitleLabel,
                    hintText: tr.savedTitleHint,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              DropdownButtonFormField<String>(
                initialValue: _kind,
                decoration: InputDecoration(
                    labelText: tr.savedKindLabel,
                    border: const OutlineInputBorder()),
                items: [
                  for (final k in SavedLogic.kinds)
                    DropdownMenuItem(value: k, child: Text(_kindLabel(tr, k))),
                ],
                onChanged: (v) =>
                    setState(() => _kind = v ?? SavedLogic.defaultKind),
              ),
              if (_kind == 'link' || _kind == 'doc') ...[
                const SizedBox(height: Gap.md),
                TextField(
                  controller: _ref,
                  onChanged: (_) => setState(() {}),
                  keyboardType: _kind == 'link'
                      ? TextInputType.url
                      : TextInputType.text,
                  decoration: InputDecoration(
                      labelText:
                          _kind == 'link' ? tr.savedLinkLabel : tr.savedDocLabel,
                      hintText: _kind == 'link'
                          ? tr.savedLinkHint
                          : tr.savedDocHint,
                      border: const OutlineInputBorder()),
                ),
              ],
              const SizedBox(height: Gap.md),
              TextField(
                controller: _note,
                minLines: 2,
                maxLines: 6,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                    labelText: tr.savedNoteLabel,
                    hintText: tr.savedNoteHint,
                    alignLabelWithHint: true,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _tag,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                    labelText: tr.savedTagLabel,
                    hintText: tr.savedTagHint,
                    prefixText: '# ',
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.lg),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(tr.cancel)),
                ),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: FilledButton(
                    onPressed: ok
                        ? () => Navigator.pop(context, <String, dynamic>{
                              'title': _title.text.trim(),
                              'note': _note.text.trim(),
                              'tag': SavedLogic.normaliseTag(_tag.text),
                              'kind': _kind,
                              'ref': _ref.text.trim(),
                            })
                        : null,
                    child: Text(tr.save),
                  ),
                ),
              ]),
            ]),
      ),
    );
  }
}
