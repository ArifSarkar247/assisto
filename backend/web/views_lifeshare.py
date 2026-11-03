"""p3life — lifeassisto.com/p/<token> (read-only trip plan or event
programme) and lifeassisto.com/rsvp/<token> (one guest answers yes/no/maybe
without the app). Tokens are signed (core.life_share); noindex, no-store, no
ads, rate-limited per IP. Never shows budgets, vendors, gifts, documents or
other guests' names."""
from django.core.cache import cache
from django.shortcuts import render
from django.utils import timezone
from django.views.decorators.http import require_http_methods, require_GET

from core import life_share as LS

from .views import _ip_hash

RATE_PER_MIN = 30

TXT = {
    "bn": {
        "brand": "Assisto", "trip": "ভ্রমণ পরিকল্পনা", "event": "অনুষ্ঠান",
        "days": "দিনের পরিকল্পনা", "day": "দিন", "legs": "যাতায়াত",
        "nodays": "এখনো দিনের পরিকল্পনা লেখা হয়নি।",
        "schedule": "অনুষ্ঠানসূচি", "noschedule": "অনুষ্ঠানসূচি এখনো লেখা হয়নি।",
        "venue": "স্থান", "date": "তারিখ", "coming": "নিশ্চিত আসছেন",
        "expected": "আসতে পারেন (হয়তো-সহ)", "people": "জন",
        "modes": {"train": "ট্রেন", "bus": "বাস", "launch": "লঞ্চ",
                  "air": "বিমান", "car": "গাড়ি", "other": "অন্যান্য"},
        "bad": "লিংকটি ঠিক নেই।",
        "revoked": "যিনি পাঠিয়েছেন তিনি এই লিংকটি বন্ধ করে দিয়েছেন।",
        "limited": "অনেকবার চেষ্টা হয়েছে। এক মিনিট পরে আবার খুলুন।",
        "privacy_trip": "শুধু দেখার জন্য। বাজেট, প্যাকিং বা কাগজপত্র এখানে কখনো দেখানো হয় না। পাঠানো মানুষটি যেকোনো সময় লিংক বন্ধ করতে পারেন।",
        "privacy_event": "শুধু দেখার জন্য। বাজেট, ভেন্ডর, উপহার বা অন্য অতিথির নাম এখানে কখনো দেখানো হয় না।",
        "rsvp_h": "দাওয়াত", "dear": "প্রিয়", "q": "আপনি কি আসছেন?",
        "yes": "আসছি", "no": "আসতে পারছি না", "maybe": "হয়তো",
        "plus": "আপনার সাথে আর কতজন আসবেন?", "send": "উত্তর পাঠান",
        "saved": "ধন্যবাদ! আপনার উত্তর পৌঁছে গেছে।",
        "now": "আপনার এখনকার উত্তর", "change": "চাইলে উত্তর বদলাতে পারেন।",
        "err_answer": "আসছেন কিনা বাছুন।", "err_plus": "সঙ্গীর সংখ্যা ০ থেকে ২০-এর মধ্যে দিন।",
        "privacy_rsvp": "আপনার উত্তর শুধু আয়োজক দেখতে পান। অন্য অতিথির নাম এখানে দেখানো হয় না।",
        "by": "Assisto দিয়ে বানানো — lifeassisto.com", "other": "English",
    },
    "en": {
        "brand": "Assisto", "trip": "Trip plan", "event": "Event",
        "days": "Day plan", "day": "Day", "legs": "Getting there",
        "nodays": "No day plan written yet.",
        "schedule": "Programme", "noschedule": "No programme written yet.",
        "venue": "Venue", "date": "Date", "coming": "Confirmed coming",
        "expected": "May come (incl. maybe)", "people": "people",
        "modes": {"train": "Train", "bus": "Bus", "launch": "Launch",
                  "air": "Flight", "car": "Car", "other": "Other"},
        "bad": "This link is not valid.",
        "revoked": "The sender turned this link off.",
        "limited": "Too many tries. Please open it again in a minute.",
        "privacy_trip": "View only. The budget, packing list and documents are never shown here. The sender can turn this link off at any time.",
        "privacy_event": "View only. The budget, vendors, gifts and other guests' names are never shown here.",
        "rsvp_h": "Invitation", "dear": "Dear", "q": "Are you coming?",
        "yes": "Coming", "no": "Can't come", "maybe": "Maybe",
        "plus": "How many more people are coming with you?", "send": "Send answer",
        "saved": "Thank you! Your answer has reached the host.",
        "now": "Your current answer", "change": "You can change your answer.",
        "err_answer": "Please choose whether you are coming.",
        "err_plus": "Please give a number of companions from 0 to 20.",
        "privacy_rsvp": "Only the host sees your answer. Other guests' names are never shown here.",
        "by": "Made with Assisto — lifeassisto.com", "other": "বাংলা",
    },
}


def _lang(request):
    return "en" if request.GET.get("lang") == "en" else "bn"


def _rate_ok(request):
    key = "lshare:%s:%s" % (_ip_hash(request),
                            timezone.now().strftime("%Y%m%d%H%M"))
    try:
        n = cache.get(key, 0) + 1
        cache.set(key, n, 90)
        return n <= RATE_PER_MIN
    except Exception:
        return True


def _headers(resp):
    resp["Cache-Control"] = "no-store"
    resp["X-Robots-Tag"] = "noindex, nofollow"
    resp["X-Frame-Options"] = "DENY"
    resp["Referrer-Policy"] = "no-referrer"
    resp["X-Content-Type-Options"] = "nosniff"
    return resp


def _base(request, lang):
    return {"lang": lang, "T": TXT[lang],
            "other_q": "" if lang == "en" else "?lang=en",
            "qlang": "?lang=en" if lang == "en" else ""}


@require_GET
def plan_page(request, token):
    lang = _lang(request)
    ctx = _base(request, lang)
    if not _rate_ok(request):
        ctx["state"] = "limited"
        return _headers(render(request, "web/life_plan.html", ctx, status=429))
    state, row = LS.resolve(token, ("trip", "event"))
    ctx["state"] = state
    if state != "ok":
        return _headers(render(request, "web/life_plan.html", ctx,
                               status=404 if state == "bad" else 410))
    if row.collection == "travel/trips":
        ctx["kind"] = "trip"
        ctx["v"] = LS.trip_view(row, lang)
        for leg in ctx["v"]["legs"]:
            leg["mode_txt"] = TXT[lang]["modes"][leg["mode"]]
    else:
        ctx["kind"] = "event"
        ctx["v"] = LS.event_view(row, lang)
    return _headers(render(request, "web/life_plan.html", ctx))


@require_http_methods(["GET", "POST"])
def rsvp_page(request, token):
    lang = _lang(request)
    ctx = _base(request, lang)
    if not _rate_ok(request):
        ctx["state"] = "limited"
        return _headers(render(request, "web/life_rsvp.html", ctx, status=429))
    state, row = LS.resolve(token, ("guest",))
    ctx["state"] = state
    if state != "ok":
        return _headers(render(request, "web/life_rsvp.html", ctx,
                               status=404 if state == "bad" else 410))
    if request.method == "POST":
        err = LS.apply_rsvp(row, request.POST.get("answer"),
                            request.POST.get("plus_ones"))
        if err:
            ctx["error"] = TXT[lang]["err_" + err]
        else:
            ctx["saved"] = True
    g = row.data or {}
    ctx["guest"] = str(g.get("name") or "")[:120]
    cur = str(g.get("rsvp") or "")
    ctx["current"] = cur if cur in LS.RSVP_CHOICES else ""
    ctx["current_txt"] = TXT[lang].get(ctx["current"], "")
    ctx["plus"] = int(g.get("plus_ones") or 0) if ctx["current"] else 0
    ev = LS.event_for(row.user_id)
    ctx["v"] = LS.event_view(ev, lang, with_counts=False) if ev else None
    ctx["token"] = token
    return _headers(render(request, "web/life_rsvp.html", ctx,
                           status=400 if ctx.get("error") else 200))
