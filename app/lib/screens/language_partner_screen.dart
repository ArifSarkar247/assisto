import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../services/error_kind.dart' show honestFailText; // qa2

/// LANGUAGE-LEARNING PARTNER — ADVANCED, KEY-GATED (#132, SPEC v2.1 §21).
///
/// A bilingual (bn↔en) practice tool: a built-in DECK of everyday vocab/phrases,
/// FLASHCARD practice with Leitner spaced-repetition scheduling, text
/// PRONUNCIATION hints, and simple deterministic QUIZZES. Fully usable with NO
/// key via the built-in decks.
///
/// HONEST: decks, flashcards, SR and quizzes are deterministic built-ins. A
/// free-form LIVE CONVERSATION partner genuinely needs a model — it is a
/// DOCUMENTED key-gated seam shown as an honest "connect an AI key for live
/// conversation" state; it is NOT built here and everything else works key-free.
/// Pronunciation hints are labelled "approximate romanised — not exact phonetics".
///
/// The on-screen logic mirrors backend/core/logic/language_partner.py VERBATIM
/// (deck order, Leitner box→interval, promote/reset on pass/fail, due filter,
/// deterministic quiz rotation & grading). Any "today" is a day-NUMBER the UI
/// passes in; no live clock drives the engine.
///
/// Honest states: welcome (first use) · loading · error · deck-done · quiz-done.
/// ZERO Bangla literals — the engine holds ascii ids + romanised hints only;
/// bn/en card text resolves through AppLocalizations (lpC_<id>_bn / lpC_<id>_en).
///
/// Persistence (generic api helpers, no api.dart edit):
///   listItems('langlearn/progress') → [{id, card_id, deck, box, next_due_day,
///                                        reps, last_day}]
/// create/update/delete on the same path. One row per card the user has
/// studied; box 1..5 (Leitner), next_due_day is an integer day-number. Each row
/// round-trips as {id, ...data} through one flexible per-user JSON collection
/// (PaCollectionItem precedent).
class LanguagePartnerScreen extends StatefulWidget {
  const LanguagePartnerScreen({super.key});
  @override
  State<LanguagePartnerScreen> createState() => _LanguagePartnerScreenState();
}

const String _progressPath = 'langlearn/progress';
const List<String> _deckKeys = [
  'greetings',
  'daily',
  'travel',
  'shopping',
  'numbers'
];

/// Day-number since the Unix epoch (deterministic integer the engine schedules
/// against — NOT a wall clock inside the engine; computed once at the UI edge).
int _todayDay() => DateTime.now().toUtc().millisecondsSinceEpoch ~/ 86400000;

String _deckLabel(AppLocalizations tr, String? d) {
  switch (d) {
    case 'daily':
      return tr.lpDeckDaily;
    case 'travel':
      return tr.lpDeckTravel;
    case 'shopping':
      return tr.lpDeckShopping;
    case 'numbers':
      return tr.lpDeckNumbers;
    default:
      return tr.lpDeckGreetings;
  }
}

IconData _deckIcon(String d) {
  switch (d) {
    case 'daily':
      return Icons.wb_sunny_outlined;
    case 'travel':
      return Icons.directions_bus_outlined;
    case 'shopping':
      return Icons.shopping_bag_outlined;
    case 'numbers':
      return Icons.pin_outlined;
    default:
      return Icons.waving_hand_outlined;
  }
}

class _LanguagePartnerScreenState extends State<LanguagePartnerScreen> {
  List<Map<String, dynamic>> _progress = [];
  bool _loading = true, _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
  String? _deck; // null → deck picker
  String _direction = 'bn2en';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      _progress = await context.read<AppState>().api.listItems(_progressPath);
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(msg)));

  Map<String, dynamic>? _rowFor(String cardId) {
    for (final r in _progress) {
      if (r['card_id'] == cardId) return r;
    }
    return null;
  }

  /// Record a flashcard result: promote (pass) or reset (fail) the Leitner box
  /// and store the next due day. Deterministic via _LpEngine.scheduleReview.
  Future<void> _recordResult(String cardId, String deck, bool passed) async {
    final api = context.read<AppState>().api;
    final existing = _rowFor(cardId);
    final curBox = (existing?['box'] as int?) ?? 1;
    final sched = _LpEngine.scheduleReview(curBox, passed, _todayDay());
    final body = {
      'card_id': cardId,
      'deck': deck,
      'box': sched.box,
      'next_due_day': sched.nextDueDay,
      'reps': ((existing?['reps'] as int?) ?? 0) + 1,
      'last_day': _todayDay(),
    };
    try {
      if (existing != null && existing['id'] is int) {
        await api.updateItem(_progressPath, existing['id'] as int, body);
      } else {
        await api.createItem(_progressPath, body);
      }
      await _load();
    } catch (_) {
      if (mounted) _toast(AppLocalizations.of(context).saveFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
          appBar: AppBar(title: Text(tr.lpTitle)),
          body: const SkeletonList());
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.lpTitle)),
        body: StateMessage(
          icon: Icons.cloud_off,
          tint: scheme.error,
          title: tr.loadFailed,
          message: honestFailText(tr, _failCause, otherwise: tr.lpLoadError),
          action: FilledButton.tonalIcon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: Text(tr.retry)),
        ),
      );
    }
    if (_deck == null) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.lpTitle)),
        body: _DeckPicker(progress: _progress, onPick: (d) {
          setState(() => _deck = d);
        }),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(_deckLabel(tr, _deck)), actions: [
        IconButton(
          tooltip: tr.lpChangeDeck,
          icon: const Icon(Icons.grid_view_outlined),
          onPressed: () => setState(() => _deck = null),
        ),
      ]),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 32),
          children: [
            _DirectionToggle(
              direction: _direction,
              onChanged: (d) => setState(() => _direction = d),
            ),
            const SizedBox(height: Gap.md),
            _DeckHeader(deck: _deck!, progress: _progress),
            const SizedBox(height: Gap.md),
            _FlashcardPractice(
              deck: _deck!,
              direction: _direction,
              progress: _progress,
              onResult: _recordResult,
            ),
            const SizedBox(height: Gap.lg),
            FilledButton.tonalIcon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => _QuizScreen(
                    deck: _deck!, direction: _direction),
              )),
              icon: const Icon(Icons.quiz_outlined),
              label: Text(tr.lpStartQuiz),
            ),
            const SizedBox(height: Gap.md),
            const _LiveSeamCard(),
          ],
        ),
      ),
    );
  }
}

// ======================= deck picker =======================
class _DeckPicker extends StatelessWidget {
  final List<Map<String, dynamic>> progress;
  final void Function(String) onPick;
  const _DeckPicker({required this.progress, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final today = _todayDay();
    return ListView(
      padding: const EdgeInsets.all(Gap.lg),
      children: [
        if (progress.isEmpty) ...[
          const SizedBox(height: Gap.lg),
          Icon(Icons.translate, size: 56, color: scheme.primary),
          const SizedBox(height: Gap.md),
          Text(tr.lpWelcomeTitle,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.sm),
          Text(tr.lpWelcomeBody,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
          const SizedBox(height: Gap.xl),
        ],
        Text(tr.lpPickDeck, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: Gap.md),
        for (final d in _deckKeys)
          Builder(builder: (context) {
            final dp = _LpEngine.deckProgress(d, progress);
            final due = _LpEngine
                .dueCards(progress, today)
                .where((id) => _LpEngine.deckOf(id) == d)
                .length;
            return Card(
              margin: const EdgeInsets.only(bottom: Gap.sm),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: scheme.primaryContainer,
                  child:
                      Icon(_deckIcon(d), color: scheme.onPrimaryContainer),
                ),
                title: Text(_deckLabel(tr, d)),
                subtitle: Text(tr.lpDeckProgress(dp.started, dp.total)),
                trailing: due > 0
                    ? Chip(
                        label: Text('$due',
                            style: const TextStyle(fontSize: 12)),
                        backgroundColor: Brand.blue.withValues(alpha: 0.15),
                        visualDensity: VisualDensity.compact,
                      )
                    : const Icon(Icons.chevron_right),
                onTap: () => onPick(d),
              ),
            );
          }),
      ],
    );
  }
}

// ======================= direction toggle =======================
class _DirectionToggle extends StatelessWidget {
  final String direction;
  final void Function(String) onChanged;
  const _DirectionToggle({required this.direction, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return SegmentedButton<String>(
      segments: [
        ButtonSegment(value: 'bn2en', label: Text(tr.lpDirBn2En)),
        ButtonSegment(value: 'en2bn', label: Text(tr.lpDirEn2Bn)),
      ],
      selected: {direction},
      onSelectionChanged: (s) => onChanged(s.first),
    );
  }
}

// ======================= deck header =======================
class _DeckHeader extends StatelessWidget {
  final String deck;
  final List<Map<String, dynamic>> progress;
  const _DeckHeader({required this.deck, required this.progress});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final dp = _LpEngine.deckProgress(deck, progress);
    final due = _LpEngine
        .dueCards(progress, _todayDay())
        .where((id) => _LpEngine.deckOf(id) == deck)
        .length;
    return Card(
      color: Brand.purple.withValues(alpha: 0.10),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(children: [
          Icon(Icons.layers_outlined, color: Brand.purple),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(due > 0 ? tr.lpDueCount(due) : tr.lpNoDue,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(
                      '${tr.lpDeckProgress(dp.started, dp.total)}  ·  ${tr.lpMasteredCount(dp.mastered)}',
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant)),
                ]),
          ),
        ]),
      ),
    );
  }
}

// ======================= flashcard practice =======================
class _FlashcardPractice extends StatefulWidget {
  final String deck, direction;
  final List<Map<String, dynamic>> progress;
  final Future<void> Function(String cardId, String deck, bool passed) onResult;
  const _FlashcardPractice(
      {required this.deck,
      required this.direction,
      required this.progress,
      required this.onResult});

  @override
  State<_FlashcardPractice> createState() => _FlashcardPracticeState();
}

class _FlashcardPracticeState extends State<_FlashcardPractice> {
  bool _revealed = false;

  List<String> get _queue {
    // Due cards for this deck first; if none are due, fall back to the full
    // deck so the user can still practise. Deterministic order.
    final due = _LpEngine
        .dueCards(widget.progress, _todayDay())
        .where((id) => _LpEngine.deckOf(id) == widget.deck)
        .toList();
    if (due.isNotEmpty) return due;
    return _LpEngine.cardIdsFor(widget.deck);
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final queue = _queue;
    if (queue.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Text(tr.lpDeckDone,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
      );
    }
    final cardId = queue.first;
    final pa = _LpEngine.promptAnswer(cardId, widget.direction);
    final row = () {
      for (final r in widget.progress) {
        if (r['card_id'] == cardId) return r;
      }
      return null;
    }();
    final box = (row?['box'] as int?) ?? 1;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Text(tr.lpFlashcards,
                style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            Text(tr.lpBoxLabel(box),
                style: TextStyle(
                    fontSize: 12, color: scheme.onSurfaceVariant)),
          ]),
          const SizedBox(height: Gap.lg),
          GestureDetector(
            onTap: () => setState(() => _revealed = !_revealed),
            child: Container(
              constraints: const BoxConstraints(minHeight: 120),
              alignment: Alignment.center,
              padding: const EdgeInsets.all(Gap.lg),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(Radii.md),
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(_lpCardText(tr, cardId, pa.promptSide),
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
                if (_revealed) ...[
                  const SizedBox(height: Gap.md),
                  const Divider(),
                  const SizedBox(height: Gap.sm),
                  Text(_lpCardText(tr, cardId, pa.answerSide),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          color: scheme.primary)),
                  const SizedBox(height: Gap.md),
                  _PronHint(hint: pa.hint),
                ] else ...[
                  const SizedBox(height: Gap.sm),
                  Text(tr.lpTapToReveal,
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant)),
                ],
              ]),
            ),
          ),
          const SizedBox(height: Gap.lg),
          if (_revealed)
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                      foregroundColor: Brand.warning),
                  onPressed: () async {
                    await widget.onResult(cardId, widget.deck, false);
                    if (mounted) setState(() => _revealed = false);
                  },
                  icon: const Icon(Icons.replay),
                  label: Text(tr.lpMissedIt),
                ),
              ),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () async {
                    await widget.onResult(cardId, widget.deck, true);
                    if (mounted) setState(() => _revealed = false);
                  },
                  icon: const Icon(Icons.check),
                  label: Text(tr.lpGotIt),
                ),
              ),
            ])
          else
            Text(
              _LpEngine.nextDueHint(tr, box),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
            ),
        ]),
      ),
    );
  }
}

// ======================= pronunciation hint =======================
class _PronHint extends StatelessWidget {
  final String hint;
  const _PronHint({required this.hint});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (hint.isEmpty) return const SizedBox.shrink();
    return Column(children: [
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.volume_up_outlined, size: 16, color: scheme.secondary),
        const SizedBox(width: 4),
        Text('${tr.lpPronHint}: $hint',
            style: TextStyle(
                fontSize: 14,
                fontStyle: FontStyle.italic,
                color: scheme.secondary)),
      ]),
      const SizedBox(height: 2),
      Text(tr.lpHintMarker,
          style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant)),
    ]);
  }
}

// ======================= live seam (key-gated) =======================
class _LiveSeamCard extends StatelessWidget {
  const _LiveSeamCard();

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.secondaryContainer.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.forum_outlined, size: 20, color: scheme.secondary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr.lpLiveSeamTitle,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(tr.lpLiveSeamBody,
                      style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                          height: 1.35)),
                ]),
          ),
        ]),
      ),
    );
  }
}

// ======================= quiz screen =======================
class _QuizScreen extends StatefulWidget {
  final String deck, direction;
  const _QuizScreen({required this.deck, required this.direction});
  @override
  State<_QuizScreen> createState() => _QuizScreenState();
}

class _QuizScreenState extends State<_QuizScreen> {
  late final _Quiz _quiz;
  int _index = 0;
  int? _picked;
  final List<int> _answers = [];

  @override
  void initState() {
    super.initState();
    // deterministic quiz (seed 0); mirror of language_partner.quiz
    _quiz = _LpEngine.quiz(widget.deck, widget.direction, 0);
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final qs = _quiz.questions;
    if (qs.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.lpQuiz)),
        body: StateMessage(
          icon: Icons.quiz_outlined,
          title: tr.lpQuiz,
          message: tr.lpDeckDone,
        ),
      );
    }
    if (_index >= qs.length) {
      final g = _LpEngine.gradeQuiz(qs, _answers);
      return Scaffold(
        appBar: AppBar(title: Text(tr.lpQuizDone)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(Gap.xxl),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(
                  g.percent >= 70
                      ? Icons.celebration_outlined
                      : Icons.menu_book_outlined,
                  size: 56,
                  color: g.percent >= 70 ? Brand.success : scheme.primary),
              const SizedBox(height: Gap.md),
              Text(tr.lpQuizScore(g.correct, g.total),
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: Gap.sm),
              Text('${g.percent}%',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: g.percent >= 70 ? Brand.success : Brand.blue)),
              if (g.wrongCardIds.isNotEmpty) ...[
                const SizedBox(height: Gap.md),
                Text(tr.lpQuizReview,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              ],
              const SizedBox(height: Gap.lg),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(tr.lpFinish),
              ),
            ]),
          ),
        ),
      );
    }

    final q = qs[_index];
    final answered = _picked != null;
    return Scaffold(
      appBar: AppBar(
          title: Text('${tr.lpQuiz}  ${_index + 1}/${qs.length}')),
      body: ListView(
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: Text(_lpSideKey(tr, q.prompt),
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(height: Gap.md),
          for (var i = 0; i < q.options.length; i++)
            _OptionTile(
              text: _lpSideKey(tr, q.options[i]),
              state: !answered
                  ? _OptState.idle
                  : (i == q.answerIndex
                      ? _OptState.correct
                      : (i == _picked ? _OptState.wrong : _OptState.idle)),
              onTap: answered ? null : () => setState(() => _picked = i),
            ),
          if (answered) ...[
            const SizedBox(height: Gap.sm),
            Text(
                _picked == q.answerIndex ? tr.lpCorrect : tr.lpWrong,
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: _picked == q.answerIndex
                        ? Brand.success
                        : Brand.danger)),
            _PronHint(hint: q.hint),
            const SizedBox(height: Gap.md),
            FilledButton.icon(
              onPressed: () {
                _answers.add(_picked ?? -1);
                setState(() {
                  _index++;
                  _picked = null;
                });
              },
              icon: Icon(_index + 1 >= qs.length
                  ? Icons.flag_outlined
                  : Icons.arrow_forward),
              label: Text(_index + 1 >= qs.length ? tr.lpFinish : tr.lpNext),
            ),
          ],
        ],
      ),
    );
  }
}

enum _OptState { idle, correct, wrong }

class _OptionTile extends StatelessWidget {
  final String text;
  final _OptState state;
  final VoidCallback? onTap;
  const _OptionTile(
      {required this.text, required this.state, required this.onTap});

  @override
  Widget build(BuildContext context) {
    Color? bg;
    IconData? icon;
    Color? fg;
    switch (state) {
      case _OptState.correct:
        bg = Brand.success.withValues(alpha: 0.14);
        icon = Icons.check_circle_outline;
        fg = Brand.success;
        break;
      case _OptState.wrong:
        bg = Brand.danger.withValues(alpha: 0.14);
        icon = Icons.cancel_outlined;
        fg = Brand.danger;
        break;
      case _OptState.idle:
        break;
    }
    return Card(
      color: bg,
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: ListTile(
        title: Text(text,
            style: TextStyle(
                color: fg, fontWeight: fg != null ? FontWeight.w600 : null)),
        trailing: icon != null ? Icon(icon, color: fg) : null,
        onTap: onTap,
      ),
    );
  }
}

// =====================================================================
// _LpEngine — a VERBATIM Dart mirror of backend/core/logic/language_partner.py.
// Deterministic; identical inputs -> identical output; the engine takes a
// day-NUMBER (no wall clock inside). ZERO Bangla literals: the deck holds ONLY
// ascii ids + deck + romanised pronunciation hints; bn/en display text resolves
// through _lpCardText (keys lpC_<id>_bn / lpC_<id>_en).
// =====================================================================

class _LpCard {
  final String id, deck, hint;
  const _LpCard(this.id, this.deck, this.hint);
}

class _PromptAnswer {
  final String id, direction, promptSide, answerSide, hint;
  const _PromptAnswer(
      this.id, this.direction, this.promptSide, this.answerSide, this.hint);
}

class _Schedule {
  final int box, intervalDays, nextDueDay;
  const _Schedule(this.box, this.intervalDays, this.nextDueDay);
}

class _DeckProgress {
  final int started, total, mastered;
  final double avgBox;
  const _DeckProgress(this.started, this.total, this.mastered, this.avgBox);
}

class _QuizQ {
  final String cardId, prompt, hint;
  final List<String> options;
  final int answerIndex;
  const _QuizQ(
      this.cardId, this.prompt, this.options, this.answerIndex, this.hint);
}

class _Quiz {
  final String deck, direction;
  final List<_QuizQ> questions;
  const _Quiz(this.deck, this.direction, this.questions);
}

class _QuizGrade {
  final int correct, total, percent;
  final List<String> wrongCardIds;
  const _QuizGrade(this.correct, this.total, this.percent, this.wrongCardIds);
}

/// Resolve a side-key of the form "<cardId>_<bn|en>" (as the quiz stores its
/// prompt/options) to localised display text. The side is the last segment.
String _lpSideKey(AppLocalizations tr, String sideKey) {
  final cut = sideKey.lastIndexOf('_');
  if (cut < 0) return '';
  return _lpCardText(tr, sideKey.substring(0, cut), sideKey.substring(cut + 1));
}

/// Side of a card to render: 'bn' or 'en'. Resolves lpC_<id>_<side> by locale.
String _lpCardText(AppLocalizations tr, String id, String side) {
  final key = '${id}_$side';
  switch (key) {
    case 'g_hello_bn':
      return tr.lpC_g_hello_bn;
    case 'g_hello_en':
      return tr.lpC_g_hello_en;
    case 'g_howareyou_bn':
      return tr.lpC_g_howareyou_bn;
    case 'g_howareyou_en':
      return tr.lpC_g_howareyou_en;
    case 'g_fine_bn':
      return tr.lpC_g_fine_bn;
    case 'g_fine_en':
      return tr.lpC_g_fine_en;
    case 'g_thanks_bn':
      return tr.lpC_g_thanks_bn;
    case 'g_thanks_en':
      return tr.lpC_g_thanks_en;
    case 'g_welcome_bn':
      return tr.lpC_g_welcome_bn;
    case 'g_welcome_en':
      return tr.lpC_g_welcome_en;
    case 'd_water_bn':
      return tr.lpC_d_water_bn;
    case 'd_water_en':
      return tr.lpC_d_water_en;
    case 'd_food_bn':
      return tr.lpC_d_food_bn;
    case 'd_food_en':
      return tr.lpC_d_food_en;
    case 'd_rice_bn':
      return tr.lpC_d_rice_bn;
    case 'd_rice_en':
      return tr.lpC_d_rice_en;
    case 'd_sleep_bn':
      return tr.lpC_d_sleep_bn;
    case 'd_sleep_en':
      return tr.lpC_d_sleep_en;
    case 'd_today_bn':
      return tr.lpC_d_today_bn;
    case 'd_today_en':
      return tr.lpC_d_today_en;
    case 't_where_bn':
      return tr.lpC_t_where_bn;
    case 't_where_en':
      return tr.lpC_t_where_en;
    case 't_howmuch_bn':
      return tr.lpC_t_howmuch_bn;
    case 't_howmuch_en':
      return tr.lpC_t_howmuch_en;
    case 't_left_bn':
      return tr.lpC_t_left_bn;
    case 't_left_en':
      return tr.lpC_t_left_en;
    case 't_right_bn':
      return tr.lpC_t_right_bn;
    case 't_right_en':
      return tr.lpC_t_right_en;
    case 't_stop_bn':
      return tr.lpC_t_stop_bn;
    case 't_stop_en':
      return tr.lpC_t_stop_en;
    case 's_price_bn':
      return tr.lpC_s_price_bn;
    case 's_price_en':
      return tr.lpC_s_price_en;
    case 's_expensive_bn':
      return tr.lpC_s_expensive_bn;
    case 's_expensive_en':
      return tr.lpC_s_expensive_en;
    case 's_buy_bn':
      return tr.lpC_s_buy_bn;
    case 's_buy_en':
      return tr.lpC_s_buy_en;
    case 's_bag_bn':
      return tr.lpC_s_bag_bn;
    case 's_bag_en':
      return tr.lpC_s_bag_en;
    case 'n_one_bn':
      return tr.lpC_n_one_bn;
    case 'n_one_en':
      return tr.lpC_n_one_en;
    case 'n_two_bn':
      return tr.lpC_n_two_bn;
    case 'n_two_en':
      return tr.lpC_n_two_en;
    case 'n_three_bn':
      return tr.lpC_n_three_bn;
    case 'n_three_en':
      return tr.lpC_n_three_en;
    case 'n_ten_bn':
      return tr.lpC_n_ten_bn;
    case 'n_ten_en':
      return tr.lpC_n_ten_en;
    case 'n_hundred_bn':
      return tr.lpC_n_hundred_bn;
    case 'n_hundred_en':
      return tr.lpC_n_hundred_en;
    default:
      return '';
  }
}

class _LpEngine {
  static const int maxBox = 5;
  static const int minBox = 1;
  static const Map<int, int> boxDays = {1: 1, 2: 2, 3: 4, 4: 7, 5: 15};

  // Deck mirrors language_partner.DECK: ascii id + deck + romanised hint only.
  static const List<_LpCard> deck = [
    _LpCard('g_hello', 'greetings', 'hyalo'),
    _LpCard('g_howareyou', 'greetings', 'kemon aachhen?'),
    _LpCard('g_fine', 'greetings', 'aami bhalo aachhi'),
    _LpCard('g_thanks', 'greetings', 'dhonnobaad'),
    _LpCard('g_welcome', 'greetings', 'shagotom'),
    _LpCard('d_water', 'daily', 'paani'),
    _LpCard('d_food', 'daily', 'khaabaar'),
    _LpCard('d_rice', 'daily', 'bhaat'),
    _LpCard('d_sleep', 'daily', 'ghum'),
    _LpCard('d_today', 'daily', 'aaj'),
    _LpCard('t_where', 'travel', 'kothaay?'),
    _LpCard('t_howmuch', 'travel', 'koto dur?'),
    _LpCard('t_left', 'travel', 'baam'),
    _LpCard('t_right', 'travel', 'daan'),
    _LpCard('t_stop', 'travel', 'thaamun'),
    _LpCard('s_price', 'shopping', 'daam koto?'),
    _LpCard('s_expensive', 'shopping', 'onek daam'),
    _LpCard('s_buy', 'shopping', 'aami kinbo'),
    _LpCard('s_bag', 'shopping', 'byaag'),
    _LpCard('n_one', 'numbers', 'ek'),
    _LpCard('n_two', 'numbers', 'dui'),
    _LpCard('n_three', 'numbers', 'tin'),
    _LpCard('n_ten', 'numbers', 'dosh'),
    _LpCard('n_hundred', 'numbers', 'eksho'),
  ];

  static List<_LpCard> cardsFor(String d) =>
      deck.where((c) => c.deck == d).toList();

  static List<String> cardIdsFor(String d) =>
      cardsFor(d).map((c) => c.id).toList();

  static String deckOf(String cardId) {
    for (final c in deck) {
      if (c.id == cardId) return c.deck;
    }
    return '';
  }

  static _LpCard _card(String id) {
    for (final c in deck) {
      if (c.id == id) return c;
    }
    return const _LpCard('', '', '');
  }

  static int dueAfterDays(int box) {
    final b = box.clamp(minBox, maxBox);
    return boxDays[b]!;
  }

  static _PromptAnswer promptAnswer(String cardId, String direction) {
    final c = _card(cardId);
    // promptSide / answerSide name which stored side to render via _lpCardText.
    if (direction == 'en2bn') {
      return _PromptAnswer(c.id, 'en2bn', 'en', 'bn', c.hint);
    }
    return _PromptAnswer(c.id, 'bn2en', 'bn', 'en', c.hint);
  }

  static _Schedule scheduleReview(int box, bool passed, int todayDay) {
    final cur = box.clamp(minBox, maxBox);
    final nxt = passed ? (cur + 1).clamp(minBox, maxBox) : minBox;
    final interval = dueAfterDays(nxt);
    return _Schedule(nxt, interval, todayDay + interval);
  }

  static List<String> dueCards(
      List<Map<String, dynamic>> progress, int todayDay) {
    final byId = <String, Map<String, dynamic>>{};
    for (final p in progress) {
      final cid = p['card_id'];
      if (cid is String) byId[cid] = p;
    }
    final due = <String>[];
    for (final c in deck) {
      final p = byId[c.id];
      if (p == null) {
        due.add(c.id); // never studied -> due
      } else if (((p['next_due_day'] as int?) ?? 0) <= todayDay) {
        due.add(c.id);
      }
    }
    return due;
  }

  static _DeckProgress deckProgress(
      String d, List<Map<String, dynamic>> progress) {
    final pool = cardsFor(d);
    final byId = <String, Map<String, dynamic>>{};
    for (final p in progress) {
      final cid = p['card_id'];
      if (cid is String) byId[cid] = p;
    }
    final started = pool.where((c) => byId.containsKey(c.id)).toList();
    final boxes = started
        .map((c) => ((byId[c.id]!['box'] as int?) ?? 1).clamp(minBox, maxBox))
        .toList();
    final avg = boxes.isEmpty
        ? 0.0
        : double.parse(
            (boxes.reduce((a, b) => a + b) / boxes.length).toStringAsFixed(2));
    final mastered = boxes.where((b) => b >= maxBox).length;
    return _DeckProgress(started.length, pool.length, mastered, avg);
  }

  static String nextDueHint(AppLocalizations tr, int box) =>
      tr.lpNextReview(dueAfterDays(box));

  static _Quiz quiz(String d, String direction, int seed) {
    final pool = cardsFor(d);
    if (pool.length < 2) return _Quiz(d, direction, const []);
    final n = pool.length;
    String ansOf(_LpCard c) => direction == 'en2bn' ? '${c.id}_bn' : '${c.id}_en';
    String promptSideOf() => direction == 'en2bn' ? 'en' : 'bn';
    // answers/options carry side-keys; the UI resolves text via _lpCardText.
    final questions = <_QuizQ>[];
    for (var i = 0; i < n; i++) {
      final c = pool[i];
      final others = [
        for (var j = 0; j < n - 1; j++) pool[(i + 1 + j + seed) % n]
      ];
      final distractors = others
          .map(ansOf)
          .where((a) => a != ansOf(c))
          .take(3)
          .toList();
      var options = <String>[ansOf(c), ...distractors];
      final pos = (i + seed) % options.length;
      if (pos != 0) {
        options = [
          ...options.sublist(options.length - pos),
          ...options.sublist(0, options.length - pos)
        ];
      }
      final answerIndex = options.indexOf(ansOf(c));
      questions.add(_QuizQ(
        c.id,
        '', // prompt resolved below via side-key for i18n
        options,
        answerIndex,
        c.hint,
      ));
    }
    // Resolve prompt + option display text lazily in the widget layer would
    // require context; instead we store side-keys and expose a resolver.
    return _Quiz(d, direction,
        [for (final q in questions) _resolvePrompt(q, promptSideOf())]);
  }

  static _QuizQ _resolvePrompt(_QuizQ q, String promptSide) =>
      _QuizQ(q.cardId, '${q.cardId}_$promptSide', q.options, q.answerIndex,
          q.hint);

  static _QuizGrade gradeQuiz(List<_QuizQ> questions, List<int> answers) {
    final total = questions.length;
    var correct = 0;
    final wrong = <String>[];
    for (var i = 0; i < total; i++) {
      final chosen = i < answers.length ? answers[i] : -1;
      if (chosen == questions[i].answerIndex) {
        correct++;
      } else {
        wrong.add(questions[i].cardId);
      }
    }
    return _QuizGrade(
        correct, total, total == 0 ? 0 : (100 * correct / total).round(), wrong);
  }
}
