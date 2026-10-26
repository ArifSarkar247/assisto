"""
booking_views.py — BOOKING BOT API (big-week item I), behind the server flag
`booking_bot` (default OFF): every endpoint answers 403 `feature_off` while
hidden (owner / staff / allow-listed testers preview it — core.feature_flags).
Public endpoints are gated on the BUSINESS OWNER's flag.

BUSINESS (Token; owner, or BusinessStaff for the day-to-day screens)
  GET/PUT  booking/biz                      page + hours + days off + policies
  POST     booking/biz/services             add a service   (owner)
  PATCH/DELETE booking/biz/services/<id>                    (owner)
  POST     booking/biz/staff                add a staff member (owner)
  PATCH/DELETE booking/biz/staff/<id>                       (owner)
  GET      booking/biz/bookings             ?scope=today|upcoming|past|day&day=
  POST     booking/biz/bookings             a phone / walk-in booking
  GET      booking/biz/bookings/<id>
  POST     booking/biz/bookings/<id>/action {action: confirmed|done|no_show|
                                            cancelled|reschedule, start}
  GET      booking/biz/slots                ?service=&day=&exclude=
  GET/POST booking/biz/blocks               block / unblock a number
PUBLIC (no login; OTP for guests; rate limited)
  GET      booking/p/<slug>                 business card + services + policy
  GET      booking/p/<slug>/days            ?service=  free count per day
  GET      booking/p/<slug>/slots           ?service=&day=
  POST     booking/p/<slug>/otp             {phone} → SMS code (core.otp)
  POST     booking/p/<slug>/book            {service, start, name, phone, code}
CUSTOMER (Token)
  GET      booking/mine
  POST     booking/mine/<id>/action         {action: cancelled|reschedule, start}
"""
from datetime import date, datetime

from django.utils import timezone
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from .i18n import req_lang, pick, is_play_flavour
from . import booking_service as S
from .logic import booking as L

FLAG = S.FLAG

_ERR = {
    "feature_off": ("এই ফিচারটি এখনো চালু হয়নি।", "This feature is not available yet."),
    "not_found": ("পাওয়া যায়নি।", "Not found."),
    "owner_only": ("শুধু মালিক এটি বদলাতে পারেন।", "Only the owner can change this."),
    "forbidden_business": ("এই ব্যবসায় আপনার অ্যাক্সেস নেই।", "You don't have access to this business."),
    "upgrade_required": ("অনলাইন বুকিং চালু করতে বিজনেস প্ল্যান দরকার।",
                         "Online booking needs the Business plan."),
    "not_ready": ("আগে অন্তত একটি সেবা ও খোলার সময় যোগ করুন।",
                  "Add at least one service and your opening hours first."),
    "bad_input": ("তথ্যগুলো ঠিক নেই — আবার দেখুন।", "Some details are not right — please check."),
    "bad_slug": ("লিংকের নাম শুধু ইংরেজি ছোট অক্ষর, সংখ্যা ও - দিয়ে (৩–৪০ অক্ষর)।",
                 "The link name may use small English letters, numbers and - (3–40 characters)."),
    "slug_taken": ("এই লিংকের নাম অন্য কেউ নিয়েছেন।", "This link name is taken."),
    "too_many": ("সীমা পূর্ণ হয়েছে।", "Limit reached."),
    "bad_service": ("সেবাটি পাওয়া যায়নি।", "That service was not found."),
    "not_taking_bookings": ("এই ব্যবসা এখন অনলাইন বুকিং নিচ্ছে না।",
                            "This business is not taking online bookings right now."),
    "slot_taken": ("দুঃখিত, এই সময়টি আর খালি নেই। অন্য সময় বেছে নিন।",
                   "Sorry, that time is no longer free. Please pick another."),
    "blocked": ("এই নম্বর থেকে অনলাইনে বুকিং নেওয়া যাচ্ছে না।",
                "Online booking isn't available for this number."),
    "too_many_pending": ("এই ব্যবসায় আপনার আগের বুকিং এখনো বাকি — আগে সেটি শেষ বা বাতিল করুন।",
                         "You already have bookings waiting here — finish or cancel one first."),
    "rate_limited": ("অনেকবার চেষ্টা হয়েছে। কিছুক্ষণ পরে আবার চেষ্টা করুন।",
                     "Too many tries. Please try again a little later."),
    "daily_cap": ("আজকের অনলাইন বুকিংয়ের সীমা পূর্ণ। ব্যবসায় সরাসরি যোগাযোগ করুন।",
                  "Today's online booking limit is reached. Please contact the business."),
    "too_late": ("এখন আর অনলাইনে বদলানো যাবে না — ব্যবসায় সরাসরি যোগাযোগ করুন।",
                 "It's too late to change online — please contact the business."),
    "too_many_reschedules": ("এই বুকিং আর বদলানো যাবে না।", "This booking can't be moved again."),
    "bad_transition": ("এই বুকিংয়ে এটা করা যায় না।", "That can't be done to this booking."),
    "not_started": ("বুকিংয়ের সময় শুরু হওয়ার পর এটা করা যাবে।", "You can do this once the booking time has started."),
    "otp_required": ("আপনার নম্বরে পাঠানো কোডটি দিন।", "Enter the code sent to your number."),
    "bad_code": ("কোডটি মেলেনি। আবার চেষ্টা করুন।", "That code did not match. Please try again."),
    "sms_off": ("SMS কোড এখন পাঠানো যাচ্ছে না — Assisto অ্যাপে লগইন করে বুক করুন।",
                "We can't send SMS codes right now — please book from the Assisto app."),
    "bad_phone": ("সঠিক মোবাইল নম্বর দিন (01XXXXXXXXX)।", "Enter a valid mobile number (01XXXXXXXXX)."),
}


def err(lang, code, status=400, **extra):
    bn, en = _ERR.get(code, _ERR["bad_input"])
    d = {"error": code, "detail": pick(lang, bn, en)}
    d.update(extra)
    return Response(d, status=status)


def _on(request, user=None):
    return S.flag_on(user if user is not None else request.user, is_play_flavour(request))


class _Gated(APIView):
    permission_classes = [IsAuthenticated]

    def initial(self, request, *args, **kwargs):
        super().initial(request, *args, **kwargs)
        if not _on(request):
            from rest_framework.exceptions import PermissionDenied
            lang = req_lang(request)
            raise PermissionDenied(detail={"error": "feature_off",
                                           "detail": pick(lang, *_ERR["feature_off"])})


def _biz(request):
    """(business, is_owner) or (None, None)."""
    from .business_views import resolve_business, is_owner
    prof, role = resolve_business(request)
    if prof is None:
        return None, None
    return prof, is_owner(role)


def _parse_day(s, now):
    try:
        return date.fromisoformat(str(s)[:10])
    except (TypeError, ValueError):
        return L.local(now).date()


def _parse_start(s):
    try:
        dt = datetime.fromisoformat(str(s).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=L.TZ)
    return dt


def _page_dict(page, lang, owner_view=True):
    from .models import BookingService, BookingStaff
    biz = page.business
    d = {"slug": page.slug, "enabled": page.enabled, "title": page.title or biz.shop_name,
         "about": page.about, "address": page.address,
         "weekly_hours": page.weekly_hours or {}, "days_off": page.days_off or [],
         "capacity": page.capacity, "step_min": page.step_min,
         "min_notice_min": page.min_notice_min, "max_days_ahead": page.max_days_ahead,
         "cancel_hours": page.cancel_hours, "auto_confirm": page.auto_confirm,
         "services": [S.service_dict(s, lang) for s in
                      BookingService.objects.filter(business=biz, **({} if owner_view else {"active": True}))],
         "public_url": S.public_url(page)}
    if owner_view:
        d.update({"max_pending_per_phone": page.max_pending_per_phone,
                  "chat_bot": page.chat_bot, "sms_reminders": page.sms_reminders,
                  "staff": [{"id": s.pk, "name": s.name, "active": s.active}
                            for s in BookingStaff.objects.filter(business=biz)],
                  "ready_problems": S.ready_problems(page),
                  "plan_ok": S.business_plan_ok(biz.user),
                  "limits": {k: S.knob(k) for k in S.KNOBS},
                  "sms_available": _sms_available()})
    return d


def _sms_available():
    from . import sms_gateway
    return sms_gateway.adapter() is not None


# =================================================================== business
class BizPageView(_Gated):
    def get(self, request):
        lang = req_lang(request)
        biz, owner = _biz(request)
        if biz is None:
            return err(lang, "forbidden_business", 403)
        page = S.page_for(biz)
        d = _page_dict(page, lang)
        d["is_owner"] = bool(owner)
        now = timezone.now()
        from .models import Booking
        day0 = datetime.combine(L.local(now).date(), datetime.min.time(), tzinfo=L.TZ)
        from datetime import timedelta
        d["counts"] = {
            "today": Booking.objects.filter(business=biz, start__gte=day0,
                                            start__lt=day0 + timedelta(days=1)).exclude(status="cancelled").count(),
            "pending": Booking.objects.filter(business=biz, status="requested", start__gt=now).count(),
            "upcoming": Booking.objects.filter(business=biz, status__in=L.ACTIVE, start__gt=now).count(),
        }
        return Response(d)

    def put(self, request):
        lang = req_lang(request)
        biz, owner = _biz(request)
        if biz is None:
            return err(lang, "forbidden_business", 403)
        if not owner:
            return err(lang, "owner_only", 403)
        page = S.page_for(biz)
        data = request.data if isinstance(request.data, dict) else {}
        fields = []
        if "weekly_hours" in data:
            hours, problems = L.clean_hours(data.get("weekly_hours"))
            if problems:
                return err(lang, "bad_input", 400, fields=problems)
            page.weekly_hours = hours
            fields.append("weekly_hours")
        if "days_off" in data:
            page.days_off = L.clean_days_off(data.get("days_off"), L.local(timezone.now()).date())
            fields.append("days_off")
        nums = {k: data[k] for k in L.BOUNDS if k in data}
        if nums:
            base = {k: getattr(page, k) for k in L.BOUNDS}
            clean = L.clean_settings(nums, base)
            for k in nums:
                setattr(page, k, clean[k])
                fields.append(k)
        for k, n in (("title", 120), ("about", 300), ("address", 200)):
            if k in data:
                setattr(page, k, str(data.get(k) or "").strip()[:n])
                fields.append(k)
        for k in ("auto_confirm", "chat_bot", "sms_reminders"):
            if k in data:
                setattr(page, k, bool(data.get(k)))
                fields.append(k)
        if "slug" in data:
            slug = L.clean_slug(data.get("slug"))
            if not slug:
                return err(lang, "bad_slug", 400)
            from .models import BookingPage
            if BookingPage.objects.filter(slug=slug).exclude(pk=page.pk).exists():
                return err(lang, "slug_taken", 409)
            page.slug = slug
            fields.append("slug")
        if "enabled" in data:
            want = bool(data.get("enabled"))
            if want and not S.business_plan_ok(biz.user):
                return err(lang, "upgrade_required", 402, plan_required="business", upgrade=True)
            page.enabled = want
            fields.append("enabled")
        if fields:
            page.save()
        if page.enabled and S.ready_problems(page):
            page.enabled = False
            page.save(update_fields=["enabled"])
            if data.get("enabled"):
                return err(lang, "not_ready", 409, ready_problems=S.ready_problems(page))
        return self.get(request)


class BizServicesView(_Gated):
    def _save(self, request, data, pk=None):
        from .models import BookingService
        lang = req_lang(request)
        biz, owner = _biz(request)
        if biz is None:
            return err(lang, "forbidden_business", 403)
        if not owner:
            return err(lang, "owner_only", 403)
        s = None
        if pk is not None:
            s = BookingService.objects.filter(business=biz, pk=pk).first()
            if s is None:
                return err(lang, "not_found", 404)
            data = dict(S.service_dict(s, lang), **data)
        elif BookingService.objects.filter(business=biz).count() >= L.MAX_SERVICES:
            return err(lang, "too_many", 409)
        clean, problems = L.clean_service(data)
        if problems:
            return err(lang, "bad_input", 400, fields=problems)
        valid = set(biz.booking_staff.values_list("pk", flat=True))
        clean["staff_ids"] = [i for i in clean["staff_ids"] if i in valid]
        if s is None:
            s = BookingService.objects.create(business=biz, **clean)
            return Response(S.service_dict(s, lang), status=201)
        for k, v in clean.items():
            setattr(s, k, v)
        s.save()
        return Response(S.service_dict(s, lang))

    def post(self, request, pk=None):
        return self._save(request, dict(request.data or {}), pk)

    def patch(self, request, pk=None):
        return self._save(request, dict(request.data or {}), pk)

    def delete(self, request, pk=None):
        from .models import BookingService
        lang = req_lang(request)
        biz, owner = _biz(request)
        if biz is None:
            return err(lang, "forbidden_business", 403)
        if not owner:
            return err(lang, "owner_only", 403)
        s = BookingService.objects.filter(business=biz, pk=pk).first()
        if s is None:
            return err(lang, "not_found", 404)
        if s.bookings.filter(status__in=L.ACTIVE).exists():
            s.active = False             # keep it for its open bookings
            s.save(update_fields=["active"])
        else:
            s.delete()
        return Response(status=204)


class BizStaffView(_Gated):
    def post(self, request, pk=None):
        from .models import BookingStaff
        lang = req_lang(request)
        biz, owner = _biz(request)
        if biz is None:
            return err(lang, "forbidden_business", 403)
        if not owner:
            return err(lang, "owner_only", 403)
        name = str((request.data or {}).get("name") or "").strip()[:80]
        if not name:
            return err(lang, "bad_input", 400, fields=["name"])
        if BookingStaff.objects.filter(business=biz).count() >= L.MAX_STAFF:
            return err(lang, "too_many", 409)
        s = BookingStaff.objects.create(business=biz, name=name)
        return Response({"id": s.pk, "name": s.name, "active": s.active}, status=201)

    def patch(self, request, pk=None):
        from .models import BookingStaff
        lang = req_lang(request)
        biz, owner = _biz(request)
        if biz is None or not owner:
            return err(lang, "owner_only", 403)
        s = BookingStaff.objects.filter(business=biz, pk=pk).first()
        if s is None:
            return err(lang, "not_found", 404)
        d = request.data or {}
        if "name" in d and str(d["name"]).strip():
            s.name = str(d["name"]).strip()[:80]
        if "active" in d:
            s.active = bool(d["active"])
        s.save()
        return Response({"id": s.pk, "name": s.name, "active": s.active})

    def delete(self, request, pk=None):
        from .models import BookingStaff
        lang = req_lang(request)
        biz, owner = _biz(request)
        if biz is None or not owner:
            return err(lang, "owner_only", 403)
        s = BookingStaff.objects.filter(business=biz, pk=pk).first()
        if s is None:
            return err(lang, "not_found", 404)
        if s.bookings.filter(status__in=L.ACTIVE, start__gt=timezone.now()).exists():
            s.active = False
            s.save(update_fields=["active"])
        else:
            s.delete()
        return Response(status=204)


class BizBookingsView(_Gated):
    def get(self, request):
        from datetime import timedelta
        from .models import Booking
        lang = req_lang(request)
        biz, _owner = _biz(request)
        if biz is None:
            return err(lang, "forbidden_business", 403)
        now = timezone.now()
        scope = request.query_params.get("scope", "today")
        qs = Booking.objects.filter(business=biz).select_related("staff", "business")
        if scope in ("today", "day"):
            day = _parse_day(request.query_params.get("day"), now) if scope == "day" else L.local(now).date()
            a = datetime.combine(day, datetime.min.time(), tzinfo=L.TZ)
            qs = qs.filter(start__gte=a, start__lt=a + timedelta(days=1)).order_by("start")
        elif scope == "upcoming":
            qs = qs.filter(start__gte=now, status__in=L.ACTIVE).order_by("start")
        elif scope == "pending":
            qs = qs.filter(start__gte=now, status="requested").order_by("start")
        else:
            qs = qs.filter(start__lt=now).order_by("-start")
        rows = [S.booking_dict(b, lang, True, now) for b in qs[:200]]
        return Response({"scope": scope, "bookings": rows})

    def post(self, request):
        """The business adds a phone-call / walk-in booking itself."""
        from .models import BookingService
        from . import otp
        lang = req_lang(request)
        biz, _owner = _biz(request)
        if biz is None:
            return err(lang, "forbidden_business", 403)
        page = S.page_for(biz)
        d = request.data or {}
        svc = BookingService.objects.filter(business=biz, pk=d.get("service") or 0).first()
        start = _parse_start(d.get("start"))
        if svc is None or start is None:
            return err(lang, "bad_input", 400)
        phone = otp.normalize_bd_phone(d.get("phone")) if d.get("phone") else ""
        if d.get("phone") and not phone:
            return err(lang, "bad_phone", 400)
        try:
            b, _raw = S.create(page, svc, start, name=str(d.get("name") or "")[:80], phone=phone,
                               staff_id=d.get("staff") or None, channel="manual", actor="business",
                               note=str(d.get("note") or ""))
        except S.BookingError as e:
            return err(lang, e.code, e.status)
        return Response(S.booking_dict(b, lang, True), status=201)


class BizBookingView(_Gated):
    def get(self, request, pk):
        from .models import Booking
        lang = req_lang(request)
        biz, _owner = _biz(request)
        b = Booking.objects.filter(business=biz, pk=pk).first() if biz else None
        if b is None:
            return err(lang, "not_found", 404)
        d = S.booking_dict(b, lang, True)
        d["history"] = b.history[-20:]
        return Response(d)


class BizBookingActionView(_Gated):
    def post(self, request, pk):
        from .models import Booking
        lang = req_lang(request)
        biz, _owner = _biz(request)
        b = Booking.objects.filter(business=biz, pk=pk).first() if biz else None
        if b is None:
            return err(lang, "not_found", 404)
        action = str((request.data or {}).get("action") or "")
        try:
            if action == "reschedule":
                start = _parse_start(request.data.get("start"))
                if start is None:
                    return err(lang, "bad_input", 400)
                S.reschedule(b, start, "business", staff_id=request.data.get("staff") or None)
            elif action in ("confirmed", "done", "no_show", "cancelled"):
                S.transition(b, action, "business")
            else:
                return err(lang, "bad_input", 400)
        except S.BookingError as e:
            return err(lang, e.code, e.status)
        b.refresh_from_db()
        return Response(S.booking_dict(b, lang, True))


class BizSlotsView(_Gated):
    def get(self, request):
        from .models import Booking, BookingService
        lang = req_lang(request)
        biz, _owner = _biz(request)
        if biz is None:
            return err(lang, "forbidden_business", 403)
        page = S.page_for(biz)
        svc = BookingService.objects.filter(business=biz, pk=request.query_params.get("service") or 0).first()
        if svc is None:
            return err(lang, "bad_service", 404)
        now = timezone.now()
        ex = None
        if request.query_params.get("exclude"):
            ex = Booking.objects.filter(business=biz, pk=request.query_params.get("exclude")).first()
        day = _parse_day(request.query_params.get("day"), now)
        rows = S.slots(page, svc, day, now=now, exclude=ex)
        return Response({"day": day.isoformat(), "slots": [S.slot_dict(s, lang) for s in rows]})


class BizBlocksView(_Gated):
    def get(self, request):
        from .models import BookingContact
        lang = req_lang(request)
        biz, _owner = _biz(request)
        if biz is None:
            return err(lang, "forbidden_business", 403)
        rows = BookingContact.objects.filter(business=biz, blocked=True).order_by("-updated_at")[:200]
        return Response({"blocked": [{"phone": c.phone} for c in rows]})

    def post(self, request):
        from . import otp
        lang = req_lang(request)
        biz, _owner = _biz(request)
        if biz is None:
            return err(lang, "forbidden_business", 403)
        phone = otp.normalize_bd_phone((request.data or {}).get("phone"))
        if not phone:
            return err(lang, "bad_phone", 400)
        blocked = bool((request.data or {}).get("blocked", True))
        S.set_contact(biz, phone, blocked=blocked)
        return Response({"phone": phone, "blocked": blocked})


# =================================================================== public
def _public_page(request, slug):
    """(page, None) or (None, error Response). Gated on the OWNER's flag."""
    from .models import BookingPage
    lang = req_lang(request)
    page = BookingPage.objects.filter(slug=str(slug)[:40]).select_related("business__user").first()
    if page is None or not _on(request, page.business.user):
        return None, err(lang, "not_found", 404)
    return page, None


def _taking(page):
    return page.enabled and not S.ready_problems(page) and S.business_plan_ok(page.business.user)


class PublicPageView(APIView):
    permission_classes = [AllowAny]

    def get(self, request, slug):
        lang = req_lang(request)
        page, bad = _public_page(request, slug)
        if bad:
            return bad
        d = _page_dict(page, lang, owner_view=False)
        d.pop("weekly_hours", None)
        d["hours"] = page.weekly_hours or {}
        d["taking_bookings"] = _taking(page)
        d["needs_otp"] = not request.user.is_authenticated
        d["sms_available"] = _sms_available()
        return Response(d)


class PublicDaysView(APIView):
    permission_classes = [AllowAny]

    def get(self, request, slug):
        from .models import BookingService
        lang = req_lang(request)
        page, bad = _public_page(request, slug)
        if bad:
            return bad
        svc = BookingService.objects.filter(business=page.business, active=True,
                                            pk=request.query_params.get("service") or 0).first()
        if svc is None:
            return err(lang, "bad_service", 404)
        if not _taking(page):
            return err(lang, "not_taking_bookings", 409)
        return Response({"days": [{"day": d, "free": n} for d, n in S.available_days(page, svc)]})


class PublicSlotsView(APIView):
    permission_classes = [AllowAny]

    def get(self, request, slug):
        from .models import BookingService
        lang = req_lang(request)
        page, bad = _public_page(request, slug)
        if bad:
            return bad
        svc = BookingService.objects.filter(business=page.business, active=True,
                                            pk=request.query_params.get("service") or 0).first()
        if svc is None:
            return err(lang, "bad_service", 404)
        if not _taking(page):
            return err(lang, "not_taking_bookings", 409)
        now = timezone.now()
        day = _parse_day(request.query_params.get("day"), now)
        rows = S.slots(page, svc, day, now=now)
        return Response({"day": day.isoformat(), "slots": [S.slot_dict(s, lang) for s in rows]})


class PublicOtpView(APIView):
    permission_classes = [AllowAny]

    def post(self, request, slug):
        from . import otp
        lang = req_lang(request)
        page, bad = _public_page(request, slug)
        if bad:
            return bad
        if not _taking(page):
            return err(lang, "not_taking_bookings", 409)
        canon = otp.normalize_bd_phone((request.data or {}).get("phone"))
        if not canon:
            return err(lang, "bad_phone", 400)
        c = S.contact(page.business, canon)
        if c and c.blocked:
            return err(lang, "blocked", 403)
        try:
            out = otp.issue(canon, "booking", request=request, lang=lang)
        except otp.OtpError as e:
            if e.reason == "sms_not_configured":
                return err(lang, "sms_off", 503)
            return Response(e.body(lang), status=e.http_status)
        return Response({"ok": True, "phone_masked": out.get("phone_masked"),
                         "expires_in": out.get("expires_in"), "resend_in": out.get("resend_in")})


def book_public(request, page, data, lang):
    """Shared by the API and the web page. -> (booking, raw token) or raises
    S.BookingError / returns error code via BookingError."""
    from . import otp
    from .models import BookingService
    if not _taking(page):
        raise S.BookingError("not_taking_bookings", 409)
    svc = BookingService.objects.filter(business=page.business, active=True,
                                        pk=data.get("service") or 0).first()
    start = _parse_start(data.get("start"))
    if svc is None or start is None:
        raise S.BookingError("bad_service", 400)
    name = str(data.get("name") or "").strip()[:80]
    user = request.user if getattr(request.user, "is_authenticated", False) else None
    if user is not None:
        phone = otp.user_phone(user) or otp.normalize_bd_phone(data.get("phone")) or ""
        name = name or (user.name or "")[:80]
        channel = "app"
    else:
        phone = otp.normalize_bd_phone(data.get("phone")) or ""
        if not phone:
            raise S.BookingError("bad_phone", 400)
        if not name:
            raise S.BookingError("bad_input", 400)
        code = str(data.get("code") or "").strip()
        if not code:
            raise S.BookingError("otp_required", 401)
        c = S.contact(page.business, phone)
        if c and c.blocked:
            raise S.BookingError("blocked", 403)
        try:
            proof = otp.verify(phone, "booking", code)
        except otp.OtpError:
            raise S.BookingError("bad_code", 400)
        if not otp.consume_proof(proof, "booking", phone):
            raise S.BookingError("bad_code", 400)
        channel = "web"
    return S.create(page, svc, start, name=name, phone=phone, user=user,
                    staff_id=data.get("staff") or None, channel=channel,
                    ip_hash=S.hash_ip(otp.client_ip(request)), actor="customer",
                    note=str(data.get("note") or "")[:300])


class PublicBookView(APIView):
    permission_classes = [AllowAny]

    def post(self, request, slug):
        lang = req_lang(request)
        page, bad = _public_page(request, slug)
        if bad:
            return bad
        try:
            b, raw = book_public(request, page, request.data or {}, lang)
        except S.BookingError as e:
            return err(lang, e.code, e.status)
        d = S.booking_dict(b, lang, for_business=False)
        d["manage_token"] = raw
        return Response(d, status=201)


# =================================================================== customer
def _my_bookings(user):
    from django.db.models import Q
    from .models import Booking, PhoneVerification
    q = Q(customer_user=user)
    pv = PhoneVerification.objects.filter(user=user).first()
    if pv and pv.phone:
        q |= Q(customer_phone=pv.phone)      # an OTP-proven number only
    return Booking.objects.filter(q).select_related("business", "staff")


class MyBookingsView(_Gated):
    def get(self, request):
        lang = req_lang(request)
        now = timezone.now()
        rows = list(_my_bookings(request.user).order_by("-start")[:100])
        up = sorted([b for b in rows if b.start >= now and b.status in L.ACTIVE], key=lambda b: b.start)
        past = [b for b in rows if b not in up]
        return Response({"upcoming": [S.booking_dict(b, lang, False, now) for b in up],
                         "past": [S.booking_dict(b, lang, False, now) for b in past[:50]]})


class MyBookingActionView(_Gated):
    def post(self, request, pk):
        lang = req_lang(request)
        b = _my_bookings(request.user).filter(pk=pk).first()
        if b is None:
            return err(lang, "not_found", 404)
        action = str((request.data or {}).get("action") or "")
        try:
            if action == "cancelled":
                S.transition(b, "cancelled", "customer")
            elif action == "reschedule":
                start = _parse_start(request.data.get("start"))
                if start is None:
                    return err(lang, "bad_input", 400)
                S.reschedule(b, start, "customer")
            else:
                return err(lang, "bad_input", 400)
        except S.BookingError as e:
            return err(lang, e.code, e.status)
        b.refresh_from_db()
        return Response(S.booking_dict(b, lang, False))


class MySlotsView(_Gated):
    """Free times to move one of MY bookings to (same service)."""
    def get(self, request, pk):
        lang = req_lang(request)
        b = _my_bookings(request.user).filter(pk=pk).first()
        if b is None or b.service is None:
            return err(lang, "not_found", 404)
        page = S.page_for(b.business, create=False)
        now = timezone.now()
        day = _parse_day(request.query_params.get("day"), now)
        rows = S.slots(page, b.service, day, now=now, exclude=b)
        return Response({"day": day.isoformat(), "slots": [S.slot_dict(s, lang) for s in rows]})
