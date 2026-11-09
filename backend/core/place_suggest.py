"""sjp0 (owner P0 9 Nov 19:40) — ONE destination suggestion list for every
app version. /maps/autocomplete (V1 apps in the field) and /maps/search (V2)
both answer from here:

  1. the user's own saved places + recent journey destinations,
  2. our free Bangladesh place list (core/bd_places.py, OpenStreetMap),
  3. Google Places Autocomplete ON TOP, only when fewer than 5 good local
     matches AND the budget allows (counted once per search SESSION, never
     per keystroke — core.maps_cost.allow).

NEVER a limit: a capped / plan-capped / off / failed / bad-session Google
answer is silent — the response is a normal "ok" with the local rows ("none"
only when nothing at all matches). Every local row carries lat/lng and an id
(saved:<id> / recent:<id> / bd:<i>) that /maps/place resolves for free, so an
old V1 client that calls Place Details on every pick still works.
"""
from . import bd_places as BP

LIMIT = 8
# public answers only ever carry these states (owner: never a limit message)
PUBLIC_STATES = ("ok", "none", "short", "cache")


def _clean(q):
    return " ".join(str(q or "").split())[:120]


def _f(v, lo=-180.0, hi=180.0):
    try:
        x = float(v)
    except (TypeError, ValueError):
        return None
    return x if lo <= x <= hi else None


def _matches(q, *names):
    nq = BP.norm(q)
    if not nq:
        return False
    toks = nq.split()
    for n in names:
        nn = BP.norm(n)
        if not nn:
            continue
        if nn.startswith(nq) or nq in nn:
            return True
        words = nn.split()
        if all(any(w.startswith(t) for w in words) for t in toks):
            return True
    return False


def mine(user, q, limit=4):
    """Saved places + recent journey destinations that match q."""
    out, seen = [], set()
    uid = getattr(user, "id", None)
    if not uid:
        return out
    try:
        from .models import SavedPlace
        for p in SavedPlace.objects.filter(user_id=uid).only(
                "id", "label", "name", "lat", "lng")[:60]:
            if p.lat is None or p.lng is None or not _matches(q, p.name, p.label):
                continue
            key = (BP.norm(p.name or p.label), round(p.lat, 3), round(p.lng, 3))
            if key in seen:
                continue
            seen.add(key)
            out.append({"place_id": "saved:%d" % p.id, "name": (p.name or p.label)[:120],
                        "secondary": (p.label if p.name and p.label != p.name else "")[:200],
                        "lat": p.lat, "lng": p.lng, "kind": "saved", "source": "saved"})
    except Exception:
        pass
    try:
        from .models import Journey
        for j in Journey.objects.filter(traveller_id=uid).order_by("-created_at") \
                .only("id", "destination")[:40]:
            d = j.destination or {}
            lat, lng = _f(d.get("lat"), -90, 90), _f(d.get("lng"))
            name = str(d.get("name") or "")
            if lat is None or lng is None or not name or not _matches(q, name):
                continue
            key = (BP.norm(name), round(lat, 3), round(lng, 3))
            if key in seen:
                continue
            seen.add(key)
            out.append({"place_id": "recent:%d" % j.id, "name": name[:120],
                        "secondary": str(d.get("address") or "")[:200],
                        "lat": lat, "lng": lng, "kind": "recent", "source": "recent"})
    except Exception:
        pass
    return out[:limit]


def suggest(user, q, session, lat=None, lng=None, lang="bn"):
    """-> {state: ok|none|short, results:[{place_id, name, secondary, lat?,
    lng?, kind?, source}], google: bool}. Never a limit / off state."""
    from . import maps_cost as MC
    q = _clean(q)
    if len(q) < MC.MIN_CHARS:
        return {"state": "short", "results": [], "google": False}
    la, ln = _f(lat, -90, 90), _f(lng)
    own = mine(user, q)
    try:
        local = BP.search(q, lat=la, lng=ln, lang=lang, limit=LIMIT)
    except Exception:
        local = []
    have = {BP.norm(r["name"]) for r in own}
    local = [r for r in local if BP.norm(r["name"]) not in have]
    good = [r for r in local if r.get("score", 0) >= BP.GOOD]
    rest = [r for r in local if r.get("score", 0) < BP.GOOD]
    gl, used_google = [], False
    if len(own) + len(good) < BP.WANT:
        try:
            g = MC.autocomplete(user, q, session, lat=lat, lng=lng, lang=lang)
        except Exception:
            g = {}
        if g.get("state") == "ok":
            used_google = True
            have |= {BP.norm(r["name"]) for r in local}
            gl = [dict(r, source="google") for r in g.get("results") or []
                  if BP.norm(r.get("name", "")) not in have]
    rows = (own + good + gl + rest)[:LIMIT]
    for r in rows:
        r.pop("score", None)
    return {"state": "ok" if rows else "none", "results": rows, "google": used_google}


def local_details(user, place_id, lang="bn"):
    """saved:/recent:/bd: ids -> {state: ok, lat, lng, address, ...} for free;
    None when the id is not one of ours."""
    pid = str(place_id or "")
    kind, _, rest = pid.partition(":")
    if kind not in ("saved", "recent", "bd") or not rest:
        return None
    got = None
    try:
        if kind == "bd":
            r = BP.row(rest, lang)
            if r:
                addr = ", ".join(x for x in (r["name"], r["secondary"]) if x)
                got = {"lat": r["lat"], "lng": r["lng"], "address": addr[:300],
                       "name": r["name"], "kind": r["kind"], "radius_m": r["radius_m"]}
        elif kind == "saved":
            from .models import SavedPlace
            p = SavedPlace.objects.filter(pk=int(rest), user_id=getattr(user, "id", None)).first()
            if p and p.lat is not None and p.lng is not None:
                got = {"lat": p.lat, "lng": p.lng, "address": (p.name or p.label)[:300],
                       "name": (p.name or p.label)[:120]}
        else:
            from .models import Journey
            j = Journey.objects.filter(pk=int(rest), traveller_id=getattr(user, "id", None)).first()
            d = (j.destination or {}) if j else {}
            la, ln = _f(d.get("lat"), -90, 90), _f(d.get("lng"))
            if la is not None and ln is not None:
                got = {"lat": la, "lng": ln, "address": str(d.get("address") or d.get("name") or "")[:300],
                       "name": str(d.get("name") or "")[:120]}
    except (TypeError, ValueError):
        got = None
    if not got:
        return {"state": "none"}
    from . import maps_cost as MC
    return dict(got, state="ok", **MC.fallback(got["lat"], got["lng"]))


def public(resp):
    """Strip any limit / off / failed state from a maps answer: the app (V1
    included) shows every non-ok state as 'limit reached'."""
    st = resp.get("state")
    if st in PUBLIC_STATES or st == "bad":
        return resp
    return dict(resp, state="none")
