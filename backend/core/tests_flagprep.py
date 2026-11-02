"""flagprep (2 Nov): the four "not yet" switches of FLAG_FLIP_READINESS_BN.md.

* agent_core: the worker (agent_core_run) rides the existing minute_jobs line,
  LAST, with a 20 s budget; idle and flag-off it does nothing. The automatic
  morning brief / evening recap reach only brief_rollout_pct % (default 10)
  of the flag's users — deterministic by user id, nested inside the flag's own
  rollout, owner / staff / allow-list always in, Owner Admin editable. Briefs
  never call AI (0 credits).
* retention_auto: retention_run is a scheduled job (*/15) and sends nothing
  while the flag is off.
* kids_watch: school_mode_tick rides the minute_jobs line.
"""
import os
import tempfile
from datetime import datetime
from io import StringIO
from unittest import mock

from django.core.cache import cache
from django.core.management import call_command
from django.test import TestCase
from django.utils import timezone

from core import feature_flags as FF
from core import ops_health as H
from core.agentcore import proactive as P
from core.models import (AgentGoal, AgentNudge, AgentRun, FeatureFlag, JobHeartbeat, OwnerAudit,
                         Reminder, User)
from web.tests_o2_owner_admin import OwnerBase


def mkuser(n):
    return User.objects.create(name="U%d" % n, phone="+8801702%06d" % n,
                               username="+8801702%06d" % n, language="bn")


def set_flag(key, on, **extra):
    FeatureFlag.objects.update_or_create(key=key, defaults=dict(
        {"enabled_all": on, "enabled_play": on}, **extra))
    FF.invalidate()


def morning(day=10, hh=7, mm=45):
    return timezone.make_aware(datetime(2026, 11, day, hh, mm))


# ====================================================================== scheduling
class SchedulingTests(TestCase):
    def test_agent_core_run_rides_minute_jobs_last(self):
        names = [n for n, _ in H.MINUTE_JOBS]
        self.assertEqual(names[-1], "agent_core_run")
        self.assertIn("school_mode_tick", names)                     # kids_watch
        self.assertEqual(dict(H.MINUTE_JOBS)["agent_core_run"], {"seconds": 20.0})
        job = H.JOB_BY_NAME["agent_core_run"]
        self.assertEqual(job.via, "minute_jobs")
        self.assertEqual(job.recommended_line(), H.minute_jobs_cron_line())
        # the live minute_jobs line already schedules it: no new cron line needed
        self.assertTrue(H.is_scheduled(job, H.minute_jobs_cron_line()))

    def test_proactive_and_retention_are_scheduled_jobs(self):
        self.assertEqual(H.JOB_BY_NAME["agent_nudges"].schedule, "*/15 * * * *")
        self.assertEqual(H.JOB_BY_NAME["retention_run"].schedule, "*/15 * * * *")
        self.assertEqual(H.JOB_BY_NAME["agent_core_retention"].schedule, "50 3 * * *")


class AgentCoreRunTests(TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        p = mock.patch("core.ops_health.lock_path",
                       lambda name: os.path.join(self.tmp.name, name + ".lock"))
        p.start()
        self.addCleanup(p.stop)
        self.addCleanup(FF.invalidate)

    def _run(self, u):
        goal = AgentGoal.objects.create(user=u, text_masked="x")
        return AgentRun.objects.create(goal=goal, user=u, state="queued")

    def test_idle_does_not_import_the_runner(self):
        out = StringIO()
        with mock.patch("core.agentcore.runner.tick") as tick:
            call_command("agent_core_run", stdout=out)
        tick.assert_not_called()
        self.assertIn("idle", out.getvalue())
        self.assertEqual(JobHeartbeat.objects.get(name="agent_core_run").last_rc, 0)

    def test_flag_off_run_is_never_advanced(self):
        set_flag("agent_core", False)
        run = self._run(mkuser(1))
        with mock.patch("core.agentcore.runner.advance") as adv:
            call_command("agent_core_run", stdout=StringIO())
        adv.assert_not_called()
        run.refresh_from_db()
        self.assertEqual(run.state, "queued")

    def test_flag_on_run_is_advanced_inside_minute_jobs_with_20s(self):
        set_flag("agent_core", True)
        self._run(mkuser(2))
        with mock.patch("core.agentcore.runner.advance") as adv, \
                mock.patch("core.journey_watch.sweep", return_value={}):
            call_command("minute_jobs", "--only", "agent_core_run", stdout=StringIO(),
                         stderr=StringIO())
        self.assertEqual(adv.call_count, 1)
        self.assertLessEqual(adv.call_args.kwargs["time_budget_s"], 20.0)


# ====================================================================== brief rollout
class BriefRolloutTests(TestCase):
    def setUp(self):
        cache.clear()
        set_flag("agent_core", True)
        self.addCleanup(FF.invalidate)
        self.sent = []
        p = mock.patch.object(P, "_push", side_effect=lambda u, n: self.sent.append((u.pk, n.trigger)) or 1)
        p.start()
        self.addCleanup(p.stop)
        ai = mock.patch("core.ai.generate", side_effect=AssertionError("no AI in briefs"))
        ai.start()
        self.addCleanup(ai.stop)

    def test_default_is_10_and_owner_value_is_clamped(self):
        self.assertEqual(P.brief_rollout_pct(), 10)
        self.assertEqual(P.save_brief_rollout(25), (10, 25))
        self.assertEqual(P.brief_rollout_pct(), 25)
        with self.assertRaises(ValueError):
            P.save_brief_rollout(101)

    def test_deterministic_nested_and_about_the_right_share(self):
        users = [mkuser(i) for i in range(1, 401)]
        a = [u.pk for u in users if P.in_brief_rollout(u, 10)]
        b = [u.pk for u in users if P.in_brief_rollout(u, 10)]
        self.assertEqual(a, b)                                           # same users every time
        self.assertTrue(15 <= len(a) <= 70, len(a))                      # ~10 % of 400
        wider = {u.pk for u in users if P.in_brief_rollout(u, 50)}
        self.assertTrue(set(a) <= wider)                                 # raising never drops anyone
        # nested inside the flag's own rollout (same hash): flag 10 % -> same group
        flag10 = {u.pk for u in users if FF.in_rollout("agent_core", u.pk, 10)}
        self.assertEqual(set(a), flag10)
        self.assertEqual([u for u in users if P.in_brief_rollout(u, 0)], [])

    def test_staff_and_allow_list_always_in(self):
        staff = mkuser(900)
        staff.is_staff = True
        staff.save()
        tester = mkuser(901)
        set_flag("agent_core", True, allow_user_ids=[tester.pk])
        self.assertTrue(P.in_brief_rollout(staff, 0))
        self.assertTrue(P.in_brief_rollout(tester, 0))

    def test_tick_sends_automatic_brief_only_to_the_cohort(self):
        users = [mkuser(i) for i in range(1, 61)]
        for u in users:
            Reminder.objects.create(user=u, title="Doctor", due_at=morning(10, 17))
        st = P.tick(now=morning(), users=users)
        cohort = {u.pk for u in users if P.in_brief_rollout(u, 10)}
        got = set(AgentNudge.objects.filter(trigger="brief_morning").values_list("user_id", flat=True))
        self.assertEqual(got, cohort)
        self.assertEqual(st["brief_rollout_wait"], len(users) - len(cohort))
        self.assertEqual({pk for pk, t in self.sent if t == "brief_morning"}, cohort)
        # the owner raises it to 100 -> everyone else gets it on the next tick, no doubles
        P.save_brief_rollout(100)
        P.tick(now=morning(10, 8, 0), users=users)
        self.assertEqual(AgentNudge.objects.filter(trigger="brief_morning").count(), len(users))
        # a brief is template-only: 0 credits, no AI (ai.generate would raise)
        n = AgentNudge.objects.filter(trigger="brief_morning").first()
        self.assertEqual((n.data["bn"]["ai_used"], n.data["bn"]["credits"]), (False, 0))

    def test_outside_cohort_still_gets_nudges_and_on_demand_brief(self):
        P.save_brief_rollout(0)
        u = mkuser(5)
        P.tick(now=morning(), users=[u])
        self.assertFalse(AgentNudge.objects.filter(user=u, trigger="brief_morning").exists())
        b = P.build_brief(u, "brief_morning", morning())                 # GET /agent-core/brief
        self.assertEqual(b["kind"], "brief_morning")

    def test_flag_off_nothing(self):
        set_flag("agent_core", False)
        P.save_brief_rollout(100)
        u = mkuser(6)
        st = P.tick(now=morning(), users=[u])
        self.assertEqual((st["users"], st["skipped_flag"]), (0, 1))
        self.assertFalse(AgentNudge.objects.exists())


class BriefRolloutOwnerTests(OwnerBase):
    def test_owner_sets_rollout_with_audit(self):
        self.ready()
        r = self.c.get("/owner/agent-runs?lang=bn")
        self.assertContains(r, "রোলআউট %")
        self.assertContains(r, 'name="pct"')
        r = self.post("/owner/agent-runs/brief-rollout", {"pct": "30"})
        self.assertEqual(r.status_code, 302)
        self.assertEqual(P.brief_rollout_pct(), 30)
        self.assertTrue(OwnerAudit.objects.filter(action="agent_brief_rollout", ok=True).exists())
        for bad in ("101", "-1", "x", ""):
            r = self.post("/owner/agent-runs/brief-rollout", {"pct": bad})
            self.assertIn("m=invalid", r["Location"])
        self.assertEqual(P.brief_rollout_pct(), 30)
        self.assertContains(self.c.get("/owner/agent-runs?lang=en"), "Rollout %")


# ====================================================================== retention_auto
class RetentionRunFlagOffTests(TestCase):
    def test_flag_off_command_sends_nothing(self):
        set_flag("retention_auto", False)
        self.addCleanup(FF.invalidate)
        out = StringIO()
        with mock.patch("core.retention_service.run_automation") as ra:
            call_command("retention_run", stdout=out)
        ra.assert_not_called()
        self.assertIn("sent=0", out.getvalue())
        self.assertEqual(JobHeartbeat.objects.get(name="retention_run").last_rc, 0)
