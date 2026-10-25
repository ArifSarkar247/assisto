import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import 'dict_store.dart';

/// Dictionary ADVANCED — one result card (feature 39, SPEC v2.1 §21).
///
/// Renders a backend-sourced [DictEntry]: bn<->en headwords, part of speech,
/// example sentence, pronunciation note, synonyms and antonyms, with
/// save/favourite, copy and share actions. ALL displayed Bangla text is DATA
/// from the open-license backend dataset — no meaning, example or synonym is
/// ever written in Dart. Chrome labels come from ARB (zero Bangla in .dart).
class DictEntryCard extends StatefulWidget {
  final DictEntry entry;
  final DictStore store;
  const DictEntryCard({super.key, required this.entry, required this.store});

  @override
  State<DictEntryCard> createState() => _DictEntryCardState();
}

class _DictEntryCardState extends State<DictEntryCard> {
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    widget.store.isSaved(widget.entry).then((v) {
      if (mounted) setState(() => _saved = v);
    });
  }

  Future<void> _toggleSave(AppLocalizations t) async {
    final now = await widget.store.toggleSaved(widget.entry);
    if (!mounted) return;
    setState(() => _saved = now);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(now ? t.dictSavedDone : t.dictRemoveSaved),
      duration: const Duration(seconds: 1),
    ));
  }

  String _plainText(AppLocalizations t) {
    final e = widget.entry;
    final parts = <String>[];
    if (e.pos.isNotEmpty) parts.add(e.pos);
    if (e.ipa.isNotEmpty) parts.add('/${e.ipa}/');
    if (e.example.isNotEmpty) parts.add(e.example);
    if (e.syn.isNotEmpty) parts.add('${t.dictSynonyms}: ${e.syn.join(', ')}');
    if (e.ant.isNotEmpty) parts.add('${t.dictAntonyms}: ${e.ant.join(', ')}');
    return parts.join('\n');
  }

  Future<void> _copy(AppLocalizations t) async {
    final e = widget.entry;
    await Clipboard.setData(ClipboardData(text: '${e.bn} — ${e.en}\n${_plainText(t)}'.trim()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(t.dictCopied),
      duration: const Duration(seconds: 1),
    ));
  }

  Future<void> _share(AppLocalizations t) async {
    final e = widget.entry;
    await Share.share(t.dictShareTemplate(_plainText(t), e.bn, e.en) /* (detail, bn, en) */.trim());
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final e = widget.entry;
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // headwords
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Text(e.bn,
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 4),
              child: Icon(Icons.swap_horiz_rounded, size: 18),
            ),
            Expanded(
              child: Text(e.en,
                  textAlign: TextAlign.end,
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            ),
          ]),
          if (e.pos.isNotEmpty || e.ipa.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(spacing: Gap.sm, runSpacing: 4, children: [
              if (e.pos.isNotEmpty)
                _Tag(label: '${t.dictPartOfSpeech}: ${e.pos}', color: cs.primary),
              if (e.ipa.isNotEmpty)
                _Tag(
                  label: '/${e.ipa}/',
                  color: cs.secondary,
                  tooltip: t.dictPronunciationNote,
                  icon: Icons.volume_up_rounded,
                ),
            ]),
          ],
          if (e.example.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            _Section(title: t.dictExample, child: Text(e.example, style: const TextStyle(fontSize: 14))),
          ],
          if (e.syn.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            _ChipsSection(title: t.dictSynonyms, items: e.syn, color: cs.tertiary),
          ],
          if (e.ant.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            _ChipsSection(title: t.dictAntonyms, items: e.ant, color: Brand.warning),
          ],
          const Divider(height: Gap.lg),
          // actions
          Row(children: [
            IconButton(
              tooltip: _saved ? t.dictRemoveSaved : t.dictSave,
              onPressed: () => _toggleSave(t),
              icon: Icon(_saved ? Icons.star_rounded : Icons.star_border_rounded,
                  color: _saved ? Brand.warning : null),
            ),
            IconButton(
              tooltip: t.dictCopy,
              onPressed: () => _copy(t),
              icon: const Icon(Icons.copy_rounded),
            ),
            IconButton(
              tooltip: t.dictShare,
              onPressed: () => _share(t),
              icon: const Icon(Icons.share_rounded),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String label;
  final Color color;
  final String? tooltip;
  final IconData? icon;
  const _Tag({required this.label, required this.color, this.tooltip, this.icon});
  @override
  Widget build(BuildContext context) {
    final w = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
        ],
        Text(label,
            style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
      ]),
    );
    return tooltip == null ? w : Tooltip(message: tooltip!, child: w);
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget child;
  const _Section({required this.title, required this.child});
  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title,
          style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              color: Theme.of(context).colorScheme.onSurfaceVariant)),
      const SizedBox(height: 2),
      child,
    ]);
  }
}

class _ChipsSection extends StatelessWidget {
  final String title;
  final List<String> items;
  final Color color;
  const _ChipsSection({required this.title, required this.items, required this.color});
  @override
  Widget build(BuildContext context) {
    return _Section(
      title: title,
      child: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Wrap(
          spacing: Gap.sm,
          runSpacing: 6,
          children: [
            for (final s in items)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: color.withValues(alpha: 0.4)),
                ),
                child: Text(s, style: const TextStyle(fontSize: 13)),
              ),
          ],
        ),
      ),
    );
  }
}
