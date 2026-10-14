"""
domestic_staff.py — pure, deterministic DOMESTIC STAFF / DRIVER tracker
(#186, SPEC v2.1 §20). A respectful household-staff ledger for the ordinary
Bangladeshi home: a maid (bua), driver, cook, guard (dorowan), gardener (mali),
nanny etc. For each person you keep a small profile — name, role, agreed MONTHLY
SALARY, and join date — and then, month by month:

    * attendance / leave for the month (days present, days of leave),
    * salary PAID vs salary DUE for that month,
    * advances / loans you handed over,
and the one honest number a fair employer wants: how much is still owed, after
subtracting what was paid AND the advances they have already taken.

HARD RULES (identical money discipline to money_engine / mess_accounting):

  * ALL MONEY IS INTEGER POISHA.  1 taka = 100 poisha.  No float ever lands in
    the ledger. Pro-rating a salary for a mid-month joiner / partial month is the
    only division, and it is done with floor + an explicit, deterministic
    remainder rule so a month's due is an exact integer — never a rounded-up
    figure that silently overcharges or shortchanges the worker.
  * NO DB, NO AI, NO I/O, NO MONEY-HOLDING.  Returns plain dicts; the view layer
    persists the raw rows and the app only renders what we return.
  * TIME IS PASSED IN.  Any "this month" / "is salary overdue" decision takes an
    explicit `now`/`today` (a 'YYYY-MM' or 'YYYY-MM-DD' string) — no hidden
    clock — so the output is reproducible and testable.
  * DIGNITY.  Copy treats staff as employees owed a fair, transparent wage, never
    as an expense to be minimised. The summary leads with what is OWED to them.
  * Human-facing copy is returned as bilingual {"bn","en"} pairs so the Dart
    layer shows them directly and keeps ZERO Bangla in .dart.

Row shapes the view layer stores (see integration note):
  person  : {id, name, role, salary, join_date}      # salary = monthly, taka-ish
  payment : {id, person, month, kind, amount,        # kind: salary|advance|repay
             present_days, leave_days, month_days}    # attendance (salary rows)

Run self-tests (no DB):
    python3 -c "import core.logic.domestic_staff_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations


def pick(lang, bn, en):
    return en if lang == "en" else bn


# roles we offer in the picker; label is bilingual, value is a stable key.
ROLES = [
    ("maid", "বুয়া / গৃহকর্মী", "Maid / housekeeper"),
    ("driver", "ড্রাইভার", "Driver"),
    ("cook", "রাঁধুনি", "Cook"),
    ("guard", "দারোয়ান", "Guard"),
    ("gardener", "মালি", "Gardener"),
    ("nanny", "আয়া / শিশু-পরিচারিকা", "Nanny / childminder"),
    ("tutor", "গৃহশিক্ষক", "Home tutor"),
    ("other", "অন্যান্য", "Other"),
]


def role_label(value, lang="bn"):
    for v, bn, en in ROLES:
        if v == value:
            return pick(lang, bn, en)
    return value or pick(lang, "অন্যান্য", "Other")


# ---------------------------------------------------------------------------
# poisha <-> taka (integer only) — mirrors mess_accounting / famacct_engine
# ---------------------------------------------------------------------------

def to_poisha(v):
    """Coerce taka-ish input to INTEGER poisha. Junk -> 0. Computed on the
    decimal STRING so binary-float noise never leaks into the ledger."""
    if v is None or v == "":
        return 0
    if isinstance(v, bool):
        return 0
    if isinstance(v, int):
        return v
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
        taka = int(whole)
        milli = int(frac)
    except ValueError:
        return 0
    poisha = taka * 100 + milli // 10
    if milli % 10 >= 5:
        poisha += 1
    return -poisha if neg else poisha


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


def fmt_poisha(p):
    """Format integer poisha as a ৳ amount (always 2 dp). The ৳ sign lives
    here, not in .dart."""
    p = int(round(p))
    neg = p < 0
    p = abs(p)
    taka, paisa = divmod(p, 100)
    return ("-" if neg else "") + "৳" + f"{_group(taka)}.{paisa:02d}"


# ---------------------------------------------------------------------------
# month helpers (all time passed in — no live clock)
# ---------------------------------------------------------------------------

def _ym(s):
    """Normalise 'YYYY-MM' or 'YYYY-MM-DD' to (year, month). None on junk."""
    if not s:
        return None
    parts = str(s).strip().split("-")
    try:
        y = int(parts[0])
        m = int(parts[1])
    except (IndexError, ValueError):
        return None
    if not (1 <= m <= 12):
        return None
    return (y, m)


def _month_key(s):
    ym = _ym(s)
    return f"{ym[0]:04d}-{ym[1]:02d}" if ym else ""


def _cmp_month(a, b):
    """-1/0/1 comparing two 'YYYY-MM' keys. Missing sorts earliest."""
    ya = _ym(a) or (0, 0)
    yb = _ym(b) or (0, 0)
    return (ya > yb) - (ya < yb)


# ---------------------------------------------------------------------------
# pro-rated monthly due (mid-month joiner / partial month by attendance)
# ---------------------------------------------------------------------------

def month_due_poisha(salary, present_days=None, month_days=None):
    """The salary DUE for one month, in INTEGER poisha.

    * Full month (present/month unset or present >= month) -> the full salary.
    * Partial month -> floor(salary * present_days / month_days). The worker is
      only ever shortchanged by sub-poisha rounding on a genuine partial month;
      a full month always pays the full agreed salary exactly. month_days
      defaults to 30 (the usual household convention) when a partial is given
      without one. Negative/garbage day counts are clamped to a full month so a
      bad entry never invents a deduction against the worker."""
    sal = to_poisha(salary)
    if sal <= 0:
        return 0
    try:
        pd = None if present_days is None or present_days == "" else float(present_days)
        md = None if month_days is None or month_days == "" else float(month_days)
    except (TypeError, ValueError):
        return sal
    if pd is None:
        return sal
    if md is None or md <= 0:
        md = 30.0
    if pd < 0:
        return sal
    if pd >= md:
        return sal
    # exact integer floor on the poisha, deterministic.
    return (sal * int(round(pd * 1000))) // int(round(md * 1000))


# ---------------------------------------------------------------------------
# per-person month ledger
# ---------------------------------------------------------------------------

def _pid(p):
    v = p.get("id", p.get("person"))
    return v if v is not None else p.get("name")


def _sum_kind(payments, kind):
    return sum(to_poisha(p.get("amount")) for p in payments
               if (p.get("kind") or "salary") == kind)


def person_month(person, payments, month, lang="bn"):
    """Reconcile ONE person for ONE month ('YYYY-MM'). Returns a dict:

        {id, name, role, role_label, month,
         salary, salary_display,
         due, due_display,              # pro-rated if attendance given
         paid, paid_display,            # salary-kind payments logged this month
         advance, advance_display,      # advances taken this month
         repay, repay_display,          # advance repayments this month
         outstanding, outstanding_display,   # due - paid  (>0 => still owed)
         present_days, leave_days, month_days,
         state: 'owed' | 'settled' | 'overpaid'}

    OUTSTANDING is the honest figure: salary due for the month minus what was
    actually paid for the month. Advances are tracked separately (they are the
    worker's money already in hand against future salary) and reported, not
    silently netted here — that reconciliation is done across months in
    `person_summary`, so a single month is never made to look as if an advance
    'cancels' an unpaid wage."""
    mk = _month_key(month)
    sal = to_poisha(person.get("salary"))
    mine = [p for p in payments
            if _pid({"id": p.get("person")}) == _pid(person)
            and _month_key(p.get("month")) == mk]
    # attendance comes off the salary rows for the month (last one wins, stable).
    present = leave = mdays = None
    for p in mine:
        if (p.get("kind") or "salary") == "salary":
            if p.get("present_days") not in (None, ""):
                present = p.get("present_days")
            if p.get("leave_days") not in (None, ""):
                leave = p.get("leave_days")
            if p.get("month_days") not in (None, ""):
                mdays = p.get("month_days")
    due = month_due_poisha(sal, present, mdays)
    paid = _sum_kind(mine, "salary")
    advance = _sum_kind(mine, "advance")
    repay = _sum_kind(mine, "repay")
    outstanding = due - paid
    if outstanding > 0:
        state = "owed"
    elif outstanding < 0:
        state = "overpaid"
    else:
        state = "settled"
    return {
        "id": _pid(person),
        "name": person.get("name", ""),
        "role": person.get("role", ""),
        "role_label": role_label(person.get("role"), lang),
        "month": mk,
        "salary": sal,
        "salary_display": fmt_poisha(sal),
        "due": due,
        "due_display": fmt_poisha(due),
        "paid": paid,
        "paid_display": fmt_poisha(paid),
        "advance": advance,
        "advance_display": fmt_poisha(advance),
        "repay": repay,
        "repay_display": fmt_poisha(repay),
        "outstanding": outstanding,
        "outstanding_display": fmt_poisha(outstanding),
        "present_days": present,
        "leave_days": leave,
        "month_days": mdays,
        "state": state,
    }


def person_summary(person, payments, now, lang="bn"):
    """Full, honest standing for ONE person as of `now` ('YYYY-MM' or
    'YYYY-MM-DD'). Walks every month from join to now and reconciles:

        {id, name, role, role_label,
         salary, salary_display,
         total_due, total_paid, ...displays,
         wages_outstanding, wages_outstanding_display,  # sum of per-month owed
         advance_balance, advance_balance_display,      # advances - repayments
         net_dues, net_dues_display,     # wages_outstanding - advance_balance
         months: [person_month(...) ...],  # newest first
         state, state_label,              # overall: owed | settled | advance_due
         note: {bn,en}}

    NET DUES is the single number a fair employer settles on: unpaid wages,
    minus any advance the worker still holds against them. A POSITIVE net_dues
    means YOU owe the worker; NEGATIVE means the worker has taken more advance
    than wages earned-but-unpaid (an advance balance to be worked off) — shown
    honestly, never hidden. The app HOLDS NO MONEY; it only shows the number."""
    sal = to_poisha(person.get("salary"))
    nowk = _month_key(now)
    joink = _month_key(person.get("join_date"))
    mine = [p for p in payments if p.get("person") == _pid(person)]

    # the set of months to reconcile: join..now, plus any month that has a row.
    months = set()
    jym = _ym(joink)
    nym = _ym(nowk)
    if jym and nym and _cmp_month(joink, nowk) <= 0:
        y, m = jym
        while (y, m) <= nym:
            months.add(f"{y:04d}-{m:02d}")
            m += 1
            if m > 12:
                m = 1
                y += 1
    for p in mine:
        mk = _month_key(p.get("month"))
        if mk:
            months.add(mk)
    ordered = sorted(months, reverse=True)  # newest first

    rows = [person_month(person, mine, mk, lang) for mk in ordered]
    total_due = sum(r["due"] for r in rows)
    total_paid = sum(r["paid"] for r in rows)
    wages_outstanding = sum(r["outstanding"] for r in rows if r["outstanding"] > 0)
    # overpaid months reduce nothing automatically (overpay ≈ a future credit)
    advance = _sum_kind(mine, "advance")
    repay = _sum_kind(mine, "repay")
    advance_balance = advance - repay
    net_dues = wages_outstanding - advance_balance

    if net_dues > 0:
        state = "owed"
    elif advance_balance > wages_outstanding:
        state = "advance_due"
    else:
        state = "settled"

    state_label = {
        "owed": pick(lang, "আপনি বকেয়া পরিশোধ করবেন", "You owe wages"),
        "advance_due": pick(lang, "অগ্রিম সমন্বয় বাকি", "Advance to adjust"),
        "settled": pick(lang, "হিসাব পরিষ্কার", "All settled"),
    }[state]

    return {
        "id": _pid(person),
        "name": person.get("name", ""),
        "role": person.get("role", ""),
        "role_label": role_label(person.get("role"), lang),
        "salary": sal,
        "salary_display": fmt_poisha(sal),
        "total_due": total_due,
        "total_due_display": fmt_poisha(total_due),
        "total_paid": total_paid,
        "total_paid_display": fmt_poisha(total_paid),
        "wages_outstanding": wages_outstanding,
        "wages_outstanding_display": fmt_poisha(wages_outstanding),
        "advance_balance": advance_balance,
        "advance_balance_display": fmt_poisha(advance_balance),
        "net_dues": net_dues,
        "net_dues_display": fmt_poisha(net_dues),
        "months": rows,
        "state": state,
        "state_label": state_label,
        "note": {
            "bn": "সব হিসাব আপনার দেওয়া তথ্য থেকে — অ্যাপ কোনো টাকা রাখে না। "
                  "কর্মীর ন্যায্য বেতন সময়মতো পরিশোধ করা আপনার দায়িত্ব।",
            "en": "Computed from what you entered — the app holds no money. "
                  "Paying your worker's fair wage on time is your responsibility.",
        },
    }


def household_summary(people, payments, now, lang="bn"):
    """Roll-up across all staff for the household dashboard:

        {count, total_monthly_salary, total_net_dues, ...displays,
         people: [person_summary(...) ...],   # most-owed first
         anyone_owed: bool, note: {bn,en}}"""
    summaries = [person_summary(p, payments, now, lang) for p in people]
    summaries.sort(key=lambda s: (-s["net_dues"], str(s["name"]).lower()))
    total_salary = sum(to_poisha(p.get("salary")) for p in people)
    total_net = sum(s["net_dues"] for s in summaries)
    return {
        "count": len(people),
        "total_monthly_salary": total_salary,
        "total_monthly_salary_display": fmt_poisha(total_salary),
        "total_net_dues": total_net,
        "total_net_dues_display": fmt_poisha(total_net),
        "anyone_owed": any(s["state"] == "owed" for s in summaries),
        "people": summaries,
        "note": {
            "bn": "ঘরের সব কর্মীর বকেয়া এক জায়গায় — টাকা অ্যাপে রাখা হয় না।",
            "en": "All your staff's dues in one place — no money is held in the app.",
        },
    }


# ---------------------------------------------------------------------------
# validation
# ---------------------------------------------------------------------------

def validate_person(name, salary, people):
    """Validation codes for adding a staff profile."""
    problems = []
    nm = (name or "").strip()
    if not nm:
        problems.append("name_required")
    elif any((p.get("name", "").strip().lower() == nm.lower()) for p in people):
        problems.append("duplicate_name")
    if to_poisha(salary) <= 0:
        problems.append("salary_required")
    return problems


def validate_payment(amount, kind):
    problems = []
    if to_poisha(amount) <= 0:
        problems.append("amount_required")
    if (kind or "salary") not in ("salary", "advance", "repay"):
        problems.append("bad_kind")
    return problems
