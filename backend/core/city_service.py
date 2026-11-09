"""citydata (owner 9 Nov 11:45): City Service data + routing (server side).

* Data: GitHub Actions builds each city's compact network + directory
  (.github/workflows/transit_data.yml); `tick()` (inside minute_jobs, via
  `manage.py city_tick`) pulls only those small release files. The server
  never downloads or processes OpenStreetMap itself.
* Routing: core.citytransit.engine (light RAPTOR, in-process, cached per data
  version; one tiny version query per request).
* Owner overrides (CityDataset.overrides) survive every monthly refresh:
  rates, hidden / edited stops & routes, approved gate facts, learned routes.
* Users: one-tap corrections, live reports (60-minute expiry, moderated),
  fares paid (-> "Reported by users"), night safety stars, consented
  name-free trip traces (trip learning).
Zero Google calls: other cities get an honest "no data yet" + an
"Open in Google Maps" link (a plain URL, no API).
"""
import gzip
import hashlib
import hmac
import json
import math
import statistics
import sys
import threading
import urllib.parse
import urllib.request
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from django.conf import settings
from django.db import transaction
from django.utils import timezone

from .citytransit import engine as E
from .citytransit import fares as F

ATTRIBUTION = "© OpenStreetMap contributors (ODbL)"
COPYRIGHT_URL = "https://www.openstreetmap.org/copyright"
DEFAULT_BASE = "https://github.com/ArifSarkar247/assisto/releases/download/transit-data/"
DHAKA_TZ = ZoneInfo("Asia/Dhaka")
# cities we plan to cover; a city without an imported dataset gets the
# honest "no data yet" answer (+ Google Maps link)
CITIES = {
    "dhaka": {"bbox": [23.58, 90.18, 24.06, 90.62], "name": "Dhaka", "name_bn": "ঢাকা"},
    "chattogram": {"bbox": [22.20, 91.70, 22.45, 91.95], "name": "Chattogram", "name_bn": "চট্টগ্রাম"},
}
LIVE_KINDS = ("jam", "road_closed", "waterlogging", "bus_not_coming", "bus_crowded", "seats_free")
LIVE_TTL_MIN = 60
LIVE_MERGE_M = 300
LIVE_PER_HOUR = 20
LIVE_FLAGS_HIDE = 3
FIX_PER_DAY = 30
FARE_MODES = ("rickshaw", "leguna", "bus", "cng", "water")
FARE_MIN_REPORTS = 10
NIGHT_MIN = 3
TRIP_CONFIRM = 3            # distinct contributors before a finding is "confirmed"
TRIP_KEEP_DAYS = 7
TRIP_TRIM_M = 300
CHECK_EVERY_S = 6 * 3600
MAX_FILE = 30 * 1024 * 1024
_UA = "AssistoCityImport/1.0 (+https://lifeassisto.com)"

_lock = threading.Lock()
_NET = {}        # city -> (token, Network, raw net dict)
_PKG = {}        # city -> (token, gz bytes)
_DIR = {}        # city -> (version, items)


def data_base():
    return getattr(settings, "CITY_DATA_BASE", "") or DEFAULT_BASE


# ------------------------------------------------------------------ data
def _ds(city):
    from .models import CityDataset
    return CityDataset.objects.filter(city=city, enabled=True).exclude(version="").only(
        "id", "city", "version", "ov_version", "enabled", "report", "counts").first()


def token(ds):
    return "%s.%d" % (ds.version, ds.ov_version)


def network(city):
    """(Network, raw net, dataset) for a city with imported data, else None."""
    ds = _ds(city)
    if ds is None:
        return None
    tok = token(ds)
    hit = _NET.get(city)
    if hit and hit[0] == tok:
        return hit[1], hit[2], ds
    from .models import CityDataset
    full = CityDataset.objects.get(pk=ds.pk)
    raw = json.loads(gzip.decompress(bytes(full.blob)).decode("utf-8"))
    nw = E.Network(raw, full.overrides or {})
    with _lock:
        _NET[city] = (tok, nw, raw)
    return nw, raw, ds


def city_at(lat, lon):
    for key, c in CITIES.items():
        b = c["bbox"]
        if b[0] <= lat <= b[2] and b[1] <= lon <= b[3]:
            return key
    return None


def google_maps(olat=None, olon=None, dlat=None, dlon=None):
    q = {"api": "1", "travelmode": "transit"}
    if olat is not None:
        q["origin"] = "%.6f,%.6f" % (olat, olon)
    if dlat is not None:
        q["destination"] = "%.6f,%.6f" % (dlat, dlon)
    return "https://www.google.com/maps/dir/?" + urllib.parse.urlencode(q)


def where(lat, lon):
    city = city_at(lat, lon)
    out = {"city": city, "has_data": False, "name": "", "name_bn": "", "counts": {},
           "coverage_pct": None, "google_maps": google_maps(lat, lon),
           "attribution": ATTRIBUTION}
    if city:
        out["name"], out["name_bn"] = CITIES[city]["name"], CITIES[city]["name_bn"]
        ds = _ds(city)
        if ds is not None:
            out["has_data"] = True
            out["counts"] = ds.counts or {}
            out["coverage_pct"] = (ds.counts or {}).get("coverage_pct")
            out["data_version"] = token(ds)
    return out


def local_minute(at=""):
    if at:
        try:
            h, m = [int(x) for x in str(at).split(":")[:2]]
            if 0 <= h < 24 and 0 <= m < 60:
                return h * 60 + m
        except ValueError:
            pass
    now = timezone.now().astimezone(DHAKA_TZ)
    return now.hour * 60 + now.minute


def complaint(ov=None):
    """Overcharge complaint line. Until the owner enters a BRTA number that
    an official BRTA page confirms, the line is the government's national
    helpline 333 and is labelled as that — never as a BRTA number."""
    c = dict(F.BRTA_COMPLAINT)
    c.update((ov or {}).get("complaint") or {})
    if c.get("number"):
        c.update({"kind": "brta", "dial": c["number"], "label_en": "BRTA complaint line",
                  "label_bn": "বিআরটিএ অভিযোগ নম্বর"})
    else:
        c.update({"kind": "national_helpline", "dial": c.get("fallback") or "333",
                  "label_en": c.get("fallback_en"), "label_bn": c.get("fallback_bn")})
    return c


def plan(olat, olon, dlat, dlon, at="", modes=None):
    city = city_at(olat, olon)
    if city is None or city != city_at(dlat, dlon):
        return {"ok": False, "reason": "no_data", "city": city,
                "google_maps": google_maps(olat, olon, dlat, dlon)}
    got = network(city)
    if got is None:
        return {"ok": False, "reason": "no_data", "city": city,
                "google_maps": google_maps(olat, olon, dlat, dlon)}
    nw, raw, ds = got
    allowed = set(E.MODES) | {"rickshaw", "women"}
    mset = [m for m in (modes or []) if m in allowed] or None
    if mset == ["women"]:             # women-only buses on top of the usual modes
        mset = list(E.MODES) + ["rickshaw", "women"]
    ans = nw.plan(olat, olon, dlat, dlon, minute=local_minute(at), modes=mset)
    ans.update({"city": city, "attribution": ATTRIBUTION, "copyright_url": COPYRIGHT_URL,
                "data_version": token(ds), "complaint": complaint(_overrides(ds)),
                "google_maps": google_maps(olat, olon, dlat, dlon)})
    if not ans["ok"]:
        ans["reason"] = "no_route"
    return ans


def _overrides(ds):
    from .models import CityDataset
    return CityDataset.objects.filter(pk=ds.pk).values_list("overrides", flat=True).first() or {}


def package(city, have=""):
    """Offline package for the phone: gzip bytes, or None when `have` is current."""
    got = network(city)
    if got is None:
        return None, None
    nw, raw, ds = got
    tok = token(ds)
    if have and have == tok:
        return tok, b""
    hit = _PKG.get(city)
    if hit and hit[0] == tok:
        return tok, hit[1]
    ov = _overrides(ds)
    doc = {"v": tok, "city": city, "net": raw, "overrides": ov,
           "rates": F.rates(ov.get("rates")), "complaint": complaint(ov),
           "attribution": ATTRIBUTION, "copyright_url": COPYRIGHT_URL}
    gz = gzip.compress(json.dumps(doc, ensure_ascii=False, separators=(",", ":")).encode(), 6)
    with _lock:
        _PKG[city] = (tok, gz)
    return tok, gz


def stations(city):
    got = network(city)
    return got[0].stations() if got else None


def station(city, stop_id, lat=None, lon=None):
    got = network(city)
    if got is None:
        return None
    nw, raw, ds = got
    g = nw.station_guide(stop_id, lat, lon)
    if g is None:
        return None
    m = raw.get("metro") or {}
    g["service"] = m.get("service") or {}
    g["recharge"] = m.get("recharge") or {}
    g["line"] = m.get("line") or {}
    g["facilities"] = m.get("facilities") or {}
    g["attribution"] = ATTRIBUTION
    return g


def metro_info(city="dhaka"):
    got = network(city)
    if got is None:
        return None
    nw, raw, ds = got
    m = raw.get("metro") or {}
    r = nw.rates["metro"]
    return {"line": m.get("line") or {}, "service": m.get("service") or {},
            "recharge": m.get("recharge") or {}, "facilities": m.get("facilities") or {},
            "stations": nw.stations(),
            "fare": {"per_km": r["per_km"], "min": r["min"], "max": r["max"],
                     "card_discount_pct": r.get("card_discount_pct", 0), "label": r["label"],
                     "checked": r.get("checked"), "source": r.get("source"),
                     "source_url": r.get("source_url"),
                     "chart": [{"a": a, "b": b, "tk": tk} for (a, b), tk in F.METRO_CHART.items()]}}


# Women (owner item 7). Facts with sources + checked date; the owner can
# edit / add in overrides["women"] (e.g. BRTC women-only routes once a
# public list is confirmed — none was found on 9 Nov, see CITY_DATA_GAPS_BN.md).
WOMEN = {
    "metro_women_coach": {
        "text": "One of the six coaches of every MRT Line 6 train is for women only (women may "
                "also ride any coach). Look for the pink signs on the platform.",
        "text_bn": "এমআরটি লাইন ৬-এর প্রতিটি ট্রেনের ছয়টি কোচের একটি শুধু নারীদের জন্য (নারীরা অন্য "
                   "যেকোনো কোচেও উঠতে পারেন)। প্ল্যাটফর্মের চিহ্ন দেখে দাঁড়ান।",
        "status": "verified", "checked": "2026-11-09",
        "source_url": "https://old.thefinancialexpress.com.bd/national/one-coach-to-be-reserved-for-women-on-metro-rail-1672048558",
        "sources": ["https://old.thefinancialexpress.com.bd/national/one-coach-to-be-reserved-for-women-on-metro-rail-1672048558",
                    "https://www.dhakatribune.com/bangladesh/329062/metro-rail-eases-travel-for-women-with-reserved"]},
    "reserved_seats": {
        "text": "City buses keep the marked front seats for women, children and people with "
                "disabilities. If someone refuses, the conductor must help.",
        "text_bn": "শহরের বাসে সামনের চিহ্নিত আসনগুলো নারী, শিশু ও প্রতিবন্ধীদের জন্য সংরক্ষিত। কেউ না "
                   "ছাড়লে কন্ডাক্টরকে বলুন।",
        "status": "reported", "checked": "2026-11-09", "source_url": "", "sources": []},
}


def women(city):
    got = network(city)
    if got is None:
        return None
    nw, raw, ds = got
    ov = _overrides(ds)
    w = {k: dict(v) for k, v in WOMEN.items()}
    for k, v in ((ov.get("women") or {}).items()):
        if k in w and isinstance(v, dict):
            w[k].update(v)
    buses = []
    for r in nw.routes:
        if r.get("women_only") and not r["hidden"]:
            buses.append({"route_id": r["id"], "route": r.get("name"), "route_bn": r.get("name_bn"),
                          "company": r.get("op", ""), "from": r.get("from", ""), "to": r.get("to", ""),
                          "hours": r.get("hours", ""), "status": E.STATUS.get(r.get("st"), "reported"),
                          "sources": r.get("src") or []})
    for b in (ov.get("women") or {}).get("buses") or []:
        if isinstance(b, dict):
            buses.append(dict(b, status=b.get("status", "reported")))
    night = []
    from django.db.models import Count, Avg
    from .models import CityNightRating
    for row in (CityNightRating.objects.filter(city=city).values("route_id")
                .annotate(n=Count("id"), avg=Avg("stars")).order_by("-n")[:200]):
        if row["n"] >= NIGHT_MIN:
            night.append({"route_id": row["route_id"], "stars": round(row["avg"], 1), "count": row["n"]})
    return {"women_buses": buses, "reserved_seats": w["reserved_seats"],
            "metro_women_coach": w["metro_women_coach"], "night": night}


def route_detail(city, route_id):
    got = network(city)
    if got is None:
        return None
    nw = got[0]
    for r in nw.routes:
        if r["id"] == route_id and not r["hidden"]:
            return {"id": r["id"], "mode": r["mode"], "name": r.get("name"), "name_bn": r.get("name_bn"),
                    "ref": r.get("ref"), "operator": r.get("op", ""), "status": E.STATUS.get(r.get("st"), "reported"),
                    "sources": r.get("src") or [], "headway_min": r["hw"],
                    "counters": r.get("counters") or [], "women_only": bool(r.get("women_only")),
                    "stops": [nw._pt(i) for i in r["stops"]], "km": r["km"][-1] if r["km"] else 0}
    return None


def search(city, q, limit=20):
    got = network(city)
    if got is None:
        return None
    nw = got[0]
    q = (q or "").strip().lower()[:60]
    if len(q) < 2:
        return {"stops": [], "routes": []}
    stops, seen = [], set()
    for i, s in enumerate(nw.stops):
        if s["hidden"] or not nw.stop_routes[i]:
            continue
        if q in (s["name"] or "").lower() or q in (s["name_bn"] or ""):
            key = (s["name"], round(s["lat"], 3), round(s["lon"], 3))
            if key in seen:
                continue
            seen.add(key)
            p = nw._pt(i)
            p["kind"] = s["kind"]
            p["routes"] = sorted({nw.routes[ri].get("name") or nw.routes[ri].get("ref") or ""
                                  for ri, _ in nw.stop_routes[i]})[:8]
            stops.append(p)
            if len(stops) >= limit:
                break
    routes, rseen = [], set()
    for r in nw.routes:
        if r["hidden"]:
            continue
        hay = " ".join([r.get("name") or "", r.get("ref") or "", r.get("op") or ""]).lower()
        if q in hay or q in (r.get("name_bn") or ""):
            k = (r.get("name"), r.get("ref"))
            if k in rseen:
                continue
            rseen.add(k)
            routes.append({"id": r["id"], "mode": r["mode"], "name": r.get("name"),
                           "name_bn": r.get("name_bn"), "ref": r.get("ref"),
                           "from": r.get("from", ""), "to": r.get("to", ""),
                           "status": E.STATUS.get(r.get("st"), "reported")})
            if len(routes) >= limit:
                break
    return {"stops": stops, "routes": routes}


def stops_near(city, lat, lon, radius=600):
    got = network(city)
    if got is None:
        return None
    nw = got[0]
    out = []
    for i, d in nw.near(lat, lon, radius)[:15]:
        p = nw._pt(i)
        p["kind"] = nw.stops[i]["kind"]
        p["meters"] = int(d)
        p["routes"] = sorted({nw.routes[ri].get("name") or nw.routes[ri].get("ref") or ""
                              for ri, _ in nw.stop_routes[i]})[:10]
        out.append(p)
    return out


def directory(city, kind=None):
    from .models import CityDataset
    ds = CityDataset.objects.filter(city=city, enabled=True).only("id", "version").first()
    if ds is None:
        return None
    hit = _DIR.get(city)
    if not hit or hit[0] != ds.version:
        full = CityDataset.objects.filter(pk=ds.pk).values_list("dir_blob", flat=True).first()
        items = []
        if full:
            items = json.loads(gzip.decompress(bytes(full)).decode("utf-8")).get("items") or []
        hit = (ds.version, items)
        _DIR[city] = hit
    items = hit[1]
    if kind:
        items = [i for i in items if i.get("kind") == kind]
    out = []
    for i in items:
        i = dict(i, status={"v": "verified"}.get(i.get("status"), "reported"))
        if i.get("routes") and len(i.get("routes_bn") or []) != len(i["routes"]):
            i["routes_bn"] = list(i["routes"])     # same length always (cityapp contract)
        out.append(i)
    return out


# ------------------------------------------------------------------ import
def _fetch(url, limit=MAX_FILE, timeout=30):
    if sys.argv[1:2] == ["test"]:
        raise OSError("no network in tests")
    req = urllib.request.Request(url, headers={"User-Agent": _UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = r.read(limit + 1)
    if len(data) > limit:
        raise ValueError("file too large")
    return data


def import_city(city, blob, dir_blob=b"", report=None, sha=""):
    from .models import CityDataset
    if city not in CITIES:
        raise ValueError("unknown city")
    got = hashlib.sha256(blob).hexdigest()
    if sha and sha != got:
        raise ValueError("sha256 mismatch")
    net = json.loads(gzip.decompress(blob).decode("utf-8"))
    if net.get("fmt") != 1 or net.get("city") != city:
        raise ValueError("bad network file")
    E.Network(net)          # must load
    rows = len(net["stops"]["rows"])
    ds, _ = CityDataset.objects.get_or_create(city=city)
    old = (ds.counts or {}).get("stops") or 0
    if old and rows < old * 0.5:
        raise ValueError("refusing a file with %d stops (now %d)" % (rows, old))
    ds.blob = blob
    ds.dir_blob = dir_blob or b""
    ds.sha256 = got
    ds.version = str(net.get("version") or got[:12])[:40]
    ds.counts = net.get("counts") or {"stops": rows, "routes": len(net["routes"])}
    rep = dict(report or {})
    rep["bbox"] = net.get("bbox")
    ds.report = rep
    ds.imported_at = timezone.now()
    ds.last_error = ""
    ds.save()
    return {"city": city, "version": ds.version, "stops": rows, "routes": len(net["routes"])}


def _meta():
    from .models import CityDataset
    ds, _ = CityDataset.objects.get_or_create(city="_meta", defaults={"enabled": False})
    return ds


def import_tick(force=False, now=None):
    from .models import CityDataset
    now = now or timezone.now()
    meta = _meta()
    if not force and meta.last_check_at and (now - meta.last_check_at).total_seconds() < CHECK_EVERY_S:
        return "idle"
    try:
        man = json.loads(_fetch(data_base() + "manifest.json", limit=2 * 1024 * 1024).decode("utf-8"))
    except Exception as e:
        CityDataset.objects.filter(pk=meta.pk).update(last_check_at=now, last_error=("manifest: %s" % e)[:300])
        return "manifest_error"
    files = man.get("files") or {}
    for city in CITIES:
        f = files.get("transit_%s.json.gz" % city)
        if not f:
            continue
        ds = CityDataset.objects.filter(city=city).only("sha256").first()
        if ds and ds.sha256 == f.get("sha256"):
            continue
        try:
            blob = _fetch(data_base() + "transit_%s.json.gz" % city)
            dblob = b""
            d = files.get("directory_%s.json.gz" % city)
            if d:
                dblob = _fetch(data_base() + "directory_%s.json.gz" % city)
            rep = {}
            try:
                rep = json.loads(_fetch(data_base() + "report_%s.json" % city, limit=4 * 1024 * 1024))
            except Exception:
                pass
            res = import_city(city, blob, dblob, rep, f.get("sha256", ""))
        except Exception as e:
            CityDataset.objects.update_or_create(city=city, defaults={"last_error": str(e)[:300]})
            return "error %s" % city
        CityDataset.objects.filter(pk=meta.pk).update(last_check_at=now, last_error="")
        return "imported %s" % json.dumps(res)
    CityDataset.objects.filter(pk=meta.pk).update(last_check_at=now, last_error="")
    return "up_to_date"


# ------------------------------------------------------------------ overrides
def bump(ds_or_city, mutate):
    """Apply `mutate(overrides)` under a row lock and bump ov_version."""
    from .models import CityDataset
    city = ds_or_city if isinstance(ds_or_city, str) else ds_or_city.city
    with transaction.atomic():
        ds = CityDataset.objects.select_for_update().get(city=city)
        ov = dict(ds.overrides or {})
        changed = mutate(ov)
        if changed is False:
            return ds
        ds.overrides = ov
        ds.ov_version += 1
        ds.save(update_fields=["overrides", "ov_version"])
    _NET.pop(city, None)
    _PKG.pop(city, None)
    return ds


PATCH_ACTIONS = ("hide_stop", "show_stop", "hide_route", "show_route", "edit_stop", "edit_route",
                 "verify_stop", "verify_route", "add_gate", "rate", "complaint")


def apply_patch(city, patch):
    """Owner-approved change -> overrides. Returns '' or an error word."""
    act = (patch or {}).get("action")
    if act not in PATCH_ACTIONS:
        return "invalid"
    tid = str(patch.get("id") or "")[:80]

    def mut(ov):
        if act in ("hide_stop", "show_stop"):
            s = set(ov.get("hide_stops") or [])
            (s.add if act == "hide_stop" else s.discard)(tid)
            ov["hide_stops"] = sorted(s)
        elif act in ("hide_route", "show_route"):
            s = set(ov.get("hide_routes") or [])
            (s.add if act == "hide_route" else s.discard)(tid)
            ov["hide_routes"] = sorted(s)
        elif act in ("edit_stop", "verify_stop"):
            e = dict((ov.get("stops") or {}).get(tid) or {})
            if act == "verify_stop":
                e["st"] = "v"
            for k in ("name", "name_bn"):
                if patch.get(k):
                    e[k] = str(patch[k])[:120]
            for k in ("lat", "lon"):
                if patch.get(k) not in (None, ""):
                    e[k] = float(patch[k])
            ov.setdefault("stops", {})[tid] = e
        elif act in ("edit_route", "verify_route"):
            e = dict((ov.get("routes") or {}).get(tid) or {})
            if act == "verify_route":
                e["st"] = "v"
            for k in ("name", "name_bn"):
                if patch.get(k):
                    e[k] = str(patch[k])[:120]
            for k in ("hw", "spd"):
                if patch.get(k) not in (None, ""):
                    e[k] = float(patch[k])
            ov.setdefault("routes", {})[tid] = e
        elif act == "add_gate":
            g = {k: patch.get(k) for k in ("ref", "name", "name_bn", "side", "near", "lift",
                                           "escalator")}
            g.update({"lat": float(patch["lat"]), "lon": float(patch["lon"]),
                      "status": "verified", "station_id": tid})
            ov.setdefault("gates_src", []).append(g)
        elif act == "rate":
            mode = str(patch.get("mode") or "")
            if mode not in F.RATES:
                raise ValueError("mode")
            vals = {k: float(v) for k, v in (patch.get("values") or {}).items()
                    if k in F.RATES[mode] and isinstance(v, (int, float, str)) and str(v) != ""}
            vals["checked"] = str(patch.get("checked") or timezone.localdate())
            ov.setdefault("rates", {}).setdefault(mode, {}).update(vals)
        elif act == "complaint":
            ov["complaint"] = {"number": str(patch.get("number") or "")[:20],
                               "verified": bool(patch.get("number")),
                               "checked": str(timezone.localdate())}
        return True

    try:
        bump(city, mut)
    except (ValueError, TypeError, KeyError):
        return "invalid"
    _resolve_gate_stations(city)
    return ""


def _resolve_gate_stations(city):
    """Owner gate facts are stored by station id; the engine wants indices."""
    got = network(city)
    if got is None:
        return
    nw = got[0]

    def mut(ov):
        src = ov.get("gates_src") or []
        new = []
        for g in src:
            si = nw.by_id.get(g.get("station_id"))
            if si is not None:
                new.append(dict(g, st=si))
        if new == (ov.get("gates") or []):
            return False
        ov["gates"] = new
        return True

    bump(city, mut)


# ------------------------------------------------------------------ users
def correction(user, city, d):
    from .models import CityCorrection
    since = timezone.now() - timedelta(days=1)
    if user and CityCorrection.objects.filter(user=user, created_at__gte=since).count() >= FIX_PER_DAY:
        return None, "limit"
    target = str(d.get("target") or "other")
    if target not in CityCorrection.TARGETS:
        target = "other"
    text = str(d.get("text") or "").strip()[:500]
    kind = str(d.get("kind") or "").strip()[:24]
    if not text and not kind:
        return None, "empty"
    lat = lon = None
    try:
        if d.get("lat") not in (None, "") and d.get("lon") not in (None, ""):
            lat, lon = float(d["lat"]), float(d["lon"])
            if not (-90 <= lat <= 90 and -180 <= lon <= 180):
                lat = lon = None
    except (TypeError, ValueError):
        lat = lon = None
    c = CityCorrection.objects.create(city=city if city in CITIES else "dhaka", user=user,
                                      target=target, target_id=str(d.get("target_id") or "")[:80],
                                      kind=kind, text=text, lat=lat, lon=lon)
    return c, ""


def resolve_correction(c, action, patch=None):
    if action == "reject":
        c.status = "rejected"
    elif action == "accept":
        if patch:
            err = apply_patch(c.city, patch)
            if err:
                return err
            c.patch = patch
        c.status = "accepted"
    else:
        return "invalid"
    c.resolved_at = timezone.now()
    c.save(update_fields=["status", "patch", "resolved_at"])
    return ""


def _box(lat, lon, m):
    dlat = m / 111000.0
    dlon = m / (111000.0 * max(0.2, math.cos(math.radians(lat))))
    return lat - dlat, lat + dlat, lon - dlon, lon + dlon


def live_report(user, kind, lat, lon, route_id=""):
    from .models import CityLiveReport
    if kind not in LIVE_KINDS:
        return None, "kind"
    city = city_at(lat, lon) or "other"
    now = timezone.now()
    uid = user.pk if user else 0
    if uid:
        from django.core.cache import cache
        ck = "citylive:%d:%s" % (uid, now.strftime("%Y%m%d%H"))
        n = cache.get(ck, 0)
        if n >= LIVE_PER_HOUR:
            return None, "limit"
        cache.set(ck, n + 1, 3700)
    a, b, c, d = _box(lat, lon, LIVE_MERGE_M)
    with transaction.atomic():
        qs = (CityLiveReport.objects.select_for_update()
              .filter(kind=kind, hidden=False, expires_at__gt=now, lat__gte=a, lat__lte=b,
                      lon__gte=c, lon__lte=d, route_id=str(route_id or "")[:80]))
        for r in qs:
            if E.hav(lat, lon, r.lat, r.lon) <= LIVE_MERGE_M:
                if uid and uid in (r.voters or []):
                    return r, ""
                r.count += 1
                r.voters = list(r.voters or []) + ([uid] if uid else [])
                r.last_at = now
                r.expires_at = now + timedelta(minutes=LIVE_TTL_MIN)
                r.save(update_fields=["count", "voters", "last_at", "expires_at"])
                return r, ""
        r = CityLiveReport.objects.create(city=city, kind=kind, lat=lat, lon=lon,
                                          route_id=str(route_id or "")[:80], user=user,
                                          voters=[uid] if uid else [], created_at=now, last_at=now,
                                          expires_at=now + timedelta(minutes=LIVE_TTL_MIN))
    return r, ""


def live_list(lat, lon, km=3.0, now=None):
    from .models import CityLiveReport
    now = now or timezone.now()
    a, b, c, d = _box(lat, lon, km * 1000)
    out = []
    for r in CityLiveReport.objects.filter(hidden=False, expires_at__gt=now, lat__gte=a, lat__lte=b,
                                           lon__gte=c, lon__lte=d).order_by("-last_at")[:200]:
        out.append({"id": r.id, "kind": r.kind, "lat": r.lat, "lon": r.lon, "count": r.count,
                    "route_id": r.route_id,
                    "minutes_ago": int((now - r.last_at).total_seconds() // 60),
                    "expires_in_min": max(0, int((r.expires_at - now).total_seconds() // 60))})
    return out


def live_flag(user, rid):
    from .models import CityLiveReport
    with transaction.atomic():
        r = CityLiveReport.objects.select_for_update().filter(pk=rid).first()
        if r is None:
            return None
        tag = "f%d" % (user.pk if user else 0)
        if tag in (r.voters or []):
            return r
        r.voters = list(r.voters or []) + [tag]
        r.flags += 1
        if r.flags >= LIVE_FLAGS_HIDE:
            r.hidden = True
        r.save(update_fields=["voters", "flags", "hidden"])
    return r


def fare_report(user, city, mode, km, paid):
    from .models import CityFareReport
    if mode not in FARE_MODES:
        return None, "mode"
    try:
        km, paid = float(km), int(paid)
    except (TypeError, ValueError):
        return None, "invalid"
    if not (0.2 <= km <= 60) or not (5 <= paid <= 5000):
        return None, "invalid"
    since = timezone.now() - timedelta(days=1)
    if user and CityFareReport.objects.filter(user=user, created_at__gte=since).count() >= 20:
        return None, "limit"
    return CityFareReport.objects.create(city=city if city in CITIES else "dhaka", mode=mode,
                                         km=km, paid=paid, user=user), ""


def night_rating(user, city, route_id, stars):
    from .models import CityNightRating
    try:
        stars = int(stars)
    except (TypeError, ValueError):
        return None, "invalid"
    if not (1 <= stars <= 5) or not route_id:
        return None, "invalid"
    r, _ = CityNightRating.objects.update_or_create(
        route_id=str(route_id)[:80], user=user,
        defaults={"stars": stars, "city": city if city in CITIES else "dhaka",
                  "created_at": timezone.now()})
    return r, ""


def _q(vals, p):
    vals = sorted(vals)
    k = (len(vals) - 1) * p
    lo = int(math.floor(k))
    hi = min(len(vals) - 1, lo + 1)
    return vals[lo] + (vals[hi] - vals[lo]) * (k - lo)


def aggregate(city, now=None):
    """Crowd fares (rickshaw / leguna -> 'Reported by users') + night
    ratings -> overrides. Bumps only when something changed."""
    from .models import CityFareReport, CityNightRating
    now = now or timezone.now()
    since = now - timedelta(days=90)
    rates = {}
    for mode in ("rickshaw", "leguna"):
        rows = list(CityFareReport.objects.filter(city=city, mode=mode, created_at__gte=since)
                    .values_list("km", "paid")[:5000])
        if len(rows) < FARE_MIN_REPORTS:
            continue
        per_km = [p / k for k, p in rows if k >= 1.2]
        short = [p for k, p in rows if k < 1.2]
        if len(per_km) < 5 or len(short) < 3:
            continue
        rates[mode] = {"label": "reported", "per_km_low": round(_q(per_km, 0.25), 1),
                       "per_km_high": round(_q(per_km, 0.75), 1),
                       "min_low": int(_q(short, 0.25)), "min_high": int(_q(short, 0.75)),
                       "checked": str(timezone.localdate()),
                       "source": "Reported by users (%d reports, last 90 days)" % len(rows), "n": len(rows)}
    night = {}
    agg = {}
    for rid, stars in CityNightRating.objects.filter(city=city).values_list("route_id", "stars")[:20000]:
        agg.setdefault(rid, []).append(stars)
    for rid, v in agg.items():
        if len(v) >= NIGHT_MIN:
            night[rid] = round(statistics.mean(v), 2)

    def mut(ov):
        cur = ov.get("rates") or {}
        new_rates = {k: v for k, v in cur.items() if (v or {}).get("label") != "reported"}
        new_rates.update(rates)
        if new_rates == cur and night == (ov.get("night") or {}):
            return False
        ov["rates"] = new_rates
        ov["night"] = night
        return True

    from .models import CityDataset
    if CityDataset.objects.filter(city=city).exists():
        bump(city, mut)


# ------------------------------------------------------------------ trips
def consent(user, on=None):
    from .models import CityTripConsent
    c, _ = CityTripConsent.objects.get_or_create(user=user)
    if on is not None and bool(on) != c.on:
        c.on = bool(on)
        c.changed_at = timezone.now()
        c.save(update_fields=["on", "changed_at"])
    return c.on


def anon_key(user):
    return hmac.new(settings.SECRET_KEY.encode(), ("citytrip:%s" % user.pk).encode(),
                    hashlib.sha256).hexdigest()[:20]


def _trim(points, m=TRIP_TRIM_M):
    """Cut the first and last `m` metres (home / work stay private)."""
    if len(points) < 3:
        return []
    a, z = points[0], points[-1]
    i = 0
    while i < len(points) and E.hav(a[1], a[2], points[i][1], points[i][2]) < m:
        i += 1
    j = len(points) - 1
    while j >= i and E.hav(z[1], z[2], points[j][1], points[j][2]) < m:
        j -= 1
    return points[i:j + 1]


def submit_trip(user, mode, points):
    from .models import CityTrip, CityTripConsent
    if not CityTripConsent.objects.filter(user=user, on=True).exists():
        return None, "no_consent"
    if mode not in ("bus", "leguna", "water"):
        return None, "mode"
    clean = []
    try:
        for p in (points or [])[:4000]:
            t, lat, lon = float(p[0]), float(p[1]), float(p[2])
            if clean and t <= clean[-1][0]:
                continue
            clean.append([int(t), round(lat, 6), round(lon, 6)])
    except (TypeError, ValueError, IndexError):
        return None, "invalid"
    if len(clean) < 10:
        return None, "too_short"
    city = city_at(clean[0][1], clean[0][2])
    if city is None:
        return None, "no_city"
    clean = _trim(clean)
    if len(clean) < 5:
        return None, "too_short"
    since = timezone.now() - timedelta(days=1)
    anon = anon_key(user)
    if CityTrip.objects.filter(anon=anon, created_at__gte=since).count() >= 30:
        return None, "limit"
    return CityTrip.objects.create(city=city, anon=anon, mode=mode, points=clean), ""


def _dwells(points, slow=1.5, min_s=20):
    """Clusters where the vehicle stood still >= min_s (stops, jams)."""
    out, start = [], None
    for k in range(1, len(points)):
        t0, a0, b0 = points[k - 1]
        t1, a1, b1 = points[k]
        dt = max(1, t1 - t0)
        v = E.hav(a0, b0, a1, b1) / dt
        if v < slow:
            if start is None:
                start = k - 1
        else:
            if start is not None and points[k - 1][0] - points[start][0] >= min_s:
                seg = points[start:k]
                out.append((seg[0][0], seg[-1][0], sum(p[1] for p in seg) / len(seg),
                            sum(p[2] for p in seg) / len(seg)))
            start = None
    return out


def _learn(city, kind, key, anon, data_fn):
    from .models import CityLearned
    obj, _ = CityLearned.objects.get_or_create(city=city, kind=kind, key=key[:120])
    obj.data = data_fn(dict(obj.data or {}))
    obj.trips += 1
    an = list(obj.anons or [])
    if anon not in an and len(an) < 50:
        an.append(anon)
    obj.anons = an
    if obj.status == "reported" and len(an) >= TRIP_CONFIRM:
        obj.status = "confirmed"
    obj.updated_at = timezone.now()
    obj.save()
    return obj


def process_trip(trip):
    """Stops (dwell clusters), stop-to-stop times by hour, new routes."""
    got = network(trip.city)
    pts = trip.points or []
    dw = _dwells(pts)
    seq = []          # (stop_id or new key, t_arrive, t_leave)
    for t0, t1, lat, lon in dw:
        sid = None
        if got:
            near = got[0].near(lat, lon, 60)
            if near:
                sid = got[0].stops[near[0][0]]["id"]
        if sid is None:
            key = "new:%.4f:%.4f" % (round(lat / 0.0006) * 0.0006, round(lon / 0.0006) * 0.0006)
            _learn(trip.city, "stop", key, trip.anon,
                   lambda d, lat=lat, lon=lon: dict(d, lat=lat, lon=lon,
                                                    seen=int(d.get("seen", 0)) + 1))
            sid = key
        if not seq or seq[-1][0] != sid:
            seq.append([sid, t0, t1])
        else:
            seq[-1][2] = t1
    for a, b in zip(seq, seq[1:]):
        if a[0].startswith("new:") or b[0].startswith("new:"):
            continue
        dur = b[1] - a[2]
        if not (20 <= dur <= 3 * 3600):
            continue
        hour = datetime.fromtimestamp(a[2], DHAKA_TZ).hour

        def seg(d, dur=dur, hour=hour):
            h = d.setdefault(str(hour), [])
            h.append(dur)
            d[str(hour)] = h[-50:]
            return d
        _learn(trip.city, "segment", "%s>%s" % (a[0], b[0]), trip.anon, seg)
    known = [s[0] for s in seq if not s[0].startswith("new:")]
    if len(known) >= 4 and got and not _covered(got[0], known):
        key = "route:" + hashlib.sha1("|".join(known).encode()).hexdigest()[:16]
        _learn(trip.city, "route", key, trip.anon,
               lambda d, known=known, mode=trip.mode: dict(d, stop_ids=known, mode=mode))
    trip.points = []
    trip.processed = True
    trip.save(update_fields=["points", "processed"])
    return len(seq)


def _covered(nw, ids):
    """True when an existing route visits these stops in this order."""
    idx = [nw.by_id.get(i) for i in ids]
    if None in idx:
        return False
    for r in nw.routes:
        pos = {si: k for k, si in enumerate(r["stops"])}
        ks = [pos.get(si) for si in idx]
        if None not in ks and all(ks[i] < ks[i + 1] for i in range(len(ks) - 1)):
            return True
    return False


def learned_to_overrides(city):
    """Confirmed findings -> network: new routes (Reported by users, source
    'trips') and per-route speeds by hour from real trips."""
    from .models import CityLearned
    got = network(city)
    if got is None:
        return
    nw = got[0]
    add_routes = []
    for l in CityLearned.objects.filter(city=city, kind="route", status="confirmed")[:500]:
        ids = (l.data or {}).get("stop_ids") or []
        if len(ids) >= 2:
            add_routes.append({"id": "trip-" + l.key[6:], "mode": (l.data or {}).get("mode", "bus"),
                               "name": "", "name_bn": "", "ref": "", "st": "r",
                               "src": [{"s": "trips", "n": len(l.anons or [])}], "stop_ids": ids})
    seg_time = {}
    for l in CityLearned.objects.filter(city=city, kind="segment", status="confirmed")[:20000]:
        a, _, b = l.key.partition(">")
        seg_time[(a, b)] = {int(h): statistics.median(v) for h, v in (l.data or {}).items() if v}
    speeds = {}
    for r in nw.routes:
        if r["mode"] == "metro":
            continue
        per_hour = {}
        for k in range(len(r["stops"]) - 1):
            a, b = nw.stops[r["stops"][k]]["id"], nw.stops[r["stops"][k + 1]]["id"]
            st = seg_time.get((a, b))
            if not st:
                continue
            km = r["km"][k + 1] - r["km"][k]
            for h, sec in st.items():
                if sec > 0 and km > 0:
                    per_hour.setdefault(h, []).append(km / (sec / 3600.0))
        if per_hour:
            speeds[r["id"]] = {str(h): round(statistics.median(v), 1) for h, v in per_hour.items()}

    def mut(ov):
        if ov.get("add_routes_learned") == add_routes and ov.get("route_speed") == speeds:
            return False
        manual = [r for r in (ov.get("add_routes") or []) if not str(r.get("id", "")).startswith("trip-")]
        ov["add_routes"] = manual + add_routes
        ov["add_routes_learned"] = add_routes
        ov["route_speed"] = speeds
        return True

    bump(city, mut)


def learn_tick(limit=200, now=None):
    from .models import CityTrip
    now = now or timezone.now()
    n = 0
    for t in CityTrip.objects.filter(processed=False).order_by("id")[:limit]:
        try:
            process_trip(t)
        except Exception:
            CityTrip.objects.filter(pk=t.pk).update(processed=True, points=[])
        n += 1
    CityTrip.objects.filter(created_at__lt=now - timedelta(days=TRIP_KEEP_DAYS)).delete()
    return n


def tick(force=False, now=None):
    """minute_jobs step. Idle minutes = two small reads."""
    from . import ops_health as H
    from .models import CityLiveReport
    now = now or timezone.now()
    out = [import_tick(force=force, now=now)]
    last = H.stamp_get("city_hourly")
    if force or last is None or (now - last).total_seconds() >= 3600:
        H.stamp_set("city_hourly", now)
        n = learn_tick(now=now)
        for city in CITIES:
            if _ds(city) is not None:
                aggregate(city, now=now)
                learned_to_overrides(city)
        CityLiveReport.objects.filter(expires_at__lt=now - timedelta(days=1)).delete()
        out.append("hourly trips=%d" % n)
    return " ".join(out)
