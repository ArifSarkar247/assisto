"""circle-extras (row 50) — link a second phone by QR / code, key-ring handover
relay, unlink signs that phone out. Made-up sample accounts only."""
import base64
from unittest import mock

from django.core.cache import cache
from django.test import SimpleTestCase
from rest_framework.test import APIClient, APITestCase

from core import device_link as DL
from core.models import DeviceSession, LinkedDevice, PaCollectionItem, User

PW = "Sample#Pass2026"
PUB = base64.b64encode(bytes(range(32))).decode()
PUB2 = base64.b64encode(bytes(range(1, 33))).decode()
SEALED = {"epk": PUB2, "nonce": base64.b64encode(b"\x01" * 12).decode(),
          "ct": base64.b64encode(b"sealed-ring-bytes" * 4).decode()}


class PureTests(SimpleTestCase):
    def test_code_normalising(self):
        self.assertEqual(DL.norm_code("abcd-efgh"), "ABCDEFGH")
        self.assertEqual(DL.norm_code(" ABCD EFGH "), "ABCDEFGH")
        self.assertEqual(DL.norm_code(DL.QR_PREFIX + "tok_123"), "tok_123")
        self.assertEqual(DL.pretty_code("ABCDEFGH"), "ABCD-EFGH")

    def test_verify_digits_stable_and_key_bound(self):
        a = DL.verify_digits(PUB)
        self.assertEqual(len(a), 6)
        self.assertTrue(a.isdigit())
        self.assertEqual(a, DL.verify_digits(PUB))
        self.assertNotEqual(a, DL.verify_digits(PUB2))
        # pinned vector, mirrored in app/test/device_link_test.dart
        self.assertEqual(a, "361262")


class LinkFlowTests(APITestCase):
    def setUp(self):
        cache.clear()
        self.u = User.objects.create_user(name="Sample Rahim", phone="+8801711000201",
                                          password=PW)

    def primary(self):
        c = APIClient()
        r = c.post("/api/v1/auth/login", {"identifier": "+8801711000201", "password": PW},
                   format="json", HTTP_X_SESSION_MODE="device", HTTP_X_DEVICE_ID="phone-a",
                   HTTP_X_DEVICE_NAME="Realme 9i")
        self.assertEqual(r.status_code, 200, r.data)
        c.credentials(HTTP_AUTHORIZATION="Token " + r.data["token"])
        return c

    def new_phone(self):
        return APIClient(HTTP_X_DEVICE_ID="phone-b", HTTP_X_DEVICE_NAME="Pixel 7",
                         HTTP_X_SESSION_MODE="device")

    def link(self, use_code=True):
        a = self.primary()
        s = a.post("/api/v1/e2/link/start", {}, format="json")
        self.assertEqual(s.status_code, 200, s.data)
        self.assertTrue(s.data["qr"].startswith(DL.QR_PREFIX))
        self.assertRegex(s.data["code"], r"^[A-HJ-NP-Z]{4}-[A-HJ-NP-Z]{4}$")
        b = self.new_phone()
        secret = s.data["code"].lower() if use_code else s.data["qr"]
        cl = b.post("/api/v1/e2/link/claim", {"code": secret, "eph_pub": PUB,
                                              "platform": "android"}, format="json")
        self.assertEqual(cl.status_code, 200, cl.data)
        return a, b, s.data, cl.data

    def test_full_link_by_code_then_messages_session_and_list(self):
        a, b, s, cl = self.link(use_code=True)
        # the primary sees the new phone's name + the SAME 6 digits
        st = a.get("/api/v1/e2/link/status", {"pair": cl["pair"]})
        self.assertEqual(st.data["state"], "claimed")
        self.assertEqual(st.data["name"], "Pixel 7")
        self.assertEqual(st.data["verify"], cl["verify"])
        self.assertEqual(st.data["eph_pub"], PUB)
        self.assertEqual(a.get("/api/v1/e2/link/status").data["pair"], cl["pair"])
        # before approval the new phone waits
        w = b.post("/api/v1/e2/link/poll", {"pair": cl["pair"], "poll": cl["poll"]}, format="json")
        self.assertEqual(w.data["state"], "waiting")
        ap = a.post("/api/v1/e2/link/approve", {"pair": cl["pair"], "sealed": SEALED}, format="json")
        self.assertEqual(ap.status_code, 200, ap.data)
        p = b.post("/api/v1/e2/link/poll", {"pair": cl["pair"], "poll": cl["poll"]}, format="json")
        self.assertEqual(p.status_code, 200, p.data)
        self.assertEqual(p.data["state"], "approved")
        self.assertEqual(p.data["sealed"], SEALED)       # relayed untouched
        self.assertEqual(p.data["user"]["id"], self.u.id)
        # the raw session key is never stored; only its hash
        self.assertFalse(DeviceSession.objects.filter(key_hash=p.data["token"]).exists())
        self.assertFalse(PaCollectionItem.objects.filter(collection="devlink").exists())
        b.credentials(HTTP_AUTHORIZATION="Token " + p.data["token"])
        self.assertEqual(b.get("/api/v1/me").status_code, 200)
        # the primary stays signed in (a link never signs anyone out)
        self.assertEqual(a.get("/api/v1/me").status_code, 200)
        devs = a.get("/api/v1/messenger/linked-devices").data["devices"]
        self.assertEqual([d["device_id"] for d in devs], ["phone-b"])
        self.assertEqual(devs[0]["name"], "Pixel 7")
        # the pickup is one-time
        again = self.new_phone().post("/api/v1/e2/link/poll",
                                      {"pair": cl["pair"], "poll": cl["poll"]}, format="json")
        self.assertEqual(again.status_code, 404)

    def test_link_by_scanned_qr_text(self):
        a, b, s, cl = self.link(use_code=False)
        self.assertEqual(a.get("/api/v1/e2/link/status", {"pair": cl["pair"]}).data["state"],
                         "claimed")

    def test_code_is_single_use(self):
        a, b, s, cl = self.link()
        r = APIClient().post("/api/v1/e2/link/claim", {"code": s["code"], "eph_pub": PUB2},
                             format="json")
        self.assertEqual(r.status_code, 410)
        self.assertEqual(r.data["reason"], "used")

    def test_unknown_code_and_bad_key(self):
        c = APIClient()
        r = c.post("/api/v1/e2/link/claim", {"code": "AAAA-BBBB", "eph_pub": PUB}, format="json")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.data["reason"], "unknown")
        self.assertTrue(r.data["detail"])
        a = self.primary()
        s = a.post("/api/v1/e2/link/start", {}, format="json").data
        r = c.post("/api/v1/e2/link/claim", {"code": s["code"], "eph_pub": "short"}, format="json")
        self.assertEqual(r.data["reason"], "bad_key")

    def test_expired_code(self):
        a = self.primary()
        s = a.post("/api/v1/e2/link/start", {}, format="json").data
        real = DL._now()
        with mock.patch("core.device_link._now", return_value=real + DL.TTL_SEC + 5):
            r = APIClient().post("/api/v1/e2/link/claim", {"code": s["code"], "eph_pub": PUB},
                                 format="json")
        self.assertEqual(r.status_code, 410)
        self.assertEqual(r.data["reason"], "expired")

    def test_reject(self):
        a, b, s, cl = self.link()
        r = a.post("/api/v1/e2/link/approve", {"pair": cl["pair"], "reject": True}, format="json")
        self.assertEqual(r.data["state"], "rejected")
        p = b.post("/api/v1/e2/link/poll", {"pair": cl["pair"], "poll": cl["poll"]}, format="json")
        self.assertEqual(p.data["state"], "rejected")
        self.assertNotIn("token", p.data)
        self.assertFalse(LinkedDevice.objects.exists())

    def test_wrong_poll_secret_gets_nothing(self):
        a, b, s, cl = self.link()
        a.post("/api/v1/e2/link/approve", {"pair": cl["pair"], "sealed": SEALED}, format="json")
        p = APIClient().post("/api/v1/e2/link/poll", {"pair": cl["pair"], "poll": "guess"},
                             format="json")
        self.assertEqual(p.status_code, 404)
        self.assertNotIn("token", p.data)

    def test_other_account_cannot_approve(self):
        a, b, s, cl = self.link()
        User.objects.create_user(name="Sample Karim", phone="+8801711000202", password=PW)
        o = APIClient()
        t = o.post("/api/v1/auth/login", {"identifier": "+8801711000202", "password": PW},
                   format="json").data["token"]
        o.credentials(HTTP_AUTHORIZATION="Token " + t)
        r = o.post("/api/v1/e2/link/approve", {"pair": cl["pair"], "sealed": SEALED}, format="json")
        self.assertEqual(r.status_code, 410)

    def test_bad_sealed_refused(self):
        a, b, s, cl = self.link()
        r = a.post("/api/v1/e2/link/approve", {"pair": cl["pair"], "sealed": {"ct": "x"}},
                   format="json")
        self.assertEqual(r.data["reason"], "bad_sealed")

    def _linked(self):
        a, b, s, cl = self.link()
        a.post("/api/v1/e2/link/approve", {"pair": cl["pair"], "sealed": SEALED}, format="json")
        tok = b.post("/api/v1/e2/link/poll", {"pair": cl["pair"], "poll": cl["poll"]},
                     format="json").data["token"]
        b.credentials(HTTP_AUTHORIZATION="Token " + tok)
        return a, b

    def test_unlink_signs_the_phone_out(self):
        a, b = self._linked()
        r = a.post("/api/v1/messenger/linked-devices/phone-b/revoke", {}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data["signed_out"], 1)
        self.assertEqual(b.get("/api/v1/me").status_code, 401)
        self.assertEqual(a.get("/api/v1/me").status_code, 200)
        self.assertEqual(a.get("/api/v1/messenger/linked-devices").data["count"], 0)

    def test_unlink_via_circle_devices_path_too(self):
        a, b = self._linked()
        self.assertEqual(a.post("/api/v1/circle/devices/phone-b/revoke", {}, format="json")
                         .status_code, 200)
        self.assertEqual(b.get("/api/v1/me").status_code, 401)

    def test_signout_from_account_security_drops_linked_row(self):
        a, b = self._linked()
        s = DeviceSession.objects.get(user=self.u, device_id="phone-b", revoked_at__isnull=True)
        r = a.post("/api/v1/account/security/devices/s%d/signout" % s.pk)
        self.assertEqual(r.status_code, 200, getattr(r, "data", None))
        self.assertTrue(LinkedDevice.objects.get(device_id="phone-b").revoked)
        self.assertEqual(a.get("/api/v1/messenger/linked-devices").data["count"], 0)

    def test_unknown_device_revoke_404(self):
        a = self.primary()
        self.assertEqual(a.post("/api/v1/messenger/linked-devices/nope/revoke", {},
                                format="json").status_code, 404)

    def test_claim_rate_limited(self):
        c = APIClient()
        with mock.patch.object(DL, "CLAIMS_PER_IP_PER_10MIN", 2):
            for _ in range(2):
                c.post("/api/v1/e2/link/claim", {"code": "AAAA-BBBB", "eph_pub": PUB}, format="json")
            r = c.post("/api/v1/e2/link/claim", {"code": "AAAA-BBBB", "eph_pub": PUB}, format="json")
        self.assertEqual(r.status_code, 429)


class ChannelPostsPagingTests(APITestCase):
    """circle-extras row 48: GET channels/<id>/posts honours limit/offset."""

    def setUp(self):
        cache.clear()
        self.a = User.objects.create_user(name="Sample Owner", phone="01730000301",
                                          password=PW, language="en")
        self.c = APIClient()
        self.c.force_authenticate(self.a)

    def test_limit_offset(self):
        cid = self.c.post("/api/v1/channels", {"name": "Sample Bazar Prices"},
                          format="json").json()["id"]
        with mock.patch("core.push.push_to_user_async", return_value=True):
            for i in range(5):
                self.assertEqual(self.c.post("/api/v1/channels/%d/posts" % cid,
                                             {"kind": "text", "text": "post %d" % i},
                                             format="json").status_code, 201)
        j = self.c.get("/api/v1/channels/%d/posts" % cid, {"limit": 2}).json()
        self.assertEqual([p["text"] for p in j["results"]], ["post 4", "post 3"])
        self.assertEqual(j["count"], 5)
        self.assertTrue(j["has_more"])
        j = self.c.get("/api/v1/channels/%d/posts" % cid, {"limit": 2, "offset": 4}).json()
        self.assertEqual([p["text"] for p in j["results"]], ["post 0"])
        self.assertFalse(j["has_more"])
        j = self.c.get("/api/v1/channels/%d/posts" % cid, {"limit": "x"}).json()
        self.assertEqual(len(j["results"]), 5)
