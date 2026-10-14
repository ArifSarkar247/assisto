"""
budget.py — pure, unit-testable BUDGET engine for the My Account module (#50).

Advanced budgeting: set a monthly limit per category, track spent-vs-budget from
REAL transactions (the same rows money_engine sees — this module never invents
spend), render progress + over-budget alerts, apply a 50-30-20 template, carry
unused budget forward (rollover), summarise this-month, keep a history series,
surface plain-language insights ("Food is 20% over"), and link budgets to a
savings goal.

Design rules (mirrors money_engine.py / medicine.py):
  * NO Django imports at module load. Every function takes plain dicts / numbers
    so it is reasoned-about and tested in isolation. The views layer feeds it
    ORM rows (the SAME transaction rows the money views already pull).
  * NO float drift. All money is handled as INTEGER POISHA (1 Taka = 100 poisha)
    internally; only the public-facing formatters convert back to a 2dp Decimal.
    Addition / subtraction / rollover therefore never accumulate binary-float
    error, and percentages are integer-rounded deterministically.

Public surface:
  to_poisha / from_poisha / taka_str      — the integer-money boundary
  spent_by_category                        — real-transaction rollup for a month
  budget_line                              — one category: limit vs spent + state
  month_budget                             — all categories for a month (the card list)
  rollover_series                          — one category across months, carry in/out
  template_50_30_20                        — needs/wants/savings split of an income
  insights                                 — ranked plain-language over/near messages
  goal_contribution                        — link a budget's underspend to a savings goal
  next_month_plan                          — suggest next month's limits from history
"""
from collections import defaultdict
from decimal import Decimal, ROUND_HALF_UP

# ---------------------------------------------------------------------------
# integer-poisha money boundary  (no float ever touches a running total)
# ---------------------------------------------------------------------------

CENTS = Decimal("0.01")

#: categories that count as "needs" vs "wants" for the 50-30-20 template and
#: for the needs/wants rollup. Savings is handled separately (goals / explicit).
NEEDS_CATEGORIES = frozenset(
    {"food", "transport", "utility", "rent", "health", "mobile", "education"})
WANTS_CATEGORIES = frozenset({"shopping", "entertainment", "dining", "travel"})

#: default template buckets (integer percent — sums to 100).
TEMPLATE_50_30_20 = (("needs", 50), ("wants", 30), ("savings", 20))


def to_poisha(v):
    """Coerce anything (str / int / float / Decimal / None) to INTEGER poisha.

    Float inputs are rounded at the 2dp boundary FIRST (via Decimal(str(v))) so
    a value like 19.99 becomes exactly 1999 poisha, never 1998 from binary drift.
    Junk / None -> 0.
    """
    if v is None or v == "":
        return 0
    if isinstance(v, int):
        return v * 100
    if isinstance(v, Decimal):
        d = v
    else:
        try:
            d = Decimal(str(v))
        except Exception:
            return 0
    return int((d * 100).quantize(Decimal("1"), rounding=ROUND_HALF_UP))


def from_poisha(p):
    """INTEGER poisha -> 2dp Decimal Taka (for API payloads / display)."""
    return (Decimal(int(p)) / 100).quantize(CENTS, rounding=ROUND_HALF_UP)


def taka_str(p):
    """INTEGER poisha -> plain '1234.50' string (no symbol; the app adds ৳)."""
    return str(from_poisha(p))


def _pct(spent_p, limit_p):
    """Integer percent of limit used. 0 when there is no limit."""
    if limit_p <= 0:
        return 0
    # integer math only: round half-up without touching a float.
    return int((Decimal(spent_p) / Decimal(limit_p) * 100)
               .quantize(Decimal("1"), rounding=ROUND_HALF_UP))


def _month_of(d):
    """'YYYY-MM' for a date-ish value ('2026-10-05' / date / '2026-10')."""
    if d is None:
        return None
    s = str(d)
    return s[:7] if len(s) >= 7 else None


# ---------------------------------------------------------------------------
# real-transaction rollup  (spent comes ONLY from actual expense rows)
# ---------------------------------------------------------------------------

def spent_by_category(txns, month=None):
    """Sum EXPENSE transactions per category, in integer poisha.

    txns: the real rows (dicts) — {'kind','amount','category','date',...}. Only
    rows with kind=='expense' count as spend; income / transfers are ignored, so
    "spent" is always grounded in actual money that left an account.
    month: 'YYYY-MM' to restrict; None = every month combined.
    Uncategorised expenses roll up under 'uncategorized'.
    """
    out = defaultdict(int)
    for t in txns:
        if (t.get("kind") or "expense") != "expense":
            continue
        if month is not None and _month_of(t.get("date")) != month:
            continue
        cat = (t.get("category") or "uncategorized") or "uncategorized"
        out[cat] += to_poisha(t.get("amount"))
    return dict(out)


# ---------------------------------------------------------------------------
# one category: limit vs real spend + honest state
# ---------------------------------------------------------------------------

def budget_line(category, monthly_limit, spent, warn_pct=80, carried_in=0):
    """One budget row: effective limit vs real spend, with an honest state.

    Returns a dict ready for the API / progress bar:
      category, limit (base), carried_in, effective_limit, spent, remaining,
      pct (int, NOT clamped — may exceed 100 so the UI can show "130%"),
      bar_pct (clamped 0..100 for the progress bar), state, over_by.

    state:
      'none' — no limit set (tracking only; pct meaningless)
      'ok'   — under the warn threshold
      'near' — at/over warn_pct but not over the limit
      'over' — spent exceeds the effective limit  (the alert trigger)
    All amounts are integer poisha in, Decimal Taka out.
    """
    base = to_poisha(monthly_limit)
    carry = to_poisha(carried_in)
    eff = base + carry
    sp = to_poisha(spent)
    remaining = eff - sp  # may be negative (overspent)
    if eff <= 0:
        state, pct = "none", 0
    else:
        pct = _pct(sp, eff)
        if sp > eff:
            state = "over"
        elif pct >= warn_pct:
            state = "near"
        else:
            state = "ok"
    over_by = max(0, sp - eff)
    return {
        "category": category,
        "limit": from_poisha(base),
        "carried_in": from_poisha(carry),
        "effective_limit": from_poisha(eff),
        "spent": from_poisha(sp),
        "remaining": from_poisha(remaining),
        "pct": pct,
        "bar_pct": min(100, max(0, pct)),
        "state": state,
        "over_by": from_poisha(over_by),
    }


def month_budget(budgets, txns, month, warn_pct=80):
    """All budget lines for ONE month + a roll-up total.

    budgets: list of {'category','monthly_limit','rollover'(bool),
                      'carried_in'(optional poisha/str)}.
    txns: real transaction rows (reused read-only).
    Returns {month, lines[], totals{...}, any_over, over_count}. 'spent' per line
    is pulled from spent_by_category(txns, month) — never fabricated.
    """
    spend = spent_by_category(txns, month)
    lines = []
    tot_limit = tot_spent = tot_carry = 0
    for b in budgets:
        cat = b.get("category")
        # spend_by_category returns INTEGER POISHA; budget_line coerces its
        # `spent` arg through to_poisha (Taka units), so hand it the Decimal
        # Taka to avoid a double *100.
        line = budget_line(cat, b.get("monthly_limit"),
                           from_poisha(spend.get(cat, 0)), warn_pct,
                           carried_in=b.get("carried_in", 0))
        line["rollover"] = bool(b.get("rollover"))
        lines.append(line)
        tot_limit += to_poisha(b.get("monthly_limit")) + to_poisha(
            b.get("carried_in", 0))
        tot_spent += spend.get(cat, 0)
        tot_carry += to_poisha(b.get("carried_in", 0))
    # uncategorised / un-budgeted real spend this month (honest: show it exists)
    budgeted_cats = {b.get("category") for b in budgets}
    unbudgeted = sum(v for c, v in spend.items() if c not in budgeted_cats)
    lines.sort(key=lambda r: ({"over": 0, "near": 1, "ok": 2, "none": 3}[r["state"]],
                              -to_poisha(r["spent"])))
    over_count = sum(1 for r in lines if r["state"] == "over")
    return {
        "month": month,
        "lines": lines,
        "totals": {
            "limit": from_poisha(tot_limit),
            "spent": from_poisha(tot_spent),
            "remaining": from_poisha(tot_limit - tot_spent),
            "carried_in": from_poisha(tot_carry),
            "pct": _pct(tot_spent, tot_limit),
            "unbudgeted_spent": from_poisha(unbudgeted),
        },
        "any_over": over_count > 0,
        "over_count": over_count,
    }


# ---------------------------------------------------------------------------
# rollover: one category across months (carry unused budget forward)
# ---------------------------------------------------------------------------

def rollover_series(category, monthly_limit, spend_by_month, months,
                    rollover=True, warn_pct=80):
    """Per-month effective budget when unused budget rolls forward.

    spend_by_month: {'YYYY-MM': spent}  (spent already summed from real txns).
    months: ordered 'YYYY-MM' list, oldest first.
    Each month effective_limit = base + carry-in (carry only when rollover on).
    carry-out = max(0, effective - spent): overspend NEVER creates negative carry,
    it shows as 'over' that month. All integer poisha — carry cannot drift.
    """
    base = to_poisha(monthly_limit)
    carry = 0  # integer poisha
    out = []
    for mk in months:
        spent_p = to_poisha(spend_by_month.get(mk, 0))
        line = budget_line(category, from_poisha(base), from_poisha(spent_p),
                           warn_pct, carried_in=from_poisha(carry if rollover else 0))
        line["month"] = mk
        out.append(line)
        eff = base + (carry if rollover else 0)
        carry = max(0, eff - spent_p) if rollover else 0
    return {
        "category": category,
        "rollover": bool(rollover),
        "months": out,
        "carry_forward": from_poisha(carry),
    }


# ---------------------------------------------------------------------------
# 50-30-20 template
# ---------------------------------------------------------------------------

def template_50_30_20(monthly_income, template=TEMPLATE_50_30_20):
    """Split an income into needs / wants / savings buckets.

    Integer poisha so the three buckets sum EXACTLY to income (the last bucket
    absorbs the rounding residue — no poisha lost). Returns the bucket amounts
    plus the residue-free total, ready to seed budgets or a savings goal.
    """
    income = to_poisha(monthly_income)
    rows = []
    allocated = 0
    for i, (name, pct) in enumerate(template):
        if i == len(template) - 1:
            amt = income - allocated  # last bucket takes the residue
        else:
            amt = income * pct // 100
            allocated += amt
        rows.append({"bucket": name, "percent": pct, "amount": from_poisha(amt)})
    return {
        "income": from_poisha(income),
        "buckets": rows,
        "savings_amount": next(
            (r["amount"] for r in rows if r["bucket"] == "savings"),
            from_poisha(0)),
    }


# ---------------------------------------------------------------------------
# insights  (plain-language, ranked; the UI localises the KEY)
# ---------------------------------------------------------------------------

def insights(month_result, max_items=3):
    """Ranked, structured insights from a month_budget() result.

    Returns a list of {code, category, pct, over_by} the app localises. Codes:
      'over'      — "{category} is {pct-100}% over budget"  (worst first)
      'near'      — "{category} is at {pct}% of budget"
      'on_track'  — emitted ONLY when nothing is over/near (honest positive)
    Never invents numbers; everything derives from the real-spend lines.
    """
    lines = month_result.get("lines", [])
    overs = sorted((l for l in lines if l["state"] == "over"),
                   key=lambda l: l["pct"], reverse=True)
    nears = sorted((l for l in lines if l["state"] == "near"),
                   key=lambda l: l["pct"], reverse=True)
    out = []
    for l in overs:
        out.append({"code": "over", "category": l["category"],
                    "pct": max(0, l["pct"] - 100), "over_by": l["over_by"]})
    for l in nears:
        out.append({"code": "near", "category": l["category"],
                    "pct": l["pct"], "over_by": l["over_by"]})
    out = out[:max_items]
    if not out and lines:
        out.append({"code": "on_track", "category": None, "pct": 0,
                    "over_by": from_poisha(0)})
    return out


# ---------------------------------------------------------------------------
# savings-goal link
# ---------------------------------------------------------------------------

def goal_contribution(month_result, goal):
    """How much of this month's TOTAL underspend can top up a savings goal.

    goal: {'target_amount','saved_amount'}. contribution = total remaining
    (never negative — an over-budget month contributes nothing). Returns the
    contribution, the resulting saved amount, the new progress %, and whether
    the goal would then be reached. Integer poisha throughout.
    """
    remaining_p = to_poisha(month_result.get("totals", {}).get("remaining", 0))
    contribution = max(0, remaining_p)
    target = to_poisha(goal.get("target_amount"))
    saved = to_poisha(goal.get("saved_amount"))
    new_saved = min(saved + contribution, target) if target > 0 else saved + contribution
    pct = _pct(new_saved, target) if target > 0 else 0
    return {
        "contribution": from_poisha(contribution),
        "new_saved": from_poisha(new_saved),
        "target": from_poisha(target),
        "progress_pct": min(100, pct),
        "reached": target > 0 and new_saved >= target,
    }


# ---------------------------------------------------------------------------
# next-month plan  (suggest limits from real history)
# ---------------------------------------------------------------------------

def next_month_plan(txns, months, categories=None, buffer_pct=10):
    """Suggest next month's per-category limit = average real spend + buffer.

    months: history 'YYYY-MM' list to average over (real expenses only).
    categories: restrict to these; None = every category that had spend.
    buffer_pct: integer headroom added over the average (default 10%).
    Integer poisha; the average is floor-divided then buffered, so suggestions
    are stable and never drift. Months with zero spend still count (so a spiky
    category isn't over-suggested).
    """
    if not months:
        return {"months": [], "suggestions": []}
    totals = defaultdict(int)
    seen_cats = set()
    for mk in months:
        s = spent_by_category(txns, mk)
        for c, v in s.items():
            totals[c] += v
            seen_cats.add(c)
    cats = categories if categories is not None else sorted(seen_cats)
    n = len(months)
    rows = []
    for c in cats:
        avg = totals.get(c, 0) // n
        suggested = avg + (avg * buffer_pct // 100)
        rows.append({
            "category": c,
            "avg_spent": from_poisha(avg),
            "suggested_limit": from_poisha(suggested),
        })
    rows.sort(key=lambda r: to_poisha(r["suggested_limit"]), reverse=True)
    return {"months": list(months), "buffer_pct": buffer_pct, "suggestions": rows}
