import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../services/error_kind.dart' show honestFailText; // qa2

/// BLOG & SCRIPT WRITING — ADVANCED, KEY-GATED (#130, SPEC v2.1 §21).
///
/// The user picks a FORMAT (blog post / video script / caption / outline), a
/// TOPIC, a TONE, a LENGTH and a language (bn / Banglish / en); we ASSEMBLE a
/// structured draft from a deterministic template: an intro/hook, a body
/// scaffold of sections (headings filled from the topic), and a CTA — every
/// section seeded with a bracketed PLACEHOLDER PROMPT the user completes in
/// their own words. The user edits the draft, copies or shares it, and saves it
/// to a per-user draft list. Assisto NEVER auto-posts and never publishes.
///
/// HONEST: the draft is a DETERMINISTIC TEMPLATE SCAFFOLD, clearly labelled
/// "AI-generated — review". A FULL AI draft (fleshed-out prose in the chosen
/// language) is a DOCUMENTED key-gated seam shown as an honest "connect an AI
/// key" state (Integrations → anthropic); it is NOT built here and the whole
/// tool works with no key.
///
/// The on-screen logic mirrors backend/core/logic/blog_writer.py VERBATIM
/// (format scaffolds, tone hooks/CTAs, section seeds, length→section count) so
/// the live preview is deterministic and identical offline. ZERO Bangla
/// literals — every string is an AppLocalizations getter.
///
/// Persistence (generic api helpers, no api.dart edit):
///   listItems('blog/drafts') → [{id, format, topic, tone, length, lang,
///                                title, body, saved_at}]
/// create/delete on the same path. Each row round-trips as {id, ...data}
/// through one flexible per-user JSON collection (PaCollectionItem precedent).
class BlogWriterScreen extends StatefulWidget {
  const BlogWriterScreen({super.key});
  @override
  State<BlogWriterScreen> createState() => _BlogWriterScreenState();
}

const String _draftsPath = 'blog/drafts';

// Kept in lockstep with blog_writer.py vocabulary.
const List<String> _formats = ['blog', 'script', 'caption', 'outline'];
const List<String> _tones = [
  'informative',
  'casual',
  'persuasive',
  'storytelling',
  'professional'
];
const List<String> _lengths = ['short', 'medium', 'long'];
const List<String> _langs = ['bn', 'banglish', 'en'];

String _today() {
  final n = DateTime.now();
  return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
}

class _BlogWriterScreenState extends State<BlogWriterScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  // compose inputs
  String _format = 'blog';
  String _tone = 'informative';
  String _length = 'medium';
  String _lang = 'en';
  final TextEditingController _topic = TextEditingController();
  final TextEditingController _body = TextEditingController();
  bool _hasDraft = false;
  int? _editingId; // non-null when re-saving an opened draft

  // saved drafts
  List<Map<String, dynamic>> _saved = [];
  bool _loading = true, _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _topic.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      _saved = await context.read<AppState>().api.listItems(_draftsPath);
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(msg)));

  void _generate() {
    FocusScope.of(context).unfocus();
    final problems = validateBlog(_format, _topic.text,
        tone: _tone, length: _length, lang: _lang);
    if (problems.isNotEmpty) {
      _toast(_problemLabel(t, problems.first));
      return;
    }
    final d = assembleBlog(_format, _topic.text,
        tone: _tone, length: _length, lang: _lang);
    setState(() {
      _body.text = d.text;
      _hasDraft = true;
      _editingId = null; // a fresh generation is a new draft
    });
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _body.text));
    if (!mounted) return;
    _toast(t.copied);
  }

  Future<void> _share() async {
    await Clipboard.setData(ClipboardData(text: _body.text));
    await Share.share(_body.text,
        subject: _topic.text.trim().isEmpty ? t.bwTitle : _topic.text.trim());
  }

  Future<void> _saveDraft() async {
    final body = {
      'format': _format,
      'topic': _topic.text.trim(),
      'tone': _tone,
      'length': _length,
      'lang': _lang,
      'title': titleForBlog(_format, _topic.text, t),
      'body': _body.text,
      'saved_at': _today(),
    };
    try {
      if (_editingId != null) {
        await context.read<AppState>().api.updateItem(_draftsPath, _editingId!, body);
      } else {
        final row =
            await context.read<AppState>().api.createItem(_draftsPath, body);
        _editingId = (row['id'] as num?)?.toInt();
      }
      await _load();
      if (mounted) _toast(t.bwSaved);
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
    }
  }

  void _openSaved(Map<String, dynamic> d) {
    setState(() {
      _format = (d['format'] ?? 'blog').toString();
      _tone = (d['tone'] ?? 'informative').toString();
      _length = (d['length'] ?? 'medium').toString();
      _lang = (d['lang'] ?? 'en').toString();
      _topic.text = (d['topic'] ?? '').toString();
      _body.text = (d['body'] ?? '').toString();
      _hasDraft = _body.text.isNotEmpty;
      _editingId = (d['id'] as num?)?.toInt();
    });
    _tabs.animateTo(0);
  }

  Future<void> _deleteSaved(Map<String, dynamic> d) async {
    final id = (d['id'] as num?)?.toInt();
    if (id == null) return;
    try {
      await context.read<AppState>().api.deleteItem(_draftsPath, id);
      if (_editingId == id) _editingId = null;
      await _load();
      if (mounted) _toast(t.commonDeleted);
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t.bwTitle),
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            Tab(
                child: Text(t.bwTabCompose,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis)),
            Tab(
                child: Text(t.bwTabSaved,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [_composeTab(), _savedTab()],
      ),
    );
  }

  // --------------------------------------------------------------- compose tab

  Widget _composeTab() {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xxl),
      children: [
        _AiMarkerCard(),
        const SizedBox(height: Gap.lg),
        _ChipsRow(
          label: t.bwFormat,
          values: _formats,
          selected: _format,
          display: (v) => _formatLabel(t, v),
          onSelect: (v) => setState(() => _format = v),
        ),
        const SizedBox(height: Gap.lg),
        TextField(
          controller: _topic,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: t.bwTopic,
            hintText: t.bwTopicHint,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: Gap.lg),
        _ChipsRow(
          label: t.bwTone,
          values: _tones,
          selected: _tone,
          display: (v) => _toneLabel(t, v),
          onSelect: (v) => setState(() => _tone = v),
        ),
        const SizedBox(height: Gap.lg),
        _ChipsRow(
          label: t.bwLength,
          values: _lengths,
          selected: _length,
          display: (v) => _lengthLabel(t, v),
          onSelect: (v) => setState(() => _length = v),
        ),
        const SizedBox(height: Gap.lg),
        _ChipsRow(
          label: t.bwLanguage,
          values: _langs,
          selected: _lang,
          display: (v) => _langLabel(t, v),
          onSelect: (v) => setState(() => _lang = v),
        ),
        const SizedBox(height: Gap.lg),
        FilledButton.icon(
          onPressed: _generate,
          icon: const Icon(Icons.auto_awesome, size: 18),
          label: Text(_hasDraft ? t.bwRegenerate : t.bwGenerate),
        ),
        if (_hasDraft) ...[
          const SizedBox(height: Gap.xl),
          Row(children: [
            Expanded(
              child: Text(t.bwDraft,
                  style: const TextStyle(fontWeight: FontWeight.w800)),
            ),
          ]),
          const SizedBox(height: Gap.xs),
          Text(t.bwPlaceholderHint,
              style: TextStyle(
                  color: scheme.onSurfaceVariant, fontSize: 12.5, height: 1.4)),
          const SizedBox(height: Gap.sm),
          TextField(
            controller: _body,
            maxLines: null,
            minLines: 10,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.lg),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _share,
                icon: const Icon(Icons.ios_share, size: 18),
                label: Text(t.bwShare),
              ),
            ),
            const SizedBox(width: Gap.sm),
            OutlinedButton.icon(
              onPressed: _copy,
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: Text(t.copy),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          OutlinedButton.icon(
            onPressed: _saveDraft,
            icon: const Icon(Icons.bookmark_outline, size: 18),
            label: Text(t.save),
          ),
          const SizedBox(height: Gap.xl),
          _FullAiCard(),
        ],
      ],
    );
  }

  // ----------------------------------------------------------------- saved tab

  Widget _savedTab() {
    final scheme = Theme.of(context).colorScheme;
    if (_loading) return const SkeletonList(count: 4);
    if (_error) {
      return StateMessage(
        icon: Icons.cloud_off,
        tint: scheme.error,
        title: t.loadFailed,
        message: honestFailText(t, _failCause, otherwise: t.bwLoadError),
        action: FilledButton.tonalIcon(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            label: Text(t.retry)),
      );
    }
    if (_saved.isEmpty) {
      return StateMessage(
        icon: Icons.bookmark_border,
        title: t.bwSavedEmptyTitle,
        message: t.bwSavedEmptyBody,
        action: FilledButton.tonalIcon(
          onPressed: () => _tabs.animateTo(0),
          icon: const Icon(Icons.edit_outlined, size: 18),
          label: Text(t.bwTabCompose),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(Gap.lg),
        itemCount: _saved.length,
        separatorBuilder: (_, __) => const SizedBox(height: Gap.md),
        itemBuilder: (_, i) {
          final d = _saved[i];
          final topic = (d['topic'] ?? '').toString();
          final title = topic.isEmpty
              ? (d['title'] ?? _formatLabel(t, (d['format'] ?? 'blog').toString()))
                  .toString()
              : topic;
          final body = (d['body'] ?? '').toString().replaceAll('\n', ' ').trim();
          return Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              onTap: () => _openSaved(d),
              leading: CircleAvatar(
                backgroundColor: scheme.secondaryContainer,
                child: Icon(_formatIcon((d['format'] ?? 'blog').toString()),
                    size: 20, color: scheme.onSecondaryContainer),
              ),
              title: Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(
                body,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: t.delete,
                onPressed: () => _deleteSaved(d),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ======================================================================
// On-device Dart mirror of backend/core/logic/blog_writer.py.
// DETERMINISTIC TEMPLATE ASSEMBLER — identical inputs always give an identical
// scaffold, so the offline preview matches the Python source of truth. PURE:
// no network, no AI, no key. The honest "AI drafts it" promise is served by
// this mock ("AI-generated — review"); a full AI draft is key-gated server-side
// via Integrations `anthropic` (out of scope here). Nothing here posts anything.
// ======================================================================

const Map<String, int> _lengthSections = {'short': 2, 'medium': 3, 'long': 5};

const Map<String, String> _toneHook = {
  'informative': 'In this piece we look at {topic} and what it means for you.',
  'casual': "So, let's talk about {topic} — here's the quick version.",
  'persuasive': 'Here is why {topic} deserves your attention today.',
  'storytelling': 'It started with a simple question about {topic}.',
  'professional': 'An overview of {topic}: context, detail and next steps.',
};
const Map<String, String> _toneCta = {
  'informative':
      '[Wrap up with the single most useful takeaway about {topic}.]',
  'casual': '[End with a friendly nudge — ask readers what they think.]',
  'persuasive':
      '[Close with a clear call to action you want the reader to take.]',
  'storytelling': '[Land the story on the lesson you drew from {topic}.]',
  'professional': '[State the recommended next step and how to reach you.]',
};

const List<List<String>> _sectionSeeds = [
  ['Background', '[Set the scene: what is {topic} and why now?]'],
  ['Key points', '[List the 2-3 points a reader must understand about {topic}.]'],
  ['How it works', '[Explain the mechanics / steps in plain language.]'],
  ['Example', '[Give one concrete, local example readers will recognise.]'],
  ['Common mistakes', '[Note a pitfall to avoid and how to avoid it.]'],
  ['What to do next', '[Give one small action the reader can take today.]'],
];

const List<List<String>> _scriptBeats = [
  ['HOOK (0-5s)', '[Open with a question or bold line about {topic}.]'],
  ['SETUP', "[In one line, tell viewers what they'll get.]"],
  ['POINT 1', '[First key point — keep it to one idea.]'],
  ['POINT 2', '[Second key point with a quick example.]'],
  ['POINT 3', '[Third key point or a surprising detail.]'],
  ['CALL TO ACTION',
    '[Tell viewers the one thing to do next (like/follow/visit).]'],
];

String _cleanTopic(String topic) {
  final t = topic.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');
  return t.isEmpty ? 'this topic' : t;
}

String _fill(String seed, String topic) => seed.replaceAll('{topic}', topic);

/// Problem keys (empty ⇒ valid). The UI localises these.
List<String> validateBlog(String format, String topic,
    {String tone = 'informative',
    String length = 'medium',
    String lang = 'en'}) {
  final out = <String>[];
  if (!_formats.contains(format)) out.add('bad_format');
  if (topic.trim().isEmpty) out.add('topic_required');
  if (!_tones.contains(tone)) out.add('bad_tone');
  if (!_lengths.contains(length)) out.add('bad_length');
  if (!_langs.contains(lang)) out.add('bad_lang');
  return out;
}

int sectionCount(String length) => _lengthSections[length] ?? 3;

List<List<String>> _bodySections(String format, String topic, String length) {
  final n = _lengthSections[length] ?? 3;
  if (format == 'script') {
    final middle = n < 1 ? 1 : n;
    final chosen = <List<String>>[
      _scriptBeats[0],
      _scriptBeats[1],
      ..._scriptBeats.sublist(2, (2 + middle).clamp(2, _scriptBeats.length - 1)),
      _scriptBeats.last,
    ];
    return [
      for (final b in chosen) [b[0], _fill(b[1], topic)]
    ];
  }
  if (format == 'caption') {
    return [
      ['Caption', _fill('[Write 1-2 punchy lines about {topic}.]', topic)],
      ['Hashtags',
        '[Add 3-5 relevant hashtags — no spaces inside a tag.]'],
    ];
  }
  final seeds = _sectionSeeds.sublist(0, n.clamp(1, _sectionSeeds.length));
  return [
    for (final s in seeds) [s[0], _fill(s[1], topic)]
  ];
}

String _titleLead(String format) {
  switch (format) {
    case 'script':
      return 'Script:';
    case 'caption':
      return 'Caption:';
    case 'outline':
      return 'Outline:';
    default:
      return 'Blog:';
  }
}

/// A localised working title used only for the saved-draft list label.
String titleForBlog(String format, String topic, AppLocalizations t) {
  final tp = _cleanTopic(topic);
  return '${_formatLabel(t, format)}: $tp';
}

/// The deterministic MOCK draft scaffold. Mirrors `blog_writer.py::assemble`.
class BlogDraft {
  final String format;
  final String tone;
  final String length;
  final String lang;
  final String hook;
  final List<List<String>> sections; // [heading, prompt]
  final String cta;
  final String text; // the whole scaffold joined into editable markdown
  const BlogDraft({
    required this.format,
    required this.tone,
    required this.length,
    required this.lang,
    required this.hook,
    required this.sections,
    required this.cta,
    required this.text,
  });

  /// Honest flags — this scaffold is always a mock, never a real-AI result.
  bool get aiRequired => false;
  bool get mock => true;
  String get aiFullRequires => 'anthropic';
}

BlogDraft assembleBlog(String format, String topic,
    {String tone = 'informative',
    String length = 'medium',
    String lang = 'en'}) {
  final tp = _cleanTopic(topic);
  final hook = _fill(_toneHook[tone] ?? _toneHook['informative']!, tp);
  final cta = _fill(_toneCta[tone] ?? _toneCta['informative']!, tp);
  final sections = _bodySections(format, tp, length);
  final titleLead = _titleLead(format);

  final lines = <String>['# $titleLead $tp', '', hook, ''];
  for (final s in sections) {
    lines.add('## ${s[0]}');
    lines.add(s[1]);
    lines.add('');
  }
  lines.add(cta);
  final text = lines.join('\n').trim();

  return BlogDraft(
    format: format,
    tone: tone,
    length: length,
    lang: lang,
    hook: hook,
    sections: sections,
    cta: cta,
    text: text,
  );
}

// ------------------------------------------------------------ label helpers

String _formatLabel(AppLocalizations t, String v) {
  switch (v) {
    case 'script':
      return t.bwFmtScript;
    case 'caption':
      return t.bwFmtCaption;
    case 'outline':
      return t.bwFmtOutline;
    default:
      return t.bwFmtBlog;
  }
}

IconData _formatIcon(String v) {
  switch (v) {
    case 'script':
      return Icons.videocam_outlined;
    case 'caption':
      return Icons.tag_outlined;
    case 'outline':
      return Icons.list_alt_outlined;
    default:
      return Icons.article_outlined;
  }
}

String _toneLabel(AppLocalizations t, String v) {
  switch (v) {
    case 'casual':
      return t.bwToneCasual;
    case 'persuasive':
      return t.bwTonePersuasive;
    case 'storytelling':
      return t.bwToneStorytelling;
    case 'professional':
      return t.bwToneProfessional;
    default:
      return t.bwToneInformative;
  }
}

String _lengthLabel(AppLocalizations t, String v) {
  switch (v) {
    case 'short':
      return t.bwLenShort;
    case 'long':
      return t.bwLenLong;
    default:
      return t.bwLenMedium;
  }
}

String _langLabel(AppLocalizations t, String v) {
  switch (v) {
    case 'bn':
      return t.bwLangBn;
    case 'banglish':
      return t.bwLangBanglish;
    default:
      return t.bwLangEn;
  }
}

String _problemLabel(AppLocalizations t, String key) {
  switch (key) {
    case 'topic_required':
      return t.bwProblemTopic;
    case 'bad_format':
      return t.bwProblemFormat;
    default:
      return t.bwProblemGeneric;
  }
}

// ------------------------------------------------------------ cards

/// The honest "AI-generated — review / never auto-posts" marker.
class _AiMarkerCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.auto_awesome, size: 18, color: scheme.onTertiaryContainer),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.bwAiMarker,
                style: TextStyle(
                    color: scheme.onTertiaryContainer,
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                    height: 1.4)),
            const SizedBox(height: 2),
            Text(t.bwNeverAutoPost,
                style: TextStyle(
                    color: scheme.onTertiaryContainer,
                    fontSize: 12,
                    height: 1.4)),
          ]),
        ),
      ]),
    );
  }
}

/// The honest key-gated "connect an AI key for a full AI draft" state.
class _FullAiCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.lock_outline, size: 18, color: scheme.primary),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.bwFullAiTitle,
                style:
                    const TextStyle(fontWeight: FontWeight.w700, height: 1.4)),
            const SizedBox(height: 2),
            Text(t.bwFullAiBody,
                style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12.5,
                    height: 1.4)),
          ]),
        ),
      ]),
    );
  }
}

/// A single-select chip row. Local to this screen so it stays self-contained.
class _ChipsRow extends StatelessWidget {
  final String label;
  final List<String> values;
  final String selected;
  final String Function(String) display;
  final ValueChanged<String> onSelect;
  const _ChipsRow({
    required this.label,
    required this.values,
    required this.selected,
    required this.display,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label,
          style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 13,
              color: scheme.onSurfaceVariant)),
      const SizedBox(height: Gap.sm),
      Wrap(
        spacing: Gap.sm,
        runSpacing: Gap.sm,
        children: [
          for (final v in values)
            ChoiceChip(
              selected: v == selected,
              onSelected: (_) => onSelect(v),
              label: Text(display(v),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
        ],
      ),
    ]);
  }
}
