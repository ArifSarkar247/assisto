"""
guardian_journey.py — owner idea 1 (28 Oct): the GUARDIAN-REQUESTED journey,
the reverse of Safe Journey. Baba sets a destination and a time window and
asks; the traveller sees "Baba wants to follow your trip today — Chattogram,
15:00–21:00" and accepts with one tap. At the window start sharing begins;
arrival tells Baba; at the window end it stops by itself.

Built ON Safe Journey: starting creates an ordinary Journey (eta = window
end, the requester as the only watcher, location kept 0 hours), so the
server sweeper's late flow is the same one — "Are you OK?" to the traveller
first, only without an answer the requester gets the last location; the
second alert also reaches the traveller's close family in My Circle.

SAFEGUARDS (server rules, each with a test in core/tests_guardian_journey.py):
  * consent every time for adults — a request is one window; there is NO
    standing auto-accept for adults (`standing` is refused);
  * child mode only for the requester's own child (requester's edge says
    'child' AND the child's own edge says father/mother/parent) under 18
    (declared by the parent); the child accepts the school schedule once and
    still always sees the banner, and can stop any single trip;
  * hard auto-end at the window end (+ at most HARD_TAIL_MIN for the late
    check only);
  * location points deleted when the trip ends (retention 0 h) — only the
    summary (start / arrival / end times, outcome) stays;
  * never silent: every start, stop, end and escalation sends the traveller a
    visible notice; the live screen shows "<name> is watching — Stop";
  * one-tap stop for the traveller, no PIN, the requester is told;
  * audit log on both sides; free on every plan (billing.SAFETY_EXEMPT —
    nothing here charges); spam caps (pending per pair, per day).

STARTING "BY ITSELF" (honest): Android forbids a location foreground service
from the background without ACCESS_BACKGROUND_LOCATION, which Assisto does
not request. If the app is open at the start time it starts at once;
otherwise the sweeper sends a high-priority "tap to start" notification and
that ONE tap starts sharing. The app says so.
"""
import logging
from datetime import datetime, time as dtime, timedelta

from django.utils import timezone

from . import journey_watch as JW
from .logic import safety_journey as SJ

log = logging.getLogger(__name__)

MAX_WINDOW_HOURS = 24
MAX_AHEAD_DAYS = 7
HARD_TAIL_MIN = 45          # after the window end: only the late check runs (ask +10, requester +20, family +35)
PENDING_PER_PAIR = 3
DAILY_PER_REQUESTER = 10
CHILD_EDGE = "child"
PARENT_EDGES = ("father", "mother", "parent")
DAYS = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")

LIVE = ("pending", "accepted", "active")


def pick(lang, bn, en):
    return SJ.pick(lang, bn, en)


def edge(owner, peer):
    """owner's accepted, unblocked My Circle edge to peer (or None)."""
    from .models import CircleMember
    if owner is None or peer is None:
        return None
    return (CircleMember.objects
            .filter(user=owner, peer_user=peer, state="accepted", blocked=False)
            .first())


def is_child_pair(requester, traveller):
    """Child mode is allowed only when BOTH sides say parent/child."""
    a, b = edge(requester, traveller), edge(traveller, requester)
    return bool(a and b and a.relation == CHILD_EDGE and b.relation in PARENT_EDGES)


def _now():
    return timezone.now()


def add_log(req, who, what, now=None, **extra):
    row = {"at": (now or _now()).isoformat(), "who": who, "what": what}
    row.update({k: v for k, v in extra.items() if v not in (None, "")})
    req.log = (list(req.log or []) + [row])[-60:]


def _name(viewer, user):
    from . import push
    return push.seen_name(viewer, user)


def _hhmm(dt, lang):
    return JW._hhmm(dt, lang)


def _dest(req, lang):
    return (req.destination or {}).get("name") or pick(lang, "গন্তব্য", "the destination")


def notify(user, req, kind, tbn, ten, bbn, ben, high=False):
    """Visible notice (push + in-app row). Never raises."""
    from . import push
    from .models import NotifEvent
    data = {"route": "journey/requests", "event": kind, "request_id": req.id}
    try:
        NotifEvent.objects.create(user=user, type="safe_journey", title_bn=tbn[:200],
                                  title_en=ten[:200], body_bn=bbn, body_en=ben,
                                  route="journey/requests", meta=dict(data))
    except Exception as e:
        log.warning("guardian: in-app row failed %s", type(e).__name__)
    try:
        push.safe_push(user, "family_alert", tbn, ten, bbn, ben, data=data,
                       high_priority=high)
    except Exception:
        pass


# ------------------------------------------------------------- windows
def _local(dt):
    return timezone.localtime(dt)


def occurrence(req, now):
    """(start, end) of the window that applies at/after `now` today.
    One-off: the request's own window. Standing (child school mode): today's
    schedule window in local time (None when today is not a school day or
    today's window is over)."""
    if not req.standing:
        return req.window_start, req.window_end
    sch = req.schedule or {}
    loc = _local(now)
    if DAYS[loc.weekday()] not in (sch.get("days") or []):
        return None
    try:
        sh, sm = [int(x) for x in str(sch.get("start")).split(":")]
        eh, em = [int(x) for x in str(sch.get("end")).split(":")]
    except (TypeError, ValueError):
        return None
    tz = loc.tzinfo
    start = datetime.combine(loc.date(), dtime(sh, sm), tz)
    end = datetime.combine(loc.date(), dtime(eh, em), tz)
    if end <= start or now >= end:
        return None
    return start, end


def validate_new(requester, traveller, d, now):
    """(clean dict, error code)."""
    from .logic import journey_dest as JD
    if traveller is None or traveller.pk == requester.pk:
        return None, "bad_person"
    if edge(requester, traveller) is None or edge(traveller, requester) is None:
        return None, "not_in_circle"
    dest = d.get("destination") if isinstance(d.get("destination"), dict) else {}
    name = " ".join(str(dest.get("name") or "").split())[:120]
    clean_dest = {"name": name}
    if dest.get("lat") not in (None, "") or dest.get("lng") not in (None, ""):
        got = JD._ok(dest.get("lat"), dest.get("lng"))
        if got is None:
            return None, "bad_coords"
        clean_dest.update(lat=got[0], lng=got[1])
    if not name and "lat" not in clean_dest:
        return None, "destination_required"
    standing = bool(d.get("standing"))
    out = {"destination": clean_dest, "note": " ".join(str(d.get("note") or "").split())[:200],
           "standing": standing, "schedule": {}}
    if standing:
        # child school mode — never for adults
        if not (is_child_pair(requester, traveller) and d.get("minor_declared") is True):
            return None, "standing_child_only"
        sch = d.get("schedule") if isinstance(d.get("schedule"), dict) else {}
        days = [x for x in (sch.get("days") or []) if x in DAYS]
        try:
            sh, sm = [int(x) for x in str(sch.get("start")).split(":")]
            eh, em = [int(x) for x in str(sch.get("end")).split(":")]
            ok = 0 <= sh < 24 and 0 <= eh < 24 and 0 <= sm < 60 and 0 <= em < 60 \
                and (eh, em) > (sh, sm) and (eh * 60 + em) - (sh * 60 + sm) <= 12 * 60
        except (TypeError, ValueError):
            ok = False
        if not days or not ok:
            return None, "bad_schedule"
        out["schedule"] = {"days": days, "start": "%02d:%02d" % (sh, sm),
                           "end": "%02d:%02d" % (eh, em)}
        # the request's own window = when consent for the schedule is needed by
        out["window_start"] = now
        out["window_end"] = now + timedelta(days=365)
        return out, None
    from django.utils.dateparse import parse_datetime
    ws, we = parse_datetime(str(d.get("start") or "")), parse_datetime(str(d.get("end") or ""))
    if ws is None or we is None:
        return None, "bad_window"
    if timezone.is_naive(ws):
        ws = timezone.make_aware(ws)
    if timezone.is_naive(we):
        we = timezone.make_aware(we)
    if we <= ws or we <= now:
        return None, "bad_window"
    if we - ws > timedelta(hours=MAX_WINDOW_HOURS):
        return None, "window_too_long"
    if ws > now + timedelta(days=MAX_AHEAD_DAYS):
        return None, "too_far_ahead"
    out["window_start"], out["window_end"] = max(ws, now), we
    return out, None


def spam_ok(requester, traveller, now):
    from .models import JourneyRequest
    pend = JourneyRequest.objects.filter(requester=requester, traveller=traveller,
                                         status="pending").count()
    if pend >= PENDING_PER_PAIR:
        return "too_many_pending"
    day = JourneyRequest.objects.filter(requester=requester,
                                        created_at__gte=now - timedelta(days=1)).count()
    if day >= DAILY_PER_REQUESTER:
        return "daily_limit"
    return None


def request_texts(req, lang, name):
    s, e = occurrence(req, _now()) or (req.window_start, req.window_end)
    if req.standing:
        sch = req.schedule or {}
        return (pick(lang, "%s স্কুলের সময় আপনার যাত্রা দেখতে চান" % name,
                     "%s wants to follow your school trips" % name),
                pick(lang, "%s, %s–%s, স্কুলের দিনগুলোতে। আপনার স্ক্রিনে সবসময় দেখা যাবে কে দেখছেন।" % (
                    _dest(req, lang), JW.bn_num(sch.get("start", "")), JW.bn_num(sch.get("end", ""))),
                     "%s, %s–%s on school days. Your screen always shows who is watching." % (
                    _dest(req, lang), sch.get("start", ""), sch.get("end", ""))))
    return (pick(lang, "%s আজ আপনার যাত্রা দেখতে চান" % name,
                 "%s wants to follow your trip" % name),
            pick(lang, "%s, %s থেকে %s। রাজি হলে শুধু এই সময়টুকু আপনার লোকেশন দেখবেন।" % (
                _dest(req, lang), _hhmm(s, lang), _hhmm(e, lang)),
                 "%s, %s to %s. If you agree, they see your location only in this window." % (
                _dest(req, lang), _hhmm(s, lang), _hhmm(e, lang))))


def as_dict(req, viewer, lang="bn"):
    mine = viewer.pk == req.requester_id
    other = req.traveller if mine else req.requester
    now = _now()
    occ = occurrence(req, now)
    j = req.journey
    live = j is not None and j.status == "active"
    out = {
        "id": req.id, "role": "requester" if mine else "traveller",
        "name": _name(viewer, other), "status": req.status, "outcome": req.outcome,
        "destination": req.destination or {}, "note": req.note,
        "window_start": req.window_start.isoformat(), "window_end": req.window_end.isoformat(),
        "standing": req.standing, "schedule": req.schedule or {},
        "today_start": occ[0].isoformat() if occ else None,
        "today_end": occ[1].isoformat() if occ else None,
        "in_window": bool(occ and occ[0] <= now < occ[1]),
        "journey_id": j.id if live else None,
        "started_at": req.started_at.isoformat() if req.started_at else None,
        "arrived_at": req.arrived_at.isoformat() if req.arrived_at else None,
        "ended_at": req.ended_at.isoformat() if req.ended_at else None,
        "log": list(req.log or [])[-20:],
    }
    if mine and live:
        fx = JW.fix_of(j)
        out["live"] = {"lat": fx[0] if fx else None, "lng": fx[1] if fx else None,
                       "fix_age_s": int((now - fx[2]).total_seconds()) if fx and fx[2] else None,
                       "url": JW.web_url(j), **JW.progress(j, fx)}
    return out


# ------------------------------------------------------------- actions
def start_trip(req, now=None):
    """Create the Journey for the current window. (journey, error)."""
    from .models import Journey, JourneyWatcher
    now = now or _now()
    if req.status == "active" and req.journey_id and req.journey.status == "active":
        return req.journey, None
    if req.status != "accepted":
        return None, "not_accepted"
    occ = occurrence(req, now)
    if occ is None or now < occ[0] - timedelta(minutes=15):
        return None, "not_in_window"
    start, end = occ
    member = edge(req.traveller, req.requester)
    if member is None:
        return None, "not_in_circle"
    for old in Journey.objects.filter(traveller=req.traveller, status="active"):
        old.status, old.stopped_at = "stopped", now
        old.expires_at = JW.ended_expiry(old, now)
        old.save(update_fields=["status", "stopped_at", "expires_at"])
    j = Journey.objects.create(
        traveller=req.traveller, destination=dict(req.destination or {}), eta=end,
        status="active", overdue_grace_min=10, location_retention_hours=0,
        stop_alert_min=20, expires_at=end + timedelta(minutes=HARD_TAIL_MIN + 30),
        last_activity_at=now, moved_at=now)
    JourneyWatcher.objects.create(journey=j, member=member)
    req.journey, req.status, req.started_at, req.ended_at = j, "active", now, None
    req.arrived_at, req.outcome = None, ""
    add_log(req, "traveller", "started", now)
    req.save()
    JW.emit(j, "started", payload={})
    rn = _name(req.traveller, req.requester)
    notify(req.traveller, req, "watching",
           "%s আপনার যাত্রা দেখছেন" % rn, "%s is watching your trip" % rn,
           "%s পর্যন্ত। যেকোনো সময় এক ট্যাপে বন্ধ করতে পারেন।" % _hhmm(end, "bn"),
           "Until %s. You can stop it any time with one tap." % _hhmm(end, "en"))
    return j, None


def _close_journey(j, now, status="stopped"):
    if j is None or j.status != "active":
        return
    j.status, j.stopped_at = status, now
    j.expires_at = now               # retention 0 h: points go on the next sweep
    j.save(update_fields=["status", "stopped_at", "expires_at"])
    JW.expire(j)                     # and right now: no path is kept
    JW.clear_urgent(j)


def finish(req, outcome, now=None, by=""):
    """End the current trip. One-off -> final status; standing -> back to
    'accepted' for the next school day."""
    now = now or _now()
    j = req.journey
    if j is not None and j.status == "active":
        _close_journey(j, now)
    req.ended_at, req.outcome = now, outcome
    if outcome == "arrived" and req.arrived_at is None:
        req.arrived_at = now
    req.status = "accepted" if (req.standing and outcome != "cancelled") else (
        "arrived" if outcome == "arrived" else "ended")
    add_log(req, by or "server", outcome, now)
    req.save()


def stop_by_traveller(req, now=None):
    now = now or _now()
    finish(req, "stopped_by_traveller", now, by="traveller")
    tn = _name(req.requester, req.traveller)
    notify(req.requester, req, "stopped",
           "%s যাত্রা দেখা বন্ধ করেছেন" % tn, "%s stopped sharing the trip" % tn,
           "%s নিজে শেয়ার বন্ধ করেছেন। চাইলে ফোন করে খোঁজ নিন।" % tn,
           "%s turned sharing off. Call them if you are worried." % tn, high=True)
    notify(req.traveller, req, "stopped_self",
           "যাত্রা শেয়ার বন্ধ হয়েছে", "Trip sharing is off",
           "আর কেউ আপনার লোকেশন দেখছেন না।", "Nobody is seeing your location now.")


# --------------------------------------------------------------- sweep
def _nudge(req, now, occ):
    rn = _name(req.traveller, req.requester)
    notify(req.traveller, req, "start_now",
           "%s এখন আপনার যাত্রা দেখছেন — শুরু করতে ট্যাপ করুন" % rn,
           "%s is following your trip now — tap to start" % rn,
           "%s, %s পর্যন্ত। ট্যাপ করলে শেয়ার শুরু হবে; যেকোনো সময় বন্ধ করা যায়।" % (
               _dest(req, "bn"), _hhmm(occ[1], "bn")),
           "%s, until %s. Tap to start sharing; you can stop any time." % (
               _dest(req, "en"), _hhmm(occ[1], "en")), high=True)
    req.nudged_at = now
    add_log(req, "server", "start_reminder", now)
    req.save(update_fields=["nudged_at", "log", "updated_at"])


def sweep(now=None, stats=None):
    from .models import JourneyRequest
    now = now or _now()
    stats = stats if stats is not None else {}

    def bump(k):
        stats[k] = stats.get(k, 0) + 1

    # unanswered when the window starts -> expired (never a silent start)
    for req in JourneyRequest.objects.filter(status="pending", window_start__lte=now,
                                             standing=False):
        req.status, req.outcome = "expired", "not_answered"
        add_log(req, "server", "expired", now)
        req.save()
        tn = _name(req.requester, req.traveller)
        notify(req.requester, req, "expired", "অনুরোধের উত্তর আসেনি", "No answer to your request",
               "%s সময় শুরুর আগে রাজি হননি, তাই কিছু শেয়ার হবে না।" % tn,
               "%s did not accept before the window began, so nothing is shared." % tn)
        bump("req_expired")
    for req in JourneyRequest.objects.filter(status="accepted").select_related(
            "requester", "traveller", "journey"):
        occ = occurrence(req, now)
        if not req.standing and now >= req.window_end:
            req.status, req.outcome = "ended", "not_started"
            add_log(req, "server", "not_started", now)
            req.save()
            tn = _name(req.requester, req.traveller)
            notify(req.requester, req, "not_started", "যাত্রা শেয়ার শুরু হয়নি",
                   "Trip sharing never started",
                   "%s-এর ফোন থেকে এই সময়ে শেয়ার শুরু হয়নি (ফোন বন্ধ বা ট্যাপ করা হয়নি)। ফোন করে খোঁজ নিন।" % tn,
                   "%s's phone did not start sharing in the window (phone off or not tapped). Please call them." % tn,
                   high=True)
            bump("req_not_started")
            continue
        if occ and occ[0] <= now < occ[1] and (req.nudged_at is None or req.nudged_at < occ[0]):
            _nudge(req, now, occ)
            bump("req_nudged")
    for req in JourneyRequest.objects.filter(status="active").select_related(
            "requester", "traveller", "journey"):
        j = req.journey
        if j is None:
            finish(req, "ended", now)
            continue
        if j.status == "arrived":
            req.arrived_at = j.stopped_at or now
            finish(req, "arrived", now, by="traveller")
            bump("req_arrived")
            continue
        if j.status != "active":
            finish(req, "ended", now)
            continue
        # never silent: the traveller is told when the requester was alerted
        if j.escalations and not any(r.get("what") == "escalated" and
                                     r.get("n") == j.escalations for r in (req.log or [])):
            rn = _name(req.traveller, req.requester)
            add_log(req, "server", "escalated", now, n=j.escalations)
            req.save(update_fields=["log", "updated_at"])
            notify(req.traveller, req, "escalated",
                   "%s-কে জানানো হয়েছে" % rn, "%s has been told" % rn,
                   "আপনি সাড়া দেননি, তাই %s আপনার শেষ লোকেশন পেয়েছেন। ভালো থাকলে অ্যাপে জানান।" % rn,
                   "You did not answer, so %s got your last location. Open the app if you're OK." % rn,
                   high=True)
            bump("req_escalation_notice")
        end = j.eta or req.window_end
        if now >= end + timedelta(minutes=HARD_TAIL_MIN):
            finish(req, "window_end", now)
            rn = _name(req.traveller, req.requester)
            notify(req.traveller, req, "auto_end", "যাত্রা শেয়ার নিজে থেকে বন্ধ হয়েছে",
                   "Trip sharing ended by itself",
                   "সময় শেষ, তাই %s আর আপনার লোকেশন দেখছেন না। পথের লোকেশন মুছে ফেলা হয়েছে।" % rn,
                   "The window is over, so %s no longer sees your location. The trip's path was deleted." % rn)
            tn = _name(req.requester, req.traveller)
            notify(req.requester, req, "auto_end", "সময় শেষ — শেয়ার বন্ধ", "Window over — sharing stopped",
                   "%s-এর যাত্রা শেয়ার সময় শেষে বন্ধ হয়েছে।" % tn,
                   "%s's trip sharing stopped at the end of the window." % tn)
            bump("req_auto_end")
    return stats
