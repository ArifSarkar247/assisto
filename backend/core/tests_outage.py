"""Outage matrix (owner order H + I: "graceful behaviour when any outside
service is down"; "failure tests with AI, SMS, push or TURN down").

For each outside service — AI providers (all + each), SMS gateway, FCM
(down + slow), TURN credential API, Meta Graph, maps (Places + OSM) — the
user-facing endpoint must:
  * answer FAST (no worker parked on a dead host: the shared circuit in
    core/ext_breaker.py opens after 5 failures and skips the call),
  * answer HONESTLY (a clear state / error code, never a fake success),
  * never 500,
  * refund credits when an AI call was charged,
  * keep retries bounded (circuit half-opens to ONE probe after cool-down),
  * alert the owner ONCE when a circuit opens (existing push.notify_owner).

Every network seam is mocked: no real outside call ever happens.
Run: manage.py test core.tests_outage --settings=assisto_backend.settings_test
"""
import time
import urllib.error
from datetime import timedelta
from unittest import mock

from django.core.cache import cache
from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient

from core import ai, ext_breaker as XB
from core.models import AIProviderState, User

V = "/api/v1"
FAST_S = 2.0   # a user-facing answer while a service is down


def mk(phone, name="U"):
    return User.objects.create_user(name=name, phone=phone, password="pw12345!",
                                    language="en")


def cl(u=None):
    c = APIClient()
    if u is not None:
        c.force_authenticate(u)
    c.credentials(HTTP_ACCEPT_LANGUAGE="en")
    return c


class _Base(TestCase):
    def setUp(self):
        cache.clear()
        self.notify = mock.patch("core.push.notify_owner",
                                 return_value={}).start()
        self.addCleanup(mock.patch.stopall)

    def timed(self, fn):
        t = time.monotonic()
        r = fn()
        return r, time.monotonic() - t

    def open_state(self, name):
        return AIProviderState.objects.get(slug=XB.slug(name)).state


# --------------------------------------------------------------- breaker
class BreakerCore(_Base):
    def test_opens_after_threshold_skips_then_one_probe_then_closes(self):
        calls = []

        def boom():
            calls.append(1)
            raise OSError("down")
        for _ in range(5):
            with self.assertRaises(OSError):
                XB.call("maps", boom)
        self.assertEqual(self.open_state("maps"), "open")
        self.notify.assert_called_once()                 # owner alerted once
        for _ in range(10):
            with self.assertRaises(XB.Unavailable):
                XB.call("maps", boom)
        self.assertEqual(len(calls), 5)                  # bounded: no more hits
        self.notify.assert_called_once()
        # cool-down over -> exactly one probe; success closes it
        AIProviderState.objects.filter(slug=XB.slug("maps")).update(
            opened_at=timezone.now() - timedelta(seconds=60))
        self.assertEqual(XB.call("maps", lambda: "ok"), "ok")
        self.assertEqual(self.open_state("maps"), "closed")
        self.assertEqual(XB.call("maps", lambda: "ok2"), "ok2")

    def test_healthy_success_costs_no_write(self):
        XB.call("osm", lambda: 1)
        from django.db import connection
        from django.test.utils import CaptureQueriesContext
        with CaptureQueriesContext(connection) as q:
            XB.call("osm", lambda: 1)
        self.assertEqual(len(q), 1, [x["sql"] for x in q])   # one SELECT

    def test_ai_dashboard_never_lists_these_rows(self):
        from core import ai_router as R
        XB.fail("sms", "x")
        self.assertFalse(any(s.startswith("x:") for s in R.states()))


# --------------------------------------------------------------- maps
class MapsDown(_Base):
    def setUp(self):
        super().setUp()
        import core.nearby as NB
        NB._CACHE.clear()
        self.get = mock.patch("core.nearby._get", side_effect=urllib.error.URLError(
            "maps down")).start()
        mock.patch("core.nearby.time.sleep").start()
        self.u = mk("01712000001")

    def test_nearby_is_honest_never_500_and_bounded(self):
        c = cl(self.u)
        for i in range(8):
            r, dt = self.timed(lambda: c.get(
                V + "/nearby", {"lat": 23.7 + i * 0.01, "lon": 90.4,
                                "type": "hospital"}))
            self.assertEqual(r.status_code, 200)
            self.assertEqual(r.json()["source"], "unavailable")
            self.assertEqual(r.json()["state"], "unavailable")
            self.assertEqual(r.json()["places"], [])
            self.assertLess(dt, FAST_S)
        self.assertEqual(self.open_state("osm"), "open")
        self.assertLessEqual(self.get.call_count, 5)     # then skipped

    def test_safe_journey_nearest_help_says_failed_with_helplines(self):
        r = cl(self.u).get(V + "/journey/nearest-help",
                           {"lat": 23.7, "lon": 90.4})
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["state"], "failed")
        self.assertTrue(r.json()["helplines"])           # 999 always there

    def test_places_down_falls_back_to_osm(self):
        self.get.side_effect = None
        self.get.return_value = '{"elements": [{"lat": 23.71, "lon": 90.41, "tags": {"name": "Thana"}}]}'
        with mock.patch("core.nearby._places", side_effect=OSError("places")), \
                mock.patch("core.integrations.get", return_value={"api_key": "k"}), \
                mock.patch("core.integrations.is_enabled", return_value=True):
            r = cl(self.u).get(V + "/nearby", {"lat": 23.7, "lon": 90.4,
                                               "type": "police"})
        self.assertEqual(r.json()["source"], "osm")
        self.assertEqual(r.json()["places"][0]["name"], "Thana")


# --------------------------------------------------------------- SMS
class SmsDown(_Base):
    def setUp(self):
        super().setUp()
        from core import sms_gateway as G
        mock.patch("core.otp.sms_available", return_value=True).start()
        mock.patch("core.sms_gateway.adapter", return_value=G.HttpSmsAdapter(
            {"api_url": "https://sms.example.invalid/send",
             "api_key": "k"})).start()
        self.http = mock.patch("core.sms_gateway._http",
                               side_effect=urllib.error.URLError("down")).start()

    def test_otp_send_is_honest_502_then_fast(self):
        for i in range(8):
            r, dt = self.timed(lambda: cl().post(V + "/auth/otp/resend", {
                "purpose": "signup", "phone": "0171300%04d" % i},
                format="json"))
            self.assertEqual(r.status_code, 502, r.content)
            self.assertIn("send_failed", r.content.decode())
            self.assertLess(dt, FAST_S)
        self.assertEqual(self.open_state("sms"), "open")
        self.assertEqual(self.http.call_count, 5)
        self.notify.assert_called_once()

    def test_gateway_4xx_is_our_request_and_never_trips(self):
        self.http.side_effect = None
        self.http.return_value = (400, "bad number")
        from core import sms_gateway as G
        ad = G.HttpSmsAdapter({"api_url": "https://x.invalid/s", "api_key": "k"})
        for _ in range(8):
            ok, _ = ad.send("+8801711111111", "hi")
            self.assertFalse(ok)
        self.assertEqual(self.http.call_count, 8)
        self.assertEqual(self.open_state("sms"), "closed")


# --------------------------------------------------------------- FCM
SA = {"client_email": "x@y", "private_key": "k", "project_id": "p"}


class FcmDown(_Base):
    def setUp(self):
        super().setUp()
        from core import push
        push.reset_cache()
        mock.patch("core.push.load_service_account", return_value=SA).start()
        mock.patch("core.push.build_jwt", return_value="jwt").start()
        self.post = mock.patch(
            "core.push._http_post",
            side_effect=OSError("fcm unreachable")).start()
        from core.models import Device
        self.u = mk("01714000001")
        Device.objects.create(user=self.u, push_token="tok-a")

    def test_push_down_bounded_calls_and_owner_alert(self):
        from core import push
        for _ in range(20):
            self.assertEqual(push.push_to_user(
                self.u, "message", "t", "t", data={"chat_id": 1}), 0)
        self.assertLessEqual(self.post.call_count, 5)
        self.assertEqual(self.open_state("fcm"), "open")
        self.notify.assert_called_once()

    def test_slow_fcm_never_blocks_the_request(self):
        """A slow Google (8 s timeouts) runs on the push thread pool, never
        in the request: placing a call returns at once."""
        from core import push
        submitted = []

        class _Ex:
            def submit(self, fn, *a):
                submitted.append(a)
        self.post.side_effect = lambda *a, **k: time.sleep(5)
        with override_settings(PUSH_SYNC=False), \
                mock.patch("core.push._get_executor", return_value=_Ex()):
            t = time.monotonic()
            ok = push.push_to_user_async(self.u, "message", "t", "t")
            self.assertLess(time.monotonic() - t, 0.5)
        self.assertTrue(ok)
        self.assertEqual(len(submitted), 1)
        self.assertEqual(self.post.call_count, 0)        # nothing inline

    def test_queue_is_bounded_but_rings_and_sos_always_queue(self):
        from core import push

        class _Ex:
            def submit(self, fn, *a):
                pass
        with override_settings(PUSH_SYNC=False), \
                mock.patch("core.push._get_executor", return_value=_Ex()), \
                mock.patch.object(push, "_pending", [push.PUSH_QUEUE_CAP]):
            self.assertFalse(push.push_to_user_async(self.u, "message", "t", "t"))
            self.assertTrue(push.push_to_user_async(self.u, "call", "t", "t"))
            self.assertTrue(push.push_to_user_async(self.u, "sos", "t", "t"))

    def test_send_message_still_201_when_fcm_down(self):
        from core.models import CircleMember
        b = mk("01714000002")
        ab = CircleMember.objects.create(user=self.u, peer_user=b,
                                         state="accepted", phone=b.phone)
        CircleMember.objects.create(user=b, peer_user=self.u, state="accepted",
                                    phone=self.u.phone, direction="incoming")
        from core.models import Device, UserPublicKey
        Device.objects.create(user=b, push_token="tok-b")
        UserPublicKey.objects.create(user=b, public_key="pkB", key_id="kB")
        UserPublicKey.objects.create(user=self.u, public_key="pkA")
        for i in range(7):
            r, dt = self.timed(lambda: cl(self.u).post(
                "%s/circle/%d/messages" % (V, ab.id),
                {"ciphertext": "Q1Q=", "nonce": "Tg==",
                 "client_msg_id": "o%d" % i}, format="json"))
            self.assertEqual(r.status_code, 201, r.content)
            self.assertLess(dt, FAST_S)
        self.assertLessEqual(self.post.call_count, 5)


# --------------------------------------------------------------- TURN
class TurnApiDown(_Base):
    def setUp(self):
        super().setUp()
        mock.patch("core.turn_pool.overflow_settings", return_value={
            "active": True, "mode": "always", "threshold_pct": 0,
            "key_id": "k", "api_token": "t"}).start()
        self.cf = mock.patch("core.turn_pool.cf_generate",
                             side_effect=urllib.error.URLError("cf down")).start()

    def test_overflow_failing_gives_own_servers_only_and_bounded(self):
        from core import turn_pool as T
        for uid in range(1, 10):
            self.assertEqual(T.overflow_ice(uid, 3600), [])
        self.assertEqual(self.cf.call_count, 5)
        self.assertEqual(self.open_state("turn"), "open")

    @override_settings(TURN_STATIC_SECRET="s", TURN_HOST="turn.example.invalid")
    def test_call_ice_still_served_from_own_turn(self):
        u = mk("01715000001")
        from core.views_c2_calls import ice_for
        ice = ice_for(u)
        self.assertTrue(ice["turn"])
        self.assertTrue(ice["iceServers"])


# --------------------------------------------------------------- Meta Graph
class GraphDown(_Base):
    def test_send_is_honest_and_bounded(self):
        from core import bizagent_graph as G
        hits = []

        def dead(method, url, headers, body):
            hits.append(1)
            return 0, {"error": {"message": "URLError"}}
        prev = G.set_transport(dead)
        self.addCleanup(G.set_transport, prev)
        for _ in range(9):
            t = time.monotonic()
            r = G.send_messenger("tok", "psid", "hello")
            self.assertLess(time.monotonic() - t, FAST_S)
            self.assertFalse(r["ok"])
            self.assertTrue(r["error"])
        self.assertEqual(len(hits), 5)
        self.assertEqual(self.open_state("graph"), "open")
        self.assertIn("graph_unavailable", G.send_messenger("t", "p", "x")["error"])

    def test_graph_4xx_never_trips(self):
        from core import bizagent_graph as G
        prev = G.set_transport(lambda *a: (400, {"error": {"message": "bad"}}))
        self.addCleanup(G.set_transport, prev)
        for _ in range(8):
            self.assertFalse(G.send_messenger("tok", "psid", "x")["ok"])
        self.assertEqual(self.open_state("graph"), "closed")


# --------------------------------------------------------------- AI
ALL = [("anthropic", "ka"), ("gemini", "kg"), ("openai", "ko")]


class AiDown(_Base):
    def setUp(self):
        super().setUp()
        mock.patch("core.ai._providers", return_value=list(ALL)).start()
        self.u = mk("01716000001")
        from core import billing
        billing.credit(self.u, "topup", 50, note="test")
        self.u.refresh_from_db()
        self.c = cl(self.u)
        r = self.c.post(V + "/chat/sessions", {}, format="json")
        self.sid = r.json()["id"]

    def fakes(self, down):
        calls = []
        for name in ("anthropic", "gemini", "openai"):
            def call(key, model, system, prompt, mx, history=None, _n=name):
                calls.append(_n)
                if _n in down:
                    raise ai.ProviderError("server")
                return "উত্তর", 10, 10
            mock.patch("core.ai._call_" + name, side_effect=call).start()
        return calls

    def send(self):
        return self.timed(lambda: self.c.post(
            "%s/chat/sessions/%d/send" % (V, self.sid), {"text": "আজ কী আছে?"},
            format="json"))

    def balance(self):
        self.u.refresh_from_db()
        return self.u.ai_credits

    def test_all_providers_down_honest_brain_answer_and_refund(self):
        before = self.balance()
        calls = self.fakes({"anthropic", "gemini", "openai"})
        r, dt = self.send()
        self.assertEqual(r.status_code, 200, r.content)
        self.assertFalse(r.json()["ai_used"])
        self.assertTrue(r.json()["message"]["text"].strip())
        self.assertLess(dt, FAST_S)
        self.assertEqual(self.balance(), before)          # refunded in full
        self.assertTrue(calls)

    def test_each_single_provider_down_still_answers(self):
        for down in ("anthropic", "gemini", "openai"):
            mock.patch.stopall()
            self.notify = mock.patch("core.push.notify_owner",
                                     return_value={}).start()
            mock.patch("core.ai._providers", return_value=list(ALL)).start()
            AIProviderState.objects.all().delete()
            calls = self.fakes({down})
            r, dt = self.send()
            self.assertEqual(r.status_code, 200, (down, r.content))
            self.assertTrue(r.json()["ai_used"], down)
            self.assertLess(dt, FAST_S)
            self.assertNotIn("anthropic", r.content.decode().lower())
            self.assertTrue(calls)
