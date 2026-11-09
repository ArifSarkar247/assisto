"""aimoney (owner final order 10 Nov 03:45, part G): FREE AI money rules.
PURE: no Django, no DB, no clock.

  * ads per AI answer is DYNAMIC:
        N = ceil(real cost of one ad-funded Normal answer x 1.2
                 / real income of one rewarded ad),  minimum 2
    recomputed once a day (core/ad_money_service.py, inside minute_jobs) from
    our own AI cost log (AIUsage) and the AdMob paid-event report
    (AdPlacementStat). Until real AdMob data exists one rewarded ad is
    counted at ৳0.40 (owner).
  * N is ALSO never below the break-even of the LONGEST answer an ad can buy
    (the ad answer at its hard caps + one free Continue of a cut answer), so
    even a single worst-case answer never loses money — the CI test
    (core/tests_aimoney.py) fails the build if that can ever happen at the
    configured worst case (WORST_AD_INCOME_BDT, the lowest per-ad income).
  * ad-funded answers run at the Normal level with a SHORTER max output
    (AD_OUT_CAP) and prompt caching (the system prompt carries
    cache_control: ephemeral — core/ai.py anthropic_request).
"""
import math

DEFAULT_AD_INCOME_BDT = 0.40     # owner: until real AdMob data exists
MIN_ADS = 2                      # owner: never fewer than 2 ads an answer
SAFETY = 1.2                     # owner: real cost x 1.2
MAX_ADS = 50                     # bound of the stored number (honest, shown to the user)
AD_OUT_CAP = 900                 # output tokens of one ad-funded answer (Normal: 1500)
CONTINUE_CALLS = 1               # worst case: one free Continue after a cut answer
# the configured worst case of the CI no-loss check: the lowest income of one
# rewarded ad we plan for (৳0.10 = eCPM ৳100, about $0.80 — far under BD
# rewarded rates). Below it N simply rises (shown honestly to the user).
WORST_AD_INCOME_BDT = 0.10
MIN_COST_SAMPLES = 30            # fewer ad-funded answers -> use all Normal answers
MIN_AD_EVENTS = 50               # fewer paid rewarded events -> ৳0.40 default
WINDOW_DAYS = 7


def paisa_per_ad(n, answer_credits=1):
    """Paisa of credit one verified rewarded ad adds to the ad wallet when
    N ads buy one answer of `answer_credits` credits. Rounded UP so N ads
    always make the whole answer (3 ads -> 34 paisa each, never 99 total)."""
    n = max(1, int(n or 1))
    return int(math.ceil(100.0 * max(1, int(answer_credits or 1)) / n))


def ads_really_needed(n, answer_credits=1):
    """Ads a user really watches per answer after the paisa rounding (<= n)."""
    return 100.0 * max(1, int(answer_credits or 1)) / paisa_per_ad(n, answer_credits)


def ads_per_answer(real_cost_bdt, income_bdt, worst_cost_bdt=0.0, answer_credits=1):
    """THE formula. real_cost_bdt None (no data yet) -> the worst case
    stands in for the real cost; worst_cost_bdt is the break-even floor."""
    inc = float(income_bdt or 0)
    if inc <= 0:
        inc = DEFAULT_AD_INCOME_BDT
    worst = max(0.0, float(worst_cost_bdt or 0))
    real = worst if real_cost_bdt is None else max(0.0, float(real_cost_bdt))
    n = max(MIN_ADS, int(math.ceil(round(real * SAFETY / inc, 6))),
            int(math.ceil(round(worst / inc, 6))))
    # the paisa rounding may let N ads count as slightly fewer (3 ads -> 34
    # paisa each): bump only if that could break even the longest answer
    while n < MAX_ADS and ads_really_needed(n, answer_credits) * inc + 1e-9 < worst:
        n += 1
    return min(MAX_ADS, n)


def answer_cost_usd(in_cap, out_cap, price):
    """Worst-case USD of one call at its hard caps (input counted at the
    dearer of normal input and a cache write)."""
    p = price or {}
    in_price = max(float(p.get("in", 0)), float(p.get("cache_write", 0)))
    return (int(in_cap) * in_price + int(out_cap) * float(p.get("out", 0))) / 1e6


def ad_row(normal_row, ad_out_cap=AD_OUT_CAP):
    """The level row an ad-funded answer runs on: Normal with the shorter
    output (never longer than Normal's own) and no fallback long budget."""
    row = dict(normal_row)
    row["out_cap"] = max(100, min(int(normal_row.get("out_cap") or 0) or ad_out_cap,
                                  int(ad_out_cap)))
    row["fallback_out_cap"] = 0
    return row


def worst_answer_bdt(levels, price_of, usd_bdt, ad_out_cap=AD_OUT_CAP):
    """৳ of the longest answer an ad can buy: the ad answer (Normal row,
    ad cap) + CONTINUE_CALLS free Continues of it (a cut ad answer's
    Continue runs at Normal — core/views_chat.py — with Normal's full
    output). `price_of(model)` -> price row."""
    r = levels["normal"]
    n = ad_row(r, ad_out_cap)
    cost = answer_cost_usd(n["in_cap"], n["out_cap"], price_of(n["model"]))
    out = max(int(r.get("out_cap") or 0), int(r.get("fallback_out_cap") or 0))
    cont = answer_cost_usd(r["in_cap"], out, price_of(r["model"]))
    return (cost + CONTINUE_CALLS * cont) * float(usd_bdt)


def profit_pct(n, income_bdt, cost_bdt, answer_credits=1):
    """% of the ad income left after the answer's cost."""
    got = ads_really_needed(n, answer_credits) * float(income_bdt)
    if got <= 0:
        return -100.0
    return round(100.0 * (got - float(cost_bdt)) / got, 1)


def income_per_ad_bdt(rows, usd_bdt):
    """(৳ per rewarded ad, paid events, source) from AdPlacementStat-like
    rows [{fmt, currency, paid_events, revenue_micros}]. BDT and USD only;
    fewer than MIN_AD_EVENTS paid events -> the ৳0.40 default."""
    n, bdt = 0, 0.0
    for r in rows or []:
        if r.get("fmt") != "rewarded":
            continue
        cur = str(r.get("currency") or "").upper()
        ev = int(r.get("paid_events") or 0)
        val = float(r.get("revenue_micros") or 0) / 1e6
        if cur == "BDT":
            bdt += val
        elif cur == "USD":
            bdt += val * float(usd_bdt)
        else:
            continue
        n += ev
    if n < MIN_AD_EVENTS or bdt <= 0:
        return DEFAULT_AD_INCOME_BDT, n, "default"
    return round(bdt / n, 4), n, "admob"


def money_rows(days, ad_income, free_ai_cost, level_cost, credits_sold):
    """Owner Admin daily money table. Inputs are {date: ...} maps:
      ad_income      {date: {fmt: ৳}}           (AdMob paid events / estimate)
      free_ai_cost   {date: ৳}                  (AI cost of free users)
      level_cost     {date: {level: (answers, ৳)}}
      credits_sold   {date: {"packs": n, "plans": n}}
    -> newest-first rows {date, ad_total, ad_by_fmt, free_ai_bdt, free_pnl,
       per_answer {level: ৳/answer}, packs, plans}."""
    out = []
    for d in sorted(days, reverse=True):
        ads = {k: round(float(v), 2) for k, v in (ad_income.get(d) or {}).items()}
        tot = round(sum(ads.values()), 2)
        ai = round(float(free_ai_cost.get(d) or 0), 2)
        per = {}
        for lid, (cnt, bdt) in (level_cost.get(d) or {}).items():
            per[lid] = round(float(bdt) / cnt, 3) if cnt else 0.0
        cs = credits_sold.get(d) or {}
        out.append({"date": d, "ad_total": tot, "ad_by_fmt": ads, "free_ai_bdt": ai,
                    "free_pnl": round(tot - ai, 2), "per_answer": per,
                    "packs": int(cs.get("packs") or 0), "plans": int(cs.get("plans") or 0)})
    return out
