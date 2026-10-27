"""Orchestrator: goal -> plan -> act -> observe -> re-plan, server-side.

A run is a resumable state machine stored in the DB (AgentRun + AgentStep):
  * advance() takes a LEASE (conditional UPDATE, so two workers never drive
    the same run), works until the run finishes, needs an approval, or its
    time slice ends, then releases the lease. A crashed worker's lease simply
    expires and the next tick resumes from the last stored step.
  * every tool step has an idempotency key (ac:<run>:<no>); a step that is
    already done is never re-run, and write tools also dedupe on the key.
  * budgets per run: tool steps, LLM calls, credits, wall-clock deadline;
    hitting one ends the run in state "budget" — never a silent overspend.
  * risk external/money/delete -> an AgentApproval; the run pauses in
    waiting_approval until the user decides (approve() / reject()).
"""
import logging
import time as _time
from dataclasses import dataclass
from datetime import timedelta

from django.db import transaction
from django.db.models import Q
from django.utils import timezone

from . import planner as PL
from . import tools as TL
from . import topics as TP
from . import trust as T
from .contract import SchemaError, ToolError, validate

log = logging.getLogger(__name__)

LEASE_S = 60
RUN_TTL = timedelta(hours=48)          # incl. waiting for an approval
MAX_INVALID_PLANS = 1                  # one "fix your JSON" retry, then fail
# per effective plan (core.plans): runs/day, credits/run, tool steps/run
LIMITS = {
    "free": {"runs_per_day": 3, "credits": 15, "steps": 5},
    "premium": {"runs_per_day": 20, "credits": 30, "steps": 8},
    "business": {"runs_per_day": 50, "credits": 60, "steps": 15},
}
MAX_LLM_CALLS = 3


class AgentError(Exception):
    def __init__(self, code, status=400):
        self.code = code
        self.status = status
        super().__init__(code)


@dataclass
class Ctx:
    user: object
    now: object
    lang: str = "bn"
    play: bool = False
    idem_key: str = ""


def limits_for(user):
    try:
        from .. import plans
        return LIMITS.get(plans.effective_plan(user), LIMITS["free"])
    except Exception:
        return LIMITS["free"]


def flag_on(user, play=False):
    try:
        from .. import feature_flags as FF
        from . import FLAG
        return FF.is_on(FLAG, user, play)
    except Exception:
        return False


# ------------------------------------------------------------------ start
def start(user, text, topic="", channel="chat", client_id="", lang="bn", play=False,
          inline=True, now=None):
    """Create (idempotently) a goal + run; optionally drive it right away."""
    from ..models import AgentGoal, AgentRun
    text = (text or "").strip()
    if not text or len(text) > 1000:
        raise AgentError("bad_goal")
    client_id = (client_id or "")[:64]
    if client_id:
        g = AgentGoal.objects.filter(user=user, client_id=client_id).first()
        if g is not None:
            return g.runs.order_by("-id").first()
    now = now or timezone.now()
    lim = limits_for(user)
    if channel != "eval":
        day0 = timezone.localtime(now).replace(hour=0, minute=0, second=0, microsecond=0)
        if AgentRun.objects.filter(user=user, created_at__gte=day0).count() >= lim["runs_per_day"]:
            raise AgentError("daily_cap", 429)
    topic = topic if topic in TP.TOPICS else TP.classify(text)
    vault = T.Vault()
    masked = vault.mask(text)
    with transaction.atomic():
        goal = AgentGoal.objects.create(
            user=user, topic=topic, channel=channel if channel in AgentGoal.CHANNELS else "chat",
            text_sealed=T.seal({"t": text}), text_masked=masked[:600], client_id=client_id)
        run = AgentRun(goal=goal, user=user, topic=topic, max_steps=lim["steps"],
                       max_llm_calls=MAX_LLM_CALLS, max_credits=lim["credits"],
                       deadline_at=now + RUN_TTL)
        T.save_vault(run, vault)
        run.save()
        T.audit(run, "run.created", topic=topic or "general", channel=goal.channel,
                goal=masked[:300])
    if inline:
        advance(run, lang=lang, play=play)
        run.refresh_from_db()
    return run


# ------------------------------------------------------------------ lease
def _lease(run, now):
    from ..models import AgentRun
    n = (AgentRun.objects.filter(pk=run.pk, state__in=("queued", "running"))
         .filter(Q(lease_until__isnull=True) | Q(lease_until__lt=now))
         .update(state="running", lease_until=now + timedelta(seconds=LEASE_S),
                 started_at=run.started_at or now))
    return n == 1


def _release(run):
    from ..models import AgentRun
    AgentRun.objects.filter(pk=run.pk).update(lease_until=None)


def _finish(run, state, error="", answer=None):
    run.state = state
    run.error_code = error[:40]
    run.finished_at = timezone.now()
    run.lease_until = None
    if answer is not None:
        run.answer_sealed = T.seal({"a": answer})
    run.save()
    vault = T.vault_of(run)
    T.audit(run, "run." + state, error=error,
            answer=vault.mask(answer)[:400] if answer else "",
            credits_total=run.credits_spent)


# ------------------------------------------------------------------ advance
def advance(run, lang="bn", play=False, time_budget_s=20.0):
    """Drive one run as far as it can go now. Returns the run's state."""
    from ..models import AgentRun
    now = timezone.now()
    if run.state not in ("queued", "running"):
        return run.state
    if not _lease(run, now):
        return run.state
    run.refresh_from_db()
    ctx = Ctx(user=run.user, now=now, lang=lang, play=play)
    t0 = _time.monotonic()
    try:
        while True:
            run.refresh_from_db()
            if run.state == "cancelled":
                return run.state
            if run.deadline_at and timezone.now() > run.deadline_at:
                _finish(run, "budget", "deadline")
                return run.state
            if _time.monotonic() - t0 > time_budget_s:
                AgentRun.objects.filter(pk=run.pk).update(state="queued")
                return "queued"
            r = _tick(run, ctx)
            if r != "continue":
                return run.state
    except Exception as e:  # noqa: BLE001 — a run never takes the API down
        log.exception("agentcore: run %s crashed", run.pk)
        run.refresh_from_db()
        if run.state in AgentRun.OPEN_STATES:
            _finish(run, "failed", "internal:" + type(e).__name__)
        return run.state
    finally:
        _release(run)


def _tick(run, ctx):
    """One unit of work. -> 'continue' | 'stop'."""
    steps = list(run.steps.order_by("no"))
    pending = [s for s in steps if s.kind == "tool" and s.state in ("pending", "waiting_approval")]
    if pending:
        st = _exec_step(run, pending[0], ctx)
        return "stop" if st == "wait" else "continue"
    plans = [s for s in steps if s.kind == "plan"]
    last = plans[-1] if plans else None
    if last is not None and last.state == "done":
        plan = T.unseal(last.result_sealed).get("plan") or {}
        tool_steps = [s for s in steps if s.kind == "tool" and s.no > last.no]
        if plan.get("done") and tool_steps and all(s.state == "done" for s in tool_steps):
            _finish(run, "done", answer=_template_answer(run, tool_steps, ctx.lang))
            return "stop"
    return _plan(run, steps, ctx)


def _observations(run, steps, vault):
    out = []
    for s in steps:
        if s.kind != "tool" or s.state not in ("done", "failed", "rejected"):
            continue
        if s.state == "done":
            out.append({"tool": s.tool, "ok": True,
                        "result": vault.mask_obj(T.unseal(s.result_sealed).get("r"))})
        else:
            out.append({"tool": s.tool, "ok": False, "error": s.error_code or s.state})
    return out


def _allowed(run, ctx):
    tp = TP.get(run.topic)
    return tp, TL.available(ctx, tp["tools"])


def _plan(run, steps, ctx):
    from ..models import AgentStep
    from .. import ai, billing
    from ..logic import pricing
    if run.llm_calls >= run.max_llm_calls:
        _finish(run, "budget", "llm_calls")
        return "stop"
    need = pricing.credit_cost(PL.CHARGE_ACTION, billing.cfg())
    if run.credits_spent + need > run.max_credits:
        _finish(run, "budget", "credits")
        return "stop"
    ok, why = billing.guard_can(run.user, PL.CHARGE_ACTION)
    if not ok:
        _finish(run, "failed", "credits" if why == "insufficient" else why)
        return "stop"
    vault = T.vault_of(run)
    tp, allowed = _allowed(run, ctx)
    invalid = sum(1 for s in steps if s.kind == "plan" and s.state == "failed")
    obs = _observations(run, steps, vault)
    T.save_vault(run, vault)           # observation masking may mint tokens
    run.save(update_fields=["vault_sealed", "updated_at"])
    req = PL.PlanRequest(user=run.user, topic=run.topic or "general", topic_rules=tp["rules"],
                         tools=allowed, goal_masked=run.goal.text_masked,
                         observations=obs, lang=ctx.lang,
                         now_iso=timezone.localtime(ctx.now).isoformat(timespec="minutes"),
                         attempt=invalid,
                         last_error=(steps[-1].error_code if steps and steps[-1].kind == "plan"
                                     and steps[-1].state == "failed" else ""))
    t0 = _time.monotonic()
    try:
        res = PL.get_planner().plan(req)
    except ai.AIUnavailable as e:
        _finish(run, "failed", "ai_" + e.reason)
        return "stop"
    no = (steps[-1].no + 1) if steps else 1
    run.llm_calls += 1
    run.credits_spent += int(res.credits or 0)
    run.cost_usd = round(run.cost_usd + float(res.cost_usd or 0), 6)
    run.save(update_fields=["llm_calls", "credits_spent", "cost_usd", "updated_at"])
    pstep = AgentStep(run=run, no=no, kind="plan", idem_key="ac:%d:%d" % (run.pk, no),
                      credits=int(res.credits or 0), cost_usd=float(res.cost_usd or 0),
                      latency_ms=int((_time.monotonic() - t0) * 1000))
    try:
        plan = PL.parse(res.raw)
        names = {t.name for t in allowed}
        for i, s in enumerate(plan["steps"]):
            if s["tool"] not in names:
                raise PL.PlanError("tool_not_allowed", s["tool"])
            try:
                validate(s["args"], TL.get(s["tool"]).input_schema, "$.steps[%d].args" % i)
            except SchemaError as e:
                raise PL.PlanError("bad_args", str(e))
        used = sum(1 for s in steps if s.kind == "tool")
        if used + len(plan["steps"]) > run.max_steps:
            raise PL.PlanError("too_many_steps")
    except PL.PlanError as e:
        pstep.state, pstep.error_code = "failed", e.code
        pstep.summary = vault.mask(e.detail)[:400]
        pstep.finished_at = timezone.now()
        pstep.save()
        T.audit(run, "plan.invalid", step=pstep, credits=pstep.credits, error=e.code,
                detail=pstep.summary)
        if e.code == "too_many_steps":
            _finish(run, "budget", "steps")
            return "stop"
        if invalid + 1 > MAX_INVALID_PLANS:
            _finish(run, "failed", "invalid_plan")
            return "stop"
        return "continue"
    pstep.state = "done"
    pstep.result_sealed = T.seal({"plan": plan})
    pstep.summary = (", ".join(s["tool"] for s in plan["steps"]) or "answer")[:400]
    pstep.finished_at = timezone.now()
    pstep.save()
    T.audit(run, "plan.ok", step=pstep, credits=pstep.credits, tools=[s["tool"] for s in plan["steps"]],
            done=bool(plan.get("done")))
    if not plan["steps"]:
        _finish(run, "done", answer=vault.unmask(plan["answer"].strip()))
        return "stop"
    for i, s in enumerate(plan["steps"]):
        t = TL.get(s["tool"])
        n = no + 1 + i
        AgentStep.objects.create(run=run, no=n, kind="tool", tool=t.name, tool_version=t.version,
                                 risk=t.risk, idem_key="ac:%d:%d" % (run.pk, n),
                                 args_sealed=T.seal({"a": s["args"]}),
                                 summary=vault.mask(t.label_en)[:400])
    return "continue"


def _rate_limited(run, tool, now):
    from ..models import AgentStep
    n = AgentStep.objects.filter(run__user_id=run.user_id, tool=tool.name, state="done",
                                 finished_at__gte=now - timedelta(hours=1)).count()
    return n >= tool.rate_per_hour


def _exec_step(run, step, ctx):
    """-> 'done' | 'failed' | 'wait'."""
    from ..models import AgentApproval
    tool = TL.get(step.tool)
    vault = T.vault_of(run)
    masked_args = T.unseal(step.args_sealed).get("a") or {}
    if tool is None or tool.version != step.tool_version:
        return _fail_step(run, step, "tool_gone")
    if tool.needs_approval:
        ap = AgentApproval.objects.filter(step=step).first()
        if ap is None or ap.status == "pending":
            if ap is None:
                args = vault.unmask_obj(masked_args)
                tctx = Ctx(user=run.user, now=ctx.now, lang=ctx.lang, play=ctx.play,
                           idem_key=step.idem_key)
                if tool.approval_title:
                    tbn, ten = (tool.approval_title(tctx, args, "bn"),
                                tool.approval_title(tctx, args, "en"))
                else:
                    tbn, ten = tool.label_bn + "?", tool.label_en + "?"
                T.request_approval(run, step, tool, masked_args, vault.mask(tbn), vault.mask(ten))
                T.save_vault(run, vault)
            step.state = "waiting_approval"
            step.save(update_fields=["state"])
            run.state = "waiting_approval"
            run.save(update_fields=["state", "vault_sealed", "updated_at"])
            return "wait"
        if ap.status != "approved":
            step.state, step.error_code = "rejected", "rejected_by_user" if ap.status == "rejected" else ap.status
            step.finished_at = timezone.now()
            step.save()
            T.audit(run, "tool.rejected", step=step, tool=tool.ref)
            return "failed"
    if _rate_limited(run, tool, ctx.now):
        return _fail_step(run, step, "rate_limited")
    args = vault.unmask_obj(masked_args)
    tctx = Ctx(user=run.user, now=ctx.now, lang=ctx.lang, play=ctx.play, idem_key=step.idem_key)
    t0 = _time.monotonic()
    try:
        out = tool.run(tctx, args)
        validate(out, tool.output_schema, "$out")
    except ToolError as e:
        return _fail_step(run, step, e.code)
    except SchemaError:
        log.error("agentcore: %s returned output outside its schema", tool.ref)
        return _fail_step(run, step, "bad_output")
    step.state = "done"
    step.result_sealed = T.seal({"r": out})
    step.summary = vault.mask(tool.summarize(out, ctx.lang))[:400]
    step.latency_ms = int((_time.monotonic() - t0) * 1000)
    step.finished_at = timezone.now()
    step.save()
    T.save_vault(run, vault)       # summaries may have minted new tokens
    run.steps_used += 1
    run.save(update_fields=["steps_used", "vault_sealed", "updated_at"])
    T.audit(run, "tool.done", step=step, tool=tool.ref, risk=tool.risk, summary=step.summary)
    return "done"


def _fail_step(run, step, code):
    step.state, step.error_code = "failed", code[:40]
    step.finished_at = timezone.now()
    step.save()
    run.steps_used += 1
    run.save(update_fields=["steps_used", "updated_at"])
    T.audit(run, "tool.failed", step=step, tool=step.tool, error=code)
    return "failed"


def _template_answer(run, tool_steps, lang):
    lines = []
    for s in tool_steps:
        t = TL.get(s.tool)
        out = T.unseal(s.result_sealed).get("r")
        if t and out is not None:
            lines.append(t.summarize(out, lang))
    return "\n".join(lines)


# Approvals reach the phone through the foreground poll (GET /agent-core/
# approvals) for now; a dedicated push kind + notification actions is work
# package WP-APP (needs an app channel, see AGENT_CORE_DESIGN_BN.md §12).


# ------------------------------------------------------------------ decisions
def decide(user, approval_id, decision, lang="bn", play=False):
    """approve | reject one pending approval (idempotent), then resume."""
    from ..models import AgentApproval
    if decision not in ("approve", "reject"):
        raise AgentError("bad_decision")
    with transaction.atomic():
        ap = (AgentApproval.objects.select_for_update()
              .filter(pk=approval_id, user=user).first())
        if ap is None:
            raise AgentError("not_found", 404)
        if ap.status == "pending":
            if timezone.now() > ap.expires_at:
                ap.status = "expired"
            else:
                ap.status = "approved" if decision == "approve" else "rejected"
            ap.decided_at = timezone.now()
            ap.save(update_fields=["status", "decided_at"])
            T.audit(ap.run, "approval." + ap.status, step=ap.step)
            run = ap.run
            if run.state == "waiting_approval":
                run.state = "running"
                run.save(update_fields=["state", "updated_at"])
            step = ap.step
            if step.state == "waiting_approval":
                step.state = "pending"
                step.save(update_fields=["state"])
    run = ap.run
    run.refresh_from_db()
    if run.state == "running":
        advance(run, lang=lang, play=play)
        run.refresh_from_db()
    return ap, run


def cancel(user, run_id):
    from ..models import AgentRun
    run = AgentRun.objects.filter(pk=run_id, user=user).first()
    if run is None:
        raise AgentError("not_found", 404)
    if run.state in AgentRun.OPEN_STATES:
        run.steps.filter(state__in=("pending", "waiting_approval")).update(state="skipped")
        run.approvals.filter(status="pending").update(status="expired", decided_at=timezone.now())
        _finish(run, "cancelled", "user")
    return run


def answer_of(run):
    return (T.unseal(run.answer_sealed) or {}).get("a") or ""


# ------------------------------------------------------------------ worker
def tick(limit=20, time_budget_s=50.0, now=None):
    """Worker entry (manage.py agent_core_run): resume queued/running runs whose
    lease is free; expire runs past their deadline. Returns runs advanced."""
    from ..models import AgentRun
    now = now or timezone.now()
    for run in AgentRun.objects.filter(state__in=AgentRun.OPEN_STATES, deadline_at__lt=now)[:200]:
        run.approvals.filter(status="pending").update(status="expired", decided_at=now)
        _finish(run, "expired", "deadline")
    t0 = _time.monotonic()
    done = 0
    qs = (AgentRun.objects.filter(state__in=("queued", "running"))
          .filter(Q(lease_until__isnull=True) | Q(lease_until__lt=now))
          .order_by("created_at")[:limit])
    for run in qs:
        if _time.monotonic() - t0 > time_budget_s:
            break
        if not flag_on(run.user):
            continue
        advance(run, time_budget_s=max(1.0, time_budget_s - (_time.monotonic() - t0)))
        done += 1
    return done
