import 'api.dart';

/// Assisto Messenger — 1:1 CHAT surface API (top-bar + ⋮ menu behaviours and
/// the Contact info screen).
///
/// Implemented as an EXTENSION on [ApiClient] so the 1:1 chat ships WITHOUT
/// editing `api.dart` core. Every method is built ONLY on the public, FIXED
/// generic helpers (`getJson` / `postJson`). Paths live under `/circle/...`
/// (AppConfig prepends `/api/v1`).
///
/// Every path below exists on the backend (core/views_m1_messenger.py and the
/// circle/messenger views); a failure surfaces as an [ApiException] the
/// screen shows honestly — there is no silent fallback.
///
/// PRIVACY INVARIANT: the server stores CIPHERTEXT ONLY and never reads chat
/// content. The ONE place plaintext leaves the device is an explicit user
/// Report: [reportLast5] uploads the last five messages the user DECRYPTED on
/// THIS device to moderation, with the user's chosen reason. Nothing else here
/// ever carries plaintext.
extension MessengerChatApi on ApiClient {
  // ======================= contact info ================================

  /// GET /circle/<peer>/info -> the contact-info payload
  /// `{about, phone, media_count, link_count, doc_count, starred_count,
  ///   groups_in_common:[{id,name}], encryption{scheme,fingerprint},
  ///   chat_lock{enabled}, muted_until, custom_notifications, relation,
  ///   custom_label}`.
  /// The phone is hidden server-side for a non-accepted peer who hid it.
  Future<Map<String, dynamic>> contactInfo(int peerId) =>
      getJson('/circle/$peerId/info');

  // ======================= mute ========================================

  /// POST /circle/<peer>/controls {muted_until} -> {..., muted_until}.
  /// [untilIso] is a UTC ISO-8601 instant, or null to unmute ("Always" sends a
  /// far-future instant). The push hook skips a muted chat.
  Future<Map<String, dynamic>> setChatMute(int peerId, String? untilIso) =>
      postJson('/circle/$peerId/controls', {'muted_until': untilIso});

  // ======================= disappearing messages ======================

  /// POST /circle/<peer>/settings {disappearing_sec} — 0 / 86400 / 604800 /
  /// 7776000 (Off / 24h / 7d / 90d). Server + device both enforce.
  Future<Map<String, dynamic>> setDisappearing(int peerId, int seconds) =>
      postJson('/messenger/chat/$peerId/settings', {'disappearing_sec': seconds});

  // ======================= chat theme / wallpaper =====================

  /// POST /circle/<peer>/settings {theme, wallpaper} — per-chat colour +
  /// wallpaper. Only disappearing_sec is server-authoritative; theme/wallpaper
  /// are persisted as opaque preferences (never a blob the server reads).
  Future<Map<String, dynamic>> setChatTheme(
    int peerId, {
    String? theme,
    String? wallpaper,
  }) =>
      postJson('/messenger/chat/$peerId/settings', {
        if (theme != null) 'theme': theme,
        if (wallpaper != null) 'wallpaper': wallpaper,
      });

  // ======================= favourites & custom lists ==================

  /// POST /circle/<peer>/controls {favourite} -> {..., favourite} — feeds the
  /// hub "Favourites" chip (stored per user, server-side).
  Future<Map<String, dynamic>> setFavourite(int peerId, bool on) =>
      postJson('/circle/$peerId/controls', {'favourite': on});

  /// GET /circle/lists -> {lists:[{id, name, member_ids}]} — the user's custom
  /// chat lists that become filter chips on the hub.
  Future<Map<String, dynamic>> chatLists() => getJson('/messenger/lists');

  /// Create a named list OR add/remove [peerId] on an existing [listId]:
  ///   * CREATE -> POST messenger/lists {name, member_refs:[peerId]}
  ///   * EDIT   -> POST messenger/lists/<id> {add:[peerId]} | {remove:[peerId]}
  /// (the backend splits create vs. edit across two routes).
  Future<Map<String, dynamic>> setChatList(
    int peerId, {
    String? name,
    int? listId,
    bool add = true,
  }) {
    if (listId != null) {
      return postJson('/messenger/lists/$listId', {
        if (add) 'add': [peerId] else 'remove': [peerId],
      });
    }
    return postJson('/messenger/lists', {
      if (name != null) 'name': name,
      'member_refs': [peerId],
    });
  }

  // ======================= calls: link / schedule =====================

  /// POST /circle/<peer>/call-link {kind, ttl_min} -> {link, token, expires_at}
  /// an EXPIRING join link. Reuses circle_calls plumbing; the backend mints the
  /// signed token. The client shares it via the OS share sheet.
  Future<Map<String, dynamic>> createCallLink(
    int peerId, {
    String kind = 'voice',
    int ttlMinutes = 60,
  }) =>
      // Backend `messenger/call-link` is NOT per-peer and takes only {kind};
      // the server mints an expiring tokenized link (ttl is server-controlled).
      postJson('/messenger/call-link', {'kind': kind});

  /// POST /circle/<peer>/schedule-call {kind, at, remind} -> {id, at, reminder}
  /// schedules a call at [atIso] and (optionally) sets a reminder for all
  /// invitees. Reuses the scheduled-calls endpoint.
  Future<Map<String, dynamic>> scheduleCall(
    int peerId, {
    required String atIso,
    String kind = 'voice',
    bool remind = true,
  }) =>
      // Backend `messenger/schedule-call` takes the invitee member ids (the peer
      // here), the ISO instant as `scheduled_at`, and `kind`. A reminder is
      // always built for every invitee server-side.
      postJson('/messenger/schedule-call', {
        'invitee_member_ids': [peerId],
        'scheduled_at': atIso,
        'kind': kind,
      });

  // ======================= close / clear / block ======================

  /// POST /circle/<peer>/controls {archived:true} — "Close chat" (keeps the
  /// entry, removes it from the active list). Reuses member controls.
  Future<Map<String, dynamic>> closeChat(int peerId) =>
      postJson('/circle/$peerId/controls', {'archived': true});

  /// POST /circle/<peer>/clear {} -> {ok, cleared_at}. Clear chat KEEPS the
  /// chat entry and hides every message up to now FOR THIS USER ONLY (a
  /// per-user marker; the peer's copy is untouched — E2E rows are never
  /// rewritten).
  Future<Map<String, dynamic>> clearChat(int peerId) =>
      postJson('/circle/$peerId/clear', const {});

  /// POST /circle/<peer>/controls {blocked:true} — silent two-way block.
  Future<Map<String, dynamic>> blockContact(int peerId, {bool on = true}) =>
      postJson('/circle/$peerId/controls', {'blocked': on});

  // ======================= report (last 5, decrypted on device) =======

  /// POST /circle/<peer>/report-last-5 {reason, note?, messages:[...]} ->
  /// moderation acknowledgement.
  ///
  /// THE ONLY plaintext upload in this layer, and only on an explicit user
  /// Report. [decryptedLastFive] is built ON THIS DEVICE from the last five
  /// messages the user already decrypted (newest last); each entry is
  /// `{id, text, mine, at}`. The server attaches them to the moderation case —
  /// it cannot reconstruct them otherwise (it holds ciphertext only).
  Future<Map<String, dynamic>> reportLast5({
    required int peerId,
    required String reason,
    String? note,
    required List<Map<String, dynamic>> decryptedLastFive,
  }) =>
      // Backend `messenger/chat/<member_id>/report` expects {categories:[],
      // note?, last_messages:[]}. The single [reason] maps to one category.
      postJson('/messenger/chat/$peerId/report', {
        'categories': [reason],
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
        'last_messages': decryptedLastFive,
      });
}
