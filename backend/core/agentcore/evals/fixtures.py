"""Deterministic seed data for the money topic. Dates are relative to TODAY
(day 1 of this month and of last month) so CI never needs a frozen clock.
The EXPECTED numbers are written here by hand from the seed constants — the
grader never trusts a tool to tell it what the right answer is."""
from datetime import date
from decimal import Decimal

from django.utils import timezone

PHONE_IN_NOTE = "01711234567"

THIS_MONTH = {"income": 50000, "expense": {"food": 8000, "rent": 15000, "transport": 2340,
                                           "bills": 1200}}
LAST_MONTH = {"income": 48000, "expense": {"food": 9500, "rent": 15000}}
BUDGETS = {"food": 7000, "transport": 2500, "rent": 20000}      # food over, transport near
LOANS = [("given", "Rahim", 5000, 1000), ("given", "Karim", 2500, 0), ("taken", "Sumon", 3000, 0)]

METER = {"name": "Bari meter", "balance": 500, "daily_use": 50}    # -> ~10 days left
EXPECT = {
    "expense_this": 26540, "income_this": 50000, "net_this": 23460,
    "expense_last": 24500, "top_this": "rent",
    "budget_over": "food", "budget_near": "transport",
    "loans_given": 6500, "loans_taken": 3000,
    "meter_balance": 500, "meter_days": 10,
}


def _months():
    t = timezone.localdate()
    this1 = date(t.year, t.month, 1)
    last1 = date(t.year - (t.month == 1), 12 if t.month == 1 else t.month - 1, 1)
    return this1, last1


def month_keys():
    a, b = _months()
    return a.strftime("%Y-%m"), b.strftime("%Y-%m")


def seed_money(user):
    from ...models import Account, Budget, Loan, Note, Transaction
    this1, last1 = _months()
    acc = Account.objects.create(user=user, name="Cash", acc_type="cash")
    rows = []
    for d, m in ((this1, THIS_MONTH), (last1, LAST_MONTH)):
        rows.append(Transaction(user=user, account=acc, kind="income", amount=Decimal(m["income"]),
                                category="salary", date=d))
        for cat, amt in m["expense"].items():
            if cat == "food" and d == this1:          # two rows -> sums are really summed
                rows.append(Transaction(user=user, account=acc, kind="expense", amount=Decimal(5000),
                                        category=cat, date=d))
                rows.append(Transaction(user=user, account=acc, kind="expense", amount=Decimal(amt - 5000),
                                        category=cat, date=d))
            else:
                rows.append(Transaction(user=user, account=acc, kind="expense", amount=Decimal(amt),
                                        category=cat, date=d))
    Transaction.objects.bulk_create(rows)
    for cat, lim in BUDGETS.items():
        Budget.objects.create(user=user, category=cat, monthly_limit=Decimal(lim))
    for kind, person, amt, repaid in LOANS:
        Loan.objects.create(user=user, kind=kind, person=person, amount=Decimal(amt),
                            repayments=[{"amount": repaid, "date": str(this1)}] if repaid else [])
    Note.objects.create(user=user, title="bKash", body="Rahim bKash %s" % PHONE_IN_NOTE)
    from ...models import PaCollectionItem          # WP-TOOLS-A: prepaid meter estimate
    PaCollectionItem.objects.create(user=user, collection="meter/meters",
                                    data={"name": METER["name"], "utility": "desco",
                                          "balance": str(METER["balance"]),
                                          "balance_date": timezone.localdate().isoformat(),
                                          "daily_use": str(METER["daily_use"])})
