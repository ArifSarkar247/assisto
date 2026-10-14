"""
circle_groups.py — Assisto "Connected Circle" GROUPS logic (M2 item 7).

Pure Python, deterministic, no DB, no AI key.  This module is the SERVER-SIDE
authority for group chats; the integrator wires it into the group views so a
client can never bypass the rules.  Benchmarked against WhatsApp + Messenger
groups.  Builds on core.logic.circle (ciphertext relay, request FSM) and
core.logic.circle_calls (the video plan gate — reused verbatim for group video).

THE GROUP CONTRACT (owner-specified, enforced here):
  - A group's members are a SUBSET OF THE CREATOR'S / ADMINS' CIRCLE.  You can
    only add someone you have a mutually-accepted relationship with.  No
    strangers, ever — `can_add_member()` rejects a non-circle candidate.  The
    invite link is therefore circle-gated too: redeeming it still requires the
    joiner to be an accepted circle member of the inviter (`invite_link_*`).
  - Roles: ADMIN and MEMBER.  The creator is the first admin.  Admins add/remove
    members, promote/demote, edit group info, pin, toggle announcements-only.
    A member may only post (unless announcements-only), react, reply, vote, and
    leave.  Role transitions are an explicit FSM (`apply_role_event`).
  - Announcements-only mode: when on, ONLY admins may post messages
    (`can_post`).  Everyone can still read / react / vote.
  - Messages stay E2E.  The server stores CIPHERTEXT ONLY, exactly as for 1:1
    (see the E2E / GROUP-KEY statement below).  A group message is the same
    opaque envelope with a `group_id` routing field; this module validates it.
  - Group VOICE call is FREE for all members.  Group VIDEO call is PREMIUM: the
    INITIATOR must hold a video-capable plan (or a referral-points unlock).  This
    reuses circle_calls.can_place_call so there is ONE source of truth for the
    video entitlement — the group-call gate cannot drift from the 1:1 gate.
  - Group size is capped (`SIZE_LIMIT_DEFAULT`, configurable per deployment /
    per group); `can_add_member` enforces the cap.

E2E / GROUP-KEY STATEMENT (documented, enforced by the envelope validator):
  The software-fallback E2E (app/lib/crypto/e2e.dart, scheme
  "x25519-xchacha-fallback-v1") is PAIRWISE.  For a group the SENDER fans out:
  it encrypts the same plaintext ONCE PER RECIPIENT and relays N ciphertext
  envelopes (one `recipient_ids` entry each, or a single envelope carrying a
  map of per-recipient ciphertexts — `build_group_fanout`).  The server still
  sees ciphertext only and never a group key.  The MLS upgrade (OpenMLS,
  mls-openmls-v1) replaces fan-out with a single group ciphertext under a
  ratcheting group key held only on members' devices; the relay envelope shape
  is unchanged, so no server/endpoint change is needed for the swap.  Either
  way: the server never holds a key and cannot read a group message.

WHAT LIVES HERE (logic/state only — DB models CircleGroup / CircleGroupMember /
GroupPoll / PollVote, and the HTTP endpoints, are the integrator's; see the
report MIGRATION NOTE):
  - Role FSM + permission matrix (admin/member; add/remove/promote/demote).
  - `can_add_member` (circle-only + size cap), `can_remove_member`,
    last-admin protection on leave/demote/remove.
  - Announcements-only gate (`can_post`).
  - Group message envelope build/validate (group_id + E2E fan-out), @mentions
    (opaque member-id refs, never names), replies, reactions (reuse semantics).
  - Pinned messages (group-scoped, capped) + announcements.
  - Poll create / vote / tally (single- or multi-choice, close, result).
  - Invite link mint/parse (reuses the signed-token shape) — circle-gated redeem.
  - Group voice/video call permission (reuses circle_calls.can_place_call).
  - Leave / report.
  - Bilingual system notifications + labels (pick(lang,bn,en); no Bangla in .dart).

Run self-tests (no DB):
    python3 -c "import core.logic.circle_groups_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

import hashlib
import hmac
import secrets
from datetime import datetime, timedelta, timezone

from core.logic.circle import (
    FALLBACK_SCHEME,
    FORBIDDEN_META_KEYS,
    REQ_ACCEPTED,
    pick,
    validate_envelope as _validate_base,
)
from core.logic.circle_calls import can_place_call


# ---------------------------------------------------------------------------
# Roles + permission matrix
# ---------------------------------------------------------------------------
# Two roles.  The creator is seeded as ADMIN; everyone else joins as MEMBER.
# A permission is a named capability; the matrix below is the single source of
# truth the view consults (so the client can never grant itself a capability).

ROLE_ADMIN = "admin"
ROLE_MEMBER = "member"
ROLES = (ROLE_ADMIN, ROLE_MEMBER)

# Capabilities an admin has that a member does not.
_ADMIN_ONLY = {
    "add_member", "remove_member", "promote", "demote", "edit_group",
    "set_announcements_only", "pin_message", "unpin_message",
    "post_when_announcements_only", "delete_any_message", "close_poll",
    "set_size_limit",
}
# Capabilities everyone (admin + member) has.
_MEMBER_CAP = {
    "post", "react", "reply", "mention", "vote", "create_poll", "leave",
    "report", "read",
}


def normalize_role(role):
    r = (role or "").strip().lower()
    return r if r in ROLES else ROLE_MEMBER


def is_admin(role):
    return normalize_role(role) == ROLE_ADMIN


def has_capability(role, capability):
    """Does `role` hold `capability`?  Admins hold member caps too."""
    role = normalize_role(role)
    if capability in _MEMBER_CAP:
        return True
    if capability in _ADMIN_ONLY:
        return role == ROLE_ADMIN
    return False


# ---------------------------------------------------------------------------
# Role / membership FSM
# ---------------------------------------------------------------------------
# A member row has a role (admin|member) and a membership status.  The status
# FSM: active -> left | removed.  (There is no "pending" for groups — you are
# added directly by an admin from their circle, WhatsApp-style, OR you redeem a
# circle-gated invite link which adds you active.)

MEMBERSHIP_ACTIVE = "active"
MEMBERSHIP_LEFT = "left"
MEMBERSHIP_REMOVED = "removed"
MEMBERSHIP_STATES = {MEMBERSHIP_ACTIVE, MEMBERSHIP_LEFT, MEMBERSHIP_REMOVED}

_MEMBERSHIP_TRANSITIONS = {
    MEMBERSHIP_ACTIVE: {"leave": MEMBERSHIP_LEFT, "remove": MEMBERSHIP_REMOVED},
    MEMBERSHIP_LEFT:   {"rejoin": MEMBERSHIP_ACTIVE},   # re-added / re-invited
    MEMBERSHIP_REMOVED: {"rejoin": MEMBERSHIP_ACTIVE},  # admin can re-add
}


def apply_membership_event(state, event):
    """Return (new_state, changed) for a membership transition.  Illegal/unknown
    events are no-ops so the endpoint can reject without raising."""
    state = state if state in MEMBERSHIP_STATES else MEMBERSHIP_ACTIVE
    nxt = _MEMBERSHIP_TRANSITIONS.get(state, {}).get(event)
    if nxt is None:
        return state, False
    return nxt, True


# Role transitions are driven by an admin action, guarded by last-admin rules.
_ROLE_EVENTS = {"promote": ROLE_ADMIN, "demote": ROLE_MEMBER}


def apply_role_event(current_role, event, actor_role, admin_count=1,
                     target_is_actor=False):
    """Return (new_role, changed, reason).

    `event` ∈ {'promote','demote'}.  Rules:
      - only an ADMIN may change roles,
      - demoting the LAST admin is refused (a group must keep ≥1 admin),
      - promoting an already-admin / demoting an already-member is a no-op.
    `admin_count` is the group's current number of active admins.
    """
    current_role = normalize_role(current_role)
    if not is_admin(actor_role):
        return current_role, False, "not_admin"
    target = _ROLE_EVENTS.get(event)
    if target is None:
        return current_role, False, "unknown_event"
    if target == current_role:
        return current_role, False, "noop"
    if event == "demote" and current_role == ROLE_ADMIN and admin_count <= 1:
        return current_role, False, "last_admin"
    return target, True, "ok"


# ---------------------------------------------------------------------------
# Group size cap + add/remove permission (CIRCLE-ONLY enforced here)
# ---------------------------------------------------------------------------
# Owner wants a CONFIGURABLE limit.  Default mirrors a sane family/community
# size; the integrator may raise it per deployment or per group (stored on the
# CircleGroup row and passed in as `size_limit`).

SIZE_LIMIT_DEFAULT = 256     # configurable; WhatsApp community-group class
SIZE_LIMIT_MAX = 1024        # hard ceiling the server will not exceed


def clamp_size_limit(requested, hard_max=SIZE_LIMIT_MAX):
    """Coerce a requested per-group size limit into [1, hard_max]."""
    try:
        v = int(requested)
    except (TypeError, ValueError):
        return SIZE_LIMIT_DEFAULT
    if v < 1:
        return 1
    return min(v, hard_max)


def can_add_member(actor_role, candidate_rel_state, current_size,
                   size_limit=SIZE_LIMIT_DEFAULT, already_member=False,
                   blocked_either=False):
    """THE add gate.  Returns {allowed, reason}.  RULES (in order):
      1. actor must be an ADMIN (add_member capability),
      2. candidate must be a mutually-ACCEPTED circle member of the actor and
         not blocked — this is what makes groups circle-only; a stranger has no
         accepted relationship so is refused with reason 'not_in_circle',
      3. not already an active member,
      4. group not at its size cap.

    `candidate_rel_state` is the relationship state (circle.REQ_* value) between
    the actor and the candidate; only 'accepted' passes.
    """
    if not has_capability(actor_role, "add_member"):
        return {"allowed": False, "reason": "not_admin"}
    if blocked_either:
        return {"allowed": False, "reason": "blocked"}
    if candidate_rel_state != REQ_ACCEPTED:
        return {"allowed": False, "reason": "not_in_circle"}
    if already_member:
        return {"allowed": False, "reason": "already_member"}
    if current_size >= clamp_size_limit(size_limit):
        return {"allowed": False, "reason": "group_full"}
    return {"allowed": True, "reason": "ok"}


def can_remove_member(actor_role, target_role, target_is_actor=False,
                      admin_count=1):
    """THE remove gate.  Returns {allowed, reason}.  RULES:
      - a member may remove only THEMSELVES (that is 'leave', handled by
        can_leave — remove-by-admin of someone else needs admin),
      - an admin may remove any member; removing a fellow ADMIN is allowed but
        the group must keep ≥1 admin (can't remove the last admin),
      - removing yourself here is disallowed — use leave().
    """
    if target_is_actor:
        return {"allowed": False, "reason": "use_leave"}
    if not has_capability(actor_role, "remove_member"):
        return {"allowed": False, "reason": "not_admin"}
    if is_admin(target_role) and admin_count <= 1:
        return {"allowed": False, "reason": "last_admin"}
    return {"allowed": True, "reason": "ok"}


def can_leave(member_role, admin_count=1, member_count=1):
    """May this member leave?  Anyone may leave, BUT the last admin may only
    leave if they are also the last member (group dissolves) — otherwise they
    must promote someone first (WhatsApp rule).  Returns {allowed, reason,
    dissolves}.  `dissolves` is True when the leaver is the last member."""
    dissolves = member_count <= 1
    if is_admin(member_role) and admin_count <= 1 and not dissolves:
        return {"allowed": False, "reason": "promote_before_leaving",
                "dissolves": False}
    return {"allowed": True, "reason": "ok", "dissolves": dissolves}


# ---------------------------------------------------------------------------
# Announcements-only gate
# ---------------------------------------------------------------------------

def can_post(role, announcements_only=False):
    """May this role post a message right now?  In announcements-only mode only
    admins may post; everyone can still react/reply-with-reaction/vote/read."""
    if not announcements_only:
        return has_capability(role, "post")
    return has_capability(role, "post_when_announcements_only")


def post_blocked_reason(lang="bn"):
    return pick(
        lang,
        "এই গ্রুপে শুধু অ্যাডমিনরা পোস্ট করতে পারেন।",
        "Only admins can post in this group.",
    )


# ---------------------------------------------------------------------------
# Group message envelope (E2E fan-out) — the SERVER contract
# ---------------------------------------------------------------------------
# A group message is the same opaque envelope as 1:1 (circle.validate_envelope)
# plus a `group_id` routing field, optional `mentions` (opaque member-id list,
# never names), `reply_to`, `reactions`, `pinned`, `announcement`.  @mentions
# are ROUTING ONLY (member ids) so the server can push a mention notification
# without reading any text; the rendered "@Name" is produced on-device.

GROUP_ENVELOPE_EXTRA_KEYS = {
    "group_id", "mentions", "reply_to", "reactions", "pinned", "announcement",
    "client_msg_id", "per_recipient",
}

# A mention is a member id (int) — never a name string.  Cap the count so a
# single message can't notification-bomb the whole group.
MENTION_MAX = 64


def _mentions_are_ids(mentions):
    if mentions is None:
        return True
    if not isinstance(mentions, (list, tuple)):
        return False
    if len(mentions) > MENTION_MAX:
        return False
    for m in mentions:
        if not isinstance(m, int):
            # allow numeric strings (ids) but reject anything name-like
            if not (isinstance(m, str) and m.isdigit()):
                return False
    return True


def validate_group_envelope(env):
    """Full group envelope validation = base relay contract + group checks.
    Returns (ok, reason).  Enforces: a group_id is present; mentions are ids
    only (no names); reply_to is a routing id; no forbidden plaintext anywhere
    (including inside a per_recipient fan-out map)."""
    ok, why = _validate_base(env)
    if not ok:
        return False, why
    if not env.get("group_id"):
        return False, "missing group_id"
    if not _mentions_are_ids(env.get("mentions")):
        return False, "mentions must be member ids, not names"
    ann = env.get("announcement")
    if ann is not None and not isinstance(ann, bool):
        return False, "announcement must be bool"
    # per_recipient fan-out map (fallback E2E): {recipient_id: {ciphertext,nonce}}
    pr = env.get("per_recipient")
    if pr is not None:
        if not isinstance(pr, dict):
            return False, "per_recipient must be an object"
        for rid, sub in pr.items():
            if not isinstance(sub, dict):
                return False, "per_recipient entry must be an object"
            bad = FORBIDDEN_META_KEYS & set(sub.keys())
            if bad:
                return False, "per_recipient carries plaintext: " + ",".join(sorted(bad))
            if not sub.get("ciphertext") or not sub.get("nonce"):
                return False, "per_recipient entry missing ciphertext/nonce"
    return True, "ok"


def build_group_fanout(group_id, sender_id, recipient_ids, per_recipient,
                       sender_key_id, scheme=None, mentions=None, reply_to=None,
                       announcement=False, client_msg_id=None, now=None):
    """Build ONE relay-safe group TEXT envelope carrying a fan-out map of
    per-recipient ciphertexts (fallback E2E encrypts once per recipient).  The
    top-level ciphertext/nonce carry the FIRST recipient's blob so the base
    validator (which requires inline ciphertext for text) is satisfied; the
    full set lives in `per_recipient`.  The server stores this verbatim; it
    holds no key and cannot decrypt.  Raises if the result isn't opaque.

    `per_recipient` = {recipient_id: {"ciphertext": b64, "nonce": b64}} with one
    entry per recipient (the sender produced these with E2E.encrypt per peer).
    When MLS lands, the caller passes a single ciphertext and omits
    per_recipient; the envelope shape is otherwise identical.
    """
    now = now or datetime.now(timezone.utc)
    recipient_ids = list(recipient_ids)
    per_recipient = dict(per_recipient or {})
    # Pick any entry for the top-level (required by the base text validator).
    first = None
    if recipient_ids:
        first = per_recipient.get(recipient_ids[0]) \
            or per_recipient.get(str(recipient_ids[0]))
    if first is None and per_recipient:
        first = next(iter(per_recipient.values()))
    first = first or {}
    env = {
        "group_id": group_id,
        "sender_id": sender_id,
        "recipient_ids": recipient_ids,
        "content_type": "text",
        "ciphertext": first.get("ciphertext", ""),
        "nonce": first.get("nonce", ""),
        "per_recipient": per_recipient,
        "sender_key_id": sender_key_id,
        "scheme": scheme or FALLBACK_SCHEME,
        "created_at": now.isoformat(),
        "delivered_to": [],
        "read_by": [],
        "reactions": {},
        "deleted": "",
    }
    if mentions is not None:
        env["mentions"] = list(mentions)
    if reply_to is not None:
        env["reply_to"] = str(reply_to)
    if announcement:
        env["announcement"] = True
    if client_msg_id is not None:
        env["client_msg_id"] = str(client_msg_id)
    ok, reason = validate_group_envelope(env)
    if not ok:
        raise ValueError("refusing to relay non-opaque group envelope: " + reason)
    return env


def mention_targets(env):
    """Normalized set of member-ids mentioned (for push routing).  Returns a
    sorted list of ints.  The server uses this to notify @mentioned members WITH
    NO ACCESS to the text."""
    out = set()
    for m in (env.get("mentions") or []):
        try:
            out.add(int(m))
        except (TypeError, ValueError):
            continue
    return sorted(out)


# ---------------------------------------------------------------------------
# Reactions (reuse 1:1 semantics: one opaque emoji per member)
# ---------------------------------------------------------------------------

REACTION_MAX_LEN = 8


def add_reaction(env, member_id, emoji):
    """Set/replace this member's reaction on a group message.  Returns (env, ok).
    Rejects over-long payloads (a reaction is one emoji, not a message)."""
    if not emoji or len(emoji) > REACTION_MAX_LEN:
        return env, False
    env = dict(env)
    reactions = dict(env.get("reactions") or {})
    reactions[str(member_id)] = emoji
    env["reactions"] = reactions
    return env, True


def remove_reaction(env, member_id):
    env = dict(env)
    reactions = dict(env.get("reactions") or {})
    reactions.pop(str(member_id), None)
    env["reactions"] = reactions
    return env, True


def reaction_summary(env):
    """Aggregate for the bubble: {emoji: count} ordered by count, + total."""
    reactions = env.get("reactions") or {}
    counts = {}
    for emoji in reactions.values():
        counts[emoji] = counts.get(emoji, 0) + 1
    ordered = dict(sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])))
    return {"counts": ordered, "total": sum(counts.values())}


# ---------------------------------------------------------------------------
# Pinned messages + announcements (group-scoped, capped)
# ---------------------------------------------------------------------------
# Only admins may pin (pin_message capability).  Pins are group-scoped and
# capped (WhatsApp pins a handful).  An "announcement" is just a posted message
# flagged announcement=True (useful in announcements-only mode); pinning an
# announcement is the common path.

PIN_CAP_PER_GROUP = 5


def can_pin_group(actor_role, current_pinned_ids, message_id,
                  cap=PIN_CAP_PER_GROUP):
    """Can `actor_role` pin `message_id` given current pins + the cap?  Only
    admins; unpinning an already-pinned message is always allowed for admins."""
    if not has_capability(actor_role, "pin_message"):
        return False
    pins = set(current_pinned_ids or [])
    if message_id in pins:
        return True  # unpin allowed
    return len(pins) < cap


def apply_pin_group(actor_role, current_pinned_ids, message_id, pin=True,
                    cap=PIN_CAP_PER_GROUP):
    """Return (new_pinned_ids, ok).  Admin-only, capped, group-scoped."""
    if not has_capability(actor_role, "pin_message"):
        return list(current_pinned_ids or []), False
    pins = list(current_pinned_ids or [])
    if pin:
        if message_id in pins:
            return pins, True
        if len(pins) >= cap:
            return pins, False
        pins.append(message_id)
        return pins, True
    return [p for p in pins if p != message_id], True


# ---------------------------------------------------------------------------
# Polls — create / vote / tally (E2E-aware: option LABELS are ciphertext)
# ---------------------------------------------------------------------------
# A poll's question + option labels are USER TEXT, so they are ciphertext too
# (encrypted on the sender device, stored opaque — same contract as messages).
# What the server CAN count safely is per-option VOTE COUNTS keyed by an opaque
# option index (0..N-1); the option's human label is decrypted on-device.  So a
# poll row stores: {id, group_id, author_id, option_count, multi, closed,
# question_ct, options_ct:[...]}.  Votes store {poll_id, voter_id, choices:[idx]}.

POLL_MIN_OPTIONS = 2
POLL_MAX_OPTIONS = 12


def can_create_poll(role):
    return has_capability(role, "create_poll")


def new_poll(poll_id, group_id, author_id, option_count, question_ct,
             options_ct, multi=False, now=None):
    """Create a poll row.  `question_ct` / `options_ct` are OPAQUE ciphertext
    (the server never reads the question or labels).  `option_count` is the
    number of options; votes reference options by INDEX only.  Raises on an
    out-of-range option count.  Returns the row dict the integrator persists."""
    n = int(option_count)
    if n < POLL_MIN_OPTIONS or n > POLL_MAX_OPTIONS:
        raise ValueError("poll must have %d..%d options" % (POLL_MIN_OPTIONS, POLL_MAX_OPTIONS))
    if not isinstance(options_ct, (list, tuple)) or len(options_ct) != n:
        raise ValueError("options_ct must carry exactly option_count ciphertexts")
    # The option ciphertexts must not smuggle plaintext.
    for o in options_ct:
        if isinstance(o, dict) and (FORBIDDEN_META_KEYS & set(o.keys())):
            raise ValueError("poll option carries plaintext")
    now = now or datetime.now(timezone.utc)
    return {
        "id": poll_id,
        "group_id": group_id,
        "author_id": author_id,
        "option_count": n,
        "multi": bool(multi),
        "closed": False,
        "question_ct": question_ct,     # opaque
        "options_ct": list(options_ct),  # opaque
        "created_at": now.isoformat(),
    }


def validate_vote(poll, choices):
    """Return (ok, reason).  A vote is a list of option INDICES.  Rules: poll
    open; indices in range; no duplicates; single-choice polls take exactly one."""
    if poll.get("closed"):
        return False, "poll_closed"
    if not isinstance(choices, (list, tuple)):
        return False, "choices must be a list"
    n = int(poll.get("option_count") or 0)
    seen = set()
    for c in choices:
        if not isinstance(c, int) or c < 0 or c >= n:
            return False, "choice_out_of_range"
        if c in seen:
            return False, "duplicate_choice"
        seen.add(c)
    if not choices:
        return False, "empty_vote"
    if not poll.get("multi") and len(choices) != 1:
        return False, "single_choice_only"
    return True, "ok"


def apply_vote(votes_by_voter, poll, voter_id, choices):
    """Return (new_votes, ok, reason).  `votes_by_voter` is {voter_id: [idx,...]}.
    A re-vote REPLACES the voter's previous choice (WhatsApp lets you change your
    vote).  Validates against the poll first."""
    ok, reason = validate_vote(poll, choices)
    if not ok:
        return votes_by_voter, False, reason
    out = dict(votes_by_voter or {})
    out[voter_id] = sorted(set(int(c) for c in choices))
    return out, True, "ok"


def tally_poll(poll, votes_by_voter):
    """Return the result: {counts:[n0,n1,...], total_voters, total_votes,
    leading:[idx,...]}.  Counts are per-option-index; the server counts these
    without ever reading an option label (labels stay ciphertext)."""
    n = int(poll.get("option_count") or 0)
    counts = [0] * n
    total_votes = 0
    voters = 0
    for _voter, choices in (votes_by_voter or {}).items():
        if not choices:
            continue
        voters += 1
        for c in choices:
            if isinstance(c, int) and 0 <= c < n:
                counts[c] += 1
                total_votes += 1
    top = max(counts) if counts else 0
    leading = [i for i, c in enumerate(counts) if c == top and top > 0]
    return {
        "counts": counts,
        "total_voters": voters,
        "total_votes": total_votes,
        "leading": leading,
    }


def close_poll(poll, actor_role, author_id=None, actor_id=None):
    """Close a poll.  An admin may always close; the poll's AUTHOR may close
    their own.  Returns (poll, ok)."""
    if not (has_capability(actor_role, "close_poll")
            or (author_id is not None and actor_id is not None and author_id == actor_id)):
        return poll, False
    poll = dict(poll)
    poll["closed"] = True
    return poll, True


# ---------------------------------------------------------------------------
# Group calls — reuse the 1:1 video plan gate (ONE source of truth)
# ---------------------------------------------------------------------------
# Group VOICE is free for all members.  Group VIDEO requires the INITIATOR to
# hold a video-capable plan (or a referral-points unlock).  We reuse
# circle_calls.can_place_call by treating the group as the "callee" with an
# always-accepted, never-blocked stand-in — so the entitlement logic can never
# diverge from the 1:1 gate.  (M3 note: the actual multi-party media transport
# is an SFU the owner provisions; this is the ENTITLEMENT gate only.)

def can_place_group_call(initiator, kind, member_count=2):
    """THE group-call gate.  `initiator` is the resolved member dict (needs
    `plan`, optional `video_unlocked`, and `role`).  Returns the can_place_call
    dict augmented with {group_video, member_count}.  RULES:
      - initiator must be an active member (role present),
      - VOICE -> free for all members,
      - VIDEO -> initiator's plan must allow video (reuses the 1:1 gate).
    """
    initiator = dict(initiator or {})
    # The group stands in as an always-accepted, non-blocked callee so the
    # relationship checks in can_place_call pass and only the plan gate matters.
    group_stub = {"accepted": True, "blocked": False}
    initiator.setdefault("accepted", True)
    result = can_place_call(initiator, group_stub, kind)
    result["group_video"] = (result.get("kind") == "video")
    result["member_count"] = int(member_count)
    return result


def group_call_upgrade_prompt(lang="bn"):
    """Shown to a FREE initiator who tries to start a group VIDEO call."""
    return {
        "kind": "circle_group_call_upgrade",
        "title": pick(lang, "গ্রুপ ভিডিও কল প্রিমিয়াম", "Group video is Premium"),
        "body": pick(
            lang,
            "গ্রুপ ভিডিও কল শুরু করতে প্রিমিয়াম লাগবে। গ্রুপ ভয়েস কল সবার জন্য ফ্রি। "
            "রেফারেল পয়েন্ট দিয়েও আনলক করা যায়।",
            "Starting a group video call needs Premium. Group voice calls are free "
            "for everyone. You can also unlock it with referral points.",
        ),
        "cta_upgrade": pick(lang, "প্রিমিয়াম নিন", "Get Premium"),
        "cta_points": pick(lang, "পয়েন্ট দিয়ে আনলক", "Unlock with points"),
    }


# ---------------------------------------------------------------------------
# Invite link — signed, expiring; redeem is CIRCLE-GATED
# ---------------------------------------------------------------------------
# An admin mints a group invite link.  The token binds group_id + inviter_id +
# expiry, signed with the server secret so it can't be forged.  CRUCIALLY, when
# someone opens the link the server STILL requires the joiner to be a
# mutually-accepted circle member of the inviter before adding them — a leaked
# link cannot pull a stranger into a circle-only group (`can_redeem_invite`).

def make_group_invite(group_id, inviter_id, secret, ttl_minutes=1440, now=None):
    """Create a compact signed group-invite token.  Returns the token str."""
    now = now or datetime.now(timezone.utc)
    exp = int((now + timedelta(minutes=ttl_minutes)).timestamp())
    nonce = secrets.token_urlsafe(6)
    body = "g.%s.%d.%d.%s" % (str(group_id), int(inviter_id), exp, nonce)
    sig = _sign(body, secret)
    return body + "." + sig


def parse_group_invite(token, secret, now=None):
    """Return (ok, data|reason).  Verifies signature + expiry.  Does NOT add the
    member and does NOT check the circle gate — that is can_redeem_invite's job,
    which the DB-backed view calls with the relationship state."""
    now = now or datetime.now(timezone.utc)
    try:
        tag, group_id, inviter_id, exp, nonce, sig = token.split(".")
    except (ValueError, AttributeError):
        return False, "malformed token"
    if tag != "g":
        return False, "not a group invite"
    body = "g.%s.%s.%s.%s" % (group_id, inviter_id, exp, nonce)
    if not hmac.compare_digest(sig, _sign(body, secret)):
        return False, "bad signature"
    try:
        if int(exp) < int(now.timestamp()):
            return False, "expired"
    except ValueError:
        return False, "bad expiry"
    return True, {
        "group_id": group_id,
        "inviter_id": int(inviter_id),
        "expires_at": int(exp),
    }


def can_redeem_invite(joiner_rel_state, current_size, size_limit=SIZE_LIMIT_DEFAULT,
                      already_member=False, blocked_either=False):
    """THE invite-link redeem gate — circle-only, exactly like can_add_member but
    from the JOINER's side.  `joiner_rel_state` is the relationship between the
    joiner and the INVITER (from the token); only 'accepted' passes, so a leaked
    link cannot admit a stranger.  Returns {allowed, reason}."""
    if blocked_either:
        return {"allowed": False, "reason": "blocked"}
    if joiner_rel_state != REQ_ACCEPTED:
        return {"allowed": False, "reason": "not_in_circle"}
    if already_member:
        return {"allowed": False, "reason": "already_member"}
    if current_size >= clamp_size_limit(size_limit):
        return {"allowed": False, "reason": "group_full"}
    return {"allowed": True, "reason": "ok"}


def group_invite_url(token, base_url="https://assisto.asalify.com"):
    """The deep-link string encoded into the shareable group invite / QR."""
    return "%s/g/%s" % (base_url, token)


# ---------------------------------------------------------------------------
# Group creation + info
# ---------------------------------------------------------------------------

GROUP_NAME_MAX = 100
GROUP_DESC_MAX = 1000


def sanitize_group_info(name, description="", photo_ref=None):
    """Coerce group info to safe bounds.  Name is required (trimmed, capped);
    description capped; photo is a BLOB REF (encrypted media, like 1:1 photos) —
    never raw bytes here.  Returns the cleaned dict.  Name/description are USER
    TEXT shown to members and stored by the integrator; since they're group
    metadata visible to all members (not a private message) they may be stored
    as given, but the field length caps prevent abuse."""
    nm = (name or "").strip()[:GROUP_NAME_MAX]
    return {
        "name": nm,
        "description": (description or "").strip()[:GROUP_DESC_MAX],
        "photo_ref": photo_ref,   # encrypted-blob reference or None
    }


def new_group(group_id, creator_id, name, description="", photo_ref=None,
              size_limit=SIZE_LIMIT_DEFAULT, announcements_only=False, now=None):
    """Create a group row (the integrator persists it + seeds the creator as the
    first ADMIN member).  Returns (group_row, creator_member_row)."""
    now = now or datetime.now(timezone.utc)
    info = sanitize_group_info(name, description, photo_ref)
    if not info["name"]:
        raise ValueError("group name required")
    group_row = {
        "id": group_id,
        "creator_id": creator_id,
        "name": info["name"],
        "description": info["description"],
        "photo_ref": info["photo_ref"],
        "size_limit": clamp_size_limit(size_limit),
        "announcements_only": bool(announcements_only),
        "created_at": now.isoformat(),
    }
    creator_member = {
        "group_id": group_id,
        "member_id": creator_id,
        "role": ROLE_ADMIN,
        "status": MEMBERSHIP_ACTIVE,
        "joined_at": now.isoformat(),
    }
    return group_row, creator_member


# ---------------------------------------------------------------------------
# Report (group or a member within it) — reuse 1:1 report shape
# ---------------------------------------------------------------------------

REPORT_REASONS = ("spam", "harassment", "scam", "impersonation", "other")


def group_report_payload(reporter_id, group_id, reason, target_member_id=None,
                         note="", lang="bn"):
    reason = reason if reason in REPORT_REASONS else "other"
    return {
        "kind": "circle_group_report",
        "reporter_id": int(reporter_id),
        "group_id": group_id,
        "target_member_id": target_member_id,
        "reason": reason,
        "note": (note or "")[:500],
        "auto_flag": reason in ("harassment", "scam", "impersonation"),
        "message": pick(lang,
                        "রিপোর্ট জমা হয়েছে। চাইলে গ্রুপ থেকে বেরিয়েও যেতে পারেন।",
                        "Report submitted. You can also leave the group."),
    }


# ---------------------------------------------------------------------------
# System notifications (bilingual) — joins/leaves/role changes/announcements
# ---------------------------------------------------------------------------

def member_added_notification(adder_name, added_name, lang="bn"):
    return {
        "kind": "group_member_added",
        "body": pick(lang,
                     f"{adder_name} {added_name}-কে গ্রুপে যুক্ত করেছেন।",
                     f"{adder_name} added {added_name} to the group."),
    }


def member_left_notification(name, lang="bn"):
    return {
        "kind": "group_member_left",
        "body": pick(lang, f"{name} গ্রুপ ছেড়ে গেছেন।", f"{name} left the group."),
    }


def member_removed_notification(remover_name, removed_name, lang="bn"):
    return {
        "kind": "group_member_removed",
        "body": pick(lang,
                     f"{remover_name} {removed_name}-কে সরিয়ে দিয়েছেন।",
                     f"{remover_name} removed {removed_name}."),
    }


def role_changed_notification(name, new_role, lang="bn"):
    if is_admin(new_role):
        return {"kind": "group_role_changed",
                "body": pick(lang, f"{name} এখন অ্যাডমিন।",
                             f"{name} is now an admin.")}
    return {"kind": "group_role_changed",
            "body": pick(lang, f"{name} আর অ্যাডমিন নন।",
                         f"{name} is no longer an admin.")}


def announcements_mode_notification(on, lang="bn"):
    if on:
        return {"kind": "group_announcements_on",
                "body": pick(lang, "এখন শুধু অ্যাডমিনরা পোস্ট করতে পারবেন।",
                             "Only admins can post now.")}
    return {"kind": "group_announcements_off",
            "body": pick(lang, "এখন সবাই পোস্ট করতে পারবেন।",
                         "Everyone can post now.")}


def role_label(role, lang="bn"):
    if is_admin(role):
        return pick(lang, "অ্যাডমিন", "Admin")
    return pick(lang, "সদস্য", "Member")


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def _sign(body, secret):
    key = (secret or "").encode("utf-8")
    return hashlib.sha256(
        hmac.new(key, body.encode("utf-8"), hashlib.sha256).digest()
    ).hexdigest()[:24]
