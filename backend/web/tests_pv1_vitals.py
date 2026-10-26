"""play-vitals: Google Play Vitals pull (mocked HTTP — never the network) and
Owner Admin → Play Vitals page (EN/BN, with/without data)."""
import io
import json
import os
import tempfile
from datetime import date, timedelta
from unittest import mock

from django.core.management import call_command
from django.test import TestCase, override_settings

from core import play_vitals as PV
from core.models import NotifEvent, PlayErrorIssue, PlayVitalDaily, User
from web.tests_o2_owner_admin import OwnerBase


def _key_file(d):
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    pk = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = pk.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                           serialization.NoEncryption()).decode()
    p = os.path.join(d, "sa.json")
    with open(p, "w") as f:
        json.dump({"client_email": "svc@example.iam.gserviceaccount.com",
                   "private_key": pem, "token_uri": "https://oauth2.example/token"}, f)
    return p


class R:
    def __init__(self, status=200, body=None):
        self.status_code, self._b = status, body if body is not None else {}
        self.text = json.dumps(self._b)

    def json(self):
        return self._b


FRESH = {"freshnessInfo": {"freshnesses": [
    {"aggregationPeriod": "HOURLY", "latestEndTime": {"year": 2026, "month": 10, "day": 25,
                                                      "hours": 3, "timeZone": {"id": "UTC"}}},
    {"aggregationPeriod": "DAILY", "latestEndTime": {"year": 2026, "month": 10, "day": 18,
                                                     "timeZone": {"id": "America/Los_Angeles"}}},
]}}


def _row(d, metrics, users, dim=None):
    row = {"startTime": {"year": d.year, "month": d.month, "day": d.day},
           "metrics": [{"metric": k, "decimalValue": {"value": str(v)}}
                       for k, v in metrics.items()]
           + [{"metric": "distinctUsers", "decimalValue": {"value": str(users)}}]}
    if dim:
        row["dimensions"] = [dim]
    return row


class FakeHTTP:
    """Routes by URL suffix; records every call. No socket is ever opened."""

    def __init__(self, fail=None, issues_pages=1):
        self.calls, self.fail, self.issues_pages = [], fail or {}, issues_pages

    def _rec(self, method, url, kw):
        self.calls.append((method, url, kw))
        for suffix, status in self.fail.items():
            if url.endswith(suffix):
                if status == "timeout":
                    raise TimeoutError("slow")
                return R(status, {"error": {"message": "nope"}})
        return None

    def post(self, url, **kw):
        bad = self._rec("post", url, kw)
        if bad:
            return bad
        if url.endswith("/token"):
            return R(200, {"access_token": "tok-123"})
        body = kw["json"]
        d0 = date(2026, 10, 17)
        dims = body.get("dimensions")
        crash = "crashRate" in body["metrics"]
        m = ({"crashRate": 0.02, "userPerceivedCrashRate": 0.015} if crash
             else {"anrRate": 0.004, "userPerceivedAnrRate": 0.003})
        if not dims:
            if not body.get("pageToken"):
                return R(200, {"rows": [_row(d0, m, 100)], "nextPageToken": "p2"})
            return R(200, {"rows": [_row(d0 - timedelta(days=1), m, 50)]})
        dim = {"deviceModel": {"dimension": "deviceModel", "stringValue": "realme/RMX3491",
                               "valueLabel": "realme 9i"},
               "apiLevel": {"dimension": "apiLevel", "int64Value": "33",
                            "valueLabel": "Android 13"},
               "versionCode": {"dimension": "versionCode", "int64Value": "10243"}}[dims[0]]
        return R(200, {"rows": [_row(d0, m, 40, dim)]})

    def get(self, url, **kw):
        bad = self._rec("get", url, kw)
        if bad:
            return bad
        if url.endswith("MetricSet"):
            return R(200, FRESH)
        if url.endswith("errorIssues:search"):
            tok = (kw.get("params") or {}).get("pageToken")
            if not tok:
                body = {"errorIssues": [{
                    "name": "apps/com.assisto.assisto/errorIssues/aaa111", "type": "CRASH",
                    "cause": "java.lang.RuntimeException: TypeToken",
                    "location": "com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver",
                    "distinctUsers": "7", "errorReportCount": "12",
                    "firstAppVersion": {"versionCode": "10230"},
                    "lastAppVersion": {"versionCode": "10243"},
                    "firstOsVersion": {"apiLevel": "29"}, "lastOsVersion": {"apiLevel": "34"},
                    "lastErrorReportTime": "2026-10-24T10:00:00Z"}]}
                if self.issues_pages > 1:
                    body["nextPageToken"] = "i2"
                return R(200, body)
            return R(200, {"errorIssues": [{
                "name": "apps/com.assisto.assisto/errorIssues/bbb222", "type": "ANR",
                "cause": "Input dispatching timed out", "distinctUsers": "2",
                "errorReportCount": "3"}]})
        if url.endswith("errorReports:search"):
            return R(200, {"errorReports": [{
                "reportText": "FATAL EXCEPTION\n" + "at x.y.z\n" * 2000,
                "deviceModel": {"marketingName": "realme 9i",
                                "deviceId": {"buildBrand": "realme", "buildDevice": "RMX3491"}},
                "osVersion": {"apiLevel": "33"}, "appVersion": {"versionCode": "10243"}}]})
        return R(404, {})


@mock.patch("core.push.notify_owner", lambda *a, **k: None)
class PullTests(TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.key = _key_file(self.tmp.name)
        self.owner = User.objects.create_superuser(name="Owner", phone="01700000999",
                                                   password="x")

    def tearDown(self):
        self.tmp.cleanup()

    def test_token_minted_locally_without_network(self):
        sa = PV.load_key(self.key)
        jwt = PV.signed_assertion(sa, now=1000)
        self.assertEqual(jwt.count("."), 2)
        http = FakeHTTP()
        self.assertEqual(PV.mint_token(sa, http), "tok-123")
        method, url, kw = http.calls[0]
        self.assertEqual(url, "https://oauth2.example/token")
        self.assertEqual(kw["data"]["assertion"].split(".")[0], jwt.split(".")[0])
        self.assertIn("timeout", kw)

    def test_full_pull_clamps_to_freshness_and_pages(self):
        http = FakeHTTP(issues_pages=2)
        logs = []
        s = PV.run(http=http, key_path=self.key, log=logs.append)
        self.assertTrue(s["ok"])
        queries = [c for c in http.calls if c[1].endswith(":query")]
        self.assertTrue(queries)
        for _, _, kw in queries:
            tl = kw["json"]["timelineSpec"]
            self.assertEqual((tl["endTime"]["year"], tl["endTime"]["month"],
                              tl["endTime"]["day"]), (2026, 10, 18))
            self.assertEqual(tl["endTime"]["timeZone"]["id"], "America/Los_Angeles")
            self.assertEqual(tl["startTime"]["day"], 20)   # 28 days earlier (Sep 20)
            self.assertEqual(kw["headers"]["Authorization"], "Bearer tok-123")
        # overall paged: 2 days each for crash, user_perceived_crash, anr, upa
        ov = PlayVitalDaily.objects.filter(dim_kind="overall")
        self.assertEqual(ov.count(), 8)
        self.assertTrue(any(c[2]["json"].get("pageToken") == "p2" for c in queries))
        dev = PlayVitalDaily.objects.get(dim_kind="device", metric="crash")
        self.assertEqual((dev.dim_value, dev.label, dev.users), ("realme/RMX3491", "realme 9i", 40))
        self.assertAlmostEqual(dev.rate, 0.02)
        # issues: both pages, a sample stack each, trimmed
        self.assertEqual(PlayErrorIssue.objects.count(), 2)
        i = PlayErrorIssue.objects.get(issue_id="aaa111")
        self.assertEqual((i.first_version, i.last_version, i.first_api, i.last_api,
                          i.users, i.reports), ("10230", "10243", 29, 34, 7, 12))
        self.assertLessEqual(len(i.sample_stack), PV.STACK_MAX)
        self.assertEqual((i.sample_device, i.sample_os, i.status), ("realme 9i", "33", "new"))
        sample = [c for c in http.calls if c[1].endswith("errorReports:search")][0]
        self.assertEqual(sample[2]["params"]["filter"], "errorIssueId = aaa111")
        self.assertNotIn("tok-123", "\n".join(logs))

    def test_upsert_idempotent(self):
        PV.run(http=FakeHTTP(), key_path=self.key)
        n1 = (PlayVitalDaily.objects.count(), PlayErrorIssue.objects.count())
        http = FakeHTTP()
        PV.run(http=http, key_path=self.key)
        self.assertEqual((PlayVitalDaily.objects.count(), PlayErrorIssue.objects.count()), n1)
        # a known issue with a sample is not re-sampled
        self.assertFalse([c for c in http.calls if c[1].endswith("errorReports:search")])

    def test_missing_key_exits_zero(self):
        out = io.StringIO()
        with override_settings(PLAY_SERVICE_ACCOUNT_JSON="/nonexistent/sa.json"):
            call_command("play_vitals_pull", stdout=out)
        self.assertIn("skipped=no_key", out.getvalue())
        self.assertEqual(PlayVitalDaily.objects.count(), 0)

    def test_unreadable_key_is_quiet(self):
        bad = os.path.join(self.tmp.name, "bad.json")
        with open(bad, "w") as f:
            f.write("{not json")
        self.assertEqual(PV.run(http=FakeHTTP(), key_path=bad)["skipped"], "no_key")

    def test_http_errors_logged_never_raise(self):
        logs = []
        http = FakeHTTP(fail={"crashRateMetricSet": 403, "anrRateMetricSet:query": 500,
                              "errorIssues:search": "timeout"})
        s = PV.run(http=http, key_path=self.key, log=logs.append)
        self.assertTrue(s["ok"])
        self.assertGreaterEqual(s["errors"], 3)
        self.assertEqual(PlayVitalDaily.objects.count(), 0)
        joined = "\n".join(logs)
        self.assertIn("HTTP 403", joined)
        self.assertIn("HTTP 500", joined)
        self.assertIn("TimeoutError", joined)

    def test_token_failure(self):
        s = PV.run(http=FakeHTTP(fail={"/token": 401}), key_path=self.key)
        self.assertEqual(s["skipped"], "no_token")

    def test_command_runs_with_key(self):
        out = io.StringIO()
        with override_settings(PLAY_SERVICE_ACCOUNT_JSON=self.key), \
                mock.patch("requests.Session", lambda: FakeHTTP()):
            call_command("play_vitals_pull", stdout=out)
        self.assertIn("ok=True", out.getvalue())

    def test_new_issue_alert_deduped(self):
        PV.run(http=FakeHTTP(), key_path=self.key)
        ev = NotifEvent.objects.filter(type="admin", meta__kind="play_new_issue")
        self.assertEqual(ev.count(), 1)
        self.assertEqual(ev.get().route, "owner")
        self.assertTrue(all(PlayErrorIssue.objects.values_list("notified", flat=True)))
        PV.run(http=FakeHTTP(), key_path=self.key)
        self.assertEqual(ev.count(), 1)

    def test_threshold_alert_deduped(self):
        # fake data: user-perceived crash 1.5% > 1.09%; ANR 0.3% < 0.47%
        PV.run(http=FakeHTTP(), key_path=self.key)
        th = NotifEvent.objects.filter(type="admin", meta__kind="play_threshold")
        self.assertEqual(list(th.values_list("meta__metric", flat=True)),
                         ["user_perceived_crash"])
        PV.run(http=FakeHTTP(), key_path=self.key)
        self.assertEqual(th.count(), 1)

    def test_weighted_rate(self):
        d = date(2026, 10, 17)
        PlayVitalDaily.objects.create(date=d, metric="crash", rate=0.01, users=300)
        PlayVitalDaily.objects.create(date=d - timedelta(days=1), metric="crash",
                                      rate=0.05, users=100)
        self.assertAlmostEqual(PV.weighted_rate("crash"), 0.02)
        self.assertIsNone(PV.weighted_rate("anr"))


class VitalsPageTests(OwnerBase):
    def test_empty_en_bn(self):
        self.ready()
        r = self.c.get("/owner/vitals?lang=en")
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "No Google Play Vitals data yet")
        self.assertContains(r, 'href="/owner/vitals"')
        self.assertContains(r, 'href="/owner/reports/errors"')
        r = self.c.get("/owner/vitals?lang=bn")
        self.assertContains(r, "প্লে ভাইটালস")

    def test_with_data(self):
        self.ready()
        d = date(2026, 10, 17)
        for i in range(3):
            day = d - timedelta(days=i)
            PlayVitalDaily.objects.create(date=day, metric="crash", rate=0.02, users=100)
            PlayVitalDaily.objects.create(date=day, metric="user_perceived_crash",
                                          rate=0.0125, users=100)
            PlayVitalDaily.objects.create(date=day, metric="anr", rate=0.004, users=100)
            PlayVitalDaily.objects.create(date=day, metric="user_perceived_crash",
                                          dim_kind="device", dim_value="realme/RMX3491",
                                          label="realme 9i", rate=0.03, users=20)
            PlayVitalDaily.objects.create(date=day, metric="user_perceived_crash",
                                          dim_kind="device", dim_value="tiny/one",
                                          label="Tiny One", rate=0.5, users=1)
            PlayVitalDaily.objects.create(date=day, metric="user_perceived_crash",
                                          dim_kind="api", dim_value="33",
                                          label="Android 13", rate=0.01, users=50)
        PlayErrorIssue.objects.create(issue_id="aaa111", type="CRASH", cause="TypeToken boom",
                                      first_version="10230", last_version="10243", users=7,
                                      reports=12, sample_stack="FATAL EXCEPTION at x.y")
        r = self.c.get("/owner/vitals?lang=en")
        self.assertEqual(r.status_code, 200)
        for s in ("Google&#x27;s data is up to 2026-10-17", "1.25%", "Above limit", "1.09",
                  "0.47", "realme 9i", "Android 13", "TypeToken boom", "10230",
                  "FATAL EXCEPTION", "<svg"):
            self.assertContains(r, s)
        self.assertNotContains(r, "Tiny One")       # under min users (10)
        self.assertContains(self.c.get("/owner/vitals?lang=en&min_users=0"), "Tiny One")
        self.assertEqual(self.c.get("/owner/vitals?metric=evil&min_users=x").status_code, 200)
        r = self.c.get("/owner/vitals?lang=bn")
        self.assertContains(r, "১.২৫%")
        self.assertContains(r, "সীমার উপরে")

    def test_mark_known(self):
        self.ready()
        i = PlayErrorIssue.objects.create(issue_id="z1", type="CRASH")
        r = self.post("/owner/vitals/issues/%d/known" % i.pk)
        self.assertEqual(r.status_code, 302)
        i.refresh_from_db()
        self.assertEqual(i.status, "known")
        self.post("/owner/vitals/issues/%d/known" % i.pk, {"undo": "1"})
        i.refresh_from_db()
        self.assertEqual(i.status, "new")
        self.assertEqual(self.post("/owner/vitals/issues/99999/known").status_code, 404)

    def test_requires_owner(self):
        from web.tests_o2_owner_admin import SClient
        self.assertIn(SClient().get("/owner/vitals").status_code, (302, 403))
