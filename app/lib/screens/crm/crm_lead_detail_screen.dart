import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../theme.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/skeleton.dart';
import 'crm_common.dart';
import 'crm_lead_form_screen.dart';
import 'crm_proposal_screen.dart';

/// Lead/Deal detail (CRM_SPEC): smart profile, score WITH reasons, full timeline
/// (messages / calls / meetings / notes / AI summaries / sentiment), next step,
/// requirement sheet, proposals, and quick actions (call / WhatsApp / email) —
/// each quick action is LOGGED as a timeline activity.
class CrmLeadDetailScreen extends StatefulWidget {
  final int org;
  final int leadId;
  const CrmLeadDetailScreen({super.key, required this.org, required this.leadId});
  @override
  State<CrmLeadDetailScreen> createState() => _CrmLeadDetailScreenState();
}

class _CrmLeadDetailScreenState extends State<CrmLeadDetailScreen> {
  Map<String, dynamic>? _lead;
  Map<String, dynamic>? _timeline;
  Map<String, dynamic>? _followup;
  bool _loading = true, _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final api = CrmApi.of(context);
      // G3: retrieve the single lead directly instead of listing + firstWhere.
      _lead = await api.lead(widget.leadId);
      _timeline = await api.leadTimeline(widget.leadId);
      _followup = await api.leadFollowup(widget.leadId);
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _quick(AppLocalizations t, String kind, String uri) async {
    // Always log the quick action (CRM_SPEC: every tap is a timeline activity).
    try {
      await CrmApi.of(context).logAction(widget.leadId, kind);
    } catch (_) {}
    // G8: if the dialer/WhatsApp/email app doesn't open, say so honestly —
    // don't imply success by only showing "action logged".
    bool launched = false;
    try {
      launched = await launchUrl(Uri.parse(uri), mode: LaunchMode.externalApplication);
    } catch (_) {
      launched = false;
    }
    if (!launched && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.crmQuickLaunchFailed)));
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(appBar: AppBar(title: Text(t.crmLead)), body: const SkeletonList());
    }
    if (_error || _lead == null || _lead!.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(t.crmLead)),
        body: StateMessage(
            icon: Icons.cloud_off,
            tint: scheme.error,
            title: t.loadFailed,
            action: FilledButton.tonalIcon(
                onPressed: _load, icon: const Icon(Icons.refresh), label: Text(t.retry))),
      );
    }
    final l = _lead!;
    final phone = (l['phone'] ?? '').toString();
    final wa = (l['whatsapp'] ?? '').toString();
    final email = (l['email'] ?? '').toString();
    final msgs = (_timeline?['messages'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final acts = (_timeline?['activities'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final insight = (_timeline?['insight'] ?? '').toString();
    final modules = ((l['required_modules'] as List?) ?? []).map((x) => x.toString()).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(l['name']?.toString().isNotEmpty == true ? l['name'] : (l['company'] ?? t.crmLead)),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            onPressed: () async {
              final ok = await Navigator.push<bool>(context,
                  MaterialPageRoute(builder: (_) => CrmLeadFormScreen(org: widget.org, existing: l)));
              if (ok == true) _load();
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.all(Gap.md), children: [
          // ---- smart profile + score ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  ScoreBadge((l['score'] as num?)?.toInt() ?? 0),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                      child: Text([l['company'], l['designation'], l['industry_display']]
                          .where((e) => (e ?? '').toString().isNotEmpty)
                          .join(' · '))),
                ]),
                const SizedBox(height: Gap.sm),
                if ((l['score_reason'] ?? '').toString().isNotEmpty)
                  Text('${t.crmScoreReason}: ${l['score_reason']}',
                      style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
                const SizedBox(height: Gap.sm),
                Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
                  _pill(t.status, l['status_display']),
                  _pill(t.source, l['source_display']),
                  if ((l['budget_range'] ?? '').toString().isNotEmpty) _pill(t.crmBudgetRange, l['budget_range']),
                  if ((l['timeline'] ?? '').toString().isNotEmpty) _pill(t.crmTimeline, l['timeline']),
                  if ((l['decision_maker'] ?? '').toString().isNotEmpty) _pill(t.crmDecisionMaker, l['decision_maker']),
                ]),
              ]),
            ),
          ),
          // ---- quick actions (each logged) ----
          const SizedBox(height: Gap.sm),
          Row(children: [
            Expanded(child: _action(t.crmCall, Icons.call, phone.isNotEmpty,
                () => _quick(t, 'call', 'tel:$phone'))),
            const SizedBox(width: Gap.sm),
            Expanded(child: _action('WhatsApp', Icons.chat, (wa.isNotEmpty || phone.isNotEmpty),
                () => _quick(t, 'whatsapp', 'https://wa.me/${(wa.isNotEmpty ? wa : phone).replaceAll(RegExp(r"[^0-9]"), "")}'))),
            const SizedBox(width: Gap.sm),
            Expanded(child: _action(t.email, Icons.mail_outline, email.isNotEmpty,
                () => _quick(t, 'email', 'mailto:$email'))),
          ]),
          // ---- required modules (requirement sheet seed) ----
          if (modules.isNotEmpty) ...[
            const SizedBox(height: Gap.md),
            _sectionTitle(t.crmRequiredModules),
            Wrap(spacing: Gap.xs, children: [
              for (final m in moduleOptions(t))
                if (modules.contains(m.code)) Chip(label: Text(m.label)),
            ]),
          ],
          if ((l['notes'] ?? '').toString().isNotEmpty) ...[
            const SizedBox(height: Gap.md),
            _sectionTitle(t.crmRequirements),
            Text(l['notes']),
          ],
          // ---- next step / follow-up suggestion ----
          const SizedBox(height: Gap.md),
          _sectionTitle(t.crmNextStep),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if ((l['next_follow_up'] ?? '').toString().isNotEmpty)
                  Text('${t.crmNextFollowUp}: ${l['next_follow_up']}'),
                if (_followup?['ok'] == true) ...[
                  Text('${t.crmSuggestedContact}: ${_followup!['suggested_contact_date'] ?? '—'}',
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                  const SizedBox(height: Gap.xs),
                  Text(_followup!['draft'] ?? '', style: const TextStyle(height: 1.4)),
                  const SizedBox(height: Gap.xs),
                  Text(
                    _followup!['draft_source'] == 'ai' ? t.crmDraftAi : t.crmDraftTemplate,
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                ],
              ]),
            ),
          ),
          // ---- proposals ----
          const SizedBox(height: Gap.md),
          FilledButton.tonalIcon(
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => CrmProposalScreen(org: widget.org, lead: l))),
            icon: const Icon(Icons.description_outlined),
            label: Text(t.crmProposals),
          ),
          // ---- Won / Lost actions ----
          const SizedBox(height: Gap.sm),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _markWon(t),
                icon: const Icon(Icons.emoji_events_outlined),
                label: Text(t.crmMarkWon),
              ),
            ),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _markLost(t),
                icon: const Icon(Icons.cancel_outlined),
                label: Text(t.crmMarkLost),
              ),
            ),
          ]),
          // ---- timeline ----
          const SizedBox(height: Gap.md),
          _sectionTitle(t.crmActivityTimeline),
          if (insight.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.sm),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.auto_awesome_outlined, size: 16),
                const SizedBox(width: Gap.xs),
                Expanded(child: Text(insight, style: TextStyle(fontStyle: FontStyle.italic, color: scheme.onSurfaceVariant))),
              ]),
            ),
          for (final a in acts)
            ListTile(
              dense: true,
              leading: Icon(_kindIcon(a['kind']), size: 18),
              title: Text(a['subject']?.toString().isNotEmpty == true ? a['subject'] : (a['kind_display'] ?? '')),
              subtitle: (a['body'] ?? '').toString().isNotEmpty ? Text(a['body']) : null,
              trailing: Text((a['created_at'] ?? '').toString().split('T').first,
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
            ),
          for (final m in msgs)
            ListTile(
              dense: true,
              leading: Icon(m['direction'] == 'out' ? Icons.call_made : Icons.call_received, size: 18),
              title: Text(m['text'] ?? ''),
              subtitle: Text('${m['sentiment']}'),
            ),
          if (acts.isEmpty && msgs.isEmpty)
            Padding(padding: const EdgeInsets.all(Gap.md), child: Text(t.crmNoTimeline)),
        ]),
      ),
    );
  }

  // G2: Mark Won = confirm → close the backing Deal as WON (server) → THEN
  // offer the separate ERP handoff. Winning no longer happens as a silent
  // side effect of the ERP stub.
  Future<void> _markWon(AppLocalizations t) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.crmMarkWon),
        content: Text(t.crmMarkWonConfirm),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.crmMarkWon)),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await CrmApi.of(context).leadMarkWon(widget.leadId);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      return;
    }
    if (!mounted) return;
    // Offer the ERP implementation handoff now that the lead is won.
    _load();
    final handoff = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.crmMarkWon),
        content: Text(t.crmWonErpHandoffPrompt),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.close)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.crmWonSendToErp)),
        ],
      ),
    );
    if (handoff != true) return;
    try {
      final r = await CrmApi.of(context).leadOnboard(widget.leadId);
      if (!mounted) return;
      final msg = r['ok'] == true ? t.crmWonHandedOff : (r['message'] ?? t.crmWonHandoffPending);
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Text(msg.toString()),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t.close))],
        ),
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _markLost(AppLocalizations t) async {
    final reasons = {
      'price': t.crmLossPrice,
      'competitor': t.crmLossCompetitor,
      'timing': t.crmLossTiming,
      'no_budget': t.crmLossNoBudget,
      'no_need': t.crmLossNoNeed,
      'no_response': t.crmLossNoResponse,
      'other': t.crmIndOther,
    };
    String? pick;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(t.crmLossReasonRequired),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final e in reasons.entries)
              RadioListTile<String>(
                value: e.key,
                groupValue: pick,
                title: Text(e.value),
                onChanged: (v) => set(() => pick = v),
              ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
            FilledButton(
                onPressed: pick == null ? null : () => Navigator.pop(ctx, true),
                child: Text(t.save)),
          ],
        ),
      ),
    );
    if (ok == true && pick != null) {
      try {
        // G1: route through the server action — loss_reason is MANDATORY and is
        // recorded on the backing Deal (reports.win_loss picks it up), not just
        // appended to free-text notes.
        await CrmApi.of(context).leadMarkLost(widget.leadId, pick!);
        _load();
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Widget _action(String label, IconData icon, bool enabled, VoidCallback onTap) =>
      OutlinedButton.icon(
        onPressed: enabled ? onTap : null,
        icon: Icon(icon, size: 18),
        label: Text(label, overflow: TextOverflow.ellipsis),
      );

  Widget _pill(String k, dynamic v) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        child: Text('$k: $v', style: const TextStyle(fontSize: 12)),
      );

  Widget _sectionTitle(String s) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.xs),
        child: Text(s, style: const TextStyle(fontWeight: FontWeight.w800)),
      );

  IconData _kindIcon(String? k) {
    switch (k) {
      case 'call':
        return Icons.call;
      case 'meeting':
        return Icons.groups_outlined;
      case 'whatsapp':
        return Icons.chat;
      case 'email':
        return Icons.mail_outline;
      case 'note':
        return Icons.sticky_note_2_outlined;
      case 'stage':
        return Icons.swap_horiz;
      default:
        return Icons.circle_outlined;
    }
  }
}
