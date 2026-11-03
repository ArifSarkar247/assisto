"""nearby (owner 3 Nov 18:50): Assisto's OWN emergency place list.

Zero Google cost: nothing here ever calls a Google API and nothing stores
Google Places content (their terms forbid it). Data:
  * OpenStreetMap — filtered per country in GitHub Actions
    (.github/workflows/nearby_data.yml), published as small gzip JSON release
    assets; `manage.py nearby_import` (inside minute_jobs) pulls only those.
    Licence ODbL 1.0, attribution "© OpenStreetMap contributors" goes with
    every answer and is shown under every list.
  * the owner (Owner Admin -> Nearby list): add / edit / hide. Edits live in
    the o_* columns + `hidden`, so a monthly refresh never undoes them.
  * Bangladesh official lists (DGHS / Police / Fire Service) are NOT imported:
    no reuse licence was found (see owner_actions/FEATURE_CARD_NEARBY_BN.md).

The phone downloads an AREA (3 x 3 one-degree tiles around it), caches it with
the area's version token, sorts by distance itself and works offline from the
last area. Every owner edit or import bumps its country's version, so the next
open on every phone re-pulls the area: changes reach all users at once.
"""
import gzip
import hashlib
import json
import math
import sys
import urllib.request
from datetime import timedelta

from django.conf import settings
from django.db import transaction
from django.db.models import F, Q
from django.utils import timezone

EMERGENCY = ("hospital", "clinic", "pharmacy", "police", "fire", "ambulance")
GENERAL = ("food", "shop", "atm", "fuel")
# owner's rollout order; the WORLD switch (Owner Admin) adds every other
# country file the monthly job produced.
ROLLOUT = ("BD", "SA", "AE", "MY", "QA", "OM", "KW", "SG", "IT", "GB", "US")
WORLD_KEY = "WORLD"
META_KEY = "_meta"
ATTRIBUTION = "© OpenStreetMap contributors (ODbL)"
COPYRIGHT_URL = "https://www.openstreetmap.org/copyright"
FIELDS = ["id", "cat", "name", "name_en", "lat", "lon", "phone", "src"]
MAX_ROWS = 6000            # densest 3-degree areas (e.g. big US cities)
CHECK_EVERY_S = 6 * 3600   # manifest check interval
MAX_FILE_BYTES = 40 * 1024 * 1024
_UA = "AssistoNearbyImport/1.0 (+https://lifeassisto.com)"
DEFAULT_BASE = "https://github.com/ArifSarkar247/assisto/releases/download/nearby-data/"


def data_base():
    return getattr(settings, "NEARBY_DATA_BASE", "") or DEFAULT_BASE


def haversine_m(a, b, c, d):
    r = 6371000.0
    p1, p2 = math.radians(a), math.radians(c)
    dp, dl = math.radians(c - a), math.radians(d - b)
    x = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return r * 2 * math.asin(min(1.0, math.sqrt(x)))


# ---------------------------------------------------------------- effective
def eff(p):
    """The values users see: owner override first, else the source."""
    return {
        "name": p.o_name or p.name,
        "name_en": p.o_name_en or p.name_en,
        "phone": p.o_phone or p.phone,
        "lat": p.o_lat if p.o_lat is not None else p.lat,
        "lon": p.o_lon if p.o_lon is not None else p.lon,
    }


def row(p):
    e = eff(p)
    return [p.id, p.category, e["name"], e["name_en"], round(e["lat"], 6),
            round(e["lon"], 6), e["phone"], p.source]


def overridden(p):
    return bool(p.o_name or p.o_name_en or p.o_phone or p.o_lat is not None
                or p.o_lon is not None or p.hidden or p.edited_at)


# ---------------------------------------------------------------- datasets
def _ds(key):
    from .models import NearbyDataset
    return NearbyDataset.objects.get_or_create(key=key)[0]


def world_on():
    from .models import NearbyDataset
    return NearbyDataset.objects.filter(key=WORLD_KEY, enabled=True).exists()


def disabled_countries():
    from .models import NearbyDataset
    return set(NearbyDataset.objects.filter(enabled=False).exclude(key=WORLD_KEY)
               .values_list("key", flat=True))


def country_allowed(cc, world=None, off=None):
    off = disabled_countries() if off is None else off
    if cc in off:
        return False
    if cc in ROLLOUT:
        return True
    return world_on() if world is None else world


def bump(country):
    """A change in `country` reaches every phone on its next open."""
    from .models import NearbyDataset
    ds = _ds(country)
    NearbyDataset.objects.filter(pk=ds.pk).update(version=F("version") + 1)


def versions(countries):
    from .models import NearbyDataset
    got = dict(NearbyDataset.objects.filter(key__in=list(countries))
               .values_list("key", "version"))
    return ",".join("%s:%d" % (c, got.get(c, 1)) for c in sorted(countries))


# ---------------------------------------------------------------- the area
def area_key(lat, lon):
    return "%d:%d" % (math.floor(lat), math.floor(lon))


def area_box(lat, lon):
    t, g = math.floor(lat), math.floor(lon)
    return (t - 1, t + 2, g - 1, g + 2)


def _in_box(lat0, lat1, lon0, lon1):
    return (Q(lat__gte=lat0, lat__lt=lat1, lon__gte=lon0, lon__lt=lon1)
            | Q(o_lat__gte=lat0, o_lat__lt=lat1, o_lon__gte=lon0, o_lon__lt=lon1))


def area(lat, lon, have=""):
    """The emergency list for the 3x3-degree area around (lat, lon).

    Returns the compact rows (FIELDS) for the phone to cache and sort, the
    area's version token, the data-based country (nearest place's country —
    our own reverse lookup, never paid geocoding) and the attribution.
    `have` = the token the phone already caches -> {"unchanged": True}."""
    from .models import NearbyPlace
    lat0, lat1, lon0, lon1 = area_box(lat, lon)
    off = disabled_countries()
    world = world_on()
    qs = (NearbyPlace.objects.filter(category__in=EMERGENCY, hidden=False)
          .filter(_in_box(lat0, lat1, lon0, lon1))
          .exclude(source="biz"))
    countries = set(qs.values_list("country", flat=True).distinct())
    countries = {c for c in countries if country_allowed(c, world, off)}
    token = versions(countries) if countries else "empty"
    base = {"area": {"key": area_key(lat, lon), "lat0": lat0, "lat1": lat1,
                     "lon0": lon0, "lon1": lon1},
            "version": token, "attribution": ATTRIBUTION, "copyright_url": COPYRIGHT_URL}
    if have and have == token:
        return dict(base, unchanged=True)
    rows = []
    for p in qs.filter(country__in=countries).only(
            "id", "category", "name", "name_en", "phone", "lat", "lon", "o_name",
            "o_name_en", "o_phone", "o_lat", "o_lon", "source", "country", "refreshed_at"):
        r = row(p)
        rows.append((haversine_m(lat, lon, r[4], r[5]), r, p.country, p.refreshed_at))
    rows.sort(key=lambda x: x[0])
    rows = rows[:MAX_ROWS]
    near_cc = rows[0][2] if rows and rows[0][0] <= 60000 else ""
    refreshed = max((x[3] for x in rows if x[3]), default=None)
    return dict(base, unchanged=False, country=near_cc, countries=sorted(countries),
                fields=FIELDS, rows=[x[1] for x in rows],
                refreshed_at=refreshed.isoformat() if refreshed else None)


def country_at(lat, lon):
    """Our own GPS -> country: the nearest listed place within ~60 km."""
    from .models import NearbyPlace
    d = 0.6
    best = None
    for c, la, lo in (NearbyPlace.objects
                      .filter(lat__gte=lat - d, lat__lte=lat + d, lon__gte=lon - d,
                              lon__lte=lon + d, category__in=EMERGENCY)
                      .values_list("country", "lat", "lon")[:3000]):
        m = haversine_m(lat, lon, la, lo)
        if m <= 60000 and (best is None or m < best[0]):
            best = (m, c)
    return best[1] if best else ""


# ---------------------------------------------------------------- sponsored
def sponsored(lat, lon, cat, limit=3):
    """Assisto business listings with a live Sponsored placement for a
    GENERAL category (never emergency), nearest first, within ~10 km."""
    from .models import NearbyPlace
    if cat not in GENERAL:
        return []
    d = 0.1
    now = timezone.now()
    out = []
    for p in (NearbyPlace.objects.filter(source="biz", category=cat, hidden=False,
                                         sponsored_until__gt=now)
              .filter(_in_box(lat - d, lat + d, lon - d, lon + d))[:200]):
        e = eff(p)
        m = haversine_m(lat, lon, e["lat"], e["lon"])
        if m <= 12000:
            out.append({"id": p.id, "name": e["name_en"] or e["name"], "name_local": e["name"],
                        "phone": e["phone"], "lat": e["lat"], "lon": e["lon"],
                        "distance_m": int(m), "sponsored": True})
    out.sort(key=lambda x: x["distance_m"])
    return out[:limit]


# ---------------------------------------------------------------- reports
REPORTS_PER_DAY = 10


def report(user, place_id, kind="wrong_number", phone="", note=""):
    """-> (report or None, error code or "")."""
    from .models import NearbyPlace, NearbyReport
    kind = kind if kind in NearbyReport.KINDS else "other"
    p = NearbyPlace.objects.filter(pk=place_id).first()
    if p is None:
        return None, "not_found"
    day = timezone.now() - timedelta(days=1)
    if NearbyReport.objects.filter(user=user, created_at__gte=day).count() >= REPORTS_PER_DAY:
        return None, "limit"
    dup = NearbyReport.objects.filter(user=user, place=p, status="open").first()
    phone = clean_phone(phone)
    note = " ".join(str(note or "").split())[:300]
    if dup:
        dup.kind, dup.suggested_phone, dup.note = kind, phone or dup.suggested_phone, note or dup.note
        dup.save(update_fields=["kind", "suggested_phone", "note"])
        return dup, ""
    return NearbyReport.objects.create(place=p, user=user, kind=kind,
                                       suggested_phone=phone, note=note), ""


def clean_phone(v):
    s = "".join(ch for ch in str(v or "") if ch.isdigit() or ch in "+ -()")
    s = " ".join(s.split())[:40]
    return s if sum(ch.isdigit() for ch in s) >= 3 else ""


# ---------------------------------------------------------------- owner edits
def _touch(p, by):
    p.edited_at = timezone.now()
    p.edited_by = by


def admin_edit(p, data, by):
    """Owner edit -> override columns (source columns untouched)."""
    cat = data.get("category")
    allowed = GENERAL if p.source == "biz" else EMERGENCY
    if cat and cat in allowed:
        p.category = cat
    for f in ("name", "name_en"):
        if f in data:
            v = " ".join(str(data[f] or "").split())[:160]
            src = getattr(p, f)
            setattr(p, "o_" + f, "" if v == src else v)
    if "phone" in data:
        v = clean_phone(data["phone"]) if str(data["phone"] or "").strip() else ""
        p.o_phone = "" if v == p.phone else v
    for f in ("lat", "lon"):
        if str(data.get(f, "")).strip():
            try:
                v = float(data[f])
            except (TypeError, ValueError):
                return "bad_" + f
            lim = 90 if f == "lat" else 180
            if not -lim <= v <= lim:
                return "bad_" + f
            setattr(p, "o_" + f, None if abs(v - getattr(p, f)) < 1e-7 else v)
    _touch(p, by)
    p.save()
    bump(p.country)
    return ""


def admin_add(data, by):
    """A place the owner adds (source 'admin'); or a business listing
    (source 'biz', category GENERAL, needs a BusinessProfile)."""
    from .models import BusinessProfile, NearbyPlace
    cat = data.get("category") or ""
    biz = None
    if data.get("business_user"):
        biz = BusinessProfile.objects.filter(user_id=data.get("business_user")).first()
        if biz is None or cat not in GENERAL:
            return None, "bad_business"
    elif cat not in EMERGENCY:
        return None, "bad_category"
    try:
        lat, lon = float(data.get("lat")), float(data.get("lon"))
    except (TypeError, ValueError):
        return None, "bad_lat"
    if not (-90 <= lat <= 90 and -180 <= lon <= 180):
        return None, "bad_lat"
    cc = str(data.get("country") or "").strip().upper()[:2] or country_at(lat, lon)
    if len(cc) != 2 or not cc.isalpha():
        return None, "bad_country"
    name = " ".join(str(data.get("name") or "").split())[:160]
    if not name:
        return None, "bad_name"
    p = NearbyPlace(country=cc, category=cat, source="biz" if biz else "admin", lat=lat,
                    lon=lon, name=name,
                    name_en=" ".join(str(data.get("name_en") or "").split())[:160],
                    phone=clean_phone(data.get("phone")), business=biz,
                    refreshed_at=timezone.now())
    if biz is not None:
        try:
            days = max(0, min(366, int(data.get("sponsored_days") or 0)))
        except (TypeError, ValueError):
            days = 0
        p.sponsored_until = timezone.now() + timedelta(days=days) if days else None
    _touch(p, by)
    p.save()
    bump(cc)
    return p, ""


def admin_hide(p, hidden, by):
    p.hidden = bool(hidden)
    _touch(p, by)
    p.save(update_fields=["hidden", "edited_at", "edited_by"])
    bump(p.country)


def admin_reset(p, by):
    """Drop every override: the source values show again."""
    p.o_name = p.o_name_en = p.o_phone = ""
    p.o_lat = p.o_lon = None
    p.hidden = False
    p.edited_at = None
    p.edited_by = by
    p.save()
    bump(p.country)


def resolve_report(r, action, phone, by):
    """fix (optionally with the corrected phone) | hide (place) | reject."""
    if action not in ("fix", "hide", "reject"):
        return "invalid"
    if action == "fix":
        ph = clean_phone(phone or r.suggested_phone)
        if ph:
            admin_edit(r.place, {"phone": ph}, by)
    elif action == "hide":
        admin_hide(r.place, True, by)
    r.status = "rejected" if action == "reject" else "fixed"
    r.resolved_at = timezone.now()
    r.save(update_fields=["status", "resolved_at"])
    return ""


# ---------------------------------------------------------------- import
def _fetch(url, limit=MAX_FILE_BYTES, timeout=30):
    if sys.argv[1:2] == ["test"]:
        # the test suite never reaches the network (tests patch _fetch)
        raise OSError("no network in tests")
    req = urllib.request.Request(url, headers={"User-Agent": _UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = r.read(limit + 1)
    if len(data) > limit:
        raise ValueError("file too large")
    return data


def parse_file(blob, cc):
    doc = json.loads(gzip.decompress(blob).decode("utf-8"))
    if str(doc.get("country") or "").upper() != cc:
        raise ValueError("country mismatch")
    fields = doc.get("fields") or []
    if fields[:7] != ["id", "cat", "name", "name_en", "lat", "lon", "phone"]:
        raise ValueError("unknown fields")
    return doc


def _clean_row(r):
    try:
        sid, cat, name, name_en, lat, lon, phone = r[:7]
        lat, lon = float(lat), float(lon)
    except (TypeError, ValueError):
        return None
    sid = str(sid)[:24]
    if cat not in EMERGENCY or not sid or not (-90 <= lat <= 90 and -180 <= lon <= 180):
        return None
    return (sid, cat, str(name or "")[:160], str(name_en or "")[:160], round(lat, 6),
            round(lon, 6), clean_phone(phone)[:40])


def import_rows(cc, rows, meta=None, force=False):
    """Upsert one country's OSM rows. Owner overrides are never touched; a
    place that left OSM is deleted unless the owner edited/hid it or it has
    an open report (then it is kept and marked gone_upstream)."""
    from .models import NearbyDataset, NearbyPlace, NearbyReport
    meta = meta or {}
    now = timezone.now()
    clean = {}
    for r in rows:
        c = _clean_row(r)
        if c:
            clean[c[0]] = c
    current = NearbyPlace.objects.filter(country=cc, source="osm").count()
    if not force and current > 1000 and len(clean) < current // 2:
        raise ValueError("refusing: %d rows vs %d listed (truncated file?)" % (len(clean), current))
    existing = {}
    for t in (NearbyPlace.objects.filter(country=cc, source="osm")
              .values_list("src_id", "id", "category", "name", "name_en", "lat", "lon",
                           "phone", "gone_upstream").iterator(chunk_size=5000)):
        existing[t[0]] = t
    create, update = [], []
    for sid, c in clean.items():
        ex = existing.get(sid)
        if ex is None:
            create.append(NearbyPlace(country=cc, category=c[1], source="osm", src_id=sid,
                                      name=c[2], name_en=c[3], lat=c[4], lon=c[5],
                                      phone=c[6], refreshed_at=now))
        elif (ex[2], ex[3], ex[4], round(ex[5], 6), round(ex[6], 6), ex[7]) != c[1:] or ex[8]:
            update.append(NearbyPlace(id=ex[1], category=c[1], name=c[2], name_en=c[3],
                                      lat=c[4], lon=c[5], phone=c[6], refreshed_at=now,
                                      gone_upstream=False))
    gone = [existing[s][1] for s in existing if s not in clean]
    with transaction.atomic():
        NearbyPlace.objects.bulk_create(create, batch_size=2000)
        NearbyPlace.objects.bulk_update(
            update, ["category", "name", "name_en", "lat", "lon", "phone", "refreshed_at",
                     "gone_upstream"], batch_size=2000)
        kept = deleted = 0
        for i in range(0, len(gone), 1000):
            chunk = gone[i:i + 1000]
            keep_ids = set(NearbyPlace.objects.filter(id__in=chunk).filter(
                Q(edited_at__isnull=False) | Q(hidden=True)).values_list("id", flat=True))
            keep_ids |= set(NearbyReport.objects.filter(place_id__in=chunk, status="open")
                            .values_list("place_id", flat=True))
            NearbyPlace.objects.filter(id__in=keep_ids).update(gone_upstream=True)
            kept += len(keep_ids)
            deleted += NearbyPlace.objects.filter(id__in=[x for x in chunk if x not in keep_ids]
                                                  ).delete()[0]
        (NearbyPlace.objects.filter(country=cc, source="osm", gone_upstream=False)
         .update(refreshed_at=now))
        ds = _ds(cc)
        NearbyDataset.objects.filter(pk=ds.pk).update(
            version=F("version") + 1, refreshed_at=now, last_error="",
            records=NearbyPlace.objects.filter(country=cc, hidden=False).count(),
            bytes=int(meta.get("bytes") or 0), sha256=str(meta.get("sha256") or "")[:64],
            osm_timestamp=str(meta.get("osm_timestamp") or "")[:40])
    return {"country": cc, "rows": len(clean), "created": len(create),
            "updated": len(update), "deleted": deleted, "kept_overridden": kept}


def import_blob(cc, blob, meta=None, force=False):
    meta = dict(meta or {})
    sha = hashlib.sha256(blob).hexdigest()
    if meta.get("sha256") and meta["sha256"] != sha:
        raise ValueError("sha256 mismatch")
    meta.setdefault("sha256", sha)
    meta.setdefault("bytes", len(blob))
    doc = parse_file(blob, cc)
    meta.setdefault("osm_timestamp", doc.get("osm_timestamp") or "")
    return import_rows(cc, doc.get("rows") or [], meta, force=force)


def pending(manifest):
    """Countries whose published file differs from what we imported, in the
    owner's rollout order (then the world, when switched on)."""
    from .models import NearbyDataset
    have = dict(NearbyDataset.objects.values_list("key", "sha256"))
    off = disabled_countries()
    world = world_on()
    cs = manifest.get("countries") or {}
    order = [c for c in ROLLOUT if c in cs] + sorted(c for c in cs if c not in ROLLOUT)
    failed = dict(NearbyDataset.objects.exclude(last_error="").values_list("key", "last_error"))
    return [c for c in order
            if country_allowed(c, world, off) and cs[c].get("sha256")
            and have.get(c) != cs[c]["sha256"]
            # a file that failed once is not retried until a new one is published
            and not failed.get(c, "").startswith("sha:%s" % cs[c]["sha256"][:12])]


def tick(force_check=False, only=None, now=None):
    """One minute_jobs step: at most one manifest check per CHECK_EVERY_S and
    at most ONE country imported per call (spreads the monthly load).
    -> short status string."""
    from .models import NearbyDataset
    now = now or timezone.now()
    meta = _ds(META_KEY)
    if (not force_check and not only and meta.last_check_at
            and (now - meta.last_check_at).total_seconds() < CHECK_EVERY_S):
        return "idle"
    try:
        manifest = json.loads(_fetch(data_base() + "manifest.json", limit=2 * 1024 * 1024)
                              .decode("utf-8"))
    except Exception as e:  # network / GitHub down: retry next interval
        NearbyDataset.objects.filter(pk=meta.pk).update(
            last_check_at=now, last_error=("manifest: %s" % e)[:300])
        return "manifest_error"
    todo = [only] if only else pending(manifest)
    if not todo:
        NearbyDataset.objects.filter(pk=meta.pk).update(last_check_at=now, last_error="")
        return "up_to_date"
    cc = todo[0]
    m = (manifest.get("countries") or {}).get(cc)
    if not m:
        return "not_in_manifest"
    try:
        blob = _fetch(data_base() + m["file"])
        res = import_blob(cc, blob, m)
    except Exception as e:
        ds = _ds(cc)
        NearbyDataset.objects.filter(pk=ds.pk).update(
            last_error=("sha:%s %s" % (str(m.get("sha256") or "")[:12], e))[:300])
        if len(todo) <= 1:
            NearbyDataset.objects.filter(pk=meta.pk).update(last_check_at=now)
        return "error %s" % cc
    if len(todo) <= 1:
        NearbyDataset.objects.filter(pk=meta.pk).update(last_check_at=now, last_error="")
    return "imported %s %s" % (cc, json.dumps(res))
