"""
circle_privacy.py — Assisto "Connected Circle" PRIVACY & CONTROLS (M1 item 6).

Pure Python, deterministic, no DB, no AI key.  These are the SERVER-ENFORCED
decision functions; the integrator wires each into the relevant view so a
client CANNOT skip enforcement.  Benchmarked against WhatsApp + Messenger
privacy controls.

THE PRIVACY CONTRACT (owner-specified, enforced here — safe defaults):
  - Incoming calls: a member chooses who may ring them — everyone-in-circle /
    only chosen people / only chosen relationship types / nobody — plus a DND
    schedule with an OPTIONAL family exception.  A blocked call is silent; a
    DND-suppressed or restricted call still LOGS a missed call.
  - Block (silent): a blocked person cannot message, call, invite, or see any
    status/last-seen/profile.  They are never told; to them nothing changes.
  - Restrict: messages land in a SEPARATE inbox with no notifications; the
    restricted person cannot see your active status or read receipts, and their
    calls do not ring (but are logged as missed).
  - Report: optionally attaches recent messages and may block in the same step.
  - Visibility of last-seen / active-status / profile-photo / about / status =
    everyone-in-circle / family-only / nobody.
  - Read-receipts + typing: on/off with the WhatsApp RECIPROCAL rule — if I turn
    OFF read receipts, I also stop seeing YOURS.
  - Mute (8h / 1 week / always), archive, pin, chat lock (PIN/fingerprint),
    delete chat.

All functions take plain dicts/values (resolved by the view from the DB) and
return a decision — never touching the DB — so they are trivially unit-testable
and cannot be short-circuited by the client.

Run self-tests (no DB):
    python3 -c "import core.logic.circle_privacy_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

from datetime import datetime, time, timezone


def pick(lang, bn, en):
    return en if lang == "en" else bn


# Close-family relation codes (mirror circle.CLOSE_FAMILY) — the "family" bucket
# for family-only visibility and the DND family exception.  Kept local so this
# module has no import cycle; the integrator may pass circle.is_close_family.
_FAMILY_RELATIONS = {"father", "mother", "child", "parent", "husband", "wife",
                     "spouse", "brother", "sister", "sibling"}


def is_family_relation(code):
    return (code or "").strip().lower() in _FAMILY_RELATIONS


# ---------------------------------------------------------------------------
# Relationship control state: block / restrict
# ---------------------------------------------------------------------------
# Each is a per-pair flag the owner sets on the OTHER member.  They are distinct:
#   block    -> hard, silent, two-way invisibility; no message/call/invite.
#   restrict -> soft; message delivered to a filtered inbox, no notification,
#               no active-status / read-receipt leak, calls don't ring.

def apply_block(blocked_set, target_id, on=True):
    """Return the updated set of blocked member ids."""
    s = set(blocked_set or [])
    if on:
        s.add(target_id)
    else:
        s.discard(target_id)
    return s


def apply_restrict(restricted_set, target_id, on=True):
    s = set(restricted_set or [])
    if on:
        s.add(target_id)
    else:
        s.discard(target_id)
    return s


def is_blocked(me, other_id):
    """True if EITHER side blocked the other.  Block is symmetric in effect:
    a person I blocked can't reach me, and (WhatsApp-style) I also cannot reach
    someone who blocked me.  `me` carries my blocked set + who-blocked-me set."""
    me = me or {}
    return (other_id in set(me.get("blocked") or [])
            or other_id in set(me.get("blocked_by") or []))


def is_restricted(me, other_id):
    """True if I have restricted `other_id` (one-directional, my view)."""
    return other_id in set((me or {}).get("restricted") or [])


# ---------------------------------------------------------------------------
# Messaging gate (block + restrict aware) — the relay calls this
# ---------------------------------------------------------------------------

def deliver_decision(sender, recipient):
    """Where does a message from `sender` to `recipient` go?  Returns
        {deliver, inbox, notify, reason}
    inbox  = "normal" | "restricted" | None (dropped)
    This is SERVER-ENFORCED in the message relay view: a blocked sender is
    silently dropped (deliver=False); a restricted sender is delivered to the
    filtered inbox with no notification.

    `recipient` dict carries: blocked (set), blocked_by (set), restricted (set).
    `sender` dict carries: id.
    """
    sid = (sender or {}).get("id")
    rcp = recipient or {}
    # block: the recipient blocked the sender -> silently drop.
    if sid in set(rcp.get("blocked") or []):
        return {"deliver": False, "inbox": None, "notify": False, "reason": "blocked"}
    # the sender blocked the recipient -> sender shouldn't be messaging anyway;
    # drop so a stale client can't leak.
    if sid in set(rcp.get("blocked_by") or []):
        return {"deliver": False, "inbox": None, "notify": False, "reason": "blocked"}
    # restrict: deliver quietly to the filtered inbox.
    if sid in set(rcp.get("restricted") or []):
        return {"deliver": True, "inbox": "restricted", "notify": False,
                "reason": "restricted"}
    return {"deliver": True, "inbox": "normal", "notify": True, "reason": "ok"}


# ---------------------------------------------------------------------------
# Visibility resolver: last-seen / active / profile-photo / about / status
# ---------------------------------------------------------------------------
# Each field has an audience policy chosen by the owner.  Resolution also honours
# block (blocked -> never) and restrict (restricted -> no active-status).

VIS_EVERYONE = "everyone"     # everyone in my circle
VIS_FAMILY = "family"         # close-family relations only
VIS_NOBODY = "nobody"
VIS_POLICIES = (VIS_EVERYONE, VIS_FAMILY, VIS_NOBODY)

VIS_FIELDS = ("last_seen", "active_status", "profile_photo", "about", "status")

# Safe defaults (owner can relax): profile visible to circle; last-seen/active
# to family; about to circle; status (stories) to circle.
_DEFAULT_VISIBILITY = {
    "last_seen": VIS_FAMILY,
    "active_status": VIS_FAMILY,
    "profile_photo": VIS_EVERYONE,
    "about": VIS_EVERYONE,
    "status": VIS_EVERYONE,
}


def default_visibility():
    return dict(_DEFAULT_VISIBILITY)


def normalize_visibility(policy):
    """Coerce an arbitrary dict into {field: policy} over VIS_FIELDS."""
    policy = policy or {}
    out = {}
    for f in VIS_FIELDS:
        v = str(policy.get(f, _DEFAULT_VISIBILITY[f]))
        out[f] = v if v in VIS_POLICIES else _DEFAULT_VISIBILITY[f]
    return out


def can_see_field(owner, viewer, field):
    """Can `viewer` see `owner`'s `field`?  SERVER-ENFORCED projection: the view
    builds the member payload for `viewer` by calling this per field, so a
    hidden field is never serialized.

    `owner` dict:
        visibility     -> {field: policy}
        blocked        -> set of ids owner blocked
        blocked_by     -> set of ids who blocked owner
        restricted     -> set of ids owner restricted
    `viewer` dict:
        id
        relation       -> viewer's relation code to owner (for family bucket)
    """
    owner = owner or {}
    viewer = viewer or {}
    vid = viewer.get("id")

    # Block always wins: a blocked viewer sees nothing.
    if vid in set(owner.get("blocked") or []) or vid in set(owner.get("blocked_by") or []):
        return False

    # Restricted viewers can't see active status specifically.
    if field == "active_status" and vid in set(owner.get("restricted") or []):
        return False

    pol = normalize_visibility(owner.get("visibility")).get(field, VIS_NOBODY)
    if pol == VIS_NOBODY:
        return False
    if pol == VIS_EVERYONE:
        return True
    if pol == VIS_FAMILY:
        return is_family_relation(viewer.get("relation"))
    return False


# ---------------------------------------------------------------------------
# Read receipts + typing — WhatsApp RECIPROCAL rule
# ---------------------------------------------------------------------------
# A member may turn read-receipts OFF (and typing OFF).  The reciprocal rule:
# if I turn OFF read receipts, I ALSO cannot see other people's read receipts.
# Restrict additionally hides receipts from the restricted person.

def can_see_read_receipt(viewer, sender):
    """Can `viewer` (the message sender who wants a 'read' tick) see that
    `sender` (the reader) has read it?  Both must have receipts ON, and the
    reader must not have restricted the viewer.

    `viewer` = {id, read_receipts: bool}          (the one who wants the tick)
    `sender` = {id, read_receipts: bool,           (the reader)
                restricted: set}                   (ids the reader restricted)
    """
    viewer = viewer or {}
    sender = sender or {}
    # Reciprocal: if I turned receipts off, I don't get to see yours.
    if not bool(viewer.get("read_receipts", True)):
        return False
    # The reader turned receipts off -> no one sees their read ticks.
    if not bool(sender.get("read_receipts", True)):
        return False
    # Restrict: reader restricted the viewer -> no read receipt leaks.
    if viewer.get("id") in set(sender.get("restricted") or []):
        return False
    return True


def can_see_typing(viewer, sender):
    """Typing indicator visibility.  Same reciprocal + restrict rules as read
    receipts (WhatsApp couples typing to read-receipts; we keep a separate flag
    `typing` but apply the same reciprocity)."""
    viewer = viewer or {}
    sender = sender or {}
    if not bool(viewer.get("typing", True)):
        return False
    if not bool(sender.get("typing", True)):
        return False
    if viewer.get("id") in set(sender.get("restricted") or []):
        return False
    return True


# ---------------------------------------------------------------------------
# Incoming-call policy + DND schedule
# ---------------------------------------------------------------------------
# Who may RING me:  everyone / chosen people / chosen relationship types /
# nobody.  Plus a DND window (quiet hours) with an optional family exception.
# A suppressed call (blocked / policy / DND / restricted) still LOGS a missed
# call unless blocked (block is silent, no log on my side).

CALLS_EVERYONE = "everyone"
CALLS_CHOSEN = "chosen"          # only member ids on an allow list
CALLS_RELATIONS = "relations"    # only chosen relationship types
CALLS_NOBODY = "nobody"
CALL_POLICIES = (CALLS_EVERYONE, CALLS_CHOSEN, CALLS_RELATIONS, CALLS_NOBODY)


def default_call_privacy():
    """Safe default: incoming calls OFF for strangers — only your circle, with a
    conservative base of everyone-in-circle (all contacts are consented family/
    friends already).  Owner can tighten to chosen/relations/nobody."""
    return {
        "policy": CALLS_EVERYONE,
        "allow_ids": [],            # for CALLS_CHOSEN
        "allow_relations": [],      # for CALLS_RELATIONS
        "dnd_enabled": False,
        "dnd_start": "22:00",       # local HH:MM
        "dnd_end": "07:00",
        "dnd_family_exception": True,
    }


def normalize_call_privacy(cfg):
    cfg = cfg or {}
    pol = str(cfg.get("policy", CALLS_EVERYONE))
    return {
        "policy": pol if pol in CALL_POLICIES else CALLS_EVERYONE,
        "allow_ids": [int(x) for x in (cfg.get("allow_ids") or []) if _is_int(x)],
        "allow_relations": [str(r).lower() for r in (cfg.get("allow_relations") or [])],
        "dnd_enabled": bool(cfg.get("dnd_enabled", False)),
        "dnd_start": _norm_hhmm(cfg.get("dnd_start", "22:00")),
        "dnd_end": _norm_hhmm(cfg.get("dnd_end", "07:00")),
        "dnd_family_exception": bool(cfg.get("dnd_family_exception", True)),
    }


def _in_dnd_window(now_t, start_t, end_t):
    """Is local time `now_t` inside the [start, end) window?  Handles windows
    that wrap past midnight (e.g. 22:00 -> 07:00)."""
    if start_t == end_t:
        return False
    if start_t < end_t:
        return start_t <= now_t < end_t
    # wraps midnight
    return now_t >= start_t or now_t < end_t


def allow_call(owner_privacy, caller, now_local=None):
    """THE incoming-call decision.  Returns
        {ring, log_missed, reason}
    - ring       = should the device ring / push?
    - log_missed = should a missed-call record be written on the owner's side?
    - reason     = machine reason for the UI/logs.

    SERVER-ENFORCED: the signalling view calls this before pushing a ring.  A
    client cannot force a ring by ignoring the owner's policy.

    `caller` dict: {id, relation, blocked, restricted}
      blocked    -> owner blocked this caller
      restricted -> owner restricted this caller
    `now_local`  -> a datetime in the OWNER's local tz (view converts); defaults
                    to now (UTC) — pass the real local time in production.
    """
    cfg = normalize_call_privacy(owner_privacy)
    caller = caller or {}

    # Block is silent AND not logged (the owner shouldn't even know).
    if bool(caller.get("blocked")):
        return {"ring": False, "log_missed": False, "reason": "blocked"}

    # Base policy: who may ring at all.
    if not _policy_permits(cfg, caller):
        return {"ring": False, "log_missed": True, "reason": "policy_declined"}

    # Restrict: never rings, but is logged as missed (filtered).
    if bool(caller.get("restricted")):
        return {"ring": False, "log_missed": True, "reason": "restricted"}

    # DND schedule with optional family exception.
    if cfg["dnd_enabled"]:
        now_local = now_local or datetime.now(timezone.utc)
        now_t = time(now_local.hour, now_local.minute)
        start_t = _as_time(cfg["dnd_start"])
        end_t = _as_time(cfg["dnd_end"])
        if _in_dnd_window(now_t, start_t, end_t):
            if cfg["dnd_family_exception"] and is_family_relation(caller.get("relation")):
                return {"ring": True, "log_missed": False, "reason": "dnd_family_exception"}
            return {"ring": False, "log_missed": True, "reason": "dnd"}

    return {"ring": True, "log_missed": False, "reason": "ok"}


def _policy_permits(cfg, caller):
    pol = cfg["policy"]
    if pol == CALLS_NOBODY:
        return False
    if pol == CALLS_EVERYONE:
        return True
    if pol == CALLS_CHOSEN:
        return caller.get("id") in set(cfg["allow_ids"])
    if pol == CALLS_RELATIONS:
        return (caller.get("relation") or "").lower() in set(cfg["allow_relations"])
    return False


# ---------------------------------------------------------------------------
# Report (optionally attach recent messages + block together)
# ---------------------------------------------------------------------------

REPORT_REASONS = ("spam", "harassment", "scam", "impersonation", "nudity",
                  "hate", "other")


def build_report(reporter_id, target_id, reason, note="",
                 attach_messages=None, also_block=False, lang="bn"):
    """Build a report payload.  `attach_messages` is an OPTIONAL list of recent
    message envelope ids/metadata the reporter chose to include (NEVER plaintext
    the server can't read — the integrator attaches ciphertext refs or, for a
    report, the reporter's device may include decrypted excerpts it uploads
    explicitly with consent; default is metadata only)."""
    reason = reason if reason in REPORT_REASONS else "other"
    attached = list(attach_messages or [])[:50]
    return {
        "kind": "circle_report",
        "reporter_id": int(reporter_id),
        "target_id": int(target_id),
        "reason": reason,
        "note": (note or "")[:1000],
        "attached_message_count": len(attached),
        "attached_messages": attached,
        "also_block": bool(also_block),
        # harsh reasons auto-suggest a block even if the reporter didn't tick it
        "suggest_block": reason in ("harassment", "scam", "impersonation", "hate"),
        "message": pick(lang,
                        "রিপোর্ট জমা হয়েছে।", "Report submitted."),
    }


# ---------------------------------------------------------------------------
# Mute / archive / pin / chat-lock / delete
# ---------------------------------------------------------------------------

MUTE_8H = "8h"
MUTE_1W = "1w"
MUTE_ALWAYS = "always"
MUTE_DURATIONS = {MUTE_8H: 8 * 3600, MUTE_1W: 7 * 24 * 3600, MUTE_ALWAYS: None}


def mute_until(duration, now=None):
    """Return an ISO expiry for a mute (None == always/no expiry)."""
    if duration not in MUTE_DURATIONS:
        return None
    secs = MUTE_DURATIONS[duration]
    if secs is None:
        return None            # 'always' — no expiry
    now = now or datetime.now(timezone.utc)
    return (now.timestamp() + secs)


def is_muted(mute_state, now=None):
    """`mute_state` = {"muted": bool, "until": epoch|None}.  'always' (until
    None while muted) stays muted; a timed mute expires."""
    ms = mute_state or {}
    if not ms.get("muted"):
        return False
    until = ms.get("until")
    if until is None:
        return True            # always
    now = now or datetime.now(timezone.utc)
    return now.timestamp() < float(until)


def should_notify(recipient_mute, inbox, now=None):
    """Combine mute + inbox routing into a final notify decision.  A restricted
    inbox never notifies; a muted chat never notifies."""
    if inbox == "restricted":
        return False
    if is_muted(recipient_mute, now=now):
        return False
    return True


MAX_PINNED = 3   # WhatsApp pins up to 3 chats


def can_pin(current_pinned_count):
    return current_pinned_count < MAX_PINNED


CHAT_LOCK_METHODS = ("pin", "fingerprint", "face", "none")


def chat_lock_config(method, pin_hash=None):
    """Normalize a chat-lock setting.  The server NEVER stores a raw PIN — only a
    client-side hash reference / an on-device biometric flag.  Enforcement
    (hiding locked chats behind auth) is on-device; the server stores the flag
    so it syncs across the user's own devices."""
    method = method if method in CHAT_LOCK_METHODS else "none"
    return {
        "locked": method != "none",
        "method": method,
        "pin_hash": pin_hash if method == "pin" else None,
    }


# ---------------------------------------------------------------------------
# Bilingual labels for the privacy UI (server-provided, so copy stays in sync)
# ---------------------------------------------------------------------------

def call_policy_label(policy, lang="bn"):
    labels = {
        CALLS_EVERYONE: ("সার্কেলের সবাই", "Everyone in my circle"),
        CALLS_CHOSEN: ("নির্বাচিত ব্যক্তিরা", "Only chosen people"),
        CALLS_RELATIONS: ("নির্বাচিত সম্পর্ক", "Only chosen relationships"),
        CALLS_NOBODY: ("কেউ নয়", "Nobody"),
    }
    bn, en = labels.get(policy, labels[CALLS_EVERYONE])
    return pick(lang, bn, en)


def visibility_label(policy, lang="bn"):
    labels = {
        VIS_EVERYONE: ("সার্কেলের সবাই", "My circle"),
        VIS_FAMILY: ("শুধু পরিবার", "Family only"),
        VIS_NOBODY: ("কেউ নয়", "Nobody"),
    }
    bn, en = labels.get(policy, labels[VIS_EVERYONE])
    return pick(lang, bn, en)


def mute_label(duration, lang="bn"):
    labels = {
        MUTE_8H: ("৮ ঘণ্টা", "8 hours"),
        MUTE_1W: ("১ সপ্তাহ", "1 week"),
        MUTE_ALWAYS: ("সবসময়", "Always"),
    }
    bn, en = labels.get(duration, ("", ""))
    return pick(lang, bn, en)


# ---------------------------------------------------------------------------
# Reviewer-pass (§21): conservative call default, honest load state, confirm gate
# ---------------------------------------------------------------------------
# §21 requires conservative defaults (the owner's phone number / reachability is
# private by default), an HONEST load state (a settings fetch failure is NEVER
# shown as if the defaults were the user's real saved choice), and a confirm gate
# on a destructive choice ("Nobody can call me" means every call is missed).

def call_policy_label_hint(policy, lang="bn"):
    """A one-line HONEST consequence hint under each call-policy option, so the
    owner understands what they are choosing (not just the label)."""
    hints = {
        CALLS_EVERYONE: ("আপনার সার্কেলের যেকেউ কল করতে পারবেন।",
                         "Anyone in your circle can call you."),
        CALLS_CHOSEN: ("শুধু নির্বাচিত ব্যক্তিরা কল করতে পারবেন।",
                       "Only people you choose can call you."),
        CALLS_RELATIONS: ("শুধু নির্বাচিত সম্পর্কের লোক কল করতে পারবেন।",
                          "Only chosen relationships can call you."),
        CALLS_NOBODY: ("কেউ কল করতে পারবেন না; সব কল মিসড হিসেবে জমা হবে।",
                       "No one can call you; every call is logged as missed."),
    }
    bn, en = hints.get(policy, hints[CALLS_EVERYONE])
    return pick(lang, bn, en)


def call_policy_is_restrictive(policy):
    """True for a policy that could cause the owner to MISS calls they expect
    (nobody / chosen / relations).  The UI shows a confirm gate before saving a
    switch INTO one of these from `everyone`."""
    return normalize_call_privacy({"policy": policy})["policy"] in (
        CALLS_NOBODY, CALLS_CHOSEN, CALLS_RELATIONS)


def call_policy_confirm(policy, lang="bn"):
    """Confirm-gate copy before committing a restrictive incoming-call policy.
    Returns None for a non-restrictive policy (no gate needed)."""
    pol = normalize_call_privacy({"policy": policy})["policy"]
    if not call_policy_is_restrictive(pol):
        return None
    if pol == CALLS_NOBODY:
        return pick(lang,
                    "কেউ আপনাকে কল করতে পারবেন না। পরিবারও নয়। নিশ্চিত?",
                    "No one will be able to call you — not even family. Are you sure?")
    return pick(lang,
                "শুধু আপনার বেছে নেওয়া লোকজনই কল করতে পারবেন। বাকি কল মিসড হবে। নিশ্চিত?",
                "Only the people you pick can call you; the rest are missed. Are you sure?")


def privacy_load_failed_notice(lang="bn"):
    """Honest copy when the privacy settings could not be loaded.  The screen
    shows this + a Retry instead of pretending the safe defaults are the owner's
    real saved choices (which could mislead them into thinking a stricter policy
    is active than really is)."""
    return pick(lang, "সেটিংস লোড করা যায়নি। আবার চেষ্টা করুন।",
                "Couldn’t load your settings. Please retry.")


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def _is_int(x):
    try:
        int(x)
        return True
    except (TypeError, ValueError):
        return False


def _norm_hhmm(v):
    t = _as_time(v)
    return f"{t.hour:02d}:{t.minute:02d}"


def _as_time(v):
    if isinstance(v, time):
        return v
    try:
        hh, mm = str(v).split(":")[:2]
        return time(int(hh) % 24, int(mm) % 60)
    except (ValueError, AttributeError):
        return time(0, 0)
