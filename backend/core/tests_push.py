"""Tests for core/push.py (FCM HTTP v1, key-gated) + views_push + hooks.

The HTTP layer (`push._http_post`) is always mocked — no network. A throwaway
RSA key is generated per test run; no real credentials are ever used.
"""
import base64
import json
import os
import tempfile
import time
from datetime import timedelta
from io import StringIO
from unittest import mock

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from django.core.management import call_command
from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient

from core import push
from core.models import (User, Device, CircleMember, CircleMessage, CallRecord,
                         Reminder)

_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
_PEM = _KEY.private_bytes(serialization.Encoding.PEM,
                          serialization.PrivateFormat.PKCS8,
                          serialization.NoEncryption()).decode()
SA = {"type": "service_account", "project_id": "assisto-test",
      "private_key_id": "kid1", "private_key": _PEM,
      "client_email": "push@assisto-test.iam.gserviceaccount.com",
      "token_uri": "https://oauth2.googleapis.com/token"}


def _b64d(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


class FakeFCM:
    """Records calls; answers token exchange + send per configurable codes."""

    def __init__(self, send_code=200, send_body=None):
        self.calls = []
        self.send_code = send_code
        self.send_body = send_body or {"name": "projects/x/messages/1"}

    def __call__(self, url, body, headers):
        self.calls.append((url, body, headers))
        if url == push.TOKEN_URI:
            return 200, {"access_token": "at-%d" % len(self.calls),
                         "expires_in": 3600}
        return self.send_code, self.send_body

    @property
    def token_calls(self):
        return [c for c in self.calls if c[0] == push.TOKEN_URI]

    @property
    def send_calls(self):
        return [c for c in self.calls if c[0] != push.TOKEN_URI]

    def sent_payloads(self):
        return [json.loads(c[1].decode()) for c in self.send_calls]


class _PushBase(TestCase):
    def setUp(self):
        push.reset_cache()
        self.tmp = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump(SA, self.tmp)
        self.tmp.close()
        self.fake = FakeFCM()
        p1 = override_settings(FCM_SERVICE_ACCOUNT_FILE=self.tmp.name,
                               PUSH_SYNC=True)
        p1.enable()
        self.addCleanup(p1.disable)
        p2 = mock.patch.object(push, "_http_post", self.fake)
        p2.start()
        self.addCleanup(p2.stop)
        self.addCleanup(os.unlink, self.tmp.name)
        self.addCleanup(push.reset_cache)

    def mkuser(self, phone, name="", lang="bn", **kw):
        return User.objects.create_user(name=name, phone=phone, password="pw12345!",
                                        language=lang, **kw)


# ---------------------------------------------------------------- unavailable
@override_settings(FCM_SERVICE_ACCOUNT_FILE="", PUSH_SYNC=True)
class UnavailableTests(TestCase):
    def setUp(self):
        push.reset_cache()

    def test_noop_without_credentials(self):
        u = User.objects.create_user(name="A", phone="01700000001", password="x")
        Device.objects.create(user=u, push_token="tok-a")
        with mock.patch.object(push, "_http_post") as http:
            self.assertFalse(push.is_available())
            self.assertFalse(push.send_to_token("tok-a", {"a": 1}))
            self.assertEqual(push.push_to_user(u, "message", "t", "t"), 0)
            self.assertFalse(push.push_to_user_async(u, "message", "t", "t"))
            self.assertIsNone(push.get_access_token())
            out = push.notify_owner("s", "b")
            http.assert_not_called()
        self.assertFalse(out["push_available"])
        self.assertFalse(out["email"])
        self.assertTrue(Device.objects.filter(push_token="tok-a").exists())

    def test_integrations_store_fallback(self):
        with mock.patch("core.integrations.get",
                        return_value={"service_account_json": json.dumps(SA)}):
            self.assertTrue(push.is_available())
        with mock.patch("core.integrations.get",
                        return_value={"service_account_json": "not json"}):
            self.assertFalse(push.is_available())
        with mock.patch("core.integrations.get", side_effect=RuntimeError):
            self.assertFalse(push.is_available())


# ---------------------------------------------------------------- oauth2
class TokenTests(_PushBase):
    def test_jwt_is_valid_rs256(self):
        jwt = push.build_jwt(SA, now=1000)
        h, c, s = jwt.split(".")
        header, claims = json.loads(_b64d(h)), json.loads(_b64d(c))
        self.assertEqual(header["alg"], "RS256")
        self.assertEqual(claims["iss"], SA["client_email"])
        self.assertEqual(claims["scope"], push.SCOPE)
        self.assertEqual(claims["aud"], push.TOKEN_URI)
        self.assertEqual(claims["exp"] - claims["iat"], 3600)
        _KEY.public_key().verify(_b64d(s), (h + "." + c).encode(),
                                 padding.PKCS1v15(), hashes.SHA256())

    def test_exchange_and_cache(self):
        t1 = push.get_access_token()
        t2 = push.get_access_token()
        self.assertEqual(t1, t2)
        self.assertEqual(len(self.fake.token_calls), 1)
        body = self.fake.token_calls[0][1].decode()
        self.assertIn("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer",
                      body)
        self.assertIn("assertion=", body)

    def test_refresh_near_expiry(self):
        push.get_access_token()
        push._token_cache["expires_at"] = time.time() + 60   # < 5 min left
        push.get_access_token()
        self.assertEqual(len(self.fake.token_calls), 2)

    def test_exchange_failure_returns_none(self):
        with mock.patch.object(push, "_http_post", return_value=(400, {})):
            self.assertIsNone(push.get_access_token())
        with mock.patch.object(push, "_http_post", side_effect=OSError):
            self.assertIsNone(push.get_access_token())


# ---------------------------------------------------------------- send
class SendTests(_PushBase):
    def test_send_success_and_payload_shape(self):
        ok = push.send_to_token("tok-1", {"n": 5, "b": True, "x": None,
                                          "from": "drop", "google.x": "drop"},
                                {"title": "T", "body": "B"}, priority="high",
                                ttl_s=30, collapse_key="c1",
                                android_channel="calls")
        self.assertTrue(ok)
        url, body, headers = self.fake.send_calls[0]
        self.assertEqual(
            url, "https://fcm.googleapis.com/v1/projects/assisto-test/messages:send")
        self.assertTrue(headers["Authorization"].startswith("Bearer at-"))
        msg = json.loads(body.decode())["message"]
        self.assertEqual(msg["token"], "tok-1")
        self.assertEqual(msg["data"], {"n": "5", "b": "true", "x": ""})
        self.assertEqual(msg["android"]["priority"], "HIGH")
        self.assertEqual(msg["android"]["ttl"], "30s")
        self.assertEqual(msg["android"]["collapse_key"], "c1")
        self.assertEqual(msg["android"]["notification"]["channel_id"], "calls")
        self.assertEqual(msg["notification"], {"title": "T", "body": "B"})

    def test_unregistered_deletes_device(self):
        u = self.mkuser("01700000002")
        Device.objects.create(user=u, push_token="dead")
        self.fake.send_code = 404
        self.fake.send_body = {"error": {"code": 404, "status": "NOT_FOUND",
                               "details": [{"errorCode": "UNREGISTERED"}]}}
        self.assertFalse(push.send_to_token("dead", {"a": "1"}))
        self.assertFalse(Device.objects.filter(push_token="dead").exists())

    def test_invalid_token_400_deletes_but_other_400_keeps(self):
        u = self.mkuser("01700000003")
        Device.objects.create(user=u, push_token="bad")
        Device.objects.create(user=u, push_token="good")
        self.fake.send_code = 400
        self.fake.send_body = {"error": {"code": 400, "status": "INVALID_ARGUMENT",
                               "message": "Invalid payload field"}}
        self.assertFalse(push.send_to_token("good", {"a": "1"}))
        self.assertTrue(Device.objects.filter(push_token="good").exists())
        self.fake.send_body = {"error": {"code": 400, "status": "INVALID_ARGUMENT",
                               "message": "The registration token is not a valid "
                                          "FCM registration token"}}
        self.assertFalse(push.send_to_token("bad", {"a": "1"}))
        self.assertFalse(Device.objects.filter(push_token="bad").exists())

    def test_401_refreshes_token_once(self):
        codes = iter([401, 200])

        def http(url, body, headers):
            if url == push.TOKEN_URI:
                return 200, {"access_token": "x", "expires_in": 3600}
            return next(codes), {}
        with mock.patch.object(push, "_http_post", side_effect=http):
            self.assertTrue(push.send_to_token("t", {"a": "1"}))

    def test_network_error_never_raises(self):
        with mock.patch.object(push, "_http_post", side_effect=OSError("down")):
            self.assertFalse(push.send_to_token("t", {"a": "1"}))


# ---------------------------------------------------------------- push_to_user
class PushToUserTests(_PushBase):
    def test_language_and_all_devices(self):
        u = self.mkuser("01700000004", lang="en")
        Device.objects.create(user=u, push_token="d1")
        Device.objects.create(user=u, push_token="d2")
        n = push.push_to_user(u, "reminder", "বাংলা", "English", "খ", "b",
                              data={"reminder_id": 7})
        self.assertEqual(n, 2)
        msgs = [p["message"] for p in self.fake.sent_payloads()]
        self.assertEqual({m["token"] for m in msgs}, {"d1", "d2"})
        self.assertEqual(msgs[0]["notification"]["title"], "English")
        self.assertEqual(msgs[0]["data"]["kind"], "reminder")
        self.assertEqual(msgs[0]["data"]["reminder_id"], "7")
        self.assertEqual(msgs[0]["data"]["lang"], "en")

    def test_bn_default(self):
        u = self.mkuser("01700000005", lang="other")
        Device.objects.create(user=u, push_token="d1")
        push.push_to_user(u, "reminder", "বাংলা", "English")
        self.assertEqual(self.fake.sent_payloads()[0]["message"]["data"]["title"],
                         "বাংলা")

    def test_call_and_sos_are_data_only_high_short_ttl(self):
        u = self.mkuser("01700000006")
        Device.objects.create(user=u, push_token="d1")
        for kind, ttl in (("call", "30s"), ("call_cancel", "60s"),
                          ("sos", "600s")):
            self.fake.calls.clear()
            push.push_to_user(u, kind, "t", "t", "b", "b", data={"call_id": 1})
            m = self.fake.sent_payloads()[0]["message"]
            self.assertNotIn("notification", m)
            self.assertEqual(m["android"]["priority"], "HIGH")
            self.assertEqual(m["android"]["ttl"], ttl)
            self.assertEqual(m["data"]["kind"], kind)

    def test_unknown_kind_and_no_devices(self):
        u = self.mkuser("01700000007")
        self.assertEqual(push.push_to_user(u, "message", "t", "t"), 0)
        Device.objects.create(user=u, push_token="d1")
        self.assertEqual(push.push_to_user(u, "bogus", "t", "t"), 0)
        self.assertEqual(self.fake.send_calls, [])

    def test_async_uses_executor_when_not_sync(self):
        u = self.mkuser("01700000008")
        ex = mock.Mock()
        with mock.patch.object(push, "_get_executor", return_value=ex):
            self.assertTrue(push.push_to_user_async(u, "message", "t", "t",
                                                    sync=False))
        ex.submit.assert_called_once()

    @override_settings(EMAIL_BACKEND="django.core.mail.backends.smtp.EmailBackend")
    def test_notify_owner_push_and_email(self):
        boss = User.objects.create_superuser(name="Boss", phone="01700000009",
                                             email="boss@example.com",
                                             password="pw")
        Device.objects.create(user=boss, push_token="bossdev")
        with mock.patch("django.core.mail.send_mail") as sm, \
                mock.patch.dict(os.environ, {"OWNER_ALERT_EMAIL": "ops@example.com"}):
            out = push.notify_owner("Disk", "Disk 90%")
        self.assertTrue(out["push_available"])
        self.assertEqual(out["push_sent"], 1)
        self.assertTrue(out["email"])
        self.assertEqual(out["email_recipients"], 2)
        self.assertEqual(sorted(sm.call_args[0][3]),
                         ["boss@example.com", "ops@example.com"])
        m = self.fake.sent_payloads()[0]["message"]
        self.assertEqual(m["data"]["kind"], "owner_alert")

    def test_notify_owner_console_backend_no_email(self):
        out = push.notify_owner("s", "b")      # test runner uses locmem
        self.assertFalse(out["email"])


# ---------------------------------------------------------------- endpoints
class EndpointTests(_PushBase):
    def setUp(self):
        super().setUp()
        self.u = self.mkuser("01711111111", name="U")
        self.c = APIClient()
        self.c.force_authenticate(self.u)

    def test_register_upsert_and_status(self):
        r = self.c.post("/api/v1/devices/register",
                        {"push_token": "tokA", "platform": "android",
                         "app_version": "1.0.145"}, format="json")
        self.assertEqual(r.status_code, 201)
        self.assertNotIn("tokA", json.dumps(r.json()))
        r = self.c.post("/api/v1/devices/register",
                        {"push_token": "tokA", "app_version": "1.0.146"},
                        format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(Device.objects.filter(user=self.u).count(), 1)
        self.assertEqual(Device.objects.get(user=self.u).app_version, "1.0.146")
        self.assertEqual(self.c.get("/api/v1/push/status").json(),
                         {"available": True})

    def test_register_requires_token(self):
        r = self.c.post("/api/v1/devices/register", {}, format="json",
                        HTTP_ACCEPT_LANGUAGE="en")
        self.assertEqual(r.status_code, 400)
        self.assertIn("push token", r.json()["detail"])

    def test_reassign_token_from_other_user(self):
        other = self.mkuser("01722222222")
        Device.objects.create(user=other, push_token="shared")
        r = self.c.post("/api/v1/devices/register", {"push_token": "shared"},
                        format="json")
        self.assertTrue(r.json()["reassigned"])
        self.assertEqual(list(Device.objects.filter(push_token="shared")
                              .values_list("user_id", flat=True)), [self.u.id])

    def test_cap_ten_drops_oldest(self):
        for i in range(12):
            self.c.post("/api/v1/devices/register", {"push_token": "t%d" % i},
                        format="json")
        toks = set(Device.objects.filter(user=self.u)
                   .values_list("push_token", flat=True))
        self.assertEqual(len(toks), 10)
        self.assertNotIn("t0", toks)
        self.assertNotIn("t1", toks)
        self.assertIn("t11", toks)

    def test_unregister(self):
        Device.objects.create(user=self.u, push_token="x")
        other = self.mkuser("01733333333")
        Device.objects.create(user=other, push_token="y")
        r = self.c.post("/api/v1/devices/unregister", {"push_token": "x"},
                        format="json")
        self.assertEqual(r.json()["removed"], 1)
        # cannot remove someone else's token
        r = self.c.post("/api/v1/devices/unregister", {"push_token": "y"},
                        format="json")
        self.assertEqual(r.json()["removed"], 0)
        self.assertTrue(Device.objects.filter(push_token="y").exists())

    def test_auth_required(self):
        r = APIClient().get("/api/v1/push/status")
        self.assertIn(r.status_code, (401, 403))

    @override_settings(FCM_SERVICE_ACCOUNT_FILE="")
    def test_status_unavailable(self):
        self.assertEqual(self.c.get("/api/v1/push/status").json(),
                         {"available": False})


# ---------------------------------------------------------------- hooks
class HookTests(_PushBase):
    def setUp(self):
        super().setUp()
        self.a = self.mkuser("01740000001", name="Amina", lang="en")
        self.b = self.mkuser("01740000002", name="Babu", lang="en")
        self.ab = CircleMember.objects.create(
            user=self.a, peer_user=self.b, name="Babu", state="accepted",
            phone="01740000002")
        self.ba = CircleMember.objects.create(
            user=self.b, peer_user=self.a, name="Amina", state="accepted",
            direction="incoming", phone="01740000001")
        Device.objects.create(user=self.b, push_token="bdev")
        Device.objects.create(user=self.a, push_token="adev")
        self.c = APIClient()
        self.c.force_authenticate(self.a)

    def _send_msg(self):
        return self.c.post("/api/v1/circle/%d/messages" % self.ab.id,
                           {"ciphertext": "U0VDUkVUIFBMQUlOVEVYVA==",
                            "nonce": "bm9uY2U=", "scheme": "x25519-xsalsa20",
                            "client_msg_id": "m1"}, format="json")

    def test_message_push_has_no_plaintext(self):
        r = self._send_msg()
        self.assertEqual(r.status_code, 201, r.content)
        msgs = [p["message"] for p in self.fake.sent_payloads()]
        self.assertEqual(len(msgs), 1)
        m = msgs[0]
        self.assertEqual(m["token"], "bdev")         # recipient only
        self.assertEqual(m["data"]["kind"], "message")
        # c3-msg: data-only (the device draws MessagingStyle); the fallback
        # title still names the sender, never the text.
        self.assertNotIn("notification", m)
        self.assertEqual(m["data"]["title"], "New message from Amina")
        self.assertEqual(m["data"]["preview"], "1")
        self.assertEqual(m["data"]["chat_id"], str(self.ba.id))
        blob = json.dumps(m)
        self.assertNotIn("U0VDUkVUIFBMQUlOVEVYVA", blob)
        self.assertNotIn("bm9uY2U", blob)
        self.assertNotIn("ciphertext", blob)

    def test_muted_recipient_gets_no_push(self):
        self.ba.muted_until = timezone.now() + timedelta(hours=1)
        self.ba.save()
        self._send_msg()
        self.assertEqual(self.fake.send_calls, [])

    def test_hook_failure_never_breaks_request(self):
        with mock.patch.object(push, "push_to_user", side_effect=RuntimeError):
            r = self._send_msg()
        self.assertEqual(r.status_code, 201)
        with mock.patch.object(push, "is_available", side_effect=RuntimeError):
            r = self.c.post("/api/v1/circle/%d/messages" % self.ab.id,
                            {"ciphertext": "QQ==", "nonce": "Tg==",
                             "client_msg_id": "m2"}, format="json")
        self.assertEqual(r.status_code, 201)
        self.assertEqual(CircleMessage.objects.count(), 2)

    def test_call_push_then_cancel(self):
        r = self.c.post("/api/v1/circle/%d/call" % self.ab.id,
                        {"kind": "voice"}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertTrue(r.json()["transport"]["app_closed_ring"])
        call_id = r.json()["call_id"]
        m = self.fake.sent_payloads()[0]["message"]
        self.assertEqual(m["token"], "bdev")
        self.assertNotIn("notification", m)
        self.assertEqual(m["data"]["kind"], "call")
        self.assertEqual(m["data"]["call_id"], str(call_id))
        self.assertEqual(m["data"]["caller_name"], "Amina")
        self.assertEqual(m["data"]["video"], "false")
        self.fake.calls.clear()
        r = self.c.post("/api/v1/circle/calls/%d/event" % call_id,
                        {"event": "cancel"}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        m = self.fake.sent_payloads()[0]["message"]
        self.assertEqual(m["data"]["kind"], "call_cancel")
        self.assertEqual(m["data"]["call_id"], str(call_id))
        self.assertEqual(m["data"]["reason"], "canceled")
        self.assertEqual(m["android"]["ttl"], "60s")

    def test_call_hook_failure_safe(self):
        with mock.patch.object(push, "member_peer_user", side_effect=RuntimeError):
            r = self.c.post("/api/v1/circle/%d/call" % self.ab.id,
                            {"kind": "voice"}, format="json")
        self.assertEqual(r.status_code, 201)
        self.assertTrue(CallRecord.objects.exists())

    def test_sos_reaches_family(self):
        r = self.c.post("/api/v1/journey/sos", {"lat": 23.7, "lng": 90.4},
                        format="json")
        self.assertEqual(r.status_code, 200, r.content)
        msgs = [p["message"] for p in self.fake.sent_payloads()]
        self.assertEqual([m["token"] for m in msgs], ["bdev"])
        self.assertEqual(msgs[0]["data"]["kind"], "sos")
        self.assertEqual(msgs[0]["data"]["lat"], "23.7")
        self.assertNotIn("notification", msgs[0])

    def test_scam_report_family_alert(self):
        r = self.c.post("/api/v1/scam/report",
                        {"message": "Your bKash account is blocked, send OTP"},
                        format="json")
        self.assertEqual(r.status_code, 200, r.content)
        msgs = [p["message"] for p in self.fake.sent_payloads()]
        self.assertEqual([m["token"] for m in msgs], ["bdev"])
        self.assertEqual(msgs[0]["data"]["kind"], "family_alert")

    def test_security_alert_owner_and_circle(self):
        from core.views_security import _notify_owner_and_circle
        _notify_owner_and_circle(self.a, "Phone locked", "5 wrong PINs")
        toks = sorted(p["message"]["token"] for p in self.fake.sent_payloads())
        self.assertEqual(toks, ["adev", "bdev"])

    def test_shop_alert_wording(self):
        from core.models import ShopSite, ShopCamera, ShopEvent
        from core.shop_views import ShopIngestView
        site = ShopSite.objects.create(owner=self.a, name="Shop")
        cam = ShopCamera.objects.create(site=site, name="Cash counter")
        ev = ShopEvent.objects.create(site=site, camera=cam, type="drawer_open",
                                      signals={"reason": ["no_pos"]},
                                      confidence=0.8)
        ShopIngestView._notify_owner(site, cam, ev)
        m = self.fake.sent_payloads()[0]["message"]
        self.assertEqual(m["token"], "adev")
        self.assertEqual(m["data"]["kind"], "shop_alert")
        self.assertIn("Please check", m["notification"]["title"])
        self.assertIn("Cash counter", m["notification"]["title"])
        self.assertNotIn("theft", json.dumps(m).lower())


# ---------------------------------------------------------------- reminders
class ReminderCommandTests(_PushBase):
    def setUp(self):
        super().setUp()
        st = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        st.close()
        self.state = st.name
        self.addCleanup(os.unlink, self.state)
        self.u = self.mkuser("01750000001", lang="en")
        Device.objects.create(user=self.u, push_token="rdev")

    def run_cmd(self):
        out = StringIO()
        call_command("push_due_reminders", "--state-file", self.state, stdout=out)
        return out.getvalue()

    def test_due_pushed_once(self):
        now = timezone.now()
        r = Reminder.objects.create(user=self.u, title="Pay rent",
                                    due_at=now - timedelta(minutes=2))
        Reminder.objects.create(user=self.u, title="old",
                                due_at=now - timedelta(minutes=30))
        Reminder.objects.create(user=self.u, title="future",
                                due_at=now + timedelta(minutes=30))
        Reminder.objects.create(user=self.u, title="done", done=True,
                                due_at=now - timedelta(minutes=1))
        Reminder.objects.create(user=self.u, title="lead", remind_before_min=10,
                                due_at=now + timedelta(minutes=8))
        self.assertIn("pushed=2", self.run_cmd())
        bodies = sorted(p["message"]["data"]["body"]
                        for p in self.fake.sent_payloads())
        self.assertEqual(bodies, ["Pay rent", "lead"])
        data = [p["message"]["data"] for p in self.fake.sent_payloads()
                if p["message"]["data"]["body"] == "Pay rent"][0]
        self.assertEqual(data["kind"], "reminder")
        self.assertEqual(data["reminder_id"], str(r.id))
        self.fake.calls.clear()
        self.assertIn("pushed=0 already_sent=2", self.run_cmd())
        self.assertEqual(self.fake.send_calls, [])

    @override_settings(FCM_SERVICE_ACCOUNT_FILE="")
    def test_noop_without_key(self):
        Reminder.objects.create(user=self.u, title="x",
                                due_at=timezone.now() - timedelta(minutes=1))
        self.assertIn("unavailable", self.run_cmd())
        self.assertEqual(self.fake.calls, [])
