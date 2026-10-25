import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import 'jobs_store.dart';
import 'jobs_card.dart';

/// Full job detail — the advanced hub for one application: pipeline tracker
/// (stage advance with dates + notes), CV/cover tailoring (MOCK + key-gated via
/// api.jobTailor), interview-prep checklist, company notes and the deterministic
/// next reminder. SPEC v2.1 §21. Zero Bangla literals (all via ARB).
///
/// `onChanged` is called after any server-side status change so the parent can
/// reload. Local-only data (notes, prep ticks, company notes) is persisted via
/// [JobsLocal] and survives offline.
class JobsDetailSheet extends StatefulWidget {
  final Map<String, dynamic> job;
  final bool isServerJob; // sample jobs (id < 0) can't be tracked server-side
  final Future<void> Function() onChanged;
  const JobsDetailSheet({
    super.key,
    required this.job,
    required this.isServerJob,
    required this.onChanged,
  });

  static Future<void> show(BuildContext context, Map<String, dynamic> job,
          {required bool isServerJob, required Future<void> Function() onChanged}) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.85,
          maxChildSize: 0.95,
          minChildSize: 0.5,
          builder: (_, controller) => JobsDetailSheet(
              job: job, isServerJob: isServerJob, onChanged: onChanged),
        ),
      );

  @override
  State<JobsDetailSheet> createState() => _JobsDetailSheetState();
}

class _JobsDetailSheetState extends State<JobsDetailSheet> {
  late Map<String, dynamic> _job;
  Set<int> _prepTicks = {};
  String _note = '', _companyNote = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _job = Map<String, dynamic>.from(widget.job);
    _loadLocal();
  }

  Future<void> _loadLocal() async {
    final id = (_job['id'] ?? 0) as int;
    final company = (_job['company'] ?? '').toString();
    final ticks = id > 0 ? await JobsLocal.prepTicks(id) : <int>{};
    final note = id > 0 ? await JobsLocal.note(id) : '';
    final cnote = company.isNotEmpty ? await JobsLocal.companyNote(company) : '';
    if (mounted) setState(() { _prepTicks = ticks; _note = note; _companyNote = cnote; });
  }

  // --- pipeline stage change (server) -------------------------------------
  Future<void> _advance(String to, AppLocalizations tr) async {
    final id = (_job['id'] ?? 0) as int;
    if (id <= 0) return; // sample job — not persisted
    final note = await _promptNote(tr);
    if (note == null) return; // cancelled
    setState(() => _busy = true);
    try {
      final body = <String, dynamic>{'status': to};
      if (to == kStageApplied) {
        body['applied_at'] = DateTime.now().toUtc().toIso8601String();
      }
      await context.read<AppState>().api.updateItem('jobs', id, body);
      _job['status'] = to;
      await widget.onChanged();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tr.jobsStageUpdated)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tr.jobsCouldNotUpdate)));
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<String?> _promptNote(AppLocalizations tr) async {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.jobsAddNoteOptional),
        content: TextField(
          controller: c,
          maxLines: 3,
          autofocus: true,
          decoration: InputDecoration(hintText: tr.jobsNoteHint, border: const OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: Text(tr.jobsConfirm)),
        ],
      ),
    );
  }

  // --- CV + cover letter (MOCK, key-gated) --------------------------------
  Future<void> _tailor(AppLocalizations tr) async {
    final id = (_job['id'] ?? 0) as int;
    if (id <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr.jobsSampleTrackHint)));
      return;
    }
    setState(() => _busy = true);
    try {
      final r = await context.read<AppState>().api.jobTailor(id);
      if (!mounted) return;
      setState(() => _busy = false);
      if (r['needs_key'] == true) {
        _showKeyGate(tr);
        return;
      }
      final cv = (r['cv_text'] ?? '').toString();
      final cover = (r['cover_letter'] ?? '').toString();
      showDialog(context: context, builder: (_) => AlertDialog(
        title: Text(tr.generated),
        content: SizedBox(width: double.maxFinite, child: SingleChildScrollView(
          child: SelectableText('CV:\n$cv\n\n${tr.coverLetter}:\n$cover'))),
        actions: [
          TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: 'CV:\n$cv\n\nCover:\n$cover'));
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr.copied)));
              },
              child: Text(tr.copy)),
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr.close)),
        ]));
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showKeyGate(AppLocalizations tr) {
    showDialog(context: context, builder: (_) => AlertDialog(
      icon: const Icon(Icons.vpn_key_rounded),
      title: Text(tr.jobsAiNeededTitle),
      content: Text(tr.availableWhenAnAiKey2),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr.ok))],
    ));
  }

  Future<void> _editNote(AppLocalizations tr) async {
    final id = (_job['id'] ?? 0) as int;
    if (id <= 0) return;
    final c = TextEditingController(text: _note);
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text(tr.jobsYourNotes),
      content: TextField(controller: c, maxLines: 5, autofocus: true,
          decoration: InputDecoration(hintText: tr.jobsNoteHint, border: const OutlineInputBorder())),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr.cancel)),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr.save)),
      ]));
    if (ok == true) {
      await JobsLocal.setNote(id, c.text.trim());
      setState(() => _note = c.text.trim());
    }
  }

  Future<void> _editCompanyNote(AppLocalizations tr) async {
    final company = (_job['company'] ?? '').toString();
    if (company.isEmpty) return;
    final c = TextEditingController(text: _companyNote);
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text(tr.jobsCompanyNotesFor(company)),
      content: TextField(controller: c, maxLines: 5, autofocus: true,
          decoration: InputDecoration(hintText: tr.jobsCompanyNoteHint, border: const OutlineInputBorder())),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr.cancel)),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr.save)),
      ]));
    if (ok == true) {
      await JobsLocal.setCompanyNote(company, c.text.trim());
      setState(() => _companyNote = c.text.trim());
    }
  }

  Future<void> _toggleTick(int i) async {
    final id = (_job['id'] ?? 0) as int;
    if (id <= 0) return;
    final s = Set<int>.from(_prepTicks);
    s.contains(i) ? s.remove(i) : s.add(i);
    await JobsLocal.setPrepTicks(id, s);
    setState(() => _prepTicks = s);
  }

  List<String> _prepTexts(AppLocalizations tr) => [
        tr.jobsPrepResearch, tr.jobsPrepMapSkills, tr.jobsPrepPractise,
        tr.jobsPrepQuestions, tr.jobsPrepLogistics, tr.jobsPrepDocs, tr.jobsPrepThankYou,
      ];

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final status = (_job['status'] ?? kStageMatched).toString();
    final company = (_job['company'] ?? '').toString();
    final jd = (_job['jd'] ?? '').toString();
    final idx = pipelineIndex(status);

    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xl),
      children: [
        Row(children: [
          Expanded(child: Text('${_job['title'] ?? ''}',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800))),
          const SizedBox(width: Gap.sm),
          StageBadge(status: status),
        ]),
        if (company.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 2),
              child: Text(company, style: TextStyle(color: scheme.onSurfaceVariant))),
        const SizedBox(height: Gap.lg),

        // pipeline spine
        if (idx >= 0)
          _PipelineSpine(index: idx)
        else
          Container(
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              Icon(Icons.flag_rounded, color: scheme.onErrorContainer, size: 18),
              const SizedBox(width: Gap.sm),
              Expanded(child: Text(
                  status == kStageRejected ? tr.jobsStageRejected : tr.jobsStageWithdrawn,
                  style: TextStyle(color: scheme.onErrorContainer, fontWeight: FontWeight.w600))),
            ]),
          ),
        const SizedBox(height: Gap.lg),

        // tracker actions
        if (!widget.isServerJob)
          _InfoNote(icon: Icons.info_outline_rounded, text: tr.jobsSampleTrackHint)
        else ...[
          Text(tr.jobsMoveStage, style: _h(scheme)),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            for (final s in nextStages(status))
              ActionChip(
                avatar: Icon(_stageIcon(s), size: 18),
                label: Text(_stageLabel(tr, s)),
                onPressed: _busy ? null : () => _advance(s, tr),
              ),
            if (nextStages(status).isEmpty)
              Text(tr.jobsNoFurtherStage, style: TextStyle(color: scheme.onSurfaceVariant)),
          ]),
        ],
        const SizedBox(height: Gap.lg),

        // reminder
        if (widget.isServerJob) _reminderCard(tr, scheme, status),

        // AI tailoring (mock + key-gated)
        const SizedBox(height: Gap.md),
        FilledButton.tonalIcon(
          onPressed: _busy ? null : () => _tailor(tr),
          icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.auto_awesome_rounded),
          label: Text(tr.jobsTailorCvCover),
        ),
        Padding(padding: const EdgeInsets.only(top: 4, left: 4),
            child: Text(tr.jobsTailorKeyNote, style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant))),
        const SizedBox(height: Gap.lg),

        // interview prep checklist
        _collapsibleHeader(tr.jobsInterviewPrep, Icons.checklist_rtl_rounded, scheme),
        for (int i = 0; i < _prepTexts(tr).length; i++)
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _prepTicks.contains(i),
            onChanged: widget.isServerJob ? (_) => _toggleTick(i) : null,
            title: Text(_prepTexts(tr)[i], style: const TextStyle(fontSize: 14)),
          ),
        const SizedBox(height: Gap.md),

        // your notes
        _notePanel(tr, scheme, title: tr.jobsYourNotes, body: _note,
            empty: tr.jobsNoNotesYet, onEdit: () => _editNote(tr)),
        const SizedBox(height: Gap.md),

        // company notes
        if (company.isNotEmpty)
          _notePanel(tr, scheme, title: tr.jobsCompanyNotesFor(company), body: _companyNote,
              empty: tr.jobsNoCompanyNotes, onEdit: () => _editCompanyNote(tr)),
        const SizedBox(height: Gap.md),

        // job description
        if (jd.isNotEmpty) ...[
          _collapsibleHeader(tr.jobDescription, Icons.description_rounded, scheme),
          Text(jd, style: TextStyle(height: 1.4, color: scheme.onSurface)),
        ],
        const SizedBox(height: Gap.lg),
        _InfoNote(icon: Icons.verified_user_rounded, text: tr.iNeverAutoApplyYou),
      ],
    );
  }

  Widget _reminderCard(AppLocalizations tr, ColorScheme scheme, String status) {
    final r = _computeReminder(status);
    if (r == null) return const SizedBox.shrink();
    final overdue = r['overdue'] as bool;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: overdue ? scheme.errorContainer : scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        Icon(overdue ? Icons.notifications_active_rounded : Icons.schedule_rounded,
            color: overdue ? scheme.onErrorContainer : scheme.onSecondaryContainer, size: 20),
        const SizedBox(width: Gap.sm),
        Expanded(child: Text(
          overdue ? tr.jobsReminderOverdue(r['text'] as String) : tr.jobsReminderDue(r['text'] as String, r['due'] as String),
          style: TextStyle(
              color: overdue ? scheme.onErrorContainer : scheme.onSecondaryContainer,
              fontWeight: FontWeight.w600),
        )),
      ]),
    );
  }

  /// Deterministic reminder mirror of job_hunter.next_reminder (dates only).
  Map<String, dynamic>? _computeReminder(String status) {
    const afterDays = {kStageSaved: 3, kStageApplied: 7, kStageInterview: 2};
    if (!afterDays.containsKey(status)) return null;
    final anchorStr = (_job['applied_at'] ?? _job['created_at'])?.toString();
    final anchor = anchorStr != null ? DateTime.tryParse(anchorStr) : null;
    if (anchor == null) return null;
    final due = DateUtils.dateOnly(anchor).add(Duration(days: afterDays[status]!));
    final today = DateUtils.dateOnly(DateTime.now());
    final tr = AppLocalizations.of(context);
    final text = {
      kStageSaved: tr.jobsReminderApplySoon,
      kStageApplied: tr.jobsReminderFollowUp,
      kStageInterview: tr.jobsReminderPrep,
    }[status]!;
    return {
      'overdue': !due.isAfter(today),
      'due': '${due.year}-${due.month.toString().padLeft(2, '0')}-${due.day.toString().padLeft(2, '0')}',
      'text': text,
    };
  }

  Widget _notePanel(AppLocalizations tr, ColorScheme scheme,
      {required String title, required String body, required String empty, required VoidCallback onEdit}) {
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(title, style: _h(scheme))),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.edit_rounded, size: 18),
            onPressed: widget.isServerJob ? onEdit : null,
            tooltip: tr.edit,
          ),
        ]),
        const SizedBox(height: 4),
        Text(body.isEmpty ? empty : body,
            style: TextStyle(color: body.isEmpty ? scheme.onSurfaceVariant : scheme.onSurface, height: 1.4)),
      ]),
    );
  }

  Widget _collapsibleHeader(String text, IconData icon, ColorScheme scheme) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.sm, top: 4),
        child: Row(children: [
          Icon(icon, size: 18, color: scheme.primary),
          const SizedBox(width: Gap.sm),
          Text(text, style: _h(scheme)),
        ]),
      );

  TextStyle _h(ColorScheme scheme) =>
      TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: scheme.onSurface);

  IconData _stageIcon(String s) => {
        kStageSaved: Icons.bookmark_added_rounded,
        kStageApplied: Icons.send_rounded,
        kStageInterview: Icons.event_available_rounded,
        kStageOffer: Icons.celebration_rounded,
        kStageRejected: Icons.cancel_rounded,
        kStageWithdrawn: Icons.undo_rounded,
        kStageMatched: Icons.replay_rounded,
      }[s] ?? Icons.arrow_forward_rounded;

  String _stageLabel(AppLocalizations tr, String s) => {
        kStageMatched: tr.jobsStageMatched,
        kStageSaved: tr.jobsStageSaved,
        kStageApplied: tr.jobsStageApplied,
        kStageInterview: tr.jobsStageInterview,
        kStageOffer: tr.jobsStageOffer,
        kStageRejected: tr.jobsStageRejected,
        kStageWithdrawn: tr.jobsStageWithdrawn,
      }[s] ?? s;
}

/// The visual pipeline progress spine (matched → … → offer).
class _PipelineSpine extends StatelessWidget {
  final int index;
  const _PipelineSpine({required this.index});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final labels = [
      tr.jobsStageMatched, tr.jobsStageSaved, tr.jobsStageApplied,
      tr.jobsStageInterview, tr.jobsStageOffer,
    ];
    return Row(children: [
      for (int i = 0; i < labels.length; i++) ...[
        Expanded(child: Column(children: [
          Container(
            width: 24, height: 24,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i <= index ? scheme.primary : scheme.surfaceContainerHighest,
            ),
            child: i < index
                ? Icon(Icons.check_rounded, size: 14, color: scheme.onPrimary)
                : i == index
                    ? Icon(Icons.circle_rounded, size: 10, color: scheme.onPrimary)
                    : null,
          ),
          const SizedBox(height: 4),
          Text(labels[i],
              textAlign: TextAlign.center,
              maxLines: 2,
              style: TextStyle(
                  fontSize: 10,
                  height: 1.1,
                  fontWeight: i == index ? FontWeight.w700 : FontWeight.w400,
                  color: i <= index ? scheme.onSurface : scheme.onSurfaceVariant)),
        ])),
        if (i < labels.length - 1)
          Container(width: 12, height: 2,
              margin: const EdgeInsets.only(bottom: 22),
              color: i < index ? scheme.primary : scheme.surfaceContainerHighest),
      ],
    ]);
  }
}

class _InfoNote extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoNote({required this.icon, required this.text});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        Icon(icon, size: 18, color: scheme.onSurfaceVariant),
        const SizedBox(width: Gap.sm),
        Expanded(child: Text(text, style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant, height: 1.3))),
      ]),
    );
  }
}
