import 'package:flutter/material.dart';

import '../../api.dart';
import '../../ds/ds.dart';
import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import 'agent_core_widgets.dart';

/// agentcore (18 Nov): the agent's PROACTIVE cards on the agent screen
/// ("For you") + the user's own audit trail ("What the agent did").
///
/// A card shows what the trigger found (a bill / loan due), why the user sees
/// it, and — when the agent proposes an action — the exact action with
/// Approve / Not now. Nothing happens without the tap; the server re-checks
/// every number against the user's records before the card is shown and
/// again at the tap (suggest.py). No Bangla literals here (language gate).
abstract class AgentNudgeSource {
  Future<Map<String, dynamic>> nudges();
  Future<Map<String, dynamic>> dismiss(int id);
  Future<Map<String, dynamic>> decide(int approvalId, String decision);
  Future<Map<String, dynamic>> activity();
}

class ApiAgentNudgeSource implements AgentNudgeSource {
  final ApiClient api;
  ApiAgentNudgeSource(this.api);
  static const _p = '/agent-core';
  @override
  Future<Map<String, dynamic>> nudges() => api.getJson('$_p/nudges');
  @override
  Future<Map<String, dynamic>> dismiss(int id) => api.postJson('$_p/nudges/$id/dismiss');
  @override
  Future<Map<String, dynamic>> decide(int approvalId, String decision) =>
      api.postJson('$_p/approvals/$approvalId', {'decision': decision});
  @override
  Future<Map<String, dynamic>> activity() => api.getJson('$_p/activity');
}

int _i(Object? v) => v is int ? v : (v is num ? v.toInt() : int.tryParse('$v') ?? 0);
String _s(Object? v) => v == null ? '' : '$v';

class AcNudgeAction {
  final int approvalId;
  final String status; // pending | approved | rejected | expired
  final String title;
  final String reminderTitle;
  final DateTime? dueAt;
  final DateTime? expiresAt;
  final bool done;
  final String result;
  final String error;
  const AcNudgeAction(
      {required this.approvalId,
      required this.status,
      required this.title,
      this.reminderTitle = '',
      this.dueAt,
      this.expiresAt,
      this.done = false,
      this.result = '',
      this.error = ''});
  factory AcNudgeAction.fromJson(Map<String, dynamic> j) => AcNudgeAction(
      approvalId: _i(j['approval_id']),
      status: _s(j['status']),
      title: _s(j['title']),
      reminderTitle: _s(j['reminder_title']),
      dueAt: DateTime.tryParse(_s(j['due_at']))?.toLocal(),
      expiresAt: DateTime.tryParse(_s(j['expires_at']))?.toLocal(),
      done: j['done'] == true,
      result: _s(j['result']),
      error: _s(j['error']));
}

class AcNudge {
  final int id;
  final String label;
  final String title;
  final String body;
  final String why;
  final bool? verified;
  final AcNudgeAction? action;
  const AcNudge(
      {required this.id,
      required this.label,
      required this.title,
      required this.body,
      required this.why,
      this.verified,
      this.action});
  factory AcNudge.fromJson(Map<String, dynamic> j) => AcNudge(
      id: _i(j['id']),
      label: _s(j['label']),
      title: _s(j['title']),
      body: _s(j['body']),
      why: _s(j['why']),
      verified: j['verified'] is bool ? j['verified'] as bool : null,
      action: j['action'] is Map
          ? AcNudgeAction.fromJson((j['action'] as Map).cast<String, dynamic>())
          : null);
}

/// "For you" — the proactive cards, newest first.
class AgentNudgesSection extends StatefulWidget {
  final AgentNudgeSource source;
  final VoidCallback? onOpenActivity;
  const AgentNudgesSection({super.key, required this.source, this.onOpenActivity});

  @override
  State<AgentNudgesSection> createState() => AgentNudgesSectionState();
}

class AgentNudgesSectionState extends State<AgentNudgesSection> {
  List<AcNudge>? _rows;
  bool _failed = false;
  final Set<int> _busy = {};
  final Map<int, String> _errors = {};

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    try {
      final j = await widget.source.nudges();
      final rows = [
        for (final r in (j['results'] as List? ?? const []))
          if (r is Map) AcNudge.fromJson(r.cast<String, dynamic>())
      ];
      if (mounted) {
        setState(() {
          _rows = rows;
          _failed = false;
        });
      }
    } catch (e) {
      // feature off / offline: the section stays out of the way (the
      // screen itself shows the feature-off and offline states)
      final off = e is ApiException && e.status == 403;
      if (mounted) {
        setState(() {
          _failed = !off;
          if (off) _rows = const [];
        });
      }
    }
  }

  Future<void> _decide(AcNudge n, String decision) async {
    final a = n.action;
    if (a == null || _busy.contains(n.id)) return;
    setState(() {
      _busy.add(n.id);
      _errors.remove(n.id);
    });
    try {
      await widget.source.decide(a.approvalId, decision);
      await reload();
    } catch (_) {
      if (mounted) setState(() => _errors[n.id] = AppLocalizations.of(context).acnFailed);
    } finally {
      if (mounted) setState(() => _busy.remove(n.id));
    }
  }

  Future<void> _hide(AcNudge n) async {
    setState(() => _busy.add(n.id));
    try {
      await widget.source.dismiss(n.id);
      await reload();
    } catch (_) {
      if (mounted) setState(() => _errors[n.id] = AppLocalizations.of(context).acnFailed);
    } finally {
      if (mounted) setState(() => _busy.remove(n.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final rows = _rows;
    if (rows == null && !_failed) return const SizedBox.shrink();
    return Column(
      key: const ValueKey('ac_nudges'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
            header: true,
            child: Text(t.acnForYou, style: Theme.of(context).textTheme.titleMedium)),
        const SizedBox(height: Gap.sm),
        if (_failed)
          AcMessage(
              key: const ValueKey('ac_nudges_error'),
              icon: Icons.cloud_off_rounded,
              body: t.acnLoadError,
              action: t.acRetry,
              onAction: reload)
        else if (rows!.isEmpty)
          Text(t.acnNothing,
              key: const ValueKey('ac_nudges_empty'),
              style: AType.bodyMedium.copyWith(color: s.ds.muted, height: 1.4))
        else
          for (final n in rows) ...[
            _card(context, n),
            const SizedBox(height: Gap.md),
          ],
        const SizedBox(height: Gap.lg),
      ],
    );
  }

  Widget _card(BuildContext context, AcNudge n) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final busy = _busy.contains(n.id);
    final a = n.action;
    return Card(
      key: ValueKey('ac_nudge_${n.id}'),
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.lg), side: BorderSide(color: s.ds.border)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.xs, Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.event_note_rounded, color: s.ds.primaryInk),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (n.label.isNotEmpty)
                  Text(n.label, style: AType.bodyMedium.copyWith(color: s.ds.muted)),
                Text(n.title,
                    style: AType.bodyMedium.copyWith(color: s.ds.text, fontWeight: FontWeight.w700)),
              ]),
            ),
            IconButton(
              key: ValueKey('ac_nudge_hide_${n.id}'),
              tooltip: t.acnHide,
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: busy ? null : () => _hide(n),
              icon: const Icon(Icons.close_rounded),
            ),
          ]),
          Padding(
            padding: const EdgeInsetsDirectional.only(end: Gap.md),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (n.body.isNotEmpty) ...[
                const SizedBox(height: Gap.xs),
                Text(n.body, style: AType.bodyMedium.copyWith(color: s.ds.text, height: 1.4)),
              ],
              if (n.why.isNotEmpty) ...[
                const SizedBox(height: Gap.xs),
                Text(t.acnWhy(n.why),
                    style: AType.bodyMedium.copyWith(color: s.ds.muted, height: 1.4)),
              ],
              if (n.verified == true) ...[
                const SizedBox(height: Gap.xs),
                Row(children: [
                  Icon(Icons.verified_rounded, size: 18, color: s.ds.successInk),
                  const SizedBox(width: Gap.xs),
                  Expanded(
                      child: Text(t.acnChecked,
                          key: ValueKey('ac_nudge_checked_${n.id}'),
                          style: AType.bodyMedium.copyWith(color: s.ds.successInk))),
                ]),
              ],
              if (a != null) ...[
                const SizedBox(height: Gap.md),
                _action(context, n, a, busy),
              ],
              if (_errors[n.id] != null) ...[
                const SizedBox(height: Gap.sm),
                Text(_errors[n.id]!, style: AType.bodyMedium.copyWith(color: s.error)),
              ],
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _action(BuildContext context, AcNudge n, AcNudgeAction a, bool busy) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    if (a.status == 'pending') {
      final left = a.expiresAt?.difference(DateTime.now());
      final hours = left == null ? 0 : left.inHours;
      return Container(
        key: ValueKey('ac_nudge_ask_${a.approvalId}'),
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
            color: s.ds.primarySoft, borderRadius: BorderRadius.circular(Radii.md)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.front_hand_rounded, color: s.ds.primaryInk),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: Text(a.title,
                    style: AType.bodyMedium
                        .copyWith(color: s.ds.primaryInk, fontWeight: FontWeight.w600, height: 1.4))),
          ]),
          const SizedBox(height: Gap.xs),
          Text(hours >= 1 ? t.acnExpiresIn(acNum(context, hours)) : t.acnExpiresSoon,
              style: AType.bodyMedium.copyWith(color: s.ds.primaryInk, height: 1.4)),
          const SizedBox(height: Gap.md),
          Wrap(alignment: WrapAlignment.end, spacing: Gap.sm, runSpacing: Gap.sm, children: [
            DsButton.secondary(
                buttonKey: ValueKey('ac_nudge_reject_${a.approvalId}'),
                onPressed: busy ? null : () => _decide(n, 'reject'),
                label: t.acnNotNow),
            DsButton(
                buttonKey: ValueKey('ac_nudge_approve_${a.approvalId}'),
                onPressed: busy ? null : () => _decide(n, 'approve'),
                busy: busy,
                icon: Icons.check_rounded,
                label: t.acnApprove),
          ]),
        ]),
      );
    }
    final ok = a.status == 'approved' && a.done;
    final text = ok
        ? (a.result.isNotEmpty ? a.result : t.acnDone)
        : a.error == 'stale_data'
            ? t.acnStale
            : a.status == 'expired'
                ? t.acnExpired
                : a.status == 'rejected'
                    ? t.acnRejected
                    : (a.result.isNotEmpty ? a.result : t.acnWorking);
    final ink = ok ? s.ds.successInk : s.ds.muted;
    return Semantics(
      liveRegion: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(ok ? Icons.check_circle_rounded : Icons.do_not_disturb_on_outlined, color: ink),
          const SizedBox(width: Gap.sm),
          Expanded(
              child: Text(text,
                  key: ValueKey('ac_nudge_result_${a.approvalId}'),
                  style: AType.bodyMedium.copyWith(color: ink, height: 1.4))),
        ]),
        if (widget.onOpenActivity != null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
                key: ValueKey('ac_nudge_activity_${a.approvalId}'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: widget.onOpenActivity,
                child: Text(t.acnActivity)),
          ),
      ]),
    );
  }
}

/// "What the agent did" — the user's own audit trail (newest first).
class AgentActivityScreen extends StatefulWidget {
  final AgentNudgeSource source;
  const AgentActivityScreen({super.key, required this.source});

  @override
  State<AgentActivityScreen> createState() => _AgentActivityScreenState();
}

class _AgentActivityScreenState extends State<AgentActivityScreen> {
  List<Map<String, dynamic>>? _rows;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final j = await widget.source.activity();
      final rows = [
        for (final r in (j['events'] as List? ?? const []))
          if (r is Map) r.cast<String, dynamic>()
      ];
      if (mounted) setState(() => _rows = rows);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final rows = _rows;
    Widget body;
    if (_failed) {
      body = Center(
          child: AcMessage(
              icon: Icons.cloud_off_rounded, body: t.acnLoadError, action: t.acRetry, onAction: _load));
    } else if (rows == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (rows.isEmpty) {
      body = ListView(padding: const EdgeInsets.all(Gap.lg), children: [
        Icon(Icons.history_edu_rounded, size: 48, color: s.ds.primaryInk),
        const SizedBox(height: Gap.md),
        Text(t.acnActivityEmpty,
            key: const ValueKey('ac_activity_empty'),
            textAlign: TextAlign.center,
            style: AType.bodyMedium.copyWith(color: s.ds.text, height: 1.4)),
        const SizedBox(height: Gap.sm),
        Text(t.acnActivityHow,
            textAlign: TextAlign.center,
            style: AType.bodyMedium.copyWith(color: s.ds.muted, height: 1.4)),
        const SizedBox(height: Gap.lg),
        DsButton(
            buttonKey: const ValueKey('ac_activity_start'),
            onPressed: () => Navigator.of(context).maybePop(),
            icon: Icons.smart_toy_outlined,
            expand: true,
            label: t.acnActivityStart),
      ]);
    } else {
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView.separated(
          key: const ValueKey('ac_activity_list'),
          padding: const EdgeInsets.all(Gap.lg),
          itemCount: rows.length,
          separatorBuilder: (context, index) => Divider(color: s.ds.border, height: Gap.lg),
          itemBuilder: (context, i) {
            final r = rows[i];
            final credits = _i(r['credits']);
            return Semantics(
              container: true,
              child: Row(
                  key: ValueKey('ac_activity_${_s(r['id'])}'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 92,
                      child: Text(_s(r['time']),
                          style: AType.bodyMedium.copyWith(color: s.ds.muted)),
                    ),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(_s(r['text']),
                            style: AType.bodyMedium.copyWith(color: s.ds.text, height: 1.4)),
                        if (credits > 0)
                          Text(t.acnCredits(acNum(context, credits)),
                              style: AType.bodyMedium.copyWith(color: s.ds.muted)),
                      ]),
                    ),
                  ]),
            );
          },
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(t.acnActivity)),
      body: SafeArea(child: body),
    );
  }
}
