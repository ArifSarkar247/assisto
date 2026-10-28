"""AF-6 — the agent eval sets against the REAL model (owner-approved spend).

    manage.py agent_eval --live --topic business --limit 50 --budget-usd 2

  * runs the topic's committed eval set (+ the approved feedback cases of
    that topic, AF-12) through the real agent loop and the real AI router
    (planner = core.ai.generate, charge agent_plan) — graded by the same
    deterministic graders as CI (harness.grade);
  * HARD spend cap: before EVERY planner call the worst case of that call
    (prompt x1.5 + full output + thinking headroom, at the dearest model the
    call could reach) is added to what was already spent; if that would pass
    the budget the call is not made and the eval stops. It refuses to start
    without an explicit --budget-usd, above the configured maximum
    (settings / env AGENT_EVAL_MAX_USD, default $10), in CI, or with no key;
  * one pass per configured planner model (provider pinned with
    ai.only_provider) -> per-model scorecard + comparison;
  * every case runs inside a transaction that is ROLLED BACK (eval users,
    seed data, runs, credits: nothing stays); the real spend is then booked
    again into the AI usage log as feature "eval.agent.<topic>" (user none)
    and Profit Guard, so the router's daily caps and the owner's cost pages
    see it; nothing is ever sent (SMS sandboxed, test-mode chat channels,
    pushes off);
  * a JSON + Markdown report is written to --out.

CI never runs this live: core.tests_afeval_live drives the same code with
the scripted brain at the router's provider seam to prove the cap, the
refusals and the report.
"""
import itertools
import json
import os
import random
import time
from contextlib import ExitStack
from unittest import mock

from django.conf import settings
from django.db import transaction
from django.utils import timezone

from . import goalsets, harness, money_goals, multi_goals
from .. import planner as PL

DEFAULT_MAX_USD = 10.0
TOPICS = ("money",) + goalsets.TOPICS + ("multi",)
FEATURE = "eval.agent.%s"


class Refused(Exception):
    pass


def max_budget():
    v = getattr(settings, "AGENT_EVAL_MAX_USD", None) or os.environ.get("AGENT_EVAL_MAX_USD")
    try:
        v = float(v)
    except (TypeError, ValueError):
        v = DEFAULT_MAX_USD
    return v if v > 0 else DEFAULT_MAX_USD


def load_cases(topic):
    from .. import feedback_cases as FB
    if topic == "money":
        cs = money_goals.cases()
    elif topic == "multi":
        cs = multi_goals.cases()
    elif topic in goalsets.TOPICS:
        cs = goalsets.load(topic)
    else:
        raise Refused("unknown topic %r (one of: %s)" % (topic, ", ".join(TOPICS)))
    if topic != "multi":
        cs = cs + FB.load_committed(topic)
    return cs


def configured_models(only=None):
    """[(provider, model)] the planner can use now, in failover order."""
    from ... import ai, ai_router
    from ... import ai_config as C
    conf = ai_router.cfg()
    keys = {n for n, _ in ai._providers()}
    out = [(p, C.model_for(conf, p, PL.PLANNER_TIER, "main")) for p in C.ORDER["main"] if p in keys]
    if only:
        out = [m for m in out if m[0] in only]
    return out


def worst_call_usd(prompt, provider=None):
    """Upper bound for ONE planner call of this prompt."""
    from ... import ai, ai_router
    from ... import ai_config as C
    from ... import ai_prompt as P
    from ...ai_evals.runner import est_tokens
    conf = ai_router.cfg()
    tin = int(est_tokens(P.system_prompt("Reply with JSON only.") + prompt) * 1.5) + 50
    effort = C.effort_for(conf, PL.PLANNER_TIER, "main")
    tout = 700 + max(1024, ai._THINK_HEADROOM.get(effort, 4096))
    provs = [provider] if provider else list(C.ORDER["main"])
    return max(C.cost_usd(conf, C.model_for(conf, p, PL.PLANNER_TIER, "main"), tin, tout)
               for p in provs)


def estimate(cases, models):
    """Expected USD (not the cap): ~1.5 planner calls per case, typical output."""
    from ... import ai_router
    from ... import ai_config as C
    from ...ai_evals.runner import est_tokens
    from .. import tools as TL
    from .. import topics as TP
    conf = ai_router.cfg()
    total = 0.0
    for prov, model in models:
        for c in cases:
            tp = TP.combined(c.get("topics") or [c["topic"]])
            req = PL.PlanRequest(user=None, topic=c["topic"], topic_rules=tp["rules"],
                                 tools=[t for t in (TL.get(n) for n in tp["tools"]) if t],
                                 goal_masked=c["goal"], lang=c.get("lang", "bn"))
            tin = est_tokens(PL.build_task(req) + PL.build_data(req)) + 400
            total += 1.5 * C.cost_usd(conf, model, tin, 350)
    return round(total, 4)


class Meter:
    def __init__(self, budget):
        self.budget = float(budget)
        self.spent = 0.0
        self.calls = 0
        self.stopped = False
        self.prompts = []
        self.provider = None

    def can_call(self, prompt):
        return self.spent + worst_call_usd(prompt, self.provider) <= self.budget


class CappedPlanner:
    """The production RouterPlanner behind the hard cap."""
    def __init__(self, meter, inner=None):
        self.meter = meter
        self.inner = inner or PL.RouterPlanner()

    def plan(self, req):
        from ... import ai
        prompt = PL.build_task(req) + PL.build_data(req)
        if self.meter.stopped or not self.meter.can_call(prompt):
            self.meter.stopped = True
            raise ai.AIUnavailable("budget")
        res = self.inner.plan(req)
        self.meter.spent += float(res.cost_usd or 0)
        self.meter.calls += 1
        self.meter.prompts.append((res.prompt_task or "") + (res.prompt_data or ""))
        return res


class _Rollback(Exception):
    pass


def _sandbox():
    """Nothing leaves the server during a live eval."""
    st = ExitStack()
    st.enter_context(mock.patch("core.sms_service.send_sms",
                                return_value={"ok": False, "reason": "sms_not_configured", "credits": 0}))
    st.enter_context(mock.patch("core.push.notify_owner", return_value={}))
    st.enter_context(mock.patch("core.agentcore.approval_push.notify", return_value=None))
    return st


def _run_one(case, meter):
    """-> (reasons, usage rows, ms). Everything the case wrote is rolled back."""
    from ...models import AIUsage
    box = {}
    t0 = time.monotonic()
    try:
        with transaction.atomic():
            n0 = len(meter.prompts)
            since = AIUsage.objects.order_by("-id").values_list("id", flat=True).first() or 0
            seam = type("Seam", (), {"prompts": []})()
            reasons = harness.run_case(case, seam)
            # the PII grader sees what the provider really got
            from .. import trust as T
            if any(T.has_raw_pii(p) for p in meter.prompts[n0:]):
                reasons.append("raw PII sent to the AI provider")
            box["usage"] = list(AIUsage.objects.filter(id__gt=since, feature="agent:plan").values(
                "model", "provider", "input_tokens", "output_tokens", "cost_usd", "tier",
                "task_class", "latency_ms", "ok", "hops", "attempts", "cache_read_tokens",
                "cache_write_tokens", "error_kind"))
            box["reasons"] = reasons
            raise _Rollback
    except _Rollback:
        pass
    except Exception as e:  # noqa: BLE001 — one broken case never stops the scorecard
        box.setdefault("usage", [])
        box["reasons"] = ["error: %s" % type(e).__name__]
    return box["reasons"], box["usage"], int((time.monotonic() - t0) * 1000)


def _book(topic, usage):
    """Re-book the real spend after the rollback (router caps + Profit Guard)."""
    from ...models import AIUsage
    from ... import billing
    for u in usage:
        AIUsage.objects.create(user=None, feature=(FEATURE % topic)[:40], credits_charged=0, **u)
        if u.get("ok") and u.get("cost_usd"):
            try:
                billing.record_ai_cost_usd(float(u["cost_usd"]))
            except Exception:
                pass


def run(topic, limit=0, budget_usd=0.0, models=None, out=print, cases=None):
    """The live eval. Caller has checked the refusals (check_refusals)."""
    cases = list(cases if cases is not None else load_cases(topic))[: limit or None]
    models = models or configured_models()
    meter = Meter(budget_usd)
    seq0 = harness._SEQ
    harness._SEQ = itertools.count(97_000_000 + random.randint(0, 900_000))   # unlikely phones
    report = {"topic": topic, "mode": "live", "budget_usd": float(budget_usd), "cases": len(cases),
              "started_at": timezone.now().isoformat(), "models": []}
    PL.set_planner(CappedPlanner(meter))
    from ... import ai
    try:
        with _sandbox():
            for prov, model in models:
                meter.provider = prov
                row = {"provider": prov, "model": model, "ran": 0, "passed": 0, "failed": [],
                       "stopped_at": None, "cost_usd": 0.0, "llm_calls": 0, "ms": []}
                spent0, calls0 = meter.spent, meter.calls
                with ai.only_provider(prov):
                    for c in cases:
                        if meter.stopped:
                            break
                        reasons, usage, ms = _run_one(c, meter)
                        _book(topic, usage)
                        if meter.stopped:          # the cap hit inside this case: not graded
                            row["stopped_at"] = c["id"]
                            break
                        row["ran"] += 1
                        row["ms"].append(ms)
                        if reasons:
                            row["failed"].append([c["id"], reasons])
                        else:
                            row["passed"] += 1
                row["cost_usd"] = round(meter.spent - spent0, 6)
                row["llm_calls"] = meter.calls - calls0
                row["pass_pct"] = round(100.0 * row["passed"] / row["ran"], 1) if row["ran"] else None
                row["avg_cost_usd"] = round(row["cost_usd"] / row["ran"], 6) if row["ran"] else None
                ms_sorted = sorted(row.pop("ms"))
                row["p50_ms"] = ms_sorted[len(ms_sorted) // 2] if ms_sorted else None
                report["models"].append(row)
                out("%s/%s: %s/%s passed, $%.4f" % (prov, model, row["passed"], row["ran"], row["cost_usd"]))
                if meter.stopped:
                    out("budget reached: spent $%.4f of $%.2f — stopping" % (meter.spent, meter.budget))
                    break
    finally:
        PL.set_planner(None)
        harness._SEQ = seq0
    report.update(spent_usd=round(meter.spent, 6), stopped=meter.stopped, llm_calls=meter.calls,
                  finished_at=timezone.now().isoformat())
    return report


def scorecard_md(rep):
    lines = ["# Agent eval (live) — %s" % rep["topic"], "",
             "Budget $%.2f · spent $%.4f · %d planner calls%s" % (
                 rep["budget_usd"], rep["spent_usd"], rep["llm_calls"],
                 " · STOPPED at the budget" if rep["stopped"] else ""), "",
             "| model | ran | passed | pass % | cost $ | $ / case | p50 ms |",
             "|---|---|---|---|---|---|---|"]
    for m in rep["models"]:
        lines.append("| %s/%s | %d | %d | %s | %.4f | %s | %s |" % (
            m["provider"], m["model"], m["ran"], m["passed"],
            "—" if m["pass_pct"] is None else m["pass_pct"], m["cost_usd"],
            "—" if m["avg_cost_usd"] is None else "%.5f" % m["avg_cost_usd"],
            "—" if m["p50_ms"] is None else m["p50_ms"]))
    if len(rep["models"]) > 1:
        ranked = sorted((m for m in rep["models"] if m["ran"]),
                        key=lambda m: (-(m["pass_pct"] or 0), m["avg_cost_usd"] or 0))
        if ranked:
            lines += ["", "Model comparison: best %s/%s (%s%%)" % (
                ranked[0]["provider"], ranked[0]["model"], ranked[0]["pass_pct"])]
    for m in rep["models"]:
        if m["failed"]:
            lines += ["", "## Failures — %s/%s (first 20)" % (m["provider"], m["model"])]
            lines += ["- %s: %s" % (cid, "; ".join(r)[:300]) for cid, r in m["failed"][:20]]
    return "\n".join(lines) + "\n"


def write_report(rep, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    stem = "agent_eval_live_%s_%s" % (rep["topic"], timezone.localtime().strftime("%Y%m%d-%H%M%S"))
    jp = os.path.join(out_dir, stem + ".json")
    with open(jp, "w", encoding="utf-8") as f:
        json.dump(rep, f, ensure_ascii=False, indent=1, default=str)
    with open(os.path.join(out_dir, stem + ".md"), "w", encoding="utf-8") as f:
        f.write(scorecard_md(rep))
    return jp


def check_refusals(topic, budget_usd, env=None):
    """Raise Refused for every reason the live eval must not start."""
    env = os.environ if env is None else env
    if env.get("CI") or env.get("GITHUB_ACTIONS"):
        raise Refused("live evals never run in CI")
    if topic not in TOPICS:
        raise Refused("unknown topic %r (one of: %s)" % (topic, ", ".join(TOPICS)))
    if budget_usd is None or float(budget_usd or 0) <= 0:
        raise Refused("refusing: --budget-usd B (> 0) is required to spend real money")
    if float(budget_usd) > max_budget():
        raise Refused("refusing: --budget-usd %.2f is above the configured maximum $%.2f "
                      "(AGENT_EVAL_MAX_USD)" % (float(budget_usd), max_budget()))
    if not configured_models():
        raise Refused("no AI provider key is configured — nothing to run")
