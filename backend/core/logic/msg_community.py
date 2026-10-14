"""
msg_community.py — Assisto Messenger COMMUNITIES logic (Step 3).

Pure Python, deterministic, NO Django, NO DB, NO AI key.  This module is the
SERVER-SIDE authority for Communities; the integrator wires it into the
community views so a client can never bypass a rule.  ORIGINAL design —
WhatsApp-Communities-*class* (a named umbrella of groups) but not a copy of its
UI / text / assets.  Builds on core.logic.circle_groups (roles + admin FSM +
announcements can_post gate + size cap, reused verbatim) and core.logic.circle
(the relationship vocabulary + REQ_* states).

────────────────────────────────────────────────────────────────────────────
WHY THIS DIFFERS FROM circle_groups (read before editing)
────────────────────────────────────────────────────────────────────────────
circle_groups is CIRCLE-ONLY: you can only add someone you already have a
mutually-accepted relationship with — no strangers, ever.  A COMMUNITY is the
owner's explicitly-requested *larger* surface: people who are NOT in each
other's circle gather around a shared community, join groups BY CHOICE, and may
message one another.  That would normally be the "strangers" case circle_groups
forbids — so the safety the circle gate used to provide is re-implemented here
as SERVER-ENFORCED consent flow instead:

  THE COMMUNITY CONTRACT (owner-specified, enforced here):
   1. A Community = {name, photo, description} + exactly ONE ANNOUNCEMENTS group
      (admins post only) + zero-or-more TOPIC groups.  (new_community seeds the
      announcements group; it can never be deleted while the community lives.)
   2. Each group is either OPEN-JOIN (tap to join) or REQUEST-JOIN (admin
      approves).  The admin chooses per group.  A join-request FSM
      (apply_join_event) drives request → approved | rejected; open-join skips
      straight to member.  Admins approve / remove members and set rules + a
      configurable size cap (reuses circle_groups.clamp_size_limit / the add
      gate's cap check).
   3. Members see each other's NAME + PHOTO (they joined the same community by
      choice).  Phone numbers are HIDDEN BY DEFAULT; a user may opt to show.
      member_card() enforces this — phone is omitted unless the owner of that
      number turned sharing on.
   4. MESSAGING across the community is gated by the CONSENT FLOW:
        - If the two users ARE in each other's circle (mutually accepted) OR a
          prior request between them was already accepted → it's a normal chat.
        - Otherwise the recipient has never consented to this sender, so the
          FIRST message lands in MESSAGE REQUESTS (Accept / Decline / Block /
          Report).  It is NOT delivered to the normal inbox.  can_direct_message
          decides this; NO CALLS are permitted before acceptance.
        - After Accept → normal chat (and calls) both directions.
   5. Per-user setting "Who in my communities can message me": EVERYONE
      (default) or NOBODY.  NOBODY blocks even the message-request from a
      non-circle sender.  SERVER-ENFORCED in can_direct_message, and the
      message-request creation is RATE-LIMITED per sender (anti-spam).

So: circle_groups = closed/circle-only groups; msg_community = open umbrella +
consent-gated cross-circle messaging.  The role/admin/announcements/size logic
is shared (imported), the join-approval + message-request + who-can-msg +
rate-limit logic is NEW and lives here.

WHAT LIVES HERE (logic/state only — DB models + HTTP endpoints are the
integrator's; see .phaseB/msg_community_integration.md):
  - Community create + info sanitize; announcements-group seeding.
  - Group join-mode (open vs request) + join-request FSM + admin approve/remove.
  - Announcements-only post gate (reuses circle_groups.can_post).
  - member_card: name+photo always, phone hidden-by-default.
  - who-can-message setting (everyone|nobody), server-enforced.
  - can_direct_message: circle? accepted-before? → direct; else → message
    request; who=nobody → blocked; calls blocked pre-acceptance.
  - message-request FSM (pending → accepted | declined | blocked + report).
  - per-sender rate limiter for new message requests (sliding window).
  - bilingual labels / notifications (pick(lang,bn,en); no Bangla in .dart).

Run self-tests (no DB):
    python3 -c "import core.logic.msg_community_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from core.logic.circle import REQ_ACCEPTED, pick
from core.logic.circle_groups import (
    MEMBERSHIP_ACTIVE,
    MEMBERSHIP_LEFT,
    MEMBERSHIP_REMOVED,
    ROLE_ADMIN,
    ROLE_MEMBER,
    SIZE_LIMIT_DEFAULT,
    can_post,
    clamp_size_limit,
    has_capability,
    is_admin,
    normalize_role,
    sanitize_group_info,
)


# ---------------------------------------------------------------------------
# Community object + its mandatory ANNOUNCEMENTS group
# ---------------------------------------------------------------------------
# A community is an umbrella.  It ALWAYS has one announcements group (admins
# post only) and may have many topic groups.  The announcements group is seeded
# at creation and is special-cased announcements_only=True forever.

COMMUNITY_NAME_MAX = 100
COMMUNITY_DESC_MAX = 2000

GROUP_KIND_ANNOUNCEMENTS = "announcements"
GROUP_KIND_TOPIC = "topic"
GROUP_KINDS = (GROUP_KIND_ANNOUNCEMENTS, GROUP_KIND_TOPIC)

# A group's join policy — the admin's per-group choice.
JOIN_OPEN = "open"         # tap to join, no approval
JOIN_REQUEST = "request"   # admin must approve
JOIN_MODES = (JOIN_OPEN, JOIN_REQUEST)


def normalize_join_mode(mode):
    m = (mode or "").strip().lower()
    return m if m in JOIN_MODES else JOIN_REQUEST   # safe default: ask


def sanitize_community_info(name, description="", photo_ref=None):
    """Coerce community metadata to safe bounds.  Name required (trimmed,
    capped); description capped; photo is an (encrypted) blob REF, never bytes."""
    nm = (name or "").strip()[:COMMUNITY_NAME_MAX]
    return {
        "name": nm,
        "description": (description or "").strip()[:COMMUNITY_DESC_MAX],
        "photo_ref": photo_ref,
    }


def new_community(community_id, creator_id, name, description="",
                  photo_ref=None, now=None):
    """Create a community row + seed its mandatory ANNOUNCEMENTS group and the
    creator as the community ADMIN.  Returns
    (community_row, announcements_group_row, creator_member_row).  The
    integrator persists all three.  Raises if the name is empty."""
    now = now or datetime.now(timezone.utc)
    info = sanitize_community_info(name, description, photo_ref)
    if not info["name"]:
        raise ValueError("community name required")
    community_row = {
        "id": community_id,
        "creator_id": creator_id,
        "name": info["name"],
        "description": info["description"],
        "photo_ref": info["photo_ref"],
        "created_at": now.isoformat(),
    }
    # The announcements group: always present, announcements_only forever,
    # request-join (you join the community, not this group openly).
    ann_group = new_community_group(
        group_id=f"{community_id}:announcements",
        community_id=community_id,
        creator_id=creator_id,
        name=info["name"],                 # mirrors the community name
        kind=GROUP_KIND_ANNOUNCEMENTS,
        join_mode=JOIN_REQUEST,
        announcements_only=True,
        now=now,
    )[0]
    creator_member = {
        "community_id": community_id,
        "group_id": ann_group["id"],
        "member_id": creator_id,
        "role": ROLE_ADMIN,
        "status": MEMBERSHIP_ACTIVE,
        "joined_at": now.isoformat(),
    }
    return community_row, ann_group, creator_member


def new_community_group(group_id, community_id, creator_id, name,
                        kind=GROUP_KIND_TOPIC, join_mode=JOIN_REQUEST,
                        description="", photo_ref=None,
                        size_limit=SIZE_LIMIT_DEFAULT, announcements_only=False,
                        now=None):
    """Create a TOPIC (or the ANNOUNCEMENTS) group under a community.  The
    announcements group is forced announcements_only=True.  Returns
    (group_row, creator_member_row).  Reuses circle_groups.sanitize_group_info
    + clamp_size_limit so the group semantics match ordinary circle groups."""
    now = now or datetime.now(timezone.utc)
    kind = kind if kind in GROUP_KINDS else GROUP_KIND_TOPIC
    info = sanitize_group_info(name, description, photo_ref)
    if not info["name"]:
        raise ValueError("group name required")
    is_ann = kind == GROUP_KIND_ANNOUNCEMENTS
    group_row = {
        "id": group_id,
        "community_id": community_id,
        "creator_id": creator_id,
        "kind": kind,
        "name": info["name"],
        "description": info["description"],
        "photo_ref": info["photo_ref"],
        "join_mode": normalize_join_mode(join_mode),
        "size_limit": clamp_size_limit(size_limit),
        # announcements group is always announcements-only; topics honour arg.
        "announcements_only": True if is_ann else bool(announcements_only),
        "rules": "",
        "created_at": now.isoformat(),
    }
    creator_member = {
        "community_id": community_id,
        "group_id": group_id,
        "member_id": creator_id,
        "role": ROLE_ADMIN,
        "status": MEMBERSHIP_ACTIVE,
        "joined_at": now.isoformat(),
    }
    return group_row, creator_member


GROUP_RULES_MAX = 4000


def set_group_rules(actor_role, rules_text):
    """Admin-only: set a group's rules text.  Returns (rules, ok).  Reuses the
    edit_group capability from circle_groups' matrix."""
    if not has_capability(actor_role, "edit_group"):
        return None, False
    return (rules_text or "").strip()[:GROUP_RULES_MAX], True


def set_group_size_limit(actor_role, requested):
    """Admin-only: set the configurable per-group size cap.  Returns
    (size_limit, ok).  Reuses set_size_limit capability + clamp_size_limit."""
    if not has_capability(actor_role, "set_size_limit"):
        return None, False
    return clamp_size_limit(requested), True


# ---------------------------------------------------------------------------
# "Groups you're in" / "Groups you can join"
# ---------------------------------------------------------------------------

def partition_groups(all_groups, my_active_group_ids, my_pending_group_ids=None):
    """Split a community's groups into {joined, joinable, requested} for the UI.
      - joined   : groups where I'm an active member,
      - requested: request-join groups where I have a pending request,
      - joinable : groups I'm not in and can act on (open = join now,
                   request = send a request).
    `all_groups` is a list of group rows (each with id + join_mode)."""
    active = set(my_active_group_ids or [])
    pending = set(my_pending_group_ids or [])
    joined, joinable, requested = [], [], []
    for g in (all_groups or []):
        gid = g.get("id")
        if gid in active:
            joined.append(g)
        elif gid in pending:
            requested.append(g)
        else:
            joinable.append({
                "id": gid,
                "name": g.get("name"),
                "kind": g.get("kind"),
                "join_mode": normalize_join_mode(g.get("join_mode")),
                "action": "join" if normalize_join_mode(g.get("join_mode")) == JOIN_OPEN else "request",
            })
    return {"joined": joined, "joinable": joinable, "requested": requested}


# ---------------------------------------------------------------------------
# Join flow — open-join vs request-join + the join-request FSM
# ---------------------------------------------------------------------------
# OPEN-JOIN : a tap adds the user directly as an active MEMBER (size cap only).
# REQUEST-JOIN: the user creates a pending JoinRequest; an admin approves (→
#   active member) or rejects.  The FSM mirrors circle's request FSM in spirit.

JOIN_PENDING = "pending"
JOIN_APPROVED = "approved"
JOIN_REJECTED = "rejected"
JOIN_CANCELLED = "cancelled"
JOIN_STATES = {JOIN_PENDING, JOIN_APPROVED, JOIN_REJECTED, JOIN_CANCELLED}

_JOIN_TRANSITIONS = {
    JOIN_PENDING: {
        "approve": JOIN_APPROVED,
        "reject": JOIN_REJECTED,
        "cancel": JOIN_CANCELLED,   # requester withdraws
    },
    JOIN_APPROVED: {},
    JOIN_REJECTED: {},              # must send a fresh request
    JOIN_CANCELLED: {},
}


def apply_join_event(state, event):
    """Advance a join-request.  Returns (new_state, changed).  Unknown/illegal
    events are no-ops so the endpoint can reject without raising."""
    state = state if state in JOIN_STATES else JOIN_PENDING
    nxt = _JOIN_TRANSITIONS.get(state, {}).get(event)
    if nxt is None:
        return state, False
    return nxt, True


def request_to_join(group, current_size, already_member=False,
                    has_pending=False, who_can_msg=None):
    """A user acts on a joinable group.  Returns {allowed, action, reason}.
      - OPEN group  → action='joined'  (add directly, subject to size cap),
      - REQUEST group → action='requested' (create a pending JoinRequest).
    RULES: not already a member; not already pending; group not full."""
    mode = normalize_join_mode(group.get("join_mode"))
    size_limit = clamp_size_limit(group.get("size_limit", SIZE_LIMIT_DEFAULT))
    if already_member:
        return {"allowed": False, "action": None, "reason": "already_member"}
    if current_size >= size_limit:
        return {"allowed": False, "action": None, "reason": "group_full"}
    if mode == JOIN_OPEN:
        return {"allowed": True, "action": "joined", "reason": "ok"}
    if has_pending:
        return {"allowed": False, "action": None, "reason": "already_requested"}
    return {"allowed": True, "action": "requested", "reason": "ok"}


def can_approve_join(actor_role, current_size, group_size_limit=SIZE_LIMIT_DEFAULT,
                     request_state=JOIN_PENDING):
    """THE approve gate (admin side).  Returns {allowed, reason}.  RULES:
      - actor must be an admin (reuses circle_groups 'add_member' capability),
      - the request must still be pending,
      - the group must not be full."""
    if not has_capability(actor_role, "add_member"):
        return {"allowed": False, "reason": "not_admin"}
    if request_state != JOIN_PENDING:
        return {"allowed": False, "reason": "not_pending"}
    if current_size >= clamp_size_limit(group_size_limit):
        return {"allowed": False, "reason": "group_full"}
    return {"allowed": True, "reason": "ok"}


def can_remove_community_member(actor_role, target_role, target_is_actor=False,
                                admin_count=1):
    """THE remove gate for a community group.  Mirrors circle_groups semantics:
      - a member removing themselves is a LEAVE, not a remove ('use_leave'),
      - only an admin may remove someone else,
      - the last admin cannot be removed (group must keep >=1 admin).
    Returns {allowed, reason}."""
    if target_is_actor:
        return {"allowed": False, "reason": "use_leave"}
    if not has_capability(actor_role, "remove_member"):
        return {"allowed": False, "reason": "not_admin"}
    if is_admin(target_role) and admin_count <= 1:
        return {"allowed": False, "reason": "last_admin"}
    return {"allowed": True, "reason": "ok"}


# ---------------------------------------------------------------------------
# Announcements-only post gate — reuse circle_groups.can_post
# ---------------------------------------------------------------------------

def can_post_in_group(role, group):
    """May this role post in this community group right now?  The announcements
    group (and any topic with announcements_only) is admins-only.  Delegates to
    circle_groups.can_post so there is ONE announcements gate."""
    return can_post(role, bool(group.get("announcements_only")))


def post_blocked_reason(lang="bn"):
    return pick(
        lang,
        "এই গ্রুপে শুধু অ্যাডমিনরা পোস্ট করতে পারেন।",
        "Only admins can post in this group.",
    )


# ---------------------------------------------------------------------------
# Member card — name + photo ALWAYS, phone HIDDEN BY DEFAULT
# ---------------------------------------------------------------------------
# Community members see each other's name + photo (they chose to join the same
# community).  A phone number is private: it is only included when the OWNER of
# that number has turned sharing ON.  Default is OFF.

def member_card(member, viewer_id=None):
    """Build the card another community member sees.  `member` carries
    {member_id, name, photo_ref, show_phone(bool, default False), phone}.
    Returns {member_id, name, photo_ref, phone|None, phone_hidden(bool)}.
    Phone is present ONLY if the member opted in (show_phone truthy).  The
    member always sees their OWN phone."""
    show = bool(member.get("show_phone", False))
    is_self = viewer_id is not None and viewer_id == member.get("member_id")
    reveal = show or is_self
    return {
        "member_id": member.get("member_id"),
        "name": member.get("name"),
        "photo_ref": member.get("photo_ref"),
        "phone": member.get("phone") if reveal else None,
        "phone_hidden": not reveal,
    }


def set_show_phone(member, show):
    """Toggle a member's phone-visibility opt-in.  Returns the updated member
    dict (default stays hidden)."""
    member = dict(member)
    member["show_phone"] = bool(show)
    return member


# ---------------------------------------------------------------------------
# "Who in my communities can message me" — EVERYONE | NOBODY (default EVERYONE)
# ---------------------------------------------------------------------------

WHO_EVERYONE = "everyone"
WHO_NOBODY = "nobody"
WHO_MODES = (WHO_EVERYONE, WHO_NOBODY)
WHO_DEFAULT = WHO_EVERYONE


def normalize_who_can_msg(mode):
    m = (mode or "").strip().lower()
    return m if m in WHO_MODES else WHO_DEFAULT


# ---------------------------------------------------------------------------
# Cross-community messaging — the CONSENT FLOW (message requests)
# ---------------------------------------------------------------------------
# The crux of the feature + the main safety surface.  Two community members may
# message, BUT a message from someone the recipient has NOT consented to does
# NOT reach the normal inbox — it becomes a MESSAGE REQUEST the recipient
# Accepts / Declines / Blocks / Reports.  Calls are blocked until acceptance.

# A prior relationship that counts as "already consented":
#   - they are in each other's circle (mutually accepted relationship), OR
#   - a previous message request between them was already accepted.

def _already_connected(rel_state, prior_request_state, blocked_either):
    if blocked_either:
        return False
    if rel_state == REQ_ACCEPTED:
        return True
    if prior_request_state == MSGREQ_ACCEPTED:
        return True
    return False


def can_direct_message(rel_state=None, prior_request_state=None,
                       recipient_who_can_msg=WHO_DEFAULT, blocked_either=False,
                       same_community=True):
    """THE server-enforced messaging gate.  Returns
    {allowed, route, reason, calls_allowed}.

      route ∈ {'direct','message_request', None}

    DECISION ORDER:
      1. blocked (either direction) → not allowed, route=None.
      2. not in a shared community → not allowed (communities only connect
         people inside the same community).
      3. already connected (circle OR a previously-accepted request) → DIRECT
         chat, calls allowed.
      4. recipient's who-can-msg == NOBODY → blocked entirely (no request even).
      5. otherwise (who == EVERYONE, no prior consent) → the message becomes a
         MESSAGE REQUEST; calls are NOT allowed until the recipient accepts.
    """
    who = normalize_who_can_msg(recipient_who_can_msg)
    if blocked_either:
        return {"allowed": False, "route": None, "reason": "blocked",
                "calls_allowed": False}
    if not same_community:
        return {"allowed": False, "route": None, "reason": "not_in_community",
                "calls_allowed": False}
    if _already_connected(rel_state, prior_request_state, blocked_either):
        return {"allowed": True, "route": "direct", "reason": "connected",
                "calls_allowed": True}
    if who == WHO_NOBODY:
        return {"allowed": False, "route": None, "reason": "who_nobody",
                "calls_allowed": False}
    return {"allowed": True, "route": "message_request",
            "reason": "first_contact_outside_circle", "calls_allowed": False}


def can_call(rel_state=None, prior_request_state=None, blocked_either=False):
    """Calls require an existing connection — NO calls before a message request
    is accepted.  Returns {allowed, reason}."""
    if blocked_either:
        return {"allowed": False, "reason": "blocked"}
    if _already_connected(rel_state, prior_request_state, blocked_either):
        return {"allowed": True, "reason": "connected"}
    return {"allowed": False, "reason": "not_connected"}


# ---------------------------------------------------------------------------
# Message-request FSM (Accept / Decline / Block / Report)
# ---------------------------------------------------------------------------

MSGREQ_PENDING = "pending"
MSGREQ_ACCEPTED = "accepted"
MSGREQ_DECLINED = "declined"
MSGREQ_BLOCKED = "blocked"
MSGREQ_STATES = {MSGREQ_PENDING, MSGREQ_ACCEPTED, MSGREQ_DECLINED, MSGREQ_BLOCKED}

_MSGREQ_TRANSITIONS = {
    MSGREQ_PENDING: {
        "accept": MSGREQ_ACCEPTED,
        "decline": MSGREQ_DECLINED,
        "block": MSGREQ_BLOCKED,
    },
    MSGREQ_ACCEPTED: {"block": MSGREQ_BLOCKED},
    MSGREQ_DECLINED: {"block": MSGREQ_BLOCKED},   # declining then blocking
    MSGREQ_BLOCKED: {"unblock": MSGREQ_DECLINED},
}


def apply_msgreq_event(state, event):
    """Advance a message request.  Returns (new_state, changed).  Report is a
    side-channel (see report_sender) and does NOT change the FSM state, so it is
    not an event here."""
    state = state if state in MSGREQ_STATES else MSGREQ_PENDING
    nxt = _MSGREQ_TRANSITIONS.get(state, {}).get(event)
    if nxt is None:
        return state, False
    return nxt, True


def new_message_request(sender_id, recipient_id, community_id, first_ciphertext,
                        first_nonce, sender_key_id, now=None):
    """Create a MESSAGE-REQUEST row holding the FIRST (still-ciphertext) message.
    Server stores ciphertext only; it never reads the body.  The recipient sees
    the sender's name+photo (member_card) and the decrypted first line on their
    device.  Returns the row the integrator persists."""
    now = now or datetime.now(timezone.utc)
    return {
        "sender_id": sender_id,
        "recipient_id": recipient_id,
        "community_id": community_id,
        "state": MSGREQ_PENDING,
        "first_ciphertext": first_ciphertext,   # opaque
        "first_nonce": first_nonce,             # opaque
        "sender_key_id": sender_key_id,
        "created_at": now.isoformat(),
    }


def report_sender(reporter_id, sender_id, community_id, reason, note="",
                  also_block=False, lang="bn"):
    """Report the sender of a message request (optionally block too).  Mirrors
    the 1:1 report shape.  Returns the report payload."""
    reasons = ("spam", "harassment", "scam", "impersonation", "other")
    reason = reason if reason in reasons else "other"
    return {
        "kind": "community_msgreq_report",
        "reporter_id": int(reporter_id),
        "sender_id": int(sender_id),
        "community_id": community_id,
        "reason": reason,
        "note": (note or "")[:500],
        "also_block": bool(also_block),
        "auto_flag": reason in ("harassment", "scam", "impersonation"),
        "message": pick(lang,
                        "রিপোর্ট জমা হয়েছে।",
                        "Report submitted."),
    }


# ---------------------------------------------------------------------------
# Rate limit — new message requests per sender (sliding window, anti-spam)
# ---------------------------------------------------------------------------
# A sender cannot blast message requests at the whole community.  We cap the
# number of NEW message requests a sender may create within a rolling window.
# The integrator passes the sender's recent request timestamps; this returns
# whether a new one is allowed + when the next slot frees up.

MSGREQ_RATE_MAX = 5              # new requests...
MSGREQ_RATE_WINDOW_SEC = 3600    # ...per this rolling window (1 hour)


def _as_dt(v):
    if isinstance(v, datetime):
        return v if v.tzinfo else v.replace(tzinfo=timezone.utc)
    if isinstance(v, (int, float)):
        return datetime.fromtimestamp(v, tz=timezone.utc)
    if isinstance(v, str):
        try:
            d = datetime.fromisoformat(v.replace("Z", "+00:00"))
            return d if d.tzinfo else d.replace(tzinfo=timezone.utc)
        except ValueError:
            return None
    return None


def check_msgreq_rate(recent_request_times, now=None,
                      max_in_window=MSGREQ_RATE_MAX,
                      window_sec=MSGREQ_RATE_WINDOW_SEC):
    """Sliding-window rate limit for NEW message requests from one sender.
    `recent_request_times` is a list of this sender's recent request timestamps
    (iso str / epoch / datetime).  Returns
    {allowed, count, remaining, retry_after_sec}.  Only timestamps inside the
    window count; `allowed` is False once the cap is reached."""
    now = now or datetime.now(timezone.utc)
    cutoff = now - timedelta(seconds=window_sec)
    in_window = []
    for t in (recent_request_times or []):
        dt = _as_dt(t)
        if dt is not None and dt > cutoff:
            in_window.append(dt)
    count = len(in_window)
    allowed = count < max_in_window
    remaining = max(0, max_in_window - count)
    retry_after = 0
    if not allowed and in_window:
        oldest = min(in_window)
        retry_after = int((oldest + timedelta(seconds=window_sec) - now).total_seconds())
        retry_after = max(0, retry_after)
    return {
        "allowed": allowed,
        "count": count,
        "remaining": remaining,
        "retry_after_sec": retry_after,
    }


def rate_limited_message(retry_after_sec, lang="bn"):
    mins = max(1, (retry_after_sec + 59) // 60)
    return pick(
        lang,
        f"অনেকগুলো মেসেজ রিকোয়েস্ট পাঠিয়েছেন। {mins} মিনিট পর আবার চেষ্টা করুন।",
        f"Too many message requests. Try again in about {mins} min.",
    )


# ---------------------------------------------------------------------------
# Bilingual labels / notifications (no Bangla in .dart)
# ---------------------------------------------------------------------------

def join_mode_label(mode, lang="bn"):
    if normalize_join_mode(mode) == JOIN_OPEN:
        return pick(lang, "যে কেউ যোগ দিতে পারে", "Anyone can join")
    return pick(lang, "অনুমোদন লাগবে", "Requires approval")


def who_can_msg_label(mode, lang="bn"):
    if normalize_who_can_msg(mode) == WHO_NOBODY:
        return pick(lang, "কেউ না", "Nobody")
    return pick(lang, "সবাই", "Everyone")


def message_request_banner(lang="bn"):
    return pick(
        lang,
        "এই ব্যক্তি আপনার সার্কেলে নেই। আপনি মেসেজ রিকোয়েস্ট গ্রহণ করলে কথা বলতে পারবেন।",
        "This person isn't in your circle. Accept the message request to chat.",
    )


def who_nobody_blocked_message(lang="bn"):
    return pick(
        lang,
        "এই ব্যক্তি কমিউনিটির মেসেজ গ্রহণ করছেন না।",
        "This person isn't accepting community messages.",
    )


def join_requested_notification(name, group_name, lang="bn"):
    return {
        "kind": "community_join_requested",
        "body": pick(lang,
                     f"{name} \"{group_name}\" গ্রুপে যোগ দিতে চান।",
                     f"{name} wants to join \"{group_name}\"."),
    }


def join_approved_notification(group_name, lang="bn"):
    return {
        "kind": "community_join_approved",
        "body": pick(lang,
                     f"আপনি এখন \"{group_name}\" গ্রুপের সদস্য।",
                     f"You're now a member of \"{group_name}\"."),
    }
