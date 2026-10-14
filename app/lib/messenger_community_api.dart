import 'api.dart';

/// Assisto Messenger — COMMUNITIES client surface (Step 3).
///
/// Implemented as an EXTENSION on [ApiClient] built ONLY on its public
/// `getJson` / `postJson` helpers, so this module ships WITHOUT editing the
/// shared api.dart. Every method maps 1:1 to a backend route in
/// `.phaseB/msg_community_integration.md`; each route delegates to a pure
/// function in `core/logic/msg_community.py`, which is the SERVER-SIDE
/// authority. The client can never grant itself a capability, skip the
/// message-request consent flow, reveal a hidden phone, or exceed the rate
/// limit — all of that is enforced on the server; these calls only express a
/// *request*.
///
/// VERB NOTE: the spec marks several routes as PATCH (group rules/size,
/// show-phone, who-can-message). ApiClient exposes only `getJson`/`postJson`
/// publicly, so this extension POSTs those bodies; the integrator maps the
/// route to its PATCH handler. Paths are authoritative and match the backend
/// route style (NO trailing slash).
///
/// Localisation: ApiClient already sends `Accept-Language: bn|en`, so any
/// server-rendered text follows the selected locale. Messages (direct + the
/// first message held in a message request) are the same opaque E2E ciphertext
/// envelope as 1:1 / groups — the server stores ciphertext only.
extension MessengerCommunityApi on ApiClient {
  // ---- Community + groups ----

  /// POST /community/create -> new_community
  /// body: {name, description, photo_ref?}
  /// -> {community, announcements_group, member}
  Future<Map<String, dynamic>> communityCreate(
    String name, {
    String description = '',
    String? photoRef,
  }) =>
      postJson('/community/create', {
        'name': name,
        'description': description,
        if (photoRef != null) 'photo_ref': photoRef,
      });

  /// POST /community/<id>/group/create -> new_community_group
  /// body: {name, kind(announcements|topic), join_mode(open|request),
  ///        description?, photo_ref?}
  Future<Map<String, dynamic>> communityGroupCreate(
    String communityId, {
    required String name,
    String kind = 'topic',
    String joinMode = 'request',
    String description = '',
    String? photoRef,
  }) =>
      postJson('/community/$communityId/group/create', {
        'name': name,
        'kind': kind,
        'join_mode': joinMode,
        'description': description,
        if (photoRef != null) 'photo_ref': photoRef,
      });

  /// PATCH /community/group/<id> (rules / size / join_mode / announcements) ->
  /// set_group_rules / set_group_size_limit (admin capability check server-side).
  /// Only the keys the caller changes are sent.
  Future<Map<String, dynamic>> communityGroupUpdate(
    String groupId, {
    String? rules,
    int? sizeLimit,
    String? joinMode,
    bool? announcementsOnly,
  }) =>
      patchJson('/community/group/$groupId', {
        if (rules != null) 'rules': rules,
        if (sizeLimit != null) 'size_limit': sizeLimit,
        if (joinMode != null) 'join_mode': joinMode,
        if (announcementsOnly != null) 'announcements_only': announcementsOnly,
      });

  /// GET /community/<id>/groups -> partition_groups for the caller
  /// -> {joined: [...], joinable: [...], requested: [...]}
  Future<Map<String, dynamic>> communityGroups(String communityId) =>
      getJson('/community/$communityId/groups');

  // ---- Join flow ----

  /// POST /community/group/<id>/join -> request_to_join
  /// -> {allowed, action('joined'|'requested'), reason}
  /// open group = joined now; request group = a JoinRequest is created.
  Future<Map<String, dynamic>> communityGroupJoin(String groupId) =>
      postJson('/community/group/$groupId/join');

  /// POST /community/join-request/<id>/approve -> can_approve_join + apply_join_event
  Future<Map<String, dynamic>> joinRequestApprove(String requestId) =>
      postJson('/community/join-request/$requestId/approve');

  /// POST /community/join-request/<id>/reject -> apply_join_event
  Future<Map<String, dynamic>> joinRequestReject(String requestId) =>
      postJson('/community/join-request/$requestId/reject');

  /// POST /community/group/<id>/member/<uid>/remove ->
  /// can_remove_community_member (last-admin protected server-side).
  Future<Map<String, dynamic>> communityMemberRemove(
    String groupId,
    String memberUid,
  ) =>
      postJson('/community/group/$groupId/member/$memberUid/remove');

  // ---- Posting ----

  /// POST /community/group/<id>/post -> can_post_in_group gate (announcements
  /// group / announcements-only topic = admins only) then the ciphertext relay.
  /// body carries the opaque E2E envelope (server stores ciphertext only).
  Future<Map<String, dynamic>> communityGroupPost(
    String groupId,
    Map<String, dynamic> envelope,
  ) =>
      postJson('/community/group/$groupId/post', envelope);

  // ---- Members (phone privacy) ----

  /// GET /community/<id>/members -> member_card per member.
  /// Each card: {member_id, name, photo_ref, phone|null, phone_hidden, role}.
  /// Phone is hidden unless the member opted in (show_phone) or it is self.
  Future<Map<String, dynamic>> communityMembers(String communityId) =>
      getJson('/community/$communityId/members');

  // ---- My privacy settings ----

  /// PATCH /me/show-phone -> set_show_phone (opt-in; default hidden).
  Future<Map<String, dynamic>> setShowPhone(bool show) =>
      patchJson('/me/show-phone', {'show_phone': show});

  /// PATCH /me/communities-who-can-msg -> stored, read by can_direct_message.
  /// value: 'everyone' (default) | 'nobody'.
  Future<Map<String, dynamic>> setCommunitiesWhoCanMsg(String value) =>
      patchJson('/me/communities-who-can-msg', {'who_can_msg': value});

  /// GET /me/communities-who-can-msg -> current {who_can_msg, show_phone}.
  Future<Map<String, dynamic>> communitiesWhoCanMsg() =>
      getJson('/me/communities-who-can-msg');

  // ---- Messaging consent (the core gate) ----

  /// POST /community/message -> check_msgreq_rate then can_direct_message.
  /// Response carries `route`:
  ///   'direct'          -> normal 1:1 relay (connected / already accepted)
  ///   'message_request' -> a CommunityMessageRequest was created (first contact
  ///                        from outside the recipient's circle)
  /// On refusal the body carries a `reason` (blocked / not_in_community /
  /// who_nobody). On HTTP 429 the server is rate-limiting — see
  /// [ApiException.status] == 429 and surface the friendly wait message.
  ///
  /// body carries the opaque first-message envelope (ciphertext only).
  Future<Map<String, dynamic>> communityMessage({
    required String communityId,
    required String recipientId,
    required Map<String, dynamic> envelope,
  }) =>
      postJson('/community/message', {
        'community_id': communityId,
        'recipient_id': recipientId,
        'envelope': envelope,
      });

  /// POST /community/message-request/<id>/accept -> apply_msgreq_event.
  /// After accept the recipient holds prior_request_state=accepted, so the next
  /// direct message routes 'direct' and calls become allowed.
  Future<Map<String, dynamic>> messageRequestAccept(String requestId) =>
      postJson('/community/message-request/$requestId/accept');

  /// POST /community/message-request/<id>/decline -> apply_msgreq_event.
  Future<Map<String, dynamic>> messageRequestDecline(String requestId) =>
      postJson('/community/message-request/$requestId/decline');

  /// POST /community/message-request/<id>/block -> apply_msgreq_event.
  Future<Map<String, dynamic>> messageRequestBlock(String requestId) =>
      postJson('/community/message-request/$requestId/block');

  /// POST /community/message-request/<id>/report -> report_sender.
  Future<Map<String, dynamic>> messageRequestReport(
    String requestId, {
    required String reason,
    String note = '',
    bool alsoBlock = false,
  }) =>
      postJson('/community/message-request/$requestId/report', {
        'reason': reason,
        'note': note,
        'also_block': alsoBlock,
      });

  // ---- Calls ----

  /// POST /community/call -> can_call (REFUSED before acceptance; no calls
  /// until a message request is accepted / the relationship is connected).
  Future<Map<String, dynamic>> communityCall(String recipientId) =>
      postJson('/community/call', {'recipient_id': recipientId});
}
