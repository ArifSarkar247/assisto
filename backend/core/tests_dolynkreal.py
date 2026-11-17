"""dolynkreal — Dahua DoLynk exactly per the Doc Center (owner export 9 Nov).

Every simulated answer in logic/cctv_connect/mocks.py has the shape of the
docs' own examples, and the simulator CHECKS what the docs require (headers,
13-digit timestamp, simplified-mode Sign, Sign-Type, AES devCode, ARC salted
password). Synthetic data only.

1. Pure: signing rule, devCode (AES + the doc's Base64 vector), ARC password,
   push signature, event types, NO face API anywhere.
2. Open IoT adapter: add by serial + password (category order, wrong
   password, locked), live HLS (create, then "already exists"), playback HLS
   of the exact segment, MP4 evidence (dump task), snapshot, cloud storage,
   subscription without face types, token refresh.
3. API end to end: stream kinds, signed push incl. offline -> health due,
   face events dropped, Open ARC behind its switch (share -> claim with the
   DMSS account -> alarm push + ack -> revoke releases the share).
"""
import base64
import hashlib
import hmac
import inspect
import json
import os
import re
import time
from datetime import timedelta
from unittest import mock

from cryptography.fernet import Fernet
from django.test import SimpleTestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import integrations
from core import tests_e2e_cctv as E2E
from core.logic import cctv_connect as CC
from core.logic.cctv_connect import dolynk as DL
from core.logic.cctv_connect import mocks as M

_KEY = Fernet.generate_key().decode()


def setUpModule():
    os.environ["INTEGRATIONS_FERNET_KEY"] = _KEY
    integrations._FERNET = None


def tearDownModule():
    integrations._FERNET = None


def _clear():
    from django.core.cache import cache
    cache.clear()
    DL._tokens.clear()
    DL._user_tokens.clear()


# ====================================================================== 1
class PureTests(SimpleTestCase):
    def setUp(self):
        _clear()

    def test_sign_rule_calling_api(self):
        # Quick Start Guide -> Calling API: UPPER(HMAC-SHA512(AK [+ token] + ts + nonce, SK))
        want = hmac.new(b"sk", b"ak1689838378183n1", hashlib.sha512).hexdigest().upper()
        self.assertEqual(DL.sign("ak", "sk", "1689838378183", "n1"), want)
        want = hmac.new(b"sk", b"akTOK1689838378183n1", hashlib.sha512).hexdigest().upper()
        self.assertEqual(DL.sign("ak", "sk", "1689838378183", "n1", "TOK"), want)
        self.assertEqual(len(want), 128)

    def test_headers_token_vs_business_call(self):
        seen = []

        def http(url, body, t, h):
            seen.append(h)
            return 200, json.dumps({"code": "200", "success": True, "msg": "ok",
                                    "data": {"appAccessToken": "TK", "validitySeconds": 604800}})
        c = DL.Client("ak", "sk", "212808822", DL.DEFAULT_BASE, http, now=lambda: 1689838378.5)
        c.call("/open-api/api-iot/device/getDeviceList", {"pageNum": "1", "pageSize": "10"})
        tok, biz = seen
        for h in (tok, biz):
            for k in ("Content-Type", "Accept-Language", "Version", "AccessKey", "Timestamp",
                      "Nonce", "Sign", "X-TraceId-Header", "ProductId"):
                self.assertTrue(h.get(k), k)
            self.assertEqual(h["Timestamp"], "1689838378500")
        self.assertNotIn("AppAccessToken", tok)
        self.assertNotIn("Sign-Type", tok)
        self.assertEqual((biz["AppAccessToken"], biz["Sign-Type"]), ("TK", "simple"))
        self.assertEqual(biz["Sign"], DL.sign("ak", "sk", biz["Timestamp"], biz["Nonce"], "TK"))
        self.assertNotEqual(tok["Nonce"], biz["Nonce"])

    def test_dev_code_aes_and_doc_vector(self):
        # "Adding Devices" method 1 example: admin123 -> Dolynk_YWRtaW4xMjM=
        self.assertEqual(DL.dev_code_simple("admin123"), "Dolynk_YWRtaW4xMjM=")
        enc = DL.dev_code("Pass@123#", "mySecretKey")
        self.assertNotIn("Pass", enc)
        base64.b64decode(enc)
        self.assertEqual(M.VendorSims._dl_decrypt(enc, "mySecretKey"), "Pass@123#")
        self.assertNotEqual(M.VendorSims._dl_decrypt(enc, "otherKey"), "Pass@123#")

    def test_arc_password_salted(self):
        a = hmac.new(b"salt1", b"pw", hashlib.sha512).hexdigest()
        want = hmac.new(b"rnd1", a.encode(), hashlib.sha512).hexdigest()
        self.assertEqual(DL.arc_password("pw", "salt1", "rnd1"), want)

    def test_push_signature(self):
        # Event message format definition: sign = HMAC-SHA512(id, secretKey)
        m = {"accessKey": "1671428969104281600", "msgType": "videoMotion",
             "deviceId": "8E0878DAAJ00153", "id": 1685822754353311744}
        m["sign"] = hmac.new(b"SK", b"1685822754353311744", hashlib.sha512).hexdigest()
        self.assertTrue(DL.verify_push(m, "SK"))
        self.assertTrue(DL.verify_push(dict(m, sign=m["sign"].upper()), "SK"))
        self.assertFalse(DL.verify_push(m, "other"))
        self.assertFalse(DL.verify_push(dict(m, id=1685822754353311745), "SK"))
        self.assertFalse(DL.verify_push(dict(m, sign=""), "SK"))

    def test_event_types(self):
        self.assertEqual(DL.classify("smdHuman"), ("alert", "person", "person"))
        self.assertEqual(DL.classify("CrossLineDetection")[:2], ("alert", "line"))
        self.assertEqual(DL.classify("videoBlind")[:2], ("alert", "covered"))
        self.assertEqual(DL.classify("offline"), ("status", False, None))
        self.assertEqual(DL.classify("storageFailure")[0], "storage")
        for t in ("rtFaceDetect", "faceDetect", "FaceRecognition", "UserModified", ""):
            self.assertEqual(DL.classify(t), (None, None, None), t)

    def test_no_face_api_anywhere(self):
        """Owner rule: no face recognition — no Access Control face API, no
        method or path naming faces, face types never subscribed."""
        names = set(dir(DL.DolynkAdapter)) | set(dir(DL.DolynkArcAdapter)) | set(dir(DL.Client)) \
            | set(vars(DL))
        self.assertFalse([n for n in names if "face" in n.lower()])
        src = inspect.getsource(DL)
        paths = set(re.findall(r'"(/open-api/[^"]+)"', src)) | set(DL.P.values()) | set(DL.ARC.values())
        self.assertTrue(paths)
        bad = [p for p in paths if "face" in p.lower() or "accesscontrol" in p.lower()]
        self.assertEqual(bad, [])
        self.assertFalse([t for t in DL.SUBSCRIBE if "face" in t.lower()])

    def test_masked_account_match(self):
        self.assertTrue(DL._masked_match("rahim.shop@mail.test", "ra***@mail.test"))
        self.assertTrue(DL._masked_match("Rahim@x.test", "rahim@x.test"))
        self.assertFalse(DL._masked_match("karim@mail.test", "ra***@mail.test"))
        self.assertFalse(DL._masked_match("", "ra***@mail.test"))
        self.assertFalse(DL._masked_match("rahim@mail.test", ""))

    def test_api_base_guard(self):
        self.assertEqual(DL._base({"api_base": "https://evil.test"}), DL.DEFAULT_BASE)
        self.assertEqual(DL._base({"api_base": "http://open-api-fk.dolynkcloud.com"}), DL.DEFAULT_BASE)
        self.assertEqual(DL._base({"api_base": "https://open-api-fk.dolynkcloud.com/"}),
                         "https://open-api-fk.dolynkcloud.com")

    def test_password_code_kept_whole(self):
        self.assertEqual(DL.DolynkAdapter.clean_code(" Ab#12$x! "), "Ab#12$x!")
        self.assertEqual(DL.DolynkAdapter.clean_code("bad\npw"), "")
        self.assertEqual(CC.base.Provider.clean_code("Ab#1"), "")        # others: alnum only


# ====================================================================== 2
class IotAdapterTests(SimpleTestCase):
    S = "SIMDODVR1"

    def setUp(self):
        _clear()
        self.sim = M.VendorSims()
        self.sim.add_device("dolynk", self.S, "Adm!n#2025", channels=4)
        self.sim.add_device("dolynk", "SIMDOCAM1", "Cam$Pass9", channels=1)
        self.a = CC.adapter("dolynk", http=self.sim.http, cfg=self.sim.cfg("dolynk"))

    def test_add_device_categories_password_and_lock(self):
        with self.assertRaises(CC.ConnectError) as e:
            self.a.link_device(self.S, "wrong-pass")
        self.assertEqual((e.exception.code, e.exception.hint), ("IDV006", "wrong_code"))
        adds = [p for p in self.sim.dl_calls if p.endswith("/addDevice")]
        self.assertEqual(len(adds), 2)                 # IPC (category refused) -> NVR
        g = self.a.link_device(self.S, "Adm!n#2025")
        self.assertEqual(g, {"mode": "device_code", "serials": [self.S]})
        self.assertEqual(self.sim.devs["dolynk"][self.S].owner, "sim")
        # a camera: right category first time when the app says so
        self.sim.dl_calls = []
        self.a.link_device("SIMDOCAM1", "Cam$Pass9", category="IPC")
        self.assertEqual(len([p for p in self.sim.dl_calls if p.endswith("/addDevice")]), 1)
        # already ours (an earlier link): the password proves it again
        g2 = self.a.link_device(self.S, "Adm!n#2025", category="NVR")
        self.assertEqual(g2["serials"], [self.S])
        with self.assertRaises(CC.ConnectError):
            self.a.link_device(self.S, "nope", category="NVR")
        # bound to another account / device locked
        self.sim.devs["dolynk"]["SIMDOCAM1"].owner = "dmss-user"
        with self.assertRaises(CC.ConnectError) as e:
            self.a.link_device("SIMDOCAM1", "Cam$Pass9", category="IPC")
        self.assertEqual(e.exception.hint, "taken")
        self.assertEqual(DL.HINT["IDV0011"], "locked")
        self.assertTrue(CC.base.hint_text("locked", "bn"))

    def test_live_playback_clip_snapshot_cloud(self):
        g = self.a.link_device(self.S, "Adm!n#2025", category="NVR")
        live = self.a.live(g, self.S, 2)
        self.assertEqual(live["proto"], "hls")
        self.assertTrue(live["url"].startswith("https://") and "lechange.com" in live["url"])
        self.assertTrue(live["token"])
        live_hd = self.a.live(g, self.S, 2, hd=True)       # "already exists" -> read back
        self.assertTrue(live_hd["url"].startswith("https://"))
        self.assertIn("/getHlsLiveList", self.sim.dl_calls[-1])
        now = time.time()
        pb = self.a.playback(g, self.S, 2, now - 600, now - 540)
        self.assertEqual(pb["proto"], "hls")
        self.assertTrue(pb["url"].startswith("https://"))
        self.assertGreaterEqual(pb["seek_s"], 0)
        self.assertEqual(len(pb["records"]), 2)
        c1 = self.a.clip(g, self.S, 2, now - 600, now - 540)
        self.assertTrue(c1["pending"] and c1["task"])
        c2 = self.a.clip(g, self.S, 2, now - 600, now - 540, task=c1["task"])
        self.assertTrue(c2["pending"])                       # status 1: waiting
        c3 = self.a.clip(g, self.S, 2, now - 600, now - 540, task=c1["task"])
        self.assertFalse(c3["pending"])
        self.assertTrue(c3["url"].startswith("https://") and c3["url"].split("?")[0].endswith(".mp4"))
        snap = self.a.snapshot(g, self.S, 2)
        self.assertEqual((snap["proto"], snap["ready_after_s"]), ("jpeg", 10))
        cl = self.a.cloud(g, self.S, 0)
        self.assertEqual(cl["plan"]["type"], "event")
        self.assertEqual(cl["plan"]["days"], 7)
        self.assertTrue(cl["clips"][0]["thumb"].startswith("https://"))
        # offline -> honest hint
        self.sim.devs["dolynk"][self.S].online = False
        with self.assertRaises(CC.ConnectError) as e:
            self.a.live(g, self.S, 3)
        self.assertEqual(e.exception.hint, "offline")

    def test_subscription_skips_face_types(self):
        g = self.a.link_device(self.S, "Adm!n#2025", category="NVR")
        self.assertEqual(self.a.after_link(g, "https://lifeassisto.test/api/v1/cctv/dolynk/callback/x"), 1)
        sub = self.sim.dl_subs[-1]
        self.assertEqual((sub["categoryCode"], sub["deviceIds"]), ("NVR", [self.S]))
        self.assertIn("smdHuman", sub["messageTypeCodes"])
        self.assertIn("offline", sub["messageTypeCodes"])
        self.assertNotIn("rtFaceDetect", sub["messageTypeCodes"])
        self.assertEqual(len(self.sim.dl_cbs), 1)
        self.a.after_link(g, "https://lifeassisto.test/api/v1/cctv/dolynk/callback/x")
        self.assertEqual(len(self.sim.dl_cbs), 1)            # the same config is reused

    def test_face_event_dropped_and_token_refresh(self):
        g = self.a.link_device(self.S, "Adm!n#2025", category="NVR")
        t0 = time.time() - 5
        self.sim.push_alarm("dolynk", self.S, 0, "face")
        self.sim.push_alarm("dolynk", self.S, 0, "cover")
        evs = self.a.events(g, self.S, t0)
        self.assertEqual([e["kind"] for e in evs], ["covered"])
        # an expired token (AUT001) is renewed once, transparently
        key = list(DL._tokens)[0]
        DL._tokens[key] = ("expired", time.time() + 999)
        self.assertEqual(len(self.a.devices(g)), 1)
        self.assertNotEqual(DL._tokens[key][0], "expired")

    def test_encrypted_dav_picture(self):
        self.a.link_device(self.S, "Adm!n#2025", category="NVR")
        u = self.a.picture_url("https://cloudreadproxy-online-sg.imoulife.com/x_thumb_qcif.dav?sig=1", self.S)
        self.assertTrue(u.startswith("https://") and ".jpg" in u)
        self.assertEqual(self.a.picture_url("https://a.lechange.com/p.jpg", self.S),
                         "https://a.lechange.com/p.jpg")


# ====================================================================== 3
def _enable(slug, cfg):
    from core.models import Integration
    Integration.objects.update_or_create(slug=slug, defaults={
        "enc_blob": integrations._encrypt(cfg), "status": "working",
        "detail": CC.SIGNED_IN.get(slug, "") + " (test)"})


class DolynkApiE2ETests(E2E._Base):
    S = "SIMDODVR1"

    def setUp(self):
        super().setUp()
        _clear()
        self.sim = M.VendorSims()
        self.sim.add_device("dolynk", self.S, "Adm!n#2025", channels=4)
        for target, value in (("core.logic.cctv_connect.base.default_http", self.sim.http),
                              ("core.shop_views._included_cameras", None),
                              ("core.cctv_connect_views._fetch_picture", None)):
            if target.endswith("default_http"):
                p = mock.patch(target, value)
            elif target.endswith("_included_cameras"):
                p = mock.patch(target, return_value=10)
            else:
                p = mock.patch(target, return_value=E2E._jpeg())
            p.start()
            self.addCleanup(p.stop)
        self.sid = self.site["id"]
        self.owner.is_staff = True
        self.owner.save(update_fields=["is_staff"])
        from core.models import ShopSite
        ShopSite.objects.filter(pk=self.sid).update(
            away={"until": (timezone.now() + timedelta(days=1)).isoformat()})

    def link_iot(self):
        _enable("dolynk", self.sim.cfg("dolynk"))
        r = self.client.get("/api/v1/cctv/connect/providers?site=%d" % self.sid)
        row = [p for p in r.data["providers"] if p["id"] == "dolynk"][0]
        self.assertTrue(row["code_secret"])                   # the app hides the password
        r = self.client.post("/api/v1/cctv/connect/dolynk/link",
                             {"site": self.sid, "serial": self.S, "code": "Adm!n#2025",
                              "category": "NVR", "consent": True}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        link = r.data["link"]
        r = self.client.post("/api/v1/cctv/connect/links/%d/import" % link["id"],
                             {"items": [{"serial": self.S, "channel": 1, "name": "Gate"}]},
                             format="json")
        self.assertEqual(r.status_code, 201, r.data)
        return link, r.data["added"][0]

    def test_password_never_stored_and_stream_kinds(self):
        from core.models import CctvCloudLink
        link, cam = self.link_iot()
        row = CctvCloudLink.objects.get(pk=link["id"])
        self.assertNotIn("Adm!n#2025", row.grant_blob + str(row.serials) + str(row.state) + row.last_error)
        url = "/api/v1/cctv/connect/cameras/%d/stream" % cam["id"]
        r = self.client.post(url, {"kind": "live"}, format="json")
        self.assertEqual((r.status_code, r.data["proto"]), (200, "hls"), r.data)
        now = time.time()
        r = self.client.post(url, {"kind": "playback", "start": now - 300, "end": now - 240},
                             format="json")
        self.assertEqual((r.status_code, r.data["proto"]), (200, "hls"), r.data)
        r = self.client.post(url, {"kind": "clip", "start": now - 300, "end": now - 240},
                             format="json")
        self.assertTrue(r.data["pending"], r.data)
        task = r.data["task"]
        for _ in range(2):
            r = self.client.post(url, {"kind": "clip", "task": task, "start": now - 300,
                                       "end": now - 240}, format="json")
        self.assertEqual((r.data["pending"], r.data["proto"]), (False, "mp4"), r.data)
        r = self.client.post(url, {"kind": "snapshot"}, format="json")
        self.assertEqual(r.data["proto"], "jpeg")
        r = self.client.post(url, {"kind": "cloud"}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertIn("plan", r.data)

    def test_signed_push_face_dropped_and_offline_makes_health_due(self):
        from core import cctv_connect_views as V
        from core.models import CctvCloudLink, ShopEvent
        link, cam = self.link_iot()
        url = V.dolynk_callback_url("dlak")
        path = url[url.index("/api/v1/"):]
        before = ShopEvent.objects.count()
        face = self.sim.dl_msg(self.S, {"id": "x-1", "channel": 1, "type": "rtFaceDetect",
                                        "at": time.time(), "pic": ""})
        r = APIClient().post(path, json.dumps([face]), content_type="application/json")
        self.assertEqual(r.data["events"], [{"ignored": "type"}])
        self.assertEqual(ShopEvent.objects.count(), before)
        other = dict(self.sim.dl_msg(self.S, {"id": "x-2", "channel": 1, "type": "smdHuman",
                                              "at": time.time(), "pic": ""}), accessKey="someone")
        r = APIClient().post(path, json.dumps(other), content_type="application/json")
        self.assertEqual(r.data["events"], [{"ignored": "not_ours"}])
        off = self.sim.dl_msg(self.S, {"id": "x-3", "channel": 1, "type": "offline",
                                       "at": time.time(), "pic": ""})
        r = APIClient().post(path, json.dumps(off), content_type="application/json")
        self.assertEqual(r.data["events"], [{"result": "health_due"}])
        st = CctvCloudLink.objects.get(pk=link["id"]).state
        self.assertEqual(st["health_at"], 0)
        self.assertTrue(st["push_at"])
        human = self.sim.dl_msg(self.S, {"id": "x-4", "channel": 1, "type": "smdHuman",
                                         "at": time.time(),
                                         "pic": "https://cloudreadproxy-online-sg.imoulife.com/a_thumb_qcif.dav?s=1"})
        r = APIClient().post(path, json.dumps(human), content_type="application/json")
        self.assertEqual(r.data["events"], [{"result": "raised"}])
        ev = ShopEvent.objects.order_by("-id").first()
        self.assertEqual(ev.camera_id, cam["id"])
        r = APIClient().post(path, json.dumps(human), content_type="application/json")
        self.assertEqual(r.data["events"], [{"result": "duplicate"}])
        # a push was seen: the 2-minute poll is off for 24 h
        n = len(self.sim.dl_calls)
        V.sync_all()
        self.assertNotIn("/open-api/api-message/getMessage", self.sim.dl_calls[n:])

    def test_arc_behind_switch_share_claim_alarm_ack_revoke(self):
        from core import cctv_connect_views as V
        from core.models import ShopEvent
        d = self.sim.devs["dolynk"][self.S]
        d.arc_account = "rahim.shop@dmss.test"            # shared from DMSS
        cfg = self.sim.cfg("dolynk_arc")
        self.assertFalse(CC.adapter("dolynk_arc", cfg=dict(cfg, arc_on="")).configured())
        ok, detail = integrations.test_dolynk_arc(dict(cfg, arc_on=""), http=self.sim.http)
        self.assertFalse(ok)
        ok, detail = integrations.test_dolynk_arc(cfg, http=self.sim.http)
        self.assertTrue(ok, detail)
        self.assertIn(CC.ARC_OK, detail)
        self.assertNotIn("Arc#Pass1", detail)
        _enable("dolynk_arc", cfg)
        r = self.client.get("/api/v1/cctv/connect/providers?site=%d" % self.sid)
        self.assertIn("dolynk_arc", [p["id"] for p in r.data["providers"]])
        r = self.client.post("/api/v1/cctv/connect/dolynk_arc/link",
                             {"site": self.sid, "serial": self.S, "code": "karim@dmss.test",
                              "consent": True}, format="json")
        self.assertEqual((r.status_code, r.data["error"]), (422, "vendor_wrong_code"))
        r = self.client.post("/api/v1/cctv/connect/dolynk_arc/link",
                             {"site": self.sid, "serial": self.S, "code": "rahim.shop@dmss.test",
                              "consent": True}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        self.assertTrue(d.arc_active)
        self.assertTrue(self.sim.arc_cb.endswith("/api/v1/cctv/dolynk/arc/%s"
                                                 % V.dolynk_callback_token("arcak", arc=True)))
        link = r.data["link"]
        r = self.client.post("/api/v1/cctv/connect/links/%d/import" % link["id"],
                             {"items": [{"serial": self.S, "channel": 0, "name": "Shop"}]},
                             format="json")
        self.assertEqual(r.status_code, 201, r.data)
        cam = r.data["added"][0]
        # ARC live is SDK-only: honest, snapshot instead
        url = "/api/v1/cctv/connect/cameras/%d/stream" % cam["id"]
        r = self.client.post(url, {"kind": "live"}, format="json")
        self.assertEqual((r.status_code, r.data["error"]), (502, "vendor_no_stream"))
        r = self.client.post(url, {"kind": "snapshot"}, format="json")
        self.assertEqual(r.data["proto"], "jpeg")
        # a pushed ARC alarm -> alert + ack
        arc_url = V.dolynk_callback_url("arcak", arc=True)
        path = arc_url[arc_url.index("/api/v1/"):]
        msg = {"localTime": int(time.time() * 1000), "companyId": 1668099767630202276,
               "msgType": "smdHuman", "accountEmail": "arc@assisto.test", "accessKey": "arcak",
               "utcTime": int(time.time() * 1000), "id": 1910316040315727872,
               "picUrls": [], "deviceId": self.S, "channelId": 0, "account": "ra***@dmss.test"}
        before = ShopEvent.objects.count()
        r = APIClient().post(path, json.dumps(msg), content_type="application/json")
        self.assertEqual(r.data["events"], [{"result": "raised"}], r.data)
        self.assertEqual(ShopEvent.objects.count(), before + 1)
        self.assertEqual(self.sim.arc_acks, [1910316040315727872])
        r = APIClient().post(path.rsplit("/", 1)[0] + "/bad", json.dumps(msg),
                             content_type="application/json")
        self.assertEqual(r.status_code, 404)
        # revoke: monitoring off + the share released
        r = self.client.delete("/api/v1/cctv/connect/links/%d" % link["id"])
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual((d.arc_active, d.arc_account), (False, ""))
