import '../feature_gates.dart' show kShowKeySeams;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../services/error_kind.dart' show honestFailText; // qa2

/// MOCK INTERVIEW — ADVANCED, KEY-GATED (#131, SPEC v2.1 §21).
///
/// Pick a CATEGORY (job / HR / technical-basics / viva); a built-in BILINGUAL
/// question bank serves interview questions ONE AT A TIME; the user types (or
/// speaks-to-text) an answer; the tool gives RULE-BASED feedback — length,
/// keyword coverage, structure tips — plus a model-answer OUTLINE. Session
/// history (asked question + self-score) is saved per user.
///
/// HONEST: the feedback is a DETERMINISTIC RUBRIC, clearly labelled "Rule-based
/// — not an AI grade". A LIVE AI interviewer (follow-ups + conversational
/// critique) is a DOCUMENTED key-gated seam shown as an honest "connect an AI
/// key" state; it is NOT built here and the whole tool works with no key.
///
/// The on-screen logic mirrors backend/core/logic/mock_interview.py VERBATIM
/// (bank order, next-unasked + wrap, rubric thresholds, tip keys) so the live
/// view is deterministic and identical offline.
///
/// Honest states: welcome (first use) · loading · error · no-category. ZERO
/// Bangla literals — every string is an AppLocalizations getter.
///
/// Persistence (generic api helpers, no api.dart edit):
///   listItems('interview/sessions')  → [{id, category, question_id,
///                                         answer, level, words, coverage,
///                                         self_score, date}]
/// create/delete on the same path. Each row round-trips as {id, ...data}
/// through one flexible per-user JSON collection (PaCollectionItem precedent).
class MockInterviewScreen extends StatefulWidget {
  const MockInterviewScreen({super.key});
  @override
  State<MockInterviewScreen> createState() => _MockInterviewScreenState();
}

const String _sessionsPath = 'interview/sessions';
const List<String> _categoryKeys = ['job', 'hr', 'technical', 'viva'];

String _today() {
  final n = DateTime.now();
  return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
}

String _catLabel(AppLocalizations tr, String? c) {
  switch (c) {
    case 'hr':
      return tr.miCatHr;
    case 'technical':
      return tr.miCatTechnical;
    case 'viva':
      return tr.miCatViva;
    default:
      return tr.miCatJob;
  }
}

class _MockInterviewScreenState extends State<MockInterviewScreen> {
  List<Map<String, dynamic>> _sessions = [];
  bool _loading = true, _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

  String? _category; // null → category picker
  final List<String> _asked = []; // ids asked this session
  _Question? _current;
  final TextEditingController _answer = TextEditingController();
  _Feedback? _feedback;
  bool _showOutline = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _answer.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      _sessions = await context.read<AppState>().api.listItems(_sessionsPath);
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(msg)));

  void _pickCategory(String c) {
    setState(() {
      _category = c;
      _asked.clear();
      _feedback = null;
      _showOutline = false;
      _answer.clear();
      _current = _MiEngine.nextQuestion(c, _asked);
    });
  }

  void _nextQuestion() {
    final c = _category;
    if (c == null) return;
    setState(() {
      _feedback = null;
      _showOutline = false;
      _answer.clear();
      _current = _MiEngine.nextQuestion(c, _asked);
    });
  }

  void _getFeedback() {
    final q = _current;
    if (q == null) return;
    final fb = _MiEngine.feedback(q.id, _answer.text);
    setState(() {
      _feedback = fb;
      if (!_asked.contains(q.id)) _asked.add(q.id);
    });
  }

  Future<void> _saveSession(int selfScore) async {
    final tr = AppLocalizations.of(context);
    final q = _current;
    final fb = _feedback;
    if (q == null || fb == null) return;
    try {
      await context.read<AppState>().api.createItem(_sessionsPath, {
        'category': _category,
        'question_id': q.id,
        'answer': _answer.text.trim(),
        'level': fb.level,
        'words': fb.words,
        'coverage': fb.coverage,
        'self_score': selfScore,
        'date': _today(),
      });
      await _load();
      if (mounted) _toast(tr.miSessionSaved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
          appBar: AppBar(title: Text(tr.miTitle)),
          body: const SkeletonList());
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.miTitle)),
        body: StateMessage(
          icon: Icons.cloud_off_rounded,
          tint: scheme.error,
          title: tr.loadFailed,
          message: honestFailText(tr, _failCause, otherwise: tr.miLoadError),
          action: FilledButton.tonalIcon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(tr.retry)),
        ),
      );
    }
    if (_category == null) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.miTitle)),
        body: _CategoryPicker(
          onPick: _pickCategory,
          sessions: _sessions,
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(tr.miTitle), actions: [
        IconButton(
          tooltip: tr.miChangeCategory,
          icon: const Icon(Icons.category_rounded),
          onPressed: () => setState(() => _category = null),
        ),
      ]),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
          children: [
            _ProgressHeader(category: _category!, asked: _asked),
            const SizedBox(height: Gap.md),
            if (_current != null) ...[
              _QuestionCard(question: _current!),
              const SizedBox(height: Gap.md),
              _AnswerField(controller: _answer),
              const SizedBox(height: Gap.sm),
              Row(children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _getFeedback,
                    icon: const Icon(Icons.rate_review_rounded),
                    label: Text(tr.miGetFeedback),
                  ),
                ),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _nextQuestion,
                    icon: const Icon(Icons.skip_next_rounded),
                    label: Text(tr.miNextQuestion),
                  ),
                ),
              ]),
              const SizedBox(height: Gap.md),
              if (_feedback != null) ...[
                _FeedbackCard(
                  feedback: _feedback!,
                  onSave: _saveSession,
                ),
                const SizedBox(height: Gap.md),
              ],
              _OutlineSection(
                questionId: _current!.id,
                expanded: _showOutline,
                onToggle: () => setState(() => _showOutline = !_showOutline),
              ),
              const SizedBox(height: Gap.md),
              const _LiveSeamCard(),
            ],
            const SizedBox(height: Gap.lg),
            _HistorySection(sessions: _sessions, onDeleted: _load),
          ],
        ),
      ),
    );
  }
}

// ======================= category picker =======================
class _CategoryPicker extends StatelessWidget {
  final void Function(String) onPick;
  final List<Map<String, dynamic>> sessions;
  const _CategoryPicker({required this.onPick, required this.sessions});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(Gap.lg),
      children: [
        if (sessions.isEmpty) ...[
          const SizedBox(height: Gap.lg),
          Icon(Icons.record_voice_over_rounded,
              size: 56, color: scheme.primary),
          const SizedBox(height: Gap.md),
          Text(tr.miWelcomeTitle,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.sm),
          Text(tr.miWelcomeBody,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
          const SizedBox(height: Gap.xl),
        ],
        Text(tr.miPickCategory,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: Gap.md),
        for (final c in _categoryKeys)
          Card(
            margin: const EdgeInsets.only(bottom: Gap.sm),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: scheme.primaryContainer,
                child: Icon(_catIcon(c), color: scheme.onPrimaryContainer),
              ),
              title: Text(_catLabel(tr, c)),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => onPick(c),
            ),
          ),
      ],
    );
  }

  IconData _catIcon(String c) {
    switch (c) {
      case 'hr':
        return Icons.people_outline_rounded;
      case 'technical':
        return Icons.code_rounded;
      case 'viva':
        return Icons.school_rounded;
      default:
        return Icons.work_outline_rounded;
    }
  }
}

// ======================= progress header =======================
class _ProgressHeader extends StatelessWidget {
  final String category;
  final List<String> asked;
  const _ProgressHeader({required this.category, required this.asked});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final p = _MiEngine.sessionProgress(category, asked);
    return Card(
      color: Brand.blue.withValues(alpha: 0.10),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(children: [
          Icon(Icons.flag_rounded, color: Brand.blue),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_catLabel(tr, category),
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: Gap.xxs),
                  Text(tr.miProgressLabel(p.done, p.total),
                      style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
                ]),
          ),
          Text('${p.percent}%',
              style: AType.titleLarge.copyWith(fontFeatures: AFonts.tabular, fontWeight: FontWeight.w800, color: Brand.blue)),
        ]),
      ),
    );
  }
}

// ======================= question card =======================
class _QuestionCard extends StatelessWidget {
  final _Question question;
  const _QuestionCard({required this.question});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr.miQuestionLabel.toUpperCase(),
              style: AType.labelSmall.copyWith(letterSpacing: 1, fontWeight: FontWeight.w700, color: scheme.primary)),
          const SizedBox(height: Gap.sm),
          Text(_miQuestionText(tr, question.id),
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w600, height: 1.35)),
        ]),
      ),
    );
  }
}

// ======================= answer field =======================
class _AnswerField extends StatelessWidget {
  final TextEditingController controller;
  const _AnswerField({required this.controller});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return TextField(
      controller: controller,
      minLines: 4,
      maxLines: 10,
      keyboardType: TextInputType.multiline,
      decoration: InputDecoration(
        labelText: tr.miAnswerLabel,
        hintText: tr.miAnswerHint,
        alignLabelWithHint: true,
        border: const OutlineInputBorder(),
      ),
    );
  }
}

// ======================= feedback card =======================
class _FeedbackCard extends StatelessWidget {
  final _Feedback feedback;
  final void Function(int selfScore) onSave;
  const _FeedbackCard({required this.feedback, required this.onSave});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final c = _levelColor(feedback.level);
    final bn = Localizations.localeOf(context).languageCode == 'bn';
    return Card(
      color: c.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.rate_review_rounded, color: c),
            const SizedBox(width: Gap.sm),
            Text(tr.miFeedbackTitle,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const Spacer(),
            _levelChip(context, feedback.level),
          ]),
          const SizedBox(height: Gap.sm),
          // honest marker: rule-based, not an AI grade
          Row(children: [
            Icon(Icons.info_outline_rounded, size: 14, color: scheme.onSurfaceVariant),
            const SizedBox(width: Gap.xs),
            Expanded(
              child: Text(tr.miFbMarker,
                  style: AType.bodySmall.copyWith(fontStyle: FontStyle.italic, color: scheme.onSurfaceVariant)),
            ),
          ]),
          const SizedBox(height: Gap.md),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            _stat(context, Icons.notes_rounded, tr.miWordsCount(feedback.words)),
            _stat(context, Icons.key_rounded,
                tr.miCoveragePct((feedback.coverage * 100).round())),
          ]),
          const SizedBox(height: Gap.md),
          for (final t in feedback.tips)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.xs),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.chevron_right_rounded, size: 18, color: c),
                Expanded(child: Text(_tipText(tr, t))),
              ]),
            ),
          if (feedback.missing.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Text(tr.miMissingLabel,
                style: AType.bodySmall.copyWith(fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.xs),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final k in feedback.missing)
                Chip(
                  label: Text(k, style: AType.labelSmall),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
            ]),
          ],
          const SizedBox(height: Gap.md),
          Text(tr.miSelfScore,
              style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.xs),
          Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (var i = 1; i <= 5; i++)
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size(44, 44),
                        padding: EdgeInsets.zero),
                    onPressed: () => onSave(i),
                    child: Text('$i'),
                  ),
              ]),
          if (bn) const SizedBox.shrink(),
        ]),
      ),
    );
  }

  String _tipText(AppLocalizations tr, String key) {
    switch (key) {
      case 'tip_longer':
        return tr.miTipLonger;
      case 'tip_cover_keywords':
        return tr.miTipCoverKeywords;
      case 'tip_structure':
        return tr.miTipStructure;
      case 'tip_strong':
        return tr.miTipStrong;
      default:
        return tr.miTipOk;
    }
  }
}

Widget _levelChip(BuildContext context, String level) {
  final tr = AppLocalizations.of(context);
  final c = _levelColor(level);
  final label = level == 'too_short'
      ? tr.miLevelTooShort
      : (level == 'strong' ? tr.miLevelStrong : tr.miLevelOk);
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: Gap.xs),
    decoration: BoxDecoration(
        color: c.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(Radii.pill)),
    child: Text(label,
        style: AType.bodySmall.copyWith(color: c, fontWeight: FontWeight.w700)),
  );
}

Color _levelColor(String level) {
  switch (level) {
    case 'too_short':
      return Brand.warning;
    case 'strong':
      return Brand.success;
    default:
      return Brand.blue;
  }
}

Widget _stat(BuildContext context, IconData icon, String text) {
  final scheme = Theme.of(context).colorScheme;
  return Row(mainAxisSize: MainAxisSize.min, children: [
    Icon(icon, size: 16, color: scheme.onSurfaceVariant),
    const SizedBox(width: Gap.xs),
    Text(text, style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
  ]);
}

// ======================= outline =======================
class _OutlineSection extends StatelessWidget {
  final String questionId;
  final bool expanded;
  final VoidCallback onToggle;
  const _OutlineSection(
      {required this.questionId,
      required this.expanded,
      required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Column(children: [
        ListTile(
          leading: Icon(Icons.lightbulb_outline_rounded, color: scheme.tertiary),
          title: Text(tr.miShowOutline),
          trailing: Icon(expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded),
          onTap: onToggle,
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr.miOutlineTitle,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: Gap.sm),
                  Text(_miOutlineText(tr, questionId),
                      style: const TextStyle(height: 1.4)),
                  const SizedBox(height: Gap.sm),
                  Text(tr.miOutlineNote,
                      style: AType.bodySmall.copyWith(fontStyle: FontStyle.italic, color: scheme.onSurfaceVariant)),
                ]),
          ),
      ]),
    );
  }
}

// ======================= live AI seam (key-gated) =======================
class _LiveSeamCard extends StatelessWidget {
  const _LiveSeamCard();

  @override
  Widget build(BuildContext context) {
    if (!kShowKeySeams) return const SizedBox.shrink(); // truth: no key dead end
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.secondaryContainer.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.auto_awesome_rounded, size: 20, color: scheme.secondary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr.miLiveSeamTitle,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: Gap.xxs),
                  Text(tr.miLiveSeamBody,
                      style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.35)),
                ]),
          ),
        ]),
      ),
    );
  }
}

// ======================= history =======================
class _HistorySection extends StatelessWidget {
  final List<Map<String, dynamic>> sessions;
  final VoidCallback onDeleted;
  const _HistorySection({required this.sessions, required this.onDeleted});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final sorted = [...sessions]..sort((a, b) =>
        ((b['id'] ?? 0) as int).compareTo((a['id'] ?? 0) as int));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(tr.miHistoryTitle, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: Gap.sm),
      if (sorted.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.sm),
          child: Text(tr.miNoHistory,
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ),
      for (final s in sorted.take(20))
        Card(
          margin: const EdgeInsets.only(bottom: Gap.sm),
          child: ListTile(
            dense: true,
            leading: Icon(Icons.history_rounded, color: scheme.primary),
            title: Text(_catLabel(tr, s['category'] as String?)),
            subtitle: Text([
              (s['date'] ?? '').toString(),
              if (s['self_score'] != null) '★ ${s['self_score']}/5',
              if (s['level'] != null)
                _levelShort(tr, s['level'] as String?),
            ].where((e) => e.isNotEmpty).join('  ·  ')),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline_rounded, size: 20),
              tooltip: tr.delete,
              onPressed: () async {
                final id = s['id'];
                if (id is int) {
                  await context
                      .read<AppState>()
                      .api
                      .deleteItem(_sessionsPath, id);
                  onDeleted();
                }
              },
            ),
          ),
        ),
    ]);
  }

  String _levelShort(AppLocalizations tr, String? level) {
    switch (level) {
      case 'too_short':
        return tr.miLevelTooShort;
      case 'strong':
        return tr.miLevelStrong;
      default:
        return tr.miLevelOk;
    }
  }
}

// =====================================================================
// _MiEngine — a VERBATIM Dart mirror of backend/core/logic/mock_interview.py.
// Deterministic; identical inputs -> identical output; no clock, no network.
//
// ZERO Bangla literals: the bank below holds ONLY ascii ids + category +
// keyword hints (the only things the rubric computes on). Question prompts and
// model-answer outlines are DISPLAY text resolved by _miQuestionText /
// _miOutlineText through AppLocalizations (keys miQ_<id> / miO_<id>), so this
// file stays Bangla-free while the rubric logic mirrors the Python exactly.
// =====================================================================

class _Question {
  final String id, category;
  const _Question(this.id, this.category);
}

class _Feedback {
  final String questionId, level;
  final int words;
  final double coverage;
  final List<String> matched, missing, tips;
  final bool structured;
  const _Feedback({
    required this.questionId,
    required this.level,
    required this.words,
    required this.coverage,
    required this.matched,
    required this.missing,
    required this.tips,
    required this.structured,
  });
}

class _MiProgress {
  final int done, total, percent;
  const _MiProgress(this.done, this.total, this.percent);
}

class _BankItem {
  final String id, category;
  final List<String> keywords;
  const _BankItem(this.id, this.category, this.keywords);
}

/// Resolve a question prompt (miQ_<id>) by active locale. ASCII switch only.
String _miQuestionText(AppLocalizations tr, String id) {
  switch (id) {
    case 'job_tellme':
      return tr.miQ_job_tellme;
    case 'job_strength':
      return tr.miQ_job_strength;
    case 'job_weakness':
      return tr.miQ_job_weakness;
    case 'job_why':
      return tr.miQ_job_why;
    case 'job_fiveyears':
      return tr.miQ_job_fiveyears;
    case 'hr_conflict':
      return tr.miQ_hr_conflict;
    case 'hr_pressure':
      return tr.miQ_hr_pressure;
    case 'hr_mistake':
      return tr.miQ_hr_mistake;
    case 'hr_teamwork':
      return tr.miQ_hr_teamwork;
    case 'hr_salary':
      return tr.miQ_hr_salary;
    case 'tech_variable':
      return tr.miQ_tech_variable;
    case 'tech_loop':
      return tr.miQ_tech_loop;
    case 'tech_sql':
      return tr.miQ_tech_sql;
    case 'tech_api':
      return tr.miQ_tech_api;
    case 'tech_debug':
      return tr.miQ_tech_debug;
    case 'viva_project':
      return tr.miQ_viva_project;
    case 'viva_tools':
      return tr.miQ_viva_tools;
    case 'viva_challenge':
      return tr.miQ_viva_challenge;
    case 'viva_improve':
      return tr.miQ_viva_improve;
    default:
      return '';
  }
}

/// Resolve a model-answer outline (miO_<id>) by active locale. ASCII switch.
String _miOutlineText(AppLocalizations tr, String id) {
  switch (id) {
    case 'job_tellme':
      return tr.miO_job_tellme;
    case 'job_strength':
      return tr.miO_job_strength;
    case 'job_weakness':
      return tr.miO_job_weakness;
    case 'job_why':
      return tr.miO_job_why;
    case 'job_fiveyears':
      return tr.miO_job_fiveyears;
    case 'hr_conflict':
      return tr.miO_hr_conflict;
    case 'hr_pressure':
      return tr.miO_hr_pressure;
    case 'hr_mistake':
      return tr.miO_hr_mistake;
    case 'hr_teamwork':
      return tr.miO_hr_teamwork;
    case 'hr_salary':
      return tr.miO_hr_salary;
    case 'tech_variable':
      return tr.miO_tech_variable;
    case 'tech_loop':
      return tr.miO_tech_loop;
    case 'tech_sql':
      return tr.miO_tech_sql;
    case 'tech_api':
      return tr.miO_tech_api;
    case 'tech_debug':
      return tr.miO_tech_debug;
    case 'viva_project':
      return tr.miO_viva_project;
    case 'viva_tools':
      return tr.miO_viva_tools;
    case 'viva_challenge':
      return tr.miO_viva_challenge;
    case 'viva_improve':
      return tr.miO_viva_improve;
    default:
      return '';
  }
}

class _MiEngine {
  static const int minWordsOk = 20;
  static const int minWordsStrong = 45;
  static const double coverageStrong = 0.5;

  // Bank mirrors mock_interview.BANK: ids + category + keyword hints only.
  static const List<_BankItem> bank = [
    _BankItem('job_tellme', 'job',
        ['experience', 'skill', 'role', 'strength', 'goal']),
    _BankItem('job_strength', 'job',
        ['strength', 'example', 'result', 'team', 'learn']),
    _BankItem('job_weakness', 'job',
        ['weakness', 'improve', 'learn', 'feedback', 'progress']),
    _BankItem('job_why', 'job',
        ['company', 'mission', 'role', 'grow', 'contribute']),
    _BankItem('job_fiveyears', 'job',
        ['grow', 'skill', 'role', 'goal', 'team']),
    _BankItem('hr_conflict', 'hr',
        ['situation', 'listen', 'resolve', 'outcome', 'respect']),
    _BankItem('hr_pressure', 'hr',
        ['deadline', 'prioritise', 'calm', 'result', 'plan']),
    _BankItem('hr_mistake', 'hr',
        ['mistake', 'responsibility', 'fix', 'learn', 'change']),
    _BankItem('hr_teamwork', 'hr',
        ['team', 'role', 'goal', 'communicate', 'result']),
    _BankItem('hr_salary', 'hr',
        ['range', 'research', 'role', 'flexible', 'value']),
    _BankItem('tech_variable', 'technical',
        ['variable', 'constant', 'change', 'value', 'memory']),
    _BankItem('tech_loop', 'technical',
        ['loop', 'condition', 'iterate', 'count', 'repeat']),
    _BankItem('tech_sql', 'technical',
        ['database', 'table', 'query', 'store', 'relation']),
    _BankItem('tech_api', 'technical',
        ['api', 'request', 'response', 'interface', 'service']),
    _BankItem('tech_debug', 'technical',
        ['reproduce', 'log', 'isolate', 'test', 'fix']),
    _BankItem('viva_project', 'viva',
        ['objective', 'problem', 'solution', 'result', 'scope']),
    _BankItem('viva_tools', 'viva',
        ['tool', 'reason', 'alternative', 'fit', 'experience']),
    _BankItem('viva_challenge', 'viva',
        ['challenge', 'problem', 'solve', 'learn', 'overcome']),
    _BankItem('viva_improve', 'viva',
        ['improve', 'future', 'feature', 'test', 'scale']),
  ];

  static String _clean(String s) => s.trim().split(RegExp(r'\s+')).join(' ');

  static List<_BankItem> _poolFor(String category) =>
      bank.where((q) => q.category == category).toList();

  static _Question? nextQuestion(String category, List<String> askedIds) {
    final pool = _poolFor(category);
    if (pool.isEmpty) return null;
    final asked = askedIds.toSet();
    var unasked = pool.where((q) => !asked.contains(q.id)).toList();
    if (unasked.isEmpty) unasked = pool; // wrap to keep practising
    final q = unasked.first;
    return _Question(q.id, q.category);
  }

  static _Feedback feedback(String questionId, String answer) {
    _BankItem? q;
    for (final b in bank) {
      if (b.id == questionId) {
        q = b;
        break;
      }
    }
    final ans = _clean(answer);
    final words = ans.isEmpty ? <String>[] : ans.split(' ');
    final n = words.length;
    final low = ans.toLowerCase();

    if (q == null) {
      return _Feedback(
          questionId: questionId,
          level: 'too_short',
          words: n,
          coverage: 0,
          matched: const [],
          missing: const [],
          tips: const ['tip_ok'],
          structured: false);
    }

    final hints = q.keywords;
    final matched = hints.where((k) => low.contains(k)).toList();
    final missing = hints.where((k) => !low.contains(k)).toList();
    final coverage = hints.isEmpty ? 0.0 : matched.length / hints.length;
    final breaks =
        '.!?।'.split('').fold<int>(0, (a, c) => a + low.split(c).length - 1);
    final structured = breaks >= 1 && n >= minWordsOk;

    String level;
    if (n < minWordsOk) {
      level = 'too_short';
    } else if (n >= minWordsStrong && coverage >= coverageStrong) {
      level = 'strong';
    } else {
      level = 'ok';
    }

    final tips = <String>[];
    if (level == 'too_short') tips.add('tip_longer');
    if (missing.isNotEmpty) tips.add('tip_cover_keywords');
    if (!structured && n >= minWordsOk) tips.add('tip_structure');
    if (level == 'strong') tips.add('tip_strong');
    if (tips.isEmpty) tips.add('tip_ok');

    return _Feedback(
        questionId: questionId,
        level: level,
        words: n,
        coverage: double.parse(coverage.toStringAsFixed(2)),
        matched: matched,
        missing: missing,
        tips: tips,
        structured: structured);
  }

  static _MiProgress sessionProgress(String category, List<String> askedIds) {
    final pool = _poolFor(category);
    final asked = askedIds.toSet();
    final done = pool.where((q) => asked.contains(q.id)).length;
    final total = pool.length;
    return _MiProgress(
        done, total, total == 0 ? 0 : (100 * done / total).round());
  }
}
