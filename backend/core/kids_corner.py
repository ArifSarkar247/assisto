"""sjkids — Children Corner delivery + seams (Safe Journey v2, 9 Nov).

The rules are pure (logic/kids_corner.py); this module tells the right
people and connects the corner to Family Care:

  * deliver(plan, ev)   — kc_* events from the school-plan pipelines
                          (kids watch, tracker chip, the child's phone);
  * fences_for(user)    — the child's corner places as ON-PHONE geofences
                          for fcbrain's FamilyWatchService (zero Google cost);
  * on_brain_event(user, e) — an on-phone arrive / leave from fcbrain's
                          ping: corner places update the child's plan day.
                          Returns "guardians" when fcbrain must NOT fan the
                          event out to the whole family (a watch place),
                          "family" for a safe place (Family Care shows it),
                          None when the event is not a corner place.

Trust: only the plan's guardians (owner + watchers + co-guardians, the
existing guardianship.alert_audience) ever hear about a child; the child sees
every plan about them and can stop it. Coordinates never go into
notification rows or logs (admin views never see a child's location) — only
the guardian-only plan API returns the question's last position.
"""
import logging
import uuid

from django.utils import timezone

from .logic import kids_corner as KC
from .logic import school_mode as SM

log = logging.getLogger(__name__)

KIND_BN = {"home": "বাসা", "school": "স্কুল", "coaching": "কোচিং", "tuition": "প্রাইভেট পড়া",
           "playground": "খেলার মাঠ", "relative": "আত্মীয়ের বাসা", "other": "নিরাপদ জায়গা",
           "market": "বাজার", "river": "নদী", "highway": "হাইওয়ে",
           "watch_other": "নজরের জায়গা"}
KIND_EN = {"home": "home", "school": "school", "coaching": "coaching", "tuition": "tuition",
           "playground": "the playground", "relative": "a relative's house",
           "other": "a safe place", "market": "the market", "river": "the river",
           "highway": "the highway", "watch_other": "a watched place"}


def place_text(kind, name, lang):
    n = str(name or "").strip()
    if n:
        return n
    return (KIND_EN if lang == "en" else KIND_BN).get(kind, "")


def texts(ev, child):
    """(title_bn, title_en, body_bn, body_en) for a corner event."""
    from . import kidswatch_service as KW
    k = ev["kind"]
    at = KC._parse(ev.get("at")) or timezone.now()
    pb = place_text(ev.get("place_kind"), ev.get("place_name"), "bn")
    pe = place_text(ev.get("place_kind"), ev.get("place_name"), "en")
    tb, te = KW._clock(at, "bn"), KW._clock(at, "en")
    if k == "kc_arrive":
        return ("%s %s পৌঁছেছে" % (child, pb), "%s reached %s" % (child, pe),
                "%s-এ পৌঁছেছে (স্বয়ংক্রিয়)।" % tb, "Arrived at %s (automatic)." % te)
    if k == "kc_leave":
        return ("%s %s থেকে বের হয়েছে" % (child, pb), "%s left %s" % (child, pe),
                "%s-এ বের হয়েছে (স্বয়ংক্রিয়)।" % tb, "Left at %s (automatic)." % te)
    if k == "kc_watch_enter":
        return ("%s %s এলাকায় ঢুকেছে" % (child, pb), "%s entered %s" % (child, pe),
                "%s-এ ঢুকেছে — এটা আপনার নজরের জায়গা। ঠিক আছে কি না একবার দেখে নিন।" % tb,
                "Entered at %s — a place you asked us to watch. Check that all is well." % te)
    if k == "kc_ask_unknown":
        return ("%s এখন কোথায়, আপনি জানেন?" % child, "Do you know where %s is?" % child,
                "%s-এর সময়ে %s কোনো নিরাপদ জায়গায় নেই। আপনি জানলে 'আমি জানি' চাপুন; "
                "না জানলে ফোন করুন বা শেষ অবস্থান দেখুন।" % (pb, child),
                "During %s hours %s is not at any safe place. Tap 'I know' if you do; "
                "otherwise call or see the last location." % (pe, child))
    if k == "kc_back_safe":
        return ("%s আবার নিরাপদ জায়গায়" % child, "%s is back at a safe place" % child,
                "%s-এ নিরাপদ জায়গায় ফিরেছে। প্রশ্নটা বন্ধ হয়েছে।" % tb,
                "Back at a safe place at %s. The question is closed." % te)
    return ("", "", "", "")


def _family_news(plan, ev):
    """Safe-place arrive / leave -> Family Care's timeline + family news via
    fcbrain's ping (the same path the phone uses). True when fcbrain took it."""
    child = plan.child_user
    if child is None:
        return False
    try:
        from . import family_brain as FB   # fcbrain (Family Care v3)
    except Exception:  # noqa: BLE001
        return False
    try:
        FB.ping(child, {"events": [{
            "id": "kc%d-%s" % (plan.id, uuid.uuid4().hex[:10]),
            "kind": "arrive" if ev["kind"] == "kc_arrive" else "leave",
            "at": ev.get("at"), "place_kind": "school" if ev.get("place_kind") == "school"
            else "place",
            "place_label": place_text(ev.get("place_kind"), ev.get("place_name"), "bn")}]})
        return True
    except Exception as e:  # noqa: BLE001
        log.warning("kids_corner: family news failed %s", type(e).__name__)
        return False


def deliver(plan, ev, now=None):
    """Store the history row and tell the plan's guardians. 'family' = Family
    Care news (fcbrain) or, without it, an in-app note; 'push' = normal push +
    card; 'ask' = the guardian question (push + card with the answer buttons)."""
    from .models import SchoolEvent
    from . import kidswatch_service as KW
    now = now or timezone.now()
    kind = ev["kind"]
    try:
        SchoolEvent.objects.create(
            plan=plan, kind=kind[:24], at=now,
            lat=ev.get("lat") if kind in ("kc_ask_unknown", "kc_watch_enter") else None,
            lng=ev.get("lng") if kind in ("kc_ask_unknown", "kc_watch_enter") else None,
            source=str(ev.get("source") or "")[:8],
            detail={k: v for k, v in ev.items()
                    if k in ("place_id", "place_kind", "place_name", "ask_id", "notify")})
    except Exception:  # noqa: BLE001
        log.warning("kids_corner: event not stored")
    if ev.get("notify") == "family" and ev.get("source") != "phone_fence" \
            and _family_news(plan, ev):
        return
    tb, te, bb, be = texts(ev, plan.child_name or "?")
    if not tb:
        return
    meta = {"plan_id": plan.id, "event": kind, "place_kind": ev.get("place_kind", "")}
    if ev.get("ask_id"):
        meta["ask_id"] = ev["ask_id"]
    n = ev.get("notify")
    KW._send(KW.plan_watchers(plan), tb, te, bb, be, meta,
             family_alert=n in ("push", "ask"), push_it=n in ("push", "ask", "family"),
             high=False, route="kids_corner")


# ------------------------------------------------------------ fcbrain seam

def _phone_plans(user):
    from .models import SchoolPlan
    return list(SchoolPlan.objects.filter(child_user=user, enabled=True,
                                          accepted_at__isnull=False)[:5])


def fences_for(user):
    """The child's corner places as on-phone fences (fcbrain format)."""
    out = []
    for p in _phone_plans(user):
        try:
            cfg = SM.validate(p.config)
        except ValueError:
            continue
        for x in KC.places(cfg):
            out.append({"id": KC.fence_id(p.id, x["id"]),
                        "kind": "school" if x["kind"] == "school" else "place",
                        "label": place_text(x["kind"], x["name"], "bn")[:40],
                        "lat": x["lat"], "lng": x["lng"], "r": x["radius_m"]})
    return out[:KC.MAX_PLACES]


def on_brain_event(user, e, now=None):
    """fcbrain ping hook: e = fcbrain's cleaned event {kind, at, place_id,
    place_kind}. Home / School of the child's own saved places update the
    corner's 'inside' too (so no false question while the phone fence says
    the child is at school)."""
    from .models import SchoolPlan
    now = now or timezone.now()
    if e.get("kind") not in ("arrive", "leave"):
        return None
    parsed = KC.parse_fence_id(e.get("place_id"))
    if parsed:
        plans = [p for p in _phone_plans(user) if p.id == parsed[0]]
        pid = parsed[1]
    elif e.get("place_kind") in ("home", "school"):
        plans = _phone_plans(user)
        pid = KC.HOME_ID if e["place_kind"] == "home" else KC.SCHOOL_ID
    else:
        return None
    from . import kidswatch_service as KW
    role = None
    for plan in plans:
        try:
            cfg = SM.validate(plan.config)
        except ValueError:
            continue
        at = e.get("at") or now
        local = at.astimezone(KW.LOCAL_TZ)
        day, evs = KC.on_fence_event(cfg, plan.day, local, e["kind"], pid, "phone_fence")
        plan.day = day
        SchoolPlan.objects.filter(pk=plan.pk).update(day=day)
        for ev in evs:
            if ev["kind"] in ("kc_arrive", "kc_leave"):
                continue          # fcbrain shares safe-place news with the family itself
            deliver(plan, ev, now)
        x = next((p for p in KC.places(cfg) if p["id"] == pid), None)
        if parsed:
            role = "guardians" if (x and x["role"] == "watch") else "family"
    return role


def tick(plan, cfg, local, now):
    """Called from kidswatch_service.tick for every live plan."""
    import copy
    from .models import SchoolPlan
    day, evs = KC.on_tick(cfg, copy.deepcopy(plan.day or {}), local)
    if day != plan.day or evs:
        SchoolPlan.objects.filter(pk=plan.pk).update(day=day)
        plan.day = day
    for ev in evs:
        deliver(plan, ev, now)
    return len(evs)
