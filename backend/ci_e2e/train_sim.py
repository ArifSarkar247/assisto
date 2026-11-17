"""train-e2e: the Train Tracker E2E's handle on the server (CI ONLY — mounted
by ci_e2e.urls under settings_e2eproof; ci_e2e refuses to load anywhere else).

Why a fake clock: Rangpur Express 771 runs 09:10-19:00 Dhaka, the CI runner
runs at any hour. `clock` moves "now" for the TRAIN modules only
(core.train_engine + core.train_service read `timezone.now` through their
module global `timezone`, which is swapped for a shifted proxy) so the train
is between two stations right now. Auth tokens, flags and every other
module keep the real clock. Time keeps flowing in real seconds after that.

Everything the riders send still goes through the REAL endpoints
(/train/<no>/trip, /train/ping, /checkin, /train/text, /now, /live): this
module only GENERATES the points (the real OSM polyline of the train at
train speed) and reads back what the engine decided (Redis state, trust).

POST /api/v1/ci-e2e/train-sim
  {op: clock, no, minutes_after_dep, device_today?, delay_min?}
        -> {date, now, offset_s, dep, arr, stations:[...]} (+ a clean slate)
  {op: riders, no, date, minutes?, lags_m?, delay_min?, spacing_s?}
        -> {riders:[[point..]..], outlier:{off_line:[..], mock:[..]}, expect:{..}}
  {op: advance, no, date, minutes}   -> the clock jumps; Redis TTL ages with it
  {op: state, no, date}              -> {redis, in_redis, ttl, state, trips:[trust..]}
  {op: learn, no, date, weeks?, delay_min?} / {op: forget, no}
  {op: text16318, no, date, delay_min?} -> a made-up 16318-style reply that
        fits "now" (the last halt passed)
All riders, texts and delays are MADE UP sample data.
"""
import random
from datetime import date as _date
from datetime import datetime
from datetime import timedelta

from django.core.cache import cache
from django.utils import timezone as dj_tz

STATE = {"offset_s": 0.0, "installed": False}
_MODS = ("core.train_engine", "core.train_service")


class _ShiftedTz:
    """django.utils.timezone with now() moved by STATE['offset_s']."""

    def __getattr__(self, name):
        return getattr(dj_tz, name)

    @staticmethod
    def now():
        return dj_tz.now() + timedelta(seconds=STATE["offset_s"])


def install():
    if STATE["installed"]:
        return
    import importlib
    for m in _MODS:
        importlib.import_module(m).timezone = _ShiftedTz()
    STATE["installed"] = True


def now():
    return dj_tz.now() + timedelta(seconds=STATE["offset_s"])


def _modules():
    from core import train_engine as TE
    from core import train_source as SRC
    from core.logic import train_geo as TG
    from core.logic import train_live as L
    return TE, SRC, TG, L


def _train(no):
    _, SRC, _, _ = _modules()
    t = SRC.train(str(no or "771"))
    if t is None:
        raise ValueError("unknown_train")
    return t


def _halts(t):
    TE, SRC, _, _ = _modules()
    return [{"id": s["id"], "en": s["en"], "bn": s["bn"], "lat": s["lat"], "lng": s["lng"],
             "ch": round(s["ch"]), "official": SRC.official_time(t, s["id"])} for s in TE.stops(t)]


def _sched_ch(t, d, ts):
    """Where the timetable puts the train at epoch ts (metres on its path)."""
    TE, _, _, L = _modules()
    sched = TE.sched_times(t, d)
    return L.predict_chainage([(s["ch"] / 1000.0, sched[s["id"]].timestamp())
                               for s in TE.stops(t) if sched.get(s["id"])], ts)


def _reset(t, d):
    TE, _, _, _ = _modules()
    from core.models import TrainCheckin, TrainObservation, TrainPassing, TrainTrip
    TrainTrip.objects.filter(train_no=t["no"]).delete()        # pings cascade
    TrainObservation.objects.filter(train_no=t["no"]).delete()
    TrainCheckin.objects.filter(train_no=t["no"]).delete()
    TrainPassing.objects.filter(train__number=t["no"]).delete()
    for k in (TE.live_key(t["no"]), TE._dirty_key(t["no"]), "train:lock:%s" % t["no"]):
        TE.STORE.delete(k)
    for wd in range(7):
        cache.delete("train:delays:%s:%d" % (t["no"], wd))


def op_clock(d):
    TE, SRC, _, _ = _modules()
    t = _train(d.get("no"))
    real = dj_tz.now()
    try:
        base = _date.fromisoformat(str(d.get("device_today") or ""))
    except ValueError:
        base = real.astimezone(SRC.DHAKA).date()
    day = next((c for c in (base, base - timedelta(days=1), base + timedelta(days=1))
                if SRC.runs_on(t, c)), None)
    if day is None:
        return {"ok": False, "reason": "no_service_day"}
    dep, arr = SRC.times(t, day)
    target = dep + timedelta(minutes=float(d.get("minutes_after_dep") or 300))
    STATE["offset_s"] = (target - real).total_seconds()
    install()
    _reset(t, day)
    return {"no": t["no"], "date": day.isoformat(), "now": target.isoformat(),
            "offset_s": round(STATE["offset_s"]), "dep": dep.isoformat(), "arr": arr.isoformat(),
            "off_days": t["off_days"], "stations": _halts(t)}


def _expect(t, day, at, delay_min):
    """The truth at `at`: the station passed last and the next one (the v1
    line the app draws: halts + stations on the line)."""
    TE, _, TG, _ = _modules()
    ch = _sched_ch(t, day, (at - timedelta(minutes=delay_min)).timestamp())
    lv = TG.line_view(TG.train(t["no"]), day, ch, at)
    st = lv["stations"]
    prev = st[lv["now_index"]] if lv["now_index"] is not None else None
    nxt = st[lv["next_index"]] if lv["next_index"] is not None else None
    halts = TE.stops(t)
    nh = next((s for s in halts if s["ch"] > ch + 150.0), None)
    ph = next((s for s in reversed(halts) if s["ch"] <= ch + 150.0), None)
    return {"ch": round(ch), "km": round(TE.ch_to_km(t, ch), 2),
            "prev": prev and {"id": prev["id"], "en": prev["en"], "bn": prev["bn"]},
            "next": nxt and {"id": nxt["id"], "en": nxt["en"], "bn": nxt["bn"]},
            "prev_halt": ph and {"id": ph["id"], "en": ph["en"], "bn": ph["bn"]},
            "next_halt": nh and {"id": nh["id"], "en": nh["en"], "bn": nh["bn"]}}


def op_riders(d):
    TE, _, TG, L = _modules()
    t = _train(d.get("no"))
    day = _date.fromisoformat(str(d["date"]))
    rt = TE.route_index(t["no"])
    minutes = float(d.get("minutes") or 6)
    spacing = max(5.0, float(d.get("spacing_s") or 30))
    delay = float(d.get("delay_min") if d.get("delay_min") is not None else 10)
    lags = [float(x) for x in (d.get("lags_m") or (0.0, 120.0, 260.0))]
    rng = random.Random(int(d.get("seed") or 7))
    # ahead_s > 0: the last points lie in the (fake) future — the API proof
    # sends each one only when its time has come (live rounds, timed);
    # stagger_s: rider k's clock runs k * stagger_s later (distinct times)
    ahead = max(0.0, min(120.0, float(d.get("ahead_s") or 0)))
    stagger = max(0.0, min(10.0, float(d.get("stagger_s") or 0)))
    end = now() - timedelta(seconds=1) + timedelta(seconds=ahead)
    n = int((minutes * 60 + ahead) // spacing)
    base_times = [end - timedelta(seconds=spacing * (n - k)) for k in range(n + 1)]
    riders = []
    for r_i, lag in enumerate(lags):
        times = [x + timedelta(seconds=stagger * r_i) for x in base_times]
        pts, prev = [], None
        for at in times:
            ch = max(0.0, _sched_ch(t, day, (at - timedelta(minutes=delay)).timestamp()) - lag)
            lat, lng = rt.point_at(ch)
            lat += rng.uniform(-12, 12) / 111320.0          # GPS noise, well inside 100 m
            spd = (ch - prev) / spacing if prev is not None else None
            prev = ch
            pts.append({"at": int(at.timestamp() * 1000), "lat": round(lat, 6),
                        "lng": round(lng, 6), "acc": 12, "speed": spd and round(spd, 2),
                        "mock": False})
        if pts[0]["speed"] is None and len(pts) > 1:
            pts[0]["speed"] = pts[1]["speed"]
        riders.append(pts)
    now_ms = int(now().timestamp() * 1000)
    base = [p for p in riders[0] if p["at"] <= now_ms][-3:]
    off_line = [dict(p, lat=round(p["lat"] + 0.0135, 6)) for p in base]   # ~1.5 km off the line
    mocked = [dict(p, mock=True) for p in base]
    return {"riders": riders, "outlier": {"off_line": off_line, "mock": mocked},
            "now": now().isoformat(), "now_ms": now_ms, "end": end.isoformat(),
            "expect": _expect(t, day, end, delay)}


def op_advance(d):
    TE, _, _, _ = _modules()
    t = _train(d.get("no"))
    day = _date.fromisoformat(str(d["date"]))
    mins = float(d.get("minutes") or 0)
    STATE["offset_s"] += mins * 60.0
    key = TE.live_key(t["no"])
    r = TE.STORE._redis()
    aged = None
    if r is not None:          # Redis TTL is real time: age it by the same jump
        ttl = r.ttl(key)
        if ttl and ttl > 0:
            left = int(ttl - mins * 60)
            if left <= 0:
                r.delete(key)
            else:
                r.expire(key, left)
            aged = max(0, left)
    else:
        st = cache.get(key)
        if st and (now() - datetime.fromisoformat(st["computed_at"])).total_seconds() \
                > TE.LIVE_TTL_S:
            cache.delete(key)
    cur = TE.read(t, day)
    return {"now": now().isoformat(), "ttl_left": aged, "mode": cur["mode"],
            "freshness": cur["freshness"]}


def op_state(d):
    TE, _, _, _ = _modules()
    import json
    from core.models import TrainTrip
    t = _train(d.get("no"))
    day = _date.fromisoformat(str(d["date"]))
    key = TE.live_key(t["no"])
    r = TE.STORE._redis()
    raw, ttl = None, None
    if r is not None:
        raw = r.get(key)
        ttl = r.ttl(key)
    st = json.loads(raw) if raw else None
    keep = ("mode", "src", "km", "ch", "speed_kmh", "avg_kmh", "last", "next", "delay_min",
            "confidence", "contributors", "updated_at", "computed_at")
    trips = [{"trust": tr.trust, "accepted": tr.accepted, "rejected": tr.rejected,
              "reasons": tr.reasons, "status": tr.status, "mode": tr.mode}
             for tr in TrainTrip.objects.filter(train_no=t["no"], service_date=day).order_by("id")]
    return {"redis": r is not None, "in_redis": raw is not None, "ttl": ttl,
            "state": {k: st.get(k) for k in keep} if st else None, "trips": trips}


def op_learn(d):
    TE, _, _, _ = _modules()
    from core.models import RailStation, RailTrain, TrainPassing
    t = _train(d.get("no"))
    day = _date.fromisoformat(str(d["date"]))
    weeks = int(d.get("weeks") or 4)
    delay = int(d.get("delay_min") if d.get("delay_min") is not None else 16)
    tr = RailTrain.objects.get(number=t["no"])
    sched = TE.sched_times(t, day)
    n = 0
    for i, s in enumerate(TE.stops(t)):
        if not s.get("arr") and not s.get("dep"):
            continue
        st = RailStation.objects.filter(code=s["id"]).first()
        if st is None or s["id"] not in sched:
            continue
        for w in range(1, weeks + 1):
            sd = day - timedelta(days=7 * w)
            at = sched[s["id"]] - timedelta(days=7 * w) + timedelta(minutes=delay + (w % 3))
            TrainPassing.objects.update_or_create(
                train=tr, service_date=sd, station=st,
                defaults={"seq": i, "weekday": sd.weekday(), "arrived_at": at,
                          "delay_min": delay + (w % 3), "source": "rider_gps",
                          "confidence": 0.6})
            n += 1
    for wd in range(7):
        cache.delete("train:delays:%s:%d" % (t["no"], wd))
    return {"passings": n}


def op_forget(d):
    TE, _, _, _ = _modules()
    from core.models import TrainPassing
    t = _train(d.get("no"))
    n = TrainPassing.objects.filter(train__number=t["no"]).delete()[0]
    for wd in range(7):
        cache.delete("train:delays:%s:%d" % (t["no"], wd))
    return {"deleted": n}


def op_text16318(d):
    TE, _, TG, _ = _modules()
    t = _train(d.get("no"))
    day = _date.fromisoformat(str(d["date"]))
    delay = int(d.get("delay_min") if d.get("delay_min") is not None else 12)
    sched = TE.sched_times(t, day)
    cur = now()
    passed = [s for s in TE.stops(t) if (s.get("arr") or s.get("dep")) and sched.get(s["id"])
              and sched[s["id"]] + timedelta(minutes=delay) <= cur]
    if not passed:
        return {"ok": False, "reason": "nothing_passed_yet"}
    s = passed[-1]
    at = (sched[s["id"]] + timedelta(minutes=delay)).astimezone(TG.DHAKA)
    text = "Train: %s-%s, Status: Left %s at %s, %s, Late: %d Min." % (
        t["no"], t["name_en"].upper(), s["en"], at.strftime("%I:%M %p"),
        at.strftime("%d-%b-%Y"), delay)
    return {"text": text, "station": {"id": s["id"], "en": s["en"], "bn": s["bn"],
                                      "ch": round(s["ch"])}, "at": at.isoformat()}


OPS = {"clock": op_clock, "riders": op_riders, "advance": op_advance, "state": op_state,
       "learn": op_learn, "forget": op_forget, "text16318": op_text16318}
