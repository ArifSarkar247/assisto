# Messenger — CHANNELS — integrator TODO (34 tests pass)

NEW `backend/core/logic/msg_channel.py` (+ tests `msg_channel_tests_snippets.py`, 34 pass, run:
`cd backend && python3 -c "import core.logic.msg_channel_tests_snippets as t; t.run_all()"`).
Pure logic, no Django/DB/AI. ORIGINAL design, benchmark WhatsApp Channels — no UI/copy/asset reuse.
ARB: apply `.phaseB/msg_channel_arb.json`. Placeholders `{count}` as String (channelFollowerCount, channelHiddenPrivate, channelViews, channelReactions, channelPollVotes).

## CRITICAL INVARIANT — enforce at the serializer, never at the client
Channel content is **NOT E2E** (public + moderatable, stored PLAINTEXT, scheme `plaintext-moderatable-v1`).
This is the deliberate opposite of personal chats / private groups (which stay E2E — DO NOT TOUCH `core.logic.circle*`
or the ciphertext relay). `msg_channel.is_e2e_surface()`/`post_is_e2e()` return False as machine-checkable guards;
`validate_post` REJECTS any post with `e2e=True`.

Follower privacy is server-enforced in `serialize_follower_list(channel, followers, viewer_id, limit, offset)`:
a `count_only` follower is NEVER returned to ANY viewer (owner/admin included) but ALWAYS increments the count.
Per-follower default visibility is `count_only`. The follower LIST is owner-controlled public/private; private blocks
non-owner/admin enumeration but still exposes the count. NEVER build a follower response any other way.

## MIGRATION (core models — integrator owns these)
- `Channel(owner FK, name≤80, handle unique≤32 [a-z0-9_], description≤500, photo_ref null, category enum,
  language enum[bn|en|other], list_visibility[public|private] DEFAULT private, verified bool DEFAULT False,
  verified_by FK operator null, verification_state[none|pending|verified], follower_count int DEFAULT 0, created_at)`.
  `verified`/`verified_by`/`follower_count` are SERVER-ONLY — never writable via the profile editor
  (`sanitize_profile_edit` strips them).
- `ChannelAdmin(channel FK, user FK, added_at; unique(channel,user))` — mirrors `admin_ids`; cap `MAX_ADMINS=20`.
- `ChannelFollower(channel FK, user FK, visibility[show|count_only] DEFAULT count_only, muted bool DEFAULT False,
  followed_at; unique(channel,user))`. follower_count == COUNT(followers) incl. count_only.
- `ChannelPost(channel FK, author FK, kind[text|photo|video|link|poll], e2e bool=False CHECK(e2e=False),
  content_scheme='plaintext-moderatable-v1', text TEXT, media_refs JSON, link_url null, poll_id null, views int=0,
  pinned bool, deleted bool, created_at)`. PLAINTEXT — moderatable.
- `ChannelPostReaction` → store AGGREGATE per-emoji count only (`{emoji:count}` on the post), NOT per-reactor rows,
  so reactions can't be used to enumerate / de-anonymise followers.
- `ChannelPoll(channel FK, question, options JSON, option_count, multi bool, closed bool, created_at)` +
  `ChannelPollVote(poll FK, voter FK, choices JSON list[int]; unique(poll,voter) re-vote replaces)`. Tally BY INDEX.
- `ChannelVerificationRequest(channel FK, state, requested_at)` optional audit of request_verification.

## Endpoints (ALL via msg_channel fns — server authority)
- `/channels` list/create (`new_channel`; raises name_required/handle_required → 400).
- `/channels/<id>` get / edit (`sanitize_profile_edit` — whitelist only).
- `/channels/<id>/admins` add/remove (`add_admin`/`remove_admin`, OWNER-only).
- `/channels/<id>/follow` (`follow`, default count_only) / `/unfollow` (`unfollow`) / `/mute` (`set_muted`).
- `/channels/<id>/my-visibility` POST show|count_only (`set_follower_visibility` — the follower's OWN record only).
- `/channels/<id>/list-visibility` POST public|private (`set_list_visibility`, OWNER-only).
- `/channels/<id>/followers` GET → `serialize_follower_list(channel, roster, viewer_id, limit, offset)`.
  Returns `{count, listable, followers:[{user_id,muted}], list_visibility, hidden_count_only}`. count_only NEVER in `followers`.
- `/channels/<id>/posts` list / create (`new_post`, publish gate `can_publish`; REJECT e2e). React:
  `/posts/<pid>/react` (`add_reaction`/`remove_reaction` — aggregate). View: `record_view` (no viewer id). Pin: admin cap.
- `/channels/<id>/polls` (`new_channel_poll`/`validate_vote`/`apply_vote`/`tally_poll`/`close_poll`) — tally by index.
- `/channels/<id>/analytics` → `channel_analytics(channel, posts, follower_count_series)` — COUNTS ONLY, `contains_pii=False`.
- `/channels/<id>/verify/request` (`request_verification`, OWNER→pending only) and operator-only
  `/admin/channels/<id>/verify/grant|revoke` (`grant_verification`/`revoke_verification`, `is_platform_operator=True`).
  `is_verified` requires BOTH flag AND a recorded operator approver — a forged flag reads as NOT verified.
- `/channels/<id>/share-link` (`make_share_link`) / resolve (`parse_share_link`).

## HOOKS (client)
- Followers get READ + REACT only. NO reply box, NO comment field, NO "message admin" on the channel surface
  (`can_follower_reply`/`can_follower_dm_admin` always False — don't render those affordances).
- Follower-visibility toggle in channel settings: "Show that I follow" vs "Count me only" (default count-only; copy below).
- Verified badge rendered ONLY when `is_verified(channel)` true (operator-granted). No self-grant UI; owner only sees
  "Request verification" → pending.
- Analytics screen consumes aggregates only (views / reactions / follower-growth); never list individual followers there.
- Channel chat clearly labelled NOT end-to-end encrypted (contrast with E2E personal/group chats).

PENDING Messenger reviewer. NOTE: original spec listed public channels as owner-decision-later; now built as
ORIGINAL feature with the follower-privacy + not-E2E safeguards above; personal/group E2E untouched.
