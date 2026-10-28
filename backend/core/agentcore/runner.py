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
import json
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
from .contract import APPROVAL_RISKS, SchemaError, ToolError, validate

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
# AF-18: a goal may follow up the user's own run finished this recently; the
# planner then sees up to MAX_PREVIOUS earlier turns (masked, inside DATA)
FOLLOW_UP_WINDOW = timedelta(hours=2)
MAX_PREVIOUS = 2


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
    charged: int = 0               # credits a tool itself charged (e.g. tagada SMS)


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
          inline=True, now=None, topic2="", follow_up=None):
    """Create (idempotently) a goal + run; optionally drive it right away.

    AF-11: with no explicit `topic` the classifier may pick TWO topics
    (topics.plan_topics); an explicit `topic` stays single unless `topic2`
    names the second one too. The run's own `topic` is the primary; the pair
    is in the run.created audit (topics_of()).

    AF-18: `follow_up` = the id of the user's previous run in this
    conversation (own, finished, within FOLLOW_UP_WINDOW; else ignored). A
    goal with no topic of its own keeps that run's topics; "undo that" takes
    back that run's own-data writes (undo.py, no AI call)."""
    from ..models import AgentGoal, AgentRun
    text = (text or "").strip()
    from . import crisis_guard as CG
    crisis = CG.detect(text[:4000])
    if crisis["crisis"]:
        text = text[:1000]              # AF-3: a long crisis message still gets help
    if not text or len(text) > 1000:
        raise AgentError("bad_goal")
    client_id = (client_id or "")[:64]
    if client_id:
        g = AgentGoal.objects.filter(user=user, client_id=client_id).first()
        if g is not None:
            return g.runs.order_by("-id").first()
    now = now or timezone.now()
    lim = limits_for(user)
    # AF-3: a crisis (self-harm, abuse, a child in danger, a medical
    # emergency) is answered BEFORE any cap or AI call: calm fixed line,
    # 999 + owner-confirmed helplines, an OFFER to tell family; 0 credits,
    # nothing else is done in this turn. Only {score, category} is logged.
    if crisis["crisis"]:
        return _crisis_run(user, text, crisis, channel, client_id, lang, lim, now)
    prev = _prev_turn(user, follow_up, now) if follow_up else None
    if prev is not None:
        from . import undo as UN
        if UN.is_undo(text):            # deterministic, 0 credits, before any cap
            return UN.undo_run(user, text, prev, channel, client_id, lang, lim, now)
    if channel != "eval":
        day0 = timezone.localtime(now).replace(hour=0, minute=0, second=0, microsecond=0)
        if AgentRun.objects.filter(user=user, created_at__gte=day0).count() >= lim["runs_per_day"]:
            raise AgentError("daily_cap", 429)
    if topic in TP.TOPICS:
        pair = [topic] + ([topic2] if topic2 in TP.TOPICS and topic2 != topic else [])
    else:
        pair = TP.plan_topics(text)
        if not pair and prev is not None:          # "and last month?" keeps the topic
            pair = [k for k in topics_of(prev) if k]
    pair = pair[:TP.MAX_TOPICS]
    topic = pair[0] if pair else ""
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
        extra = {"topics": pair, "secondary": pair[1]} if len(pair) > 1 else {}
        if prev is not None:
            extra["follow_up"] = prev.pk
        T.audit(run, "run.created", topic=topic or "general", channel=goal.channel,
                goal=masked[:300], **extra)
    run._topics = pair or [""]
    # AF-4: the goal's toxicity SCORE is logged (never the words); the user's
    # own wording to their own assistant is not refused — but nothing toxic
    # is ever SENT for them (_exec_step) or answered back (_finish).
    from .. import ai_guard as G
    tx = G.toxicity(text)
    if tx["toxic"]:
        T.audit(run, "guard.toxicity_in", **G.tox_log(tx))
    if "memory" in pair:
        # WP-MEMORY: "remember my password / PIN / OTP / card / NID" is refused
        # BEFORE any AI call — the secret never reaches a model, 0 credits.
        from . import memory as MEM
        why = MEM.secret_kind(text)
        if why:
            T.audit(run, "guard.secret", kind=why)
            _finish(run, "done", answer=MEM.tool_remember_sum({"refused": why}, lang))
            return run
    if inline:
        advance(run, lang=lang, play=play)
        run.refresh_from_db()
    return run


def _crisis_run(user, text, crisis, channel, client_id, lang, lim, now):
    """AF-3: a finished run whose answer is the fixed crisis line. The goal
    text is kept only SEALED (the user's own history); the masked copy that
    Owner Admin and the audit can see is empty."""
    from ..models import AgentGoal, AgentRun
    from . import crisis_guard as CG
    with transaction.atomic():
        goal = AgentGoal.objects.create(
            user=user, topic="safety", channel=channel if channel in AgentGoal.CHANNELS else "chat",
            text_sealed=T.seal({"t": text}), text_masked="", client_id=client_id)
        run = AgentRun(goal=goal, user=user, topic="safety", max_steps=lim["steps"],
                       max_llm_calls=MAX_LLM_CALLS, max_credits=lim["credits"],
                       deadline_at=now + RUN_TTL)
        T.save_vault(run, T.Vault())
        run.save()
        T.audit(run, "run.created", topic="safety", channel=goal.channel, goal="")
        T.audit(run, "guard.crisis", **CG.log_detail(crisis))
    run._lang = lang
    reply, _card = CG.respond(user, crisis, lang, surface="agent", event_id="run:%d" % run.pk)
    _finish(run, "done", answer=reply)
    return run


def _prev_turn(user, follow_up, now):
    """AF-18: the run `follow_up` names, when it may be followed up."""
    from ..models import AgentRun
    try:
        pk = int(follow_up)
    except (TypeError, ValueError):
        return None
    prev = AgentRun.objects.filter(pk=pk, user=user).select_related("goal").first()
    if prev is None or prev.state in AgentRun.OPEN_STATES:
        return None
    if (prev.finished_at or prev.created_at) < (now or timezone.now()) - FOLLOW_UP_WINDOW:
        return None
    if crisis_of(prev):
        return None                      # a crisis handover is never continued by the planner
    return prev


def follow_up_of(run):
    ev = run.audit.filter(event="run.created").order_by("id").first()
    return (ev.detail or {}).get("follow_up") if ev is not None else None


def previous_turns(run, vault):
    """AF-18: up to MAX_PREVIOUS earlier turns, oldest first, MASKED with
    this run's vault: [{goal, answer, tools, undo}]."""
    from ..models import AgentRun
    out, cur, seen = [], follow_up_of(run), {run.pk}
    while cur and cur not in seen and len(out) < MAX_PREVIOUS:
        seen.add(cur)
        p = AgentRun.objects.filter(pk=cur, user_id=run.user_id).select_related("goal").first()
        if p is None:
            break
        goal = (T.unseal(p.goal.text_sealed) or {}).get("t") or p.goal.text_masked or ""
        ans = answer_of(p) if p.state == "done" else ""
        ev = p.audit.filter(event="run.created").order_by("id").first()
        d = (ev.detail or {}) if ev is not None else {}
        out.insert(0, {"goal": vault.mask(goal)[:600], "answer": vault.mask(ans)[:600],
                       "tools": sorted({s.tool for s in p.steps.filter(kind="tool", state="done")}),
                       "undo": bool(d.get("undo"))})
        cur = d.get("follow_up")
    return out


def topics_of(run):
    """AF-11: [primary] or [primary, secondary] for this run ([""] = general)."""
    cached = getattr(run, "_topics", None)
    if cached is not None:
        return list(cached)
    ev = run.audit.filter(event="run.created").order_by("id").first()
    pair = list((ev.detail or {}).get("topics") or []) if ev is not None else []
    if len(pair) < 2 or pair[0] != run.topic or any(k not in TP.TOPICS for k in pair):
        pair = [run.topic or ""]
    run._topics = pair[:TP.MAX_TOPICS]
    return list(run._topics)


def topic_scopes(run, lang="bn"):
    """AF-11: the plan card's explicit scope line per topic of this run."""
    return [TP.scope(k, lang) for k in topics_of(run)]


def crisis_of(run):
    """AF-3: {"score", "category"} when this run was a crisis handover."""
    ev = run.audit.filter(event="guard.crisis").first()
    return dict(ev.detail or {}) if ev is not None else None


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
    if answer is not None:
        # WP-MEMORY gap fix: the health rule is enforced in CODE on every
        # final answer (no diagnosis / medicine / dose / therapy; doctor-999
        # line), not only asked of the model in the topic instructions.
        from . import health_guard as HG
        answer, removed = HG.filter_answer(answer, _health_topic(run), _answer_lang(run))
        if removed:
            T.audit(run, "guard.health", removed=removed)
        # AF-4 OUTBOUND: an abusive / hateful / threatening / sexual final
        # answer is never shown — honest fallback, score audited
        from .. import ai_guard as G
        tx = G.toxicity(answer)
        if tx["toxic"]:
            T.audit(run, "guard.toxicity", **G.tox_log(tx))
            answer = G.SAFE_FALLBACK_LINE[_answer_lang(run)]
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


def _health_topic(run):
    """The health rule applies when health is the primary OR the second topic."""
    try:
        return "health" if "health" in topics_of(run) else run.topic
    except Exception:  # noqa: BLE001
        return run.topic


def _answer_lang(run):
    lang = getattr(run, "_lang", "") or getattr(run.user, "language", "bn") or "bn"
    return "en" if lang == "en" else "bn"


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
    run._lang = lang
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
            _finish(run, "done", answer=_template_answer(run, _answer_steps(run, steps, tool_steps),
                                                         ctx.lang))
            return "stop"
        # the user REJECTED a card of a finished plan: answer from templates
        # (0 credits) instead of paying for another planner call
        if plan.get("done") and tool_steps and all(s.state in ("done", "rejected") for s in tool_steps) \
                and any(s.state == "rejected" and s.error_code == "rejected_by_user" for s in tool_steps):
            _finish(run, "done", answer=_template_answer(run, _answer_steps(run, steps, tool_steps),
                                                         ctx.lang))
            return "stop"
    return _plan(run, steps, ctx)


def _answer_steps(run, steps, last_plan_steps):
    """AF-11: a two-topic run answers from EVERY finished tool step (both
    topics' results), a single-topic run from its last plan's steps."""
    if len(topics_of(run)) < 2:
        return last_plan_steps
    return [s for s in steps if s.kind == "tool" and s.state in ("done", "rejected")]


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
    tp = TP.combined(topics_of(run))
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
    memory = _memory_for(run, vault)
    previous = previous_turns(run, vault)      # AF-18 (masked; may mint tokens)
    run._previous = previous
    _note_taint(run, obs, memory)      # AF-5: instructions found inside DATA
    T.save_vault(run, vault)           # observation/memory masking may mint tokens
    run.save(update_fields=["vault_sealed", "updated_at"])
    pair = topics_of(run)
    req = PL.PlanRequest(user=run.user, topic=run.topic or "general", topic_rules=tp["rules"],
                         topics=[k or "general" for k in pair],
                         second_rules=tp.get("second_rules", ""),
                         tool_topics={t.name: TP.tool_topic(t.name, pair) for t in allowed}
                         if len(pair) > 1 else {},
                         tools=allowed, goal_masked=run.goal.text_masked,
                         observations=obs, memory=memory, lang=ctx.lang, previous=previous,
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
            # AF-11: each tool is checked against ITS OWN topic's allow-list
            # (one of this run's <= 2 topics); anything else is rejected
            if s["tool"] not in names or not TP.tool_topic(s["tool"], pair):
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
    extra = ({"tool_topics": [TP.tool_topic(s["tool"], pair) for s in plan["steps"]]}
             if len(pair) > 1 else {})
    T.audit(run, "plan.ok", step=pstep, credits=pstep.credits, tools=[s["tool"] for s in plan["steps"]],
            done=bool(plan.get("done")), **extra)
    if not plan["steps"]:
        ans = _checked_answer(run, plan["answer"].strip(), steps, obs, memory, tp, ctx)
        _finish(run, "done", answer=vault.unmask(ans))
        return "stop"
    for i, s in enumerate(plan["steps"]):
        t = TL.get(s["tool"])
        n = no + 1 + i
        AgentStep.objects.create(run=run, no=n, kind="tool", tool=t.name, tool_version=t.version,
                                 risk=t.risk, idem_key="ac:%d:%d" % (run.pk, n),
                                 args_sealed=T.seal({"a": s["args"]}),
                                 summary=vault.mask(t.label_en)[:400])
    return "continue"


# ------------------------------------------------------------------ AF-1 checked answers
# Numbers the product itself states in fixed lines (the 999 emergency line).
TRUSTED_NUMBERS = ("999",)
NOT_SURE_LINE = {
    "bn": "দুঃখিত, এই উত্তরের সংখ্যাগুলো আপনার তথ্যের সাথে মিলিয়ে নিশ্চিত হতে পারিনি, তাই বলছি না। "
          "আপনার হিসাব থেকে দেখে দিতে বললে আমি সেটা খুঁজে দেখব।",
    "en": "Sorry, I couldn't check the numbers in that answer against your data, so I won't "
          "state them. Ask me to look it up in your records and I will.",
}


def grounding_sources(run, ctx, obs, memory, tp):
    """Everything a final answer's numbers may come from: the user's own goal,
    this run's tool results, the scoped memory, the topic rules, today's date
    (+/- 7 days) and the product's fixed lines. All MASKED (same space as the
    planner's answer)."""
    from . import health_guard as HG
    now = timezone.localtime(ctx.now)
    days = " ".join((now + timedelta(days=d)).strftime("%Y-%m-%d %H:%M")
                    for d in range(-7, 8))
    src = [run.goal.text_masked or "", json.dumps(obs or [], ensure_ascii=False, default=str),
           json.dumps(memory or [], ensure_ascii=False, default=str), (tp or {}).get("rules") or "",
           days, " ".join(TRUSTED_NUMBERS), HG.DOCTOR_999_LINE["bn"], HG.DOCTOR_999_LINE["en"]]
    src += [o["result"] for o in obs or [] if isinstance(o.get("result"), dict)]
    # AF-18: a follow-up may repeat a number from an earlier turn of this chat
    src += [json.dumps(getattr(run, "_previous", None) or [], ensure_ascii=False, default=str)]
    return src


def _checked_answer(run, masked_answer, steps, obs, memory, tp, ctx):
    """AF-1 (Agentforce 'grounded answers' parity), PRODUCTION check: every
    number / amount / date in the model's own final text must trace to this
    run's tool results, the user's goal or saved memory. An invented one ->
    the answer is rewritten from the tool templates (0 credits) when tools
    ran, else an honest "not sure" line. Audit guard.grounding (counts and
    kinds only, never the numbers)."""
    from . import health_guard as HG
    from .. import ai_guard as G
    lang = _answer_lang(run)
    # AF-5: a sentence that relays an instruction / phishing ask found in the
    # data ("your account is blocked, call ⟦PHONE_3⟧ and share the OTP") is
    # dropped before anything else — the user sees an honest line instead.
    masked_answer, echoed = G.scrub_injection_echo(masked_answer, run.goal.text_masked, lang)
    if echoed:
        T.audit(run, "guard.injection_echo", removed=echoed)
    clean, _ = HG.filter_answer(masked_answer, _health_topic(run), lang)
    clean = T.TOKEN_RX.sub(" ", clean)        # ⟦ACCT_12⟧ is a token, not a number
    bad = G.ungrounded_numbers(clean, *grounding_sources(run, ctx, obs, memory, tp))
    if not bad:
        return masked_answer
    done = [s for s in steps if s.kind == "tool" and s.state in ("done", "rejected")]
    T.audit(run, "guard.grounding", invented=len(bad),
            kinds=sorted({b["type"] for b in bad}), action="template" if done else "not_sure")
    if done:
        return _template_answer(run, done, lang) or NOT_SURE_LINE[lang]
    return NOT_SURE_LINE[lang]


def answer_sources(run, lang="bn"):
    """AF-1: which tools / data the final answer stands on — [{tool, label,
    label_bn, label_en, step}] from this run's DONE tool steps (+ the saved
    memory when it was used). Shown on the answer card as 'উৎস / Sources'."""
    out = []
    for s in run.steps.filter(kind="tool", state="done").order_by("no"):
        t = TL.get(s.tool)
        bn_l, en_l = (t.label_bn, t.label_en) if t else (s.tool, s.tool)
        out.append({"tool": s.tool, "label": bn_l if lang == "bn" else en_l,
                    "label_bn": bn_l, "label_en": en_l, "step": s.no})
    if run.audit.filter(event="memory.used").exists():
        out.append({"tool": "memory", "label": "আপনার রাখা তথ্য" if lang == "bn" else "Your saved facts",
                    "label_bn": "আপনার রাখা তথ্য", "label_en": "Your saved facts", "step": None})
    return out


def answer_check(run):
    """AF-1: 'checked' (no invented number found) | 'rewritten' (an invented
    number was replaced) | '' (no final answer yet)."""
    if run.state != "done":
        return ""
    return "rewritten" if run.audit.filter(event="guard.grounding").exists() else "checked"


def _memory_for(run, vault):
    """WP-MEMORY: only the goal's relevant, masked, size-capped life-graph
    facts (memory.for_goal) — never the whole graph; never a suggestion or a
    sensitive fact. A memory problem never breaks a run."""
    from . import memory as MEM
    try:
        goal = (T.unseal(run.goal.text_sealed) or {}).get("t") or run.goal.text_masked
        facts = MEM.for_goal(run.user, run.topic, goal, vault)
    except Exception:  # noqa: BLE001
        log.exception("agentcore: memory scope failed for run %s", run.pk)
        return []
    if facts:
        T.audit(run, "memory.used", count=len(facts), ids=[f["id"] for f in facts])
    return facts


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
    first_look = step.state == "pending" and not AgentApproval.objects.filter(step=step).exists()
    if tool.risk == "external" and first_look:
        # AF-4: a message / post the agent would send for the user is never
        # abusive / hateful / threatening / sexual — blocked before the
        # approval card, score audited (never the words)
        from .. import ai_guard as G
        tx = G.toxicity("\n".join(_strings(masked_args)))
        if tx["toxic"]:
            T.audit(run, "guard.toxicity", step=step, tool=tool.ref, **G.tox_log(tx))
            return _fail_step(run, step, "toxic_blocked")
    if first_look and tool.risk == "write_low" and _tainted(run):
        # AF-5: in a run that saw an instruction inside the data, an own-data
        # write may not carry a number taken from that data either
        why = _exfil(run, masked_args)
        if why:
            T.audit(run, "guard.exfil", step=step, tool=tool.ref, kind=why)
            return _fail_step(run, step, why)
    if first_look and tool.risk in APPROVAL_RISKS:
        # AF-5 STRUCTURAL: nothing that leaves the app may carry a phone /
        # NID / account / e-mail the USER did not type in this goal — a value
        # read from data (another customer's number, an attacker's number in
        # a chat) can never be sent out, whatever the model planned.
        why = _exfil(run, masked_args)
        if why:
            T.audit(run, "guard.exfil", step=step, tool=tool.ref, kind=why)
            return _fail_step(run, step, why)
        # recipients only from the user's OWN records, checked BEFORE a card is
        # shown (no "send to ⟦PHONE_3⟧?" card for a stranger)
        if tool.precheck is not None:
            pctx = Ctx(user=run.user, now=ctx.now, lang=ctx.lang, play=ctx.play, idem_key=step.idem_key)
            try:
                tool.precheck(pctx, vault.unmask_obj(masked_args))
            except ToolError as e:
                return _fail_step(run, step, e.code)
    # AF-5: after an instruction was seen inside the data, every own-data write
    # (reminder, note, money log, stock) also waits for the user's one tap.
    needs = tool.needs_approval or (tool.risk == "write_low" and tool.name not in SUGGEST_ONLY
                                    and _tainted(run))
    if needs:
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
                if _tainted(run):
                    tbn, ten = TAINT_PREFIX["bn"] + tbn, TAINT_PREFIX["en"] + ten
                new_ap = T.request_approval(run, step, tool, masked_args, vault.mask(tbn),
                                            vault.mask(ten))
                T.save_vault(run, vault)
                from . import approval_push      # WP-APP: push kind agent_approval
                approval_push.notify(new_ap, tool)
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
    step.credits = int(tctx.charged or 0)
    step.result_sealed = T.seal({"r": out})
    step.summary = vault.mask(tool.summarize(out, ctx.lang))[:400]
    step.latency_ms = int((_time.monotonic() - t0) * 1000)
    step.finished_at = timezone.now()
    step.save()
    T.save_vault(run, vault)       # summaries may have minted new tokens
    run.steps_used += 1
    run.credits_spent += step.credits     # the ledger was debited by the module itself
    run.save(update_fields=["steps_used", "credits_spent", "vault_sealed", "updated_at"])
    T.audit(run, "tool.done", step=step, credits=step.credits, tool=tool.ref, risk=tool.risk,
            summary=step.summary)
    return "done"


# ------------------------------------------------------------------ AF-5 helpers
# suggestion-only tools: the user approves on the "AI knows" page anyway
SUGGEST_ONLY = ("memory.remember", "memory.update")
TAINT_PREFIX = {"bn": "সাবধান: এই কাজের কথা এসেছে ডেটার ভেতরের লেখা থেকে — ",
                "en": "Careful: this came from text inside your data — "}


def _note_taint(run, obs, memory):
    """AF-5: audit guard.injection_seen once when a tool result or a saved
    fact carries an instruction to the assistant (tool names only, never
    the text). From then on own-data writes need approval."""
    from .. import ai_guard as G
    if run.audit.filter(event="guard.injection_seen").exists():
        return
    hit = sorted({o["tool"] for o in obs or [] if o.get("ok")
                  and any(G.injection_hits(x) for x in _strings(o.get("result")))})
    if any(G.injection_hits(m.get("fact") or "") for m in memory or []):
        hit.append("memory")
    if hit:
        T.audit(run, "guard.injection_seen", tools=hit)


def _tainted(run):
    return run.audit.filter(event="guard.injection_seen").exists()


def _exfil(run, masked_args):
    """'' or why an outgoing step's arguments carry a value the user never
    gave: raw PII (the planner typed a number) or a vault token minted from
    DATA instead of from the user's own goal."""
    txt = "\n".join(_strings(masked_args))
    if T.has_raw_pii(txt):
        return "pii_blocked"
    goal = run.goal.text_masked or ""
    if any(m.group(0) not in goal for m in T.TOKEN_RX.finditer(txt)):
        return "pii_exfil_blocked"
    return ""


def _strings(obj):
    if isinstance(obj, str):
        return [obj]
    if isinstance(obj, dict):
        return [x for v in obj.values() for x in _strings(v)]
    if isinstance(obj, (list, tuple)):
        return [x for v in obj for x in _strings(v)]
    return []


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
        if t and s.state == "rejected":
            lines.append("“%s” বাতিল করা হয়েছে — কিছু করা হয়নি।" % t.label_bn if lang == "bn"
                         else "“%s” was rejected — nothing was done." % t.label_en)
            continue
        out = T.unseal(s.result_sealed).get("r")
        if t and out is not None:
            lines.append(t.summarize(out, lang))
    return "\n".join(lines)


# Approvals reach the phone by push kind `agent_approval` (approval_push.py,
# Reject / Approve notification actions) AND the foreground poll (GET
# /agent-core/approvals) when push is unavailable.


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
