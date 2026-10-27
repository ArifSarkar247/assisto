import 'dart:async';

import 'package:flutter/material.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../payments/credits_out_sheet.dart';
import '../../theme.dart';
import 'agent_core_push.dart';
import 'agent_core_source.dart';
import 'agent_core_widgets.dart';

/// agent-core WP-APP: one run, live — the plan as steps with their real
/// server status (polled), approval cards for steps that need the user's OK,
/// the result with its sources (which module answered), the credits really
/// spent, cancel, and 👍/👎 feedback. Used by the agent screen and by a run
/// opened from history.
///
/// Polling (battery): only while the server is working (queued / running),
/// only while the app is in the foreground, backing off 2 s -> 15 s, and it
/// gives up after [maxPoll] with an honest "still working — check later".
/// It never invents progress: every status shown is what the server said.
class AcRunPanel extends StatefulWidget {
  final AgentCoreSource source;
  final AcRun run;
  final AcTools? tools;
  final ValueChanged<AcRun>? onChanged;

  /// Out of credits + credits bought: run the same goal again (agent screen).
  final ValueChanged<String>? onRetryGoal;

  /// Tests: no real timers.
  final List<Duration> pollSchedule;
  final Duration maxPoll;
  const AcRunPanel(
      {super.key,
      required this.source,
      required this.run,
      this.tools,
      this.onChanged,
      this.onRetryGoal,
      this.pollSchedule = defaultSchedule,
      this.maxPoll = const Duration(minutes: 3)});

  static const defaultSchedule = [
    Duration(seconds: 2),
    Duration(seconds: 3),
    Duration(seconds: 5),
    Duration(seconds: 8),
    Duration(seconds: 13),
    Duration(seconds: 15),
  ];

  @override
  State<AcRunPanel> createState() => AcRunPanelState();
}

class AcRunPanelState extends State<AcRunPanel> with WidgetsBindingObserver {
  late AcRun _run = widget.run;
  Timer? _timer;
  int _polls = 0;
  DateTime _pollStart = DateTime.now();
  bool _gaveUp = false;
  bool _paused = false;
  bool _busy = false;
  final Set<int> _deciding = {};
  int? _fb;
  bool _fbSent = false;
  final _note = TextEditingController();

  AcRun get run => _run;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _fb = _run.feedback;
    _fbSent = _run.feedback != null;
    AgentCorePush.approvalsChanged.addListener(_onPush);
    _schedule(reset: true);
  }

  @override
  void didUpdateWidget(AcRunPanel old) {
    super.didUpdateWidget(old);
    if (old.run.id != widget.run.id) {
      _set(widget.run);
      _fb = _run.feedback;
      _fbSent = _run.feedback != null;
      _schedule(reset: true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AgentCorePush.approvalsChanged.removeListener(_onPush);
    _timer?.cancel();
    _note.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _paused = false;
      if (_run.isOpen) _refresh(); // catch up once, then poll again if needed
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _paused = true;
      _timer?.cancel();
    }
  }

  void _onPush() {
    if (_run.isOpen) _refresh();
  }

  void _set(AcRun r) {
    _run = r;
    widget.onChanged?.call(r);
  }

  void _schedule({bool reset = false}) {
    _timer?.cancel();
    if (reset) {
      _polls = 0;
      _pollStart = DateTime.now();
      _gaveUp = false;
    }
    if (!_run.isWorking || _paused) return;
    if (DateTime.now().difference(_pollStart) > widget.maxPoll) {
      if (mounted) setState(() => _gaveUp = true);
      return;
    }
    final s = widget.pollSchedule;
    if (s.isEmpty) return;
    final wait = s[_polls < s.length ? _polls : s.length - 1];
    _polls++;
    _timer = Timer(wait, _refresh);
  }

  Future<void> _refresh() async {
    try {
      final j = await widget.source.run(_run.id);
      if (!mounted) return;
      setState(() => _set(AcRun.fromJson(j)));
    } catch (_) {
      // keep the last real status; try again on the normal back-off
    }
    if (mounted) _schedule();
  }

  Future<void> manualRefresh() async {
    _schedule(reset: true);
    await _refresh();
  }

  Future<void> _cancel() async {
    setState(() => _busy = true);
    try {
      final j = await widget.source.cancel(_run.id);
      if (mounted) setState(() => _set(AcRun.fromJson(j)));
    } catch (e) {
      _snack(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _decide(AcApproval ap, String decision) async {
    setState(() => _deciding.add(ap.id));
    try {
      final j = await widget.source.decide(ap.id, decision);
      if (!mounted) return;
      final t = AppLocalizations.of(context);
      final st = ((j['approval'] as Map?)?['status'] ?? '').toString();
      final r = j['run'];
      setState(() {
        if (r is Map<String, dynamic>) _set(AcRun.fromJson(r));
      });
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          content: Text(st == 'approved'
              ? t.acApApproved
              : (st == 'rejected' ? t.acApRejected : t.acApGone))));
      unawaited(AgentCorePush.cancelFor(ap.id));
      _schedule(reset: true);
    } catch (e) {
      _snack(e);
    } finally {
      if (mounted) setState(() => _deciding.remove(ap.id));
    }
  }

  Future<void> _sendFeedback() async {
    final v = _fb;
    if (v == null) return;
    setState(() => _busy = true);
    try {
      await widget.source.feedback(_run.id, v, _note.text.trim());
      if (mounted) setState(() => _fbSent = true);
    } catch (e) {
      _snack(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _buyCredits() async {
    final ok = await CreditsOut.offer(context, screen: 'agent_core', draftKept: true);
    if (ok && mounted) widget.onRetryGoal?.call(_run.goal);
  }

  void _snack(Object e) {
    if (!mounted) return;
    final t = AppLocalizations.of(context);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(e is ApiException && e.message.isNotEmpty ? e.message : t.acErrorLoad)));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final bn = acBn(context);
    final r = _run;
    final finished = !r.isOpen;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // ---- header: goal + live state
      Semantics(
        liveRegion: true,
        label: acRunStateLabel(t, r.state),
        child: Row(children: [
          Icon(acStateIcon(r.state), color: acStateColor(s, r.state)),
          const SizedBox(width: Gap.sm),
          Expanded(
              child: Text(acRunStateLabel(t, r.state),
                  key: const ValueKey('ac_run_state'),
                  style: tt.titleMedium?.copyWith(color: acStateColor(s, r.state)))),
          if (r.isWorking)
            const SizedBox(
                width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
        ]),
      ),
      const SizedBox(height: Gap.sm),
      Text(r.goal, style: tt.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
      const SizedBox(height: Gap.xs),
      Wrap(spacing: Gap.md, runSpacing: Gap.xs, children: [
        if (r.topicLabel.isNotEmpty)
          Text(t.acTopic(r.topicLabel), style: TextStyle(color: s.onSurfaceVariant)),
        if (r.createdAt != null)
          Text(t.acStarted(acTime(context, r.createdAt)),
              style: TextStyle(color: s.onSurfaceVariant)),
      ]),
      // ---- honest failure states
      if (r.aiNotSetUp)
        AcMessage(
            key: const ValueKey('ac_no_ai'),
            icon: Icons.power_off_rounded,
            title: t.acNotSetUpTitle,
            body: r.errorText)
      else if (r.outOfCredits)
        AcMessage(
            key: const ValueKey('ac_no_credits'),
            icon: Icons.toll_rounded,
            title: t.acOutOfCreditsTitle,
            body: r.errorText,
            action: t.acBuyCredits,
            onAction: _buyCredits)
      else if (finished && r.state != 'done' && r.errorText.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: Gap.md),
          child: Text(r.errorText,
              key: const ValueKey('ac_error_text'), style: TextStyle(color: s.error)),
        ),
      // ---- approvals waiting inside this run
      for (final ap in r.approvals)
        AcApprovalCard(
            ap: ap,
            busy: _deciding.contains(ap.id),
            onApprove: () => _decide(ap, 'approve'),
            onReject: () => _decide(ap, 'reject')),
      // ---- result + sources
      if (r.state == 'done' && r.answer.isNotEmpty) ...[
        const SizedBox(height: Gap.lg),
        Semantics(header: true, child: Text(t.acAnswerTitle, style: tt.titleSmall)),
        const SizedBox(height: Gap.xs),
        Container(
          key: const ValueKey('ac_answer'),
          padding: const EdgeInsets.all(Gap.md),
          decoration: BoxDecoration(
              color: s.primaryContainer, borderRadius: BorderRadius.circular(Radii.md)),
          child: SelectableText(acDigits(r.answer, bn),
              style: TextStyle(color: s.onPrimaryContainer, height: 1.45)),
        ),
      ],
      if (r.sources.isNotEmpty) ...[
        const SizedBox(height: Gap.md),
        Semantics(header: true, child: Text(t.acSourcesTitle, style: tt.titleSmall)),
        for (final st in r.sources)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.widgets_outlined, size: 18, color: s.onSurfaceVariant),
              const SizedBox(width: Gap.sm),
              Expanded(
                  child: Text(widget.tools?.label(st.tool, bn) ?? st.tool,
                      style: const TextStyle(fontWeight: FontWeight.w600))),
            ]),
          ),
      ],
      // ---- the plan as steps
      if (r.trail.isNotEmpty) ...[
        const SizedBox(height: Gap.lg),
        Semantics(header: true, child: Text(t.acPlanTitle, style: tt.titleSmall)),
        for (final st in r.trail) _step(context, st),
      ],
      const SizedBox(height: Gap.md),
      Text(t.acSpent(acNum(context, r.credits)),
          key: const ValueKey('ac_spent'), style: TextStyle(color: s.onSurfaceVariant)),
      if (_gaveUp && r.isWorking) ...[
        const SizedBox(height: Gap.md),
        Text(t.acStillWorking, key: const ValueKey('ac_still_working')),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: manualRefresh,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(t.acRefresh)),
        ),
      ],
      if (r.isOpen) ...[
        const SizedBox(height: Gap.md),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
              key: const ValueKey('ac_cancel'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _busy ? null : _cancel,
              icon: const Icon(Icons.stop_circle_outlined),
              label: Text(t.acCancel)),
        ),
      ],
      if (finished && r.state != 'cancelled') ...[
        const SizedBox(height: Gap.lg),
        _feedback(context),
      ],
    ]);
  }

  Widget _step(BuildContext context, AcStep st) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final bn = acBn(context);
    final label = st.kind == 'plan' ? t.acStepPlan : (widget.tools?.label(st.tool, bn) ?? st.tool);
    final state = acStepStateLabel(t, st.state);
    return MergeSemantics(
      child: Semantics(
        label: t.acSemStep(acDigits(st.no, bn), label, state),
        excludeSemantics: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.xs),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(acStateIcon(st.state), size: 20, color: acStateColor(s, st.state)),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(
                    [
                      state,
                      if (st.credits > 0) t.acStepCredits(acNum(context, st.credits)),
                    ].join(' · '),
                    style: TextStyle(color: s.onSurfaceVariant, fontSize: 13)),
                if (st.kind == 'tool' && st.state == 'done' && st.summary.isNotEmpty)
                  Text(acDigits(st.summary, bn), style: TextStyle(color: s.onSurface)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _feedback(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    if (_fbSent) {
      return Text(t.acFeedbackThanks,
          key: const ValueKey('ac_fb_thanks'), style: TextStyle(color: s.primary));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(t.acFeedbackAsk, style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: Gap.xs),
      Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
        ChoiceChip(
          key: const ValueKey('ac_fb_up'),
          avatar: const Icon(Icons.thumb_up_alt_outlined, size: 18),
          label: Text(t.acFeedbackUp),
          selected: _fb == 1,
          materialTapTargetSize: MaterialTapTargetSize.padded,
          onSelected: (_) => setState(() => _fb = 1),
        ),
        ChoiceChip(
          key: const ValueKey('ac_fb_down'),
          avatar: const Icon(Icons.thumb_down_alt_outlined, size: 18),
          label: Text(t.acFeedbackDown),
          selected: _fb == -1,
          materialTapTargetSize: MaterialTapTargetSize.padded,
          onSelected: (_) => setState(() => _fb = -1),
        ),
      ]),
      if (_fb != null) ...[
        const SizedBox(height: Gap.sm),
        TextField(
          key: const ValueKey('ac_fb_note'),
          controller: _note,
          maxLength: 300,
          minLines: 1,
          maxLines: 3,
          decoration: InputDecoration(
              labelText: t.acFeedbackNote, border: const OutlineInputBorder()),
        ),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: FilledButton.tonal(
              key: const ValueKey('ac_fb_send'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _busy ? null : _sendFeedback,
              child: Text(t.acFeedbackSend)),
        ),
      ],
    ]);
  }
}
