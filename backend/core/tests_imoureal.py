"""imou-real (owner order 17 Nov: real camera test with Imou / EZVIZ / Dahua /
Hikvision). Every vendor answer here is RECORDED / FAKE — shaped exactly like
the public docs (open.imoulife.com: setMessageCallback, message format,
createDeviceRecordHls; DoLynk Doc Center: PRM0016 "Sign error"). No live
call, no real key.

1. Imou push parsing: capabilityEvent (msgType detection.motion.detected,
   labelType humanAlarm, picUrlArray), iotEvent person / motion codes, event
   time -> push latency.
2. Imou client: token cached; TK1002 -> fresh token + ONE retry; callback
   flags include capabilityEvent; createDeviceRecordHls request shape.
3. Imou adapter playback: SD HLS, cloud fallback, honest sdk_only, one-day
   window.
4. DoLynk: PRM0016 with the simple signature -> one retry in "full", saved
   to the integration and logged without secrets; an explicit mode is kept.
5. Owner Admin card: the badge shows the LAST real result with its time; a
   runtime token failure turns an old green red, a later success clears it;
   secrets are redacted from test details.
6. The Imou callback: latency recorded + returned; a message for another
   appId is refused.
7. cctv_vendor_check (read-only readiness): codes only, localhost callback
   reported as not usable.
Synthetic data only.
"""
import json
import os
import time
from datetime import datetime, timezone as dt_tz
from unittest import mock

from cryptography.fernet import Fernet
from django.test import SimpleTestCase, TestCase
from rest_framework.test import APIClient

from core import integrations as I
from core.logic import imou as IM
from core.logic.cctv_connect import dolynk as DL
from core.logic.cctv_connect import imou as IMA
from core.tests_watchman import _Base, _jpeg

_KEY = Fernet.generate_key().decode()

# recorded shapes (values made up), from the public Imou docs
CAPABILITY_HUMAN = {
    "msgType": "detection.motion.detected", "deviceId": "TESTIPC000012345",
    "productId": "56WGTET2", "channelId": "0", "time": 1673406989,
    "localTime": "20230111T111629", "alarmId": "1162578620235050001",
    "thumbUrl": "https://example.easy4ip.com/pic/thumb.jpg",
    "picUrlArray": ["https://example.easy4ip.com/pic/frame1.jpg"],
    "labelType": "humanAlarm", "aiTag": "person"}
IOT_PERSON = {"msgType": "iotEvent", "did": "TESTQWER0001", "channelId": "0",
              "alarmId": "1162578620235051004", "time": "20250901195200",
              "utcTime": "20250901T115200", "content": {"event": "33000"}}


def setUpModule():
    os.environ["INTEGRATIONS_FERNET_KEY"] = _KEY
    I._FERNET = None


def tearDownModule():
    I._FERNET = None


class _ImouHttp:
    """A recorded Imou Open API: answers by method name, logs every call."""

    def __init__(self, answers=None):
        self.calls = []
        self.answers = dict(answers or {})
        self.tokens = 0

    def __call__(self, url, body, timeout, *headers):
        method = url.rsplit("/", 1)[1]
        req = json.loads(body)
        self.calls.append((method, req["params"]))
        if method == "accessToken":
            self.tokens += 1
            return 200, json.dumps({"result": {"code": "0", "data": {
                "accessToken": "At_%d" % self.tokens, "expireTime": 259200}}})
        ans = self.answers.get(method)
        if callable(ans):
            ans = ans(req["params"])
        if ans is None:
            ans = {"code": "OP1000", "msg": "unknown method"}
        return 200, json.dumps({"result": ans})


def ok(data=None):
    return {"code": "0", "msg": "ok", "data": data or {}}


# ------------------------------------------------------------------ 1
class ImouPushParseTests(SimpleTestCase):
    def test_capability_event_human_from_docs(self):
        a = IM.parse_alarm(CAPABILITY_HUMAN)
        self.assertEqual((a["device_id"], a["channel"], a["human"]),
                         ("TESTIPC000012345", "0", True))
        self.assertEqual(a["pic"], "https://example.easy4ip.com/pic/frame1.jpg")  # picUrlArray
        self.assertEqual(a["at"], 1673406989.0)
        self.assertEqual(a["alarm_id"], "1162578620235050001")

    def test_capability_motion_is_not_human(self):
        m = dict(CAPABILITY_HUMAN, labelType="", aiTag="")
        self.assertFalse(IM.parse_alarm(m)["human"])

    def test_iot_event_codes(self):
        self.assertTrue(IM.parse_alarm(IOT_PERSON)["human"])
        motion = dict(IOT_PERSON, content={"event": "32000"})
        self.assertFalse(IM.parse_alarm(motion)["human"])
        self.assertIsNone(IM.parse_alarm(dict(IOT_PERSON, content={"event": "10001"})))
        # utcTime (UTC) wins over the device-local 14-digit "time"
        self.assertEqual(IM.event_epoch(IOT_PERSON),
                         datetime(2025, 9, 1, 11, 52, 0).replace(
                             tzinfo=dt_tz.utc).timestamp())

    def test_event_time_forms_and_latency(self):
        self.assertEqual(IM.event_epoch({"time": 1673406989000}), 1673406989.0)   # ms
        self.assertIsNone(IM.event_epoch({"time": "soon"}))
        self.assertEqual(IM.push_latency(100.0, 103.46), 3.5)
        self.assertEqual(IM.push_latency(100.0, 60.0), 0.0)     # small clock skew
        self.assertIsNone(IM.push_latency(None, 100.0))
        self.assertIsNone(IM.push_latency(0.0, 3 * 86400.0))    # unbelievable

    def test_status_messages_never_alert(self):
        self.assertIsNone(IM.parse_alarm({"msgType": "deviceStatus", "did": "X1"}))


# ------------------------------------------------------------------ 2
class ImouClientTests(SimpleTestCase):
    def setUp(self):
        IM._token_cache.clear()
        self.addCleanup(IM._token_cache.clear)

    def test_token_cached(self):
        h = _ImouHttp({"deviceOnline": ok({"onLine": "1"})})
        c = IM.ImouClient("APP1", "SEC1", http=h)
        c.device_online("D1")
        c.device_online("D1")
        self.assertEqual(h.tokens, 1)

    def test_expired_token_refreshed_once(self):
        seen = []

        def online(p):
            seen.append(p["token"])
            return {"code": "TK1002", "msg": "token expired"} if len(seen) == 1 else ok({"onLine": "1"})
        h = _ImouHttp({"deviceOnline": online})
        c = IM.ImouClient("APP2", "SEC2", http=h)
        c.device_online("D1")
        self.assertEqual(seen, ["At_1", "At_2"])        # new token, one retry
        # a second TK1002 in a row is not looped forever
        h2 = _ImouHttp({"deviceOnline": {"code": "TK1002", "msg": "x"}})
        IM._token_cache.clear()
        with self.assertRaises(IM.ImouError) as e:
            IM.ImouClient("APP3", "SEC3", http=h2).device_online("D1")
        self.assertEqual(e.exception.code, "TK1002")
        self.assertEqual(h2.tokens, 2)

    def test_callback_flags_include_capability_event(self):
        h = _ImouHttp({"setMessageCallback": ok()})
        IM.ImouClient("APP4", "SEC4", http=h).set_callback("https://api.example.test/cb/x")
        p = dict(h.calls)["setMessageCallback"]
        self.assertEqual(p["status"], "on")
        self.assertEqual(set(p["callbackFlag"].split(",")),
                         {"alarm", "deviceStatus", "capabilityEvent"})

    def test_record_hls_request_shape(self):
        h = _ImouHttp({"createDeviceRecordHls": ok({"url": "https://cmgw.easy4ip.com/r/x.m3u8"})})
        url = IM.ImouClient("APP5", "SEC5", http=h).record_hls(
            "D1", "0", "2026-11-17 10:00:00", "2026-11-17 10:05:00", "localRecord")
        self.assertTrue(url.endswith(".m3u8"))
        p = dict(h.calls)["createDeviceRecordHls"]
        self.assertEqual((p["recordType"], p["streamId"], p["channelId"]), ("localRecord", 1, "0"))
        self.assertEqual(p["beginTime"][:10], p["endTime"][:10])


# ------------------------------------------------------------------ 3
class ImouPlaybackTests(SimpleTestCase):
    CFG = {"app_id": "imid", "app_secret": "ims"}

    def setUp(self):
        IM._token_cache.clear()
        self.addCleanup(IM._token_cache.clear)

    def adapter(self, h):
        return IMA.ImouAdapter(dict(self.CFG), http=lambda url, body, t, hd=None: h(url, body, t))

    def records(self, p):
        return ok({"records": [{"beginTime": p["beginTime"], "endTime": p["endTime"]}]})

    def test_sd_card_hls(self):
        h = _ImouHttp({"queryLocalRecords": self.records,
                       "createDeviceRecordHls": ok({"url": "https://cmgw.easy4ip.com/r/sd.m3u8"})})
        now = time.time()
        pb = self.adapter(h).playback({"mode": "device_code", "serials": ["D1"]}, "D1", 0,
                                      now - 600, now - 540)
        self.assertEqual((pb["proto"], pb["source"]), ("hls", "sd"))
        self.assertTrue(pb["records"])

    def test_cloud_fallback_then_honest_sdk_only(self):
        def hls(p):
            if p["recordType"] == "localRecord":
                return {"code": "DV1026", "msg": "not supported"}
            return ok({"url": "https://cmgw.easy4ip.com/r/cloud.m3u8"})
        h = _ImouHttp({"queryLocalRecords": self.records, "createDeviceRecordHls": hls})
        now = time.time()
        g = {"mode": "device_code", "serials": ["D1"]}
        self.assertEqual(self.adapter(h).playback(g, "D1", 0, now - 600, now - 540)["source"],
                         "cloud")
        h2 = _ImouHttp({"queryLocalRecords": self.records,
                        "createDeviceRecordHls": {"code": "OP1021", "msg": "x"}})
        pb = self.adapter(h2).playback(g, "D1", 0, now - 600, now - 540)
        self.assertEqual((pb["url"], pb["proto"]), ("", "sdk_only"))
        self.assertTrue(pb["records"])

    def test_foreign_host_url_refused(self):
        h = _ImouHttp({"queryLocalRecords": self.records,
                       "createDeviceRecordHls": ok({"url": "https://evil.example.com/x.m3u8"})})
        now = time.time()
        pb = self.adapter(h).playback({"mode": "device_code", "serials": ["D1"]}, "D1", 0,
                                      now - 600, now - 540)
        self.assertEqual(pb["proto"], "sdk_only")

    def test_window_kept_inside_one_day(self):
        h = _ImouHttp({"queryLocalRecords": self.records,
                       "createDeviceRecordHls": ok({"url": "https://cmgw.easy4ip.com/r/sd.m3u8"})})
        # 23:58 -> 00:02 Bangladesh time crosses midnight
        end = datetime(2026, 11, 17, 0, 2) - IMA.BD
        end_epoch = (end - datetime(1970, 1, 1)).total_seconds()
        self.adapter(h).playback({"mode": "device_code", "serials": ["D1"]}, "D1", 0,
                                 end_epoch - 240, end_epoch)
        p = dict(h.calls)["createDeviceRecordHls"]
        self.assertEqual((p["beginTime"], p["endTime"]),
                         ("2026-11-17 00:00:00", "2026-11-17 00:02:00"))


# ------------------------------------------------------------------ 4
class _DolynkFullOnly:
    """DoLynk answering PRM0016 (Sign error) to the simple signature: this
    account wants the FAQ 'full' form (live check 17 Nov)."""

    def __init__(self):
        self.signs = []

    def __call__(self, url, body, timeout, headers):
        h = headers or {}
        full = DL.sign(h["AccessKey"], "dlsk", h["Timestamp"], h["Nonce"], extra="POST")
        self.signs.append("full" if h.get("Sign") == full else "other")
        if url.endswith(DL.TOKEN_PATH):
            if h.get("Sign") != full:
                return 200, json.dumps({"code": "PRM0016", "msg": "Sign error", "success": False})
            return 200, json.dumps({"code": "200", "success": True,
                                    "data": {"appAccessToken": "eyJ.sim", "validitySeconds": 604800}})
        return 200, json.dumps({"code": "200", "success": True, "data": {}})


class DolynkSignModeTests(TestCase):
    CFG = {"access_key": "dlak", "secret_key": "dlsk", "product_id": "212808822"}

    def setUp(self):
        DL._tokens.clear()
        self.addCleanup(DL._tokens.clear)

    def test_auto_full_saved_and_logged_without_secret(self):
        I.save("dolynk", dict(self.CFG))
        http = _DolynkFullOnly()
        a = DL.DolynkAdapter(dict(self.CFG), http=http)
        with self.assertLogs("assisto.shop", level="INFO") as logs:
            self.assertEqual(a.signin(), "eyJ.sim")
        self.assertEqual(http.signs, ["other", "full"])          # one retry only
        self.assertEqual(I.get("dolynk")["sign_mode"], "full")
        text = "\n".join(logs.output)
        self.assertIn("sign mode auto-set to full", text)
        self.assertNotIn("dlsk", text)
        # next client signs in full straight away
        DL._tokens.clear()
        http2 = _DolynkFullOnly()
        DL.DolynkAdapter(I.get("dolynk"), http=http2).signin()
        self.assertEqual(http2.signs, ["full"])

    def test_explicit_simple_is_respected(self):
        a = DL.DolynkAdapter(dict(self.CFG, sign_mode="simple"), http=_DolynkFullOnly())
        with self.assertRaises(DL.B.ConnectError) as e:
            a.signin()
        self.assertEqual(e.exception.code, "PRM0016")

    def test_other_cfg_never_overwrites_saved_integration(self):
        I.save("dolynk", dict(self.CFG, access_key="savedak"))
        DL.DolynkAdapter(dict(self.CFG), http=_DolynkFullOnly()).signin()
        self.assertNotIn("sign_mode", I.get("dolynk"))


# ------------------------------------------------------------------ 5
class CardBadgeTests(TestCase):
    def row(self, slug, lang="en"):
        return [r for r in I.list_all(lang) if r["slug"] == slug][0]

    def green(self, slug):
        from django.utils import timezone
        from core.models import Integration
        I.save(slug, {"app_id": "imid", "app_secret": "SuperSecret99"})
        Integration.objects.filter(slug=slug).update(status="working", detail="Imou access token OK",
                                                     last_tested=timezone.now())

    def test_runtime_failure_turns_old_green_red_then_clears(self):
        self.green("imou")
        self.assertEqual(self.row("imou")["status"], "working")
        self.assertTrue(self.row("imou")["badge"].endswith("· OK"))
        I.record_check("imou", False, "SN1001", "token")
        r = self.row("imou")
        self.assertEqual(r["status"], "failing")
        self.assertIn("failed SN1001", r["badge"])
        self.assertIn("SN1001", self.row("imou", "bn")["badge"])
        self.assertTrue(I.is_enabled("imou"))          # the feature gate is not flipped
        I.record_check("imou", True, "", "token")
        self.assertEqual(self.row("imou")["status"], "working")

    def test_network_blip_is_not_the_key(self):
        self.green("imou")
        self.assertIsNone(I.record_check("imou", False, "network", "token"))
        self.assertIsNone(I.record_check("imou", False, "http_502", "token"))
        self.assertEqual(self.row("imou")["status"], "working")

    def test_real_token_failure_is_recorded(self):
        self.green("imou")
        IM._token_cache.clear()

        def http(url, body, t):
            return 200, json.dumps({"result": {"code": "SN1001", "msg": "sign error"}})
        with self.assertRaises(IM.ImouError):
            IM.ImouClient("imid", "SuperSecret99", http=http).token()
        self.assertIn("SN1001", self.row("imou")["badge"])
        # another app id (an end user's project) never touches the card
        self.green("imou")
        IM._token_cache.clear()
        with self.assertRaises(IM.ImouError):
            IM.ImouClient("otherapp", "x", http=http).token()
        self.assertEqual(self.row("imou")["status"], "working")

    def test_test_detail_redacts_secrets(self):
        I.save("imou", {"app_id": "imid", "app_secret": "SuperSecret99"})
        self.assertEqual(I.redact("imou", "boom SuperSecret99 boom"), "boom *** boom")
        with mock.patch.object(I, "test_imou", side_effect=RuntimeError("x SuperSecret99")):
            status, detail = I.test("imou")
        self.assertEqual(status, "failing")
        self.assertNotIn("SuperSecret99", detail)
        page = json.dumps(I.list_all("en"))
        self.assertNotIn("SuperSecret99", page)                    # masked only


# ------------------------------------------------------------------ 6
class ImouCallbackLatencyTests(_Base):
    def setUp(self):
        super().setUp()
        from core.models import ShopCamera
        site = self.setup_home()
        cam = self.add_camera(site["id"], vendor="imou")
        ShopCamera.objects.filter(pk=cam["id"]).update(vendor_ref="TESTIPC000012345:0")
        self.cam_id = cam["id"]
        self.tok = IM.callback_token("APPID", "x")

    def post(self, msg):
        with mock.patch("core.watchman_views.imou_cloud_on", return_value=True), \
                mock.patch("core.integrations.get", return_value={"app_id": "APPID"}), \
                mock.patch("core.logic.imou.callback_token", return_value=self.tok), \
                mock.patch("core.logic.imou.fetch_snapshot", return_value=_jpeg()):
            return APIClient().post("/api/v1/shop/imou/callback/%s" % self.tok, json.dumps(msg),
                                    content_type="application/json")

    def test_person_alert_with_latency(self):
        from core.models import ShopCamera, ShopEvent
        msg = dict(CAPABILITY_HUMAN, time=int(time.time()) - 3)
        r = self.post(msg)
        self.assertEqual(r.status_code, 200)
        ev = r.data["events"][0]
        self.assertTrue(ev["raised"])
        self.assertGreaterEqual(ev["latency_s"], 2.0)
        self.assertLess(ev["latency_s"], 60.0)
        lat = ShopCamera.objects.get(pk=self.cam_id).compat["imou_latency_s"]
        self.assertEqual(len(lat), 1)
        self.assertEqual(ShopEvent.objects.count(), 1)
        # Imou re-sends the same alarmId: no second alert
        self.assertEqual(self.post(msg).data["events"][0]["ignored"], "duplicate")

    def test_other_app_refused(self):
        r = self.post(dict(CAPABILITY_HUMAN, appId="someoneelse", alarmId="z1"))
        self.assertEqual(r.data["events"][0]["ignored"], "other_app")


# ------------------------------------------------------------------ 7
class VendorCheckTests(TestCase):
    def test_callback_state(self):
        from core.management.commands.cctv_vendor_check import callback_state
        self.assertEqual(callback_state("http://localhost/api/v1/shop/imou/callback/x"), "localhost")
        self.assertEqual(callback_state("https://api.example.test/api/v1/cb/x"), "https")
        self.assertEqual(callback_state(""), "none")

    def test_imou_ready_codes_only(self):
        from core.management.commands import cctv_vendor_check as VC
        I.save("imou", {"app_id": "imid", "app_secret": "SuperSecret99"})
        IM._token_cache.clear()
        h = _ImouHttp({"deviceBaseList": ok({"deviceList": [{"deviceId": "D1"}]})})
        with mock.patch.object(IMA.ImouAdapter, "client",
                               lambda self: IM.ImouClient("imid", "SuperSecret99", http=h)):
            row = VC.check("imou")
        self.assertEqual((row["keys"], row["token"], row["devices"]), ("set", "OK", "OK 1"))
        self.assertNotIn("SuperSecret99", json.dumps(row))
        self.assertNotIn("At_", json.dumps(row))                 # never a token

    def test_imou_failure_turns_card_red(self):
        from django.utils import timezone
        from core.management.commands import cctv_vendor_check as VC
        from core.models import Integration
        I.save("imou", {"app_id": "imid", "app_secret": "SuperSecret99"})
        Integration.objects.filter(slug="imou").update(status="working", last_tested=timezone.now())
        IM._token_cache.clear()

        def http(url, body, t):
            return 200, json.dumps({"result": {"code": "SN1001", "msg": "x"}})
        with mock.patch.object(IMA.ImouAdapter, "client",
                               lambda self: IM.ImouClient("imid", "SuperSecret99", http=http)):
            row = VC.check("imou")
        self.assertEqual(row["token"], "FAIL SN1001")
        r = [x for x in I.list_all("en") if x["slug"] == "imou"][0]
        self.assertEqual(r["status"], "failing")

    def test_missing_keys(self):
        from core.management.commands import cctv_vendor_check as VC
        self.assertEqual(VC.check("hikconnect")["keys"], "missing")


# ------------------------------------------------------------------ 8
class CustomerPathTests(TestCase):
    """imou-real (owner 17 Nov): the CUSTOMER app path. Serial + code stays
    owner/admin-only until the owner's per-vendor switch; the app is told
    what to remove first; an approved no-delete path leads only when its
    switch is on."""

    def setUp(self):
        from django.contrib.auth import get_user_model
        U = get_user_model()
        self.cust = U.objects.create_user(name="Customer", phone="01710009001", password="pw")
        self.staff = U.objects.create_user(name="Admin", phone="01710009002", password="pw")
        self.staff.is_staff = True
        self.staff.save()

    def row(self, pid, user):
        from core import cctv_connect_views as V
        return V.provider_row(pid, user)

    def test_imou_customer_gate_and_guide(self):
        I.save("imou", {"app_id": "imid", "app_secret": "ims"})
        self.assertEqual(self.row("imou", self.cust)["modes"], [])          # closed today
        r = self.row("imou", self.staff)
        self.assertEqual((r["modes"], r["before"], r["no_delete"], r["lead"]),
                         (["device_code"], "imou_life", False, False))
        I.save("imou", {"devbind_customers": "on"})
        self.assertEqual(self.row("imou", self.cust)["modes"], ["device_code"])

    def test_ezviz_now_has_a_customer_switch(self):
        self.assertIn("devbind_customers", [f["key"] for f in I.REGISTRY["ezviz"]["fields"]])
        I.save("ezviz", {"app_key": "ezk", "app_secret": "ezs"})
        self.assertEqual(self.row("ezviz", self.cust)["modes"], [])
        I.save("ezviz", {"devbind_customers": "on"})
        r = self.row("ezviz", self.cust)
        self.assertEqual((r["modes"], r["before"]), (["device_code"], "ezviz_app"))

    def test_no_delete_path_leads_only_with_switch_and_approval(self):
        oauth = {"app_id": "imid", "app_secret": "ims", "oauth_ak": "imak", "oauth_sk": "imsk",
                 "oauth_h5_url": "https://open.imoulife.com/oauth/h5?project=sim"}
        I.save("imou", dict(oauth, no_delete_default="on"))
        r = self.row("imou", self.cust)
        self.assertEqual((r["modes"], r["no_delete"], r["lead"]), (["oauth"], True, True))
        I.save("imou", {"no_delete_default": "off"})
        self.assertFalse(self.row("imou", self.cust)["lead"])
        # switch on but NOT approved (no OAuth keys): never leads
        from core.models import Integration
        Integration.objects.filter(slug="imou").delete()
        I.save("imou", {"app_id": "imid", "app_secret": "ims", "no_delete_default": "on"})
        r = self.row("imou", self.staff)
        self.assertEqual((r["no_delete"], r["lead"]), (False, False))
        for slug in ("imou", "ezviz", "dolynk_arc"):
            self.assertIn("no_delete_default", [f["key"] for f in I.REGISTRY[slug]["fields"]])


# ------------------------------------------------------------------ 9
class ReregisterFlagsTests(TestCase):
    """imou-real: `cctv_callback_rotate --vendor imou` (callback_links.
    reregister) must subscribe capabilityEvent too (person / motion on
    current Imou models), keeping numberstat when the account offers it."""

    def test_rotate_registers_capability_event(self):
        from core import callback_links as CL
        I.save("imou", {"app_id": "imid", "app_secret": "ims"})
        IM._token_cache.clear()
        h = _ImouHttp({"setMessageCallback": ok()})
        with mock.patch.object(IMA.ImouAdapter, "client",
                               lambda self: IM.ImouClient("imid", "ims", http=h)):
            self.assertEqual(CL.reregister("imou"), "registered")
        flags = dict(h.calls)["setMessageCallback"]["callbackFlag"].split(",")
        self.assertEqual(set(flags), {"alarm", "deviceStatus", "capabilityEvent", "numberstat"})
