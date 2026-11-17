"""adcontrol (OWNER FINAL ORDER ADS, 10 Nov 03:45, part B): Owner Admin ->
Ad control. Every ad placement of the app (core.logic.ad_control registry),
grouped by feature: on/off + ad type (only the types that fit), applied LIVE
(the app re-reads /ads/config on start and resume — no new build), per
placement impressions, eCPM and income per day (Google's onPaidEvent values
when there are any, else an ESTIMATE from the owner's eCPM guess, always
labelled). Global caps: interstitial gap (>= 3 min) + daily cap.

Turning an emergency / safety / trust placement ON first shows a warning
page ("this is an emergency or safety screen, are you sure?"); only the
confirmed second POST saves it. Every save -> OwnerAudit before/after."""
from datetime import timedelta

from django.utils import timezone
from django.views.decorators.http import require_http_methods

from . import security as S
from .base import diff, done, owner_view, page, to_int

_PATH = "/owner/ad-control"


def _stored():
    from core import billing
    return (billing.get_config().data or {}).get("ad_control") or {}


def _save(new):
    from core import billing
    row = billing.get_config()
    data = dict(row.data or {})
    data["ad_control"] = new
    row.data = data
    row.save()


def _stats(stored, days):
    from django.db.models import Sum
    from core.logic import ad_control as AC
    from core.models import AdPlacementStat
    today = timezone.localdate()
    dates = [(today - timedelta(days=i)).isoformat() for i in range(days)]
    # ads-guard: real ads only — Google TEST-ad events are never income
    rows = (AdPlacementStat.objects.filter(date__gte=today - timedelta(days=days - 1),
                                           test=False)
            .values("date", "placement", "currency")
            .annotate(impressions=Sum("impressions"), paid_events=Sum("paid_events"),
                      revenue_micros=Sum("revenue_micros")))
    return AC.report([dict(r, date=r["date"].isoformat()) for r in rows], stored, dates), dates


def _form_changes(post, eff):
    """[(key, on, type)] the form asks for (only real differences)."""
    from core.logic import ad_control as AC
    out = []
    for p in AC.PLACEMENTS:
        k = p["key"]
        if ("t_" + k) not in post and ("seen_" + k) not in post:
            continue
        on = post.get("on_" + k) == "1"
        typ = post.get("t_" + k) or eff["placements"][k]["type"]
        if on != eff["placements"][k]["on"] or typ != eff["placements"][k]["type"]:
            out.append((k, on, typ))
    return out


@require_http_methods(["GET", "POST"])
@owner_view()
def ad_control(request):
    from core.logic import ad_control as AC
    lang = getattr(request, "owner_lang", "bn")
    stored = _stored()
    eff = AC.normalize(stored)
    warn = []
    if request.method == "POST":
        if request.POST.get("what") == "caps":
            new = AC.normalize(stored)
            for k, (lo, hi) in AC.CAP_BOUNDS.items():
                v = to_int(request.POST.get(k))
                if v is not None:
                    new["caps"][k] = max(lo, min(hi, v))
            for t in AC.TYPES:
                try:
                    v = float(request.POST.get("ecpm_" + t, ""))
                    new["ecpm_estimate"][t] = max(AC.ECPM_BOUNDS[0], min(AC.ECPM_BOUNDS[1], v))
                except ValueError:
                    pass
            new = AC.normalize(new)
            b, a = diff(eff, new)
            _save(new)
            S.audit(request, request.owner, "ad_control_caps", "ads", before=b, after=a)
            return done(_PATH)
        confirmed = set(request.POST.getlist("confirm_safety"))
        new = AC.normalize(stored)
        for k, on, typ in _form_changes(request.POST, eff):
            res, why = AC.apply_change(new, k, on=on, typ=typ, confirm_safety=k in confirmed)
            if why == "needs_safety_confirm":
                warn.append(AC.BY_KEY[k])
                res, _ = AC.apply_change(new, k, typ=typ)
            if res is not None:
                new = res
        if warn:
            # nothing is saved until the owner confirms every safety row
            return page(request, "owner/ad_control_confirm.html", {
                "warn": [{"key": p["key"], "label": p["bn"] if lang == "bn" else p["en"]}
                         for p in warn],
                "post": [(k, v) for k in request.POST for v in request.POST.getlist(k)
                         if k not in ("_ot", "csrfmiddlewaretoken", "confirm_safety")],
            }, nav="ad_control")
        b, a = diff(eff, new)
        if a:
            _save(new)
            S.audit(request, request.owner, "ad_control_placements", "ads", before=b, after=a)
        return done(_PATH)
    days = to_int(request.GET.get("days"), 7)
    days = days if days in (1, 7, 14, 30) else 7
    rep, dates = _stats(stored, days)
    groups = []
    for gid, gbn, gen in AC.GROUPS:
        rows = []
        for p in AC.PLACEMENTS:
            if p["group"] != gid:
                continue
            st = eff["placements"][p["key"]]
            r = rep[p["key"]]
            rows.append({"key": p["key"], "label": p["bn"] if lang == "bn" else p["en"],
                         "rule": p["rule"], "safety": p["safety"], "on": st["on"],
                         "type": st["type"], "allowed": p["allowed"],
                         "default": "%s / %s" % ("ON" if p["on"] else "OFF", p["type"]),
                         "rep": r})
        groups.append({"id": gid, "title": gbn if lang == "bn" else gen, "rows": rows})
    n_on = sum(1 for v in eff["placements"].values() if v["on"])
    return page(request, "owner/ad_control.html", {
        "groups": groups, "caps": eff["caps"], "ecpm": eff["ecpm_estimate"],
        "cap_bounds": AC.CAP_BOUNDS, "types": AC.TYPES, "days": days, "dates": dates,
        "day_options": (1, 7, 14, 30), "n_on": n_on, "n": len(AC.PLACEMENTS),
        "blocked": AC.BLOCKED_CATEGORIES, "rating": AC.MAX_AD_CONTENT_RATING,
    }, nav="ad_control")


@require_http_methods(["GET"])
@owner_view()
def ad_control_detail(request, key):
    """One placement: impressions, eCPM and income for each of the last 30 days."""
    from django.http import Http404
    from core.logic import ad_control as AC
    p = AC.BY_KEY.get(key)
    if p is None:
        raise Http404
    lang = getattr(request, "owner_lang", "bn")
    rep, _ = _stats(_stored(), 30)
    return page(request, "owner/ad_control_detail.html", {
        "p": p, "label": p["bn"] if lang == "bn" else p["en"], "rep": rep[key],
    }, nav="ad_control")
