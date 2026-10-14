import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../api.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
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

  /// FIRST-RUN "Start your company's CRM": creates a CrmOrg, makes the caller
  /// OWNER and seeds a sample pipeline + default stages (server-side). `industry`
  /// and `teamSize` are the stable option codes from the first-run form.
  Future<Map<String, dynamic>> createOrg(String name,
          {String? industry, String? teamSize}) =>
      _c.createItem('crm/orgs', {
        'name': name,
        if (industry != null) 'industry': industry,
        if (teamSize != null) 'team_size': teamSize,
      });

  /// FIRST-RUN "Join a team": join an existing org by its invite code.
  Future<Map<String, dynamic>> joinOrg(String code) =>
      _c.postJson('/crm/join', {'code': code.trim()});

  /// Owner/manager: read the org's team invite code (to share with teammates).
  Future<Map<String, dynamic>> inviteCode(int org) =>
      _c.getJson('/crm/orgs/$org/invite/');

  /// Owner/manager: rotate (re-issue) the org's invite code.
  Future<Map<String, dynamic>> rotateInviteCode(int org) =>
      _c.postJson('/crm/orgs/$org/invite/');

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

  // ---- WhatsApp (official Business Cloud API only; MOCK + key-gated) ----
  // Honest state for the lead sheet: has_key (owner connected Meta Cloud API),
  // opted_in, in_window (24h free-form window). Never pretends to be live.
  Future<Map<String, dynamic>> whatsappStatus(int leadId) =>
      _c.getJson('/crm/leads/$leadId/whatsapp_status/');
  // Record the lead's WhatsApp consent (required before any send).
  Future<Map<String, dynamic>> whatsappOptIn(int leadId, bool optedIn) =>
      _c.postJson('/crm/leads/$leadId/whatsapp_optin/', {'opted_in': optedIn});
  // Send a WhatsApp message/template from the CRM. With no Meta key the server
  // returns state='needs_key' (drafted) — never a faked delivery. Either way the
  // send is auto-logged on the lead timeline as a whatsapp activity.
  Future<Map<String, dynamic>> whatsappSend(int leadId,
          {String? text, int? templateId, List<String> params = const []}) =>
      _c.postJson('/crm/leads/$leadId/whatsapp_send/', {
        if (text != null) 'text': text,
        if (templateId != null) 'template_id': templateId,
        if (params.isNotEmpty) 'params': params,
      });
  // Owner-defined WhatsApp templates (list + use). Body is owner-written copy;
  // the CRM never invents template content.
  Future<List<Map<String, dynamic>>> waTemplates(int org) =>
      _c.listItems('crm/wa-templates?org=$org&active=1');
  // Opt-in bulk send to a filtered lead set — fans out to individual 1:1 sends,
  // never a group (server enforces opt-in + 24h-window + paid-template rules).
  Future<Map<String, dynamic>> whatsappBulk(int org,
          {String? text, int? templateId, List<String> params = const [],
          List<int> leadIds = const [], String? status, String? priority}) =>
      _c.postJson('/crm/whatsapp/bulk', {
        'org': org,
        if (text != null) 'text': text,
        if (templateId != null) 'template_id': templateId,
        if (params.isNotEmpty) 'params': params,
        if (leadIds.isNotEmpty) 'lead_ids': leadIds,
        if (status != null) 'status': status,
        if (priority != null) 'priority': priority,
      });
}

/// A CRM failure the UI can render honestly: a human message + a short 6-char
/// REFERENCE CODE. The code is the SAME one the backend wrote to its error log
/// (crm/errors.py), so a user can quote it to support and support can grep the
/// server log for it. If the server didn't surface a code (older build / a
/// pre-network failure like no connectivity) we mint a client-side code and log
/// it locally via debugPrint so there is still something to correlate.
class CrmError {
  final String message;
  final String ref;
  final int? status;
  CrmError(this.message, this.ref, {this.status});

  static final _rand = Random();
  // Unambiguous alphabet (no 0/O/1/I), matching the server's ref_code().
  static const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  static String _clientRef() =>
      List.generate(6, (_) => _alphabet[_rand.nextInt(_alphabet.length)]).join();

  /// Build from any thrown error. Prefers the server's ref (carried on
  /// ApiException via a dynamic `ref` getter the integrator adds in api.dart);
  /// falls back to a locally-minted, locally-logged code.
  factory CrmError.from(Object e) {
    String? serverRef;
    String message = e.toString();
    int? status;
    if (e is ApiException) {
      status = e.status;
      // `ref` is an optional field on ApiException (integrator adds it so the
      // server's reference code flows through). Read it defensively so this
      // file compiles whether or not that field exists yet.
      try {
        final dynamic dyn = e;
        final r = dyn.ref;
        if (r is String && r.isNotEmpty) serverRef = r;
      } catch (_) {/* field not present on this build */}
    }
    if (serverRef != null) return CrmError(message, serverRef, status: status);
    final local = _clientRef();
    debugPrint('CRM error ref=$local (client) :: $message');
    return CrmError(message, local, status: status);
  }
}

/// A crafted CRM state view: LOADING (skeleton), EMPTY (friendly) or ERROR
/// (with the reference code + a RETRY button). One widget so every CRM screen
/// shows a consistent, localized, never-raw state. Pass exactly one of the
/// named constructors.
class CrmStateView extends StatelessWidget {
  final _Kind _kind;
  final IconData? icon;
  final String? title;
  final String? message;
  final CrmError? error;
  final VoidCallback? onRetry;
  final Widget? action;
  final int skeletonCount;

  const CrmStateView._(this._kind,
      {this.icon,
      this.title,
      this.message,
      this.error,
      this.onRetry,
      this.action,
      this.skeletonCount = 6});

  /// Loading state — the standard shimmering skeleton list.
  const CrmStateView.loading({int count = 6})
      : this._(_Kind.loading, skeletonCount: count);

  /// Empty state — friendly icon + title (+ optional hint / action).
  const CrmStateView.empty({
    required IconData icon,
    required String title,
    String? message,
    Widget? action,
  }) : this._(_Kind.empty,
            icon: icon, title: title, message: message, action: action);

  /// Error state — shows the reference code and a RETRY button.
  const CrmStateView.error({
    required CrmError error,
    required String title,
    VoidCallback? onRetry,
  }) : this._(_Kind.error, error: error, title: title, onRetry: onRetry);

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_kind == _Kind.loading) return SkeletonList(count: skeletonCount);
    if (_kind == _Kind.empty) {
      return StateMessage(
          icon: icon!, title: title!, message: message, action: action);
    }
    // ---- error: message + reference code chip + retry ----
    return StateMessage(
      icon: Icons.cloud_off,
      tint: scheme.error,
      title: title ?? t.loadFailed,
      message: error?.message,
      action: Column(mainAxisSize: MainAxisSize.min, children: [
        if (error != null && error!.ref.isNotEmpty) RefCodeChip(error!.ref),
        if (onRetry != null) ...[
          const SizedBox(height: Gap.md),
          FilledButton.tonalIcon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: Text(t.retry)),
        ],
      ]),
    );
  }
}

enum _Kind { loading, empty, error }

/// A small, copyable reference-code chip shown on every CRM error. Long-press /
/// tap copies it so a user can send the exact code to support.
class RefCodeChip extends StatelessWidget {
  final String code;
  const RefCodeChip(this.code, {super.key});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.tag, size: 14, color: scheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Text('${t.crmRefCode}: ',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        SelectableText(code,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.0)),
      ]),
    );
  }
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
