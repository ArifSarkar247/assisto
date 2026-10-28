import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'in_chat_ai_engine.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// in_chat_ai_sheet.dart — the ONE bounded in-chat AI helper (#97, §21).
///
/// Opened from the chat ⋮ menu. Offers exactly three bounded actions over text
/// the DEVICE already decrypted: summarise-thread / translate-message /
/// adjust-tone. Every result is a DETERMINISTIC MOCK (see
/// [in_chat_ai_engine.dart]) carrying an honest "AI-generated — review" marker,
/// a copy action and an INSERT-into-composer action. Translate honestly shows a
/// "needs AI key" state (it never fabricates a translation). The helper NEVER
/// auto-sends — insert only drops text into the composer for the user to edit
/// and send themselves.
///
/// Zero Bangla literals: all user-facing strings come from AppLocalizations.
///
/// Returns a String to INSERT into the composer, or null if the user just
/// closed / copied.
Future<String?> showInChatAiSheet(
  BuildContext context, {
  required List<Map<String, dynamic>> decryptedRecent,
  String? seedText,
}) {
  return showAppSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _InChatAiSheet(
      decryptedRecent: decryptedRecent,
      seedText: seedText ?? '',
    ),
  );
}

class _InChatAiSheet extends StatefulWidget {
  final List<Map<String, dynamic>> decryptedRecent;
  final String seedText;
  const _InChatAiSheet({required this.decryptedRecent, required this.seedText});

  @override
  State<_InChatAiSheet> createState() => _InChatAiSheetState();
}

class _InChatAiSheetState extends State<_InChatAiSheet> {
  String _action = 'summarise';
  String _tone = 'polite';
  late final TextEditingController _text =
      TextEditingController(text: widget.seedText);
  InChatAiResult? _out;

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  String _actionLabel(String a) {
    switch (a) {
      case 'summarise':
        return t.inChatAiSummarise;
      case 'translate':
        return t.inChatAiTranslate;
      default:
        return t.inChatAiTone;
    }
  }

  String _toneLabel(String tone) {
    switch (tone) {
      case 'polite':
        return t.inChatAiTonePolite;
      case 'shorter':
        return t.inChatAiToneShorter;
      case 'warmer':
        return t.inChatAiToneWarmer;
      case 'firmer':
        return t.inChatAiToneFirmer;
      default:
        return t.inChatAiToneFormal;
    }
  }

  void _run() {
    final res = runInChatAi(
      _action,
      messages: widget.decryptedRecent,
      text: _text.text,
      tone: _tone,
    );
    setState(() => _out = res);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        left: Gap.lg,
        right: Gap.lg,
        top: Gap.xs,
        bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.auto_awesome_rounded, color: Brand.cyan),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(t.inChatAiTitle,
                    style: Theme.of(context).textTheme.titleLarge),
              ),
            ]),
            const SizedBox(height: Gap.xs),
            Text(t.inChatAiIntro,
                style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.md),
            // action chooser
            Wrap(
              spacing: Gap.sm,
              runSpacing: Gap.sm,
              children: [
                for (final a in kInChatAiActions)
                  ChoiceChip(
                    label: Text(_actionLabel(a)),
                    selected: _action == a,
                    onSelected: (_) => setState(() {
                      _action = a;
                      _out = null;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: Gap.md),
            if (_action == 'summarise')
              _summariseInput(scheme)
            else ...[
              TextField(
                controller: _text,
                minLines: 2,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: t.inChatAiTextLabel,
                  alignLabelWithHint: true,
                ),
              ),
              if (_action == 'tone') ...[
                const SizedBox(height: Gap.md),
                Text(t.inChatAiToneLabel,
                    style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: Gap.sm),
                Wrap(
                  spacing: Gap.sm,
                  runSpacing: Gap.sm,
                  children: [
                    for (final tn in kInChatAiTones)
                      ChoiceChip(
                        label: Text(_toneLabel(tn)),
                        selected: _tone == tn,
                        onSelected: (_) => setState(() {
                          _tone = tn;
                          _out = null;
                        }),
                      ),
                  ],
                ),
              ],
            ],
            const SizedBox(height: Gap.md),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _run,
                icon: const Icon(Icons.auto_fix_high_rounded),
                label: Text(t.inChatAiGenerate),
              ),
            ),
            if (_out != null) ...[
              const SizedBox(height: Gap.lg),
              _resultCard(_out!, scheme),
            ],
            const SizedBox(height: Gap.sm),
          ],
        ),
      ),
    );
  }

  Widget _summariseInput(ColorScheme scheme) {
    final n = widget.decryptedRecent
        .where((m) => '${m['text'] ?? ''}'.trim().isNotEmpty)
        .length;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(children: [
        Icon(Icons.forum_rounded, size: 18, color: scheme.onSurfaceVariant),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(
            n == 0 ? t.inChatAiThreadEmpty : t.inChatAiThreadCount(n),
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
        ),
      ]),
    );
  }

  // ---- result rendering ----------------------------------------------------
  Widget _resultCard(InChatAiResult out, ColorScheme scheme) {
    // honest input problems first (empty text / empty thread)
    if (out.problems.isNotEmpty) {
      return _notice(
        icon: Icons.info_outline_rounded,
        tint: Brand.warning,
        text: out.problems.contains('empty_thread')
            ? t.inChatAiThreadEmpty
            : t.inChatAiTextMissing,
      );
    }

    final body = <Widget>[];
    if (out.action == 'summarise') {
      body.add(Text(t.inChatAiThreadCount(out.count),
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)));
      body.add(const SizedBox(height: Gap.xs));
      for (final b in out.bullets) {
        body.add(Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('• ',
                style: TextStyle(color: scheme.onSurfaceVariant)),
            Expanded(
              child: Text(
                '${b.who == 'you' ? t.inChatAiWhoYou : t.inChatAiWhoThem}: ${b.text}',
                style: const TextStyle(height: 1.35),
              ),
            ),
          ]),
        ));
      }
    } else if (out.action == 'tone') {
      body.add(SelectableText(out.result, style: const TextStyle(height: 1.4)));
    } else {
      // translate — honest key-gated state; never a fabricated translation
      body.add(_notice(
        icon: Icons.vpn_key_rounded,
        tint: Brand.blue,
        text: out.direction == 'bn2en'
            ? t.inChatAiTranslateBnEn
            : t.inChatAiTranslateEnBn,
      ));
      body.add(const SizedBox(height: Gap.sm));
      body.add(Text(t.inChatAiTranslateSource,
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)));
      body.add(SelectableText(out.source, style: const TextStyle(height: 1.4)));
      body.add(const SizedBox(height: Gap.sm));
      body.add(_notice(
        icon: Icons.lock_outline_rounded,
        tint: Brand.warning,
        text: t.inChatAiNeedsKey,
      ));
    }

    // what gets copied / inserted (translate has no usable output text)
    final insertable = out.action == 'tone'
        ? out.result
        : out.action == 'summarise'
            ? out.bullets
                .map((b) =>
                    '• ${b.who == 'you' ? t.inChatAiWhoYou : t.inChatAiWhoThem}: ${b.text}')
                .join('\n')
            : '';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: Brand.cyan.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: Brand.cyan.withValues(alpha: 0.3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // honest AI marker — always present on AI output
        Row(children: [
          const Icon(Icons.auto_awesome_rounded, size: 14, color: Brand.cyan),
          const SizedBox(width: 6),
          Expanded(
            child: Text(t.inChatAiMarker,
                style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Brand.cyan)),
          ),
        ]),
        const SizedBox(height: Gap.sm),
        ...body,
        if (insertable.isNotEmpty) ...[
          const SizedBox(height: Gap.md),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: insertable));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(t.inChatAiCopied)));
                },
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: Text(t.inChatAiCopy),
              ),
            ),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: FilledButton.icon(
                onPressed: () => Navigator.pop(context, insertable),
                icon: const Icon(Icons.input_rounded, size: 18),
                label: Text(t.inChatAiInsert),
              ),
            ),
          ]),
          const SizedBox(height: 6),
          Text(t.inChatAiNeverSends,
              style: TextStyle(
                  fontSize: 11, color: scheme.onSurfaceVariant, height: 1.3)),
        ],
      ]),
    );
  }

  Widget _notice(
          {required IconData icon,
          required Color tint,
          required String text}) =>
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 16, color: tint),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(text,
              style: TextStyle(fontSize: 12, height: 1.35, color: tint)),
        ),
      ]);
}
