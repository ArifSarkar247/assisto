/// lpapp — VOCABULARY: IELTS + life topic lists (bundled, offline), Bangla
/// meaning, example, listen, spaced repetition (Leitner 1..5 via lp/vocab),
/// daily goal (10 new words) and the shared streak.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import '../../ds/ds.dart';
import 'package:provider/provider.dart';

import '../../ads/ad_banner_slot.dart';
import '../../ads/ad_placements.dart' show AdExit, AdExitPlacement;
import '../../l10n/app_localizations.dart';
import '../../services/error_kind.dart' show honestFailText;
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart' show withNavBarInset;
import '../../widgets/local_digits.dart';
import '../../widgets/skeleton.dart';
import '../ielts_engine.dart' show ieltsToday;
import 'lp_data.dart';
import 'lp_engine.dart';
import 'lp_ui.dart';

const int kLpNewWordsPerDay = 10;

class LpVocabScreen extends StatefulWidget {
  const LpVocabScreen({super.key});
  @override
  State<LpVocabScreen> createState() => _LpVocabScreenState();
}

class _LpVocabScreenState extends State<LpVocabScreen> {
  List<Map<String, dynamic>> _topics = const [];
  List<Map<String, dynamic>> _rows = const [];
  bool _loading = true, _offline = false;
  Object? _fail;
  String _group = 'ielts';

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
      _topics = await LpContent.topics();
    } catch (e) {
      _fail = e;
    }
    // gap-lp: offline = the phone copy + queued moves (sent when back online)
    final (rows, offline) = await LpVocabStore.load(context.read<AppState>().api);
    _rows = rows;
    _offline = offline;
    if (mounted) setState(() => _loading = false);
  }

  Map<String, VocabState> get _state => LpProgress(const [], _rows, const []).vocabState;

  Future<void> _study(List<Map<String, dynamic>> words, String title) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => LpVocabSession(words: words, rows: _rows, title: title)));
    if (mounted) unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) return Scaffold(appBar: AppBar(title: Text(tr.lp2VocabTitle)), body: const SkeletonList());
    if (_fail != null) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.lp2VocabTitle)),
        body: StateMessage(
          icon: Icons.error_outline_rounded,
          title: tr.loadFailed,
          message: honestFailText(tr, _fail, otherwise: tr.lp2ContentFail),
          action: FilledButton.tonalIcon(onPressed: _load, icon: const Icon(Icons.refresh_rounded), label: Text(tr.retry)),
        ),
      );
    }
    final st = _state;
    final today = ieltsToday();
    final all = [for (final t in _topics) ...lpList(t['words'])];
    final due = dueWords([for (final w in all) '${w['id']}'], st, today,
        newPerDay: kLpNewWordsPerDay,
        introducedToday: _rows.where((r) => (r['first_day'] as num?)?.toInt() == today).length);
    final byId = {for (final w in all) '${w['id']}': w};
    final shown = _topics.where((t) => t['group'] == _group).toList();
    return Scaffold(
      bottomNavigationBar: const AdBannerSlot(screen: 'lp_vocab'),
      appBar: AppBar(title: Text(tr.lp2VocabTitle)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl)),
        children: [
          if (_offline)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.md),
              child: DsCard(
                key: const Key('lp2-vocab-offline'),
                padding: EdgeInsets.zero,
                child: ListTile(
                  leading: Icon(Icons.cloud_off_rounded, color: DsTokens.of(context).dangerInk),
                  title: Text(tr.lp2ProgressOffline),
                  trailing: TextButton(onPressed: _load, child: Text(tr.retry)),
                ),
              ),
            ),
          DsSurface(color: scheme.ds.primarySoft,
            padding: const EdgeInsets.all(Gap.lg),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(tr.lp2VocabToday, style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700, color: scheme.ds.primaryInk)),
                const SizedBox(height: Gap.xs),
                Text(
                    due.isEmpty
                        ? tr.lp2VocabAllDone
                        : tr.lp2VocabDue(ld(context, due.length)),
                    style: AType.bodyMedium.copyWith(color: scheme.ds.primaryInk, height: 1.4)),
                Text(tr.lp2VocabLearned(ld(context, learnedCount(st)), ld(context, all.length)),
                    style: AType.bodySmall.copyWith(color: scheme.ds.primaryInk)),
                const SizedBox(height: Gap.md),
                FilledButton.icon(
                  key: const Key('lp2-vocab-start'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(kMinTap)),
                  onPressed: due.isEmpty
                      ? null
                      : () => _study([for (final id in due) if (byId[id] != null) byId[id]!], tr.lp2VocabToday),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: Text(due.isEmpty ? tr.lp2VocabComeBack : tr.lp2VocabStart),
                ),
              ]),
          ),
          const SizedBox(height: Gap.lg),
          SegmentedButton<String>(
            segments: [
              ButtonSegment(value: 'ielts', label: Text(tr.lp2VocabIelts), icon: const Icon(Icons.school_rounded)),
              ButtonSegment(value: 'life', label: Text(tr.lp2VocabLife), icon: const Icon(Icons.public_rounded)),
            ],
            selected: {_group},
            onSelectionChanged: (s) => setState(() => _group = s.first),
          ),
          const SizedBox(height: Gap.md),
          for (final t in shown)
            Builder(builder: (context) {
              final words = lpList(t['words']);
              final learned = words.where((w) => (st['${w['id']}']?.box ?? 0) >= 3).length;
              return Padding(padding: const EdgeInsets.only(bottom: Gap.sm), child: DsCard(
                  padding: EdgeInsets.zero,
                  child: ListTile(
                  minVerticalPadding: Gap.md,
                  leading: CircleAvatar(
                    backgroundColor: scheme.ds.primarySoft,
                    child: Icon(lpIcon('${t['icon']}', Icons.style_rounded), color: scheme.ds.primaryInk),
                  ),
                  title: Text(lpLoc(context, t, 'title')),
                  subtitle: Text(tr.lp2VocabLearned(ld(context, learned), ld(context, words.length))),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => _study(words, lpLoc(context, t, 'title')),
                ),
                ));
            }),
        ],
      ),
    );
  }
}

/// One study session: word → tap to see Bangla meaning + example → "I knew
/// it" / "Not yet" (Leitner). Saves each answer; finishes with a summary.
class LpVocabSession extends StatefulWidget {
  final List<Map<String, dynamic>> words;
  final List<Map<String, dynamic>> rows;
  final String title;
  const LpVocabSession({super.key, required this.words, required this.rows, required this.title});
  @override
  State<LpVocabSession> createState() => _LpVocabSessionState();
}

class _LpVocabSessionState extends State<LpVocabSession> {
  int _i = 0, _knew = 0;
  bool _shown = false;
  late final Map<String, Map<String, dynamic>> _rowById = {
    for (final r in widget.rows) '${r['card_id']}': r,
  };
  final DateTime _start = DateTime.now();
  bool _logged = false;

  @override
  void dispose() {
    if (_logged) AdExit.maybeShow(AdExitPlacement.lessonAfterFinish);
    super.dispose();
  }

  Future<void> _answer(bool knew) async {
    final w = widget.words[_i];
    final id = '${w['id']}';
    final today = ieltsToday();
    final old = _rowById[id];
    final next = vocabNext(
        old == null ? null : VocabState((old['box'] as num?)?.toInt() ?? 1, (old['due'] as num?)?.toInt() ?? 0),
        knew,
        today);
    final body = {
      'card_id': id,
      'box': next.box,
      'due': next.due,
      'last_day': today,
      // gap-lp: the day a word was first studied (the 10-new-words-a-day goal)
      'first_day': old?['first_day'] ?? (old == null ? today : null),
    }..removeWhere((_, v) => v == null);
    setState(() {
      if (knew) _knew++;
      _i++;
      _shown = false;
    });
    final api = context.read<AppState>().api;
    try {
      if (old != null && old['id'] is int) {
        await api.updateItem(kLpVocab, old['id'] as int, body);
        _rowById[id] = {...old, ...body};
      } else {
        final r = await api.createItem(kLpVocab, body);
        _rowById[id] = {...body, 'id': r['id']};
      }
      unawaited(LpVocabStore.remember(_rowById[id]!));
    } catch (_) {
      // gap-lp: offline — the move waits on the phone and is sent on the next load
      _rowById[id] = {...?old, ...body};
      unawaited(LpVocabStore.queue(id, body));
    }
    if (_i >= widget.words.length && !_logged) {
      _logged = true;
      final mins = DateTime.now().difference(_start).inMinutes.clamp(1, 30);
      unawaited(lpLogPractice(api, 'vocab', mins));
      AdExit.taskDone(AdExitPlacement.lessonAfterFinish);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final n = widget.words.length;
    if (_i >= n) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: StateMessage(
          icon: Icons.emoji_events_rounded,
          tint: Brand.success,
          title: tr.lp2VocabDoneTitle,
          message: tr.lp2VocabDoneBody(ld(context, _knew), ld(context, n)),
          action: FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(kMinTap, kMinTap)),
              onPressed: () => Navigator.of(context).pop(),
              child: Text(tr.lp2Done)),
        ),
      );
    }
    final w = widget.words[_i];
    final word = '${w['w']}';
    final ex = '${w['ex'] ?? ''}';
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        children: [
          LinearProgressIndicator(value: _i / n, backgroundColor: scheme.ds.cardHighest),
          const SizedBox(height: Gap.xs),
          Text(ld(context, '${_i + 1} / $n'), style: AType.bodySmall.copyWith(color: scheme.ds.muted)),
          const SizedBox(height: Gap.lg),
          DsCard(
            padding: const EdgeInsets.all(Gap.xl),
            child: Column(children: [
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Flexible(
                    child: Text(word,
                        key: const Key('lp2-word'),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
                  ),
                  LpListenButton(text: word),
                ]),
                if ('${w['pos'] ?? ''}'.isNotEmpty)
                  Text('${w['pos']}', style: AType.bodyMedium.copyWith(color: scheme.ds.muted)),
                if (_shown) ...[
                  const Divider(height: Gap.xl),
                  Text('${w['bn']}',
                      key: const Key('lp2-meaning'),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: Gap.md),
                  if (ex.isNotEmpty)
                    Row(children: [
                      Expanded(child: Text(ex, style: AType.bodyMedium.copyWith(fontStyle: FontStyle.italic, height: 1.4))),
                      LpListenButton(text: ex),
                    ]),
                ],
              ]),
          ),
          const SizedBox(height: Gap.lg),
          if (!_shown)
            FilledButton.icon(
              key: const Key('lp2-show'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: () => setState(() => _shown = true),
              icon: const Icon(Icons.visibility_rounded),
              label: Text(tr.lp2ShowMeaning),
            )
          else
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('lp2-notyet'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  onPressed: () => _answer(false),
                  icon: const Icon(Icons.replay_rounded),
                  label: Text(tr.lp2NotYet),
                ),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: FilledButton.icon(
                  key: const Key('lp2-knew'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  onPressed: () => _answer(true),
                  icon: const Icon(Icons.check_rounded),
                  label: Text(tr.lp2KnewIt),
                ),
              ),
            ]),
          const SizedBox(height: Gap.md),
          Text(tr.lp2VocabHow, style: AType.bodySmall.copyWith(color: scheme.ds.muted, height: 1.4)),
        ],
      ),
    );
  }
}
