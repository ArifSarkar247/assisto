"""
nominee.py — Assisto Nominee / family-access "digital inheritance / emergency
access" engine (feature 36). Pure Python, deterministic, no Django, no AI key;
fully unit-testable.

WHAT THIS IS
    A trusted-person plan: the OWNER names nominees (name, relationship, phone),
    chooses which CATEGORIES of their information each nominee may reach
    (emergency card, document-vault LIST/pointers, account LIST, insurance,
    final wishes / instructions) and in what PRIORITY order, plus a RELEASE
    TRIGGER that decides when — and only when — access may open.

Benchmarked (capability only, adapted to BD + respectful nominee / waris /
trusted-person framing) vs digital-legacy / dead-man-switch apps
(Google Inactive Account Manager, "if-I-die" / legacy-vault class).

THE SAFETY INVARIANT (why it can NEVER trigger unsafely)
    Access moves through exactly three states and only ever forward one hop at a
    time, each hop gated:

        armed  --request-->  pending  --(window elapsed, not cancelled)-->  open

      * armed   : the default. A saved plan opens NOTHING. No data is shared.
      * pending : a GRACE WINDOW is running. Entered only by a *verified*
                  trigger (see below). The owner is notified and ONE tap returns
                  it to `armed`. Nothing is shared yet.
      * open    : access to the chosen categories is granted — and is still
                  owner-revocable back to `armed` at any time.

    A release is only ever *proposed*; it is confirmed by the elapse of real
    time during which the owner could cancel. There is no path that jumps
    straight to `open` without passing through a cancellable `pending` window,
    and no trigger fires on its own without an owner-configured, verified
    condition:

      - owner_grant : the owner, authenticated on their own device, must request
                      AND confirm; then the grace window runs.
      - inactivity  : reuses Safe-Journey wellness. The window only starts after
                      the owner misses the wellness prompt for the full
                      configured period; any owner activity / "I'm OK" cancels.
      - multi_verify: a quorum of named trusted people must EACH confirm
                      independently before the window even starts.

    Raw secrets never flow through here. Scopes grant category LISTS / pointers
    / instructions only; the document vault stays end-to-end encrypted and its
    contents are released (if ever) by a separate key step the integrator wires
    — this module models the FLOW and the SAFEGUARDS, not the ciphertext.

Bilingual labels via pick(). Run self-tests:
    python3 -c "import core.logic.nominee_tests_snippets as t; t.run_all()"
"""
from datetime import datetime, timedelta

# ---------------------------------------------------------------------------
# Vocabulary
# ---------------------------------------------------------------------------

# Categories a nominee may be granted. These are LISTS / pointers / instructions
# — never raw secrets. 'all' is a convenience that expands to every category.
SCOPES = ("emergency", "documents", "accounts", "insurance", "wishes")

RELATIONSHIPS = ("spouse", "child", "parent", "sibling", "family",
                 "lawyer", "friend")

TRIGGERS = ("owner_grant", "inactivity", "multi_verify")

# Release lifecycle states.
STATE_ARMED = "armed"
STATE_PENDING = "pending"
STATE_OPEN = "open"

# Grace window: once a release is requested, access does NOT open until this
# many hours pass with no cancellation. Owner-configurable within bounds.
GRACE_HOURS_DEFAULT = 48
GRACE_HOURS_MIN = 1
GRACE_HOURS_MAX = 24 * 14

# Inactivity trigger bounds (days).
INACTIVITY_DAYS_DEFAULT = 30
INACTIVITY_DAYS_MIN = 7
INACTIVITY_DAYS_MAX = 365

# multi_verify: how many named confirmers are required (a quorum). Clamped to
# the number of configured confirmers so it can never be trivially satisfied by
# an empty set.
MULTI_VERIFY_QUORUM_DEFAULT = 2


def pick(bn, en, lang="en"):
    return bn if str(lang).startswith("bn") else en


def _clamp(v, lo, hi, default):
    try:
        v = int(v)
    except (TypeError, ValueError):
        return default
    return max(lo, min(hi, v))


def parse_dt(v):
    if v is None:
        return None
    if isinstance(v, datetime):
        return v
    s = str(v).replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(s)
    except ValueError:
        return None


# ---------------------------------------------------------------------------
# Building / validating a nominee plan
# ---------------------------------------------------------------------------

def normalize_scopes(scopes):
    """Return a clean, de-duplicated, ordered scope list. 'all' expands to every
    category. Unknown values are dropped. Empty input is INVALID (a nominee must
    be able to see at least one thing) and returns an empty list for the caller
    to reject."""
    if not scopes:
        return []
    if isinstance(scopes, str):
        scopes = [scopes]
    out = []
    for s in scopes:
        if s == "all":
            return list(SCOPES)
        if s in SCOPES and s not in out:
            out.append(s)
    return out


def build_nominee(name, contact, relationship="family", scopes=None,
                  priority=1, trigger="owner_grant",
                  inactivity_days=INACTIVITY_DAYS_DEFAULT,
                  grace_hours=GRACE_HOURS_DEFAULT,
                  multi_verify_ids=None,
                  multi_verify_quorum=MULTI_VERIFY_QUORUM_DEFAULT):
    """Validate + normalize an owner-defined nominee plan. Returns a plain dict
    the view layer can persist. Raises ValueError on an unusable plan so a bad
    definition can never silently become a live access grant."""
    name = (name or "").strip()
    if not name:
        raise ValueError("nominee name required")

    norm = normalize_scopes(scopes)
    if not norm:
        raise ValueError("at least one access category required")

    if relationship not in RELATIONSHIPS:
        relationship = "family"
    if trigger not in TRIGGERS:
        trigger = "owner_grant"

    ids = sorted({int(x) for x in (multi_verify_ids or []) if str(x).strip()})
    quorum = _clamp(multi_verify_quorum, 1, max(1, len(ids)),
                    MULTI_VERIFY_QUORUM_DEFAULT) if ids else 0

    return {
        "name": name,
        "contact": (contact or "").strip(),
        "relationship": relationship,
        "scopes": norm,
        # legacy single-scope mirror for the current serializer/back-compat
        "scope": "all" if norm == list(SCOPES) else norm[0],
        "priority": _clamp(priority, 1, 999, 1),
        "trigger": trigger,
        "inactivity_days": _clamp(inactivity_days, INACTIVITY_DAYS_MIN,
                                  INACTIVITY_DAYS_MAX, INACTIVITY_DAYS_DEFAULT),
        "grace_hours": _clamp(grace_hours, GRACE_HOURS_MIN, GRACE_HOURS_MAX,
                              GRACE_HOURS_DEFAULT),
        "multi_verify_ids": ids,
        "multi_verify_quorum": quorum,
        # live release lifecycle (starts dormant — opens nothing)
        "release_state": STATE_ARMED,
        "release_requested_at": None,
        "release_confirmations": [],   # ids who confirmed (multi_verify)
        "activated": False,
        "activated_at": None,
    }


def order_nominees(nominees):
    """Stable sort by priority (then name) so the owner's fallback order is
    honoured when presenting / contacting nominees."""
    return sorted(nominees or [],
                  key=lambda n: (n.get("priority", 999), n.get("name", "")))


# ---------------------------------------------------------------------------
# The release state machine — the heart of the safety design
# ---------------------------------------------------------------------------

def _is_pending(n):
    return n.get("release_state") == STATE_PENDING or n.get("release_pending")


def request_release(nominee, *,
                    owner_confirmed=False,
                    now=None,
                    wellness_state=None,
                    confirmations=None):
    """Attempt to move a nominee from `armed` to `pending` (start the grace
    window). Returns (ok, reason_bn, reason_en, nominee).

    The trigger's precondition MUST be satisfied or we refuse — this is the gate
    that stops an unsafe/automatic open:

      owner_grant  : requires owner_confirmed=True (a second, explicit, on-device
                     owner confirmation).
      inactivity   : requires wellness_state == 'alert' (Safe-Journey decided the
                     owner missed the full wellness period + response window).
                     Any other wellness state is refused.
      multi_verify : requires a quorum of DISTINCT named confirmers.

    Even when it succeeds, this only starts the cancellable grace window; it
    NEVER opens access."""
    now = now or datetime.now()
    n = dict(nominee)

    if n.get("activated") or n.get("release_state") == STATE_OPEN:
        return (False, "অ্যাক্সেস ইতিমধ্যে খোলা।", "Access is already open.", n)
    if _is_pending(n):
        return (False, "একটি রিলিজ ইতিমধ্যে অপেক্ষমাণ।",
                "A release is already pending.", n)

    trigger = n.get("trigger", "owner_grant")

    if trigger == "owner_grant":
        if not owner_confirmed:
            return (False, "মালিকের নিশ্চিতকরণ প্রয়োজন।",
                    "Owner confirmation is required.", n)

    elif trigger == "inactivity":
        if wellness_state != "alert":
            return (False,
                    "ওয়েলনেস চেক এখনও অ্যালার্ট অবস্থায় যায়নি।",
                    "The wellness check has not reached the alert state yet.", n)

    elif trigger == "multi_verify":
        need = n.get("multi_verify_quorum", MULTI_VERIFY_QUORUM_DEFAULT)
        allowed = set(n.get("multi_verify_ids") or [])
        got = {int(x) for x in (confirmations or []) if int(x) in allowed}
        if need <= 0 or len(got) < need:
            return (False,
                    "যথেষ্ট সংখ্যক বিশ্বস্ত ব্যক্তি নিশ্চিত করেননি।",
                    "Not enough trusted people have confirmed.", n)
        n["release_confirmations"] = sorted(got)

    n["release_state"] = STATE_PENDING
    n["release_pending"] = True
    n["release_requested_at"] = now.isoformat()
    return (True, "গ্রেস সময় শুরু হয়েছে — যেকোনো সময় বাতিল করা যাবে।",
            "Grace window started — cancellable at any time.", n)


def cancel_release(nominee):
    """Owner cancels a pending (or revokes an open) release. ALWAYS allowed and
    ALWAYS safe: returns the nominee to `armed`, closing any access. This is the
    'owner-cancellable at all times' guarantee."""
    n = dict(nominee)
    n["release_state"] = STATE_ARMED
    n["release_pending"] = False
    n["release_requested_at"] = None
    n["release_confirmations"] = []
    n["activated"] = False
    n["activated_at"] = None
    return n


def grace_remaining_seconds(nominee, now=None):
    """Seconds left in the grace window, or 0 if elapsed / not pending."""
    if not _is_pending(nominee):
        return 0
    req = parse_dt(nominee.get("release_requested_at"))
    if req is None:
        return 0
    now = now or datetime.now()
    grace = _clamp(nominee.get("grace_hours"), GRACE_HOURS_MIN,
                   GRACE_HOURS_MAX, GRACE_HOURS_DEFAULT)
    elapsed = (now - req).total_seconds()
    left = grace * 3600 - elapsed
    return int(left) if left > 0 else 0


def can_open_now(nominee, now=None):
    """True only if the nominee is `pending` AND the full grace window has
    elapsed with no cancellation. This is the sole precondition for opening
    access — enforced server-side, never client-trusted."""
    return _is_pending(nominee) and grace_remaining_seconds(nominee, now) == 0 \
        and parse_dt(nominee.get("release_requested_at")) is not None


def open_access(nominee, *, owner_confirmed=False, now=None):
    """Move `pending` -> `open`. Refuses unless (a) the grace window has fully
    elapsed and (b) the owner confirms once more. Returns
    (ok, reason_bn, reason_en, nominee). Even after opening, cancel_release()
    can revoke it at any time."""
    now = now or datetime.now()
    n = dict(nominee)
    if n.get("activated") or n.get("release_state") == STATE_OPEN:
        return (True, "অ্যাক্সেস ইতিমধ্যে খোলা।", "Access already open.", n)
    if not _is_pending(n):
        return (False, "আগে রিলিজের অনুরোধ করতে হবে।",
                "A release must be requested first.", n)
    if grace_remaining_seconds(n, now) > 0:
        return (False, "গ্রেস সময় এখনও শেষ হয়নি।",
                "The grace window has not elapsed yet.", n)
    if not owner_confirmed:
        return (False, "চূড়ান্ত নিশ্চিতকরণ প্রয়োজন।",
                "A final confirmation is required.", n)
    n["release_state"] = STATE_OPEN
    n["release_pending"] = False
    n["activated"] = True
    n["activated_at"] = now.isoformat()
    return (True, "অ্যাক্সেস খোলা হয়েছে।", "Access opened.", n)


def visible_scopes(nominee):
    """The categories a nominee can actually see RIGHT NOW. Empty unless access
    is open — so a dormant/pending plan leaks nothing."""
    if nominee.get("activated") or nominee.get("release_state") == STATE_OPEN:
        return normalize_scopes(nominee.get("scopes") or nominee.get("scope"))
    return []


def release_status(nominee, lang="en", now=None):
    """Human-readable status for the UI (bilingual)."""
    if nominee.get("activated") or nominee.get("release_state") == STATE_OPEN:
        return {"state": STATE_OPEN,
                "label": pick("অ্যাক্সেস খোলা", "Access open", lang)}
    if _is_pending(nominee):
        return {"state": STATE_PENDING,
                "label": pick("অপেক্ষমাণ (গ্রেস সময়)", "Pending (grace window)",
                              lang),
                "grace_remaining_seconds": grace_remaining_seconds(nominee, now)}
    return {"state": STATE_ARMED,
            "label": pick("প্রস্তুত", "Armed", lang)}
