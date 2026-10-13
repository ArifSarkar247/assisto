import 'package:flutter/material.dart';
import '../../theme.dart';
import '../../l10n/app_localizations.dart';
import 'crm_common.dart';
import 'crm_lead_detail_screen.dart';

/// Today screen (CRM_SPEC): follow-ups due/overdue, new high-score (90+) leads,
/// stuck deals, suggested drafts. All from real data.
class CrmTodayScreen extends StatefulWidget {
  final int org;
  const CrmTodayScreen({super.key, required this.org});
  @override
  State<CrmTodayScreen> createState() => _CrmTodayScreenState();
}

class _CrmTodayScreenState extends State<CrmTodayScreen> {
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
      _data = await CrmApi.of(context).today(widget.org);
    } catch (e) {
      _error = CrmError.from(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) return const CrmStateView.loading();
    if (_error != null) {
      return CrmStateView.error(error: _error!, title: t.loadFailed, onRetry: _load);
    }
    final d = _data ?? {};
    final high = (d['high_score_leads'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final fu = (d['lead_followups'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final overdue = (d['overdue_next_steps'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final stuck = (d['stuck_deals'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final missing = (d['missing_next_step'] as List?)?.cast<Map<String, dynamic>>() ?? [];

    final empty = high.isEmpty && fu.isEmpty && overdue.isEmpty && stuck.isEmpty && missing.isEmpty;
    if (empty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(children: [
          const SizedBox(height: 80),
          CrmStateView.empty(
              icon: Icons.wb_sunny_outlined,
              title: t.crmTodayClear,
              message: t.crmTodayClearHint),
        ]),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(Gap.md), children: [
        if (high.isNotEmpty) ...[
          _header(t.crmTodayHotLeads, Icons.local_fire_department_outlined, Brand.danger),
          for (final l in high)
            Card(
              child: ListTile(
                leading: ScoreBadge((l['score'] as num).toInt()),
                title: Text(l['name']?.toString().isNotEmpty == true
                    ? l['name']
                    : (l['company'] ?? t.crmLead)),
                subtitle: Text([l['company'], l['industry_display']]
                    .where((e) => (e ?? '').toString().isNotEmpty)
                    .join(' · ')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openLead((l['id'] as num).toInt()),
              ),
            ),
        ],
        if (fu.isNotEmpty) ...[
          _header(t.crmTodayFollowups, Icons.event_outlined, Brand.warning),
          for (final l in fu)
            Card(
              child: ListTile(
                leading: const Icon(Icons.schedule),
                title: Text(l['name']?.toString().isNotEmpty == true
                    ? l['name']
                    : (l['company'] ?? t.crmLead)),
                subtitle: Text('${t.crmNextFollowUp}: ${l['next_follow_up'] ?? '—'}'),
                onTap: () => _openLead((l['id'] as num).toInt()),
              ),
            ),
        ],
        if (overdue.isNotEmpty) ...[
          _header(t.crmTodayOverdueSteps, Icons.warning_amber_outlined, Brand.danger),
          for (final s in overdue)
            Card(
              child: ListTile(
                leading: const Icon(Icons.flag_outlined),
                title: Text(s['title'] ?? ''),
                subtitle: Text('${s['next_step']} · ${t.crmDue}: ${s['due']}'),
              ),
            ),
        ],
        if (missing.isNotEmpty) ...[
          _header(t.crmTodayMissingStep, Icons.help_outline, scheme.onSurfaceVariant),
          for (final s in missing)
            Card(child: ListTile(leading: const Icon(Icons.remove_circle_outline), title: Text(s['title'] ?? ''), subtitle: Text(t.crmNoNextStep))),
        ],
        if (stuck.isNotEmpty) ...[
          _header(t.crmTodayStuck, Icons.hourglass_bottom_outlined, Brand.warning),
          for (final s in stuck)
            Card(
              child: ListTile(
                leading: const Icon(Icons.timelapse),
                title: Text(s['title'] ?? ''),
                subtitle: Text('${s['stage']} · ${s['days']} ${t.crmDaysStuck}'),
              ),
            ),
        ],
      ]),
    );
  }

  void _openLead(int id) => Navigator.push(context,
      MaterialPageRoute(builder: (_) => CrmLeadDetailScreen(org: widget.org, leadId: id)));

  Widget _header(String text, IconData icon, Color tint) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.md, Gap.xs, Gap.sm),
        child: Row(children: [
          Icon(icon, size: 18, color: tint),
          const SizedBox(width: Gap.sm),
          Text(text, style: const TextStyle(fontWeight: FontWeight.w800)),
        ]),
      );
}
