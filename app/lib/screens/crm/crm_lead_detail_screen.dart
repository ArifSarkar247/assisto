import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../theme.dart';
import '../../l10n/app_localizations.dart';
import 'crm_common.dart';
import '../../plans_v2/plans_v2.dart';
import '../../plans_v2/upgrade_sheet.dart';
import 'crm_lead_form_screen.dart';
import 'crm_proposal_screen.dart';
import 'crm_proposal_advanced_screen.dart';
import 'crm_whatsapp_sheet.dart';
import 'crm_log_activity_sheet.dart';
import 'crm100_api.dart'; // crm100
import 'crm_send_sheet.dart'; // crm100
import 'customer_history_screen.dart'; // crm100

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
  UpgradeReason? _followupLock; // plans-v2: follow-up reminders locked
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
      final api = CrmApi.of(context);
      // G3: retrieve the single lead directly instead of listing + firstWhere.
      _lead = await api.lead(widget.leadId);
      _timeline = await api.leadTimeline(widget.leadId);
    } catch (e) {
      _error = CrmError.from(e);
    }
    // plans-v2: the follow-up suggestion is a Premium feature — a refusal
    // must never hide the lead itself (reads always work).
    _followupLock = null;
    if (_error == null) {
      try {
        _followup = await CrmApi.of(context).leadFollowup(widget.leadId);
      } catch (e) {
        _followup = null;
        _followupLock = UpgradeReason.fromError(e);
      }
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

  // Open the WhatsApp Business Cloud API sheet. A send there is auto-logged on
  // the server, so we refresh the timeline when it returns true.
  Future<void> _openWhatsApp(Map<String, dynamic> l) async {
    final name = (l['name']?.toString().isNotEmpty == true
        ? l['name']
        : (l['company'] ?? '')).toString();
    final sent = await CrmWhatsAppSheet.show(context,
        leadId: widget.leadId, leadName: name);
    if (sent == true) _load();
  }

  // Fast "log what happened + set next follow-up" flow (sales-exec core task).
  // The sheet logs an activity and (optionally) writes next_follow_up on the
  // lead — the field that drives the CRM Today screen. Refresh on any save.
  Future<void> _logActivity() async {
    final saved = await CrmLogActivitySheet.show(context,
        leadId: widget.leadId,
        currentFollowUp: (_lead?['next_follow_up'] ?? '').toString());
    if (saved == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(appBar: AppBar(title: Text(t.crmLead)), body: const CrmStateView.loading());
    }
    if (_error != null || _lead == null || _lead!.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(t.crmLead)),
        body: CrmStateView.error(
            error: _error ?? CrmError(t.loadFailed, ''),
            title: t.loadFailed,
            onRetry: _load),
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
            tooltip: AppLocalizations.of(context).edit,
            icon: const Icon(Icons.edit_rounded),
            onPressed: () async {
              final ok = await Navigator.push<bool>(context,
                  MaterialPageRoute(builder: (_) => CrmLeadFormScreen(org: widget.org, existing: l)));
              if (ok == true) _load();
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _logActivity,
        icon: const Icon(Icons.add_task_rounded),
        label: Text(t.crmLogActivity),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96), children: [ // clear the FAB
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
                  Text('${t.crmScoreReason}: ${crmScoreReasonText(context, t, '${l['score_reason']}')}',
                      style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
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
            Expanded(child: _action(t.crmCall, Icons.call_rounded, phone.isNotEmpty,
                () => _quick(t, 'call', 'tel:$phone'))),
            const SizedBox(width: Gap.sm),
            // WhatsApp now opens the official Business Cloud API sheet (send +
            // auto-log + key-gated state) — NOT a wa.me personal deep-link.
            Expanded(child: _action('WhatsApp', Icons.chat_rounded, (wa.isNotEmpty || phone.isNotEmpty),
                () => _openWhatsApp(l))),
            const SizedBox(width: Gap.sm),
            Expanded(child: _action(t.email, Icons.mail_outline_rounded, email.isNotEmpty,
                () => _quick(t, 'email', 'mailto:$email'))),
          ]),
          // crm100: send from the CRM (WhatsApp link / phone SMS / Assisto
          // SMS, never automatic) + the one customer history page.
          const SizedBox(height: Gap.sm),
          Row(children: [
            Expanded(child: _action(t.c100ActMessage, Icons.send_rounded,
                (wa.isNotEmpty || phone.isNotEmpty), () async {
              final name = '${l['name'] ?? ''}'.isNotEmpty ? '${l['name']}' : '${l['company'] ?? ''}';
              final sent = await CrmSendSheet.show(context,
                  target: CustomerTarget(lead: widget.leadId),
                  name: name,
                  lead: widget.leadId,
                  initialText: t.c100DefaultText(name.isEmpty ? t.c100Customer : name));
              if (sent == true) _load();
            })),
            const SizedBox(width: Gap.sm),
            Expanded(child: _action(t.c100HistoryShort, Icons.history_rounded, true,
                () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => CustomerHistoryScreen(
                        target: CustomerTarget(lead: widget.leadId),
                        name: '${l['name'] ?? ''}'))))),
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
                // Tap to set/change the next follow-up date (drives Today).
                InkWell(
                  onTap: _logActivity,
                  borderRadius: BorderRadius.circular(Radii.sm),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: Gap.xs),
                    child: Row(children: [
                      const Icon(Icons.event_rounded, size: 16),
                      const SizedBox(width: Gap.xs),
                      Expanded(
                        child: Text((l['next_follow_up'] ?? '').toString().isNotEmpty
                            ? '${t.crmNextFollowUp}: ${crmDate(context, l['next_follow_up'])}'
                            : t.crmNextFollowUp),
                      ),
                      Icon(Icons.edit_rounded, size: 14, color: scheme.onSurfaceVariant),
                    ]),
                  ),
                ),
                if (_followupLock != null)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      key: const Key('pv2-followup-locked'),
                      onPressed: () => UpgradeSheet.show(context, _followupLock!),
                      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                      icon: const Icon(Icons.lock_rounded, size: 18),
                      label: Text(t.pv2FollowupLocked(planName(t, _followupLock!.neededPlan))),
                    ),
                  ),
                if (_followup?['ok'] == true) ...[
                  Text('${t.crmSuggestedContact}: ${crmDate(context, _followup!['suggested_contact_date'])}',
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                  const SizedBox(height: Gap.xs),
                  Text(_followup!['draft'] ?? '', style: const TextStyle(height: 1.4)),
                  const SizedBox(height: Gap.xs),
                  Text(
                    _followup!['draft_source'] == 'ai' ? t.crmDraftAi : t.crmDraftTemplate,
                    style: AType.labelSmall.copyWith(color: scheme.onSurfaceVariant),
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
            icon: const Icon(Icons.description_rounded),
            label: Text(t.crmProposals),
          ),
          const SizedBox(height: Gap.sm),
          OutlinedButton.icon(
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(
                    builder: (_) => CrmProposalAdvancedScreen(org: widget.org, lead: l))),
            icon: const Icon(Icons.auto_awesome_motion_rounded),
            label: Text(t.crmQuoteVersions),
          ),
          // ---- Won / Lost actions ----
          const SizedBox(height: Gap.sm),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _markWon(t),
                icon: const Icon(Icons.emoji_events_rounded),
                label: Text(t.shopQaMarkWon),
              ),
            ),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _markLost(t),
                icon: const Icon(Icons.cancel_rounded),
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
                const Icon(Icons.auto_awesome_rounded, size: 16),
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
                  style: AType.labelSmall.copyWith(color: scheme.onSurfaceVariant)),
            ),
          for (final m in msgs)
            ListTile(
              dense: true,
              leading: Icon(m['direction'] == 'out' ? Icons.call_made_rounded : Icons.call_received_rounded, size: 18),
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
        scrollable: true, // insets: 200% text / keyboard
        title: Text(t.shopQaMarkWon),
        content: Text(t.crmMarkWonConfirm),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.shopQaMarkWon)),
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
        scrollable: true, // insets: 200% text / keyboard
        title: Text(t.shopQaMarkWon),
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
          scrollable: true, // insets: 200% text / keyboard
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
          scrollable: true, // insets: 200% text / keyboard
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

  // icon over label: three equal buttons fit 360 px without cutting
  // "WhatsApp" to "Wh…"; the label shrinks rather than ellipsizes.
  Widget _action(String label, IconData icon, bool enabled, VoidCallback onTap) =>
      OutlinedButton(
        onPressed: enabled ? onTap : null,
        style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: Gap.xs, vertical: Gap.sm)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 18),
          const SizedBox(height: Gap.xxs),
          FittedBox(fit: BoxFit.scaleDown, child: Text(label, maxLines: 1)),
        ]),
      );

  Widget _pill(String k, dynamic v) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xs),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        child: Text('$k: $v', style: AType.bodySmall),
      );

  Widget _sectionTitle(String s) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.xs),
        child: Text(s, style: const TextStyle(fontWeight: FontWeight.w800)),
      );

  IconData _kindIcon(String? k) {
    switch (k) {
      case 'call':
        return Icons.call_rounded;
      case 'meeting':
        return Icons.groups_rounded;
      case 'whatsapp':
        return Icons.chat_rounded;
      case 'email':
        return Icons.mail_outline_rounded;
      case 'note':
        return Icons.sticky_note_2_rounded;
      case 'stage':
        return Icons.swap_horiz_rounded;
      default:
        return Icons.circle_rounded;
    }
  }
}
