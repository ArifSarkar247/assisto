"""
Weighted sales forecast — HONEST and data-grounded (spec §Reports/dashboard).

The forecast is NEVER a fabricated percentage. It is computed directly from the
org's own open deals:

    weighted_pipeline = Σ (deal.value × deal.probability / 100)  over OPEN deals

We also expose a "commit" (deals closing this period with probability ≥ 70) and
a "best case" (all open deals at full value). If there are no open deals, we
return a clear "not enough data" message in both languages — we do not invent a
number. The METHOD is always returned alongside the number so it is auditable.
"""
from datetime import date
from decimal import Decimal

NOT_ENOUGH = {
    "bn": "পর্যাপ্ত ডাটা নেই — পূর্বাভাসের জন্য অন্তত একটি চলমান ডিল দরকার।",
    "en": "Not enough data — a forecast needs at least one open deal.",
}


def _month_bounds(d=None):
    d = d or date.today()
    start = d.replace(day=1)
    if d.month == 12:
        end = d.replace(year=d.year + 1, month=1, day=1)
    else:
        end = d.replace(month=d.month + 1, day=1)
    return start, end


def weighted_forecast(deals_qs, period_end=None):
    """`deals_qs` is a Deal queryset already scoped to one org.

    Returns a dict with weighted pipeline, commit, best-case, counts and the
    method string. All money is Decimal → float for JSON at the edge only.
    """
    open_deals = [d for d in deals_qs if d.state == "open"]
    n = len(open_deals)
    if n == 0:
        return {
            "ok": True,
            "has_data": False,
            "message_bn": NOT_ENOUGH["bn"],
            "message_en": NOT_ENOUGH["en"],
            "method": "Σ(value × probability / 100) over open deals",
            "weighted": 0.0, "best_case": 0.0, "commit": 0.0,
            "open_count": 0, "commit_count": 0,
        }

    weighted = Decimal(0)
    best = Decimal(0)
    commit = Decimal(0)
    commit_n = 0
    _, default_end = _month_bounds()
    period_end = period_end or default_end

    for d in open_deals:
        val = d.value or Decimal(0)
        prob = Decimal(d.probability or 0)
        weighted += (val * prob) / Decimal(100)
        best += val
        # "Commit": high-probability deals expected to close by period_end.
        closes_in_period = (d.expected_close is not None
                            and d.expected_close < period_end)
        if prob >= 70 and closes_in_period:
            commit += val
            commit_n += 1

    return {
        "ok": True,
        "has_data": True,
        "method": "Σ(value × probability / 100) over open deals",
        "weighted": float(round(weighted, 2)),
        "best_case": float(round(best, 2)),
        "commit": float(round(commit, 2)),
        "open_count": n,
        "commit_count": commit_n,
        "message_bn": (f"ওজনযুক্ত পাইপলাইন ৳{weighted:,.0f} "
                       f"({n}টি চলমান ডিল থেকে, সম্ভাব্যতা-ভিত্তিক)।"),
        "message_en": (f"Weighted pipeline ৳{weighted:,.0f} "
                       f"from {n} open deals (probability-weighted)."),
    }


def target_attainment(won_total, target_amount):
    """% of a BDT target attained from real won value. No target → None (we do
    not invent a goal)."""
    if not target_amount:
        return None
    return round(float(won_total) / float(target_amount) * 100.0, 1)
