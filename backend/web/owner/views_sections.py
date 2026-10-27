"""The owner panel sections. Every business rule is delegated to the SAME
Python functions the /api/v1/admin/* endpoints use:

  Discover      core.views_discover (create_card/update_card/delete_card/
                save_card_image/reorder_cards/cards_for/card_report_range/
                report_csv/report_pdf) + core.logic.discover
  Pricing/Ads   core.views_build61.pricing_snapshot / pricing_apply
                (core.logic.pricing normalize + validate_edit)
  Flags         core.views_build61.flags_snapshot / flags_flip
                (core.logic.admin_flags confirm gate)
  P&L           core.billing.pnl_dashboard
  Integrations  core.integrations list_all / summary / save / test
  Users         core.billing.credit, core.logic.msg_moderation.admin_user_action
"""
import copy
import json
from datetime import timedelta

from django.contrib.auth import get_user_model
from django.db import transaction
from django.db.models import Count, F, Q, Sum
from django.db.models.functions import TruncDate
from django.http import Http404, HttpResponse, HttpResponseRedirect
from django.utils import timezone
from django.utils.dateparse import parse_date
from django.views.decorators.http import require_http_methods

from . import charts
from . import security as S
from .base import diff, done, owner_view, page, to_int, to_num
from .i18n import strings

User = get_user_model()


def _T(request):
    return strings(request.owner_lang)


def _days(request, default=30, lo=1, hi=180):
    d = to_int(request.GET.get("days"), default)
    return max(lo, min(hi, d))


# ================================================================ dashboard
@require_http_methods(["GET"])
@owner_view()
def dashboard(request):
    from core import billing
    from core.models import DiscoverCard
    from core.views_discover import _admin_payload
    ctx = {}
    # Owner decision: red banner while the server disk is >= limits.disk_alert_pct
    # (default 80%); nothing under it. Same check uptime_check alerts from.
    try:
        from core import disk_alert
        st = disk_alert.status()
        ctx["disk"] = st if st["alert"] else None
        if st["alert"] and request.owner_lang == "bn":
            ctx["disk_txt"] = {k: disk_alert.bn_digits(st[k])
                               for k in ("used_pct", "free_gb", "threshold")}
        elif st["alert"]:
            ctx["disk_txt"] = {k: st[k] for k in ("used_pct", "free_gb", "threshold")}
    except Exception:
        ctx["disk"] = None
    try:
        ctx["segments"] = billing.plan_segment_counts()
    except Exception:
        ctx["segments"] = None
    try:
        g = billing.guard_state()
        ctx["guard"] = g
    except Exception:
        ctx["guard"] = None
    try:
        p = billing.pnl_dashboard(days=7)
        ctx["pnl7"] = p["totals"]
        ctx["pnl7_has"] = bool(p["series"])
    except Exception:
        ctx["pnl7"], ctx["pnl7_has"] = None, False
    try:
        from core import integrations as I
        ctx["integ"] = I.summary(request.owner_lang)["counts"]
    except Exception:
        ctx["integ"] = None
    cards = [_admin_payload(c) for c in DiscoverCard.objects.all()]
    ctx["discover_live"] = sum(1 for c in cards if c["live"])
    ctx["discover_total"] = len(cards)
    today = timezone.localdate()
    ctx["signups_today"] = User.objects.filter(date_joined__date=today).count()
    from core.models import OwnerAudit
    ctx["recent"] = OwnerAudit.objects.select_related("actor")[:8]
    return page(request, "owner/dashboard.html", ctx, nav="home")


# ================================================================= discover
_DISCOVER_FIELDS = ("type", "title_bn", "title_en", "desc_bn", "desc_en", "icon",
                    "route", "url", "start_at", "end_at", "audience", "min_build",
                    "sponsor_name", "sponsor_revenue")


def _card_form_data(request):
    d = {k: request.POST.get(k, "") for k in _DISCOVER_FIELDS}
    d["enabled"] = request.POST.get("enabled") == "on"
    return d


def _card_snapshot(card):
    from core.views_discover import _admin_payload
    p = _admin_payload(card)
    p.pop("stats", None)
    p.pop("live", None)
    return json.loads(json.dumps(p, default=str))


def _discover_meta():
    from core.logic import discover as D
    return {"types": D.TYPES, "audiences": D.AUDIENCES, "routes": D.ROUTE_KEYS,
            "icons": D.ICONS, "segments": D.SEGMENTS}


def _local_input(dt):
    if not dt:
        return ""
    return timezone.localtime(dt).strftime("%Y-%m-%dT%H:%M")


@require_http_methods(["GET"])
@owner_view()
def discover_list(request):
    from core.models import DiscoverCard
    from core.views_discover import _admin_payload, _totals_by_card, app_payload, cards_for
    from core.logic import discover as D
    tot = _totals_by_card()
    cards = [_admin_payload(c, tot.get(c.id)) for c in DiscoverCard.objects.all()]
    seg = request.GET.get("segment") or "free"
    if seg not in D.SEGMENTS:
        seg = "free"
    build = to_int(request.GET.get("build"))
    preview = [app_payload(c) for c in cards_for(seg, build)]
    return page(request, "owner/discover_list.html",
                {"cards": cards, "preview": preview, "seg": seg, "build": build,
                 "ids": ",".join(str(c["id"]) for c in cards), **_discover_meta()},
                nav="discover")


def _render_card_form(request, card, errors=None, safety=None, status=200, data=None):
    ctx = {"card": card, "errors": errors or {}, "safety": safety or [],
           "data": data or {}, **_discover_meta()}
    if card is not None and card.pk:
        ctx["start_local"] = _local_input(card.start_at)
        ctx["end_local"] = _local_input(card.end_at)
    return page(request, "owner/discover_form.html", ctx, status=status, nav="discover")


@require_http_methods(["GET", "POST"])
@owner_view()
def discover_new(request):
    from core.views_discover import create_card, save_card_image
    if request.method == "GET":
        return _render_card_form(request, None, data={"enabled": True, "audience": "all",
                                                      "type": "FEATURE"})
    data = _card_form_data(request)
    card, errors, safety = create_card(data, request.owner)
    if errors or safety:
        return _render_card_form(request, None, errors, safety, status=400, data=data)
    S.audit(request, request.owner, "discover.create", "card:%s" % card.pk,
            after=_card_snapshot(card))
    f = request.FILES.get("image")
    if f:
        err = save_card_image(card, f, request.owner)
        if err:
            return _render_card_form(request, card, {"image": err}, status=400)
        S.audit(request, request.owner, "discover.image", "card:%s" % card.pk,
                after={"image": True})
    return done("/owner/discover/%d" % card.pk, "created")


def _card_or_404(pk):
    from core.models import DiscoverCard
    c = DiscoverCard.objects.filter(pk=pk).first()
    if c is None:
        raise Http404
    return c


@require_http_methods(["GET", "POST"])
@owner_view()
def discover_edit(request, pk):
    from core.views_discover import save_card_image, update_card
    card = _card_or_404(pk)
    if request.method == "GET":
        return _render_card_form(request, card)
    before = _card_snapshot(card)
    data = _card_form_data(request)
    errors, safety = update_card(card, data, request.owner)
    if errors or safety:
        card.refresh_from_db()
        return _render_card_form(request, card, errors, safety, status=400, data=data)
    b, a = diff(before, _card_snapshot(card))
    if a:
        S.audit(request, request.owner, "discover.update", "card:%s" % card.pk,
                before=b, after=a)
    if request.POST.get("remove_image") == "on" and card.image:
        card.image.delete(save=True)
        S.audit(request, request.owner, "discover.image", "card:%s" % card.pk,
                before={"image": True}, after={"image": False})
    f = request.FILES.get("image")
    if f:
        err = save_card_image(card, f, request.owner)
        if err:
            return _render_card_form(request, card, {"image": err}, status=400)
        S.audit(request, request.owner, "discover.image", "card:%s" % card.pk,
                after={"image": True})
    return done("/owner/discover/%d" % card.pk)


@require_http_methods(["POST"])
@owner_view()
def discover_toggle(request, pk):
    from core.views_discover import update_card
    card = _card_or_404(pk)
    before = card.enabled
    errors, safety = update_card(card, {"enabled": not before}, request.owner)
    if errors or safety:
        return done("/owner/discover", "invalid")
    S.audit(request, request.owner, "discover.toggle", "card:%s" % card.pk,
            before={"enabled": before}, after={"enabled": card.enabled})
    return done("/owner/discover")


@require_http_methods(["POST"])
@owner_view()
def discover_delete(request, pk):
    from core.views_discover import delete_card
    card = _card_or_404(pk)
    if request.POST.get("confirm") != "on":
        return done("/owner/discover/%d" % pk, "confirm_needed")
    snap = _card_snapshot(card)
    delete_card(card, request.owner)
    S.audit(request, request.owner, "discover.delete", "card:%s" % pk, before=snap)
    return done("/owner/discover", "deleted")


@require_http_methods(["POST"])
@owner_view()
def discover_reorder(request):
    """ids = comma list (drag & drop) or move=<id>:up|down (no-JS buttons)."""
    from core.models import DiscoverCard
    from core.views_discover import reorder_cards
    current = list(DiscoverCard.objects.values_list("id", flat=True))
    move = request.POST.get("move", "")
    if move:
        pid, _, direction = move.partition(":")
        pid = to_int(pid)
        if pid in current:
            i = current.index(pid)
            j = i - 1 if direction == "up" else i + 1
            if 0 <= j < len(current):
                current[i], current[j] = current[j], current[i]
        ids = current
    else:
        ids = [to_int(x) for x in request.POST.get("ids", "").split(",") if x.strip()]
        if None in ids or sorted(ids) != sorted(current):
            return done("/owner/discover", "invalid")
    before = list(DiscoverCard.objects.values_list("id", flat=True))
    err = reorder_cards(ids, request.owner)
    if err:
        return done("/owner/discover", "invalid")
    S.audit(request, request.owner, "discover.reorder", "discover",
            before={"ids": before}, after={"ids": ids})
    return done("/owner/discover")


def _range(request):
    today = timezone.localdate()
    d_to = parse_date(request.GET.get("to") or "") or today
    d_from = parse_date(request.GET.get("from") or "") or (d_to - timedelta(days=29))
    if d_from > d_to:
        d_from, d_to = d_to, d_from
    if (d_to - d_from).days > 365:
        d_from = d_to - timedelta(days=365)
    return d_from, d_to


@require_http_methods(["GET"])
@owner_view()
def discover_report(request, pk, fmt=None):
    from core.views_discover import card_report_range, report_csv, report_pdf
    card = _card_or_404(pk)
    d_from, d_to = _range(request)
    rep = card_report_range(card, d_from, d_to)
    if fmt in ("csv", "pdf"):
        name = "discover-%s-%s_%s" % (card.key, rep["from"], rep["to"])
        if fmt == "csv":
            resp = HttpResponse(report_csv(rep), content_type="text/csv; charset=utf-8")
        else:
            resp = HttpResponse(report_pdf(rep), content_type="application/pdf")
        resp["Content-Disposition"] = 'attachment; filename="%s.%s"' % (name, fmt)
        S.audit(request, request.owner, "discover.export", "card:%s" % pk,
                after={"format": fmt, "from": rep["from"], "to": rep["to"]})
        return resp
    T = _T(request)
    has = rep["totals"]["impressions"] or rep["totals"]["clicks"]
    chart = charts.bars([r["date"] for r in rep["rows"]],
                        [(T["impressions"], "s1", [r["impressions"] for r in rep["rows"]]),
                         (T["clicks"], "s2", [r["clicks"] for r in rep["rows"]])]) if has else ""
    return page(request, "owner/discover_report.html",
                {"card": card, "rep": rep, "chart": chart, "has": has,
                 "qs": "from=%s&to=%s" % (rep["from"], rep["to"])}, nav="discover")


# ================================================================== pricing
_SCALARS = ("margin", "annual_discount_pct", "credit_bdt", "usd_bdt", "play_fee",
            "gateway_fee", "vat", "fixed_cost_per_day", "storage_cost_bdt_per_gb_month",
            "probashi_price_usd", "ai_daily_budget_usd", "ai_user_daily_limit")
_DICT_SECTIONS = ("guarantees", "limits", "referral", "profit_guard", "shop", "otp",
                  "vehicle", "photo_studio", "world",   # p4-world
                  "retention",   # retention1
                  "billing",     # billing-v2: staged unlock + refund window
                  "plans_v2")    # plans-v2 (own labelled card, not the generic list)


# Plan-row keys the editor never shows or posts. Owner decision: nothing is
# unlimited — the old unlimited_ai switch is gone (normalize forces False and
# validate_edit refuses a True), so it is not offered as a control at all.
_PLAN_HIDDEN = ("unlimited_ai",)


def _plan_row(row):
    return {k: v for k, v in row.items() if k not in _PLAN_HIDDEN}


def _coerce(raw, current):
    """Form string -> the type of the current config value (None = invalid)."""
    if isinstance(current, bool):
        return raw == "on"
    if isinstance(current, (int, float)):
        n = to_num(raw)
        if n is None:
            return None
        return int(n) if isinstance(current, int) and float(n).is_integer() else n
    return str(raw if raw is not None else "").strip()


def _fields_of(d):
    """[(key, value, kind)] for a flat dict of scalars."""
    out = []
    for k, v in d.items():
        if isinstance(v, bool):
            out.append((k, v, "bool"))
        elif isinstance(v, (int, float)):
            out.append((k, v, "num"))
        elif isinstance(v, str):
            out.append((k, v, "text"))
    return out


def _pricing_patch(request, cfg):
    """Build the PricingConfig patch for the ONE section this form posted."""
    sec = request.POST.get("section", "")
    bad = []

    def read(prefix, current):
        out = {}
        for k, v in current.items():
            if isinstance(v, (dict, list)):
                continue
            name = "%s.%s" % (prefix, k)
            if isinstance(v, bool):
                out[k] = request.POST.get(name) == "on"
                continue
            if name not in request.POST:
                continue
            val = _coerce(request.POST.get(name), v)
            if val is None:
                bad.append(name)
            else:
                out[k] = val
        return out

    if sec == "scalars":
        patch = read("s", {k: cfg[k] for k in _SCALARS if k in cfg})
    elif sec == "plans":
        patch = {"plans": {pid: read("plans.%s" % pid, _plan_row(row))
                           for pid, row in cfg["plans"].items()}}
    elif sec == "action_costs":
        patch = {"action_costs": {aid: read("ac.%s" % aid, row)
                                  for aid, row in cfg["action_costs"].items()}}
    elif sec == "topup_packs":
        packs = []
        for i, row in enumerate(cfg["topup_packs"]):
            if request.POST.get("tp.%d.delete" % i) == "on":
                continue
            packs.append({**row, **read("tp.%d" % i, row)})
        new_id = request.POST.get("tp.new.id", "").strip()
        if new_id:
            tmpl = cfg["topup_packs"][0] if cfg["topup_packs"] else {
                "id": "", "price": 0, "credits": 0, "valid_months": 12}
            row = {k: _coerce(request.POST.get("tp.new.%s" % k, ""), v) for k, v in tmpl.items()}
            if any(v is None for v in row.values()):
                bad.append("tp.new")
            else:
                packs.append(row)
        patch = {"topup_packs": packs}
    elif sec == "home_quick_defaults":
        raw = [x.strip() for x in request.POST.get("home_quick_defaults", "").split(",")
               if x.strip()]
        patch = {"home_quick_defaults": raw}
    elif sec in _DICT_SECTIONS:
        patch = {sec: read(sec, cfg[sec])}
    else:
        patch, bad = {}, ["section"]
    return sec, patch, bad


def _plans_v2_ctx(cfg, T=None):
    """plans-v2 Owner Admin card: one row per capability x Free/Premium/
    Business, the CRM contact limits and the trial settings."""
    from core.logic import entitlements as E
    pv = cfg.get("plans_v2") or E.defaults()
    T = T or {}
    rows = [{"cap": c, "label": T.get("pv2_cap_" + c, c), "cells": [{"name": "plans_v2.%s_%s" % (t, c),
                                   "on": bool(pv.get("%s_%s" % (t, c)))}
                                  for t in E.TIERS]} for c in E.CAPS]
    contacts = [{"tier": t, "name": "plans_v2.%s_crm_contacts" % t,
                 "value": pv.get("%s_crm_contacts" % t)} for t in E.TIERS]
    return {"rows": rows, "contacts": contacts, "tiers": E.TIERS,
            "trial_days": pv.get("trial_days"), "trial_plan": pv.get("trial_plan"),
            "trial_plans": E.TRIAL_PLANS,
            "unlimited_display_at": pv.get("unlimited_display_at")}


@require_http_methods(["GET", "POST"])
@owner_view()
def pricing(request):
    from core.views_build61 import pricing_apply, pricing_snapshot
    snap = pricing_snapshot()
    cfg = snap["config"]
    ctx = {}
    status = 200
    if request.method == "POST" and request.POST.get("action") == "calls_free":
        # dl1: "Free calls (testing)" — an owner kill-switch (AdminFlagState),
        # flipped through the same audited flags engine as the Ads switches.
        from core.calls_free import FLAG, calls_free
        from core.views_build61 import flags_flip
        reason = request.POST.get("reason", "")[:200]
        value = request.POST.get("value") == "on"
        old = calls_free()
        ok, payload = flags_flip(request.owner.id, FLAG, value, reason)
        if ok:
            S.audit(request, request.owner, "flag.flip", "flag:%s" % FLAG,
                    before={FLAG: old}, after={FLAG: value, "_reason": reason})
            return done("/owner/pricing#calls_free")
        T0 = _T(request)
        ctx["problem_text_flag"] = [T0.get("f_" + p, p) for p in payload["problems"]]
        status = 400
    elif request.method == "POST":
        sec, patch, bad = _pricing_patch(request, cfg)
        if bad:
            ctx["problems"] = ["invalid_number"]
            ctx["bad_fields"] = bad
            status = 400
        else:
            body = {"config": patch, "reason": request.POST.get("reason", "")[:200],
                    "auto_reprice": request.POST.get("auto_reprice") == "on"}
            ok, payload = pricing_apply(request.owner.id, body)
            if ok:
                b, a = diff(cfg, payload["config"])
                S.audit(request, request.owner, "pricing.update", "pricing:%s" % sec,
                        before=b, after={**a, "_reason": body["reason"]})
                return done("/owner/pricing")
            ctx["problems"] = payload["problems"]
            ctx["margin_check_failed"] = payload.get("margin_check")
            status = 400
            S.audit(request, request.owner, "pricing.rejected", "pricing:%s" % sec,
                    after={"problems": payload["problems"]}, ok=False)
    T = _T(request)
    from core.calls_free import calls_free as _calls_free
    ctx.update({
        "calls_free": _calls_free(),
        "cfg": cfg, "audit": (snap.get("audit") or [])[:15],
        "margin_check": snap.get("margin_check"), "warnings": snap.get("warnings") or [],
        "scalars": _fields_of({k: cfg[k] for k in _SCALARS if k in cfg}),
        "plans": [(pid, _fields_of(_plan_row(row))) for pid, row in cfg["plans"].items()],
        "plan_cols": [k for k, _, _ in _fields_of(_plan_row(next(iter(cfg["plans"].values()))))],
        "actions": [(aid, _fields_of(row)) for aid, row in cfg["action_costs"].items()],
        "action_cols": [k for k, _, _ in _fields_of(next(iter(cfg["action_costs"].values())))]
        if cfg["action_costs"] else [],
        "packs": [(str(i), _fields_of(row)) for i, row in enumerate(cfg["topup_packs"])],
        "pack_cols": [k for k, _, _ in _fields_of(cfg["topup_packs"][0])]
        if cfg["topup_packs"] else ["id", "price", "credits", "valid_months"],
        # billing-v2: bn/en labels for the section fields (key when unnamed);
        # plans-v2 has its own labelled card (pv2), not the generic list
        "sections": [(s, [(k, v, kind, T.get("pf_" + k, k)) for k, v, kind in _fields_of(cfg[s])])
                     for s in _DICT_SECTIONS if isinstance(cfg.get(s), dict) and s != "plans_v2"],
        "pv2": _plans_v2_ctx(cfg, T),
        "home_quick": ", ".join(cfg.get("home_quick_defaults") or []),
        "problem_text": ([T.get("p_" + p, p) for p in ctx.get("problems", [])]
                         + ctx.get("problem_text_flag", [])),
        "warning_text": [{"text": T.get("w_" + w.get("code", ""), w.get("code", "")),
                          "plan": w.get("plan"), "period": w.get("period"),
                          "max_safe": w.get("max_safe_discount_pct")}
                         for w in (snap.get("warnings") or [])],
    })
    return page(request, "owner/pricing.html", ctx, status=status, nav="pricing")


# ====================================================================== P&L
@require_http_methods(["GET"])
@owner_view()
def pnl(request):
    from core import billing
    from core.logic import profit_guard as PG
    days = _days(request, 30, 1, 180)
    data = billing.pnl_dashboard(days=days)
    T = _T(request)
    series = data["series"]
    labels = [d["date"] or "" for d in series]
    chart = charts.bars(labels, [
        (T["revenue"], "s1", [d["revenue"]["total"] for d in series]),
        (T["cost_total"], "s2", [d["variable"]["total"] + d["fixed"] for d in series]),
    ], unit="৳") if series else ""
    by_source = [(s, round(sum(d["revenue"].get(s, 0) for d in series), 2))
                 for s in PG.REVENUE_SOURCES]
    by_cost = [(t, round(sum(d["variable"].get(t, 0) for d in series), 2))
               for t in PG.COST_TYPES]
    ps = data.get("photo_studio") or {}
    try:  # t9-turnscale: relayed-call cost per minute (Profit Guard)
        from core import turn_monitor
        relay_cost = turn_monitor.relay_cost(days)
    except Exception:
        relay_cost = None
    return page(request, "owner/pnl.html", {
        "cost": relay_cost,
        "d": data, "days": days, "chart": chart, "series": list(reversed(series)),
        "by_source": by_source, "by_cost": by_cost,
        "ps_features": [{"feature": f.get("feature"),
                         **{k: round((f.get(k) or 0) / 100.0, 2)
                            for k in ("revenue", "cost", "margin")}}
                        for f in (ps.get("features") or [])],
        "ps_totals": {k: round(((ps.get("totals") or {}).get(k) or 0) / 100.0, 2)
                      for k in ("revenue", "cost", "margin")},
        "day_options": (7, 30, 90, 180)}, nav="pnl")


# ====================================================================== ads
_AD_REWARD_KEYS = (# admob (owner 25 Oct): real-id switch + per-placement on/off
                   "admob_real_ids", "admob_personalized",
                   "place_app_open", "place_banner", "place_interstitial",
                   "place_rewarded", "banner_screens", "interstitial_moments",
                   "ecpm_bdt", "revenue_share", "appopen_min_gap_sec", "appopen_daily_cap",
                   "appopen_start_day", "appopen_skip_after_s", "appopen_min_bg_sec",
                   "rewarded_daily_cap", "interstitial_daily_cap",
                   "interstitial_min_gap_sec", "native_daily_cap", "home_native_size",
                   "hero_enabled", "hero_start_muted", "consent_debug_eea",
                   # p2-money
                   "sponsors_enabled", "community_sponsored_enabled",
                   "community_sponsored_min_members", "community_sponsored_daily_cap",
                   "offers_enabled", "offer_notif_daily_cap", "offers_premium_notifs")
_PS_AD_KEYS = ("entry_interstitial_enabled", "entry_interstitial_gap_min", "enhance_hd_ads",
               "max_ads_per_job", "free_prompt_trials_per_day", "ad_value_bdt",
               "ad_value_share", "ticket_ttl_min",
               # d1-photo v2 pricing (owner order 6)
               "free_enhance_per_day", "free_enhance_ads", "premium_enhance_daily_cap",
               "free_gen_lifetime", "free_gen_per_week", "free_gen_min_ads",
               # photo-final (owner 24 Oct): free enhance rules, provider switch,
               # daily spend cap, GFPGAN legal switch, Ultra HD budget
               "free_enhance_lifetime", "enhance_unlock_ads", "free_enhance_per_week_no_ads",
               "rollout_assisto_face", "rollout_runpod_serverless", "rollout_replicate",
               "rollout_fal_face", "fal_face_model", "realesrgan_allowed",
               "provider_timeout_s", "daily_spend_cap_usd", "cap_fallback_local",
               "face_blend_natural_pct", "face_blend_strong_pct",
               "max_input_mp", "ultra_hd_budget_pct")
_AD_FLAGS = ("ads_rewarded", "ads_app_open")


@require_http_methods(["GET", "POST"])
@owner_view()
def ads(request):
    from core.views_build61 import flags_flip, flags_snapshot, pricing_apply, pricing_snapshot
    T = _T(request)
    cfg = pricing_snapshot()["config"]
    ctx, status = {}, 200
    if request.method == "POST":
        action = request.POST.get("action")
        reason = request.POST.get("reason", "")[:200]
        if action == "flag":
            flag = request.POST.get("flag", "")
            if flag not in _AD_FLAGS:
                raise Http404
            value = request.POST.get("value") == "on"
            snap = flags_snapshot()
            old = next((f["value"] for f in snap["flags"] if f["id"] == flag), None)
            ok, payload = flags_flip(request.owner.id, flag, value, reason)
            if ok:
                S.audit(request, request.owner, "flag.flip", "flag:%s" % flag,
                        before={flag: old}, after={flag: value, "_reason": reason})
                return done("/owner/ads")
            ctx["problems"] = [T.get("f_" + p, p) for p in payload["problems"]]
            status = 400
        else:
            # Photo Studio's block only exists once that build is deployed.
            blocks = [("ad_rewards", _AD_REWARD_KEYS)]
            if "photo_studio" in cfg:
                blocks.append(("photo_studio", _PS_AD_KEYS))
            patch, bad = {b: {} for b, _ in blocks}, []
            for blk, keys in blocks:
                for k in keys:
                    cur = cfg[blk].get(k)
                    name = "%s.%s" % (blk, k)
                    if isinstance(cur, bool):
                        patch[blk][k] = request.POST.get(name) == "on"
                    elif name in request.POST:
                        v = _coerce(request.POST.get(name), cur)
                        if v is None:
                            bad.append(name)
                        else:
                            patch[blk][k] = v
            if bad:
                ctx["problems"] = [T["p_invalid_number"]]
                status = 400
            else:
                ok, payload = pricing_apply(request.owner.id,
                                            {"config": patch, "reason": reason})
                if ok:
                    b, a = diff({k: cfg[k] for k in patch},
                                {k: payload["config"][k] for k in patch})
                    S.audit(request, request.owner, "ads.update", "pricing:ads",
                            before=b, after={**a, "_reason": reason})
                    return done("/owner/ads")
                ctx["problems"] = [T.get("p_" + p, p) for p in payload["problems"]]
                status = 400
    fsnap = flags_snapshot()
    flags = [f for f in fsnap["flags"] if f["id"] in _AD_FLAGS]
    try:
        from core import integrations as I
        admob = I.is_enabled("admob")
    except Exception:
        admob = False
    # admob: placement x impressions x clicks x revenue (7 or 30 days)
    stat_days = 30 if request.GET.get("days") == "30" else 7
    try:
        from core import admob_service
        stats = admob_service.placement_stats(stat_days)
    except Exception:
        stats = []
    ctx.update({
        "stats": stats, "stat_days": stat_days,
        "ar": [(k, cfg["ad_rewards"].get(k),
                "bool" if isinstance(cfg["ad_rewards"].get(k), bool)
                else ("str" if isinstance(cfg["ad_rewards"].get(k), str) else "num"),
                T.get("ak_" + k, k)) for k in _AD_REWARD_KEYS if k in cfg["ad_rewards"]],
        "ps": [(k, (cfg.get("photo_studio") or {}).get(k),
                "bool" if isinstance((cfg.get("photo_studio") or {}).get(k), bool)
                else ("text" if isinstance((cfg.get("photo_studio") or {}).get(k), str) else "num"),
                T.get("psk_" + k, k))
               for k in _PS_AD_KEYS if k in (cfg.get("photo_studio") or {})],
        "flags": flags, "admob": admob})
    return page(request, "owner/ads.html", ctx, status=status, nav="ads")


# ============================================================= integrations
@require_http_methods(["GET", "POST"])
@owner_view()
def integrations(request):
    from core import integrations as I
    lang = request.owner_lang
    if request.method == "POST":
        slug = request.POST.get("slug", "")
        if slug not in I.REGISTRY:
            raise Http404
        action = request.POST.get("action")
        if action == "save":
            keys = {f["key"] for f in I.REGISTRY[slug]["fields"]}
            data = {k: request.POST.get(k, "").strip() for k in keys
                    if request.POST.get(k, "").strip()}
            if not data:
                return done("/owner/integrations#i-%s" % slug, "nothing")
            try:
                I.save(slug, data)
            except RuntimeError:
                return done("/owner/integrations", "no_fernet")
            except ValueError:
                raise Http404
            secret = {f["key"] for f in I.REGISTRY[slug]["fields"] if f["secret"]}
            S.audit(request, request.owner, "integration.save", "integration:%s" % slug,
                    after={k: ("••••" + v[-4:] if k in secret else v)
                           for k, v in data.items()})
            return done("/owner/integrations#i-%s" % slug)
        if action == "test":
            try:
                st, detail = I.test(slug)
            except RuntimeError:
                return done("/owner/integrations", "no_fernet")
            S.audit(request, request.owner, "integration.test", "integration:%s" % slug,
                    after={"status": st}, ok=(st == "working"))
            return done("/owner/integrations#i-%s" % slug, "tested")
        raise Http404
    try:
        rows = I.list_all(lang)
        summ = I.summary(lang)
        err = ""
    except RuntimeError:
        rows, summ, err = [], None, "no_fernet"
    cats = {}
    for r in rows:
        cats.setdefault(r["category"], []).append(r)
    return page(request, "owner/integrations.html",
                {"cats": sorted(cats.items()), "summary": summ, "err": err},
                nav="integrations")


# ==================================================================== users
def _search_users(q):
    q = (q or "").strip()
    if not q:
        return User.objects.order_by("-date_joined")[:25]
    cond = Q(name__icontains=q) | Q(username__icontains=q) | Q(email__icontains=q)
    from core.phone import canonical_phone, variants
    canon = canonical_phone(q)
    if canon:
        cond |= Q(phone__in=variants(canon))
    digits = "".join(ch for ch in q if ch.isdigit())
    if digits and len(digits) >= 4:
        cond |= Q(phone__contains=digits[-10:])
    qid = q.lstrip("#")
    if qid.isdigit():
        cond |= Q(pk=int(qid))
    return User.objects.filter(cond).order_by("-date_joined")[:50]


@require_http_methods(["GET"])
@owner_view()
def users(request):
    q = request.GET.get("q", "")
    rows = []
    from core import plans
    for u in _search_users(q):
        try:
            eff = plans.effective_plan(u)
        except Exception:
            eff = u.plan
        rows.append({"u": u, "eff": eff})
    return page(request, "owner/users.html", {"q": q, "rows": rows}, nav="users")


def _user_state(u):
    from core import billing, plans
    try:
        wallet = billing.ad_wallet_credits(u)
    except Exception:
        wallet = 0
    return {"plan": u.plan, "plan_until": u.plan_until.isoformat() if u.plan_until else None,
            "effective": plans.effective_plan(u), "ai_credits": int(u.ai_credits or 0),
            "ad_wallet": wallet, "status": u.account_status}


def _adjust_credits(user, delta, note, actor=None):
    """Owner credit adjustment through the bucketed engine (billing-v2):
    +delta into the free bucket, -delta in spend order, never below 0,
    ledger reason 'adjust' with the acting owner id as the source."""
    from core import credits as CR
    return CR.owner_adjust(user, delta, note[:120], actor=actor)


@require_http_methods(["GET", "POST"])
@owner_view()
def user_detail(request, pk):
    from core import plans
    from core.models import CreditLedger
    T = _T(request)
    u = User.objects.filter(pk=pk).first()
    if u is None:
        raise Http404
    ctx, status = {}, 200
    if request.method == "POST":
        action = request.POST.get("action")
        reason = request.POST.get("reason", "").strip()[:200]
        before = _user_state(u)
        err = ""
        if not reason:
            err = T["err_reason"]
        elif action == "credits":
            delta = to_int(request.POST.get("delta"))
            if not delta or abs(delta) > 100000:
                err = T["err_delta"]
            else:
                _adjust_credits(u, delta, "owner: " + reason, actor=request.owner)
        elif action == "plan":
            plan = request.POST.get("plan", "")
            days = to_int(request.POST.get("days"), 0) or 0
            if plan not in plans.PLANS or plan == "founder":
                err = T["err_plan"]
            elif plan == "free":
                # billing-v2: a recorded owner grant (actor + reason), never revenue
                from core.payments import entitlement as _E
                _E.owner_grant(u, plan="free", until=None, source="owner_grant",
                               actor=request.owner, reason=reason)
            elif not (1 <= days <= 3660):
                err = T["err_days"]
            else:
                from core.payments import entitlement as _E
                _E.owner_grant(u, plan=plan, until=timezone.now() + timedelta(days=days),
                               source="owner_grant", actor=request.owner, reason=reason)
        elif action in ("block", "unblock"):
            if u.pk == request.owner.pk or u.is_superuser:
                err = T["err_block_owner"]
            else:
                from core.logic import msg_moderation as mmod
                from core.models import ModerationAudit
                act = mmod.A_SUSPEND if action == "block" else mmod.A_UNSUSPEND
                new_status, reset, audit_entry = mmod.admin_user_action(
                    u.account_status, act, request.owner.id, u.id, reason)
                u.account_status = new_status
                u.save(update_fields=["account_status"])
                if reset:
                    from rest_framework.authtoken.models import Token
                    Token.objects.filter(user=u).delete()
                ModerationAudit.objects.create(
                    actor=request.owner, action=audit_entry["action"],
                    target_kind=mmod.T_PERSON, target_id=str(u.id),
                    reason=audit_entry["reason"],
                    extra={"new_status": new_status, "reset_sessions": reset,
                           "via": "owner_panel"})
        else:
            raise Http404
        if err:
            ctx["error"] = err
            status = 400
        else:
            u.refresh_from_db()
            b, a = diff(before, _user_state(u))
            S.audit(request, request.owner, "user." + action, "user:%s" % u.pk,
                    before=b, after={**a, "_reason": reason})
            return done("/owner/users/%d" % u.pk)
    from .views_bill2 import user_billing
    ctx.update(user_billing(u))
    ctx.update({"u": u, "state": _user_state(u),
                "ledger": CreditLedger.objects.filter(user=u)[:20],
                "plan_ids": [p for p in plans.PLANS if p != "founder"],
                "blocked": u.account_status in ("suspended", "banned")})
    return page(request, "owner/user_detail.html", ctx, status=status, nav="users")


# ================================================================== reports
def _by_day(qs, field, since, today, agg=None):
    rows = (qs.annotate(d=TruncDate(field)).values("d")
            .annotate(v=agg if agg is not None else Count("id")).order_by("d"))
    got = {r["d"]: r["v"] or 0 for r in rows}
    out = []
    d = since
    while d <= today:
        out.append((d.isoformat(), got.get(d, 0)))
        d += timedelta(days=1)
    return out


@require_http_methods(["GET"])
@owner_view()
def reports(request):
    from core.models import AnalyticsEvent, AuditLog, CreditLedger, DailyLedger
    from core.logic import profit_guard as PG
    T = _T(request)
    days = _days(request, 30, 7, 180)
    today = timezone.localdate()
    since = today - timedelta(days=days - 1)
    signups = _by_day(User.objects.filter(date_joined__date__gte=since), "date_joined",
                      since, today)
    spent_qs = CreditLedger.objects.filter(created_at__date__gte=since, delta__lt=0,
                                           reason__in=("consume", "ad_spend"))
    spent = [(d, -v) for d, v in _by_day(spent_qs, "created_at", since, today, Sum("delta"))]
    active = _by_day(AuditLog.objects.filter(created_at__date__gte=since),
                     "created_at", since, today, Count("user_id", distinct=True))
    an = {}
    for r in (AnalyticsEvent.objects.filter(day__gte=since).values("day")
              .annotate(n=Count("uid_hash", distinct=True))):
        an[r["day"]] = r["n"]
    analytics_active = [(d, an.get(parse_date(d), 0)) for d, _ in signups]
    rev = {}
    for r in DailyLedger.objects.filter(date__gte=since, date__lte=today):
        rev[r.date.isoformat()] = round(sum(float(v or 0) for v in
                                            (r.revenue_by_source or {}).values()
                                            if isinstance(v, (int, float))), 2)
    revenue = [(d, rev.get(d, 0)) for d, _ in signups]
    top_spend = list(spent_qs.values("note").annotate(credits=Sum("delta"), n=Count("id"))
                     .order_by("credits")[:10])
    for r in top_spend:
        r["credits"] = -(r["credits"] or 0)
    top_used = []
    for r in (AnalyticsEvent.objects.filter(day__gte=since, name="feature_used")
              .values("props__feature").annotate(users=Count("uid_hash", distinct=True))
              .order_by("-users")[:10]):
        if r["props__feature"]:
            top_used.append({"feature": r["props__feature"], "users": r["users"]})

    def block(key, rows, cls, unit=""):
        has = any(v for _, v in rows)
        return {"key": key, "title": T[key], "rows": list(reversed(rows)),
                "total": round(sum(v for _, v in rows), 2), "has": has,
                "chart": charts.bars([d for d, _ in rows], [(T[key], cls, [v for _, v in rows])],
                                     height=160, unit=unit) if has else ""}

    now = timezone.now()
    ctx = {
        "days": days, "day_options": (7, 30, 90, 180),
        "blocks": [block("r_signups", signups, "s1"), block("r_active", active, "s1"),
                   block("r_analytics_active", analytics_active, "s1"),
                   block("r_revenue", revenue, "s1", "৳"), block("r_spent", spent, "s2")],
        "top_spend": top_spend, "top_used": top_used,
        "users_total": User.objects.count(),
        "users_7": AuditLog.objects.filter(created_at__gte=now - timedelta(days=7))
        .values("user_id").distinct().count(),
        "users_30": AuditLog.objects.filter(created_at__gte=now - timedelta(days=30))
        .values("user_id").distinct().count(),
    }
    return page(request, "owner/reports.html", ctx, nav="reports")


# ==================================================================== audit
@require_http_methods(["GET"])
@owner_view()
def audit_log(request):
    from core.models import OwnerAudit
    qs = OwnerAudit.objects.select_related("actor")
    act = request.GET.get("action", "").strip()
    if act:
        qs = qs.filter(action__startswith=act)
    pg = max(1, to_int(request.GET.get("page"), 1) or 1)
    total = qs.count()
    rows = list(qs[(pg - 1) * 50: pg * 50])
    for r in rows:
        r.before_json = json.dumps(r.before, ensure_ascii=False, default=str) if r.before else ""
        r.after_json = json.dumps(r.after, ensure_ascii=False, default=str) if r.after else ""
    prefixes = ("login", "2fa", "logout", "discover", "pricing", "ads", "flag",
                "integration", "user", "security", "founders", "feedback")
    return page(request, "owner/audit.html",
                {"rows": rows, "act": act, "page_no": pg, "total": total,
                 "has_next": pg * 50 < total, "prefixes": prefixes}, nav="audit")


# ================================================================= security
@require_http_methods(["GET", "POST"])
@owner_view()
def security(request):
    from core.models import OwnerSession, OwnerTOTP
    T = _T(request)
    me = request.owner
    sess = request.owner_session
    totp = OwnerTOTP.objects.filter(user=me).first()
    ctx, status = {}, 200
    if request.method == "POST":
        action = request.POST.get("action")
        if action == "revoke_others":
            n = OwnerSession.objects.filter(user=me).exclude(pk=sess.pk).delete()[0]
            S.audit(request, me, "security.revoke_sessions", "user:%s" % me.pk,
                    after={"revoked": n})
            return done("/owner/security")
        code = request.POST.get("code", "")
        key = "mfa:%s" % me.pk
        left = S.lock_remaining(key)
        ok = False
        if left:
            ctx["error"] = T["err_locked"].format(m=max(1, left // 60))
        elif totp:
            c = S.verify_totp(S.decrypt(totp.secret_enc), code, totp.last_counter)
            if c is not None:
                totp.last_counter = c
                totp.save(update_fields=["last_counter", "updated_at"])
                ok = True
            elif action == "reset_2fa" and S.looks_like_recovery(code):
                ok = S.consume_recovery(totp, code)
        if not ok and not left:
            S.register_fail(key)
            ctx["error"] = T["err_code"]
        if action == "reset_2fa" and ok and not me.check_password(request.POST.get("password", "")):
            ok = False
            ctx["error"] = T["err_login"]
        if ok and action == "new_codes":
            codes = S.new_recovery_codes()
            totp.recovery_hashes = [S.hash_recovery(x) for x in codes]
            totp.save(update_fields=["recovery_hashes", "updated_at"])
            S.audit(request, me, "security.new_recovery_codes", "user:%s" % me.pk,
                    after={"recovery_codes": len(codes)})
            return page(request, "owner/recovery_codes.html", {"codes": codes}, nav="security")
        if ok and action == "reset_2fa":
            totp.delete()
            OwnerSession.objects.filter(user=me).exclude(pk=sess.pk).delete()
            sess.stage = "enrol"
            sess.pending_secret_enc = ""
            sess.save(update_fields=["stage", "pending_secret_enc"])
            S.audit(request, me, "security.reset_2fa", "user:%s" % me.pk)
            return HttpResponseRedirect("/owner/enrol")
        if not ok:
            status = 400
            S.audit(request, me, "security.%s_fail" % (action or "x")[:20], "user:%s" % me.pk,
                    ok=False)
    ctx.update({
        "sessions": OwnerSession.objects.filter(user=me).order_by("-last_seen"),
        "current_id": sess.pk,
        "codes_left": len(totp.recovery_hashes or []) if totp else 0,
        "enrolled_at": totp.confirmed_at if totp else None,
        "idle_min": S.idle_minutes()})
    return page(request, "owner/security.html", ctx, status=status, nav="security")
