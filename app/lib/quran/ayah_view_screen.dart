// quranview (owner order 9 Nov 21:55, lane 14): the bilingual AYAH VIEW.
// Spec: owner_actions/QURAN_BILINGUAL_SPEC_BN.md (section 2).
//
// Blocks (each with a source line, each line toggleable, remembered):
//   Arabic (Tanzil Uthmani, verbatim, offline) · Bangla pronunciation (lane
//   15 rule engine, "under review") · English transliteration (QF) · Bangla
//   meaning + English meaning (QuranEnc, verbatim) · word by word (QF) ·
//   recitation with reciter + repeat (QF, streamed) · tafsir & shane nuzul.
// LANGUAGE RULE: Bangla AND English are both shown in either app language —
// the owner's only exception to strict language separation.
// HARD RULES: no AI; no ads; texts never altered; QF kept <= 6 days.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';
import '../widgets/local_digits.dart';
import 'quran_ayah_audio.dart';
import 'quran_bilingual_api.dart';
import 'quran_store.dart';
import 'quran_tafsir_sheet.dart';

const String kQvArabicFont = 'AmiriQuran';

/// The toggleable lines, in screen order.
enum QvLine { arabic, pron, translit, bn, en, words, audio }

class QvPrefs {
  static const _off = 'qv_lines_off_v1';
  static const _rec = 'qv_reciter_v1';
  static const _rep = 'qv_repeat_v1';

  static Future<Set<QvLine>> hidden() async {
    try {
      final p = await SharedPreferences.getInstance();
      final names = p.getStringList(_off) ?? const [];
      return {
        for (final l in QvLine.values)
          if (names.contains(l.name)) l
      };
    } catch (_) {
      return {};
    }
  }

  static Future<void> setHidden(Set<QvLine> off) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(_off, [for (final l in off) l.name]);
    } catch (_) {}
  }

  static Future<(int?, int)> audio() async {
    try {
      final p = await SharedPreferences.getInstance();
      return (p.getInt(_rec), p.getInt(_rep) ?? 1);
    } catch (_) {
      return (null, 1);
    }
  }

  static Future<void> setAudio(int? reciter, int repeat) async {
    try {
      final p = await SharedPreferences.getInstance();
      if (reciter != null) await p.setInt(_rec, reciter);
      await p.setInt(_rep, repeat);
    } catch (_) {}
  }
}

const List<int> kQvRepeats = [1, 3, 5, 7, 10];

class AyahViewScreen extends StatefulWidget {
  final QuranData data;
  final int sura;
  final int aya;

  /// Test / gallery seams.
  final QuranBilingualApi? api;
  final QvPlayer? player;
  const AyahViewScreen(
      {super.key,
      required this.data,
      required this.sura,
      required this.aya,
      this.api,
      this.player});

  @override
  State<AyahViewScreen> createState() => _AyahViewScreenState();
}

class _AyahViewScreenState extends State<AyahViewScreen> {
  late QuranBilingualApi _api;
  late int _aya;
  Set<QvLine> _off = {};
  Map<String, dynamic>? _meaning, _pron, _qf, _reciters;
  bool _meaningLoading = true, _qfLoading = true, _pronLoading = true;
  int? _reciter;
  int _repeat = 1;
  int _playing = 0;
  bool _audioFailed = false;
  late final QuranAyahAudio _audio;

  QuranSura get _s => widget.data.suras[widget.sura - 1];

  @override
  void initState() {
    super.initState();
    _aya = widget.aya.clamp(1, _s.ayas);
    _api = widget.api ??
        QuranBilingualApi((p) => context.read<AppState>().api.getJson(p));
    _audio = QuranAyahAudio(
        player: widget.player,
        onState: (i, failed) {
          if (!mounted) return;
          setState(() {
            _playing = i;
            _audioFailed = failed;
          });
        });
    _init();
  }

  @override
  void dispose() {
    _audio.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final off = await QvPrefs.hidden();
    final (rec, rep) = await QvPrefs.audio();
    if (!mounted) return;
    setState(() {
      _off = off;
      _reciter = rec;
      _repeat = kQvRepeats.contains(rep) ? rep : 1;
    });
    _loadSura();
    _loadAyah();
    _api.reciters().then((r) {
      if (mounted) setState(() => _reciters = r);
    });
  }

  Future<void> _loadSura() async {
    setState(() {
      _meaningLoading = true;
      _pronLoading = true;
    });
    final m = _api.meaning(widget.sura);
    final p = _api.pron(widget.sura);
    final mm = await m;
    if (mounted) setState(() {
      _meaning = mm;
      _meaningLoading = false;
    });
    final pp = await p;
    if (mounted) setState(() {
      _pron = pp;
      _pronLoading = false;
    });
  }

  Future<void> _loadAyah() async {
    setState(() => _qfLoading = true);
    final q = await _api.qf(widget.sura, _aya, reciter: _reciter);
    if (!mounted) return;
    setState(() {
      _qf = q;
      _qfLoading = false;
    });
  }

  void _go(int aya) {
    if (aya < 1 || aya > _s.ayas) return;
    _audio.stop();
    setState(() {
      _aya = aya;
      _qf = null;
    });
    QuranPrefs.setLastRead(AyaRef(widget.sura, aya));
    _loadAyah();
  }

  bool _on(QvLine l) => !_off.contains(l);

  Future<void> _lines() async {
    final t = AppLocalizations.of(context);
    await showAppSheet<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        return ListView(
          shrinkWrap: true,
          padding: withNavBarInset(ctx, const EdgeInsets.all(Gap.lg)),
          children: [
            Text(t.qvLines,
                style: AType.titleMedium.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: Gap.xs),
            Text(t.qvLinesHint, style: AType.bodySmall),
            for (final l in QvLine.values)
              if (_available(l))
              SwitchListTile(
                key: Key('qv-line-${l.name}'),
                contentPadding: EdgeInsets.zero,
                title: Text(_lineName(t, l)),
                value: _on(l),
                onChanged: (v) {
                  setState(() => v ? _off.remove(l) : _off.add(l));
                  setSheet(() {});
                  QvPrefs.setHidden(_off);
                },
              ),
          ],
        );
      }),
    );
  }

  /// Lines whose source is live right now (others are hidden, not teased).
  bool _available(QvLine l) => switch (l) {
        QvLine.pron => _pronShown,
        QvLine.translit || QvLine.words || QvLine.audio => !_qfOff,
        _ => true,
      };

  String _lineName(AppLocalizations t, QvLine l) => switch (l) {
        QvLine.arabic => t.qvLineArabic,
        QvLine.pron => t.qvLinePron,
        QvLine.translit => t.qvLineTranslit,
        QvLine.bn => t.qvLineBn,
        QvLine.en => t.qvLineEn,
        QvLine.words => t.qvLineWords,
        QvLine.audio => t.qvLineAudio,
      };

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final ref = AyaRef(widget.sura, _aya);
    return Scaffold(
      appBar: AppBar(
        title: Text('${quranSuraTitle(Localizations.localeOf(context).languageCode == 'bn', _s)} '
            '${ld(context, '${widget.sura}:$_aya')}'),
        actions: [
          IconButton(
            key: const Key('qv-lines'),
            tooltip: t.qvLines,
            icon: const Icon(Icons.tune_rounded),
            onPressed: _lines,
          ),
        ],
      ),
      body: ListView(
        key: const Key('qv-body'),
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.md)),
        children: [
          if (_on(QvLine.arabic))
            _Block(
              key: const Key('qv-arabic'),
              title: t.qvLineArabic,
              source: t.qvSourceTanzil,
              child: Text(widget.data.ar(ref),
                  textDirection: TextDirection.rtl,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                      fontFamily: kQvArabicFont, fontSize: 30, height: 2.0)),
            ),
          // NO SHOWPIECES: a source that is not live yet (pronunciation
          // engine, Quran Foundation key) hides its block (no placeholder promise).
          if (_on(QvLine.pron) && _pronShown) _pronBlock(t),
          if (_on(QvLine.translit) && !_qfOff) _translitBlock(t),
          if (_on(QvLine.bn)) _meaningBlock(t, 'bn'),
          if (_on(QvLine.en)) _meaningBlock(t, 'en'),
          if (_on(QvLine.words) && !_qfOff) _wordsBlock(t),
          if (_on(QvLine.audio) && !_qfOff) _audioBlock(t),
          const SizedBox(height: Gap.sm),
          FilledButton.tonalIcon(
            key: const Key('qv-tafsir'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            icon: const Icon(Icons.menu_book_rounded),
            label: Text(t.qvTafsirBtn),
            onPressed: () => showQuranTafsirSheet(context,
                api: _api, sura: widget.sura, aya: _aya),
          ),
          const SizedBox(height: Gap.md),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('qv-prev'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                icon: const Icon(Icons.chevron_left_rounded),
                label: Text(t.qvPrev),
                onPressed: _aya > 1 ? () => _go(_aya - 1) : null,
              ),
            ),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('qv-next'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                icon: const Icon(Icons.chevron_right_rounded),
                // gap-quranblood Q5: the last verse leads to the next sura
                label: Text(_aya < _s.ayas || widget.sura >= widget.data.suras.length
                    ? t.qvNext
                    : t.qvNextSura),
                onPressed: _aya < _s.ayas
                    ? () => _go(_aya + 1)
                    : widget.sura < widget.data.suras.length
                        ? () => Navigator.of(context).pushReplacement(MaterialPageRoute(
                            builder: (_) => AyahViewScreen(
                                data: widget.data,
                                sura: widget.sura + 1,
                                aya: 1,
                                api: widget.api,
                                player: widget.player)))
                        : null,
              ),
            ),
          ]),
          const SizedBox(height: Gap.lg),
          Text(t.qvNoAi,
              key: const Key('qv-noai'),
              style: AType.bodySmall
                  .copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: Gap.xs),
          Text(t.qvQfCredit,
              key: const Key('qv-qf-credit'),
              style: AType.bodySmall
                  .copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _loading() => const Padding(
        padding: EdgeInsets.symmetric(vertical: Gap.sm),
        child: LinearProgressIndicator(),
      );

  Widget _retry(AppLocalizations t, String msg, VoidCallback onRetry, Key key) =>
      Row(key: key, children: [
        Expanded(child: Text(msg)),
        TextButton(
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: onRetry,
          child: Text(t.qvRetry),
        ),
      ]);

  bool get _pronShown =>
      _pronLoading || '${qvItem(_pron, _aya)?['bn'] ?? ''}'.isNotEmpty;

  Widget _pronBlock(AppLocalizations t) {
    final it = qvItem(_pron, _aya);
    final bn = (it?['bn'] as String?) ?? '';
    final review = '${it?['review'] ?? ''}';
    final approved = review == 'approved';
    final note = (it?['note_bn'] as String?) ?? '';
    final legend = (_pron?['legend_bn'] as String?) ?? '';
    final bism = (_pron?['bismillah_bn'] as String?) ?? '';
    // lane 15: a rejected line is never shown, only its fixed note.
    final hideText = review == 'rejected';
    Widget child;
    if (_pronLoading) {
      child = _loading();
    } else {
      child = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (!approved) QvReviewChip(label: t.qvUnderReview),
        if (_aya == 1 && bism.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Text(bism, style: AType.bodyMedium),
          ),
        const SizedBox(height: Gap.xs),
        // bn keeps its ZWNJ (U+200C) marks as sent — never stripped.
        if (!hideText)
          Text(bn, key: const Key('qv-pron-text'), style: AType.bodyLarge),
        if (note.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Text(note,
                key: const Key('qv-pron-note'),
                style: AType.bodySmall
                    .copyWith(color: Theme.of(context).colorScheme.error)),
          ),
        if (legend.isNotEmpty && !hideText)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Text(legend,
                key: const Key('qv-pron-legend'),
                style: AType.bodySmall.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
      ]);
    }
    return _Block(
        key: const Key('qv-pron'),
        title: t.qvLinePron,
        source: t.qvSourcePron,
        child: child);
  }

  bool get _qfOff => _qf != null && _qf!['enabled'] == false;

  Widget _qfState(AppLocalizations t, Widget Function() ok, String name) {
    if (_qfLoading) return _loading();
    if (_qf == null) {
      return _retry(t, t.qvLoadFailed, _loadAyah, Key('qv-$name-retry'));
    }
    return ok();
  }

  Widget _translitBlock(AppLocalizations t) => _Block(
        key: const Key('qv-translit'),
        title: t.qvLineTranslit,
        source: t.qvSourceQf,
        child: _qfState(t, () {
          final s = (_qf!['translit'] as String?) ?? '';
          return Text(s.isEmpty ? t.qvNotInSource : s,
              textDirection: TextDirection.ltr,
              style: AType.bodyLarge.copyWith(fontStyle: FontStyle.italic));
        }, 'translit'),
      );

  Widget _meaningBlock(AppLocalizations t, String lang) {
    final block = _meaning?[lang] as Map<String, dynamic>?;
    final it = qvItem(block, _aya);
    final title = lang == 'bn' ? t.qvLineBn : t.qvLineEn;
    final key = Key('qv-meaning-$lang');
    if (_meaningLoading) {
      return _Block(key: key, title: title, child: _loading());
    }
    if (block == null || it == null) {
      return _Block(
          key: key,
          title: title,
          child: _retry(t, t.qvLoadFailed, _loadSura, Key('qv-meaning-$lang-retry')));
    }
    final pub = '${block['publisher'] ?? ''}';
    final ver = ld(context, '${block['version'] ?? ''}');
    return _Block(
      key: key,
      title: title,
      source: t.qvSourceQe(pub, ver),
      child: Text('${it['text'] ?? ''}',
          key: Key('qv-meaning-$lang-text'),
          textDirection: TextDirection.ltr,
          style: AType.bodyLarge),
    );
  }

  Widget _wordsBlock(AppLocalizations t) => _Block(
        key: const Key('qv-words'),
        title: t.qvLineWords,
        source: t.qvSourceQf,
        child: _qfState(t, () {
          final words = (_qf!['words'] as List?) ?? const [];
          if (words.isEmpty) return Text(t.qvNotInSource);
          final scheme = Theme.of(context).colorScheme;
          return Directionality(
            textDirection: TextDirection.rtl,
            child: Wrap(
              spacing: Gap.sm,
              runSpacing: Gap.sm,
              children: [
                for (final w in words.whereType<Map>())
                  Container(
                    constraints: const BoxConstraints(minWidth: 72, minHeight: 48),
                    padding: const EdgeInsets.all(Gap.sm),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(Radii.md),
                    ),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text('${w['ar'] ?? ''}',
                          textDirection: TextDirection.rtl,
                          style: const TextStyle(
                              fontFamily: kQvArabicFont, fontSize: 24, height: 1.8)),
                      if ('${w['tr'] ?? ''}'.isNotEmpty)
                        Text('${w['tr']}',
                            textDirection: TextDirection.ltr,
                            style: AType.labelMedium
                                .copyWith(fontStyle: FontStyle.italic)),
                      if ('${w['bn'] ?? ''}'.isNotEmpty)
                        Text('${w['bn']}',
                            textDirection: TextDirection.ltr,
                            style: AType.bodyMedium),
                      if ('${w['en'] ?? ''}'.isNotEmpty)
                        Text('${w['en']}',
                            textDirection: TextDirection.ltr,
                            style: AType.bodySmall
                                .copyWith(color: scheme.onSurfaceVariant)),
                    ]),
                  ),
              ],
            ),
          );
        }, 'words'),
      );

  List<Map> get _reciterItems =>
      ((_reciters?['items'] as List?) ?? const []).whereType<Map>().toList();

  int? get _effectiveReciter {
    final ids = [for (final r in _reciterItems) r['id'] as int?];
    if (_reciter != null && ids.contains(_reciter)) return _reciter;
    final d = _qf?['reciter_id'] ?? _reciters?['default_id'];
    return d is int && ids.contains(d) ? d : (ids.isEmpty ? null : ids.first);
  }

  Widget _audioBlock(AppLocalizations t) => _Block(
        key: const Key('qv-audio'),
        title: t.qvLineAudio,
        source: t.qvSourceQf,
        child: _qfState(t, () {
          final url = (_qf!['audio_url'] as String?) ?? '';
          final rec = _effectiveReciter;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (_reciterItems.isNotEmpty)
              DropdownButtonFormField<int>(
                key: Key('qv-reciter-${rec ?? 0}'),
                isExpanded: true,
                initialValue: rec,
                decoration: InputDecoration(labelText: t.qvReciter),
                items: [
                  for (final r in _reciterItems)
                    DropdownMenuItem<int>(
                        value: r['id'] as int,
                        child: Text(
                            '${r['name']}${'${r['style'] ?? ''}'.isEmpty ? '' : ' · ${r['style']}'}',
                            overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  _audio.stop();
                  setState(() => _reciter = v);
                  QvPrefs.setAudio(v, _repeat);
                  _loadAyah();
                },
              ),
            const SizedBox(height: Gap.sm),
            Text(t.qvRepeat, style: AType.labelLarge),
            const SizedBox(height: Gap.xs),
            Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
              for (final n in kQvRepeats)
                ChoiceChip(
                  key: Key('qv-repeat-$n'),
                  label: Text(t.qvRepeatN(ld(context, n))),
                  selected: _repeat == n,
                  onSelected: (_) {
                    setState(() => _repeat = n);
                    QvPrefs.setAudio(null, n);
                  },
                ),
            ]),
            const SizedBox(height: Gap.sm),
            if (url.isEmpty)
              Text(t.qvAudioMissing, key: const Key('qv-audio-missing'))
            else
              Row(children: [
                FilledButton.icon(
                  key: const Key('qv-play'),
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                  icon: Icon(_playing > 0
                      ? Icons.stop_rounded
                      : Icons.play_arrow_rounded),
                  label: Text(_playing > 0 ? t.qvStop : t.qvPlay),
                  onPressed: () => _playing > 0
                      ? _audio.stop()
                      : _audio.play(url, _repeat),
                ),
                const SizedBox(width: Gap.md),
                if (_playing > 0)
                  Expanded(
                    child: Text(
                        t.qvPlaying(ld(context, _playing), ld(context, _repeat)),
                        key: const Key('qv-playing')),
                  ),
              ]),
            if (_audioFailed)
              Padding(
                padding: const EdgeInsets.only(top: Gap.xs),
                child: Text(t.qvAudioFailed,
                    key: const Key('qv-audio-failed'),
                    style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
          ]);
        }, 'audio'),
      );
}

class QvReviewChip extends StatelessWidget {
  final String label;
  const QvReviewChip({super.key, required this.label});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const Key('qv-under-review'),
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xxs),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Text(label,
          style: AType.labelMedium.copyWith(color: scheme.onTertiaryContainer)),
    );
  }
}

/// A titled card with the source line underneath.
class _Block extends StatelessWidget {
  final String title;
  final Widget child;
  final String? source;
  const _Block({super.key, required this.title, required this.child, this.source});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: Gap.md),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Semantics(
          header: true,
          child: Text(title,
              style: AType.labelLarge.copyWith(
                  color: scheme.primary, fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: Gap.xs),
        child,
        if (source != null) ...[
          const SizedBox(height: Gap.sm),
          Text(source!,
              style: AType.labelSmall.copyWith(color: scheme.onSurfaceVariant)),
        ],
      ]),
    );
  }
}
