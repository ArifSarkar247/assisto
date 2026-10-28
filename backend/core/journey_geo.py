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
    from .billing import flag_on
    cfg = integrations.get("google_places") or {}
    return bool(cfg.get("api_key")) and integrations.is_enabled("google_places") \
        and flag_on("maps_geocoding")


def _places_text(q, key, lang, near=None):
    params = {"query": q, "key": key, "region": "bd",
              "language": "bn" if lang == "bn" else "en"}
    if near:
        params["location"] = "%s,%s" % near
        params["radius"] = 30000
    url = ("https://maps.googleapis.com/maps/api/place/textsearch/json?" +
           urllib.parse.urlencode(params))
    req = urllib.request.Request(url, headers={"User-Agent": _UA})
    data = json.loads(urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_S)
                      .read().decode("utf-8", "replace"))
    out = []
    for r in (data.get("results") or [])[:8]:
        loc = (r.get("geometry") or {}).get("location") or {}
        if loc.get("lat") is None:
            continue
        out.append({"name": str(r.get("name") or "")[:120],
                    "address": str(r.get("formatted_address") or "")[:200],
                    "lat": round(float(loc["lat"]), 6),
                    "lng": round(float(loc["lng"]), 6)})
    return out


def geocode(q, lang="bn", near=None, search=None):
    """{'available', 'results', 'state'} — state: ok | none | failed | off."""
    q = " ".join(str(q or "").split())[:120]
    if not geocoder_ready():
        return {"available": False, "results": [], "state": "off"}
    if len(q) < 2:
        return {"available": True, "results": [], "state": "none"}
    from . import ext_breaker as XB
    cfg = integrations.get("google_places") or {}
    try:
        rows = XB.call("maps", search or _places_text, q, cfg["api_key"], lang, near)
    except Exception:
        return {"available": True, "results": [], "state": "failed"}
    return {"available": True, "results": rows, "state": "ok" if rows else "none"}
