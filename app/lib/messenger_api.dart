import 'api.dart';

/// Assisto Messenger API surface — contacts/invites, personal connection
/// requests, and the messenger profile (`/me`).
///
/// Implemented as an EXTENSION on [ApiClient] so the Messenger shell ships
/// WITHOUT editing api.dart. It is built ONLY on the public, FIXED generic
/// helpers (`getJson` / `postJson`) and — for profile writes — the typed
/// `updateProfile(/me PATCH)` already on the client. Every path lives under
/// `api/v1/messenger/` or `/me` (AppConfig prepends `/api/v1`).
///
/// Backend contract (.phaseB/msg_contacts_integration.md,
/// .phaseB/CONNECTED_CIRCLE_MESSENGER.md):
///   POST /messenger/contacts/contract      -> client hashing contract (v1)
///   POST /messenger/contacts/match         -> who-is-on-Assisto (hashes only)
///   POST /messenger/invite/existing        -> in-app invite + connection req
///   POST /messenger/invite/share-link      -> OS share-sheet descriptor
///   POST /messenger/invite/sms             -> own-SIM sms: URI descriptor
///   POST /messenger/request                -> personal connection request
///   POST /messenger/request/<id>/act       -> accept|decline|cancel|block
///   POST /messenger/request/<id>/message   -> the ONE pre-accept note
///   POST /messenger/request/<id>/report    -> report (+ auto-block)
///   GET  /me                               -> profile (+ messenger fields)
///   PATCH/me                               -> profile write
///
/// PRIVACY INVARIANT: this layer NEVER sends raw phone numbers or names to the
/// server. Contact matching uploads ONLY the de-duplicated salted-hash batch
/// plus the permission flag; non-user hashes are never persisted anywhere.
extension MessengerApi on ApiClient {
  // ======================= contacts & matching ==========================

  /// GET the machine-readable client hashing contract (algorithm id, version,
  /// default country code, truncation length, and the server-wide match salt).
  /// The salt is NOT an auth key — it only raises the cost of an offline
  /// dictionary attack; the same number must hash identically on every device.
  Future<Map<String, dynamic>> contactsContract() =>
      getJson('/messenger/contacts/contract');

  /// POST a de-duplicated batch of salted hashes + the explicit permission
  /// flag. The server intersects against [UserPhoneHash] (verified users only)
  /// and returns `{matches:[public_user_descriptor...], stored:false}`. The
  /// request body is never persisted. Raw numbers/names are NEVER sent.
  Future<Map<String, dynamic>> contactsMatch({
    required List<String> hashes,
    required bool permissionGranted,
  }) =>
      postJson('/messenger/contacts/match', {
        'hashes': hashes,
        'permission_granted': permissionGranted,
      });

  // ======================= invites ======================================

  /// Invite an EXISTING Assisto user already in the device's matched set. Mints
  /// the in-app connection request; pushes via FCM when configured, else it
  /// shows on the target's next open. Relation is mandatory.
  Future<Map<String, dynamic>> inviteExisting({
    required int toUserId,
    required String relation,
    String? customLabel,
  }) =>
      postJson('/messenger/invite/existing', {
        'to_user_id': toUserId,
        'relation': relation,
        if (customLabel != null && customLabel.isNotEmpty)
          'custom_label': customLabel,
      });

  /// Invite a NON-user via a signed share-link. Returns a descriptor for the OS
  /// share sheet: `{text{bn,en}?, url, token, auto_sent:false}`. The server
  /// never sends anything.
  Future<Map<String, dynamic>> inviteShareLink({required String relation}) =>
      postJson('/messenger/invite/share-link', {'relation': relation});

  /// Invite a NON-user by own-SIM SMS. Returns an `sms:` URI descriptor
  /// `{sms_uri, body, auto_sent:false, uses_gateway:false}` — the CLIENT opens
  /// the device composer and the USER presses Send. No gateway, never auto-send.
  Future<Map<String, dynamic>> inviteSms({
    required String relation,
    required String toNumber,
  }) =>
      postJson('/messenger/invite/sms', {
        'relation': relation,
        'to_number': toNumber,
      });

  // ======================= connection requests ==========================

  /// Send a personal connection request. Relation is MANDATORY; an optional
  /// one-line [note] is the single pre-accept message. Enforces no-self and the
  /// per-user daily limit server-side (the N+1 send is blocked).
  Future<Map<String, dynamic>> connectionRequest({
    required int targetId,
    required String relation,
    String? customLabel,
    String? note,
  }) =>
      postJson('/messenger/request', {
        'target_id': targetId,
        'relation': relation,
        if (customLabel != null && customLabel.isNotEmpty)
          'custom_label': customLabel,
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      });

  /// Act on a connection request. [event] ∈ accept|decline|cancel|block.
  /// 2b fix (guarded server-side): the sender can only CANCEL their own
  /// outgoing request; only the recipient may accept/decline an incoming one.
  Future<Map<String, dynamic>> connectionAct({
    required int requestId,
    required String event,
  }) =>
      postJson('/messenger/request/$requestId/act', {'event': event});

  /// Send the ONE pre-accept note on a request. A second note / any other
  /// pre-accept message is rejected server-side (`can_send_before_accept`).
  Future<Map<String, dynamic>> connectionMessage({
    required int requestId,
    required String note,
  }) =>
      postJson('/messenger/request/$requestId/message', {'note': note});

  /// Report (and optionally block) the other party on a request.
  Future<Map<String, dynamic>> connectionReport({
    required int requestId,
    required String action,
    required String reason,
    String? note,
  }) =>
      postJson('/messenger/request/$requestId/report', {
        'action': action,
        'reason': reason,
        if (note != null && note.isNotEmpty) 'note': note,
      });

  // ======================= messenger profile (/me) ======================

  /// Read the full profile incl. messenger fields (`photo`, `photo_link`,
  /// `bio`, `show_phone`, `communities_who_can_msg`). Uses the raw `/me` map so
  /// the messenger-only fields survive even though the typed [AppUser] model
  /// doesn't carry them yet. The matching WRITE is the core client's typed
  /// `updateProfile(fields)` (PATCH /me) — the screen calls that directly, then
  /// re-reads here to pick up the messenger-only fields.
  Future<Map<String, dynamic>> messengerProfile() => getJson('/me');
}
