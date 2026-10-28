"""AF-8 — agent observability: p50/p95 latency (planner + per tool), per-tool
error rate, invalid-plan rate, run failure rate, cost per successful task,
approval accept / reject / expire rates; owner alerts via ops_watch with
owner-editable thresholds (min sample sizes, two bad checks in a row)."""
import tempfile
from datetime import timedelta
from io import StringIO
from unittest import mock

from django.core.management import call_command
from django.test import TestCase, override_settings
from django.utils import timezone

from core import ops_health as H
from core.agentcore import observability as AO
from core.models import (AgentApproval, AgentGoal, AgentRun, AgentStep, OpsAlertState, OwnerAudit,
                         User)
from web.tests_o2_owner_admin import OwnerBase

ALL_OK = "LoadState=loaded\nActiveState=active\nSubState=running"
_N = iter(range(1, 10 ** 6))


def _run(user, state="done", cost=0.01, plan_ms=800, plan_failed=False, tools=()):
    g = AgentGoal.objects.create(user=user, topic="family", text_masked="x")
    r = AgentRun.objects.create(goal=g, user=user, topic="family", state=state, cost_usd=cost)
    no = 1
    if plan_failed:
        AgentStep.objects.create(run=r, no=no, kind="plan", state="failed", latency_ms=plan_ms,
                                 idem_key="t:%d" % next(_N), error_code="not_json")
        no += 1
    AgentStep.objects.create(run=r, no=no, kind="plan", state="done", latency_ms=plan_ms,
                             idem_key="t:%d" % next(_N))
    for tool, st, ms in tools:
        no += 1
        AgentStep.objects.create(run=r, no=no, kind="tool", tool=tool, state=st, latency_ms=ms,
                                 risk="read", idem_key="t:%d" % next(_N))
    return r


class StatsTests(TestCase):
    def setUp(self):
        self.u = User.objects.create(name="A", phone="+8801711000901", username="+8801711000901")

    def test_numbers(self):
        for i in range(8):
            _run(self.u, cost=0.02, plan_ms=100 * (i + 1),
                 tools=[("reminders.list", "done", 50 + 10 * i)])
        _run(self.u, state="failed", plan_failed=True, cost=0.0,
             tools=[("reminders.list", "failed", 0)])
        _run(self.u, state="budget", cost=0.0)
        s = AO.stats(timezone.now() - timedelta(hours=1))
        self.assertEqual((s["runs"], s["done"], s["failed"]), (10, 8, 2))
        self.assertEqual(s["failure_pct"], 20.0)
        self.assertEqual(s["invalid_plan_pct"], 10.0)
        self.assertEqual(s["plan_p95_ms"], 800)
        t = s["tools"][0]
        self.assertEqual((t["tool"], t["calls"], t["errors"], t["error_pct"]), ("reminders.list", 9, 1, 11.1))
        self.assertEqual((t["p50_ms"], t["p95_ms"]), (80, 120))
        self.assertAlmostEqual(s["cost_per_success_usd"], 0.02)

    def test_approval_rates(self):
        r = _run(self.u, state="waiting_approval")
        for status in ("approved", "approved", "rejected", "expired", "pending"):
            st = AgentStep.objects.create(run=r, no=next(_N) + 10, kind="tool", tool="notes.delete",
                                          risk="delete", idem_key="ap:%d" % next(_N))
            AgentApproval.objects.create(run=r, step=st, user=self.u, risk="delete", status=status,
                                         expires_at=timezone.now() + timedelta(hours=1))
        ap = AO.stats(timezone.now() - timedelta(hours=1))["approvals"]
        self.assertEqual((ap["decided"], ap["accept_pct"], ap["reject_pct"], ap["expire_pct"]),
                         (4, 50.0, 25.0, 25.0))

    def test_percentile(self):
        self.assertIsNone(AO.pctl([], 95))
        self.assertEqual(AO.pctl([5], 95), 5)
        self.assertEqual(AO.pctl(list(range(1, 101)), 95), 95)


class AlertTests(TestCase):
    def setUp(self):
        self.u = User.objects.create(name="A", phone="+8801711000902", username="+8801711000902")

    def _bad(self, keys=None):
        out = {k: bad for k, bad, _, _ in AO.alert_checks()}
        return sorted(k for k, b in out.items() if b) if keys is None else [out.get(k) for k in keys]

    def test_quiet_below_min_sample(self):
        for _ in range(5):
            _run(self.u, state="failed", plan_failed=True)
        self.assertEqual(self._bad(), [])

    def test_failure_invalid_tool_and_cost_alerts(self):
        for _ in range(6):
            _run(self.u, state="failed", plan_failed=True, tools=[("notes.search", "failed", 0)])
        for _ in range(6):
            _run(self.u, cost=0.5, tools=[("notes.search", "done", 9000)])
        bad = self._bad()
        for k in ("agent:run_failure", "agent:invalid_plan", "agent:cost_per_task",
                  "agent:tool_err:notes.search", "agent:tool_p95:notes.search"):
            self.assertIn(k, bad)
        self.assertNotIn("agent:tool_err:reminders.list", bad)          # quiet tool stays OK
        # the owner raises the bars -> no alert
        AO.save({"run_failure_pct": 90.0, "invalid_plan_pct": 90.0, "cost_per_task_usd": 1.0,
                 "tool_error_pct": 90.0, "tool_p95_ms": 20000})
        self.assertEqual(self._bad(), [])

    def test_ops_watch_alerts_owner_after_two_bad_runs_then_dedupes(self):
        owner = User.objects.create_superuser(name="O", phone="+8801700000901", password="pw-12345678")
        for _ in range(12):
            _run(self.u, state="failed")
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        cron = "\n".join(j.cron_line() for j in H.JOBS)

        def once():
            with mock.patch("core.ops_health.installed_cron_text", return_value=cron), \
                    mock.patch("core.ops_health._systemctl_show", return_value=ALL_OK), \
                    mock.patch("core.ops_health.LOGS", tmp.name), \
                    override_settings(OPS_BACKUP_DIR=tmp.name), \
                    mock.patch("core.push.notify_owner", return_value={"push_sent": 1}) as n:
                call_command("ops_watch", stdout=StringIO())
            return n
        self.assertEqual(once().call_count, 0)                     # 1st bad check: wait
        n = once()
        self.assertEqual(n.call_count, 1)
        self.assertIn("agent runs failing", n.call_args[0][1])
        self.assertEqual(once().call_count, 0)                     # deduped
        self.assertTrue(OpsAlertState.objects.get(key="agent:run_failure").bad)
        self.assertTrue(owner.is_superuser)

    def test_validate(self):
        clean, probs = AO.validate({"min_runs": "20", "tool_error_pct": "500", "plan_p95_ms": "x"})
        self.assertEqual(clean, {"min_runs": 20})
        self.assertEqual(sorted(probs), ["plan_p95_ms", "tool_error_pct"])


class OwnerPageTests(OwnerBase):
    def test_page_shows_health_and_saves_thresholds(self):
        u = User.objects.create(name="B", phone="+8801711000903", username="+8801711000903")
        _run(u, tools=[("reminders.list", "done", 70)])
        self.ready()
        r = self.c.get("/owner/agent-runs?lang=en")
        self.assertContains(r, "Health of the agent")
        self.assertContains(r, "reminders.list")
        r = self.post("/owner/agent-runs/thresholds", {"run_failure_pct": "35"})
        self.assertEqual(r.status_code, 302)
        self.assertEqual(AO.cfg()["run_failure_pct"], 35.0)
        self.assertTrue(OwnerAudit.objects.filter(action="agent_obs", ok=True).exists())
        r = self.post("/owner/agent-runs/thresholds", {"run_failure_pct": "0"})
        self.assertIn("m=invalid", r["Location"])
        self.assertContains(self.c.get("/owner/agent-runs?lang=bn"), "এজেন্টের স্বাস্থ্য")
