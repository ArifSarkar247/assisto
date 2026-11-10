"""aimoney (owner final order 10 Nov 03:45, part G): Owner Admin -> Money
(daily). Per day: free users' profit or loss (ad income minus their AI
cost), AI cost per answer by level, ad income per ad type, credits sold —
plus today's ads-per-answer number and how it was computed. Aggregates
only; no user is shown. Read-only."""
from django.views.decorators.http import require_http_methods

from .base import owner_view, page

L = {
    "bn": {"title": "টাকার হিসাব (দৈনিক)", "date": "তারিখ", "ads": "বিজ্ঞাপনের আয়",
           "free_ai": "ফ্রি ব্যবহারকারীর AI খরচ", "pnl": "ফ্রি ব্যবহারকারীতে লাভ/লোকসান",
           "per_answer": "প্রতি উত্তরে AI খরচ (লেভেল)", "packs": "প্যাক ক্রেডিট বিক্রি",
           "plans": "প্ল্যান ক্রেডিট", "estimate": "আনুমানিক (AdMob-এর আসল আয় এখনো আসেনি, ৳০.৪০/বিজ্ঞাপন ধরা)",
           "n": "আজ ১টি AI উত্তরের জন্য বিজ্ঞাপন", "how": "হিসাব",
           "cost": "একটি বিজ্ঞাপনের উত্তরের আসল খরচ", "income": "একটি রিওয়ার্ডেড বিজ্ঞাপনের আয়",
           "worst": "সবচেয়ে লম্বা উত্তরের খরচ", "profit": "সবচেয়ে খারাপ অবস্থায় লাভ",
           "intro": "শুধু মোট সংখ্যা — কোনো ব্যবহারকারী দেখা যায় না। বিজ্ঞাপন সংখ্যা = (আসল খরচ × ১.২) ÷ এক বিজ্ঞাপনের আয়, কমপক্ষে ২, প্রতিদিন নতুন করে হিসাব হয়।",
           "none": "—", "ad_row": "বিজ্ঞাপনের উত্তর"},
    "en": {"title": "Money (daily)", "date": "Date", "ads": "Ad income",
           "free_ai": "Free users' AI cost", "pnl": "Free users profit / loss",
           "per_answer": "AI cost per answer (level)", "packs": "Pack credits sold",
           "plans": "Plan credits", "estimate": "estimate (no real AdMob income yet, ৳0.40 an ad)",
           "n": "Ads for 1 AI answer today", "how": "How",
           "cost": "Real cost of one ad-funded answer", "income": "Income of one rewarded ad",
           "worst": "Longest answer cost", "profit": "Worst-case profit",
           "intro": "Totals only — no user is shown. Ads per answer = (real cost x 1.2) / income of one ad, minimum 2, recomputed every day.",
           "none": "—", "ad_row": "ad-funded"},
}


@require_http_methods(["GET"])
@owner_view()
def money(request):
    from core import ad_money_service as AMS
    lang = getattr(request, "owner_lang", "bn")
    lab = L.get(lang, L["bn"])
    try:
        days = int(request.GET.get("days") or 14)
    except (TypeError, ValueError):
        days = 14
    t = AMS.money_table(days=days)
    return page(request, "owner/money.html", {"t": t, "L": lab}, nav="money")
