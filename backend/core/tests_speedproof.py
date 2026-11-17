"""speedproof: the Guard Box live-request fast path, the CI-only timing
middleware, and the screen-speed regression guard (tools/speedproof/guard.py)."""
import importlib.util
import json
import os
import tempfile
from datetime import timedelta
from pathlib import Path
from unittest import mock

from django.db import connection
from django.test import RequestFactory, SimpleTestCase, TestCase, override_settings
from django.test.utils import CaptureQueriesContext
from django.http import HttpResponse

from core import ci_timing
from core.tests_shop_ops import _Base

ROOT = Path(__file__).resolve().parents[2]


class LivePollTests(_Base):
    def _online(self):
        r = self.dev().post("/api/v1/shop/heartbeat",
                            {"camera_token": self.cam.camera_token, "caps": ["live"]},
                            format="json")
        self.assertEqual(r.status_code, 200)
        return r

    def _pending(self):
        return self.dev().get("/api/v1/shop/live/pending",
                              HTTP_X_SHOP_TOKEN=self.cam.camera_token)

    def test_heartbeat_tells_the_phone_how_often_to_poll(self):
        self.assertEqual(self._online().data["live_poll_s"], 4)
        with override_settings(SHOP_LIVE_POLL_S=0):
            self.assertEqual(self._online().data["live_poll_s"], 0)
        with override_settings(SHOP_LIVE_POLL_S=999):
            self.assertEqual(self._online().data["live_poll_s"], 60)

    def test_empty_poll_is_cheap(self):
        self._online()
        with CaptureQueriesContext(connection) as q:
            r = self._pending()
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["sessions"], [])
        self.assertEqual(r.data["poll_s"], 4)
        # token -> camera (1) + one EXISTS; no sweep UPDATEs, no ICE config
        self.assertLessEqual(len(q.captured_queries), 3, [x["sql"] for x in q.captured_queries])
        self.assertFalse(any(x["sql"].lstrip().upper().startswith("UPDATE")
                             for x in q.captured_queries))

    def test_poll_sees_a_new_live_request_at_once(self):
        self._online()
        with mock.patch("core.logic.rtc.throttle_decision",
                        return_value={"throttled": False, "reason": ""}):
            s = self.client.post("/api/v1/shop/live/start", {"camera": self.cam.id},
                                 format="json")
            self.assertEqual(s.status_code, 201, s.data)
            p = self._pending()
        self.assertEqual([x["id"] for x in p.data["sessions"]], [s.data["id"]])
        self.assertIn("ice", p.data["sessions"][0])

    def test_expired_request_is_not_offered(self):
        from core.models import ShopLiveSession
        self._online()
        with mock.patch("core.logic.rtc.throttle_decision",
                        return_value={"throttled": False, "reason": ""}):
            sid = self.client.post("/api/v1/shop/live/start", {"camera": self.cam.id},
                                   format="json").data["id"]
        ShopLiveSession.objects.filter(pk=sid).update(
            expires_at=ShopLiveSession.objects.get(pk=sid).created - timedelta(seconds=1))
        self.assertEqual(self._pending().data["sessions"], [])

    def test_bad_token_refused(self):
        r = self.dev().get("/api/v1/shop/live/pending", HTTP_X_SHOP_TOKEN="nope")
        self.assertIn(r.status_code, (401, 403))


class CiTimingTests(SimpleTestCase):
    def test_line_format(self):
        line = ci_timing.timing_line("GET", "/api/v1/circle/chats?x=1", 200, 12.345, 7, now_ms=5)
        self.assertEqual(line, "CITIMING 5 GET /api/v1/circle/chats 200 12.3 7\n")

    def test_middleware_writes_only_api_requests(self):
        with tempfile.TemporaryDirectory() as d:
            log = os.path.join(d, "t.log")
            with override_settings(CI_TIMING_LOG=log):
                mw = ci_timing.CiTimingMiddleware(lambda r: HttpResponse("ok"))
                rf = RequestFactory()
                mw(rf.get("/api/v1/me"))
                mw(rf.get("/static/x.css"))
            rows = open(log).read().splitlines()
        self.assertEqual(len(rows), 1)
        p = rows[0].split()
        self.assertEqual(p[0:3], ["CITIMING", p[1], "GET"])
        self.assertEqual(p[3:5], ["/api/v1/me", "200"])

    def test_off_without_a_log_file(self):
        with override_settings(CI_TIMING_LOG=""):
            mw = ci_timing.CiTimingMiddleware(lambda r: HttpResponse("ok"))
            self.assertEqual(mw(RequestFactory().get("/api/v1/me")).status_code, 200)

    def test_not_in_production_settings(self):
        from django.conf import settings
        self.assertNotIn("core.ci_timing.CiTimingMiddleware", settings.MIDDLEWARE)


def _guard():
    spec = importlib.util.spec_from_file_location("sp_guard", ROOT / "tools/speedproof/guard.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


class SpeedGuardTests(SimpleTestCase):
    BASE = {"slack_pct": 20, "floor_ms": 50,
            "screens": {"home_cold": 1000, "chat_open_warm": 400, "quran_ayah_cold": 600}}

    def test_more_than_20_percent_slower_fails(self):
        g = _guard()
        bad = g.compare(self.BASE, {"home_cold": 1300, "chat_open_warm": 400, "quran_ayah_cold": 600})
        self.assertEqual([b["screen"] for b in bad], ["home_cold"])

    def test_within_20_percent_or_noise_floor_passes(self):
        g = _guard()
        # exactly +20%, +10%, and faster
        ok = g.compare(self.BASE, {"home_cold": 1200, "chat_open_warm": 440, "quran_ayah_cold": 500})
        self.assertEqual(ok, [])

    def test_small_screen_needs_both_percent_and_floor(self):
        g = _guard()
        base = {"slack_pct": 20, "floor_ms": 50, "screens": {"x": 100}}
        self.assertEqual(g.compare(base, {"x": 145}), [])      # +45%, only +45 ms
        self.assertEqual(len(g.compare(base, {"x": 151})), 1)  # +51 ms and +51%

    def test_missing_or_timed_out_screen_fails(self):
        g = _guard()
        bad = g.compare(self.BASE, {"home_cold": 900, "chat_open_warm": None})
        self.assertEqual(sorted(b["screen"] for b in bad), ["chat_open_warm", "quran_ayah_cold"])

    def test_extract_from_perf_json(self):
        g = _guard()
        perf = {"flows": [{"id": "s03_circle", "opens": {
            "circle_list_cold": {"ready_ms": 420, "timed_out": False},
            "circle_list_warm": {"ready_ms": 380, "timed_out": False},
            "chat_open_cold": {"ready_ms": None, "timed_out": True}}}]}
        got = g.measured(perf)
        self.assertEqual(got["circle_list_cold"], 420)
        self.assertIsNone(got["chat_open_cold"])

    def test_committed_baseline_is_valid(self):
        b = json.loads((ROOT / "tools/speedproof/baseline.json").read_text())
        self.assertEqual(b["slack_pct"], 20)
        self.assertTrue(b["screens"])
        self.assertTrue(all(isinstance(v, int) and v > 0 for v in b["screens"].values()))


# ---------------------------------------------------------------- chat seen
from core.tests_c3_msg import _Base as _C3Base  # noqa: E402


class ChatSeenBulkTests(_C3Base):
    def test_opening_a_delivered_chat_is_a_few_queries_not_one_per_message(self):
        from core.models import CircleReceipt
        from core.views_c3_msg import sync_delivered
        ids = [self.send(self.cb, self.ba, "sp%d" % i) for i in range(60)]
        sync_delivered(self.a)       # A's phone got them: delivered, not seen
        self.assertEqual(CircleReceipt.objects.filter(
            user=self.a, message_id__in=ids, seen_at__isnull=True).count(), 60)
        with CaptureQueriesContext(connection) as q:
            r = self.ca.post("/api/v1/circle/%d/seen" % self.ab.id, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["updated"], 60)
        self.assertLess(len(q.captured_queries), 45, len(q.captured_queries))
        self.assertEqual(CircleReceipt.objects.filter(
            user=self.a, message_id__in=ids, seen_at__isnull=True).count(), 0)
        # B (the sender) sees read ticks
        self.assertEqual(self.status_of(self.cb, self.ba, ids[-1]), "read")

    def test_query_count_does_not_grow_with_messages(self):
        from core.views_c3_msg import sync_delivered
        for i in range(10):
            self.send(self.cb, self.ba, "a%d" % i)
        sync_delivered(self.a)
        with CaptureQueriesContext(connection) as q1:
            self.ca.post("/api/v1/circle/%d/seen" % self.ab.id, format="json")
        for i in range(50):
            self.send(self.cb, self.ba, "b%d" % i)
        sync_delivered(self.a)
        with CaptureQueriesContext(connection) as q2:
            self.ca.post("/api/v1/circle/%d/seen" % self.ab.id, format="json")
        self.assertLessEqual(len(q2.captured_queries), len(q1.captured_queries) + 3)


# ---------------------------------------------------------------- payments catalog
class CatalogMemoTests(TestCase):
    def test_products_normalizes_the_config_once(self):
        from core.logic import pricing
        from core.payments import catalog
        c = pricing.normalize({})
        real = pricing.normalize
        with mock.patch.object(pricing, "normalize", side_effect=real) as n:
            out = catalog.products("gateway", "en", cfg=c)
        # was one normalize per helper call per sku (dozens); now the given
        # dict once (+ at most a couple inside pricing helpers)
        self.assertLessEqual(n.call_count, 3, n.call_count)
        self.assertEqual(out, catalog.products("gateway", "en", cfg=pricing.normalize({})))

    def test_a_raw_dict_is_still_normalized(self):
        from core.payments import catalog
        raw = {"plans": {"premium": {"price": "123"}}}
        self.assertEqual(catalog._cfg(raw)["plans"]["premium"]["price"], 123)
        self.assertNotIn("payments", raw)   # never mutated


# ---------------------------------------------------------------- Family night preview
from core.tests_fcbrain import V as _FV, cl as _fcl, Base as _FcBase  # noqa: E402


class NightPreviewCacheTests(_FcBase):
    def test_second_open_reuses_the_preview(self):
        from core import family_brain as FB
        FB.ping(self.kid, {"battery": 60})
        r1 = _fcl(self.mom).get("%s/family/brain/night-news" % _FV)
        self.assertEqual(r1.status_code, 200)
        self.assertEqual(r1.json()["card"]["source"], "preview")
        with CaptureQueriesContext(connection) as q1:
            _fcl(self.mom).get("%s/family/brain/night-news" % _FV)
        from django.core.cache import cache
        cache.clear()
        with CaptureQueriesContext(connection) as q2:
            r3 = _fcl(self.mom).get("%s/family/brain/night-news" % _FV)
        self.assertLess(len(q1.captured_queries), len(q2.captured_queries))
        self.assertEqual(r3.json()["card"], r1.json()["card"])
