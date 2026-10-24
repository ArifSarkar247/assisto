"""f1-founders owner-panel sections.

  Founding Members  core.founders (grant / revoke / resolve / preview) — the
                    same rules everywhere; N months = PricingConfig
                    limits.founding_member_months (edit in /owner/pricing).
  Feedback          core.models.FeedbackReport (in-app "Send feedback /
                    report a problem"); screenshots via core.media_sign
                    signed, expiring links.
Every change is written to OwnerAudit with before/after.
"""
import csv
import io

from django.contrib.auth import get_user_model
from django.http import Http404, HttpResponse
from django.views.decorators.http import require_http_methods

from . import security as S
from .base import diff, done, owner_view, page, to_int
from .i18n import strings

User = get_user_model()


def _T(request):
    return strings(request.owner_lang)


# ============================================================ founders
def _members_ctx():
    from core import founders as F, plans
    rows = []
    for u in F.members()[:300]:
        try:
            eff = plans.effective_plan(u)
        except Exception:
            eff = u.plan
        rows.append({"u": u, "eff": eff, "lifetime": plans.lifetime_founder(u)})
    return rows


@require_http_methods(["GET", "POST"])
@owner_view()
def founders(request):
    from core import founders as F
    T = _T(request)
    n = F.months()
    ctx, status = {"months": n}, 200
    if request.method == "POST":
        action = request.POST.get("action", "")
        reason = request.POST.get("reason", "").strip()[:200]
        if action == "preview":
            text = request.POST.get("numbers", "")
            res = F.resolve(text, request.POST.getlist("uid"))
            if not (res["users"] or res["unknown"] or res["invalid"]):
                ctx["error"] = T["fm_err_empty"]
                status = 400
            else:
                rows = F.preview_rows(res["users"], n)
                ctx.update({"rows": rows, "unknown": res["unknown"],
                            "invalid": res["invalid"], "numbers": text,
                            "back": request.POST.get("back", "")
                            if request.POST.get("back", "").isdigit() else "",
                            "will_change": sum(1 for r in rows
                                               if r["outcome"] not in ("already", "lifetime"))})
                return page(request, "owner/founders_preview.html", ctx, nav="founders")
        elif action == "apply":
            ids = [i for i in (to_int(v) for v in request.POST.getlist("uid")) if i]
            if not ids:
                ctx["error"] = T["fm_err_empty"]
                status = 400
            elif not reason:
                ctx["error"] = T["err_reason"]
                status = 400
            elif request.POST.get("confirm") != "on":
                ctx["error"] = T["fm_err_confirm"]
                status = 400
            else:
                counts = {}
                for u in User.objects.filter(pk__in=ids[:F.MAX_BULK]):
                    outcome, before, after = F.grant(u, actor=request.owner,
                                                     reason=reason, n=n)
                    counts[outcome] = counts.get(outcome, 0) + 1
                    if before != after:
                        b, a = diff(before, after)
                        S.audit(request, request.owner, "founders.grant",
                                "user:%s" % u.pk, before=b,
                                after={**a, "_months": n, "_outcome": outcome,
                                       "_reason": reason})
                S.audit(request, request.owner, "founders.bulk", "users:%d" % len(ids),
                        after={"months": n, "outcomes": counts, "_reason": reason})
                back = request.POST.get("back", "")
                if back.isdigit():
                    return done("/owner/users/%s" % back, "granted")
                return done("/owner/founders", "granted")
        elif action == "revoke":
            uid = to_int(request.POST.get("uid"))
            u = User.objects.filter(pk=uid).first() if uid else None
            if u is None:
                raise Http404
            if not reason:
                ctx["error"] = T["err_reason"]
                status = 400
            else:
                changed, before, after = F.revoke(u, actor=request.owner, reason=reason)
                if changed:
                    b, a = diff(before, after)
                    S.audit(request, request.owner, "founders.revoke", "user:%s" % u.pk,
                            before=b, after={**a, "_reason": reason})
                back = request.POST.get("back", "")
                if back.isdigit():
                    return done("/owner/users/%s" % back, "revoked")
                return done("/owner/founders", "revoked")
        else:
            raise Http404
    ctx["members"] = _members_ctx()
    ctx["seats"] = _seats_ctx()   # p5-growth: automatic Founding seats
    return page(request, "owner/founders.html", ctx, status=status, nav="founders")


def _seats_ctx():
    """p5-growth: automatic numbered Founding seats (first N activated)."""
    from django.db.models import Sum
    from core import growth as G
    from core.models import FoundingSeat
    c = G.cfg()
    agg = FoundingSeat.objects.aggregate(cr=Sum("credits"), cost=Sum("cost_bdt"))
    return {"total": int(c["founding_auto_seats"]), "credits": int(c["founding_seat_credits"]),
            "need": int(c["invite_activation_days"]),
            "taken": FoundingSeat.objects.count(),
            "credits_given": int(agg["cr"] or 0), "cost": float(agg["cost"] or 0),
            "latest": list(FoundingSeat.objects.select_related("user")
                           .order_by("-number")[:50])}


# ============================================================ feedback
_FB_PAGE = 50


def _fb_filtered(request):
    from core.models import FeedbackReport
    qs = FeedbackReport.objects.select_related("user")
    st = request.GET.get("status", "")
    cat = request.GET.get("cat", "")
    if st in FeedbackReport.STATUSES:
        qs = qs.filter(status=st)
    else:
        st = ""
    if cat in FeedbackReport.CATEGORIES:
        qs = qs.filter(category=cat)
    else:
        cat = ""
    return qs, st, cat


@require_http_methods(["GET"])
@owner_view()
def feedback_list(request):
    from core.models import FeedbackReport
    from django.db.models import Count
    qs, st, cat = _fb_filtered(request)
    pg = max(1, to_int(request.GET.get("page"), 1) or 1)
    total = qs.count()
    rows = list(qs[(pg - 1) * _FB_PAGE: pg * _FB_PAGE])
    counts = {r["status"]: r["n"] for r in
              FeedbackReport.objects.values("status").annotate(n=Count("id"))}
    return page(request, "owner/feedback_list.html", {
        "rows": rows, "st": st, "cat": cat, "total": total, "page_no": pg,
        "has_next": pg * _FB_PAGE < total, "statuses": FeedbackReport.STATUSES,
        "categories": FeedbackReport.CATEGORIES,
        "counts": [(s, counts.get(s, 0)) for s in FeedbackReport.STATUSES],
    }, nav="feedback")


@require_http_methods(["GET"])
@owner_view()
def feedback_csv(request):
    qs, st, cat = _fb_filtered(request)
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(["id", "created_at", "status", "category", "user_id", "user_name",
                "note", "owner_note", "has_screenshot", "app_version", "app_build",
                "device_model", "os_version", "language", "route"])
    n = 0
    for r in qs[:5000]:
        n += 1
        w.writerow([r.id, r.created_at.isoformat(), r.status, r.category, r.user_id,
                    _csv_safe(r.user.name or r.user.username), _csv_safe(r.note),
                    _csv_safe(r.owner_note), "yes" if r.screenshot else "no",
                    _csv_safe(r.app_version), _csv_safe(r.app_build),
                    _csv_safe(r.device_model), _csv_safe(r.os_version),
                    r.language, _csv_safe(r.route)])
    S.audit(request, request.owner, "feedback.export", "feedback",
            after={"rows": n, "status": st, "category": cat})
    resp = HttpResponse("﻿" + buf.getvalue(), content_type="text/csv; charset=utf-8")
    resp["Content-Disposition"] = 'attachment; filename="assisto-feedback.csv"'
    return resp


def _csv_safe(v):
    """Neutralise spreadsheet formula injection (=, +, -, @ at the start)."""
    s = str(v or "")
    return "'" + s if s[:1] in ("=", "+", "-", "@", "\t", "\r") else s


def _fb_state(r):
    return {"status": r.status, "owner_note": r.owner_note}


@require_http_methods(["GET", "POST"])
@owner_view()
def feedback_detail(request, pk):
    from core.models import FeedbackReport
    T = _T(request)
    r = FeedbackReport.objects.select_related("user").filter(pk=pk).first()
    if r is None:
        raise Http404
    ctx, status = {}, 200
    if request.method == "POST":
        new_status = request.POST.get("status", "")
        note = request.POST.get("owner_note", "").strip()[:2000]
        if new_status not in FeedbackReport.STATUSES:
            ctx["error"] = T["fb_err_status"]
            status = 400
        else:
            before = _fb_state(r)
            r.status, r.owner_note = new_status, note
            r.save(update_fields=["status", "owner_note", "updated_at"])
            b, a = diff(before, _fb_state(r))
            if a:
                S.audit(request, request.owner, "feedback.update", "feedback:%s" % r.pk,
                        before=b, after=a)
                return done("/owner/feedback/%d" % r.pk)
            return done("/owner/feedback/%d" % r.pk, "nothing")
    shot = ""
    if r.screenshot:
        try:
            shot = r.screenshot.url
        except Exception:
            shot = ""
    ctx.update({"r": r, "shot": shot, "statuses": FeedbackReport.STATUSES})
    return page(request, "owner/feedback_detail.html", ctx, status=status, nav="feedback")
