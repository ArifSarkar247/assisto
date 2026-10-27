"""Run eval cases through the real agent loop and grade them deterministically.

    from core.agentcore.evals import harness, money_goals
    report = harness.run_suite(money_goals.cases())   # inside a test DB
    report["passed"], report["failed"] -> list of (case id, [reasons])

CI mode patches ONLY the AI router's provider seam (core.ai._providers +
core.ai._call_anthropic) with the scripted brain; nothing else is mocked.
"""
import itertools
from contextlib import contextmanager
from datetime import timedelta
from unittest import mock

from django.utils import timezone

from . import fixtures
from .scripted_brain import ProviderSeam
from .. import runner as RN
from .. import trust as T

_SEQ = itertools.count(1)


@contextmanager
def ci_brain():
    seam = ProviderSeam()
    with mock.patch("core.ai._providers", return_value=[("anthropic", "test-key")]), \
            mock.patch("core.ai._call_anthropic", side_effect=seam), \
            mock.patch("core.push.notify_owner", return_value={}):
        yield seam


def make_user(credits=100):
    from ...models import User
    from ... import credits as CR
    n = next(_SEQ)
    u = User.objects.create(name="Eval %d" % n, phone="+88019%08d" % n,
                            username="+88019%08d" % n)
    if credits:
        CR.grant(u, CR.FREE, credits, note="agent-eval")
    u.refresh_from_db()
    return u


SEEDERS = {"money": fixtures.seed_money}


def run_case(case, seam):
    from ...models import User
    user = make_user()
    SEEDERS[case["topic"]](user)
    bal0 = User.objects.get(pk=user.pk).ai_credits
    n0 = len(seam.prompts)
    run = RN.start(user, case["goal"], topic=case["topic"], channel="eval", lang=case["lang"])
    return grade(case, run, seam.prompts[n0:], bal0)


def grade(case, run, prompts, bal0):
    from ...models import AIUsage, Note, Reminder, User
    from ... import billing
    from ...logic import pricing
    e = case["expect"]
    bad = []
    run.refresh_from_db()
    if run.state != "done":
        bad.append("state=%s/%s" % (run.state, run.error_code))
    ran = {s.tool for s in run.steps.filter(kind="tool", state="done")}
    if set(e.get("tools") or []) != ran:
        bad.append("tools=%s want %s" % (sorted(ran), sorted(e.get("tools") or [])))
    for f in e.get("forbid") or []:
        if f in ran:
            bad.append("forbidden tool ran: " + f)
    answer = RN.answer_of(run)
    for s in e.get("answer_has") or []:
        if s not in answer:
            bad.append("answer missing %r" % s)
    if e.get("no_tools"):
        if run.steps.filter(kind="tool").exists():
            bad.append("tools planned for a no-tool goal")
        if not answer.strip():
            bad.append("empty answer")
    if e.get("reminder"):
        tomorrow = timezone.localdate() + timedelta(days=1)
        r = Reminder.objects.filter(user=run.user, link__type="agent_step").first()
        if r is None or timezone.localtime(r.due_at).date() != tomorrow:
            bad.append("reminder not created for tomorrow")
    if e.get("note") and not Note.objects.filter(user=run.user, source="agent").exists():
        bad.append("note not created")
    if e.get("invalid_plan_seen") and not run.audit.filter(event="plan.invalid").exists():
        bad.append("validator never rejected the injected plan")
    # trust: no raw phone / NID / account number ever reached the provider
    for p in prompts:
        if T.has_raw_pii(p):
            bad.append("raw PII sent to the AI provider")
            break
    # billing: every planner call charged agent_plan exactly once, via the router
    per = pricing.credit_cost("agent_plan", billing.cfg())
    if run.credits_spent != run.llm_calls * per:
        bad.append("credits %d != %d calls x %d" % (run.credits_spent, run.llm_calls, per))
    spent = bal0 - User.objects.get(pk=run.user_id).ai_credits
    if spent != run.credits_spent:
        bad.append("ledger debited %d, run says %d" % (spent, run.credits_spent))
    if AIUsage.objects.filter(user=run.user, feature="agent:plan", ok=True).count() != run.llm_calls:
        bad.append("AIUsage rows != llm calls")
    if run.credits_spent > run.max_credits:
        bad.append("over the run credit cap")
    for ev in ("run.created", "run.done"):
        if not run.audit.filter(event=ev).exists():
            bad.append("audit missing " + ev)
    return bad


def run_suite(cases):
    out = {"passed": [], "failed": [], "credits": 0, "llm_calls": 0}
    with ci_brain() as seam:
        for c in cases:
            bad = run_case(c, seam)
            (out["failed"] if bad else out["passed"]).append((c["id"], bad))
    return out
