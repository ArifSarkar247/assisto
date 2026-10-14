import 'api.dart';

/// Assisto Messenger — GROUP CHAT ⋮ + COMMUNITY/CHANNEL detail ⋮ client surface.
///
/// Implemented as an EXTENSION on [ApiClient] built ONLY on the public
/// getJson / postJson helpers (+ the shared Accept-Language header), so the
/// group ⋮ and the community/channel detail ⋮ ship WITHOUT editing api.dart —
/// the integrator SHOULD later fold these into ApiClient proper; the signatures
/// + paths below are authoritative. Every path is under `api/v1/` (AppConfig
/// prepends `/api/v1`).
///
/// These MIRROR the 1:1 chat contract (circle_messaging / circle_extras) but
/// scoped to a GROUP, plus the few community/channel-detail-⋮ actions the
/// detail screens need. The server is the authority for every capability —
/// the client only expresses a request:
///   * group VIDEO call requires a Premium INITIATOR (can_place_group_call);
///     the client reads {allowed, needs_video_plan} and never self-grants.
///   * Exit group is LAST-ADMIN protected server-side (can_leave_group): the
///     last admin must promote someone first; the UI surfaces the refusal.
///   * Report funnels into the one moderation engine (/moderation/report via
///     [MsgrReportSheet]) — no private report path.
///   * Channel FOLLOWERS have READ + REACT only — there is NO reply/DM path on
///     the server, so these helpers never expose one.
extension MessengerGroupApi on ApiClient {
  // ========================= group ⋮ : mute ===============================

  /// POST /circle/groups/<id>/mute {duration} -> {muted_until?}. duration ∈
  /// `8h` | `1w` | `always`. Mirrors circle_extras mute semantics; silences the
  /// group's notifications without leaving. `off` clears the mute.
  // TODO(backend): no `messenger/groups/<id>/mute` route exists; the group ⋮
  // mute degrades to an honest "pending" state until the server endpoint lands.
  Future<Map<String, dynamic>> groupSetMute(String groupId, String duration) =>
      postJson('/circle/groups/$groupId/mute', {'duration': duration});

  // ========================= group ⋮ : disappearing ======================

  /// POST /circle/groups/<id>/disappearing {ttl} -> {ttl}. ttl ∈ `off` | `24h`
  /// | `7d` | `90d`. Server + device enforced (circle_extras disappearing);
  /// applies to every member's future messages in this group.
  // TODO(backend): no `messenger/groups/<id>/disappearing` route exists; the
  // group ⋮ disappearing timer degrades to "pending" until the endpoint lands.
  Future<Map<String, dynamic>> groupSetDisappearing(
          String groupId, String ttl) =>
      postJson('/circle/groups/$groupId/disappearing', {'ttl': ttl});

  // ========================= group ⋮ : theme =============================

  /// POST /circle/groups/<id>/theme {color?, wallpaper?} -> persisted per-group
  /// theme (circle_extras per-chat theme). Only the keys the caller changes are
  /// sent; a null clears that field.
  Future<Map<String, dynamic>> groupSetTheme(
    String groupId, {
    String? color,
    String? wallpaper,
  }) =>
      // TODO(backend): no `messenger/groups/<id>/theme` route exists; the group
      // ⋮ theme degrades to "pending" until the server endpoint lands.
      postJson('/circle/groups/$groupId/theme', {
        if (color != null) 'color': color,
        if (wallpaper != null) 'wallpaper': wallpaper,
      });

  // ========================= group ⋮ : favourites ========================

  /// POST /circle/groups/<id>/favourite {on} -> {favourite}. Feeds the hub
  /// "Favourites" filter chip (circle_extras favourites).
  // TODO(backend): no `messenger/groups/<id>/favourite` route exists; the group
  // ⋮ favourite toggle degrades to "pending" until the endpoint lands.
  Future<Map<String, dynamic>> groupSetFavourite(String groupId, bool on) =>
      postJson('/circle/groups/$groupId/favourite', {'on': on});

  // ========================= group ⋮ : export ============================

  /// GET /circle/groups/<id>/export?media=bool -> {url, filename} for a .txt
  /// (± media) export the client then hands to the OS share sheet
  /// (circle_extras export). The server builds the archive; plaintext is only
  /// assembled from the caller's already-decrypted copy on device where E2E
  /// requires — the integrator wires the on-device assembly.
  // TODO(backend): no `messenger/groups/<id>/export` route exists; the group ⋮
  // export degrades to "pending" until the server endpoint lands.
  Future<Map<String, dynamic>> groupExport(String groupId,
          {bool withMedia = false}) =>
      getJson('/circle/groups/$groupId/export?media=$withMedia');

  // ========================= group ⋮ : call links / schedule =============

  /// POST /circle/groups/<id>/call-link -> {url, expires_at}. An EXPIRING link
  /// anyone in the group can tap to join (circle_calls call-links).
  Future<Map<String, dynamic>> groupCallLink(String groupId,
          {String kind = 'voice'}) =>
      // Backend `messenger/call-link` is not group-scoped and takes only {kind};
      // it mints an expiring tokenized join link anyone can tap.
      postJson('messenger/call-link', {'kind': kind});

  /// POST /circle/groups/<id>/schedule-call {at, kind} -> the scheduled call
  /// (reminders fan out to all members — circle_calls scheduled-calls). `at` is
  /// an ISO-8601 instant; kind ∈ `voice` | `video` (video still Premium-gated
  /// at placement time).
  Future<Map<String, dynamic>> groupScheduleCall(
    String groupId, {
    required String at,
    String kind = 'voice',
    List<int> inviteeMemberIds = const [],
  }) =>
      // Backend `messenger/schedule-call` takes {invitee_member_ids,
      // scheduled_at, kind}; it builds reminders for every invitee + organiser.
      // (No per-group schedule route exists; this is the shared endpoint.)
      postJson('messenger/schedule-call', {
        'invitee_member_ids': inviteeMemberIds,
        'scheduled_at': at,
        'kind': kind,
      });

  // ========================= group ⋮ : Assisto extras ====================

  /// POST /circle/groups/<id>/ai/<task> {messages} -> {result}. task ∈
  /// `summarise` | `translate`. The AI runs ONLY on the caller's already-
  /// decrypted messages passed up here (the server AI never sees group
  /// ciphertext — circle.py ai_redaction); the integrator wires the on-device
  /// collection of plaintext before this call. Premium may gate the task
  /// server-side; the client reads {allowed, needs_plan}.
  Future<Map<String, dynamic>> groupAiTask(
    String groupId,
    String task, {
    List<String> messages = const [],
    String targetLang = '',
  }) =>
      // TODO(backend): no `messenger/groups/<id>/ai/<task>` route exists; the
      // group ⋮ AI tasks degrade to "needs key / pending" until it lands.
      postJson('/circle/groups/$groupId/ai/$task', {
        'messages': messages,
        if (targetLang.isNotEmpty) 'target_lang': targetLang,
      });

  // ========================= community detail ⋮ ==========================

  /// POST /community/<id>/notifications {muted} -> updated membership. Toggles
  /// the member's community-wide new-post alerts without leaving.
  // TODO(backend): no `community/<id>/notifications` route exists; the community
  // detail ⋮ notification toggle degrades to "pending" until it lands.
  Future<Map<String, dynamic>> communitySetNotifications(
          String communityId, bool muted) =>
      postJson('/community/$communityId/notifications', {'muted': muted});

  /// POST /community/<id>/leave -> {left}. LAST-ADMIN protected server-side
  /// (can_leave_community): the last admin must hand over first; the UI
  /// surfaces the refusal `reason`.
  // TODO(backend): no `community/<id>/leave` route exists; the community detail
  // ⋮ leave action degrades to "pending" until the server endpoint lands.
  Future<Map<String, dynamic>> communityLeave(String communityId) =>
      postJson('/community/$communityId/leave');

  // ========================= channel detail ⋮ ============================
  // (follow / unfollow / mute / my-visibility / share-link already live in
  //  MessengerChannelApi; nothing added here so there is no duplicate path.)
}
