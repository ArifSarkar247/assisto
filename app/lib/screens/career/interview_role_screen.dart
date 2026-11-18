import 'package:flutter/material.dart';
import '../../theme.dart';
import '../../ds/ds.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../services/error_kind.dart' show honestFailText;
import '../../state.dart';
import '../../widgets/app_sheet.dart' show withNavBarInset;
import '../../widgets/local_counter.dart';
import '../../widgets/local_digits.dart';
import '../../widgets/skeleton.dart';
import '../../widgets/voice_input.dart';

/// p2career (flag career_plus): role-based mock interview.
/// Roles + questions come from the server (Assisto's own bilingual bank, in the
/// app language). The user types OR speaks (the app's shared speech-to-text,
/// [VoiceDictation] — text lands in the box, never auto-sent), then gets:
///   * the key-free RUBRIC score (labelled "rule-based — not an AI grade"),
///   * optionally AI feedback through the server's AI router (credits + a daily
///     cap; an honest message when AI is not connected).
/// Zero Bangla literals.
class InterviewRoleScreen extends StatefulWidget {
  const InterviewRoleScreen({super.key});

  @override
  State<InterviewRoleScreen> createState() => _InterviewRoleScreenState();
}

class _InterviewRoleScreenState extends State<InterviewRoleScreen> {
  bool _loading = true, _failed = false, _busy = false;
  Object? _failCause;
  List<Map<String, dynamic>> _roles = [];
  Map<String, dynamic>? _role; // {id, name, questions:[{id,text,outline}]}
  int _index = 0;
  Map<String, dynamic>? _rubric;
  Map<String, dynamic>? _ai;
  // career: the LAST checked score per question index (an edited, re-checked
  // answer replaces its old score) -> the per-question summary at the end.
  final Map<int, int> _scores = {};
  bool _done = false;
  final _answer = TextEditingController();
  late final VoiceDictation _voice = VoiceDictation();

  AppLocalizations get t => AppLocalizations.of(context);
  String get _lang => Localizations.localeOf(context).languageCode == 'bn' ? 'bn' : 'en';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadRoles());
  }

  @override
  void dispose() {
    _voice.dispose();
    _answer.dispose();
    super.dispose();
  }

  Future<void> _loadRoles() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final r = await context.read<AppState>().api.getJson('/career/interview/roles?lang=$_lang');
      _roles = (r['roles'] as List? ?? const []).whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    } catch (e) {
      _failed = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _pickRole(String id) async {
    setState(() => _busy = true);
    try {
      final r = await context.read<AppState>().api.getJson('/career/interview/roles/$id?lang=$_lang');
      setState(() {
        _role = r;
        _index = 0;
        _scores.clear();
        _done = false;
        _resetAnswer();
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(honestFailText(t, e))));
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  void _resetAnswer() {
    _answer.clear();
    _rubric = null;
    _ai = null;
  }

  List<Map<String, dynamic>> get _questions =>
      (_role?['questions'] as List? ?? const []).whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();

  Future<void> _submit({bool ai = false}) async {
    FocusScope.of(context).unfocus();
    final text = _answer.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.crrEmptyAnswer)));
      return;
    }
    setState(() => _busy = true);
    try {
      final q = _questions[_index];
      final r = await context.read<AppState>().api.postJson('/career/interview/feedback',
          {'qid': q['id'], 'answer': text, 'lang': _lang, 'ai': ai});
      setState(() {
        _rubric = (r['rubric'] as Map?)?.cast<String, dynamic>();
        // career: a re-check of an edited answer must not keep the OLD AI
        // feedback under the new answer
        _ai = r['ai'] is Map ? (r['ai'] as Map).cast<String, dynamic>() : (ai ? _ai : null);
        if (_rubric != null) _scores[_index] = (_rubric!['score'] as num?)?.toInt() ?? 0;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(honestFailText(t, e))));
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  void _next() {
    setState(() {
      if (_index + 1 >= _questions.length) {
        _done = true;
      } else {
        _index++;
      }
      _resetAnswer();
    });
  }

  void _endNow() => setState(() {
        _done = true;
        _resetAnswer();
      });

  String _tip(String id) => switch (id) {
        'longer' => t.crrTipLonger,
        'shorter' => t.crrTipShorter,
        'cover_topics' => t.crrTipCoverTopics,
        'add_example' => t.crrTipAddExample,
        'fewer_fillers' => t.crrTipFewerFillers,
        _ => t.crrTipKeepGoing,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_role == null ? t.crrRoleTitle : '${_role!['name'] ?? ''}', maxLines: 2)),
      body: _loading
          ? const SkeletonList()
          : _failed
              ? StateMessage(
                  icon: Icons.cloud_off_rounded,
                  title: honestFailText(t, _failCause),
                  action: DsButton.secondary(onPressed: _loadRoles, icon: Icons.refresh_rounded, label: t.retry))
              : _role == null
                  ? _rolePicker(context)
                  : _done
                      ? _finished(context)
                      : _questionView(context),
    );
  }

  Widget _rolePicker(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: withNavBarInset(context, const EdgeInsets.all(16)),
      children: [
        if (_busy) const LinearProgressIndicator(),
        Text(t.crrRolePick, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(t.crrRoleEntrySub, style: AType.bodyMedium.copyWith(color: scheme.ds.muted)),
        const SizedBox(height: 12),
        for (final r in _roles)
          Padding(padding: const EdgeInsets.only(bottom: 8), child: DsSurface(flat: true, borderColor: Theme.of(context).colorScheme.ds.border,
              padding: EdgeInsets.zero,
              child: ListTile(
              key: ValueKey('crr-role-${r['id']}'),
              leading: CircleAvatar(
                  backgroundColor: scheme.ds.primarySoft,
                  child: Icon(Icons.work_outline_rounded, color: scheme.ds.primaryInk)),
              title: Text('${r['name'] ?? ''}'),
              subtitle: Text(t.crrRoleQuestions(ld(context, r['count'] ?? 0))),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _busy ? null : () => _pickRole('${r['id']}'),
            ),
            )),
      ],
    );
  }

  Widget _questionView(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final q = _questions[_index];
    final r = _rubric;
    return ListView(
      padding: withNavBarInset(context, const EdgeInsets.fromLTRB(16, 12, 16, 32)),
      children: [
        if (_busy) const LinearProgressIndicator(),
        Text(t.crrRoleQuestionOf(ld(context, _index + 1), ld(context, _questions.length)),
            style: Theme.of(context).textTheme.labelLarge?.copyWith(color: scheme.primary)),
        const SizedBox(height: 8),
        Text('${q['text'] ?? ''}',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text(t.crrModelOutline),
          children: [
            Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text('${q['outline'] ?? ''}')),
            const SizedBox(height: 8),
          ],
        ),
        TextField(
          key: const ValueKey('crr-answer'),
          controller: _answer,
          minLines: 4,
          maxLines: 10,
          maxLength: 3000,
          buildCounter: localCounter,
          decoration: InputDecoration(
            hintText: t.crrAnswerHint,
            suffixIcon: VoiceMicButton(voice: _voice, input: _answer),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          DsButton(key: const ValueKey('crr-submit'), onPressed: _busy ? null : () => _submit(), icon: Icons.fact_check_rounded, label: t.crrSubmit),
          if (r != null)
            DsButton.secondary(key: const ValueKey('crr-next'), onPressed: _busy ? null : _next, icon: Icons.arrow_forward_rounded, label: _index + 1 >= _questions.length ? t.crrFinish : t.crrNext),
          if (_scores.isNotEmpty && _index + 1 < _questions.length)
            TextButton.icon(
                key: const ValueKey('crr-end'),
                onPressed: _busy ? null : _endNow,
                icon: const Icon(Icons.flag_outlined),
                label: Text(t.crrEndNow)),
        ]),
        if (r != null) ...[
          const SizedBox(height: 16),
          DsSurface(flat: true, borderColor: Theme.of(context).colorScheme.ds.border,
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t.crrScore(ld(context, r['score'] ?? 0)),
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                Text(t.crrRubricLabel, style: Theme.of(context).textTheme.bodySmall),
                Text(t.crrWords(ld(context, r['words'] ?? 0)), style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 10),
                for (final tip in (r['tips'] as List? ?? const []))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(Icons.lightbulb_outline_rounded, size: 20, color: scheme.primary),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_tip('$tip'))),
                    ]),
                  ),
                const SizedBox(height: 8),
                Text(
                    t.crrCoveredCount(
                        ld(context, (r['hits'] as List? ?? const []).length),
                        ld(context, (r['hits'] as List? ?? const []).length +
                            (r['missing'] as List? ?? const []).length)),
                    style: Theme.of(context).textTheme.labelLarge),
              ]),
          ),
          const SizedBox(height: 8),
          DsSurface(flat: true, borderColor: Theme.of(context).colorScheme.ds.border,
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(t.crrAiFeedback, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                if (_ai == null)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: DsButton.secondary(key: const ValueKey('crr-ai'), onPressed: _busy ? null : () => _submit(ai: true), icon: Icons.auto_awesome_rounded, label: t.crrAiFeedbackBtn),
                  )
                else if (_ai!['ai_used'] == true) ...[
                  Text('${_ai!['text'] ?? ''}'),
                  const SizedBox(height: 8),
                  // career: say what this cost — and that a repeat is free
                  Text(
                      _ai!['cached'] == true
                          ? t.crrAiCachedFree
                          : t.crrAiCharged(ld(context, (_ai!['charged'] as num?)?.toInt() ?? 0)),
                      key: const ValueKey('crr-ai-cost'),
                      style: AType.bodyMedium.copyWith(color: scheme.ds.muted)),
                ] else
                  Text('${_ai!['message'] ?? t.crrAiNotReady}',
                      style: AType.bodyMedium.copyWith(color: scheme.ds.muted)),
              ]),
          ),
        ],
      ],
    );
  }

  Widget _finished(BuildContext context) {
    final vals = _scores.values.toList();
    final avg = vals.isEmpty ? 0 : (vals.reduce((a, b) => a + b) / vals.length).round();
    final qs = _questions;
    final done = _scores.keys.toList()..sort((a, b) => _scores[a]!.compareTo(_scores[b]!));
    return ListView(
      padding: withNavBarInset(context, const EdgeInsets.all(24)),
      children: [
        Icon(Icons.emoji_events_rounded, size: 56, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 12),
        Text(t.crrDoneTitle,
            textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(t.crrDoneAvg(ld(context, avg)),
            key: const ValueKey('crr-done-avg'),
            textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        // career: every answered question with its score (weakest first to
        // practise again)
        for (final i in done)
          if (i < qs.length)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: DsSurface(
                flat: true,
                borderColor: Theme.of(context).colorScheme.ds.border,
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t.crrDoneQ(ld(context, i + 1), ld(context, _scores[i] ?? 0)),
                      style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 4),
                  Text('${qs[i]['text'] ?? ''}'),
                ]),
              ),
            ),
        const SizedBox(height: 12),
        DsButton(onPressed: () => _pickRole('${_role!['id']}'), icon: Icons.replay_rounded, label: t.crrAgain),
        const SizedBox(height: 8),
        DsButton.secondary(onPressed: () => setState(() => _role = null), icon: Icons.list_rounded, label: t.crrRolePick),
      ],
    );
  }
}
