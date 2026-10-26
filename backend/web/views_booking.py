"""booking-bot — lifeassisto.com/b/<slug>: a business' public booking page.

Mobile-first, one language per page (?lang=en, default Bangla), NO JS, no
ads, noindex. Steps: service → day → free time → name + mobile → SMS code →
booked (with a private manage link: cancel inside the business' policy, stop
reminders). Every time shown comes from core.booking_service.slots() — the
business' real calendar. Behind the flag `booking_bot` (the business owner's):
off → 404. All limits are the API's (core.booking_service / core.otp).
"""
from datetime import date, datetime

from django.http import Http404, HttpResponseRedirect
from django.shortcuts import render
from django.utils import timezone
from django.views.decorators.http import require_http_methods

from core import booking_service as S
from core.logic import booking as L

from .views import _lang

TXT = {
    "bn": {
        "book": "সময় বুক করুন", "services": "সেবা বেছে নিন", "min": "মিনিট",
        "days": "দিন বেছে নিন", "times": "খালি সময়", "none_day": "এই দিনে কোনো খালি সময় নেই — অন্য দিন দেখুন।",
        "free": "খালি", "full": "ভর্তি", "closed": "বন্ধ", "change": "বদলান",
        "name": "আপনার নাম", "phone": "মোবাইল নম্বর", "send": "কোড পাঠিয়ে বুক করুন",
        "code": "SMS-এ আসা ৬ সংখ্যার কোড", "confirm": "বুকিং নিশ্চিত করুন",
        "sent": "আপনার নম্বরে একটি কোড পাঠানো হয়েছে।",
        "ok_h": "বুকিং হয়েছে", "req_h": "অনুরোধ পাঠানো হয়েছে",
        "req_b": "ব্যবসা নিশ্চিত করলে জানানো হবে।",
        "manage": "এই লিংকটি রেখে দিন — এখান থেকে বুকিং দেখা, বাতিল ও রিমাইন্ডার বন্ধ করা যাবে:",
        "not_taking": "এই ব্যবসা এখন অনলাইন বুকিং নিচ্ছে না।",
        "policy": "শুরুর {h} ঘণ্টা আগ পর্যন্ত অনলাইনে বাতিল করা যাবে।",
        "privacy": "আপনার নাম ও নম্বর শুধু এই ব্যবসা দেখবে। শুধু এই বুকিং নিয়েই বার্তা আসবে — কোনো বিজ্ঞাপন নয়।",
        "app": "Assisto অ্যাপ থাকলে অ্যাপ থেকেও বুক করা যায় — কোড লাগে না।",
        "your": "আপনার বুকিং", "status": "অবস্থা", "cancel": "বুকিং বাতিল করুন",
        "stop": "রিমাইন্ডার বন্ধ করুন", "stopped": "রিমাইন্ডার বন্ধ করা হয়েছে।",
        "cancelled": "বুকিং বাতিল হয়েছে।", "too_late": "এখন আর অনলাইনে বাতিল করা যাবে না — ব্যবসায় সরাসরি যোগাযোগ করুন।",
        "unknown": "লিংকটি ঠিক নেই বা মেয়াদ শেষ।", "back": "বুকিং পেজে ফিরুন",
        "address": "ঠিকানা",
    },
    "en": {
        "book": "Book a time", "services": "Choose a service", "min": "min",
        "days": "Choose a day", "times": "Free times", "none_day": "No free time on this day — please try another day.",
        "free": "free", "full": "full", "closed": "closed", "change": "Change",
        "name": "Your name", "phone": "Mobile number", "send": "Send code and book",
        "code": "6-digit code from the SMS", "confirm": "Confirm booking",
        "sent": "We sent a code to your number.",
        "ok_h": "Booked", "req_h": "Request sent",
        "req_b": "We'll let you know when the business confirms.",
        "manage": "Keep this link — use it to see, cancel or stop reminders for your booking:",
        "not_taking": "This business is not taking online bookings right now.",
        "policy": "You can cancel online until {h} hours before the start.",
        "privacy": "Only this business sees your name and number. You'll only get messages about this booking — no ads.",
        "app": "Have the Assisto app? Book there too — no code needed.",
        "your": "Your booking", "status": "Status", "cancel": "Cancel booking",
        "stop": "Stop reminders", "stopped": "Reminders are stopped.",
        "cancelled": "The booking is cancelled.", "too_late": "It's too late to cancel online — please contact the business.",
        "unknown": "This link is not right or has expired.", "back": "Back to the booking page",
        "address": "Address",
    },
}


def _page_or_404(request, slug):
    from core.models import BookingPage
    page = (BookingPage.objects.filter(slug=str(slug)[:40]).select_related("business__user").first())
    if page is None or not S.flag_on(page.business.user):
        raise Http404()
    return page


def _render(request, tpl, status=200, **ctx):
    lang = _lang(request)
    ctx.update(lang=lang, B=TXT[lang], qlang="?lang=en" if lang == "en" else "",
               amp_lang="&lang=en" if lang == "en" else "")
    resp = render(request, tpl, ctx, status=status)
    resp["Cache-Control"] = "no-store"
    resp["X-Frame-Options"] = "DENY"
    resp["Referrer-Policy"] = "no-referrer"
    resp["X-Robots-Tag"] = "noindex"
    return resp


def _ctx(request, page):
    from core.booking_views import _taking
    lang = _lang(request)
    services = list(page.business.booking_services.filter(active=True))
    svc = None
    sid = request.GET.get("service") or request.POST.get("service")
    if sid and str(sid).isdigit():
        svc = next((s for s in services if s.pk == int(sid)), None)
    if svc is None and len(services) == 1:
        svc = services[0]
    taking = _taking(page)
    ctx = {"page": page, "biz_name": page.title or page.business.shop_name,
           "services": [dict(S.service_dict(s, lang),
                             dur=L.num(lang, s.duration_min),
                             price=L.num(lang, s.price_bdt)) for s in services],
           "svc": svc, "taking": taking,
           "policy": TXT[lang]["policy"].format(h=L.num(lang, page.cancel_hours))}
    if svc is not None and taking:
        now = timezone.now()
        days = []
        for d, n in S.available_days(page, svc, now=now, days=14):
            dd = date.fromisoformat(d)
            days.append({"day": d, "free": n, "free_txt": L.num(lang, n),
                         "label": L.day_label(lang, dd)})
        ctx["days"] = days
        try:
            day = date.fromisoformat((request.GET.get("day") or request.POST.get("day") or "")[:10])
        except ValueError:
            day = next((date.fromisoformat(x["day"]) for x in days if x["free"]), None)
        if day is not None:
            ctx["day"] = day.isoformat()
            ctx["slots"] = [{"start": L.local(s["start"]).isoformat(),
                             "label": L.time_text(lang, s["start"])}
                            for s in S.slots(page, svc, day, now=now)]
    return ctx


@require_http_methods(["GET", "POST"])
def booking_page(request, slug):
    from core import otp
    from core.booking_views import book_public, _ERR
    page = _page_or_404(request, slug)
    lang = _lang(request)
    B = TXT[lang]
    if request.method == "GET":
        return _render(request, "web/booking.html", **_ctx(request, page))
    action = request.POST.get("action", "")
    form = {k: (request.POST.get(k) or "").strip()[:80] for k in ("service", "start", "name", "phone", "day")}
    ctx = _ctx(request, page)
    ctx["form"] = form
    try:
        ctx["picked"] = L.when_text(lang, datetime.fromisoformat(form["start"]))
    except ValueError:
        ctx["picked"] = ""

    def fail(code, status=400, **kw):
        ctx.update(kw)
        ctx["error"] = _ERR.get(code, _ERR["bad_input"])[1 if lang == "en" else 0]
        return _render(request, "web/booking.html", status=status, **ctx)

    if action == "send":
        canon = otp.normalize_bd_phone(form["phone"])
        if not canon:
            return fail("bad_phone")
        if not form["name"] or not form["start"]:
            return fail("bad_input")
        c = S.contact(page.business, canon)
        if c and c.blocked:
            return fail("blocked", 403)
        try:
            otp.issue(canon, "booking", request=request, lang=lang)
        except otp.OtpError as e:
            if e.reason == "sms_not_configured":
                return fail("sms_off", 503)
            return fail("rate_limited", 429)
        ctx["step"] = "code"
        ctx["info"] = B["sent"]
        return _render(request, "web/booking.html", **ctx)
    if action == "book":
        data = dict(form, code=request.POST.get("code", "")[:8])
        try:
            b, raw = book_public(request, page, data, lang)
        except S.BookingError as e:
            st = e.status if e.status < 500 else 400
            if e.code == "bad_code":
                return fail("bad_code", 400, step="code")
            return fail(e.code, st)
        return HttpResponseRedirect("/b/m/%s%s" % (raw, "?lang=en&new=1" if lang == "en" else "?new=1"))
    return fail("bad_input")


@require_http_methods(["GET", "POST"])
def booking_manage(request, token):
    from core.models import Booking
    lang = _lang(request)
    B = TXT[lang]
    b = (Booking.objects.filter(manage_hash=S.hash_token(token)).select_related("business").first()
         if token else None)
    if b is None or not S.flag_on(b.business.user):
        return _render(request, "web/booking_manage.html", status=404, unknown=True)
    info = err = ""
    if request.method == "POST":
        a = request.POST.get("action", "")
        if a == "cancel":
            try:
                S.transition(b, "cancelled", "customer")
                info = B["cancelled"]
            except S.BookingError:
                err = B["too_late"]
        elif a == "stop" and b.customer_phone:
            S.set_contact(b.business, b.customer_phone, stop=True)
            info = B["stopped"]
        b.refresh_from_db()
    d = S.booking_dict(b, lang, for_business=False)
    page = getattr(b.business, "booking_page", None)
    return _render(request, "web/booking_manage.html", b=d, info=info, error=err,
                   new=request.GET.get("new") == "1",
                   slug=page.slug if page else "", token=token,
                   can_cancel="cancelled" in d["can"],
                   stopped=bool((S.contact(b.business, b.customer_phone) or None) and
                                S.contact(b.business, b.customer_phone).stop))
