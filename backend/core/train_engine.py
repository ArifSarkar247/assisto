"""train-engine — the LIVE train engine (Train Tracker V2, owner order 17 Nov).

Layers (pure rules in core/logic/train_live.py + train_sms16318.py):
  B  rider GPS   — anonymous per-trip key, 100 m line check, train-speed check,
                   no mock; per-rider Kalman; multi-rider consensus + trust;
  C  cell towers — opted-in riders teach tower -> track; weak GPS placed by tower;
  E  check-in    — "reached / left X": near the station (<= 500 m) or 2+ agree;
                   points (ledger, never cash) only for matching reports;
  F  shared text — any text the user shares/pastes (16318 reply, group post,
                   WhatsApp; bn/en/Banglish) -> same checks -> low confidence;
  G  prediction  — confirmed passings teach the usual delay per train x
                   station x weekday; with no live data -> "predicted";
  H  live state  — Redis `train:live:<no>` (TTL 15 min) + a tiny read payload
                   with freshness: live / N min ago / predicted / timetable.

PRIVACY: no user id is ever stored with a point (TrainTrip has none); raw
points, trips, observations and check-ins are deleted 24 h after creation by
`train_engine_tick` (inside minute_jobs); the learned tower map holds only
aggregate counts. Nothing is sold or exported — the only outputs are the
app's own read API and the offline pack (timetable + tower map, no riders).

Train data: built against core.logic.train_geo (train(no), route(no) path,
stations(), times(), line_stations()) — the DATA lane keeps that interface
when it moves trains/stations/schedules to PostgreSQL. A stop may carry
"arr"/"dep" ("HH:MM", official) and "max_kmh"; without them the engine
interpolates by rail distance (labelled estimate).
"""
import gzip
import hashlib
import hmac
import json
import logging
import math
import secrets
from datetime import datetime, timedelta
from datetime import timezone as dtz
from functools import lru_cache

from django.conf import settings
from django.core.cache import cache
from django.db import transaction
from django.utils import timezone

from . import train_source as SRC
from .logic import train_geo as TG
from .logic import train_live as L
from .logic import train_text as TX
from .models import (TrainCellBin, TrainCheckin, TrainObservation, TrainPing,
                     TrainPassing, TrainPointLedger, TrainTrip)

log = logging.getLogger(__name__)

LIVE_TTL_S = 15 * 60
KEEP_H = 24
MAX_BATCH = 240
QUEUED_MAX_H = 24
FUTURE_SLACK_S = 60
RECOMPUTE_EVERY_S = 10
OBS_FRESH_MIN = 30
NEAR_STATION_M = 500.0
CHECKIN_MATCH_MIN = 10
CHECKIN_PER_DAY = 20
CHECKIN_POINTS = 5
POINTS_PER_DAY = 50
TEXT_PER_HOUR = 10
TEXT_MATCH_MIN = 15
TEXT_PAST_H = 6
PASS_CONF = 0.45
LEARN_DAYS = 120
TRIPS_PER_DAY = 12
ARRIVE_M = 800.0
PURGE_BATCH = 5000
OFFLINE_TTL_S = 6 * 3600
NOTE_BN = "সময়সূচি থেকে আনুমানিক"
NOTE_EN = "Estimated from timetable"


# ------------------------------------------------------------ live store (Redis)
class LiveStore:
    """Redis (settings.TRAIN_LIVE_REDIS_URL, redis-py) with a fallback to the
    Django cache when the URL is empty (tests) or Redis is unreachable."""
    _client = None
    _url = None

    def _redis(self):
        url = getattr(settings, "TRAIN_LIVE_REDIS_URL", "") or ""
        if not url:
            return None
        if LiveStore._client is None or LiveStore._url != url:
            try:
                import redis  # noqa: PLC0415 — optional until the server pip line runs
                LiveStore._client = redis.Redis.from_url(url, socket_timeout=0.5,
                                                         socket_connect_timeout=0.5)
                LiveStore._url = url
            except Exception:   # noqa: BLE001 — redis-py missing -> cache
                return None
        return LiveStore._client

    def get(self, key):
        r = self._redis()
        if r is not None:
            try:
                raw = r.get(key)
                return json.loads(raw) if raw else None
            except Exception:   # noqa: BLE001
                log.warning("train-engine: redis get failed, using the cache")
        return cache.get(key)

    def set(self, key, value, ttl):
        raw = json.dumps(value, separators=(",", ":"), ensure_ascii=False)
        r = self._redis()
        if r is not None:
            try:
                r.set(key, raw, ex=int(ttl))
                return
            except Exception:   # noqa: BLE001
                log.warning("train-engine: redis set failed, using the cache")
        cache.set(key, json.loads(raw), int(ttl))

    def add(self, key, ttl):
        """True when the key was free (a short lock / once-per-window gate)."""
        r = self._redis()
        if r is not None:
            try:
                return bool(r.set(key, b"1", nx=True, ex=int(ttl)))
            except Exception:   # noqa: BLE001
                pass
        return cache.add(key, 1, int(ttl))

    def incr(self, key, ttl):
        r = self._redis()
        if r is not None:
            try:
                n = r.incr(key)
                if n == 1:
                    r.expire(key, int(ttl))
                return int(n)
            except Exception:   # noqa: BLE001
                pass
        if cache.add(key, 1, int(ttl)):
            return 1
        try:
            return int(cache.incr(key))
        except ValueError:
            cache.set(key, 1, int(ttl))
            return 1

    def delete(self, key):
        r = self._redis()
        if r is not None:
            try:
                r.delete(key)
            except Exception:   # noqa: BLE001
                pass
        cache.delete(key)


STORE = LiveStore()


def live_key(no):
    return "train:live:%s" % no


def _uh(user):
    """Short keyed hash of a user id for rate-limit keys (Redis/cache only,
    expires within a day; never stored with points)."""
    return hmac.new(settings.SECRET_KEY.encode(), b"tl:%d" % user.pk,
                    hashlib.sha256).hexdigest()[:20]


def _limited(user, what, limit, ttl):
    return STORE.incr("train:rl:%s:%s" % (what, _uh(user)), ttl) > limit


# ------------------------------------------------------------ train data adapter
@lru_cache(maxsize=1024)
def route_index(no):
    t = SRC.train(no)
    if not t or len(t.get("path") or []) < 2:
        return None
    return L.RouteIndex(t["path"])


def stops(t):
    """Timetable halts in order: [{id, bn, en, km (official), ch (metres on
    the path), lat, lng, arr?, dep?, max_kmh?}]."""
    st = SRC.stations()
    out = []
    for s in t.get("stops") or []:
        info = st.get(s["st"]) or {}
        out.append(dict(id=s["st"], bn=info.get("bn", ""), en=info.get("en", ""),
                        km=float(s["km"]), ch=float(s.get("ch") if s.get("ch") is not None
                                                    else s["km"] * 1000.0),
                        lat=info.get("lat"), lng=info.get("lng"),
                        arr=s.get("arr"), dep=s.get("dep"), max_kmh=s.get("max_kmh")))
    return out


def sched_times(t, d):
    """{station code: scheduled aware datetime} — official times; halts
    without one are interpolated between timed halts (an estimate)."""
    return SRC.stop_times(t, d)


def ch_to_km(t, x):
    """Path metres -> official km (for display; linear between halts)."""
    ss = stops(t)
    if not ss:
        return x / 1000.0
    for a, b in zip(ss, ss[1:]):
        if a["ch"] <= x <= b["ch"]:
            f = 0.0 if b["ch"] == a["ch"] else (x - a["ch"]) / (b["ch"] - a["ch"])
            return a["km"] + f * (b["km"] - a["km"])
    return ss[-1]["km"] if x > ss[-1]["ch"] else ss[0]["km"]


def standard_kmh(t, d):
    dep, arr = SRC.times(t, d)
    rt = route_index(t["no"])
    h = max(0.25, (arr - dep).total_seconds() / 3600.0)
    return (rt.length / 1000.0 if rt else float(t.get("km") or 0)) / h


def _seg_max(t, d, ch):
    """Max line speed near `ch` (data's max_kmh, else from the scheduled
    average speed between the surrounding halts)."""
    ss = stops(t)
    sched = sched_times(t, d)
    a = b = None
    for s in ss:
        if s["ch"] <= ch:
            a = s
        elif b is None:
            b = s
    avg = None
    if a and b and b["ch"] > a["ch"] and sched.get(a["id"]) and sched.get(b["id"]):
        h = (sched[b["id"]] - sched[a["id"]]).total_seconds() / 3600.0
        if h > 0:
            avg = (b["ch"] - a["ch"]) / 1000.0 / h
    return L.seg_max_kmh([dict(km=s["ch"] / 1000.0, max_kmh=s.get("max_kmh")) for s in ss],
                         ch, avg)


def service_date_for(t, at):
    """Which service date a moment belongs to (overnight trains)."""
    local = at.astimezone(TG.DHAKA).date()
    for d in (local, local - timedelta(days=1), local - timedelta(days=2)):
        dep, arr = SRC.times(t, d)
        if dep - timedelta(hours=1) <= at <= arr + timedelta(hours=TG.LATE_END_H):
            return d
    return local


# ------------------------------------------------------------ trips (anonymous)
def _hash(token):
    return hashlib.sha256(token.encode()).hexdigest()


def open_trip(user, t, d, cells_ok=False):
    """-> (token, trip) or (None, 'rate_limited'). The token is shown once
    to the phone; the DB keeps only its sha256 — and never the user."""
    if _limited(user, "trip", TRIPS_PER_DAY, 86400):
        return None, "rate_limited"
    token = secrets.token_urlsafe(24)
    trip = TrainTrip.objects.create(key=_hash(token), train_no=t["no"], service_date=d,
                                    cells_ok=bool(cells_ok), trust=L.TRUST_START)
    return token, trip


def trip_by_token(token):
    if not token or not isinstance(token, str) or len(token) > 100:
        return None
    return TrainTrip.objects.filter(key=_hash(token)).first()


def trip_for_share(share, cells_ok=False):
    """v1 bridge: the existing /train/share/<id>/fixes feeds the engine. The
    trip key is an HMAC of the share id (server secret); the ping rows carry
    no user id, and the share row itself is purged after the trip."""
    key = hmac.new(settings.SECRET_KEY.encode(), b"share:%d" % share.id,
                   hashlib.sha256).hexdigest()
    trip, _ = TrainTrip.objects.get_or_create(
        key=key, defaults={"train_no": share.train_no, "service_date": share.service_date,
                           "trust": L.TRUST_START, "cells_ok": bool(cells_ok)})
    if cells_ok and not trip.cells_ok:
        trip.cells_ok = True
        trip.save(update_fields=["cells_ok"])
    return trip


def _num(v):
    try:
        f = float(v)
        return f if math.isfinite(f) else None
    except (TypeError, ValueError):
        return None


def _epoch(v, now):
    if v is None or v == "":
        return None
    n = _num(v)
    if n is not None:
        return n / 1000.0 if n > 1e11 else n
    try:
        at = datetime.fromisoformat(str(v).replace("Z", "+00:00"))
    except ValueError:
        return None
    if timezone.is_naive(at):
        at = at.replace(tzinfo=TG.DHAKA)
    return at.timestamp()


def normalize(p, now):
    """One point from the phone (v2 or v1 keys) -> dict or None."""
    if not isinstance(p, dict):
        return None
    at = _epoch(p.get("at", p.get("t")), now)
    if at is None:
        return None
    nowe = now.timestamp()
    if at > nowe + FUTURE_SLACK_S or at < nowe - QUEUED_MAX_H * 3600:
        return None
    spd = _num(p.get("speed"))
    if spd is None and p.get("speed_kmh") is not None:
        spd = (_num(p.get("speed_kmh")) or 0.0) / 3.6
    if spd is not None and spd < 0:
        spd = None
    return {"at": min(at, nowe), "lat": _num(p.get("lat")), "lng": _num(p.get("lng")),
            "acc": _num(p.get("acc")) or 0.0, "speed": spd,
            "heading": _num(p.get("heading", p.get("bearing"))),
            "mock": bool(p.get("mock")), "cell": L.cell_key(p.get("cell")),
            "queued": bool(p.get("queued"))}


def _bins_for(cell):
    return list(TrainCellBin.objects.filter(cell=cell).values_list("bi", "bj", "n"))


def _learn_cell(trip, cell, lat, lng):
    """Opted-in riders only; one count per (tower, bin) change per trip, so a
    rider standing still cannot inflate a bin."""
    bi, bj = L.cell_bin(lat, lng)
    tag = "%s|%d|%d" % (cell, bi, bj)
    if tag == trip.last_cell_bin:
        return False
    trip.last_cell_bin = tag
    obj, created = TrainCellBin.objects.get_or_create(cell=cell, bi=bi, bj=bj,
                                                      defaults={"n": 1})
    if not created:
        TrainCellBin.objects.filter(pk=obj.pk).update(n=obj.n + 1, updated_at=timezone.now())
    return True


def ingest(trip, points, now=None):
    """Validate + filter a batch for one anonymous trip.
    -> {accepted, rejected, placed_by_cell, learned_cells, reasons, status}."""
    now = now or timezone.now()
    t = SRC.train(trip.train_no)
    rt = route_index(trip.train_no)
    res = {"accepted": 0, "rejected": 0, "placed_by_cell": 0, "learned_cells": 0,
           "reasons": {}, "status": trip.status}
    if t is None or rt is None or trip.status != "active":
        return res
    pts = [normalize(p, now) for p in (points or [])[:MAX_BATCH]]
    bad = sum(1 for p in pts if p is None)
    if bad:
        res["rejected"] += bad
        res["reasons"]["bad_point"] = bad
    kf = L.Kalman1D.from_state(trip.kf)
    last = trip.last
    rows = []
    dep, arr = SRC.times(t, trip.service_date)
    win = ((dep - timedelta(minutes=TG.EARLY_START_MIN)).timestamp(),
           (arr + timedelta(hours=TG.LATE_END_H)).timestamp())
    for p in sorted([p for p in pts if p], key=lambda p: p["at"]):
        if p["mock"]:                       # isFromMockProvider: refused first
            res["rejected"] += 1
            res["reasons"]["mock"] = res["reasons"].get("mock", 0) + 1
            trip.trust = L.TRUST_MIN
            continue
        if not (win[0] <= p["at"] <= win[1]):
            res["rejected"] += 1
            res["reasons"]["not_running"] = res["reasons"].get("not_running", 0) + 1
            continue
        if last and p["at"] <= last["at"]:
            res["rejected"] += 1
            res["reasons"]["stale"] = res["reasons"].get("stale", 0) + 1
            continue
        hint = None
        if kf is not None:
            hint = kf.x + kf.v * max(0.0, p["at"] - (kf.t or p["at"]))
        seg = _seg_max(t, trip.service_date, hint if hint is not None else 0.0)
        ok, why, ch, _off = L.check_point(p, rt, last, seg, hint, t.get("lowq"))
        if ok:
            res["accepted"] += 1
            kf = L.step(kf, p["at"], ch, p["acc"], p["speed"])
            last = {"ch": round(ch, 1), "at": p["at"], "acc": p["acc"]}
            trip.mode = "gps"
            trip.last_at = datetime.fromtimestamp(p["at"], tz=dtz.utc)
            rows.append(TrainPing(trip=trip, at=trip.last_at, lat=round(p["lat"], 6),
                                  lng=round(p["lng"], 6), acc=p["acc"], speed=p["speed"],
                                  heading=p["heading"], chainage=round(ch, 1)))
            if trip.cells_ok and p["cell"]:
                lat, lng = rt.point_at(ch)          # snapped to the line
                if _learn_cell(trip, p["cell"], lat, lng):
                    res["learned_cells"] += 1
            continue
        res["rejected"] += 1
        res["reasons"][why] = res["reasons"].get(why, 0) + 1
        if why == "mock":
            trip.trust = L.TRUST_MIN
        elif why in ("off_line", "too_fast"):
            trip.trust = max(L.TRUST_MIN, trip.trust - 0.02)
        if why in ("no_gps", "bad_accuracy") and p["cell"]:
            place = L.place_by_cell(_bins_for(p["cell"]), rt, hint)
            if place is not None:
                kf = L.step(kf, p["at"], place["x"], r=float(place["spread_m"]) ** 2)
                res["placed_by_cell"] += 1
                trip.mode = "cell" if trip.mode != "gps" or not last or \
                    p["at"] - last["at"] > 120 else trip.mode
                trip.last_at = datetime.fromtimestamp(p["at"], tz=dtz.utc)
    if rows:
        TrainPing.objects.bulk_create(rows)
    trip.kf = kf.state() if kf else trip.kf
    trip.last = last
    trip.accepted += res["accepted"]
    trip.rejected += res["rejected"]
    reasons = dict(trip.reasons or {})
    for k, v in res["reasons"].items():
        reasons[k] = int(reasons.get(k, 0)) + v
    trip.reasons = reasons
    if kf is not None and kf.x >= rt.length - ARRIVE_M:
        trip.status = "arrived"
    trip.save()
    res["status"] = trip.status
    if res["accepted"] or res["placed_by_cell"]:
        maybe_recompute(t, trip.service_date, now)
    return res


# ------------------------------------------------------------ observations
def _station_ch(t, sid):
    for s in SRC.line_stations(t):
        if s["id"] == sid:
            return float(s["ch"]), s
    return None, None


def _add_obs(t, d, source, sid, kind, at, late=None, weight=0.3):
    ch, _ = _station_ch(t, sid)
    if ch is None:
        return None
    return TrainObservation.objects.create(train_no=t["no"], service_date=d, source=source,
                                           station=sid, kind=kind, chainage=ch, at=at,
                                           late_min=late, weight=weight)


# ------------------------------------------------------------ E: station check-in
def _award(user, n):
    """Points (never money). Daily cap; -> points actually given."""
    since = timezone.now() - timedelta(days=1)
    got = sum(TrainPointLedger.objects.filter(user=user, created_at__gte=since)
              .values_list("points", flat=True))
    give = max(0, min(n, POINTS_PER_DAY - got))
    if give:
        TrainPointLedger.objects.create(user=user, points=give, reason="checkin_match")
    return give


def points_balance(user):
    return sum(TrainPointLedger.objects.filter(user=user).values_list("points", flat=True))


def _gps_agrees(t, sid, at):
    """The rider consensus had the train within 1.5 km of the station then."""
    st = STORE.get(live_key(t["no"]))
    ch, _ = _station_ch(t, sid)
    if not st or ch is None or st.get("src") != "gps":
        return False
    age = abs(_parse(st.get("updated_at")).timestamp() - at.timestamp()) if \
        st.get("updated_at") else 1e9
    return age <= 300 and abs(float(st.get("ch", 0)) - ch) <= 1500.0


def _parse(s):
    try:
        return datetime.fromisoformat(str(s))
    except ValueError:
        return timezone.now()


def checkin(user, t, d, sid, kind, at=None, lat=None, lng=None, acc=None, now=None):
    """-> {ok, status: accepted|pending|rejected, reason?, points}."""
    now = now or timezone.now()
    if kind not in ("reached", "left"):
        return {"ok": False, "status": "rejected", "reason": "bad_kind", "points": 0}
    ch, st = _station_ch(t, sid)
    if ch is None:
        return {"ok": False, "status": "rejected", "reason": "not_on_this_train", "points": 0}
    at_e = _epoch(at, now) if at is not None else None
    at = datetime.fromtimestamp(at_e, tz=dtz.utc) if at_e else now
    if at > now + timedelta(minutes=1) or at < now - timedelta(minutes=30):
        at = now
    old = TrainCheckin.objects.filter(user=user, train_no=t["no"], service_date=d,
                                      station=sid, kind=kind).first()
    if old is not None:
        return {"ok": True, "status": old.status, "reason": "already", "points": old.points}
    if _limited(user, "checkin", CHECKIN_PER_DAY, 86400):
        return {"ok": False, "status": "rejected", "reason": "rate_limited", "points": 0}
    near = False
    la, ln, ac = _num(lat), _num(lng), _num(acc)
    if la is not None and ln is not None and st.get("lat") is not None and (ac or 0) <= 200:
        near = L.haversine_m(la, ln, float(st["lat"]), float(st["lng"])) <= NEAR_STATION_M
    win = timedelta(minutes=CHECKIN_MATCH_MIN)
    with transaction.atomic():
        me = TrainCheckin.objects.create(user=user, train_no=t["no"], service_date=d,
                                         station=sid, kind=kind, at=at, near=near)
        others = list(TrainCheckin.objects.select_for_update().filter(
            train_no=t["no"], service_date=d, station=sid, kind=kind,
            at__gte=at - win, at__lte=at + win).exclude(user=user))
        matched = bool(others) or _gps_agrees(t, sid, at)
        if near or others:
            newly = [me] + [o for o in others if o.status != "accepted"]
            for c in newly:
                c.status = "accepted"
                c.save(update_fields=["status"])
            _add_obs(t, d, "checkin", sid, kind, at, weight=0.6 if near else 0.5)
            record_passing(t, d, sid, at, "checkin", kind, 0.6 if near else 0.5)
        if matched:
            for c in [me] + others:
                if c.points == 0:
                    c.points = _award(c.user, CHECKIN_POINTS)
                    c.save(update_fields=["points"])
    me.refresh_from_db()
    if me.status == "accepted":
        maybe_recompute(t, d, now, force=True)
    return {"ok": True, "status": me.status, "points": me.points,
            **({} if me.status == "accepted" else {"reason": "waiting_for_second_report"})}


# ------------------------------------------------------------ G: confirmed passings
PASS_SOURCE = {"gps": "rider_gps", "cell": "tower", "checkin": "checkin",
               "text": "shared_text"}
_SOURCE_RANK = ("shared_text", "checkin", "tower", "rider_gps", "official")


def record_passing(t, d, sid, at, source, kind="reached", confidence=0.5):
    """Store one confirmed passing in the DATA lane's TrainPassing (anonymous:
    train, station, date, times, delay, how confirmed). Needs the official
    data loaded (load_bd_trains); a second confirmation only adds to it."""
    from .models import RailStation, RailTrain
    ss = stops(t)
    seq = next((i for i, s in enumerate(ss) if s["id"] == sid), None)
    sched = sched_times(t, d).get(sid)
    if seq is None or sched is None:
        return None
    if kind == "left" and ss[seq].get("dep"):
        sched = SRC.stop_dep(t, d, sid) or sched
    delay = int(round((at - sched).total_seconds() / 60.0))
    if not (-60 <= delay <= 900):
        return None
    if not SRC.official_time(t, sid):
        delay = None          # no official time here: keep the passing, never invent a delay
    tr = RailTrain.objects.filter(number=t["no"]).only("id").first()
    st = RailStation.objects.filter(code=sid).only("id").first()
    if tr is None or st is None:
        return None
    src = PASS_SOURCE.get(source, source)
    field = "departed_at" if kind == "left" else "arrived_at"
    obj, created = TrainPassing.objects.get_or_create(
        train=tr, service_date=d, station=st,
        defaults={"seq": seq, "weekday": d.weekday(), "delay_min": delay, "source": src,
                  field: at, "confidence": round(confidence, 2)})
    if not created:
        obj.confirmations += 1
        if getattr(obj, field) is None:
            setattr(obj, field, at)
        if kind != "left" or obj.delay_min is None:
            obj.delay_min = delay if kind != "left" or obj.arrived_at is None else obj.delay_min
        if _SOURCE_RANK.index(src) > _SOURCE_RANK.index(obj.source) \
                if obj.source in _SOURCE_RANK and src in _SOURCE_RANK else False:
            obj.source = src
        obj.confidence = round(max(obj.confidence, confidence), 2)
        obj.save()
    cache.delete("train:delays:%s:%d" % (t["no"], d.weekday()))
    return obj


def learned_delays(t, weekday, today=None):
    """{station: {delay_min, n, p25, p75, scope}} — train x station x weekday
    (>= DELAY_MIN_N passes), else train x station any weekday (>= 5)."""
    ck = "train:delays:%s:%d" % (t["no"], weekday)
    hit = cache.get(ck)
    if hit is not None:
        return hit
    today = today or timezone.now().astimezone(TG.DHAKA).date()
    rows = TrainPassing.objects.filter(
        train__number=t["no"], service_date__gte=today - timedelta(days=LEARN_DAYS),
        delay_min__isnull=False).values_list(
        "station__code", "service_date", "weekday", "delay_min")
    by_wd, by_any = {}, {}
    for sid, sd, wd, dl in rows:
        age = (today - sd).days
        by_any.setdefault(sid, []).append((age, dl))
        if wd == weekday:
            by_wd.setdefault(sid, []).append((age, dl))
    out = {}
    for sid in by_any:
        r = L.learned_delay(by_wd.get(sid, []))
        scope = "weekday"
        if r is None:
            r = L.learned_delay(by_any[sid], L.DELAY_MIN_N_ANYDAY)
            scope = "any_day"
        if r is not None:
            out[sid] = dict(r, scope=scope)
    cache.set(ck, out, 3600)
    return out


def predicted(t, d, now=None):
    """No live data: position + delay from the learned usual delay. Labelled
    "predicted" (never live). None when nothing has been learned."""
    now = now or timezone.now()
    ld = learned_delays(t, d.weekday(), now.astimezone(TG.DHAKA).date())
    ss = stops(t)
    if not ld or not ss:
        return None
    known = [i for i, s in enumerate(ss) if s["id"] in ld]
    sched = sched_times(t, d)
    rows = []
    for i, s in enumerate(ss):
        if sched.get(s["id"]) is None:
            continue
        j = min(known, key=lambda k: (abs(k - i), k < i))   # nearest learned halt
        dl = ld[ss[j]["id"]]["delay_min"]
        rows.append((s, dl, sched[s["id"]] + timedelta(minutes=dl)))
    if not rows:
        return None
    first, last = rows[0][2], rows[-1][2]
    if now < first - timedelta(minutes=30) or now > last + timedelta(hours=1):
        return None
    x = L.predict_chainage([(s["ch"] / 1000.0, at.timestamp()) for s, _, at in rows],
                           now.timestamp())
    rt = route_index(t["no"])
    lat, lng = rt.point_at(x) if rt else (None, None)
    nxt = next((r for r in rows if r[0]["ch"] > x + 1), None)
    cover = len(known) / float(len(ss))
    return {"v": 1, "no": t["no"], "date": d.isoformat(), "mode": "predicted", "src": "learned",
            "freshness": {"state": "predicted", "updated_at": None, "age_s": None},
            "km": round(ch_to_km(t, x), 2), "ch": round(x),
            "lat": round(lat, 5) if lat else None,
            "lng": round(lng, 5) if lng else None, "speed_kmh": None,
            "next": ({"id": nxt[0]["id"], "bn": nxt[0]["bn"], "en": nxt[0]["en"],
                      "km": nxt[0]["km"], "eta": nxt[2].isoformat(),
                      "sched": sched[nxt[0]["id"]].isoformat(), "delay_min": nxt[1]}
                     if nxt else None),
            "etas": [[s["id"], at.astimezone(TG.DHAKA).isoformat()[11:16], dl,
                      int(SRC.official_time(t, s["id"]))] for s, dl, at in rows if s["ch"] > x + 1],
            "delay_min": nxt[1] if nxt else rows[-1][1],
            "confidence": round(L.PREDICT_CONF * (0.5 + 0.5 * cover), 2), "contributors": 0,
            "shift": {s["id"]: dl for s, dl, _ in rows},
            "learned_from": sum(v["n"] for v in ld.values())}


# ------------------------------------------------------------ F: shared / pasted text
def train_names():
    out = {}
    for x in SRC.trains():
        out[x["no"]] = [n for n in (x.get("name_bn"), x.get("name_en"), x.get("name"))
                        if n]
    return out


def known_trains():
    return {x["no"] for x in SRC.trains()}


def _pick_train(cands, sid, at):
    """Same name, two directions (771 / 772): the one whose line has the
    station and whose timetable there is nearest to the reported time."""
    best = None
    for no in cands:
        t = SRC.train(no)
        if t is None or _station_ch(t, sid)[0] is None:
            continue
        d = service_date_for(t, at)
        st = sched_times(t, d).get(sid)
        if st is None:
            _, ss = _station_ch(t, sid)
            dep, arr = SRC.times(t, d)
            st = dep + (arr - dep) * 0.5
        gap = abs((at - st).total_seconds())
        if best is None or gap < best[0]:
            best = (gap, t)
    return best[1] if best else None


def _time_ok(t, d, sid, at, now):
    if at > now + timedelta(minutes=10) or at < now - timedelta(hours=TEXT_PAST_H):
        return False
    dep, arr = SRC.times(t, d)
    return dep - timedelta(minutes=60) <= at <= arr + timedelta(hours=TG.LATE_END_H)


def _text_agrees(t, d, sid, kind, at, rep):
    """2+ independent reports: other sharers (short-lived Redis/cache list of
    keyed hashes, 1 h), an accepted check-in / text there, or the riders."""
    key = "train:txt:%s:%s:%s:%s" % (t["no"], d.isoformat(), sid, kind)
    seen = STORE.get(key) or []
    win = TEXT_MATCH_MIN * 60
    others = [s for s in seen if s[0] != rep and abs(s[1] - at.timestamp()) <= win]
    if not any(s[0] == rep for s in seen):
        seen.append([rep, at.timestamp()])
        STORE.set(key, seen[-20:], 3600)
    if others:
        return True
    if TrainObservation.objects.filter(
            train_no=t["no"], service_date=d, station=sid, kind=kind,
            at__gte=at - timedelta(seconds=win), at__lte=at + timedelta(seconds=win)).exists():
        return True
    return _gps_agrees(t, sid, at)


def share_text(user, text, no=None, date=None, lat=None, lng=None, acc=None, now=None):
    """-> (http status, body). Never stores the text, the sender or a phone
    number. Applied only after the plausibility checks."""
    now = now or timezone.now()
    if _limited(user, "text", TEXT_PER_HOUR, 3600):
        return 429, {"ok": False, "reason": "rate_limited"}
    t_hint = SRC.train(no) if no else None
    line = {s["id"] for s in SRC.line_stations(t_hint)} if t_hint else None
    p = TX.parse(text, SRC.stations(), now, TG.DHAKA, train_no=no, line_ids=line,
                 known_trains=known_trains(), train_names=train_names())
    if not p or not p.get("candidates"):
        return 400, {"ok": False, "reason": "unparsed"}
    t = _pick_train(p["candidates"], p["station_id"], p["at"])
    sinfo = SRC.stations().get(p["station_id"]) or {}
    parsed = {"no": t["no"] if t else p["no"], "station_id": p["station_id"],
              "station_bn": sinfo.get("bn", ""), "station_en": sinfo.get("en", ""),
              "kind": p["kind"], "at": p["at"].isoformat(), "late_min": p["late_min"]}
    if t is None:
        return 200, {"ok": True, "parsed": parsed, "applied": False, "status": "rejected",
                     "reason": "not_on_route"}
    d = date or service_date_for(t, p["at"])
    if not _time_ok(t, d, p["station_id"], p["at"], now):
        return 200, {"ok": True, "parsed": parsed, "applied": False, "status": "rejected",
                     "reason": "time_not_plausible"}
    _, st = _station_ch(t, p["station_id"])
    near = False
    la, ln = _num(lat), _num(lng)
    if la is not None and ln is not None and st.get("lat") is not None and \
            (_num(acc) or 0) <= 200:
        near = L.haversine_m(la, ln, float(st["lat"]), float(st["lng"])) <= NEAR_STATION_M
    if not (near or _text_agrees(t, d, p["station_id"], p["kind"], p["at"], _uh(user))):
        return 200, {"ok": True, "parsed": parsed, "applied": False, "status": "pending",
                     "reason": "waiting_for_second_report"}
    _add_obs(t, d, "text", p["station_id"], p["kind"], p["at"], p["late_min"],
             weight=0.4 if near else 0.3)
    record_passing(t, d, p["station_id"], p["at"], "text", p["kind"], 0.4 if near else 0.3)
    maybe_recompute(t, d, now, force=True)
    return 200, {"ok": True, "parsed": parsed, "applied": True, "status": "accepted"}


def sms_apply(user, text, no=None, date=None, now=None):
    """Back-compat name for the app's /train/sms16318 contract."""
    return share_text(user, text, no=no, date=date, now=now)


# ------------------------------------------------------------ B: "Are you on this train?"
def onboard_check(t, d, points, now=None):
    """Not stored. -> {ask, on_line, train_speed, forward, km, speed_kmh, running}."""
    now = now or timezone.now()
    rt = route_index(t["no"])
    if rt is None:
        return {"ask": False, "reason": "no_route"}
    pts = [normalize(p, now) for p in (points or [])[:10]]
    pts = [p for p in pts if p and now.timestamp() - p["at"] <= 600]
    hint = None
    for p in pts:
        ch, _ = rt.project(p["lat"], p["lng"]) if p["lat"] is not None else (None, None)
        hint = ch if ch is not None else hint
    out = L.onboard_signal(pts, rt, _seg_max(t, d, hint or 0.0))
    dep, arr = SRC.times(t, d)
    running = dep - timedelta(minutes=TG.EARLY_START_MIN) <= now <= \
        arr + timedelta(hours=TG.LATE_END_H)
    out["running"] = running
    out["ask"] = bool(out["ask"] and running)
    return out


# ------------------------------------------------------------ H: live state
def maybe_recompute(t, d, now=None, force=False):
    if force or STORE.add("train:lock:%s" % t["no"], RECOMPUTE_EVERY_S):
        try:
            return recompute(t, d, now)
        except Exception:   # noqa: BLE001 — the live state must never break ingest
            log.exception("train-engine: recompute failed for %s", t["no"])
    return None


def _riders(t, d, now):
    rt = route_index(t["no"])
    out = []
    trips = list(TrainTrip.objects.filter(train_no=t["no"], service_date=d,
                                          last_at__gte=now - timedelta(seconds=L.FRESH_S),
                                          kf__isnull=False))
    for tr in trips:
        kf = L.Kalman1D.from_state(tr.kf)
        if kf is None:
            continue
        kf.predict(min(now.timestamp(), max(kf.t or 0, now.timestamp())))
        out.append({"id": tr.id, "x": max(0.0, min(rt.length, kf.x)), "v": kf.v,
                    "sigma": kf.sigma(), "trust": tr.trust, "mode": tr.mode,
                    "at": tr.last_at})
    return trips, out


def _from_obs(t, d, now):
    o = TrainObservation.objects.filter(
        train_no=t["no"], service_date=d,
        at__gte=now - timedelta(minutes=OBS_FRESH_MIN)).order_by("-at", "-weight").first()
    if o is None:
        return None
    age = max(0.0, (now - o.at).total_seconds())
    x = o.chainage
    v = 0.0
    if o.kind == "left" or age > 300:
        v = standard_kmh(t, d) / 3.6
        x += v * age
    conf = round(max(0.05, o.weight * max(0.3, 1.0 - age / (OBS_FRESH_MIN * 60.0))), 2)
    return {"x": x, "v": v, "conf": min(conf, 0.6), "src": o.source, "n": 1, "at": o.at}


def _actuals(t, d):
    """Accepted check-ins / pasted replies -> {station: [iso time, checkins]}."""
    out = {}
    for o in TrainObservation.objects.filter(train_no=t["no"], service_date=d):
        cur = out.get(o.station)
        if cur is None or o.at.isoformat() < cur[0]:
            out[o.station] = [o.at.isoformat(), 0]
    counts = {}
    for sid in TrainCheckin.objects.filter(train_no=t["no"], service_date=d,
                                           status="accepted").values_list("station", flat=True):
        counts[sid] = counts.get(sid, 0) + 1
    for sid, n in counts.items():
        out.setdefault(sid, [None, 0])[1] = n
    return out


def recompute(t, d, now=None):
    """Fuse everything for one train/date and write `train:live:<no>`.
    Returns the state, or None when there is no live data (the read API then
    says "estimated from timetable")."""
    now = now or timezone.now()
    rt = route_index(t["no"])
    if rt is None:
        return None
    trips, riders = _riders(t, d, now)
    cons = L.consensus(riders)
    if cons:
        if cons["trust"]:
            for tr in trips:
                if tr.id in cons["trust"]:
                    tr.trust = round(cons["trust"][tr.id], 3)
            TrainTrip.objects.bulk_update([tr for tr in trips if tr.id in cons["trust"]],
                                          ["trust"])
        inl = [r for r in riders if r["id"] in cons["inliers"]]
        newest = max(r["at"] for r in inl)
        age = (now - newest).total_seconds()
        mean_trust = sum(r["trust"] for r in inl) / len(inl)
        conf = L.gps_confidence(len(inl), mean_trust, age, cons["agree"])
        src = "gps" if any(r["mode"] == "gps" for r in inl) else "cell"
        if src == "cell":
            conf = min(conf, 0.4)
        x, v, n, upd = cons["x"], cons["v"], len(inl), newest
    else:
        ob = _from_obs(t, d, now)
        if ob is None:
            return None
        x, v, n, conf, src, upd = ob["x"], ob["v"], ob["n"], ob["conf"], ob["src"], ob["at"]
    x = max(0.0, min(rt.length, x))
    prev = STORE.get(live_key(t["no"]))
    if prev and prev.get("date") != d.isoformat():
        prev = None
    hist = L.push_hist((prev or {}).get("hist"), now.timestamp(), x)
    now_kmh = v * 3.6
    spd = L.eta_speed_kmh(now_kmh, hist, standard_kmh(t, d))
    sched = sched_times(t, d)
    passed = dict((prev or {}).get("passed") or {})
    prev_x = float(prev["ch"]) if prev and prev.get("ch") is not None else None
    ss = stops(t)
    last_s = next_s = None
    etas = []
    for s in ss:
        m = s["ch"]
        if sched.get(s["id"]) is None:
            continue
        if m <= x + 150.0:
            last_s = s
            if s["id"] not in passed and prev_x is not None and prev_x < m - 150.0:
                passed[s["id"]] = now.isoformat()
                if src == "gps" and conf >= PASS_CONF:
                    record_passing(t, d, s["id"], now, "gps", "reached", conf)
            continue
        eta = (now + timedelta(minutes=L.eta_minutes((m - x) / 1000.0, spd))).astimezone(TG.DHAKA)
        official = SRC.official_time(t, s["id"])
        # delay only against an OFFICIAL time — never against a time we placed
        delay = int(round((eta - sched[s["id"]]).total_seconds() / 60.0)) if official else None
        etas.append({"id": s["id"], "eta": eta.isoformat(), "sched": sched[s["id"]].isoformat(),
                     "delay_min": delay, "official": official})
        if next_s is None:
            next_s = s
    lat, lng = rt.point_at(x)
    delay = next((e["delay_min"] for e in etas if e["delay_min"] is not None), None) \
        if etas else (
        int(round((now - sched[ss[-1]["id"]]).total_seconds() / 60.0))
        if ss and sched.get(ss[-1]["id"]) else None)

    def _st(s, extra=None):
        if s is None:
            return None
        return dict({"id": s["id"], "bn": s["bn"], "en": s["en"], "km": s["km"]}, **(extra or {}))

    state = {
        "v": 1, "no": t["no"], "date": d.isoformat(), "mode": "live" if src in ("gps", "cell")
        else "reported", "src": src,
        "km": round(ch_to_km(t, x), 2), "ch": round(x), "lat": round(lat, 5),
        "lng": round(lng, 5),
        "speed_kmh": round(now_kmh) if src in ("gps", "cell") else None,
        "avg_kmh": round(spd),
        "last": _st(last_s, {"at": passed.get(last_s["id"]) if last_s else None}),
        "next": _st(next_s, etas[0] if etas else None),
        "etas": etas, "delay_min": delay, "confidence": min(L.CONF_CAP, conf),
        "contributors": n, "updated_at": upd.isoformat(), "computed_at": now.isoformat(),
        "hist": hist, "passed": passed,
    }
    STORE.set(live_key(t["no"]), state, LIVE_TTL_S)
    return state


def _age(state, now):
    try:
        return max(0, int((now - datetime.fromisoformat(state["updated_at"])).total_seconds()))
    except (KeyError, ValueError, TypeError):
        return None


def read(t, d, now=None):
    """The tiny public payload for the app (no rider data, no ids)."""
    now = now or timezone.now()
    st = STORE.get(live_key(t["no"]))
    if st and st.get("date") == d.isoformat():
        age = _age(st, now)
        fresh = "live" if age is not None and age <= L.FRESH_S else "stale"
        acts = _actuals(t, d)
        return {"v": 1, "no": t["no"], "date": st["date"], "mode": st["mode"], "src": st["src"],
                "freshness": {"state": fresh, "updated_at": st["updated_at"], "age_s": age},
                "km": st["km"], "ch": st.get("ch"), "lat": st["lat"], "lng": st["lng"],
                "speed_kmh": st["speed_kmh"], "avg_kmh": st["avg_kmh"],
                "last": st["last"], "next": st["next"],
                # [station, ETA HH:MM, delay vs official time | null, 1 = official time]
                "etas": [[e["id"], e["eta"][11:16], e["delay_min"], int(e.get("official", 1))]
                         for e in st["etas"]],
                "delay_min": st["delay_min"], "confidence": st["confidence"],
                "contributors": st["contributors"],
                "actual": {k: (st["passed"].get(k) or (acts.get(k) or [None])[0])
                           for k in set(st["passed"]) | set(acts)},
                "checkins": {k: v[1] for k, v in acts.items() if v[1]}}
    return predicted(t, d, now) or timetable_payload(t, d, now)


def timetable_payload(t, d, now):
    """No live data and nothing learned: where the timetable says it is."""
    sched = sched_times(t, d)
    ss = [s for s in stops(t) if sched.get(s["id"])]
    if not ss:
        return {"v": 1, "no": t["no"], "date": d.isoformat(), "mode": "timetable",
                "src": "timetable", "note_bn": NOTE_BN, "note_en": NOTE_EN,
                "freshness": {"state": "timetable", "updated_at": None, "age_s": None},
                "state": None, "km": None, "ch": None, "lat": None, "lng": None,
                "speed_kmh": None, "next": None, "etas": [], "delay_min": None,
                "confidence": 0.1, "contributors": 0}
    first, last = sched[ss[0]["id"]], sched[ss[-1]["id"]]
    state = "not_started" if now < first else ("arrived" if now >= last else "running")
    ch = L.predict_chainage([(s["ch"] / 1000.0, sched[s["id"]].timestamp()) for s in ss],
                            now.timestamp())
    rt = route_index(t["no"])
    lat, lng = rt.point_at(ch) if rt else (None, None)
    nxt = next((s for s in ss if s["ch"] > ch + 1), None)
    return {"v": 1, "no": t["no"], "date": d.isoformat(), "mode": "timetable", "src": "timetable",
            "note_bn": NOTE_BN, "note_en": NOTE_EN,
            "freshness": {"state": "timetable", "updated_at": None, "age_s": None},
            "state": state, "runs": SRC.runs_on(t, d),
            "km": round(ch_to_km(t, ch), 2), "ch": round(ch),
            "lat": round(lat, 5) if lat is not None else None,
            "lng": round(lng, 5) if lng is not None else None, "speed_kmh": None,
            "next": ({"id": nxt["id"], "bn": nxt["bn"], "en": nxt["en"], "km": nxt["km"],
                      "eta": sched[nxt["id"]].isoformat()} if nxt else None),
            "etas": [[s["id"], sched[s["id"]].isoformat()[11:16], None,
                      int(SRC.official_time(t, s["id"]))] for s in ss if s["ch"] > ch + 1],
            "delay_min": None, "confidence": 0.1, "contributors": 0}


@lru_cache(maxsize=1)
def _code_by_name():
    out = {}
    for code, st in SRC.stations().items():
        for n in (st.get("bn"), st.get("en")):
            if n:
                out.setdefault(n.strip().lower(), code)
    return out


def _code_for(row):
    """A v1 line row (old OSM id) -> the official station code (by id, else name)."""
    sid = row.get("id")
    if sid in SRC.stations():
        return sid
    names = _code_by_name()
    for n in (row.get("bn"), row.get("en")):
        if n and n.strip().lower() in names:
            return names[n.strip().lower()]
    return sid


def enrich_live_view(view, t, d, now=None):
    """Additive keys on the existing GET /train/<no>/live (app contract):
    freshness, live.{speed_kmh, confidence, contributors, eta_next},
    line.stations[i].{actual, delay_min, checkins}."""
    now = now or timezone.now()
    t = SRC.train(t["no"])          # the official data (v1 still reads the old file)
    if t is None:
        return view
    r = read(t, d, now)
    view["freshness"] = r["freshness"]
    view["engine"] = r
    if r["mode"] == "timetable":
        view["freshness"] = dict(r["freshness"], note_bn=NOTE_BN, note_en=NOTE_EN)
        return view
    if r["mode"] == "predicted":           # learned usual delay — never "live"
        view["predicted"] = {"delay_min": r["delay_min"], "chainage_m": r.get("ch"),
                             "basis_n": r.get("learned_from", 0), "lat": r["lat"],
                             "lng": r["lng"], "next": r["next"], "confidence": r["confidence"]}
        shift = {sid: dl for sid, dl in (r.get("shift") or {}).items()}
        for s in (view.get("line") or {}).get("stations") or []:
            sid = _code_for(s)
            dl = shift.get(sid, r["delay_min"])
            if dl is not None and s.get("sched"):
                try:
                    s["eta"] = (datetime.fromisoformat(s["sched"]) +
                                timedelta(minutes=dl)).isoformat()
                    s["delay_min"] = dl
                except ValueError:
                    pass
        return view
    if r["mode"] == "reported":            # check-ins / shared text only: low confidence
        view["reported"] = {"km": r["km"], "lat": r["lat"], "lng": r["lng"], "source": r["src"],
                            "confidence": r["confidence"], "age_s": r["freshness"]["age_s"],
                            "delay_min": r["delay_min"], "next": r["next"]}
    live = view.get("live")
    if not live and r["mode"] != "live":
        live = {}
    elif not live:
        live = {"label": "live", "chainage_m": r.get("ch"), "lat": r["lat"],
                "lng": r["lng"], "sharers": r["contributors"], "dropped": 0,
                "age_s": r["freshness"]["age_s"], "arrived": False}
        view["live"] = live
        view["mode"] = "live"
        view["sharers"] = r["contributors"]
    if not live:
        live = view.get("reported") or {}
    live.update(speed_kmh=r["speed_kmh"], confidence=r["confidence"],
                contributors=r["contributors"], source=r["src"],
                eta_next=(r["next"] or {}).get("eta"))
    if r["delay_min"] is not None:
        view["delay_min"] = r["delay_min"]
    delays = {e[0]: e[2] for e in r["etas"]}
    for s in (view.get("line") or {}).get("stations") or []:
        sid = _code_for(s)
        if r["actual"].get(sid):
            s["actual"] = r["actual"][sid]
        if sid in delays:
            s["delay_min"] = delays[sid]
        if r["checkins"].get(sid):
            s["checkins"] = r["checkins"][sid]
    return view


# ------------------------------------------------------------ offline pack (towers)
@lru_cache(maxsize=1)
def _segment_indexes():
    """[(RouteIndex, bbox)] per rail segment, in br_segments.geojson order."""
    out = []
    for a, b in SRC.segment_index():
        path = SRC.segment_path(a, b)
        if len(path) < 2:
            out.append((None, None))
            continue
        lats, lngs = [p[0] for p in path], [p[1] for p in path]
        out.append((L.RouteIndex(path), (min(lats) - 0.02, max(lats) + 0.02,
                                         min(lngs) - 0.02, max(lngs) + 0.02)))
    return out


def tower_map():
    """Learned towers for the offline bundle's `tw` (format in the plan doc,
    "অফলাইন বান্ডেল"): [mcc, mnc, tac, cid, segment index, metres into that
    segment, samples, lat x 1e5, lng x 1e5] — the strongest bin per tower snapped to the nearest
    rail segment (<= 1.5 km). Aggregate counts only, no rider, no time."""
    best = {}
    for cell, bi, bj, n in TrainCellBin.objects.values_list("cell", "bi", "bj", "n"):
        tot = best.setdefault(cell, [0, None])
        tot[0] += n
        if tot[1] is None or n > tot[1][2]:
            tot[1] = (bi, bj, n)
    segs = _segment_indexes()
    out = []
    for cell, (total, (bi, bj, _)) in sorted(best.items()):
        if total < L.CELL_MIN_N:
            continue
        lat, lng = L.bin_center(bi, bj)
        hit = None
        for i, (ri, bb) in enumerate(segs):
            if ri is None or not (bb[0] <= lat <= bb[1] and bb[2] <= lng <= bb[3]):
                continue
            ch, off = ri.project(lat, lng, radius_cells=2)
            if ch is not None and off <= L.CELL_ON_ROUTE_M and (hit is None or off < hit[2]):
                hit = (i, ch, off, ri)
        if hit is None:
            continue
        mcc, mnc, tac, cid = (int(x) for x in cell.split("-"))
        plat, plng = hit[3].point_at(hit[1])      # the learned point, snapped to the line
        out.append([mcc, mnc, tac, cid, hit[0], int(round(hit[1])), int(total),
                    int(round(plat * 1e5)), int(round(plng * 1e5))])
    return out


def offline_pack(force=False):
    """The DATA lane's offline bundle (train_data.offline_bundle()) with the
    learned tower map filled into `tw`. -> (meta, gzip bytes); cached 6 h."""
    meta = None if force else STORE.get("train:offline:meta")
    blob = None if force else cache.get("train:offline:gz")
    if meta and blob:
        return meta, blob
    from . import train_data
    raw, _gz, _ver = train_data.offline_bundle()
    body = json.loads(raw)
    body.pop("ver", None)
    body["tw"] = tower_map()
    raw = json.dumps(body, separators=(",", ":"), ensure_ascii=False).encode()
    version = hashlib.sha256(raw).hexdigest()[:12]
    body["ver"] = version
    raw = json.dumps(body, separators=(",", ":"), ensure_ascii=False).encode()
    blob = gzip.compress(raw, 9, mtime=0)
    meta = {"version": version, "size_bytes": len(blob), "raw_bytes": len(raw),
            "updated_at": timezone.now().isoformat(), "trains": len(body.get("tr") or []),
            "towers": len(body["tw"])}
    STORE.set("train:offline:meta", meta, OFFLINE_TTL_S)
    cache.set("train:offline:gz", blob, OFFLINE_TTL_S)
    return meta, blob


# ------------------------------------------------------------ tick (minute_jobs)
def purge(now=None):
    """Delete raw points, trips, observations and check-ins older than 24 h
    (bounded batches). -> {table: deleted}."""
    now = now or timezone.now()
    cut = now - timedelta(hours=KEEP_H)
    out = {}
    for name, qs in (("pings", TrainPing.objects.filter(created_at__lt=cut)),
                     ("trips", TrainTrip.objects.filter(created_at__lt=cut)),
                     ("observations", TrainObservation.objects.filter(created_at__lt=cut)),
                     ("checkins", TrainCheckin.objects.filter(created_at__lt=cut))):
        ids = list(qs.values_list("id", flat=True)[:PURGE_BATCH])
        out[name] = qs.model.objects.filter(id__in=ids).delete()[0] if ids else 0
    return out


def tick(now=None):
    """One minute_jobs step: purge, then refresh the live state of trains
    that have fresh riders/reports so ETAs keep moving. Idle = 2 reads."""
    now = now or timezone.now()
    out = purge(now)
    active = set(TrainTrip.objects.filter(last_at__gte=now - timedelta(seconds=L.FRESH_S))
                 .values_list("train_no", "service_date")[:200])
    active |= set(TrainObservation.objects.filter(at__gte=now - timedelta(minutes=OBS_FRESH_MIN))
                  .values_list("train_no", "service_date")[:200])
    n = 0
    for no, d in active:
        t = SRC.train(no)
        if t is not None and maybe_recompute(t, d, now, force=True) is not None:
            n += 1
    out["recomputed"] = n
    return out
