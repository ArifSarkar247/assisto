"""
pa_socialinbox.py — the deterministic engine behind PA SECRETARY MODE
(celebrity tier) UNIFIED SOCIAL INBOX / DM TRIAGE (issue #123, SPEC v2.1 §14,
ADVANCED).

A public-figure's PA triages important DMs / mentions across platforms as a
MANUAL BOARD, offline, with NO key. Each item the PA logs has a platform
(instagram / facebook / messenger / twitter / youtube / other), a `from` handle,
the message text, a PRIORITY (urgent / normal / low) and a STATUS (new /
replied / archived). This engine orders the board (open first → priority →
newest), tallies open counts per platform, and surfaces the urgent queue.

Pure Python, deterministic, no Django, no DB, no network, **no clock**, **no AI**.

HONEST, KEY-GATED — LIVE DM FETCH SEAM (NEVER FABRICATES A MESSAGE)
------------------------------------------------------------------
Pulling REAL DMs/mentions live from Instagram or a Facebook Page needs the
owner's own `instagram` / `messenger` (FB Page) account connected via the
Integrations store (Meta Graph API). Until those keys are present and working,
`inbox_fetch_seam()` HONESTLY returns `{required: True, mock: True, messages:
[]}` — the UI shows a "connect your Page / Instagram account" card and the board
stays a MANUAL triage list. We NEVER invent a DM, a sender or a mention. This is
Assisto's own triage tool — it is NOT a Meta client and never pretends to be one.

Mirrors the conventions of the other pa_*/logic modules.

Run self-tests (no DB):
    python3 -c "import core.logic.pa_socialinbox_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

from datetime import datetime


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ---------------------------------------------------------------- vocabulary
# Platforms the PA may tag an item with (neutral seed keys; UI localises them).
PLAT_INSTAGRAM = "instagram"
PLAT_FACEBOOK = "facebook"
PLAT_MESSENGER = "messenger"
PLAT_TWITTER = "twitter"
PLAT_YOUTUBE = "youtube"
PLAT_OTHER = "other"
PLATFORMS = (PLAT_INSTAGRAM, PLAT_FACEBOOK, PLAT_MESSENGER, PLAT_TWITTER,
             PLAT_YOUTUBE, PLAT_OTHER)

# Priority + deterministic rank (urgent first).
PR_URGENT = "urgent"
PR_NORMAL = "normal"
PR_LOW = "low"
PRIORITIES = (PR_URGENT, PR_NORMAL, PR_LOW)
_PR_RANK = {PR_URGENT: 0, PR_NORMAL: 1, PR_LOW: 2}

# Status (new/replied/archived). "new" is open; the rest are handled.
ST_NEW = "new"
ST_REPLIED = "replied"
ST_ARCHIVED = "archived"
STATUSES = (ST_NEW, ST_REPLIED, ST_ARCHIVED)
_OPEN = (ST_NEW,)

# The honest marker key the live-fetch seam carries. The UI renders the
# localised "connect your Page / Instagram account" copy from this. The two
# Integrations keys that unlock a real fetch (see core/integrations.py REGISTRY).
INBOX_MARKER_KEY = "social_inbox_seam"
SEAM_KEYS = ("instagram", "messenger")  # IG + FB-Page (Meta Graph)


# ------------------------------------------------------------------ parsing

def _parse(dt):
    if not dt:
        return None
    s = str(dt).strip()
    if not s:
        return None
    if s.endswith("Z"):
        s = s[:-1]
    try:
        return datetime.fromisoformat(s)
    except ValueError:
        try:
            return datetime.fromisoformat(s + "T00:00:00")
        except ValueError:
            return None


def _clean(text):
    return " ".join(str(text or "").split()).strip()


# ------------------------------------------------------------- normalization

def normalize_item(item):
    """Coerce a dict into a clean triage item. Unknown platform → other,
    unknown priority → normal, unknown status → new. Never raises; the message
    text is the PA's own log — we never fabricate it."""
    x = dict(item or {})
    plat = x.get("platform")
    if plat not in PLATFORMS:
        plat = PLAT_OTHER
    pr = x.get("priority")
    if pr not in PRIORITIES:
        pr = PR_NORMAL
    st = x.get("status")
    if st not in STATUSES:
        st = ST_NEW
    return {
        "id": x.get("id"),
        "platform": plat,
        "from_handle": _clean(x.get("from_handle") or x.get("from")),
        "message": str(x.get("message") or "").strip(),
        "priority": pr,
        "status": st,
        "at": (str(x.get("at")).strip() if x.get("at") else ""),
        "note": str(x.get("note") or ""),
    }


# ------------------------------------------------------------------- validate

def validate_item(item):
    """A triage item needs either a sender handle or message text; at must
    parse if present."""
    x = normalize_item(item)
    problems = []
    if not x["from_handle"] and not x["message"]:
        problems.append("empty_item")
    if x["at"] and _parse(x["at"]) is None:
        problems.append("bad_at")
    return problems


# ------------------------------------------------------------------ ordering

def is_open(item):
    return normalize_item(item)["status"] in _OPEN


def order_inbox(items):
    """Board order: OPEN (new) before handled, then by priority, then newest
    `at` (undated last within its bucket), then sender, then id — stable."""
    normed = [normalize_item(x) for x in (items or [])]

    def key(m):
        open_rank = 0 if m["status"] in _OPEN else 1
        pr_rank = _PR_RANK.get(m["priority"], 1)
        at = _parse(m["at"])
        # newest first within bucket: no date → last
        return (open_rank, pr_rank, at is None, -(at.timestamp()) if at else 0,
                m["from_handle"].lower(), str(m.get("id") or ""))
    return sorted(normed, key=key)


# ---------------------------------------------------------------- derived

def triage(items):
    """Deterministic triage roll-up: ordered board, open count, per-platform
    open counts, the urgent-open queue and a handled tally. Pure numbers."""
    ordered = order_inbox(items)
    by_platform_open = {p: 0 for p in PLATFORMS}
    open_count = 0
    urgent = []
    handled = 0
    for m in ordered:
        if m["status"] in _OPEN:
            open_count += 1
            by_platform_open[m["platform"]] += 1
            if m["priority"] == PR_URGENT:
                urgent.append(m)
        else:
            handled += 1
    return {
        "items": ordered,
        "count": len(ordered),
        "open_count": open_count,
        "handled_count": handled,
        "by_platform_open": by_platform_open,
        "urgent": urgent,
        "urgent_count": len(urgent),
        "mock": False,
    }


# ------------------------------------------------------- live DM-fetch seam

def inbox_fetch_seam():
    """DOCUMENTED key-gated seam for LIVE DM / mention fetch from the owner's
    own Instagram / Facebook Page (Meta Graph API).

    Honest MOCK: never fetches, never invents a message or a sender. Returns the
    shape the integrator wires to the `instagram` + `messenger` Integrations keys
    when they are present and working. Until then the UI shows a "connect your
    Page / Instagram account" card and the board stays a MANUAL triage list.
    """
    return {
        "action": "fetch",
        "messages": [],        # honest: empty — no account, nothing invented
        "required": True,      # an IG / FB-Page account must be connected
        "keys": list(SEAM_KEYS),
        "mock": True,
        "marker": INBOX_MARKER_KEY,
    }
