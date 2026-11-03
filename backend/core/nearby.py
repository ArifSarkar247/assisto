"""
Nearby places (extra C). Google Places (owner key, best for Bangladesh) with an
OpenStreetMap Overpass fallback (no key, polite, cached). Returns real data
only — name, distance, open-now, address, phone, maps link. We NEVER invent
ratings; OSM has none, and Places ratings are passed through only if present.
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
PLACES_ATTRIBUTION = "Google"


def attribution(source):
    """The licence line the app must show under results from `source`."""
    return {"osm": OSM_ATTRIBUTION, "places": PLACES_ATTRIBUTION}.get(source, "")
_CACHE = {}        # (type,lat2,lon2) -> (ts, results)  tiny in-process cache
_CACHE_TTL = 300
_LAST_OSM = [0.0]  # polite rate-limit for Overpass

_PLACES_TYPE = {"restaurant": "restaurant", "pharmacy": "pharmacy",
                "atm": "atm", "hospital": "hospital", "lodging": "lodging",
                "police": "police", "fire": "fire_station",
                "transport": "transit_station", "fuel": "gas_station",
                "mosque": "mosque", "govt": "local_government_office"}
# OSM tag filters per type (nodes, ways and relations; `out center` gives a
# point for buildings mapped as areas, e.g. most hospitals).
_OSM_FILTER = {"restaurant": ['nwr["amenity"="restaurant"]'],
               "pharmacy": ['nwr["amenity"="pharmacy"]'],
               "atm": ['nwr["amenity"="atm"]', 'nwr["amenity"="bank"]'],
               "hospital": ['nwr["amenity"="hospital"]', 'nwr["amenity"="clinic"]'],
               "lodging": ['nwr["tourism"~"hotel|motel|guest_house"]'],
               "police": ['nwr["amenity"="police"]'],
               "fire": ['nwr["amenity"="fire_station"]'],
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


# NOTE for integrator: the nearby endpoint in core/views.py that calls
# search(...) should pass lang=req_lang(request) so the OSM "(unnamed)"
# placeholder follows the user's language.
def search(lat, lon, ptype, lang="bn"):
    """Return (results, source). Open data (OSM) only — never paid Google Nearby Search."""
    ptype = ptype if ptype in _PLACES_TYPE else "restaurant"
    ckey = (ptype, round(lat, 3), round(lon, 3))
    hit = _CACHE.get(ckey)
    if hit and time.time() - hit[0] < _CACHE_TTL:
        return hit[1]
    from . import ext_breaker as XB
    # placesnew (owner 3 Nov 18:50 + 19:55): never the paid (legacy) Google
    # Nearby Search — open data only; the app adds "See more in Google Maps".
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
