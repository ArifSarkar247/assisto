// quranview: TAFSIR & SHANE NUZUL sheet with source chips (owner-approved
// screen; spec owner_actions/QURAN_BILINGUAL_SPEC_BN.md section 3).
//
// Only licensed sources (QuranEnc.com written terms). QUL's Bengali tafsirs
// have no copyright information on QUL -> never shown (owner action).
// Shane nuzul = a WHOLE unit of a licensed source that itself states the
// reason of revelation (server rule keyword_v1), verbatim; otherwise the
// clear line "this source has no shane nuzul for this ayah". No AI.
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';
import '../widgets/local_digits.dart';
import 'quran_bilingual_api.dart';

Future<void> showQuranTafsirSheet(BuildContext context,
    {required QuranBilingualApi api, required int sura, required int aya}) {
  return showAppSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      builder: (ctx, scroll) =>
          QuranTafsirBody(api: api, sura: sura, aya: aya, scroll: scroll),
    ),
  );
}

class QuranTafsirBody extends StatefulWidget {
  final QuranBilingualApi api;
  final int sura;
  final int aya;
  final ScrollController? scroll;
  final String? initialSource;
  const QuranTafsirBody(
      {super.key,
      required this.api,
      required this.sura,
      required this.aya,
      this.scroll,
      this.initialSource});

  @override
  State<QuranTafsirBody> createState() => _QuranTafsirBodyState();
}

class _QuranTafsirBodyState extends State<QuranTafsirBody> {
  Map<String, dynamic>? _d;
  bool _loading = true;
  String? _sel;

  @override
  void initState() {
    super.initState();
    _sel = widget.initialSource;
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final d = await widget.api.tafsir(widget.sura, widget.aya);
    if (!mounted) return;
    setState(() {
      _d = d;
      _loading = false;
    });
  }

  List<Map> get _sources =>
      ((_d?['sources'] as List?) ?? const []).whereType<Map>().toList();

  bool _bn(BuildContext c) => Localizations.localeOf(c).languageCode == 'bn';

  String _title(Map s) => '${_bn(context) ? s['title_bn'] : s['title_en']}';

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final pad = withNavBarInset(context, const EdgeInsets.all(Gap.lg));
    final head = Text(
        '${t.qvTafsirBtn} · ${ld(context, '${widget.sura}:${widget.aya}')}',
        style: AType.titleMedium.copyWith(fontWeight: FontWeight.bold));
    if (_loading) {
      return ListView(controller: widget.scroll, padding: pad, children: [
        head,
        const SizedBox(height: Gap.lg),
        const LinearProgressIndicator(),
      ]);
    }
    final srcs = _sources;
    if (_d == null || srcs.isEmpty) {
      return ListView(controller: widget.scroll, padding: pad, children: [
        head,
        const SizedBox(height: Gap.lg),
        Text(t.qvLoadFailed, key: const Key('qv-tafsir-failed')),
        const SizedBox(height: Gap.sm),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
            onPressed: _load,
            child: Text(t.qvRetry),
          ),
        ),
      ]);
    }
    final sel = srcs.firstWhere((s) => s['id'] == _sel, orElse: () => srcs.first);
    final sn = ((_d?['shan_nuzul'] as List?) ?? const [])
        .whereType<Map>()
        .where((x) => x['source_id'] == sel['id'])
        .toList();
    return ListView(
      key: const Key('qv-tafsir-body'),
      controller: widget.scroll,
      padding: pad,
      children: [
        head,
        const SizedBox(height: Gap.md),
        Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
          for (final s in srcs)
            ChoiceChip(
              key: Key('qv-src-${s['id']}'),
              label: Text(_title(s)),
              selected: s['id'] == sel['id'],
              onSelected: (_) => setState(() => _sel = '${s['id']}'),
            ),
        ]),
        const SizedBox(height: Gap.md),
        _Section(
          title: t.qvTafsirText,
          child: _Verbatim(text: '${sel['text'] ?? ''}', key: const Key('qv-tafsir-text')),
        ),
        _Section(
          title: t.qvShanNuzul,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (sn.isEmpty)
              Text(t.qvShanNone, key: const Key('qv-shan-none'))
            else ...[
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: Gap.sm, vertical: Gap.xxs),
                decoration: BoxDecoration(
                  color: scheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(Radii.pill),
                ),
                child: Text(t.qvUnderReview,
                    style: AType.labelMedium
                        .copyWith(color: scheme.onTertiaryContainer)),
              ),
              const SizedBox(height: Gap.xs),
              for (final x in sn)
                Padding(
                  padding: const EdgeInsets.only(bottom: Gap.sm),
                  child: _Verbatim(
                      key: const Key('qv-shan-text'), text: '${x['text'] ?? ''}'),
                ),
            ],
            const SizedBox(height: Gap.xs),
            Text(t.qvShanRule,
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          ]),
        ),
        Text(
          t.qvSourceQe('${sel['publisher'] ?? ''}', ld(context, '${sel['version'] ?? ''}')),
          key: const Key('qv-tafsir-source'),
          style: AType.labelSmall.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: Gap.sm),
        Text(t.qvNoAi,
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.xs),
        Text(t.qvTafsirPendingNote,
            key: const Key('qv-tafsir-pending-note'),
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget child;
  const _Section({required this.title, required this.child});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: Gap.md),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Semantics(
          header: true,
          child: Text(title,
              style: AType.labelLarge
                  .copyWith(color: scheme.primary, fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: Gap.xs),
        child,
      ]),
    );
  }
}

/// Publisher text exactly as sent (only <b> rendered as bold).
class _Verbatim extends StatelessWidget {
  final String text;
  const _Verbatim({super.key, required this.text});
  @override
  Widget build(BuildContext context) {
    final base = AType.bodyLarge.copyWith(color: Theme.of(context).colorScheme.onSurface);
    return SelectableText.rich(TextSpan(style: base, children: [
      for (final r in qvRuns(text))
        TextSpan(
            text: r.$1,
            style: r.$2 ? base.copyWith(fontWeight: FontWeight.bold) : null),
    ]));
  }
}
