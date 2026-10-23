import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../widgets/chal_bank.dart';
import '../services/error_kind.dart' show honestFailText; // qa2

/// DAILY CHALLENGES / QUIZ — ADVANCED (#173, §21).
///
/// A daily-engagement feature: one challenge per day, rotated DETERMINISTICALLY
/// from the calendar date so the same day always shows the same item on every
/// device — no sync, no randomness. Answer a quiz or do a tiny task, build a
/// streak, earn points, and keep a history of what you completed.
///
/// The BANK (>=20 curated bilingual items: finance / health / digital-safety /
/// general knowledge) lives in widgets/chal_bank.dart, a VERBATIM mirror of
/// backend/core/logic/daily_challenges.py. The date->index rotation, scoring,
/// streak and points summary are deterministic and identical to the backend.
///
/// POINTS SEAM (holds no money): a correct quiz earns [ChalBank.pointsCorrect],
/// a wrong one a small [ChalBank.pointsTry] consolation, a done task
/// [ChalBank.pointsTask]. These are the SAME "points" the referral engine mints
/// — this screen only COUNTS them; redeeming points for Premium days is the
/// integrator's seam (referral.POINTS_PER_PREMIUM_DAY). We never grant a plan.
///
/// Honest states: welcome (first use) · loading · error · done-today. ZERO
/// Bangla literals — every string is an AppLocalizations getter; the bank text
/// is served localized from ChalBank, not hard-coded in the widgets.
///
/// Persistence (generic api helpers, no api.dart edit):
///   listItems('challenges/progress') → [{id, date, item_id, kind, answer,
///                                         correct, points}]
///   createItem('challenges/progress', row) when the user completes the day's
///   challenge. One flexible per-user JSON collection (PaCollectionItem
///   precedent); the BANK itself is deterministic in-code, never stored.
class DailyChallengesScreen extends StatefulWidget {
  const DailyChallengesScreen({super.key});
  @override
  State<DailyChallengesScreen> createState() => _DailyChallengesScreenState();
}

const String _progressPath = 'challenges/progress';

String _today() {
  final n = DateTime.now();
  return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
}

class _DailyChallengesScreenState extends State<DailyChallengesScreen> {
  List<Map<String, dynamic>> _progress = [];
  bool _loading = true, _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

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
    final api = context.read<AppState>().api;
    try {
      _progress = await api.listItems(_progressPath);
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(msg)));

  Map<String, dynamic>? _todayRow(String date) {
    for (final r in _progress) {
      if ((r['date'] ?? '').toString() == date && r['answer'] != null) {
        return r;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.chalTitle)),
        body: const SkeletonList(),
      );
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.chalTitle)),
        body: StateMessage(
          icon: Icons.cloud_off,
          tint: scheme.error,
          title: tr.loadFailed,
          message: honestFailText(tr, _failCause, otherwise: tr.chalLoadError),
          action: FilledButton.tonalIcon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: Text(tr.retry)),
        ),
      );
    }

    final today = _today();
    final isBn = Localizations.localeOf(context).languageCode != 'en';
    final item = ChalBank.daily(tr, today, isBn);
    final summary = ChalBank.summarise(_progress, today);
    final doneRow = _todayRow(today);

    return Scaffold(
      appBar: AppBar(
        title: Text(tr.chalTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: tr.chalHistory,
            onPressed: _progress.isEmpty ? null : _openHistory,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 32),
          children: [
            // first-use welcome banner (only before anything is done)
            if (summary.totalCompleted == 0) _WelcomeBanner(),
            _StatsStrip(summary: summary),
            const SizedBox(height: Gap.md),
            if (item == null)
              StateMessage(
                icon: Icons.event_busy_outlined,
                title: tr.chalNoneTitle,
                message: tr.chalNoneBody,
              )
            else
              _TodayCard(
                item: item,
                doneRow: doneRow,
                onComplete: (answer) => _complete(item, answer, today),
              ),
            const SizedBox(height: Gap.md),
            _pointsNote(context, tr.chalPointsNote),
          ],
        ),
      ),
    );
  }

  Future<void> _complete(
      ChalItem item, dynamic answer, String date) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final scored = ChalBank.score(item.itemId, answer);
    final row = <String, dynamic>{
      'date': date,
      'item_id': item.itemId,
      'kind': scored.kind,
      'answer': scored.answer,
      'correct': scored.correct,
      'points': scored.points,
    };
    try {
      await api.createItem(_progressPath, row);
      await _load();
      if (mounted) {
        _toast(item.kind == 'task'
            ? tr.chalTaskDone(scored.points)
            : (scored.correct
                ? tr.chalCorrectToast(scored.points)
                : tr.chalWrongToast(scored.points)));
      }
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  void _openHistory() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _HistoryScreen(progress: _progress),
    ));
  }
}

// ===================== welcome (first-use) =====================
class _WelcomeBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.md),
      color: scheme.primaryContainer.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Row(children: [
          Icon(Icons.emoji_events_outlined, size: 32, color: scheme.primary),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr.chalWelcomeTitle,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 15)),
                  const SizedBox(height: 2),
                  Text(tr.chalWelcomeBody,
                      style: TextStyle(
                          fontSize: 12.5, color: scheme.onSurfaceVariant)),
                ]),
          ),
        ]),
      ),
    );
  }
}

// ===================== stats strip =====================
class _StatsStrip extends StatelessWidget {
  final ChalSummary summary;
  const _StatsStrip({required this.summary});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return Row(children: [
      Expanded(
          child: _stat(context, Icons.local_fire_department_outlined,
              tr.chalStreak, '${summary.currentStreak}', Brand.purple)),
      const SizedBox(width: Gap.sm),
      Expanded(
          child: _stat(context, Icons.star_outline, tr.chalPoints,
              '${summary.totalPoints}', Brand.warning)),
      const SizedBox(width: Gap.sm),
      Expanded(
          child: _stat(
              context,
              Icons.task_alt,
              tr.chalDone,
              '${summary.totalCompleted}',
              Theme.of(context).colorScheme.primary)),
    ]);
  }

  Widget _stat(BuildContext context, IconData icon, String label, String value,
      Color color) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.md, horizontal: Gap.sm),
        child: Column(children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: Gap.xs),
          Text(value,
              style: TextStyle(
                  fontSize: 20, fontWeight: FontWeight.bold, color: color)),
          const SizedBox(height: 2),
          Text(label,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
        ]),
      ),
    );
  }
}

// ===================== today's challenge card =====================
class _TodayCard extends StatefulWidget {
  final ChalItem item;
  final Map<String, dynamic>? doneRow;
  final ValueChanged<dynamic> onComplete;
  const _TodayCard(
      {required this.item, required this.doneRow, required this.onComplete});
  @override
  State<_TodayCard> createState() => _TodayCardState();
}

class _TodayCardState extends State<_TodayCard> {
  int? _selected;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final item = widget.item;
    final done = widget.doneRow != null;
    final answeredIdx =
        done ? (widget.doneRow!['answer'] as num?)?.toInt() : null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            _catChip(context, item.cat),
            const Spacer(),
            Text(
                item.kind == 'task' ? tr.chalKindTask : tr.chalKindQuiz,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant)),
          ]),
          const SizedBox(height: Gap.md),
          Text(item.question,
              style: const TextStyle(
                  fontSize: 17, fontWeight: FontWeight.w700, height: 1.35)),
          const SizedBox(height: Gap.lg),

          if (item.kind == 'quiz')
            ..._quizOptions(context, item, done, answeredIdx)
          else
            _taskBody(context, done),

          const SizedBox(height: Gap.md),

          // explanation shows only after completion (don't spoil the quiz)
          if (done) _explainBox(context, item),

          if (!done) ...[
            const SizedBox(height: Gap.sm),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _busy || (item.kind == 'quiz' && _selected == null)
                    ? null
                    : _submit,
                icon: Icon(item.kind == 'task'
                    ? Icons.check_circle_outline
                    : Icons.send_outlined),
                label: Text(item.kind == 'task'
                    ? tr.chalMarkDone
                    : tr.chalSubmitAnswer),
              ),
            ),
          ],
        ]),
      ),
    );
  }

  List<Widget> _quizOptions(
      BuildContext context, ChalItem item, bool done, int? answeredIdx) {
    final scheme = Theme.of(context).colorScheme;
    return [
      for (var i = 0; i < item.options.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.sm),
          child: () {
            final isCorrect = done && i == item.answer;
            final isWrongPick =
                done && i == answeredIdx && answeredIdx != item.answer;
            Color border = scheme.outlineVariant;
            Color? bg;
            if (done) {
              if (isCorrect) {
                border = Brand.success;
                bg = Brand.success.withValues(alpha: 0.12);
              } else if (isWrongPick) {
                border = scheme.error;
                bg = scheme.error.withValues(alpha: 0.10);
              }
            } else if (_selected == i) {
              border = scheme.primary;
              bg = scheme.primary.withValues(alpha: 0.08);
            }
            return InkWell(
              borderRadius: BorderRadius.circular(Radii.md),
              onTap: done || _busy ? null : () => setState(() => _selected = i),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: Gap.md, vertical: Gap.md),
                decoration: BoxDecoration(
                  color: bg,
                  border: Border.all(color: border, width: 1.4),
                  borderRadius: BorderRadius.circular(Radii.md),
                ),
                child: Row(children: [
                  Icon(
                    done
                        ? (isCorrect
                            ? Icons.check_circle
                            : (isWrongPick
                                ? Icons.cancel
                                : Icons.radio_button_unchecked))
                        : (_selected == i
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked),
                    size: 20,
                    color: isCorrect
                        ? Brand.success
                        : (isWrongPick
                            ? scheme.error
                            : (_selected == i && !done
                                ? scheme.primary
                                : scheme.onSurfaceVariant)),
                  ),
                  const SizedBox(width: Gap.md),
                  Expanded(
                    child: Text(item.options[i],
                        style: const TextStyle(fontSize: 14.5, height: 1.3)),
                  ),
                ]),
              ),
            );
          }(),
        ),
    ];
  }

  Widget _taskBody(BuildContext context, bool done) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(children: [
        Icon(done ? Icons.check_circle : Icons.flag_outlined,
            color: done ? Brand.success : scheme.primary),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(done ? tr.chalTaskCompleted : tr.chalTaskHint,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
        ),
      ]),
    );
  }

  Widget _explainBox(BuildContext context, ChalItem item) {
    final scheme = Theme.of(context).colorScheme;
    final tr = AppLocalizations.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.lightbulb_outline, size: 16, color: scheme.secondary),
          const SizedBox(width: Gap.xs),
          Text(tr.chalWhy,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: scheme.secondary)),
        ]),
        const SizedBox(height: Gap.xs),
        Text(item.explain,
            style: const TextStyle(fontSize: 13.5, height: 1.4)),
      ]),
    );
  }

  Future<void> _submit() async {
    final item = widget.item;
    if (item.kind == 'quiz' && _selected == null) return;
    setState(() => _busy = true);
    widget.onComplete(item.kind == 'task' ? 1 : _selected);
    // parent reloads & rebuilds with doneRow; guard against disposal
    if (mounted) setState(() => _busy = false);
  }
}

// ===================== history =====================
class _HistoryScreen extends StatelessWidget {
  final List<Map<String, dynamic>> progress;
  const _HistoryScreen({required this.progress});
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final isBn = Localizations.localeOf(context).languageCode != 'en';
    final rows = [...progress.where((r) => r['answer'] != null)]..sort((a, b) =>
        (b['date'] ?? '').toString().compareTo((a['date'] ?? '').toString()));
    return Scaffold(
      appBar: AppBar(title: Text(tr.chalHistory)),
      body: rows.isEmpty
          ? StateMessage(
              icon: Icons.history,
              title: tr.chalHistoryEmptyTitle,
              message: tr.chalHistoryEmptyBody,
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 32),
              children: [
                for (final r in rows)
                  () {
                    final item = ChalBank.byId(
                        tr, (r['item_id'] ?? '').toString(), isBn);
                    final correct = r['correct'] == true;
                    final kind = (r['kind'] ?? '').toString();
                    return Card(
                      margin: const EdgeInsets.only(bottom: Gap.sm),
                      child: ListTile(
                        leading: Icon(
                          kind == 'task'
                              ? Icons.flag_circle_outlined
                              : (correct
                                  ? Icons.check_circle
                                  : Icons.cancel_outlined),
                          color: kind == 'task'
                              ? scheme.primary
                              : (correct ? Brand.success : scheme.error),
                        ),
                        title: Text(
                            item?.question ?? (r['item_id'] ?? '').toString(),
                            maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text((r['date'] ?? '').toString()),
                        trailing: Text('+${r['points'] ?? 0}',
                            style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: Brand.warning)),
                      ),
                    );
                  }(),
              ],
            ),
    );
  }
}

// ===================== shared small widgets =====================
Widget _catChip(BuildContext context, String cat) {
  final tr = AppLocalizations.of(context);
  final String label;
  final Color c;
  switch (cat) {
    case 'finance':
      label = tr.chalCatFinance;
      c = Brand.success;
      break;
    case 'health':
      label = tr.chalCatHealth;
      c = Brand.danger;
      break;
    case 'safety':
      label = tr.chalCatSafety;
      c = Brand.blue;
      break;
    default:
      label = tr.chalCatGeneral;
      c = Brand.purple;
  }
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
    decoration: BoxDecoration(
      color: c.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(Radii.pill),
    ),
    child: Text(label,
        style: TextStyle(color: c, fontSize: 11.5, fontWeight: FontWeight.w700)),
  );
}

Widget _pointsNote(BuildContext context, String text) {
  final scheme = Theme.of(context).colorScheme;
  return Card(
    color: scheme.surfaceContainerHighest,
    child: Padding(
      padding: const EdgeInsets.all(Gap.md),
      child: Row(children: [
        Icon(Icons.info_outline, size: 18, color: scheme.onSurfaceVariant),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(text,
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
        ),
      ]),
    ),
  );
}
