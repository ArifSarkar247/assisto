"""
journey_during.py — sjduring: Safe Journey V2 "DURING the trip" rules
(owner order 9 Nov 11:15, owner_actions/SAFE_JOURNEY_V2_SPEC_BN.md).

RULE: late does not mean danger and early does not mean safe. Safety comes
from SIGNALS, not the clock. When something looks wrong the traveller is
asked PRIVATELY first; the family hears only when there is no answer. Never
a red alert from lateness alone. Never a false Arrived.

  * STATES (traveller + watchers): moving | slow (Slow in traffic — still
    moving, never "late") | stopped (minutes) | off_route | nearly (inside
    1 km) | phone_off (+ last battery + honest reason) | arrived.
  * ALERT LADDER: signal -> private ask on the traveller's phone (5 min)
    -> amber "Check on NAME" to watchers -> red ONLY on a strong signal:
    danger PIN, SOS, phone suddenly off with good battery, or no answer
    10 more minutes after amber.
  * NEAR DESTINATION: inside 1 km lateness alerts stop; a stop there of
    30 min or more asks the traveller first (never the family first).
  * ARRIVAL: inside a radius by place type (home / office / house ~150 m;
    airport / bus terminal / rail station / launch ghat / university
    ~400 m) for 2 minutes. Abnormal arrival (too early, after leaving the
    route, after a long stop) needs the PIN; the traveller can require it
    always.
  * SECRET PIN: safe PIN -> watchers see "Confirmed with PIN". Danger PIN ->
    the traveller's screen shows a normal Arrived, watchers silently get red
    with live location and a 30 s audio clip.
  * NIGHT (22:00-06:00 Dhaka): tighter stop / no-location thresholds and a
    private check-in every 30 minutes (a missed night check-in alone never
    alerts anybody — it only adds to a real signal).

The pure functions below take plain values (no ORM) and are unit-tested
directly; `sweep_signal` / `answer` / `arrive_with_pin` are the thin ORM glue
the sweeper and views call. Ladder state lives in Journey.during (JSON).
"""
from datetime import timedelta
import logging

from django.utils import timezone

log = logging.getLogger(__name__)

# ----------------------------------------------------------------- tunables
NEAR_M = 1000                 # "Nearly there"
ASK_MIN = 5                   # private ask -> amber after this
RED_AFTER_MIN = 10            # amber -> red (no answer) after this
NEAR_STOP_MIN = 30            # stopped inside 1 km this long -> ask the traveller
STOPPED_SHOW_MIN = 3          # still this long = "Stopped"
DWELL_S = 120                 # inside the arrival circle this long = arrived
SLOW_KMH = 8.0                # vehicle crawling below this = "Slow in traffic"
MOVING_KMH = 2.0
NIGHT_FROM, NIGHT_TO = 22, 6  # local hours
NIGHT_STOP_MIN = 12           # night: a stop is a signal sooner
NIGHT_LOST_MIN = 10           # night: no location is a signal sooner
NIGHT_CHECKIN_MIN = 30        # night: private "Still OK?" this often
GOOD_BATT = 30                # phone off with >= this = "suddenly off"
EXTEND_DEFAULT = 40
COVER_MIN = 30                # danger PIN: keep live location this long
AUDIO_MAX_BYTES = 1_500_000   # 30 s AAC is ~250 KB; hard cap

VEHICLE_MODES = ("bus", "local_bus", "long_bus", "car", "cng", "bike", "ride",
                 "train", "metro", "launch")

# arrival radius by place type (metres)
RADIUS_SMALL = 150
RADIUS_BIG = 400
BIG_KINDS = ("airport", "bus_terminal", "rail_station", "launch_ghat", "university")
KIND_WORDS = (
    ("airport", ("airport", "বিমানবন্দর", "এয়ারপোর্ট", "এয়ারপোর্ট", "biman bondor")),
    ("bus_terminal", ("bus terminal", "terminal", "টার্মিনাল", "bus stand", "বাসস্ট্যান্ড",
                      "বাস স্ট্যান্ড", "bus counter")),
    ("rail_station", ("railway station", "rail station", "station", "স্টেশন", "রেলস্টেশন",
                      "রেল স্টেশন", "kamalapur", "কমলাপুর")),
    ("launch_ghat", ("launch ghat", "launch terminal", "ghat", "ঘাট", "sadarghat", "সদরঘাট")),
    ("university", ("university", "বিশ্ববিদ্যালয়", "বিশ্ববিদ্যালয়", "versity", "ভার্সিটি")),
)

# fastest believable door-to-door speed by mode (km/h, straight line).
# Used ONLY to reject an impossible arrival — never to call anybody late.
MAX_KMH = {"walk": 8, "rickshaw": 20, "cycle": 25, "local_bus": 60, "bus": 70,
           "long_bus": 90, "cng": 60, "bike": 90, "car": 100, "ride": 100,
           "train": 110, "metro": 80, "launch": 35}
MAX_KMH_DEFAULT = 100

STATES = ("moving", "slow", "stopped", "off_route", "nearly", "phone_off", "arrived")


# ------------------------------------------------------------- pure helpers
def is_night(local_dt):
    """22:00-06:00 local (Asia/Dhaka) — night journeys check in more often."""
    if local_dt is None:
        return False
    h = local_dt.hour
    return h >= NIGHT_FROM or h < NIGHT_TO


def place_kind(dest):
    """'home' | 'office' | 'airport' | 'bus_terminal' | 'rail_station' |
    'launch_ghat' | 'university' | 'other' — the start screen's own kind
    first, then the saved-place label, then words in the name."""
    dest = dest or {}
    k = str(dest.get("kind") or dest.get("place_type") or "").strip().lower()
    if k in BIG_KINDS or k in ("home", "office", "house", "school", "hospital"):
        return k
    lbl = str(dest.get("label") or "").strip().lower()
    if lbl in ("home", "office", "school"):
        return lbl
    name = " %s " % str(dest.get("name") or "").lower()
    for kind, words in KIND_WORDS:
        if any(w in name for w in words):
            return kind
    return "other"


def arrival_radius(dest):
    return RADIUS_BIG if place_kind(dest) in BIG_KINDS else RADIUS_SMALL


def _hav(a, b):
    from .logic.safety import haversine_m
    return haversine_m(a[0], a[1], b[0], b[1])


def dwell(points, dest_pt, radius_m, min_s=DWELL_S):
    """(arrived, seconds_inside). `points` = [(lat, lng, at)] oldest first.
    Arrived only when the NEWEST fix is inside the circle and the run of
    inside fixes ending there spans >= min_s. One lucky fix (a GPS jump)
    never arrives."""
    if not points or dest_pt is None:
        return False, 0
    if _hav(points[-1][:2], dest_pt) > radius_m:
        return False, 0
    first = points[-1]
    for p in reversed(points):
        if _hav(p[:2], dest_pt) > radius_m:
            break
        first = p
    span = (points[-1][2] - first[2]).total_seconds()
    return span >= min_s, int(span)


def earliest_possible(origin_pt, dest_pt, mode, started_at, given=None):
    """The earliest PHYSICALLY possible arrival ("Earlier than C is not
    possible"). The start screen's C (from Google Routes) wins; else the
    straight line at the fastest believable speed for the mode."""
    if given is not None:
        return given
    if origin_pt is None or dest_pt is None or started_at is None:
        return None
    d_km = _hav(origin_pt, dest_pt) / 1000.0
    v = MAX_KMH.get(str(mode or ""), MAX_KMH_DEFAULT)
    return started_at + timedelta(minutes=60.0 * d_km / v)


def classify(*, status, fix_age_min, lost_min, still_min, dist_m, off_route,
             speed_kmh, mode, lost_why="", battery=None):
    """The ONE state shown to the traveller and the watchers.
    Lateness is not an input on purpose: late while moving is "slow" or
    "moving", never an alarm."""
    if status == "arrived":
        return {"state": "arrived"}
    if fix_age_min is None or fix_age_min >= lost_min:
        out = {"state": "phone_off", "minutes": int(fix_age_min or 0)}
        if battery is not None:
            out["battery"] = int(battery)
        if lost_why:
            out["why"] = lost_why
        return out
    if dist_m is not None and dist_m <= NEAR_M:
        out = {"state": "nearly", "distance_m": int(dist_m)}
        if still_min >= STOPPED_SHOW_MIN:
            out["stopped_min"] = int(still_min)
        return out
    if off_route:
        return {"state": "off_route"}
    vehicle = str(mode or "") in VEHICLE_MODES
    if still_min >= STOPPED_SHOW_MIN:
        if vehicle and speed_kmh is not None and speed_kmh >= 12 and still_min < 45:
            # was going at vehicle speed just before: a jam, not a stop
            return {"state": "slow", "minutes": int(still_min)}
        return {"state": "stopped", "minutes": int(still_min)}
    if vehicle and speed_kmh is not None and MOVING_KMH <= speed_kmh < SLOW_KMH:
        return {"state": "slow"}
    return {"state": "moving"}


def late_alert_allowed(state):
    """Lateness may ask the traveller only when it is NOT moving and NOT
    nearly there (owner: late while moving = Slow in traffic only)."""
    return state.get("state") in ("stopped", "off_route")


def _iso(dt):
    return dt.isoformat() if dt else None


def _dt(s):
    from .logic import safety_journey as SJ
    d = SJ.parse_dt(s) if s else None
    if d is not None and timezone.is_naive(d):
        d = timezone.make_aware(d)
    return d


def ladder(during, signal, now):
    """Advance the alert ladder. `signal` = None or a dict {kind, key, ...}
    (kinds: off_route, long_stop, near_stop, late_stopped, phone_off,
    night_checkin). Returns (actions, during). Actions: ("ask", ask),
    ("amber", ask), ("red", ask), ("back", ask) (the phone is sending again
    after an amber). Pure: no ORM, no clock but `now`.

    A pending ask whose signal went away before amber (the bus moved on,
    the traveller is back on the route, the tea stop ended) is closed
    quietly — that is the main source of false alerts in the corpus."""
    d = dict(during or {})
    acts = []
    ask = dict(d.get("ask") or {}) or None
    if ask and not ask.get("answered"):
        same = signal is not None and signal.get("kind") == ask.get("kind")
        asked = _dt(ask.get("at"))
        if ask.get("kind") == "phone_off":
            if not same:
                ask["answered"] = "back"
                ask["answered_at"] = _iso(now)
                d["ask"] = ask
                acts.append(("back", ask))
                ask = None
        elif ask.get("kind") == "night_checkin":
            # a missed night check-in alone never alerts anybody
            if signal is None or signal.get("key") == ask.get("key") and \
                    signal.get("kind") == "night_checkin":
                return acts, d
            ask = None   # the next check-in, or a real signal, replaces it
        elif signal is None and not ask.get("amber_at"):
            ask["answered"] = "cleared"
            ask["answered_at"] = _iso(now)
            d["ask"] = ask
            ask = None
        if ask is not None:
            if not ask.get("amber_at") and asked and now - asked >= timedelta(minutes=ASK_MIN):
                ask["amber_at"] = _iso(now)
                acts.append(("amber", ask))
            amber = _dt(ask.get("amber_at"))
            if amber and not ask.get("red_at") and \
                    now - amber >= timedelta(minutes=RED_AFTER_MIN) and \
                    (ask.get("kind") != "phone_off" or ask.get("good_batt")):
                ask["red_at"] = _iso(now)
                acts.append(("red", ask))
            d["ask"] = ask
            return acts, d
    if signal is None:
        return acts, d
    done = list(d.get("done") or [])
    sid = "%s:%s" % (signal.get("kind"), signal.get("key"))
    if sid in done:
        return acts, d
    new = dict(signal)
    new["id"] = sid
    new["at"] = _iso(now)
    if signal.get("kind") == "phone_off":
        # the phone cannot be asked: watchers get amber at once (calm, with
        # the honest reason); red later only when the battery was good
        new["amber_at"] = _iso(now)
        acts.append(("amber", new))
    else:
        acts.append(("ask", new))
    if signal.get("kind") in ("off_route", "long_stop", "near_stop", "late_stopped"):
        ab = list(d.get("abnormal") or [])
        tag = "off_route" if signal.get("kind") == "off_route" else "long_stop"
        if tag not in ab:
            ab.append(tag)
        d["abnormal"] = ab
    done.append(sid)
    d["done"] = done[-40:]
    d["ask"] = new
    return acts, d


def answer_ask(during, action, now):
    """Traveller answered the private screen. -> (during, was_amber)."""
    d = dict(during or {})
    ask = dict(d.get("ask") or {})
    was_amber = bool(ask.get("amber_at"))
    if ask:
        ask["answered"] = action
        ask["answered_at"] = _iso(now)
        d["ask"] = ask
    d["last_answer"] = {"action": action, "at": _iso(now)}
    return d, was_amber


def pin_needed(during, *, always, too_early):
    """Why the arrival needs the PIN: [] = not needed."""
    why = []
    if too_early:
        why.append("too_early")
    for t in (during or {}).get("abnormal") or []:
        if t not in why:
            why.append(t)
    if always and not why:
        why.append("always")
    return why


# -------------------------------------------------------------- ORM glue
def local_now(now):
    return timezone.localtime(now)


def _pt(d):
    try:
        return (float(d["lat"]), float(d["lng"]))
    except (KeyError, TypeError, ValueError):
        return None


def given_earliest(j):
    for src in (j.destination or {}, j.vehicle or {}):
        v = src.get("earliest_at") if isinstance(src, dict) else None
        if v:
            return _dt(v)
    return None


def earliest_for(j):
    return earliest_possible(_pt(j.origin or {}), _pt(j.destination or {}),
                             (j.vehicle or {}).get("mode") or j.mode,
                             j.created_at, given_earliest(j))


def recent_points(j, since_s=1800, until=None):
    from .models import JourneyPoint
    q = JourneyPoint.objects.filter(journey=j)
    if until is not None:
        q = q.filter(at__lte=until)
        q = q.filter(at__gte=until - timedelta(seconds=since_s))
    rows = list(q.order_by("-at").values_list("lat", "lng", "at")[:120])
    rows.reverse()
    return rows


def state_of(j, now):
    """The live state dict for this journey (traveller + watchers)."""
    from . import journey_watch as JW
    from .logic import journey_dest as JD
    if j.status == "arrived":
        return {"state": "arrived"}
    fx = JW.fix_of(j)
    night = is_night(local_now(now)) or bool(j.night)
    lost = NIGHT_LOST_MIN if night else JW.LOST_FIX_MIN
    age = None
    if fx is not None and fx[2] is not None:
        age = (now - fx[2]).total_seconds() / 60.0
    elif fx is None:
        # no fix yet: the phone is "off" only once the start is that old
        age = (now - j.created_at).total_seconds() / 60.0
    why, batt = JW.lost_reason(j)
    if batt is None:
        loc = j.last_location or {}
        batt = loc.get("battery") if loc.get("battery") is not None else loc.get("battery_last")
    dest = _pt(j.destination or {})
    dist = None
    off = False
    speed = None
    still = 0.0
    if fx is not None:
        if dest is not None:
            dist = JD.distance_m(fx[0], fx[1], dest[0], dest[1])
        if j.route_deviation or dest is not None:
            off = JW.offroute(j, fx[0], fx[1])[0]
        if j.moved_at is not None:
            still = max(0.0, (now - j.moved_at).total_seconds() / 60.0)
        pts = recent_points(j, JD.SPEED_WINDOW_S, until=fx[2]) if fx[2] else []
        speed = JD.observed_kmh(pts)
        if speed is None and still >= STOPPED_SHOW_MIN and j.moved_at is not None:
            before = recent_points(j, 1800, until=j.moved_at)
            speed = JD.observed_kmh(before, window_s=1800)
    st = classify(status=j.status, fix_age_min=age, lost_min=lost, still_min=still,
                  dist_m=dist, off_route=off, speed_kmh=speed,
                  mode=(j.vehicle or {}).get("mode") or j.mode, lost_why=why,
                  battery=batt)
    st["night"] = night
    if st["state"] == "nearly" and st.get("stopped_min"):
        st["near_note"] = True   # "No alert even if late; asked after 30 min"
    return st


def _signal_for(j, st, now):
    """The ONE signal (or None) this sweep sees, from the state."""
    from . import journey_watch as JW
    s = st.get("state")
    night = st.get("night")
    if s == "phone_off":
        fx = JW.fix_of(j)
        key = fx[2].isoformat() if fx and fx[2] else "nofix"
        b = st.get("battery")
        good = (b is not None and int(b) >= GOOD_BATT and st.get("why") != "killed")
        return {"kind": "phone_off", "key": key, "battery": b,
                "why": st.get("why", ""), "good_batt": bool(good)}
    if s == "nearly":
        if st.get("stopped_min", 0) >= NEAR_STOP_MIN and j.moved_at:
            return {"kind": "near_stop", "key": j.moved_at.isoformat(),
                    "minutes": st["stopped_min"]}
        return None   # lateness alerts stop inside 1 km
    if s == "off_route":
        fx = JW.fix_of(j)
        return {"kind": "off_route", "key": (j.during or {}).get("off_since") or "1",
                "lat": fx[0] if fx else None, "lng": fx[1] if fx else None,
                "from": _last_on_route(j, now)}
    if s == "stopped":
        limit = int(j.stop_alert_min or 0)
        if limit <= 0:
            return None
        if night:
            limit = min(limit, NIGHT_STOP_MIN)
        from . import journey_mode as JM
        fx = JW.fix_of(j)
        dwell_kind, mlimit = JM.stop_rule(j, fx[0], fx[1]) if fx else (None, limit)
        if dwell_kind:
            limit = max(limit, int(mlimit))   # a train at a station / a ghat wait
        if st.get("minutes", 0) >= limit and j.moved_at:
            return {"kind": "long_stop", "key": j.moved_at.isoformat(),
                    "minutes": st["minutes"]}
        state, _m = JW.overdue(j, now)
        if state in ("ask", "alert") and late_alert_allowed(st) and j.moved_at:
            return {"kind": "late_stopped", "key": j.moved_at.isoformat(),
                    "minutes": st.get("minutes", 0)}
        return None
    if night and s in ("moving", "slow"):
        last = _dt((j.during or {}).get("night_at")) or j.created_at
        if now - last >= timedelta(minutes=NIGHT_CHECKIN_MIN):
            return {"kind": "night_checkin", "key": str(int(now.timestamp() // (NIGHT_CHECKIN_MIN * 60)))}
    return None


def _last_on_route(j, now):
    """{lat,lng} of the newest fix that was still on the route ("from")."""
    from . import journey_watch as JW
    for lat, lng, _at in reversed(recent_points(j, 3600, until=now)):
        if not JW.offroute(j, lat, lng)[0]:
            return {"lat": lat, "lng": lng}
    return None


ASK_TEXT = {
    "off_route": (("রুট বদলেছেন?", "Changed route?"),
                  ("শুধু আপনার ফোনে — পরিবার এখনো জানে না। ট্যাপ করে জানান।",
                   "Only on your phone — the family does not know yet. Tap to answer.")),
    "long_stop": (("অনেকক্ষণ থেমে আছেন — সব ঠিক?", "Stopped a while — all OK?"),
                  ("শুধু আপনার ফোনে — পরিবার এখনো জানে না। ট্যাপ করে জানান।",
                   "Only on your phone — the family does not know yet. Tap to answer.")),
    "late_stopped": (("সব ঠিক আছে?", "All OK?"),
                     ("শুধু আপনার ফোনে — পরিবার এখনো জানে না। ট্যাপ করে জানান।",
                      "Only on your phone — the family does not know yet. Tap to answer.")),
    "near_stop": (("গন্তব্যের কাছে থেমে আছেন — সব ঠিক?", "Stopped near your destination — all OK?"),
                  ("শুধু আপনার ফোনে — পরিবার এখনো জানে না। ট্যাপ করে জানান।",
                   "Only on your phone — the family does not know yet. Tap to answer.")),
    "night_checkin": (("রাতের যাত্রা — সব ঠিক?", "Night trip — all OK?"),
                      ("শুধু আপনার ফোনে। এক ট্যাপে জানান আপনি ভালো আছেন।",
                       "Only on your phone. One tap to say you are OK.")),
}


def _push_ask(j, ask):
    from . import journey_watch as JW
    (tbn, ten), (bbn, ben) = ASK_TEXT.get(ask.get("kind"), ASK_TEXT["long_stop"])
    JW.push_traveller(j.traveller, j.id, "check_ask", tbn, ten, bbn, ben)


def apply_actions(j, acts):
    from . import journey_watch as JW
    for kind, ask in acts:
        if kind == "ask":
            _push_ask(j, ask)
        elif kind == "amber":
            JW.emit(j, "check_on", key=ask.get("id", "")[:60],
                    payload={"why": ask.get("kind"), "level": "amber",
                             **({"battery": ask["battery"]} if ask.get("battery") is not None else {}),
                             **({"lost_why": ask["why"]} if ask.get("why") else {})})
        elif kind == "back" and ask.get("amber_at"):
            JW.emit(j, "phone_back", key=ask.get("id", "")[:60])
        elif kind == "red":
            JW.emit(j, "check_red", key=ask.get("id", "")[:60],
                    payload={"why": ask.get("kind"), "level": "red"})


def sweep_journey(j, now, stats=None):
    """One sweeper step for an ACTIVE journey (called by journey_watch)."""
    d = dict(j.during or {})
    if d.get("cover"):
        # danger PIN: live location for COVER_MIN, then the trip ends
        until = _dt(d.get("cover_until"))
        if until and now >= until:
            from . import journey_watch as JW
            d["cover"] = False
            j.during = d
            j.status = "arrived"
            j.stopped_at = j.stopped_at or now
            j.expires_at = now + timedelta(hours=24)
            j.save(update_fields=["during", "status", "stopped_at", "expires_at"])
        return
    st = state_of(j, now)
    if st.get("state") == "off_route":
        d.setdefault("off_since", _iso(now))
    else:
        d.pop("off_since", None)
    j.during = d
    sig = _signal_for(j, st, now)
    if sig and sig.get("kind") == "night_checkin":
        d["night_at"] = _iso(now)
    acts, d = ladder(d, sig, now)
    d["state"] = st
    j.during = d
    j.save(update_fields=["during"])
    apply_actions(j, acts)
    if stats is not None:
        for k, _a in acts:
            stats["ladder_" + k] = stats.get("ladder_" + k, 0) + 1


def enabled(j):
    """V2 rules for every personal journey. A "share for a while" has no
    destination; a guardian-requested trip keeps its own requester-first
    escalation (core/guardian_journey.py). settings.SJ_DURING_V2 = False is
    the one-line rollback."""
    from django.conf import settings
    if not getattr(settings, "SJ_DURING_V2", True):
        return False
    if (j.destination or {}).get("share"):
        return False
    try:
        if j.pk and j.guardian_requests.exists():
            return False
    except Exception:
        pass
    return True


def calm_overdue(j, state):
    if state in ("grace", "ask", "alert") and j is not None and enabled(j):
        return "late_calm"
    return state


def pin_prefs(user):
    """(configured, always)."""
    from .models import DuressPin
    dp = DuressPin.objects.filter(user=user).first()
    ok = bool(dp and dp.salt and dp.normal_hash)
    return ok, bool(ok and dp.arrive_always)


def is_too_early(j, now):
    """Before the earliest physically possible time C. qjourney's
    JW.arrival_plausible (same C keys) wins when it is merged in."""
    from . import journey_watch as JW
    fn = getattr(JW, "arrival_plausible", None)
    if fn is not None:
        try:
            return (fn(j, now=now) or {}).get("reason") == "too_early"
        except Exception:
            pass
    c = earliest_for(j)
    return c is not None and now < c


def arrival_decision(j, now):
    """'arrived' | 'pin' (ask the PIN first) | 'wait' (impossible and no
    PIN set: never accepted before the earliest possible time)."""
    too_early = is_too_early(j, now)
    configured, always = pin_prefs(j.traveller)
    why = pin_needed(j.during, always=always, too_early=too_early)
    if not why:
        return "arrived", why
    if not configured:
        return ("wait" if too_early else "arrived"), why
    return "pin", why


def auto_arrival(j, now, acc=None):
    """Location view: inside the place-type radius for 2 minutes. Returns
    'arrived' (finish now) or None (keep going; a PIN may now be asked)."""
    from . import sj_live as SL
    d = dict(j.during or {})
    if d.get("cover") or d.get("pin_wait"):
        return None
    dest = _pt(j.destination or {})
    if dest is None:
        return None
    radius = arrival_radius(j.destination)
    if not SL.acc_ok_for_arrival(acc, radius):
        return None
    ok, _s = dwell(recent_points(j, 900, until=now), dest, radius)
    if not ok:
        return None
    verdict, why = arrival_decision(j, now)
    if verdict == "arrived":
        return "arrived"
    ask_pin(j, now, why, verdict)
    return None


def ask_pin(j, now, why, verdict="pin", push=True):
    """Arrival looks abnormal: keep the trip live, ask the traveller for the
    PIN privately; an impossible (too early) arrival is shown to watchers
    as "Unusually fast arrival, PIN asked". push=False: the traveller is
    already looking at the PIN box (a manual "I've arrived" tap, sjproof)."""
    from . import journey_watch as JW
    d = dict(j.during or {})
    if verdict == "pin":
        d["pin_wait"] = {"why": list(why), "at": _iso(now)}
    if "too_early" in why:
        b = list(d.get("badges") or [])
        if "fast_pin" not in b:
            b.append("fast_pin")
        d["badges"] = b
    j.during = d
    j.save(update_fields=["during"])
    if verdict == "pin" and push:
        JW.push_traveller(j.traveller, j.id, "arrive_pin",
                          "পৌঁছেছেন? PIN দিন", "Arrived? Enter your PIN",
                          "যাত্রা শেষ করতে আপনার গোপন PIN দিন।",
                          "Enter your secret PIN to finish the journey.")
    if "too_early" in why:
        JW.emit(j, "fast_pin", key="1", payload={"level": "amber",
                                                  **({"nopin": True} if verdict == "wait" else {})})


def badges(j):
    """Finished-list badges: 'pin_ok' (green shield, Confirmed with PIN) and
    'fast_pin' (amber, Unusually fast arrival, PIN asked) — from this
    module's own flags and qjourney's /arrived events (arrival_unusual,
    arrived + confirmed_pin)."""
    out = list((j.during or {}).get("badges") or [])
    try:
        for kind, p in j.events.filter(kind__in=("arrival_unusual", "arrived", "fast_pin")) \
                .values_list("kind", "payload"):
            tag = ("fast_pin" if kind in ("arrival_unusual", "fast_pin") else
                   "pin_ok" if (p or {}).get("confirmed_pin") else None)
            if tag and tag not in out:
                out.append(tag)
    except Exception:
        pass
    return out


def purge(j):
    """Privacy (journey expiry): the danger audio goes with the locations."""
    d = dict(j.during or {})
    path = d.pop("audio", None)
    if path:
        try:
            from django.core.files.storage import default_storage
            default_storage.delete(path)
        except Exception:
            pass
        j.during = d
        j.save(update_fields=["during"])


def board_card(j, viewer, now):
    """One watcher card (active or finished)."""
    from . import journey_watch as JW
    from . import push as PUSH
    d = j.during or {}
    cover = bool(d.get("cover"))
    live = j.status == "active"
    st = state_of(j, now) if live else {"state": "arrived" if j.status == "arrived" else j.status}
    fx = JW.fix_of(j) if (live or j.sos_active) else None
    ask = d.get("ask") or {}
    level = ""
    if j.sos_active or d.get("pin") == "danger":
        level = "red"
    elif ask.get("red_at") and not ask.get("answered"):
        level = "red"
    elif ask.get("amber_at") and not ask.get("answered"):
        level = "amber"
    out = {
        "id": j.id, "name": PUSH.seen_name(viewer, j.traveller),
        "mode": (j.vehicle or {}).get("mode") or j.mode or "",
        "status": j.status if not cover else "active",
        "state": st.get("state"), "state_minutes": st.get("minutes") or st.get("stopped_min"),
        "battery": st.get("battery"), "why": st.get("why", ""),
        "near_note": bool(st.get("near_note")),
        "level": level, "badges": badges(j),
        "destination": (j.destination or {}).get("name") or "",
        "eta": j.eta.isoformat() if j.eta else None,
        "window_from": (j.destination or {}).get("window_from"),
        "window_to": (j.destination or {}).get("window_to"),
        "earliest_at": _iso(earliest_for(j)),
        "lat": fx[0] if fx else None, "lng": fx[1] if fx else None,
        "night": bool(st.get("night")),
        "started_at": _iso(j.created_at),
        "ended_at": _iso(j.stopped_at),
        "pin": "ok" if d.get("pin") == "ok" else "",
        "audio": bool(d.get("audio")) and d.get("pin") == "danger",
    }
    if live and st.get("distance_m") is not None:
        out["distance_m"] = st["distance_m"]
    elif live and fx:
        p = JW.progress(j, fx)
        if p.get("distance_m") is not None:
            out["distance_m"] = int(p["distance_m"])
    return out


# --------------------------------------------------------------- texts
def watcher_text(kind, j, name, lang, p):
    """(title, body) for check_on / check_red / time_extended / stop_place /
    pin_ok / fast_pin / danger_pin / danger_audio, or None."""
    from .logic import safety_journey as SJ
    pick = SJ.pick
    if kind == "check_on":
        why = p.get("why")
        if why == "phone_off":
            b = p.get("battery")
            bt = ("" if b is None else
                  pick(lang, " শেষ চার্জ ছিল %s%%।" % _bn(b), " Last battery %s%%." % b))
            if p.get("lost_why") == "battery":
                body = pick(lang, "%s-এর ফোন থেকে লোকেশন আসছে না — চার্জ শেষ হয়ে ফোন বন্ধ হয়ে থাকতে পারে।%s" % (name, bt),
                            "No location from %s — the battery probably ran out.%s" % (name, bt))
            elif p.get("lost_why") == "killed":
                body = pick(lang, "%s-এর ফোন থেকে লোকেশন আসছে না — ফোনের ব্যাটারি-সেভার হয়তো Assisto থামিয়েছে।%s" % (name, bt),
                            "No location from %s — the phone's battery saver probably paused Assisto.%s" % (name, bt))
            else:
                body = pick(lang, "%s-এর ফোন থেকে লোকেশন আসছে না — ফোন বন্ধ বা নেট নেই।%s এটাই শেষ জানা জায়গা।" % (name, bt),
                            "No location from %s — the phone is off or offline.%s This is the last known place." % (name, bt))
        else:
            body = pick(lang, "%s-কে কিছু জিজ্ঞেস করা হয়েছিল, ৫ মিনিটে উত্তর আসেনি। একবার ফোন করে খোঁজ নিন। এটাই শেষ জানা জায়গা।" % name,
                        "%s was asked privately and did not answer in 5 minutes. Please call to check. This is the last known place." % name)
        return pick(lang, "%s-এর খোঁজ নিন" % name, "Check on %s" % name), body
    if kind == "arrived" and (j.during or {}).get("pin") == "ok":
        kind = "pin_ok"
    if kind == "phone_back":
        return (pick(lang, "%s-এর ফোন আবার চালু" % name, "%s's phone is back" % name),
                pick(lang, "%s-এর ফোন থেকে আবার লোকেশন আসছে। যাত্রা চলছে।" % name,
                     "Location from %s is coming in again. The journey continues." % name))
    if kind == "check_red":
        return (pick(lang, "জরুরি: %s সাড়া দিচ্ছেন না" % name, "Urgent: %s is not answering" % name),
                pick(lang, "%s এখনো কোনো উত্তর দেননি। এখনই ফোন করুন; না পেলে কাছের কাউকে পাঠান বা ৯৯৯-এ কল করুন।" % name,
                     "%s has still not answered. Call now; if you cannot reach them, send someone nearby or call 999." % name))
    if kind == "stop_place":
        return (pick(lang, "%s থামার জায়গা জানিয়েছেন" % name, "%s shared where they stopped" % name),
                pick(lang, "%s একটু থেমেছেন এবং জায়গাটা আপনাকে দেখাচ্ছেন। সব ঠিক আছে।" % name,
                     "%s has stopped for a bit and is showing you the place. All is OK." % name))
    if kind == "pin_ok":
        return (pick(lang, "%s পৌঁছেছেন — PIN দিয়ে নিশ্চিত" % name, "%s arrived — Confirmed with PIN" % name),
                pick(lang, "%s নিজের গোপন PIN দিয়ে নিরাপদে পৌঁছানো নিশ্চিত করেছেন।" % name,
                     "%s confirmed a safe arrival with their secret PIN." % name))
    if kind == "fast_pin" and p.get("nopin"):
        return (pick(lang, "অস্বাভাবিক দ্রুত পৌঁছানো", "Unusually fast arrival"),
                pick(lang, "%s এত তাড়াতাড়ি পৌঁছানো সম্ভব নয়, তাই এখনো পৌঁছেছেন দেখানো হচ্ছে না। একবার ফোন করে খোঁজ নিন।" % _dest(j, lang),
                     "Reaching %s this early is not possible, so it is not shown as Arrived yet. Please call to check." % _dest(j, lang)))
    if kind == "fast_pin":
        return (pick(lang, "অস্বাভাবিক দ্রুত পৌঁছানো — PIN চাওয়া হয়েছে", "Unusually fast arrival, PIN asked"),
                pick(lang, "%s এত তাড়াতাড়ি পৌঁছানো সম্ভব নয়, তাই %s-কে PIN দিতে বলা হয়েছে। PIN না দেওয়া পর্যন্ত যাত্রা চলছে।" % (_dest(j, lang), name),
                     "Reaching %s this early is not possible, so %s was asked for the PIN. The journey stays live until then." % (_dest(j, lang), name)))
    if kind == "danger_pin":
        return (pick(lang, "জরুরি: %s বিপদে থাকতে পারেন" % name, "Emergency: %s may be in danger" % name),
                pick(lang, "%s পৌঁছানোর সময় গোপন বিপদ-PIN দিয়েছেন। তাঁর ফোনে সব স্বাভাবিক দেখাচ্ছে। লাইভ লোকেশন দেখুন; তাঁকে জোরে ফোন করে ধরিয়ে দেবেন না।" % name,
                     "%s entered the secret danger PIN on arrival. Their own screen looks normal. Watch the live location; don't give them away with a loud call." % name))
    if kind == "danger_audio":
        return (pick(lang, "%s-এর ৩০ সেকেন্ডের অডিও এসেছে" % name, "30-second audio from %s" % name),
                pick(lang, "বিপদ-PIN দেওয়ার পর রেকর্ড করা অডিও। শুনতে ট্যাপ করুন।",
                     "Recorded after the danger PIN. Tap to listen."))
    return None


def _bn(v):
    from . import journey_watch as JW
    return JW.bn_num(v)


def _dest(j, lang):
    from .logic import safety_journey as SJ
    return (j.destination or {}).get("name") or SJ.pick(lang, "গন্তব্যে", "the destination")
