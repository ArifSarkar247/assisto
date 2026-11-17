"""train-data (Train Tracker V2): load the official Bangladesh Railway
timetable + OSM rail geometry into PostgreSQL, check completeness, and build
the compact offline bundle for phones.

Files (committed, built by tools/train/br/*.py — never fetched at run time):
  data/train/br_official.json    the official list (what the CI check compares to)
  data/train/br_trains.json      trains + stops with station codes + km from origin
  data/train/br_stations.json    stations, lat/lng + source
  data/train/br_segments.geojson rail line per consecutive stop pair (ODbL)
"""
import datetime
import gzip
import hashlib
import json
import os
from functools import lru_cache

from django.db import transaction

DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "train")
KIND_CODE = {"intercity": 1, "mail": 2, "commuter": 3, "local": 4, "international": 5}
STATUS_CODE = {"running": 1, "suspended": 2, "proposed": 3, "withdrawn": 4}
# trains the owner named: the CI check fails loudly if any is missing
MUST_HAVE = {
    "771": ("রংপুর এক্সপ্রেস", "ঢাকা", "রংপুর"),
    "772": ("রংপুর এক্সপ্রেস", "রংপুর", "ঢাকা"),
}
CROSS_BORDER = ("মৈত্রী এক্সপ্রেস", "বন্ধন এক্সপ্রেস", "মিতালী এক্সপ্রেস")


def nuk(s):
    """One spelling for the nukta letters (precomposed ড় ঢ় য়)."""
    return (s or "").replace("\u09a1\u09bc", "\u09dc").replace("\u09a2\u09bc", "\u09dd").replace("\u09af\u09bc", "\u09df")


def _read(name):
    with open(os.path.join(DATA, name), encoding="utf-8") as f:
        return json.load(f)


@lru_cache(maxsize=1)
def official():
    return _read("br_official.json")


def official_numbers():
    return [t["no"] for t in official()["trains"]]


def _time(v):
    if not v:
        return None
    h, m = v.split(":")
    return datetime.time(int(h), int(m))


def _days(stops):
    """Midnight count for each stop's arr/dep (times roll over past 00:00)."""
    out, prev, day = [], None, 0
    for s in stops:
        rec = {}
        for f in ("arr", "dep"):
            v = s.get(f)
            if not v:
                rec[f] = day
                continue
            m = int(v[:2]) * 60 + int(v[3:])
            if prev is not None and m < prev:
                day += 1
            prev = m
            rec[f] = day
        out.append(rec)
    return out


def load(stdout=None):
    """Upsert everything. Idempotent; a train that left the official list is
    marked status=withdrawn (its passing history is kept)."""
    from .models import RailSegment, RailStation, RailTrain, RailTrainStop

    stations = _read("br_stations.json")["stations"]
    trains = _read("br_trains.json")["trains"]
    segs = _read("br_segments.geojson")["features"]
    with transaction.atomic():
        by_code = {}
        for s in stations:
            obj, _ = RailStation.objects.update_or_create(code=s["code"], defaults={
                "name_bn": s["name_bn"], "name_en": s["name_en"], "district": s.get("district") or "",
                "lat": s.get("lat"), "lng": s.get("lng"), "coord_source": (s.get("coord_source") or "")[:200],
                "osm_id": s.get("osm_id") or ""})
            by_code[s["code"]] = obj
        seen = set()
        for t in trains:
            src = t.get("source") or {}
            fetched = src.get("fetched")
            obj, _ = RailTrain.objects.update_or_create(number=t["no"], defaults={
                "name_bn": t["name_bn"], "name_en": t["name_en"], "kind": t["kind"], "zone": t["zone"],
                "status": t["status"], "status_note": t.get("status_note", ""),
                "origin": by_code[t["origin_code"]], "destination": by_code[t["destination_code"]],
                "off_days": t.get("off_days") or [], "bd_section_only": bool(t.get("bd_section_only")),
                "source_url": src.get("url") or "", "source_file": src.get("file") or "",
                "source_edition": src.get("edition") or "",
                "source_fetched": datetime.date.fromisoformat(fetched) if fetched else None})
            seen.add(t["no"])
            RailTrainStop.objects.filter(train=obj).delete()
            days = _days(t["stops"])
            RailTrainStop.objects.bulk_create([RailTrainStop(
                train=obj, seq=i, station=by_code[s["station"]], arr_time=_time(s.get("arr")),
                dep_time=_time(s.get("dep")), arr_day=days[i]["arr"], dep_day=days[i]["dep"],
                km_from_origin=s.get("km"), time_source="corrected" if s.get("note") else "official",
                note=(s.get("note") or "")[:200]) for i, s in enumerate(t["stops"])])
        RailTrain.objects.exclude(number__in=seen).update(status="withdrawn")
        for f in segs:
            p = f["properties"]
            RailSegment.objects.update_or_create(code=p["id"], defaults={
                "from_station": by_code[p["from"]], "to_station": by_code[p["to"]], "km": p["km"],
                "geometry": f["geometry"]["coordinates"]})
    counts = {"stations": len(stations), "trains": len(trains), "segments": len(segs)}
    if stdout:
        stdout.write("loaded %(trains)d trains, %(stations)d stations, %(segments)d rail segments" % counts)
    return counts


def check():
    """Return a list of problems (empty = complete): every official train is
    in the DB (not withdrawn), Rangpur Express both ways, cross-border trains."""
    from .models import RailTrain

    problems = []
    have = {t.number: t for t in RailTrain.objects.select_related("origin", "destination")}
    for no in official_numbers():
        t = have.get(no)
        if t is None:
            problems.append("missing train %s" % no)
        elif t.status == "withdrawn":
            problems.append("train %s is withdrawn but still in the official list" % no)
    for no, (name, a, b) in MUST_HAVE.items():
        t = have.get(no)
        if t is None or nuk(t.name_bn) != nuk(name) or nuk(t.origin.name_bn) != nuk(a) \
                or nuk(t.destination.name_bn) != nuk(b):
            problems.append("%s %s %s→%s not loaded correctly" % (no, name, a, b))
        elif t.stops.count() < 2:
            problems.append("%s has no stops" % no)
    for name in CROSS_BORDER:
        if not any(nuk(t.name_bn) == nuk(name) for t in have.values()):
            problems.append("cross-border train %s missing" % name)
    return problems


def _mins(v):
    return int(v[:2]) * 60 + int(v[3:]) if v else -1


@lru_cache(maxsize=1)
def offline_bundle():
    """Compact timetable for the phone (offline, weekly refresh). Index-based
    arrays; see owner_actions/TRAIN_TRACKER_V2_BN.md "অফলাইন বান্ডেল".
    Returns (json_bytes, gzip_bytes, version)."""
    stations = _read("br_stations.json")["stations"]
    trains = _read("br_trains.json")["trains"]
    sidx = {s["code"]: i for i, s in enumerate(stations)}
    st = [[s["code"], s["name_bn"], s["name_en"],
           round(s["lat"] * 1e5) if s.get("lat") is not None else None,
           round(s["lng"] * 1e5) if s.get("lng") is not None else None] for s in stations]
    tr = []
    for t in trains:
        mask = 0
        for d in t.get("off_days") or []:
            mask |= 1 << d
        tr.append([t["no"], t["name_bn"], t["name_en"], KIND_CODE[t["kind"]], STATUS_CODE[t["status"]], mask,
                   [[sidx[s["station"]], _mins(s.get("arr")), _mins(s.get("dep")),
                     round(s["km"] * 10) if s.get("km") is not None else -1] for s in t["stops"]]])
    body = {"v": 1, "st": st, "tr": tr, "tw": []}
    raw = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    version = hashlib.sha256(raw).hexdigest()[:12]
    body["ver"] = version
    raw = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return raw, gzip.compress(raw, 9, mtime=0), version
