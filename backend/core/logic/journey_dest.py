"""
journey2 — Safe Journey destination + ride helpers (pure, no ORM, no network).

* parse_maps_link(text): coordinates out of what people actually paste in
  Bangladesh — a Google Maps share link (long form), a "geo:" URI, an
  Apple/OSM link, or plain "23.78, 90.41". Short links (maps.app.goo.gl)
  carry no coordinates; `is_short_maps_link` tells the caller to resolve the
  redirect first (core.journey_watch does it with a fixed host allow-list).
* distance_m / rough_minutes: straight-line distance and an HONEST rough trip
  time (road factor x a typical Dhaka speed per mode). It is never called an
  ETA from traffic — the app and the watcher page label it "rough".
* clean_vehicle: the ride details a traveller attaches (plate, type, ride
  app, driver name/phone, note) — whitelisted keys, trimmed, bounded.
* place_kind: Home / School / Office / other for saved places.
"""
import re
from urllib.parse import parse_qs, unquote, urlparse

from .safety import haversine_m

# ------------------------------------------------------------- coordinates
_NUM = r"(-?\d{1,3}(?:\.\d+)?)"
_PAIR = re.compile(_NUM + r"\s*,\s*\+?" + _NUM)
# plain text / geo: both numbers need decimals ("House 12, 4" is an address)
_DEC = r"(-?\d{1,3}\.\d{3,})"
_DPAIR = re.compile(_DEC + r"\s*,\s*\+?" + _DEC)
_AT = re.compile(r"@" + _NUM + r"," + _NUM)            # .../@23.78,90.41,17z
_BANG = re.compile(r"!3d" + _NUM + r"!4d" + _NUM)       # ...!3d23.78!4d90.41
_SHORT_HOSTS = ("maps.app.goo.gl", "goo.gl")
RESOLVE_HOSTS = ("maps.app.goo.gl", "goo.gl", "google.com", "www.google.com",
                 "maps.google.com", "google.com.bd", "www.google.com.bd")


def _ok(lat, lng):
    try:
        lat, lng = float(lat), float(lng)
    except (TypeError, ValueError):
        return None
    if not (-90 <= lat <= 90 and -180 <= lng <= 180):
        return None
    if lat == 0 and lng == 0:
        return None
    return round(lat, 6), round(lng, 6)


def _pair(s, strict=False):
    m = (_DPAIR if strict else _PAIR).search(s or "")
    return _ok(m.group(1), m.group(2)) if m else None


def is_short_maps_link(text):
    try:
        u = urlparse(str(text or "").strip())
    except ValueError:
        return False
    host = (u.hostname or "").lower()
    return u.scheme in ("http", "https") and host in _SHORT_HOSTS


def resolvable_host(url):
    """Only Google's own hosts are followed when resolving a short link
    (no open redirect / SSRF: the server never fetches anything else)."""
    try:
        u = urlparse(str(url or ""))
    except ValueError:
        return False
    return u.scheme == "https" and (u.hostname or "").lower() in RESOLVE_HOSTS


def parse_maps_link(text):
    """{'lat','lng','name'} from a pasted link / text, or None.

    Order matters: an explicit place pin (!3d..!4d.. / q= / query= / ll=)
    beats the map viewport (@lat,lng) which is only where the map was
    looking."""
    raw = str(text or "").strip()
    if not raw or len(raw) > 2000:
        return None
    s = unquote(raw)
    m = _BANG.search(s)
    if m:
        p = _ok(m.group(1), m.group(2))
        if p:
            return {"lat": p[0], "lng": p[1], "name": _place_name(s)}
    if s.lower().startswith("geo:"):
        p = _pair(s[4:].split("?")[0])
        if p:
            return {"lat": p[0], "lng": p[1], "name": ""}
    try:
        u = urlparse(s if "://" in s else "")
    except ValueError:
        u = None
    if u is not None and u.scheme in ("http", "https"):
        qs = parse_qs(u.query)
        for k in ("q", "query", "ll", "daddr", "destination", "center", "mlat"):
            v = (qs.get(k) or [""])[0]
            if k == "mlat":
                p = _ok(v, (qs.get("mlon") or [""])[0])
            else:
                p = _pair(v)
            if p:
                return {"lat": p[0], "lng": p[1], "name": _place_name(s)}
        m = _AT.search(s)
        if m:
            p = _ok(m.group(1), m.group(2))
            if p:
                return {"lat": p[0], "lng": p[1], "name": _place_name(s)}
        # osm: .../#map=17/23.78/90.41
        m = re.search(r"map=\d+/" + _NUM + "/" + _NUM, s)
        if m:
            p = _ok(m.group(1), m.group(2))
            if p:
                return {"lat": p[0], "lng": p[1], "name": ""}
        return None
    # plain text: "23.7806, 90.4070" (also inside a sentence)
    p = _pair(s, strict=True)
    if p:
        return {"lat": p[0], "lng": p[1], "name": ""}
    return None


def _place_name(s):
    """'/maps/place/Bashundhara+City/@...' -> 'Bashundhara City' (or '')."""
    m = re.search(r"/maps/place/([^/@?]+)", s)
    if not m:
        return ""
    name = unquote(m.group(1).replace("+", " ")).strip()
    if _pair(name):
        return ""
    return name[:120]


# ---------------------------------------------------------- distance / time
ROAD_FACTOR = 1.35          # Dhaka roads vs the straight line (rough)
# typical door-to-door city speeds, km/h (rough; never shown as live traffic)
MODE_KMH = {"walk": 4.5, "rickshaw": 7.0, "bus": 10.0, "cng": 12.0,
            "car": 12.0, "bike": 16.0, "ride": 12.0, "": 12.0}


def distance_m(a_lat, a_lng, b_lat, b_lng):
    try:
        return int(round(haversine_m(float(a_lat), float(a_lng),
                                     float(b_lat), float(b_lng))))
    except (TypeError, ValueError):
        return None


def rough_minutes(dist_m, mode=""):
    """Rough trip minutes for a straight-line distance. None when unknown.
    Rounded UP to 5 minutes (never promise sooner than true), minimum 5."""
    if dist_m is None or dist_m < 0:
        return None
    kmh = MODE_KMH.get(mode or "", MODE_KMH[""])
    mins = (dist_m * ROAD_FACTOR / 1000.0) / kmh * 60.0
    return max(5, int(-(-mins // 5) * 5))


# ---------------------------------------------------------------- ride
MODES = ("cng", "bike", "car", "rickshaw", "bus", "walk", "ride")
RIDE_APPS = ("pathao", "uber", "obhai", "indrive", "other")


MODE_LABEL = {"cng": ("সিএনজি", "CNG"), "bike": ("বাইক", "Bike"), "car": ("গাড়ি", "Car"),
              "rickshaw": ("রিকশা", "Rickshaw"), "bus": ("বাস", "Bus"),
              "walk": ("হেঁটে", "Walking"), "ride": ("রাইড", "Ride")}
APP_LABEL = {"pathao": ("পাঠাও", "Pathao"), "uber": ("উবার", "Uber"),
             "obhai": ("ওভাই", "Obhai"), "indrive": ("ইনড্রাইভ", "inDrive")}


def _lbl(table, key, lang):
    v = table.get(key or "")
    return (v[0] if lang == "bn" else v[1]) if v else ""


def ride_line(v, lang="bn"):
    """'সিএনজি · পাঠাও · DHAKA METRO THA 11-2233' — labels in ONE language
    (the plate is what is painted on the vehicle and stays as typed)."""
    v = v or {}
    parts = [_lbl(MODE_LABEL, v.get("mode"), lang), _lbl(APP_LABEL, v.get("app"), lang),
             str(v.get("plate") or "")]
    return " · ".join(p for p in parts if p)


def _txt(v, n):
    return re.sub(r"\s+", " ", str(v or "")).strip()[:n]


def clean_vehicle(d):
    """Whitelisted, bounded ride details or None when nothing useful."""
    if not isinstance(d, dict):
        return None
    out = {}
    plate = _txt(d.get("plate"), 40)
    if plate:
        out["plate"] = plate
    mode = _txt(d.get("mode"), 16).lower()
    if mode in MODES:
        out["mode"] = mode
    app = _txt(d.get("app"), 16).lower()
    if app in RIDE_APPS:
        out["app"] = app
    name = _txt(d.get("driver_name"), 60)
    if name:
        out["driver_name"] = name
    phone = re.sub(r"[^\d+]", "", str(d.get("driver_phone") or ""))[:16]
    if len(re.sub(r"\D", "", phone)) >= 6:
        out["driver_phone"] = phone
    note = _txt(d.get("note"), 120)
    if note:
        out["note"] = note
    return out or None


# ------------------------------------------------------------ saved places
PLACE_KINDS = ("home", "school", "office", "other")
MAX_PLACES = 30


def place_kind(label):
    k = _txt(label, 40).lower()
    return k if k in PLACE_KINDS else "other"


def clean_place(d):
    """(place dict, error code). Coordinates are optional only for 'other'
    with a name; Home/School/Office need a pin (they exist to auto-detect
    arrival)."""
    if not isinstance(d, dict):
        return None, "bad"
    kind = place_kind(d.get("kind") or d.get("label"))
    name = _txt(d.get("name"), 160)
    lat, lng = d.get("lat"), d.get("lng")
    p = None
    if lat not in (None, "") or lng not in (None, ""):
        p = _ok(lat, lng)
        if p is None:
            return None, "bad_coords"
    if p is None:
        return None, "coords_required"
    if not name:
        name = ""
    return {"kind": kind, "label": kind if kind != "other" else _txt(d.get("label"), 40),
            "name": name, "lat": p[0], "lng": p[1]}, None
