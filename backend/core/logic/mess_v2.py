"""
mess_v2.py — pure, deterministic math for MESS AND BACHELOR V2 (owner order
10 Nov 01:20, Part 2 A–L). NO DB, NO I/O: the view layer (core/views_mess.py)
loads rows and calls these functions.

Units
  * money: INTEGER POISHA (1 taka = 100 poisha). Never a float in a ledger.
  * meals: INTEGER MILLI-MEALS (1 meal = 1000). Breakfast is 500 by default
    (mess setting may make it 1000); lunch 1000; dinner 1000. So one person's
    day is 2500 / 1500 / 1000 / 0 etc. Guest meals count under the HOST.

Rules (owner order)
  * Meals are ON by default every day for every member who is in the mess on
    that day; a stored day row overrides the default.
  * MEAL RATE = total BAZAR ÷ total meals. Service charges are NOT in it.
  * Service charges (khala, electricity, gas, water, Wi-Fi, rent, other) are
    split EQUALLY by default, or by seat/room share (weights) when the charge
    says so. Split with the largest-remainder method: shares sum EXACTLY to
    the bill.
  * Month end per member: meals × rate + service charges − deposits − carry-in
    credit = will pay (positive due) / will get back (negative due).
    We report `balance` = credit − cost (positive = gets back).
"""
from __future__ import annotations

import datetime as _dt

from . import mess_accounting as V1

MEAL = 1000
BREAKFAST_DEFAULT = 500
SLOTS = ("b", "l", "d")
CHARGE_KINDS = ("khala", "electricity", "gas", "water", "wifi", "rent", "other")
DEFAULT_CUTOFF_HOUR = 22          # 10 pm the day before
MAX_RANGE_DAYS = 62               # multi-day meal off: at most ~2 months


# ---------------------------------------------------------------- months
def clamp_start_day(v):
    try:
        v = int(v)
    except (TypeError, ValueError):
        return 1
    return max(1, min(28, v))


def _add_month(d):
    y, m = (d.year + 1, 1) if d.month == 12 else (d.year, d.month + 1)
    return _dt.date(y, m, d.day)


def period_for(day, start_day=1):
    """(start, end) of the mess month that contains `day`. start_day 1-28."""
    s = clamp_start_day(start_day)
    if day.day >= s:
        start = _dt.date(day.year, day.month, s)
    else:
        y, m = (day.year - 1, 12) if day.month == 1 else (day.year, day.month - 1)
        start = _dt.date(y, m, s)
    end = _add_month(start) - _dt.timedelta(days=1)
    return start, end


def month_key(start):
    return start.isoformat()[:7]


def period_from_key(key, start_day=1):
    """'2026-11' -> (start, end) of that mess month."""
    try:
        y, m = (int(x) for x in str(key).split("-")[:2])
        start = _dt.date(y, m, clamp_start_day(start_day))
    except (TypeError, ValueError):
        return None
    return start, _add_month(start) - _dt.timedelta(days=1)


def days(start, end):
    d = start
    while d <= end:
        yield d
        d += _dt.timedelta(days=1)


# ---------------------------------------------------------------- meals
def _int(v, lo=0, hi=50):
    try:
        v = int(round(float(v)))
    except (TypeError, ValueError):
        return lo
    return max(lo, min(hi, v))


def clean_day(data):
    """Normalise a stored/posted meal day: {'b','l','d'} on/off (0/1) and
    {'gb','gl','gd'} guest counts (0-20)."""
    data = data or {}
    out = {s: (1 if _int(data.get(s, 1), 0, 1) else 0) for s in SLOTS}
    for s in SLOTS:
        out["g" + s] = _int(data.get("g" + s, 0), 0, 20)
    return out


DEFAULT_DAY = {"b": 1, "l": 1, "d": 1, "gb": 0, "gl": 0, "gd": 0}


def day_milli(day, breakfast=BREAKFAST_DEFAULT):
    """Milli-meals of one member-day (own + guests)."""
    d = clean_day(day)
    w = {"b": int(breakfast), "l": MEAL, "d": MEAL}
    return sum((d[s] + d["g" + s]) * w[s] for s in SLOTS)


def in_mess_on(member, day):
    """member: {'joined_on': date, 'left_on': date|None}. Left day excluded."""
    j = member.get("joined_on")
    left = member.get("left_on")
    if j and day < j:
        return False
    if left and day >= left:
        return False
    return True


def meals_by_member(members, day_rows, start, end, breakfast=BREAKFAST_DEFAULT):
    """{member_id: milli} for the window, defaulting every in-mess day to ON.
    day_rows: {(member_id, date): data}."""
    out = {}
    for m in members:
        mid = m["id"]
        tot = 0
        for d in days(start, end):
            if not in_mess_on(m, d):
                continue
            row = day_rows.get((mid, d))
            tot += day_milli(row if row is not None else DEFAULT_DAY, breakfast)
        out[mid] = tot
    return out


def can_member_edit_day(day, now_local, cutoff_hour=DEFAULT_CUTOFF_HOUR):
    """A member may change own meals for `day` only until cutoff_hour on the
    day BEFORE (Dhaka local time). Managers/admins bypass this in the view."""
    ch = _int(cutoff_hour, 0, 23)
    limit = _dt.datetime.combine(day - _dt.timedelta(days=1), _dt.time(ch, 0))
    return now_local.replace(tzinfo=None) < limit


OFFLINE_GRACE_HOURS = 24        # a meal change saved offline may sync this late


def offline_saved_ok(day, saved_local, now_local, cutoff_hour=DEFAULT_CUTOFF_HOUR,
                     grace_hours=OFFLINE_GRACE_HOURS):
    """gap-money: a member's meal change SAVED OFFLINE before the cut-off is
    still accepted when the phone gets internet after it. The phone's
    saved-at time is never trusted alone — all must hold:
      * saved_at is before the cut-off (day before, cutoff_hour, Dhaka);
      * saved_at is not in the future of the server clock;
      * the sync arrives at most `grace_hours` after the cut-off (so an old
        or forged clock can only reach back one day, never rewrite history).
    """
    if saved_local is None:
        return False
    ch = _int(cutoff_hour, 0, 23)
    limit = _dt.datetime.combine(day - _dt.timedelta(days=1), _dt.time(ch, 0))
    saved = saved_local.replace(tzinfo=None)
    now = now_local.replace(tzinfo=None)
    return (saved < limit and saved <= now
            and now <= limit + _dt.timedelta(hours=_int(grace_hours, 0, 72)))


# ---------------------------------------------------------------- splitting
def split_weighted(total, weights):
    """Largest-remainder split of integer `total` by integer `weights`
    ({id: w}). Shares sum EXACTLY to total; ties -> input order."""
    ids = list(weights.keys())
    W = sum(max(0, int(weights[i])) for i in ids)
    if not ids or W == 0 or total == 0:
        return {i: 0 for i in ids}
    sign = -1 if total < 0 else 1
    t = abs(int(total))
    floors, rems = [], []
    for i in ids:
        num = t * max(0, int(weights[i]))
        floors.append(num // W)
        rems.append(num % W)
    left = t - sum(floors)
    order = sorted(range(len(ids)), key=lambda k: (-rems[k], k))
    for k in range(left):
        floors[order[k]] += 1
    return {ids[k]: sign * floors[k] for k in range(len(ids))}


def days_present(member, start, end):
    """Days of [start, end] the member is in the mess (left day excluded)."""
    j = member.get("joined_on")
    left = member.get("left_on")
    a = max(start, j) if j else start
    b = min(end, left - _dt.timedelta(days=1)) if left else end
    return max(0, (b - a).days + 1)


def charge_shares(charge, members, period=None):
    """One service charge -> {member_id: poisha}. charge: {'amount' poisha,
    'split': 'equal'|'seat', 'members': [ids] optional subset}. members:
    [{'id','seat_share','joined_on','left_on'}] who are in the mess that month.

    gap-money: with `period` = (start, end) the bill is PRO-RATED by the days
    each member was in the mess — someone who joins on the 21st of a 30-day
    month pays 10/30 of an equal share (× seat share for rent). A member in
    for the whole month weighs the same as before, so full-month messes keep
    the exact old numbers. Largest remainder: shares still sum EXACTLY to the
    bill."""
    subset = charge.get("members") or []
    pool = [m for m in members if not subset or m["id"] in subset]
    if period is not None:
        days = {m["id"]: days_present(m, period[0], period[1]) for m in pool}
    else:
        days = {m["id"]: 1 for m in pool}
    if charge.get("split") == "seat":
        w = {m["id"]: max(0, int(m.get("seat_share") or 0)) * days[m["id"]] for m in pool}
        if sum(w.values()) == 0:
            w = dict(days)
    else:
        w = dict(days)
    if sum(w.values()) == 0:
        w = {m["id"]: 1 for m in pool}
    return split_weighted(int(charge.get("amount") or 0), w)


# ---------------------------------------------------------------- month end
def settle(members, meals, bazar, charges, deposits, carry_in=None, period=None):
    """The month-end table.

    members  [{'id','name','seat_share'}]
    meals    {id: milli}
    bazar    [{'amount' poisha}]
    charges  [{'amount','kind','split','members'}]
    deposits [{'member', 'amount'}]
    carry_in {id: poisha}  (+ = credit from last month, − = still owed)
    period   (start, end) — service bills pro-rated by days present

    Returns totals + per-member rows; every row's
        due = meal_cost + service − deposits − carry_in
    (due > 0: will pay; due < 0: will get back). `reconciles` proves the
    meal costs sum exactly to the bazar and the service shares to the bills.
    """
    carry_in = carry_in or {}
    meals_total = sum(meals.get(m["id"], 0) for m in members)
    bazar_total = sum(int(b.get("amount") or 0) for b in bazar)
    cost = split_weighted(bazar_total, {m["id"]: meals.get(m["id"], 0) for m in members}) \
        if meals_total > 0 else {m["id"]: 0 for m in members}
    service = {m["id"]: 0 for m in members}
    by_kind = {m["id"]: {} for m in members}
    charges_total = 0
    for c in charges:
        charges_total += int(c.get("amount") or 0)
        for mid, p in charge_shares(c, members, period).items():
            service[mid] = service.get(mid, 0) + p
            k = c.get("kind") or "other"
            by_kind.setdefault(mid, {})[k] = by_kind.get(mid, {}).get(k, 0) + p
    dep = {}
    for d in deposits:
        dep[d.get("member")] = dep.get(d.get("member"), 0) + int(d.get("amount") or 0)
    rows = []
    for m in members:
        mid = m["id"]
        due = cost.get(mid, 0) + service.get(mid, 0) - dep.get(mid, 0) - int(carry_in.get(mid, 0))
        rows.append({
            "id": mid, "name": m.get("name", ""),
            "meals_milli": meals.get(mid, 0),
            "meal_cost": cost.get(mid, 0),
            "service": service.get(mid, 0),
            "service_by_kind": by_kind.get(mid, {}),
            "deposits": dep.get(mid, 0),
            "carry_in": int(carry_in.get(mid, 0)),
            "due": due,
            "balance": -due,
            "state": "will_pay" if due > 0 else ("gets_back" if due < 0 else "clear"),
        })
    reconciles = (sum(cost.values()) == (bazar_total if meals_total > 0 else 0)
                  and sum(service.values()) == charges_total
                  if members else True)
    rate = (bazar_total * MEAL / meals_total) if meals_total > 0 else 0.0
    return {
        "meals_total_milli": meals_total,
        "bazar_total": bazar_total,
        "charges_total": charges_total,
        "deposits_total": sum(dep.values()),
        "meal_rate": rate,                 # poisha per meal (display only)
        "meal_rate_display": V1.fmt_poisha(rate),
        "members": rows,
        "reconciles": bool(reconciles),
    }


def carry_out(settlement):
    """Balances to carry into next month: {id: credit} (+ gets back)."""
    return {r["id"]: r["balance"] for r in settlement.get("members", [])}


# ---------------------------------------------------------------- text
def fmt_meals(milli):
    whole, frac = divmod(int(milli), MEAL)
    if frac == 0:
        return str(whole)
    return ("%d.%03d" % (whole, frac)).rstrip("0")


def report_text(mess_name, key, s, lang="bn"):
    """Plain-text month report (shared into the E2E group by the app)."""
    bn = lang != "en"
    lines = []
    lines.append(("%s — %s মাসের হিসাব" if bn else "%s — %s month report") % (mess_name, key))
    lines.append(("মোট বাজার %s, মোট মিল %s, মিল রেট %s" if bn else
                  "Total bazar %s, total meals %s, meal rate %s") % (
        V1.fmt_poisha(s["bazar_total"]), fmt_meals(s["meals_total_milli"]),
        s["meal_rate_display"]))
    if s.get("charges_total"):
        lines.append(("সার্ভিস চার্জ মোট %s" if bn else "Service charges total %s")
                     % V1.fmt_poisha(s["charges_total"]))
    for r in s["members"]:
        if r["state"] == "will_pay":
            res = ("দেবেন %s" if bn else "will pay %s") % V1.fmt_poisha(r["due"])
        elif r["state"] == "gets_back":
            res = ("ফেরত পাবেন %s" if bn else "gets back %s") % V1.fmt_poisha(-r["due"])
        else:
            res = "হিসাব সমান" if bn else "all clear"
        lines.append(("• %s: মিল %s, সার্ভিস %s, জমা %s → %s" if bn else
                      "• %s: meals %s, service %s, deposits %s → %s") % (
            r["name"], fmt_meals(r["meals_milli"]), V1.fmt_poisha(r["service"]),
            V1.fmt_poisha(r["deposits"]), res))
    out = "\n".join(lines)
    if bn:
        out = to_bn_digits(out)
    return out


def to_bn_digits(s):
    return "".join(chr(0x09E6 + ord(c) - 48) if "0" <= c <= "9" else c for c in str(s))
