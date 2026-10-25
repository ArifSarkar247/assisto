import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
import '../../services/error_kind.dart' show honestFailText; // qa2

/// PA SECRETARY MODE — RESEARCH & PRESENTATION organizer (#114, §14, ADVANCED).
///
/// The PA organises research for the boss entirely by hand, offline, with NO
/// key: a research TOPIC, NOTES and SOURCES (title + url/citation the PA typed),
/// a presentation OUTLINE (ordered SECTIONS each with bullet points), and a
/// deterministic plain-text OUTLINE EXPORT suitable for pasting into slides.
///
/// HONEST, KEY-GATED (NEVER FABRICATES):
///   * AI-assisted research / slide generation is a DOCUMENTED key-gated seam
///     shown as an honest "connect an AI key" card (_AiSeamCard). This screen
///     NEVER invents a fact, a citation or a source URL — the only text it emits
///     is a deterministic reshape of what the PA typed.
///
/// Export format mirrors backend/core/logic/pa_research.py outline_export so the
/// pasteable text is identical offline.
///
/// Honest states: welcome (no topics) · loading · error. ZERO Bangla literals —
/// every string is an AppLocalizations getter.
///
/// Persistence (generic api helpers, no api.dart edit):
///   listItems('pa/research')  → mixed rows tagged by {kind}:
///     {id, kind:'topic',   title, goal}
///     {id, kind:'item',    topic_id, kind2:'note'|'source', text, ref}
///     {id, kind:'section', topic_id, heading, order, bullets}
///   create/update/delete on 'pa/research'; rows round-trip as {id, ...data}
///   through one flexible per-user JSON collection (PaCollectionItem precedent).
///   (Note: the note/source discriminator is stored as `kind2` because the row's
///   own `kind` field already tags topic/item/section for this collection.)
class ResearchPrepScreen extends StatefulWidget {
  const ResearchPrepScreen({super.key});
  @override
  State<ResearchPrepScreen> createState() => _ResearchPrepScreenState();
}

const String _path = 'pa/research';

class _ResearchPrepScreenState extends State<ResearchPrepScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  bool _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      _rows = await context.read<AppState>().api.listItems(_path);
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  List<Map<String, dynamic>> get _topics =>
      _rows.where((r) => '${r['kind']}' == 'topic').toList();

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _openTopicEditor([Map<String, dynamic>? existing]) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _TopicEditor(existing: existing),
    );
    if (result == null) return;
    final api = context.read<AppState>().api;
    try {
      if (existing != null && existing['id'] is int) {
        await api.updateItem(_path, existing['id'] as int, result);
      } else {
        await api.createItem(_path, {...result, 'kind': 'topic'});
      }
      await _load();
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
          appBar: AppBar(title: Text(t.paResearchTitle)),
          body: const SkeletonList());
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text(t.paResearchTitle)),
        body: StateMessage(
          icon: Icons.cloud_off_rounded,
          tint: scheme.error,
          title: t.loadFailed,
          message: honestFailText(t, _failCause, otherwise: t.paResearchLoadError),
          action: FilledButton.tonalIcon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(t.retry)),
        ),
      );
    }
    final topics = _topics;
    return Scaffold(
      appBar: AppBar(title: Text(t.paResearchTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openTopicEditor(),
        icon: const Icon(Icons.add_rounded),
        label: Text(t.paResearchNewTopic),
      ),
      body: topics.isEmpty
          ? StateMessage(
              icon: Icons.menu_book_rounded,
              tint: Brand.blue,
              title: t.paResearchWelcomeTitle,
              message: t.paResearchWelcomeBody,
              action: FilledButton.icon(
                onPressed: () => _openTopicEditor(),
                icon: const Icon(Icons.add_rounded),
                label: Text(t.paResearchNewTopic),
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
                children: [
                  const _AiSeamCard(),
                  const SizedBox(height: Gap.sm),
                  for (final tp in topics)
                    Card(
                      margin: const EdgeInsets.only(bottom: Gap.sm),
                      child: ListTile(
                        onTap: () async {
                          await Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => _TopicDetailScreen(topic: tp),
                          ));
                          await _load();
                        },
                        leading: CircleAvatar(
                          backgroundColor: scheme.primaryContainer,
                          child: Icon(Icons.topic_rounded,
                              color: scheme.onPrimaryContainer),
                        ),
                        title: Text('${tp['title'] ?? ''}',
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: '${tp['goal'] ?? ''}'.trim().isEmpty
                            ? null
                            : Text('${tp['goal']}',
                                maxLines: 2, overflow: TextOverflow.ellipsis),
                        trailing: IconButton(
                            icon: const Icon(Icons.edit_rounded),
                            tooltip: t.edit,
                            onPressed: () => _openTopicEditor(tp)),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

// ======================= AI seam (key-gated) =======================
class _AiSeamCard extends StatelessWidget {
  const _AiSeamCard();
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.secondaryContainer.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.auto_awesome_rounded, size: 20, color: scheme.secondary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.paResearchAiSeamTitle,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.xxs),
              Text(t.paResearchAiSeamBody,
                  style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.35)),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ======================= topic detail =======================
class _TopicDetailScreen extends StatefulWidget {
  final Map<String, dynamic> topic;
  const _TopicDetailScreen({required this.topic});
  @override
  State<_TopicDetailScreen> createState() => _TopicDetailScreenState();
}

class _TopicDetailScreenState extends State<_TopicDetailScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;

  AppLocalizations get t => AppLocalizations.of(context);
  int get _topicId => widget.topic['id'] as int;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final all = await context.read<AppState>().api.listItems(_path);
      _rows = all.where((r) => r['topic_id'] == _topicId).toList();
    } catch (_) {
      _rows = [];
    }
    if (mounted) setState(() => _loading = false);
  }

  List<Map<String, dynamic>> get _notes => _rows
      .where((r) => '${r['kind']}' == 'item' && '${r['kind2']}' == 'note')
      .toList();
  List<Map<String, dynamic>> get _sources => _rows
      .where((r) => '${r['kind']}' == 'item' && '${r['kind2']}' == 'source')
      .toList();

  List<Map<String, dynamic>> get _sections {
    final s = _rows.where((r) => '${r['kind']}' == 'section').toList();
    s.sort((a, b) {
      final oa = int.tryParse('${a['order'] ?? 0}') ?? 0;
      final ob = int.tryParse('${b['order'] ?? 0}') ?? 0;
      if (oa != ob) return oa.compareTo(ob);
      return '${a['heading'] ?? ''}'
          .toLowerCase()
          .compareTo('${b['heading'] ?? ''}'.toLowerCase());
    });
    return s;
  }

  List<String> _bullets(Map<String, dynamic> section) => '${section['bullets'] ?? ''}'
      .replaceAll('\r', '')
      .split('\n')
      .map((l) => l.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' '))
      .where((l) => l.isNotEmpty)
      .toList();

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _create(Map<String, dynamic> body) async {
    try {
      await context
          .read<AppState>()
          .api
          .createItem(_path, {...body, 'topic_id': _topicId});
      await _load();
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
    }
  }

  Future<void> _update(int id, Map<String, dynamic> body) async {
    try {
      await context
          .read<AppState>()
          .api
          .updateItem(_path, id, {...body, 'topic_id': _topicId});
      await _load();
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
    }
  }

  Future<void> _delete(int id) async {
    try {
      await context.read<AppState>().api.deleteItem(_path, id);
      await _load();
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
    }
  }

  // ---- deterministic outline export (mirror of outline_export) ----
  String _buildExport({bool includeSources = false}) {
    final lines = <String>[];
    final title = '${widget.topic['title'] ?? ''}'.trim();
    if (title.isNotEmpty) {
      lines.add(title);
      lines.add('');
    }
    var i = 1;
    for (final s in _sections) {
      lines.add('$i. ${s['heading'] ?? ''}');
      for (final b in _bullets(s)) {
        lines.add('   - $b');
      }
      i++;
    }
    if (includeSources && _sources.isNotEmpty) {
      lines.add('');
      lines.add('Sources:');
      for (final s in _sources) {
        final text = '${s['text'] ?? ''}'.trim();
        final ref = '${s['ref'] ?? ''}'.trim();
        if (text.isNotEmpty && ref.isNotEmpty) {
          lines.add('- $text ($ref)');
        } else {
          lines.add('- ${text.isNotEmpty ? text : ref}');
        }
      }
    }
    while (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    return lines.join('\n');
  }

  Future<void> _addItem(String kind2) async {
    final r = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ItemEditor(kind2: kind2),
    );
    if (r == null) return;
    await _create(r);
  }

  Future<void> _addOrEditSection([Map<String, dynamic>? e]) async {
    final r = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _SectionEditor(
          existing: e, nextOrder: _sections.length + 1),
    );
    if (r == null) return;
    if (e != null && e['id'] is int) {
      await _update(e['id'] as int, r);
    } else {
      await _create(r);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.topic['title'] ?? ''}',
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: _loading
          ? const SkeletonList()
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 40),
                children: [
                  const _AiSeamCard(),
                  const SizedBox(height: Gap.lg),

                  // ---- notes ----
                  _SectionHeader(
                      icon: Icons.sticky_note_2_rounded,
                      label: t.paResearchNotesHeader,
                      onAdd: () => _addItem('note')),
                  if (_notes.isEmpty)
                    _EmptyLine(t.paResearchNoNotes)
                  else
                    for (final n in _notes)
                      _ItemTile(
                        icon: Icons.notes_rounded,
                        title: '${n['text'] ?? ''}',
                        subtitle: '',
                        onDelete: () => _delete(n['id'] as int),
                      ),
                  const SizedBox(height: Gap.lg),

                  // ---- sources ----
                  _SectionHeader(
                      icon: Icons.link_rounded,
                      label: t.paResearchSourcesHeader,
                      onAdd: () => _addItem('source')),
                  if (_sources.isEmpty)
                    _EmptyLine(t.paResearchNoSources)
                  else
                    for (final s in _sources)
                      _ItemTile(
                        icon: Icons.link_rounded,
                        title: '${s['text'] ?? ''}'.trim().isEmpty
                            ? '${s['ref'] ?? ''}'
                            : '${s['text']}',
                        subtitle: '${s['ref'] ?? ''}',
                        onDelete: () => _delete(s['id'] as int),
                      ),
                  const SizedBox(height: Gap.lg),

                  // ---- outline sections ----
                  _SectionHeader(
                      icon: Icons.format_list_numbered_rounded,
                      label: t.paResearchOutlineHeader,
                      onAdd: () => _addOrEditSection()),
                  if (_sections.isEmpty)
                    _EmptyLine(t.paResearchNoSections)
                  else
                    for (final s in _sections)
                      Card(
                        margin: const EdgeInsets.only(bottom: Gap.sm),
                        child: Padding(
                          padding: const EdgeInsets.all(Gap.md),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  Expanded(
                                    child: Text('${s['heading'] ?? ''}',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w800)),
                                  ),
                                  PopupMenuButton<String>(
                                    onSelected: (v) => v == 'edit'
                                        ? _addOrEditSection(s)
                                        : _delete(s['id'] as int),
                                    itemBuilder: (_) => [
                                      PopupMenuItem(
                                          value: 'edit', child: Text(t.edit)),
                                      PopupMenuItem(
                                          value: 'delete',
                                          child: Text(t.delete)),
                                    ],
                                  ),
                                ]),
                                for (final b in _bullets(s))
                                  Padding(
                                    padding:
                                        const EdgeInsets.only(left: Gap.sm),
                                    child: Text('• $b',
                                        style: TextStyle(
                                            color: scheme.onSurfaceVariant)),
                                  ),
                              ]),
                        ),
                      ),
                  const SizedBox(height: Gap.xl),

                  // ---- export ----
                  OutlinedButton.icon(
                    icon: const Icon(Icons.file_download_rounded),
                    label: Text(t.paResearchExportButton),
                    onPressed: () => showModalBottomSheet(
                      context: context,
                      isScrollControlled: true,
                      showDragHandle: true,
                      builder: (_) => _ExportSheet(
                        buildText: _buildExport,
                        hasSources: _sources.isNotEmpty,
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

// ======================= export sheet =======================
class _ExportSheet extends StatefulWidget {
  final String Function({bool includeSources}) buildText;
  final bool hasSources;
  const _ExportSheet({required this.buildText, required this.hasSources});
  @override
  State<_ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<_ExportSheet> {
  bool _withSources = false;
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final text = widget.buildText(includeSources: _withSources);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (_, controller) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, 0),
            child: Row(children: [
              Expanded(
                child: Text(t.paResearchExportTitle,
                    style: AType.titleLarge.copyWith(fontWeight: FontWeight.w800)),
              ),
              if (widget.hasSources)
                Row(children: [
                  Text(t.paResearchIncludeSources,
                      style: AType.bodySmall),
                  Switch(
                      value: _withSources,
                      onChanged: (v) => setState(() => _withSources = v)),
                ]),
            ]),
          ),
          Expanded(
            child: SingleChildScrollView(
              controller: controller,
              padding: const EdgeInsets.all(Gap.lg),
              child: SelectableText(
                text.isEmpty ? t.paResearchExportEmpty : text,
                style: const TextStyle(fontFamily: 'monospace', height: 1.4),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.copy_rounded),
                label: Text(t.paResearchCopy),
                onPressed: text.isEmpty
                    ? null
                    : () async {
                        await Clipboard.setData(ClipboardData(text: text));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(t.paResearchCopied)));
                        }
                      },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ======================= small shared widgets =======================
class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onAdd;
  const _SectionHeader(
      {required this.icon, required this.label, required this.onAdd});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(children: [
      Icon(icon, size: 18, color: scheme.primary),
      const SizedBox(width: Gap.sm),
      Expanded(
          child: Text(label,
              style:
                  AType.titleMedium.copyWith(fontWeight: FontWeight.w800))),
      IconButton(
          icon: const Icon(Icons.add_circle_outline_rounded),
          tooltip: AppLocalizations.of(context).add,
          onPressed: onAdd),
    ]);
  }
}

class _EmptyLine extends StatelessWidget {
  final String text;
  const _EmptyLine(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.sm),
        child: Text(text,
            style: AType.bodyMedium.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
}

class _ItemTile extends StatelessWidget {
  final IconData icon;
  final String title, subtitle;
  final VoidCallback onDelete;
  const _ItemTile(
      {required this.icon,
      required this.title,
      required this.subtitle,
      required this.onDelete});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(icon),
      title: Text(title, maxLines: 3, overflow: TextOverflow.ellipsis),
      subtitle: subtitle.trim().isEmpty
          ? null
          : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: IconButton(
          icon: const Icon(Icons.close_rounded, size: 18),
          tooltip: t.delete,
          onPressed: onDelete),
    );
  }
}

// ======================= editors =======================
class _TopicEditor extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _TopicEditor({this.existing});
  @override
  State<_TopicEditor> createState() => _TopicEditorState();
}

class _TopicEditorState extends State<_TopicEditor> {
  late final TextEditingController _title =
      TextEditingController(text: '${widget.existing?['title'] ?? ''}');
  late final TextEditingController _goal =
      TextEditingController(text: '${widget.existing?['goal'] ?? ''}');

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void dispose() {
    _title.dispose();
    _goal.dispose();
    super.dispose();
  }

  void _save() {
    if (_title.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.paResearchTitleRequired)));
      return;
    }
    Navigator.pop(context, {
      'kind': 'topic',
      'title': _title.text.trim(),
      'goal': _goal.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(widget.existing == null ? t.paResearchNewTopic : t.edit,
              style:
                  AType.titleLarge.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: Gap.lg),
          TextField(
              controller: _title,
              autofocus: true,
              decoration: InputDecoration(
                  labelText: t.paResearchTopicTitleLabel,
                  border: const OutlineInputBorder())),
          const SizedBox(height: Gap.md),
          TextField(
              controller: _goal,
              maxLines: 2,
              decoration: InputDecoration(
                  labelText: t.paResearchGoalLabel,
                  border: const OutlineInputBorder())),
          const SizedBox(height: Gap.lg),
          SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: _save, child: Text(t.save))),
        ]),
      ),
    );
  }
}

class _ItemEditor extends StatefulWidget {
  final String kind2; // 'note' | 'source'
  const _ItemEditor({required this.kind2});
  @override
  State<_ItemEditor> createState() => _ItemEditorState();
}

class _ItemEditorState extends State<_ItemEditor> {
  final TextEditingController _text = TextEditingController();
  final TextEditingController _ref = TextEditingController();

  AppLocalizations get t => AppLocalizations.of(context);
  bool get _isSource => widget.kind2 == 'source';

  @override
  void dispose() {
    _text.dispose();
    _ref.dispose();
    super.dispose();
  }

  void _save() {
    final text = _text.text.trim();
    final ref = _ref.text.trim();
    if (_isSource) {
      if (text.isEmpty && ref.isEmpty) {
        Navigator.pop(context);
        return;
      }
    } else if (text.isEmpty) {
      Navigator.pop(context);
      return;
    }
    Navigator.pop(context, {
      'kind': 'item',
      'kind2': widget.kind2,
      'text': text,
      'ref': ref,
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
              _isSource
                  ? t.paResearchSourcesHeader
                  : t.paResearchNotesHeader,
              style:
                  AType.titleLarge.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: Gap.lg),
          TextField(
              controller: _text,
              autofocus: true,
              maxLines: _isSource ? 1 : 4,
              decoration: InputDecoration(
                  labelText: _isSource
                      ? t.paResearchSourceTitleLabel
                      : t.paResearchNoteTextLabel,
                  border: const OutlineInputBorder())),
          if (_isSource) ...[
            const SizedBox(height: Gap.md),
            TextField(
                controller: _ref,
                decoration: InputDecoration(
                    labelText: t.paResearchSourceRefLabel,
                    helperText: t.paResearchSourceRefHelper,
                    border: const OutlineInputBorder())),
          ],
          const SizedBox(height: Gap.lg),
          SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: _save, child: Text(t.save))),
        ]),
      ),
    );
  }
}

class _SectionEditor extends StatefulWidget {
  final Map<String, dynamic>? existing;
  final int nextOrder;
  const _SectionEditor({this.existing, required this.nextOrder});
  @override
  State<_SectionEditor> createState() => _SectionEditorState();
}

class _SectionEditorState extends State<_SectionEditor> {
  late final TextEditingController _heading =
      TextEditingController(text: '${widget.existing?['heading'] ?? ''}');
  late final TextEditingController _bullets =
      TextEditingController(text: '${widget.existing?['bullets'] ?? ''}');
  late final TextEditingController _order = TextEditingController(
      text: '${widget.existing?['order'] ?? widget.nextOrder}');

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void dispose() {
    _heading.dispose();
    _bullets.dispose();
    _order.dispose();
    super.dispose();
  }

  void _save() {
    if (_heading.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.paResearchHeadingRequired)));
      return;
    }
    Navigator.pop(context, {
      'kind': 'section',
      'heading': _heading.text.trim(),
      'order': int.tryParse(_order.text.trim()) ?? widget.nextOrder,
      'bullets': _bullets.text,
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(t.paResearchOutlineHeader,
              style:
                  AType.titleLarge.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: Gap.lg),
          TextField(
              controller: _heading,
              autofocus: true,
              decoration: InputDecoration(
                  labelText: t.paResearchSectionHeadingLabel,
                  border: const OutlineInputBorder())),
          const SizedBox(height: Gap.md),
          TextField(
              controller: _order,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                  labelText: t.paResearchSectionOrderLabel,
                  border: const OutlineInputBorder())),
          const SizedBox(height: Gap.md),
          TextField(
              controller: _bullets,
              maxLines: 5,
              decoration: InputDecoration(
                  labelText: t.paResearchSectionBulletsLabel,
                  helperText: t.paResearchSectionBulletsHelper,
                  border: const OutlineInputBorder())),
          const SizedBox(height: Gap.lg),
          SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: _save, child: Text(t.save))),
        ]),
      ),
    );
  }
}
