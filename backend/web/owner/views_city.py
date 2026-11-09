"""citydata (owner 9 Nov 11:45): Owner Admin -> City data.

Tabs: Corrections (users' one-tap fixes: accept with a change, or reject),
Live reports (active ones; hide), Data (per city: version, counts, coverage %,
top-50 trip result, gaps, import errors, on/off, check now), Coverage (stops
and routes per ~2 km area of the city, empty areas first), Fares (every rate
with its checked date; the BRTA complaint number), Learned (trip learning
findings). Every change bumps the city's version (phones refresh their offline
package) and goes to the owner audit log."""
import json
import math
from collections import defaultdict

from django.utils import timezone
from django.views.decorators.http import require_http_methods

from . import security as S
from .base import done, owner_view, page, to_int

TABS = ("fixes", "live", "data", "coverage", "fares", "learned", "stops")
_PAGE = 50


def _coverage(city):
    from core import city_service as CS
    got = CS.network(city)
    if got is None:
        return []
    nw = got[0]
    bb = CS.CITIES[city]["bbox"]
    step = 0.018            # ~2 km
    cells = defaultdict(lambda: {"stops": 0, "routes": set(), "names": defaultdict(int)})
    for i, s in enumerate(nw.stops):
        if s["hidden"] or not nw.stop_routes[i]:
            continue
        k = (int((s["lat"] - bb[0]) // step), int((s["lon"] - bb[1]) // step))
        c = cells[k]
        c["stops"] += 1
        c["routes"] |= {ri for ri, _ in nw.stop_routes[i]}
        if s["name"]:
            c["names"][s["name"]] += 1
    rows = []
    ny = int(math.ceil((bb[2] - bb[0]) / step))
    nx = int(math.ceil((bb[3] - bb[1]) / step))
    for y in range(ny):
        for x in range(nx):
            c = cells.get((y, x))
            lat, lon = bb[0] + (y + 0.5) * step, bb[1] + (x + 0.5) * step
            name = max(c["names"].items(), key=lambda kv: kv[1])[0] if c and c["names"] else ""
            rows.append({"lat": round(lat, 3), "lon": round(lon, 3), "name": name,
                         "stops": c["stops"] if c else 0, "routes": len(c["routes"]) if c else 0})
    rows.sort(key=lambda r: (r["stops"] > 0, r["routes"], r["stops"]))
    return rows


@require_http_methods(["GET"])
@owner_view()
def city(request):
    from core import city_service as CS
    from core.citytransit import fares as F
    from core.models import CityCorrection, CityDataset, CityLearned, CityLiveReport
    tab = request.GET.get("tab") or "fixes"
    tab = tab if tab in TABS else "fixes"
    cty = request.GET.get("city") or "dhaka"
    cty = cty if cty in CS.CITIES else "dhaka"
    pg = max(1, to_int(request.GET.get("page"), 1) or 1)
    ctx = {"tab": tab, "city": cty, "cities": list(CS.CITIES), "page_no": pg,
           "attribution": CS.ATTRIBUTION, "actions": CS.PATCH_ACTIONS}
    now = timezone.now()
    if tab == "fixes":
        st = request.GET.get("st") or "open"
        qs = CityCorrection.objects.all()
        if st != "all":
            qs = qs.filter(status="open")
        ctx["total"] = qs.count()
        ctx["fixes"] = list(qs[(pg - 1) * _PAGE: pg * _PAGE])
        ctx["has_next"] = pg * _PAGE < ctx["total"]
        ctx["st"] = st
    elif tab == "live":
        ctx["live"] = list(CityLiveReport.objects.filter(expires_at__gt=now).order_by("-last_at")[:200])
        for r in ctx["live"]:
            r.ago = int((now - r.last_at).total_seconds() // 60)
    elif tab == "data":
        ds = list(CityDataset.objects.exclude(city="_meta").defer("blob", "dir_blob").order_by("city"))
        for d in ds:
            d.rep = d.report or {}
            d.top = (d.rep.get("top50") or {})
            d.fails = [t for t in d.top.get("trips", []) if not t.get("pass")][:50]
            d.gaps = d.rep.get("gap_counts") or {}
        ctx["datasets"] = ds
        ctx["meta"] = CityDataset.objects.filter(city="_meta").defer("blob", "dir_blob").first()
        ctx["missing"] = [c for c in CS.CITIES if c not in {d.city for d in ds}]
        for d in ds:     # citycov: coverage as phones see it now (users' stops included)
            try:
                d.live_cov = CS.live_coverage(d.city) if d.enabled and d.version else None
            except Exception:
                d.live_cov = None
    elif tab == "coverage":
        rows = _coverage(cty)
        ctx["cells"] = rows[:300]
        ctx["cells_total"] = len(rows)
        ctx["cells_empty"] = sum(1 for r in rows if not r["stops"])
    elif tab == "fares":
        d = CityDataset.objects.filter(city=cty).defer("blob", "dir_blob").first()
        ov = (d.overrides or {}) if d else {}
        R = F.rates(ov.get("rates"))
        ctx["rates"] = [{"mode": k, "label": v.get("label"), "checked": v.get("checked"),
                         "source": v.get("source"), "source_url": v.get("source_url"),
                         "values": [(kk, vv) for kk, vv in v.items()
                                    if isinstance(vv, (int, float)) and not isinstance(vv, bool)]}
                        for k, v in R.items()]
        ctx["complaint"] = CS.complaint(ov)
        ctx["has_ds"] = d is not None
    elif tab == "stops":
        ctx.update(_user_stops(cty, request.GET.get("st") or "reported"))
    else:
        st = request.GET.get("st") or "confirmed"
        qs = CityLearned.objects.filter(city=cty)
        if st in ("reported", "confirmed", "rejected"):
            qs = qs.filter(status=st)
        ctx["learned"] = list(qs.order_by("-updated_at")[:200])
        for l in ctx["learned"]:
            l.n = len(l.anons or [])
            l.short = json.dumps(l.data, ensure_ascii=False)[:160]
        ctx["st"] = st
    ctx["tiles"] = [
        ("fixes", CityCorrection.objects.filter(status="open").count()),
        ("live", CityLiveReport.objects.filter(expires_at__gt=now, hidden=False).count()),
        ("data", CityDataset.objects.exclude(city="_meta").exclude(version="").count()),
        ("learned", CityLearned.objects.filter(status="confirmed").count()),
        ("stops", CityLearned.objects.filter(kind="field", status="reported").count()),
    ]
    return page(request, "owner/city.html", ctx, nav="city")


def _user_stops(city, st):
    """citycov: field reports + trip-learned stops, newest first."""
    from core import city_service as CS
    from core.models import CityLearned
    st = st if st in ("reported", "confirmed", "rejected") else "reported"
    got = CS.network(city)
    names = {r["id"]: (r.get("name") or r.get("ref") or r["id"]) for r in got[0].routes} if got else {}
    rows = []
    for l in (CityLearned.objects.filter(city=city, kind__in=("field", "stop"), status=st)
              .order_by("-updated_at")[:200]):
        d = l.data or {}
        if d.get("lat") is None:
            continue
        rows.append({"id": l.id, "src": l.kind, "lat": round(float(d["lat"]), 6),
                     "lon": round(float(d["lon"]), 6), "people": len(l.anons or []),
                     "trips": len(set(d.get("tids") or [])) if l.kind == "stop" else l.trips,
                     "route": names.get(d.get("route") or "", d.get("route") or ""),
                     "stop": d.get("stop") or "", "updated": l.updated_at})
    return {"ustops": rows, "st": st, "need": CS.FIELD_CONFIRM}


def _patch(request):
    p = {k: request.POST.get(k, "").strip() for k in ("action", "id", "name", "name_bn", "lat",
                                                       "lon", "hw", "spd", "ref", "side", "number")}
    p = {k: v for k, v in p.items() if v != ""}
    return p


@require_http_methods(["POST"])
@owner_view()
def city_fix(request, pk):
    from core import city_service as CS
    from core.models import CityCorrection
    c = CityCorrection.objects.filter(pk=pk).first()
    if c is None:
        return done("/owner/city?tab=fixes", "invalid")
    action = request.POST.get("decision") or ""
    patch = _patch(request) if request.POST.get("action") else None
    err = CS.resolve_correction(c, action, patch)
    S.audit(request, request.owner, "city_fix." + action, "city_fix:%s" % c.pk,
            after={"patch": patch or {}, "error": err}, ok=not err)
    return done("/owner/city?tab=fixes", "invalid" if err else "saved")


@require_http_methods(["POST"])
@owner_view()
def city_change(request):
    """Direct owner change (no user report needed): same patch actions."""
    from core import city_service as CS
    city = request.POST.get("city") or "dhaka"
    back = request.POST.get("back") or "/owner/city?tab=fares"
    if not back.startswith("/owner/city"):
        back = "/owner/city"
    if city not in CS.CITIES:
        return done(back, "invalid")
    p = _patch(request)
    if p.get("action") == "rate":
        p["mode"] = request.POST.get("mode") or ""
        vals = {}
        for k, v in request.POST.items():
            if k.startswith("v_") and v.strip():
                try:
                    vals[k[2:]] = float(v)
                except ValueError:
                    return done(back, "invalid")
        p["values"] = vals
        p["checked"] = request.POST.get("checked") or ""
    err = CS.apply_patch(city, p)
    S.audit(request, request.owner, "city_change." + str(p.get("action")), "city:%s" % city,
            after=dict(p, error=err), ok=not err)
    return done(back, "invalid" if err else "saved")


@require_http_methods(["POST"])
@owner_view()
def city_live(request, pk):
    from core.models import CityLiveReport
    r = CityLiveReport.objects.filter(pk=pk).first()
    if r is None:
        return done("/owner/city?tab=live", "invalid")
    hide = request.POST.get("action") != "show"
    r.hidden = hide
    r.save(update_fields=["hidden"])
    S.audit(request, request.owner, "city_live." + ("hide" if hide else "show"), "city_live:%s" % pk)
    return done("/owner/city?tab=live", "saved")


@require_http_methods(["POST"])
@owner_view()
def city_dataset(request):
    from core import city_service as CS
    from core.models import CityDataset
    city = request.POST.get("city") or ""
    action = request.POST.get("action") or ""
    if action == "check":
        res = CS.import_tick(force=True)
        S.audit(request, request.owner, "city_dataset.check", "city:*", after={"result": res})
        return done("/owner/city?tab=data", "saved")
    if city not in CS.CITIES or action not in ("on", "off"):
        return done("/owner/city?tab=data", "invalid")
    CityDataset.objects.filter(city=city).update(enabled=action == "on")
    CS._NET.pop(city, None)
    CS._PKG.pop(city, None)
    S.audit(request, request.owner, "city_dataset." + action, "city:%s" % city)
    return done("/owner/city?tab=data", "saved")


@require_http_methods(["POST"])
@owner_view()
def city_learned(request, pk):
    from core.models import CityLearned
    l = CityLearned.objects.filter(pk=pk).first()
    action = request.POST.get("action") or ""
    if l is None or action not in ("confirm", "reject"):
        return done("/owner/city?tab=learned", "invalid")
    l.status = "confirmed" if action == "confirm" else "rejected"
    l.save(update_fields=["status"])
    S.audit(request, request.owner, "city_learned." + action, "city_learned:%s" % pk)
    if l.kind in ("field", "stop"):     # citycov: users' stops change the network at once
        from core import city_service as CS
        try:
            CS.learned_to_overrides(l.city)
        except Exception:
            pass
        back = request.POST.get("back") or ""
        if back.startswith("/owner/city"):
            return done(back, "saved")
    return done("/owner/city?tab=learned", "saved")
