# Assisto Messenger — COMMUNITIES integration (Step 3)

Pure logic: `backend/core/logic/msg_community.py`
Tests: `backend/core/logic/msg_community_tests_snippets.py` (34 tests, `run_all()`)
ARB: `.phaseB/msg_community_arb.json`

```
cd backend && python3 -c "import core.logic.msg_community_tests_snippets as t; t.run_all()"
# -> msg_community: 34 tests passed
```

This module is the SERVER-SIDE authority for Communities. The client can never
grant itself a capability, skip the message-request consent flow, reveal a
hidden phone, or exceed the rate limit — every gate is enforced here and the
views below MUST call it.

## What is REUSED (not re-implemented)

From `core.logic.circle_groups` (verbatim):
- Roles `ROLE_ADMIN`/`ROLE_MEMBER`, `has_capability`, `is_admin`, `normalize_role`.
- Admin/announcements gate `can_post` (wrapped as `can_post_in_group`).
- Size cap `clamp_size_limit` (+ `SIZE_LIMIT_DEFAULT`), `sanitize_group_info`.
- Membership states `MEMBERSHIP_ACTIVE/LEFT/REMOVED`.

From `core.logic.circle`: `REQ_ACCEPTED` (circle relationship) + `pick(lang,bn,en)`.

NEW here: community umbrella + announcements-group seeding, per-group join-mode
(open vs request), join-request FSM + admin approve, member-card phone privacy,
who-can-message setting, the message-request consent flow, message-request FSM,
and the per-sender rate limiter. circle_groups is CIRCLE-ONLY; communities are
the owner's larger open surface, so the old circle gate is replaced by this
server-enforced consent flow.

## Public functions (what the views call)

Community / groups
- `sanitize_community_info(name, description, photo_ref)`
- `new_community(id, creator_id, name, ...)` -> (community_row, announcements_group_row, creator_member_row)
- `new_community_group(id, community_id, creator_id, name, kind, join_mode, ...)` -> (group_row, creator_member_row)
- `set_group_rules(actor_role, text)` / `set_group_size_limit(actor_role, n)` — admin-only
- `partition_groups(all_groups, my_active_ids, my_pending_ids)` -> {joined, joinable, requested}

Join flow
- `normalize_join_mode(m)` (JOIN_OPEN | JOIN_REQUEST; default request)
- `request_to_join(group, current_size, already_member, has_pending)` -> {allowed, action('joined'|'requested'), reason}
- `apply_join_event(state, event)` FSM: pending -> approved|rejected|cancelled
- `can_approve_join(actor_role, current_size, group_size_limit, request_state)` — admin-only
- `can_remove_community_member(actor_role, target_role, target_is_actor, admin_count)` — last-admin protected

Posting
- `can_post_in_group(role, group)` — announcements group / announcements_only topic = admins only

Member privacy
- `member_card(member, viewer_id)` -> {member_id, name, photo_ref, phone|None, phone_hidden} — phone hidden unless `show_phone` or self
- `set_show_phone(member, show)` — opt-in toggle

Messaging consent (the core gate)
- `normalize_who_can_msg(m)` (WHO_EVERYONE default | WHO_NOBODY)
- `can_direct_message(rel_state, prior_request_state, recipient_who_can_msg, blocked_either, same_community)`
  -> {allowed, route('direct'|'message_request'|None), reason, calls_allowed}
- `can_call(rel_state, prior_request_state, blocked_either)` — no calls before acceptance
- `apply_msgreq_event(state, event)` FSM: pending -> accepted|declined|blocked; (accepted|declined) -> blocked; blocked -> (unblock) declined
- `new_message_request(sender, recipient, community_id, first_ciphertext, first_nonce, sender_key_id)` — stores CIPHERTEXT ONLY
- `report_sender(reporter, sender, community_id, reason, note, also_block)`
- `check_msgreq_rate(recent_request_times, now, max_in_window=5, window_sec=3600)` -> {allowed, count, remaining, retry_after_sec}

## The two enforcement surfaces (owner-critical)

### 1. First message from OUTSIDE the recipient's circle -> Message request
`can_direct_message` decision order:
1. `blocked_either` -> `{allowed:False, route:None, reason:"blocked"}`
2. `same_community=False` -> `{allowed:False, reason:"not_in_community"}`
3. already connected (`rel_state==REQ_ACCEPTED` OR `prior_request_state==MSGREQ_ACCEPTED`)
   -> `{allowed:True, route:"direct", calls_allowed:True}`
4. recipient `who_can_msg==NOBODY` -> `{allowed:False, reason:"who_nobody"}` (no request created)
5. else -> `{allowed:True, route:"message_request", reason:"first_contact_outside_circle", calls_allowed:False}`

So a stranger's first message NEVER lands in the normal inbox — it becomes a
Message request (Accept/Decline/Block/Report via `apply_msgreq_event` +
`report_sender`). `calls_allowed` is False until acceptance; `can_call` enforces
the same ("no calls before acceptance"). After Accept, the recipient's row holds
`prior_request_state=MSGREQ_ACCEPTED`, so subsequent `can_direct_message` returns
`route="direct"` with `calls_allowed=True`.

### 2. "Who can message me" + rate limit
- Setting is per-user, default EVERYONE, stored on the user profile, read into
  `can_direct_message(recipient_who_can_msg=...)`. NOBODY blocks even the
  message-request creation.
- Before creating a message request the view calls `check_msgreq_rate(sender's
  recent request timestamps)`; if `allowed` is False it returns the sliding-
  window `retry_after_sec` and the view refuses (surface `communityRateLimited`).

## MIGRATION NOTE — DB models (integrator owns; do NOT add here)

- `Community(id, creator, name, description, photo_ref, created_at)`
- `CommunityGroup(id, community(fk), creator, kind[announcements|topic],
  name, description, photo_ref, join_mode[open|request], size_limit,
  announcements_only, rules, created_at)` — exactly one `kind=announcements`
  per community, created with the community and never deletable.
- `CommunityMember(community, group, member(user), role[admin|member],
  status[active|left|removed], joined_at)`
- `CommunityJoinRequest(group, requester, state[pending|approved|rejected|
  cancelled], created_at)`
- `CommunityMessageRequest(sender, recipient, community, state[pending|
  accepted|declined|blocked], first_ciphertext, first_nonce, sender_key_id,
  created_at)` — ciphertext only; server never stores plaintext.
- User profile fields: `show_phone(bool, default False)`,
  `communities_who_can_msg[everyone|nobody], default everyone`.

## HTTP endpoints (integrator wires; each delegates to a function above)

- `POST /api/community/create` -> `new_community`
- `POST /api/community/<id>/group/create` -> `new_community_group`
- `PATCH /api/community/group/<id>` (rules/size/join_mode/announcements) ->
  `set_group_rules` / `set_group_size_limit` (admin capability check)
- `GET  /api/community/<id>/groups` -> `partition_groups` for the caller
- `POST /api/community/group/<id>/join` -> `request_to_join` (open=join now,
  request=create JoinRequest)
- `POST /api/community/join-request/<id>/approve|reject` -> `can_approve_join` +
  `apply_join_event`
- `POST /api/community/group/<id>/member/<uid>/remove` ->
  `can_remove_community_member`
- `POST /api/community/group/<id>/post` -> `can_post_in_group` gate (then the
  existing circle_groups envelope relay)
- `GET  /api/community/<id>/members` -> `member_card` per member (phone hidden)
- `PATCH /api/me/show-phone` -> `set_show_phone`
- `PATCH /api/me/communities-who-can-msg` -> stored, read by `can_direct_message`
- `POST /api/community/message` -> `check_msgreq_rate` then `can_direct_message`:
  route=direct -> normal 1:1 relay; route=message_request -> `new_message_request`
- `POST /api/community/message-request/<id>/accept|decline|block` ->
  `apply_msgreq_event`
- `POST /api/community/message-request/<id>/report` -> `report_sender`
- `POST /api/community/call` -> `can_call` (refuse pre-acceptance)

## Privacy / E2E posture
Messages (direct + the first message held in a message request) are the same
opaque ciphertext envelope as 1:1 / groups — the server stores ciphertext only
and holds no key. Community name/description/photo and member name/photo are
shown to all members by design (they joined by choice); phone is the one private
field, default hidden.
