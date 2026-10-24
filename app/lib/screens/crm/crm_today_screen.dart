import 'package:flutter/material.dart';
import '../../theme.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/ladder_common.dart';
import 'crm_common.dart';
import 'crm_lead_detail_screen.dart';
import 'crm_log_activity_sheet.dart';

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
          _header(t.crmTodayHotLeads, Icons.local_fire_department_outlined, Theme.of(context).colorScheme.error),
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
                trailing: _inlineActions(t, l),
                onTap: () => _openLead((l['id'] as num).toInt()),
              ),
            ),
        ],
        if (fu.isNotEmpty) ...[
          _header(t.crmTodayFollowups, Icons.event_outlined, AssistoTokens.of(context).warning),
          for (final l in fu)
            Card(
              child: ListTile(
                leading: const Icon(Icons.schedule),
                title: Text(l['name']?.toString().isNotEmpty == true
                    ? l['name']
                    : (l['company'] ?? t.crmLead)),
                subtitle: Text('${t.crmNextFollowUp}: ${_date(l['next_follow_up'])}'),
                trailing: _inlineActions(t, l),
                onTap: () => _openLead((l['id'] as num).toInt()),
              ),
            ),
        ],
        if (overdue.isNotEmpty) ...[
          _header(t.crmTodayOverdueSteps, Icons.warning_amber_outlined, Theme.of(context).colorScheme.error),
          for (final s in overdue)
            Card(
              child: ListTile(
                leading: const Icon(Icons.flag_outlined),
                title: Text(s['title'] ?? ''),
                subtitle: Text('${s['next_step']} · ${t.crmDue}: ${_date(s['due'])}'),
                trailing: _rescheduleAction(t, s),
                onTap: _leadIdOf(s) != null ? () => _openLead(_leadIdOf(s)!) : null,
              ),
            ),
        ],
        if (missing.isNotEmpty) ...[
          _header(t.crmTodayMissingStep, Icons.help_outline, scheme.onSurfaceVariant),
          for (final s in missing)
            Card(
              child: ListTile(
                leading: const Icon(Icons.remove_circle_outline),
                title: Text(s['title'] ?? ''),
                subtitle: Text(t.crmNoNextStep),
                trailing: _rescheduleAction(t, s),
                onTap: _leadIdOf(s) != null ? () => _openLead(_leadIdOf(s)!) : null,
              ),
            ),
        ],
        if (stuck.isNotEmpty) ...[
          _header(t.crmTodayStuck, Icons.hourglass_bottom_outlined, AssistoTokens.of(context).warning),
          for (final s in stuck)
            Card(
              child: ListTile(
                leading: const Icon(Icons.timelapse),
                title: Text(s['title'] ?? ''),
                subtitle: Text('${s['stage']} · ${fmtInt(context, (s['days'] as num?)?.toInt() ?? 0)} ${t.crmDaysStuck}'),
                trailing: _rescheduleAction(t, s),
                onTap: _leadIdOf(s) != null ? () => _openLead(_leadIdOf(s)!) : null,
              ),
            ),
        ],
      ]),
    );
  }

  /// Localised yyyy-MM-dd (Bangla numerals in bn). Falls back to a dash / the
  /// raw value when the string is empty or not a parseable date.
  String _date(dynamic v) {
    return crmDate(context, v);
  }

  void _openLead(int id) => Navigator.push(context,
      MaterialPageRoute(builder: (_) => CrmLeadDetailScreen(org: widget.org, leadId: id)))
      .then((_) => _load());

  /// A lead id from a row if present (`id` on lead rows, `lead_id`/`lead` on
  /// deal-engine rows). Returns null when the row can't resolve to a lead — then
  /// the row stays non-tappable and shows no reschedule button.
  int? _leadIdOf(Map<String, dynamic> row) {
    final v = row['id'] ?? row['lead_id'] ?? row['lead'];
    return v is num ? v.toInt() : null;
  }

  /// First usable phone for inline dialling (`phone` then `whatsapp`).
  String _phoneOf(Map<String, dynamic> l) {
    final p = (l['phone'] ?? '').toString().trim();
    if (p.isNotEmpty) return p;
    return (l['whatsapp'] ?? '').toString().trim();
  }

  String _nameOf(Map<String, dynamic> l, AppLocalizations t) =>
      (l['name']?.toString().isNotEmpty == true
              ? l['name']
              : (l['company'] ?? t.crmLead))
          .toString();

  /// Inline call + WhatsApp buttons for a lead row — launch directly (no
  /// drill-in). Only shown when the row resolves to a lead id AND has a phone.
  Widget? _inlineActions(AppLocalizations t, Map<String, dynamic> l) {
    final id = _leadIdOf(l);
    final phone = _phoneOf(l);
    if (id == null || phone.isEmpty) return null;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(
        tooltip: t.crmCall,
        icon: const Icon(Icons.call),
        onPressed: () => crmQuickCall(context, id, phone),
      ),
      IconButton(
        tooltip: t.cWhatsapp,
        icon: const Icon(Icons.chat),
        onPressed: () async {
          final sent = await crmQuickWhatsApp(context, id, _nameOf(l, t));
          if (sent) _load();
        },
      ),
    ]);
  }

  /// A trailing "reschedule" button for overdue/stuck/missing rows — opens the
  /// log-activity sheet so the rep can set a new next-follow-up on the spot.
  /// Only shown when the row resolves to a lead id.
  Widget? _rescheduleAction(AppLocalizations t, Map<String, dynamic> row) {
    final id = _leadIdOf(row);
    if (id == null) return null;
    return IconButton(
      tooltip: t.remCalReschedule,
      icon: const Icon(Icons.event_repeat_outlined),
      onPressed: () => _reschedule(id),
    );
  }

  Future<void> _reschedule(int leadId) async {
    final saved = await CrmLogActivitySheet.show(context, leadId: leadId);
    if (saved == true) _load();
  }

  Widget _header(String text, IconData icon, Color tint) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.md, Gap.xs, Gap.sm),
        child: Row(children: [
          Icon(icon, size: 18, color: tint),
          const SizedBox(width: Gap.sm),
          Expanded(child: Text(text, style: const TextStyle(fontWeight: FontWeight.w800))),
        ]),
      );
}
