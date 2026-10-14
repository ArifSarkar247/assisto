import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../widgets/social_engine.dart';
import '../widgets/social_cards.dart';

/// SOCIAL-MEDIA POST & CAPTION composer (#135, SPEC v2.1 §21, ADVANCED).
///
/// Opened from Agent Studio. The user picks a PLATFORM (Facebook / Instagram /
/// LinkedIn / WhatsApp-status), a TOPIC/goal, a TONE, a LENGTH and a language
/// (bn / Banglish / en); we DRAFT a ready-to-edit post body + a one-line
/// caption + hashtags + suggested emoji. A live per-platform character counter
/// warns before the hard limit. The user edits freely, taps hashtag/emoji chips
/// to insert them, then COPIES or SHARES to the platform's own app (share sheet
/// / deep link) and posts it THEMSELVES — Assisto NEVER auto-posts. Drafts can
/// be saved and reopened (local history).
///
/// The "AI drafts it for you" promise is served by a DETERMINISTIC MOCK
/// (`social_engine.dart`, mirroring `backend/core/logic/social.py`) and is
/// clearly labelled "AI-generated — review before posting". A real provider is
/// key-gated server-side (`core.ai.generate`); see up_social_integration.md.
class SocialComposeScreen extends StatefulWidget {
  const SocialComposeScreen({super.key});
  @override
  State<SocialComposeScreen> createState() => _SocialComposeScreenState();
}

class _SocialComposeScreenState extends State<SocialComposeScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  // compose inputs
  String _platform = 'facebook';
  String _tone = 'friendly';
  String _length = 'medium';
  String _lang = 'en';
  final TextEditingController _topic = TextEditingController();
  final TextEditingController _body = TextEditingController();
  final TextEditingController _caption = TextEditingController();
  List<String> _hashtags = [];
  List<String> _emoji = [];
  bool _hasDraft = false;
  String? _editingId; // non-null when re-saving an opened draft

  // saved drafts / history
  List<SavedDraft> _saved = [];
  bool _loading = true;
  String? _error;

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
    _caption.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await SocialStore.load();
      if (!mounted) return;
      setState(() {
        _saved = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _generate() {
    FocusScope.of(context).unfocus();
    final problems = validateSocial(_platform, _topic.text,
        tone: _tone, length: _length, lang: _lang);
    if (problems.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(problemLabel(t, problems.first))));
      return;
    }
    final d = buildDraft(_platform, _topic.text,
        tone: _tone, length: _length, lang: _lang);
    setState(() {
      _body.text = d.body;
      _caption.text = d.caption;
      _hashtags = d.hashtags;
      _emoji = d.emoji;
      _hasDraft = true;
      _editingId = null; // a fresh generation is a new draft
    });
  }

  void _insert(String s) {
    final sel = _body.selection;
    final text = _body.text;
    final at = (sel.isValid ? sel.end : text.length).clamp(0, text.length);
    final needsSpace = at > 0 && at <= text.length && text[at - 1] != ' ';
    final ins = (needsSpace ? ' ' : '') + s;
    final next = text.replaceRange(at, at, ins);
    _body.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: at + ins.length),
    );
    setState(() {});
  }

  String get _shareText =>
      composeForShare(_body.text, _hashtags, _platform);

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _shareText));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(t.copied)));
  }

  /// Open the platform's own share sheet with the drafted text. The user picks
  /// the target app and posts it themselves — we never post. The text is also
  /// copied first so it's easy to paste where a share can't prefill.
  Future<void> _share() async {
    await Clipboard.setData(ClipboardData(text: _shareText));
    await Share.share(_shareText, subject: _caption.text);
  }

  Future<void> _saveDraft() async {
    final now = DateTime.now();
    final id = _editingId ?? now.microsecondsSinceEpoch.toString();
    final entry = SavedDraft(
      id: id,
      platform: _platform,
      topic: _topic.text.trim(),
      tone: _tone,
      caption: _caption.text,
      body: _body.text,
      hashtags: _hashtags,
      savedAt: now.toIso8601String(),
    );
    setState(() {
      _saved = [entry, ..._saved.where((d) => d.id != id)].take(50).toList();
      _editingId = id;
    });
    await SocialStore.save(_saved);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(t.socialSaved)));
  }

  void _openSaved(SavedDraft d) {
    setState(() {
      _platform = d.platform;
      _tone = d.tone;
      _topic.text = d.topic;
      _body.text = d.body;
      _caption.text = d.caption;
      _hashtags = d.hashtags;
      _emoji = emojiFor(d.tone, d.platform);
      _hasDraft = true;
      _editingId = d.id;
    });
    _tabs.animateTo(0);
  }

  Future<void> _deleteSaved(SavedDraft d) async {
    setState(() => _saved = _saved.where((x) => x.id != d.id).toList());
    await SocialStore.save(_saved);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(t.commonDeleted)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t.socialTitle),
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            Tab(
                child: Text(t.socialTabCompose,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis)),
            Tab(
                child: Text(t.socialTabSaved,
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
    final count = charCount(_shareText, _platform);
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xxl),
      children: [
        const AiDraftMarker(),
        const SizedBox(height: Gap.lg),

        ChoiceChipsRow(
          label: t.socialPlatform,
          values: kPlatformOrder,
          selected: _platform,
          display: (v) => platformLabel(t, v),
          leading: platformIcon,
          onSelect: (v) => setState(() {
            _platform = v;
            if (_hasDraft) _emoji = emojiFor(_tone, _platform);
          }),
        ),
        const SizedBox(height: Gap.lg),

        TextField(
          controller: _topic,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: t.socialTopic,
            hintText: t.socialTopicHint,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: Gap.lg),

        ChoiceChipsRow(
          label: t.socialTone,
          values: kTones,
          selected: _tone,
          display: (v) => toneLabel(t, v),
          onSelect: (v) => setState(() => _tone = v),
        ),
        const SizedBox(height: Gap.lg),
        ChoiceChipsRow(
          label: t.socialLength,
          values: kLengths,
          selected: _length,
          display: (v) => lengthLabel(t, v),
          onSelect: (v) => setState(() => _length = v),
        ),
        const SizedBox(height: Gap.lg),
        ChoiceChipsRow(
          label: t.socialLanguage,
          values: const ['bn', 'banglish', 'en'],
          selected: _lang,
          display: (v) => langLabel(t, v),
          onSelect: (v) => setState(() => _lang = v),
        ),
        const SizedBox(height: Gap.lg),

        FilledButton.icon(
          onPressed: _generate,
          icon: const Icon(Icons.auto_awesome, size: 18),
          label: Text(_hasDraft ? t.socialRegenerate : t.socialGenerate),
        ),

        if (_hasDraft) ...[
          const SizedBox(height: Gap.xl),
          Text(t.socialCaption,
              style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: Gap.sm),
          TextField(
            controller: _caption,
            maxLines: 2,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.lg),

          Row(children: [
            Expanded(
              child: Text(t.socialPost,
                  style: const TextStyle(fontWeight: FontWeight.w800)),
            ),
            CharCounter(count: count),
          ]),
          const SizedBox(height: Gap.sm),
          TextField(
            controller: _body,
            maxLines: null,
            minLines: 5,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),

          Text(t.socialHashtags,
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.sm),
          HashtagChips(tags: _hashtags, onTap: _insert),

          if (_emoji.isNotEmpty) ...[
            const SizedBox(height: Gap.md),
            Text(t.socialEmoji,
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.xs),
            EmojiChips(emoji: _emoji, onTap: _insert),
          ],

          const SizedBox(height: Gap.xl),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: count.over ? null : _share,
                icon: const Icon(Icons.ios_share, size: 18),
                label: Text(t.socialShare),
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
          if (count.over) ...[
            const SizedBox(height: Gap.sm),
            Text(t.socialOverLimit,
                style: const TextStyle(color: Brand.danger, fontSize: 12.5)),
          ],
        ],
      ],
    );
  }

  // ----------------------------------------------------------------- saved tab

  Widget _savedTab() {
    if (_loading) return const SkeletonList(count: 4);
    if (_error != null) {
      return StateMessage(
        icon: Icons.cloud_off,
        tint: Brand.danger,
        title: t.socialLoadError,
        action: FilledButton.tonal(onPressed: _load, child: Text(t.retry)),
      );
    }
    if (_saved.isEmpty) {
      return StateMessage(
        icon: Icons.bookmark_border,
        title: t.socialSavedEmptyTitle,
        message: t.socialSavedEmptyBody,
        action: FilledButton.tonalIcon(
          onPressed: () => _tabs.animateTo(0),
          icon: const Icon(Icons.edit_outlined, size: 18),
          label: Text(t.socialTabCompose),
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
          return SavedDraftTile(
            d: d,
            onOpen: () => _openSaved(d),
            onDelete: () => _deleteSaved(d),
          );
        },
      ),
    );
  }
}
