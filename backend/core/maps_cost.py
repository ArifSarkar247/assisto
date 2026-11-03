"""mapscost (owner order 3 Nov 18:40, PART 1) — the ONLY door to paid Google
Maps Platform web APIs. Every paid call goes through `_paid()`, which:

* needs the SERVER key (Owner Admin -> Integrations -> google_maps_server,
  encrypted; the older google_places entry is honoured as a fallback). The key
  never leaves the server — the phones never see it;
* needs the `maps_geocoding` cost switch on (Owner Admin -> Cost flags);
* checks the per-user daily limit and the global daily cap for that API
  (editable in Owner Admin -> Maps usage) BEFORE spending, and counts the call;
* on any refusal / failure answers a FREE fallback: the coordinates as text
  and an "Open in Google Maps" link (opening the Google Maps app is free).

What is NOT here, on purpose (zero API calls): map display (Maps SDK on the
phone), live location, destination alarm, arrival / school geofences (GPS
distance maths on the phone and our server), navigation (Google Maps app
intent) and SOS — SOS never calls or waits on anything in this module.

Reverse geocoding: the phone asks the free on-phone Android Geocoder first;
only when that gives nothing does it call /maps/reverse here, which answers
from our ~50 m cache before paying.
Search: Places API (New) Autocomplete with a session token, 2+ characters
(jsearch, owner 4 Nov: like the Google Maps app),
the app debounces 300 ms, field masks on every request, and ONE Place Details
(Essentials fields only: id, location, formattedAddress) ends the session.
Routes: one Compute Routes call at trip start or on the user's tap, cached
10 minutes per user + rounded origin/destination.
"""
import json
import math
import re
import urllib.error
import urllib.parse
import urllib.request
from datetime import timedelta

from django.core.cache import cache
from django.db import IntegrityError, transaction
from django.db.models import F, Sum
from django.utils import timezone

HTTP_TIMEOUT_S = 5
_UA = "AssistoMaps/1.0 (+https://lifeassisto.com)"
CACHE_RADIUS_M = 50.0
CELL_DEG = 0.0005            # ~55 m north-south; lookups check the 3x3 block
GEO_CACHE_DAYS = 60
ROUTE_CACHE_S = 600
CONFIG_KEY = "maps_cost"

# Defaults keep a normal month inside Google's free monthly caps (owner rule:
# no spending). Prices = Google Maps Platform list price per 1000 calls after
# the free cap (Mar 2025 price list); all editable in Owner Admin.
APIS = ("geocode", "autocomplete", "place_details", "routes", "text_search")
DEFAULTS = {
    "geocode":       {"usd_per_1000": 5.0,  "free_month": 10000, "user_day": 20, "global_day": 300},
    "autocomplete":  {"usd_per_1000": 2.83, "free_month": 10000, "user_day": 60, "global_day": 300},
    "place_details": {"usd_per_1000": 5.0,  "free_month": 10000, "user_day": 15, "global_day": 300},
    "routes":        {"usd_per_1000": 10.0, "free_month": 5000,  "user_day": 6,  "global_day": 150},
    "text_search":   {"usd_per_1000": 32.0, "free_month": 5000,  "user_day": 5,  "global_day": 100},
}
LABELS = {
    "geocode": ("ঠিকানা খোঁজা (Geocoding)", "Address lookup (Geocoding)"),
    "autocomplete": ("জায়গা খোঁজা — Autocomplete", "Place search — Autocomplete"),
    "place_details": ("জায়গার বিবরণ — Place Details Essentials", "Place Details Essentials"),
    "routes": ("রাস্তায় সময় — Routes", "Road time — Routes"),
    "text_search": ("পুরোনো নাম-খোঁজা — Text Search", "Old name search — Text Search"),
}
DEFAULT_BDT_PER_USD = 122.0
FIELD_LIMITS = {"usd_per_1000": (0.0, 1000.0), "free_month": (0, 10_000_000),
                "user_day": (0, 100_000), "global_day": (0, 10_000_000)}

_TOKEN = re.compile(r"^[A-Za-z0-9_-]{8,64}$")
_PLACE_ID = re.compile(r"^[A-Za-z0-9_-]{6,300}$")


# ------------------------------------------------------------------ config
def config():
    """{'apis': {api: {usd_per_1000, free_month, user_day, global_day}},
    'bdt_per_usd'} — owner edits merged over the defaults."""
    from .models import PricingConfig
    row = PricingConfig.objects.filter(key=CONFIG_KEY).first()
    data = (row.data if row else None) or {}
    apis = {}
    for a in APIS:
        cur = dict(DEFAULTS[a])
        for k, v in ((data.get("apis") or {}).get(a) or {}).items():
            if k in cur:
                cur[k] = v
        apis[a] = cur
    try:
        bdt = float(data.get("bdt_per_usd") or DEFAULT_BDT_PER_USD)
    except (TypeError, ValueError):
        bdt = DEFAULT_BDT_PER_USD
    return {"apis": apis, "bdt_per_usd": bdt}


def save_config(api, values=None, bdt_per_usd=None):
    """Owner edit. Validates every number; returns (before, after). Raises
    ValueError on an unknown api / field or an out-of-range number."""
    from .models import PricingConfig
    row, _ = PricingConfig.objects.get_or_create(key=CONFIG_KEY)
    data = dict(row.data or {})
    before = config()
    if api:
        if api not in APIS:
            raise ValueError("unknown api")
        cur = dict((data.get("apis") or {}).get(api) or {})
        for k, v in (values or {}).items():
            if k not in FIELD_LIMITS:
                raise ValueError("unknown field")
            lo, hi = FIELD_LIMITS[k]
            n = float(v) if k == "usd_per_1000" else int(v)
            if n < lo or n > hi:
                raise ValueError("out of range")
            cur[k] = n
        apis = dict(data.get("apis") or {})
        apis[api] = cur
        data["apis"] = apis
    if bdt_per_usd is not None:
        n = float(bdt_per_usd)
        if n <= 0 or n > 10000:
            raise ValueError("out of range")
        data["bdt_per_usd"] = n
    row.data = data
    row.save(update_fields=["data", "updated_at"])
    return before, config()


# ------------------------------------------------------------------ key
def server_key():
    """The server-only key (never sent to phones)."""
    from . import integrations
    for slug in ("google_maps_server", "google_places"):
        k = str((integrations.get(slug) or {}).get("api_key") or "").strip()
        if k:
            return k
    return ""


def ready():
    from .billing import flag_on
    return bool(server_key()) and flag_on("maps_geocoding")


# ------------------------------------------------------------------ limits
def _uid(user):
    return int(getattr(user, "id", 0) or 0) if user is not None else 0


def _bump(day, api, uid, field):
    from .models import MapsUsage
    n = MapsUsage.objects.filter(day=day, api=api, user_id=uid).update(**{field: F(field) + 1})
    if not n:
        try:
            with transaction.atomic():
                MapsUsage.objects.create(day=day, api=api, user_id=uid, **{field: 1})
        except IntegrityError:
            MapsUsage.objects.filter(day=day, api=api, user_id=uid).update(**{field: F(field) + 1})


def _plan_allowed(user):
    """safeplans hook: per-plan monthly cap on paid map calls. Safe fallback
    (allowed) until core.safe_plans exists / when it fails."""
    try:
        from .safe_plans import paid_maps_allowed
    except Exception:
        return True
    try:
        return bool(paid_maps_allowed(user))
    except Exception:
        return True


def _plan_note(user):
    try:
        from .safe_plans import note_paid_maps
    except Exception:
        return
    try:
        note_paid_maps(user)
    except Exception:
        pass


def allow(api, user, now=None):
    """(ok, reason) — reason '' | 'user_cap' | 'plan_cap' | 'global_cap'. Counts the call
    when allowed, counts the refusal when not. Day = Bangladesh local date."""
    from .models import MapsUsage
    day = timezone.localdate(now or timezone.now())
    c = config()["apis"][api]
    uid = _uid(user)
    if uid:
        mine = MapsUsage.objects.filter(day=day, api=api, user_id=uid) \
            .values_list("count", flat=True).first() or 0
        if mine >= int(c["user_day"]):
            _bump(day, api, uid, "capped")
            return False, "user_cap"
    if uid and not _plan_allowed(user):
        _bump(day, api, uid, "capped")
        return False, "plan_cap"
    total = MapsUsage.objects.filter(day=day, api=api).aggregate(s=Sum("count"))["s"] or 0
    if total >= int(c["global_day"]):
        _bump(day, api, uid, "capped")
        return False, "global_cap"
    _bump(day, api, uid, "count")
    if uid:
        _plan_note(user)
    return True, ""


# ------------------------------------------------------------------ fallback
def _ok_coord(lat, lng):
    try:
        lat, lng = float(lat), float(lng)
    except (TypeError, ValueError):
        return None
    if not (-90 <= lat <= 90 and -180 <= lng <= 180) or (lat == 0 and lng == 0):
        return None
    return lat, lng


def fallback(lat=None, lng=None):
    """Free answer: coordinates text + 'Open in Google Maps' (free)."""
    p = _ok_coord(lat, lng)
    if not p:
        return {"coords": "", "gmaps_url": ""}
    return {"coords": "%.5f, %.5f" % p,
            "gmaps_url": "https://www.google.com/maps/search/?api=1&query=%.6f,%.6f" % p}


# ------------------------------------------------------------------ http
def _http_json(url, body=None, headers=None):
    data = json.dumps(body).encode() if body is not None else None
    h = {"User-Agent": _UA}
    if data is not None:
        h["Content-Type"] = "application/json"
    h.update(headers or {})
    req = urllib.request.Request(url, data=data, headers=h,
                                 method="POST" if data is not None else "GET")
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_S) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


HTTP = _http_json      # tests replace this — CI never makes a real call


def _paid(api, user, fn):
    """Run fn(key) under the limits. -> (state, result) with state in
    ok | off | user_cap | global_cap | failed."""
    if not ready():
        return "off", None
    ok, why = allow(api, user)
    if not ok:
        return why, None
    try:
        from . import ext_breaker as XB
        return "ok", XB.call("maps", fn, server_key())
    except Exception:
        return "failed", None


# ------------------------------------------------------------------ reverse
def _cell(lat, lng):
    return int(math.floor(lat / CELL_DEG)), int(math.floor(lng / CELL_DEG))


def _cell_key(ci, cj, lang):
    return "%d:%d:%s" % (ci, cj, lang)


def cache_lookup(lat, lng, lang="bn", now=None):
    from .models import MapsGeoCache
    from .logic.safety import haversine_m
    ci, cj = _cell(lat, lng)
    keys = [_cell_key(ci + a, cj + b, lang) for a in (-1, 0, 1) for b in (-1, 0, 1)]
    since = (now or timezone.now()) - timedelta(days=GEO_CACHE_DAYS)
    best, best_d = None, None
    for row in MapsGeoCache.objects.filter(cell__in=keys, created_at__gte=since):
        d = haversine_m(lat, lng, row.lat, row.lng)
        if d <= CACHE_RADIUS_M and (best_d is None or d < best_d):
            best, best_d = row, d
    return best.address if best else None


def cache_store(lat, lng, lang, address, source="google"):
    from .models import MapsGeoCache
    address = str(address or "").strip()[:300]
    if not address:
        return
    ci, cj = _cell(lat, lng)
    MapsGeoCache.objects.create(cell=_cell_key(ci, cj, lang), lat=lat, lng=lng,
                                lang=lang, address=address, source=source[:12])


def reverse(user, lat, lng, lang="bn"):
    """Address for a point. -> {state, address, coords, gmaps_url}; state:
    cache | ok | none | off | user_cap | global_cap | failed | bad."""
    lang = "en" if lang == "en" else "bn"
    p = _ok_coord(lat, lng)
    if not p:
        return {"state": "bad", "address": "", "coords": "", "gmaps_url": ""}
    lat, lng = p
    out = fallback(lat, lng)
    hit = cache_lookup(lat, lng, lang)
    if hit:
        return dict(out, state="cache", address=hit)

    def call(key):
        q = urllib.parse.urlencode({"latlng": "%.6f,%.6f" % (lat, lng), "key": key,
                                    "language": lang, "region": "bd"})
        data = HTTP("https://maps.googleapis.com/maps/api/geocode/json?" + q)
        rows = data.get("results") or []
        return str(rows[0].get("formatted_address") or "") if rows else ""

    state, addr = _paid("geocode", user, call)
    if state != "ok":
        return dict(out, state=state, address="")
    if not addr:
        return dict(out, state="none", address="")
    cache_store(lat, lng, lang, addr)
    return dict(out, state="ok", address=addr[:300])


# ------------------------------------------------------------------ search
AUTOCOMPLETE_MASK = ("suggestions.placePrediction.placeId,"
                     "suggestions.placePrediction.structuredFormat,"
                     "suggestions.placePrediction.distanceMeters")
DETAILS_MASK = "id,location,formattedAddress"       # Essentials SKU only
MIN_CHARS = 2      # jsearch: "Ch" already lists places (owner 4 Nov)


def autocomplete(user, q, session, lat=None, lng=None, lang="bn"):
    """-> {state, results:[{place_id, name, secondary}]}; state: ok | none |
    short | bad_session | off | user_cap | global_cap | failed."""
    q = " ".join(str(q or "").split())[:120]
    if len(q) < MIN_CHARS:
        return {"state": "short", "results": []}
    session = str(session or "")
    if not _TOKEN.match(session):
        return {"state": "bad_session", "results": []}
    body = {"input": q, "sessionToken": session, "includedRegionCodes": ["bd"],
            "regionCode": "bd", "languageCode": "en" if lang == "en" else "bn"}
    near = _ok_coord(lat, lng)
    if near:
        body["locationBias"] = {"circle": {"center": {"latitude": near[0], "longitude": near[1]},
                                           "radius": 30000.0}}
        # same request, no extra charge: Google returns each row's straight
        # distance from here (distanceMeters) — the phone formats it
        body["origin"] = {"latitude": near[0], "longitude": near[1]}

    def call(key):
        data = HTTP("https://places.googleapis.com/v1/places:autocomplete", body,
                    {"X-Goog-Api-Key": key, "X-Goog-FieldMask": AUTOCOMPLETE_MASK})
        out = []
        for s in (data.get("suggestions") or [])[:6]:
            pp = s.get("placePrediction") or {}
            sf = pp.get("structuredFormat") or {}
            pid = str(pp.get("placeId") or "")
            name = str(((sf.get("mainText") or {}).get("text")) or "")
            if pid and name:
                row = {"place_id": pid, "name": name[:120],
                       "secondary": str(((sf.get("secondaryText") or {}).get("text")) or "")[:200]}
                dm = pp.get("distanceMeters")
                if isinstance(dm, (int, float)) and dm >= 0:
                    row["distance_m"] = int(dm)
                out.append(row)
        return out

    state, rows = _paid("autocomplete", user, call)
    if state != "ok":
        return {"state": state, "results": []}
    return {"state": "ok" if rows else "none", "results": rows}


def place_details(user, place_id, session, lang="bn"):
    """One Place Details (Essentials) — ends the autocomplete session.
    -> {state, lat, lng, address}."""
    place_id = str(place_id or "")
    if not _PLACE_ID.match(place_id):
        return {"state": "bad"}
    session = str(session or "")
    ck = "mapsplace:%s:%s" % (place_id, lang)
    hit = cache.get(ck)
    if hit:
        return dict(hit, state="cache")
    q = {"languageCode": "en" if lang == "en" else "bn"}
    if _TOKEN.match(session):
        q["sessionToken"] = session

    def call(key):
        d = HTTP("https://places.googleapis.com/v1/places/%s?%s"
                 % (urllib.parse.quote(place_id), urllib.parse.urlencode(q)), None,
                 {"X-Goog-Api-Key": key, "X-Goog-FieldMask": DETAILS_MASK})
        loc = d.get("location") or {}
        if loc.get("latitude") is None:
            return None
        return {"lat": round(float(loc["latitude"]), 6), "lng": round(float(loc["longitude"]), 6),
                "address": str(d.get("formattedAddress") or "")[:300]}

    state, got = _paid("place_details", user, call)
    if state != "ok":
        return {"state": state}
    if not got:
        return {"state": "none"}
    cache.set(ck, got, 24 * 3600)
    if got["address"]:
        cache_store(got["lat"], got["lng"], "en" if lang == "en" else "bn", got["address"])
    return dict(got, state="ok", **fallback(got["lat"], got["lng"]))


# ------------------------------------------------------------------ routes
_MODES = {"walk": "WALK", "bike": "TWO_WHEELER", "motorbike": "TWO_WHEELER"}


def route_eta(user, o_lat, o_lng, d_lat, d_lng, mode=""):
    """Road time with traffic, ONE call (trip start or the user's tap), cached
    10 minutes per user + rounded points. -> {state, minutes, distance_m,
    gmaps_url}."""
    o, d = _ok_coord(o_lat, o_lng), _ok_coord(d_lat, d_lng)
    if not o or not d:
        return {"state": "bad"}
    gm = ("https://www.google.com/maps/dir/?api=1&origin=%.6f,%.6f&destination=%.6f,%.6f"
          % (o[0], o[1], d[0], d[1]))
    travel = _MODES.get(str(mode or "").lower(), "DRIVE")
    ck = "mapsroute:%d:%.3f:%.3f:%.4f:%.4f:%s" % (_uid(user), o[0], o[1], d[0], d[1], travel)
    hit = cache.get(ck)
    if hit:
        return dict(hit, state="cache", gmaps_url=gm)
    body = {"origin": {"location": {"latLng": {"latitude": o[0], "longitude": o[1]}}},
            "destination": {"location": {"latLng": {"latitude": d[0], "longitude": d[1]}}},
            "travelMode": travel}
    if travel in ("DRIVE", "TWO_WHEELER"):
        body["routingPreference"] = "TRAFFIC_AWARE"

    def call(key):
        r = HTTP("https://routes.googleapis.com/directions/v2:computeRoutes", body,
                 {"X-Goog-Api-Key": key,
                  "X-Goog-FieldMask": "routes.duration,routes.distanceMeters"})
        rt = (r.get("routes") or [None])[0]
        if not rt:
            return None
        secs = int(str(rt.get("duration") or "0s").rstrip("s") or 0)
        return {"minutes": max(1, int(round(secs / 60.0))),
                "distance_m": int(rt.get("distanceMeters") or 0)}

    state, got = _paid("routes", user, call)
    if state != "ok":
        return {"state": state, "gmaps_url": gm}
    if not got:
        return {"state": "none", "gmaps_url": gm}
    cache.set(ck, got, ROUTE_CACHE_S)
    return dict(got, state="ok", gmaps_url=gm)


# ------------------------------------------------------------------ owner card
def cost_usd(month_calls, free_month, usd_per_1000):
    """Estimated bill for the month: only calls above the free monthly cap."""
    over = max(0, int(month_calls) - int(free_month))
    return round(over * float(usd_per_1000) / 1000.0, 2)


def usage_card(now=None, lang="bn"):
    """Owner Admin 'Maps usage': per API today / this month / capped today /
    free left / estimated USD + BDT; totals."""
    from .models import MapsUsage
    now = now or timezone.now()
    today = timezone.localdate(now)
    first = today.replace(day=1)
    cfg = config()
    bdt = cfg["bdt_per_usd"]
    rows, tot_usd = [], 0.0
    for a in APIS:
        c = cfg["apis"][a]
        qs = MapsUsage.objects.filter(api=a)
        t = qs.filter(day=today).aggregate(n=Sum("count"), k=Sum("capped"))
        m = qs.filter(day__gte=first, day__lte=today).aggregate(n=Sum("count"))["n"] or 0
        usd = cost_usd(m, c["free_month"], c["usd_per_1000"])
        tot_usd += usd
        rows.append({"api": a, "label": LABELS[a][0 if lang == "bn" else 1],
                     "today": t["n"] or 0, "capped_today": t["k"] or 0, "month": m,
                     "free_left": max(0, int(c["free_month"]) - m),
                     "usd": usd, "bdt": round(usd * bdt, 2), **c})
    return {"rows": rows, "usd": round(tot_usd, 2), "bdt": round(tot_usd * bdt, 2),
            "bdt_per_usd": bdt, "ready": ready(), "month": first.strftime("%Y-%m"),
            "key_set": bool(server_key())}
