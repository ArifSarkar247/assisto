"""livemon: read-only daily live monitor (core/live_monitor.py, manage.py
live_monitor, Owner Admin → Live health card). Google is mocked; all data
here is made up."""
import io
import json
import os
import shutil
import tempfile
from datetime import datetime, timedelta
from unittest import mock
from zoneinfo import ZoneInfo

from django.core.management import call_command
from django.test import SimpleTestCase, TestCase, override_settings
from django.utils import timezone

from core import live_monitor as LM
from core import ops_health as H

DHAKA = ZoneInfo("Asia/Dhaka")
UTC = ZoneInfo("UTC")


# ------------------------------------------------------------ fake Google
class _Resp:
    def __init__(self, body, status=200):
        self._b, self.status_code, self.text = body, status, json.dumps(body)

    def json(self):
        return self._b


def _gd(d):
    return {"year": d.year, "month": d.month, "day": d.day}


def _row(d, crash=None, anr=None, users=100, version=None):
    m = [{"metric": "distinctUsers", "decimalValue": {"value": str(users)}}]
    if crash is not None:
        m += [{"metric": "userPerceivedCrashRate", "decimalValue": {"value": str(crash)}},
              {"metric": "crashRate", "decimalValue": {"value": str(crash)}}]
    if anr is not None:
        m += [{"metric": "userPerceivedAnrRate", "decimalValue": {"value": str(anr)}},
              {"metric": "anrRate", "decimalValue": {"value": str(anr)}}]
    r = {"startTime": _gd(d), "metrics": m}
    if version:
        r["dimensions"] = [{"dimension": "versionCode", "int64Value": version,
                            "valueLabel": "1.0." + version}]
    return r


class FakeGoogle:
    """GET metric set -> freshness; POST :query -> rows; GET errorIssues."""
    END = datetime(2026, 11, 16).date()

    def __init__(self, crash_last=0.02, crash_prev=0.004, anr_last=0.001):
        self.crash_last, self.crash_prev, self.anr_last = crash_last, crash_prev, anr_last
        self.calls = []

    def get(self, url, headers=None, timeout=None, params=None):
        self.calls.append(("get", url))
        if url.endswith("errorIssues:search"):
            return _Resp({"errorIssues": [
                {"name": "apps/x/errorIssues/a1", "type": "CRASH",
                 "cause": "java.lang.IllegalStateException", "location": "com.example.Foo.bar",
                 "distinctUsers": "3", "errorReportCount": "9",
                 "lastAppVersion": {"versionCode": "10338"}},
                {"name": "apps/x/errorIssues/a2", "type": "ANR", "cause": "Input dispatching",
                 "location": "android.os.MessageQueue", "distinctUsers": "7",
                 "errorReportCount": "7", "lastAppVersion": {"versionCode": "10337"}}]})
        return _Resp({"freshnessInfo": {"freshnesses": [{
            "aggregationPeriod": "DAILY",
            "latestEndTime": dict(_gd(self.END), timeZone={"id": "America/Los_Angeles"})}]}})

    def post(self, url, headers=None, timeout=None, json=None, data=None):
        self.calls.append(("post", url))
        crash = "crashRateMetricSet" in url
        dim = (json or {}).get("dimensions")
        prev = self.END - timedelta(days=1)
        if dim:
            rows = [_row(self.END, crash=self.crash_last if crash else None,
                         anr=None if crash else self.anr_last, users=80, version="10338"),
                    _row(prev, crash=0.0 if crash else None, anr=None if crash else 0.0,
                         users=20, version="10337")]
        else:
            rows = [_row(self.END, crash=self.crash_last if crash else None,
                         anr=None if crash else self.anr_last, users=100),
                    _row(prev, crash=self.crash_prev if crash else None,
                         anr=None if crash else 0.0, users=300)]
        return _Resp({"rows": rows})


def _with_key():
    return mock.patch.multiple("core.play_vitals",
                               load_key=mock.Mock(return_value={"client_email": "x@y",
                                                                "private_key": "k"}),
                               mint_token=mock.Mock(return_value="tok"))


class PlayVitalsTests(SimpleTestCase):
    def test_rates_latest_day_7d_and_versions(self):
        g = FakeGoogle()
        with _with_key():
            out = LM.play_vitals(http=g)
        self.assertTrue(out["ok"])
        self.assertEqual(out["latest_day"], "2026-11-16")
        self.assertAlmostEqual(out["crash_1d"], 0.02)
        # user-weighted: (0.02*100 + 0.004*300) / 400
        self.assertAlmostEqual(out["crash_7d"], 0.008)
        self.assertAlmostEqual(out["anr_1d"], 0.001)
        self.assertEqual(out["users_1d"], 100)
        self.assertEqual([v["version"] for v in out["by_version"]], ["10338", "10337"])
        self.assertEqual(out["top_issues"][0]["users"], 7)          # most users first
        self.assertEqual(out["top_issues"][1]["cause"], "java.lang.IllegalStateException")
        # read-only: only GETs and :query POSTs, never an edit
        for method, url in g.calls:
            self.assertIn("playdeveloperreporting.googleapis.com", url)
            if method == "post":
                self.assertTrue(url.endswith(":query"), url)

    def test_no_key_skips_without_any_call(self):
        g = FakeGoogle()
        with mock.patch("core.play_vitals.load_key", return_value=None):
            out = LM.play_vitals(http=g)
        self.assertFalse(out["ok"])
        self.assertEqual(out["skipped"], "no_key")
        self.assertEqual(g.calls, [])

    def test_google_down_never_raises(self):
        class Boom:
            def get(self, *a, **k):
                raise TimeoutError()
            post = get
        with _with_key():
            out = LM.play_vitals(http=Boom())
        self.assertFalse(out["ok"])
        self.assertTrue(out["skipped"])


# ------------------------------------------------------------ nginx
class NginxTests(SimpleTestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.d, True)
        self.now = datetime(2026, 11, 17, 0, 0, tzinfo=UTC)

    def _log(self, lines, name="api_timing.log"):
        p = os.path.join(self.d, name)
        with open(p, "w") as f:
            f.write("\n".join(lines) + "\n")
        return p

    def _t(self, hours_ago):
        return (self.now - timedelta(hours=hours_ago)).isoformat()

    def test_counts_5xx_top_endpoints_and_window(self):
        lines = [
            "%s 200 GET /api/v1/health 0.01 0.01" % self._t(1),
            "%s 502 GET /api/v1/chats/123/messages 0.5 0.5" % self._t(2),
            "%s 500 GET /api/v1/chats/98765/messages?x=1 0.5 0.5" % self._t(3),
            "%s 500 POST /api/v1/ai/ask 2.0 2.0" % self._t(4),
            "%s 500 POST /api/v1/ai/ask 2.0 2.0" % self._t(30),        # outside 24 h
            "%s 200 POST /api/v1/payments/play/verify 0.3 0.3" % self._t(5),
            "%s 409 POST /api/v1/payments/play/verify 0.3 0.3" % self._t(5),
            "%s 201 POST /api/v1/auth/register 0.3 0.3" % self._t(6),
            "%s 503 POST /api/v1/auth/register 0.3 0.3" % self._t(6),
            "garbage line",
        ]
        out = LM.nginx_stats(now=self.now, paths=(self._log(lines), "/nope/missing.log"))
        self.assertTrue(out["ok"])
        self.assertEqual(out["requests"], 8)
        self.assertEqual(out["errors_5xx"], 4)
        self.assertEqual(out["top_failing"][0],
                         {"method": "GET", "path": "/api/v1/chats/{id}/messages", "count": 2})
        self.assertEqual(out["play_verify"], {"ok": 1, "refused": 1, "error": 0})
        self.assertEqual(out["register"], {"ok": 1, "client": 0, "server": 1})

    def test_missing_logs_not_ok(self):
        out = LM.nginx_stats(now=self.now, paths=("/nope/a", "/nope/b"))
        self.assertFalse(out["ok"])
        self.assertEqual(out["errors_5xx"], 0)

    def test_spike_flags(self):
        rep = {"server": {"errors_5xx": 25, "share_5xx": 0.02, "max_5xx_hour": 5}}
        self.assertEqual([f["code"] for f in LM.p0_flags(rep)], ["server_5xx_spike"])
        rep = {"server": {"errors_5xx": 25, "share_5xx": 0.001, "max_5xx_hour": 5}}
        self.assertEqual(LM.p0_flags(rep), [])
        rep = {"server": {"errors_5xx": 31, "share_5xx": 0.001, "max_5xx_hour": 31}}
        self.assertEqual([f["code"] for f in LM.p0_flags(rep)], ["server_5xx_spike"])


class P0RuleTests(SimpleTestCase):
    def test_owner_thresholds(self):
        rep = {"play": {"crash_1d": 0.0101, "crash_7d": 0.009, "anr_1d": 0.0048, "anr_7d": 0.001},
               "users": {"signup_success": 0.69, "signup_otp_attempts": 10}}
        codes = [f["code"] for f in LM.p0_flags(rep)]
        self.assertEqual(codes, ["play_crash_1d", "play_anr_1d", "signup_broken"])

    def test_few_signup_attempts_are_not_p0(self):
        rep = {"users": {"signup_success": 0.2, "signup_otp_attempts": 9}}
        self.assertEqual(LM.p0_flags(rep), [])

    def test_is_due_once_a_dhaka_day_from_06(self):
        d = lambda h, m=0, day=17: datetime(2026, 11, day, h, m, tzinfo=DHAKA)  # noqa: E731
        self.assertFalse(LM.is_due(d(5, 59), None))
        self.assertTrue(LM.is_due(d(6, 0), None))
        self.assertFalse(LM.is_due(d(9, 0), d(6, 1)))
        self.assertTrue(LM.is_due(d(6, 0, day=18), d(6, 1)))

    def test_minute_job_registered(self):
        names = [n for n, _ in H.MINUTE_JOBS]
        self.assertIn("live_monitor", names)
        self.assertEqual(names[-1], "agent_core_run")
        self.assertEqual(dict(H.MINUTE_JOBS)["live_monitor"], {"tick": True})
        self.assertEqual(H.JOB_BY_NAME["live_monitor"].via, "minute_jobs")


# ------------------------------------------------------------ DB parts
PHONES = ["+88017000000%02d" % i for i in range(12)]   # made-up


class DbStatsTests(TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.d, True)

    def _signups(self, attempts, verified):
        from core.models import OtpChallenge, OtpProof
        now = timezone.now()
        for i, ph in enumerate(PHONES[:attempts]):
            for _ in range(2):    # a resend must not count twice
                OtpChallenge.objects.create(phone=ph, purpose="signup", code_hash="x",
                                            salt="s", expires_at=now + timedelta(minutes=5),
                                            sent=True)
            if i < verified:
                OtpProof.objects.create(token_hash="t%d" % i, phone=ph, purpose="signup",
                                        expires_at=now + timedelta(minutes=10))
        OtpChallenge.objects.create(phone=PHONES[0], purpose="login", code_hash="x", salt="s",
                                    expires_at=now, sent=True)

    def test_users_signup_success_and_dau_wau(self):
        from core.models import ActiveDay, User
        self._signups(12, 6)
        u1 = User.objects.create_user(name="Test A", phone="01700000091", password="pw-123456")
        u2 = User.objects.create_user(name="Test B", phone="01700000092", password="pw-123456")
        yday = timezone.localdate() - timedelta(days=1)
        ActiveDay.objects.create(user=u1, day=yday, cohort_day=yday)
        ActiveDay.objects.create(user=u2, day=yday - timedelta(days=3), cohort_day=yday)
        ActiveDay.objects.create(user=u2, day=yday - timedelta(days=9), cohort_day=yday)
        u = LM.users_stats()
        self.assertEqual(u["signup_otp_attempts"], 12)
        self.assertEqual(u["signup_otp_verified"], 6)
        self.assertAlmostEqual(u["signup_success"], 0.5)
        self.assertEqual(u["signups_24h"], 2)
        self.assertEqual((u["dau"], u["wau"]), (1, 2))
        self.assertIn("signup_broken", [f["code"] for f in LM.p0_flags({"users": u})])

    def test_payments(self):
        from core.models import PaymentEvent
        PaymentEvent.objects.create(kind="play.charge", channel="play", ref="GPA.1", amount_bdt=100)
        PaymentEvent.objects.create(kind="order.paid", channel="gateway", ref="o1", amount_bdt=50)
        PaymentEvent.objects.create(kind="order.verify_error", channel="gateway", ref="o2")
        PaymentEvent.objects.create(kind="play.test_charge", channel="play", ref="t1")
        p = LM.payments_stats()
        self.assertEqual(p["verified"], 2)
        self.assertEqual(p["verified_bdt"], 150.0)
        self.assertEqual(p["failed_events"], 1)
        self.assertEqual(p["test_charges"], 1)

    def test_collect_write_privacy_and_bangla_line(self):
        from core.models import User
        User.objects.create_user(name="Rahim Sample", phone="01700000093", password="pw-123456")
        self._signups(3, 3)
        with mock.patch("core.play_vitals.load_key", return_value=None):
            rep = LM.collect(log_paths=())
        LM.write(rep, self.d)
        body = open(os.path.join(self.d, "live_monitor_latest.json"), encoding="utf-8").read()
        for secret in PHONES[:3] + ["01700000093", "Rahim"]:
            self.assertNotIn(secret, body)
        js = json.loads(body)
        self.assertEqual(js["p0"], [])
        self.assertEqual(js["users"]["signups_24h"], 1)
        line = open(os.path.join(self.d, "live_monitor_bn.txt"), encoding="utf-8").read()
        self.assertEqual(line.count("\n"), 1)
        self.assertIn("সব ঠিক আছে", line)
        self.assertIn("নতুন ব্যবহারকারী ১ জন", line)
        self.assertNotIn("1 জন", line)

    def test_p0_line_names_the_problem(self):
        g = FakeGoogle(crash_last=0.03)
        with _with_key():
            rep = LM.collect(http=g, log_paths=())
        self.assertTrue(rep["p0_any"])
        self.assertIn("ক্র্যাশ ১%-এর বেশি (শেষ দিন)", rep["bn_line"])
        self.assertIn("৩.০০%", rep["bn_line"])

    def test_command_tick_runs_once_a_day(self):
        with override_settings(LIVE_MONITOR_DIR=self.d), \
                mock.patch("core.play_vitals.load_key", return_value=None), \
                mock.patch("core.live_monitor.NGINX_LOGS", ()), \
                mock.patch("core.live_monitor.is_due", side_effect=lambda now, last: last is None):
            call_command("live_monitor", tick=True, stdout=io.StringIO())
            self.assertTrue(os.path.exists(os.path.join(self.d, "live_monitor_bn.txt")))
            self.assertIsNotNone(H.stamp_get("live_monitor"))
            os.remove(os.path.join(self.d, "live_monitor_bn.txt"))
            call_command("live_monitor", tick=True, stdout=io.StringIO())
            self.assertFalse(os.path.exists(os.path.join(self.d, "live_monitor_bn.txt")))


# ------------------------------------------------------------ Owner Admin card
from web.tests_o2_owner_admin import OwnerBase  # noqa: E402


class LiveHealthCardTests(OwnerBase):
    def setUp(self):
        super().setUp()
        self.d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.d, True)

    def test_empty_then_p0_card(self):
        from web.owner.i18n import strings
        self.ready()
        with override_settings(LIVE_MONITOR_DIR=self.d):
            html = self.c.get("/owner/").content.decode()
            self.assertIn('id="live-health"', html)
            self.assertTrue(strings("bn")["lh_empty"] in html or strings("en")["lh_empty"] in html)
            g = FakeGoogle(crash_last=0.03)
            with _with_key():
                LM.write(LM.collect(http=g, log_paths=()), self.d)
            html = self.c.get("/owner/").content.decode()
        self.assertIn('id="live-p0"', html)
        self.assertTrue("৩.০০%" in html or "3.00%" in html)
        self.assertIn("java.lang.IllegalStateException", html)
