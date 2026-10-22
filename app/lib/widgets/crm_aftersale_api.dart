import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import '../api.dart';
import '../state.dart';

/// Thin API wrappers for the ADVANCED quote/proposal + AFTER-SALE surfaces.
/// Kept in a NEW file (shared api.dart and screens/crm/crm_common.dart are not
/// modified) — every call uses the existing generic ApiClient helpers.
///
/// All of these endpoints are described in
/// `.phaseB/crm_aftersale_integration.md` and resolve (route_check); any
/// server failure surfaces a clean CrmStateView.error with a reference code.
class CrmAfterSaleApi {
  final ApiClient _c;
  CrmAfterSaleApi(this._c);

  static CrmAfterSaleApi of(BuildContext ctx) =>
      CrmAfterSaleApi(ctx.read<AppState>().api);

  // ---- quote versions / acceptance / convert (advanced §6) ----
  Future<List<Map<String, dynamic>>> quoteVersions(int leadId) =>
      // versions = the lead's proposals (ProposalViewSet filters ?lead=); the
      // old crm/leads/<id>/quote_versions route never existed (route_check).
      _c.listItems('crm/proposals?lead=$leadId');
  Future<Map<String, dynamic>> quoteVersionDiff(int quoteId) =>
      _c.getJson('/crm/proposals/$quoteId/diff/');
  Future<Map<String, dynamic>> setValidity(int quoteId, int validDays) =>
      _c.postJson('/crm/proposals/$quoteId/validity/', {'valid_days': validDays});
  Future<Map<String, dynamic>> requestDiscountApproval(int quoteId) =>
      _c.postJson('/crm/proposals/$quoteId/request_discount_approval/');
  Future<Map<String, dynamic>> approveDiscount(int quoteId) =>
      _c.postJson('/crm/proposals/$quoteId/approve_discount/');
  Future<Map<String, dynamic>> acceptanceLink(int quoteId) =>
      _c.getJson('/crm/proposals/$quoteId/acceptance_link/');
  Future<Map<String, dynamic>> pdfModel(int quoteId) =>
      _c.getJson('/crm/proposals/$quoteId/pdf_model/');
  Future<Map<String, dynamic>> convertToOrder(int quoteId) =>
      _c.postJson('/crm/proposals/$quoteId/convert_to_order/');

  // ---- after-sale: collections (§7) ----
  Future<List<Map<String, dynamic>>> installments(int org, {int? order}) =>
      _c.listItems(
          'crm/installments?org=$org${order != null ? '&order=$order' : ''}');
  Future<Map<String, dynamic>> collectionSummary(int org, {int? order}) =>
      _c.getJson(
          '/crm/collections/summary?org=$org${order != null ? '&order=$order' : ''}');
  Future<Map<String, dynamic>> recordCollection(
          int installmentId, int amountPoisha, String method,
          {String reference = ''}) =>
      _c.postJson('/crm/installments/$installmentId/collect/', {
        'amount_poisha': amountPoisha,
        'method': method,
        'reference': reference,
      });

  // ---- after-sale: AMC / renewals (§7) ----
  Future<List<Map<String, dynamic>>> amcs(int org, {String? filter}) =>
      _c.listItems('crm/amcs?org=$org${filter != null ? '&status=$filter' : ''}');
  Future<Map<String, dynamic>> scheduleReminder(int amcId) =>
      _c.postJson('/crm/amcs/$amcId/schedule_reminder/');
  Future<Map<String, dynamic>> renewAmc(int amcId, int termDays) =>
      _c.postJson('/crm/amcs/$amcId/renew/', {'term_days': termDays});

  // ---- after-sale: complaints (§7) ----
  Future<List<Map<String, dynamic>>> complaints(int org, {String? state}) =>
      _c.listItems(
          'crm/complaints?org=$org${state != null ? '&state=$state' : ''}');
  Future<Map<String, dynamic>> createComplaint(Map<String, dynamic> body) =>
      _c.createItem('crm/complaints', body);
  Future<Map<String, dynamic>> complaintTransition(int id, String action) =>
      _c.postJson('/crm/complaints/$id/transition/', {'action': action});

  // ---- after-sale: upsell (§7) ----
  Future<Map<String, dynamic>> upsell(int org, {int? company, int? lead}) =>
      _c.getJson('/crm/upsell?org=$org'
          '${company != null ? '&company=$company' : ''}'
          '${lead != null ? '&lead=$lead' : ''}');

  // ---- after-sale: Axon ERP implementation hand-off (design/link only) ----
  Future<Map<String, dynamic>> erpHandoff(int dealId) =>
      _c.getJson('/crm/deals/$dealId/erp_handoff/');
  Future<Map<String, dynamic>> erpHandoffTransition(int dealId, String action) =>
      _c.postJson('/crm/deals/$dealId/erp_handoff/transition/', {'action': action});
}

/// BDT formatting from integer POISHA (no float). 150050 → "৳1,500.50".
/// The whole-taka helper `bdt` in crm_common.dart drops paisa; this one keeps
/// the two-decimal paisa since after-sale collections track exact poisha.
String bdtFromPoisha(num? poisha) {
  final p = (poisha ?? 0).round();
  final sign = p < 0 ? '-' : '';
  final abs = p.abs();
  final taka = abs ~/ 100;
  final paisa = abs % 100;
  final s = taka.toString();
  final buf = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return '৳$sign$buf.${paisa.toString().padLeft(2, '0')}';
}
