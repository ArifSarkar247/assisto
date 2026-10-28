"""agent-core: Owner Admin -> Agent runs. Runs, success rate, credits, real
provider cost (AIUsage feature "agent:*" books into the same AI router caps),
per-topic split, user feedback and one run's MASKED audit trail. Owner-only;
goal text is shown masked (phone / NID / account numbers are tokens)."""
from datetime import timedelta

from django.db.models import Avg, Count, Q, Sum
from django.http import Http404
from django.utils import timezone
from django.views.decorators.http import require_http_methods

from .base import owner_view, page, to_int

_PAGE = 50
_DAYS = (1, 7, 30)


@require_http_methods(["GET"])
@owner_view()
def agent_runs(request):
    from core.models import AgentRun, AIUsage
    days = to_int(request.GET.get("days"), 7) or 7
    if days not in _DAYS:
        days = 7
    since = timezone.now() - timedelta(days=days)
    st = request.GET.get("state") or ""
    if st not in AgentRun.STATES:
        st = ""
    base = AgentRun.objects.filter(created_at__gte=since)
    agg = base.aggregate(n=Count("id"), done=Count("id", filter=Q(state="done")),
                         failed=Count("id", filter=Q(state__in=("failed", "budget", "expired"))),
                         credits=Sum("credits_spent"), cost=Sum("cost_usd"),
                         steps=Avg("steps_used"), llm=Avg("llm_calls"),
                         up=Count("id", filter=Q(feedback=1)),
                         down=Count("id", filter=Q(feedback=-1)))
    finished = (agg["done"] or 0) + (agg["failed"] or 0)
    ai_cost = float(AIUsage.objects.filter(created_at__gte=since, feature__startswith="agent:")
                    .aggregate(s=Sum("cost_usd"))["s"] or 0.0)
    topics = list(base.values("topic").annotate(
        n=Count("id"), done=Count("id", filter=Q(state="done")),
        credits=Sum("credits_spent"), cost=Sum("cost_usd")).order_by("-n"))
    for t in topics:
        t["pct"] = int(round(100 * t["done"] / t["n"])) if t["n"] else 0
    errors = list(base.exclude(error_code="").values("error_code")
                  .annotate(n=Count("id")).order_by("-n")[:10])
    qs = base.select_related("goal")
    if st:
        qs = qs.filter(state=st)
    pg = max(1, to_int(request.GET.get("page"), 1) or 1)
    total = qs.count()
    rows = list(qs[(pg - 1) * _PAGE: pg * _PAGE])
    return page(request, "owner/agent_runs.html", {
        "rows": rows, "st": st, "states": AgentRun.STATES, "days": days, "day_opts": _DAYS,
        "total": total, "page_no": pg, "has_next": pg * _PAGE < total,
        "n": agg["n"] or 0, "done": agg["done"] or 0,
        "success_pct": int(round(100 * (agg["done"] or 0) / finished)) if finished else 0,
        "credits": agg["credits"] or 0, "cost": round(float(agg["cost"] or 0), 4),
        "ai_cost": round(ai_cost, 4),
        "avg_steps": round(float(agg["steps"] or 0), 1), "avg_llm": round(float(agg["llm"] or 0), 1),
        "up": agg["up"] or 0, "down": agg["down"] or 0, "topics": topics, "errors": errors,
        "nudges": _nudge_stats(since),
        "obs": _obs(since), "obs_cfg": _obs_cfg(),
        "fb": _fb_stats(),
    }, nav="agent_runs")


def _fb_stats():
    """AF-12: review-queue counts (never breaks the runs page)."""
    try:
        from core.agentcore import feedback_cases as FB
        return FB.stats()
    except Exception:
        return None


def _obs(since):
    """AF-8: latency / error / cost / approval numbers (never breaks the page)."""
    try:
        from core.agentcore import observability as AO
        return AO.stats(since)
    except Exception:
        return None


def _obs_cfg():
    from core.agentcore import observability as AO
    return [(k, v) for k, v in AO.cfg().items()]


@require_http_methods(["POST"])
@owner_view()
def agent_obs_save(request):
    """AF-8: the owner's alert thresholds (OwnerAudit action agent_obs)."""
    from core.agentcore import observability as AO
    from . import security as S
    from .base import done
    clean, problems = AO.validate(request.POST)
    if problems or not clean:
        S.audit(request, request.owner, "agent_obs", "thresholds", after={"rejected": problems}, ok=False)
        return done("/owner/agent-runs", "invalid")
    before, after = AO.save(clean, actor=request.owner)
    S.audit(request, request.owner, "agent_obs", "thresholds", before=before, after=after)
    return done("/owner/agent-runs")


def _nudge_stats(since):
    """agent-proactive: per-trigger nudge stats (never breaks the runs page)."""
    try:
        from core.agentcore import proactive as P
        return P.stats_by_trigger(since)
    except Exception:
        return []


@require_http_methods(["GET"])
@owner_view()
def agent_run_detail(request, pk):
    from core.models import AgentRun
    run = AgentRun.objects.filter(pk=pk).select_related("goal", "user").first()
    if run is None:
        raise Http404
    return page(request, "owner/agent_run.html", {
        "run": run, "steps": list(run.steps.order_by("no")),
        "events": list(run.audit.order_by("id")[:300]),
        "approvals": list(run.approvals.all()),
    }, nav="agent_runs")


# ------------------------------------------------------------------ AF-12 feedback -> test cases
FB_AUDIT = "agent_feedback_case"


@require_http_methods(["GET"])
@owner_view()
def agent_feedback_queue(request):
    """AF-12: thumbs-down runs waiting to become eval cases (all MASKED)."""
    from core.agentcore import feedback_cases as FB
    from core.agentcore import tools as TL
    pending, decided = FB.queue()
    lang = getattr(request, "owner_lang", "bn")
    rows = [{"id": r.pk, "d": r.data, "tools": FB.allowed_tools(r.data)} for r in pending]
    return page(request, "owner/agent_feedback.html", {
        "rows": rows, "decided": [{"id": r.pk, "d": r.data} for r in decided],
        "all_tools": [t.name for t in TL.TOOLS], "states": FB.STATES, "stats": FB.stats(),
        "lang": lang,
    }, nav="agent_runs")


@require_http_methods(["POST"])
@owner_view()
def agent_feedback_decide(request, pk):
    from core.agentcore import feedback_cases as FB
    from core.models import PaCollectionItem
    from . import security as S
    from .base import done
    row = PaCollectionItem.objects.filter(pk=pk, collection=FB.COLLECTION).first()
    if row is None:
        raise Http404
    back = "/owner/agent-runs/feedback"
    action = request.POST.get("action") or ""
    if action not in ("approve", "reject"):
        return done(back, "invalid")
    before = {"status": row.data.get("status")}
    clean = None
    if action == "approve":
        clean, problems = FB.validate_decision(row.data, request.POST)
        if problems:
            S.audit(request, request.owner, FB_AUDIT, "fb-%s" % row.data.get("run_id"),
                    after={"rejected": problems}, ok=False)
            return done(back, "invalid")
    FB.decide(row, action, clean, actor=request.owner)
    S.audit(request, request.owner, FB_AUDIT, "fb-%s" % row.data.get("run_id"), before=before,
            after={"status": row.data.get("status"), "tools": (clean or {}).get("expect_tools"),
                   "forbid": (clean or {}).get("expect_forbid")})
    return done(back)
