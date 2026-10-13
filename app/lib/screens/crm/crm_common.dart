import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../api.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../l10n/app_localizations.dart';

/// Shared helpers for the in-app Sales CRM module. All CRM screens talk to the
/// DRF JSON API under `/crm/...` via the existing generic ApiClient helpers
/// (getJson / postJson / listItems / createItem / updateItem / deleteItem) — no
/// changes to the shared api.dart are required.
class CrmApi {
  final ApiClient _c;
  CrmApi(this._c);

  static CrmApi of(BuildContext ctx) =>
      CrmApi(ctx.read<AppState>().api);

  // ---- orgs / today / dashboard ----
  Future<List<Map<String, dynamic>>> orgs() => _c.listItems('crm/orgs');
  Future<Map<String, dynamic>> createOrg(String name) =>
      _c.createItem('crm/orgs', {'name': name});
  Future<Map<String, dynamic>> today(int org) => _c.getJson('/crm/today?org=$org');
  Future<Map<String, dynamic>> dashboard(int org) =>
      _c.getJson('/crm/dashboard?org=$org');

  // ---- leads ----
  Future<List<Map<String, dynamic>>> leads(int org,
      {String? priority, String? status, String? industry, String? q}) {
    final sb = StringBuffer('crm/leads?org=$org');
    if (priority != null) sb.write('&priority=$priority');
    if (status != null) sb.write('&status=$status');
    if (industry != null) sb.write('&industry=$industry');
    if (q != null && q.isNotEmpty) sb.write('&q=${Uri.encodeQueryComponent(q)}');
    return _c.listItems(sb.toString());
  }

  Future<Map<String, dynamic>> createLead(Map<String, dynamic> body) =>
      _c.createItem('crm/leads', body);
  Future<void> updateLead(int id, Map<String, dynamic> body) =>
      _c.updateItem('crm/leads', id, body);
  // Retrieve a single lead (G3) — avoids loading the whole list + firstWhere.
  Future<Map<String, dynamic>> lead(int id) =>
      _c.getJson('/crm/leads/$id/');
  Future<Map<String, dynamic>> leadTimeline(int id) =>
      _c.getJson('/crm/leads/$id/timeline/');
  Future<Map<String, dynamic>> leadFollowup(int id) =>
      _c.getJson('/crm/leads/$id/followup/');
  Future<Map<String, dynamic>> leadProposal(int id, String requirements) =>
      _c.postJson('/crm/leads/$id/proposal/', {'requirements': requirements});
  Future<Map<String, dynamic>> leadOnboard(int id) =>
      _c.postJson('/crm/leads/$id/onboard/');
  // Close the lead's backing deal as WON (G2) — client confirms first.
  Future<Map<String, dynamic>> leadMarkWon(int id) =>
      _c.postJson('/crm/leads/$id/mark_won/');
  // Close the lead's backing deal as LOST with a MANDATORY reason (G1).
  Future<Map<String, dynamic>> leadMarkLost(int id, String lossReason,
          {String lossNote = '', String competitor = ''}) =>
      _c.postJson('/crm/leads/$id/mark_lost/', {
        'loss_reason': lossReason,
        'loss_note': lossNote,
        'competitor': competitor,
      });
  // Quote builder (G6): build a Proposal from price-book selections.
  Future<Map<String, dynamic>> leadQuote(int id, List<Map<String, dynamic>> selections,
          {double discountPct = 0, double taxPct = 0, String requirements = '', String title = ''}) =>
      _c.postJson('/crm/leads/$id/quote/', {
        'selections': selections,
        'discount_pct': discountPct,
        'tax_pct': taxPct,
        'requirements': requirements,
        'title': title,
      });
  Future<Map<String, dynamic>> logAction(int id, String kind,
          {String subject = '', String body = ''}) =>
      _c.postJson('/crm/leads/$id/log_action/',
          {'kind': kind, 'subject': subject, 'body': body});

  // ---- paste extraction (rule-based, no AI/scraping) ----
  Future<Map<String, dynamic>> extract(String text) =>
      _c.postJson('/crm/extract', {'text': text});

  // ---- pipelines / deals (kanban) ----
  Future<List<Map<String, dynamic>>> pipelines(int org) =>
      _c.listItems('crm/pipelines?org=$org');
  Future<List<Map<String, dynamic>>> deals(int org, {int? pipeline}) =>
      _c.listItems('crm/deals?org=$org${pipeline != null ? '&pipeline=$pipeline' : ''}');
  Future<Map<String, dynamic>> createDeal(Map<String, dynamic> body) =>
      _c.createItem('crm/deals', body);
  Future<Map<String, dynamic>> moveDeal(int id, int stage,
          {String? lossReason, String? lossNote, String? competitor}) =>
      _c.postJson('/crm/deals/$id/move/', {
        'stage': stage,
        if (lossReason != null) 'loss_reason': lossReason,
        if (lossNote != null) 'loss_note': lossNote,
        if (competitor != null) 'competitor': competitor,
      });
  Future<Map<String, dynamic>> setNextStep(int id, String step, String? due) =>
      _c.postJson('/crm/deals/$id/set_next_step/',
          {'next_step': step, 'next_step_due': due});

  // ---- activities ----
  Future<List<Map<String, dynamic>>> activities(int org, {int? lead, int? deal}) {
    final sb = StringBuffer('crm/activities?org=$org');
    if (lead != null) sb.write('&lead=$lead');
    if (deal != null) sb.write('&deal=$deal');
    return _c.listItems(sb.toString());
  }
  Future<Map<String, dynamic>> createActivity(Map<String, dynamic> body) =>
      _c.createItem('crm/activities', body);

  // ---- team / routing ----
  Future<List<Map<String, dynamic>>> members(int org) =>
      _c.listItems('crm/members?org=$org');
  Future<List<Map<String, dynamic>>> routingRules(int org) =>
      _c.listItems('crm/routing-rules?org=$org');

  // ---- proposals ----
  Future<List<Map<String, dynamic>>> proposals(int org, {int? lead}) =>
      _c.listItems('crm/proposals?org=$org${lead != null ? '&lead=$lead' : ''}');
  Future<Map<String, dynamic>> proposalTransition(int id, String to) =>
      _c.postJson('/crm/proposals/$id/transition/', {'to': to});

  // ---- price book ----
  Future<List<Map<String, dynamic>>> products(int org) =>
      _c.listItems('crm/products?org=$org');
}

/// Format a BDT amount with the taka sign (৳ is allowed in .dart).
String bdt(num? v) {
  final n = (v ?? 0).round();
  final s = n.abs().toString();
  final buf = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return '৳${n < 0 ? '-' : ''}$buf';
}

/// A 0–100 lead score badge. Colour steps: >=90 danger-tint (hot), >=60 warn,
/// else muted. WCAG-safe foregrounds.
class ScoreBadge extends StatelessWidget {
  final int score;
  const ScoreBadge(this.score, {super.key});
  @override
  Widget build(BuildContext context) {
    final hot = score >= 90;
    final warm = score >= 60;
    final bg = hot
        ? Brand.danger
        : warm
            ? Brand.warning
            : Theme.of(context).colorScheme.surfaceContainerHighest;
    final fg = (hot || warm) ? Colors.white : Theme.of(context).colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Text('$score',
          style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: 12)),
    );
  }
}

/// A clean "available when ___" / needs-key banner. Keeps every AI/integration
/// gate honest and consistent across the CRM.
class NeedsKeyBanner extends StatelessWidget {
  final String message;
  final IconData icon;
  const NeedsKeyBanner(this.message, {super.key, this.icon = Icons.lock_outline});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.all(Gap.md),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(children: [
        Icon(icon, size: 20, color: scheme.onSecondaryContainer),
        const SizedBox(width: Gap.sm),
        Expanded(
            child: Text(message,
                style: TextStyle(color: scheme.onSecondaryContainer, height: 1.35))),
      ]),
    );
  }
}

/// Industry code → icon, for the leads list.
IconData industryIcon(String? code) {
  switch (code) {
    case 'rmg':
      return Icons.checkroom_outlined;
    case 'pharma':
      return Icons.medication_outlined;
    case 'retail':
      return Icons.storefront_outlined;
    default:
      return Icons.business_outlined;
  }
}

/// Source code → icon, for the leads list.
IconData sourceIcon(String? code) {
  switch (code) {
    case 'whatsapp':
      return Icons.chat_outlined;
    case 'messenger':
      return Icons.forum_outlined;
    case 'linkedin':
      return Icons.business_center_outlined;
    case 'email':
      return Icons.mail_outline;
    default:
      return Icons.edit_outlined;
  }
}

/// The module options spec (lead required-modules multi-select). Codes are
/// stable; labels come from ARB so bn/en never mix.
List<({String code, String label})> moduleOptions(AppLocalizations t) => [
      (code: 'hrm', label: t.crmModHrm),
      (code: 'payroll', label: t.crmModPayroll),
      (code: 'vat', label: t.crmModVat),
      (code: 'accounts', label: t.crmModAccounts),
      (code: 'inventory', label: t.crmModInventory),
      (code: 'production', label: t.crmModProduction),
      (code: 'sales', label: t.crmModSales),
    ];
