"""
msg_channel.py — Assisto Messenger "CHANNELS" logic (Messenger wave, Step 3).

Pure Python, deterministic, NO Django, NO DB, NO AI key.  This module is the
SERVER-SIDE authority for broadcast CHANNELS; the integrator wires it into the
channel views so a client can NEVER bypass the rules.  Original design, built
feature-for-feature against WhatsApp Channels, but NONE of their UI / copy /
assets / internal shapes are reused.

────────────────────────────────────────────────────────────────────────────
WHAT A CHANNEL IS  (and is NOT)
────────────────────────────────────────────────────────────────────────────
A CHANNEL is a ONE-TO-MANY broadcast: the owner (and appointed channel admins)
PUBLISH posts; FOLLOWERS consume them.  A post may be text, photos, videos,
links, or a poll.  Followers may REACT (emoji) to a post — and that is the ONLY
upstream action they get.  A follower CANNOT reply to a post, CANNOT comment,
and CANNOT DM the owner/admin through the channel.  `can_follower_reply()` and
`can_follower_dm_admin()` ALWAYS return False — there is no setting that opens
them, by design, so a follower can never contact the publisher through the
channel surface.

A channel exposes: a FOLLOWER COUNT, a profile (name / handle / description /
photo), a CATEGORY and a LANGUAGE, a VERIFIED badge, channel ADMINS, ANALYTICS
(views / reactions / follower-growth — derived from COUNTS only, never PII),
plus per-follower MUTE, UNFOLLOW, and a public SHARE LINK.

════════════════════════════════════════════════════════════════════════════
NOT E2E — THIS IS THE DELIBERATE EXCEPTION
════════════════════════════════════════════════════════════════════════════
Channel content is PUBLIC and MODERATABLE, so it is **NOT end-to-end
encrypted**.  Posts are stored as PLAINTEXT on the server (`CONTENT_NOT_E2E`)
precisely so the content can be moderated / taken down / reported.  This is the
OPPOSITE of personal chats and private groups, which remain E2E (server stores
ciphertext only — see core.logic.circle / circle_groups).  THIS MODULE MUST NOT
TOUCH those E2E surfaces; it only governs the public channel surface.
`post_is_e2e()` returns False and `is_e2e_surface()` returns False for every
channel object, as a machine-checkable guard that nobody wires channel content
through the ciphertext relay.

════════════════════════════════════════════════════════════════════════════
FOLLOWER PRIVACY  — THE CRITICAL, SERVER-ENFORCED CONTRACT
════════════════════════════════════════════════════════════════════════════
Two independent switches decide who appears in a follower listing:

  1. CHANNEL-level  : the owner sets the follower LIST to PUBLIC or PRIVATE.
                      PRIVATE  → nobody but the owner/admins may enumerate it.
                      PUBLIC   → anyone may enumerate it … but see rule 2.

  2. FOLLOWER-level : each follower chooses their OWN visibility:
                      "show"       → may appear in a listing (subject to rule 1)
                      "count_only" → is NEVER shown to anyone, ever.
                      DEFAULT IS "count_only".  A new follower is invisible
                      until they explicitly opt in.

THE HARD RULE (enforced in `serialize_follower_list` and proven by tests):
  A "count_only" follower is NEVER returned in ANY listing — not when the list
  is public, not to the channel owner, not to a channel admin, not to anyone.
  They STILL increment the follower COUNT.  The choice is changeable anytime
  (`set_follower_visibility`) and defaults back to count_only is the safe side.

So the follower count and the follower listing are decoupled: count ≥ number
of names ever returned, and the gap is exactly the count-only followers, which
no viewer can resolve.  Analytics never expose identities either — they are
pure aggregates over counts.

════════════════════════════════════════════════════════════════════════════
VERIFIED BADGE
════════════════════════════════════════════════════════════════════════════
`verified` is an OWNER-APPROVED flag only.  A channel can NEVER self-grant it.
`request_verification()` only records a pending request; `grant_verification()`
requires a platform-operator actor and is the ONLY path that flips the flag on.
`is_verified()` reads the stored flag and the approving actor; a channel object
whose flag was set without an operator approver is treated as NOT verified.

────────────────────────────────────────────────────────────────────────────
WHAT LIVES HERE (logic/state only — DB models & HTTP endpoints are the
integrator's; see .phaseB/msg_channel_integration.md):
  - Channel profile create / edit (sanitize name/handle/desc/category/language).
  - Role matrix: OWNER / ADMIN / FOLLOWER; capability checks.
  - Follow / unfollow / mute; follower COUNT; follower VISIBILITY switch.
  - serialize_follower_list(viewer, ...) — the privacy-safe enumerator.
  - Post build / validate (NOT E2E, plaintext, moderatable); reactions.
  - Polls: create / vote / tally BY INDEX (same index discipline as groups).
  - Analytics from counts only (no PII).
  - Verification request / grant (operator-only).
  - Share link mint / parse.
This module is self-contained (no imports from other circle_* logic) so the
E2E modules and this NOT-E2E module can never be confused for one another.
"""

from __future__ import annotations

import hashlib
import re

# ───────────────────────────── constants ──────────────────────────────────

# Roles on a channel.
ROLE_OWNER = "owner"
ROLE_ADMIN = "admin"
ROLE_FOLLOWER = "follower"
ROLES = (ROLE_OWNER, ROLE_ADMIN, ROLE_FOLLOWER)

# Follower-list visibility set by the channel owner.
LIST_PUBLIC = "public"
LIST_PRIVATE = "private"

# Per-follower visibility.  DEFAULT is count_only (the private, safe side).
VIS_SHOW = "show"
VIS_COUNT_ONLY = "count_only"
VIS_DEFAULT = VIS_COUNT_ONLY

# Post kinds.  Channels broadcast these; NONE of them are E2E.
POST_TEXT = "text"
POST_PHOTO = "photo"
POST_VIDEO = "video"
POST_LINK = "link"
POST_POLL = "poll"
POST_KINDS = (POST_TEXT, POST_PHOTO, POST_VIDEO, POST_LINK, POST_POLL)

# Channel content is PUBLIC + MODERATABLE → stored in the clear, NOT E2E.
CONTENT_NOT_E2E = "plaintext-moderatable-v1"

# Verification states.
VERIF_NONE = "none"
VERIF_PENDING = "pending"
VERIF_VERIFIED = "verified"

# Limits.
MAX_NAME = 80
MAX_DESC = 500
MAX_HANDLE = 32
MAX_ADMINS = 20
MAX_POLL_OPTIONS = 12
MAX_REACTION_LEN = 16

# A small, curated category set (extend per deployment).  Kept opaque keys.
CATEGORIES = (
    "news", "education", "business", "health", "religion",
    "entertainment", "sports", "technology", "community", "other",
)
# Language is an ISO-ish tag; we whitelist the two app languages + "other".
LANGUAGES = ("bn", "en", "other")


# ───────────────────────────── role / capability ──────────────────────────

# Capability matrix.  FOLLOWERS deliberately get ONLY read + react.
_CAPS = {
    ROLE_OWNER: {
        "publish", "edit_post", "delete_post", "edit_profile", "add_admin",
        "remove_admin", "view_analytics", "set_list_visibility",
        "request_verification", "view_full_followers", "delete_channel",
        "pin_post", "create_poll", "close_poll",
    },
    ROLE_ADMIN: {
        "publish", "edit_post", "delete_post", "edit_profile",
        "view_analytics", "view_full_followers", "pin_post",
        "create_poll", "close_poll",
    },
    # A follower can read, react, mute, unfollow, and change THEIR OWN
    # visibility.  Nothing else.  No reply, no comment, no DM.
    ROLE_FOLLOWER: {
        "read", "react", "mute", "unfollow", "set_own_visibility", "vote",
    },
}


def has_capability(role, cap):
    """True iff `role` holds `cap`."""
    return cap in _CAPS.get(role, set())


def can_publish(role):
    """Only owner/admin may publish a post."""
    return has_capability(role, "publish")


def can_follower_reply(*_a, **_k):
    """HARD RULE: a follower can NEVER reply to a channel post.  There is no
    argument, setting, or role that makes this True for a follower surface —
    channels are one-to-many broadcast.  Always False."""
    return False


def can_follower_dm_admin(*_a, **_k):
    """HARD RULE: a follower can NEVER DM the owner/admin through the channel.
    The channel surface exposes no upstream message path.  Always False."""
    return False


def can_react(role):
    """A follower (and owner/admin) may react to a post."""
    return has_capability(role, "react") or role in (ROLE_OWNER, ROLE_ADMIN)


# ───────────────────────────── profile ────────────────────────────────────

_HANDLE_RE = re.compile(r"[^a-z0-9_]")


def _clip(s, n):
    s = "" if s is None else str(s)
    s = s.replace("\x00", "").strip()
    return s[:n]


def sanitize_handle(handle):
    """Normalise a public @handle: lowercase, [a-z0-9_] only, length-capped.
    Returns "" if nothing usable remains (caller should reject empty)."""
    h = (handle or "").strip().lower().lstrip("@")
    h = _HANDLE_RE.sub("", h)
    return h[:MAX_HANDLE]


def sanitize_category(category):
    c = (category or "").strip().lower()
    return c if c in CATEGORIES else "other"


def sanitize_language(language):
    lang = (language or "").strip().lower()
    return lang if lang in LANGUAGES else "other"


def new_channel(channel_id, owner_id, name, handle,
                description="", category="other", language="other",
                photo_ref=None, created_at=None):
    """Build a fresh channel record (dict).  New channels start UNVERIFIED and
    with a PRIVATE follower list (owner opts into public).  Raises ValueError
    on an unusable name/handle so the endpoint returns a clean 400."""
    nm = _clip(name, MAX_NAME)
    hd = sanitize_handle(handle)
    if not nm:
        raise ValueError("name_required")
    if not hd:
        raise ValueError("handle_required")
    return {
        "channel_id": channel_id,
        "owner_id": owner_id,
        "name": nm,
        "handle": hd,
        "description": _clip(description, MAX_DESC),
        "category": sanitize_category(category),
        "language": sanitize_language(language),
        "photo_ref": photo_ref,
        "admin_ids": [],
        "list_visibility": LIST_PRIVATE,
        "verified": False,
        "verified_by": None,          # operator actor id, set only on grant
        "verification_state": VERIF_NONE,
        "follower_count": 0,
        "created_at": created_at,
    }


def sanitize_profile_edit(patch):
    """Sanitise an owner/admin profile edit.  ONLY whitelisted, cleaned fields
    survive — a client can never smuggle `verified`, `follower_count`,
    `owner_id`, or `admin_ids` through the profile editor."""
    out = {}
    if "name" in patch:
        out["name"] = _clip(patch["name"], MAX_NAME)
    if "handle" in patch:
        out["handle"] = sanitize_handle(patch["handle"])
    if "description" in patch:
        out["description"] = _clip(patch["description"], MAX_DESC)
    if "category" in patch:
        out["category"] = sanitize_category(patch["category"])
    if "language" in patch:
        out["language"] = sanitize_language(patch["language"])
    if "photo_ref" in patch:
        out["photo_ref"] = patch["photo_ref"]
    return out


def role_of(channel, user_id):
    """Resolve a user's role on a channel: owner / admin / follower-or-viewer.
    Returns ROLE_FOLLOWER for anyone who is not owner/admin (the capability
    matrix then limits them to read/react — an unauthenticated viewer gets even
    less because the endpoint checks follow state separately)."""
    if user_id is not None and user_id == channel.get("owner_id"):
        return ROLE_OWNER
    if user_id is not None and user_id in (channel.get("admin_ids") or []):
        return ROLE_ADMIN
    return ROLE_FOLLOWER


def add_admin(channel, actor_id, new_admin_id):
    """Owner appoints a channel admin.  Returns (channel, ok, reason)."""
    if role_of(channel, actor_id) != ROLE_OWNER:
        return channel, False, "owner_only"
    if new_admin_id == channel.get("owner_id"):
        return channel, False, "owner_not_admin"
    admins = list(channel.get("admin_ids") or [])
    if new_admin_id in admins:
        return channel, True, "already_admin"
    if len(admins) >= MAX_ADMINS:
        return channel, False, "admin_cap"
    admins.append(new_admin_id)
    ch = dict(channel)
    ch["admin_ids"] = admins
    return ch, True, "ok"


def remove_admin(channel, actor_id, admin_id):
    """Owner removes a channel admin.  Returns (channel, ok, reason)."""
    if role_of(channel, actor_id) != ROLE_OWNER:
        return channel, False, "owner_only"
    admins = list(channel.get("admin_ids") or [])
    if admin_id not in admins:
        return channel, False, "not_admin"
    admins.remove(admin_id)
    ch = dict(channel)
    ch["admin_ids"] = admins
    return ch, True, "ok"


# ───────────────────────── follower list visibility ───────────────────────

def set_list_visibility(channel, actor_id, visibility):
    """Owner sets the follower LIST to public/private.  Owner-only.
    Returns (channel, ok, reason)."""
    if role_of(channel, actor_id) != ROLE_OWNER:
        return channel, False, "owner_only"
    if visibility not in (LIST_PUBLIC, LIST_PRIVATE):
        return channel, False, "bad_visibility"
    ch = dict(channel)
    ch["list_visibility"] = visibility
    return ch, True, "ok"


def normalize_follower_visibility(value):
    """Coerce a per-follower visibility to a legal value, DEFAULTING to
    count_only (the private side) for anything unknown/missing/None."""
    return VIS_SHOW if value == VIS_SHOW else VIS_COUNT_ONLY


def new_follower(user_id, followed_at=None, visibility=None, muted=False):
    """Build a follower record.  `visibility` DEFAULTS to count_only — a brand
    new follower is invisible until they opt in."""
    return {
        "user_id": user_id,
        "visibility": normalize_follower_visibility(visibility),
        "muted": bool(muted),
        "followed_at": followed_at,
    }


def set_follower_visibility(follower, value):
    """A follower changes THEIR OWN visibility (show / count_only).  Anytime.
    Returns a new follower record."""
    f = dict(follower)
    f["visibility"] = normalize_follower_visibility(value)
    return f


def is_count_only(follower):
    """True iff this follower must NEVER appear in any listing."""
    return normalize_follower_visibility(follower.get("visibility")) == VIS_COUNT_ONLY


# ───────────────────────── follow / count / mute ──────────────────────────

def follow(channel, followers, user_id, followed_at=None, visibility=None):
    """Add `user_id` as a follower (idempotent) and keep follower_count exactly
    in sync with the roster.  Returns (channel, followers, follower_record).
    New followers default to count_only."""
    roster = dict(followers or {})
    if user_id in roster:
        return channel, roster, roster[user_id]
    rec = new_follower(user_id, followed_at=followed_at, visibility=visibility)
    roster[user_id] = rec
    ch = dict(channel)
    ch["follower_count"] = _recount(roster)
    return ch, roster, rec


def unfollow(channel, followers, user_id):
    """Remove a follower.  Returns (channel, followers, removed_bool)."""
    roster = dict(followers or {})
    removed = roster.pop(user_id, None) is not None
    ch = dict(channel)
    ch["follower_count"] = _recount(roster)
    return ch, roster, removed


def set_muted(followers, user_id, muted):
    """A follower mutes / unmutes the channel (no post notifications).  Mute is
    purely the follower's own preference and never affects the count."""
    roster = dict(followers or {})
    if user_id in roster:
        rec = dict(roster[user_id])
        rec["muted"] = bool(muted)
        roster[user_id] = rec
    return roster


def _recount(followers):
    """The follower COUNT is simply the roster size.  EVERY follower counts —
    including count_only ones — which is exactly why count and listing differ."""
    return len(followers or {})


def follower_count(channel=None, followers=None):
    """The authoritative follower count.  Prefer the live roster if given
    (so count_only followers are always included), else the stored field."""
    if followers is not None:
        return _recount(followers)
    return int((channel or {}).get("follower_count") or 0)


# ──────────────────── THE privacy-safe follower enumerator ─────────────────

def serialize_follower_list(channel, followers, viewer_id,
                            limit=None, offset=0):
    """Return a listing that NEVER leaks a count-only follower.

    The ONLY followers that may appear are those with visibility == "show".
    A count_only follower is omitted FOR EVERY VIEWER — the channel owner and
    admins included.  Separately, if the channel's list is PRIVATE, ONLY the
    owner/admins may enumerate at all (non-privileged viewers get an empty list
    but still see the true count).

    Returns a dict:
        {"count": <true follower count, incl. count-only>,
         "listable": <# of show followers the VIEWER is allowed to see>,
         "followers": [{"user_id":..., "muted":...}, ...],
         "list_visibility": "public"|"private",
         "hidden_count_only": <# followers suppressed because count_only>}

    `hidden_count_only` is an AGGREGATE (a number, never ids) so analytics can
    show "N chose to stay private" without ever naming them.
    """
    roster = followers or {}
    total = _recount(roster)

    viewer_role = role_of(channel, viewer_id)
    privileged = viewer_role in (ROLE_OWNER, ROLE_ADMIN)
    list_public = channel.get("list_visibility") == LIST_PUBLIC

    # Count-only followers are suppressed for EVERYONE — compute the aggregate
    # up front so it is reported regardless of who is asking.
    hidden_count_only = sum(1 for f in roster.values() if is_count_only(f))

    # Enumeration gate: private list ⇒ only owner/admins may enumerate at all.
    may_enumerate = list_public or privileged

    rows = []
    if may_enumerate:
        # Deterministic order: by user_id.  Only "show" followers are eligible,
        # so a count_only follower can NEVER enter `rows` — this is the guard.
        eligible = [
            f for f in roster.values()
            if not is_count_only(f)            # ← count-only NEVER shown, to anyone
        ]
        eligible.sort(key=lambda f: _sort_key(f.get("user_id")))
        if offset:
            eligible = eligible[offset:]
        if limit is not None:
            eligible = eligible[:limit]
        rows = [{"user_id": f.get("user_id"), "muted": bool(f.get("muted"))}
                for f in eligible]

    listable = sum(1 for f in roster.values() if not is_count_only(f)) \
        if may_enumerate else 0

    return {
        "count": total,
        "listable": listable,
        "followers": rows,
        "list_visibility": channel.get("list_visibility"),
        "hidden_count_only": hidden_count_only,
    }


def _sort_key(uid):
    # Stable ordering even across mixed id types.
    return (0, uid) if isinstance(uid, int) else (1, str(uid))


# ───────────────────────────── posts (NOT E2E) ────────────────────────────

def is_e2e_surface(_obj=None):
    """GUARD: channel surfaces are NEVER end-to-end encrypted.  Always False.
    Used by the integrator to assert channel content is not routed through the
    ciphertext relay used by personal chats / private groups."""
    return False


def post_is_e2e(_post=None):
    """GUARD: a channel post is NEVER E2E.  Always False.  Channel content is
    public + moderatable, stored as plaintext (CONTENT_NOT_E2E)."""
    return False


def new_post(post_id, channel, author_id, kind, *,
             text="", media_refs=None, link_url=None, poll=None,
             created_at=None):
    """Build a channel post.  Only owner/admins may author.  Content is
    PLAINTEXT (NOT E2E) so it can be moderated.  Returns (post, ok, reason)."""
    role = role_of(channel, author_id)
    if not can_publish(role):
        return None, False, "publish_denied"
    if kind not in POST_KINDS:
        return None, False, "bad_kind"

    post = {
        "post_id": post_id,
        "channel_id": channel.get("channel_id"),
        "author_id": author_id,
        "kind": kind,
        "e2e": False,                       # explicit: channel posts are NOT E2E
        "content_scheme": CONTENT_NOT_E2E,
        "text": _clip(text, 4096),
        "media_refs": list(media_refs or []),
        "link_url": _clip(link_url, 2048) if link_url else None,
        "poll": poll,
        "reactions": {},                    # emoji -> count (aggregate only)
        "views": 0,
        "pinned": False,
        "deleted": False,
        "created_at": created_at,
    }
    ok, reason = validate_post(post)
    if not ok:
        return None, False, reason
    return post, True, "ok"


def validate_post(post):
    """Server-side post validator.  Enforces per-kind required fields and the
    NOT-E2E invariant (a channel post must not claim to be E2E).  Returns
    (ok, reason)."""
    if post.get("e2e") is True:
        return False, "channel_post_must_not_be_e2e"
    kind = post.get("kind")
    if kind not in POST_KINDS:
        return False, "bad_kind"
    if kind == POST_TEXT and not (post.get("text") or "").strip():
        return False, "empty_text"
    if kind in (POST_PHOTO, POST_VIDEO) and not post.get("media_refs"):
        return False, "media_required"
    if kind == POST_LINK and not post.get("link_url"):
        return False, "link_required"
    if kind == POST_POLL and not post.get("poll"):
        return False, "poll_required"
    return True, "ok"


def record_view(post):
    """Increment a post's aggregate view counter.  COUNT only — no viewer id is
    ever stored here, so analytics stay PII-free."""
    p = dict(post)
    p["views"] = int(p.get("views") or 0) + 1
    return p


def add_reaction(post, emoji):
    """A follower reacts.  We store ONLY an aggregate per-emoji COUNT — never
    who reacted — so a reaction cannot be used to enumerate followers or leak a
    count-only follower.  Returns the updated post."""
    e = _clip(emoji, MAX_REACTION_LEN)
    if not e:
        return post
    p = dict(post)
    reactions = dict(p.get("reactions") or {})
    reactions[e] = int(reactions.get(e, 0)) + 1
    p["reactions"] = reactions
    return p


def remove_reaction(post, emoji):
    """Undo a reaction (aggregate count down, floored at 0)."""
    e = _clip(emoji, MAX_REACTION_LEN)
    p = dict(post)
    reactions = dict(p.get("reactions") or {})
    if e in reactions:
        n = int(reactions[e]) - 1
        if n <= 0:
            reactions.pop(e, None)
        else:
            reactions[e] = n
    p["reactions"] = reactions
    return p


# ───────────────────────────── polls (by index) ───────────────────────────

def new_channel_poll(poll_id, option_count, question, options,
                     multi=False, created_at=None):
    """Build a channel poll.  Unlike group polls (E2E, ciphertext labels),
    channel poll text is PLAINTEXT (channels are public).  Tally is still BY
    INDEX.  Returns (poll, ok, reason)."""
    n = int(option_count or 0)
    opts = list(options or [])
    if n < 2 or n > MAX_POLL_OPTIONS:
        return None, False, "bad_option_count"
    if len(opts) != n:
        return None, False, "option_mismatch"
    return {
        "poll_id": poll_id,
        "question": _clip(question, 300),
        "options": [_clip(o, 120) for o in opts],
        "option_count": n,
        "multi": bool(multi),
        "closed": False,
        "created_at": created_at,
    }, True, "ok"


def validate_vote(poll, choices):
    """A vote is a list of option INDICES.  Poll must be open; indices in range;
    no duplicates; single-choice polls take exactly one.  Returns (ok, reason)."""
    if poll.get("closed"):
        return False, "poll_closed"
    if not isinstance(choices, (list, tuple)):
        return False, "choices_not_list"
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
    """Record/replace a voter's choice.  Re-vote REPLACES the previous one.
    Returns (new_votes, ok, reason)."""
    ok, reason = validate_vote(poll, choices)
    if not ok:
        return votes_by_voter, False, reason
    out = dict(votes_by_voter or {})
    out[voter_id] = sorted(set(int(c) for c in choices))
    return out, True, "ok"


def tally_poll(poll, votes_by_voter):
    """Tally BY INDEX.  Returns {counts:[...], total_voters, total_votes,
    leading:[idx,...]}.  Counts are per-option-index aggregates — identities of
    voters are never exposed."""
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


def close_poll(poll):
    """Close a poll (no more votes)."""
    p = dict(poll)
    p["closed"] = True
    return p


# ───────────────────────────── analytics (counts only) ────────────────────

def channel_analytics(channel, posts, follower_count_series=None):
    """Aggregate channel analytics from COUNTS ONLY — never PII, never a
    follower identity.  Inputs:
      - `posts`: list of post dicts (uses their views / reactions aggregates).
      - `follower_count_series`: optional list of (period_label, count) points
        for follower-growth; growth is derived purely from those counts.

    Returns a dict of pure aggregates.  There is deliberately NO per-user,
    per-reactor, or per-viewer field anywhere in the output.
    """
    posts = posts or []
    total_views = sum(int(p.get("views") or 0) for p in posts if not p.get("deleted"))
    total_reactions = 0
    reactions_breakdown = {}
    for p in posts:
        if p.get("deleted"):
            continue
        for emoji, cnt in (p.get("reactions") or {}).items():
            c = int(cnt or 0)
            total_reactions += c
            reactions_breakdown[emoji] = reactions_breakdown.get(emoji, 0) + c

    live_posts = [p for p in posts if not p.get("deleted")]
    post_count = len(live_posts)
    avg_views = round(total_views / post_count, 2) if post_count else 0.0

    growth = _follower_growth(follower_count_series)

    return {
        "follower_count": int(channel.get("follower_count") or 0),
        "post_count": post_count,
        "total_views": total_views,
        "avg_views_per_post": avg_views,
        "total_reactions": total_reactions,
        "reactions_breakdown": reactions_breakdown,
        "follower_growth": growth,
        # explicit, so a reviewer can assert it:
        "contains_pii": False,
    }


def _follower_growth(series):
    """Derive follower-growth from a COUNT series only.  `series` is a list of
    (label, count).  Returns {start, end, net, points:[{label,count,delta}]}."""
    if not series:
        return {"start": 0, "end": 0, "net": 0, "points": []}
    points = []
    prev = None
    for label, count in series:
        c = int(count or 0)
        delta = 0 if prev is None else c - prev
        points.append({"label": label, "count": c, "delta": delta})
        prev = c
    start = int(series[0][1] or 0)
    end = int(series[-1][1] or 0)
    return {"start": start, "end": end, "net": end - start, "points": points}


# ───────────────────────────── verification (owner-approved) ──────────────

def request_verification(channel, actor_id):
    """Owner requests the verified badge.  This ONLY records a PENDING request;
    it NEVER grants the badge.  A channel can never self-verify.
    Returns (channel, ok, reason)."""
    if role_of(channel, actor_id) != ROLE_OWNER:
        return channel, False, "owner_only"
    if channel.get("verified"):
        return channel, True, "already_verified"
    ch = dict(channel)
    ch["verification_state"] = VERIF_PENDING
    return ch, True, "ok"


def grant_verification(channel, operator_actor_id, is_platform_operator):
    """Flip the verified flag ON.  The ONLY path that sets `verified=True`.
    Requires a PLATFORM-OPERATOR actor — the channel owner/admins cannot do it.
    Records the approving operator so `is_verified` can prove provenance.
    Returns (channel, ok, reason)."""
    if not is_platform_operator or operator_actor_id is None:
        return channel, False, "operator_only"
    ch = dict(channel)
    ch["verified"] = True
    ch["verified_by"] = operator_actor_id
    ch["verification_state"] = VERIF_VERIFIED
    return ch, True, "ok"


def revoke_verification(channel, operator_actor_id, is_platform_operator):
    """Operator removes the badge (e.g. on policy violation).  Operator-only."""
    if not is_platform_operator or operator_actor_id is None:
        return channel, False, "operator_only"
    ch = dict(channel)
    ch["verified"] = False
    ch["verified_by"] = None
    ch["verification_state"] = VERIF_NONE
    return ch, True, "ok"


def is_verified(channel):
    """A channel counts as verified ONLY if the flag is set AND an operator
    approver is recorded.  A flag set without an operator approver (i.e. a
    self-grant attempt) is treated as NOT verified."""
    return bool(channel.get("verified")) and channel.get("verified_by") is not None


# ───────────────────────────── share link ─────────────────────────────────

_LINK_PREFIX = "assisto://channel/"


def make_share_link(channel):
    """Mint a PUBLIC share link for a channel.  Channels are public, so the link
    carries only the handle + a short non-secret checksum (tamper hint, not a
    capability).  Anyone with the link may view/follow — that is intended."""
    handle = channel.get("handle") or ""
    cid = str(channel.get("channel_id"))
    digest = hashlib.sha256(f"{cid}:{handle}".encode("utf-8")).hexdigest()[:8]
    return f"{_LINK_PREFIX}{handle}?c={cid}&k={digest}"


def parse_share_link(link):
    """Parse a share link → {"handle":..., "channel_id":..., "checksum":...} or
    None if it is not a channel link.  The checksum is advisory only."""
    if not isinstance(link, str) or not link.startswith(_LINK_PREFIX):
        return None
    rest = link[len(_LINK_PREFIX):]
    handle, _, query = rest.partition("?")
    params = {}
    for part in query.split("&"):
        if "=" in part:
            k, v = part.split("=", 1)
            params[k] = v
    cid = params.get("c")
    if cid is not None and cid.isdigit():
        cid = int(cid)
    return {
        "handle": sanitize_handle(handle),
        "channel_id": cid,
        "checksum": params.get("k"),
    }
