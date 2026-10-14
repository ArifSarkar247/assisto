import 'api.dart';

/// Messenger MODERATION + OWNER-ADMIN — client surface (Step 3).
///
/// Wires the Flutter UI to the backend moderation engine
/// (`backend/core/logic/msg_moderation.py`; see
/// `.phaseB/msg_moderation_integration.md`). This moderation layer governs
/// PUBLIC surfaces only (channels / posts / communities / groups / people).
/// The circle-only E2E chat stays untouched: the server stores ciphertext
/// only and an admin NEVER sees message contents or contact lists. None of the
/// endpoints below return, accept or request message bodies or contacts — the
/// users projection is the ALLOWED public set (name, phone, photo, signup
/// date, plan, last active, app version, report count, status).
///
/// Implemented as an EXTENSION on [ApiClient] built ONLY on its public
/// [ApiClient.getJson] / [ApiClient.postJson] helpers, so this ships WITHOUT
/// editing the shared api.dart. Paths match the integration doc
/// (`api/v1/` prefix is applied by [AppConfig.api]; no trailing slash).
///
/// Admin gating: the admin endpoints return HTTP 403 `{"detail": "..."}` for
/// non-operator/owner users. [getJson]/[postJson] surface that as an
/// [ApiException] with `status == 403`; screens catch it and show a dedicated
/// "admins only" state. Shells SHOULD additionally pre-gate entry points with
/// [moderationWhoAmI] so non-admins never see the admin links at all.
extension MessengerAdminApi on ApiClient {
  // ==========================================================================
  // USER-FACING — reporting + appeals (any signed-in user)
  // ==========================================================================

  /// POST /moderation/report
  /// {target_kind: channel|post|community|group|person, target_id,
  ///  categories:[code,...], note?}
  /// -> {ok, severe, content_status, queued, message}.
  ///
  /// `categories` are normalized reason codes (see [ModReasons]); the SEVERE
  /// set (child sexual abuse, violent threats, terrorism, scams/fraud) is
  /// hidden immediately, everything else goes to review. The server decides —
  /// the client can never bypass the outcome.
  Future<Map<String, dynamic>> moderationReport({
    required String targetKind,
    required String targetId,
    required List<String> categories,
    String? note,
  }) =>
      postJson('/moderation/report', {
        'target_kind': targetKind,
        'target_id': targetId,
        'categories': categories,
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      });

  /// POST /moderation/<item>/appeal {reason}
  /// -> {ok, queue_state, message}. Affected user only; re-opens within the
  /// appeal window (server enforces `can_appeal`). Reason is required.
  Future<Map<String, dynamic>> moderationAppeal(
          String itemId, String reason) =>
      postJson('/moderation/$itemId/appeal', {'reason': reason});

  // ==========================================================================
  // ADMIN — moderation queue (operator / owner only; 403 otherwise)
  // ==========================================================================

  /// GET /admin/moderation/queue[?filter=severe|legal|appeals]
  /// -> {items:[{id, target_kind, target_id, categories:[...], severe,
  ///     content_status, queue_state, report_count, decision, legal_retention,
  ///     opened_at, resolved_at}], can_admin}.
  Future<Map<String, dynamic>> adminModerationQueue({String? filter}) =>
      getJson('/admin/moderation/queue'
          '${filter != null && filter.isNotEmpty ? '?filter=$filter' : ''}');

  /// GET /admin/moderation/<item> -> the full item + its audit trail
  /// {item:{...}, audit:[{actor, action, reason, at, ...}]}.
  Future<Map<String, dynamic>> adminModerationItem(String itemId) =>
      getJson('/admin/moderation/$itemId');

  /// POST /admin/moderation/<item>/action {action, reason}
  /// action ∈ remove|restore|warn|suspend|ban. `reason` is MANDATORY — the
  /// server rejects a blank reason and writes an append-only audit row.
  /// -> {ok, content_status, decision, audit:[...]}.
  Future<Map<String, dynamic>> adminModerationAction(
          String itemId, String action, String reason) =>
      postJson('/admin/moderation/$itemId/action',
          {'action': action, 'reason': reason});

  /// POST /admin/moderation/<item>/reopen {reason}
  /// -> {ok, queue_state}. Moves an appealed/resolved item back to queued.
  Future<Map<String, dynamic>> adminModerationReopen(
          String itemId, String reason) =>
      postJson('/admin/moderation/$itemId/reopen', {'reason': reason});

  // ==========================================================================
  // ADMIN — users (OWNER only; 403 otherwise)
  // PUBLIC PROJECTION ONLY. No message contents, no contact lists — ever.
  // ==========================================================================

  /// GET /admin/users[?q=<search>][&status=active|suspended|banned]
  /// -> {users:[{id, name, phone, photo_url, signup_date, plan, last_active,
  ///     app_version, report_count, status}], can_admin}.
  /// The projection is exactly the allowed public fields; the API does not
  /// return message bodies or contacts.
  Future<Map<String, dynamic>> adminUsers({String? query, String? status}) {
    final params = <String>[];
    if (query != null && query.trim().isNotEmpty) {
      params.add('q=${Uri.encodeQueryComponent(query.trim())}');
    }
    if (status != null && status.isNotEmpty) params.add('status=$status');
    final qs = params.isEmpty ? '' : '?${params.join('&')}';
    return getJson('/admin/users$qs');
  }

  /// GET /admin/users/<id>/public -> the user's PUBLIC channels/communities
  /// {channels:[{id, name, member_count, status}], communities:[...]}.
  /// Still no private content — public surfaces only.
  Future<Map<String, dynamic>> adminUserPublic(String userId) =>
      getJson('/admin/users/$userId/public');

  /// POST /admin/users/<id>/action {action, reason}
  /// action ∈ suspend|unsuspend|reset_sessions|ban. `reason` is MANDATORY;
  /// the server audits every action. -> {ok, status, audit:[...]}.
  Future<Map<String, dynamic>> adminUserAction(
          String userId, String action, String reason) =>
      postJson('/admin/users/$userId/action',
          {'action': action, 'reason': reason});

  // ==========================================================================
  // GATE — lightweight role probe so shells hide admin links from non-admins.
  // ==========================================================================

  /// GET /admin/moderation/queue used purely as a role probe: returns true iff
  /// the current user is an operator/owner. Catches 403 -> false, so the shell
  /// can decide whether to render the admin entry points at all. Any other
  /// error also resolves to false (fail-closed).
  Future<bool> moderationWhoAmI() async {
    try {
      final r = await getJson('/admin/moderation/queue?filter=probe');
      // Prefer an explicit flag when the backend sends one.
      if (r['can_admin'] is bool) return r['can_admin'] as bool;
      return true;
    } on ApiException {
      return false;
    } catch (_) {
      return false;
    }
  }
}

/// Normalized moderation reason codes shared by the report sheet and the admin
/// queue. The SEVERE set is hidden immediately on a single valid report; the
/// rest go to review. Codes mirror the backend logic constants; labels are
/// resolved via AppLocalizations in the UI (zero Bangla in source).
class ModReasons {
  ModReasons._();

  // Severe — immediate hide, legal-retention candidates.
  static const childSafety = 'child_safety'; // child sexual abuse/exploitation
  static const violentThreat = 'violent_threat';
  static const terrorism = 'terrorism';
  static const scamFraud = 'scam_fraud';

  // Non-severe — queued for review.
  static const harassment = 'harassment';
  static const hateSpeech = 'hate_speech';
  static const nudity = 'nudity'; // 18+ / adult content (owner-review policy)
  static const spam = 'spam';
  static const impersonation = 'impersonation';
  static const misinformation = 'misinformation';
  static const selfHarm = 'self_harm';
  static const other = 'other';

  static const severe = {childSafety, violentThreat, terrorism, scamFraud};

  static const severeOrder = [
    childSafety,
    violentThreat,
    terrorism,
    scamFraud,
  ];

  static const otherOrder = [
    harassment,
    hateSpeech,
    selfHarm,
    nudity,
    impersonation,
    misinformation,
    spam,
    other,
  ];

  static bool isSevere(String code) => severe.contains(code);
}

/// The kinds of public surface that can be reported. Passed as `target_kind`.
class ModTargets {
  ModTargets._();
  static const channel = 'channel';
  static const post = 'post';
  static const community = 'community';
  static const group = 'group';
  static const person = 'person';
}
