"""
money_engine.py — pure, unit-testable finance math for the My Account module.

No Django imports at module load: every function takes plain dicts / numbers so
it can be reasoned about and tested in isolation (the views layer feeds it rows
from the ORM). Mirrors the "adherence-style" pure-function design of
medicine.py.

Covers:
  - account_balances / net worth (assets minus liabilities, over time)
  - budget spend + rollover (unused budget carries to next month)
  - trends: month-over-month totals, per-category deltas
  - loans: running balance with partial repayments + history
  - recurring transaction generation (daily / weekly / monthly)
  - split-expense allocation across people / categories
  - monthly report data (for PDF / Excel export in the app)
"""
from collections import defaultdict
from datetime import date, timedelta
from decimal import Decimal, ROUND_HALF_UP

ZERO = Decimal("0")
CENTS = Decimal("0.01")


def D(v):
    """Coerce anything (str/int/float/None/Decimal) to a Decimal, 0 on junk."""
    if v is None or v == "":
        return ZERO
    if isinstance(v, Decimal):
        return v
    try:
        return Decimal(str(v))
    except Exception:
        return ZERO


def money(v):
    """Round to 2dp for display/report."""
    return D(v).quantize(CENTS, rounding=ROUND_HALF_UP)


CATEGORY_LABELS = {
    # slug: (bn, en) — the UI localises; backend may send either via pick().
    "salary": ("বেতন", "Salary"),
    "food": ("খাবার", "Food"),
    "transport": ("যাতায়াত", "Transport"),
    "mobile": ("মোবাইল রিচার্জ", "Mobile"),
    "utility": ("ইউটিলিটি বিল", "Utilities"),
    "shopping": ("কেনাকাটা", "Shopping"),
    "health": ("স্বাস্থ্য", "Health"),
    "education": ("শিক্ষা", "Education"),
    "rent": ("বাসা ভাড়া", "Rent"),
    "sendmoney": ("টাকা পাঠানো", "Send Money"),
    "income": ("আয়", "Income"),
    "uncategorized": ("অন্যান্য", "Other"),
}


def category_label(slug, lang="bn"):
    bn, en = CATEGORY_LABELS.get(slug, (slug, slug))
    return en if lang == "en" else bn


# ---------------------------------------------------------------------------
# month helpers
# ---------------------------------------------------------------------------

def month_key(d):
    """'YYYY-MM' for a date or ISO string."""
    if isinstance(d, str):
        return d[:7]
    return f"{d.year:04d}-{d.month:02d}"


def _as_date(d):
    if isinstance(d, date):
        return d
    return date.fromisoformat(str(d)[:10])


def add_months(d, n):
    d = _as_date(d)
    m = d.month - 1 + n
    y = d.year + m // 12
    m = m % 12 + 1
    # clamp day to end of target month
    last = [31, 29 if y % 4 == 0 and (y % 100 or y % 400 == 0) else 28,
            31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1]
    return date(y, m, min(d.day, last))


def prev_month_key(mk):
    y, m = int(mk[:4]), int(mk[5:7])
    return month_key(add_months(date(y, m, 1), -1))


# ---------------------------------------------------------------------------
# balances + net worth
# ---------------------------------------------------------------------------

def account_balance(opening_balance, txns):
    """Current balance for ONE account given its txns.
    txn: {'kind': 'income'|'expense'|'transfer', 'amount', 'account', 'to_account'}
    For this account: income +amount, expense -amount, transfer out -amount,
    transfer in (to_account==this) +amount. Caller passes only this account's rows
    plus any transfer-in rows targeting it (via to_account)."""
    bal = D(opening_balance)
    for t in txns:
        amt = D(t.get("amount"))
        kind = t.get("kind")
        if kind == "income":
            bal += amt
        elif kind == "expense":
            bal -= amt
        elif kind == "transfer":
            # row appears for the source; to_account rows handled by caller split
            bal -= amt
    return money(bal)


def net_worth(accounts, loans):
    """assets = sum of account balances + money others owe me (loans given,
    outstanding); liabilities = money I owe (loans taken, outstanding)."""
    assets = sum((D(a.get("balance", a.get("opening_balance"))) for a in accounts), ZERO)
    owed_to_me = ZERO
    i_owe = ZERO
    for ln in loans:
        bal = loan_balance(ln).get("balance", ZERO)
        if ln.get("kind") == "given":
            owed_to_me += bal
        else:
            i_owe += bal
    return {
        "assets": money(assets),
        "receivable": money(owed_to_me),
        "liabilities": money(i_owe),
        "net_worth": money(assets + owed_to_me - i_owe),
    }


def net_worth_series(snapshots):
    """snapshots: list of {'month': 'YYYY-MM', 'net_worth': value} (already
    computed per month). Returns the series sorted + month-over-month delta."""
    rows = sorted(({"month": s["month"], "net_worth": money(s["net_worth"])}
                   for s in snapshots), key=lambda r: r["month"])
    prev = None
    for r in rows:
        r["delta"] = money(r["net_worth"] - prev) if prev is not None else ZERO
        prev = r["net_worth"]
    return rows


# ---------------------------------------------------------------------------
# budgets + rollover
# ---------------------------------------------------------------------------

def category_spend(txns, month=None):
    """Sum expenses per category for a month (or all months if None)."""
    out = defaultdict(lambda: ZERO)
    for t in txns:
        if t.get("kind") != "expense":
            continue
        if month and month_key(t.get("date")) != month:
            continue
        out[t.get("category") or "uncategorized"] += D(t.get("amount"))
    return {k: money(v) for k, v in out.items()}


def budget_status(limit, spent, warn_pct=80):
    """('ok'|'near'|'over', pct_int, remaining)."""
    lim = D(limit)
    sp = D(spent)
    if lim <= 0:
        return ("none", 0, money(-sp))
    pct = int((sp / lim * 100).to_integral_value(rounding=ROUND_HALF_UP))
    state = "over" if sp > lim else ("near" if pct >= warn_pct else "ok")
    return (state, pct, money(lim - sp))


def budget_with_rollover(category, monthly_limit, spend_by_month, months,
                         rollover=True):
    """Compute per-month effective budget when unused budget rolls forward.

    spend_by_month: {'YYYY-MM': spent}
    months: ordered list of 'YYYY-MM' to evaluate (oldest first).
    Each month's effective_limit = base_limit + carried-in (if rollover & carry>0).
    carry-out = effective_limit - spent (never negative; overspend does NOT
    create negative carry — it just shows as 'over' that month).
    """
    base = D(monthly_limit)
    carry = ZERO
    out = []
    for mk in months:
        spent = D(spend_by_month.get(mk, 0))
        eff = base + (carry if rollover else ZERO)
        state, pct, remaining = budget_status(eff, spent)
        out.append({
            "month": mk,
            "base_limit": money(base),
            "carried_in": money(carry if rollover else ZERO),
            "effective_limit": money(eff),
            "spent": money(spent),
            "remaining": money(eff - spent),
            "state": state,
            "pct": pct,
        })
        carry = max(ZERO, eff - spent) if rollover else ZERO
    return {"category": category, "rollover": rollover, "months": out,
            "carry_forward": money(carry)}


# ---------------------------------------------------------------------------
# trends
# ---------------------------------------------------------------------------

def monthly_totals(txns):
    """{'YYYY-MM': {'income','expense','net'}} across all txns."""
    acc = defaultdict(lambda: {"income": ZERO, "expense": ZERO})
    for t in txns:
        mk = month_key(t.get("date"))
        if not mk:
            continue
        kind = t.get("kind")
        if kind in ("income", "expense"):
            acc[mk][kind] += D(t.get("amount"))
    out = {}
    for mk, v in acc.items():
        out[mk] = {"income": money(v["income"]), "expense": money(v["expense"]),
                   "net": money(v["income"] - v["expense"])}
    return dict(sorted(out.items()))


def month_over_month(txns, months_back=6, today=None):
    """Series of the last `months_back` months with income/expense/net and the
    net delta vs the previous month."""
    today = today or date.today()
    totals = monthly_totals(txns)
    series = []
    prev_net = None
    cur = date(today.year, today.month, 1)
    keys = [month_key(add_months(cur, -(months_back - 1 - i))) for i in range(months_back)]
    for mk in keys:
        t = totals.get(mk, {"income": ZERO, "expense": ZERO, "net": ZERO})
        delta = money(t["net"] - prev_net) if prev_net is not None else ZERO
        series.append({"month": mk, **t, "delta": delta})
        prev_net = t["net"]
    return series


def category_trends(txns, month, prev=None):
    """Per-category spend this month vs previous, with the delta. `prev` defaults
    to the month before `month`."""
    prev = prev or prev_month_key(month)
    cur_s = category_spend(txns, month)
    prev_s = category_spend(txns, prev)
    cats = set(cur_s) | set(prev_s)
    rows = []
    for c in cats:
        now = cur_s.get(c, ZERO)
        was = prev_s.get(c, ZERO)
        rows.append({
            "category": c,
            "current": money(now),
            "previous": money(was),
            "delta": money(now - was),
            "up": now > was,
        })
    rows.sort(key=lambda r: r["current"], reverse=True)
    return {"month": month, "previous_month": prev, "categories": rows}


# ---------------------------------------------------------------------------
# loans: running balance with partial repayments
# ---------------------------------------------------------------------------

def loan_balance(loan):
    """loan: {'amount', 'kind', 'repayments': [{'amount','date'}...], 'settled'}
    Returns running balance + a history ledger (principal then each repayment).
    For 'given' loans the balance is what's still owed TO me; for 'taken' it's
    what I still owe."""
    principal = D(loan.get("amount"))
    reps = loan.get("repayments") or []
    paid = ZERO
    ledger = [{"type": "principal", "amount": money(principal),
               "date": loan.get("date"), "balance": money(principal)}]
    running = principal
    for r in sorted(reps, key=lambda x: str(x.get("date") or "")):
        amt = D(r.get("amount"))
        paid += amt
        running = running - amt
        ledger.append({"type": "repayment", "amount": money(amt),
                       "date": r.get("date"), "balance": money(max(ZERO, running))})
    balance = max(ZERO, principal - paid)
    fully = bool(loan.get("settled")) or balance <= 0
    # For reporting, overpayment is meaningless: don't show paid>principal or
    # a progress bar above 100%. (The balance already floors at 0 above.) The
    # raw sum of repayments isn't lost — it's reconstructable from the ledger.
    reported_paid = min(paid, principal) if principal > 0 else paid
    if principal > 0:
        pct = int((reported_paid / principal * 100).to_integral_value(ROUND_HALF_UP))
        pct = min(100, pct)
    else:
        pct = 100
    return {
        "principal": money(principal),
        "paid": money(reported_paid),
        "balance": money(balance),
        "settled": fully,
        "progress_pct": pct,
        "ledger": ledger,
    }


def apply_repayment(loan, amount, on_date=None):
    """Return a NEW repayment entry to append (pure — caller persists)."""
    return {"amount": money(amount), "date": (on_date or date.today()).isoformat()
            if not isinstance(on_date, str) else on_date}


# ---------------------------------------------------------------------------
# recurring transaction generation
# ---------------------------------------------------------------------------

def generate_recurring(rule, since, until):
    """Expand a recurring rule into concrete txn dates in [since, until].

    rule: {'freq': 'daily'|'weekly'|'monthly', 'interval': 1, 'start': date,
           'weekday': 0-6 (weekly, optional), 'day_of_month': 1-31 (monthly)}
    Returns a list of ISO dates. Deterministic; no DB.
    """
    since = _as_date(since)
    until = _as_date(until)
    start = _as_date(rule.get("start") or since)
    interval = max(1, int(rule.get("interval") or 1))
    freq = rule.get("freq", "monthly")
    out = []
    if freq == "daily":
        d = start
        while d <= until:
            if d >= since:
                out.append(d.isoformat())
            d += timedelta(days=interval)
    elif freq == "weekly":
        d = start
        wd = rule.get("weekday")
        if wd is not None:
            # shift start to the first matching weekday on/after start
            d += timedelta(days=(int(wd) - d.weekday()) % 7)
        while d <= until:
            if d >= since:
                out.append(d.isoformat())
            d += timedelta(weeks=interval)
    elif freq == "monthly":
        dom = int(rule.get("day_of_month") or start.day)
        anchor = date(start.year, start.month, 1)
        i = 0
        while True:
            m = add_months(anchor, i * interval)
            last = [31, 29 if m.year % 4 == 0 and (m.year % 100 or m.year % 400 == 0)
                    else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m.month - 1]
            d = date(m.year, m.month, min(dom, last))
            if d > until:
                break
            if d >= since and d >= start:
                out.append(d.isoformat())
            i += 1
            if i > 1000:
                break
    return out


def next_recurring_date(rule, after=None):
    """The next single occurrence strictly after `after` (today by default)."""
    after = _as_date(after or date.today())
    horizon = add_months(after, 13)  # look up to ~1 year ahead
    for iso in generate_recurring(rule, after + timedelta(days=1), horizon):
        return iso
    return None


# ---------------------------------------------------------------------------
# split expenses
# ---------------------------------------------------------------------------

def split_expense(total, parts, mode="equal"):
    """Split `total` across `parts`.

    mode='equal': parts is an int (number of people) OR a list of names.
    mode='shares': parts is a list of {'name', 'weight'} — proportional.
    mode='amount': parts is a list of {'name', 'amount'} — fixed, remainder to last.
    mode='percent': parts is a list of {'name', 'percent'} — % of total.

    Returns list of {'name', 'amount'} that always sums EXACTLY to total
    (last part absorbs rounding residue so no paisa is lost).
    """
    total = money(total)
    rows = []
    if mode == "equal":
        names = ([f"#{i + 1}" for i in range(parts)] if isinstance(parts, int)
                 else list(parts))
        n = len(names)
        if n == 0:
            return []
        each = money(total / n)
        rows = [{"name": nm, "amount": each} for nm in names]
    elif mode == "shares":
        tw = sum(D(p.get("weight", 1)) for p in parts) or Decimal("1")
        rows = [{"name": p.get("name"), "amount": money(total * D(p.get("weight", 1)) / tw)}
                for p in parts]
    elif mode == "percent":
        rows = [{"name": p.get("name"), "amount": money(total * D(p.get("percent")) / 100)}
                for p in parts]
    elif mode == "amount":
        rows = [{"name": p.get("name"), "amount": money(p.get("amount"))} for p in parts]
    # fix rounding residue on the last row. For 'amount'/'percent' the explicit
    # allocations can exceed `total`, which would otherwise push the last row
    # negative when it absorbs the (negative) residue. Guard against that: the
    # split would be nonsensical, so reject it with a clear error rather than
    # silently handing someone a negative share. (UI currently only uses
    # 'equal'; this keeps 'amount'/'percent' safe for when they're exposed.)
    if rows:
        if mode in ("amount", "percent"):
            allocated = sum(r["amount"] for r in rows)
            if allocated > total:
                raise ValueError(
                    "split overshoot: allocated %s exceeds total %s (mode=%s)"
                    % (allocated, total, mode))
        residue = total - sum(r["amount"] for r in rows)
        rows[-1]["amount"] = money(rows[-1]["amount"] + residue)
    return rows


# ---------------------------------------------------------------------------
# monthly report (feeds PDF / Excel export in the app)
# ---------------------------------------------------------------------------

def monthly_report(txns, month, budgets=None, opening_net_worth=None):
    """Assemble everything the export needs for one month.
    budgets: list of {'category','monthly_limit'}."""
    totals = monthly_totals(txns).get(month, {"income": ZERO, "expense": ZERO, "net": ZERO})
    by_cat = category_spend(txns, month)
    trends = category_trends(txns, month)
    month_txns = [t for t in txns if month_key(t.get("date")) == month]
    month_expenses = [t for t in month_txns if t.get("kind") == "expense"]
    biggest = max(month_expenses, key=lambda t: D(t.get("amount")), default=None) \
        if month_expenses else None
    budget_lines = []
    for b in (budgets or []):
        spent = by_cat.get(b.get("category"), ZERO)
        state, pct, remaining = budget_status(b.get("monthly_limit"), spent)
        budget_lines.append({"category": b.get("category"),
                             "limit": money(b.get("monthly_limit")),
                             "spent": money(spent), "remaining": remaining,
                             "state": state, "pct": pct})
    return {
        "month": month,
        "income": totals["income"],
        "expense": totals["expense"],
        "net": totals["net"],
        "savings_rate": int((totals["net"] / totals["income"] * 100)
                            .to_integral_value(ROUND_HALF_UP))
        if totals["income"] > 0 else 0,
        "by_category": [{"category": k, "amount": v}
                        for k, v in sorted(by_cat.items(), key=lambda kv: kv[1], reverse=True)],
        "category_trends": trends["categories"],
        "budgets": budget_lines,
        "txn_count": len(month_txns),
        "biggest_expense": ({"category": biggest.get("category"),
                             "amount": money(biggest.get("amount")),
                             "date": biggest.get("date")}
                            if biggest else None),
    }
