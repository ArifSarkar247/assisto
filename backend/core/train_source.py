"""train-engine — read-only view of the OFFICIAL train data for the live engine.

Source: the DATA lane's committed files (the same ones `load_bd_trains` puts
in PostgreSQL tables br_trains / br_stations / br_train_schedules /
br_rail_segments): data/train/br_trains.json, br_stations.json and
br_segments.geojson (OSM, ODbL). Reading the files (cached once per process)
keeps the hot ping path free of DB queries and works in SimpleTestCase.

Shapes (what core/train_engine.py uses):
  train(no) -> {no, name_bn, name_en, status, off_days, dep "HH:MM", arr "HH:MM",
                stops: [{st: code, km, arr, dep, arr_day, dep_day}], path: [[lat, lng]..],
                km}
  stations() -> {code: {bn, en, lat, lng}}
  times(t, d) -> (departure, arrival) aware datetimes (Asia/Dhaka)
  stop_times(t, d) -> {code: scheduled datetime (arrival, else departure)}
  line_stations(t) -> [{id, bn, en, km, ch, lat, lng, stop}]
  (km = official distance for display; ch = metres along the path, used for
  every position / ETA computation so the two never disagree)
  segment_index() -> [(from, to)] in br_segments.geojson order (offline towers)
"""
import json
import os
from datetime import datetime, timedelta
from functools import lru_cache

from .logic import train_geo as TG
from .logic.train_live import haversine_m

DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "train")
DHAKA = TG.DHAKA


def _read(name):
    with open(os.path.join(DATA, name), encoding="utf-8") as fh:
        return json.load(fh)


@lru_cache(maxsize=1)
def stations():
    out = {}
    for s in _read("br_stations.json")["stations"]:
        out[s["code"]] = {"bn": s.get("name_bn", ""), "en": s.get("name_en", ""),
                          "lat": s.get("lat"), "lng": s.get("lng")}
    return out


@lru_cache(maxsize=1)
def _segments():
    g = _read("br_segments.geojson")
    by, order = {}, []
    for f in g["features"]:
        p = f["properties"]
        pts = [[c[1], c[0]] for c in f["geometry"]["coordinates"]]
        by[(p["from"], p["to"])] = pts
        order.append((p["from"], p["to"]))
    return by, order


def segment_index():
    return _segments()[1]


# OSM gaps: a segment whose OSM line is far longer than the straight line
# between its two stations follows a detour (e.g. Pabna-Tebunia: 24 km of OSM
# line for 8 km between the stations — the track there is missing in OSM).
# Such a segment is drawn as the straight chord and riders there are matched
# with a wide tolerance (by progress between the two stations).
LOWQ_SEGMENTS = {("pabna", "tebunia")}     # confirmed by the data lane
LOWQ_RATIO = 2.5
LOWQ_EXTRA_KM = 8.0


def _len_m(path):
    return sum(haversine_m(a[0], a[1], b[0], b[1]) for a, b in zip(path, path[1:]))


@lru_cache(maxsize=4096)
def segment_low_quality(a, b):
    """True when the OSM line between stations a and b is not trustworthy."""
    if (a, b) in LOWQ_SEGMENTS or (b, a) in LOWQ_SEGMENTS:
        return True
    by, _ = _segments()
    seg = by.get((a, b)) or by.get((b, a))
    st = stations()
    sa, sb = st.get(a) or {}, st.get(b) or {}
    if not seg or sa.get("lat") is None or sb.get("lat") is None:
        return False
    chord = haversine_m(sa["lat"], sa["lng"], sb["lat"], sb["lng"])
    length = _len_m(seg)
    return chord > 0 and length / chord >= LOWQ_RATIO and \
        (length - chord) / 1000.0 >= LOWQ_EXTRA_KM


def segment_path(a, b):
    if segment_low_quality(a, b):
        st = stations()
        return [[st[a]["lat"], st[a]["lng"]], [st[b]["lat"], st[b]["lng"]]]
    by, _ = _segments()
    if (a, b) in by:
        return by[(a, b)]
    if (b, a) in by:
        return list(reversed(by[(b, a)]))
    st = stations()
    sa, sb = st.get(a) or {}, st.get(b) or {}
    if sa.get("lat") is None or sb.get("lat") is None:
        return []
    return [[sa["lat"], sa["lng"]], [sb["lat"], sb["lng"]]]   # no OSM line: straight


def _mins(v):
    return int(v[:2]) * 60 + int(v[3:5]) if v else None


def _days(stops):
    """Day offsets: a clock time earlier than the previous one = next day."""
    out, day, prev = [], 0, None
    for s in stops:
        a, d = _mins(s.get("arr")), _mins(s.get("dep"))
        ad = dd = None
        if a is not None:
            if prev is not None and a < prev:
                day += 1
            ad, prev = day, a
        if d is not None:
            if prev is not None and d < prev:
                day += 1
            dd, prev = day, d
        out.append((ad, dd))
    return out


def _build(t):
    stops = []
    for s, (ad, dd) in zip(t["stops"], _days(t["stops"])):
        stops.append({"st": s["station"], "km": float(s.get("km") or 0.0), "ch": None,
                      "arr": s.get("arr"), "dep": s.get("dep"),
                      "arr_day": ad, "dep_day": dd, "src": s.get("src", "official")})
    path, ch, lowq = [], 0.0, []
    if stops:
        stops[0]["ch"] = 0.0
    for a, b in zip(stops, stops[1:]):
        seg = segment_path(a["st"], b["st"])
        if segment_low_quality(a["st"], b["st"]):
            lowq.append([a["ch"], None])
        seg = seg[1:] if path and seg else seg
        for p in seg:
            if path:
                ch += haversine_m(path[-1][0], path[-1][1], p[0], p[1])
            path.append(p)
        b["ch"] = ch            # metres along THIS path (the engine's chainage)
        if lowq and lowq[-1][1] is None:
            lowq[-1][1] = ch
    first = next((s for s in stops if s["dep"]), stops[0])
    last = next((s for s in reversed(stops) if s["arr"]), stops[-1])
    return {"no": t["no"], "name_bn": t.get("name_bn", ""), "name_en": t.get("name_en", ""),
            "status": t.get("status", "running"), "off_days": t.get("off_days") or [],
            "kind": t.get("kind", ""), "dep": first["dep"], "arr": last["arr"] or last["dep"],
            "arr_day": last["arr_day"] if last["arr"] else last["dep_day"],
            "stops": stops, "path": path, "km": stops[-1]["km"] if stops else 0.0,
            "lowq": [tuple(r) for r in lowq]}


def official_time(t, code):
    """True when the official timetable lists a time for this halt (else any
    time shown for it is an estimate between known halts)."""
    return any(s["st"] == code and (s.get("arr") or s.get("dep")) for s in t.get("stops") or [])


@lru_cache(maxsize=1)
def _trains():
    out = {}
    for t in _read("br_trains.json")["trains"]:
        if t.get("stops"):
            out[t["no"]] = _build(t)
    return out


def trains():
    return list(_trains().values())


def train(no):
    return _trains().get(str(no or "").strip())


def _at(d, hm, day):
    h, m = int(hm[:2]), int(hm[3:5])
    return datetime(d.year, d.month, d.day, h, m, tzinfo=DHAKA) + timedelta(days=day or 0)


def times(t, d):
    dep = _at(d, t["dep"], 0)
    arr = _at(d, t["arr"], t.get("arr_day") or 0)
    if arr <= dep:
        arr += timedelta(days=1)
    return dep, arr


def stop_times(t, d, km_total=None):
    """{code: scheduled datetime}. Stops without an official time (mail /
    commuter halts) are interpolated by distance between the timed ones."""
    out = {}
    timed = []
    for s in t["stops"]:
        if s["arr"]:
            at = _at(d, s["arr"], s["arr_day"])
        elif s["dep"]:
            at = _at(d, s["dep"], s["dep_day"])
        else:
            at = None
        out[s["st"]] = at
        if at is not None:
            timed.append((s["km"], at))
    for s in t["stops"]:
        if out[s["st"]] is None and len(timed) >= 2:
            lo = max((x for x in timed if x[0] <= s["km"]), default=timed[0])
            hi = min((x for x in timed if x[0] >= s["km"]), default=timed[-1])
            f = 0.0 if hi[0] == lo[0] else (s["km"] - lo[0]) / (hi[0] - lo[0])
            out[s["st"]] = lo[1] + (hi[1] - lo[1]) * f
    return out


def runs_on(t, d):
    return d.weekday() not in set(t.get("off_days") or [])


def line_stations(t):
    st = stations()
    return [dict(id=s["st"], bn=(st.get(s["st"]) or {}).get("bn", ""),
                 en=(st.get(s["st"]) or {}).get("en", ""), km=s["km"],
                 ch=s.get("ch", s["km"] * 1000.0),
                 lat=(st.get(s["st"]) or {}).get("lat"), lng=(st.get(s["st"]) or {}).get("lng"),
                 stop=True) for s in t["stops"]]


def stop_dep(t, d, code):
    """Scheduled departure at one halt (None when the timetable has none)."""
    for s in t["stops"]:
        if s["st"] == code and s["dep"]:
            return _at(d, s["dep"], s["dep_day"])
    return None


# ------------------------------------------------------------ v1 (train_geo) shape
LINE_STATION_M = 300.0        # a station this close to the path is "on the line"


def _meta():
    tm = _read("br_trains.json").get("_meta") or {}
    g = _read("br_segments.geojson").get("_meta") or {}
    src = (tm.get("timetable") or g.get("timetable") or {}).get("sources") or {}
    eds = sorted({v.get("edition", "") for v in src.values() if v.get("edition")})
    return {
        "trains_source": "Bangladesh Railway official timetable (railway.gov.bd, east + west "
                         "zones + cross-border page; editions %s)" % ", ".join(eds),
        "geometry": "ODbL 1.0 — © OpenStreetMap contributors "
                    "(https://www.openstreetmap.org/copyright)",
        "osm_base": g.get("osm_rail_base") or g.get("osm_stations_base"),
        "built": (tm.get("timetable") or {}).get("fetched") or tm.get("fetched"),
        "approval": "Official times. Every train stays approved:false until the owner "
                    "checks it in closed testing; positions without live data are "
                    "labelled 'timetable estimate'.",
        "stop_times": "Official time at every listed halt; other stations are placed by "
                      "rail distance (estimate).",
        "source": "official",
    }


def _geo_train(t):
    """The official train in the shape core.logic.train_geo has always used.
    Stop "km" = metres along this train's path / 1000 (positions and stops
    agree); the official distance stays in "km_official"."""
    raw = next((x for x in _read("br_trains.json")["trains"] if x["no"] == t["no"]), {})
    stops = [{"st": s["st"], "km": round((s.get("ch") or 0.0) / 1000.0, 3),
              "km_official": s["km"], "arr": s["arr"], "dep": s["dep"],
              "arr_day": s["arr_day"], "dep_day": s["dep_day"]} for s in t["stops"]]
    return {"no": t["no"], "name_bn": t["name_bn"], "name_en": t["name_en"],
            "from": stops[0]["st"], "to": stops[-1]["st"], "dep": t["dep"], "arr": t["arr"],
            "arr_day": t.get("arr_day") or 0, "off_days": t["off_days"], "stops": stops,
            "path": t["path"], "km": round(stops[-1]["km"], 1), "approved": False,
            "lowq": t.get("lowq") or [],
            "status": t["status"], "kind": t["kind"], "source": raw.get("source") or {}}


@lru_cache(maxsize=1)
def geo_timetable():
    """{"_meta", "stations", "trains"} for core.logic.train_geo (v1 screens,
    search, Safe Journey train flow, destination alarm)."""
    rows = [_geo_train(t) for t in trains() if len(t.get("path") or []) >= 2]
    return {"_meta": _meta(), "stations": stations(), "trains": rows}


@lru_cache(maxsize=1024)
def geo_line_stations(no):
    """Every station the train passes, in order: its halts (stop=True) plus
    the timetable stations within LINE_STATION_M of its path between them
    (stop=False). [{id, bn, en, km, lat, lng, stop}]."""
    from .logic.train_live import RouteIndex
    t = next((x for x in geo_timetable()["trains"] if x["no"] == no), None)
    if t is None:
        return []
    st = stations()
    rows = {s["st"]: dict(id=s["st"], bn=st.get(s["st"], {}).get("bn", ""),
                          en=st.get(s["st"], {}).get("en", ""), km=s["km"],
                          lat=st.get(s["st"], {}).get("lat"), lng=st.get(s["st"], {}).get("lng"),
                          stop=True) for s in t["stops"]}
    ri = RouteIndex(t["path"])
    first, last = t["stops"][0]["km"] * 1000.0, t["stops"][-1]["km"] * 1000.0
    for code, s in st.items():
        if code in rows or s.get("lat") is None:
            continue
        ch, off = ri.project(s["lat"], s["lng"])
        if ch is not None and off <= LINE_STATION_M and first < ch < last:
            rows[code] = dict(id=code, bn=s.get("bn", ""), en=s.get("en", ""),
                              km=round(ch / 1000.0, 3), lat=s["lat"], lng=s["lng"], stop=False)
    return sorted(rows.values(), key=lambda r: (r["km"], not r["stop"]))
