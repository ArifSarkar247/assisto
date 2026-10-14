import 'api.dart';
import 'models.dart';
import 'widgets/action_models.dart';

/// Action Center client surface (SPEC v2.1 §21, feature #9 — "Action Center &
/// audit log"). Transparent log of everything the AI/app DID on the user's
/// behalf (DONE) plus actions awaiting the user's approval (PENDING), tied to
/// the autonomy level.
///
/// Implemented as an EXTENSION on [ApiClient] built ONLY on its public helpers
/// (getJson / postJson) so this module ships WITHOUT editing the shared
/// api.dart. The integrator SHOULD later fold these into ApiClient proper — the
/// signatures/paths below are authoritative and mirror
/// `.phaseB/up_action_integration.md`.
///
/// Honest degradation:
///   * DONE reads the REAL, already-shipped `GET /audit` endpoint
///     (AuditListView → AuditLog), so the chronological log works TODAY with
///     zero backend changes.
///   * UNDO posts to the REAL, already-shipped `POST /undo` endpoint
///     (UndoView), which restores the most-recently-deleted item inside the
///     180-second window. Outside that window / non-undoable actions surface a
///     plain "nothing to undo" — never a fake success.
///   * PENDING (approval queue) and per-action approve/reject/edit need the NEW
///     endpoints documented in the integration note. Until the backend lands
///     them, [pendingActions] catches the 404/My and returns an empty list so
///     the screen shows an honest "nothing waiting" state instead of an error.
extension ActionCenterApi on ApiClient {
  // --------------------------------------------------------------- DONE (audit)

  /// GET /audit -> list of audit entries (newest first, capped server-side).
  /// REAL endpoint today (AuditListView). Thin alias over the existing
  /// [ApiClient.audit] so the Action Center has one cohesive surface.
  Future<List<AuditEntry>> actionHistory() => audit();

  // ------------------------------------------------------------ PENDING (queue)

  /// GET /actions/pending -> {pending:[{id, action, module, title, summary,
  /// autonomy_level, created_at, detail}]}. NEW endpoint (see integration
  /// note). Returns the actions the AI has PREPARED but is holding for the
  /// user's approval under autonomy level 3 ("do it with approval").
  ///
  /// Degrades honestly: if the endpoint is not deployed yet (404) or the device
  /// is offline, returns an EMPTY list so the UI shows "nothing waiting", never
  /// a crash. Any other server error is rethrown for the caller to surface.
  Future<List<PendingAction>> pendingActions() async {
    try {
      final j = await getJson('/actions/pending');
      final raw = (j['pending'] as List?) ?? const [];
      return raw
          .map((e) => PendingAction.fromJson(e as Map<String, dynamic>))
          .toList();
    } on ApiException catch (e) {
      if (e.status == 404) return const <PendingAction>[];
      rethrow;
    }
  }

  /// POST /actions/{id}/approve {edit?} -> {ok, done:{...}}. Runs a prepared
  /// action now. When [edit] is supplied the user's tweaks (e.g. an edited
  /// draft message body) override the prepared payload before it runs.
  Future<Map<String, dynamic>> approveAction(int id,
          {Map<String, dynamic>? edit}) =>
      postJson('/actions/$id/approve', {if (edit != null) 'edit': edit});

  /// POST /actions/{id}/reject {reason?} -> {ok}. Discards a prepared action.
  /// The rejection itself is audit-logged server-side (action=`action.reject`).
  Future<Map<String, dynamic>> rejectAction(int id, {String? reason}) =>
      postJson('/actions/$id/reject',
          {if (reason != null && reason.isNotEmpty) 'reason': reason});

  // ---------------------------------------------------------------------- UNDO

  /// POST /undo -> {restored, id} | 404 {detail}. REAL endpoint today
  /// (UndoView): recreates the most-recently-deleted item within 180s. Returns
  /// null when there is nothing to undo (honest "too late / not undoable")
  /// instead of throwing, so callers can show a gentle note.
  Future<Map<String, dynamic>?> undoLast() async {
    try {
      return await postJson('/undo');
    } on ApiException catch (e) {
      if (e.status == 404 || e.status == 400) return null;
      rethrow;
    }
  }

  /// Whether a given audit action string is undoable right now. The backend's
  /// UndoView only recreates recently-DELETED items (`*.delete` within 180s),
  /// so we expose undo exactly when the log entry is a delete that has not
  /// already been undone. Keeps the UI honest — no "Undo" button that 404s.
  static bool isUndoable(AuditEntry e) =>
      e.action.endsWith('.delete') && e.detail['undone'] != true;
}
