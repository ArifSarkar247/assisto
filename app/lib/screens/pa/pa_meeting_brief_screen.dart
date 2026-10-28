import '../../feature_gates.dart' show kShowKeySeams;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../../theme.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/pa_engine.dart';

/// PA Secretary — MEETING REMINDER + 1-PAGE BRIEF (SPEC v2.1 §14 #104,
/// ADVANCED §21).
///
/// For a selected meeting: configure reminder lead-times, fill the structured
/// brief fields (purpose, agenda bullets, prep checklist), and view/share a
/// DETERMINISTIC one-page brief assembled from THOSE fields — never AI, never
/// fabricated. Logic mirrors core.logic.pa_brief via pa_engine.dart.
///
/// Honest states: a brief that is missing sections says so (and a small "N%
/// ready" meter), the reminder config honestly flags when every chosen lead is
/// already in the past, and the AI-enhanced brief is a clearly key-gated,
/// NOT-built seam (documented, disabled, labelled). ZERO Bangla glyphs here —
/// every string is an AppLocalizations getter.
class PaMeetingBriefScreen extends StatefulWidget {
  final Map<String, dynamic> meeting;
  final Future<void> Function(Map<String, dynamic> updated)? onSaved;
  const PaMeetingBriefScreen({super.key, required this.meeting, this.onSaved});

  @override
  State<PaMeetingBriefScreen> createState() => _PaMeetingBriefScreenState();
}

class _PaMeetingBriefScreenState extends State<PaMeetingBriefScreen> {
  late Map<String, dynamic> _m;
  late final TextEditingController _purpose;
  late final TextEditingController _agenda;
  late final TextEditingController _prep;
  late List<int> _leads;
  bool _dirty = false;

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _m = Map<String, dynamic>.from(widget.meeting);
    _purpose = TextEditingController(text: '${_m['purpose'] ?? _m['what'] ?? ''}');
    _agenda = TextEditingController(text: _joinBullets(_m['agenda']));
    _prep = TextEditingController(text: _joinBullets(_m['prep']));
    final raw = (_m['leads'] as List?)?.map((e) => e is int ? e : int.tryParse('$e') ?? -1).toList();
    _leads = cleanLeads(raw?.where((e) => e >= 0).toList());
  }

  @override
  void dispose() {
    _purpose.dispose();
    _agenda.dispose();
    _prep.dispose();
    super.dispose();
  }

  String _joinBullets(dynamic raw) {
    if (raw is List) return raw.join('\n');
    return '${raw ?? ''}';
  }

  Map<String, dynamic> get _current => {
        ..._m,
        'purpose': _purpose.text.trim(),
        'agenda': splitBullets(_agenda.text),
        'prep': splitBullets(_prep.text),
        'leads': _leads,
      };

  Future<void> _save() async {
    final updated = _current;
    setState(() {
      _m = updated;
      _dirty = false;
    });
    if (widget.onSaved != null) await widget.onSaved!(updated);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.paBriefSaved)));
    }
  }

  Future<void> _share() async {
    final text = briefShareText(context, _current);
    await Clipboard.setData(ClipboardData(text: text));
    await Share.share(text, subject: '${_current['title'] ?? ''}');
  }

  Future<void> _copy() async {
    await Clipboard.setData(
        ClipboardData(text: briefShareText(context, _current)));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.copied)));
    }
  }

  void _toggleLead(int lead) {
    setState(() {
      final set = _leads.toSet();
      if (!set.add(lead)) set.remove(lead);
      _leads = cleanLeads(set.toList());
      _dirty = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final b = assembleBrief(_current);
    final scheme = Theme.of(context).colorScheme;
    final pct = briefCompleteness(_current);
    final rs = reminderSummary(b.start, _leads);

    return Scaffold(
      appBar: AppBar(
        title: Text(t.paBriefTitle),
        actions: [
          IconButton(
            tooltip: t.paShare,
            onPressed: b.hasCore ? _share : null,
            icon: const Icon(Icons.ios_share_rounded),
          ),
        ],
      ),
      floatingActionButton: _dirty
          ? FloatingActionButton.extended(
              onPressed: _save,
              icon: const Icon(Icons.check_rounded),
              label: Text(t.save),
            )
          : null,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 96),
        children: [
          // honest AI marker: this brief is a deterministic assembly, not AI.
          _DeterministicMarker(text: t.paBriefDeterministic),
          const SizedBox(height: Gap.lg),

          if (!b.hasCore)
            _IncompleteCore(text: t.paBriefNeedsCore)
          else ...[
            _CompletenessMeter(pct: pct),
            const SizedBox(height: Gap.lg),
            _BriefPreview(brief: b),
            const SizedBox(height: Gap.lg),
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _share,
                  icon: const Icon(Icons.ios_share_rounded, size: 18),
                  label: Text(t.paShare),
                ),
              ),
              const SizedBox(width: Gap.sm),
              OutlinedButton.icon(
                onPressed: _copy,
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: Text(t.copy),
              ),
            ]),
          ],

          const SizedBox(height: Gap.xl),
          _SectionLabel(text: t.paBriefFieldsHeading),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _purpose,
            onChanged: (_) => setState(() => _dirty = true),
            maxLines: 2,
            decoration: InputDecoration(
                labelText: t.paBriefWhat,
                hintText: t.paBriefWhatHint,
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _agenda,
            onChanged: (_) => setState(() => _dirty = true),
            maxLines: null,
            minLines: 3,
            decoration: InputDecoration(
                labelText: t.paBriefAgenda,
                hintText: t.paBriefBulletHint,
                alignLabelWithHint: true,
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _prep,
            onChanged: (_) => setState(() => _dirty = true),
            maxLines: null,
            minLines: 3,
            decoration: InputDecoration(
                labelText: t.paBriefPrep,
                hintText: t.paBriefBulletHint,
                alignLabelWithHint: true,
                border: const OutlineInputBorder()),
          ),

          const SizedBox(height: Gap.xl),
          _SectionLabel(text: t.paReminderHeading),
          const SizedBox(height: Gap.sm),
          Text(t.paReminderHint,
              style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.3)),
          const SizedBox(height: Gap.md),
          Wrap(
            spacing: Gap.sm,
            runSpacing: Gap.sm,
            children: kLeadOptions
                .map((lead) => FilterChip(
                      label: Text(leadLabel(t, lead)),
                      selected: _leads.contains(lead),
                      onSelected: (_) => _toggleLead(lead),
                    ))
                .toList(),
          ),
          const SizedBox(height: Gap.md),
          _ReminderStatus(summary: rs, hasCore: b.hasCore),

          const SizedBox(height: Gap.xl),
          _AiSeamCard(text: t.paBriefAiSeam, cta: t.paBriefAiCta),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// pieces
// ---------------------------------------------------------------------------

class _DeterministicMarker extends StatelessWidget {
  final String text;
  const _DeterministicMarker({required this.text});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(children: [
        Icon(Icons.verified_rounded, size: 18, color: scheme.primary),
        const SizedBox(width: Gap.sm),
        Expanded(
            child: Text(text,
                style: AType.bodySmall.copyWith(height: 1.35))),
      ]),
    );
  }
}

class _IncompleteCore extends StatelessWidget {
  final String text;
  const _IncompleteCore({required this.text});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xl),
      child: Column(children: [
        Icon(Icons.event_busy_rounded,
            size: 44, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(height: Gap.md),
        Text(text,
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.4)),
      ]),
    );
  }
}

class _CompletenessMeter extends StatelessWidget {
  final int pct;
  const _CompletenessMeter({required this.pct});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
          child: Text(t.paBriefReady(pct),
              style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w600)),
        ),
      ]),
      const SizedBox(height: Gap.xs),
      ClipRRect(
        borderRadius: BorderRadius.circular(Radii.pill),
        child: LinearProgressIndicator(
          value: pct / 100.0,
          minHeight: 8,
          backgroundColor: scheme.surfaceContainerHighest,
          valueColor: AlwaysStoppedAnimation(
              pct >= 100 ? Brand.success : Brand.blue),
        ),
      ),
    ]);
  }
}

class _BriefPreview extends StatelessWidget {
  final Brief brief;
  const _BriefPreview({required this.brief});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final loc = Localizations.localeOf(context).toString();
    final df = DateFormat('EEE, d MMM yyyy · HH:mm', loc);
    final hf = DateFormat('HH:mm', loc);
    String whenStr = '';
    if (brief.start != null) {
      whenStr = df.format(brief.start!);
      if (brief.end != null) whenStr += ' – ${hf.format(brief.end!)}';
    }

    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      padding: const EdgeInsets.all(Gap.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(brief.title,
            style: AType.titleLarge.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: Gap.md),
        _row(context, Icons.schedule_rounded, t.paBriefWhen, whenStr),
        _row(context, Icons.place_rounded, t.paBriefWhere, brief.where,
            missing: brief.missing.contains('where'), t: t),
        _row(context, Icons.group_rounded, t.paBriefWho, brief.who.join(', '),
            missing: brief.missing.contains('who'), t: t),
        _row(context, Icons.flag_rounded, t.paBriefWhat, brief.what,
            missing: brief.missing.contains('what'), t: t),
        const SizedBox(height: Gap.md),
        _bulletBlock(context, t.paBriefAgenda, brief.agenda,
            empty: brief.missing.contains('agenda'), t: t, check: false),
        const SizedBox(height: Gap.md),
        _bulletBlock(context, t.paBriefPrep, brief.prep,
            empty: brief.missing.contains('prep'), t: t, check: true),
        if (brief.note.isNotEmpty) ...[
          const SizedBox(height: Gap.md),
          _row(context, Icons.sticky_note_2_rounded, t.paBriefNote,
              brief.note),
        ],
      ]),
    );
  }

  Widget _row(BuildContext context, IconData icon, String label, String value,
      {bool missing = false, AppLocalizations? t}) {
    final scheme = Theme.of(context).colorScheme;
    final showValue = value.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 16, color: scheme.onSurfaceVariant),
        const SizedBox(width: Gap.sm),
        SizedBox(
          width: 70,
          child: Text(label,
              style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600)),
        ),
        Expanded(
          child: Text(
            showValue ? value : (t?.paBriefMissing ?? ''),
            style: AType.bodyMedium.copyWith(height: 1.35, fontStyle: showValue ? null : FontStyle.italic, color: showValue
                    ? null
                    : scheme.onSurfaceVariant.withValues(alpha: 0.7)),
          ),
        ),
      ]),
    );
  }

  Widget _bulletBlock(
      BuildContext context, String label, List<String> items,
      {required bool empty, required AppLocalizations t, required bool check}) {
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label,
          style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: Gap.xs),
      if (empty)
        Text(t.paBriefSectionEmpty,
            style: AType.bodyMedium.copyWith(fontStyle: FontStyle.italic, color: scheme.onSurfaceVariant.withValues(alpha: 0.7)))
      else
        ...items.map((x) => Padding(
              padding: const EdgeInsets.only(top: Gap.xxs, bottom: Gap.xxs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                      check
                          ? Icons.check_box_outline_blank_rounded
                          : Icons.circle_rounded,
                      size: check ? 16 : 7,
                      color: scheme.primary),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                      child: Text(x,
                          style: AType.bodyMedium.copyWith(height: 1.35))),
                ],
              ),
            )),
    ]);
  }
}

class _ReminderStatus extends StatelessWidget {
  final ReminderSummary summary;
  final bool hasCore;
  const _ReminderStatus({required this.summary, required this.hasCore});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (!hasCore) {
      return Text(t.paReminderNoTime,
          style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, fontStyle: FontStyle.italic));
    }
    if (summary.allPast) {
      return Row(children: [
        const Icon(Icons.history_toggle_off_rounded, size: 16, color: Brand.warning),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(t.paReminderAllPast,
              style: AType.bodySmall.copyWith(color: Brand.warning)),
        ),
      ]);
    }
    if (summary.count == 0) {
      return Text(t.paReminderNone,
          style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant));
    }
    final loc = Localizations.localeOf(context).toString();
    final nextStr = summary.next == null
        ? ''
        : DateFormat('d MMM, HH:mm', loc).format(summary.next!);
    return Row(children: [
      const Icon(Icons.notifications_active_rounded,
          size: 16, color: Brand.success),
      const SizedBox(width: Gap.sm),
      Expanded(
        child: Text(t.paReminderNext(summary.count, nextStr),
            style: AType.bodySmall),
      ),
    ]);
  }
}

class _AiSeamCard extends StatelessWidget {
  final String text;
  final String cta;
  const _AiSeamCard({required this.text, required this.cta});
  @override
  Widget build(BuildContext context) {
    if (!kShowKeySeams) return const SizedBox.shrink(); // truth: no key dead end
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(children: [
        Icon(Icons.auto_awesome_rounded,
            size: 20, color: scheme.onSurfaceVariant),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(text,
                style: AType.bodySmall.copyWith(height: 1.3, color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.xs),
            // Honest: disabled — key-gated seam, not built in this batch.
            TextButton.icon(
              onPressed: null,
              icon: const Icon(Icons.lock_outline_rounded, size: 14),
              label: Text(cta),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel({required this.text});
  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800));
  }
}
