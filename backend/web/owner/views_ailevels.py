"""aifinal (owner AI order 3 Nov 23:15, PART 3): Owner Admin -> AI answer
levels. Normal / Better / Best: provider, model, hard input/output caps, max
message length, credits (never below the computed 40 % worst-case minimum),
the on/off switch and which levels free + ad credits pay for. Per-provider
daily budget caps live on Owner Admin -> AI (shown here, linked). Every save
goes through pricing_apply (PricingConfig audit) AND OwnerAudit."""
from django.views.decorators.http import require_http_methods

from . import security as S
from .base import done, owner_view, page

INT_KEYS = ("in_cap", "out_cap", "max_chars", "history_turns", "credits", "per_day")
TOP_INT = ("welcome_credits", "ad_answers_per_ad")   # PART 4
L = {
    "bn": {"title": "AI উত্তরের লেভেল", "intro": "ব্যবহারকারী নিজে বেছে নেন: সাধারণ / ভালো / সেরা। কখনো নিজে থেকে দামি মডেলে যায় না; ব্যাকআপ শুধু একই বা সস্তা মডেলে। ক্রেডিট = সবচেয়ে খারাপ অবস্থার খরচ থেকে হিসাব (৪০% লাভ, VAT ১৫%, Play ফি ১৫%) — এর কমে রাখা যায় না।",
           "on": "লেভেল চালু (অ্যাপে পিকার দেখাবে)", "default": "ডিফল্ট লেভেল", "free": "ফ্রি ও বিজ্ঞাপনের ক্রেডিট যে লেভেলে চলে",
           "level": "লেভেল", "provider": "প্রোভাইডার", "model": "মডেল", "worst": "সবচেয়ে খারাপ খরচ", "min": "সর্বনিম্ন ক্রেডিট",
           "charged": "নেওয়া হয়", "profit": "লাভ % (খারাপ অবস্থা)", "caps": "প্রোভাইডারের দৈনিক খরচের সীমা (AI পাতায় বদলান)",
           "save": "সংরক্ষণ", "reason": "কারণ", "welcome": "নতুন ইউজারকে একবার ফ্রি ক্রেডিট (যাচাই করা ফোন + ডিভাইস প্রতি একবার)", "welcome_n": "কত ক্রেডিট", "ad_n": "একটি বিজ্ঞাপনে কয়টি সাধারণ উত্তর (শুধু প্রাপ্তবয়স্ক)", "ad_profit": "বিজ্ঞাপনের লাভ % (খারাপ অবস্থা, ন্যূনতম eCPM)", "per_day": "per_day = একজন ইউজার দিনে কয়টি উত্তর (০ = সীমা নেই)", "bad": "ভুল সংখ্যা", "rate": "USD→৳", "safe": "এক ক্রেডিটে সর্বোচ্চ AI খরচ ৳"},
    "en": {"title": "AI answer levels", "intro": "The user picks: Normal / Better / Best. Never auto-upgrades to a dearer model; fallback only to the same or a cheaper one. Credits come from the worst-case cost (40 % profit, VAT 15 %, Play fee 15 %) — they cannot be set lower.",
           "on": "Levels on (the app shows the picker)", "default": "Default level", "free": "Levels free + ad credits pay for",
           "level": "Level", "provider": "Provider", "model": "Model", "worst": "Worst-case cost", "min": "Minimum credits",
           "charged": "Charged", "profit": "Profit % (worst case)", "caps": "Provider daily spend caps (edit on the AI page)",
           "save": "Save", "reason": "Reason", "welcome": "Free credits once for a new user (once per verified phone + device)", "welcome_n": "Credits", "ad_n": "Normal answers per rewarded ad (adults only)", "ad_profit": "Ad profit % (worst case, floor eCPM)", "per_day": "per_day = answers per user per day (0 = no limit)", "bad": "Invalid number", "rate": "USD→৳", "safe": "Max AI cost per credit ৳"},
}


@require_http_methods(["GET", "POST"])
@owner_view(perm="payments", write_perm="owner")
def ai_levels(request):
    from core import ai_levels_service as ALS
    from core import ai_router as R
    from core.logic import ai_levels as AL
    from core.views_build61 import pricing_apply
    lang = getattr(request, "owner_lang", "bn")
    lab = L.get(lang, L["bn"])
    cur, _c = ALS.cfg()
    ctx, status = {}, 200
    if request.method == "POST":
        reason = request.POST.get("reason", "").strip()[:200] or "ai_levels"
        new = {"enabled": request.POST.get("enabled") == "on",
               "default": request.POST.get("default", cur["default"]),
               "free_credit_levels": [x for x in AL.LEVEL_IDS
                                      if request.POST.get("free_" + x) == "on"] or ["normal"],
               "levels": {}, "welcome_on": request.POST.get("welcome_on") == "on"}
        bad = []
        for k in TOP_INT:
            raw = request.POST.get(k, "").strip()
            try:
                new[k] = int(raw) if raw else cur[k]
            except ValueError:
                bad.append(k)
        for lid in AL.LEVEL_IDS:
            row = dict(cur["levels"][lid])
            for k in INT_KEYS:
                raw = request.POST.get("%s_%s" % (lid, k), "").strip()
                if raw == "":
                    continue
                try:
                    row[k] = int(raw)
                except ValueError:
                    bad.append("%s_%s" % (lid, k))
            for k in ("provider", "model"):
                raw = request.POST.get("%s_%s" % (lid, k), "").strip()
                if raw:
                    row[k] = raw
            new["levels"][lid] = row
        if bad:
            ctx["error"] = lab["bad"] + ": " + ", ".join(bad)
            status = 400
        else:
            ok, payload = pricing_apply(request.owner.id, {"config": {"ai_levels": new},
                                                           "reason": reason})
            if ok:
                S.audit(request, request.owner, "ai_levels.update", "ai_levels",
                        after={"enabled": new["enabled"], "_reason": reason})
                return done("/owner/ai-levels")
            ctx["error"] = ", ".join(payload.get("problems") or ["error"])
            status = 400
    cur, _c = ALS.cfg()
    ctx.update({"L": lab, "c": cur, "t": ALS.table(), "ids": AL.LEVEL_IDS,
                "providers": AL.PROVIDERS, "caps": R.cfg()["caps_usd"], "int_keys": INT_KEYS,
                "ad": ALS.ad_table()})
    return page(request, "owner/ai_levels.html", ctx, status=status, nav="ai_levels")
