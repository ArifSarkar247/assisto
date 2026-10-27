"""ops-watch: heartbeats (track_job), lateness / failing / stuck / waiting /
not-scheduled, missing cron lines, systemctl parsing, alert dedupe + daily
reminder + recovery, ops_watch command (owner-only delivery), crash / ANR rate
maths incl. the minimum sample, and the crash-report ANR/exit kinds."""
import json
import tempfile
from datetime import timedelta
from io import StringIO
from pathlib import Path
from unittest import mock

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.core.management import call_command
from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient

from core import crash_rate as CR
from core import ops_health as H
from core.models import ActiveDay, ClientErrorReport, JobHeartbeat, OpsAlertState

User = get_user_model()


class HeartbeatTests(TestCase):
    def test_success_records_ok(self):
        @H.track_job("billing_daily")
        def run():
            return "done"
        self.assertEqual(run(), "done")
        hb = JobHeartbeat.objects.get(name="billing_daily")
        self.assertEqual(hb.last_rc, 0)
        self.assertFalse(hb.running)
        self.assertIsNotNone(hb.last_ok)
        self.assertEqual((hb.runs_ok, hb.runs_failed, hb.fails_in_row), (1, 0, 0))

    def test_exception_recorded_and_reraised(self):
        @H.track_job("run_watchers")
        def run():
            raise ValueError("boom")
        with self.assertRaises(ValueError):
            run()
        with self.assertRaises(ValueError):
            run()
        hb = JobHeartbeat.objects.get(name="run_watchers")
        self.assertEqual(hb.last_rc, 1)
        self.assertEqual(hb.last_error, "ValueError")
        self.assertIsNone(hb.last_ok)
        self.assertEqual((hb.runs_failed, hb.fails_in_row), (2, 2))

    def test_system_exit_code(self):
        @H.track_job("retention_run")
        def run():
            raise SystemExit(3)
        with self.assertRaises(SystemExit):
            run()
        self.assertEqual(JobHeartbeat.objects.get(name="retention_run").last_rc, 3)

    def test_heartbeat_failure_never_breaks_job(self):
        with mock.patch("core.models.JobHeartbeat.objects.get_or_create",
                        side_effect=RuntimeError("db down")):
            @H.track_job("uptime_check")
            def run():
                return 7
            self.assertEqual(run(), 7)

    def test_real_command_is_instrumented(self):
        with mock.patch("core.ai._providers", return_value=[]):
            call_command("ai_health_check", stdout=StringIO())
        self.assertEqual(JobHeartbeat.objects.get(name="ai_health_check").last_rc, 0)

    def test_ops_heartbeat_command(self):
        call_command("ops_heartbeat", "backup", "--rc", "2", "--duration-ms", "900",
                     stdout=StringIO())
        hb = JobHeartbeat.objects.get(name="backup")
        self.assertEqual((hb.last_rc, hb.last_duration_ms), (2, 900))
        call_command("ops_heartbeat", "nope", stdout=StringIO())
        self.assertFalse(JobHeartbeat.objects.filter(name="nope").exists())


class JobStatusTests(TestCase):
    def setUp(self):
        self.now = timezone.now()
        self.job = H.JOB_BY_NAME["booking_reminders"]      # every 5 min, grace 5 min

    def hb(self, **kw):
        d = dict(name=self.job.name, last_start=self.now - timedelta(minutes=2),
                 last_finish=self.now - timedelta(minutes=2), last_ok=self.now - timedelta(minutes=2),
                 last_rc=0)
        d.update(kw)
        return JobHeartbeat.objects.create(**d)

    def test_ok_and_next_due(self):
        st = H.job_status(self.job, self.hb(), now=self.now)
        self.assertEqual(st["status"], "ok")
        self.assertEqual(st["next_due"], self.now - timedelta(minutes=2) + timedelta(minutes=5))

    def test_late_after_interval_plus_grace(self):
        t = self.now - timedelta(minutes=11)
        st = H.job_status(self.job, self.hb(last_start=t, last_finish=t, last_ok=t), now=self.now)
        self.assertEqual(st["status"], "late")
        t = self.now - timedelta(minutes=9)
        JobHeartbeat.objects.all().delete()
        st = H.job_status(self.job, self.hb(last_start=t, last_finish=t, last_ok=t), now=self.now)
        self.assertEqual(st["status"], "ok")

    def test_failing(self):
        st = H.job_status(self.job, self.hb(last_rc=1, last_error="KeyError"), now=self.now)
        self.assertEqual(st["status"], "failing")
        self.assertIn("KeyError", st["detail"])

    def test_late_when_runs_but_never_succeeds_is_failing_first(self):
        st = H.job_status(self.job, self.hb(last_rc=1, last_ok=None), now=self.now)
        self.assertEqual(st["status"], "failing")

    def test_stuck(self):
        st = H.job_status(self.job, self.hb(running=True,
                                            last_start=self.now - timedelta(hours=1)),
                          now=self.now)
        self.assertEqual(st["status"], "stuck")

    def test_never_ran_waiting_then_late(self):
        self.assertEqual(H.job_status(self.job, None, first_seen=self.now - timedelta(minutes=3),
                                      now=self.now)["status"], "waiting")
        self.assertEqual(H.job_status(self.job, None, first_seen=self.now - timedelta(minutes=30),
                                      now=self.now)["status"], "late")

    def test_not_scheduled(self):
        st = H.job_status(self.job, None, now=self.now, scheduled=False)
        self.assertEqual(st["status"], "not_scheduled")

    def test_daily_grace(self):
        job = H.JOB_BY_NAME["billing_daily"]
        self.assertEqual(job.grace_s, 3 * 3600)
        t = self.now - timedelta(hours=26)
        hb = JobHeartbeat.objects.create(name=job.name, last_finish=t, last_ok=t, last_rc=0)
        self.assertEqual(H.job_status(job, hb, now=self.now)["status"], "ok")
        t = self.now - timedelta(hours=28)
        hb.last_finish = hb.last_ok = t
        self.assertEqual(H.job_status(job, hb, now=self.now)["status"], "late")

    def test_backup_from_file_age(self):
        job = H.JOB_BY_NAME["backup"]
        fresh = [{"name": "b", "size": 1, "mtime": self.now - timedelta(hours=5)}]
        old = [{"name": "b", "size": 1, "mtime": self.now - timedelta(hours=30)}]
        self.assertEqual(H.job_status(job, None, now=self.now, backups=fresh)["status"], "ok")
        self.assertEqual(H.job_status(job, None, now=self.now, backups=old)["status"], "late")

    def test_restore_drill_monthly(self):
        job = H.JOB_BY_NAME["restore_test"]
        ok = {"ok": True, "finished_at": (self.now - timedelta(days=10)).isoformat()}
        old = {"ok": True, "finished_at": (self.now - timedelta(days=40)).isoformat()}
        bad = {"ok": False, "finished_at": (self.now - timedelta(days=1)).isoformat()}
        self.assertEqual(H.job_status(job, None, now=self.now, restore=ok)["status"], "ok")
        self.assertEqual(H.job_status(job, None, now=self.now, restore=old)["status"], "late")
        self.assertEqual(H.job_status(job, None, now=self.now, restore=bad)["status"], "failing")


class CronTests(TestCase):
    CRON = """
# comment manage.py journey_sweep
* * * * * ubuntu cd /x && nice -n15 /v/python manage.py push_due_reminders >> l 2>&1
0 * * * * ubuntu cd /x && /v/python manage.py run_watchers >> l 2>&1
15 2 * * * ubuntu /home/ubuntu/assisto/migration/backup.sh >>l 2>&1
*/5 * * * * ubuntu cd /x && /v/python manage.py booking_reminders_v2
"""

    def test_scheduled_detection(self):
        text = "\n".join(l for l in self.CRON.splitlines() if not l.startswith("#"))
        self.assertTrue(H.is_scheduled(H.JOB_BY_NAME["push_due_reminders"], text))
        self.assertTrue(H.is_scheduled(H.JOB_BY_NAME["run_watchers"], text))
        self.assertTrue(H.is_scheduled(H.JOB_BY_NAME["backup"], text))
        self.assertFalse(H.is_scheduled(H.JOB_BY_NAME["journey_sweep"], text))
        # a longer command name is not a match
        self.assertFalse(H.is_scheduled(H.JOB_BY_NAME["booking_reminders"], text))

    def test_installed_text_drops_comments(self):
        with mock.patch("core.ops_health.subprocess.run") as run, \
                mock.patch("core.ops_health.glob.glob", return_value=[]):
            run.return_value = mock.Mock(returncode=0, stdout=self.CRON)
            text = H.installed_cron_text()
        self.assertNotIn("journey_sweep", text)
        names = [j.name for j, _ in H.missing_cron(text)]
        self.assertIn("journey_sweep", names)
        self.assertIn("antitheft_escalate", names)
        self.assertIn("ops_watch", names)
        self.assertNotIn("run_watchers", names)

    def test_exact_lines(self):
        self.assertEqual(
            H.JOB_BY_NAME["journey_sweep"].cron_line(),
            "* * * * * ubuntu cd /home/ubuntu/assisto/backend && flock -n "
            "/tmp/assisto-journey-sweep.lock nice -n10 /home/ubuntu/assisto/.venv/bin/python "
            "manage.py journey_sweep --quiet >> /home/ubuntu/assisto/backend/logs/journey_sweep.log 2>&1")
        self.assertIn("manage.py run_watchers", H.JOB_BY_NAME["run_watchers"].cron_line())
        self.assertIn("migration/backup.sh", H.JOB_BY_NAME["backup"].cron_line())


class ServiceTests(TestCase):
    def test_parse_and_classify(self):
        p = H.parse_systemctl_show("LoadState=loaded\nActiveState=active\nSubState=running\n")
        self.assertEqual(H.classify_service(p), "ok")
        self.assertEqual(H.classify_service(H.parse_systemctl_show(
            "LoadState=loaded\nActiveState=failed\nSubState=failed")), "down")
        self.assertEqual(H.classify_service(H.parse_systemctl_show(
            "LoadState=not-found\nActiveState=inactive\nSubState=dead")), "absent")
        self.assertEqual(H.classify_service({}), "unknown")
        self.assertEqual(H.classify_service(H.parse_systemctl_show(
            "LoadState=loaded\nActiveState=activating\nSubState=start")), "ok")

    def test_service_status_runner(self):
        st = H.service_status("coturn", runner=lambda u: "LoadState=loaded\nActiveState=inactive\nSubState=dead")
        self.assertEqual(st["status"], "down")
        st = H.service_status("x", runner=lambda u: (_ for _ in ()).throw(OSError()))
        self.assertEqual(st["status"], "unknown")


class AlertStateTests(TestCase):
    def test_job_alert_once_remind_daily_recover(self):
        t0 = timezone.now()
        chk = [("job:billing_daily", True, "billing_daily: late", 1)]
        nb, rm, rc = H.evaluate(chk, now=t0)
        self.assertEqual((nb, rm, rc), (["billing_daily: late"], [], []))
        nb, rm, rc = H.evaluate(chk, now=t0 + timedelta(minutes=5))
        self.assertEqual((nb, rm, rc), ([], [], []))            # deduped
        nb, rm, rc = H.evaluate(chk, now=t0 + timedelta(hours=25))
        self.assertEqual(rm, ["billing_daily: late"])            # daily reminder
        nb, rm, rc = H.evaluate([("job:billing_daily", False, "ok", 1)],
                                now=t0 + timedelta(hours=26))
        self.assertEqual(len(rc), 1)
        self.assertIn("OK again", rc[0])
        st = OpsAlertState.objects.get(key="job:billing_daily")
        self.assertFalse(st.bad)
        self.assertEqual(st.bad_count, 0)
        nb, rm, rc = H.evaluate([("job:billing_daily", False, "ok", 1)],
                                now=t0 + timedelta(hours=27))
        self.assertEqual((nb, rm, rc), ([], [], []))

    def test_service_needs_two_bad_runs(self):
        chk = [("svc:coturn", True, "service coturn is failed", 2)]
        self.assertEqual(H.evaluate(chk)[0], [])
        self.assertEqual(H.evaluate(chk)[0], ["service coturn is failed"])
        # a blip that recovers before the 2nd run never alerts
        H.evaluate([("svc:nginx", True, "x", 2)])
        self.assertEqual(H.evaluate([("svc:nginx", False, "ok", 2)])[2], [])

    def test_compose(self):
        self.assertIsNone(H.compose([], [], []))
        s, b = H.compose(["a"], ["b"], ["c"])
        self.assertEqual(s, "Assisto ops: 2 problems")
        self.assertIn("NEW:\n- a", b)
        self.assertIn("RECOVERED:\n- c", b)
        self.assertEqual(H.compose([], [], ["c"])[0], "Assisto ops: recovered")


ALL_OK = "LoadState=loaded\nActiveState=active\nSubState=running"


class OpsWatchCommandTests(TestCase):
    def setUp(self):
        self.owner = User.objects.create_superuser(name="O", phone="+8801700000001", password="pw-12345678")
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def run_cmd(self, cron, svc=ALL_OK, *extra):
        out = StringIO()
        with mock.patch("core.ops_health.installed_cron_text", return_value=cron), \
                mock.patch("core.ops_health._systemctl_show", return_value=svc), \
                mock.patch("core.ops_health.LOGS", self.tmp.name), \
                override_settings(OPS_BACKUP_DIR=self.tmp.name), \
                mock.patch("core.push.notify_owner", return_value={"push_sent": 1}) as n:
            call_command("ops_watch", *extra, stdout=out)
        return n, out.getvalue()

    def full_cron(self):
        return "\n".join(j.cron_line() for j in H.JOBS)

    def test_missing_cron_alerts_owner_once_with_exact_line(self):
        cron = "\n".join(j.cron_line() for j in H.JOBS if j.name != "journey_sweep")
        n, _ = self.run_cmd(cron)
        self.assertEqual(n.call_count, 1)
        subject, body = n.call_args[0]
        self.assertIn("journey_sweep: not_scheduled", body)
        self.assertIn(H.JOB_BY_NAME["journey_sweep"].cron_line(), body)
        n2, _ = self.run_cmd(cron)
        self.assertEqual(n2.call_count, 0)                        # deduped
        self.assertTrue(JobHeartbeat.objects.filter(name="ops_watch", last_rc=0).exists())

    def test_service_down_then_recovered(self):
        down = "LoadState=loaded\nActiveState=failed\nSubState=failed"
        cron = self.full_cron()
        self.assertEqual(self.run_cmd(cron, down)[0].call_count, 0)    # 1st bad run
        n, _ = self.run_cmd(cron, down)
        self.assertIn("service assisto is failed", n.call_args[0][1])
        n, _ = self.run_cmd(cron, ALL_OK)
        self.assertEqual(n.call_args[0][0], "Assisto ops: recovered")

    def test_dry_run_changes_nothing(self):
        n, out = self.run_cmd("", ALL_OK, "--dry-run")
        self.assertEqual(n.call_count, 0)
        self.assertFalse(OpsAlertState.objects.exists())
        self.assertIn("ok  ", out)

    def test_alert_goes_only_to_owner_admin(self):
        from core import push
        User.objects.create_user(phone="+8801700000002", password="pw-12345678", name="U")
        self.assertEqual([u.pk for u in push.owner_admin_users()], [self.owner.pk])


class CrashRateTests(TestCase):
    def setUp(self):
        self.day = timezone.localdate() - timedelta(days=1)
        self.users = [User.objects.create_user(phone="+88017000%05d" % i, password="pw-12345678",
                                               name="u%d" % i) for i in range(10)]

    def active(self, n, day=None):
        for u in self.users[:n]:
            ActiveDay.objects.get_or_create(user=u, day=day or self.day,
                                            defaults={"cohort_day": self.day})

    def report(self, u, fatal=True, source="app", day=None, fp="f" * 20, **kw):
        now = timezone.now()
        return ClientErrorReport.objects.create(
            fingerprint=fp, day=day or self.day, user=u, fatal=fatal, source=source,
            error_type="StateError", first_at=now, last_at=now, **kw)

    def test_daily_rate_and_crash_free(self):
        self.active(8)
        self.report(self.users[0])
        self.report(self.users[0], fp="g" * 20)                  # same user twice
        self.report(self.users[1], fatal=False)                  # non-fatal ignored
        self.report(self.users[2], source="anr", fatal=False)
        self.report(self.users[9])                               # reporter not in ActiveDay
        r = [x for x in CR.daily(3, timezone.localdate()) if x["day"] == self.day][0]
        self.assertEqual(r["dau"], 9)
        self.assertEqual((r["crash_users"], r["anr_users"]), (2, 1))
        self.assertAlmostEqual(r["crash_rate"], 2 / 9)
        self.assertAlmostEqual(r["crash_free"], 7 / 9)

    def test_window_user_days_and_min_sample(self):
        self.active(10)
        self.active(10, self.day - timedelta(days=1))
        self.report(self.users[0])
        s = CR.window(7)
        self.assertEqual(s["user_days"], 20)
        self.assertEqual(s["crash_user_days"], 1)
        self.assertAlmostEqual(s["crash_rate"], 0.05)
        self.assertFalse(s["enough"])
        self.assertFalse(s["crash_over"])                         # too few -> never over
        chk = dict((k, (bad, d)) for k, bad, d, _ in CR.alert_checks())
        self.assertFalse(chk["crash_rate"][0])
        self.assertIn("too few users", chk["crash_rate"][1])
        with override_settings(OPS_CRASH_MIN_USER_DAYS=20):
            s = CR.window(7)
            self.assertTrue(s["enough"])
            self.assertTrue(s["crash_over"])
            self.assertFalse(s["anr_over"])
            chk = dict((k, (bad, d)) for k, bad, d, _ in CR.alert_checks())
            self.assertTrue(chk["crash_rate"][0])
            self.assertIn("5.00%", chk["crash_rate"][1])

    def test_no_users_no_rate(self):
        s = CR.window(7)
        self.assertIsNone(s["crash_rate"])
        self.assertFalse(s["enough"])

    def test_today_excluded_from_alert_window(self):
        today = timezone.localdate()
        self.active(10, today)
        self.report(self.users[0], day=today)
        self.assertEqual(CR.window(7)["user_days"], 0)

    def test_breakdown_by_version_with_approx_denominator(self):
        for u in self.users[:4]:
            u.app_version = "1.0.150"
            u.save(update_fields=["app_version"])
        self.active(4)
        self.report(self.users[0], version="1.0.150", brand="realme")
        self.report(self.users[1], version="1.0.150", brand="oppo", source="anr", fatal=False)
        rows = {r["value"]: r for r in CR.breakdown("version", 3)}
        self.assertEqual(rows["1.0.150"]["crash_users"], 1)
        self.assertEqual(rows["1.0.150"]["anr_users"], 1)
        self.assertEqual(rows["1.0.150"]["users"], 4)
        self.assertAlmostEqual(rows["1.0.150"]["crash_rate"], 0.25)
        brands = {r["value"]: r for r in CR.breakdown("brand", 3)}
        self.assertIsNone(brands["realme"]["users"])
        sigs = CR.top_signatures(3)
        self.assertEqual(sigs[0]["users"], 2)


class ExitReportEndpointTests(TestCase):
    def setUp(self):
        cache.clear()
        self.u = User.objects.create_user(phone="+8801700000999", password="pw-12345678", name="T")
        self.c = APIClient()
        self.c.force_authenticate(self.u)

    def post(self, **kw):
        b = {"v": 2, "error_type": "Whatever", "message": "Input dispatching timed out",
             "frames": [], "where": "anr", "version": "1.0.200", "build": "200",
             "device": {"brand": "realme", "model": "RMX3491", "android": "13", "sdk": 33}}
        b.update(kw)
        return self.c.post("/api/v1/client/crash-report", b, format="json")

    def test_anr_kind(self):
        occ = timezone.now() - timedelta(days=2)
        r = self.post(kind="anr", occurred_ms=int(occ.timestamp() * 1000))
        self.assertTrue(r.json()["stored"])
        e = ClientErrorReport.objects.get()
        self.assertEqual((e.source, e.fatal, e.error_type), ("anr", False, "ANR"))
        self.assertEqual(e.day, timezone.localdate(occ))

    def test_exit_crash_is_fatal(self):
        self.post(kind="exit_crash", error_type="NativeCrash", where="exit.native")
        e = ClientErrorReport.objects.get()
        self.assertEqual((e.source, e.fatal), ("exit", True))

    def test_bad_occurred_ms_falls_back_to_today(self):
        self.post(kind="anr", occurred_ms="x")
        self.post(kind="anr", occurred_ms=4102444800000, where="anr2")   # 2100: future
        self.assertEqual(set(ClientErrorReport.objects.values_list("day", flat=True)),
                         {timezone.localdate()})

    def test_plain_report_unchanged(self):
        self.post(fatal=True, frames=["a (package:assisto/x.dart:1)"])
        e = ClientErrorReport.objects.get()
        self.assertEqual((e.source, e.fatal), ("app", True))


class BackupHelpersTests(TestCase):
    def test_backup_files_and_offsite_and_restore_result(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "assisto_backup_20261027_010101.tar.gz.enc").write_bytes(b"x" * 10)
            Path(d, "other.txt").write_text("x")
            files = H.backup_files(d)
            self.assertEqual([f["name"] for f in files], ["assisto_backup_20261027_010101.tar.gz.enc"])
            log = Path(d, "backup.log")
            log.write_text("DONE\nOFFSITE: not configured — x\nDONE\nOFFSITE: uploaded to offsite:b\n")
            self.assertEqual(H.offsite_state(str(log)), "uploaded")
            log.write_text("OFFSITE: upload FAILED\n")
            self.assertEqual(H.offsite_state(str(log)), "failed")
            self.assertEqual(H.offsite_state(str(Path(d, "none.log"))), "unknown")
            p = Path(d, "r.json")
            p.write_text(json.dumps({"ok": True, "finished_at": "2026-10-27T10:00:00+00:00"}))
            self.assertTrue(H.restore_test_result(str(p))["ok"])
            self.assertIsNone(H.restore_test_result(str(Path(d, "missing.json"))))
