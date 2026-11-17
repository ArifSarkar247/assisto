import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../theme.dart' show Gap, AType;
import '../../ds/ds.dart'; // gap-bizai
import '../../widgets/app_sheet.dart' show withNavBarInset; // gap-bizai
import 'crm_common.dart';
import 'crm_firstrun_screen.dart';
import 'crm_today_screen.dart';
import 'crm_leads_screen.dart';
import 'crm_contacts_tab.dart';
import '../../feature_flags.dart';
import 'crm_pipeline_screen.dart';
import 'crm_dashboard_screen.dart';
import 'crm_companies_screen.dart';
import 'crm_reports_screen.dart';
import 'crm_team_screen.dart';
import 'crm_team_advanced_screen.dart';
import 'crm_aftersale_screen.dart';
import 'crm_automation_screen.dart';
import 'crm_capture_screen.dart';
import 'customer_list_screen.dart'; // crm100

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
    // gap-bizai (owner card "CRM tabs simple"): 13 tabs in one row lost a
    // small shop owner. The four used every day stay as tabs; every other
    // tool is one tap away under "More" in the top bar — always on screen,
    // even on a narrow phone (nothing removed, nothing hidden).
    final more = <({IconData icon, String label, Widget child})>[
      // plans-v2: CRM contacts (Free can add these up to the owner's limit)
      if (FeatureFlags.instance.isOn('plans_v2'))
        (icon: Icons.contacts_rounded, label: t.pv2TabContacts, child: CrmContactsTab(org: org)),
      (icon: Icons.domain_rounded, label: t.crmTabCompanies, child: CrmCompaniesScreen(org: org)),
      (icon: Icons.insights_rounded, label: t.crmTabDashboard, child: CrmDashboardScreen(org: org)),
      (icon: Icons.bar_chart_rounded, label: t.crmTabReports, child: CrmReportsScreen(org: org)),
      (icon: Icons.groups_rounded, label: t.crmTabTeam, child: CrmTeamScreen(org: org)),
      (icon: Icons.add_box_rounded, label: t.crmCapture, child: CrmCaptureScreen(org: org)),
      (icon: Icons.support_agent_rounded, label: t.crmAfterSale, child: CrmAfterSaleScreen(org: org)),
      (icon: Icons.leaderboard_rounded, label: t.crmTeamManage, child: CrmTeamAdvancedScreen(org: org)),
      (icon: Icons.bolt_rounded, label: t.crmAutomation, child: CrmAutomationScreen(org: org)),
    ];
    final tabs = [
      (icon: Icons.today_rounded, label: t.crmTabToday, child: CrmTodayScreen(org: org)),
      // crm100: every customer once (khata + shop + orders + AI chats + leads)
      (icon: Icons.person_search_rounded, label: t.c100CustomersTab, child: const CustomerListScreen(embedded: true)),
      (icon: Icons.people_alt_rounded, label: t.crmTabLeads, child: CrmLeadsScreen(org: org)),
      (icon: Icons.view_kanban_rounded, label: t.crmTabPipeline, child: CrmPipelineScreen(org: org)),
    ];

    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        // banners-everywhere (owner 26 Oct): one bottom banner, Free only
        appBar: AppBar(
          title: Text(t.crmTitle),
          actions: [
            // gap-bizai: every other CRM tool, one tap away
            IconButton(
              key: const ValueKey('gbz-crm-more'),
              tooltip: t.gbzCrmMore,
              icon: const Icon(Icons.apps_rounded),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => Scaffold(
                      appBar: AppBar(title: Text(t.gbzCrmMore)), body: CrmMoreTab(items: more)))),
            ),
            if (_orgs.length > 1)
              PopupMenuButton<int>(
                icon: const Icon(Icons.business_rounded),
                onSelected: (v) => setState(() => _org = v),
                itemBuilder: (_) => [
                  for (final o in _orgs)
                    PopupMenuItem(value: (o['id'] as num).toInt(), child: Text(o['name'] ?? '')),
                ],
              ),
          ],
          // four tabs: still a scrolling row that starts at the screen edge,
          // so nothing is cut with "…" at 200 % font.
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
            tabs: [for (final tb in tabs) Tab(icon: Icon(tb.icon, size: 20), child: Text(tb.label, softWrap: false))],
          ),
        ),
        body: TabBarView(children: [for (final tb in tabs) tb.child]),
      ),
    );
  }
}


/// gap-bizai: the CRM tools that are not used every day, one tap each.
/// Each opens full screen with its own title and back arrow.
class CrmMoreTab extends StatelessWidget {
  final List<({IconData icon, String label, Widget child})> items;
  const CrmMoreTab({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final ds = DsTokens.of(context);
    return ListView(
      padding: withNavBarInset(context, const EdgeInsets.symmetric(vertical: Gap.md)),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
          child: Text(t.gbzCrmMoreSub, style: AType.bodyMedium.copyWith(color: ds.muted)),
        ),
        DsGroup(children: [
          for (final it in items)
            DsListRow(
              key: ValueKey('gbz-crm-more-${it.icon.codePoint}'),
              title: it.label,
              leading: DsAvatar(child: Icon(it.icon, size: 22, color: ds.primaryInk)),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => Scaffold(appBar: AppBar(title: Text(it.label)), body: it.child))),
            ),
        ]),
      ],
    );
  }
}
