"""plansprep (owner 9 Nov 10:20): Owner Admin -> Plans. The ONE page for plan
numbers: every plan / pack / AI level with price, credits (from the formula
while pricing_v2 is on), Play product, what it includes; the 40 % worst-case
check; what the pricing_v2 switch changes; the change history (PricingConfig
audit); and a live P&L per plan (last 30 days, read-only).

Edits (plan price / yearly price / ads / family; the pricing_v2 switch) go
through pricing_apply — the same validate + audit path as Owner Admin ->
Pricing — AND OwnerAudit, each with a typed reason. Credits are never typed
while pricing_v2 is on (the formula sets them)."""
from datetime import timedelta

from django.utils import timezone
from django.views.decorators.http import require_http_methods

from . import security as S
from .base import done, owner_view, page, to_int

HISTORY_PATHS = ("plans", "topup_packs", "pricing_v2", "billing.unlock", "billing.pack",
                 "probashi_plan.pool", "probashi_plan.annual", "ai_levels.levels",
                 "ai_levels.welcome", "ai_levels.ad", "ai_levels.web", "action_costs")

L = {
    "bn": {"title": "প্ল্যান ও দাম", "intro": "সব প্ল্যান, প্যাক ও AI লেভেলের সংখ্যা এক জায়গায় — অ্যাপ, ওয়েবসাইট ও রসিদ এখান থেকেই পড়ে। pricing_v2 চালু থাকলে ক্রেডিট সূত্র থেকে আসে (হাতে লেখা নয়): ১ ক্রেডিট ≥ ৳২.৮০, প্রতিটি প্ল্যান ও প্যাকে সবচেয়ে খারাপ অবস্থায়ও ≥৪০% লাভ।",
           "switch": "pricing_v2 সুইচ", "on": "চালু", "off": "বন্ধ", "turn_on": "চালু করুন",
           "turn_off": "বন্ধ করুন (আগের হিসাবে ফেরত)", "reason": "কারণ (লিখতেই হবে)",
           "plans": "প্ল্যান", "plan": "প্ল্যান", "price": "দাম ৳", "year": "বার্ষিক ৳",
           "credits": "ক্রেডিট/মাস", "ycredits": "বার্ষিকে ক্রেডিট/মাস", "product": "Play পণ্য",
           "includes": "কী থাকে", "packs": "ক্রেডিট প্যাক", "sale": "বিক্রি", "valid": "মেয়াদ (মাস)",
           "levels": "AI উত্তরের লেভেল", "model": "মডেল", "worst": "সবচেয়ে খারাপ খরচ ৳",
           "check": "৪০% লাভের হিসাব (সবচেয়ে খারাপ অবস্থা)", "pct": "লাভ %", "fail": "৪০%-এর নিচে",
           "flip": "pricing_v2 চালু হলে যা বদলাবে", "nochange": "কিছু বদলাবে না — আগেই চালু।",
           "history": "পরিবর্তনের ইতিহাস", "when": "কখন", "who": "কে", "what": "কী বদলেছে",
           "pnl": "প্ল্যান-প্রতি লাভ-ক্ষতি (গত ৩০ দিন)", "users": "চালু ব্যবহারকারী",
           "gross": "আয় ৳", "net": "হাতে আসে ৳", "ai": "AI খরচ ৳", "profit": "লাভ ৳",
           "margin": "লাভ %", "edit": "প্ল্যান বদলান", "save": "সংরক্ষণ", "ads": "বিজ্ঞাপন",
           "family": "পরিবার", "none": "এখনো কিছু নেই।", "bad": "ভুল সংখ্যা",
           "credits_ro": "pricing_v2 চালু: ক্রেডিট সূত্র থেকে, এখানে লেখা যায় না।",
           "pnl_note": "আয় = Play/গেটওয়ের আসল অর্ডার (টেস্ট বাদ, রিফান্ড বাদ); AI খরচ = ব্যবহারকারীর এখনকার প্ল্যান ধরে।"},
    "en": {"title": "Plans & prices", "intro": "Every plan, pack and AI level number in one place — the app, the website and receipts read from here. With pricing_v2 on, credits come from the formula (never typed): 1 credit >= ৳2.80, every plan and pack keeps >= 40 % profit in the worst case.",
           "switch": "pricing_v2 switch", "on": "ON", "off": "OFF", "turn_on": "Turn on",
           "turn_off": "Turn off (back to the old numbers)", "reason": "Reason (required)",
           "plans": "Plans", "plan": "Plan", "price": "Price ৳", "year": "Yearly ৳",
           "credits": "Credits/month", "ycredits": "Yearly: credits/month", "product": "Play product",
           "includes": "Includes", "packs": "Credit packs", "sale": "On sale", "valid": "Valid (months)",
           "levels": "AI answer levels", "model": "Model", "worst": "Worst-case cost ৳",
           "check": "40 % profit check (worst case)", "pct": "Profit %", "fail": "below 40 %",
           "flip": "What turning pricing_v2 on changes", "nochange": "Nothing — already on.",
           "history": "Change history", "when": "When", "who": "Who", "what": "What changed",
           "pnl": "Profit & loss per plan (last 30 days)", "users": "Active users",
           "gross": "Revenue ৳", "net": "Net ৳", "ai": "AI cost ৳", "profit": "Profit ৳",
           "margin": "Margin %", "edit": "Edit plans", "save": "Save", "ads": "Ads",
           "family": "Family", "none": "Nothing yet.", "bad": "Invalid number",
           "credits_ro": "pricing_v2 is on: credits come from the formula and cannot be typed here.",
           "pnl_note": "Revenue = real Play / gateway orders (tests and refunds removed); AI cost by each user's current plan."},
}


def _book(c, lang):
    from core.logic import plan_book as BOOK, pricing as P
    from core.payments import catalog
    v2 = BOOK.is_on(c)
    rows = []
    for pid, p in c["plans"].items():
        if pid == "free" or p["price"] > 0:
            yearly = P.annual_price(pid, c) if p["price"] > 0 else 0
            yc = (BOOK.annual_credits_total(yearly, pid) // 12 if v2 and yearly else p["credits"])
            prod, bp = catalog.play_product("%s_monthly" % pid, c)
            rows.append({"id": pid, "price": p["price"], "year": yearly, "credits": p["credits"],
                         "ycredits": yc, "ads": p["ads"], "family": p["family"],
                         "product": ("%s / %s" % (prod, bp)) if prod else "—",
                         "includes": P.plan_benefits(pid, lang, c) if pid in P._PLAN_META else []})
    off = BOOK.packs_off(c)
    packs = [dict(p, on_sale=p["id"] not in off,
                  product=catalog.play_product("pack_" + p["id"], c)[0]) for p in c["topup_packs"]]
    return rows, packs


def _levels(c):
    try:
        from core import ai_levels_service as ALS
        from core.logic import ai_levels as AL, plan_book as BOOK
        lv, _ = ALS.cfg(c)
        prices, rate, safe, _ = ALS._economics(c)
        return BOOK.level_rows(lv["levels"], prices, AL.worst_cost_usd,
                               lambda r: AL.credits_for(r, prices, rate, safe))
    except Exception:  # noqa: BLE001 — never break the page
        return []


def _history(row):
    from core.logic import plan_book as BOOK
    out = []
    for e in list(row.audit or [])[:30]:
        if not isinstance(e, dict):
            continue
        diff = [d for d in BOOK.flat_diff(e.get("old") or {}, e.get("new") or {})
                if d[0].startswith(HISTORY_PATHS)]
        if not diff:
            continue
        out.append({"at": str(e.get("at", ""))[:16].replace("T", " "), "actor": e.get("actor"),
                    "reason": e.get("reason", ""),
                    "changes": ["%s: %s → %s" % d for d in diff[:12]],
                    "more": max(0, len(diff) - 12)})
    return out[:15]


def plan_pnl(now=None, days=30):
    """Per-plan P&L: real orders (no tests, refunds removed) and AI cost by
    each user's current paid plan. Read-only."""
    from django.db.models import Sum
    from core.logic import plan_book as BOOK
    from core.models import AIUsage, PaidOrder, PlanPeriod
    now = now or timezone.now()
    since = now - timedelta(days=days)
    revenue = {}
    for o in PaidOrder.objects.filter(is_test=False, purchased_at__gte=since).only(
            "kind", "plan", "sku", "price", "refunded_amount", "currency"):
        key = o.plan if o.kind == "sub" and o.plan else (
            "cctv" if o.sku.startswith(("cctv", "cctvx_")) else "packs")
        amt = float(o.price or 0) - float(o.refunded_amount or 0)
        if o.currency != "BDT":
            continue
        revenue[key] = revenue.get(key, 0.0) + amt
    plan_of = {}
    for pp in PlanPeriod.objects.filter(status="active", starts_at__lte=now,
                                        ends_at__gt=now).only("user_id", "plan"):
        plan_of[pp.user_id] = pp.plan
    users = {}
    for p in plan_of.values():
        users[p] = users.get(p, 0) + 1
    try:
        from core import billing
        rate = float(billing.cfg().get("usd_bdt") or 120.0)
    except Exception:  # noqa: BLE001
        rate = 120.0
    cost = {}
    for r in (AIUsage.objects.filter(created_at__gte=since, user__isnull=False)
              .values("user_id").annotate(s=Sum("cost_usd"))):
        k = plan_of.get(r["user_id"], "free")
        cost[k] = cost.get(k, 0.0) + float(r["s"] or 0) * rate
    return BOOK.plan_pnl(revenue, cost, users)


@require_http_methods(["GET", "POST"])
@owner_view(perm="payments", write_perm="owner")
def plans(request):
    from core import billing
    from core.logic import plan_book as BOOK
    from core.views_build61 import pricing_apply
    lang = getattr(request, "owner_lang", "bn")
    lab = L.get(lang, L["bn"])
    c = billing.cfg()
    ctx, status = {}, 200
    if request.method == "POST":
        action = request.POST.get("action", "")
        reason = request.POST.get("reason", "").strip()[:200]
        patch, bad = None, []
        if not reason:
            bad.append("reason")
        elif action == "v2":
            patch = {"pricing_v2": {"on": request.POST.get("value") == "on"}}
        elif action == "plans":
            pp = {}
            for pid, p in c["plans"].items():
                row = {}
                for k in ("price", "annual_price", "family") + (() if BOOK.is_on(c) else ("credits",)):
                    raw = request.POST.get("%s.%s" % (pid, k))
                    if raw is None or raw.strip() == "":
                        continue
                    v = to_int(raw)
                    if v is None or v < 0:
                        bad.append("%s.%s" % (pid, k))
                    elif v != p.get(k):
                        row[k] = v
                ads = request.POST.get("%s.ads" % pid) == "on"
                if ads != p["ads"]:
                    row["ads"] = ads
                if row:
                    pp[pid] = row
            patch = {"plans": pp} if pp else None
        if bad:
            ctx["error"] = lab["bad"] + ": " + ", ".join(bad)
            status = 400
        elif patch:
            ok, payload = pricing_apply(request.owner.id, {"config": patch,
                                                           "reason": "plans: " + reason})
            if ok:
                S.audit(request, request.owner, "plans.update", "plans:%s" % action,
                        after={**patch, "_reason": reason})
                return done("/owner/plans")
            ctx["error"] = ", ".join(payload.get("problems") or ["error"])
            status = 400
            S.audit(request, request.owner, "plans.rejected", "plans:%s" % action,
                    after={"problems": payload.get("problems")}, ok=False)
        else:
            return done("/owner/plans", "nochange")
        c = billing.cfg()
    rows, packs = _book(c, lang)
    flip = []
    if not BOOK.is_on(c):
        try:
            from core.management.commands.pricing_v2_apply import preview
            flip = ["%s: %s → %s" % d for d in preview()[0]][:80]
        except Exception:  # noqa: BLE001
            flip = []
    ctx.update({"L": lab, "v2": BOOK.is_on(c), "plans": rows, "packs": packs,
                "levels": _levels(c), "check": BOOK.worst_case_rows(c), "flip": flip,
                "history": _history(billing.get_config()), "pnl": sorted(plan_pnl().items())})
    return page(request, "owner/plans.html", ctx, status=status, nav="plans")
