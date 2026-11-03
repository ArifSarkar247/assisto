"""mapscost (owner order 3 Nov 18:40, PART 1): Owner Admin -> Maps usage.
Paid Google Maps calls per API today / this month, calls refused by a cap
today, free monthly cap left, estimated USD + BDT (rate editable), and the
per-user daily limit + global daily cap per API (editable). Numbers only —
no user's location is ever shown here."""
from django.views.decorators.http import require_http_methods

from . import security as S
from .base import done, owner_view, page

L = {
    "bn": {"title": "ম্যাপ খরচ", "api": "API", "today": "আজ কল", "capped": "আজ সীমায় আটকানো",
           "month": "এই মাসে কল", "free_left": "ফ্রি সীমা বাকি", "usd": "আনুমানিক USD",
           "bdt": "আনুমানিক টাকা", "rate": "USD / ১০০০ কল", "free": "মাসিক ফ্রি কল",
           "user_day": "প্রতি জনের দৈনিক সীমা", "global_day": "সবার মিলে দৈনিক সীমা",
           "bdt_rate": "১ USD = কত টাকা", "save": "সেভ", "total": "এই মাসের মোট আনুমানিক খরচ",
           "ready": "সার্ভার কি সেট ও চালু", "not_ready": "সার্ভার কি নেই বা Cost flags-এ maps_geocoding বন্ধ — সব পেইড কল বন্ধ, অ্যাপ ফ্রি বিকল্প দেখাচ্ছে",
           "intro": "শুধু সংখ্যা — কারো লোকেশন এখানে দেখা যায় না। ম্যাপ দেখানো (Maps SDK), লাইভ লোকেশন, গন্তব্য অ্যালার্ম, স্কুল/পৌঁছানোর জিওফেন্স, নেভিগেশন আর SOS কোনো পেইড কল করে না। খরচ = (মাসের কল − ফ্রি সীমা) × রেট — অনুমান, Google-এর বিল নয়।",
           "bad": "সংখ্যা ঠিক নয় — সেভ হয়নি"},
    "en": {"title": "Maps usage", "api": "API", "today": "Calls today", "capped": "Refused by cap today",
           "month": "Calls this month", "free_left": "Free cap left", "usd": "Est. USD",
           "bdt": "Est. BDT", "rate": "USD / 1000 calls", "free": "Free calls / month",
           "user_day": "Per-user daily limit", "global_day": "Global daily cap",
           "bdt_rate": "1 USD = BDT", "save": "Save", "total": "Estimated cost this month",
           "ready": "Server key set and on", "not_ready": "No server key, or maps_geocoding is off in Cost flags — all paid calls are off; the app shows the free fallback",
           "intro": "Numbers only — nobody's location is shown here. Map display (Maps SDK), live location, destination alarm, school / arrival geofences, navigation and SOS make no paid calls. Cost = (month calls − free cap) × rate — an estimate, not Google's bill.",
           "bad": "Not a valid number — not saved"},
}


@require_http_methods(["GET", "POST"])
@owner_view()
def maps_usage(request):
    from core import maps_cost as MC
    lang = getattr(request, "owner_lang", "bn")
    lab = L.get(lang, L["bn"])
    problems, status = [], 200
    if request.method == "POST":
        api = request.POST.get("api", "")
        try:
            if api == "_bdt":
                before, after = MC.save_config(None, bdt_per_usd=request.POST.get("bdt_per_usd", ""))
            else:
                vals = {k: request.POST.get(k, "").strip().replace(",", "")
                        for k in MC.FIELD_LIMITS if request.POST.get(k, "").strip() != ""}
                before, after = MC.save_config(api, vals)
        except (TypeError, ValueError):
            problems, status = [lab["bad"]], 400
        else:
            S.audit(request, request.owner, "maps.cost", "maps:%s" % (api or "-")[:20],
                    before=before, after=after)
            return done("/owner/maps-usage")
    card = MC.usage_card(lang=lang)
    return page(request, "owner/maps_usage.html",
                {"card": card, "L": lab, "problems": problems}, status=status, nav="maps_usage")
