"""
msg_organise.py — Assisto Messenger CHAT-ORGANISE + MESSAGE-ACTION backend logic
(reviewer-pass for tickets #86 "Message actions" and #87 "Chat organise").

Pure Python, deterministic, NO Django, NO DB, NO AI key.  Every function takes
plain dicts/values (resolved by the view from the DB) and returns a decision or
a normalised record — it never touches the DB — so the SERVER enforcement cannot
be skipped by the client and every branch is trivially unit-testable.

WHAT THIS ADDS (each SERVER-ENFORCED, each disjoint from msg_messenger_ui.py):

  #87 CHAT ORGANISE (the chat-LIST surface)
    1. PIN / UNPIN  — a per-user pin on a chat, with a CAP and a stable ordering:
       pinned chats float to the top (pin order), the rest by recent activity.
    2. ARCHIVE / UNARCHIVE — move a chat into (out of) the archived view.  The
       partition helper splits a chat list into {active, archived} honestly so
       the UI can render an archived view + an "archived (n)" affordance.
    3. MUTE — mute a chat for a DURATION (8h / 1w / always) → an expiry instant;
       plus a predicate that reports whether a chat is CURRENTLY muted (honest:
       an elapsed mute is treated as un-muted so the UI never lies).
    4. SEARCH — a pure, accent/case-folded chat-list search over name + last
       message, returning a RESULT STATE ('results' | 'no_results' | 'idle') so
       the UI can show a true no-results state distinct from an empty list.

  #86 MESSAGE ACTIONS (the chat-THREAD surface) — the SERVER-SIDE gates the long
      -press set must honour.  These MIRROR circle_messaging windows but are
      framed as the reviewer-pass "can I?" gates the client asks before it shows
      a destructive/confirm action, so the confirm gate is honest:
    5. can_edit_message        — own + text + inside the edit window.
    6. delete_scope_options    — which delete scopes are offered (me / everyone),
       everyone only for own messages inside the delete-everyone window.
    7. edited_marker / deleted_marker — the honest render markers for an edited
       or a (for-everyone) deleted message.
    8. normalise_forward       — the forward envelope flags (forwarded + hop
       count, with the "many times forwarded" threshold) so a forwarded message
       renders an honest label and the hop count can never go backwards.

Windows MIRROR core/logic/circle_messaging.py so client and server agree:
    EDIT_WINDOW_MIN = 15 ; DELETE_EVERYONE_WINDOW_MIN = 60*24*2 (two days).

Run self-tests (no DB):
    python3 -c "import core.logic.msg_organise_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

import unicodedata
from datetime import datetime, timedelta, timezone


# --- windows (MIRROR circle_messaging.py; kept local so this module is pure) ---
EDIT_WINDOW_MIN = 15
DELETE_EVERYONE_WINDOW_MIN = 60 * 24 * 2       # two days
FORWARD_MANY_HOPS = 5                          # "forwarded many times" at >= 5

# --- organise caps / durations ---
PIN_CAP_PER_USER = 5                           # a sane cap on pinned chats
MUTE_8H_SEC = 8 * 3600
MUTE_1W_SEC = 7 * 24 * 3600
MUTE_ALWAYS = "always"                         # a sentinel duration (no expiry)
MUTE_DURATIONS = ("8h", "1w", "always")


def _now(now=None):
    return now or datetime.now(timezone.utc)


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


def _iso(dt):
    dt = _as_dt(dt)
    return dt.isoformat() if dt else None


def _minutes_since(sent_at, now=None):
    at = _as_dt(sent_at)
    if at is None:
        return None
    return (_now(now) - at).total_seconds() / 60.0


# ===========================================================================
# #87 — 1. PIN / UNPIN (cap + stable ordering)
# ===========================================================================
# A pin is a per-user flag on a chat.  Pinned chats float to the TOP in the
# order they were pinned (pin_at ascending); the rest fall below ordered by
# recent activity (at descending).  Toggling is idempotent and capped.

def can_pin_chat(current_pinned_count, is_already_pinned):
    """Return (ok, reason).  Un-pinning is always allowed; pinning is blocked at
    the cap.  Idempotent: pinning an already-pinned chat is a no-op 'ok'."""
    if is_already_pinned:
        return True, "ok"                       # unpin, or re-pin no-op
    if (current_pinned_count or 0) >= PIN_CAP_PER_USER:
        return False, "pin_cap_reached"
    return True, "ok"


def order_chat_list(chats, now=None):
    """Stable ordering for the chat list: PINNED first (by pin_at ascending — the
    order they were pinned), then the rest by activity (`at` descending, newest
    first).  Archived chats are NOT dropped here (that is partition_archived's
    job) — this only orders.  Pure; returns a NEW list."""
    rows = list(chats or [])

    def activity_key(c):
        dt = _as_dt(c.get("at"))
        # newest first -> larger timestamp sorts earlier; missing -> oldest.
        return dt.timestamp() if dt else float("-inf")

    pinned = [c for c in rows if c.get("pinned")]
    rest = [c for c in rows if not c.get("pinned")]

    def pin_key(c):
        dt = _as_dt(c.get("pin_at"))
        return dt.timestamp() if dt else float("inf")   # unknown pin_at last

    pinned.sort(key=pin_key)                     # earliest-pinned at the very top
    rest.sort(key=activity_key, reverse=True)    # most recent activity first
    return pinned + rest


# ===========================================================================
# #87 — 2. ARCHIVE / UNARCHIVE
# ===========================================================================
# Archiving moves a chat into a separate "Archived" view; it stays a real chat
# (never deleted).  Un-archiving restores it to the main list.

def partition_archived(chats):
    """Split a chat list into {'active': [...], 'archived': [...], 'archived_count'}
    honestly.  A chat is archived iff `archived` is truthy.  Pure; preserves the
    input order within each bucket."""
    active, archived = [], []
    for c in (chats or []):
        (archived if c.get("archived") else active).append(c)
    return {"active": active, "archived": archived,
            "archived_count": len(archived)}


def set_archived(chat, archived):
    """Return a NEW chat dict with the archived flag set.  Archiving a PINNED
    chat also clears the pin (a chat cannot be both pinned-to-top and hidden in
    the archive — honest state).  Pure."""
    c = dict(chat or {})
    c["archived"] = bool(archived)
    if archived:
        c["pinned"] = False
        c["pin_at"] = None
    return c


# ===========================================================================
# #87 — 3. MUTE (duration -> expiry; honest "currently muted?" predicate)
# ===========================================================================

def normalize_mute_duration(duration):
    """Snap a requested duration to a known token; unknown -> '8h' (the default
    offered first)."""
    d = (duration or "").strip().lower()
    return d if d in MUTE_DURATIONS else "8h"


def mute_until(duration, now=None):
    """Return the ISO expiry instant for a mute duration, or None for 'always'
    (muted with no expiry).  '8h' / '1w' resolve to a future instant."""
    d = normalize_mute_duration(duration)
    if d == MUTE_ALWAYS:
        return None
    secs = MUTE_8H_SEC if d == "8h" else MUTE_1W_SEC
    return _iso(_now(now) + timedelta(seconds=secs))


def build_mute(chat_ref, duration, now=None):
    """A per-user mute record (pure): the chat it mutes + the expiry (None =
    always).  The integrator stores it; `is_muted` reads it back honestly."""
    d = normalize_mute_duration(duration)
    return {
        "chat_ref": chat_ref,
        "duration": d,
        "muted_at": _iso(_now(now)),
        "mute_until": mute_until(d, now=now),     # None => always
    }


def is_muted(mute_record, now=None):
    """True iff the chat is CURRENTLY muted.  'always' (mute_until is None) stays
    muted; a timed mute whose instant has passed is treated as UN-muted so the
    UI never shows a stale muted badge.  A missing record => not muted."""
    if not mute_record:
        return False
    until = mute_record.get("mute_until")
    if until is None:
        # Distinguish "always" from "never set": only a real 'always' record is
        # muted-forever; a record with no fields at all is not muted.
        return mute_record.get("duration") == MUTE_ALWAYS or bool(
            mute_record.get("muted_at"))
    exp = _as_dt(until)
    if exp is None:
        return False
    return _now(now) <= exp


# ===========================================================================
# #87 — 4. SEARCH (pure fold; honest result state)
# ===========================================================================

def _fold(s):
    """Lower-case + strip combining marks so search is accent/diacritic
    insensitive.  Keeps Bangla intact (it has no case) while folding Latin."""
    s = unicodedata.normalize("NFKD", str(s or "")).casefold()
    return "".join(ch for ch in s if not unicodedata.combining(ch))


def search_chats(chats, query):
    """Filter chats by a space-separated query over the member name + last
    message text.  Every term must match (AND).  Returns
        {'state': 'idle'|'results'|'no_results', 'query': <folded>, 'results': [...]}
    so the UI can show a TRUE no-results state distinct from an empty list.
    An 'Ask Assisto' prefix is stripped (the agent handoff lands later)."""
    raw = (query or "").strip()
    folded = _fold(raw)
    if folded.startswith("ask assisto"):
        folded = folded[len("ask assisto"):].strip()
    if not folded:
        return {"state": "idle", "query": "", "results": list(chats or [])}
    terms = [t for t in folded.split() if t]
    out = []
    for c in (chats or []):
        member = (c.get("member") or {})
        hay = _fold(f"{member.get('name', '')} {c.get('last_text', '')}")
        if all(t in hay for t in terms):
            out.append(c)
    return {"state": "results" if out else "no_results",
            "query": folded, "results": out}


# ===========================================================================
# #86 — 5/6. MESSAGE ACTION GATES (edit / delete scopes)
# ===========================================================================

def can_edit_message(message, now=None):
    """Return (ok, reason).  A message is editable iff it is MINE, text, not
    already deleted-for-everyone, and still inside the edit window."""
    m = message or {}
    if not m.get("mine"):
        return False, "not_mine"
    if (m.get("content_type") or "text") != "text":
        return False, "not_text"
    if m.get("deleted") == "everyone":
        return False, "deleted"
    mins = _minutes_since(m.get("at"), now=now)
    if mins is None:
        return False, "unknown_time"
    if mins > EDIT_WINDOW_MIN:
        return False, "edit_window_passed"
    return True, "ok"


def delete_scope_options(message, now=None):
    """Which delete scopes the long-press menu may OFFER for a message:
        always 'me'; 'everyone' only when the message is MINE, not already
        deleted-for-everyone, and inside the delete-everyone window.
    Returns a list preserving UI order ['me', 'everyone']."""
    m = message or {}
    opts = ["me"]
    if m.get("deleted") == "everyone":
        return opts
    mins = _minutes_since(m.get("at"), now=now)
    if (m.get("mine") and mins is not None
            and mins <= DELETE_EVERYONE_WINDOW_MIN):
        opts.append("everyone")
    return opts


def apply_delete(message, scope):
    """Return a NEW message dict reflecting the delete.  'everyone' tombstones
    the message (body cleared, honest deleted marker); 'me' marks it removed for
    this user only.  The server stores ciphertext only — clearing the body here
    is the client-side render decision the view mirrors by tombstoning."""
    m = dict(message or {})
    if scope == "everyone":
        m["deleted"] = "everyone"
        m["text"] = ""
    else:
        m["deleted"] = "me"
    return m


# ===========================================================================
# #86 — 7. HONEST RENDER MARKERS (edited / deleted)
# ===========================================================================

def edited_marker(message):
    """True iff the bubble should show the '(edited)' marker — edited AND not
    tombstoned (a deleted-for-everyone message never shows 'edited')."""
    m = message or {}
    return bool(m.get("edited")) and m.get("deleted") != "everyone"


def deleted_marker(message):
    """'everyone' | 'me' | '' — what tombstone the bubble renders.  Honest: an
    'everyone' delete shows the deleted placeholder; 'me' hides the row."""
    m = message or {}
    d = m.get("deleted")
    return d if d in ("everyone", "me") else ""


# ===========================================================================
# #86 — 8. FORWARD (hop count can never go backwards; many-times label)
# ===========================================================================

def normalize_forward(source_message):
    """Return {forwarded, forward_hops, many_times} for a message being forwarded
    FROM `source_message`.  The hop count increments by one and can never
    decrease; at/above FORWARD_MANY_HOPS the UI shows the 'forwarded many times'
    label (an honest provenance signal)."""
    src = source_message or {}
    hops = max(0, int(src.get("forward_hops") or 0)) + 1
    return {"forwarded": True, "forward_hops": hops,
            "many_times": hops >= FORWARD_MANY_HOPS}
