import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import '../../ds/ds.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/offline_banner.dart';
import '../../widgets/voice_input.dart';
import 'agent_approvals_screen.dart';
import 'agent_core_push.dart';
import 'agent_core_source.dart';
import 'agent_core_widgets.dart';
import 'agent_history_screen.dart';
import 'agent_nudges.dart'; // agentcore
import 'agent_run_panel.dart';
import 'biz_brief_screen.dart';
import '../../feature_flags.dart';
import '../../widgets/local_counter.dart';

/// agent-core WP-APP: the hidden Assisto Agent screen (flag `agent_core`,
/// default OFF — reachable only through the flag-gated ChatNav route /
/// sidebar item, i.e. owner / staff / allow-listed testers while OFF).
///
/// Flow: type or say a goal -> "See the cost" shows the credit estimate from
/// the server BEFORE anything runs (owner rule) -> "Run · about N credits"
/// -> the live run (AcRunPanel). Honest states: offline = not started (sent
/// when back online while this page is open), daily cap, AI not set up, out
/// of credits (billing sheet), feature off.
enum AcPhase { compose, confirm, sending, offline, run }

class AgentCoreScreen extends StatefulWidget {
  final AgentCoreSource? source;

  /// agentcore: the proactive cards + activity (null in tests = from AppState).
  final AgentNudgeSource? nudgeSource;

  /// Tests / gallery: start in a given state.
  final AcPhase? debugPhase;
  final String? debugGoal;
  final AcRun? debugRun;
  final List<Duration> pollSchedule;
  const AgentCoreScreen(
      {super.key,
      this.source,
      this.nudgeSource,
      this.debugPhase,
      this.debugGoal,
      this.debugRun,
      this.pollSchedule = AcRunPanel.defaultSchedule});

  @override
  State<AgentCoreScreen> createState() => _AgentCoreScreenState();
}

class _AgentCoreScreenState extends State<AgentCoreScreen> {
  late final AgentCoreSource _src = widget.source ??
      ApiAgentCoreSource(Provider.of<AppState>(context, listen: false).api);
  late final AppState? _app = _maybeApp();
  // agentcore: "For you" cards + "What the agent did" (null = not available)
  late final AgentNudgeSource? _nudgeSrc =
      widget.nudgeSource ?? (widget.source != null ? null : _apiNudges());
  final _nudgesKey = GlobalKey<AgentNudgesSectionState>();
  final _input = TextEditingController();
  late final VoiceDictation _voice = VoiceDictation();
  AcTools? _tools;
  bool _toolsFailed = false;
  bool _featureOff = false;
  AcPhase _phase = AcPhase.compose;
  String _goal = '';
  String _clientId = '';
  AcRun? _run;
  String? _sendError;
  int _approvals = 0;

  AppState? _maybeApp() {
    try {
      return Provider.of<AppState>(context, listen: false);
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    _phase = widget.debugPhase ?? AcPhase.compose;
    _goal = widget.debugGoal ?? '';
    _input.text = _goal;
    _run = widget.debugRun;
    _app?.addListener(_onApp);
    AgentCorePush.approvalsChanged.addListener(_loadApprovals);
    _loadTools();
    _loadApprovals();
  }

  @override
  void dispose() {
    _app?.removeListener(_onApp);
    AgentCorePush.approvalsChanged.removeListener(_loadApprovals);
    _voice.dispose();
    _input.dispose();
    super.dispose();
  }

  bool get _online => _app?.online ?? true;

  void _onApp() {
    // offline goal: send it (same client_id = never twice) once back online
    if (_phase == AcPhase.offline && _online && mounted) _send();
  }

  bool _isFeatureOff(Object e) =>
      e is ApiException && e.status == 403 && e.body?['error'] == 'feature_off';

  Future<void> _loadTools() async {
    try {
      final j = await _src.tools();
      if (mounted) setState(() => _tools = AcTools.fromJson(j));
    } catch (e) {
      if (mounted) {
        setState(() {
          _featureOff = _isFeatureOff(e);
          _toolsFailed = true;
        });
      }
    }
  }

  AgentNudgeSource? _apiNudges() {
    final app = _app;
    return app == null ? null : ApiAgentNudgeSource(app.api);
  }

  void _openActivity() {
    final src = _nudgeSrc;
    if (src == null) return;
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => AgentActivityScreen(source: src)));
  }

  Future<void> _loadApprovals() async {
    _nudgesKey.currentState?.reload(); // agentcore: a decision elsewhere updates the cards
    try {
      final j = await _src.approvals();
      final n = (j['approvals'] as List? ?? const []).length;
      if (mounted) setState(() => _approvals = n);
    } catch (_) {} // best-effort: badge count only; the inbox shows real errors
  }

  void _toConfirm() {
    final g = _input.text.trim();
    if (g.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _goal = g;
      _sendError = null;
      _phase = AcPhase.confirm;
    });
    if (_tools == null) _loadTools(); // fresh estimate
  }

  void _confirmRun() {
    _clientId =
        'ac-${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 30)}';
    _send();
  }

  Future<void> _send() async {
    if (!_online) {
      setState(() => _phase = AcPhase.offline);
      return;
    }
    setState(() {
      _phase = AcPhase.sending;
      _sendError = null;
    });
    try {
      final j = await _src.startGoal(_goal, clientId: _clientId);
      if (!mounted) return;
      setState(() {
        _run = AcRun.fromJson(j);
        _phase = AcPhase.run;
      });
      _loadApprovals();
    } on ApiException catch (e) {
      if (!mounted) return;
      final t = AppLocalizations.of(context);
      setState(() {
        _featureOff = _isFeatureOff(e);
        _phase = AcPhase.confirm;
        _sendError = e.body?['error'] == 'daily_cap'
            ? (e.message.isNotEmpty ? e.message : t.acDailyCap)
            : (e.message.isNotEmpty ? e.message : t.acErrorLoad);
      });
    } catch (_) {
      // no answer from the server: NOT started (never fake progress)
      if (mounted) setState(() => _phase = AcPhase.offline);
    }
  }

  void _newTask() {
    setState(() {
      _phase = AcPhase.compose;
      _run = null;
      _goal = '';
      _input.clear();
      _sendError = null;
    });
    _loadTools();
  }

  void _retryGoal(String goal) {
    setState(() {
      _goal = goal;
      _input.text = goal;
      _run = null;
      _phase = AcPhase.confirm;
    });
    _loadTools();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.acTitle),
        actions: [
          IconButton(
            key: const ValueKey('ac_open_approvals'),
            tooltip: _approvals > 0
                ? t.acApprovalsWaiting(acNum(context, _approvals))
                : t.acApprovals,
            onPressed: _openApprovals,
            icon: Badge(
              isLabelVisible: _approvals > 0,
              label: Text(acNum(context, _approvals)),
              child: const Icon(Icons.fact_check_outlined),
            ),
          ),
          if (_nudgeSrc != null)
            IconButton(
              key: const ValueKey('ac_open_activity'),
              tooltip: t.acnActivity,
              onPressed: _openActivity,
              icon: const Icon(Icons.receipt_long_rounded),
            ),
          IconButton(
            key: const ValueKey('ac_open_history'),
            tooltip: t.acHistory,
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => AgentHistoryScreen(source: _src, tools: _tools))),
            icon: const Icon(Icons.history_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: _featureOff
            ? Center(
                child: AcMessage(
                    key: const ValueKey('ac_feature_off'),
                    icon: Icons.lock_outline_rounded,
                    body: t.acFeatureOff))
            : ListView(
                padding: const EdgeInsets.all(Gap.lg),
                children: [
                  const OfflineBanner(),
                  if (_approvals > 0)
                    DsCard(tone: DsTone.success,
                      padding: EdgeInsets.zero,
                      child: ListTile(
                        key: const ValueKey('ac_approvals_banner'),
                        minVerticalPadding: Gap.md,
                        leading: Icon(Icons.front_hand_rounded,
                            color: Theme.of(context).colorScheme.ds.successInk),
                        title: Text(t.acApprovalsWaiting(acNum(context, _approvals)),
                            style: AType.bodyMedium.copyWith(
                                color: Theme.of(context).colorScheme.ds.successInk,
                                fontWeight: FontWeight.w600)),
                        trailing: Icon(Icons.chevron_right_rounded,
                            color: Theme.of(context).colorScheme.ds.successInk),
                        onTap: _openApprovals,
                      ),
                    ),
                  ..._body(context),
                ],
              ),
      ),
    );
  }

  Future<void> _openApprovals() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => AgentApprovalsScreen(source: _src)));
    _loadApprovals();
    if (_run != null && _run!.isOpen) {
      try {
        final j = await _src.run(_run!.id);
        if (mounted) setState(() => _run = AcRun.fromJson(j));
      } catch (_) {} // best-effort: refresh; the run panel keeps polling
    }
  }

  List<Widget> _body(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final nudges = _nudgeSrc;
    switch (_phase) {
      case AcPhase.compose:
        return [
          if (nudges != null)
            AgentNudgesSection(key: _nudgesKey, source: nudges, onOpenActivity: _openActivity),
          Text(t.acIntro, style: AType.bodyMedium.copyWith(color: s.ds.muted, height: 1.4)),
          const SizedBox(height: Gap.lg),
          // bizops: the shop owner's morning card (flag business; hidden when off)
          if (FeatureFlags.instance.isOn('business')) ...[
            DsSurface(color: s.ds.primarySoft,
              padding: EdgeInsets.zero,
              child: ListTile(
                key: const ValueKey('ac_open_biz_brief'),
                minVerticalPadding: Gap.md,
                leading: Icon(Icons.storefront_rounded, color: s.ds.primaryInk),
                title: Text(t.boEntry,
                    style: AType.bodyMedium.copyWith(
                        color: s.ds.primaryInk, fontWeight: FontWeight.w600)),
                subtitle: Text(t.boEntryBody, style: AType.bodyMedium.copyWith(color: s.ds.primaryInk)),
                trailing: Icon(Icons.chevron_right_rounded, color: s.ds.primaryInk),
                onTap: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => const BizBriefScreen())),
              ),
            ),
            const SizedBox(height: Gap.lg),
          ],
          TextField(
            key: const ValueKey('ac_goal_input'),
            controller: _input,
            minLines: 2,
            maxLines: 6,
            maxLength: 1000,
            buildCounter: localCounter,
            textInputAction: TextInputAction.newline,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: t.acGoalLabel,
              hintText: t.acGoalHint,
              suffixIcon: VoiceMicButton(voice: _voice, input: _input),
            ),
          ),
          const SizedBox(height: Gap.md),
          DsButton(buttonKey: const ValueKey('ac_check_cost'), onPressed: _input.text.trim().isEmpty ? null : _toConfirm, icon: Icons.toll_rounded, label: t.acCheckCost),
        ];
      case AcPhase.confirm:
        return [_goalCard(context), const SizedBox(height: Gap.md), _estimate(context)];
      case AcPhase.sending:
        return [
          _goalCard(context),
          const SizedBox(height: Gap.xl),
          Semantics(
            liveRegion: true,
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              const SizedBox(
                  width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: Gap.md),
              Flexible(child: Text(t.acSending, key: const ValueKey('ac_sending'))),
            ]),
          ),
        ];
      case AcPhase.offline:
        return [
          _goalCard(context),
          const SizedBox(height: Gap.md),
          Container(
            key: const ValueKey('ac_offline_queued'),
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(
                color: s.ds.successBg, borderRadius: BorderRadius.circular(Radii.md)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.cloud_off_rounded, color: s.ds.successInk),
              const SizedBox(width: Gap.sm),
              Expanded(
                  child: Text(t.acOfflineQueued,
                      style: AType.bodyMedium.copyWith(color: s.ds.successInk, height: 1.4))),
            ]),
          ),
          const SizedBox(height: Gap.md),
          Wrap(alignment: WrapAlignment.end, spacing: Gap.sm, runSpacing: Gap.sm, children: [
            DsButton.secondary(onPressed: _newTask, label: t.acDiscard),
            FilledButton(
                key: const ValueKey('ac_send_now'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: _send,
                child: Text(t.acSendNow)),
          ]),
        ];
      case AcPhase.run:
        final r = _run;
        return [
          if (r != null)
            AcRunPanel(
              key: ValueKey('ac_run_${r.id}'),
              source: _src,
              run: r,
              tools: _tools,
              pollSchedule: widget.pollSchedule,
              onChanged: (x) {
                _run = x;
                if (!x.isOpen) _loadApprovals();
              },
              onRetryGoal: _retryGoal,
            ),
          const SizedBox(height: Gap.lg),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const ValueKey('ac_new_task'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _newTask,
              icon: const Icon(Icons.add_rounded),
              label: Text(t.acNewTask),
            ),
          ),
        ];
    }
  }

  Widget _goalCard(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
          color: s.ds.cardHighest, borderRadius: BorderRadius.circular(Radii.md)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.flag_outlined, color: s.ds.muted),
        const SizedBox(width: Gap.sm),
        Expanded(
            child: Text(_goal,
                style: AType.bodyMedium.copyWith(color: s.ds.text, fontWeight: FontWeight.w600))),
      ]),
    );
  }

  Widget _estimate(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final tools = _tools;
    if (tools == null) {
      if (_toolsFailed) {
        return AcMessage(
            icon: Icons.cloud_off_rounded,
            body: t.acErrorLoad,
            action: t.acRetry,
            onAction: () {
              setState(() => _toolsFailed = false);
              _loadTools();
            });
      }
      return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: Gap.md),
        Flexible(child: Text(t.acCheckingCost)),
      ]);
    }
    final e = tools.estimate;
    final capped = e.runsLeftToday <= 0;
    return Card(
      key: const ValueKey('ac_estimate'),
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.lg),
          side: BorderSide(color: s.ds.border)),
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Semantics(
              header: true,
              child: Text(t.acEstimateTitle, style: Theme.of(context).textTheme.titleMedium)),
          const SizedBox(height: Gap.sm),
          _line(context, Icons.toll_rounded, t.acEstimateTypical(acNum(context, e.typicalCredits))),
          _line(context, Icons.shield_outlined, t.acEstimateMax(acNum(context, e.maxCredits))),
          _line(context, Icons.front_hand_outlined, t.acEstimateApprovalNote),
          _line(
              context,
              Icons.today_rounded,
              capped
                  ? t.acDailyCap
                  : t.acEstimateRunsLeft(acNum(context, e.runsLeftToday)),
              danger: capped),
          if (_sendError != null) ...[
            const SizedBox(height: Gap.sm),
            Text(_sendError!,
                key: const ValueKey('ac_send_error'), style: AType.bodyMedium.copyWith(color: s.error)),
          ],
          const SizedBox(height: Gap.lg),
          Wrap(alignment: WrapAlignment.end, spacing: Gap.sm, runSpacing: Gap.sm, children: [
            DsButton.secondary(buttonKey: const ValueKey('ac_edit'), onPressed: () => setState(() => _phase = AcPhase.compose), label: t.acEdit),
            DsButton(buttonKey: const ValueKey('ac_run'), onPressed: capped ? null : _confirmRun, icon: Icons.play_arrow_rounded, label: t.acRunConfirm(acNum(context, e.typicalCredits))),
          ]),
        ]),
      ),
    );
  }

  Widget _line(BuildContext context, IconData icon, String text, {bool danger = false}) {
    final s = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 20, color: danger ? s.error : s.ds.muted),
        const SizedBox(width: Gap.sm),
        Expanded(child: Text(text, style: AType.bodyMedium.copyWith(color: danger ? s.error : null, height: 1.35))),
      ]),
    );
  }
}
