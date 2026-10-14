"""
travel_planner.py — pure, deterministic TRAVEL PLANNER math (#35, SPEC v2.1 §21,
ADVANCED, KEY-GATED).

Plan a trip entirely by hand, offline, with no key: a destination + dates, a
day-by-day itinerary, a packing checklist, a ৳ budget (estimated vs actual per
category), and a countdown. This module is PURE — like `probashi.py`: no Django,
no DB, no network, **no AI**, no live clock (all "today" is passed in), and it
NEVER holds money or books anything.

WHAT'S DETERMINISTIC HERE
-------------------------
  * `trip_days` / `countdown`     — date math from a passed-in `today`
  * `budget_summary`              — integer-poisha estimated vs actual totals,
                                    per-category, remaining; no float drift
  * `packing_progress`            — checked / total + percent
  * `itinerary_overview`          — per-day activity counts, total activities
  * `fmt_bdt` / `to_poisha`       — exact poisha money formatting (৳)

KEY-GATED SEAMS (HONEST, NEVER FABRICATE)
-----------------------------------------
Two things need a key and are DOCUMENTED SEAMS only — this module builds the
REQUEST SHAPE and never fabricates results:

  * AI itinerary suggestions — `suggest_itinerary_request(trip, has_ai_key)`:
    wired to Integrations → `anthropic` (`core.ai.generate`). Returns
    `ready`/`ai_required` + the prompt INPUTS; it NEVER returns invented
    activities. No key => `ready=False`, `marker="ai_needs_key"`.
  * Live booking / live prices — `booking_request(item, has_booking_key)`:
    wired to a booking Integration. Returns the request SHAPE only; it NEVER
    fabricates a price, an availability, or a confirmation. No key =>
    `ready=False`, `marker="booking_needs_key"`. Prices the user sees are only
    the ESTIMATES they typed themselves.

HARD RULES (money discipline identical to the finance modules):
  * ALL MONEY IS INTEGER POISHA (1 BDT = 100 poisha); each amount is parsed and
    rounded ONCE, totals add rounded poisha — no float drift.
  * NO DB, NO AI, NO I/O, NO LIVE CLOCK, NO MONEY-HOLDING, NO BOOKING.
  * Human-facing copy is bilingual {"bn","en"} so the Dart layer keeps ZERO
    Bangla literals.

Run self-tests (no DB):
    python3 -c "import core.logic.travel_planner_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

from datetime import date


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ----------------------------------------------------------------- constants

# Default budget categories (neutral English seed keys; the UI localises).
BUDGET_CATEGORIES = ("transport", "stay", "food", "activities", "shopping", "other")

STATUS_UPCOMING = "upcoming"
STATUS_ONGOING = "ongoing"
STATUS_PAST = "past"

AI_MARKER = "ai_needs_key"
BOOKING_MARKER = "booking_needs_key"


# ----------------------------------------------------------------- helpers

def _clean(text):
    return " ".join(str(text or "").split()).strip()


def to_poisha(v):
    """Coerce a BDT amount-ish value to INTEGER POISHA (×100). Junk -> 0.
    Negatives clamped to 0 (a budget line is never negative)."""
    if v is None or v == "":
        return 0
    if isinstance(v, bool):
        return 0
    # Treat any numeric/string input as a BDT *amount* (e.g. 1200.50), then
    # convert to poisha. (So an int like 1200 means ৳1200.00, not 12 poisha.)
    s = str(v).strip().replace(",", "")
    neg = s.startswith("-")
    if neg:
        s = s[1:]
    if "." in s:
        whole, frac = s.split(".", 1)
    else:
        whole, frac = s, ""
    whole = whole or "0"
    frac = (frac + "00")[:3]
    try:
        major = int(whole)
        milli = int(frac)
    except ValueError:
        return 0
    poisha = major * 100 + milli // 10
    if milli % 10 >= 5:
        poisha += 1
    return 0 if neg else poisha


def _group(n):
    s = str(n)
    if len(s) <= 3:
        return s
    head, tail = s[:-3], s[-3:]
    parts = []
    while len(head) > 2:
        parts.insert(0, head[-2:])
        head = head[:-2]
    if head:
        parts.insert(0, head)
    return ",".join(parts) + "," + tail


def fmt_bdt(poisha):
    """Format integer poisha as a ৳ amount string (always 2 dp)."""
    p = int(poisha)
    neg = p < 0
    p = abs(p)
    taka, paisa = divmod(p, 100)
    return ("-" if neg else "") + "৳" + f"{_group(taka)}.{paisa:02d}"


def _parse_date(s):
    """Parse 'YYYY-MM-DD' to a date, or None. Deterministic, no clock."""
    s = _clean(s)
    if not s:
        return None
    try:
        y, m, d = s.split("-")
        return date(int(y), int(m), int(d))
    except (ValueError, AttributeError):
        return None


# ----------------------------------------------------------------- dates

def trip_days(start, end):
    """Inclusive number of days from start to end (both 'YYYY-MM-DD'). 0 if
    either is unparseable or end < start. Deterministic."""
    a, b = _parse_date(start), _parse_date(end)
    if not a or not b or b < a:
        return 0
    return (b - a).days + 1


def countdown(start, end, today):
    """Status + days relative to a PASSED-IN `today` ('YYYY-MM-DD').

    Returns {status, days, total_days}. `days` is days-until-start when
    upcoming (0 if it starts today), days-remaining (inclusive) when ongoing,
    and days-since-end when past. No live clock — `today` is always supplied."""
    a, b = _parse_date(start), _parse_date(end)
    t = _parse_date(today)
    total = trip_days(start, end)
    if not a or not b or not t or b < a:
        return {"status": STATUS_UPCOMING, "days": 0, "total_days": total}
    if t < a:
        return {"status": STATUS_UPCOMING, "days": (a - t).days, "total_days": total}
    if t > b:
        return {"status": STATUS_PAST, "days": (t - b).days, "total_days": total}
    return {"status": STATUS_ONGOING, "days": (b - t).days + 1, "total_days": total}


# ----------------------------------------------------------------- budget

def budget_summary(rows, lang="bn"):
    """Roll up budget rows into estimated vs actual totals, per-category and
    overall, plus remaining (estimated - actual). Integer poisha, no drift.

    Each row: {"category": <key>, "estimate": "1200", "actual": "900"}.
    Unknown categories fold into "other". Deterministic ordering by
    BUDGET_CATEGORIES then any extras in first-seen order."""
    by_cat = {}
    order = []
    for r in (rows or []):
        cat = _clean((r or {}).get("category")) or "other"
        if cat not in by_cat:
            by_cat[cat] = {"estimate": 0, "actual": 0}
            order.append(cat)
        by_cat[cat]["estimate"] += to_poisha((r or {}).get("estimate"))
        by_cat[cat]["actual"] += to_poisha((r or {}).get("actual"))
    # stable, friendly ordering: known categories first, then extras
    ordered = [c for c in BUDGET_CATEGORIES if c in by_cat]
    ordered += [c for c in order if c not in BUDGET_CATEGORIES]
    cats = []
    tot_est = tot_act = 0
    for c in ordered:
        est = by_cat[c]["estimate"]
        act = by_cat[c]["actual"]
        tot_est += est
        tot_act += act
        cats.append({
            "category": c,
            "estimate": est,
            "actual": act,
            "remaining": est - act,
            "estimate_bdt": fmt_bdt(est),
            "actual_bdt": fmt_bdt(act),
            "remaining_bdt": fmt_bdt(est - act),
        })
    return {
        "categories": cats,
        "total_estimate": tot_est,
        "total_actual": tot_act,
        "remaining": tot_est - tot_act,
        "total_estimate_bdt": fmt_bdt(tot_est),
        "total_actual_bdt": fmt_bdt(tot_act),
        "remaining_bdt": fmt_bdt(tot_est - tot_act),
        # honest: overspent when actual exceeds estimate (remaining negative)
        "overspent": tot_act > tot_est,
    }


# ----------------------------------------------------------------- packing

def packing_progress(items):
    """Checked / total + integer percent for a packing checklist.

    Each item: {"label": "...", "checked": True/False}. Items with a blank
    label are ignored. Deterministic; percent is floor(checked*100/total)."""
    rows = [i for i in (items or []) if _clean((i or {}).get("label"))]
    total = len(rows)
    checked = sum(1 for i in rows if (i or {}).get("checked"))
    pct = (checked * 100 // total) if total else 0
    return {"checked": checked, "total": total, "percent": pct,
            "done": total > 0 and checked == total}


# ----------------------------------------------------------------- itinerary

def itinerary_overview(days):
    """Per-day activity counts + totals for the itinerary.

    `days` is a list of {"day": <int/str>, "title": "...",
    "activities": [{"what": "...", "place": "...", "time": "..."}]}.
    Returns deterministic counts; never reorders activities."""
    out = []
    total_act = 0
    for idx, d in enumerate(days or []):
        acts = [a for a in (d or {}).get("activities", [])
                if _clean((a or {}).get("what"))]
        total_act += len(acts)
        out.append({
            "index": idx,
            "day": (d or {}).get("day", idx + 1),
            "title": _clean((d or {}).get("title")),
            "activity_count": len(acts),
        })
    return {"days": out, "day_count": len(out), "total_activities": total_act}


# ----------------------------------------------------------------- AI seam

def suggest_itinerary_request(trip, has_ai_key=False):
    """Build the request SHAPE for the key-gated AI itinerary seam — NEVER an
    itinerary. Wired by the integrator to Integrations → `anthropic`
    (`core.ai.generate`). No key => ready=False, marker=AI_MARKER. This module
    returns NO suggested activities and never fabricates places or plans."""
    trip = trip or {}
    dest = _clean(trip.get("destination"))
    missing = []
    if not dest:
        missing.append("no_destination")
    days = trip_days(trip.get("start"), trip.get("end"))
    if days <= 0:
        missing.append("no_dates")
    ready = has_ai_key and not missing
    return {
        "action": "suggest_itinerary",
        "ready": ready,
        "ai_required": True,
        "provider_integration": "anthropic",
        "marker": AI_MARKER if not has_ai_key else "",
        "missing": missing,
        # prompt INPUTS only — the executor composes/sends the model call
        "inputs": {"destination": dest, "days": days,
                   "start": _clean(trip.get("start")),
                   "end": _clean(trip.get("end"))},
        "suggestions": [],  # honest: never fabricated here
    }


# ----------------------------------------------------------------- booking seam

def booking_request(item, has_booking_key=False):
    """Build the request SHAPE for the key-gated LIVE BOOKING seam — NEVER a
    price, availability, or confirmation. No key => ready=False,
    marker=BOOKING_MARKER. Any price the user sees is their own typed ESTIMATE;
    this module never fabricates a live price and never holds money."""
    item = item or {}
    kind = _clean(item.get("kind"))  # flight / hotel / bus / train ...
    query = _clean(item.get("query"))
    missing = []
    if not kind:
        missing.append("no_kind")
    if not query:
        missing.append("no_query")
    ready = has_booking_key and not missing
    return {
        "action": "booking",
        "ready": ready,
        "ai_required": False,  # a booking API, not an AI model
        "provider_integration": "booking",
        "marker": BOOKING_MARKER if not has_booking_key else "",
        "missing": missing,
        "inputs": {"kind": kind, "query": query},
        "price": None,          # honest: never fabricated
        "availability": None,   # honest: never fabricated
        "confirmation": None,   # honest: never books / holds money
    }
