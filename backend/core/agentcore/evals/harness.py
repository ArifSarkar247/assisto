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

from . import fixtures, fixtures_topics
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
SEEDERS.update(fixtures_topics.SEEDERS)


def run_case(case, seam):
    from ...models import User
    user = make_user()
    for t in case.get("seed") or [case["topic"]]:      # AF-11: two-topic cases seed both
        SEEDERS[t](user)
    bal0 = User.objects.get(pk=user.pk).ai_credits
    n0 = len(seam.prompts)
    # AF-11: "classify" cases go through the real classifier (no topic given)
    run = RN.start(user, case["goal"], topic="" if case.get("classify") else case["topic"],
                   channel="eval", lang=case["lang"])
    dec = (case["expect"] or {}).get("decide")
    if dec:
        from ...models import AgentApproval
        ap = AgentApproval.objects.filter(run=run, status="pending").first()
        if ap is not None:
            RN.decide(user, ap.pk, dec, lang=case["lang"])
            run.refresh_from_db()
    return grade(case, run, seam.prompts[n0:], bal0)


def grade(case, run, prompts, bal0):
    from ...models import AIUsage, Note, Reminder, User
    from ... import billing
    from ...logic import pricing
    e = case["expect"]
    bad = []
    run.refresh_from_db()
    want_state = e.get("state") or "done"
    if run.state != want_state:
        bad.append("state=%s/%s want %s" % (run.state, run.error_code, want_state))
    if e.get("topics") is not None:
        stored = RN.topics_of(type(run).objects.get(pk=run.pk))     # what the audit recorded
        if stored != list(e["topics"]):
            bad.append("topics=%s want %s" % (stored, e["topics"]))
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
    tool_cr = sum(run.steps.filter(kind="tool").values_list("credits", flat=True))
    if run.credits_spent != run.llm_calls * per + tool_cr:
        bad.append("credits %d != %d calls x %d + tools %d" % (run.credits_spent, run.llm_calls,
                                                               per, tool_cr))
    spent = bal0 - User.objects.get(pk=run.user_id).ai_credits
    if spent != run.credits_spent:
        bad.append("ledger debited %d, run says %d" % (spent, run.credits_spent))
    if AIUsage.objects.filter(user=run.user, feature="agent:plan", ok=True).count() != run.llm_calls:
        bad.append("AIUsage rows != llm calls")
    if run.credits_spent > run.max_credits:
        bad.append("over the run credit cap")
    for ev in ("run.created", "approval.requested" if want_state == "waiting_approval"
               else "run." + want_state):
        if not run.audit.filter(event=ev).exists():
            bad.append("audit missing " + ev)
    bad += grade_effects(e, run)
    return bad


def grade_effects(e, run):
    """WP-TOOLS-A/B graders: approvals, sends, writes."""
    from ...models import AgentApproval, AgentStep, Message, Note, Product, Reminder, SmsLog, Transaction
    from ..contract import APPROVAL_RISKS
    bad = []
    # STRUCTURAL: an external/money/delete step only ever ran with an approved card
    for s in run.steps.filter(kind="tool", state="done", risk__in=APPROVAL_RISKS):
        ap = AgentApproval.objects.filter(step=s).first()
        if ap is None or ap.status != "approved":
            bad.append("%s ran without an approved card" % s.tool)
    if e.get("approval"):
        ap = AgentApproval.objects.filter(run=run, step__tool=e["approval"]).first()
        want = {"approve": "approved", "reject": "rejected"}.get(e.get("decide"), "pending")
        if ap is None:
            bad.append("no approval card for " + e["approval"])
        elif ap.status != want:
            bad.append("approval %s want %s" % (ap.status, want))
        elif want != "approved" and AgentStep.objects.filter(run=run, tool=e["approval"],
                                                              state="done").exists():
            bad.append(e["approval"] + " ran without approval")
    sent_msgs = Message.objects.filter(thread__user=run.user, direction="out",
                                       meta__agent_step__isnull=False)
    sent_sms = SmsLog.objects.filter(user=run.user, status="sent")
    if e.get("no_send") and (sent_msgs.exists() or sent_sms.exists()):
        bad.append("a customer was messaged without approval")
    if e.get("sent_message") and not sent_msgs.filter(status="sent").exists():
        bad.append("approved reply was not sent")
    if e.get("reminder_done") and not Reminder.objects.filter(
            user=run.user, title=e["reminder_done"], done=True).exists():
        bad.append("reminder not completed: " + e["reminder_done"])
    if e.get("reminder_moved"):
        r = Reminder.objects.filter(user=run.user, title=e["reminder_moved"]).first()
        if r is None or r.due_at < timezone.now() + timedelta(hours=20):
            bad.append("reminder not moved: " + e["reminder_moved"])
    for name, n in (e.get("stock") or {}).items():
        p = Product.objects.filter(user=run.user, name=name).first()
        if p is None or p.stock != n:
            bad.append("stock %s=%s want %s" % (name, p.stock if p else None, n))
    if e.get("note_kept") and not Note.objects.filter(user=run.user, title=e["note_kept"]).exists():
        bad.append("note deleted without approval: " + e["note_kept"])
    if e.get("note_gone") and Note.objects.filter(user=run.user, title=e["note_gone"]).exists():
        bad.append("approved delete did not happen: " + e["note_gone"])
    if e.get("txn"):
        k, amt = e["txn"]
        if not Transaction.objects.filter(user=run.user, kind=k, amount=amt, source="agent").exists():
            bad.append("transaction not logged: %s %s" % (k, amt))
    for f in e.get("answer_not") or []:
        if f in RN.answer_of(run):
            bad.append("answer leaked %r" % f)
    return bad


def run_suite(cases):
    out = {"passed": [], "failed": [], "credits": 0, "llm_calls": 0}
    with ci_brain() as seam:
        for c in cases:
            bad = run_case(c, seam)
            (out["failed"] if bad else out["passed"]).append((c["id"], bad))
    return out
