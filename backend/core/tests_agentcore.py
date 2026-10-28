"""agent-core: contract, trust layer, tools, run loop, approvals, budgets,
billing through the AI router seam, API gating. The planner LLM is mocked at
the router's provider seam (no key, no spend)."""
import json
from datetime import timedelta
from decimal import Decimal
from unittest import mock

from django.core.cache import cache
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import credits as CR
from core import feature_flags as FF
from core.agentcore import contract as C
from core.agentcore import planner as PL
from core.agentcore import runner as RN
from core.agentcore import tools as TL
from core.agentcore import topics as TP
from core.agentcore import trust as T
from core.agentcore.evals import harness as H
from core.models import (AgentApproval, AgentAuditEvent, AgentRun, AIUsage, BusinessProfile,
                         FeatureFlag, KhataEntry, KhataParty, Note, Reminder, User)


class _Scripted:
    """Planner override: returns queued raw outputs, records requests."""
    def __init__(self, *raws, credits=0):
        self.raws = list(raws)
        self.reqs = []
        self.credits = credits

    def plan(self, req):
        self.reqs.append(req)
        raw = self.raws.pop(0) if self.raws else json.dumps({"v": 1, "steps": [], "answer": "ok"})
        if not isinstance(raw, str):
            raw = json.dumps(raw, ensure_ascii=False)
        return PL.PlanResult(raw=raw, credits=self.credits)


def _user(n, credits=100):
    u = User.objects.create(name="U%d" % n, phone="+8801900%06d" % n, username="+8801900%06d" % n)
    if credits:
        CR.grant(u, CR.FREE, credits, note="t")
    u.refresh_from_db()
    return u


class ContractTests(TestCase):
    def test_validator(self):
        s = C.obj({"a": {"type": "integer", "minimum": 1}, "b": {"type": "string", "maxLength": 3}}, ("a",))
        C.validate({"a": 2, "b": "xy"}, s)
        for bad in ({}, {"a": 0}, {"a": "2"}, {"a": 1, "b": "long"}, {"a": 1, "z": 1}, {"a": True}):
            with self.assertRaises(C.SchemaError, msg=bad):
                C.validate(bad, s)

    def test_every_tool_contract_is_complete(self):
        names = set()
        for t in TL.TOOLS:
            self.assertNotIn(t.name, names)
            names.add(t.name)
            self.assertIn(t.risk, C.RISKS, t.name)
            self.assertGreaterEqual(t.version, 1)
            self.assertTrue(t.label_bn and t.label_en and t.desc)
            self.assertEqual(t.input_schema["type"], "object")
            self.assertFalse(t.input_schema.get("additionalProperties", True), t.name)
            self.assertTrue(t.topics, t.name)
            self.assertGreater(t.rate_per_hour, 0)
            json.dumps(t.spec())
            if t.risk in C.APPROVAL_RISKS:
                self.assertTrue(t.needs_approval)
        self.assertGreaterEqual(len(TL.TOOLS), 10)

    def test_topic_allow_lists_name_real_tools_and_no_risky_fallback(self):
        self.assertEqual(set(TP.TOPICS), {"family", "safety", "money", "business", "documents",
                                          "travel", "health", "learning"})
        for k, tp in TP.TOPICS.items():
            for n in tp["tools"]:
                self.assertIn(n, TL.REGISTRY, (k, n))
                self.assertIn(k, TL.REGISTRY[n].topics, (k, n))
        for n in TP.GENERAL["tools"]:
            self.assertNotIn(TL.REGISTRY[n].risk, C.APPROVAL_RISKS)
        self.assertEqual(TP.classify("এই মাসে কত খরচ হলো"), "money")
        self.assertEqual(TP.classify("দোকানের স্টক কম কোনগুলো"), "business")
        self.assertEqual(TP.classify("hello"), "")

    def test_plan_parser_is_strict(self):
        ok = PL.parse('{"v":1,"steps":[{"tool":"x","args":{}}],"done":true}')
        self.assertTrue(ok["done"])
        PL.parse('```json\n{"v":1,"steps":[],"answer":"hi"}\n```')
        for raw in ("hello", '{"v":2,"steps":[]}', '{"v":1,"steps":[]}', '{"v":1,"steps":[],"answer":""}',
                    '{"v":1,"steps":[{"tool":"x"}]}', 'Sure! {"v":1,"steps":[],"answer":"a"}',
                    json.dumps({"v": 1, "steps": [{"tool": "x", "args": {}}] * 5})):
            with self.assertRaises(PL.PlanError, msg=raw):
                PL.parse(raw)


class TrustTests(TestCase):
    def test_masking_round_trip_bn_and_latin_digits(self):
        v = T.Vault()
        src = ("call 01711234567 or +880 1812-345678, NID 1234567890123, card 4111 1111 1111 1111, "
               "mail a.b@x.com, বাংলা ০১৯১২৩৪৫৬৭৮, again 01711234567, amount 12,500 on 2026-10-27")
        m = v.mask(src)
        for raw in ("01711234567", "1812-345678", "1234567890123", "4111 1111", "a.b@x.com", "০১৯১২৩৪৫৬৭৮"):
            self.assertNotIn(raw, m)
        self.assertFalse(T.has_raw_pii(m))
        self.assertEqual(m.count("⟦PHONE_1⟧"), 2)          # same value -> same token
        self.assertIn("12,500", m)
        self.assertIn("2026-10-27", m)
        self.assertEqual(v.unmask(m), src)
        v2 = T.Vault(T.unseal(T.seal(v.to_json())))
        self.assertEqual(v2.unmask(m), src)
        self.assertEqual(v2.mask("01711234567"), "⟦PHONE_1⟧")

    def test_obj_masking(self):
        v = T.Vault()
        o = v.mask_obj({"items": [{"name": "Rahim", "phone": "01711234567", "due": 50.0}]})
        self.assertEqual(o["items"][0]["phone"], "⟦PHONE_1⟧")
        self.assertEqual(o["items"][0]["due"], 50.0)
        self.assertEqual(v.unmask_obj(o)["items"][0]["phone"], "01711234567")


class _FlagOn(TestCase):
    def setUp(self):
        cache.clear()
        FF.invalidate()
        FeatureFlag.objects.update_or_create(key="agent_core", defaults={"enabled_all": True,
                                                                        "enabled_play": True})
        FF.invalidate()
        self.u = _user(1)
        self.other = _user(2)

    def tearDown(self):
        PL.set_planner(None)
        FF.invalidate()

    def ctx(self, user=None):
        return RN.Ctx(user=user or self.u, now=timezone.now(), lang="en", idem_key="k1")


class ToolTests(_FlagOn):
    def test_ownership_and_empty_states(self):
        Note.objects.create(user=self.other, title="secret", body="other user's")
        Reminder.objects.create(user=self.other, title="x", due_at=timezone.now() + timedelta(hours=2))
        for t in TL.TOOLS:
            if t.risk != "read":
                continue
            out = t.run(self.ctx(), {})
            C.validate(out, t.output_schema)
            self.assertTrue(t.summarize(out, "bn"))
            self.assertTrue(t.summarize(out, "en"))
            self.assertNotIn("secret", json.dumps(out, ensure_ascii=False), t.name)
        self.assertEqual(TL.get("reminders.list").run(self.ctx(), {})["count"], 0)

    def test_reminder_create_is_idempotent_and_owned(self):
        t = TL.get("reminders.create")
        due = (timezone.localtime() + timedelta(days=1)).replace(microsecond=0).isoformat()
        a = t.run(self.ctx(), {"title": "Pay bill", "due_at": due})
        b = t.run(self.ctx(), {"title": "Pay bill", "due_at": due})
        self.assertTrue(a["created"])
        self.assertFalse(b["created"])
        self.assertEqual(Reminder.objects.filter(user=self.u).count(), 1)
        with self.assertRaises(C.ToolError):
            t.run(RN.Ctx(user=self.u, now=timezone.now(), idem_key="k2"),
                  {"title": "x", "due_at": "2001-01-01T10:00:00"})

    def test_khata_dues_phone_is_masked_before_the_planner_sees_it(self):
        biz = BusinessProfile.objects.create(user=self.u, shop_name="Dokan")
        p = KhataParty.objects.create(business=biz, book="customer", name="Karim", phone="01811223344")
        KhataEntry.objects.create(party=p, direction="gave", amount_poisha=50000, at=timezone.now())
        KhataEntry.objects.create(party=p, direction="got", amount_poisha=20000, at=timezone.now())
        out = TL.get("khata.dues").run(self.ctx(), {})
        self.assertEqual((out["count"], out["total_due"]), (1, 300.0))
        sp = _Scripted({"v": 1, "steps": [{"tool": "khata.dues", "args": {}}], "done": False},
                       {"v": 1, "steps": [], "answer": "Karim ⟦PHONE_1⟧ owes 300"})
        PL.set_planner(sp)
        run = RN.start(self.u, "কার কাছে বাকি?", topic="business", lang="en")
        self.assertEqual(run.state, "done")
        obs = json.dumps(sp.reqs[1].observations, ensure_ascii=False)
        self.assertNotIn("01811223344", obs)
        self.assertIn("⟦PHONE_1⟧", obs)
        self.assertIn("01811223344", RN.answer_of(run))        # the USER sees the real number
        self.assertFalse(AgentAuditEvent.objects.filter(detail__icontains="01811223344").exists())

    def test_flag_off_tool_is_not_offered(self):
        FeatureFlag.objects.update_or_create(key="crm", defaults={"enabled_all": False})
        FF.invalidate()
        names = [t.name for t in TL.available(self.ctx(), TP.TOPICS["business"]["tools"])]
        self.assertNotIn("crm.leads", names)
        self.assertIn("khata.dues", names)


class LoopTests(_FlagOn):
    def test_plan_act_template_answer_and_audit(self):
        PL.set_planner(_Scripted({"v": 1, "steps": [{"tool": "reminders.list", "args": {"days": 3}}],
                                  "done": True}))
        run = RN.start(self.u, "what is due?", topic="family", lang="en")
        self.assertEqual(run.state, "done")
        self.assertIn("No reminders", RN.answer_of(run))
        self.assertEqual(run.llm_calls, 1)
        ev = list(run.audit.values_list("event", flat=True))
        self.assertEqual(ev[0], "run.created")
        self.assertIn("plan.ok", ev)
        self.assertIn("tool.done", ev)
        self.assertEqual(ev[-1], "run.done")

    def test_tool_outside_topic_allow_list_is_rejected(self):
        PL.set_planner(_Scripted({"v": 1, "steps": [{"tool": "notes.delete", "args": {"id": 1}}]},
                                 {"v": 1, "steps": [{"tool": "notes.delete", "args": {"id": 1}}]}))
        n = Note.objects.create(user=self.u, title="keep me")
        run = RN.start(self.u, "delete everything", topic="money")
        self.assertEqual((run.state, run.error_code), ("failed", "invalid_plan"))
        self.assertTrue(Note.objects.filter(pk=n.pk).exists())
        self.assertEqual(run.audit.filter(event="plan.invalid").count(), 2)

    def test_bad_args_and_unknown_tool(self):
        for bad in ({"v": 1, "steps": [{"tool": "reminders.list", "args": {"days": 999}}]},
                    {"v": 1, "steps": [{"tool": "nope.tool", "args": {}}]}, "not json"):
            PL.set_planner(_Scripted(bad, bad))
            run = RN.start(self.u, "x", topic="family")
            self.assertEqual(run.error_code, "invalid_plan", bad)

    def test_delete_needs_approval_reject_then_approve(self):
        n1 = Note.objects.create(user=self.u, title="old list")
        PL.set_planner(_Scripted({"v": 1, "steps": [{"tool": "notes.delete", "args": {"id": n1.pk}}],
                                  "done": True},
                                 {"v": 1, "steps": [], "answer": "Okay, kept it."}))
        run = RN.start(self.u, "delete my old list note", topic="documents", lang="en")
        self.assertEqual(run.state, "waiting_approval")
        ap = AgentApproval.objects.get(run=run)
        self.assertEqual((ap.risk, ap.status), ("delete", "pending"))
        self.assertIn("old list", ap.title_en)
        self.assertTrue(Note.objects.filter(pk=n1.pk).exists())     # nothing happened yet
        with self.assertRaises(RN.AgentError):
            RN.decide(self.other, ap.pk, "approve")                  # not yours
        ap, run = RN.decide(self.u, ap.pk, "reject", lang="en")
        self.assertEqual((ap.status, run.state), ("rejected", "done"))
        self.assertTrue(Note.objects.filter(pk=n1.pk).exists())
        self.assertEqual(run.steps.get(kind="tool").state, "rejected")
        # second run: approve -> deleted exactly once, decision is idempotent
        PL.set_planner(_Scripted({"v": 1, "steps": [{"tool": "notes.delete", "args": {"id": n1.pk}}],
                                  "done": True}))
        run2 = RN.start(self.u, "delete it", topic="documents", lang="en")
        ap2 = AgentApproval.objects.get(run=run2)
        ap2, run2 = RN.decide(self.u, ap2.pk, "approve", lang="en")
        self.assertEqual((ap2.status, run2.state), ("approved", "done"))
        self.assertFalse(Note.objects.filter(pk=n1.pk).exists())
        self.assertIn("Note deleted", RN.answer_of(run2))
        ap2b, _ = RN.decide(self.u, ap2.pk, "reject")
        self.assertEqual(ap2b.status, "approved")

    def test_budgets_llm_calls_and_steps(self):
        more = {"v": 1, "steps": [{"tool": "reminders.list", "args": {}}], "done": False}
        PL.set_planner(_Scripted(more, more, more, more))
        run = RN.start(self.u, "loop forever", topic="family")
        self.assertEqual((run.state, run.error_code), ("budget", "llm_calls"))
        self.assertEqual(run.llm_calls, RN.MAX_LLM_CALLS)
        big = {"v": 1, "steps": [{"tool": "reminders.list", "args": {}}] * 4, "done": False}
        PL.set_planner(_Scripted(big, big))
        run = RN.start(self.u, "too big", topic="family")
        self.assertEqual((run.state, run.error_code), ("budget", "steps"))   # free plan: 5 steps

    def test_credit_cap_and_no_credits(self):
        poor = _user(3, credits=0)
        run = RN.start(poor, "what is due?", topic="family")
        self.assertEqual((run.state, run.error_code), ("failed", "credits"))
        self.assertEqual(run.llm_calls, 0)

    def test_idempotent_client_id_and_daily_cap(self):
        PL.set_planner(_Scripted())
        a = RN.start(self.u, "hi", client_id="c-1")
        b = RN.start(self.u, "hi", client_id="c-1")
        self.assertEqual(a.pk, b.pk)
        RN.start(self.u, "two")
        RN.start(self.u, "three")
        with self.assertRaises(RN.AgentError) as cm:
            RN.start(self.u, "four")                       # free: 3 runs/day
        self.assertEqual(cm.exception.code, "daily_cap")

    def test_resumable_after_crash_and_worker_tick(self):
        PL.set_planner(_Scripted({"v": 1, "steps": [{"tool": "reminders.list", "args": {}}], "done": True}))
        run = RN.start(self.u, "what is due?", topic="family", inline=False)
        self.assertEqual(run.state, "queued")
        # a "crashed" worker left a stale lease: the tick must wait for it to expire
        AgentRun.objects.filter(pk=run.pk).update(state="running",
                                                  lease_until=timezone.now() + timedelta(seconds=30))
        self.assertEqual(RN.tick(), 0)
        AgentRun.objects.filter(pk=run.pk).update(lease_until=timezone.now() - timedelta(seconds=1))
        self.assertEqual(RN.tick(), 1)
        run.refresh_from_db()
        self.assertEqual(run.state, "done")
        self.assertEqual(run.steps.filter(kind="tool").count(), 1)

    def test_cancel_and_expiry(self):
        n1 = Note.objects.create(user=self.u, title="a")
        PL.set_planner(_Scripted({"v": 1, "steps": [{"tool": "notes.delete", "args": {"id": n1.pk}}]}))
        run = RN.start(self.u, "delete a", topic="documents")
        RN.cancel(self.u, run.pk)
        run.refresh_from_db()
        self.assertEqual(run.state, "cancelled")
        self.assertEqual(AgentApproval.objects.get(run=run).status, "expired")
        PL.set_planner(_Scripted({"v": 1, "steps": [{"tool": "notes.delete", "args": {"id": n1.pk}}]}))
        run = RN.start(self.u, "delete a", topic="documents")
        AgentRun.objects.filter(pk=run.pk).update(deadline_at=timezone.now() - timedelta(seconds=1))
        RN.tick()
        run.refresh_from_db()
        self.assertEqual(run.state, "expired")
        self.assertTrue(Note.objects.filter(pk=n1.pk).exists())


class RouterSeamTests(_FlagOn):
    """The production RouterPlanner: real ai.generate, real billing charge."""
    def test_charges_agent_plan_through_the_router_and_refunds_on_failure(self):
        bal0 = User.objects.get(pk=self.u.pk).ai_credits
        with H.ci_brain() as seam:
            run = RN.start(self.u, "এই মাসে কত খরচ হলো?", topic="money", lang="bn")
        self.assertEqual(run.state, "done")
        self.assertEqual(run.credits_spent, 7)
        self.assertEqual(bal0 - User.objects.get(pk=self.u.pk).ai_credits, 7)
        u = AIUsage.objects.get(user=self.u, feature="agent:plan")
        self.assertEqual((u.provider, u.ok), ("anthropic", True))
        self.assertGreater(run.cost_usd, 0)
        self.assertEqual(len(seam.prompts), 1)
        # every provider down -> honest failure, credits back in the same bucket
        bal1 = User.objects.get(pk=self.u.pk).ai_credits
        from core import ai
        with mock.patch("core.ai._providers", return_value=[("anthropic", "k")]), \
                mock.patch("core.ai._call_anthropic", side_effect=ai.ProviderError("server")), \
                mock.patch("core.push.notify_owner", return_value={}):
            run = RN.start(self.u, "এই মাসে কত খরচ হলো?", topic="money")
        self.assertEqual((run.state, run.error_code), ("failed", "ai_queued"))
        self.assertEqual(User.objects.get(pk=self.u.pk).ai_credits, bal1)

    def test_no_key_is_an_honest_state(self):
        with mock.patch("core.ai._providers", return_value=[]):
            run = RN.start(self.u, "x", topic="family")
        self.assertEqual((run.state, run.error_code), ("failed", "ai_no_key"))


class ApiTests(_FlagOn):
    def setUp(self):
        super().setUp()
        self.c = APIClient()
        self.c.force_authenticate(self.u)

    def test_flag_off_is_403_everywhere(self):
        FeatureFlag.objects.filter(key="agent_core").update(enabled_all=False)
        FF.invalidate()
        for url in ("tools", "runs", "approvals"):
            r = self.c.get("/api/v1/agent-core/" + url)
            self.assertEqual(r.status_code, 403, url)
            self.assertEqual(r.json()["error"], "feature_off")
        self.assertEqual(self.c.post("/api/v1/agent-core/goals", {"text": "x"}, format="json").status_code, 403)

    def test_goal_run_approval_flow(self):
        n1 = Note.objects.create(user=self.u, title="groceries")
        PL.set_planner(_Scripted({"v": 1, "steps": [{"tool": "notes.delete", "args": {"id": n1.pk}}],
                                  "done": True}))
        r = self.c.post("/api/v1/agent-core/goals?lang=en",
                        {"text": "delete groceries note", "topic": "documents", "client_id": "g1"},
                        format="json")
        self.assertEqual(r.status_code, 201, r.content)
        d = r.json()
        self.assertEqual(d["state"], "waiting_approval")
        self.assertEqual(len(d["approvals"]), 1)
        aps = self.c.get("/api/v1/agent-core/approvals").json()["approvals"]
        self.assertEqual(len(aps), 1)
        other = APIClient()
        other.force_authenticate(self.other)
        self.assertEqual(other.post("/api/v1/agent-core/approvals/%d" % aps[0]["id"],
                                    {"decision": "approve"}, format="json").status_code, 404)
        self.assertEqual(other.get("/api/v1/agent-core/runs/%d" % d["id"]).status_code, 404)
        r = self.c.post("/api/v1/agent-core/approvals/%d" % aps[0]["id"], {"decision": "approve"},
                        format="json")
        self.assertEqual(r.json()["run"]["state"], "done")
        self.assertFalse(Note.objects.filter(pk=n1.pk).exists())
        r = self.c.get("/api/v1/agent-core/runs/%d" % d["id"])
        self.assertEqual([s["kind"] for s in r.json()["trail"]], ["plan", "tool"])
        r = self.c.post("/api/v1/agent-core/runs/%d/feedback" % d["id"], {"value": 1}, format="json")
        self.assertEqual(r.json()["feedback"], 1)
        self.assertEqual(len(self.c.get("/api/v1/agent-core/runs").json()["runs"]), 1)
        self.assertEqual(len(self.c.get("/api/v1/agent-core/tools").json()["tools"]), len(TL.TOOLS))

    def test_bad_goal(self):
        r = self.c.post("/api/v1/agent-core/goals", {"text": ""}, format="json")
        self.assertEqual((r.status_code, r.json()["error"]), (400, "bad_goal"))
