"""
Nearby places (extra C) — ZERO Google cost (owner 3 Nov 18:50).

Emergency types (hospital, pharmacy, police, fire, clinic, ambulance) come
from Assisto's OWN list (core.nearby_list: monthly OpenStreetMap extract +
owner overrides); other types, and an emergency type where our list has
nothing yet, use the free OpenStreetMap Overpass API (polite, cached). The
paid Google Places Nearby Search is never called and no Google Places
content is ever stored (Google's terms forbid it). Real data only — we NEVER
invent ratings; OSM has none.
"""
import json
import math
import time
import urllib.parse
import urllib.request

from .i18n import pick

# OSM Overpass usage policy: identify the app with a contact URL, cache, and
# stay polite (one query per ~2 s). Attribution is returned with every answer
# (ODbL: "© OpenStreetMap contributors") and shown by the app.
_UA = "AssistoNearby/1.0 (+https://lifeassisto.com)"
OSM_ATTRIBUTION = "© OpenStreetMap contributors (ODbL)"


def attribution(source):
    """The licence line the app must show under results from `source`."""
    return {"osm": OSM_ATTRIBUTION, "assisto": OSM_ATTRIBUTION}.get(source, "")
_CACHE = {}        # (type,lat2,lon2) -> (ts, results)  tiny in-process cache
_CACHE_TTL = 300
_LAST_OSM = [0.0]  # polite rate-limit for Overpass

_TYPES = ("restaurant", "pharmacy", "atm", "hospital", "lodging", "police", "fire",
          "transport", "fuel", "mosque", "govt", "clinic", "ambulance")
# types served from Assisto's own list first (core.nearby_list.EMERGENCY)
_OWN = {"hospital": ("hospital", "clinic"), "pharmacy": ("pharmacy",),
        "police": ("police",), "fire": ("fire",), "clinic": ("clinic",),
        "ambulance": ("ambulance",)}
# OSM tag filters per type (nodes, ways and relations; `out center` gives a
# point for buildings mapped as areas, e.g. most hospitals).
_OSM_FILTER = {"restaurant": ['nwr["amenity"="restaurant"]'],
               "pharmacy": ['nwr["amenity"="pharmacy"]'],
               "atm": ['nwr["amenity"="atm"]', 'nwr["amenity"="bank"]'],
               "hospital": ['nwr["amenity"="hospital"]', 'nwr["amenity"="clinic"]'],
               "lodging": ['nwr["tourism"~"hotel|motel|guest_house"]'],
               "police": ['nwr["amenity"="police"]'],
               "fire": ['nwr["amenity"="fire_station"]'],
               "clinic": ['nwr["amenity"="clinic"]'],
               "ambulance": ['nwr["emergency"="ambulance_station"]'],
               "transport": ['nwr["amenity"="bus_station"]', 'nwr["railway"="station"]',
                             'nwr["amenity"="ferry_terminal"]'],
               "fuel": ['nwr["amenity"="fuel"]'],
               "mosque": ['nwr["amenity"="place_of_worship"]["religion"="muslim"]'],
               "govt": ['nwr["office"="government"]', 'nwr["amenity"="townhall"]']}


def _haversine(a, b, c, d):
    R = 6371000
    p1, p2 = math.radians(a), math.radians(c)
    dp = math.radians(c - a)
    dl = math.radians(d - b)
    x = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return int(R * 2 * math.asin(math.sqrt(x)))


# srvperf/H: a maps lookup sits in the request path (Nearby, Safe Journey's
# police/hospital): short timeout + shared circuit, never 20 s x2 per call.
HTTP_TIMEOUT_S = 6


def _get(url, timeout=HTTP_TIMEOUT_S):
    req = urllib.request.Request(url, headers={"User-Agent": _UA})
    return urllib.request.urlopen(req, timeout=timeout).read().decode("utf-8", "replace")


def _own(lat, lon, ptype, radius=10000, lang="bn"):
    """Nearest rows of Assisto's own list (same shape as _osm)."""
    from . import nearby_list as NL
    from .models import NearbyPlace
    d = radius / 100000.0 + 0.02
    out = []
    qs = (NearbyPlace.objects.filter(category__in=_OWN[ptype], hidden=False)
          .exclude(source="biz")
          .filter(NL._in_box(lat - d, lat + d, lon - d, lon + d))[:2000])
    for p in qs:
        e = NL.eff(p)
        m = _haversine(lat, lon, e["lat"], e["lon"])
        if m > radius:
            continue
        name = (e["name_en"] if lang == "en" else e["name"]) or e["name"] or e["name_en"]
        out.append({
            "id": p.id,
            "name": name or pick(lang, "(নামহীন)", "(unnamed)"),
            "address": "",
            "distance_m": m,
            "open_now": None,
            "rating": None,
            "phone": e["phone"] or None,
            "lat": e["lat"], "lon": e["lon"],
            "maps": "https://www.google.com/maps/search/?api=1&query=%s,%s" % (e["lat"], e["lon"]),
        })
    return sorted(out, key=lambda x: x["distance_m"])[:12]


def _osm(lat, lon, ptype, radius=2500, lang="bn"):
    gap = time.time() - _LAST_OSM[0]
    if gap < 1:
        time.sleep(1 - gap)       # polite to the free Overpass API, but short
    _LAST_OSM[0] = time.time()
    flts = _OSM_FILTER.get(ptype, _OSM_FILTER["restaurant"])
    union = "".join(f"{f}(around:{radius},{lat},{lon});" for f in flts)
    q = f"[out:json][timeout:20];({union});out center 30;"
    url = "https://overpass-api.de/api/interpreter?data=" + urllib.parse.quote(q)
    data = json.loads(_get(url))
    out = []
    for el in data.get("elements", []):
        tags = el.get("tags", {})
        c = el.get("center") or {}
        plat, plon = el.get("lat", c.get("lat")), el.get("lon", c.get("lon"))
        if not plat:
            continue
        out.append({
            "name": tags.get("name") or pick(lang, "(নামহীন)", "(unnamed)"),
            "address": ", ".join(filter(None, [tags.get("addr:road"), tags.get("addr:city")])),
            "distance_m": _haversine(lat, lon, plat, plon),
            "open_now": None,               # OSM has no reliable open-now
            "rating": None,                 # never invent
            "phone": tags.get("phone") or tags.get("contact:phone"),
            "lat": plat, "lon": plon,
            "maps": f"https://www.google.com/maps/search/?api=1&query={plat},{plon}",
        })
    return sorted(out, key=lambda x: x["distance_m"])[:12]


def search(lat, lon, ptype, lang="bn"):
    """Return (results, source). Own list for emergency types, else OSM
    Overpass. Never Google (owner 3 Nov: zero Google cost)."""
    ptype = ptype if ptype in _TYPES else "restaurant"
    ckey = (ptype, round(lat, 3), round(lon, 3), lang)
    hit = _CACHE.get(ckey)
    if hit and time.time() - hit[0] < _CACHE_TTL:
        return hit[1]
    from . import ext_breaker as XB
    res = None
    if ptype in _OWN:
        try:
            rows = _own(lat, lon, ptype, lang=lang)
            if rows:
                res = (rows, "assisto")
        except Exception:
            res = None
    if res is None:
        try:
            res = (XB.call("osm", _osm, lat, lon, ptype, lang=lang), "osm")
        except Exception:
            # srvperf/H: every maps source is down -> an honest empty answer
            # (never a 500, never cached so the next try can succeed).
            return [], "unavailable"
    _CACHE[ckey] = (time.time(), res)
    return res
