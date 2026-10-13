import 'package:flutter/material.dart';
import '../../theme.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/skeleton.dart';
import 'crm_common.dart';
import 'crm_today_screen.dart';
import 'crm_leads_screen.dart';
import 'crm_pipeline_screen.dart';
import 'crm_dashboard_screen.dart';
import 'crm_team_screen.dart';

/// Root of the in-app Sales CRM. Picks (or creates) a sales org, then shows the
/// CRM workspace: Today / Leads / Pipeline / Dashboard / Team as inner tabs.
class CrmHomeScreen extends StatefulWidget {
  /// Optional preselected org (used by the screenshot gallery).
  final int? previewOrg;
  const CrmHomeScreen({super.key, this.previewOrg});
  @override
  State<CrmHomeScreen> createState() => _CrmHomeScreenState();
}

class _CrmHomeScreenState extends State<CrmHomeScreen> {
  List<Map<String, dynamic>> _orgs = [];
  int? _org;
  bool _loading = true, _error = false;

  @override
  void initState() {
    super.initState();
    if (widget.previewOrg != null) {
      _org = widget.previewOrg;
      _loading = false;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      _orgs = await CrmApi.of(context).orgs();
      if (_orgs.isNotEmpty) _org = (_orgs.first['id'] as num).toInt();
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _createOrg(AppLocalizations t) async {
    final ctl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.crmNewOrg),
        content: TextField(
            controller: ctl,
            decoration: InputDecoration(labelText: t.crmOrgName),
            autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.create)),
        ],
      ),
    );
    if (ok == true && ctl.text.trim().isNotEmpty) {
      await CrmApi.of(context).createOrg(ctl.text.trim());
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    if (_loading) {
      return Scaffold(appBar: AppBar(title: Text(t.crmTitle)), body: const SkeletonList());
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text(t.crmTitle)),
        body: StateMessage(
            icon: Icons.cloud_off,
            tint: scheme.error,
            title: t.loadFailed,
            action: FilledButton.tonalIcon(
                onPressed: _load, icon: const Icon(Icons.refresh), label: Text(t.retry))),
      );
    }
    if (_org == null) {
      return Scaffold(
        appBar: AppBar(title: Text(t.crmTitle)),
        body: StateMessage(
          icon: Icons.hub_outlined,
          title: t.crmNoOrg,
          message: t.crmNoOrgHint,
          action: FilledButton.icon(
              onPressed: () => _createOrg(t),
              icon: const Icon(Icons.add),
              label: Text(t.crmNewOrg)),
        ),
      );
    }

    final org = _org!;
    final tabs = [
      (icon: Icons.today_outlined, label: t.crmTabToday, child: CrmTodayScreen(org: org)),
      (icon: Icons.people_alt_outlined, label: t.crmTabLeads, child: CrmLeadsScreen(org: org)),
      (icon: Icons.view_kanban_outlined, label: t.crmTabPipeline, child: CrmPipelineScreen(org: org)),
      (icon: Icons.insights_outlined, label: t.crmTabDashboard, child: CrmDashboardScreen(org: org)),
      (icon: Icons.groups_outlined, label: t.crmTabTeam, child: CrmTeamScreen(org: org)),
    ];

    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text(t.crmTitle),
          actions: [
            if (_orgs.length > 1)
              PopupMenuButton<int>(
                icon: const Icon(Icons.business_outlined),
                onSelected: (v) => setState(() => _org = v),
                itemBuilder: (_) => [
                  for (final o in _orgs)
                    PopupMenuItem(value: (o['id'] as num).toInt(), child: Text(o['name'] ?? '')),
                ],
              ),
          ],
          bottom: TabBar(
            isScrollable: true,
            tabs: [for (final tb in tabs) Tab(icon: Icon(tb.icon, size: 20), text: tb.label)],
          ),
        ),
        body: TabBarView(children: [for (final tb in tabs) tb.child]),
      ),
    );
  }
}
