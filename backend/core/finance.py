"""
Finance toolkit (feature 26): net worth, zakat, EMI, investment projection.
Pure compute over the user's OWN data + inputs — no AI key, no invented numbers.
Rates/prices that the app can't know (gold/silver price) are owner inputs; we
never guess them.
"""
from decimal import Decimal, InvalidOperation


def _d(v, default="0"):
    try:
        return Decimal(str(v if v not in (None, "") else default))
    except (InvalidOperation, ValueError):
        return Decimal(default)


def net_worth(user):
    """Assets (account balances + savings + investments) minus liabilities."""
    from .models import Account, Transaction, SavingsGoal, Loan
    assets = Decimal("0")
    for acc in Account.objects.filter(user=user):
        bal = _d(getattr(acc, "opening_balance", 0))
        agg = Transaction.objects.filter(user=user, account=acc)
        for t in agg:
            bal += _d(t.amount) if t.kind == "income" else -_d(t.amount)
        assets += bal
    saved = sum((_d(g.saved) for g in SavingsGoal.objects.filter(user=user)), Decimal("0"))
    liabilities = sum((_d(l.amount) for l in Loan.objects.filter(user=user, kind="taken")),
                      Decimal("0"))
    receivable = sum((_d(l.amount) for l in Loan.objects.filter(user=user, kind="given")),
                     Decimal("0"))
    nw = assets + saved + receivable - liabilities
    return {"assets": str(assets + saved), "receivable": str(receivable),
            "liabilities": str(liabilities), "net_worth": str(nw)}


def zakat(cash=0, gold_value=0, silver_value=0, investments=0, debts=0,
          nisab=0):
    """Zakat = 2.5% of zakatable wealth above nisab. Gold/silver VALUE and the
    nisab threshold are owner/user inputs (we never guess bullion prices)."""
    wealth = _d(cash) + _d(gold_value) + _d(silver_value) + _d(investments) - _d(debts)
    if wealth <= 0:
        return {"zakatable": "0", "zakat_due": "0", "above_nisab": False}
    above = wealth >= _d(nisab) if _d(nisab) > 0 else True
    due = (wealth * Decimal("0.025")).quantize(Decimal("0.01")) if above else Decimal("0")
    return {"zakatable": str(wealth), "zakat_due": str(due), "above_nisab": above}


def emi(principal, annual_rate_pct, months):
    """Standard reducing-balance EMI."""
    p = _d(principal)
    n = int(_d(months, "1"))
    r = _d(annual_rate_pct) / Decimal("1200")  # monthly rate fraction
    if n <= 0:
        return {"emi": "0", "total": "0", "interest": "0"}
    if r == 0:
        m = (p / n)
    else:
        f = (1 + r) ** n
        m = p * r * f / (f - 1)
    m = m.quantize(Decimal("0.01"))
    total = (m * n).quantize(Decimal("0.01"))
    return {"emi": str(m), "total": str(total), "interest": str(total - p),
            "months": n}


def invest_projection(principal, annual_rate_pct, years, monthly_add=0):
    """Compound growth with optional monthly contribution. Projection, clearly
    labelled as an estimate — not a guarantee."""
    p = _d(principal)
    r = _d(annual_rate_pct) / Decimal("100")
    yrs = int(_d(years, "1"))
    add = _d(monthly_add)
    bal = p
    mr = r / Decimal("12")
    for _ in range(yrs * 12):
        bal = bal * (1 + mr) + add
    return {"future_value": str(bal.quantize(Decimal("0.01"))),
            "invested": str((p + add * yrs * 12).quantize(Decimal("0.01"))),
            "years": yrs, "estimate": True}


# ---------------------------------------------------------------------------
# ADVANCED calculators (feature 26+). Pure, Decimal-only, no DB, no AI.
# These mirror the client-side Dart compute so the numbers are identical and
# can also back an AI tool / voice flow later. Every money result is quantized
# to paisa (2 dp) and returned as a string — no float drift.
# ---------------------------------------------------------------------------

_CENT = Decimal("0.01")


def _q(x):
    return str(x.quantize(_CENT))


def emi_schedule(principal, annual_rate_pct, months, mode="reducing"):
    """EMI with a full amortization schedule.

    mode="reducing" (declining balance, bank standard) or "flat" (interest on
    full principal every month — microfinance / some auto loans in BD).
    Returns per-month principal/interest/balance split and totals.
    """
    p = _d(principal)
    n = int(_d(months, "1"))
    annual = _d(annual_rate_pct)
    if n <= 0 or p <= 0:
        return {"emi": "0", "total": "0", "interest": "0", "months": max(n, 0),
                "mode": mode, "schedule": []}
    r = annual / Decimal("1200")  # monthly fraction
    if mode == "flat":
        total_interest = (p * (annual / Decimal("100")) * (Decimal(n) / Decimal("12")))
        m = ((p + total_interest) / n).quantize(_CENT)
        per_principal = (p / n)
        per_interest = (total_interest / n)
    else:
        if r == 0:
            m = (p / n).quantize(_CENT)
        else:
            f = (1 + r) ** n
            m = (p * r * f / (f - 1)).quantize(_CENT)
    schedule = []
    bal = p
    total_pay = Decimal("0")
    for i in range(1, n + 1):
        if mode == "flat":
            interest_i = per_interest.quantize(_CENT)
            principal_i = per_principal.quantize(_CENT)
        else:
            interest_i = (bal * r).quantize(_CENT)
            principal_i = (m - interest_i)
        if i == n:  # absorb rounding into the final payment
            principal_i = bal
            pay_i = (principal_i + interest_i).quantize(_CENT)
        else:
            pay_i = m
        bal = (bal - principal_i)
        total_pay += pay_i
        schedule.append({
            "month": i,
            "payment": _q(pay_i),
            "principal": _q(principal_i),
            "interest": _q(interest_i),
            "balance": _q(bal if bal > 0 else Decimal("0")),
        })
    total = total_pay.quantize(_CENT)
    return {"emi": _q(m), "total": _q(total), "interest": _q(total - p),
            "months": n, "mode": mode, "schedule": schedule}


def rate_compare(principal, months, rate_a_pct, rate_b_pct, mode="reducing"):
    """Compare two profit/interest rates for the same loan — which installment
    is cheaper and by how much over the life of the loan."""
    a = emi_schedule(principal, rate_a_pct, months, mode)
    b = emi_schedule(principal, rate_b_pct, months, mode)
    diff = (Decimal(b["total"]) - Decimal(a["total"]))
    return {"a": {"emi": a["emi"], "total": a["total"], "interest": a["interest"]},
            "b": {"emi": b["emi"], "total": b["total"], "interest": b["interest"]},
            "cheaper": "a" if diff > 0 else ("b" if diff < 0 else "equal"),
            "savings": _q(abs(diff))}


def dps_projection(monthly, annual_rate_pct, months):
    """DPS / recurring-deposit style savings. Deposit at the start of each month,
    monthly compounding (how most BD bank DPS products quote)."""
    dep = _d(monthly)
    n = int(_d(months, "1"))
    mr = _d(annual_rate_pct) / Decimal("1200")
    bal = Decimal("0")
    for _ in range(max(n, 0)):
        bal = (bal + dep) * (1 + mr)
    invested = (dep * n)
    maturity = bal.quantize(_CENT)
    return {"maturity": _q(maturity), "invested": _q(invested),
            "profit": _q(maturity - invested), "months": n, "estimate": True}


def goal_savings(target, current, annual_rate_pct, months):
    """How much to set aside each month to hit a savings goal by a deadline,
    given an expected profit rate. Solves the annuity for the payment."""
    tgt = _d(target)
    cur = _d(current)
    n = int(_d(months, "1"))
    mr = _d(annual_rate_pct) / Decimal("1200")
    if n <= 0:
        return {"monthly": "0", "months": 0, "shortfall": _q(tgt - cur)}
    # future value of current savings
    fv_cur = cur * ((1 + mr) ** n)
    need = tgt - fv_cur
    if need <= 0:
        return {"monthly": "0", "months": n, "reached_without_saving": True}
    if mr == 0:
        pay = need / n
    else:
        factor = (((1 + mr) ** n) - 1) / mr  # ordinary annuity FV factor
        pay = need / factor
    return {"monthly": _q(pay), "months": n,
            "projected": _q(tgt), "estimate": True}


def budget_503020(monthly_income):
    """50-30-20 rule: needs / wants / savings split of take-home income."""
    inc = _d(monthly_income)
    needs = (inc * Decimal("0.50")).quantize(_CENT)
    wants = (inc * Decimal("0.30")).quantize(_CENT)
    savings = (inc - needs - wants).quantize(_CENT)  # remainder → no drift
    return {"income": _q(inc), "needs": _q(needs), "wants": _q(wants),
            "savings": _q(savings)}


def affordability(monthly_income, monthly_expenses, price,
                  down_payment=0, months=12, annual_rate_pct=0, mode="reducing"):
    """Can I afford this? Compares free monthly cashflow against the EMI for a
    financed purchase (or lump-sum share if months<=1)."""
    free = _d(monthly_income) - _d(monthly_expenses)
    price_d = _d(price)
    down = _d(down_payment)
    financed = price_d - down
    n = int(_d(months, "1"))
    if financed <= 0:
        emi_amt = Decimal("0")
    elif n <= 1:
        emi_amt = financed
    else:
        sched = emi_schedule(financed, annual_rate_pct, n, mode)
        emi_amt = Decimal(sched["emi"])
    leftover = (free - emi_amt)
    ratio = (emi_amt / free * 100) if free > 0 else Decimal("999")
    return {"free_cashflow": _q(free), "emi": _q(emi_amt),
            "leftover": _q(leftover), "burden_pct": str(ratio.quantize(_CENT)),
            "affordable": bool(leftover >= 0 and free > 0)}


def break_even(fixed_cost, unit_price, unit_cost):
    """Units to sell before profit starts, given fixed cost and per-unit margin."""
    fixed = _d(fixed_cost)
    margin = _d(unit_price) - _d(unit_cost)
    if margin <= 0:
        return {"units": None, "revenue": "0", "impossible": True,
                "margin": _q(margin)}
    import math
    units = math.ceil(float(fixed / margin))
    revenue = (_d(unit_price) * units)
    return {"units": units, "revenue": _q(revenue), "margin": _q(margin),
            "impossible": False}


def simple_roi(invested, returned, months=0):
    """Simple ROI % and (optionally) annualised return."""
    inv = _d(invested)
    ret = _d(returned)
    if inv <= 0:
        return {"roi_pct": "0", "profit": "0"}
    profit = ret - inv
    roi = (profit / inv * 100)
    out = {"roi_pct": str(roi.quantize(_CENT)), "profit": _q(profit)}
    n = int(_d(months, "0"))
    if n > 0:
        out["annualised_pct"] = str((roi * 12 / n).quantize(_CENT))
    return out


def convert_amount(amount, rate):
    """Currency / unit conversion: amount * rate. Rate is a user input (we never
    fetch or guess FX rates)."""
    return {"result": _q(_d(amount) * _d(rate))}


def zakat_full(cash=0, bank=0, gold_value=0, silver_value=0, investments=0,
               business_goods=0, money_lent=0, debts=0, nisab=0):
    """Expanded zakat: more wealth buckets, still 2.5% above nisab. All bullion
    prices / nisab are owner inputs."""
    wealth = (_d(cash) + _d(bank) + _d(gold_value) + _d(silver_value)
              + _d(investments) + _d(business_goods) + _d(money_lent) - _d(debts))
    if wealth <= 0:
        return {"zakatable": "0", "zakat_due": "0", "above_nisab": False}
    above = wealth >= _d(nisab) if _d(nisab) > 0 else True
    due = (wealth * Decimal("0.025")).quantize(_CENT) if above else Decimal("0")
    return {"zakatable": _q(wealth), "zakat_due": _q(due), "above_nisab": above}
