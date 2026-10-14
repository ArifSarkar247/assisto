"""
landlord_tenant.py — pure deterministic engine behind Assisto's LANDLORD–TENANT
rent tracker (feature #185, বাড়িওয়ালা-ভাড়াটিয়া, SPEC v2.1 §20, built to the
§21 ADVANCED standard).

WHAT IT TRACKS
--------------
A small landlord in Bangladesh rents out UNITS (flats / rooms / shops) to
TENANTS and every MONTH owes themselves a clear answer: who has paid, who is
due, how much utility share each tenant carries, and the running ARREARS. People
keep this in a paper khata and lose the thread. Assisto makes the month's
collected / due picture honest and keeps a receipt note per payment — while NEVER
holding or moving any money.

This module is PURE, in the exact idiom of `payment_ladder.py` / `samity.py`: no
Django, no DB, no network, no AI, and NO CLOCK of its own — any function that
needs "now"/"today" takes it in. Same inputs → same output, so the on-device Dart
mirror (`rent_engine.dart`) produces an identical arrears picture offline and the
self-tests pin every number.

HARD HONESTY RULES (structural, not cosmetic)
---------------------------------------------
  * NEVER HOLDS MONEY. `holds_money()` is a constant `False`. This engine records
    what a tenant paid (the landlord collects it themselves, their own way); it
    custodies nothing, transfers nothing, charges nothing.
  * TRANSPARENT MATH. Each month's bill = base rent + the tenant's utility shares
    (each either a fixed amount or an explicit share of a shared bill). `due`,
    `paid`, `outstanding` always reconcile: outstanding == bill - paid (never < 0
    for the month; credit is reported separately, never silently applied).
  * RECEIPT, NOT A TRANSACTION. A payment record carries a `note` so the landlord
    can issue a receipt line; it does not represent a money transfer by the app.

MONEY is INTEGER POISHA everywhere (1 taka = 100 poisha), no float math, so sums
never drift. Amounts arrive as integer `*_poisha` (preferred) or a taka value;
`to_poisha` normalises the taka form with Decimal.

DATA SHAPES (unknown keys ignored; missing keys use safe defaults)
------------------------------------------------------------------
unit = {
    "id": 1,
    "label": "Flat 3A",
    "rent_poisha": 1200000,          # base monthly rent (৳12,000.00)
    "tenant_name": "Karim",          # current tenant display name
    "active": true,
    "utilities": [                   # recurring utility shares for this unit
        {"name": "water", "amount_poisha": 30000},           # fixed share
        {"name": "service", "share_of_poisha": 60000,
         "share_num": 1, "share_den": 4},                     # 1/4 of a ৳600 bill
    ],
}

payment = {
    "unit_id": 1,
    "month": "2026-02",              # ISO year-month the payment is FOR
    "paid_poisha": 1250000,          # how much the tenant paid for that month
    "paid_at": "2026-02-05",
    "note": "cash, received by hand",
    "method": "cash",                # cash | bkash | bank | other (display only)
}

Everything is plain stdlib and hand-verified in landlord_tenant_tests_snippets.py.
"""

from decimal import Decimal, InvalidOperation

METHODS = ("cash", "bkash", "nagad", "bank", "other")


# ------------------------------------------------------------------ honesty
def holds_money():
    """This engine NEVER custodies money. Constant False — surfaced in the UI as
    a 'tracks rent, never holds money' banner."""
    return False


def charges_money():
    """No function here ever moves or charges money. Constant False."""
    return False


# ------------------------------------------------------------------ amounts
def to_poisha(value):
    """Taka value (string/number/Decimal) → integer poisha, NO float math.
    Invalid ⇒ 0."""
    if value is None:
        return 0
    try:
        d = Decimal(str(value).strip())
    except (InvalidOperation, ValueError):
        return 0
    return int((d * 100).to_integral_value())


def _amount_of(obj, key_poisha, key_taka):
    """Prefer an integer `*_poisha` field; else convert a taka field."""
    o = obj or {}
    if key_poisha in o and o[key_poisha] is not None:
        try:
            return max(0, int(o[key_poisha]))
        except (TypeError, ValueError):
            return 0
    return to_poisha(o.get(key_taka))


# ------------------------------------------------------------------ utilities
def utility_amount(util):
    """One utility line → integer poisha for this tenant's SHARE.

    Two honest forms:
      * fixed:  {"amount_poisha": N}  (or {"amount": "N.NN"})
      * share:  {"share_of_poisha": TOTAL, "share_num": a, "share_den": b}
                → floor(TOTAL * a / b) in integer poisha (no float, no rounding up)
    Unknown/empty ⇒ 0."""
    u = util or {}
    if ("share_of_poisha" in u) or ("share_of" in u):
        total = _amount_of(u, "share_of_poisha", "share_of")
        num = u.get("share_num", 1)
        den = u.get("share_den", 1)
        try:
            num = int(num)
            den = int(den)
        except (TypeError, ValueError):
            return 0
        if den <= 0 or num <= 0:
            return 0
        return (total * num) // den
    return _amount_of(u, "amount_poisha", "amount")


def utilities_total(unit):
    """Sum of every utility share for a unit (integer poisha)."""
    return sum(utility_amount(u) for u in (unit or {}).get("utilities", []))


def monthly_bill(unit):
    """The full monthly bill for a unit = base rent + all utility shares.

    Returns {"rent_poisha", "utilities_poisha", "bill_poisha",
             "breakdown": [{"name", "amount_poisha"}...]} so the UI can show an
    itemised receipt and the number can never be a mystery."""
    rent = _amount_of(unit, "rent_poisha", "rent")
    breakdown = [{"name": (u or {}).get("name", ""),
                  "amount_poisha": utility_amount(u)}
                 for u in (unit or {}).get("utilities", [])]
    util_total = sum(b["amount_poisha"] for b in breakdown)
    return {
        "rent_poisha": rent,
        "utilities_poisha": util_total,
        "bill_poisha": rent + util_total,
        "breakdown": breakdown,
    }


# ------------------------------------------------------------------ validate
def active_units(units):
    """Active units only, ordered by label then id (deterministic)."""
    us = [u for u in (units or []) if u.get("active", True)]
    return sorted(us, key=lambda u: (str(u.get("label") or ""),
                                     u.get("id") if isinstance(u.get("id"), int)
                                     else 1 << 30))


def validate_unit(unit):
    """Problem keys for a unit (empty ⇒ usable). The UI localises these."""
    problems = []
    u = unit or {}
    if not str(u.get("label") or "").strip():
        problems.append("label_required")
    if _amount_of(u, "rent_poisha", "rent") <= 0:
        problems.append("rent_required")
    for util in u.get("utilities", []):
        if not str((util or {}).get("name") or "").strip():
            problems.append("utility_name_required")
            break
    seen = set()
    return [p for p in problems if not (p in seen or seen.add(p))]


# ------------------------------------------------------------- month status
def _paid_for(payments, unit_id, month):
    """Total paid (integer poisha) recorded for one unit in one ISO month."""
    total = 0
    for p in payments or []:
        if p.get("unit_id") == unit_id and p.get("month") == month:
            total += _amount_of(p, "paid_poisha", "paid")
    return total


def unit_month(unit, payments, month):
    """HONEST per-unit, per-month status.

    Returns:
      {
        "unit_id", "label", "tenant_name", "month",
        "bill_poisha", "rent_poisha", "utilities_poisha", "breakdown",
        "paid_poisha",                 # total recorded for this month
        "outstanding_poisha",          # max(0, bill - paid)  (the arrears line)
        "credit_poisha",               # max(0, paid - bill)  (overpaid; reported, not applied)
        "status": "paid" | "partial" | "due",
      }
    status: "paid" when paid >= bill (and bill > 0); "partial" when 0 < paid < bill;
    "due" when nothing recorded. A zero-bill unit is "paid" (nothing owed)."""
    b = monthly_bill(unit)
    paid = _paid_for(payments, unit.get("id"), month)
    bill = b["bill_poisha"]
    outstanding = max(0, bill - paid)
    credit = max(0, paid - bill)
    if bill <= 0 or paid >= bill:
        status = "paid"
    elif paid > 0:
        status = "partial"
    else:
        status = "due"
    return {
        "unit_id": unit.get("id"),
        "label": unit.get("label"),
        "tenant_name": unit.get("tenant_name"),
        "month": month,
        "bill_poisha": bill,
        "rent_poisha": b["rent_poisha"],
        "utilities_poisha": b["utilities_poisha"],
        "breakdown": b["breakdown"],
        "paid_poisha": paid,
        "outstanding_poisha": outstanding,
        "credit_poisha": credit,
        "status": status,
    }


def month_summary(units, payments, month):
    """Whole-portfolio honest summary for one month. Every total reconciles:
        billed == collected + outstanding   (ignoring credit, reported apart)

    Returns:
      {
        "month", "unit_count",
        "billed_poisha", "collected_poisha", "outstanding_poisha", "credit_poisha",
        "paid_count", "partial_count", "due_count",
        "units": [unit_month(...) per active unit],
        "holds_money": False, "charges_money": False,
      }
    """
    rows = [unit_month(u, payments, month) for u in active_units(units)]
    billed = sum(r["bill_poisha"] for r in rows)
    collected = sum(min(r["paid_poisha"], r["bill_poisha"]) for r in rows)
    outstanding = sum(r["outstanding_poisha"] for r in rows)
    credit = sum(r["credit_poisha"] for r in rows)
    return {
        "month": month,
        "unit_count": len(rows),
        "billed_poisha": billed,
        "collected_poisha": collected,
        "outstanding_poisha": outstanding,
        "credit_poisha": credit,
        "paid_count": sum(1 for r in rows if r["status"] == "paid"),
        "partial_count": sum(1 for r in rows if r["status"] == "partial"),
        "due_count": sum(1 for r in rows if r["status"] == "due"),
        "units": rows,
        "holds_money": holds_money(),
        "charges_money": charges_money(),
    }


# --------------------------------------------------------------- arrears
def _month_seq(start_month, count):
    """`count` consecutive ISO year-months starting at `start_month` ('YYYY-MM').
    Pure date arithmetic, no clock. Returns [] on a malformed start."""
    try:
        y, m = (int(x) for x in str(start_month).split("-")[:2])
    except (ValueError, TypeError):
        return []
    if not (1 <= m <= 12):
        return []
    out = []
    for _ in range(max(0, count)):
        out.append(f"{y:04d}-{m:02d}")
        m += 1
        if m > 12:
            m = 1
            y += 1
    return out


def arrears(units, payments, start_month, through_month):
    """HONEST arrears across a RANGE of months [start_month .. through_month].

    For each active unit, sums the outstanding across every month in the range so
    the landlord sees the true running total owed — never a single-month snapshot
    mistaken for the whole picture.

    Returns:
      {
        "start_month", "through_month", "months": [ISO...],
        "total_outstanding_poisha",
        "units": [
          {"unit_id", "label", "tenant_name",
           "outstanding_poisha",             # summed over the range
           "months_in_arrears": int,         # months with any outstanding
           "per_month": [{"month", "outstanding_poisha"}...]}
        ],
      }
    The range is inclusive; an end before the start yields an empty, honest range
    (no negative spans)."""
    seq = _month_seq(start_month, 1)
    all_months = []
    # build an inclusive sequence up to through_month, capped at 120 months to
    # stay bounded on a malformed/huge range.
    y, m = (int(x) for x in str(start_month).split("-")[:2]) if seq else (0, 0)
    if seq:
        guard = 0
        cur = start_month
        while guard < 120:
            all_months.append(cur)
            if cur == through_month:
                break
            nxt = _month_seq(cur, 2)
            if len(nxt) < 2:
                break
            cur = nxt[1]
            guard += 1
        else:
            all_months = []  # never reached through_month within the cap
        # if through_month is before start_month, the loop appended only start;
        # detect and collapse to an empty honest range.
        if through_month not in all_months:
            all_months = []

    unit_rows = []
    grand = 0
    for u in active_units(units):
        per_month, u_out, in_arrears = [], 0, 0
        for mo in all_months:
            um = unit_month(u, payments, mo)
            per_month.append({"month": mo,
                              "outstanding_poisha": um["outstanding_poisha"]})
            u_out += um["outstanding_poisha"]
            if um["outstanding_poisha"] > 0:
                in_arrears += 1
        grand += u_out
        unit_rows.append({
            "unit_id": u.get("id"),
            "label": u.get("label"),
            "tenant_name": u.get("tenant_name"),
            "outstanding_poisha": u_out,
            "months_in_arrears": in_arrears,
            "per_month": per_month,
        })
    return {
        "start_month": start_month,
        "through_month": through_month,
        "months": all_months,
        "total_outstanding_poisha": grand,
        "units": unit_rows,
    }


# ------------------------------------------------------- reminder seam (doc)
def due_reminder_plan(units, payments, month, now_day=1, lead_days=3):
    """DESCRIBE-ONLY seam for a due-rent reminder (NOT wired to notifications).

    Pure helper: given the month's status, returns the list of units that are
    not fully paid plus a suggested reminder lead. The integrator may feed this
    into the EXISTING reminders/notifications pipeline (see the integration md
    'rent-reminder seam' section). This function schedules nothing, sends
    nothing, and needs no key.

      {
        "month", "lead_days",
        "needs_reminder": [{"unit_id", "label", "tenant_name",
                            "outstanding_poisha"}...],
        "wired": False,                 # honest: this only PLANS a reminder
      }
    """
    rows = [r for r in month_summary(units, payments, month)["units"]
            if r["status"] in ("due", "partial")]
    return {
        "month": month,
        "lead_days": max(0, int(lead_days)),
        "needs_reminder": [{"unit_id": r["unit_id"], "label": r["label"],
                            "tenant_name": r["tenant_name"],
                            "outstanding_poisha": r["outstanding_poisha"]}
                           for r in rows],
        "wired": False,
    }
