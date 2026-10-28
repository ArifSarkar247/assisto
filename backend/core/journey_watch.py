"""
journey_watch.py — journey100: the SERVER half of Safe Journey.

The phone sends location fixes while the user's own journey is active (a
foreground location service the user starts). Everything that must happen
even when the traveller's phone is silent, off or offline runs HERE, from the
`journey_sweep` management command (cron, every minute):

  * overdue -> "Are you OK?" push to the traveller -> no answer -> watchers
    alerted (high-priority FCM + in-app FamilyAlert/NotifEvent), repeated up
    to MAX_ESCALATIONS times, 15 min apart;
  * started / arrived / extended / ended / low battery / vehicle / duress
    events pushed to the watchers (the views emit them at once; the sweeper
    re-delivers anything that did not go out);
  * prolonged stop, off route (planned route or origin->destination
    corridor), signal lost;
  * wellness checks (parents living alone), overdue safe-arrival check-ins,
    routine reminders;
  * privacy: expired journeys lose every location row and the vehicle photo;
    no trail point is ever older than TRAIL_MAX_DAYS.

IDEMPOTENT: every watcher-facing event is a JourneyEvent row, UNIQUE on
(journey, kind, key) — two sweeps (or a sweep racing a view) can never send
the same event twice. RATE-LIMITED: info events count against a per-watcher
hourly cap; emergencies (overdue alert, duress) are never capped.

Safety is always free (billing.SAFETY_EXEMPT): nothing here debits credits.
Pure helpers (geometry, text) have no ORM access and are unit-tested directly.
"""
import logging
from datetime import timedelta
from math import cos, radians, sqrt

from django.conf import settings
from django.db import IntegrityError, transaction
from django.utils import timezone

from .logic import safety_journey as SJ
from .logic.safety import haversine_m

log = logging.getLogger(__name__)

# --------------------------------------------------------------- tunables
MAX_WATCHERS = int(getattr(settings, "JOURNEY_MAX_WATCHERS", 10))
DAILY_JOURNEY_CAP = int(getattr(settings, "JOURNEY_DAILY_CAP", 20))
MAX_EXTENSIONS = 6
EXTEND_MIN, EXTEND_MAX = 5, 120
OK_SNOOZE_MIN = 15            # "I'm OK" moves the deadline this far ahead
NIGHT_GRACE_MIN = 7           # night routine: tighter grace (mirror of safety.py)
FRESH_FIX_S = 120             # web page: a fix newer than this is "live"
LOST_FIX_MIN = 15             # no fix for this long -> "signal lost" alert
MOVE_M = 60                   # moving more than this resets the stop clock
OFFROUTE_REPEAT_MIN = 15
OVERDUE_REPEAT_MIN = 15
MAX_ESCALATIONS = 3
LOW_BATT = SJ.LOW_BATTERY_THRESHOLD   # 15 %
LOW_BATT_STEP = 5             # re-alert only after a further 5 % drop
WATCHER_HOURLY_CAP = 30       # info pushes per watcher per hour
DELIVERY_ATTEMPTS = 5
TRAIL_MAX_DAYS = int(getattr(settings, "JOURNEY_TRAIL_MAX_DAYS", 7))
URGENT = ("overdue_alert", "duress", "low_battery", "off_route", "long_stop",
          "signal_lost")
NEVER_CAPPED = ("overdue_alert", "duress")


# ----------------------------------------------------------------- helpers
_BN = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")


def bn_num(v):
    return str(v).translate(_BN)


def _n(lang, v):
    return bn_num(v) if lang == "bn" else str(v)


def _hhmm(dt, lang):
    if dt is None:
        return ""
    s = timezone.localtime(dt).strftime("%H:%M")
    return bn_num(s) if lang == "bn" else s


def site():
    return (getattr(settings, "WEB_PUBLIC_SITE", "") or
            "https://lifeassisto.com").rstrip("/")


LINK_HOURS = 48               # the watcher link's own life (from the start)


def link_expiry(j):
    """Stable expiry baked into the watcher link: start + LINK_HOURS. The link
    never changes when the trip is extended; the page additionally refuses
    any journey past its privacy expiry (Journey.expires_at)."""
    return (j.created_at or timezone.now()) + timedelta(hours=LINK_HOURS)


def link_id(j):
    """The id part signed into the watcher link: "<id>" for the first
    generation (links shared before journey2 keep working), "<id>-<gen>"
    after the traveller turned the link off and shared a new one."""
    gen = int(getattr(j, "web_gen", 0) or 0)
    return str(j.id) if gen <= 0 else "%s-%s" % (j.id, gen)


def split_link_id(raw):
    """("123-2") -> (123, 2); ("123") -> (123, 0); junk -> (None, None)."""
    s = str(raw or "")
    head, _, gen = s.partition("-")
    if not head.isdigit() or (gen and not gen.isdigit()):
        return None, None
    return int(head), int(gen or 0)


def web_token(j):
    if not j.pk:
        return ""
    return SJ.make_web_token(link_id(j), link_expiry(j), settings.SECRET_KEY)


def web_url(j):
    t = web_token(j)
    return "%s/j/%s" % (site(), t) if t else ""


def tile_config():
    """Map tiles for the watcher page. Same key as vehicle tracking
    (settings / env MAP_TILE_URL, an {z}/{x}/{y} template from a provider the
    owner has an account with). Empty = no map, an honest 'open in Google
    Maps' link instead. tile.openstreetmap.org is NEVER used (OSMF policy)."""
    import os
    url = str(getattr(settings, "MAP_TILE_URL", "") or
              os.getenv("MAP_TILE_URL", "") or "")
    if "tile.openstreetmap.org" in url or "{z}" not in url:
        url = ""
    attr = str(getattr(settings, "MAP_TILE_ATTRIBUTION", "") or
               os.getenv("MAP_TILE_ATTRIBUTION", "") or
               "© OpenStreetMap contributors")
    return {"tile_url": url, "attribution": attr}


def fix_of(j):
    """(lat, lng, at_datetime, battery) of the last fix, or None."""
    loc = j.last_location or {}
    lat, lng = loc.get("lat"), loc.get("lng")
    if lat is None or lng is None:
        return None
    try:
        lat, lng = float(lat), float(lng)
    except (TypeError, ValueError):
        return None
    at = SJ.parse_dt(loc.get("at"))
    if at is not None and timezone.is_naive(at):
        at = timezone.make_aware(at)
    return lat, lng, at, loc.get("battery")


def effective_grace(j):
    g = int(j.overdue_grace_min or 0)
    return min(g, NIGHT_GRACE_MIN) if j.night else g


def overdue(j, now):
    """(state, minutes) from the pure state machine, with the night grace and
    the journey's own response window."""
    d = {"status": j.status, "eta": j.eta,
         "overdue_grace_min": effective_grace(j),
         "overdue_response_min": int(j.response_window_min or 10)}
    return SJ.overdue_state(d, now=now)


# --------------------------------------------------------------- geometry
def _xy(lat0, lat, lng):
    """Equirectangular metres around lat0 (fine at city scale)."""
    k = 111320.0
    return lng * k * cos(radians(lat0)), lat * k


def point_segment_m(p, a, b):
    """Distance in metres from point p to segment a-b; each is (lat, lng)."""
    lat0 = (a[0] + b[0] + p[0]) / 3.0
    px, py = _xy(lat0, *p)
    ax, ay = _xy(lat0, *a)
    bx, by = _xy(lat0, *b)
    dx, dy = bx - ax, by - ay
    L2 = dx * dx + dy * dy
    if L2 <= 0:
        return sqrt((px - ax) ** 2 + (py - ay) ** 2)
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / L2))
    cx, cy = ax + t * dx, ay + t * dy
    return sqrt((px - cx) ** 2 + (py - cy) ** 2)


def _pt(d):
    try:
        return (float(d["lat"]), float(d["lng"]))
    except (KeyError, TypeError, ValueError):
        return None


def offroute(j, lat, lng):
    """(off: bool, metres, threshold). Planned route -> distance to the
    polyline vs route_radius_m. No route -> the origin->destination corridor,
    half-width max(route_radius_m, 35 % of the trip, capped at 3 km) because
    real roads bend. No destination coordinates -> never off route."""
    p = (float(lat), float(lng))
    route = [x for x in (_pt(r) for r in (j.planned_route or [])) if x]
    radius = max(SJ.ROUTE_DEVIATION_M_MIN, int(j.route_radius_m or 500))
    if len(route) >= 2:
        d = min(point_segment_m(p, route[i], route[i + 1])
                for i in range(len(route) - 1))
        return d > radius, int(d), radius
    dest = _pt(j.destination or {})
    origin = _pt(j.origin or {})
    if dest is None or origin is None:
        return False, None, radius
    trip = haversine_m(origin[0], origin[1], dest[0], dest[1])
    thr = int(max(radius, min(3000, 0.35 * trip)))
    d = point_segment_m(p, origin, dest)
    return d > thr, int(d), thr


def progress(j, fx=None):
    """journey2: straight-line distance left to a PINNED destination and a
    rough remaining time (road factor x typical city speed for the mode).
    {} when the destination has no pin or there is no fix — never a guess."""
    from .logic import journey_dest as JD
    dest = _pt(j.destination or {})
    fx = fx if fx is not None else fix_of(j)
    if dest is None or fx is None:
        return {}
    d = JD.distance_m(fx[0], fx[1], dest[0], dest[1])
    if d is None:
        return {}
    mode = ((j.vehicle or {}).get("mode") or j.mode or "")
    return {"distance_m": d, "rough_min": JD.rough_minutes(d, mode)}


def near_destination(j, lat, lng, factor=2.0):
    dest = _pt(j.destination or {})
    if dest is None:
        return False
    return haversine_m(lat, lng, dest[0], dest[1]) <= factor * int(j.arrival_radius_m or 120)


# ----------------------------------------------------------------- texts
def _dest(j, lang):
    return (j.destination or {}).get("name") or SJ.pick(lang, "গন্তব্য", "the destination")


def event_text(kind, j, name, lang, p):
    """(title, body) for a watcher-facing event in `lang` (strict bn / en)."""
    pick = SJ.pick
    loc = {"lat": p.get("lat"), "lng": p.get("lng")} if p.get("lat") is not None else None
    url = p.get("url") or ""
    link = pick(lang, " লাইভ পাতা: %s" % url, " Live page: %s" % url) if url else ""
    dest = _dest(j, lang)
    if kind == "started":
        pl = SJ.journey_started_payload(name, dest, web_link=url or None, lang=lang)
        eta = _hhmm(j.eta, lang)
        if eta:
            pl["body"] += pick(lang, " পৌঁছানোর সময়: %s।" % eta, " Expected by %s." % eta)
        from .logic import journey_dest as JD
        ride = JD.ride_line(p, lang) if (p.get("plate") or p.get("app")) else ""
        if ride:
            pl["body"] += pick(lang, " যানবাহন: %s।" % ride, " Ride: %s." % ride)
        if p.get("driver_name"):
            pl["body"] += pick(lang, " চালক: %s।" % p["driver_name"], " Driver: %s." % p["driver_name"])
        return pl["title"], pl["body"]
    if kind == "arrived":
        pl = SJ.arrived_payload(name, dest, lang=lang)
        return pl["title"], pl["body"]
    if kind == "extended":
        m, eta = _n(lang, p.get("minutes", "")), _hhmm(j.eta, lang)
        return (pick(lang, "যাত্রার সময় বাড়ানো হয়েছে", "Journey time extended"),
                pick(lang, "%s যাত্রার সময় %s মিনিট বাড়িয়েছেন। নতুন সময়: %s।" % (name, m, eta),
                     "%s added %s min to the trip. New arrival time: %s." % (name, m, eta)))
    if kind == "low_battery":
        pl = SJ.low_battery_payload(name, _n(lang, p.get("battery", "")), loc, lang=lang)
        return pl["title"], pl["body"] + link
    if kind == "overdue_alert":
        pl = SJ.overdue_payload(name, dest, _n(lang, p.get("minutes", 0)), loc, lang=lang)
        return pl["title"], pl["body"] + link
    if kind == "ok_again":
        return (pick(lang, "সাড়া দিয়েছেন: ভালো আছেন", "They answered: I'm OK"),
                pick(lang, "%s জানিয়েছেন তিনি ভালো আছেন। যাত্রা চলছে।" % name,
                     "%s says they are OK. The journey continues." % name))
    if kind == "off_route":
        pl = SJ.route_deviation_payload(name, _n(lang, p.get("meters", "")), loc, lang=lang)
        return pl["title"], pl["body"] + link
    if kind == "long_stop":
        m = _n(lang, p.get("minutes", ""))
        return (pick(lang, "অনেকক্ষণ এক জায়গায় থেমে আছেন", "Stopped for a long time"),
                pick(lang, "%s প্রায় %s মিনিট ধরে এক জায়গায় থেমে আছেন।%s%s" % (
                    name, m, SJ._loc_line(loc, lang), link),
                     "%s has not moved for about %s min.%s%s" % (
                    name, m, SJ._loc_line(loc, lang), link)))
    if kind == "signal_lost":
        m = _n(lang, p.get("minutes", ""))
        return (pick(lang, "লোকেশন আসছে না", "No location coming in"),
                pick(lang, "%s মিনিট ধরে %s-এর ফোন থেকে লোকেশন আসেনি (ফোন বন্ধ, চার্জ শেষ বা নেট নেই হতে পারে)।%s%s" % (
                    m, name, SJ._loc_line(loc, lang), link),
                     "No location from %s for %s min (the phone may be off, flat or offline).%s%s" % (
                    name, m, SJ._loc_line(loc, lang), link)))
    if kind == "ended":
        return (pick(lang, "যাত্রা শেষ করা হয়েছে", "Journey ended"),
                pick(lang, "%s গন্তব্যে পৌঁছানোর আগেই যাত্রাটি শেষ করেছেন।" % name,
                     "%s ended the journey before reaching %s." % (name, dest)))
    if kind == "duress":
        return (pick(lang, "জরুরি: %s বিপদে থাকতে পারেন" % name, "Emergency: %s may be in danger" % name),
                pick(lang, "%s গোপন বিপদ-PIN দিয়েছেন। এখনই খোঁজ নিন, তাঁর ফোনে ফোন করে সতর্ক করবেন না।%s%s" % (
                    name, SJ._loc_line(loc, lang), link),
                     "%s entered their secret duress PIN. Check on them now, but don't give them away with a loud call.%s%s" % (
                    name, SJ._loc_line(loc, lang), link)))
    if kind == "vehicle":
        # journey2: the ride in ONE language (the raw mode code used to land
        # in the Bangla push) + the driver's name when the traveller gave it
        from .logic import journey_dest as JD
        ride = JD.ride_line({"plate": p.get("plate"), "mode": p.get("mode"),
                             "app": p.get("app")}, lang) or pick(lang, "অজানা", "unknown")
        drv = str(p.get("driver_name") or "")
        drv = pick(lang, " চালক: %s।" % drv, " Driver: %s." % drv) if drv else ""
        extra = pick(lang, " গাড়ির ছবি লাইভ পাতায় আছে।", " The ride photo is on the live page.") \
            if p.get("photo") else ""
        return (pick(lang, "যানবাহনের তথ্য", "Ride details shared"),
                pick(lang, "%s-এর যানবাহন: %s।" % (name, ride),
                     "%s's ride: %s." % (name, ride)) + drv + extra + link)
    return (pick(lang, "নিরাপদ যাত্রা", "Safe Journey"), name)


# -------------------------------------------------------------- audience
def watcher_users(j):
    """Users who watch journey `j`: the traveller's chosen circle members,
    accepted and not blocked, with an Assisto account. Never the traveller."""
    from .push import member_peer_user
    out, seen = [], set()
    for w in j.watchers.select_related("member").all():
        m = w.member
        if m is None or m.user_id != j.traveller_id or m.state != "accepted" or m.blocked:
            continue
        u = member_peer_user(m)
        if u is None or u.pk == j.traveller_id or u.pk in seen:
            continue
        seen.add(u.pk)
        out.append(u)
    return out


def is_watcher(j, user):
    return any(u.pk == user.pk for u in watcher_users(j))


def _rate_ok(user, kind):
    if kind in NEVER_CAPPED:
        return True
    from django.core.cache import cache
    key = "jw:rate:%s:%s" % (user.pk, timezone.now().strftime("%Y%m%d%H"))
    try:
        n = cache.get(key, 0) + 1
        cache.set(key, n, 3700)
        return n <= WATCHER_HOURLY_CAP
    except Exception:
        return True


def _notify(user, kind, j, tbn, ten, bbn, ben, data, urgent, high):
    """In-app rows + push for one recipient. Never raises."""
    from . import push
    from .models import FamilyAlert, NotifEvent
    lang = push.user_lang(user)
    try:
        if urgent:
            FamilyAlert.objects.create(
                user=user, kind="journey",
                title=(ten if lang == "en" else tbn)[:160],
                body=ben if lang == "en" else bbn,
                severity="high", payload=dict(data))
        NotifEvent.objects.create(
            user=user, type="safe_journey", title_bn=tbn[:200], title_en=ten[:200],
            body_bn=bbn, body_en=ben, route="journey", meta=dict(data))
    except Exception as e:
        log.warning("journey_watch: in-app row failed %s", type(e).__name__)
    try:
        push.safe_push(user, "family_alert", tbn, ten, bbn, ben,
                       data=dict(data), high_priority=high)
    except Exception:
        pass
    return True


def deliver(ev):
    """Write in-app rows + push for every watcher of ev.journey. Marks the
    event delivered (even with zero watchers, so it is not retried)."""
    from . import push
    j = ev.journey
    p = dict(ev.payload or {})
    data = {"journey_id": j.id, "event": ev.kind, "route": "journey/watch",
            "url": p.get("url") or web_url(j),
            "lat": "" if p.get("lat") is None else p.get("lat"),
            "lng": "" if p.get("lng") is None else p.get("lng")}
    urgent = ev.kind in URGENT
    n = 0
    for u in watcher_users(j):
        if not _rate_ok(u, ev.kind):
            continue
        name = push.seen_name(u, j.traveller)
        tbn, bbn = event_text(ev.kind, j, name, "bn", p)
        ten, ben = event_text(ev.kind, j, name, "en", p)
        _notify(u, ev.kind, j, tbn, ten, bbn, ben, data, urgent,
                high=urgent or ev.kind in ("started", "arrived"))
        n += 1
    ev.attempts += 1
    ev.recipients = n
    ev.delivered_at = timezone.now()
    ev.save(update_fields=["attempts", "recipients", "delivered_at"])
    return n


def emit(j, kind, key="", payload=None, deliver_now=True):
    """Create the (journey, kind, key) event once and deliver it. Returns the
    new event, or None when it already existed (idempotent)."""
    from .models import JourneyEvent
    p = dict(payload or {})
    fx = fix_of(j)
    if fx and "lat" not in p:
        p["lat"], p["lng"] = fx[0], fx[1]
    p.setdefault("url", web_url(j))
    try:
        with transaction.atomic():
            ev = JourneyEvent.objects.create(journey=j, kind=kind, key=str(key)[:64],
                                             payload=p)
    except IntegrityError:
        return None
    if deliver_now:
        try:
            deliver(ev)
        except Exception as e:  # the sweeper retries
            log.warning("journey_watch: deliver failed %s", type(e).__name__)
    return ev


def clear_urgent(j, user=None):
    """Journey over / traveller OK: urgent in-app cards about it go stale."""
    from .models import FamilyAlert
    try:
        q = FamilyAlert.objects.filter(kind="journey", dismissed=False,
                                       payload__journey_id=j.id)
        q.update(dismissed=True)
    except Exception:
        pass


def push_traveller(user, journey_id, event, tbn, ten, bbn, ben):
    """A push to the traveller's own phones (Are you OK? / routine). The tap
    opens Safe Journey (the live screen when a journey is active)."""
    from . import push
    try:
        push.safe_push(user, "family_alert", tbn, ten, bbn, ben,
                       data={"route": "journey", "event": event,
                             "journey_id": journey_id or ""},
                       high_priority=True)
    except Exception:
        pass


# ------------------------------------------------------- view-side hooks
def on_location(j, lat, lng, at, battery, now=None):
    """Called by the location view for each fix (newest last). Updates the
    stop anchor and emits low-battery / arrival events."""
    now = now or timezone.now()
    lat, lng = float(lat), float(lng)
    a = _pt(j.anchor or {})
    if a is None or haversine_m(a[0], a[1], lat, lng) > MOVE_M:
        j.anchor = {"lat": lat, "lng": lng}
        j.moved_at = at
    if j.origin is None or _pt(j.origin or {}) is None:
        j.origin = {**(j.origin or {}), "lat": lat, "lng": lng}
    try:
        b = int(battery) if battery is not None and str(battery) != "" else None
    except (TypeError, ValueError):
        b = None
    if b is not None and b < LOW_BATT and j.status == "active":
        last = j.low_batt_pct
        if last is None or b <= last - LOW_BATT_STEP:
            j.low_batt_pct = b
            emit(j, "low_battery", key=str(b), payload={"battery": b, "lat": lat, "lng": lng})


def on_arrived(j, now=None):
    now = now or timezone.now()
    j.status = "arrived"
    j.stopped_at = j.stopped_at or now
    j.sos_active = False
    j.expires_at = now + timedelta(hours=int(j.location_retention_hours or 0))
    emit(j, "arrived")
    clear_urgent(j)


def ended_expiry(j, now):
    return now + timedelta(hours=int(j.location_retention_hours or 0))


# ------------------------------------------------------------------ sweep
def _sweep_journey(j, now, stats):
    from .models import JourneyPoint
    if j.expires_at and now >= j.expires_at:
        expire(j)
        stats["expired"] += 1
        return
    state, mins = overdue(j, now)
    if state == "ask" and j.ask_sent_at is None:
        lang_left = int(j.response_window_min or 10) - int(mins)
        push_traveller(
            j.traveller, j.id, "overdue_ask",
            "আপনি ঠিক আছেন?", "Are you OK?",
            "পৌঁছানোর সময় পার হয়েছে। ট্যাপ করে জানান আপনি ভালো আছেন, নইলে %s মিনিটে আপনার পরিচিতদের জানানো হবে।" % bn_num(max(1, lang_left)),
            "Your arrival time has passed. Tap to say you're OK, or your watchers are alerted in %s min." % max(1, lang_left))
        j.ask_sent_at = now
        j.save(update_fields=["ask_sent_at"])
        stats["asked"] += 1
    elif state == "alert":
        due = (j.escalated_at is None or
               (j.escalations < MAX_ESCALATIONS and
                now - j.escalated_at >= timedelta(minutes=OVERDUE_REPEAT_MIN)))
        if due:
            n = j.escalations + 1
            if emit(j, "overdue_alert", key="%s:%s" % (j.eta.isoformat() if j.eta else "", n),
                    payload={"minutes": int(mins)}):
                stats["escalated"] += 1
            j.escalated_at, j.escalations = now, n
            j.save(update_fields=["escalated_at", "escalations"])
    fx = fix_of(j)
    if fx is None:
        if now - j.created_at >= timedelta(minutes=LOST_FIX_MIN) and j.lost_alerted_at is None:
            emit(j, "signal_lost", key="nofix", payload={"minutes": LOST_FIX_MIN})
            j.lost_alerted_at = now
            j.save(update_fields=["lost_alerted_at"])
            stats["lost"] += 1
        return
    lat, lng, at, _b = fx
    age_min = (now - at).total_seconds() / 60.0 if at else 9999
    if age_min >= LOST_FIX_MIN:
        if j.lost_alerted_at is None or (at and j.lost_alerted_at < at):
            emit(j, "signal_lost", key=at.isoformat() if at else "x",
                 payload={"minutes": int(age_min)})
            j.lost_alerted_at = now
            j.save(update_fields=["lost_alerted_at"])
            stats["lost"] += 1
        return   # a stale fix says nothing about stops or routes
    if (j.stop_alert_min or 0) > 0 and j.moved_at is not None:
        still = (now - j.moved_at).total_seconds() / 60.0
        if (still >= j.stop_alert_min and not near_destination(j, lat, lng) and
                (j.stop_alerted_at is None or j.stop_alerted_at < j.moved_at)):
            emit(j, "long_stop", key=j.moved_at.isoformat(), payload={"minutes": int(still)})
            j.stop_alerted_at = now
            j.save(update_fields=["stop_alerted_at"])
            stats["long_stop"] += 1
    if j.route_deviation:
        off, d, _thr = offroute(j, lat, lng)
        if off and (j.offroute_alerted_at is None or
                    now - j.offroute_alerted_at >= timedelta(minutes=OFFROUTE_REPEAT_MIN)):
            bucket = int(now.timestamp() // (OFFROUTE_REPEAT_MIN * 60))
            emit(j, "off_route", key=str(bucket), payload={"meters": d})
            j.offroute_alerted_at = now
            j.save(update_fields=["offroute_alerted_at"])
            stats["off_route"] += 1


def expire(j):
    """Privacy: the journey is over its hard expiry — drop every location."""
    from .models import JourneyPoint
    JourneyPoint.objects.filter(journey=j).delete()
    if j.vehicle_photo:
        try:
            j.vehicle_photo.delete(save=False)
        except Exception:
            pass
        j.vehicle_photo = ""
    j.last_location = None
    j.anchor = None
    j.planned_route = None
    if j.status == "active":
        j.status = "expired"
    j.save(update_fields=["last_location", "anchor", "planned_route", "status",
                          "vehicle_photo"])
    clear_urgent(j)


def _sweep_privacy(now, stats):
    from django.db.models import Q
    from .models import Journey, JourneyPoint
    due = Journey.objects.filter(expires_at__lte=now).filter(
        Q(status="active") | Q(last_location__isnull=False) | ~Q(vehicle_photo="") |
        Q(points__isnull=False)).distinct()
    for j in due:
        expire(j)
        stats["purged"] += 1
    # belt and braces: nothing older than TRAIL_MAX_DAYS, whatever the setting
    old = now - timedelta(days=TRAIL_MAX_DAYS)
    n, _ = JourneyPoint.objects.filter(at__lt=old).delete()
    stats["old_points"] += n


def _sweep_retry(now, stats):
    from .models import JourneyEvent
    for ev in JourneyEvent.objects.filter(
            delivered_at__isnull=True, attempts__lt=DELIVERY_ATTEMPTS,
            created_at__gte=now - timedelta(hours=2)).select_related("journey"):
        try:
            deliver(ev)
            stats["retried"] += 1
        except Exception:
            ev.attempts += 1
            ev.save(update_fields=["attempts"])


def _activity(w):
    """Latest sign of life for a wellness parent: an explicit 'I'm fine', any
    device check-in (push token refresh on app open) or a daily active day."""
    from .models import Device
    cands = [w.last_activity_at, getattr(w.parent, "last_active", None)]
    d = Device.objects.filter(user=w.parent).order_by("-last_seen").first()
    if d is not None:
        cands.append(d.last_seen)
    cands = [c for c in cands if c is not None]
    return max(cands) if cands else None


def _naive_local(dt):
    return timezone.localtime(dt).replace(tzinfo=None) if dt else None


def _family_alert(person, recipients, kind, tbn, ten, bbn, ben, data):
    for u in recipients:
        if _rate_ok(u, "overdue_alert"):
            _notify(u, kind, None, tbn, ten, bbn, ben, data, urgent=True, high=True)


def _wellness_recipients(w):
    from .models import CircleMember
    from .push import circle_family_users, member_peer_user
    ids = [i for i in (w.watcher_ids or []) if str(i).isdigit()]
    if ids:
        out = []
        for m in CircleMember.objects.filter(user=w.parent, pk__in=ids,
                                             state="accepted", blocked=False):
            u = member_peer_user(m)
            if u is not None and u.pk != w.parent_id:
                out.append(u)
        if out:
            return out
    return circle_family_users(w.parent)


def _sweep_wellness(now, stats):
    from . import push
    from .models import WellnessWatch
    for w in WellnessWatch.objects.filter(enabled=True, parent_opt_in=True).select_related("parent"):
        cfg = {"enabled": True, "parent_opt_in": True, "period_hours": w.period_hours,
               "response_window_min": w.response_window, "quiet_start": w.quiet_start,
               "quiet_end": w.quiet_end}
        act = _activity(w)
        if act and w.prompt_sent_at and act > w.prompt_sent_at:
            w.prompt_sent_at, w.alert_sent_at = None, None   # they came back
            w.save(update_fields=["prompt_sent_at", "alert_sent_at"])
        state, _ = SJ.wellness_state(cfg, _naive_local(act), now=_naive_local(now),
                                     prompt_sent_at=_naive_local(w.prompt_sent_at))
        if state == "prompt" and w.prompt_sent_at is None:
            push.safe_push(w.parent, "family_alert", "সব ঠিক আছে তো?", "Is everything OK?",
                           "ট্যাপ করে জানান আপনি ভালো আছেন, পরিবার নিশ্চিন্ত থাকবে।",
                           "Tap to let your family know you're fine.",
                           data={"route": "journey/wellness", "event": "wellness_prompt"},
                           high_priority=True)
            w.prompt_sent_at = now
            w.save(update_fields=["prompt_sent_at"])
            stats["wellness_prompt"] += 1
        elif state == "alert" and w.alert_sent_at is None:
            # family100: one delivery function (consent, idempotency, audit)
            from . import family_alerts as FA

            def _txt(name, lang):
                pl = SJ.wellness_payload(name, lang=lang)
                return pl["title"], pl["body"]
            FA.alert(w.parent, "wellness_alert",
                     "wellness:%s:%s" % (w.pk, int((w.prompt_sent_at or now).timestamp())),
                     payload={"event": "wellness_alert"},
                     recipients=_wellness_recipients(w), texts=_txt, now=now)
            w.alert_sent_at = now
            w.save(update_fields=["alert_sent_at"])
            stats["wellness_alert"] += 1


def _sweep_checkins(now, stats):
    from . import push
    from .logic import safety as SAF
    from .models import SafetyCheckin
    for c in SafetyCheckin.objects.filter(arrived=False, alerted_at__isnull=True,
                                          eta__isnull=False,
                                          eta__gte=now - timedelta(hours=24)).select_related("user"):
        state, mins = SAF.checkin_status(c.eta, now=now, grace_minutes=c.grace_min)
        if state != "overdue":
            continue
        # family100: one delivery function (consent, idempotency, audit,
        # quiet hours); the event key makes a re-run a no-op.
        from . import family_alerts as FA

        def _txt(name, lang, c=c, mins=mins):
            pl = SAF.checkin_overdue_payload(
                name, c.place, bn_num(mins) if lang == "bn" else mins, lang)
            return pl["title"], pl["body"]
        FA.alert(c.user, "checkin_overdue", "checkin:%s" % c.id,
                 payload={"event": "checkin_overdue", "checkin_id": c.id},
                 texts=_txt, now=now)
        c.alerted_at = now
        c.save(update_fields=["alerted_at"])
        stats["checkin_alert"] += 1
    # they arrived after all: the family's urgent cards about it go stale
    from .models import FamilyAlert
    done = SafetyCheckin.objects.filter(arrived=True, alerted_at__isnull=False,
                                        arrived_at__gte=now - timedelta(hours=24))
    for c in done:
        FamilyAlert.objects.filter(kind__in=("journey", "checkin_overdue"),
                                   dismissed=False,
                                   payload__checkin_id=c.id).update(dismissed=True)


def routine_start_time(r):
    """HH:MM to remind: the routine's 'home by' time minus its trip minutes."""
    try:
        h, m = (int(x) for x in str(r.time).split(":"))
    except (ValueError, AttributeError):
        return None
    t = (h * 60 + m - int(r.minutes or 0)) % (24 * 60)
    return "%02d:%02d" % (t // 60, t % 60)


def _sweep_routines(now, stats):
    """At (home-by - trip minutes) the traveller gets one push a day: start a
    Safe Journey. The server cannot start one (only the user can start the
    location service); a started journey then has the full overdue chain."""
    from .models import Journey, JourneyRoutine
    local = _naive_local(now)
    for r in JourneyRoutine.objects.filter(enabled=True).select_related("user"):
        start = routine_start_time(r)
        if start is None:
            continue
        d = {"enabled": True, "days": r.days, "time": start}
        if not SJ.routine_due(d, now=local, last_started=_naive_local(r.last_fired_at)):
            continue
        r.last_fired_at = now
        r.save(update_fields=["last_fired_at"])
        if Journey.objects.filter(traveller=r.user, status="active").exists():
            continue   # already on a journey
        dest_bn = (r.destination or {}).get("name") or "গন্তব্য"
        dest_en = (r.destination or {}).get("name") or "your destination"
        by_bn, by_en = bn_num(r.time), r.time
        push_traveller(r.user, "", "routine",
                       "নিরাপদ যাত্রা শুরু করবেন?", "Start your Safe Journey?",
                       "%s-এর মধ্যে %s পৌঁছানোর রুটিন। ট্যাপ করে যাত্রা শুরু করুন, দেরি হলে আপনার পরিচিতরা জানবেন।" % (by_bn, dest_bn),
                       "Your routine: %s by %s. Tap to start a journey; your people are told if you're late." % (dest_en, by_en))
        stats["routine"] += 1


def sweep(now=None):
    """One pass. Safe to run every minute, twice, or concurrently with views."""
    from collections import Counter
    from .models import Journey
    now = now or timezone.now()
    stats = Counter()
    for j in Journey.objects.filter(status="active").select_related("traveller"):
        try:
            _sweep_journey(j, now, stats)
        except Exception as e:
            stats["errors"] += 1
            log.warning("journey_sweep: journey %s %s", j.id, type(e).__name__)
    from . import family_alerts as FA

    def _sweep_family(now, stats):
        FA.sweep(now, stats)
    for fn in (_sweep_retry, _sweep_wellness, _sweep_checkins, _sweep_routines,
               _sweep_privacy, _sweep_family):
        try:
            fn(now, stats)
        except Exception as e:
            stats["errors"] += 1
            log.warning("journey_sweep: %s %s", fn.__name__, type(e).__name__)
    return dict(stats)
