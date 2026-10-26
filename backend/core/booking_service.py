"""
booking_service.py — BOOKING BOT (big-week item I): the DB layer over the
pure rules in core.logic.booking. Views (core.booking_views, web /b/<slug>)
and the business AI agent (core.bizagent_service._compose) call ONLY this.

Hard rules kept here
  * DOUBLE BOOKING IS IMPOSSIBLE: create / reschedule run in one transaction
    and INSERT one BookingSlotLock per 5-minute granule per seat; the UNIQUE
    (business, resource, seat, at) constraint refuses the loser of any race.
  * Abuse limits (all bounded, admin-editable in Pricing → shop):
    per-IP bookings per hour, per-phone bookings per day, per-business online
    bookings per day, max PENDING bookings per phone per business (the
    business' own policy), blocked numbers.
  * Messages go to a customer ONLY about THEIR booking: confirmation / change
    / cancel, and at most MAX_REMINDERS reminders (24 h + 2 h), never in quiet
    hours (22:00-08:00), never after STOP. Chat replies use the existing
    official-channel sender (24 h window enforced there); SMS only through the
    configured gateway, only if the business switched it on, capped per day
    and paid from the business' credits (billing.charge "sms" → Profit Guard).
  * No cold calls, no marketing: nothing here ever messages a phone that has
    not booked.
"""
import hashlib
import logging
import secrets
from datetime import datetime, time, timedelta

from django.conf import settings
from django.db import IntegrityError, transaction
from django.utils import timezone

from .logic import booking as L

log = logging.getLogger("assisto.booking")

FLAG = "booking_bot"

KNOBS = {   # Pricing → shop (bounded in core.logic.pricing)
    "booking_ip_per_hour": 10,
    "booking_phone_per_day": 5,
    "booking_biz_per_day": 200,
    "booking_sms_per_biz_day": 50,
    "booking_max_reminders": 2,
}


class BookingError(Exception):
    def __init__(self, code, status=400):
        super().__init__(code)
        self.code = code
        self.status = status


def knob(key):
    from . import billing
    try:
        return int((billing.cfg().get("shop") or {}).get(key, KNOBS[key]))
    except Exception:
        return KNOBS[key]


def flag_on(user, play=False):
    try:
        from . import feature_flags as FF
        return FF.is_on(FLAG, user, play)
    except Exception:
        return False


def business_plan_ok(user):
    from . import plans
    from . import feature_flags as FF
    return plans.effective_plan(user) == "business" or FF.is_privileged(user)


def hash_ip(ip):
    return hashlib.sha256(((ip or "") + settings.SECRET_KEY[:8]).encode()).hexdigest() if ip else ""


def hash_token(raw):
    return hashlib.sha256(str(raw).encode()).hexdigest()


# ===================================================================== page
def _unique_slug(base):
    from .models import BookingPage
    base = L.clean_slug(base) or "shop"
    if len(base) < 3:
        base = (base + "-shop")[:40]
    slug, n = base, 1
    while BookingPage.objects.filter(slug=slug).exists():
        n += 1
        slug = ("%s-%d" % (base[:34], n))
    return slug


def page_for(business, create=True):
    from .models import BookingPage
    p = BookingPage.objects.filter(business=business).first()
    if p is None and create:
        name = business.shop_name or ("shop-%d" % business.pk)
        p = BookingPage.objects.create(business=business, slug=_unique_slug(name),
                                       title=business.shop_name or "")
    return p


def page_cfg(page):
    return {"weekly_hours": page.weekly_hours or {}, "days_off": page.days_off or [],
            "step_min": page.step_min, "min_notice_min": page.min_notice_min,
            "max_days_ahead": page.max_days_ahead, "capacity": page.capacity}


def ready_problems(page):
    """What still stops the page taking bookings (honest checklist)."""
    out = []
    if not page.business.booking_services.filter(active=True).exists():
        out.append("no_services")
    if not any((page.weekly_hours or {}).get(str(d)) for d in range(7)):
        out.append("no_hours")
    return out


def public_url(page):
    base = getattr(settings, "PUBLIC_BASE_URL", "") or "https://lifeassisto.com"
    return "%s/b/%s" % (base.rstrip("/"), page.slug)


# ===================================================================== slots
def _active_staff(business):
    return list(business.booking_staff.filter(active=True))


def resources_for(page, service, staff_id=None):
    """[(resource id, seats)]: the staff who can do the service (seats 1 each),
    else the shared capacity as resource 0."""
    staff = _active_staff(page.business)
    if staff:
        allowed = [s for s in staff if not service.staff_ids or s.pk in service.staff_ids]
        if staff_id:
            allowed = [s for s in allowed if s.pk == int(staff_id)]
        return [(s.pk, 1) for s in allowed]
    return [(0, max(1, page.capacity))]


def _busy(business, t0, t1, exclude=None):
    from .models import Booking
    qs = Booking.objects.filter(business=business, status__in=L.ACTIVE,
                                start__lt=t1, block_end__gt=t0)
    if exclude is not None:
        qs = qs.exclude(pk=exclude.pk)
    busy = {}
    for b in qs:
        busy.setdefault(b.staff_id or 0, []).append((b.start, b.block_end))
    return busy


def _day_bounds(day):
    a = datetime.combine(day, time(0, 0), tzinfo=L.TZ)
    return a, a + timedelta(days=1, hours=8)     # + spill of a long buffer


def slots(page, service, day, now=None, staff_id=None, exclude=None, limit=L.MAX_SLOTS_SHOWN):
    now = now or timezone.now()
    res = resources_for(page, service, staff_id)
    t0, t1 = _day_bounds(day)
    busy = _busy(page.business, t0, t1, exclude=exclude)
    return L.free_slots(day, now, page_cfg(page), {"duration_min": service.duration_min,
                                                   "buffer_min": service.buffer_min},
                        res, busy, limit=limit)


def next_slots(page, service, now=None, n=L.BOT_OPTIONS, from_day=None, days=7):
    now = now or timezone.now()
    day = from_day or L.local(now).date()
    out = []
    for i in range(days):
        d = day + timedelta(days=i)
        if not L.bookable_day(d, now, page_cfg(page)):
            break
        out.extend(slots(page, service, d, now=now, limit=n - len(out)))
        if len(out) >= n:
            break
    return out[:n]


def available_days(page, service, now=None, days=None):
    """[(date iso, n free)] for the booking horizon (max 31 days computed)."""
    now = now or timezone.now()
    cfg = page_cfg(page)
    days = min(days or cfg["max_days_ahead"] + 1, 31)
    today = L.local(now).date()
    out = []
    for i in range(days):
        d = today + timedelta(days=i)
        if not L.bookable_day(d, now, cfg):
            break
        n = len(slots(page, service, d, now=now))
        out.append((d.isoformat(), n))
    return out


# ===================================================================== locks
def _try_lock(booking, rid, seats):
    from .models import BookingSlotLock
    grains = L.granules(booking.start, booking.block_end)
    for seat in range(seats):
        try:
            with transaction.atomic():
                BookingSlotLock.objects.bulk_create([
                    BookingSlotLock(booking=booking, business_id=booking.business_id,
                                    resource=rid, seat=seat, at=g) for g in grains])
            return True
        except IntegrityError:
            continue
    return False


def _place(page, booking, service, staff_id=None):
    """Lock a seat for booking.start; sets booking.staff. False when taken."""
    for rid, seats in resources_for(page, service, staff_id):
        if _try_lock(booking, rid, seats):
            if rid and booking.staff_id != rid:
                booking.staff_id = rid
                booking.save(update_fields=["staff"])
            return True
    return False


def _hist(b, by, what, **kw):
    h = list(b.history or [])[-40:]
    h.append(dict({"at": timezone.now().isoformat(), "by": by, "what": what}, **kw))
    b.history = h


# ===================================================================== create
def contact(business, phone):
    from .models import BookingContact
    if not phone:
        return None
    return BookingContact.objects.filter(business=business, phone=phone).first()


def _check_limits(page, phone, ip_hash, now, actor):
    from .models import Booking
    biz = page.business
    c = contact(biz, phone)
    if c and c.blocked and actor != "business":
        raise BookingError("blocked", 403)
    if actor == "business":
        return
    if phone:
        pending = Booking.objects.filter(business=biz, customer_phone=phone,
                                         status__in=L.ACTIVE, start__gt=now).count()
        if pending >= page.max_pending_per_phone:
            raise BookingError("too_many_pending", 429)
        if Booking.objects.filter(customer_phone=phone,
                                  created_at__gt=now - timedelta(days=1)).count() \
                >= knob("booking_phone_per_day"):
            raise BookingError("rate_limited", 429)
    if ip_hash and Booking.objects.filter(ip_hash=ip_hash,
                                          created_at__gt=now - timedelta(hours=1)).count() \
            >= knob("booking_ip_per_hour"):
        raise BookingError("rate_limited", 429)
    day0 = datetime.combine(L.local(now).date(), time(0, 0), tzinfo=L.TZ)
    if Booking.objects.filter(business=biz, created_at__gte=day0).exclude(
            channel="manual").count() >= knob("booking_biz_per_day"):
        raise BookingError("daily_cap", 429)


def _valid_start(page, service, start, now, staff_id=None, exclude=None):
    day = L.local(start).date()
    for s in slots(page, service, day, now=now, staff_id=staff_id, exclude=exclude,
                   limit=10_000):
        if s["start"] == start:
            return True
    return False


def create(page, service, start, *, name="", phone="", user=None, staff_id=None,
           channel="web", thread=None, ip_hash="", actor="customer", note="", now=None):
    """-> (booking, raw manage token). Raises BookingError(code)."""
    from .models import Booking
    now = now or timezone.now()
    if service is None or service.business_id != page.business_id or not service.active:
        raise BookingError("bad_service", 400)
    if actor != "business" and not page.enabled:
        raise BookingError("not_taking_bookings", 409)
    if start.tzinfo is None:
        start = start.replace(tzinfo=L.TZ)
    start = start.astimezone(L.TZ)
    _check_limits(page, phone, ip_hash, now, actor)
    if not _valid_start(page, service, start, now, staff_id=staff_id):
        raise BookingError("slot_taken", 409)
    raw = secrets.token_urlsafe(18)
    end = start + timedelta(minutes=service.duration_min)
    with transaction.atomic():
        b = Booking.objects.create(
            business=page.business, service=service, service_name=service.name,
            customer_user=user, customer_name=(name or "")[:80],
            customer_phone=phone or "", start=start, end=end,
            block_end=end + timedelta(minutes=service.buffer_min),
            status="confirmed" if (page.auto_confirm or actor == "business") else "requested",
            channel=channel[:20], thread=thread, note=(note or "")[:300], ip_hash=ip_hash,
            manage_hash=hash_token(raw))
        if not _place(page, b, service, staff_id):
            raise _Rollback()
        _hist(b, actor, "created", status=b.status)
        b.save(update_fields=["history"])
    _after_create(b, actor)
    return b, raw


class _Rollback(BookingError):
    def __init__(self):
        super().__init__("slot_taken", 409)


# ===================================================================== lifecycle
def transition(b, new, actor, now=None):
    from .models import BookingPage
    now = now or timezone.now()
    page = BookingPage.objects.filter(business=b.business).first()
    if actor == "customer":
        if not L.customer_window_open(b.start, now, page.cancel_hours if page else 0):
            raise BookingError("too_late", 409)
    if not L.can_move(b.status, new, actor):
        raise BookingError("bad_transition", 409)
    if new in ("done", "no_show") and now < b.start:
        raise BookingError("not_started", 409)
    old = b.status
    with transaction.atomic():
        b.status = new
        if new == "cancelled":
            b.cancelled_by = actor
            b.locks.all().delete()
        _hist(b, actor, new, was=old)
        b.save(update_fields=["status", "cancelled_by", "history", "updated_at"])
    _after_change(b, actor, new)
    return b


def reschedule(b, start, actor, now=None, staff_id=None):
    from .models import BookingPage
    now = now or timezone.now()
    page = BookingPage.objects.filter(business=b.business).first()
    if b.status not in L.ACTIVE or page is None or b.service is None:
        raise BookingError("bad_transition", 409)
    if actor == "customer" and not L.customer_window_open(b.start, now, page.cancel_hours):
        raise BookingError("too_late", 409)
    if actor == "customer" and b.reschedules >= 3:
        raise BookingError("too_many_reschedules", 429)
    if start.tzinfo is None:
        start = start.replace(tzinfo=L.TZ)
    start = start.astimezone(L.TZ)
    if not _valid_start(page, b.service, start, now, staff_id=staff_id, exclude=b):
        raise BookingError("slot_taken", 409)
    old = b.start
    try:
        with transaction.atomic():
            b.locks.all().delete()
            b.start = start
            b.end = start + timedelta(minutes=b.service.duration_min)
            b.block_end = b.end + timedelta(minutes=b.service.buffer_min)
            b.reschedules += 1
            b.reminded, b.reminders_sent = [], 0
            if actor == "customer" and not page.auto_confirm:
                b.status = "requested"
            b.save()
            if not _place(page, b, b.service, staff_id):
                raise _Rollback()
            _hist(b, actor, "rescheduled", old=old.isoformat())
            b.save(update_fields=["history"])
    except BookingError:
        b.refresh_from_db()
        raise
    _after_change(b, actor, "rescheduled")
    return b


def set_contact(business, phone, **fields):
    from .models import BookingContact
    c, _ = BookingContact.objects.get_or_create(business=business, phone=phone)
    for k, v in fields.items():
        setattr(c, k, v)
    c.save()
    return c


# ===================================================================== notify
def _owner_note(b, title_bn, title_en, body_bn, body_en):
    from . import push
    from .models import NotifEvent
    owner = b.business.user
    try:
        NotifEvent.objects.create(user=owner, type="business", title_bn=title_bn[:200],
                                  title_en=title_en[:200], body_bn=body_bn, body_en=body_en,
                                  route="booking", meta={"booking_id": b.pk})
    except Exception:
        log.warning("booking: notif event failed")
    push.safe_push(owner, "reminder", title_bn, title_en, body_bn, body_en,
                   data={"route": "booking", "booking_id": str(b.pk)})


def _customer_note(b, text_bn, text_en, chat=True):
    """In-app (push + notification centre) for an Assisto customer, and the
    originating chat (official channel; 24 h window enforced by send_text)."""
    from . import push
    from .models import NotifEvent
    sent = []
    u = b.customer_user
    if u is not None:
        try:
            NotifEvent.objects.create(user=u, type="business", title_bn=b.business.shop_name[:200] or "বুকিং",
                                      title_en=b.business.shop_name[:200] or "Booking",
                                      body_bn=text_bn, body_en=text_en, route="my_bookings",
                                      meta={"booking_id": b.pk})
            sent.append("inapp")
        except Exception:
            pass
        if push.safe_push(u, "reminder", b.business.shop_name or "Assisto", b.business.shop_name or "Assisto",
                          text_bn, text_en, data={"route": "my_bookings", "booking_id": str(b.pk)}):
            sent.append("push")
    t = b.thread
    if chat and t is not None and not t.opted_out:
        from . import bizagent_service as BS
        m = BS.send_text(t, text_en if t.lang == "en" else text_bn, kind="text", is_ai=True,
                         source="system", meta={"booking_id": b.pk})
        if m.status in ("sent", "delivered", "read"):
            sent.append("chat")
    return sent


def _biz_name(b):
    return b.business.shop_name or "Assisto"


def _after_create(b, actor):
    if actor == "business":
        return
    w_bn, w_en = L.when_text("bn", b.start), L.when_text("en", b.start)
    who = b.customer_name or b.customer_phone or "—"
    if b.status == "requested":
        _owner_note(b, "নতুন বুকিং অনুরোধ", "New booking request",
                    "%s — %s, %s। নিশ্চিত করুন।" % (who, b.service_name, w_bn),
                    "%s — %s, %s. Please confirm." % (who, b.service_name, w_en))
    else:
        _owner_note(b, "নতুন বুকিং", "New booking",
                    "%s — %s, %s" % (who, b.service_name, w_bn),
                    "%s — %s, %s" % (who, b.service_name, w_en))
    _crm_lead(b)


def _after_change(b, actor, what):
    if actor == "customer":
        w_bn, w_en = L.when_text("bn", b.start), L.when_text("en", b.start)
        who = b.customer_name or b.customer_phone or "—"
        if what == "cancelled":
            _owner_note(b, "বুকিং বাতিল", "Booking cancelled",
                        "%s বাতিল করেছেন: %s, %s" % (who, b.service_name, w_bn),
                        "%s cancelled: %s, %s" % (who, b.service_name, w_en))
        else:
            _owner_note(b, "বুকিংয়ের সময় বদল", "Booking moved",
                        "%s নতুন সময় চেয়েছেন: %s, %s" % (who, b.service_name, w_bn),
                        "%s moved to: %s, %s" % (who, b.service_name, w_en))
        return
    if actor == "business" and what in ("confirmed", "cancelled", "rescheduled"):
        _customer_note(b, L.status_message("bn", what, b.service_name, b.start, _biz_name(b)),
                       L.status_message("en", what, b.service_name, b.start, _biz_name(b)))


def _crm_lead(b):
    """Plan item I: a booking is a lead for the business' CRM (best-effort;
    the business' own customer, never shared). Only when the owner already
    runs a CRM org; one lead per phone, never a duplicate."""
    if not b.customer_phone:
        return
    try:
        from crm.models import CrmOrg, Lead
        org = CrmOrg.objects.filter(owner_id=b.business.user_id).order_by("id").first()
        if org is None:
            return
        from . import otp
        local_ph = otp.local_form(b.customer_phone)
        if Lead.objects.filter(org=org, phone__in=[b.customer_phone, local_ph]).exists():
            return
        src = {"whatsapp_cloud": "whatsapp", "messenger": "messenger"}.get(b.channel, "manual")
        Lead.objects.create(org=org, name=b.customer_name[:120], phone=local_ph[:32],
                            source=src,
                            notes="Booking: %s — %s" % (b.service_name, L.when_text("en", b.start)))
    except Exception:
        log.warning("booking: crm lead failed")


# ===================================================================== reminders
def _sms_today(business, now):
    from .models import Booking
    day0 = datetime.combine(L.local(now).date(), time(0, 0), tzinfo=L.TZ)
    n = 0
    for h in Booking.objects.filter(business=business, updated_at__gte=day0).values_list(
            "history", flat=True):
        n += sum(1 for e in (h or []) if e.get("what") == "sms" and e.get("at", "") >= day0.isoformat())
    return n


def _send_sms(b, text, now):
    from . import billing, sms_gateway
    page = getattr(b.business, "booking_page", None)
    if page is None or not page.sms_reminders or not b.customer_phone:
        return False
    ad = sms_gateway.adapter()
    if ad is None:
        return False
    if _sms_today(b.business, now) >= knob("booking_sms_per_biz_day"):
        return False
    res = billing.charge(b.business.user, "sms", qty=1, note="booking.reminder")
    if not res.get("ok"):
        return False
    ok, _detail = ad.send(b.customer_phone, text)
    if not ok:
        billing.credit(b.business.user, "adjust", res.get("charged", 0), note="booking.sms_refund")
        return False
    _hist(b, "system", "sms")
    return True


def reminder_guard(b, now, max_reminders=None):
    """THE single customer-messaging guard for booking reminders (caps, quiet
    hours 22:00-08:00, STOP / chat opt-out). Returns (kind, allowed):
      kind    — "24h" | "2h" | None (nothing due: quiet hours, cap reached,
                too early / too late, booked too close to the start);
      allowed — False when the customer said STOP (the reminder is counted
                as used but never sent).
    Integrator note: switch this ONE function to a shared core.logic.msg_guard
    when that lands (item H); nothing else in booking decides who may be
    messaged. The 24 h Meta window is enforced by bizagent send_text."""
    if max_reminders is None:
        max_reminders = max(0, min(L.MAX_REMINDERS, knob("booking_max_reminders")))
    if L.in_quiet_hours(now):
        return None, False
    kind = L.due_reminder(b.start, b.created_at, now, list(b.reminded or []), max_reminders)
    if not kind:
        return None, False
    c = contact(b.business, b.customer_phone)
    stopped = bool(c and c.stop) or bool(b.thread and b.thread.opted_out)
    return kind, not stopped


def send_due_reminders(now=None, limit=500):
    """Run every few minutes (cron: manage.py booking_reminders). Returns the
    number of reminders that went out on at least one channel."""
    from .models import Booking
    now = now or timezone.now()
    if L.in_quiet_hours(now):
        return 0
    maxr = max(0, min(L.MAX_REMINDERS, knob("booking_max_reminders")))
    qs = (Booking.objects.filter(status="confirmed", start__gt=now,
                                 start__lte=now + timedelta(hours=24, minutes=10))
          .select_related("business", "business__user", "customer_user", "thread")[:limit])
    out = 0
    for b in qs:
        if not flag_on(b.business.user):
            continue
        kind, allowed = reminder_guard(b, now, maxr)
        if not kind:
            continue
        b.reminded = list(b.reminded or []) + [kind]
        b.reminders_sent += 1
        if not allowed:
            _hist(b, "system", "reminder_skipped_stop", kind=kind)
            b.save(update_fields=["reminded", "reminders_sent", "history"])
            continue
        tb = L.reminder_text("bn", kind, _biz_name(b), b.service_name, b.start, now)
        te = L.reminder_text("en", kind, _biz_name(b), b.service_name, b.start, now)
        sent = _customer_note(b, tb, te)
        if not sent:
            lang = (b.thread.lang if b.thread else "bn")
            if _send_sms(b, te if lang == "en" else tb, now):
                sent = ["sms"]
        _hist(b, "system", "reminder", kind=kind, via=sent)
        b.save(update_fields=["reminded", "reminders_sent", "history"])
        if sent:
            out += 1
    return out


# ===================================================================== serialise
def booking_dict(b, lang, for_business=True, now=None):
    now = now or timezone.now()
    page = getattr(b.business, "booking_page", None)
    d = {"id": b.pk, "service": b.service_name, "service_id": b.service_id,
         "staff": b.staff.name if b.staff_id and b.staff else "", "staff_id": b.staff_id,
         "start": L.local(b.start).isoformat(), "end": L.local(b.end).isoformat(),
         "status": b.status, "status_label": L.status_label(lang, b.status),
         "when": L.when_text(lang, b.start), "channel": b.channel,
         "customer_name": b.customer_name, "note": b.note,
         "reminders_sent": b.reminders_sent, "reschedules": b.reschedules,
         "business": {"id": b.business_id, "name": _biz_name(b),
                      "slug": page.slug if page else ""}}
    if for_business:
        # the customer's phone is visible ONLY to this business
        d["customer_phone"] = b.customer_phone
        d["thread_id"] = b.thread_id
        d["is_app_user"] = b.customer_user_id is not None
        c = contact(b.business, b.customer_phone)
        d["blocked"] = bool(c and c.blocked)
        d["stopped"] = bool(c and c.stop)
        d["can"] = [m for m in ("confirmed", "done", "no_show", "cancelled")
                    if L.can_move(b.status, m, "business")
                    and not (m in ("done", "no_show") and now < b.start)]
        if b.status in L.ACTIVE:
            d["can"].append("reschedule")
    else:
        open_ = page is not None and L.customer_window_open(b.start, now, page.cancel_hours)
        d["can"] = (["cancelled", "reschedule"] if b.status in L.ACTIVE and open_ else [])
        d["cancel_hours"] = page.cancel_hours if page else 0
    return d


def service_dict(s, lang):
    return {"id": s.pk, "name": s.name, "duration_min": s.duration_min,
            "buffer_min": s.buffer_min, "price_bdt": s.price_bdt,
            "staff_ids": list(s.staff_ids or []), "active": s.active}


def slot_dict(s, lang):
    return {"start": L.local(s["start"]).isoformat(), "end": L.local(s["end"]).isoformat(),
            "label": L.time_text(lang, s["start"]), "staff_ids": [r for r in s["resources"] if r]}


# ===================================================================== chat bot
def _bot_services(business):
    return list(business.booking_services.filter(active=True)[:9])


def bot_reply(business, thread, text, lang, now=None):
    """Called by the business AI agent BEFORE its order flow. Returns a
    compose()-shaped dict when this message belongs to a booking chat, else
    None. Every time offered comes from slots() — never invented. Cost 0
    (rule reply: no AI, no credits)."""
    now = now or timezone.now()
    if thread is None or not (text or "").strip():
        return None
    page = page_for(business, create=False)
    if page is None or not page.enabled or not page.chat_bot or not flag_on(business.user):
        return None
    draft = dict(thread.order_draft or {})
    st = dict(draft.get("bk") or {})
    if not st:
        if draft.get("active") and not L.wants_booking(text):
            return None            # an order chat: the order flow keeps it
        if L.is_cancel(text):
            r = _bot_cancel_existing(thread, lang, now)
            if r is not None or not L.wants_booking(text):
                return r
        if not L.wants_booking(text):
            return None
    services = _bot_services(business)
    if not services:
        return None

    def save(new):
        d = dict(thread.order_draft or {})
        if new:
            d["bk"] = new
        else:
            d.pop("bk", None)
        thread.order_draft = d
        thread.save(update_fields=["order_draft"])

    def out(t):
        return {"text": t, "kind": "text", "risk": None, "confidence": 1.0,
                "source": "rule", "rule": "booking"}

    if st and (L.is_cancel(text) or L.is_stop(text)) and st.get("step") != "confirm":
        save(None)
        return out(L.bot_cancelled(lang))

    today = L.local(now).date()
    step = st.get("step")
    if not step:
        if len(services) == 1:
            st = {"step": "slot", "service": services[0].pk}
            return _bot_offer(page, services[0], st, save, out, lang, now,
                              L.parse_day(text, today))
        save({"step": "service"})
        return out(L.bot_pick_service(lang, [service_dict(s, lang) for s in services]))

    if step == "service":
        i = L.pick_option(text, len(services))
        if not i:
            return out(L.bot_pick_service(lang, [service_dict(s, lang) for s in services]))
        st = {"step": "slot", "service": services[i - 1].pk}
        return _bot_offer(page, services[i - 1], st, save, out, lang, now, None)

    svc = next((s for s in services if s.pk == st.get("service")), None)
    if svc is None:
        save(None)
        return None

    if step == "slot":
        opts = st.get("slots") or []
        i = L.pick_option(text, len(opts))
        if not i:
            day = L.parse_day(text, today)
            return _bot_offer(page, svc, st, save, out, lang, now, day)
        st.update(step="name", start=opts[i - 1]["start"], staff=opts[i - 1].get("staff"))
        if thread.customer_name:
            st["name"] = thread.customer_name
            return _bot_after_name(st, svc, thread, save, out, lang)
        save(st)
        return out(L.bot_ask_name(lang))

    if step == "name":
        st["name"] = text.strip()[:80]
        return _bot_after_name(st, svc, thread, save, out, lang)

    if step == "phone":
        from .logic import bizagent as BZ
        ph = BZ.find_phone(text)
        canon = _canon(ph) if ph else ""
        if not canon:
            return out(L.bot_ask_phone(lang))
        st["phone"] = canon
        st["step"] = "confirm"
        save(st)
        return out(L.bot_confirm_q(lang, svc.name, datetime.fromisoformat(st["start"]), st["name"]))

    if step == "confirm":
        from .logic import bizagent as BZ
        if BZ.is_no(text):
            save(None)
            return out(L.bot_cancelled(lang))
        if not BZ.is_yes(text):
            return out(L.bot_confirm_q(lang, svc.name, datetime.fromisoformat(st["start"]), st["name"]))
        try:
            b, _raw = create(page, svc, datetime.fromisoformat(st["start"]),
                             name=st.get("name", ""), phone=st.get("phone", ""),
                             staff_id=st.get("staff") or None, channel=thread.channel,
                             thread=thread, actor="customer", now=now)
        except BookingError as e:
            if e.code == "slot_taken":
                st = {"step": "slot", "service": svc.pk}
                r = _bot_offer(page, svc, st, save, out, lang, now, None)
                r["text"] = L.bot_slot_gone(lang) + "\n" + r["text"]
                return r
            save(None)
            return out(L.bot_refused(lang, e.code))
        save(None)
        return out(L.bot_booked(lang, svc.name, b.start, b.status == "confirmed"))
    save(None)
    return None


def _canon(ph):
    from . import otp
    return otp.normalize_bd_phone(ph) or ""


def _bot_after_name(st, svc, thread, save, out, lang):
    phone = _canon(thread.customer_phone) if thread.customer_phone else ""
    if phone:
        st.update(phone=phone, step="confirm")
        save(st)
        return out(L.bot_confirm_q(lang, svc.name, datetime.fromisoformat(st["start"]), st["name"]))
    st["step"] = "phone"
    save(st)
    return out(L.bot_ask_phone(lang))


def _bot_offer(page, svc, st, save, out, lang, now, day):
    if day is not None:
        found = slots(page, svc, day, now=now, limit=L.BOT_OPTIONS)
    else:
        found = next_slots(page, svc, now=now)
    if not found:
        st.pop("slots", None)
        save(dict(st, step="slot"))
        return out(L.bot_no_slots(lang, svc.name))
    st.update(step="slot", slots=[{"start": L.local(s["start"]).isoformat(),
                                   "staff": (s["resources"][0] or None)} for s in found])
    save(st)
    return out(L.bot_offer_slots(lang, svc.name, found))


def _bot_cancel_existing(thread, lang, now):
    from .models import Booking
    b = (Booking.objects.filter(thread=thread, status__in=L.ACTIVE, start__gt=now)
         .order_by("start").first())
    if b is None:
        return None
    try:
        transition(b, "cancelled", "customer", now=now)
    except BookingError:
        return {"text": L.pick(lang, "বুকিং শুরুর খুব কাছাকাছি — বাতিল করতে সরাসরি ব্যবসার সাথে যোগাযোগ করুন।",
                               "It is too close to the start — please contact the business to cancel."),
                "kind": "text", "risk": None, "confidence": 1.0, "source": "rule", "rule": "booking"}
    return {"text": L.bot_booking_cancelled(lang, b.service_name, b.start), "kind": "text",
            "risk": None, "confidence": 1.0, "source": "rule", "rule": "booking"}


def note_chat_stop(thread):
    """The customer said STOP in a chat: no more booking reminders for the
    phone(s) this chat booked with."""
    from .models import Booking
    try:
        for ph in set(Booking.objects.filter(thread=thread).exclude(customer_phone="")
                      .values_list("customer_phone", flat=True)):
            set_contact(thread.business, ph, stop=True)
    except Exception:
        log.warning("booking: chat stop failed")
