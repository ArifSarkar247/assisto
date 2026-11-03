"""aifinal (owner AI order 3 Nov 23:15, PART 2): Owner Admin -> AI usage log.
Per request: time, pseudonymous user id, feature, answer level, provider +
model, tokens in/out, cost USD + BDT, latency, result (success, fallback with
reason, error, refunded). Totals today and this month per provider. Filters.
Message text is NEVER stored or shown (core/ai_usage_log.py)."""
from django.views.decorators.http import require_http_methods

from .base import owner_view, page

L = {
    "bn": {"title": "AI ব্যবহারের লগ", "intro": "প্রতিটি AI অনুরোধের হিসাব — বার্তার লেখা কখনো রাখা বা দেখানো হয় না। ইউজার আইডি ছদ্মনামে (u-…)। ৯০ দিন পরে নিজে থেকে মুছে যায়।",
           "today": "আজ (প্রোভাইডার অনুযায়ী)", "month": "এই মাস (প্রোভাইডার অনুযায়ী)",
           "provider": "প্রোভাইডার", "requests": "অনুরোধ", "tin": "টোকেন ইন", "tout": "টোকেন আউট",
           "usd": "খরচ USD", "bdt": "খরচ ৳", "time": "সময়", "user": "ইউজার (ছদ্মনাম)",
           "feature": "ফিচার", "level": "লেভেল", "model": "মডেল", "lat": "সময় লেগেছে ms",
           "result": "ফল", "reason": "কারণ", "credits": "ক্রেডিট", "refunded": "ফেরত",
           "filter": "ফিল্টার", "all": "সব", "days": "দিন", "none": "এই ফিল্টারে কোনো অনুরোধ নেই।",
           "success": "সফল", "fallback": "ব্যাকআপে গেছে", "error": "ব্যর্থ", "refunded_r": "ফেরত দেওয়া"},
    "en": {"title": "AI usage log", "intro": "Every AI request — message text is never stored or shown. User ids are pseudonyms (u-…). Rows are deleted after 90 days.",
           "today": "Today (per provider)", "month": "This month (per provider)",
           "provider": "Provider", "requests": "Requests", "tin": "Tokens in", "tout": "Tokens out",
           "usd": "Cost USD", "bdt": "Cost ৳", "time": "Time", "user": "User (pseudonym)",
           "feature": "Feature", "level": "Level", "model": "Model", "lat": "Latency ms",
           "result": "Result", "reason": "Reason", "credits": "Credits", "refunded": "Refunded",
           "filter": "Filter", "all": "All", "days": "Days", "none": "No requests for this filter.",
           "success": "success", "fallback": "fallback", "error": "error", "refunded_r": "refunded"},
}


@require_http_methods(["GET"])
@owner_view(perm="payments")
def ai_usage(request):
    from core import ai_config as C
    from core import ai_usage_log as UL
    lang = getattr(request, "owner_lang", "bn")
    f = UL.clean_filters(request.GET)
    ctx = {"L": L.get(lang, L["bn"]), "f": f,
           "today": UL.totals(period="today"), "month": UL.totals(period="month"),
           "rows": UL.recent(f), "providers": C.PROVIDERS, "levels": UL.LEVELS,
           "results": UL.RESULTS, "retention": UL.RETENTION_DAYS}
    return page(request, "owner/ai_usage.html", ctx, nav="ai_usage")
