import 'dart:math';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../api.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
import '../../widgets/ladder_common.dart' show fmtInt;
import '../../l10n/app_localizations.dart';
import 'crm_whatsapp_sheet.dart';

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

  // ---- companies / contacts (Company/Contact 360) ----
  // Both ViewSets are org-scoped on the server. There is NO ?company filter on
  // the contact/deal/activity viewsets yet, so the 360 screen fetches the org
  // set once and groups client-side (see crm_company360_integration.md).
  Future<List<Map<String, dynamic>>> companies(int org) =>
      _c.listItems('crm/companies?org=$org');
  Future<Map<String, dynamic>> company(int id) =>
      _c.getJson('/crm/companies/$id/');
  Future<List<Map<String, dynamic>>> contacts(int org) =>
      _c.listItems('crm/contacts?org=$org');

  // ---- activities ----
  // `company`/`contact` params are sent HOPEFULLY — the server ignores unknown
  // query keys, so when the backend adds the filter this starts narrowing
  // automatically; until then the 360 screen filters the org set client-side.
  Future<List<Map<String, dynamic>>> activities(int org,
      {int? lead, int? deal, int? company, int? contact}) {
    final sb = StringBuffer('crm/activities?org=$org');
    if (lead != null) sb.write('&lead=$lead');
    if (deal != null) sb.write('&deal=$deal');
    if (company != null) sb.write('&company=$company');
    if (contact != null) sb.write('&contact=$contact');
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

  /// What to show the user: the server's message, or a plain-language line
  /// for a technical (network) failure — never a raw exception/URL.
  String textFor(BuildContext context) =>
      _honest(AppLocalizations.of(context));

  /// rt2: a 5xx with no human sentence (the client's generic "Something went
  /// wrong (500)" or an empty body) is OUR server's fault — say so; the
  /// "check your internet" line only when the server never answered.
  String _honest(AppLocalizations t) {
    final generic = message.isEmpty || message.startsWith('Something went wrong (');
    if ((status ?? 0) >= 500 && generic) return t.m3ErrServer;
    return message.isNotEmpty ? message : t.shopQaLoadFailedBody;
  }

  static final _rand = Random();
  // Unambiguous alphabet (no 0/O/1/I), matching the server's ref_code().
  static const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  static String _clientRef() =>
      List.generate(6, (_) => _alphabet[_rand.nextInt(_alphabet.length)]).join();

  /// Build from any thrown error. Prefers the server's ref (carried on
  /// ApiException.ref, parsed in api.dart);
  /// falls back to a locally-minted, locally-logged code.
  factory CrmError.from(Object e) {
    String? serverRef;
    // Only a server ApiException carries a human message. Anything else
    // (ClientException / SocketException with a URL) is technical: it is
    // logged with the ref code, and the user sees a plain-language line.
    String message = '';
    final technical = e.toString();
    int? status;
    if (e is ApiException) {
      message = e.message;
      status = e.status;
      // `ref` is ApiException's optional server reference code. Read
      // defensively (it may be null).
      try {
        final dynamic dyn = e;
        final r = dyn.ref;
        if (r is String && r.isNotEmpty) serverRef = r;
      } catch (_) {/* field not present on this build */}
    }
    if (serverRef != null) return CrmError(message, serverRef, status: status);
    final local = _clientRef();
    debugPrint('CRM error ref=$local (client) :: ${message.isEmpty ? technical : message}');
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
      icon: Icons.cloud_off_rounded,
      tint: scheme.error,
      title: title ?? t.loadFailed,
      message: error == null ? t.shopQaLoadFailedBody : error!._honest(t),
      action: Column(mainAxisSize: MainAxisSize.min, children: [
        if (error != null && error!.ref.isNotEmpty) RefCodeChip(error!.ref),
        if (onRetry != null) ...[
          const SizedBox(height: Gap.md),
          FilledButton.tonalIcon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
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
        Icon(Icons.tag_rounded, size: 14, color: scheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Text('${t.crmRefCode}: ',
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
        SelectableText(code,
            style: AType.labelMedium.copyWith(fontWeight: FontWeight.w800,
                letterSpacing: 1.0)),
      ]),
    );
  }
}

/// Format a BDT amount with the taka sign, LOCALE-AWARE: Bangla digits + comma
/// grouping in Bangla, Latin in English (reuses the shared [fmtInt], which also
/// handles the sign). ৳ (U+09F3) is allowed in .dart — the language gate exempts
/// the currency sign. Pass a BuildContext so the locale can be read.
String bdt(BuildContext context, num? v) =>
    '৳${fmtInt(context, (v ?? 0).round())}';

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
        ? Theme.of(context).colorScheme.error
        : warm
            ? AssistoTokens.of(context).warning
            : Theme.of(context).colorScheme.surfaceContainerHighest;
    final fg = hot
        ? Theme.of(context).colorScheme.onError
        : warm
            ? AssistoTokens.of(context).onWarning
            : Theme.of(context).colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Radii.pill)),
      child: Text('$score',
          style: AType.labelMedium.copyWith(color: fg, fontWeight: FontWeight.w800)),
    );
  }
}

/// A clean "available when ___" / needs-key banner. Keeps every AI/integration
/// gate honest and consistent across the CRM.
class NeedsKeyBanner extends StatelessWidget {
  final String message;
  final IconData icon;
  const NeedsKeyBanner(this.message, {super.key, this.icon = Icons.lock_outline_rounded});
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
      return Icons.checkroom_rounded;
    case 'pharma':
      return Icons.medication_rounded;
    case 'retail':
      return Icons.storefront_rounded;
    default:
      return Icons.business_rounded;
  }
}

/// Source code → icon, for the leads list.
IconData sourceIcon(String? code) {
  switch (code) {
    case 'whatsapp':
      return Icons.chat_rounded;
    case 'messenger':
      return Icons.forum_rounded;
    case 'linkedin':
      return Icons.business_center_rounded;
    case 'email':
      return Icons.mail_outline_rounded;
    default:
      return Icons.edit_rounded;
  }
}

/// Shared quick-contact launchers so the Today list and the Leads list can
/// dial / open WhatsApp inline WITHOUT drilling into the lead-detail screen —
/// identical mechanism to CrmLeadDetailScreen's `_quick`/`_openWhatsApp`.
///
/// [crmQuickCall]: logs the tap as a `call` activity (best-effort), then opens
/// the device dialer with `tel:`. If the dialer can't open, it says so honestly
/// (G8) instead of implying success. Fully guarded.
Future<void> crmQuickCall(
    BuildContext context, int leadId, String phone) async {
  final t = AppLocalizations.of(context);
  try {
    await CrmApi.of(context).logAction(leadId, 'call');
  } catch (_) {/* best-effort log */}
  bool launched = false;
  try {
    launched = await launchUrl(Uri.parse('tel:$phone'),
        mode: LaunchMode.externalApplication);
  } catch (_) {
    launched = false;
  }
  if (!launched && context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(t.crmQuickLaunchFailed)));
  }
}

/// [crmQuickWhatsApp]: opens the official WhatsApp Business Cloud API sheet
/// (send + auto-log + key-gated state) — NOT a wa.me personal deep-link, mirror
/// of the detail screen. Returns true if a message was sent (caller may refresh).
Future<bool> crmQuickWhatsApp(
    BuildContext context, int leadId, String leadName) async {
  final sent = await CrmWhatsAppSheet.show(context,
      leadId: leadId, leadName: leadName);
  return sent == true;
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

/// QA qa1: CRM dates came through as ISO "2026-10-13" in both languages.
/// A date-only/ISO string becomes a localized medium date ("13 Oct 2026" /
/// Bangla digits and month); anything unparsable is shown as-is, empty as "—".
String crmDate(BuildContext context, dynamic v) {
  final s = (v ?? '').toString();
  if (s.isEmpty) return '—';
  final d = DateTime.tryParse(s);
  if (d == null) return s;
  return DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag()).format(d);
}

/// QA qa1: the server's score reason is a formula with internal keys
/// ("industry_fit=25 + company_size=25 + buying_signals=50 (…) = 95"). Show it
/// as words in the user's language; an unknown format falls back to the raw
/// text (it is still the honest reason).
String crmScoreReasonText(BuildContext context, AppLocalizations t, String raw) {
  final m = RegExp(r'industry_fit=(\d+).*?company_size=(\d+).*?buying_signals=(\d+)')
      .firstMatch(raw);
  if (m == null) return raw;
  String n(int i) => fmtInt(context, int.parse(m.group(i)!));
  return t.qa1CrmScoreParts(n(1), n(2), n(3));
}

// The backend's by_industry rows carry the raw industry CODE (rmg/pharma/…).
// Map known codes to their proper labels (matches crm_firstrun) and title-
// case anything unexpected, so nothing renders as a bare lowercase token.
String crmIndustryLabel(AppLocalizations t, String? code) {
  switch (code) {
    case 'rmg':
      return t.crmIndRmg;
    case 'pharma':
      return t.crmIndPharma;
    case 'retail':
      return t.crmIndRetail;
    case 'it':
      return t.crmIndIt;
    case 'manufacturing':
      return t.crmIndManufacturing;
    case 'services':
      return t.crmIndServices;
    case 'other':
      return t.crmIndOther;
    default:
      final c = (code ?? '').trim();
      if (c.isEmpty) return '—';
      return c[0].toUpperCase() + c.substring(1);
  }
}
