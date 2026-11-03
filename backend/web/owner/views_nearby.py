"""nearby (owner 3 Nov 18:50): Owner Admin -> Nearby list.

Search / add / edit / hide any place of Assisto's own emergency list; edits
are overrides (o_* columns + hidden) so the monthly OpenStreetMap refresh
never undoes them; every change bumps the country's version, so every phone
re-pulls its area on the next open. The app's "Report wrong number" lands in
the review queue here. Every record shows its source and last refresh.
Datasets: records / version / last refresh per country + the WORLD switch.
Every action goes to the owner audit log."""
from django.db.models import Q
from django.http import Http404
from django.views.decorators.http import require_http_methods

from . import security as S
from .base import done, owner_view, page, to_int

_PAGE = 50
TABS = ("places", "reports", "datasets")
FILTERS = ("all", "edited", "hidden", "admin", "biz", "gone", "no_phone")


def _snap(p):
    from core import nearby_list as NL
    e = NL.eff(p)
    return {"hidden": p.hidden, "category": p.category, **e}


@require_http_methods(["GET"])
@owner_view()
def nearby(request):
    from core import nearby_list as NL
    from core.models import NearbyDataset, NearbyPlace, NearbyReport
    tab = request.GET.get("tab") or "places"
    tab = tab if tab in TABS else "places"
    pg = max(1, to_int(request.GET.get("page"), 1) or 1)
    q = (request.GET.get("q") or "").strip()[:80]
    cc = (request.GET.get("cc") or "").strip().upper()[:2]
    cat = request.GET.get("cat") or ""
    flt = request.GET.get("f") or "all"
    flt = flt if flt in FILTERS else "all"
    rows, reports, datasets, total = [], [], [], 0
    if tab == "places":
        qs = NearbyPlace.objects.all()
        if q:
            qq = (Q(name__icontains=q) | Q(name_en__icontains=q) | Q(o_name__icontains=q)
                  | Q(o_name_en__icontains=q) | Q(phone__icontains=q) | Q(o_phone__icontains=q)
                  | Q(src_id=q))
            if q.isdigit():
                qq |= Q(pk=int(q))
            qs = qs.filter(qq)
        if cc:
            qs = qs.filter(country=cc)
        if cat in NL.EMERGENCY + NL.GENERAL:
            qs = qs.filter(category=cat)
        if flt == "edited":
            qs = qs.filter(edited_at__isnull=False)
        elif flt == "hidden":
            qs = qs.filter(hidden=True)
        elif flt in ("admin", "biz"):
            qs = qs.filter(source=flt)
        elif flt == "gone":
            qs = qs.filter(gone_upstream=True)
        elif flt == "no_phone":
            qs = qs.filter(phone="", o_phone="")
        total = qs.count()
        rows = list(qs.order_by("country", "category", "name", "id")[(pg - 1) * _PAGE: pg * _PAGE])
        for p in rows:
            p.e = NL.eff(p)
            p.n_open = p.reports.filter(status="open").count()
    elif tab == "reports":
        st = flt if flt in ("all",) else "open"
        qs = NearbyReport.objects.select_related("place")
        if st == "open":
            qs = qs.filter(status="open")
        total = qs.count()
        reports = list(qs.order_by("-id")[(pg - 1) * _PAGE: pg * _PAGE])
        for r in reports:
            r.e = NL.eff(r.place)
    else:
        datasets = list(NearbyDataset.objects.exclude(key__in=(NL.WORLD_KEY, NL.META_KEY))
                        .order_by("key"))
        order = {c: i for i, c in enumerate(NL.ROLLOUT)}
        datasets.sort(key=lambda d: (order.get(d.key, 99), d.key))
        for d in datasets:
            d.rollout = d.key in order
            d.listed = NearbyPlace.objects.filter(country=d.key).count()
    meta = NearbyDataset.objects.filter(key=NL.META_KEY).first()
    tiles = [
        ("reports", NearbyReport.objects.filter(status="open").count()),
        ("places", NearbyPlace.objects.filter(hidden=False).exclude(source="biz").count()),
        ("datasets", NearbyDataset.objects.exclude(key__in=(NL.WORLD_KEY, NL.META_KEY)).count()),
    ]
    return page(request, "owner/nearby.html", {
        "tab": tab, "rows": rows, "reports": reports, "datasets": datasets, "total": total,
        "page_no": pg, "has_next": pg * _PAGE < total, "q": q, "cc": cc, "cat": cat,
        "f": flt, "filters": FILTERS, "cats": NL.EMERGENCY, "gcats": NL.GENERAL,
        "tiles": tiles, "world_on": NL.world_on(), "meta": meta,
        "attribution": NL.ATTRIBUTION, "rollout": NL.ROLLOUT,
    }, nav="nearby")


@require_http_methods(["POST"])
@owner_view()
def nearby_place(request, pk):
    from core import nearby_list as NL
    from core.models import NearbyPlace
    p = NearbyPlace.objects.filter(pk=pk).first()
    if p is None:
        raise Http404
    action = request.POST.get("action") or ""
    back = request.POST.get("back") or "/owner/nearby"
    if not back.startswith("/owner/nearby"):
        back = "/owner/nearby"
    before = _snap(p)
    err = ""
    if action == "save":
        err = NL.admin_edit(p, {k: request.POST.get(k, "") for k in
                                ("name", "name_en", "phone", "lat", "lon", "category")},
                            request.owner)
    elif action in ("hide", "show"):
        NL.admin_hide(p, action == "hide", request.owner)
    elif action == "reset":
        NL.admin_reset(p, request.owner)
    elif action == "sponsor_off" and p.source == "biz":
        p.sponsored_until = None
        p.save(update_fields=["sponsored_until"])
        NL.bump(p.country)
    else:
        return done(back, "invalid")
    p.refresh_from_db()
    S.audit(request, request.owner, "nearby_place." + action, "nearby_place:%s" % p.pk,
            before=before, after=dict(_snap(p), error=err), ok=not err)
    return done(back, "invalid" if err else "saved")


@require_http_methods(["POST"])
@owner_view()
def nearby_add(request):
    from core import nearby_list as NL
    data = {k: request.POST.get(k, "") for k in
            ("name", "name_en", "phone", "lat", "lon", "category", "country",
             "business_user", "sponsored_days")}
    p, err = NL.admin_add(data, request.owner)
    S.audit(request, request.owner, "nearby_place.add",
            "nearby_place:%s" % (p.pk if p else "-"), after=dict(data, error=err), ok=not err)
    return done("/owner/nearby?tab=places&f=%s" % ("biz" if data.get("business_user") else "admin"),
                "invalid" if err else "saved")


@require_http_methods(["POST"])
@owner_view()
def nearby_report(request, pk):
    from core import nearby_list as NL
    from core.models import NearbyReport
    r = NearbyReport.objects.filter(pk=pk).select_related("place").first()
    if r is None:
        raise Http404
    action = request.POST.get("action") or ""
    before = _snap(r.place)
    err = NL.resolve_report(r, action, request.POST.get("phone") or "", request.owner)
    r.place.refresh_from_db()
    S.audit(request, request.owner, "nearby_report." + action, "nearby_report:%s" % r.pk,
            before=before, after=dict(_snap(r.place), status=r.status, error=err), ok=not err)
    return done("/owner/nearby?tab=reports", "invalid" if err else "saved")


@require_http_methods(["POST"])
@owner_view()
def nearby_dataset(request):
    """WORLD switch, or turn one country's list off / on."""
    from core import nearby_list as NL
    from core.models import NearbyDataset
    key = (request.POST.get("key") or "").upper()[:8]
    on = request.POST.get("on") == "1"
    if key != NL.WORLD_KEY and not (len(key) == 2 and key.isalpha()):
        return done("/owner/nearby?tab=datasets", "invalid")
    ds, _ = NearbyDataset.objects.get_or_create(key=key, defaults={"enabled": on})
    before = {"enabled": ds.enabled}
    ds.enabled = on
    ds.save(update_fields=["enabled"])
    if key != NL.WORLD_KEY:
        NL.bump(key)
    S.audit(request, request.owner, "nearby_dataset", "nearby_dataset:%s" % key,
            before=before, after={"enabled": on})
    return done("/owner/nearby?tab=datasets", "saved")
