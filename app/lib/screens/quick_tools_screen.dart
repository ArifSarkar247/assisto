import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../ads/ad_banner_slot.dart' show AdBannerSlot;
import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../widgets/quick_tools_engine.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// QUICK TOOLS (#17, SPEC v2.1 §6, built to ADVANCED §21).
///
/// A small toolbox over entered text: SUMMARISE / FIX GRAMMAR / TRANSLATE /
/// CHANGE TONE / MAKE SHAREABLE. Each is a DETERMINISTIC MOCK transform
/// (`quick_tools_engine.dart`, mirroring `backend/core/logic/quick_tools.py`)
/// labelled honestly "AI-generated — review". Translate is honest: it renders a
/// few known common phrases offline and otherwise shows a "connect an AI key for
/// a real translation" state — it never fabricates a sentence translation. A
/// real provider is key-gated server-side (`core.ai.generate`, Integrations
/// `anthropic`); see up_quickbrief_integration.md.
///
/// Works with NO key. Output can be copied / shared (the user shares it
/// themselves — nothing is auto-sent). Results are mostly stateless; an optional
/// local save keeps a short history.
class QuickToolsScreen extends StatefulWidget {
  const QuickToolsScreen({super.key});
  @override
  State<QuickToolsScreen> createState() => _QuickToolsScreenState();
}

class _QuickToolsScreenState extends State<QuickToolsScreen> {
  final TextEditingController _input = TextEditingController();
  String _action = 'summarise';
  String _tone = 'polite';
  String _direction = 'auto';

  QuickResult? _result;
  bool _translateNeedsKey = false;

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  String _actionLabel(String a) {
    switch (a) {
      case 'summarise':
        return t.qtActionSummarise;
      case 'fix_grammar':
        return t.qtActionGrammar;
      case 'translate':
        return t.qtActionTranslate;
      case 'change_tone':
        return t.qtActionTone;
      default:
        return t.qtActionShareable;
    }
  }

  String _toneLabel(String v) {
    switch (v) {
      case 'polite':
        return t.qtTonePolite;
      case 'shorter':
        return t.qtToneShorter;
      case 'warmer':
        return t.qtToneWarmer;
      case 'firmer':
        return t.qtToneFirmer;
      default:
        return t.qtToneFormal;
    }
  }

  String _dirLabel(String v) {
    switch (v) {
      case 'bn2en':
        return t.qtDirBnEn;
      case 'en2bn':
        return t.qtDirEnBn;
      default:
        return t.qtDirAuto;
    }
  }

  String _problemLabel(String key) {
    switch (key) {
      case 'empty_text':
        return t.qtErrEmpty;
      case 'bad_tone':
        return t.qtErrTone;
      case 'bad_direction':
        return t.qtErrDirection;
      default:
        return t.qtErrEmpty;
    }
  }

  /// The common-phrase lookup (English key → localised bn rendering) the offline
  /// translate fallback uses. Sourced from the ARB so no Bangla lives in .dart.
  Map<String, String> _phraseTable() => {
        'hello': t.qtPhraseHello,
        'thank you': t.qtPhraseThankYou,
        'thanks': t.qtPhraseThankYou,
        'good morning': t.qtPhraseGoodMorning,
        'good night': t.qtPhraseGoodNight,
        'how are you': t.qtPhraseHowAreYou,
        'yes': t.qtPhraseYes,
        'no': t.qtPhraseNo,
        'sorry': t.qtPhraseSorry,
        'welcome': t.qtPhraseWelcome,
      };

  void _run() {
    FocusScope.of(context).unfocus();
    final problems = validateQuick(_action, _input.text,
        tone: _tone, direction: _direction);
    if (problems.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_problemLabel(problems.first))));
      return;
    }
    final r = runQuick(_action, _input.text,
        tone: _tone, direction: _direction, phraseTable: _phraseTable());
    setState(() {
      _result = r;
      _translateNeedsKey = r.action == 'translate' && r.aiRequired;
    });
  }

  Future<void> _copy() async {
    final text = _result?.result ?? '';
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(t.copied)));
  }

  Future<void> _share() async {
    final text = _result?.result ?? '';
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    await Share.share(text);
  }

  Future<void> _save() async {
    final r = _result;
    if (r == null || r.result.isEmpty) return;
    final now = DateTime.now();
    final list = await QuickStore.load();
    final entry = SavedQuick(
      id: now.microsecondsSinceEpoch.toString(),
      action: r.action,
      source: r.source,
      result: r.result,
      savedAt: now.toIso8601String(),
    );
    await QuickStore.save([entry, ...list]);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(t.saved)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      // banners-everywhere (owner 26 Oct): one bottom banner, Free only
      bottomNavigationBar: const AdBannerSlot(screen: 'quick_tools'),
      appBar: AppBar(title: Text(t.qtTitle)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xxl)),
        children: [
          _AiMarker(text: t.f6QtRuleMarker, note: t.qtNeverSends) /* f6: rule-based, not AI */,
          const SizedBox(height: Gap.lg),

          // the text the toolbox works over
          TextField(
            controller: _input,
            maxLines: null,
            minLines: 4,
            decoration: InputDecoration(
              labelText: t.qtInputLabel,
              hintText: t.qtInputHint,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: Gap.lg),

          Text(t.qtToolLabel,
              style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: Gap.sm),
          Wrap(
            spacing: Gap.sm,
            runSpacing: Gap.sm,
            children: [
              for (final a in kQuickActions)
                ChoiceChip(
                  label: Text(_actionLabel(a),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  selected: _action == a,
                  onSelected: (_) => setState(() {
                    _action = a;
                    _result = null;
                  }),
                ),
            ],
          ),

          if (_action == 'change_tone') ...[
            const SizedBox(height: Gap.lg),
            Text(t.qtToneLabel,
                style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: Gap.sm),
            Wrap(
              spacing: Gap.sm,
              runSpacing: Gap.sm,
              children: [
                for (final v in kQuickTones)
                  ChoiceChip(
                    label: Text(_toneLabel(v)),
                    selected: _tone == v,
                    onSelected: (_) => setState(() => _tone = v),
                  ),
              ],
            ),
          ],

          if (_action == 'translate') ...[
            const SizedBox(height: Gap.lg),
            Text(t.qtDirLabel,
                style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: Gap.sm),
            Wrap(
              spacing: Gap.sm,
              runSpacing: Gap.sm,
              children: [
                for (final v in kQuickDirections)
                  ChoiceChip(
                    label: Text(_dirLabel(v)),
                    selected: _direction == v,
                    onSelected: (_) => setState(() => _direction = v),
                  ),
              ],
            ),
          ],

          const SizedBox(height: Gap.xl),
          FilledButton.icon(
            onPressed: _run,
            icon: const Icon(Icons.auto_awesome_rounded, size: 18),
            label: Text(t.qtRun),
          ),

          if (_result != null) ...[
            const SizedBox(height: Gap.xl),
            if (_translateNeedsKey)
              _NeedsKeyCard(
                title: t.qtTranslateNeedsKeyTitle,
                body: t.qtTranslateNeedsKeyBody,
              )
            else ...[
              Text(t.qtResultLabel,
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: Gap.sm),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(Gap.lg),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(Radii.md),
                ),
                child: SelectableText(
                  _result!.result.isEmpty ? t.qtResultEmpty : _result!.result,
                  style: const TextStyle(height: 1.5),
                ),
              ),
              if (_result!.action == 'translate' && _result!.phraseHit) ...[
                const SizedBox(height: Gap.sm),
                Text(t.qtPhraseFallbackNote,
                    style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
              ],
              const SizedBox(height: Gap.lg),
              Row(children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _result!.result.isEmpty ? null : _share,
                    icon: const Icon(Icons.ios_share_rounded, size: 18),
                    label: Text(t.share),
                  ),
                ),
                const SizedBox(width: Gap.sm),
                OutlinedButton.icon(
                  onPressed: _result!.result.isEmpty ? null : _copy,
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: Text(t.copy),
                ),
              ]),
              const SizedBox(height: Gap.sm),
              OutlinedButton.icon(
                onPressed: _result!.result.isEmpty ? null : _save,
                icon: const Icon(Icons.bookmark_outline_rounded, size: 18),
                label: Text(t.save),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// Honest "AI-generated — review" marker + "Assisto never sends for you" note.
class _AiMarker extends StatelessWidget {
  final String text;
  final String note;
  const _AiMarker({required this.text, required this.note});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.auto_awesome_rounded, size: 18, color: scheme.onTertiaryContainer),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(text,
                style: AType.bodySmall.copyWith(color: scheme.onTertiaryContainer, fontWeight: FontWeight.w700, height: 1.4)),
            const SizedBox(height: Gap.xxs),
            Text(note,
                style: AType.bodySmall.copyWith(color: scheme.onTertiaryContainer, height: 1.4)),
          ]),
        ),
      ]),
    );
  }
}

/// Honest key-gated state for a real translation.
class _NeedsKeyCard extends StatelessWidget {
  final String title;
  final String body;
  const _NeedsKeyCard({required this.title, required this.body});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StateMessage(
      icon: Icons.key_rounded,
      tint: Brand.warning,
      title: title,
      message: body,
    );
  }
}
