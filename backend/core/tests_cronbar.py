"""cronbar (board group 23, server jobs): every scheduled job has a heartbeat,
an ops_watch row, a bounded runtime (flock + timeout + "slow" state), the
minute_jobs jobs never get their old stand-alone line back, the recommended
cron file renders every job, and the money / push jobs fixed here are
idempotent even when two runs overlap."""
import os
import signal
import tempfile
from datetime import timedelta
from io import StringIO
from unittest import mock

from django.core.management import call_command, get_commands, load_command_class
from django.test import TestCase
from django.utils import timezone

from core import ops_health as H
from core.models import JobHeartbeat, User

# /etc/cron.d/assisto-app + `crontab -l` as installed on lifeassisto.com on
# 2 Nov 2026 (read-only copy; the two #OFF lines are the commented-out old
# stand-alone minute lines).
LIVE_2NOV = """
* * * * * cd /home/ubuntu/assisto/backend && /home/ubuntu/assisto/.venv/bin/python manage.py bizagent_process >> /home/ubuntu/assisto/logs/bizagent_process.log 2>&1
*/30 * * * * cd /home/ubuntu/assisto/backend && /home/ubuntu/assisto/.venv/bin/python manage.py bizagent_couriers >> /home/ubuntu/assisto/logs/bizagent_couriers.log 2>&1
0 15 * * * cd /home/ubuntu/assisto/backend && /home/ubuntu/assisto/.venv/bin/python manage.py bizagent_daily >> /home/ubuntu/assisto/logs/bizagent_daily.log 2>&1
*/15 * * * * cd /home/ubuntu/assisto/backend && /home/ubuntu/assisto/.venv/bin/python manage.py world_refresh >> /home/ubuntu/assisto/logs/world_refresh.log 2>&1
30 3 * * * cd /home/ubuntu/assisto/backend && /home/ubuntu/assisto/.venv/bin/python manage.py world_job_alerts >> /home/ubuntu/assisto/logs/world_job_alerts.log 2>&1
20 22 * * * /home/ubuntu/assisto/bin/disk_guard_daily.sh >> /home/ubuntu/assisto/logs/disk_guard.log 2>&1
*/5 * * * * ubuntu nice -n15 /home/ubuntu/assisto/.venv/bin/python /home/ubuntu/assisto/backend/manage.py check_went_dark >/dev/null 2>&1
0 * * * * ubuntu nice -n15 /home/ubuntu/assisto/.venv/bin/python /home/ubuntu/assisto/backend/manage.py purge_deletions >> /home/ubuntu/assisto/backend/logs/purge_deletions.log 2>&1
15 3 * * * ubuntu nice -n15 /home/ubuntu/assisto/.venv/bin/python /home/ubuntu/assisto/backend/manage.py storage_recompute >/dev/null 2>&1
30 3 * * * ubuntu nice -n15 /home/ubuntu/assisto/.venv/bin/python /home/ubuntu/assisto/backend/manage.py shop_prune_snapshots >/dev/null 2>&1
*/2 * * * * ubuntu nice -n15 /home/ubuntu/assisto/.venv/bin/python /home/ubuntu/assisto/backend/manage.py uptime_check >>/home/ubuntu/assisto/backend/logs/uptime.log 2>&1
* * * * * ubuntu cd /home/ubuntu/assisto/backend && nice -n15 ionice -c3 /home/ubuntu/assisto/.venv/bin/python manage.py push_due_reminders >> /home/ubuntu/assisto/backend/logs/push_reminders.log 2>&1
*/15 * * * * ubuntu cd /home/ubuntu/assisto/backend && nice -n15 /home/ubuntu/assisto/.venv/bin/python manage.py purge_disappearing >> /home/ubuntu/assisto/backend/logs/purge_disappearing.log 2>&1
10 4 * * * ubuntu cd /home/ubuntu/assisto/backend && nice -n15 ionice -c3 /home/ubuntu/assisto/.venv/bin/python manage.py shop_camera_billing >> /home/ubuntu/assisto/backend/logs/shop_camera_billing.log 2>&1
20 4 * * * ubuntu cd /home/ubuntu/assisto/backend && nice -n15 ionice -c3 /home/ubuntu/assisto/.venv/bin/python manage.py vehicle_tracking_billing >> /home/ubuntu/assisto/backend/logs/vehicle_tracking_billing.log 2>&1
*/10 * * * * ubuntu cd /home/ubuntu/assisto/backend && nice -n15 /home/ubuntu/assisto/.venv/bin/python manage.py purge_web_photos >> /home/ubuntu/assisto/backend/logs/purge_web_photos.log 2>&1
30 3 * * * ubuntu cd /home/ubuntu/assisto/backend && nice -n15 /home/ubuntu/assisto/.venv/bin/python manage.py purge_l1_retention >> /home/ubuntu/assisto/backend/logs/purge_l1_retention.log 2>&1
* * * * * ubuntu cd /home/ubuntu/assisto/backend && nice -n10 /home/ubuntu/assisto/.venv/bin/python manage.py calls_sweep >> /home/ubuntu/assisto/backend/logs/calls_sweep.log 2>&1
7 * * * * ubuntu cd /home/ubuntu/assisto/backend && nice -n15 /home/ubuntu/assisto/.venv/bin/python manage.py payments_sweep >> /home/ubuntu/assisto/backend/logs/payments_sweep.log 2>&1
* * * * * ubuntu cd /home/ubuntu/assisto/backend && nice -n15 /home/ubuntu/assisto/.venv/bin/python manage.py turn_monitor >/dev/null 2>&1
40 6 * * * ubuntu cd /home/ubuntu/assisto/backend && nice -n15 /home/ubuntu/assisto/.venv/bin/python manage.py play_vitals_pull >> /home/ubuntu/assisto/backend/logs/play_vitals.log 2>&1
40 3 * * * ubuntu cd /home/ubuntu/assisto/backend && nice -n15 /home/ubuntu/assisto/.venv/bin/python manage.py billing_daily >> /home/ubuntu/assisto/backend/logs/billing_daily.log 2>&1
5 0 * * * ubuntu cd /home/ubuntu/assisto/backend && nice -n15 /home/ubuntu/assisto/.venv/bin/python manage.py profit_guard_rollover >> /home/ubuntu/assisto/backend/logs/profit_guard_rollover.log 2>&1
0 * * * * ubuntu cd /home/ubuntu/assisto/backend && nice -n15 ionice -c3 /home/ubuntu/assisto/.venv/bin/python manage.py run_watchers >> /home/ubuntu/assisto/backend/logs/run_watchers.log 2>&1
0 3 * * * ubuntu cd /home/ubuntu/assisto/backend && nice -n15 ionice -c3 /home/ubuntu/assisto/.venv/bin/python manage.py generate_briefings >> /home/ubuntu/assisto/backend/logs/generate_briefings.log 2>&1
*/5 * * * * ubuntu cd /home/ubuntu/assisto/backend && nice -n15 ionice -c3 /home/ubuntu/assisto/.venv/bin/python manage.py booking_reminders >> /home/ubuntu/assisto/backend/logs/booking_reminders.log 2>&1
*/15 * * * * ubuntu cd /home/ubuntu/assisto/backend && nice -n15 ionice -c3 /home/ubuntu/assisto/.venv/bin/python manage.py retention_run >> /home/ubuntu/assisto/backend/logs/retention_run.log 2>&1
#OFF * * * * * ubuntu cd /home/ubuntu/assisto/backend && flock -n /tmp/assisto-journey-sweep.lock nice -n10 /home/ubuntu/assisto/.venv/bin/python manage.py journey_sweep --quiet >> /home/ubuntu/assisto/backend/logs/journey_sweep.log 2>&1
#OFF * * * * * ubuntu cd /home/ubuntu/assisto/backend && flock -n /tmp/assisto-antitheft-escalate.lock nice -n10 /home/ubuntu/assisto/.venv/bin/python manage.py antitheft_escalate >> /home/ubuntu/assisto/backend/logs/antitheft_escalate.log 2>&1
*/5 * * * * ubuntu cd /home/ubuntu/assisto/backend && flock -n /tmp/assisto-ops-watch.lock nice -n15 /home/ubuntu/assisto/.venv/bin/python manage.py ops_watch >> /home/ubuntu/assisto/backend/logs/ops_watch.log 2>&1
*/5 * * * * ubuntu cd /home/ubuntu/assisto/backend && flock -n /tmp/assisto-ai-health-check.lock nice -n15 /home/ubuntu/assisto/.venv/bin/python manage.py ai_health_check >> /home/ubuntu/assisto/backend/logs/ai_health_check.log 2>&1
15 * * * * ubuntu cd /home/ubuntu/assisto/backend && nice -n15 ionice -c3 /home/ubuntu/assisto/.venv/bin/python manage.py meter_low_alerts >> /home/ubuntu/assisto/backend/logs/meter_low_alerts.log 2>&1
30 2 1 * * ubuntu /home/ubuntu/assisto/migration/restore_test.sh >> /home/ubuntu/assisto/backend/logs/restore_test.log 2>&1
*/5 * * * * ubuntu cd /home/ubuntu/assisto/backend && flock -n /tmp/assisto-tagada-sweep.lock nice -n10 /home/ubuntu/assisto/.venv/bin/python manage.py tagada_sweep --quiet >> /home/ubuntu/assisto/logs/tagada_sweep.log 2>&1
20 * * * * ubuntu cd /home/ubuntu/assisto/backend && flock -n /tmp/assisto-vault-expiry-alerts.lock nice -n15 ionice -c3 /home/ubuntu/assisto/.venv/bin/python manage.py vault_expiry_alerts --quiet >> /home/ubuntu/assisto/logs/vault_expiry_alerts.log 2>&1
35 * * * * ubuntu cd /home/ubuntu/assisto/backend && flock -n /tmp/assisto-vehicle-reminders.lock nice -n15 ionice -c3 /home/ubuntu/assisto/.venv/bin/python manage.py vehicle_reminders --quiet >> /home/ubuntu/assisto/logs/vehicle_reminders.log 2>&1
45 3 * * * ubuntu cd /home/ubuntu/assisto/backend && flock -n /tmp/assisto-vehicle-daily-rollup.lock nice -n15 ionice -c3 /home/ubuntu/assisto/.venv/bin/python manage.py vehicle_daily_rollup >> /home/ubuntu/assisto/logs/vehicle_daily_rollup.log 2>&1
17 * * * * ubuntu cd /home/ubuntu/assisto/backend && flock -n /tmp/assisto-shop-clip-purge.lock nice -n15 ionice -c3 /home/ubuntu/assisto/.venv/bin/python manage.py shop_clip_purge >> /home/ubuntu/assisto/logs/shop_clip_purge.log 2>&1
* * * * * ubuntu cd /home/ubuntu/assisto/backend && nice -n10 /home/ubuntu/assisto/.venv/bin/python manage.py minute_jobs --log-dir /home/ubuntu/assisto/backend/logs >> /home/ubuntu/assisto/backend/logs/minute_jobs.log 2>&1
50 3 * * * ubuntu cd /home/ubuntu/assisto/backend && flock -n /tmp/assisto-agent-core-retention.lock nice -n15 ionice -c3 /home/ubuntu/assisto/.venv/bin/python manage.py agent_core_retention >> /home/ubuntu/assisto/logs/agent_core_retention.log 2>&1
* * * * * ubuntu cd /home/ubuntu/assisto/backend && flock -n /tmp/assisto-shop-guard-tick.lock nice -n10 /home/ubuntu/assisto/.venv/bin/python manage.py shop_guard_tick >> /home/ubuntu/assisto/logs/shop_guard_tick.log 2>&1
15 2 * * * ubuntu /home/ubuntu/assisto/migration/backup.sh >>/home/ubuntu/assisto/backend/logs/backup.log 2>&1
*/5 * * * * root systemctl is-active --quiet assisto || systemctl restart assisto; systemctl is-active --quiet coturn || systemctl restart coturn
"""

# jobs added to JOBS on 2 Nov that are NOT installed live (honest not_scheduled)
NOT_INSTALLED_2NOV = {"agent_nudges", "agent_memory_learn", "probashi_daily",
                      "calls_delivery_snapshot", "ai_usage_monthly", "ezviz_poll_alarms"}


def installed(text):
    """Feed `text` through the real reader (comments dropped)."""
    with mock.patch("core.ops_health.subprocess.run") as run, \
            mock.patch("core.ops_health.glob.glob", return_value=[]):
        run.return_value = mock.Mock(returncode=0, stdout=text)
        return H.installed_cron_text()


def manage_jobs():
    return [j for j in H.JOBS if j.kind == "manage"]


# ------------------------------------------------------------ coverage
class EveryJobTrackedTests(TestCase):
    def test_every_job_command_exists_and_handle_has_heartbeat(self):
        cmds = get_commands()
        for j in manage_jobs():
            self.assertIn(j.name, cmds, "%s: no management command" % j.name)
            cmd = load_command_class(cmds[j.name], j.name)
            self.assertEqual(getattr(type(cmd).handle, "ops_job", None), j.name,
                             "%s: handle is not wrapped by @track_job(%r)" % (j.name, j.name))

    def test_names_unique_and_shell_jobs_report_heartbeats(self):
        names = [j.name for j in H.JOBS]
        self.assertEqual(len(names), len(set(names)))
        root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        for script, name in (("migration/backup.sh", "backup"),
                             ("migration/restore_test.sh", "restore_test")):
            with open(os.path.join(root, script)) as fh:
                body = " ".join(fh.read().replace("\\\n", " ").split())
            self.assertIn("manage.py ops_heartbeat %s" % name, body)

    def test_meter_low_alerts_and_new_jobs_registered(self):
        for n in {"meter_low_alerts"} | NOT_INSTALLED_2NOV:
            self.assertIn(n, H.JOB_BY_NAME)

    def test_live_cron_has_no_unknown_command_and_no_double(self):
        text = installed(LIVE_2NOV)
        d = H.cron_diff(text)
        self.assertEqual(d["unknown"], [])          # every scheduled command is watched
        self.assertEqual(d["double"], [])
        self.assertEqual(d["old_lines"], [])        # the #OFF lines are comments
        self.assertEqual({n for n, _ in d["missing"]}, NOT_INSTALLED_2NOV)

    def test_unknown_command_is_reported(self):
        text = installed(LIVE_2NOV + "0 1 * * * ubuntu cd /x && /v/python manage.py credits_verify\n")
        self.assertEqual(H.cron_diff(text)["unknown"], ["credits_verify"])


# ------------------------------------------------------------ minute_jobs
class ViaMinuteJobsTests(TestCase):
    def test_via_jobs_recommend_the_minute_jobs_line(self):
        for name in H.MINUTE_JOB_NAMES:
            job = H.JOB_BY_NAME[name]
            self.assertEqual(job.via, "minute_jobs")
            self.assertEqual(job.recommended_line(), H.minute_jobs_cron_line())
        missing = dict((j.name, line) for j, line in H.missing_cron(""))
        self.assertEqual(missing["journey_sweep"], H.minute_jobs_cron_line())
        self.assertEqual(missing["calls_sweep"], H.JOB_BY_NAME["calls_sweep"].cron_line())

    def test_old_standalone_line_uncommented_is_a_double_run(self):
        old = H.JOB_BY_NAME["journey_sweep"].cron_line()
        live = LIVE_2NOV.replace("#OFF * * * * * ubuntu cd /home/ubuntu/assisto/backend && "
                                 "flock -n /tmp/assisto-journey-sweep.lock",
                                 "* * * * * ubuntu cd /home/ubuntu/assisto/backend && "
                                 "flock -n /tmp/assisto-journey-sweep.lock")
        for text in (installed(live), installed(LIVE_2NOV + old + "\n")):
            d = H.cron_diff(text)
            self.assertEqual([n for n, _ in d["old_lines"]], ["journey_sweep"])
            self.assertEqual(d["double"], [("journey_sweep", 2)])
            snap = H.snapshot(cron_text=text, service_runner=lambda u: "")
            st = {j["name"]: j for j in snap["jobs"]}["journey_sweep"]
            self.assertEqual(st["status"], "double_run")
            self.assertIn("double_run", H.BAD_JOB)
            chk = dict((k, (bad, det)) for k, bad, det, _ in H.checks_from(snap))
            self.assertTrue(chk["job:journey_sweep"][0])

    def test_same_job_in_user_crontab_and_cron_d_is_double(self):
        extra = ("* * * * * ubuntu cd /home/ubuntu/assisto/backend && /v/python manage.py "
                 "bizagent_process >> l 2>&1\n")
        d = H.cron_diff(installed(LIVE_2NOV + extra))
        self.assertIn(("bizagent_process", 2), d["double"])


# ------------------------------------------------------------ bounded runtime
class BoundedRuntimeTests(TestCase):
    def setUp(self):
        self.now = timezone.now()

    def test_every_manage_line_has_flock_and_timeout(self):
        for j in manage_jobs():
            line = j.cron_line()
            self.assertIn("flock -n %s " % H.lock_path(j.name), line, j.name)
            self.assertIn("timeout -k 30 %d " % j.kill_s, line, j.name)
            self.assertGreaterEqual(j.kill_s, j.max_runtime_s)
            self.assertLessEqual(j.max_runtime_s, max(j.interval, 50))
        self.assertEqual(H.JOB_BY_NAME["calls_sweep"].max_runtime_s, 51)
        self.assertEqual(H.JOB_BY_NAME["calls_sweep"].kill_s, 120)
        self.assertEqual(H.JOB_BY_NAME["billing_daily"].max_runtime_s, 3 * 3600)
        self.assertEqual(H.JOB_BY_NAME["billing_daily"].kill_s, 4 * 3600)

    def _hb(self, job, ms, rc=0):
        t = self.now - timedelta(seconds=30)
        return JobHeartbeat.objects.create(name=job.name, last_start=t, last_finish=t,
                                           last_ok=t if rc == 0 else None, last_rc=rc,
                                           last_duration_ms=ms)

    def test_slow_run_is_bad_and_needs_two_checks(self):
        job = H.JOB_BY_NAME["calls_sweep"]
        self.assertEqual(H.job_status(job, self._hb(job, 2000), now=self.now)["status"], "ok")
        JobHeartbeat.objects.all().delete()
        st = H.job_status(job, self._hb(job, 70000), now=self.now)
        self.assertEqual(st["status"], "slow")
        self.assertIn("70s", st["detail"])
        self.assertIn("slow", H.BAD_JOB)
        snap = {"jobs": [dict(st, name=job.name, cron_line=job.cron_line())], "services": []}
        (key, bad, _detail, need), = H.checks_from(snap)
        self.assertTrue(bad)
        self.assertEqual(need, 2)

    def test_killed_run_is_failing_with_reason(self):
        job = H.JOB_BY_NAME["booking_reminders"]

        @H.track_job(job.name)
        def handle():
            raise SystemExit(H.TERM_RC)        # what SIGTERM turns into
        with self.assertRaises(SystemExit):
            handle()
        hb = JobHeartbeat.objects.get(name=job.name)
        self.assertEqual(hb.last_rc, 143)
        self.assertIn("time limit", hb.last_error)
        self.assertFalse(hb.running)
        self.assertEqual(H.job_status(job, hb, now=timezone.now())["status"], "failing")

    def test_sigterm_handler_installed_only_during_run_and_restored(self):
        calls = []
        with mock.patch("signal.getsignal", return_value=signal.SIG_DFL), \
                mock.patch("signal.signal", side_effect=lambda s, h: calls.append(h)):
            @H.track_job("x_test_job")
            def handle():
                return 7
            self.assertEqual(handle(), 7)
        self.assertEqual(calls, [H._term_to_exit, signal.SIG_DFL])
        with mock.patch("signal.getsignal", return_value=signal.SIG_IGN), \
                mock.patch("signal.signal") as sig:
            H.track_job("x_test_job")(lambda: 1)()
        sig.assert_not_called()                # a custom handler is left alone


# ------------------------------------------------------------ renderer
class RenderCronFileTests(TestCase):
    def test_file_has_every_job_once(self):
        text = H.render_cron_file()
        for j in H.JOBS:
            if j.via == "minute_jobs":
                self.assertNotIn(j.cron_line(), text)
            else:
                self.assertEqual(text.count(j.cron_line()), 1, j.name)
        self.assertEqual(text.count(H.minute_jobs_cron_line()), 1)
        self.assertIn(H.WATCHDOG_LINE, text)
        cmds = [ln for ln in text.splitlines() if ln and not ln.startswith("#")]
        # rendered = installed: nothing missing, nothing double
        d = H.cron_diff("\n".join(cmds))
        self.assertEqual((d["missing"], d["double"], d["old_lines"], d["unknown"]),
                         ([], [], [], []))

    def test_command_prints_file_and_diff_read_only(self):
        out = StringIO()
        call_command("ops_cron_file", stdout=out)
        self.assertEqual(out.getvalue(), H.render_cron_file())
        out = StringIO()
        with mock.patch("core.ops_health.installed_cron_text",
                        return_value=installed(LIVE_2NOV)):
            call_command("ops_cron_file", "--diff", stdout=out)
        txt = out.getvalue()
        self.assertIn("MISSING (6)", txt)
        self.assertIn("[ezviz_poll_alarms]", txt)
        self.assertIn("DOUBLE (0)", txt)
        self.assertIn("NOT IN JOBS (0)", txt)
        out = StringIO()
        with mock.patch("core.ops_health.installed_cron_text", return_value=""):
            call_command("ops_cron_file", "--diff", stdout=out)
        self.assertIn("not readable", out.getvalue())


# ------------------------------------------------------------ idempotency
def _user(phone, **kw):
    u = User.objects.create_user(name="U" + phone[-3:], phone=phone, password="pw-12345678")
    for k, v in kw.items():
        setattr(u, k, v)
    u.save()
    return u


class BillingOverlapTests(TestCase):
    """Two runs that both listed the same due item: only ONE debit."""

    def setUp(self):
        self.debits = []

        def debit(user, need, note=""):
            self.debits.append((user.pk, need, note))
            return need
        p = mock.patch("core.shop_views._debit_camera_credits", side_effect=debit)
        p.start()
        self.addCleanup(p.stop)
        self.owner = _user("01710009001")

    def test_shop_camera_charged_once_when_runs_overlap(self):
        from core import shop_views as SV
        from core.models import ShopCamera, ShopSite
        from core.management.commands.shop_camera_billing import run_billing
        site = ShopSite.objects.create(owner=self.owner, name="Main")
        cam = ShopCamera.objects.create(site=site, name="Extra")
        ShopCamera.objects.filter(pk=cam.pk).update(
            billed_until=timezone.now() - timedelta(hours=1))
        with mock.patch("core.shop_views._included_cameras", return_value=0), \
                mock.patch("core.shop_views._extra_camera_credits", return_value=20):
            stale = list(SV.owner_enabled_cameras(self.owner))   # run B lists first
            self.assertEqual(run_billing()["renewed"], 1)        # run A charges
            with mock.patch("core.shop_views.owner_enabled_cameras", return_value=stale):
                res = run_billing()                              # run B, stale list
            self.assertEqual(res["renewed"], 0)
            self.assertEqual(run_billing()["renewed"], 0)        # same-day re-run
        self.assertEqual(len(self.debits), 1)
        cam.refresh_from_db()
        self.assertGreater(cam.billed_until, timezone.now() + timedelta(days=29))

    def test_vehicle_tracker_charged_once_when_runs_overlap(self):
        from core.models import VehicleTracker
        from core.management.commands import vehicle_tracking_billing as VB
        now = timezone.now()
        t = VehicleTracker.objects.create(owner=self.owner, imei="350000000000017",
                                          name="Car", state="paired", protocol="gt06",
                                          paired_at=now - timedelta(days=31),
                                          billed_until=now - timedelta(minutes=1))
        with mock.patch("core.vehicle_service.month_credits", return_value=30):
            stale = VB.due_tracker_ids(now)
            self.assertEqual(stale, [t.id])
            self.assertEqual(VB.run_billing(now)["renewed"], 1)
            with mock.patch.object(VB, "due_tracker_ids", return_value=stale):
                res = VB.run_billing(now)
            self.assertEqual((res["renewed"], res["disabled"]), (0, 0))
        self.assertEqual(len(self.debits), 1)
        t.refresh_from_db()
        self.assertEqual(t.state, "paired")
        self.assertGreater(t.billed_until, now + timedelta(days=29))


class MeterLowAlertsIdempotentTests(TestCase):
    def test_same_alert_pushed_once_across_runs(self):
        from core.models import PaCollectionItem
        u = _user("01710009002")
        PaCollectionItem.objects.create(user=u, collection="meter/meters",
                                        data={"name": "Home"})
        alert = {"level": "low", "runout_date": "2026-11-05",
                 "title": {"bn": "মিটার", "en": "Meter"},
                 "body": {"bn": "কম", "en": "Low"}}
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        state = os.path.join(tmp.name, "meter.json")
        with mock.patch("core.push.is_available", return_value=True), \
                mock.patch("core.push.push_to_user", return_value=1) as push, \
                mock.patch("core.logic.prepaid_meter.in_quiet_hours", return_value=False), \
                mock.patch("core.logic.prepaid_meter.low_alert", return_value=alert):
            for _ in range(3):
                call_command("meter_low_alerts", "--state-file", state, stdout=StringIO())
        self.assertEqual(push.call_count, 1)
        self.assertTrue(JobHeartbeat.objects.filter(name="meter_low_alerts", last_rc=0).exists())


class BriefingsBoundedTests(TestCase):
    def test_limit_and_rerun_make_one_briefing_per_user(self):
        from core.models import NightBriefing
        _user("01710009003")
        _user("01710009004")
        total = User.objects.count()
        with mock.patch("core.management.commands.generate_briefings.ai.available",
                        return_value=False), \
                mock.patch("core.management.commands.generate_briefings._build_alerts",
                           return_value=[]):
            call_command("generate_briefings", "--limit", "1", stdout=StringIO())
            self.assertEqual(NightBriefing.objects.count(), 1)
            call_command("generate_briefings", stdout=StringIO())
            call_command("generate_briefings", stdout=StringIO())
        self.assertEqual(NightBriefing.objects.count(), total)
        self.assertEqual(NightBriefing.objects.values("user").distinct().count(), total)


class WatchersBudgetTests(TestCase):
    def test_budget_stops_new_checks_and_leaves_them_for_next_run(self):
        from core.models import Watcher
        u = _user("01710009005")
        Watcher.objects.create(user=u, kind="rss", label="News", interval_min=60)
        mod = "core.management.commands.run_watchers"
        with mock.patch(mod + ".watcher.check", return_value=False) as chk, \
                mock.patch(mod + ".time.sleep"):
            out = StringIO()
            call_command("run_watchers", "--max-seconds", "0", stdout=out)
            self.assertEqual(chk.call_count, 0)
            self.assertIn("left_for_next_run=1", out.getvalue())
            call_command("run_watchers", stdout=StringIO())
            self.assertEqual(chk.call_count, 1)
