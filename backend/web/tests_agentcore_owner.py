"""agent-core: Owner Admin -> Agent runs (list, filters, detail, owner-only)."""
from core.models import AgentGoal, AgentRun, AgentAuditEvent, User
from web.tests_o2_owner_admin import OwnerBase, SClient


class AgentRunsPanelTests(OwnerBase):
    def setUp(self):
        super().setUp()
        self.u = User.objects.create_user(name="Rina", phone="01711000411", password="x")
        g = AgentGoal.objects.create(user=self.u, topic="money", text_masked="call ⟦PHONE_1⟧ about rent")
        self.r1 = AgentRun.objects.create(goal=g, user=self.u, topic="money", state="done",
                                          credits_spent=7, llm_calls=1, cost_usd=0.02, feedback=1)
        g2 = AgentGoal.objects.create(user=self.u, topic="business", text_masked="stock?")
        self.r2 = AgentRun.objects.create(goal=g2, user=self.u, topic="business", state="failed",
                                          error_code="invalid_plan")
        AgentAuditEvent.objects.create(user=self.u, run=self.r1, event="plan.ok", credits=7)
        self.ready()

    def test_list_tiles_filters_and_detail(self):
        r = self.c.get("/owner/agent-runs?lang=en")
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "Agent runs")
        self.assertContains(r, "⟦PHONE_1⟧")
        self.assertContains(r, "50%")                     # 1 done of 2 finished
        self.assertContains(r, "invalid_plan")
        r = self.c.get("/owner/agent-runs?lang=en&state=done&days=30")
        self.assertContains(r, "#%d" % self.r1.pk)
        self.assertNotContains(r, "stock?")
        r = self.c.get("/owner/agent-runs?lang=bn&state=bogus&days=99")
        self.assertContains(r, "এজেন্ট রান")
        r = self.c.get("/owner/agent-runs/%d?lang=en" % self.r1.pk)
        self.assertContains(r, "plan.ok")
        self.assertEqual(self.c.get("/owner/agent-runs/999999").status_code, 404)

    def test_requires_owner(self):
        r = SClient().get("/owner/agent-runs")
        self.assertEqual((r.status_code, r["Location"]), (302, "/owner/login"))
