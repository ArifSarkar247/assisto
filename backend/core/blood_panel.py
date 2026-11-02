"""
Blood donor panel ("রক্তদাতা প্যানেল", owner 2 Nov) — the service. Behind the
flag `blood_donors` (OFF). Views: core/blood_views.py. Pure rules + every
number: core/logic/blood_rules.py. Owner Admin: web/owner/views_blood.py.

PRIVACY (server-enforced):
  * A donor is listed ONLY after a SEPARATE consent on the donor page (the
    Family card's blood group stays on the phone and is never read here).
  * Strangers see: first name, blood group, area NAME + rounded distance
    (whole km), "can donate now / again on <date>", the verified badge. Never
    the exact point, never the address; phone / e-mail only when the donor
    switched "make public" on.
  * Contact = a private in-app thread (no numbers). My Circle = a REQUEST the
    donor accepts or declines (never auto-added). App calls work after that.

URGENT REQUEST PUSH (no background location): donors who opted in, are
"available", are ELIGIBLE by the needed-by date, whose group can give to the
requested group, and whose coarse area is within the request radius (+ the
district fuzz when only a district is known). Exact group first, nearest
first; one push per request per donor, at most MAX_PUSH_PER_DONOR_DAY per
donor per 24 h and MAX_PUSH_PER_REQUEST per request (the rest see it in the
app). Requests auto-expire EXPIRE_AFTER_NEEDED_H after needed-by; 3
independent fake reports hide a request until the owner reviews it.
"""
import base64
import binascii
import io
import logging
import secrets
import threading
from datetime import timedelta

from django.conf import settings
from django.core.files.base import ContentFile
from django.db import transaction
from django.db.models import Q
from django.utils import timezone

from .logic import blood_rules as BR
from .logic import missing_rules as MR

log = logging.getLogger(__name__)

FLAG = "blood_donors"
ROUTE = "blood_panel"


def flag_on(user):
    try:
        from . import feature_flags as FF
        return bool(FF.is_on(FLAG, user))
    except Exception:
        return False


def now():
    return timezone.now()


def today():
    return timezone.localdate()


def log_event(kind, request=None, actor=None, **meta):
    try:
        from .models import BloodEvent
        BloodEvent.objects.create(request=request, actor=actor, kind=kind[:24],
                                  meta={k: v for k, v in meta.items() if v is not None})
    except Exception as e:
        log.warning("blood: event log failed %s", type(e).__name__)


# ------------------------------------------------------------------ push
def _send_push(user, kind, title_bn, title_en, body_bn, body_en, data, high=False):
    """One visible push. Patched in tests."""
    from . import push
    return push.push_to_user(user, kind, title_bn, title_en, body_bn, body_en,
                             data=data, high_priority=high)


def _inapp(user, title_bn, title_en, body_bn, body_en, meta):
    try:
        from .models import NotifEvent
        NotifEvent.objects.create(user=user, type="family_alert", title_bn=title_bn[:200],
                                  title_en=title_en[:200], body_bn=body_bn, body_en=body_en,
                                  route=ROUTE, meta=dict(meta))
    except Exception as e:
        log.warning("blood: in-app row failed %s", type(e).__name__)


def notify(user, event, tbn, ten, bbn, ben, push_it=True, high=False, kind="family_alert",
           **ids):
    data = {"route": ROUTE, "event": event}
    data.update({k: v for k, v in ids.items() if v is not None})
    _inapp(user, tbn, ten, bbn, ben, data)
    if push_it:
        try:
            return _send_push(user, kind, tbn, ten, bbn, ben, data, high=high) > 0
        except Exception:
            return False
    return False


def _run_bg(fn, *args):
    """Fan-outs run in ONE background thread (sequential sends, never a flood
    in front of SOS / calls). Inline under PUSH_SYNC (tests)."""
    if getattr(settings, "PUSH_SYNC", False):
        fn(*args)
        return

    def run():
        from django.db import close_old_connections, connection
        try:
            close_old_connections()
            fn(*args)
        except Exception as e:
            log.warning("blood: fan-out failed %s", type(e).__name__)
        finally:
            try:
                connection.close()
            except Exception:
                pass

    transaction.on_commit(lambda: threading.Thread(target=run, daemon=True,
                                                   name="blood-fanout").start())


# ------------------------------------------------------------------ donor profile
def get_donor(user):
    from .models import BloodDonor
    return BloodDonor.objects.filter(user=user).first()


def eligibility(d, on_day=None):
    on_day = on_day or today()
    nxt = BR.next_eligible(d.last_donation, d.sex) if d else None
    return {"eligible": nxt is None or nxt <= on_day,
            "next_date": nxt.isoformat() if nxt else None,
            "interval_days": BR.interval_days(d.sex if d else "")}


def donor_json(d, lang="bn"):
    """The donor's OWN view of their profile."""
    if d is None:
        return {"enabled": False, "consented": False}
    dist = MR.district(d.district)
    out = {"enabled": d.enabled, "consented": bool(d.consent_at),
           "consent_version": d.consent_version, "blood_group": d.blood_group,
           "sex": d.sex, "last_donation": d.last_donation.isoformat() if d.last_donation else None,
           "available": d.available, "district": d.district,
           "district_name": (dist[2] if lang == "bn" else dist[1]) if dist else "",
           "area_text": d.area_text, "has_point": d.lat is not None,
           "phone_public": d.phone_public, "email_public": d.email_public,
           "verified": bool(d.verified_at), "verification": verification_state(d.user)}
    out.update(eligibility(d))
    return out


def verification_state(user):
    from .models import BloodVerification
    v = BloodVerification.objects.filter(user=user).order_by("-id").first()
    return v.state if v else ""


def save_donor(user, body, at=None):
    """Create / update the donor profile. -> (donor, error, fields).
    Turning ON needs consent + group + an area. Turning OFF is never gated."""
    from .models import BloodDonor
    at = at or now()
    d = get_donor(user) or BloodDonor(user=user)
    fields = []
    if "blood_group" in body:
        g = BR.normalise_group(body.get("blood_group"))
        if not g:
            fields.append("blood_group")
        d.blood_group = g or d.blood_group
    if "sex" in body:
        s = str(body.get("sex") or "").strip().lower()[:1]
        d.sex = s if s in ("m", "f") else ""
    if "last_donation" in body:
        ld, ok = BR.clean_last_donation(body.get("last_donation"), today())
        if not ok:
            fields.append("last_donation")
        else:
            if ld != d.last_donation:
                d.reminded_for = None
            d.last_donation = ld
    if "district" in body:
        code = str(body.get("district") or "").strip().lower()
        d.district = code if MR.district(code) else ""
    if "area_text" in body:
        txt = BR.clean_text(body.get("area_text"), 60)
        if MR.looks_like_address(txt) or BR.has_contact(txt):
            fields.append("area_text")
        else:
            d.area_text = txt
    if body.get("clear_point") is True:
        d.lat = d.lng = None
    if body.get("lat") is not None:
        la, ln = MR.coarse(body.get("lat")), MR.coarse(body.get("lng"))
        if MR.in_bangladesh(la, ln):
            d.lat, d.lng = la, ln
            if not d.district:
                d.district = MR.nearest_district(la, ln)
        else:
            fields.append("location")
    for b in ("phone_public", "email_public", "available"):
        if b in body:
            setattr(d, b, body.get(b) is True)
    if fields:
        return None, "invalid", fields
    if body.get("consent") is True:
        d.consent_at, d.consent_version = at, BR.CONSENT_VERSION
    if "enabled" in body:
        want = body.get("enabled") is True
        if want:
            if not d.consent_at or d.consent_version < BR.CONSENT_VERSION:
                return None, "consent_required", []
            if not d.blood_group:
                return None, "invalid", ["blood_group"]
            if not (d.district or d.lat is not None):
                return None, "area_required", []
        d.enabled = want
    was_new = d.pk is None
    d.save()
    if was_new or "enabled" in body:
        log_event("donor_on" if d.enabled else "donor_off", None, user)
    return d, None, []


def leave(user):
    """Leave the panel: the profile row (group, area, dates, consent) is
    deleted; pending slip photos too. Never flag-gated."""
    from .models import BloodDonor, BloodVerification
    for v in BloodVerification.objects.filter(user=user):
        _delete_slip(v, "donor_left")
        if v.state == "pending":
            v.state = "withdrawn"
        v.save(update_fields=["photo", "state"])
    n = BloodDonor.objects.filter(user=user).delete()[0]
    log_event("donor_left", None, user)
    return n > 0


def mark_donated(user, on_day=None):
    """The donor gave blood today (or on_day): resets the clock."""
    d = get_donor(user)
    if d is None:
        return None
    d.last_donation = on_day or today()
    d.reminded_for = None
    d.save(update_fields=["last_donation", "reminded_for", "updated_at"])
    return d


# ------------------------------------------------------------------ search
def _searches_today(user, at):
    from .models import BloodEvent
    return BloodEvent.objects.filter(actor=user, kind="search",
                                     at__gte=at - timedelta(hours=24)).count()


def public_card(d, viewer_area, lang="bn", on_day=None):
    """What another user sees of a donor. Coarse only."""
    u = d.user
    dist = MR.district(d.district)
    _ok, km = BR.within(viewer_area, BR.area_of(d.lat, d.lng, d.district), 10 ** 6)
    el = eligibility(d, on_day)
    out = {"id": d.id, "name": BR.first_name(u.name) or ("দাতা" if lang == "bn" else "Donor"),
           "blood_group": d.blood_group, "area_text": d.area_text,
           "district_name": (dist[2] if lang == "bn" else dist[1]) if dist else "",
           "km": BR.shown_km(km) if viewer_area and (d.lat is not None or d.district) else None,
           "eligible": el["eligible"], "next_date": el["next_date"],
           "verified": bool(d.verified_at),
           "phone": (u.phone or None) if d.phone_public else None,
           "email": (u.email or None) if d.email_public else None}
    return out


def search(user, params, lang="bn", at=None):
    """-> (rows, error). Listed donors near the viewer, by group."""
    from .models import BloodDonor
    at = at or now()
    if _searches_today(user, at) >= BR.MAX_SEARCH_DAY:
        return None, "rate_limited"
    group = BR.normalise_group(params.get("group"))
    radius = BR.clean_radius(params.get("radius"))
    la, ln = MR.coarse(params.get("lat")), MR.coarse(params.get("lng"))
    if not MR.in_bangladesh(la, ln):
        la = ln = None
    code = str(params.get("district") or "").strip().lower()
    me = get_donor(user)
    if la is None and not MR.district(code) and me is not None:
        la, ln, code = me.lat, me.lng, me.district
    viewer = BR.area_of(la, ln, code if MR.district(code) else "")
    if viewer is None:
        return None, "area_required"
    groups = ([group] if params.get("compatible") not in ("1", "true", True) or not group
              else BR.donor_groups_for(group)) if group else list(BR.BLOOD_GROUPS)
    qs = (BloodDonor.objects.filter(enabled=True, available=True, user__is_active=True,
                                    blood_group__in=groups)
          .exclude(user=user).select_related("user"))
    on_day = timezone.localtime(at).date()
    rows = []
    for d in qs[:5000]:
        ok, km = BR.within(viewer, BR.area_of(d.lat, d.lng, d.district), radius)
        if not ok:
            continue
        rows.append((d, km or 0.0))
    only_now = params.get("eligible_only") in ("1", "true", True)
    out = []
    for d, km in rows:
        card = public_card(d, viewer, lang, on_day)
        if only_now and not card["eligible"]:
            continue
        out.append((not card["eligible"], d.blood_group != group, km, card))
    out.sort(key=lambda r: (r[0], r[1], r[2]))
    log_event("search", None, user, group=group, radius=radius, n=len(out))
    return [r[3] for r in out[:BR.MAX_LIST]], None


# ------------------------------------------------------------------ requests
def posting_ban_until(user, at):
    from .models import BloodEvent
    e = (BloodEvent.objects.filter(actor=user, kind="poster_banned",
                                   at__gte=at - timedelta(days=BR.POSTING_BAN_DAYS))
         .order_by("-at").first())
    return e.at + timedelta(days=BR.POSTING_BAN_DAYS) if e else None


def create_request(user, body, at=None):
    """-> (request, error, fields)."""
    from .models import BloodRequest
    at = at or now()
    if posting_ban_until(user, at):
        return None, "banned", []
    fields = []
    group = BR.normalise_group(body.get("blood_group"))
    if not group:
        fields.append("blood_group")
    units = BR.clean_units(body.get("units"))
    if units is None:
        fields.append("units")
    hospital = BR.clean_text(body.get("hospital"), 120)
    if len(hospital) < 3 or BR.has_contact(hospital):
        fields.append("hospital")
    area = BR.clean_text(body.get("area_text"), 60)
    if MR.looks_like_address(area) or BR.has_contact(area):
        fields.append("area_text")
    note = BR.clean_text(body.get("note"), 300)
    if BR.has_contact(note):
        fields.append("note")
    nb = None
    try:
        from django.utils.dateparse import parse_datetime
        nb = parse_datetime(str(body.get("needed_by") or ""))
        if nb is not None and timezone.is_naive(nb):
            nb = timezone.make_aware(nb)
    except (TypeError, ValueError):
        nb = None
    if nb is None or nb < at - timedelta(minutes=10) or nb > at + timedelta(hours=BR.MAX_NEEDED_IN_H):
        fields.append("needed_by")
    la, ln = MR.coarse(body.get("lat")), MR.coarse(body.get("lng"))
    if la is not None and not MR.in_bangladesh(la, ln):
        fields.append("location")
    code = str(body.get("district") or "").strip().lower()
    code = code if MR.district(code) else ""
    if fields:
        return None, "invalid", fields
    if la is None and not code:
        return None, "area_required", []
    if la is not None and not code:
        code = MR.nearest_district(la, ln)
    day = BloodRequest.objects.filter(requester=user, created_at__gte=at - timedelta(hours=24))
    if day.count() >= BR.MAX_REQ_DAY:
        return None, "too_many_requests", []
    if BloodRequest.objects.filter(requester=user, state__in=BloodRequest.LIVE).count() >= BR.MAX_ACTIVE_REQ:
        return None, "too_many_active", []
    r = BloodRequest.objects.create(
        requester=user, blood_group=group, units=units, hospital=hospital, area_text=area,
        district=code, lat=la, lng=ln, radius_km=BR.clean_radius(body.get("radius_km")),
        needed_by=nb, note=note, state="active",
        expires_at=max(nb, at) + timedelta(hours=BR.EXPIRE_AFTER_NEEDED_H))
    log_event("request", r, user, group=group, units=units)
    _run_bg(fan_out, r.id)
    return r, None, []


def candidates(req, at):
    """[(exact_group, km, donor)] — opted-in, available, eligible by
    needed-by, compatible, within the radius. Sorted exact first, nearest."""
    from .models import BloodDonor
    a = BR.area_of(req.lat, req.lng, req.district)
    if a is None:
        return []
    by_day = timezone.localtime(req.needed_by).date()
    out = []
    for d in (BloodDonor.objects
              .filter(enabled=True, available=True, user__is_active=True,
                      blood_group__in=BR.donor_groups_for(req.blood_group))
              .exclude(user_id=req.requester_id).select_related("user")):
        if not BR.is_eligible(d.last_donation, d.sex, by_day):
            continue
        ok, km = BR.within(a, BR.area_of(d.lat, d.lng, d.district), req.radius_km)
        if ok:
            out.append((d.blood_group == req.blood_group, km or 0.0, d))
    out.sort(key=lambda r: (not r[0], r[1]))
    return out


def _donor_pushes_today(user, at):
    from .models import BloodRecipient
    return BloodRecipient.objects.filter(user=user, pushed_at__gte=at - timedelta(hours=24)).count()


def request_texts(req):
    when = timezone.localtime(req.needed_by).strftime("%H:%M, %d/%m")
    where = req.hospital + ((" (%s)" % req.area_text) if req.area_text else "")
    return ("জরুরি রক্ত দরকার: %s · %d ব্যাগ" % (req.blood_group, req.units),
            "Urgent blood needed: %s · %d bag(s)" % (req.blood_group, req.units),
            "%s — লাগবে %s-এর মধ্যে। আপনি দিতে পারলে খুলে 'আমি দিতে পারব' চাপুন।" % (where, when),
            "%s — needed by %s. If you can donate, open and tap 'I can donate'." % (where, when))


def fan_out(req_id):
    """Recipient rows + pushes. Idempotent (unique rows)."""
    from .models import BloodRecipient, BloodRequest
    req = BloodRequest.objects.filter(pk=req_id, state="active").first()
    if req is None:
        return {"pushed": 0, "listed": 0}
    at = now()
    tbn, ten, bbn, ben = request_texts(req)
    pushed = listed = 0
    for _exact, _km, d in candidates(req, at):
        row, made = BloodRecipient.objects.get_or_create(request=req, user=d.user,
                                                         defaults={"source": "push"})
        if not made:
            continue
        listed += 1
        if pushed >= BR.MAX_PUSH_PER_REQUEST or _donor_pushes_today(d.user, at) >= BR.MAX_PUSH_PER_DONOR_DAY:
            row.source = "list"
            row.save(update_fields=["source"])
            _inapp(d.user, tbn, ten, bbn, ben, {"route": ROUTE, "event": "request",
                                                "request_id": req.id})
            continue
        row.pushed_at = at   # counts toward the daily cap even if FCM is down
        row.save(update_fields=["pushed_at"])
        if notify(d.user, "request", tbn, ten, bbn, ben, high=True, request_id=req.id):
            pushed += 1
    BloodRequest.objects.filter(pk=req.id).update(pushed=req.pushed + pushed,
                                                   listed=req.listed + listed)
    log_event("fan_out", req, pushed=pushed, listed=listed)
    return {"pushed": pushed, "listed": listed}


def role(user, req):
    if req.requester_id == user.id:
        return "requester"
    return "donor"


def can_see(user, req):
    """The requester always; others while the request is active (hidden /
    removed ones only the requester)."""
    return req.requester_id == user.id or req.state in ("active", "fulfilled")


def visible_requests(user, at=None):
    """Active requests a donor can answer: compatible + nearby (or already a
    recipient). Requests I made are listed separately."""
    from .models import BloodRequest
    at = at or now()
    d = get_donor(user)
    base = BloodRequest.objects.filter(state="active", expires_at__gt=at).exclude(requester=user)
    rows = list(base.filter(recipients__user=user).distinct()[:50])
    seen = {r.id for r in rows}
    if d is not None and d.enabled and d.blood_group:
        me = BR.area_of(d.lat, d.lng, d.district)
        for r in base.exclude(id__in=seen)[:500]:
            if not BR.can_donate_to(d.blood_group, r.blood_group):
                continue
            ok, _km = BR.within(BR.area_of(r.lat, r.lng, r.district), me, r.radius_km)
            if ok:
                rows.append(r)
    rows.sort(key=lambda r: r.needed_by)
    return rows[:50]


def respond(req, user, answer, at=None):
    """Donor answer: can | cannot | withdraw | donated. -> error or None."""
    from .models import BloodRecipient
    at = at or now()
    if req.requester_id == user.id:
        return "not_allowed"
    if answer not in ("can", "cannot", "withdraw", "donated"):
        return "invalid"
    d = get_donor(user)
    if answer in ("can", "donated") and (d is None or not d.enabled):
        return "not_donor"
    if answer == "can":
        if req.state != "active" or req.expires_at <= at:
            return "not_active"
        if not BR.can_donate_to(d.blood_group, req.blood_group):
            return "incompatible"
        if not BR.is_eligible(d.last_donation, d.sex, timezone.localtime(req.needed_by).date()):
            return "not_eligible"
    row, _ = BloodRecipient.objects.get_or_create(request=req, user=user,
                                                  defaults={"source": "list"})
    row.response = "withdrawn" if answer == "withdraw" else answer
    row.responded_at = at
    row.save(update_fields=["response", "responded_at"])
    log_event("respond", req, user, answer=answer)
    if answer == "can":
        th = thread_for(user, req.requester, req)
        sys_text = "আমি রক্ত দিতে পারব।" if (user.language or "bn") != "en" else "I can donate."
        _post(th, by_donor=True, text=sys_text, at=at, notify_other=False)
        notify(req.requester, "responder",
               "একজন দাতা রাজি", "A donor can help",
               "%s (%s) আপনার অনুরোধে রক্ত দিতে রাজি। অ্যাপে কথা বলুন।" % (BR.first_name(user.name) or "দাতা", d.blood_group),
               "%s (%s) can donate for your request. Talk in the app." % (BR.first_name(user.name) or "A donor", d.blood_group),
               high=True, request_id=req.id, thread_id=th.id)
    if answer == "donated":
        mark_donated(user, timezone.localtime(at).date())
    return None


def responders(req, lang="bn"):
    """What the requester sees: donors who said they can (coarse only)."""
    from .models import BloodThread
    a = BR.area_of(req.lat, req.lng, req.district)
    out = []
    for row in (req.recipients.filter(response__in=("can", "donated"))
                .select_related("user").order_by("responded_at")):
        d = get_donor(row.user)
        if d is None:
            continue
        card = public_card(d, a, lang)
        th = BloodThread.objects.filter(donor=row.user, seeker=req.requester).first()
        card.update({"response": row.response, "thread_id": th.id if th else None,
                     "responded_at": row.responded_at.isoformat() if row.responded_at else None})
        out.append(card)
    return out


def end_request(req, state, by, at=None):
    """fulfilled | closed | expired | removed. Tells the donors who said
    they can (one push, no details) when blood is found / it is closed."""
    at = at or now()
    if req.state not in req.LIVE:
        return "not_active"
    req.state, req.closed_at = state, at
    req.save(update_fields=["state", "closed_at"])
    log_event("end_" + state, req, by if hasattr(by, "pk") else None)
    if state in ("fulfilled", "closed"):
        for row in req.recipients.filter(response="can").select_related("user"):
            notify(row.user, "ended",
                   "রক্তের ব্যবস্থা হয়েছে" if state == "fulfilled" else "অনুরোধ বন্ধ",
                   "Blood arranged" if state == "fulfilled" else "Request closed",
                   "আপনি যে অনুরোধে রাজি হয়েছিলেন, সেটি আর লাগবে না। সাড়া দেওয়ার জন্য ধন্যবাদ।",
                   "The request you answered is no longer needed. Thank you for answering.",
                   request_id=req.id)
    return None


def sweep(at=None, limit=300, reminders=True):
    """Hourly (purge_deletions): expire requests + eligibility reminders.
    List GETs call it with reminders=False (expiry only, cheap)."""
    from .models import BloodDonor, BloodRequest
    at = at or now()
    n = 0
    for r in BloodRequest.objects.filter(state__in=BloodRequest.LIVE, expires_at__lte=at)[:limit]:
        if end_request(r, "expired", "system", at) is None:
            n += 1
    if not reminders:
        return n
    day = timezone.localtime(at).date()
    shortest = min(list(BR.INTERVAL_DAYS.values()) + [BR.INTERVAL_DEFAULT])
    for d in (BloodDonor.objects.filter(enabled=True, last_donation__isnull=False,
                                        last_donation__lte=day - timedelta(days=shortest),
                                        last_donation__gte=day - timedelta(days=shortest + 400))
              .select_related("user")[:5000]):
        nxt = BR.next_eligible(d.last_donation, d.sex)
        if nxt and nxt <= day and d.reminded_for != nxt and (day - nxt).days <= 7:
            d.reminded_for = nxt
            d.save(update_fields=["reminded_for"])
            notify(d.user, "eligible", "আপনি আবার রক্ত দিতে পারবেন",
                   "You can donate blood again",
                   "শেষ দানের পর নির্দিষ্ট সময় পার হয়েছে। কাছে কারও রক্ত লাগলে আপনি সাহায্য করতে পারবেন।",
                   "Enough time has passed since your last donation. You can help when someone nearby needs blood.",
                   kind="reminder")
    return n


# ------------------------------------------------------------------ reports + admin
def report(req, user, reason, note, at=None):
    from .models import BloodReport
    at = at or now()
    if req.requester_id == user.id:
        return "not_allowed", False
    if reason not in BR.REPORT_REASONS:
        reason = "other"
    if BloodReport.objects.filter(reporter=user, created_at__gte=at - timedelta(days=1)).count() >= BR.MAX_REPORTS_DAY:
        return "rate_limited", False
    if BloodReport.objects.filter(request=req, reporter=user).exists():
        return "already", False
    joined = getattr(user, "date_joined", None)
    young = bool(joined and at - joined < timedelta(days=BR.REPORTER_MIN_AGE_DAYS))
    BloodReport.objects.create(request=req, reporter=user, reason=reason,
                               note=BR.clean_text(note, 300), counted=not young)
    log_event("reported", req, user, reason=reason, counted=not young)
    n = BloodReport.objects.filter(request=req, counted=True, status="open").count()
    if req.state == "active" and n >= BR.REPORT_HIDE_N:
        req.hidden_from, req.state = "active", "hidden"
        req.save(update_fields=["state", "hidden_from"])
        log_event("auto_hidden", req, reports=n)
        notify(req.requester, "hidden", "অনুরোধ পর্যালোচনায়", "Request under review",
               "কয়েকজন রিপোর্ট করায় অনুরোধটি সাময়িকভাবে লুকানো — দ্রুত পর্যালোচনা হবে।",
               "Several people reported it, so it is hidden while we review it.",
               request_id=req.id)
        return "ok", True
    return "ok", False


def admin_action(req, action, owner, at=None):
    from .models import BloodReport
    at = at or now()
    if action == "hide" and req.state == "active":
        req.hidden_from, req.state = "active", "hidden"
        req.save(update_fields=["state", "hidden_from"])
    elif action == "restore" and req.state == "hidden":
        req.state = "active"
        req.save(update_fields=["state"])
        BloodReport.objects.filter(request=req, status="open").update(status="dismissed")
    elif action in ("remove", "remove_ban") and req.state in req.LIVE:
        end_request(req, "removed", owner, at)
        BloodReport.objects.filter(request=req, status="open").update(status="upheld")
        if action == "remove_ban":
            log_event("poster_banned", req, req.requester, days=BR.POSTING_BAN_DAYS)
    elif action == "close" and req.state in req.LIVE:
        end_request(req, "closed", owner, at)
    else:
        return "invalid"
    log_event("admin_" + action, req, owner)
    return None


# ------------------------------------------------------------------ verification
def submit_slip(user, raw_b64):
    """-> (verification, error)."""
    from .models import BloodVerification
    d = get_donor(user)
    if d is None or not d.enabled:
        return None, "not_donor"
    if d.verified_at:
        return None, "already_verified"
    if BloodVerification.objects.filter(user=user, state="pending").exists():
        return None, "already_pending"
    try:
        data = base64.b64decode(str(raw_b64 or ""), validate=True)
    except (binascii.Error, ValueError):
        return None, "bad_photo"
    if not data or len(data) > BR.PHOTO_MAX_BYTES:
        return None, "bad_photo"
    try:
        from PIL import Image, ImageOps
        im = ImageOps.exif_transpose(Image.open(io.BytesIO(data))).convert("RGB")
        im.thumbnail((BR.PHOTO_MAX_SIDE, BR.PHOTO_MAX_SIDE))
        out = io.BytesIO()
        im.save(out, "JPEG", quality=85)    # no exif -> no GPS / metadata
    except Exception:
        return None, "bad_photo"
    v = BloodVerification(user=user, state="pending")
    v.photo.save("%s.jpg" % secrets.token_hex(16), ContentFile(out.getvalue()), save=False)
    v.save()
    log_event("slip_sent", None, user, v=v.id)
    return v, None


def _delete_slip(v, why):
    if not v.photo:
        return False
    try:
        v.photo.delete(save=False)
    except Exception as e:
        log.warning("blood: slip delete failed %s", type(e).__name__)
    v.photo = ""
    log_event("slip_deleted", None, v.user, v=v.id, why=why)
    return True


def review_slip(v, approve, owner, note="", at=None):
    """Owner Admin: approve -> badge; reject -> no badge. The photo FILE is
    deleted either way."""
    from .models import BloodDonor
    at = at or now()
    if v.state != "pending":
        return "invalid"
    v.state = "approved" if approve else "rejected"
    v.note = BR.clean_text(note, 200)
    v.reviewed_at, v.reviewed_by = at, owner
    _delete_slip(v, "reviewed")
    v.save(update_fields=["state", "note", "reviewed_at", "reviewed_by", "photo"])
    if approve:
        BloodDonor.objects.filter(user=v.user).update(verified_at=at)
    log_event("slip_" + v.state, None, owner, v=v.id, donor=v.user_id)
    notify(v.user, "verify", "রক্তদাতা যাচাই", "Donor verification",
           "আপনার রক্তদানের স্লিপ যাচাই হয়েছে — 'যাচাই করা দাতা' ব্যাজ চালু। ছবিটি মুছে ফেলা হয়েছে।"
           if approve else "স্লিপ দিয়ে যাচাই করা গেল না। ছবিটি মুছে ফেলা হয়েছে; চাইলে আরেকটি পরিষ্কার ছবি দিন।",
           "Your donation slip was checked — the verified donor badge is on. The photo was deleted."
           if approve else "We could not verify the slip. The photo was deleted; you may send a clearer one.",
           push_it=True, kind="reminder")
    return None


# ------------------------------------------------------------------ threads
def thread_for(donor_user, seeker_user, req=None):
    from .models import BloodThread
    th, made = BloodThread.objects.get_or_create(donor=donor_user, seeker=seeker_user,
                                                 defaults={"request": req})
    if not made and req is not None and th.request_id != req.id:
        th.request = req
        th.save(update_fields=["request"])
    return th


def side(th, user):
    if th.donor_id == user.id:
        return "donor"
    if th.seeker_id == user.id:
        return "seeker"
    return None


def _post(th, by_donor, text, at, notify_other=True):
    from .models import BloodMessage
    BloodMessage.objects.create(thread=th, by_donor=by_donor, text=text, at=at)
    th.last_at = at
    if by_donor:
        th.seeker_unread += 1
    else:
        th.donor_unread += 1
    th.save(update_fields=["last_at", "seeker_unread", "donor_unread"])
    if notify_other:
        other = th.seeker if by_donor else th.donor
        notify(other, "message", "রক্তদাতা প্যানেলে নতুন বার্তা", "New message in Blood donors",
               "অ্যাপে খুলে উত্তর দিন।", "Open the app to reply.", kind="reminder",
               thread_id=th.id)


def start_thread(seeker, donor_profile, text, at=None):
    """A seeker writes to a listed donor. -> (thread, error)."""
    from .models import BloodThread
    at = at or now()
    if donor_profile.user_id == seeker.id:
        return None, "not_allowed"
    if not (donor_profile.enabled and donor_profile.available):
        return None, "not_available"
    text = BR.clean_text(text, 600)
    if len(text) < 2:
        return None, "invalid"
    th = BloodThread.objects.filter(donor=donor_profile.user, seeker=seeker).first()
    if th is None:
        if BloodThread.objects.filter(seeker=seeker, created_at__gte=at - timedelta(days=1)).count() >= BR.MAX_NEW_THREADS_DAY:
            return None, "rate_limited"
        th = thread_for(donor_profile.user, seeker)
    err = send(th, seeker, text, at)
    return (None, err) if err else (th, None)


def send(th, user, text, at=None):
    at = at or now()
    s = side(th, user)
    if s is None:
        return "not_allowed"
    if th.blocked_by:
        return "blocked"
    text = BR.clean_text(text, 600)
    if len(text) < 1:
        return "invalid"
    if th.messages.filter(by_donor=(s == "donor"), at__gte=at - timedelta(days=1)).count() >= BR.MAX_MSGS_DAY:
        return "rate_limited"
    _post(th, s == "donor", text, at)
    return None


def thread_json(th, user, lang="bn"):
    s = side(th, user)
    other = th.seeker if s == "donor" else th.donor
    d = get_donor(th.donor)
    return {"id": th.id, "side": s,
            "other_name": BR.first_name(other.name) or ("ব্যবহারকারী" if lang == "bn" else "User"),
            "blood_group": d.blood_group if d else "",
            "verified": bool(d and d.verified_at),
            "request_id": th.request_id, "last_at": th.last_at.isoformat(),
            "unread": th.donor_unread if s == "donor" else th.seeker_unread,
            "blocked": bool(th.blocked_by), "blocked_by_me": th.blocked_by == s,
            "circle_ask": th.circle_ask,
            "phone": (th.donor.phone or None) if (s == "seeker" and d and d.phone_public) else None}


def mark_read(th, user):
    s = side(th, user)
    f = "donor_unread" if s == "donor" else "seeker_unread"
    if getattr(th, f):
        setattr(th, f, 0)
        th.save(update_fields=[f])


def block(th, user, on=True):
    s = side(th, user)
    if s is None:
        return "not_allowed"
    if on:
        th.blocked_by = s
    elif th.blocked_by == s:
        th.blocked_by = ""
    th.save(update_fields=["blocked_by"])
    log_event("thread_block" if on else "thread_unblock", th.request, user, thread=th.id)
    return None


def circle(th, user, action):
    """My Circle by REQUEST only: the seeker asks; the DONOR accepts or
    declines. Accept returns the seeker's user id — the donor's app then
    sends a normal My Circle request (existing limits, the seeker accepts).
    -> (error, extra)."""
    s = side(th, user)
    if s is None:
        return "not_allowed", {}
    if th.blocked_by:
        return "blocked", {}
    if action == "ask":
        if s != "seeker":
            return "not_allowed", {}
        if th.circle_ask in ("asked", "accepted", "declined"):
            return ("already" if th.circle_ask != "declined" else "declined"), {}
        th.circle_ask = "asked"
        th.save(update_fields=["circle_ask"])
        notify(th.donor, "circle_ask", "My Circle-এ যুক্ত হওয়ার অনুরোধ", "Request to join My Circle",
               "যিনি রক্ত খুঁজছেন তিনি আপনাকে My Circle-এ যুক্ত করতে চান। আপনি রাজি হলে তবেই হবে।",
               "The person looking for blood wants to add you to My Circle. Only if you agree.",
               kind="reminder", thread_id=th.id)
        return None, {}
    if action in ("accept", "decline"):
        if s != "donor" or th.circle_ask != "asked":
            return "not_allowed", {}
        th.circle_ask = "accepted" if action == "accept" else "declined"
        th.save(update_fields=["circle_ask"])
        log_event("circle_" + action, th.request, user, thread=th.id)
        return None, ({"circle_to_user_id": th.seeker_id} if action == "accept" else {})
    return "invalid", {}


def my_threads(user):
    from .models import BloodThread
    return (BloodThread.objects.filter(Q(donor=user) | Q(seeker=user))
            .select_related("donor", "seeker").order_by("-last_at")[:100])


# ------------------------------------------------------------------ banks
def banks(lang="bn"):
    """Official / verified list only. Empty + source_pending today."""
    src = BR.BANKS_SOURCE
    return {"banks": list(BR.BLOOD_BANKS) if src else [],
            "source": src, "source_pending": not src}
