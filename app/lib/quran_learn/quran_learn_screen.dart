// quranread (owner order 3 Nov 11:45, part B, flag quran_learn): Learn to read
// the Quran - Noorani-method ORDER (letters + makhraj, harakat, tanween, jazm,
// tashdeed, madd, words, ayat, basic tajweed), our own lessons
// (lib/l10n/quran_learn_content.dart), big Arabic letters (Amiri Quran, OFL),
// Bangla explanations, "Listen" (honest: no licensed audio yet) and
// "I read, check me" (phone speech-to-text letter matching, labelled a helper,
// not a teacher). Progress steps + daily goal; no ads; core learning free;
// EXPERIMENTAL until a qualified Qari reviews the lessons.
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../l10n/quran_learn_content.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';
import '../widgets/local_digits.dart';
import 'learn_progress.dart';
import 'qaida_audio.dart';
import 'qaida_model.dart';
import 'recite_check.dart';
import 'recite_sheet.dart';
import 'uthmani_text.dart';

bool _bn(BuildContext c) => Localizations.localeOf(c).languageCode == 'bn';

String _date(BuildContext c, String ymd) {
  final d = DateTime.tryParse(ymd);
  if (d == null) return ld(c, ymd);
  return ld(c, '${d.day}/${d.month}/${d.year}');
}

// ------------------------------------------------------------------- home
class QuranLearnScreen extends StatefulWidget {
  /// Tests / gallery: start from this progress instead of the saved one.
  final QlProgress? progress;
  const QuranLearnScreen({super.key, this.progress});

  @override
  State<QuranLearnScreen> createState() => _QuranLearnScreenState();
}

class _QuranLearnScreenState extends State<QuranLearnScreen> {
  QlProgress? _p;

  @override
  void initState() {
    super.initState();
    _p = widget.progress;
    if (_p == null) _load();
  }

  Future<void> _load() async {
    final p = await QlProgressStore.load();
    if (mounted) setState(() => _p = p);
  }

  Future<void> _open(QlStage s, QlLesson l) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => QuranLessonScreen(stage: s, lesson: l, progress: _p)));
    if (!mounted) return;
    if (widget.progress != null) {
      setState(() {}); // shared object, already updated
    } else {
      await _load();
    }
  }

  Future<void> _pickGoal() async {
    final p = _p;
    if (p == null) return;
    final g = await showAppSheet<int>(
      context: context,
      builder: (ctx) {
        final t = AppLocalizations.of(ctx);
        return Column(
          key: const Key('ql-goal-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: Text(t.qlGoalTitle, style: AType.titleLarge),
            ),
            for (final n in QlProgress.goals)
              ListTile(
                key: Key('ql-goal-$n'),
                minTileHeight: kMinTap,
                leading: Icon(n == p.goal
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded),
                title: Text(t.qlGoalItems(ld(ctx, n))),
                selected: n == p.goal,
                onTap: () => Navigator.of(ctx).pop(n),
              ),
            const SizedBox(height: Gap.md),
          ],
        );
      },
    );
    if (g == null || !mounted) return;
    setState(() => p.goal = g);
    await QlProgressStore.save(p);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final p = _p;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.qlTitle),
        actions: [
          IconButton(
            key: const Key('ql-about'),
            tooltip: t.qlAbout,
            icon: const Icon(Icons.info_outline_rounded),
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const QuranLearnAboutScreen())),
          ),
        ],
      ),
      body: p == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              key: const Key('ql-home'),
              padding: withNavBarInset(context, const EdgeInsets.all(Gap.md)),
              children: [
                const QlExperimentalBanner(),
                const SizedBox(height: Gap.md),
                _todayCard(t, p),
                const SizedBox(height: Gap.md),
                _continueCard(t, p),
                for (final course in const [kCourseQaida, kCourseNazera]) ...[
                  const SizedBox(height: Gap.lg),
                  _courseHeader(t, p, course),
                  const SizedBox(height: Gap.sm),
                  for (final s in kQlStages.where((s) => s.course == course))
                    _stageTile(t, p, s),
                ],
                const SizedBox(height: Gap.lg),
                Row(children: [
                  Icon(Icons.volunteer_activism_rounded,
                      size: 20, color: AssistoTokens.of(context).textMuted),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Text(t.qlFreeNoAds,
                        style: AType.bodySmall
                            .copyWith(color: AssistoTokens.of(context).textMuted)),
                  ),
                ]),
              ],
            ),
    );
  }

  Widget _todayCard(AppLocalizations t, QlProgress p) {
    final now = DateTime.now();
    final done = p.today(now);
    final streak = p.streak(now);
    final cs = Theme.of(context).colorScheme;
    return Card(
      key: const Key('ql-today'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(children: [
          SizedBox(
            width: 64,
            height: 64,
            child: Stack(alignment: Alignment.center, children: [
              SizedBox.expand(
                child: CircularProgressIndicator(
                  value: (done / p.goal).clamp(0.0, 1.0).toDouble(),
                  strokeWidth: 6,
                  backgroundColor: cs.surfaceContainerHighest,
                ),
              ),
              if (done >= p.goal)
                Icon(Icons.check_rounded, color: cs.primary)
              else
                Text(ld(context, done), style: AType.titleMedium),
            ]),
          ),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.qlToday(ld(context, done), ld(context, p.goal)),
                  style: AType.titleMedium.copyWith(fontWeight: FontWeight.w600)),
              Text(
                  done >= p.goal
                      ? t.qlGoalDone
                      : (streak > 0 ? t.qlStreak(ld(context, streak)) : t.qlNoStreak),
                  style: AType.bodyMedium),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  key: const Key('ql-goal'),
                  style: TextButton.styleFrom(
                      minimumSize: const Size(kMinTap, kMinTap),
                      padding: const EdgeInsets.symmetric(horizontal: Gap.sm)),
                  onPressed: _pickGoal,
                  child: Text(t.qlGoalChange),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _continueCard(AppLocalizations t, QlProgress p) {
    final bn = _bn(context);
    final next = p.nextLesson();
    if (next == null) {
      return Card(
        margin: EdgeInsets.zero,
        child: ListTile(
          leading: const Icon(Icons.emoji_events_rounded),
          title: Text(t.qlAllDone),
        ),
      );
    }
    // Last opened lesson if it still has work, else the first unfinished one.
    var target = next;
    for (final s in kQlStages) {
      for (final l in s.lessons) {
        if (l.id == p.lastLesson && !p.lessonDone(l)) target = (stage: s, lesson: l);
      }
    }
    final fresh = p.learned.isEmpty && p.lastLesson == null;
    return FilledButton.icon(
      key: const Key('ql-continue'),
      style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(56),
          alignment: AlignmentDirectional.centerStart,
          padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm)),
      onPressed: () => _open(target.stage, target.lesson),
      icon: Icon(fresh ? Icons.play_arrow_rounded : Icons.history_edu_rounded),
      label: Text(fresh ? t.qlStart : t.qlContinue(target.lesson.title.of(bn))),
    );
  }

  Widget _courseHeader(AppLocalizations t, QlProgress p, String course) {
    final doneOn = p.done[course];
    return Row(children: [
      Expanded(
        child: Text(course == kCourseQaida ? t.qlCourseQaida : t.qlCourseNazera,
            style: AType.titleMedium.copyWith(fontWeight: FontWeight.w600)),
      ),
      if (doneOn != null)
        Flexible(
          child: Text(t.qlCourseDone(_date(context, doneOn)),
              textAlign: TextAlign.end,
              style: AType.labelMedium
                  .copyWith(color: AssistoTokens.of(context).success)),
        ),
    ]);
  }

  Widget _stageTile(AppLocalizations t, QlProgress p, QlStage s) {
    final bn = _bn(context);
    final cs = Theme.of(context).colorScheme;
    final total = p.stageTotal(s), got = p.stageLearned(s);
    final done = got == total;
    return Card(
      key: Key('ql-stage-${s.n}'),
      margin: const EdgeInsets.only(bottom: Gap.sm),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: CircleAvatar(
          backgroundColor: done ? AssistoTokens.of(context).success : cs.primaryContainer,
          foregroundColor: done ? Colors.white : cs.onPrimaryContainer,
          child: done
              ? const Icon(Icons.check_rounded)
              : Text(ld(context, s.n), style: AType.titleMedium),
        ),
        title: Text(s.title.of(bn), style: AType.titleMedium),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s.summary.of(bn), style: AType.bodySmall),
          const SizedBox(height: Gap.xs),
          LinearProgressIndicator(value: total == 0 ? 0 : got / total),
          const SizedBox(height: Gap.xxs),
          Text(t.qlProgress(ld(context, got), ld(context, total)),
              style: AType.labelSmall),
        ]),
        children: [
          for (final l in s.lessons)
            ListTile(
              key: Key('ql-lesson-${l.id}'),
              minTileHeight: kMinTap,
              title: Text(l.title.of(bn)),
              trailing: p.lessonDone(l)
                  ? Icon(Icons.check_circle_rounded,
                      color: AssistoTokens.of(context).success,
                      semanticLabel: t.qlLearned)
                  : Text(ld(context, '${p.learnedIn(l)}/${l.items.length}')),
              onTap: () => _open(s, l),
            ),
        ],
      ),
    );
  }
}

class QlExperimentalBanner extends StatelessWidget {
  const QlExperimentalBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final tok = AssistoTokens.of(context);
    return Container(
      key: const Key('ql-experimental'),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
          color: tok.warningContainer, borderRadius: BorderRadius.circular(Radii.md)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.science_outlined, color: tok.onWarningContainer),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.qlExperimentalTitle,
                style: AType.titleSmall.copyWith(
                    color: tok.onWarningContainer, fontWeight: FontWeight.w700)),
            Text(t.qlExperimentalBody,
                style: AType.bodySmall.copyWith(color: tok.onWarningContainer)),
          ]),
        ),
      ]),
    );
  }
}

// ----------------------------------------------------------------- lesson
class QuranLessonScreen extends StatefulWidget {
  final QlStage stage;
  final QlLesson lesson;
  final QlProgress? progress;
  const QuranLessonScreen(
      {super.key, required this.stage, required this.lesson, this.progress});

  @override
  State<QuranLessonScreen> createState() => _QuranLessonScreenState();
}

class _QuranLessonScreenState extends State<QuranLessonScreen> {
  QlProgress? _p;
  UthmaniText? _u;
  Object? _err;
  int _sel = 0;

  bool get _needsText => widget.lesson.items.any((i) => i.ref != null);

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final p = widget.progress ?? await QlProgressStore.load();
    p.lastLesson = widget.lesson.id;
    if (!mounted) return;
    setState(() => _p = p);
    unawaitedSave(p);
    if (_needsText) await _loadText();
  }

  void unawaitedSave(QlProgress p) {
    QlProgressStore.save(p);
  }

  Future<void> _loadText() async {
    setState(() => _err = null);
    try {
      final u = await UthmaniText.load();
      if (mounted) setState(() => _u = u);
    } catch (e) {
      if (mounted) setState(() => _err = e);
    }
  }

  String _text(QlItem i) => i.ar ?? (_u?.text(i.ref!) ?? '');

  void _toggle(QlItem i) {
    final p = _p;
    if (p == null) return;
    final t = AppLocalizations.of(context);
    final before = p.today(DateTime.now());
    final doneBefore = Set.of(p.done.keys);
    final wasLesson = p.lessonDone(widget.lesson);
    setState(() => p.toggle(i.id, DateTime.now()));
    unawaitedSave(p);
    final m = ScaffoldMessenger.maybeOf(context);
    if (m == null) return;
    String? msg;
    if (p.done.keys.any((c) => !doneBefore.contains(c))) {
      msg = t.qlCourseCompleted;
    } else if (!wasLesson && p.lessonDone(widget.lesson)) {
      msg = t.qlLessonDone;
    } else if (before < p.goal && p.today(DateTime.now()) >= p.goal) {
      msg = t.qlGoalDone;
    }
    if (msg != null) {
      m.clearSnackBars();
      m.showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _check(QlItem i) async {
    final text = _text(i);
    await showReciteSheet(
      context,
      expected: text,
      alsoAccept: i.check == null ? const [] : [i.check!],
      letterName: i.check != null,
      onScore: (s) {
        final p = _p;
        if (p == null) return;
        p.recordScore(i.id, s);
        unawaitedSave(p);
      },
    );
  }

  ({QlStage stage, QlLesson lesson})? _nextLesson() {
    var seen = false;
    for (final s in kQlStages) {
      for (final l in s.lessons) {
        if (seen) return (stage: s, lesson: l);
        if (l.id == widget.lesson.id) seen = true;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final bn = _bn(context);
    final p = _p;
    final l = widget.lesson;
    Widget body;
    if (p == null || (_needsText && _u == null && _err == null)) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_needsText && _u == null) {
      body = ListView(
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        children: [
          const Icon(Icons.menu_book_rounded, size: 48),
          const SizedBox(height: Gap.md),
          Text(t.qlLoadFailed, textAlign: TextAlign.center),
          const SizedBox(height: Gap.md),
          Center(
            child: FilledButton(
                key: const Key('ql-retry'),
                onPressed: _loadText,
                child: Text(t.qlRetry)),
          ),
        ],
      );
    } else {
      final got = p.learnedIn(l);
      final next = _nextLesson();
      body = ListView(
        key: Key('ql-lesson-body-${l.id}'),
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.md)),
        children: [
          Text(t.qlStageN(ld(context, widget.stage.n), widget.stage.title.of(bn)),
              style: AType.labelLarge
                  .copyWith(color: Theme.of(context).colorScheme.primary)),
          const SizedBox(height: Gap.xs),
          Text(l.intro.of(bn), style: AType.bodyLarge),
          const SizedBox(height: Gap.md),
          if (l.grid) ...[
            _focusCard(t, p, l.items[_sel < l.items.length ? _sel : 0]),
            const SizedBox(height: Gap.md),
            Text(t.qlTapLetter, style: AType.bodySmall),
            const SizedBox(height: Gap.sm),
            _grid(t, p, l),
          ] else
            for (final i in l.items) _itemCard(t, p, i),
          const SizedBox(height: Gap.lg),
          LinearProgressIndicator(value: got / l.items.length),
          const SizedBox(height: Gap.xs),
          Text(t.qlProgress(ld(context, got), ld(context, l.items.length)),
              style: AType.bodySmall),
          if (p.lessonDone(l) && next != null) ...[
            const SizedBox(height: Gap.md),
            FilledButton.icon(
              key: const Key('ql-next-lesson'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(kMinTap)),
              icon: const Icon(Icons.arrow_forward_rounded),
              label: Text(t.qlNextLessonNamed(next.lesson.title.of(bn))),
              onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute(
                  builder: (_) => QuranLessonScreen(
                      stage: next.stage, lesson: next.lesson, progress: widget.progress))),
            ),
          ],
          if (_u != null) ...[
            const SizedBox(height: Gap.md),
            Text(t.qlTanzilCredit,
                style: AType.bodySmall
                    .copyWith(color: AssistoTokens.of(context).textMuted)),
          ],
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(l.title.of(bn)),
        actions: [
          IconButton(
            tooltip: t.qlAbout,
            icon: const Icon(Icons.info_outline_rounded),
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const QuranLearnAboutScreen())),
          ),
        ],
      ),
      body: body,
    );
  }

  Widget _grid(AppLocalizations t, QlProgress p, QlLesson l) {
    final cs = Theme.of(context).colorScheme;
    final bn = _bn(context);
    return Wrap(
      key: const Key('ql-grid'),
      textDirection: TextDirection.rtl,
      spacing: Gap.sm,
      runSpacing: Gap.sm,
      children: [
        for (var k = 0; k < l.items.length; k++)
          Semantics(
            button: true,
            selected: k == _sel,
            label: l.items[k].say?.of(bn),
            child: InkWell(
              key: Key('ql-tile-${l.items[k].id}'),
              borderRadius: BorderRadius.circular(Radii.md),
              onTap: () => setState(() => _sel = k),
              child: Container(
                constraints: const BoxConstraints(minWidth: 72, minHeight: 72),
                padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                decoration: BoxDecoration(
                  color: k == _sel ? cs.primaryContainer : cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(Radii.md),
                  border: Border.all(
                      color: k == _sel ? cs.primary : Colors.transparent, width: 2),
                ),
                child: Stack(alignment: Alignment.center, children: [
                  ExcludeSemantics(
                    child: Text(_text(l.items[k]),
                        textDirection: TextDirection.rtl,
                        style: qlArabic(36,
                            color: k == _sel ? cs.onPrimaryContainer : cs.onSurface)),
                  ),
                  if (p.learned.contains(l.items[k].id))
                    PositionedDirectional(
                      top: 2,
                      start: 2,
                      child: Icon(Icons.check_circle_rounded,
                          size: 16, color: AssistoTokens.of(context).success),
                    ),
                ]),
              ),
            ),
          ),
      ],
    );
  }

  Widget _actions(AppLocalizations t, QlProgress p, QlItem i) {
    final text = _text(i);
    final canCheck =
        qlCanCheck(text) || (i.check != null && qlCanCheck(i.check!));
    final learned = p.learned.contains(i.id);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
        OutlinedButton.icon(
          key: Key('ql-listen-${i.id}'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(kMinTap, kMinTap)),
          icon: Icon(qaidaAudioAvailable(i)
              ? Icons.volume_up_rounded
              : Icons.headset_off_rounded),
          label: Text(t.qlListen),
          onPressed: () => showQlNoAudio(context),
        ),
        if (canCheck)
          FilledButton.icon(
            key: Key('ql-check-${i.id}'),
            style: FilledButton.styleFrom(minimumSize: const Size(kMinTap, kMinTap)),
            icon: const Icon(Icons.mic_rounded),
            label: Text(t.qlCheckMe),
            onPressed: () => _check(i),
          ),
      ]),
      if (!canCheck)
        Padding(
          padding: const EdgeInsets.only(top: Gap.xs),
          child: Text(t.qlReciteNoCheck, style: AType.bodySmall),
        ),
      const SizedBox(height: Gap.sm),
      FilledButton.tonalIcon(
        key: Key('ql-learned-${i.id}'),
        style: FilledButton.styleFrom(minimumSize: const Size(kMinTap, kMinTap)),
        icon: Icon(learned ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded),
        label: Text(learned ? t.qlLearned : t.qlMarkLearned),
        onPressed: () => _toggle(i),
      ),
      if (p.best[i.id] != null)
        Padding(
          padding: const EdgeInsets.only(top: Gap.xs),
          child: Text(t.qlBestCheck(ld(context, p.best[i.id])),
              style: AType.bodySmall),
        ),
    ]);
  }

  Widget _focusCard(AppLocalizations t, QlProgress p, QlItem i) {
    final bn = _bn(context);
    final cs = Theme.of(context).colorScheme;
    final n = widget.lesson.items.length;
    return Card(
      key: const Key('ql-focus'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            IconButton(
              tooltip: t.qlPrev,
              icon: const Icon(Icons.chevron_left_rounded),
              onPressed: _sel > 0 ? () => setState(() => _sel--) : null,
            ),
            Expanded(
              child: SizedBox(
                height: 150,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(_text(i),
                      key: const Key('ql-focus-text'),
                      textDirection: TextDirection.rtl,
                      style: qlArabic(96, color: cs.onSurface)),
                ),
              ),
            ),
            IconButton(
              tooltip: t.qlNext,
              icon: const Icon(Icons.chevron_right_rounded),
              onPressed: _sel < n - 1 ? () => setState(() => _sel++) : null,
            ),
          ]),
          if (i.say != null)
            Text(t.qlSay(i.say!.of(bn)),
                textAlign: TextAlign.center,
                style: AType.titleLarge.copyWith(fontWeight: FontWeight.w600)),
          if (i.heavy)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(top: Gap.xs),
                child: Chip(
                  avatar: const Icon(Icons.fitness_center_rounded, size: 16),
                  label: Text(t.qlHeavy),
                ),
              ),
            ),
          if (i.note != null) ...[
            const SizedBox(height: Gap.sm),
            Text(i.note!.of(bn), style: AType.bodyLarge),
          ],
          if (i.ref != null) ...[
            const SizedBox(height: Gap.xs),
            Text(t.qlQuranRef(ld(context, i.ref!.label())), style: AType.bodySmall),
          ],
          const SizedBox(height: Gap.md),
          _actions(t, p, i),
        ]),
      ),
    );
  }

  Widget _itemCard(AppLocalizations t, QlProgress p, QlItem i) {
    final bn = _bn(context);
    final cs = Theme.of(context).colorScheme;
    return Card(
      key: Key('ql-item-${i.id}'),
      margin: const EdgeInsets.only(bottom: Gap.md),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(_text(i),
              textAlign: TextAlign.right,
              textDirection: TextDirection.rtl,
              style: qlArabic(32, color: cs.onSurface)),
          if (i.ref != null)
            Text(t.qlQuranRef(ld(context, i.ref!.label())), style: AType.bodySmall),
          if (i.say != null) ...[
            const SizedBox(height: Gap.xs),
            Text(t.qlSay(i.say!.of(bn)), style: AType.titleMedium),
          ],
          if (i.note != null) ...[
            const SizedBox(height: Gap.xs),
            Text(i.note!.of(bn), style: AType.bodyMedium),
          ],
          const SizedBox(height: Gap.md),
          _actions(t, p, i),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------------ about
class QuranLearnAboutScreen extends StatefulWidget {
  const QuranLearnAboutScreen({super.key});

  static final Uri tanzil = Uri.parse('https://tanzil.net');

  @override
  State<QuranLearnAboutScreen> createState() => _QuranLearnAboutScreenState();
}

class _QuranLearnAboutScreenState extends State<QuranLearnAboutScreen> {
  String? _notice;

  @override
  void initState() {
    super.initState();
    UthmaniText.load().then((u) {
      if (mounted) setState(() => _notice = u.notice);
    }).catchError((Object _) {/* the rest of the page still shows */});
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    Widget item(IconData i, String s) => Padding(
          padding: const EdgeInsets.only(bottom: Gap.md),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(i, size: 22, color: accent),
            const SizedBox(width: Gap.md),
            Expanded(child: Text(s)),
          ]),
        );
    return Scaffold(
      appBar: AppBar(title: Text(t.qlAbout)),
      body: ListView(
        key: const Key('ql-about-body'),
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        children: [
          const QlExperimentalBanner(),
          const SizedBox(height: Gap.lg),
          item(Icons.school_rounded, t.qlAboutMethod),
          item(Icons.menu_book_rounded, t.qlAboutText),
          item(Icons.font_download_rounded, t.qlAboutFont),
          item(Icons.headset_off_rounded, t.qlAboutAudio),
          item(Icons.mic_none_rounded, t.qlAboutVoice),
          item(Icons.translate_rounded, t.qlAboutPron),
          item(Icons.volunteer_activism_rounded, t.qlFreeNoAds),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(kMinTap, kMinTap)),
              icon: const Icon(Icons.open_in_new_rounded),
              label: Text(t.qlOpenTanzil),
              onPressed: () async {
                try {
                  await launchUrl(QuranLearnAboutScreen.tanzil,
                      mode: LaunchMode.externalApplication);
                } catch (_) {/* best-effort: no browser app; the address is shown in the notice */}
              },
            ),
          ),
          if ((_notice ?? '').isNotEmpty) ...[
            const Divider(height: Gap.xl),
            Text(t.qlTanzilNotice,
                style: AType.titleSmall.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: Gap.sm),
            SelectableText(_notice!,
                textDirection: TextDirection.ltr, style: AType.bodySmall),
          ],
        ],
      ),
    );
  }
}
