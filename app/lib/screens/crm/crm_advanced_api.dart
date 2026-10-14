import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import '../../api.dart';
import '../../state.dart';

/// Thin API wrapper for the ADVANCED CRM surfaces added in this phase:
/// team targets/commission/leaderboard (#8), owner automation rules (#11) and
/// capture / dedupe-merge (#1). It uses ONLY the existing public ApiClient
/// helpers (listItems / createItem / updateItem / getJson / postJson) — no
/// change to the shared api.dart. Endpoint names mirror the ones documented in
/// `.phaseB/crm_team_integration.md` for the backend to add.
///
/// Kept separate from CrmApi (crm_common.dart) so this phase touches only NEW
/// files. Screens hold an instance via [CrmAdvApi.of].
class CrmAdvApi {
  final ApiClient _c;
  CrmAdvApi(this._c);

  static CrmAdvApi of(BuildContext ctx) => CrmAdvApi(ctx.read<AppState>().api);

  // ---------- TEAM (#8) ----------
  Future<List<Map<String, dynamic>>> members(int org) =>
      _c.listItems('crm/members?org=$org');

  /// Monthly targets for the org (each row: member, period, amount,
  /// deals_target, + server-computed progress: pct, won_amount, attained).
  Future<List<Map<String, dynamic>>> targets(int org, {String? period}) =>
      _c.listItems('crm/targets?org=$org${period != null ? '&period=$period' : ''}');

  /// OWNER sets/updates a member's target for a period. Amounts are owner
  /// inputs — the CRM never invents a quota.
  Future<Map<String, dynamic>> saveTarget(Map<String, dynamic> body) =>
      _c.createItem('crm/targets', body);

  /// Activity leaderboard (server ranks via logic_team.leaderboard). Rows carry
  /// calls/meetings/proposals/deals_won/won_amount + score + rank.
  Future<Map<String, dynamic>> leaderboard(int org, {String? period}) =>
      _c.getJson('/crm/leaderboard/?org=$org${period != null ? '&period=$period' : ''}');

  /// OWNER-REVIEW commission config for the org + a computed preview per member.
  /// The config is owner-defined (flat/tiered/bonus); nothing is hard-coded.
  Future<Map<String, dynamic>> commissionConfig(int org) =>
      _c.getJson('/crm/commission-config/?org=$org');
  Future<Map<String, dynamic>> saveCommissionConfig(
          int org, Map<String, dynamic> config) =>
      _c.postJson('/crm/commission-config/', {'org': org, 'config': config});

  // ---------- ROUTING (#8) ----------
  Future<List<Map<String, dynamic>>> routingRules(int org) =>
      _c.listItems('crm/routing-rules?org=$org');
  Future<Map<String, dynamic>> saveRoutingRule(Map<String, dynamic> body) =>
      _c.createItem('crm/routing-rules', body);
  Future<void> updateRoutingRule(int id, Map<String, dynamic> body) =>
      _c.updateItem('crm/routing-rules', id, body);
  Future<List<Map<String, dynamic>>> territories(int org) =>
      _c.listItems('crm/territories?org=$org');

  // ---------- AUTOMATION RULES (#11) ----------
  Future<List<Map<String, dynamic>>> automationRules(int org) =>
      _c.listItems('crm/automation-rules?org=$org');
  Future<Map<String, dynamic>> saveAutomationRule(Map<String, dynamic> body) =>
      _c.createItem('crm/automation-rules', body);
  Future<void> updateAutomationRule(int id, Map<String, dynamic> body) =>
      _c.updateItem('crm/automation-rules', id, body);
  Future<Map<String, dynamic>> deleteAutomationRule(int id) =>
      _c.postJson('/crm/automation-rules/$id/delete/', const {});

  // ---------- CAPTURE / DEDUPE (#1) ----------
  /// Business-card capture. OCR is key-gated server-side: with no key the
  /// response is {available:false, needs_key:true} and the user types the card
  /// text, which is parsed into a DRAFT. Never fabricates fields.
  Future<Map<String, dynamic>> cardParse(int org, {String text = ''}) =>
      _c.postJson('/crm/capture/card', {'org': org, 'text': text});

  /// Website lead-form intake → normalised lead draft (+ unmapped fields shown).
  Future<Map<String, dynamic>> formIntake(int org, Map<String, dynamic> payload) =>
      _c.postJson('/crm/capture/form', {'org': org, 'payload': payload});

  /// Detect duplicate leads (server mirrors logic_capture.find_duplicates).
  Future<Map<String, dynamic>> duplicates(int org) =>
      _c.getJson('/crm/capture/duplicates/?org=$org');

  /// Preview a merge WITHOUT applying it — returns the plan (activity_count
  /// before/after must be equal; the UI shows the no-loss guarantee).
  Future<Map<String, dynamic>> mergePreview(
          int org, int survivorId, List<int> duplicateIds) =>
      _c.postJson('/crm/capture/merge_preview',
          {'org': org, 'survivor': survivorId, 'duplicates': duplicateIds});

  /// Apply a reviewed merge (folds timeline/activities onto the survivor).
  Future<Map<String, dynamic>> mergeApply(
          int org, int survivorId, List<int> duplicateIds) =>
      _c.postJson('/crm/capture/merge',
          {'org': org, 'survivor': survivorId, 'duplicates': duplicateIds});

  Future<List<Map<String, dynamic>>> leads(int org) =>
      _c.listItems('crm/leads?org=$org');
}
