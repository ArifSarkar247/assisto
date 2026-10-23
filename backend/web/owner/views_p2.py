"""p2-money owner-panel sections.

  Sponsors     brands that buy direct placements (CRUD).
  Campaigns    placement, price (flat / CPM), dates, audience (Free only,
               + interest categories, + optional divisions), pacing, creative
               (image + bn/en copy + link), content-safety checklist + the
               automatic wording/link check, approve / pause / reject, a
               Discover card from a discover campaign, "send offer
               notification" for a brand offer, per-day reports + CSV.
  Ad impact    P&L per placement (direct revenue + AdMob ESTIMATE) and the
               retention / uninstall-proxy comparison between ad-exposure
               buckets, with an honest small-sample warning.
Every change is written to OwnerAudit with before/after.
"""
import json
from datetime import timedelta
from decimal import Decimal, InvalidOperation

from django.http import Http404, HttpResponse
from django.utils import timezone
from django.views.decorators.http import require_http_methods

from . import security as S
from .base import diff, done, owner_view, page, to_int
from .i18n import strings

_SPONSOR_FIELDS = ("name", "category", "website", "contact_name", "contact_phone",
                   "contact_email", "notes")
_CAMPAIGN_TEXT = ("name", "placement", "pricing", "title_bn", "title_en", "body_bn",
                  "body_en", "cta_bn", "cta_en", "link_url", "notes")


def _T(request):
    return strings(request.owner_lang)


def _local_input(dt):
    if not dt:
        return ""
    return timezone.localtime(dt).strftime("%Y-%m-%dT%H:%M")


def _dec(v):
    try:
        return Decimal(str(v or "0").strip() or "0").quantize(Decimal("0.01"))
    except (InvalidOperation, ValueError):
        return None


def _sponsor_or_404(pk):
    from core.models import Sponsor
    s = Sponsor.objects.filter(pk=pk).first()
    if s is None:
        raise Http404
    return s


def _campaign_or_404(pk):
    from core.models import SponsorCampaign
    c = SponsorCampaign.objects.select_related("sponsor").filter(pk=pk).first()
    if c is None:
        raise Http404
    return c


def _sponsor_snap(s):
    return {k: getattr(s, k) for k in _SPONSOR_FIELDS + ("active",)}


def _campaign_snap(c):
    d = {k: getattr(c, k) for k in _CAMPAIGN_TEXT}
    d.update({"status": c.status, "price_bdt": str(c.price_bdt),
              "budget_bdt": str(c.budget_bdt),
              "start_at": c.start_at.isoformat() if c.start_at else None,
              "end_at": c.end_at.isoformat() if c.end_at else None,
              "categories": list(c.categories or []),
              "divisions": list(c.divisions or []),
              "daily_imp_cap": c.daily_imp_cap, "priority": c.priority,
              "checklist": dict(c.checklist or {}), "image": bool(c.image)})
    return json.loads(json.dumps(d, default=str))


# ================================================================ sponsors
@require_http_methods(["GET", "POST"])
@owner_view()
def sponsors(request):
    from core.models import Sponsor, SponsorCampaign
    T = _T(request)
    ctx, status = {}, 200
    if request.method == "POST":
        data = {k: request.POST.get(k, "").strip()[:300] for k in _SPONSOR_FIELDS}
        if not data["name"]:
            ctx["error"] = T["p2_err_name"]
            status = 400
        else:
            s = Sponsor.objects.create(**data)
            S.audit(request, request.owner, "sponsor.create", "sponsor:%s" % s.pk,
                    after=_sponsor_snap(s))
            return done("/owner/sponsors/%d" % s.pk, "created")
    from core import sponsor_service as SS
    camps = list(SponsorCampaign.objects.select_related("sponsor")[:300])
    tot = SS._totals([c.id for c in camps])
    now = timezone.now()
    rows = []
    for c in camps:
        imp, clk = tot.get(c.id, (0, 0))
        live = c.status == "approved" and (c.start_at is None or c.start_at <= now) \
            and (c.end_at is None or now < c.end_at)
        rows.append({"c": c, "imp": imp, "clk": clk, "live": live,
                     "ctr": SS.SP.ctr(imp, clk)})
    ctx.update({"sponsors": Sponsor.objects.all()[:300], "campaigns": rows})
    return page(request, "owner/p2_sponsors.html", ctx, status=status, nav="sponsors")


@require_http_methods(["GET", "POST"])
@owner_view()
def sponsor_edit(request, pk):
    s = _sponsor_or_404(pk)
    T = _T(request)
    ctx, status = {"s": s}, 200
    if request.method == "POST":
        before = _sponsor_snap(s)
        data = {k: request.POST.get(k, "").strip()[:300] for k in _SPONSOR_FIELDS}
        if not data["name"]:
            ctx["error"] = T["p2_err_name"]
            status = 400
        else:
            for k, v in data.items():
                setattr(s, k, v)
            s.active = request.POST.get("active") == "on"
            s.save()
            b, a = diff(before, _sponsor_snap(s))
            if a:
                S.audit(request, request.owner, "sponsor.update", "sponsor:%s" % s.pk,
                        before=b, after=a)
            return done("/owner/sponsors/%d" % s.pk)
    ctx["campaigns"] = s.campaigns.all()
    return page(request, "owner/p2_sponsor.html", ctx, status=status, nav="sponsors")


# ================================================================ campaigns
def _campaign_form(request):
    from core.views_discover import _parse_dt
    from core.logic import sponsor as SP
    d = {k: request.POST.get(k, "").strip() for k in _CAMPAIGN_TEXT}
    d["price_bdt"] = _dec(request.POST.get("price_bdt"))
    d["budget_bdt"] = _dec(request.POST.get("budget_bdt"))
    d["daily_imp_cap"] = max(0, min(10 ** 7, to_int(request.POST.get("daily_imp_cap"), 0) or 0))
    d["priority"] = max(-100, min(100, to_int(request.POST.get("priority"), 0) or 0))
    d["categories"] = SP.clean_categories(request.POST.getlist("categories"))
    d["divisions"] = SP.clean_divisions(request.POST.getlist("divisions"))
    s, ok1 = _parse_dt(request.POST.get("start_at"))
    e, ok2 = _parse_dt(request.POST.get("end_at"))
    d["start_at"], d["end_at"] = s, e
    errors = SP.validate_campaign({**d, "price_bdt": d["price_bdt"] if d["price_bdt"] is not None else "x",
                                   "budget_bdt": d["budget_bdt"] if d["budget_bdt"] is not None else "x"})
    if not (ok1 and ok2):
        errors["start_at"] = "invalid_date"
    from core.logic import discover as D
    safety = D.safety_issues({"title_bn": d["title_bn"], "title_en": d["title_en"],
                              "desc_bn": d["body_bn"], "desc_en": d["body_en"],
                              "url": d["link_url"]})
    if d["link_url"] and D.url_issue(d["link_url"]):
        errors["link_url"] = D.url_issue(d["link_url"])
    return d, errors, safety


def _render_campaign(request, c, sponsor, data=None, errors=None, safety=None,
                     status=200, extra=None):
    from core.logic import sponsor as SP
    from core.models import Sponsor
    if data:
        v = dict(data)
        v["start_local"] = _local_input(data.get("start_at")) if hasattr(data.get("start_at"), "tzinfo") else ""
        v["end_local"] = _local_input(data.get("end_at")) if hasattr(data.get("end_at"), "tzinfo") else ""
    elif c is not None:
        v = {k: getattr(c, k) for k in _CAMPAIGN_TEXT}
        v.update({"price_bdt": c.price_bdt, "budget_bdt": c.budget_bdt,
                  "daily_imp_cap": c.daily_imp_cap, "priority": c.priority,
                  "start_local": _local_input(c.start_at), "end_local": _local_input(c.end_at)})
    else:
        v = {}
    ctx = {"c": c, "v": v, "sponsor": sponsor, "data": data or {}, "errors": errors or {},
           "safety": safety or [], "placements": SP.PLACEMENTS,
           "categories": SP.CATEGORIES, "divisions": SP.DIVISIONS,
           "checklist_keys": SP.CHECKLIST, "sponsors": Sponsor.objects.all()[:300],
           "start_local": _local_input(c.start_at) if c else "",
           "end_local": _local_input(c.end_at) if c else "",
           "cats_on": list((c.categories if c else (data or {}).get("categories")) or []),
           "divs_on": list((c.divisions if c else (data or {}).get("divisions")) or []),
           "checks_on": dict((c.checklist if c else {}) or {})}
    if c is not None:
        ctx["can_approve"] = SP.checklist_complete(c.checklist) and not c.safety_issues
        ctx["discover_ready"] = c.placement == "discover"
        ctx["offer_ready"] = c.placement == "brand_offer" and c.status == "approved"
    ctx.update(extra or {})
    return page(request, "owner/p2_campaign.html", ctx, status=status, nav="sponsors")


def _save_image(c, f):
    from core.views_discover import MAX_IMAGE_BYTES
    if f.size > MAX_IMAGE_BYTES:
        return "too_large"
    try:
        from PIL import Image
        img = Image.open(f)
        img.verify()
        if (img.format or "").upper() not in ("PNG", "JPEG", "WEBP"):
            raise ValueError("format")
        f.seek(0)
    except Exception:
        return "not_an_image"
    if c.image:
        try:
            c.image.delete(save=False)
        except Exception:
            pass
    c.image.save(f.name or "creative.png", f, save=True)
    return ""


@require_http_methods(["GET", "POST"])
@owner_view()
def campaign_new(request):
    from core.models import Sponsor, SponsorCampaign
    sp = Sponsor.objects.filter(pk=to_int(request.GET.get("sponsor") or
                                          request.POST.get("sponsor"), 0)).first()
    if request.method == "GET":
        return _render_campaign(request, None, sp, data={"pricing": "flat",
                                                         "placement": "discover"})
    if sp is None:
        return _render_campaign(request, None, None, errors={"sponsor": "required"},
                                status=400)
    d, errors, safety = _campaign_form(request)
    if errors:
        return _render_campaign(request, None, sp, d, errors, safety, status=400)
    c = SponsorCampaign.objects.create(sponsor=sp, status="draft", safety_issues=safety, **d)
    S.audit(request, request.owner, "campaign.create", "campaign:%s" % c.pk,
            after=_campaign_snap(c))
    f = request.FILES.get("image")
    if f:
        err = _save_image(c, f)
        if err:
            return _render_campaign(request, c, sp, errors={"image": err}, status=400)
    return done("/owner/campaigns/%d" % c.pk, "created")


@require_http_methods(["GET", "POST"])
@owner_view()
def campaign_edit(request, pk):
    from core.logic import sponsor as SP
    c = _campaign_or_404(pk)
    T = _T(request)
    if request.method == "GET":
        return _render_campaign(request, c, c.sponsor)
    action = request.POST.get("action", "save")
    before = _campaign_snap(c)
    reason = request.POST.get("reason", "").strip()[:200]
    if action == "save":
        d, errors, safety = _campaign_form(request)
        if errors:
            return _render_campaign(request, c, c.sponsor, d, errors, safety, status=400)
        for k, v in d.items():
            setattr(c, k, v)
        c.safety_issues = safety
        c.checklist = {k: request.POST.get("chk_" + k) == "on" for k in SP.CHECKLIST}
        # any edit of an approved campaign sends it back for re-approval
        if c.status == "approved" and (safety or not SP.checklist_complete(c.checklist)):
            c.status = "paused"
        c.save()
        f = request.FILES.get("image")
        if f:
            err = _save_image(c, f)
            if err:
                return _render_campaign(request, c, c.sponsor, errors={"image": err},
                                        status=400)
        if request.POST.get("remove_image") == "on" and c.image:
            c.image.delete(save=True)
    elif action in ("approve", "pause", "reject", "end"):
        if action == "approve":
            if c.safety_issues or not SP.checklist_complete(c.checklist):
                return _render_campaign(request, c, c.sponsor, status=400,
                                        extra={"approve_error": T["p2_err_checklist"]})
            if not c.image and c.placement in ("app_open", "hero"):
                return _render_campaign(request, c, c.sponsor, status=400,
                                        extra={"approve_error": T["p2_err_image"]})
            c.status, c.approved_by, c.approved_at = "approved", request.owner, timezone.now()
        else:
            c.status = {"pause": "paused", "reject": "rejected", "end": "ended"}[action]
        c.save()
        if c.discover_card_id:
            card = c.discover_card
            card.enabled = c.status == "approved"
            card.save(update_fields=["enabled", "updated_at"])
    elif action == "discover_card":
        if c.placement != "discover":
            raise Http404
        _make_discover_card(c)
    elif action == "send_offer":
        from core import sponsor_service as SS
        res = SS.send_offer_notifications(c)
        S.audit(request, request.owner, "campaign.offer_notify", "campaign:%s" % c.pk,
                after={"sent": res["sent"], "skipped": res["skipped"], "_reason": reason})
        return _render_campaign(request, c, c.sponsor, extra={"sent": res})
    else:
        raise Http404
    b, a = diff(before, _campaign_snap(c))
    if a:
        S.audit(request, request.owner, "campaign.%s" % action, "campaign:%s" % c.pk,
                before=b, after={**a, "_reason": reason})
    return done("/owner/campaigns/%d" % c.pk)


def _make_discover_card(c):
    """A SPONSORED Discover card for a discover campaign (Free audience only;
    enabled only while the campaign is approved). Stats/report flow through
    the existing Discover machinery and roll up into the campaign."""
    from core.models import DiscoverCard
    card = c.discover_card or DiscoverCard(key="")
    card.type = "SPONSORED"
    card.title_bn, card.title_en = c.title_bn[:80], c.title_en[:80]
    card.desc_bn, card.desc_en = c.body_bn[:200], c.body_en[:200]
    card.url, card.route = c.link_url, ""
    card.icon = "local_offer"
    card.start_at, card.end_at = c.start_at, c.end_at
    card.audience = "free"
    card.sponsor_name = c.sponsor.name[:80]
    card.sponsor_revenue = c.price_bdt if c.pricing == "flat" else 0
    card.enabled = c.status == "approved"
    if not card.key:
        card.key = "camp-%d" % c.pk
    card.save()
    if c.image and not card.image:
        try:
            c.image.open("rb")
            card.image.save("camp-%d.png" % c.pk, c.image.file, save=True)
        except Exception:
            pass
    c.discover_card = card
    c.save(update_fields=["discover_card", "updated_at"])
    return card


@require_http_methods(["GET"])
@owner_view()
def campaign_report(request, pk, fmt=None):
    from core import sponsor_service as SS
    from .views_sections import _range
    c = _campaign_or_404(pk)
    d_from, d_to = _range(request)
    rep = SS.campaign_report(c, d_from, d_to)
    if fmt == "csv":
        resp = HttpResponse(SS.report_csv(rep), content_type="text/csv; charset=utf-8")
        resp["Content-Disposition"] = 'attachment; filename="campaign-%d-%s_%s.csv"' % (
            c.pk, rep["from"], rep["to"])
        S.audit(request, request.owner, "campaign.export", "campaign:%s" % pk,
                after={"from": rep["from"], "to": rep["to"]})
        return resp
    if fmt is not None:
        raise Http404
    return page(request, "owner/p2_report.html",
                {"c": c, "rep": rep, "qs": "from=%s&to=%s" % (rep["from"], rep["to"])},
                nav="sponsors")


# ================================================================ ad impact
@require_http_methods(["GET"])
@owner_view()
def ad_impact(request):
    from core import sponsor_service as SS
    from .views_sections import _days
    days = _days(request, 30, 1, 180)
    pnl = SS.placement_pnl(days)
    ret = SS.retention_impact(max(days, 30))
    T = _T(request)
    summary = [(p, v) for p, v in pnl["summary"].items()]
    total = round(sum(v["total"] for _, v in summary), 2)
    return page(request, "owner/p2_impact.html", {
        "pnl": pnl, "summary": summary, "total": total, "days": days,
        "ret": ret, "buckets": list(ret["buckets"].items()),
        "any_small": any(b["small_sample"] for b in ret["buckets"].values()),
        "day_options": (7, 30, 90, 180), "T2": T}, nav="impact")
