"""journeymode — how the traveller is going, inside Safe Journey (owner order
2 Nov 17:40: Train tracker and Destination alarm INSIDE Safe Journey).

One flow, no copies: the train part CALLS the train tracker's own service /
geometry (core/train_service.py, core/logic/train_geo.py); the destination
alarm runs on the phone only (app/lib/train/dest_alarm_service.dart) — the
server never sees it.

* train link: the journey stores {no, date, to} in Journey.vehicle["train"]
  (no migration). Watchers get where the train is, the next station and a
  rough arrival time at the traveller's station — ALWAYS labelled an
  estimate, with its basis:
    "own"       the traveller's own journey fix, on this train's rail line
                (already shared with these watchers by the journey itself);
    "live"      the train tracker's crowd position (other passengers);
    "timetable" the timetable only.
  Gated by the flag `train_tracker` (the journey works without it).
* mode-aware stop alerts: a train standing at a station or on its line
  (crossing wait), a metro on its line or a launch at a ghat is NOT
  "stopped for a long time" at the normal 20 min — a later, calm notice
  only. Bus traffic jams reuse journey100b's jam rule (journey_watch.in_traffic).
* late check: when the traveller's own fix shows the train running late,
  the "Are you OK?" check waits for the train's (estimated) arrival at
  their station — capped, and only with a FRESH fix on the line.
"""
from datetime import timedelta

from django.utils import timezone

TRAIN_FLAG = "train_tracker"

# travel modes of the start-screen chips (plus the older ride modes)
TRANSIT_MODES = ("train", "metro", "launch")
BUS_MODES = ("local_bus", "long_bus", "bus")

ON_LINE_M = 300.0          # within this of a rail line = on the train's line
STATION_M = 600.0          # within this of a station = standing at it
TRAIN_STATION_MIN = 60     # a train standing at a station: calm notice only after
TRAIN_LINE_MIN = 45        # ...on the line between stations (crossing wait)
METRO_MIN = 30             # metro on its line
LAUNCH_MIN = 60            # launch (ghat waits are long)
OWN_FIX_ON_LINE_M = 250.0  # the traveller's fix counts as "on this train" within this
OWN_FIX_FRESH_MIN = 10
LATE_CAP_MIN = 240         # never push the late check further than this past the ETA


def _mode(j):
    return ((j.vehicle or {}).get("mode") or j.mode or "").lower()


# ------------------------------------------------------------ train link
def clean_train(d):
    from .logic import journey_dest as JD
    return JD.clean_train(d)


def train_of(j):
    return clean_train((j.vehicle or {}).get("train"))


def _flag(user):
    try:
        from . import feature_flags as FF
        return bool(FF.is_on(TRAIN_FLAG, user))
    except Exception:
        return False


def _fresh_fix(j, now):
    from . import journey_watch as JW
    fx = JW.fix_of(j)
    if fx is None or fx[2] is None:
        return None
    if (now - fx[2]).total_seconds() > OWN_FIX_FRESH_MIN * 60:
        return None
    return fx


def _station(sid):
    from .logic import train_geo as TG
    s = TG.stations().get(sid) or {}
    return {"id": sid, "bn": s.get("bn", ""), "en": s.get("en", ""),
            "lat": s.get("lat"), "lng": s.get("lng")}


def _context(j, now):
    """(train, route, service_date, to_eta_entry, own_chainage, live) or None."""
    from . import train_service as TS
    from .logic import train_geo as TG
    link = train_of(j)
    if not link:
        return None
    t = TG.train(link["no"])
    if t is None:
        return None
    try:
        from datetime import date
        sd = date.fromisoformat(link["date"])
    except ValueError:
        return None
    rt = TG.route(t["no"])
    if rt is None:
        return None
    to_e = None
    for e in TG.stop_etas(t, rt, sd):
        if e["st"] == link.get("to"):
            to_e = e
    if to_e is None:  # no station chosen: the train's own end
        etas = TG.stop_etas(t, rt, sd)
        to_e = etas[-1] if etas else None
    own = None
    fx = _fresh_fix(j, now)
    if fx is not None:
        ch, off = rt.project(fx[0], fx[1])
        if off <= OWN_FIX_ON_LINE_M:
            own = ch
    live = None
    if own is None:
        try:
            v = TS.live_view(t, sd, now=now)
            live = v.get("live")
        except Exception:
            live = None   # best-effort: timetable estimate below
    return t, rt, sd, to_e, own, live


def train_link(j, now=None, viewer=None):
    """The watcher / traveller view of the linked train, or None (no link,
    unknown train, or the flag is off for the traveller)."""
    from .logic import train_geo as TG
    now = now or timezone.now()
    if not train_of(j) or not _flag(j.traveller):
        return None
    ctx = _context(j, now)
    if ctx is None:
        return None
    t, rt, sd, to_e, own, live = ctx
    if own is not None:
        ch, basis = own, "own"
    elif live:
        ch, basis = float(live.get("chainage_m") or 0), "live"
    else:
        est = TG.estimate(t, sd, now)
        if est is None:
            return None
        ch, basis = float(est["chainage_m"]), "timetable"
    lat, lng = rt.point_at(ch)
    delay = TG.delay_minutes(t, sd, ch, now) if basis != "timetable" else None
    nxt = TG.next_stop_after(t, ch)
    to_at = None
    passed = False
    if to_e is not None:
        passed = ch >= float(to_e["km"]) * 1000.0 - 200
        to_at = to_e["at"] + timedelta(minutes=max(0, delay or 0))
    return {
        "no": t["no"], "name_bn": t["name_bn"], "date": sd.isoformat(),
        "basis": basis, "label": "estimate",
        "lat": round(lat, 6), "lng": round(lng, 6),
        "next_stop": _station(nxt) if nxt else None,
        "to": _station(to_e["st"]) if to_e else None,
        "to_eta": to_at.isoformat() if to_at and not passed else None,
        "delay_min": delay,
        "passed": passed,
        "url_route": "train/%s" % t["no"],
    }


def train_late_eta(j, now):
    """When the traveller's OWN fresh fix is on this train's line and the train
    runs late, the (estimated, capped) time it reaches their station; else
    None. Used only to postpone the "Are you OK?" check — never to hide an
    SOS, never without a fresh fix."""
    if j.eta is None or not train_of(j) or not _flag(j.traveller):
        return None
    try:
        ctx = _context(j, now)
    except Exception:
        return None
    if ctx is None:
        return None
    t, rt, sd, to_e, own, _live = ctx
    if own is None or to_e is None:
        return None
    from .logic import train_geo as TG
    if own >= float(to_e["km"]) * 1000.0 - 200:
        return None      # at / past their station: the normal check applies
    delay = TG.delay_minutes(t, sd, own, now)
    if not delay or delay <= 0:
        return None
    at = to_e["at"] + timedelta(minutes=delay)
    cap = j.eta + timedelta(minutes=LATE_CAP_MIN)
    at = min(at, cap)
    return at if at > j.eta else None


# ------------------------------------------------------------ stop rules
def _near_station(lat, lng):
    from .logic import train_geo as TG
    from .logic.safety import haversine_m
    for s in TG.stations().values():
        try:
            if haversine_m(lat, lng, float(s["lat"]), float(s["lng"])) <= STATION_M:
                return True
        except (KeyError, TypeError, ValueError):
            continue
    return False


def _on_rail(lat, lng):
    from .logic import train_geo as TG
    try:
        return TG.network().distance_m(lat, lng) <= ON_LINE_M
    except Exception:
        return False


def stop_rule(j, lat, lng):
    """(kind, minutes) for a long stop at (lat, lng) by travel mode:
    kind None = a normal stop (the journey's own stop_alert_min), else a calm
    later notice: "station" / "line" (train), "metro", "ghat" (launch).
    A stop OFF the line (the traveller got off and stands somewhere) is a
    normal stop again. Bus jams are journey_watch.in_traffic (journey100b)."""
    m = _mode(j)
    base = int(j.stop_alert_min or 0)
    if m == "train":
        if _near_station(lat, lng):
            return "station", max(base, TRAIN_STATION_MIN)
        if _on_rail(lat, lng):
            return "line", max(base, TRAIN_LINE_MIN)
        return None, base
    if m == "metro":
        return "metro", max(base, METRO_MIN)
    if m == "launch":
        return "ghat", max(base, LAUNCH_MIN)
    return None, base


def dwell_text(kind, name, m, lang):
    """(title, body) for a calm long-stop notice by travel mode."""
    bn = lang == "bn"
    if kind == "station":
        return (("ট্রেন স্টেশনে অনেকক্ষণ দাঁড়িয়ে", "%s-এর ট্রেন প্রায় %s মিনিট ধরে একটা স্টেশনে দাঁড়িয়ে আছে — ট্রেনে এটা প্রায়ই হয়। চিন্তা হলে ফোন করুন।" % (name, m))
                if bn else
                ("Train waiting at a station", "%s's train has been at a station for about %s min — this often happens on trains. Call them if you're worried." % (name, m)))
    if kind == "line":
        return (("ট্রেন লাইনে থেমে আছে — হয়তো ক্রসিংয়ের অপেক্ষা", "%s-এর ট্রেন প্রায় %s মিনিট ধরে লাইনে থেমে আছে — অন্য ট্রেনের জন্য অপেক্ষা হতে পারে। চিন্তা হলে ফোন করুন।" % (name, m))
                if bn else
                ("Train stopped on the line — maybe waiting to cross", "%s's train has been stopped on the line for about %s min — it may be waiting for another train. Call them if you're worried." % (name, m)))
    if kind == "metro":
        return (("মেট্রো অনেকক্ষণ থেমে আছে", "%s প্রায় %s মিনিট ধরে একই জায়গায় — মেট্রো থেমে থাকতে পারে। চিন্তা হলে ফোন করুন।" % (name, m))
                if bn else
                ("Metro not moving for a while", "%s has been at the same place for about %s min — the metro may be held. Call them if you're worried." % (name, m)))
    return (("লঞ্চ অনেকক্ষণ থেমে আছে", "%s প্রায় %s মিনিট ধরে একই জায়গায় — লঞ্চ ঘাটে অপেক্ষা করতে পারে। চিন্তা হলে ফোন করুন।" % (name, m))
            if bn else
            ("Launch not moving for a while", "%s has been at the same place for about %s min — the launch may be waiting at a ghat. Call them if you're worried." % (name, m)))
