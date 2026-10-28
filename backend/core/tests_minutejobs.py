"""minutejobs: `manage.py minute_jobs` runs journey_sweep then antitheft_escalate
in one process — both run, each keeps its own heartbeat, one failing never
skips the other, each takes its own flock, per-job log files; ops_watch
accepts either the old two cron lines or the new one; the cron commands skip
system checks."""
import os
import tempfile
from io import StringIO
from pathlib import Path
from unittest import mock

from django.core.management import call_command
from django.test import SimpleTestCase, TestCase

from core import ops_health as H
from core.management.commands import antitheft_escalate, journey_sweep, minute_jobs
from core.models import AntiTheftEvent, JobHeartbeat


class _Base(TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        # private lock files: parallel test processes never share /tmp locks
        p = mock.patch("core.ops_health.lock_path",
                       lambda name: os.path.join(self.tmp.name, name + ".lock"))
        p.start()
        self.addCleanup(p.stop)

    def hb(self, name):
        return JobHeartbeat.objects.filter(name=name).first()

    def run_cmd(self, *args):
        out, err = StringIO(), StringIO()
        call_command("minute_jobs", *args, stdout=out, stderr=err)
        return out.getvalue(), err.getvalue()


class MinuteJobsTests(_Base):
    def test_both_run_in_order_with_their_own_heartbeats(self):
        with mock.patch("core.journey_watch.sweep", return_value={}), \
                mock.patch("core.management.commands.minute_jobs.call_command",
                           wraps=call_command) as cc:
            self.run_cmd()
        self.assertEqual([c.args[0] for c in cc.call_args_list],
                         ["journey_sweep", "antitheft_escalate"])
        self.assertTrue(cc.call_args_list[0].kwargs["quiet"])
        # both heartbeats recorded OK, as from their own cron lines
        for name in ("journey_sweep", "antitheft_escalate"):
            hb = self.hb(name)
            self.assertIsNotNone(hb, name)
            self.assertEqual(hb.last_rc, 0)
            self.assertIsNotNone(hb.last_ok)
            self.assertFalse(hb.running)
        self.assertIsNone(self.hb("minute_jobs"))   # no extra job in ops_watch

    def test_journey_failure_never_skips_antitheft(self):
        with mock.patch("core.journey_watch.sweep", side_effect=RuntimeError("boom")):
            with self.assertRaises(SystemExit) as cm:
                out, _ = self.run_cmd()
        self.assertEqual(cm.exception.code, 1)
        self.assertEqual(self.hb("journey_sweep").last_rc, 1)
        self.assertEqual(self.hb("journey_sweep").last_error, "RuntimeError")
        self.assertEqual(self.hb("antitheft_escalate").last_rc, 0)

    def test_antitheft_failure_after_journey_ok(self):
        with mock.patch("core.journey_watch.sweep", return_value={}), \
                mock.patch.object(AntiTheftEvent.objects, "filter",
                                  side_effect=RuntimeError("db")):
            with self.assertRaises(SystemExit):
                self.run_cmd()
        self.assertEqual(self.hb("journey_sweep").last_rc, 0)
        self.assertEqual(self.hb("antitheft_escalate").last_rc, 1)

    def test_held_lock_skips_only_that_job_like_flock_n(self):
        with mock.patch("core.journey_watch.sweep", return_value={}) as sweep:
            with minute_jobs.job_lock("journey_sweep") as got:
                self.assertTrue(got)
                out, err = self.run_cmd()     # no SystemExit: a skip is not a failure
            self.assertFalse(sweep.called)
            self.assertIsNone(self.hb("journey_sweep"))
            self.assertEqual(self.hb("antitheft_escalate").last_rc, 0)
            # lock released afterwards -> runs again
            self.run_cmd()
            self.assertTrue(sweep.called)
        self.assertEqual(err, "")

    def test_lock_is_the_cron_lock_file(self):
        with mock.patch("core.journey_watch.sweep", return_value={}):
            self.run_cmd()
        self.assertTrue(Path(self.tmp.name, "journey_sweep.lock").exists())
        self.assertTrue(Path(self.tmp.name, "antitheft_escalate.lock").exists())

    def test_log_dir_appends_each_jobs_output_to_its_own_log(self):
        d = self.tmp.name
        Path(d, "journey_sweep.log").write_text("old line\n")
        with mock.patch("core.journey_watch.sweep", return_value={"overdue": 2}):
            out, _ = self.run_cmd("--log-dir", d)
        txt = Path(d, "journey_sweep.log").read_text()
        self.assertTrue(txt.startswith("old line\n"))
        self.assertIn("journey_sweep overdue=2", txt)
        self.assertEqual(out, "")
        # quiet: an idle sweep prints nothing (same as `journey_sweep --quiet`)
        with mock.patch("core.journey_watch.sweep", return_value={}):
            self.run_cmd("--log-dir", d)
        self.assertNotIn("idle", Path(d, "journey_sweep.log").read_text())
        # a failure's traceback lands in that job's log
        with mock.patch("core.journey_watch.sweep", side_effect=ValueError("x")):
            with self.assertRaises(SystemExit):
                self.run_cmd("--log-dir", d)
        txt = Path(d, "journey_sweep.log").read_text()
        self.assertIn("journey_sweep: FAILED", txt)
        self.assertIn("ValueError", txt)
        self.assertEqual(self.hb("antitheft_escalate").last_rc, 0)

    def test_missing_log_dir_reports_and_still_runs_next(self):
        with mock.patch("core.journey_watch.sweep", return_value={}):
            with self.assertRaises(SystemExit):
                out, err = self.run_cmd("--log-dir", os.path.join(self.tmp.name, "nope"))
        self.assertIsNone(self.hb("journey_sweep"))

    def test_only(self):
        with mock.patch("core.journey_watch.sweep", return_value={}) as sweep:
            self.run_cmd("--only", "antitheft_escalate")
        self.assertFalse(sweep.called)
        self.assertEqual(self.hb("antitheft_escalate").last_rc, 0)


class CheckSkipTests(TestCase):
    def test_cron_commands_skip_system_checks(self):
        # system checks import the whole URLconf (~0.7 s CPU per process)
        for mod in (minute_jobs, journey_sweep, antitheft_escalate):
            self.assertEqual(mod.Command.requires_system_checks, [], mod.__name__)

    def test_antitheft_idle_minute_does_not_import_views(self):
        with mock.patch("core.views_antitheft.escalate_due") as esc:
            call_command("antitheft_escalate", stdout=StringIO())
        self.assertFalse(esc.called)


class OpsWatchCronTests(TestCase):
    OLD = "\n".join(H.JOB_BY_NAME[n].cron_line() for n in ("journey_sweep", "antitheft_escalate"))

    def test_old_two_lines_still_scheduled(self):
        for n in ("journey_sweep", "antitheft_escalate"):
            self.assertTrue(H.is_scheduled(H.JOB_BY_NAME[n], self.OLD))

    def test_new_line_schedules_both_and_nothing_else(self):
        new = H.minute_jobs_cron_line()
        for n in ("journey_sweep", "antitheft_escalate"):
            self.assertTrue(H.is_scheduled(H.JOB_BY_NAME[n], new), n)
        self.assertFalse(H.is_scheduled(H.JOB_BY_NAME["calls_sweep"], new))
        missing = [j.name for j, _ in H.missing_cron(new)]
        self.assertNotIn("journey_sweep", missing)
        self.assertNotIn("antitheft_escalate", missing)
        self.assertIn("calls_sweep", missing)

    def test_both_old_and_new_during_switch(self):
        text = self.OLD + "\n" + H.minute_jobs_cron_line()
        self.assertEqual([j for j, _ in H.missing_cron(text)
                          if j.name in ("journey_sweep", "antitheft_escalate")], [])

    def test_longer_name_is_not_a_match(self):
        txt = "* * * * * ubuntu cd /x && /v/python manage.py minute_jobs_v2 >> l 2>&1"
        self.assertFalse(H.is_scheduled(H.JOB_BY_NAME["journey_sweep"], txt))

    def test_exact_new_line(self):
        self.assertEqual(
            H.minute_jobs_cron_line(),
            "* * * * * ubuntu cd /home/ubuntu/assisto/backend && nice -n10 "
            "/home/ubuntu/assisto/.venv/bin/python manage.py minute_jobs --log-dir "
            "/home/ubuntu/assisto/backend/logs >> /home/ubuntu/assisto/backend/logs/"
            "minute_jobs.log 2>&1")
        self.assertEqual(H.lock_path("journey_sweep"), "/tmp/assisto-journey-sweep.lock")
        self.assertEqual([n for n, _ in H.MINUTE_JOBS], ["journey_sweep", "antitheft_escalate"])

    def test_snapshot_no_false_not_scheduled(self):
        snap = H.snapshot(cron_text=H.minute_jobs_cron_line(),
                          service_runner=lambda u: "")
        by = {j["name"]: j for j in snap["jobs"]}
        self.assertTrue(by["journey_sweep"]["scheduled"])
        self.assertTrue(by["antitheft_escalate"]["scheduled"])
        self.assertNotEqual(by["journey_sweep"]["status"], "not_scheduled")


class EveryMinuteCronSkipsChecksTests(SimpleTestCase):
    """Every per-minute cron command skips Django's system checks (~0.7 s CPU
    per run on the 2-vCPU box; measured 28 Oct)."""

    def test_every_minute_commands_skip_system_checks(self):
        import importlib
        for name in ("journey_sweep", "antitheft_escalate", "minute_jobs",
                     "push_due_reminders", "calls_sweep", "turn_monitor",
                     "bizagent_process"):
            mod = importlib.import_module("core.management.commands." + name)
            self.assertEqual(mod.Command.requires_system_checks, [], name)
