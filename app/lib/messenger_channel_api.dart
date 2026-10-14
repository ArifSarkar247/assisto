import 'api.dart';

/// Assisto Messenger — CHANNELS + DISCOVERY API surface (Messenger Step 3).
///
/// Implemented as an EXTENSION on [ApiClient] built ONLY on the public
/// getJson / postJson helpers (+ the shared Accept-Language header), so these
/// screens ship WITHOUT editing api.dart — the integrator SHOULD later fold
/// these into ApiClient proper; the signatures + paths below are authoritative.
/// Every path is under `api/v1/` (AppConfig prepends `/api/v1`).
///
/// CRITICAL INVARIANTS (server-enforced — the client NEVER relaxes them):
///  * Channel content is PUBLIC + moderatable, scheme `plaintext-moderatable-v1`
///    — it is NOT end-to-end encrypted (the deliberate opposite of personal
///    chats / private groups, which stay E2E). We never set `e2e` on a post.
///  * Follower privacy: a `count_only` follower is NEVER returned by
///    `channelFollowers` to ANY viewer (owner/admin included) but ALWAYS
///    increments the count. Per-follower default visibility is `count_only`.
///  * Followers get READ + REACT only — there is no reply/comment/DM-admin path
///    on the server, so the UI must never render those affordances.
///  * `is_verified` requires BOTH a flag AND a recorded operator approver; the
///    owner can only `channelRequestVerification` (→ pending). No self-grant.
///
/// The server returns pre-formatted `{bn,en}` display pairs where it already
/// owns the wording; the UI shows those directly and never re-translates them.
extension MessengerChannelApi on ApiClient {
  // ========================= channels (list / create) =====================

  /// GET /channels -> {following:[channel], suggested:[channel]}. A `channel`
  /// is {id, name, handle, description, photo_ref?, category, language,
  /// follower_count, is_verified, verification_state, list_visibility,
  /// is_owner, is_admin, my_following:bool, my_muted:bool,
  /// my_visibility[show|count_only]}. Suggested are surfaced from the viewer's
  /// chosen interests / language / public popularity — NEVER from private
  /// messages or contacts (server guarantee; surfaced in the UI note).
  Future<Map<String, dynamic>> channelList() => getJson('/channels');

  /// POST /channels {name, handle, description?, category?, language?} -> the
  /// created channel (viewer becomes owner + first admin). `new_channel` raises
  /// name_required / handle_required -> 400.
  Future<Map<String, dynamic>> channelCreate({
    required String name,
    required String handle,
    String description = '',
    String category = '',
    String language = '',
  }) =>
      postJson('/channels', {
        'name': name,
        'handle': handle,
        'description': description,
        if (category.isNotEmpty) 'category': category,
        if (language.isNotEmpty) 'language': language,
      });

  // ========================= one channel (get / edit) =====================

  /// GET /channels/<id> -> {channel, posts:[post], can_publish:bool}. A `post`
  /// is {id, kind[text|photo|video|link|poll], text, media_refs[], link_url?,
  /// poll?, reactions:{emoji:count}, my_reaction?, views, pinned, created_at}.
  /// A poll is {id, question, options:[String], multi, closed, tally:[int],
  /// total_votes, my_choices:[int]}. content_scheme is always
  /// `plaintext-moderatable-v1` — NOT E2E.
  Future<Map<String, dynamic>> channelGet(int id) => getJson('/channels/$id');

  /// POST /channels/<id> (edit; the backend whitelists via `sanitize_profile_edit`
  /// — `verified` / `verified_by` / `follower_count` are stripped server-side and
  /// must never be sent). Only name / description / category / language /
  /// photo_ref are editable. Returns the updated channel. (No public patch
  /// helper on ApiClient, so edits POST to the same path per the backend spec.)
  Future<Map<String, dynamic>> channelEdit(
    int id, {
    String? name,
    String? description,
    String? category,
    String? language,
    String? photoRef,
  }) =>
      patchJson('/channels/$id', {
        if (name != null) 'name': name,
        if (description != null) 'description': description,
        if (category != null) 'category': category,
        if (language != null) 'language': language,
        if (photoRef != null) 'photo_ref': photoRef,
      });

  // ========================= admins (owner-only) ==========================

  /// GET /channels/<id>/admins -> {admins:[{user_id, name, is_owner}]}.
  Future<Map<String, dynamic>> channelAdmins(int id) =>
      getJson('/channels/$id/admins');

  /// POST /channels/<id>/admins {user_id, action[add|remove]} -> updated admins.
  /// OWNER-only (server-enforced). Cap MAX_ADMINS=20.
  Future<Map<String, dynamic>> channelSetAdmin({
    required int id,
    required int userId,
    required String action,
  }) =>
      postJson('/channels/$id/admins', {'user_id': userId, 'action': action});

  // ========================= follow / mute ================================

  /// POST /channels/<id>/follow -> updated channel. Default follower visibility
  /// is `count_only` (set server-side); the UI can change it afterwards via
  /// [channelMyVisibility].
  Future<Map<String, dynamic>> channelFollow(int id) =>
      postJson('/channels/$id/follow');

  /// POST /channels/<id>/unfollow -> updated channel.
  Future<Map<String, dynamic>> channelUnfollow(int id) =>
      postJson('/channels/$id/unfollow');

  /// POST /channels/<id>/mute {muted} -> updated channel. Mutes new-post alerts
  /// without unfollowing.
  Future<Map<String, dynamic>> channelSetMuted(int id, bool muted) =>
      postJson('/channels/$id/mute', {'muted': muted});

  // ========================= follower privacy =============================

  /// POST /channels/<id>/my-visibility {visibility[show|count_only]} -> updated
  /// channel. Sets the FOLLOWER'S OWN record only. `count_only` (the default)
  /// means the follower's name is shown to NO ONE — not even the owner — while
  /// still counting toward follower_count. Changeable anytime.
  Future<Map<String, dynamic>> channelMyVisibility(int id, String visibility) =>
      postJson('/channels/$id/my-visibility', {'visibility': visibility});

  /// POST /channels/<id>/list-visibility {visibility[public|private]} -> updated
  /// channel. OWNER-only; controls whether the follower LIST may be enumerated.
  /// Private still exposes the count; it blocks non-owner/admin enumeration.
  Future<Map<String, dynamic>> channelListVisibility(
          int id, String visibility) =>
      postJson('/channels/$id/list-visibility', {'visibility': visibility});

  /// GET /channels/<id>/followers?limit=&offset= ->
  /// {count, listable, followers:[{user_id, name?, muted}], list_visibility,
  /// hidden_count_only}. `count_only` followers are NEVER in `followers`.
  Future<Map<String, dynamic>> channelFollowers(int id,
          {int limit = 50, int offset = 0}) =>
      getJson('/channels/$id/followers?limit=$limit&offset=$offset');

  // ========================= posts ========================================

  /// GET /channels/<id>/posts?limit=&offset= -> {posts:[post]}.
  Future<Map<String, dynamic>> channelPosts(int id,
          {int limit = 30, int offset = 0}) =>
      getJson('/channels/$id/posts?limit=$limit&offset=$offset');

  /// POST /channels/<id>/posts -> the created post. kind ∈ text|photo|video|
  /// link|poll. We NEVER send `e2e` — channel posts are plaintext-moderatable
  /// by design and the server REJECTS any post with e2e=true. Poll posts pass
  /// {question, options:[String], multi} and the server creates the poll.
  Future<Map<String, dynamic>> channelCreatePost({
    required int id,
    required String kind,
    String text = '',
    List<String> mediaRefs = const [],
    String? linkUrl,
    String? pollQuestion,
    List<String> pollOptions = const [],
    bool pollMulti = false,
  }) =>
      postJson('/channels/$id/posts', {
        'kind': kind,
        'text': text,
        if (mediaRefs.isNotEmpty) 'media_refs': mediaRefs,
        if (linkUrl != null && linkUrl.isNotEmpty) 'link_url': linkUrl,
        if (kind == 'poll') 'question': pollQuestion ?? '',
        if (kind == 'poll') 'options': pollOptions,
        if (kind == 'poll') 'multi': pollMulti,
      });

  /// POST /channels/<id>/posts/<pid>/react {emoji, on} -> updated aggregate
  /// {reactions:{emoji:count}, my_reaction?}. `on=false` removes. Reactions are
  /// stored as per-emoji COUNTS only (never per-reactor rows), so they cannot be
  /// used to enumerate / de-anonymise followers.
  Future<Map<String, dynamic>> channelReact({
    required int id,
    required int postId,
    required String emoji,
    required bool on,
  }) =>
      postJson(
          '/channels/$id/posts/$postId/react', {'emoji': emoji, 'on': on});

  /// POST /channels/<id>/posts/<pid>/view -> {}. Records a view with NO viewer
  /// id (aggregate count only).
  Future<Map<String, dynamic>> channelRecordView(
          {required int id, required int postId}) =>
      postJson('/channels/$id/posts/$postId/view');

  /// POST /channels/<id>/posts/<pid>/pin {pinned} -> updated post. Admin-only;
  /// server caps the number of pinned posts.
  Future<Map<String, dynamic>> channelPinPost({
    required int id,
    required int postId,
    required bool pinned,
  }) =>
      postJson('/channels/$id/posts/$postId/pin', {'pinned': pinned});

  // ========================= polls ========================================

  /// POST /channels/<id>/polls/<pollId>/vote {choices:[int]} -> updated poll
  /// {tally:[int], total_votes, my_choices, closed}. Votes are BY INDEX; a
  /// re-vote replaces the previous choice. Single-choice polls send one index.
  Future<Map<String, dynamic>> channelPollVote({
    required int id,
    required int pollId,
    required List<int> choices,
  }) =>
      postJson('/channels/$id/polls/$pollId/vote', {'choices': choices});

  /// POST /channels/<id>/polls/<pollId>/close -> updated poll (admin-only).
  Future<Map<String, dynamic>> channelPollClose(
          {required int id, required int pollId}) =>
      postJson('/channels/$id/polls/$pollId/close');

  /// GET /channels/<id>/polls/<pollId>/tally -> {tally:[int], total_votes,
  /// closed}. Tally BY INDEX.
  Future<Map<String, dynamic>> channelPollTally(
          {required int id, required int pollId}) =>
      getJson('/channels/$id/polls/$pollId/tally');

  // ========================= analytics ====================================

  /// GET /channels/<id>/analytics -> {total_views, total_reactions,
  /// follower_growth:[{day, count}], contains_pii:false}. COUNTS ONLY — the
  /// server guarantees no PII; the screen never lists individual followers.
  Future<Map<String, dynamic>> channelAnalytics(int id) =>
      getJson('/channels/$id/analytics');

  // ========================= verification =================================

  /// POST /channels/<id>/verify/request -> updated channel
  /// (verification_state -> pending). OWNER-only. There is NO self-grant path;
  /// only a platform operator can grant, out of band.
  Future<Map<String, dynamic>> channelRequestVerification(int id) =>
      postJson('/channels/$id/verify/request');

  // ========================= share link ===================================

  /// GET /channels/<id>/share-link -> {url, handle}. A public, shareable link
  /// (`make_share_link`) the owner/follower can send to other apps / show as QR.
  Future<Map<String, dynamic>> channelShareLink(int id) =>
      getJson('/channels/$id/share-link');

  // ========================= discovery ====================================

  /// GET /channels/discover?q=&category=&language= ->
  /// {results:[channel], suggested:[channel], categories:[String]}. `suggested`
  /// comes from chosen interests / language / public popularity — NEVER from
  /// private messages or contacts (server guarantee, stated in the UI). An empty
  /// query with a category filters by category; no filters returns suggestions.
  Future<Map<String, dynamic>> channelDiscover({
    String query = '',
    String category = '',
    String language = '',
  }) {
    final qp = <String>[];
    if (query.isNotEmpty) qp.add('q=${Uri.encodeQueryComponent(query)}');
    if (category.isNotEmpty) {
      qp.add('category=${Uri.encodeQueryComponent(category)}');
    }
    if (language.isNotEmpty) {
      qp.add('language=${Uri.encodeQueryComponent(language)}');
    }
    final suffix = qp.isEmpty ? '' : '?${qp.join('&')}';
    return getJson('/channels/discover$suffix');
  }
}
