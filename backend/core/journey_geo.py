"""
journey2 — the two network helpers behind the Safe Journey destination
picker. Both are honest about being unavailable; neither ever invents a place.

* resolve_short_link(url): a phone's Google Maps "Share" gives a short link
  (https://maps.app.goo.gl/...) with no coordinates in it. We read ONLY the
  redirect Location header (no body, no cookies), follow at most 4 hops and
  only across Google's own hosts (journey_dest.RESOLVE_HOSTS) — so the server
  can never be used to fetch anything else (no SSRF / open redirect).
* geocode(q): search by place name through the owner's Google Places key
  (Owner Admin -> Integrations -> google_places) and only while the
  `maps_geocoding` cost switch is on. Without a key the answer is
  {"available": False} and the app hides the search box, offering saved
  places, current location, a pasted link or the map instead.
"""
import json
import urllib.error
import urllib.parse
import urllib.request

from . import integrations
from .logic import journey_dest as JD

HTTP_TIMEOUT_S = 5
_UA = "AssistoSafeJourney/1.0 (+https://lifeassisto.com)"


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _location_of(url):
    """The redirect target of one GET, or '' (never the body)."""
    opener = urllib.request.build_opener(_NoRedirect)
    req = urllib.request.Request(url, method="GET", headers={"User-Agent": _UA})
    try:
        with opener.open(req, timeout=HTTP_TIMEOUT_S) as r:
            return r.headers.get("Location") or ""
    except urllib.error.HTTPError as e:
        if 300 <= e.code < 400:
            return e.headers.get("Location") or ""
        return ""


def resolve_short_link(url, fetch=None):
    """Coordinates behind a maps.app.goo.gl link, or None. `fetch(url)` ->
    redirect target is injectable for tests."""
    fetch = fetch or _location_of
    cur = str(url or "").strip()
    for _ in range(4):
        if not JD.resolvable_host(cur):
            return None
        try:
            nxt = fetch(cur)
        except Exception:
            return None
        if not nxt:
            return JD.parse_maps_link(cur)
        nxt = urllib.parse.urljoin(cur, nxt)
        if not JD.resolvable_host(nxt):
            return None
        got = JD.parse_maps_link(nxt)
        if got:
            return got
        cur = nxt
    return None


def geocoder_ready():
    """mapscost: the server key (google_maps_server, else the older
    google_places entry) + the maps_geocoding cost switch."""
    from . import maps_cost as MC
    return MC.ready()


def _places_text(q, key, lang, near=None):
    """placesnew (owner 3 Nov 19:55): Places API (New) Text Search — the legacy
    legacy Text Search endpoint can't be enabled on new projects. Field
    mask keeps it to the fields we show."""
    body = {"textQuery": q, "languageCode": "bn" if lang == "bn" else "en",
            "regionCode": "BD", "maxResultCount": 8}
    if near:
        body["locationBias"] = {"circle": {"center": {"latitude": float(near[0]),
                                                      "longitude": float(near[1])},
                                           "radius": 30000.0}}
    req = urllib.request.Request(
        "https://places.googleapis.com/v1/places:searchText",
        data=json.dumps(body).encode("utf-8"), method="POST",
        headers={"User-Agent": _UA, "Content-Type": "application/json",
                 "X-Goog-Api-Key": key,
                 "X-Goog-FieldMask": "places.displayName,places.formattedAddress,places.location"})
    data = json.loads(urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_S)
                      .read().decode("utf-8", "replace") or "{}")
    out = []
    for r in (data.get("places") or [])[:8]:
        loc = r.get("location") or {}
        if loc.get("latitude") is None:
            continue
        out.append({"name": str((r.get("displayName") or {}).get("text") or "")[:120],
                    "address": str(r.get("formattedAddress") or "")[:200],
                    "lat": round(float(loc["latitude"]), 6),
                    "lng": round(float(loc["longitude"]), 6)})
    return out


def geocode(q, lang="bn", near=None, search=None, user=None):
    """{'available', 'results', 'state'} — state: ok | none | failed | off |
    user_cap | global_cap. mapscost: kept only for app builds older than the
    Autocomplete search; every call is under the text_search daily caps."""
    q = " ".join(str(q or "").split())[:120]
    if not geocoder_ready():
        return {"available": False, "results": [], "state": "off"}
    if len(q) < 2:
        return {"available": True, "results": [], "state": "none"}
    from . import ext_breaker as XB
    from . import maps_cost as MC
    ok, why = MC.allow("text_search", user)
    if not ok:
        return {"available": True, "results": [], "state": why}
    try:
        rows = XB.call("maps", search or _places_text, q, MC.server_key(), lang, near)
    except Exception:
        return {"available": True, "results": [], "state": "failed"}
    return {"available": True, "results": rows, "state": "ok" if rows else "none"}
