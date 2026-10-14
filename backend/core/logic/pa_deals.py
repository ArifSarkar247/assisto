"""
pa_deals.py — the deterministic engine behind PA SECRETARY MODE (celebrity tier)
BRAND-DEAL PIPELINE (issue #121, SPEC v2.1 §14, ADVANCED).

A celebrity / public-figure's PA tracks brand/endorsement DEALS by hand, offline,
with NO key: each deal has a brand, a value (৳ — a number the PA typed), a STAGE
(negotiating → signed → delivered → paid), a list of DELIVERABLES, and a
deadline. This engine produces a deterministic PIPELINE roll-up (totals per stage,
weighted "expected" value, overdue list from a passed-in `now`) and a stable
ordering for the board.

Pure Python, deterministic, no Django, no DB, no network, **no clock**, **no AI**,
**no payment**. This module HOLDS NO MONEY and MOVES NO MONEY — it only TRACKS
values the PA typed. Every amount that appears is a manual estimate, never ours.
Mirrors the conventions of the other pa_*/logic modules.

Run self-tests (no DB):
    python3 -c "import core.logic.pa_deals_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

from datetime import datetime


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ---------------------------------------------------------------- vocabulary
# Deal stages, in pipeline order (neutral English seed keys; UI localises them).
STAGE_NEGOTIATING = "negotiating"
STAGE_SIGNED = "signed"
STAGE_DELIVERED = "delivered"
STAGE_PAID = "paid"
STAGES = (STAGE_NEGOTIATING, STAGE_SIGNED, STAGE_DELIVERED, STAGE_PAID)

# Deterministic rank for board ordering (earlier stage first).
_STAGE_RANK = {s: i for i, s in enumerate(STAGES)}

# Rough "likelihood this value lands" weight per stage, for an HONEST expected
# total. These are conservative, fixed weights (not a forecast model): a deal in
# negotiation counts less than one already signed. The UI labels this "expected
# (weighted)" so it is never mistaken for cash in hand.
_STAGE_WEIGHT = {
    STAGE_NEGOTIATING: 0.5,
    STAGE_SIGNED: 0.9,
    STAGE_DELIVERED: 1.0,
    STAGE_PAID: 1.0,
}

# Stages that are "closed" (work delivered or money settled) — never overdue.
_CLOSED = (STAGE_DELIVERED, STAGE_PAID)


# ------------------------------------------------------------------ parsing

def _parse(dt):
    """Lenient ISO-8601 → datetime, or None. Accepts a trailing 'Z'. Never
    raises — a bad/empty value simply has no date."""
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


def _money(v):
    """Coerce a typed value to a non-negative number (int if whole). Never
    raises; junk → 0. We only track what the PA typed — we hold no money."""
    try:
        n = float(v)
    except (TypeError, ValueError):
        return 0
    if n < 0:
        n = 0
    return int(n) if n == int(n) else round(n, 2)


# ------------------------------------------------------------- normalization

def normalize_deal(deal):
    """Coerce a dict into a clean deal. Unknown stage → negotiating. Never
    raises; never invents a brand, a value or a date."""
    d = dict(deal or {})
    stage = d.get("stage")
    if stage not in STAGES:
        stage = STAGE_NEGOTIATING
    # deliverables: a list of trimmed strings, or a newline/comma string.
    raw = d.get("deliverables")
    if isinstance(raw, (list, tuple)):
        deliverables = [_clean(x) for x in raw if _clean(x)]
    else:
        parts = str(raw or "").replace(",", "\n").split("\n")
        deliverables = [_clean(x) for x in parts if _clean(x)]
    return {
        "id": d.get("id"),
        "brand": _clean(d.get("brand")),
        "value": _money(d.get("value")),
        "stage": stage,
        "deliverables": deliverables,
        "deadline": (str(d.get("deadline")).strip() if d.get("deadline") else ""),
        "note": str(d.get("note") or ""),
    }


# ------------------------------------------------------------------- validate

def validate_deal(deal):
    """Return a list of problem keys (empty ⇒ valid). The UI localises these.
    A brand is required; deadline must parse if present."""
    d = normalize_deal(deal)
    problems = []
    if not d["brand"]:
        problems.append("brand_required")
    if d["deadline"] and _parse(d["deadline"]) is None:
        problems.append("bad_deadline")
    return problems


# ------------------------------------------------------------------ ordering

_FAR = "9999-12-31T23:59:59"


def _deal_key(d):
    """Deterministic board key: open stages before closed, then by deadline
    (undated last), then brand, then id — stable across runs."""
    rank = _STAGE_RANK.get(d["stage"], 0)
    dl = _parse(d["deadline"])
    key_time = dl.isoformat() if dl else _FAR
    return (rank, key_time, d["brand"].lower(), str(d.get("id") or ""))


def order_deals(deals):
    """New list of normalized deals in a stable board order."""
    return sorted((normalize_deal(x) for x in (deals or [])), key=_deal_key)


# ---------------------------------------------------------------- derived

def is_overdue(deal, now):
    """True when an OPEN deal (not delivered/paid) has a deadline strictly
    before `now`. Closed deals are never overdue. Deterministic — `now` is
    supplied by the caller, no clock here."""
    d = normalize_deal(deal)
    if d["stage"] in _CLOSED:
        return False
    dl = _parse(d["deadline"])
    if not dl:
        return False
    return dl.date() < now.date()


def pipeline(deals, now):
    """A deterministic pipeline roll-up — pure numbers the UI renders.

    Returns per-stage counts & value totals, an overall total, an HONEST
    weighted "expected" total (stage-weighted, clearly not cash), the count of
    deals already PAID (settled) and the list of OVERDUE open deals from `now`.
    Holds NO money; every value is one the PA typed.
    """
    ordered = order_deals(deals)
    by_stage = {s: {"count": 0, "value": 0} for s in STAGES}
    total = 0
    expected = 0.0
    paid_value = 0
    overdue = []
    for d in ordered:
        s = d["stage"]
        by_stage[s]["count"] += 1
        by_stage[s]["value"] += d["value"]
        total += d["value"]
        expected += d["value"] * _STAGE_WEIGHT[s]
        if s == STAGE_PAID:
            paid_value += d["value"]
        if is_overdue(d, now):
            overdue.append(d)
    # expected: whole number when clean, else 2dp — honest & stable
    exp = int(expected) if expected == int(expected) else round(expected, 2)
    return {
        "deals": ordered,
        "by_stage": by_stage,
        "count": len(ordered),
        "total_value": total,          # sum of ALL typed values (not cash)
        "expected_value": exp,         # stage-weighted estimate (NOT cash)
        "paid_value": paid_value,      # sum of deals marked paid (settled)
        "overdue": overdue,
        "overdue_count": len(overdue),
        # honest: nothing here is money we hold or move.
        "mock": False,
        "holds_money": False,
    }
