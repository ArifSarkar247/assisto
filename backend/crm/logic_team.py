"""
TEAM logic (CRM spec #8) — PURE PYTHON, no Django imports.

The views layer feeds these functions plain dicts (built from ORM rows) and
persists whatever they return. Everything here is deterministic given its
inputs so it can be unit-tested with no DB, no network, no clock.

What lives here:
  * round-robin assignment picker — fair + deterministic given a member order
    and a persisted cursor (no RNG, no wall-clock).
  * territory / industry router — first-match, deterministic, ordered rules.
  * monthly target-progress calculation — % attainment, pace vs. the month.
  * commission ENGINE — **config-driven**. The owner supplies the rule set
    (flat %, tiered, or per-deal bonus). This module BAKES NO NUMBERS: with no
    config it returns an explicit "owner must set" placeholder and zero payout.
  * activity leaderboard ranking — deterministic ordering + dense ranks + ties.

None of these invent money, percentages, or quotas. Commission % / tiers and
target amounts are OWNER-REVIEW inputs and must be passed in.
"""
from __future__ import annotations

import re
from decimal import Decimal, ROUND_HALF_UP


# A clearly-labelled sentinel the UI/serializer shows when the owner has NOT yet
# configured commission. The engine never guesses a rate.
OWNER_MUST_SET = "OWNER_MUST_SET"


# =====================================================================
# 1. ROUND-ROBIN ASSIGNMENT
# =====================================================================

def round_robin_pick(member_ids, cursor=0, count=1, skip_ids=None):
    """Pick the next ``count`` members fairly, round-robin, starting AFTER
    ``cursor`` (the index last used, persisted by the caller).

    Deterministic: given the same ordered ``member_ids`` and ``cursor`` it
    always returns the same picks. No RNG, no clock. ``skip_ids`` (e.g. members
    on leave / over quota) are stepped over but still advance fairly.

    Returns ``{"picks": [ids...], "cursor": new_cursor}``. ``cursor`` is the
    index of the LAST member handed out, so the caller persists it and passes it
    back next time. With an empty roster, picks is empty and cursor unchanged.
    """
    ids = list(member_ids)
    if not ids:
        return {"picks": [], "cursor": cursor}
    skip = set(skip_ids or [])
    eligible = [i for i in ids if i not in skip]
    if not eligible:
        return {"picks": [], "cursor": cursor}

    n = len(ids)
    # Normalise the cursor into range; -1 would mean "start at index 0".
    idx = cursor % n
    picks = []
    steps = 0
    # Walk forward over the FULL ordered list (so position is stable across
    # calls), collecting eligible members until we have `count` or we have
    # circled the whole roster without finding more.
    while len(picks) < count and steps < n * max(count, 1):
        idx = (idx + 1) % n
        steps += 1
        candidate = ids[idx]
        if candidate in skip:
            continue
        picks.append(candidate)
    last_cursor = idx if picks else cursor
    return {"picks": picks, "cursor": last_cursor}


# =====================================================================
# 2. TERRITORY / INDUSTRY ROUTER
# =====================================================================

def route_by_rules(rules, *, industry="other", source="manual", company_size=0,
                   region=""):
    """First-match territory/industry router. ``rules`` is an ORDERED list of
    dicts; the first active rule whose non-empty conditions all match wins.

    Rule dict keys (all optional except it should carry an ``assign_to`` and/or
    ``territory``):
      order, active(bool), match_industry, match_source, match_region,
      min_company_size(int), assign_to(member id), territory(id).

    Returns ``{"assign_to", "territory", "matched_rule", "reason"}``. With no
    match, assign_to/territory are None and reason explains the fall-through.
    Deterministic: rules are sorted by (order, index); first match wins.
    """
    ordered = sorted(
        enumerate(rules),
        key=lambda t: (t[1].get("order", 0), t[0]),
    )
    for _, r in ordered:
        if not r.get("active", True):
            continue
        if r.get("match_industry") and r["match_industry"] != industry:
            continue
        if r.get("match_source") and r["match_source"] != source:
            continue
        if r.get("match_region") and _norm(r["match_region"]) != _norm(region):
            continue
        mn = int(r.get("min_company_size") or 0)
        if mn and int(company_size or 0) < mn:
            continue
        return {
            "assign_to": r.get("assign_to"),
            "territory": r.get("territory"),
            "matched_rule": r.get("id"),
            "reason": "matched",
        }
    return {"assign_to": None, "territory": None, "matched_rule": None,
            "reason": "no_rule_matched"}


# =====================================================================
# 3. MONTHLY TARGET PROGRESS
# =====================================================================

def target_progress(target_amount, won_amount, *, deals_target=0, deals_won=0,
                    day_of_period=0, days_in_period=0):
    """Compute attainment for a member's (owner-set) monthly target.

    ``target_amount`` / ``deals_target`` are OWNER inputs — never invented. If
    the owner has set no amount target (``target_amount`` <= 0) we return an
    explicit ``target_set=False`` so the UI shows "owner must set a target"
    rather than a fake 0%.

    Pace: if the caller passes where we are in the period (day_of_period /
    days_in_period) we compute an expected-by-now figure so the UI can say
    "ahead/behind pace". All money is Decimal; percentages are rounded to 1dp.
    """
    tgt = _dec(target_amount)
    won = _dec(won_amount)
    out = {
        "target_amount": _money(tgt),
        "won_amount": _money(won),
        "deals_target": int(deals_target or 0),
        "deals_won": int(deals_won or 0),
        "target_set": tgt > 0 or int(deals_target or 0) > 0,
    }
    if tgt > 0:
        pct = (won / tgt) * Decimal(100)
        out["pct"] = float(pct.quantize(Decimal("0.1"), ROUND_HALF_UP))
        out["remaining"] = _money(max(Decimal(0), tgt - won))
        out["attained"] = won >= tgt
    else:
        out["pct"] = None
        out["remaining"] = None
        out["attained"] = False
        out["note"] = OWNER_MUST_SET

    if int(deals_target or 0) > 0:
        dpct = (Decimal(int(deals_won or 0)) / Decimal(int(deals_target))) \
            * Decimal(100)
        out["deals_pct"] = float(dpct.quantize(Decimal("0.1"), ROUND_HALF_UP))
    else:
        out["deals_pct"] = None

    # Pace (optional) — only when the caller tells us where in the period we are.
    if tgt > 0 and days_in_period and day_of_period:
        frac = Decimal(min(day_of_period, days_in_period)) / Decimal(days_in_period)
        expected = (tgt * frac)
        out["expected_by_now"] = _money(expected)
        out["on_pace"] = won >= expected
        gap = won - expected
        out["pace_gap"] = _money(gap)  # +ve = ahead, -ve = behind
    return out


# =====================================================================
# 4. COMMISSION ENGINE — CONFIG-DRIVEN, NO BAKED NUMBERS
# =====================================================================

def commission(won_amount, config, *, deals_won=0):
    """Compute commission payable on ``won_amount`` using an OWNER-SUPPLIED
    ``config``. **This function bakes in NO rate, NO tier, NO bonus.**

    config schema (all owner-defined; any missing → placeholder result):
      {
        "kind": "flat" | "tiered" | "none",
        "flat_pct": Decimal/str/number,         # for kind="flat"
        "tiers": [                               # for kind="tiered", ordered
           {"upto": amount|null, "pct": number}, # null upto = "and above"
        ],
        "per_deal_bonus": number,                # optional, added per won deal
      }

    Returns a dict with ``payout`` (Decimal money string), ``breakdown`` (how it
    was derived, auditable), and ``config_set`` (False when the owner has not
    configured a rule — payout is 0 and ``note`` == OWNER_MUST_SET).
    """
    won = _dec(won_amount)
    if not config or config.get("kind") in (None, "", "none"):
        return {"payout": _money(Decimal(0)), "config_set": False,
                "note": OWNER_MUST_SET, "breakdown": []}

    kind = config.get("kind")
    breakdown = []
    payout = Decimal(0)

    if kind == "flat":
        pct = _dec(config.get("flat_pct"))
        if pct <= 0:
            return {"payout": _money(Decimal(0)), "config_set": False,
                    "note": OWNER_MUST_SET, "breakdown": []}
        payout = won * pct / Decimal(100)
        breakdown.append({"band": "flat", "amount": _money(won),
                          "pct": float(pct), "commission": _money(payout)})

    elif kind == "tiered":
        tiers = config.get("tiers") or []
        if not tiers:
            return {"payout": _money(Decimal(0)), "config_set": False,
                    "note": OWNER_MUST_SET, "breakdown": []}
        # Marginal tiers: each slice of won_amount up to the tier ceiling is
        # paid at that tier's %. Ceilings must be ascending; null = top band.
        lower = Decimal(0)
        remaining = won
        for tier in tiers:
            if remaining <= 0:
                break
            upto = tier.get("upto")
            ceiling = _dec(upto) if upto is not None else None
            pct = _dec(tier.get("pct"))
            if ceiling is None:
                slice_amt = remaining
            else:
                band = max(Decimal(0), ceiling - lower)
                slice_amt = min(remaining, band)
                lower = ceiling
            if slice_amt <= 0:
                continue
            comm = slice_amt * pct / Decimal(100)
            payout += comm
            breakdown.append({"band": _money(slice_amt), "pct": float(pct),
                              "commission": _money(comm)})
            remaining -= slice_amt
    else:
        return {"payout": _money(Decimal(0)), "config_set": False,
                "note": f"unknown_kind:{kind}", "breakdown": []}

    bonus_each = _dec(config.get("per_deal_bonus"))
    if bonus_each > 0 and deals_won:
        bonus = bonus_each * Decimal(int(deals_won))
        payout += bonus
        breakdown.append({"band": "per_deal_bonus", "deals": int(deals_won),
                          "each": _money(bonus_each), "commission": _money(bonus)})

    return {"payout": _money(payout), "config_set": True, "breakdown": breakdown}


# =====================================================================
# 5. ACTIVITY LEADERBOARD RANKING
# =====================================================================

def leaderboard(rows, *, weights=None, sort_key="score"):
    """Rank members for the activity leaderboard, deterministically.

    ``rows``: list of per-member dicts, e.g.
      {"member_id", "name", "calls", "meetings", "proposals",
       "won_amount", "deals_won", ...}

    ``weights`` (OWNER-tunable, optional): a dict mapping any numeric field to a
    multiplier used to compute a composite ``score``. If omitted we fall back to
    a transparent default weighting (calls=1, meetings=3, proposals=5,
    deals_won=10) — clearly a default, overridable by the owner. Money fields
    are NOT auto-weighted (amounts dwarf counts); include them in ``weights``
    explicitly if the owner wants them scored.

    Returns rows sorted desc by ``sort_key`` with a dense ``rank`` added. Ties
    share a rank; order within a tie is by ``member_id`` asc (stable).
    """
    default_w = {"calls": 1, "meetings": 3, "proposals": 5, "deals_won": 10}
    w = dict(default_w)
    if weights:
        w = dict(weights)  # owner fully overrides the default set

    scored = []
    for r in rows:
        if "score" in r and sort_key == "score" and weights is None \
                and r.get("score") is not None:
            score = r["score"]
        else:
            score = 0
            for field, mult in w.items():
                score += _num(r.get(field)) * _num(mult)
        item = dict(r)
        item["score"] = score
        scored.append(item)

    # Deterministic sort: primary key desc, tie-break member_id asc.
    scored.sort(key=lambda x: (-_num(x.get(sort_key, 0)),
                               _num(x.get("member_id", 0))))

    # Dense ranks with shared rank on ties.
    rank = 0
    prev = object()
    for i, item in enumerate(scored):
        key_val = _num(item.get(sort_key, 0))
        if key_val != prev:
            rank = i + 1
            prev = key_val
        item["rank"] = rank
    return scored


# =====================================================================
# helpers
# =====================================================================

def _norm(s):
    return re.sub(r"\s+", " ", (s or "").strip().lower())


def _dec(v):
    if v is None or v == "":
        return Decimal(0)
    if isinstance(v, Decimal):
        return v
    return Decimal(str(v))


def _money(d):
    """Serialise a Decimal money value as a 2dp string (stable, no float drift)."""
    return str(_dec(d).quantize(Decimal("0.01"), ROUND_HALF_UP))


def _num(v):
    try:
        return float(v or 0)
    except (TypeError, ValueError):
        return 0.0
