import 'package:flutter/material.dart';
import '../../ds/ds.dart';
import '../../theme.dart';
import '../../messaging/date_separators.dart' show localDigits;
import '../../l10n/app_localizations.dart';
import 'crm_common.dart';
import 'crm_advanced_api.dart';
import '../../widgets/crm_target_editor.dart';
import '../../widgets/crm_commission_config.dart';
import '../../widgets/crm_leaderboard_list.dart';
import '../../widgets/crm_routing_editor.dart';
import 'package:assisto/widgets/app_sheet.dart';

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
          // scrollable tabs size to their label: nothing cut at any font size
          bottom: TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [
            Tab(child: Text(t.crmTargets, softWrap: false)),
            Tab(child: Text(t.crmLeaderboard, softWrap: false)),
            Tab(child: Text(t.crmCommission, softWrap: false)),
            Tab(child: Text(t.crmRoutingConfig, softWrap: false)),
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
    final saved = await showAppSheet<bool>(
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
      // empty: the state's own big button is the one action (no second FAB)
      floatingActionButton: _targets.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _edit(null),
              icon: const Icon(Icons.add_rounded),
              label: Text(t.crmSetTarget),
            ),
      body: _targets.isEmpty
          ? CrmStateView.empty(
              icon: Icons.flag_rounded,
              title: t.crmNoTargets,
              message: t.crmNoTargetsHint,
              action: DsButton(
                  onPressed: () => _edit(null),
                  icon: Icons.add_rounded,
                  label: t.crmSetTarget,
                  expand: true))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
                children: [
                  for (final tg in _targets)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Gap.sm),
                      child: _targetCard(t, tg),
                    ),
                ],
              ),
            ),
    );
  }

  Widget _targetCard(AppLocalizations t, Map<String, dynamic> tg) {
    final scheme = Theme.of(context).colorScheme;
    final set = tg['target_set'] == true;
    final pct = (tg['pct'] as num?)?.toDouble();
    final onPace = tg['on_pace'];
    return DsCard(
      padding: const EdgeInsets.all(Gap.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            DsAvatar(name: tg['member_name']?.toString() ?? t.crmWholeTeam, size: 40),
            const SizedBox(width: Gap.md),
            Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tg['member_name']?.toString() ?? t.crmWholeTeam,
                  style: AType.bodyLarge.copyWith(color: scheme.ds.text, fontWeight: FontWeight.w800)),
              if ((tg['period'] ?? '').toString().isNotEmpty)
                Text(localDigits(tg['period'].toString(), Localizations.localeOf(context).languageCode),
                    style: AType.bodySmall.copyWith(color: scheme.ds.muted)),
            ])),
            IconButton(
                tooltip: AppLocalizations.of(context).edit,
                icon: const Icon(Icons.edit_rounded, size: 18),
                onPressed: () => _edit(tg)),
          ]),
          if (!set)
            NeedsKeyBanner(t.crmOwnerMustSetTarget,
                icon: Icons.flag_rounded)
          else ...[
            const SizedBox(height: Gap.xs),
            // won / target + percent: big tight numbers on a Wrap (no
            // overflow at 200%), Bangla digits in bn
            Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.end,
                spacing: Gap.md,
                runSpacing: Gap.xs,
                children: [
              Text('${bdt(context, tg['won_amount'] as num?)} / ${bdt(context, tg['target_amount'] as num?)}',
                  style: AType.titleMedium.copyWith(
                      color: scheme.ds.text, fontWeight: FontWeight.w800, fontFeatures: AFonts.tabular)),
              if (pct != null)
                Text(localDigits('${pct.toStringAsFixed(1)}%', Localizations.localeOf(context).languageCode),
                    style: AType.titleMedium.copyWith(
                        fontWeight: FontWeight.w800,
                        color: pct >= 100 ? scheme.ds.successInk : scheme.ds.primaryInk)),
            ]),
            const SizedBox(height: Gap.xs),
            ClipRRect(
              borderRadius: BorderRadius.circular(Radii.pill),
              child: LinearProgressIndicator(
                value: ((pct ?? 0) / 100).clamp(0.0, 1.0),
                minHeight: 8,
                backgroundColor: scheme.ds.cardHighest,
                color: (pct ?? 0) >= 100 ? scheme.ds.success : scheme.ds.primary,
              ),
            ),
            if (onPace != null) ...[
              const SizedBox(height: Gap.xs),
              Row(children: [
                Icon(onPace == true ? Icons.trending_up_rounded : Icons.trending_down_rounded,
                    size: 16,
                    color: onPace == true ? AssistoTokens.of(context).success : AssistoTokens.of(context).warning),
                const SizedBox(width: Gap.xs),
                Expanded(
                  child: Text(onPace == true ? t.crmOnPace : t.crmBehindPace,
                      style: AType.bodySmall.copyWith(
                          fontWeight: FontWeight.w600,
                          color: onPace == true
                              ? scheme.ds.successInk
                              : Brand.onTint(context, AssistoTokens.of(context).warning))),
                ),
              ]),
            ],
          ],
        ]),
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
          icon: Icons.emoji_events_rounded,
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
