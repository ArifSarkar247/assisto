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

  /// POST /circle/groups/<id>/mute {duration} -> {ok, muted, mute,
  /// muted_until}. duration ∈ `8h` | `1w` | `always` | `off`. The server's
  /// group push hook skips a member who muted the group.
  Future<Map<String, dynamic>> groupSetMute(String groupId, String duration) =>
      postJson('/circle/groups/$groupId/mute', {'duration': duration});

  // ========================= group ⋮ : disappearing ======================

  /// POST /circle/groups/<id>/disappearing {ttl} -> {ttl}. ttl ∈ `off` | `24h`
  /// | `7d` | `90d`. Server + device enforced (circle_extras disappearing);
  /// applies to every member's future messages in this group.
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
          // ⋮ theme degrades to "pending" until the server endpoint lands.
      postJson('/circle/groups/$groupId/theme', {
        if (color != null) 'color': color,
        if (wallpaper != null) 'wallpaper': wallpaper,
      });

  // ========================= group ⋮ : favourites ========================

  /// POST /circle/groups/<id>/favourite {on} -> {favourite}. Feeds the hub
  /// "Favourites" filter chip (circle_extras favourites).
  Future<Map<String, dynamic>> groupSetFavourite(String groupId, bool on) =>
      postJson('/circle/groups/$groupId/favourite', {'on': on});

  // ========================= group ⋮ : export ============================

  /// GET /circle/groups/<id>/export?media=bool -> {url, filename, expires_at,
  /// message_count, encrypted:true, media_included:false}. `url` is a SIGNED,
  /// expiring media link to a JSON file holding only what the server has
  /// (metadata + the caller's own ciphertext envelopes); the device decrypts
  /// it and builds the readable .txt it shares (see group_export.dart).
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
      postJson('/messenger/call-link', {'kind': kind});

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
      postJson('/messenger/schedule-call', {
        'invitee_member_ids': inviteeMemberIds,
        'scheduled_at': at,
        'kind': kind,
      });

  // ========================= group ⋮ : Assisto extras ====================

  /// POST /circle/groups/<id>/ai/<task> {messages, target_lang?} -> always
  /// 200: {allowed:true, result, reminder?} or {allowed:false, reason,
  /// needs_plan, message}. task ∈ `summarise` | `translate` | `reminder`. The
  /// AI sees ONLY the text the user decrypted on this device and sends with
  /// the tap; credits + the no-key state are the server's (ai.generate).
  Future<Map<String, dynamic>> groupAiTask(
    String groupId,
    String task, {
    List<String> messages = const [],
    String targetLang = '',
  }) =>
          // group ⋮ AI tasks degrade to "needs key / pending" until it lands.
      postJson('/circle/groups/$groupId/ai/$task', {
        'messages': messages,
        if (targetLang.isNotEmpty) 'target_lang': targetLang,
      });

  // ========================= community detail ⋮ ==========================

  /// POST /community/<id>/notifications {muted} -> {ok, notifications_muted}.
  /// Stored per member. The server does not push community posts yet, so the
  /// detail ⋮ shows this as an honest disabled item.
  Future<Map<String, dynamic>> communitySetNotifications(
          String communityId, bool muted) =>
      postJson('/community/$communityId/notifications', {'muted': muted});

  /// POST /community/<id>/leave -> {left, allowed, reason?}. LAST-ADMIN
  /// protected: a refusal is a 200 with allowed:false, reason
  /// 'promote_before_leaving'.
  Future<Map<String, dynamic>> communityLeave(String communityId) =>
      postJson('/community/$communityId/leave');

  /// POST /circle/groups/<id>/clear {} -> {ok, cleared_at}: hide the history
  /// for THIS user only (per-user marker; other members keep theirs).
  Future<Map<String, dynamic>> groupClear(String groupId) =>
      postJson('/circle/groups/$groupId/clear', const {});

  // ========================= channel detail ⋮ ============================
  // (follow / unfollow / mute / my-visibility / share-link already live in
  //  MessengerChannelApi; nothing added here so there is no duplicate path.)
}
