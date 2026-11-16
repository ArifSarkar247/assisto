/// LANGUAGE PARTNER V2 — going-abroad + other-language TRACKS (lpfinish).
///
/// The Start screen's chips open real courses taught from Bangla (content by
/// lpstage2 / lpstage3, imported with `manage.py lp_seed`):
///   Japan (JLPT N5 + JFT-Basic) · Korea (EPS-TOPIK) · Germany (A1) ·
///   Middle East (work Arabic) · Chinese (HSK 1) · French (A1).
/// Each track: syllabus + exam format, weekly lessons (new words, grammar, the
/// four skills with instant checks) and practice tests in the real public
/// format, marked by the server (/lp/mocks/<id>/mark). Listening is read by
/// the phone's own voice until recorded audio exists. The free weekly section
/// / "open with credits" gate is the same as IELTS (lpGateSheet). Every score
/// is a practice score, never an official result. No ads inside a test.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import '../../ds/ds.dart';
import 'package:provider/provider.dart';

import '../../api.dart' show ApiException;
import '../../l10n/app_localizations.dart';
import '../../services/error_kind.dart' show honestFailText;
import '../../state.dart';
import '../../theme.dart';
import '../../voice/va_native.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/local_counter.dart';
import '../../widgets/local_digits.dart';
import '../../widgets/skeleton.dart';
import '../language_pack_screen.dart' show speakPackLine;
import 'lp_data.dart';
import 'lp_life.dart' show LpLifeListScreen;
import 'lp_mock.dart' show lpGateSheet;
import 'lp_ui.dart';

/// One chip on the Start screen = one course (one job, one chip).
class LpTrackChip {
  final String id;
  final List<String> tracks;
  final IconData icon;
  const LpTrackChip(this.id, this.tracks, this.icon);
}

const kLpAbroadChips = [
  LpTrackChip('ja', ['jlpt_n5', 'jft_basic'], Icons.work_rounded),
  LpTrackChip('ko', ['eps_topik'], Icons.factory_rounded),
  LpTrackChip('de', ['de_a1'], Icons.flight_takeoff_rounded),
  LpTrackChip('ar', ['ar_work'], Icons.construction_rounded),
];
const kLpOtherChips = [
  LpTrackChip('zh', ['hsk1'], Icons.translate_rounded),
  LpTrackChip('fr', ['fr_a1'], Icons.translate_rounded),
];

/// Phone-voice locale of a track's language.
String lpTrackLocale(String lang) => switch (lang) {
      'ja' => 'ja-JP',
      'ko' => 'ko-KR',
      'de' => 'de-DE',
      'zh' => 'zh-CN',
      'fr' => 'fr-FR',
      'ar' => 'ar-SA',
      _ => 'en-GB',
    };

String _loc2(BuildContext context, Object? m) {
  if (m is Map) {
    final bn = '${m['bn'] ?? ''}';
    if (lpBn(context) && bn.trim().isNotEmpty) return bn;
    return '${m['en'] ?? bn}';
  }
  return m == null ? '' : '$m';
}

Map<String, dynamic> _map(Object? v) => v is Map ? v.cast<String, dynamic>() : const {};

/// Tests: replaces the phone voice.
@visibleForTesting
Future<void> Function(String text, String lang)? debugLpTtsSpeak;

/// Plays text with the phone's own voice: {lang, lines:[..], repeat}. Long
/// scripts are split into pieces under the engine's input limit. In exam mode
/// ([replay] false) it can be played `repeat` times, like the real test.
class LpTtsPlayer extends StatefulWidget {
  final Map<String, dynamic> tts;
  final bool replay;
  const LpTtsPlayer({super.key, required this.tts, this.replay = true});
  @override
  State<LpTtsPlayer> createState() => _LpTtsPlayerState();
}

class _LpTtsPlayerState extends State<LpTtsPlayer> {
  static const _maxChars = 3500;
  int _plays = 0;
  int _piece = 0;
  bool _on = false;

  List<String> get _pieces {
    final out = <String>[];
    var cur = StringBuffer();
    for (final l in lpStrs(widget.tts['lines'])) {
      if (cur.length + l.length + 1 > _maxChars && cur.isNotEmpty) {
        out.add(cur.toString());
        cur = StringBuffer();
      }
      if (cur.isNotEmpty) cur.write('\n');
      cur.write(l);
    }
    if (cur.isNotEmpty) out.add(cur.toString());
    return out;
  }

  int get _allowed => ((widget.tts['repeat'] as num?)?.toInt() ?? 1).clamp(1, 3);

  @override
  void dispose() {
    if (_on) unawaited(_stop());
    super.dispose();
  }

  Future<void> _stop() async {
    try {
      await VaNative.stopSpeaking();
    } catch (_) {
      // nothing is playing
    }
  }

  Future<void> _play() async {
    final pieces = _pieces;
    if (pieces.isEmpty) return;
    final lang = '${widget.tts['lang'] ?? 'en-GB'}';
    if (_on) {
      await _stop();
      if (mounted) setState(() => _on = false);
      return;
    }
    setState(() => _on = true);
    final text = pieces[_piece.clamp(0, pieces.length - 1)];
    if (debugLpTtsSpeak != null) {
      await debugLpTtsSpeak!(text, lang);
    } else {
      await speakPackLine(context, text, lang);
    }
    if (!mounted) return;
    setState(() {
      if (_piece + 1 < pieces.length) {
        _piece++;
      } else {
        _piece = 0;
        _plays++;
      }
      _on = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final pieces = _pieces;
    final locked = !widget.replay && _plays >= _allowed;
    final multi = pieces.length > 1;
    return Card(
      color: scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(children: [
          IconButton.filled(
            key: const Key('lp2-tts-play'),
            tooltip: _on ? tr.lp2TrackStop : tr.lp2PlayAudio,
            constraints: const BoxConstraints(minWidth: 56, minHeight: 56),
            onPressed: locked || pieces.isEmpty ? null : _play,
            icon: Icon(_on ? Icons.stop_rounded : Icons.play_arrow_rounded),
          ),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                  locked
                      ? tr.lp2AudioPlayedOnce
                      : multi
                          ? tr.lp2TrackPlayPart(ld(context, _piece + 1), ld(context, pieces.length))
                          : tr.lp2PlayAudio,
                  style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w600)),
              Text(tr.lp2TrackPhoneVoice, style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
              if (!widget.replay && !locked)
                Text(tr.lp2TrackPlaysLeft(ld(context, _allowed - _plays)),
                    style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ============================================================ track home

class LpTrackScreen extends StatefulWidget {
  final String title;
  final List<String> tracks;
  const LpTrackScreen({super.key, required this.title, required this.tracks});
  @override
  State<LpTrackScreen> createState() => _LpTrackScreenState();
}

class _LpTrackScreenState extends State<LpTrackScreen> {
  late String _track = widget.tracks.first;
  bool _loading = true;
  Object? _fail;
  Map<String, dynamic> _syl = const {};
  List<Map<String, dynamic>> _lessons = const [];
  List<Map<String, dynamic>> _tests = const [];
  Set<String> _done = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _fail = null;
    });
    final api = context.read<AppState>().api;
    try {
      final r = await Future.wait([
        api.getJson('/lp/content/syllabus?track=$_track'),
        api.getJson('/lp/content/lesson?track=$_track'),
        api.getJson('/lp/mocks?kind=$_track'),
      ]);
      final syl = lpList(r[0]['items']);
      _syl = syl.isEmpty ? const {} : syl.first;
      _lessons = lpList(r[1]['items']);
      _tests = lpList(r[2]['mocks']);
    } catch (e) {
      _fail = e;
    }
    try {
      final days = await api.listItems(kLpDays);
      _done = {
        for (final d in days)
          if ('${d['kind']}'.startsWith('lesson:')) '${d['kind']}'.substring(7)
      };
    } catch (_) { // best-effort: lesson ticks only; the course itself loaded above
    }
    if (mounted) setState(() => _loading = false);
  }

  String _sectionName(String id) {
    for (final s in lpList(_map(_syl['exam_format'])['sections'])) {
      if ('${s['id']}' == id) return _loc2(context, s['title']);
    }
    return id;
  }

  Future<void> _open(Widget w) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
    if (mounted) unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final weeks = lpList(_syl['weeks']).where((w) => lpStrs(w['lessons']).isNotEmpty).toList();
    final byId = {for (final l in _lessons) '${l['id']}': l};
    final fmt = _map(_syl['exam_format']);
    final probashi = _map(_syl['probashi']);
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl)),
          children: [
            if (widget.tracks.length > 1) ...[
              SegmentedButton<String>(
                segments: [
                  for (final t in widget.tracks)
                    ButtonSegment(value: t, label: Text(t == 'jft_basic' ? 'JFT-Basic' : 'JLPT N5')),
                ],
                selected: {_track},
                onSelectionChanged: (s) {
                  _track = s.first;
                  _load();
                },
              ),
              const SizedBox(height: Gap.md),
            ],
            if (_loading)
              const SkeletonList()
            else if (_fail != null)
              StateMessage(
                icon: Icons.cloud_off_rounded,
                tint: scheme.error,
                title: tr.loadFailed,
                message: honestFailText(tr, _fail, otherwise: tr.lp2TrackLoadFail),
                action: FilledButton.tonalIcon(
                    onPressed: _load, icon: const Icon(Icons.refresh_rounded), label: Text(tr.retry)),
              )
            else if (_lessons.isEmpty && _tests.isEmpty)
              StateMessage(
                icon: Icons.school_rounded,
                title: tr.lp2TrackEmptyTitle,
                message: tr.lp2TrackEmptyBody,
                action: FilledButton.icon(
                  onPressed: () => _open(const LpLifeListScreen()),
                  icon: const Icon(Icons.record_voice_over_rounded),
                  label: Text(tr.lp2LifeStart),
                ),
              )
            else ...[
              if (_syl.isNotEmpty)
                DsCard(key: const Key('lp2-track-syllabus'),
                  padding: const EdgeInsets.all(Gap.lg),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Text(_loc2(context, _syl['title']),
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: Gap.sm),
                      Text('${_syl['summary_bn'] ?? ''}', style: AType.bodyMedium.copyWith(height: 1.5)),
                      if ('${_syl['who_for_bn'] ?? ''}'.isNotEmpty) ...[
                        const SizedBox(height: Gap.sm),
                        Text('${_syl['who_for_bn']}', style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant, height: 1.5)),
                      ],
                      if (lpStrs(_syl['can_do_bn']).isNotEmpty) ...[
                        const SizedBox(height: Gap.md),
                        Text(tr.lp2TrackCanDo, style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700)),
                        for (final c in lpStrs(_syl['can_do_bn']))
                          Padding(
                            padding: const EdgeInsets.only(top: Gap.xs),
                            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Icon(Icons.check_circle_rounded, size: 18, color: Brand.onTint(context, Brand.success)),
                              const SizedBox(width: Gap.sm),
                              Expanded(child: Text(c, style: AType.bodyMedium.copyWith(height: 1.4))),
                            ]),
                          ),
                      ],
                    ]),
                ),
              if (lpList(fmt['sections']).isNotEmpty)
                DsCard(
                  padding: EdgeInsets.zero,
                  child: ExpansionTile(
                    leading: const Icon(Icons.fact_check_rounded),
                    title: Text(tr.lp2TrackExamFormat),
                    childrenPadding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.md),
                    children: [
                      for (final s in lpList(fmt['sections']))
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(_loc2(context, s['title'])),
                          subtitle: Text([
                            if (s['minutes'] != null) tr.lp2TrackMinutes(ld(context, s['minutes'])),
                            if (s['questions'] != null) tr.lp2TrackQuestions(ld(context, s['questions'])),
                          ].join(' · ')),
                        ),
                      if ('${fmt['scoring_bn'] ?? ''}'.isNotEmpty)
                        Text('${fmt['scoring_bn']}', style: AType.bodyMedium.copyWith(height: 1.5)),
                      if ('${fmt['official_info_bn'] ?? ''}'.isNotEmpty) ...[
                        const SizedBox(height: Gap.sm),
                        Text('${fmt['official_info_bn']}',
                            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.5)),
                      ],
                    ],
                  ),
                ),
              const SizedBox(height: Gap.md),
              Text(tr.lp2TrackLessons,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.sm),
              if (weeks.isEmpty)
                for (final l in _lessons) _lessonTile(l)
              else
                for (final w in weeks)
                  DsCard(
                    padding: EdgeInsets.zero,
                    child: ExpansionTile(
                      key: PageStorageKey('wk-$_track-${w['week']}'),
                      initiallyExpanded: w == weeks.first,
                      title: Text(tr.lp2TrackWeek(ld(context, w['week'] ?? 1)),
                          style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700)),
                      subtitle: Text('${w['goal_bn'] ?? ''}', style: AType.bodyMedium.copyWith(height: 1.4)),
                      children: [
                        for (final id in lpStrs(w['lessons']))
                          if (byId[id] != null) _lessonTile(byId[id]!),
                      ],
                    ),
                  ),
              const SizedBox(height: Gap.lg),
              Text(tr.lp2TrackTests,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.sm),
              for (final m in _tests)
                DsCard(key: ValueKey('lp2-track-test-${m['id']}'),
                  padding: const EdgeInsets.all(Gap.md),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Row(children: [
                        Expanded(
                          child: Text(lpLoc(context, m, 'title'),
                              style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700, height: 1.3)),
                        ),
                        if (m['beta'] == true) LpTag(text: tr.lp2Beta, color: Brand.warning),
                      ]),
                      const SizedBox(height: Gap.sm),
                      Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
                        for (final s in lpStrs(m['sections']))
                          ActionChip(
                            key: ValueKey('lp2-track-sec-${m['id']}-$s'),
                            avatar: const Icon(Icons.timer_rounded, size: 18),
                            label: Text(_sectionName(s)),
                            materialTapTargetSize: MaterialTapTargetSize.padded,
                            onPressed: () => _open(LpTrackTestRunner(
                                mock: m, section: s, sectionTitle: _sectionName(s))),
                          ),
                      ]),
                    ]),
                ),
              if ('${probashi['note_bn'] ?? ''}'.isNotEmpty)
                Card(
                  color: scheme.secondaryContainer,
                  child: ListTile(
                    leading: Icon(Icons.public_rounded, color: scheme.onSecondaryContainer),
                    title: Text(tr.lp2TrackProbashi,
                        style: AType.bodyMedium.copyWith(color: scheme.onSecondaryContainer, fontWeight: FontWeight.w700)),
                    subtitle: Text('${probashi['note_bn']}',
                        style: AType.bodyMedium.copyWith(color: scheme.onSecondaryContainer, height: 1.4)),
                  ),
                ),
              LpPracticeFooter(text: _loc2(context, _syl['practice_label']).isEmpty ? null : _loc2(context, _syl['practice_label'])),
            ],
          ],
        ),
      ),
    );
  }

  Widget _lessonTile(Map<String, dynamic> l) {
    final tr = AppLocalizations.of(context);
    final id = '${l['id']}';
    final done = _done.contains(id);
    return ListTile(
      key: ValueKey('lp2-lesson-$id'),
      minVerticalPadding: Gap.md,
      leading: CircleAvatar(
        child: done ? const Icon(Icons.check_rounded) : Text(ld(context, l['day'] ?? '•')),
      ),
      title: Text(_loc2(context, l['title'])),
      subtitle: Text(tr.lp2TrackMinutes(ld(context, l['minutes'] ?? 20))),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => _open(LpLessonScreen(lesson: l)),
    );
  }
}

// ============================================================ lesson

class LpLessonScreen extends StatefulWidget {
  final Map<String, dynamic> lesson;
  const LpLessonScreen({super.key, required this.lesson});
  @override
  State<LpLessonScreen> createState() => _LpLessonScreenState();
}

class _LpLessonScreenState extends State<LpLessonScreen> {
  final DateTime _start = DateTime.now();
  final Map<String, String> _picked = {};
  final Set<String> _checked = {};
  final Set<String> _shown = {};
  final Map<String, TextEditingController> _text = {};

  Map<String, dynamic> get l => widget.lesson;
  String get _lang => lpTrackLocale('${l['lang'] ?? ''}');

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _say(String text) => IconButton(
        tooltip: AppLocalizations.of(context).lp2Listen,
        constraints: const BoxConstraints(minWidth: kMinTap, minHeight: kMinTap),
        icon: const Icon(Icons.volume_up_rounded),
        onPressed: () => debugLpTtsSpeak != null ? debugLpTtsSpeak!(text, _lang) : speakPackLine(context, text, _lang),
      );

  Widget _targetBlock(Map<String, dynamic> m, {bool big = false}) {
    final scheme = Theme.of(context).colorScheme;
    final target = '${m['target'] ?? ''}';
    final reading = [m['kana'], m['roman'], m['bn_pron']]
        .where((x) => x != null && '$x'.isNotEmpty && '$x' != target)
        .map((x) => '$x')
        .join(' · ');
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(target,
              style: big
                  ? Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)
                  : AType.bodyMedium.copyWith(fontWeight: FontWeight.w600, height: 1.4)),
          if (reading.isNotEmpty) Text(reading, style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant, height: 1.4)),
          if ('${m['bn'] ?? ''}'.isNotEmpty) Text('${m['bn']}', style: AType.bodyMedium.copyWith(height: 1.4)),
        ]),
      ),
      if (target.isNotEmpty) _say(target),
    ]);
  }

  Widget _choice(Map<String, dynamic> q) {
    final tr = AppLocalizations.of(context);
    final id = '${q['id']}';
    final opts = lpStrs(q['options']);
    final roman = lpStrs(q['options_roman']);
    final checked = _checked.contains(id);
    final right = '${q['answer'] ?? ''}';
    final mine = _picked[id];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
        for (final (i, o) in opts.indexed)
          ChoiceChip(
            label: Text('${String.fromCharCode(65 + i)}. $o${i < roman.length && roman[i].isNotEmpty ? ' (${roman[i]})' : ''}'),
            selected: mine == String.fromCharCode(65 + i),
            materialTapTargetSize: MaterialTapTargetSize.padded,
            onSelected: checked ? null : (_) => setState(() => _picked[id] = String.fromCharCode(65 + i)),
          ),
      ]),
      const SizedBox(height: Gap.sm),
      if (!checked)
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton.tonal(
            key: ValueKey('lp2-check-$id'),
            style: FilledButton.styleFrom(minimumSize: const Size(kMinTap, kMinTap)),
            onPressed: mine == null ? null : () => setState(() => _checked.add(id)),
            child: Text(tr.lp2TrackCheck),
          ),
        )
      else
        Card(
          color: (mine == right ? Brand.success : Brand.warning).withValues(alpha: 0.15),
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(mine == right ? tr.lp2Right : tr.lp2TrackKey(right),
                  style: AType.bodyMedium.copyWith(
                      fontWeight: FontWeight.w700,
                      color: Brand.onTint(context, mine == right ? Brand.success : Brand.danger))),
              if ('${q['explain_bn'] ?? ''}'.isNotEmpty) Text('${q['explain_bn']}', style: AType.bodyMedium.copyWith(height: 1.4)),
            ]),
          ),
        ),
    ]);
  }

  Widget _model(String id, Map<String, dynamic> model, {bool typed = true}) {
    final tr = AppLocalizations.of(context);
    final c = _text.putIfAbsent(id, () => TextEditingController());
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (typed)
        TextField(
          controller: c,
          maxLength: 400,
          buildCounter: localCounter,
          minLines: 2,
          maxLines: 5,
          decoration: InputDecoration(border: const OutlineInputBorder(), hintText: tr.lp2TrackWriteHere),
        ),
      if (_shown.contains(id))
        Card(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(tr.lp2TrackModel, style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700)),
              _targetBlock(model),
              Text(tr.lp2TrackSelfCheck, style: AType.bodySmall),
            ]),
          ),
        )
      else
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            key: ValueKey('lp2-model-$id'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(kMinTap, kMinTap)),
            onPressed: () => setState(() => _shown.add(id)),
            icon: const Icon(Icons.visibility_rounded),
            label: Text(tr.lp2TrackShowModel),
          ),
        ),
    ]);
  }

  Map<String, dynamic> _ttsOf(Map<String, dynamic> q) {
    final t = _map(q['tts']);
    if (t.isNotEmpty) return t;
    final s = _map(q['script']);
    return {
      'lang': _lang,
      'lines': [for (final x in lpList(s['turns'])) if ('${x['text'] ?? ''}'.isNotEmpty) '${x['text']}'],
      'repeat': s['repeat'] ?? 1,
    };
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final pr = _map(l['practice']);
    Widget h(String t) => Padding(
          padding: const EdgeInsets.only(top: Gap.lg, bottom: Gap.sm),
          child: Text(t, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        );
    return Scaffold(
      appBar: AppBar(title: Text(_loc2(context, l['title']))),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl)),
        children: [
          if ('${l['goal_bn'] ?? ''}'.isNotEmpty)
            DsCard(
              padding: EdgeInsets.zero,
              child: ListTile(
                leading: const Icon(Icons.flag_rounded),
                title: Text('${l['goal_bn']}', style: AType.bodyMedium.copyWith(height: 1.4)),
              ),
            ),
          h(tr.lp2TrackVocab),
          for (final v in lpList(l['vocab']))
            DsCard(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  _targetBlock(v, big: true),
                  if (_map(v['example']).isNotEmpty) ...[
                    const Divider(),
                    _targetBlock(_map(v['example'])),
                  ],
                ]),
            ),
          h(tr.lp2TrackGrammar),
          for (final g in lpList(l['grammar']))
            DsCard(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text('${g['pattern'] ?? ''}', style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: Gap.xs),
                  Text('${g['explain_bn'] ?? ''}', style: AType.bodyMedium.copyWith(height: 1.5)),
                  for (final e in lpList(g['examples'])) ...[const Divider(), _targetBlock(e)],
                ]),
            ),
          h(tr.lp2TrackPractice),
          for (final q in lpList(pr['listening']))
            DsCard(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text(lpSectionName(tr, 'listening'), style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700)),
                  LpTtsPlayer(tts: _ttsOf(q)),
                  Text('${q['prompt_bn'] ?? ''}', style: AType.bodyMedium.copyWith(height: 1.4)),
                  const SizedBox(height: Gap.sm),
                  _choice(q),
                ]),
            ),
          for (final q in lpList(pr['reading']))
            DsCard(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text(lpSectionName(tr, 'reading'), style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: Gap.xs),
                  SelectableText('${q['passage'] ?? ''}', style: AType.bodyMedium.copyWith(height: 1.6)),
                  if ('${q['passage_roman'] ?? ''}'.isNotEmpty)
                    Text('${q['passage_roman']}', style: AType.bodySmall),
                  const SizedBox(height: Gap.sm),
                  Text('${q['prompt_bn'] ?? ''}', style: AType.bodyMedium.copyWith(height: 1.4)),
                  const SizedBox(height: Gap.sm),
                  _choice(q),
                ]),
            ),
          for (final q in lpList(pr['writing']))
            DsCard(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text(lpSectionName(tr, 'writing'), style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700)),
                  Text('${q['prompt_bn'] ?? ''}', style: AType.bodyMedium.copyWith(height: 1.4)),
                  const SizedBox(height: Gap.sm),
                  _model('${q['id']}', _map(q['model'])),
                ]),
            ),
          for (final q in lpList(pr['speaking']))
            DsCard(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text(lpSectionName(tr, 'speaking'), style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700)),
                  Text('${q['prompt_bn'] ?? ''}', style: AType.bodyMedium.copyWith(height: 1.4)),
                  Text(tr.lp2TrackSayAloud, style: AType.bodySmall),
                  const SizedBox(height: Gap.sm),
                  _model('${q['id']}', _map(q['model']), typed: false),
                ]),
            ),
          const SizedBox(height: Gap.lg),
          FilledButton.icon(
            key: const Key('lp2-lesson-done'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: () async {
              final api = context.read<AppState>().api;
              final mins = DateTime.now().difference(_start).inMinutes.clamp(1, 90);
              await lpLogPractice(api, 'lesson:${l['id']}', mins);
              if (context.mounted) {
                lpToast(context, tr.lp2TrackDoneToast);
                Navigator.of(context).pop();
              }
            },
            icon: const Icon(Icons.done_all_rounded),
            label: Text(tr.lp2TrackDone),
          ),
          LpPracticeFooter(text: _loc2(context, l['practice_label']).isEmpty ? null : _loc2(context, l['practice_label'])),
        ],
      ),
    );
  }
}

// ============================================================ practice test

class LpTrackTestRunner extends StatefulWidget {
  final Map<String, dynamic> mock;
  final String section;
  final String sectionTitle;
  const LpTrackTestRunner({super.key, required this.mock, required this.section, required this.sectionTitle});
  @override
  State<LpTrackTestRunner> createState() => _LpTrackTestRunnerState();
}

class _LpTrackTestRunnerState extends State<LpTrackTestRunner> {
  Map<String, dynamic>? _sec;
  Map<String, dynamic> _scoring = const {};
  String _lang = '';
  bool _loading = true, _marking = false;
  Object? _fail;
  final Map<int, String> _ans = {};
  final Map<String, TextEditingController> _text = {};
  Map<String, dynamic>? _result;
  bool _selfDone = false;
  final DateTime _start = DateTime.now();

  String get _id => '${widget.mock['id']}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load({bool pay = false}) async {
    setState(() {
      _loading = true;
      _fail = null;
    });
    try {
      final r = await context
          .read<AppState>()
          .api
          .getJson('/lp/mocks/$_id?section=${widget.section}${pay ? '&pay=credits' : ''}');
      final secs = lpList(r['sections']);
      _sec = secs.isEmpty ? null : secs.first;
      _scoring = _map(r['scoring']);
      _lang = lpTrackLocale('${r['lang'] ?? ''}');
    } on ApiException catch (e) {
      if (e.reason == 'premium' || e.reason == 'week_used' || e.reason == 'credits') {
        if (!mounted) return;
        final payNow = await lpGateSheet(context, e.reason == 'credits' ? 'week_used' : e.reason!,
            nextFreeAt: '${e.body?['next_free_at'] ?? ''}',
            unlockCredits: pay || e.reason == 'credits' ? null : (e.body?['unlock_credits'] as num?)?.toInt());
        if (!mounted) return;
        if (payNow) return _load(pay: true);
        Navigator.of(context).pop();
        return;
      }
      _fail = e;
    } catch (e) {
      _fail = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  List<Map<String, dynamic>> get _questions =>
      [for (final p in lpList(_sec?['parts'])) ...lpList(p['questions'])];

  Future<void> _submit() async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    if (_questions.isEmpty) {
      setState(() => _selfDone = true);
      unawaited(lpLogPractice(api, 'track', DateTime.now().difference(_start).inMinutes.clamp(1, 90)));
      return;
    }
    setState(() => _marking = true);
    try {
      final r = await api.postJson('/lp/mocks/$_id/mark', {
        'section': widget.section,
        'answers': {for (final e in _ans.entries) '${e.key}': e.value},
      });
      unawaited(lpLogPractice(api, 'track', DateTime.now().difference(_start).inMinutes.clamp(1, 90)));
      if (mounted) setState(() => _result = r);
    } catch (e) {
      if (mounted) lpToast(context, honestFailText(tr, e, otherwise: tr.lp2MarkFail));
    }
    if (mounted) setState(() => _marking = false);
  }

  Widget _question(Map<String, dynamic> q) {
    final scheme = Theme.of(context).colorScheme;
    final n = (q['n'] as num?)?.toInt() ?? 0;
    final opts = lpStrs(q['options']);
    final roman = lpStrs(q['options_roman']);
    final item = _result == null
        ? null
        : lpList(_result!['items']).firstWhere((x) => '${x['n']}' == '$n', orElse: () => const {});
    final tts = _map(q['tts']);
    return Padding(
      key: ValueKey('tq$n'),
      padding: const EdgeInsets.only(bottom: Gap.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (tts.isNotEmpty && _result == null) LpTtsPlayer(tts: tts, replay: false),
        if ('${q['passage'] ?? ''}'.isNotEmpty) ...[
          SelectableText('${q['passage']}', style: AType.bodyMedium.copyWith(height: 1.6)),
          if ('${q['passage_roman'] ?? ''}'.isNotEmpty) Text('${q['passage_roman']}', style: AType.bodySmall),
          const SizedBox(height: Gap.xs),
        ],
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          CircleAvatar(radius: 14, child: Text(ld(context, n), style: AType.bodySmall)),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${q['prompt'] ?? ''}', style: AType.bodyMedium.copyWith(height: 1.4)),
              if ('${q['prompt_roman'] ?? ''}'.isNotEmpty)
                Text('${q['prompt_roman']}', style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
            ]),
          ),
        ]),
        const SizedBox(height: Gap.xs),
        Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
          for (final (i, o) in opts.indexed)
            ChoiceChip(
              label: Text('${String.fromCharCode(65 + i)}. $o${i < roman.length && roman[i].isNotEmpty ? ' (${roman[i]})' : ''}'),
              selected: _ans[n] == String.fromCharCode(65 + i),
              materialTapTargetSize: MaterialTapTargetSize.padded,
              onSelected: _result != null ? null : (_) => setState(() => _ans[n] = String.fromCharCode(65 + i)),
            ),
        ]),
        if (item != null && item.isNotEmpty)
          Card(
            color: (item['correct'] == true ? Brand.success : Brand.warning).withValues(alpha: 0.15),
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(
                    item['correct'] == true
                        ? AppLocalizations.of(context).lp2Right
                        : AppLocalizations.of(context).lp2TrackKey('${item['key'] ?? ''}'),
                    style: AType.bodyMedium.copyWith(
                        fontWeight: FontWeight.w700,
                        color: Brand.onTint(context, item['correct'] == true ? Brand.success : Brand.danger))),
                if ('${item['explain_bn'] ?? ''}'.isNotEmpty)
                  Text('${item['explain_bn']}', style: AType.bodyMedium.copyWith(height: 1.4)),
              ]),
            ),
          ),
      ]),
    );
  }

  Widget _task(Map<String, dynamic> t) {
    final tr = AppLocalizations.of(context);
    final id = '${t['id']}';
    final c = _text.putIfAbsent(id, () => TextEditingController());
    final model = _map(t['model']);
    final prompt = _map(t['prompt']);
    return DsCard(key: ValueKey('tt$id'),
      padding: const EdgeInsets.all(Gap.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (prompt.isEmpty)
            Text('${t['prompt'] ?? ''}', style: AType.bodyMedium.copyWith(height: 1.4))
          else ...[
            if ('${prompt['bn'] ?? ''}'.isNotEmpty) Text('${prompt['bn']}', style: AType.bodyMedium.copyWith(height: 1.4)),
            if ('${prompt['target'] ?? ''}'.isNotEmpty)
              Text('${prompt['target']}', style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w600, height: 1.4)),
          ],
          const SizedBox(height: Gap.sm),
          TextField(
            controller: c,
            maxLength: 600,
            buildCounter: localCounter,
            minLines: 3,
            maxLines: 8,
            enabled: !_selfDone,
            decoration: InputDecoration(border: const OutlineInputBorder(), hintText: tr.lp2TrackWriteHere),
          ),
          if (_selfDone && model.isNotEmpty) ...[
            Text(tr.lp2TrackModel, style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700)),
            Text('${model['target'] ?? ''}', style: AType.bodyMedium.copyWith(height: 1.5)),
            if ('${model['bn'] ?? ''}'.isNotEmpty) Text('${model['bn']}', style: AType.bodySmall),
            IconButton(
              tooltip: tr.lp2Listen,
              constraints: const BoxConstraints(minWidth: kMinTap, minHeight: kMinTap),
              icon: const Icon(Icons.volume_up_rounded),
              onPressed: () => debugLpTtsSpeak != null
                  ? debugLpTtsSpeak!('${model['target']}', _lang)
                  : speakPackLine(context, '${model['target']}', _lang),
            ),
          ],
        ]),
    );
  }

  Future<bool> _confirmLeave() async {
    if (_result != null || _selfDone) return true;
    final tr = AppLocalizations.of(context);
    var leave = false;
    await showAppSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr.lp2LeaveTitle, style: Theme.of(ctx).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.sm),
          Text(tr.lp2LeaveBody),
          const SizedBox(height: Gap.lg),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(kMinTap)),
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(tr.lp2KeepGoing),
          ),
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(kMinTap)),
            onPressed: () {
              leave = true;
              Navigator.of(ctx).pop();
            },
            child: Text(tr.lp2LeaveTest),
          ),
        ]),
      ),
    );
    return leave;
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final title = widget.sectionTitle;
    if (_loading) return Scaffold(appBar: AppBar(title: Text(title)), body: const SkeletonList());
    if (_fail != null || _sec == null) {
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: StateMessage(
          icon: Icons.cloud_off_rounded,
          tint: scheme.error,
          title: tr.loadFailed,
          message: honestFailText(tr, _fail, otherwise: tr.lp2MocksFail),
          action: FilledButton.tonalIcon(onPressed: _load, icon: const Icon(Icons.refresh_rounded), label: Text(tr.retry)),
        ),
      );
    }
    final done = _result != null || _selfDone;
    final mins = (_sec!['minutes'] as num?)?.toInt() ?? 30;
    final r = _result;
    return PopScope(
      canPop: done,
      onPopInvokedWithResult: (did, _) async {
        if (did) return;
        if (await _confirmLeave() && context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title),
            Text(lpLoc(context, widget.mock, 'title'), style: AType.bodySmall),
          ]),
          actions: [
            if (!done)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                child: Center(
                  child: LpTimer(
                    key: ValueKey('ttimer-${widget.section}'),
                    seconds: mins * 60,
                    onDone: () {
                      lpToast(context, tr.lp2TimeUp);
                      _submit();
                    },
                  ),
                ),
              ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl),
          children: [
            if (r != null)
              Card(
                key: const Key('lp2-track-result'),
                color: scheme.primaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(Gap.lg),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text(tr.lp2TrackRight(ld(context, r['raw'] ?? 0), ld(context, r['total'] ?? 0)),
                        style: Theme.of(context)
                            .textTheme
                            .headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w800, color: scheme.onPrimaryContainer)),
                    if (r['score'] != null && r['max'] != null && _scoring['per_question'] != null)
                      Text(tr.lp2TrackScore(ld(context, r['score']), ld(context, r['max'])),
                          style: AType.bodyMedium.copyWith(color: scheme.onPrimaryContainer)),
                    if ('${_scoring['pass_hint_bn'] ?? ''}'.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: Gap.sm),
                        child: Text('${_scoring['pass_hint_bn']}',
                            style: AType.bodySmall.copyWith(color: scheme.onPrimaryContainer, height: 1.4)),
                      ),
                  ]),
                ),
              ),
            for (final p in lpList(_sec!['parts'])) ...[
              if (_map(p['instructions']).isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: Gap.sm),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text('${_map(p['instructions'])['bn'] ?? ''}',
                        style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700, height: 1.4)),
                    if ('${_map(p['instructions'])['target'] ?? ''}'.isNotEmpty)
                      Text('${_map(p['instructions'])['target']}', style: AType.bodySmall),
                  ]),
                ),
              if (_map(p['tts']).isNotEmpty && _result == null) LpTtsPlayer(tts: _map(p['tts']), replay: false),
              if ('${p['passage'] ?? ''}'.isNotEmpty) ...[
                SelectableText('${p['passage']}', style: AType.bodyMedium.copyWith(height: 1.6)),
                if ('${p['passage_roman'] ?? ''}'.isNotEmpty) Text('${p['passage_roman']}', style: AType.bodySmall),
                const SizedBox(height: Gap.sm),
              ],
              for (final q in lpList(p['questions'])) _question(q),
            ],
            for (final t in lpList(_sec!['tasks'])) _task(t),
            if (_selfDone)
              DsCard(key: const Key('lp2-track-self'),
                padding: EdgeInsets.zero,
                child: ListTile(leading: const Icon(Icons.rate_review_rounded), title: Text(tr.lp2TrackSelfCheck)),
              ),
            LpPracticeFooter(text: '${_scoring['note_bn'] ?? ''}'.isEmpty || !lpBn(context) ? null : '${_scoring['note_bn']}'),
          ],
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.md),
            child: done
                ? FilledButton.icon(
                    key: const Key('lp2-track-close'),
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.check_rounded),
                    label: Text(tr.lp2Close),
                  )
                : FilledButton.icon(
                    key: const Key('lp2-track-submit'),
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                    onPressed: _marking ? null : _submit,
                    icon: _marking
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.done_all_rounded),
                    label: Text(_questions.isEmpty ? tr.lp2TrackShowModel : tr.lp2TrackSubmit),
                  ),
          ),
        ),
      ),
    );
  }
}
