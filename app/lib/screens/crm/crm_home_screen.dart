import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import 'crm_common.dart';
import 'crm_firstrun_screen.dart';
import 'crm_today_screen.dart';
import 'crm_leads_screen.dart';
import 'crm_pipeline_screen.dart';
import 'crm_dashboard_screen.dart';
import 'crm_companies_screen.dart';
import 'crm_reports_screen.dart';
import 'crm_team_screen.dart';
import 'crm_team_advanced_screen.dart';
import 'crm_aftersale_screen.dart';
import 'crm_automation_screen.dart';
import 'crm_capture_screen.dart';

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
  bool _loading = true;
  CrmError? _error;

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
      _error = null;
    });
    try {
      _orgs = await CrmApi.of(context).orgs();
      if (_orgs.isNotEmpty) {
        _org = (_orgs.first['id'] as num).toInt();
      } else {
        // No org/membership → first-run, NOT an error.
        _org = null;
      }
    } catch (e) {
      _error = CrmError.from(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);

    if (_loading) {
      return Scaffold(
          appBar: AppBar(title: Text(t.crmTitle)),
          body: const CrmStateView.loading());
    }
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: Text(t.crmTitle)),
        body: CrmStateView.error(
            error: _error!, title: t.loadFailed, onRetry: _load),
      );
    }
    if (_org == null) {
      // FIRST-RUN: friendly welcome with "Start your CRM" / "Join a team".
      return Scaffold(
        appBar: AppBar(title: Text(t.crmTitle)),
        body: CrmFirstRunScreen(onReady: _load),
      );
    }

    final org = _org!;
    final tabs = [
      (icon: Icons.today_outlined, label: t.crmTabToday, child: CrmTodayScreen(org: org)),
      (icon: Icons.people_alt_outlined, label: t.crmTabLeads, child: CrmLeadsScreen(org: org)),
      (icon: Icons.domain_outlined, label: t.crmTabCompanies, child: CrmCompaniesScreen(org: org)),
      (icon: Icons.view_kanban_outlined, label: t.crmTabPipeline, child: CrmPipelineScreen(org: org)),
      (icon: Icons.insights_outlined, label: t.crmTabDashboard, child: CrmDashboardScreen(org: org)),
      (icon: Icons.bar_chart_outlined, label: t.crmTabReports, child: CrmReportsScreen(org: org)),
      (icon: Icons.groups_outlined, label: t.crmTabTeam, child: CrmTeamScreen(org: org)),
      (icon: Icons.add_box_outlined, label: t.crmCapture, child: CrmCaptureScreen(org: org)),
      (icon: Icons.support_agent_outlined, label: t.crmAfterSale, child: CrmAfterSaleScreen(org: org)),
      (icon: Icons.leaderboard_outlined, label: t.crmTeamManage, child: CrmTeamAdvancedScreen(org: org)),
      (icon: Icons.bolt_outlined, label: t.crmAutomation, child: CrmAutomationScreen(org: org)),
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
            tabs: [for (final tb in tabs) Tab(icon: Icon(tb.icon, size: 20), child: Text(tb.label, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis))],
          ),
        ),
        body: TabBarView(children: [for (final tb in tabs) tb.child]),
      ),
    );
  }
}
