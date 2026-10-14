"""
mess_accounting.py — pure, deterministic MESS & BACHELOR ACCOUNTING math
(#182, SPEC v2.1 §20). The classic Bangladeshi "mess manager": a set of members
living together, a count of meals each member ate this month, the bazar/market
expenses someone paid for, and the three numbers every mess argues about —

    meal rate  = total bazar  ÷  total meals
    a member's meal cost = their meals × meal rate
    a member's balance   = their deposits − their meal cost − their other charges

…plus a transparent monthly summary that reconciles to zero.

HARD RULES (identical to money_engine / famacct_engine discipline):

  * ALL MONEY IS INTEGER POISHA.  1 taka = 100 poisha.  Never a float in the
    ledger; the meal rate is the ONLY non-integer and it is kept as an exact
    fraction (total_bazar_poisha / total_meals) and only rounded for DISPLAY.
    A member's share of the bazar is computed as
        floor(total_bazar * member_meals / total_meals)
    with the leftover poisha handed out one-each to the members with the biggest
    fractional remainder (largest-remainder method, ties -> input order), so the
    members' meal costs ALWAYS sum EXACTLY back to total_bazar — zero drift, no
    paisa lost or invented, ever.  This is fairer AND exact: no member is
    silently charged a rounded-up rate.
  * NO DB, NO AI, NO I/O, NO MONEY-HOLDING.  This module computes and returns
    plain dicts; the view layer persists the raw rows (members / meals / bazar /
    deposits) in a flexible per-user JSON collection and renders what we return.
  * Human-facing copy is returned as bilingual {"bn","en"} pairs so the Dart
    layer shows them directly and keeps ZERO Bangla in .dart.

Run self-tests (no DB):
    python3 -c "import core.logic.mess_accounting_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ---------------------------------------------------------------------------
# poisha <-> taka (integer only; display helpers) — mirrors famacct_engine
# ---------------------------------------------------------------------------

def to_poisha(v):
    """Coerce taka-ish input to INTEGER poisha. Accepts int poisha already,
    '12.50' taka strings, ints/floats of taka — result is an int of poisha, so
    no float survives into the ledger. Junk -> 0. Computed on the decimal STRING
    so binary-float noise never leaks in."""
    if v is None or v == "":
        return 0
    if isinstance(v, bool):  # guard: bool is an int subclass
        return 0
    if isinstance(v, int):
        return v  # already poisha
    s = str(v).strip().replace(",", "")
    neg = s.startswith("-")
    if neg:
        s = s[1:]
    if "." in s:
        whole, frac = s.split(".", 1)
    else:
        whole, frac = s, ""
    whole = whole or "0"
    frac = (frac + "00")[:3]  # 3 digits lets us round the 3rd
    try:
        taka = int(whole)
        milli = int(frac)
    except ValueError:
        return 0
    poisha = taka * 100 + milli // 10
    if milli % 10 >= 5:
        poisha += 1
    return -poisha if neg else poisha


def _group(n):
    """South-Asian lakh/crore comma grouping of a non-negative integer string."""
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


def fmt_poisha(p):
    """Format integer poisha as a ৳ amount string (always 2 dp). The ৳ sign
    lives here, not in .dart."""
    p = int(round(p))
    neg = p < 0
    p = abs(p)
    taka, paisa = divmod(p, 100)
    return ("-" if neg else "") + "৳" + f"{_group(taka)}.{paisa:02d}"


# ---------------------------------------------------------------------------
# meal rate — the exact fraction, rounded only for display
# ---------------------------------------------------------------------------

def total_meals(members):
    """Sum of every member's meal count. members: [{'meals': <number>, ...}].
    Meal counts can be fractional (half-meals are common) so we keep them as
    coerced floats, but round each to the nearest tenth first for determinism."""
    return round(sum(_meals(m) for m in members), 3)


def _meals(m):
    try:
        v = float(m.get("meals", 0) or 0)
    except (TypeError, ValueError):
        v = 0.0
    if v < 0:
        v = 0.0
    return round(v, 3)


def total_bazar(bazar_entries):
    """Sum of bazar/market expense entries, in INTEGER poisha. Each entry is
    {'amount': taka-ish, ...}."""
    return sum(to_poisha(b.get("amount")) for b in bazar_entries)


def meal_rate_poisha(total_bazar_poisha, meals_total):
    """The meal rate as EXACT poisha-per-meal (a float, display-only). Returns
    0.0 when there are no meals yet (honest: rate is undefined, not infinite)."""
    tb = int(total_bazar_poisha)
    if meals_total <= 0:
        return 0.0
    return tb / meals_total


# ---------------------------------------------------------------------------
# fair, exact distribution of the bazar across members by meals eaten
# ---------------------------------------------------------------------------

def meal_cost_shares(total_bazar_poisha, members):
    """Each member's share of the bazar, in INTEGER poisha, distributed by meals
    eaten with the largest-remainder method so shares sum EXACTLY to the total
    bazar (no drift). Members with zero meals pay zero. Returns a dict
    {member_id: poisha}. Deterministic: leftover poisha go to the biggest
    fractional remainders, ties broken by input order."""
    tb = int(total_bazar_poisha)
    ids = [_mid(m) for m in members]
    meals = [_meals(m) for m in members]
    mt = sum(meals)
    if mt <= 0 or tb == 0:
        return {mid: 0 for mid in ids}
    # Work in integer "milli-meals" so the weighting is exact and deterministic
    # regardless of float representation of half-meals.
    weights = [int(round(x * 1000)) for x in meals]
    W = sum(weights)
    if W == 0:
        return {mid: 0 for mid in ids}
    sign = -1 if tb < 0 else 1
    t = abs(tb)
    floors, rems = [], []
    for w in weights:
        num = t * w
        floors.append(num // W)
        rems.append(num % W)
    leftover = t - sum(floors)
    order = sorted(range(len(ids)), key=lambda i: (-rems[i], i))
    for k in range(leftover):
        floors[order[k]] += 1
    return {ids[i]: sign * floors[i] for i in range(len(ids))}


def _mid(m):
    v = m.get("id", m.get("member"))
    return v if v is not None else m.get("name")


# ---------------------------------------------------------------------------
# deposits & other (fixed) charges per member
# ---------------------------------------------------------------------------

def deposits_by_member(deposits):
    """Sum each member's deposits (to the mess fund), in INTEGER poisha.
    deposits: [{'member': id, 'amount': taka-ish}]."""
    out = {}
    for d in deposits:
        mid = d.get("member", d.get("id"))
        out[mid] = out.get(mid, 0) + to_poisha(d.get("amount"))
    return out


def charges_by_member(charges):
    """Sum each member's OTHER fixed charges (house rent share, gas bill,
    utility, the manager's fixed buys, fines) in INTEGER poisha. These are NOT
    meal-rate items — they are added to a member's cost directly.
    charges: [{'member': id, 'amount': taka-ish}]. A charge with no member
    (member None) is a common/shared charge split equally among `members`
    elsewhere — this helper only sums the per-member ones."""
    out = {}
    for c in charges:
        mid = c.get("member", c.get("id"))
        out[mid] = out.get(mid, 0) + to_poisha(c.get("amount"))
    return out


def split_common_charges(charges, members):
    """Common (member-less) charges split EQUALLY across members using the
    exact integer method (remainder poisha to the first members by input order).
    Returns {member_id: poisha}. Per-member charges are ignored here."""
    ids = [_mid(m) for m in members]
    total = sum(to_poisha(c.get("amount")) for c in charges
                if c.get("member") in (None, "", "all", "common"))
    out = {mid: 0 for mid in ids}
    n = len(ids)
    if n == 0 or total == 0:
        return out
    base, rem = divmod(abs(total), n)
    sign = -1 if total < 0 else 1
    for i, mid in enumerate(ids):
        out[mid] = sign * (base + (1 if i < rem else 0))
    return out


# ---------------------------------------------------------------------------
# the full monthly ledger — the one function the screen calls
# ---------------------------------------------------------------------------

def monthly_summary(members, bazar_entries, deposits, charges=None, lang="bn"):
    """Reconcile a whole month. Returns a deterministic dict:

        {
          'meals_total', 'bazar_total', 'meal_rate',  (ints/float poisha)
          'meal_rate_display', 'bazar_total_display', (formatted ৳ strings)
          'members': [
             {'id','name','meals','meal_cost','deposits','other_charges',
              'balance', ...display strings..., 'state': 'owes'|'gets_back'|'clear'}
          ],
          'reconciles': bool,   # sum(meal_cost)+sum(common) == bazar+common? (exact)
          'note': {'bn','en'},
        }

    balance = deposits − meal_cost − per-member charges − share of common charges.
    A POSITIVE balance means the mess owes the member money back (gets_back);
    NEGATIVE means the member still owes the mess (owes). The module HOLDS NO
    MONEY — it only tells each member their number so they can settle offline.
    """
    charges = charges or []
    mt = total_meals(members)
    tb = total_bazar(bazar_entries)
    rate = meal_rate_poisha(tb, mt)
    meal_cost = meal_cost_shares(tb, members)
    dep = deposits_by_member(deposits)
    per_charge = charges_by_member([c for c in charges
                                    if c.get("member") not in (None, "", "all", "common")])
    common = split_common_charges(charges, members)

    rows = []
    for m in members:
        mid = _mid(m)
        mc = meal_cost.get(mid, 0)
        d = dep.get(mid, 0)
        oc = per_charge.get(mid, 0) + common.get(mid, 0)
        bal = d - mc - oc
        if bal > 0:
            state = "gets_back"
        elif bal < 0:
            state = "owes"
        else:
            state = "clear"
        rows.append({
            "id": mid,
            "name": m.get("name", ""),
            "meals": _meals(m),
            "meal_cost": mc,
            "meal_cost_display": fmt_poisha(mc),
            "deposits": d,
            "deposits_display": fmt_poisha(d),
            "other_charges": oc,
            "other_charges_display": fmt_poisha(oc),
            "balance": bal,
            "balance_display": fmt_poisha(bal),
            "state": state,
        })

    # reconciliation: every poisha of bazar + every charge is accounted for.
    charged_out = sum(r["meal_cost"] for r in rows) + \
        sum(per_charge.values()) + sum(common.values())
    charged_in = tb + sum(per_charge.values()) + \
        sum(to_poisha(c.get("amount")) for c in charges
            if c.get("member") in (None, "", "all", "common"))
    reconciles = (charged_out == charged_in)

    return {
        "meals_total": mt,
        "bazar_total": tb,
        "bazar_total_display": fmt_poisha(tb),
        "meal_rate": rate,
        "meal_rate_display": fmt_poisha(rate),
        "members": rows,
        "reconciles": reconciles,
        "note": {
            "bn": "সব হিসাব আপনার দেওয়া তথ্য থেকে নিখুঁতভাবে করা — "
                  "অ্যাপ কোনো টাকা রাখে না, শুধু প্রত্যেকের হিসাব দেখায়।",
            "en": "Computed exactly from the counts you entered — the app holds "
                  "no money, it only shows each member's number.",
        }
    }


def validate_member(name, members):
    """Validation codes for adding a member (empty / duplicate name)."""
    problems = []
    nm = (name or "").strip()
    if not nm:
        problems.append("name_required")
    elif any((m.get("name", "").strip().lower() == nm.lower()) for m in members):
        problems.append("duplicate_name")
    return problems
