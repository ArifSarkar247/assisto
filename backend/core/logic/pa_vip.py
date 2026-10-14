"""
pa_vip.py — the deterministic, key-free engine behind Assisto's
PA SECRETARY MODE · VIP & STAKEHOLDER tracker (issue #118, SPEC v2.1 §14,
built to the §21 ADVANCED standard; CORPORATE tier).

WHAT THIS IS
------------
A VIP / stakeholder relationship tracker. The PA keeps one CONTACT per
stakeholder — name, organisation, a relationship TIER, the LAST-TOUCH and
NEXT-TOUCH dates, a follow-up CADENCE (days), private notes and an interaction
LOG — and the engine deterministically works out follow-up health: who is
OVERDUE, who is DUE SOON, and who is on track, computed against a `now` the
caller passes IN (no clock). It also derives a suggested next-touch date from
the last touch + cadence when the owner hasn't set one.

    contact = {name, org, tier, last_touch, next_touch, cadence_days,
               notes, log[]}
    log entry = {date, note}          (verbatim; never interpreted)

Nothing is fabricated. The tracker is deterministic; dates are plain ISO
strings (YYYY-MM-DD) compared lexicographically, which is exact for that format.

CONSERVATIVE PRIVACY
--------------------
This is sensitive relationship data. The engine holds NOTHING: it is a pure
function. It never emits notes into any summary/share surface on its own — the
caller decides what to show. The UI (vip_stakeholder_screen.dart) keeps notes
and the interaction log behind an explicit reveal and masks nothing it is told
to show, but the engine's roll-up carries ONLY counts + names + status, never
note bodies. We never phone-home and never need a key.

NO AI SEAM THAT FABRICATES
--------------------------
This feature is fully deterministic and key-free; there is no "AI writes your
relationships" path. (A future optional seam could DRAFT a check-in message
from the owner's own notes, but that is NOT built here and nothing is faked.)

PURE — NO DJANGO, NO DB, NO NETWORK, NO CLOCK, NO AI
----------------------------------------------------
Every function is a pure function of its arguments; `now` (an ISO date string)
is passed in. Hand-verified in pa_vip_tests_snippets.py. Mirrored by
app/lib/screens/pa/vip_stakeholder_screen.dart.
"""

import re

# ------------------------------------------------------------------ vocabulary

# Relationship tiers (neutral seed keys; the UI localises). Order = priority.
TIER_STRATEGIC = "strategic"   # top — board / investor / key client
TIER_KEY = "key"               # important ongoing stakeholder
TIER_STANDARD = "standard"     # regular contact
TIERS = (TIER_STRATEGIC, TIER_KEY, TIER_STANDARD)

# Follow-up status buckets (neutral keys the UI localises).
STATUS_OVERDUE = "overdue"
STATUS_DUE_SOON = "due_soon"
STATUS_ON_TRACK = "on_track"
STATUS_NO_DATE = "no_date"     # no next-touch known and no cadence to derive one

# "Due soon" window: next-touch within this many days of `now`.
DUE_SOON_DAYS = 7

# Default cadence used ONLY to DERIVE a suggested next-touch when the owner set
# neither a next-touch nor a cadence (so an undated contact still surfaces).
DEFAULT_CADENCE_DAYS = 30

_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


# ------------------------------------------------------------------ helpers

def _clean(text):
    return " ".join(str(text or "").split()).strip()


def _norm_tier(v):
    v = _clean(v).lower()
    return v if v in TIERS else TIER_STANDARD


def _int(v, default=0):
    try:
        n = int(float(str(v).strip()))
        return n if n >= 0 else default
    except (TypeError, ValueError):
        return default


def _iso(v):
    """Return a clean YYYY-MM-DD string if v is a valid such date, else ""."""
    s = _clean(v)
    if not _DATE_RE.match(s):
        return ""
    try:
        from datetime import date
        y, m, d = (int(x) for x in s.split("-"))
        date(y, m, d)  # validates ranges (e.g. rejects 2026-13-40)
        return s
    except (ValueError, TypeError):
        return ""


def _add_days(iso, days):
    """ISO date + days → ISO date (pure, stdlib). "" if iso invalid."""
    iso = _iso(iso)
    if not iso:
        return ""
    from datetime import date, timedelta
    y, m, d = (int(x) for x in iso.split("-"))
    return (date(y, m, d) + timedelta(days=int(days))).isoformat()


def _days_between(a, b):
    """Signed day count b - a for two valid ISO dates; None if either invalid."""
    a, b = _iso(a), _iso(b)
    if not a or not b:
        return None
    from datetime import date
    ay, am, ad = (int(x) for x in a.split("-"))
    by, bm, bd = (int(x) for x in b.split("-"))
    return (date(by, bm, bd) - date(ay, am, ad)).days


# ------------------------------------------------------------------ validate

def validate(name="", tier="", cadence_days=0):
    """Return a list of problem keys (empty ⇒ valid). The UI localises these."""
    problems = []
    if not _clean(name):
        problems.append("empty_name")
    if _clean(tier) and _clean(tier).lower() not in TIERS:
        problems.append("bad_tier")
    seen = set()
    return [p for p in problems if not (p in seen or seen.add(p))]


# ------------------------------------------------------------------ status

def effective_next_touch(last_touch="", next_touch="", cadence_days=0):
    """The next-touch date we track against, deterministically:
      1. an explicit next_touch the owner set (if valid), else
      2. last_touch + cadence_days (if both usable), else
      3. last_touch + DEFAULT_CADENCE_DAYS (so a contact with only a last-touch
         still surfaces), else
      4. "" (unknown).
    PURE."""
    nxt = _iso(next_touch)
    if nxt:
        return nxt
    last = _iso(last_touch)
    if last:
        cad = _int(cadence_days) or DEFAULT_CADENCE_DAYS
        return _add_days(last, cad)
    return ""


def status_for(now="", last_touch="", next_touch="", cadence_days=0):
    """Deterministic follow-up status + days-until (negative = overdue).

    Returns {status, due_date, days}. `now` is a passed-in ISO date string.
    If neither a next-touch nor a last-touch is known → STATUS_NO_DATE (honest:
    we do not guess a date out of nothing)."""
    due = effective_next_touch(last_touch, next_touch, cadence_days)
    if not due:
        return {"status": STATUS_NO_DATE, "due_date": "", "days": None}
    delta = _days_between(now, due)  # due - now ; <0 means due is in the past
    if delta is None:
        return {"status": STATUS_NO_DATE, "due_date": due, "days": None}
    if delta < 0:
        st = STATUS_OVERDUE
    elif delta <= DUE_SOON_DAYS:
        st = STATUS_DUE_SOON
    else:
        st = STATUS_ON_TRACK
    return {"status": st, "due_date": due, "days": delta}


# ------------------------------------------------------------------ roll-up

_TIER_ORDER = {TIER_STRATEGIC: 0, TIER_KEY: 1, TIER_STANDARD: 2}
_STATUS_ORDER = {STATUS_OVERDUE: 0, STATUS_DUE_SOON: 1,
                 STATUS_ON_TRACK: 2, STATUS_NO_DATE: 3}


def summarise(contacts=None, now=""):
    """Deterministic roll-up across contacts for the dashboard. PURE.

    Returns {counts, items}. `counts` = per-status totals + total. `items` is
    the contacts annotated with status, SORTED by (status severity, tier
    priority, days-until, name) — stable & total. PRIVACY: items carry name,
    org, tier, status, due_date, days ONLY — never notes or log bodies."""
    out_items = []
    counts = {STATUS_OVERDUE: 0, STATUS_DUE_SOON: 0,
              STATUS_ON_TRACK: 0, STATUS_NO_DATE: 0, "total": 0}
    for c in (contacts or []):
        if not isinstance(c, dict):
            continue
        name = _clean(c.get("name"))
        if not name:
            continue
        tier = _norm_tier(c.get("tier"))
        st = status_for(now,
                        last_touch=c.get("last_touch"),
                        next_touch=c.get("next_touch"),
                        cadence_days=c.get("cadence_days"))
        counts[st["status"]] += 1
        counts["total"] += 1
        out_items.append({
            "name": name,
            "org": _clean(c.get("org")),
            "tier": tier,
            "status": st["status"],
            "due_date": st["due_date"],
            "days": st["days"],
        })

    def _key(it):
        days = it["days"] if it["days"] is not None else 10 ** 9
        return (_STATUS_ORDER[it["status"]], _TIER_ORDER[it["tier"]],
                days, it["name"].lower())

    out_items.sort(key=_key)
    return {"counts": counts, "items": out_items}
