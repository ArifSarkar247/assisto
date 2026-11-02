"""lifebar — board groups 17 (daily life) + 18 (work).

Watch feed: a WatchHit is now pushed once (it used to sit silently).
Exam result: ExamWatcher pages are now polled by run_watchers (they were saved
but never checked), a change sets result_ready + one push; list/delete API;
per-user cap. Network + FCM are mocked; no real fetches.
"""
from datetime import date, datetime, timedelta
from io import StringIO
from unittest import mock

from django.core.management import call_command
from django.utils import timezone
from rest_framework.test import APIClient

from core import watcher
from core.models import Device, ExamWatcher, User, Watcher, WatchHit
from core.tests_push import _PushBase


def _client(u):
    c = APIClient()
    c.force_authenticate(u)
    return c


class WatchHitPushTests(_PushBase):
    def test_hit_is_pushed_once_with_watch_feed_route(self):
        u = self.mkuser("01710000001", lang="bn")
        Device.objects.create(user=u, push_token="tok-1")
        w = Watcher.objects.create(user=u, kind="page", label="ভিসা পাতা",
                                   config={"url": "https://example.org/v"},
                                   interval_min=60)
        seq = iter(["a", "b"])
        with mock.patch.object(watcher, "extract_value", lambda _w: next(seq)):
            self.assertIsNone(watcher.check(w))     # baseline
            hit = watcher.check(w)                  # changed
        self.assertIsNotNone(hit)
        self.assertEqual(watcher.notify_hit(hit), 1)
        p = self.fake.sent_payloads()[-1]["message"]
        self.assertEqual(p["data"]["route"], "watch_feed")
        self.assertEqual(p["data"]["kind"], "reminder")
        self.assertIn("ভিসা পাতা", p["data"]["title"])

    def test_run_watchers_pushes_on_change_only(self):
        u = self.mkuser("01710000002")
        Device.objects.create(user=u, push_token="tok-2")
        Watcher.objects.create(user=u, kind="page", label="X",
                               config={"url": "https://example.org/x"},
                               interval_min=60, last_hash="old", last_value="v0")
        with mock.patch.object(watcher, "extract_value", lambda _w: "v1"), \
                mock.patch("core.management.commands.run_watchers.time.sleep"):
            out = StringIO()
            call_command("run_watchers", stdout=out)
        self.assertIn("hits=1", out.getvalue())
        self.assertEqual(WatchHit.objects.count(), 1)
        self.assertEqual(len(self.fake.send_calls), 1)

    def test_notify_hit_never_raises_without_devices(self):
        u = self.mkuser("01710000003")
        w = Watcher.objects.create(user=u, kind="page", label="Y", config={})
        hit = WatchHit.objects.create(watcher=w, summary="s")
        self.assertEqual(watcher.notify_hit(hit), 0)


class ExamWatcherTests(_PushBase):
    def _ew(self, u, **kw):
        d = dict(user=u, label="SSC", url="https://eboardresults.com/x")
        d.update(kw)
        return ExamWatcher.objects.create(**d)

    def test_first_fetch_is_baseline_then_change_pushes(self):
        u = self.mkuser("01720000001")
        Device.objects.create(user=u, push_token="tok-e")
        ew = self._ew(u)
        with mock.patch.object(watcher, "_fetch", return_value="<p>soon</p>"):
            self.assertFalse(watcher.check_exam(ew))
            self.assertFalse(watcher.check_exam(ew))      # unchanged
        with mock.patch.object(watcher, "_fetch", return_value="<p>results</p>"):
            self.assertTrue(watcher.check_exam(ew))
        ew.refresh_from_db()
        self.assertTrue(ew.result_ready)
        p = self.fake.sent_payloads()[-1]["message"]
        self.assertEqual(p["data"]["route"], "exam")
        # honest wording: "may be out", never a fabricated result
        self.assertIn("থাকতে পারে", p["data"]["body"])

    def test_fetch_failure_counts_and_stops(self):
        u = self.mkuser("01720000002")
        ew = self._ew(u)
        with mock.patch.object(watcher, "_fetch", side_effect=OSError("down")):
            self.assertFalse(watcher.check_exam(ew))
        ew.refresh_from_db()
        self.assertEqual(ew.consecutive_failures, 1)
        ew.consecutive_failures = watcher.EXAM_MAX_FAILURES
        self.assertFalse(watcher.exam_due(ew))

    def test_due_schedule(self):
        u = self.mkuser("01720000003")
        tz = timezone.get_current_timezone()
        today = date(2026, 11, 10)
        before = self._ew(u, expected_date=today + timedelta(days=5))
        at6 = datetime(2026, 11, 10, 6, 0, tzinfo=tz)
        at7 = datetime(2026, 11, 10, 7, 0, tzinfo=tz)
        self.assertTrue(watcher.exam_due(before, at6))      # 6-hourly
        self.assertFalse(watcher.exam_due(before, at7))
        day = self._ew(u, expected_date=today)
        self.assertTrue(watcher.exam_due(day, at7))         # hourly on the day
        old = self._ew(u, expected_date=today - timedelta(days=60))
        self.assertFalse(watcher.exam_due(old, at7))        # stopped
        nourl = self._ew(u, url="")
        self.assertFalse(watcher.exam_due(nourl, at7))
        ready = self._ew(u, result_ready=True)
        self.assertFalse(watcher.exam_due(ready, at7))

    def test_list_delete_and_cap(self):
        u = self.mkuser("01720000004")
        other = self.mkuser("01720000005")
        c = _client(u)
        r = c.post("/api/v1/exam/watcher",
                   {"label": "HSC", "url": "https://eboardresults.com/",
                    "expected_date": "2026-11-20"}, format="json")
        self.assertEqual(r.status_code, 201)
        wid = r.data["id"]
        lst = c.get("/api/v1/exam/watcher").data["watchers"]
        self.assertEqual(len(lst), 1)
        self.assertTrue(lst[0]["checking"])
        self.assertFalse(lst[0]["result_ready"])
        # someone else cannot delete it
        self.assertEqual(_client(other).delete(f"/api/v1/exam/watcher?id={wid}")
                         .status_code, 404)
        self.assertEqual(c.delete(f"/api/v1/exam/watcher?id={wid}").status_code, 200)
        self.assertEqual(ExamWatcher.objects.filter(user=u).count(), 0)
        for i in range(10):
            self._ew(u, label=f"x{i}")
        r = c.post("/api/v1/exam/watcher",
                   {"url": "https://eboardresults.com/"}, format="json")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.data["error"], "limit")

    def test_run_watchers_polls_exam_pages(self):
        u = self.mkuser("01720000006")
        self._ew(u, last_snapshot="old-hash")
        with mock.patch.object(watcher, "_fetch", return_value="new page"), \
                mock.patch("core.management.commands.run_watchers.time.sleep"):
            out = StringIO()
            call_command("run_watchers", stdout=out)
        self.assertIn("exam_checked=1", out.getvalue())
        self.assertIn("exam_hits=1", out.getvalue())
