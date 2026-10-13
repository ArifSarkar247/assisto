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
