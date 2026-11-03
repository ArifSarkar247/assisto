import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../services/error_kind.dart' show honestFailText;
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart' show withNavBarInset;
import '../widgets/local_counter.dart';
import '../widgets/local_digits.dart';
import '../widgets/skeleton.dart';
import '../widgets/voice_input.dart';
import 'ielts_engine.dart';

/// p2lang — IELTS PRACTICE inside Language Partner (flag `language_packs`).
///
/// Four modules + pronunciation + vocabulary, all from GET /ielts/content
/// (original Assisto content — nothing copied from Cambridge / IDP / British
/// Council; Listening links to the official FREE practice pages because we
/// hold no licensed audio):
///   * Pronunciation — read a sentence, the phone's speech-to-text hears it,
///     [alignWords] marks each word clear / heard differently / missed, OFFLINE.
///   * Speaking Part 1/2/3 — answer by voice (or type), key-free checklist
///     (pace, fillers, variety) + optional AI band estimate (credits).
///   * Writing Task 1 (letter) / Task 2 (essay) — checklist + optional AI.
///   * Reading — original passages, True/False/Not Given + MCQ, explanations.
///   * Vocabulary — academic words, Leitner review (ielts/vocab).
/// Every score is labelled a PRACTICE ESTIMATE, never an official band.
/// Practice days (ielts/practice) drive the daily streak.
/// ZERO Bangla literals: Bangla content comes from the server.
class IeltsScreen extends StatefulWidget {
  const IeltsScreen({super.key});
  @override
  State<IeltsScreen> createState() => _IeltsScreenState();
}

const String _practicePath = 'ielts/practice';
const String _vocabPath = 'ielts/vocab';

bool _isBn(BuildContext c) => Localizations.localeOf(c).languageCode == 'bn';

/// Pick the bn / en field of a server row by the app language.
String _loc(BuildContext c, Map m, String bnKey, String enKey) =>
    '${(_isBn(c) ? m[bnKey] : m[enKey]) ?? ''}';

List<Map<String, dynamic>> _list(Object? v) =>
    v is List ? v.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList() : const [];

/// Shared state handed to every module page.
class _Ielts {
  final Map<String, dynamic> content;
  final Future<void> Function(String kind, int score) logPractice;
  _Ielts(this.content, this.logPractice);
  bool get aiReady => content['ai_ready'] == true;
  String estimate(BuildContext c) =>
      _loc(c, (content['estimate_label'] as Map?) ?? const {}, 'bn', 'en');
}

class _IeltsScreenState extends State<IeltsScreen> {
  Map<String, dynamic>? _content;
  List<Map<String, dynamic>> _practice = [];
  bool _loading = true;
  Object? _fail;

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
      _content = await api.getJson('/ielts/content');
      try {
        _practice = await api.listItems(_practicePath);
      } catch (_) {
        _practice = []; // the streak is a bonus; never block practice on it
      }
    } catch (e) {
      _fail = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _logPractice(String kind, int score) async {
    final today = ieltsToday();
    if (_practice.any((r) => r['day'] == today && r['kind'] == kind)) return;
    try {
      final row = await context
          .read<AppState>()
          .api
          .createItem(_practicePath, {'day': today, 'kind': kind, 'score': score});
      if (mounted) setState(() => _practice = [..._practice, row]);
    } catch (_) {/* streak only; the practice result is already on screen */}
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(appBar: AppBar(title: Text(tr.ieltsTitle)), body: const SkeletonList());
    }
    if (_fail != null || _content == null) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.ieltsTitle)),
        body: StateMessage(
          icon: Icons.cloud_off_rounded,
          tint: scheme.error,
          title: tr.loadFailed,
          message: honestFailText(tr, _fail, otherwise: tr.ieltsLoadError),
          action: FilledButton.tonalIcon(
              onPressed: _load, icon: const Icon(Icons.refresh_rounded), label: Text(tr.retry)),
        ),
      );
    }
    final ctx = _Ielts(_content!, _logPractice);
    final days = _practice.map((r) => r['day']).whereType<int>();
    final st = ieltsStreak(days, ieltsToday());
    void open(Widget page) =>
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    final modules = <(IconData, String, String, Widget)>[
      (Icons.record_voice_over_rounded, tr.ieltsPron, tr.ieltsPronSub, _PronList(ctx: ctx)),
      (Icons.mic_rounded, tr.ieltsSpeaking, tr.ieltsSpeakingSub, _SpeakingList(ctx: ctx)),
      (Icons.edit_note_rounded, tr.ieltsWriting, tr.ieltsWritingSub, _WritingList(ctx: ctx)),
      (Icons.menu_book_rounded, tr.ieltsReading, tr.ieltsReadingSub, _ReadingList(ctx: ctx)),
      (Icons.headphones_rounded, tr.ieltsListening, tr.ieltsListeningSub, _ListeningPage(ctx: ctx)),
      (Icons.style_rounded, tr.ieltsVocab, tr.ieltsVocabSub, _VocabPage(ctx: ctx)),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(tr.ieltsTitle)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
          children: [
            Card(
              color: scheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(Gap.lg),
                child: Row(children: [
                  Icon(Icons.local_fire_department_rounded,
                      size: 40, color: scheme.onPrimaryContainer),
                  const SizedBox(width: Gap.md),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(
                          st.current > 0
                              ? ld(context, tr.ieltsStreak(st.current))
                              : tr.ieltsStreakStart,
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: scheme.onPrimaryContainer, fontWeight: FontWeight.w700)),
                      if (st.best > 0)
                        Text(ld(context, tr.ieltsStreakBest(st.best)),
                            style: TextStyle(color: scheme.onPrimaryContainer)),
                      if (st.todayDone)
                        Text(tr.ieltsTodayDone,
                            style: TextStyle(color: scheme.onPrimaryContainer)),
                    ]),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: Gap.sm),
            _EstimateNote(text: ctx.estimate(context)),
            const SizedBox(height: Gap.md),
            for (final m in modules)
              Card(
                margin: const EdgeInsets.only(bottom: Gap.sm),
                child: ListTile(
                  minVerticalPadding: Gap.md,
                  leading: CircleAvatar(
                    backgroundColor: scheme.secondaryContainer,
                    child: Icon(m.$1, color: scheme.onSecondaryContainer),
                  ),
                  title: Text(m.$2),
                  subtitle: Text(m.$3),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => open(m.$4),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EstimateNote extends StatelessWidget {
  final String text;
  const _EstimateNote({required this.text});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.info_outline_rounded, size: 18, color: scheme.onSurfaceVariant),
        const SizedBox(width: Gap.xs),
        Expanded(
            child: Text(text,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13, height: 1.35))),
      ]),
    );
  }
}

/// passed / total as a 0..100 integer (0 when total is missing).
int _pct(Object? passed, Object? total) {
  final t = total is num ? total.toInt() : 0;
  final p = passed is num ? passed.toInt() : 0;
  return t <= 0 ? 0 : (100 * p) ~/ t;
}

void _toast(BuildContext context, String msg) => ScaffoldMessenger.of(context)
  ..clearSnackBars()
  ..showSnackBar(SnackBar(content: Text(msg)));

/// Scaffold for every module page: app bar + scrollable padded body.
Widget _page(BuildContext context, String title, List<Widget> children) => Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl)),
        children: children,
      ),
    );

Widget _bodyText(BuildContext context, String t) => Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Text(t,
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, height: 1.4)),
    );

// ======================= pronunciation =======================

class _PronList extends StatelessWidget {
  final _Ielts ctx;
  const _PronList({required this.ctx});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final rows = _list(ctx.content['pron']);
    return _page(context, tr.ieltsPron, [
      _bodyText(context, tr.ieltsPronHow),
      for (final r in rows)
        Card(
          margin: const EdgeInsets.only(bottom: Gap.sm),
          child: ListTile(
            minVerticalPadding: Gap.md,
            title: Text('${r['text']}'),
            subtitle: Text(_loc(context, r, 'tip_bn', 'tip_en'),
                maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => IeltsPronPractice(ctx: ctx, row: r))),
          ),
        ),
    ]);
  }
}

/// One sentence: record → align → coloured words + score. Public for tests.
class IeltsPronPractice extends StatefulWidget {
  final Object ctx; // _Ielts (Object so tests can build it via the hub)
  final Map<String, dynamic> row;
  final String? debugHeard; // gallery/tests: a finished attempt
  /// Language packs: the speech locale of the language being learnt
  /// (e.g. 'ko-KR'); null = English. [title] replaces the app-bar title.
  final String? localeId;
  final String? title;
  const IeltsPronPractice(
      {super.key, required this.ctx, required this.row, this.debugHeard, this.localeId, this.title});
  @override
  State<IeltsPronPractice> createState() => _IeltsPronPracticeState();
}

class _IeltsPronPracticeState extends State<IeltsPronPractice> {
  final _heard = TextEditingController();
  late final VoiceDictation _voice = VoiceDictation(mode: 'en', learnLocale: widget.localeId);
  AlignResult? _result;

  @override
  void initState() {
    super.initState();
    if (widget.debugHeard != null) {
      _heard.text = widget.debugHeard!;
      _result = alignWords('${widget.row['text']}', widget.debugHeard!);
    }
  }

  @override
  void dispose() {
    _voice.stop();
    _voice.dispose();
    _heard.dispose();
    super.dispose();
  }

  Future<void> _record() async {
    if (_voice.listening) {
      await _voice.stop();
      return;
    }
    _heard.clear();
    setState(() => _result = null);
    await _voice.start(context, _heard, pauseFor: const Duration(seconds: 3));
  }

  void _check() {
    final tr = AppLocalizations.of(context);
    if (ieltsWords(_heard.text).isEmpty) {
      _toast(context, tr.ieltsNothingHeard);
      return;
    }
    final r = alignWords('${widget.row['text']}', _heard.text);
    setState(() => _result = r);
    final c = widget.ctx;
    if (c is _Ielts) unawaited(c.logPractice('pron', r.score));
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final r = _result;
    final tip = _loc(context, widget.row, 'tip_bn', 'tip_en');
    return _page(context, widget.title ?? tr.ieltsPron, [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Text('${widget.row['text']}',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(height: 1.3)),
        ),
      ),
      const SizedBox(height: Gap.sm),
      if (tip.isNotEmpty)
        Text('${tr.ieltsTip}: $tip', style: TextStyle(height: 1.4, color: scheme.onSurface)),
      const SizedBox(height: Gap.lg),
      ListenableBuilder(
        listenable: _voice,
        builder: (context, _) => FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: _record,
          icon: Icon(_voice.listening ? Icons.stop_rounded : Icons.mic_rounded),
          label: Text(_voice.listening ? tr.ieltsStop : tr.ieltsRecord),
        ),
      ),
      const SizedBox(height: Gap.md),
      TextField(
        controller: _heard,
        readOnly: true,
        minLines: 1,
        maxLines: 4,
        decoration: InputDecoration(
            labelText: tr.ieltsHeardLabel, border: const OutlineInputBorder()),
      ),
      const SizedBox(height: Gap.sm),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        onPressed: _check,
        icon: const Icon(Icons.fact_check_rounded),
        label: Text(tr.ieltsCheck),
      ),
      if (r != null) ...[
        const SizedBox(height: Gap.lg),
        Text(ld(context, tr.ieltsPronScore(r.score)),
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.sm),
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          for (final w in r.rows) _WordChip(row: w),
        ]),
        const SizedBox(height: Gap.md),
        _Legend(),
        const SizedBox(height: Gap.sm),
        _EstimateNote(text: tr.ieltsPronEstimate),
      ],
    ]);
  }
}

Color _statusColor(String s) => switch (s) {
      'ok' => Brand.success,
      'sub' => Brand.warning,
      _ => Brand.danger,
    };

IconData _statusIcon(String s) => switch (s) {
      'ok' => Icons.check_circle_rounded,
      'sub' => Icons.swap_horiz_rounded,
      _ => Icons.cancel_rounded,
    };

class _WordChip extends StatelessWidget {
  final AlignRow row;
  const _WordChip({required this.row});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final c = _statusColor(row.status);
    final ink = Brand.onTint(context, c);
    final label = row.status == 'sub' ? '${row.word} · ${tr.ieltsHeardAs(row.heard)}' : row.word;
    final what = switch (row.status) {
      'ok' => tr.ieltsWordOk,
      'sub' => tr.ieltsWordSub,
      _ => tr.ieltsWordMiss,
    };
    return Semantics(
      label: '$label, $what',
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: 40),
        padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: c.withValues(alpha: 0.6)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(_statusIcon(row.status), size: 18, color: ink),
          const SizedBox(width: Gap.xs),
          Flexible(child: Text(label, style: TextStyle(color: ink, fontWeight: FontWeight.w600))),
        ]),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    Widget item(String s, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(_statusIcon(s), size: 16, color: Brand.onTint(context, _statusColor(s))),
          const SizedBox(width: Gap.xs),
          Flexible(child: Text(t)),
        ]);
    return Wrap(spacing: Gap.lg, runSpacing: Gap.xs, children: [
      item('ok', tr.ieltsWordOk),
      item('sub', tr.ieltsWordSub),
      item('miss', tr.ieltsWordMiss),
    ]);
  }
}

// ======================= feedback card (speaking + writing) =======================

String _critLabel(AppLocalizations tr, String id) => switch (id) {
      'task' => tr.ieltsCritTask,
      'coherence' => tr.ieltsCritCoherence,
      'lexical' => tr.ieltsCritLexical,
      'grammar' => tr.ieltsCritGrammar,
      'fluency' => tr.ieltsCritFluency,
      _ => tr.ieltsCritPronunciation,
    };

String _band(Object? b) {
  if (b is! num) return '';
  return b == b.roundToDouble() ? '${b.toInt()}' : b.toStringAsFixed(1);
}

/// Checklist (always) + AI estimate block (when asked). Public for tests.
class IeltsFeedback extends StatelessWidget {
  final Map<String, dynamic> result;
  const IeltsFeedback({super.key, required this.result});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final check = (result['check'] as Map?)?.cast<String, dynamic>() ?? const {};
    final items = _list(check['items']);
    final ai = (result['ai'] as Map?)?.cast<String, dynamic>();
    final state = '${result['ai_state'] ?? 'not_asked'}';
    final charged = (result['credits_charged'] as num?)?.toInt() ?? 0;
    final label = _loc(context, (result['estimate_label'] as Map?) ?? const {}, 'bn', 'en');
    final aiMsg = switch (state) {
      'no_key' => tr.ieltsAiNotConnected,
      'credits' || 'user_limit' => tr.ieltsAiNoCredits,
      'unreadable' => tr.ieltsAiUnreadable,
      'busy' || 'budget' => tr.ieltsAiBusy,
      _ => null,
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(ld(context, tr.ieltsChecklistTitle(check['passed'] ?? 0, check['total'] ?? 0)),
          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: Gap.sm),
      for (final i in items)
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.sm),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(i['ok'] == true ? Icons.check_circle_rounded : Icons.error_outline_rounded,
                color: Brand.onTint(context, i['ok'] == true ? Brand.success : Brand.warning)),
            const SizedBox(width: Gap.sm),
            Expanded(child: Text(ld(context, _loc(context, i, 'bn', 'en')), style: const TextStyle(height: 1.4))),
          ]),
        ),
      if (aiMsg != null)
        Card(
          color: scheme.surfaceContainerHighest,
          child: Padding(padding: const EdgeInsets.all(Gap.md), child: Text(aiMsg)),
        ),
      if (ai != null) ...[
        const SizedBox(height: Gap.md),
        Text(tr.ieltsAiTitle,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        if (ai['overall'] is num)
          Text(ld(context, '${tr.ieltsOverall}: ${tr.ieltsBandEstimate(_band(ai['overall']))}'),
              style: Theme.of(context).textTheme.titleLarge),
        for (final c in _list(ai['criteria']))
          Card(
            margin: const EdgeInsets.only(top: Gap.sm),
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                    ld(context,
                        '${_critLabel(tr, '${c['id']}')} — ${c['band'] is num ? tr.ieltsBandEstimate(_band(c['band'])) : tr.ieltsNoBandText}'),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: Gap.xs),
                Text(_loc(context, c, 'bn', 'en'), style: const TextStyle(height: 1.4)),
              ]),
            ),
          ),
        if (_list(ai['fixes']).isNotEmpty) ...[
          const SizedBox(height: Gap.md),
          Text(tr.ieltsFixes, style: const TextStyle(fontWeight: FontWeight.w700)),
          for (final f in _list(ai['fixes']))
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text('• ${_loc(context, f, 'bn', 'en')}', style: const TextStyle(height: 1.4)),
            ),
        ],
        if (charged > 0)
          Padding(
            padding: const EdgeInsets.only(top: Gap.sm),
            child: Text(ld(context, tr.ieltsAiCharged(charged)),
                style: TextStyle(color: scheme.onSurfaceVariant)),
          ),
      ],
      const SizedBox(height: Gap.sm),
      _EstimateNote(text: label),
    ]);
  }
}

/// The two buttons under an answer: free checklist + optional AI estimate.
class _CheckButtons extends StatelessWidget {
  final bool busy;
  final bool aiReady;
  final void Function(bool useAi) onCheck;
  const _CheckButtons({required this.busy, required this.aiReady, required this.onCheck});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        onPressed: busy ? null : () => onCheck(false),
        icon: busy
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.fact_check_rounded),
        label: Text(tr.ieltsGetFeedback),
      ),
      if (aiReady) ...[
        const SizedBox(height: Gap.sm),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: busy ? null : () => onCheck(true),
          icon: const Icon(Icons.auto_awesome_rounded),
          label: Text(tr.ieltsAiEstimate),
        ),
      ],
    ]);
  }
}

// ======================= speaking =======================

class _SpeakingList extends StatefulWidget {
  final _Ielts ctx;
  const _SpeakingList({required this.ctx});
  @override
  State<_SpeakingList> createState() => _SpeakingListState();
}

class _SpeakingListState extends State<_SpeakingList> {
  String _part = 'p1';
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final sp = (widget.ctx.content['speaking'] as Map?) ?? const {};
    final rows = _list(_part == 'p1' ? sp['p1'] : sp['p2']);
    final help = switch (_part) {
      'p1' => tr.ieltsPart1Help,
      'p2' => tr.ieltsPart2Help,
      _ => tr.ieltsPart3Help,
    };
    return _page(context, tr.ieltsSpeaking, [
      SegmentedButton<String>(
        segments: [
          ButtonSegment(value: 'p1', label: Text(ld(context, tr.ieltsPartN(1)))),
          ButtonSegment(value: 'p2', label: Text(ld(context, tr.ieltsPartN(2)))),
          ButtonSegment(value: 'p3', label: Text(ld(context, tr.ieltsPartN(3)))),
        ],
        selected: {_part},
        onSelectionChanged: (s) => setState(() => _part = s.first),
      ),
      const SizedBox(height: Gap.md),
      _bodyText(context, help),
      for (final r in rows)
        Card(
          margin: const EdgeInsets.only(bottom: Gap.sm),
          child: ListTile(
            minVerticalPadding: Gap.md,
            title: Text(_part == 'p1'
                ? _loc(context, r, 'topic_bn', 'topic_en')
                : _part == 'p2'
                    ? '${r['title']}'
                    : '${(r['p3'] as List?)?.first ?? ''}'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => IeltsSpeakingPractice(ctx: widget.ctx, part: _part, row: r))),
          ),
        ),
    ]);
  }
}

class IeltsSpeakingPractice extends StatefulWidget {
  final Object ctx;
  final String part;
  final Map<String, dynamic> row;
  const IeltsSpeakingPractice({super.key, required this.ctx, required this.part, required this.row});
  @override
  State<IeltsSpeakingPractice> createState() => _IeltsSpeakingPracticeState();
}

class _IeltsSpeakingPracticeState extends State<IeltsSpeakingPractice> {
  final _answer = TextEditingController();
  late final VoiceDictation _voice = VoiceDictation(mode: 'en');
  final _spoken = Stopwatch();
  Timer? _prep;
  int _prepLeft = 0;
  bool _busy = false;
  Map<String, dynamic>? _result;

  @override
  void initState() {
    super.initState();
    _voice.addListener(_onVoice);
  }

  void _onVoice() {
    if (_voice.listening && !_spoken.isRunning) _spoken.start();
    if (!_voice.listening && _spoken.isRunning) _spoken.stop();
  }

  @override
  void dispose() {
    _prep?.cancel();
    _voice.removeListener(_onVoice);
    _voice.stop();
    _voice.dispose();
    _answer.dispose();
    super.dispose();
  }

  void _startPrep() {
    _prep?.cancel();
    setState(() => _prepLeft = 60);
    _prep = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _prepLeft--);
      if (_prepLeft <= 0) t.cancel();
    });
  }

  Future<void> _check(bool useAi) async {
    final tr = AppLocalizations.of(context);
    if (ieltsWords(_answer.text).isEmpty) {
      _toast(context, tr.ieltsEmptyAnswer);
      return;
    }
    setState(() => _busy = true);
    try {
      final r = await context.read<AppState>().api.postJson('/ielts/speaking/check', {
        'part': widget.part,
        'prompt_id': widget.row['id'],
        'transcript': _answer.text,
        'seconds': _spoken.elapsed.inSeconds,
        'use_ai': useAi,
      });
      if (!mounted) return;
      setState(() => _result = r);
      final c = widget.ctx;
      final ch = (r['check'] as Map?) ?? const {};
      if (c is _Ielts) {
        unawaited(c.logPractice('speaking', _pct(ch['passed'], ch['total'])));
      }
    } catch (e) {
      if (mounted) _toast(context, honestFailText(tr, e, otherwise: tr.ieltsLoadError));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final r = widget.row;
    final bullets = (r['bullets'] as List?)?.map((e) => '$e').toList() ?? const <String>[];
    final List<String> questions = switch (widget.part) {
      'p1' => ((r['questions'] as List?) ?? const []).map((e) => '$e').toList(),
      'p3' => ((r['p3'] as List?) ?? const []).map((e) => '$e').toList(),
      _ => const [],
    };
    final ctx = widget.ctx;
    return _page(context, ld(context, tr.ieltsPartN(int.parse(widget.part.substring(1)))), [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (widget.part == 'p2') ...[
              Text('${r['title']}',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.sm),
              Text(tr.ieltsYouShouldSay),
              for (final b in bullets) Text('• $b', style: const TextStyle(height: 1.5)),
            ] else
              for (final q in questions)
                Padding(
                  padding: const EdgeInsets.only(bottom: Gap.xs),
                  child: Text('• $q', style: const TextStyle(height: 1.4)),
                ),
          ]),
        ),
      ),
      if (widget.part == 'p2') ...[
        const SizedBox(height: Gap.sm),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: _prepLeft > 0 ? null : _startPrep,
          icon: const Icon(Icons.timer_outlined),
          label: Text(_prepLeft > 0 ? ld(context, tr.ieltsPrepLeft(_prepLeft)) : tr.ieltsPrepTimer),
        ),
      ],
      const SizedBox(height: Gap.md),
      _bodyText(context, tr.ieltsAnswerHint),
      ListenableBuilder(
        listenable: _voice,
        builder: (context, _) => FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: () => _voice.toggle(context, _answer),
          icon: Icon(_voice.listening ? Icons.stop_rounded : Icons.mic_rounded),
          label: Text(_voice.listening ? tr.ieltsStop : tr.ieltsRecord),
        ),
      ),
      const SizedBox(height: Gap.sm),
      TextField(
        controller: _answer,
        minLines: 3,
        maxLines: 10,
        maxLength: 6000,
        buildCounter: localCounter,
        decoration: InputDecoration(labelText: tr.ieltsYourAnswer, border: const OutlineInputBorder()),
      ),
      const SizedBox(height: Gap.sm),
      _CheckButtons(
          busy: _busy, aiReady: ctx is _Ielts && ctx.aiReady, onCheck: _check),
      if (_result != null) ...[
        const SizedBox(height: Gap.lg),
        IeltsFeedback(result: _result!),
      ],
    ]);
  }
}

// ======================= writing =======================

class _WritingList extends StatefulWidget {
  final _Ielts ctx;
  const _WritingList({required this.ctx});
  @override
  State<_WritingList> createState() => _WritingListState();
}

class _WritingListState extends State<_WritingList> {
  String _task = 't2';
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final rows = _list(((widget.ctx.content['writing'] as Map?) ?? const {})[_task]);
    return _page(context, tr.ieltsWriting, [
      SegmentedButton<String>(
        segments: [
          ButtonSegment(value: 't1', label: Text(tr.ieltsTask1)),
          ButtonSegment(value: 't2', label: Text(tr.ieltsTask2)),
        ],
        selected: {_task},
        onSelectionChanged: (s) => setState(() => _task = s.first),
      ),
      const SizedBox(height: Gap.md),
      _bodyText(context, _task == 't1' ? tr.ieltsTask1Help : tr.ieltsTask2Help),
      for (final r in rows)
        Card(
          margin: const EdgeInsets.only(bottom: Gap.sm),
          child: ListTile(
            minVerticalPadding: Gap.md,
            title: Text('${r['prompt']}', maxLines: 3, overflow: TextOverflow.ellipsis),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => IeltsWritingPractice(ctx: widget.ctx, task: _task, row: r))),
          ),
        ),
    ]);
  }
}

class IeltsWritingPractice extends StatefulWidget {
  final Object ctx;
  final String task;
  final Map<String, dynamic> row;
  final String? debugText;
  final Map<String, dynamic>? debugResult;
  const IeltsWritingPractice(
      {super.key, required this.ctx, required this.task, required this.row, this.debugText, this.debugResult});
  @override
  State<IeltsWritingPractice> createState() => _IeltsWritingPracticeState();
}

class _IeltsWritingPracticeState extends State<IeltsWritingPractice> {
  late final _text = TextEditingController(text: widget.debugText ?? '');
  bool _busy = false;
  late Map<String, dynamic>? _result = widget.debugResult;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _check(bool useAi) async {
    final tr = AppLocalizations.of(context);
    if (ieltsWords(_text.text).isEmpty) {
      _toast(context, tr.ieltsEmptyAnswer);
      return;
    }
    setState(() => _busy = true);
    try {
      final r = await context.read<AppState>().api.postJson('/ielts/writing/check', {
        'task': widget.task,
        'prompt_id': widget.row['id'],
        'text': _text.text,
        'use_ai': useAi,
      });
      if (!mounted) return;
      setState(() => _result = r);
      final c = widget.ctx;
      final ch = (r['check'] as Map?) ?? const {};
      if (c is _Ielts) {
        unawaited(c.logPractice('writing', _pct(ch['passed'], ch['total'])));
      }
    } catch (e) {
      if (mounted) _toast(context, honestFailText(tr, e, otherwise: tr.ieltsLoadError));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final min = (widget.row['min_words'] as num?)?.toInt() ?? (widget.task == 't1' ? 150 : 250);
    final n = ieltsWords(_text.text).length;
    final ctx = widget.ctx;
    return _page(context, widget.task == 't1' ? tr.ieltsTask1 : tr.ieltsTask2, [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Text('${widget.row['prompt']}', style: const TextStyle(height: 1.45)),
        ),
      ),
      const SizedBox(height: Gap.md),
      TextField(
        controller: _text,
        minLines: 8,
        maxLines: 20,
        maxLength: 6000,
        buildCounter: localCounter,
        keyboardType: TextInputType.multiline,
        decoration: InputDecoration(labelText: tr.ieltsWriteHint, border: const OutlineInputBorder()),
      ),
      Text(ld(context, tr.ieltsWordCount(n, min)),
          style: TextStyle(
              color: n >= min
                  ? Brand.onTint(context, Brand.success)
                  : Theme.of(context).colorScheme.onSurfaceVariant)),
      const SizedBox(height: Gap.md),
      _CheckButtons(busy: _busy, aiReady: ctx is _Ielts && ctx.aiReady, onCheck: _check),
      if (_result != null) ...[
        const SizedBox(height: Gap.lg),
        IeltsFeedback(result: _result!),
      ],
    ]);
  }
}

// ======================= reading =======================

class _ReadingList extends StatelessWidget {
  final _Ielts ctx;
  const _ReadingList({required this.ctx});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final rows = _list(ctx.content['reading']);
    return _page(context, tr.ieltsReading, [
      _bodyText(context, tr.ieltsReadingOriginal),
      for (final r in rows)
        Card(
          margin: const EdgeInsets.only(bottom: Gap.sm),
          child: ListTile(
            minVerticalPadding: Gap.md,
            leading: const Icon(Icons.article_outlined),
            title: Text('${r['title']}'),
            subtitle: Text(ld(context, tr.ieltsQuestionsCount(_list(r['questions']).length))),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => IeltsReadingPractice(ctx: ctx, row: r))),
          ),
        ),
    ]);
  }
}

class IeltsReadingPractice extends StatefulWidget {
  final Object ctx;
  final Map<String, dynamic> row;
  const IeltsReadingPractice({super.key, required this.ctx, required this.row});
  @override
  State<IeltsReadingPractice> createState() => _IeltsReadingPracticeState();
}

class _IeltsReadingPracticeState extends State<IeltsReadingPractice> {
  final Map<String, String> _answers = {};
  Map<String, dynamic>? _graded;
  bool _busy = false;

  Future<void> _submit() async {
    final tr = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final g = await context.read<AppState>().api.postJson('/ielts/reading/grade',
          {'passage_id': widget.row['id'], 'answers': _answers});
      if (!mounted) return;
      setState(() => _graded = g);
      final c = widget.ctx;
      if (c is _Ielts) {
        unawaited(c.logPractice('reading', _pct(g['correct'], g['total'])));
      }
    } catch (e) {
      if (mounted) _toast(context, honestFailText(tr, e, otherwise: tr.ieltsLoadError));
    }
    if (mounted) setState(() => _busy = false);
  }

  String _answerLabel(AppLocalizations tr, Map q, String a) {
    if (q['type'] == 'tfng') {
      return switch (a) { 'true' => tr.ieltsTrue, 'false' => tr.ieltsFalse, _ => tr.ieltsNotGiven };
    }
    final opts = (q['options'] as List?) ?? const [];
    final i = int.tryParse(a) ?? -1;
    return i >= 0 && i < opts.length ? '${opts[i]}' : a;
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final qs = _list(widget.row['questions']);
    final graded = {for (final r in _list(_graded?['rows'])) '${r['id']}': r};
    return _page(context, tr.ieltsReading, [
      Text('${widget.row['title']}',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: Gap.sm),
      for (final p in (widget.row['paragraphs'] as List? ?? const []))
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.md),
          child: Text('$p', style: const TextStyle(height: 1.5)),
        ),
      const Divider(),
      for (var i = 0; i < qs.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(ld(context, '${i + 1}. ${qs[i]['text']}'),
                style: const TextStyle(fontWeight: FontWeight.w600, height: 1.4)),
            const SizedBox(height: Gap.xs),
            // Full-width rows (not chips): long MCQ options wrap at 200 % font.
            for (final a in qs[i]['type'] == 'tfng'
                ? const ['true', 'false', 'notgiven']
                : [for (var k = 0; k < ((qs[i]['options'] as List?)?.length ?? 0); k++) '$k'])
              Semantics(
                selected: _answers['${qs[i]['id']}'] == a,
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: Gap.xs),
                  leading: Icon(_answers['${qs[i]['id']}'] == a
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded),
                  title: Text(_answerLabel(tr, qs[i], a)),
                  onTap: _graded != null
                      ? null
                      : () => setState(() => _answers['${qs[i]['id']}'] = a),
                ),
              ),
            if (graded['${qs[i]['id']}'] != null)
              Builder(builder: (context) {
                final g = graded['${qs[i]['id']}']!;
                final ok = g['correct'] == true;
                return Padding(
                  padding: const EdgeInsets.only(top: Gap.xs),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(ok ? Icons.check_circle_rounded : Icons.cancel_rounded,
                        color: Brand.onTint(context, ok ? Brand.success : Brand.danger)),
                    const SizedBox(width: Gap.xs),
                    Expanded(
                      child: Text(
                          '${tr.ieltsCorrectAnswer(_answerLabel(tr, qs[i], '${g['answer']}'))}\n${_loc(context, g, 'bn', 'en')}',
                          style: const TextStyle(height: 1.4)),
                    ),
                  ]),
                );
              }),
          ]),
        ),
      if (_graded == null)
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: _busy || _answers.isEmpty ? null : _submit,
          icon: const Icon(Icons.fact_check_rounded),
          label: Text(tr.ieltsSubmitAnswers),
        )
      else ...[
        Text(ld(context, tr.ieltsScore(_graded!['correct'] ?? 0, _graded!['total'] ?? 0)),
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.sm),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: () => setState(() {
            _graded = null;
            _answers.clear();
          }),
          icon: const Icon(Icons.replay_rounded),
          label: Text(tr.ieltsTryAgain),
        ),
      ],
    ]);
  }
}

// ======================= listening (official links) =======================

class _ListeningPage extends StatelessWidget {
  final _Ielts ctx;
  const _ListeningPage({required this.ctx});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final links = _list(ctx.content['official_links']);
    return _page(context, tr.ieltsListening, [
      _bodyText(context, tr.ieltsListeningBody),
      for (final l in links)
        Card(
          margin: const EdgeInsets.only(bottom: Gap.sm),
          child: ListTile(
            minVerticalPadding: Gap.md,
            leading: const Icon(Icons.open_in_new_rounded),
            title: Text('${l['org']}'),
            subtitle: Text(_loc(context, l, 'bn', 'en')),
            onTap: () async {
              final uri = Uri.tryParse('${l['url']}');
              if (uri == null || uri.scheme != 'https') {
                _toast(context, tr.ieltsOpenLinkFailed);
                return;
              }
              try {
                final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
                if (!ok && context.mounted) _toast(context, tr.ieltsOpenLinkFailed);
              } catch (_) {
                if (context.mounted) _toast(context, tr.ieltsOpenLinkFailed);
              }
            },
          ),
        ),
    ]);
  }
}

// ======================= vocabulary (Leitner) =======================

class _VocabPage extends StatefulWidget {
  final _Ielts ctx;
  const _VocabPage({required this.ctx});
  @override
  State<_VocabPage> createState() => _VocabPageState();
}

class _VocabPageState extends State<_VocabPage> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true, _revealed = false;
  Object? _fail;

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
    try {
      _rows = await context.read<AppState>().api.listItems(_vocabPath);
    } catch (e) {
      _fail = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Map<String, dynamic>? _row(String id) {
    for (final r in _rows) {
      if (r['card_id'] == id) return r;
    }
    return null;
  }

  /// Due = never studied, or next_due_day <= today. Content order.
  List<Map<String, dynamic>> _due() {
    final today = ieltsToday();
    return _list(widget.ctx.content['vocab']).where((v) {
      final r = _row('${v['id']}');
      return r == null || ((r['next_due_day'] as num?)?.toInt() ?? 0) <= today;
    }).toList();
  }

  Future<void> _answer(Map<String, dynamic> card, bool passed) async {
    final api = context.read<AppState>().api;
    final tr = AppLocalizations.of(context);
    final existing = _row('${card['id']}');
    final (box, due) =
        leitnerNext((existing?['box'] as num?)?.toInt() ?? 1, passed, ieltsToday());
    final body = {
      'card_id': card['id'],
      'box': box,
      'next_due_day': due,
      'reps': ((existing?['reps'] as num?)?.toInt() ?? 0) + 1,
    };
    try {
      if (existing != null && existing['id'] is int) {
        await api.updateItem(_vocabPath, existing['id'] as int, body);
      } else {
        await api.createItem(_vocabPath, body);
      }
      unawaited(widget.ctx.logPractice('vocab', passed ? 100 : 0));
      _revealed = false;
      await _load();
    } catch (_) {
      if (mounted) _toast(context, tr.saveFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(appBar: AppBar(title: Text(tr.ieltsVocab)), body: const SkeletonList());
    }
    if (_fail != null) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.ieltsVocab)),
        body: StateMessage(
          icon: Icons.cloud_off_rounded,
          tint: scheme.error,
          title: tr.loadFailed,
          message: honestFailText(tr, _fail, otherwise: tr.ieltsLoadError),
          action: FilledButton.tonalIcon(
              onPressed: _load, icon: const Icon(Icons.refresh_rounded), label: Text(tr.retry)),
        ),
      );
    }
    final due = _due();
    if (due.isEmpty) {
      return _page(context, tr.ieltsVocab, [
        const SizedBox(height: Gap.xl),
        Icon(Icons.celebration_rounded, size: 56, color: scheme.primary),
        const SizedBox(height: Gap.md),
        Text(tr.ieltsVocabNoneDue, textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: Gap.lg),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back_rounded),
          label: Text(tr.ieltsBackToPractice),
        ),
      ]);
    }
    final card = due.first;
    return _page(context, tr.ieltsVocab, [
      _bodyText(context, tr.ieltsVocabHow),
      Text(ld(context, tr.ieltsVocabDue(due.length)),
          style: const TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: Gap.md),
      Card(
        child: InkWell(
          onTap: () => setState(() => _revealed = true),
          child: Padding(
            padding: const EdgeInsets.all(Gap.xl),
            child: Column(children: [
              Text('${card['en']}',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.md),
              if (_revealed) ...[
                // The meaning is the Bangla gloss (the point of the card);
                // in English the example sentence carries the meaning.
                if (_isBn(context))
                  Text('${card['bn']}', textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: Gap.sm),
                Text('${card['example']}', textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
              ] else
                Text(tr.ieltsShowMeaning, style: TextStyle(color: scheme.primary)),
            ]),
          ),
        ),
      ),
      const SizedBox(height: Gap.md),
      if (_revealed)
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: () => _answer(card, false),
              icon: const Icon(Icons.replay_rounded),
              label: Text(tr.lpMissedIt),
            ),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: () => _answer(card, true),
              icon: const Icon(Icons.check_rounded),
              label: Text(tr.lpGotIt),
            ),
          ),
        ])
      else
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: () => setState(() => _revealed = true),
          child: Text(tr.ieltsShowMeaning),
        ),
    ]);
  }
}
