import 'package:flutter/material.dart';
import '../../theme.dart';
import '../../l10n/app_localizations.dart';
import 'crm_common.dart';
import 'crm_advanced_api.dart';
import '../../widgets/crm_target_editor.dart';
import '../../widgets/crm_commission_config.dart';
import '../../widgets/crm_leaderboard_list.dart';
import '../../widgets/crm_routing_editor.dart';

/// ADVANCED TEAM management (CRM spec #8): monthly TARGETS, activity
/// LEADERBOARD, OWNER-REVIEW COMMISSION config, and routing (territory /
/// industry + round-robin) configuration. Benchmarked against B2B CRM team
/// management (HubSpot/Zoho/Salesforce): quota tracking, rep leaderboard,
/// commission plans, and assignment/territory rules.
///
/// Commission %/tiers and target amounts are NEVER hard-coded — they are owner
/// inputs. With none set the UI shows a clearly-labelled "owner must set" state.
class CrmTeamAdvancedScreen extends StatelessWidget {
  final int org;
  const CrmTeamAdvancedScreen({super.key, required this.org});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text(t.crmTeamManage),
          bottom: TabBar(isScrollable: true, tabs: [
            Tab(text: t.crmTargets),
            Tab(text: t.crmLeaderboard),
            Tab(text: t.crmCommission),
            Tab(text: t.crmRoutingConfig),
          ]),
        ),
        body: TabBarView(children: [
          _TargetsTab(org: org),
          _LeaderboardTab(org: org),
          _CommissionTab(org: org),
          _RoutingTab(org: org),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- TARGETS
class _TargetsTab extends StatefulWidget {
  final int org;
  const _TargetsTab({required this.org});
  @override
  State<_TargetsTab> createState() => _TargetsTabState();
}

class _TargetsTabState extends State<_TargetsTab> {
  List<Map<String, dynamic>> _targets = [];
  List<Map<String, dynamic>> _members = [];
  bool _loading = true;
  CrmError? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = CrmAdvApi.of(context);
      _members = await api.members(widget.org);
      _targets = await api.targets(widget.org);
    } catch (e) {
      _error = CrmError.from(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _edit(Map<String, dynamic>? existing) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => CrmTargetEditor(
          org: widget.org, members: _members, existing: existing),
    );
    if (saved == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_loading) return const CrmStateView.loading();
    if (_error != null) {
      return CrmStateView.error(error: _error!, title: t.loadFailed, onRetry: _load);
    }
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(null),
        icon: const Icon(Icons.add),
        label: Text(t.crmSetTarget),
      ),
      body: _targets.isEmpty
          ? CrmStateView.empty(
              icon: Icons.flag_outlined,
              title: t.crmNoTargets,
              message: t.crmNoTargetsHint,
              action: FilledButton.tonalIcon(
                  onPressed: () => _edit(null),
                  icon: const Icon(Icons.add),
                  label: Text(t.crmSetTarget)))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(Gap.md),
                children: [for (final tg in _targets) _targetCard(t, tg)],
              ),
            ),
    );
  }

  Widget _targetCard(AppLocalizations t, Map<String, dynamic> tg) {
    final scheme = Theme.of(context).colorScheme;
    final set = tg['target_set'] == true;
    final pct = (tg['pct'] as num?)?.toDouble();
    final onPace = tg['on_pace'];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text(tg['member_name']?.toString() ?? t.crmWholeTeam,
                    style: const TextStyle(fontWeight: FontWeight.w800))),
            Text(tg['period']?.toString() ?? '',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
            IconButton(
                icon: const Icon(Icons.edit_outlined, size: 18),
                onPressed: () => _edit(tg)),
          ]),
          if (!set)
            NeedsKeyBanner(t.crmOwnerMustSetTarget,
                icon: Icons.flag_outlined)
          else ...[
            const SizedBox(height: Gap.xs),
            Row(children: [
              Text('${bdt(tg['won_amount'] as num?)} / ${bdt(tg['target_amount'] as num?)}',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const Spacer(),
              if (pct != null)
                Text('${pct.toStringAsFixed(1)}%',
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: pct >= 100 ? Brand.success : scheme.onSurface)),
            ]),
            const SizedBox(height: Gap.xs),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: ((pct ?? 0) / 100).clamp(0.0, 1.0),
                minHeight: 8,
                color: (pct ?? 0) >= 100 ? Brand.success : scheme.primary,
              ),
            ),
            if (onPace != null) ...[
              const SizedBox(height: Gap.xs),
              Row(children: [
                Icon(onPace == true ? Icons.trending_up : Icons.trending_down,
                    size: 16,
                    color: onPace == true ? Brand.success : Brand.warning),
                const SizedBox(width: 4),
                Text(onPace == true ? t.crmOnPace : t.crmBehindPace,
                    style: TextStyle(
                        fontSize: 12,
                        color: onPace == true ? Brand.success : Brand.warning)),
              ]),
            ],
          ],
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------ LEADERBOARD
class _LeaderboardTab extends StatefulWidget {
  final int org;
  const _LeaderboardTab({required this.org});
  @override
  State<_LeaderboardTab> createState() => _LeaderboardTabState();
}

class _LeaderboardTabState extends State<_LeaderboardTab> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  CrmError? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await CrmAdvApi.of(context).leaderboard(widget.org);
      _rows = ((r['rows'] as List?) ?? []).cast<Map<String, dynamic>>();
    } catch (e) {
      _error = CrmError.from(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_loading) return const CrmStateView.loading();
    if (_error != null) {
      return CrmStateView.error(error: _error!, title: t.loadFailed, onRetry: _load);
    }
    if (_rows.isEmpty) {
      return CrmStateView.empty(
          icon: Icons.emoji_events_outlined,
          title: t.crmNoLeaderboard,
          message: t.crmNoLeaderboardHint);
    }
    return RefreshIndicator(
        onRefresh: _load, child: CrmLeaderboardList(rows: _rows));
  }
}

// ------------------------------------------------------------- COMMISSION
class _CommissionTab extends StatefulWidget {
  final int org;
  const _CommissionTab({required this.org});
  @override
  State<_CommissionTab> createState() => _CommissionTabState();
}

class _CommissionTabState extends State<_CommissionTab> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  CrmError? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _data = await CrmAdvApi.of(context).commissionConfig(widget.org);
    } catch (e) {
      _error = CrmError.from(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_loading) return const CrmStateView.loading();
    if (_error != null) {
      return CrmStateView.error(error: _error!, title: t.loadFailed, onRetry: _load);
    }
    return CrmCommissionConfig(
        org: widget.org, data: _data ?? const {}, onSaved: _load);
  }
}

// ---------------------------------------------------------------- ROUTING
class _RoutingTab extends StatefulWidget {
  final int org;
  const _RoutingTab({required this.org});
  @override
  State<_RoutingTab> createState() => _RoutingTabState();
}

class _RoutingTabState extends State<_RoutingTab> {
  List<Map<String, dynamic>> _rules = [];
  List<Map<String, dynamic>> _members = [];
  List<Map<String, dynamic>> _territories = [];
  bool _loading = true;
  CrmError? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = CrmAdvApi.of(context);
      _members = await api.members(widget.org);
      _rules = await api.routingRules(widget.org);
      try {
        _territories = await api.territories(widget.org);
      } catch (_) {
        _territories = [];
      }
    } catch (e) {
      _error = CrmError.from(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_loading) return const CrmStateView.loading();
    if (_error != null) {
      return CrmStateView.error(error: _error!, title: t.loadFailed, onRetry: _load);
    }
    return CrmRoutingEditor(
      org: widget.org,
      rules: _rules,
      members: _members,
      territories: _territories,
      onChanged: _load,
    );
  }
}
