"""CCTV watchman — vendor cloud / camera-push paths, end to end through the
REAL code with only the vendor HTTP layer mocked (CI-safe, no secrets).

  * Imou Open Platform: link (accessToken -> bindDevice -> deviceOnline ->
    setMessageCallback, every request signed md5(time,nonce,appSecret)) ->
    alarm callback -> ONE still downloaded from the Imou CDN -> alert + FCM ->
    repeat alarm GROUPED (count 2, no second push) -> owner feedback adapts the
    camera -> privacy-mode / status messages ignored -> video refused.
    Payload fields (msgType videoMotion|human, did, cid, cname, time, alarmId,
    picurlArray) follow Imou's message-callback push as used by the Home
    Assistant imou_life integration; newer PTZs send
    msgType "e_multiVideoAiPerArea" for a person.
  * Hikvision ISAPI "HTTP Listening": multipart EventNotificationAlert XML +
    JPEG (Hikvision ISAPI developer guide, Event Notification), AcuSense
    detectionTarget=human, the 10-second videoloss/inactive heartbeat, the
    burst dedupe, Video Tampering (shelteralarm).
  * Dahua eventManager push: CrossLineDetection Start (JSON) and the
    "Code=...;action=Start" text form.
  * The Shop Box edge client's real HTTP payload (shopbox.payload) for a
    gateway camera checked from the app carries the SERVER camera id, so the
    alert is attributed to that camera.
The full real-socket harness (real RTSP stream, ONVIF simulator, YOLOX on the
edge, runserver, mock FCM) is tools/e2e/cctv_e2e.sh.
"""
import io
import json
import os
import shutil
import sys
import tempfile
from unittest import mock

from django.test import override_settings
from rest_framework.test import APIClient, APITestCase

from core.models import User

_MEDIA = tempfile.mkdtemp(prefix="e2e-cctv-media-")
FF_KEY = "home_watchman"


def _jpeg(w=800, h=450, color=(30, 80, 140)):
    from PIL import Image
    b = io.BytesIO()
    Image.new("RGB", (w, h), color).save(b, "JPEG")
    return b.getvalue()


MP4 = b"\x00\x00\x00\x18ftypmp42\x00\x00\x00\x00mp42isom" + b"\x00" * 2048


class _Raw(io.BytesIO):
    def read(self, n=-1, decode_content=False):      # urllib3 HTTPResponse.read
        return super().read(n)


class _Resp:
    def __init__(self, status, body=b"", ctype="image/jpeg"):
        self.status_code = status
        self.headers = {"Content-Type": ctype}
        self.raw = _Raw(body)


@override_settings(MEDIA_ROOT=_MEDIA)
class _Base(APITestCase):
    @classmethod
    def tearDownClass(cls):
        super().tearDownClass()
        shutil.rmtree(_MEDIA, ignore_errors=True)
        os.makedirs(_MEDIA, exist_ok=True)

    def setUp(self):
        self.owner = User.objects.create_user(name="Rahim", phone="01710003001",
                                              password="pw")
        self.owner.ai_credits = 500
        self.owner.language = "en"
        self.owner.save()
        self.family = User.objects.create_user(name="Karima", phone="01710003002",
                                               password="pw")
        self.family.language = "bn"
        self.family.save()
        self.client.force_authenticate(self.owner)
        self.pushes = []
        p = mock.patch("core.push.safe_push",
                       side_effect=lambda *a, **k: self.pushes.append((a, k)) or True)
        p.start()
        self.addCleanup(p.stop)
        from core import feature_flags as FF
        from core.models import FeatureFlag
        FF.ensure_seeded()
        FeatureFlag.objects.filter(key=FF_KEY).update(enabled_all=True,
                                                     enabled_play=True)
        FF.invalidate()
        self.addCleanup(FF.invalidate)
        r = self.client.post("/api/v1/shop/watchman/setup",
                             {"kind": "home", "gateway": "pc", "name": "Home"},
                             format="json")
        self.assertEqual(r.status_code, 201, r.data)
        self.site = r.data
        r = self.client.post("/api/v1/shop/sites/%d/viewers" % self.site["id"],
                             {"phone": "01710003002"}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        self.pushes.clear()

    def add_camera(self, vendor, name):
        r = self.client.post("/api/v1/shop/sites/%d/cameras" % self.site["id"],
                             {"name": name, "kind": "shopbox", "vendor": vendor,
                              "source": {"host": "192.168.1.64", "port": 554}},
                             format="json")
        self.assertEqual(r.status_code, 201, r.data)
        return r.data

    def shop_pushes(self):
        return [k for a, k in self.pushes if a[1] == "shop_alert"]


# ============================================================== Imou cloud
class ImouCloudE2ETests(_Base):
    APP_ID, SECRET = "test-app", "test-secret"

    def setUp(self):
        super().setUp()
        from core.logic import imou as IM
        IM._token_cache.clear()
        self.cam = self.add_camera("imou", "Gate (Imou)")
        self.calls = []
        self.bound = set()

    def imou_http(self, url, body, timeout):
        """The Imou Open API v1 as documented: every call is signed; answers
        {"result": {"code": "0", "data": ...}}."""
        import hashlib
        from urllib.parse import urlparse
        method = urlparse(url).path.rsplit("/", 1)[1]
        req = json.loads(body)
        sysd = req["system"]
        want = hashlib.md5(("time:%d,nonce:%s,appSecret:%s" % (
            sysd["time"], sysd["nonce"], self.SECRET)).encode()).hexdigest()
        if sysd["sign"] != want or sysd["appId"] != self.APP_ID:
            return 200, json.dumps({"result": {"code": "SN1001", "msg": "sign error"}})
        self.calls.append((method, req["params"]))
        data = {}
        if method == "accessToken":
            data = {"accessToken": "At_e2e_000", "expireTime": 259200}
        elif method == "bindDevice":
            if req["params"].get("code") != "L2C3D4":
                return 200, json.dumps({"result": {"code": "DV1007",
                                                   "msg": "device code error"}})
            self.bound.add(req["params"]["deviceId"])
        elif method == "deviceOnline":
            if req["params"]["deviceId"] not in self.bound:
                return 200, json.dumps({"result": {"code": "DV1003",
                                                   "msg": "device not belong to user"}})
            data = {"onLine": "1"}
        elif method == "setDeviceSnapEnhanced":
            data = {"url": "https://lechangecloud.easy4ip.com/snap/1.jpg"}
        return 200, json.dumps({"result": {"code": "0", "msg": "success", "data": data}})

    def link(self, code="L2C3D4"):
        from core.logic import imou as IM
        client = IM.ImouClient(self.APP_ID, self.SECRET, http=self.imou_http)
        with mock.patch("core.watchman_views.imou_cloud_on", return_value=True), \
                mock.patch("core.logic.imou.ImouClient.from_integration",
                           return_value=client):
            return self.client.post("/api/v1/shop/cameras/%d/imou" % self.cam["id"],
                                    {"device_serial": "7j0a8b9c", "safety_code": code},
                                    format="json")

    def callback(self, msg, pic=None):
        from core.logic import imou as IM
        tok = IM.callback_token(self.APP_ID, "x")
        cdn = _Resp(200, pic if pic is not None else _jpeg())
        with mock.patch("core.watchman_views.imou_cloud_on", return_value=True), \
                mock.patch("core.integrations.get",
                           return_value={"app_id": self.APP_ID, "app_secret": self.SECRET}), \
                mock.patch("core.logic.imou.callback_token", return_value=tok), \
                mock.patch("requests.get", return_value=cdn) as get:
            r = APIClient().post("/api/v1/shop/imou/callback/%s" % tok, json.dumps(msg),
                                 content_type="application/json")
        return r, get

    @staticmethod
    def alarm(mtype="human", alarm_id="1001", pic="https://lechangecloud.easy4ip.com/a/1.jpg"):
        return {"msgType": mtype, "did": "7J0A8B9C", "cid": "0", "cname": "Gate",
                "time": 1793080800, "alarmId": alarm_id, "type": 1,
                "picurlArray": [pic]}

    def test_link_alarm_snapshot_alert_group_feedback(self):
        from core.models import FamilyAlert, ShopCamera, ShopEvent
        r = self.link()
        self.assertEqual(r.status_code, 200, r.data)
        methods = [m for m, _ in self.calls]
        for m in ("accessToken", "bindDevice", "setMessageCallback"):
            self.assertIn(m, methods)
        cb = dict(self.calls[methods.index("setMessageCallback")][1])
        self.assertIn("/api/v1/shop/imou/callback/", cb["callbackUrl"])
        self.assertIn("alarm", cb["callbackFlag"])
        cam = ShopCamera.objects.get(pk=self.cam["id"])
        self.assertEqual(cam.vendor_ref, "7J0A8B9C:0")
        self.assertNotIn("L2C3D4", json.dumps([cam.source, cam.compat, cam.device_info]))

        r, get = self.callback(self.alarm())
        self.assertEqual(r.status_code, 200, r.data)
        self.assertTrue(r.data["events"][0]["raised"])
        get.assert_called_once()
        self.assertEqual(get.call_args[0][0], "https://lechangecloud.easy4ip.com/a/1.jpg")
        ev = ShopEvent.objects.get()
        self.assertEqual((ev.type, ev.camera_id), ("camera_alarm", self.cam["id"]))
        self.assertGreaterEqual(ev.confidence, 0.6)           # human, armed
        self.assertTrue(ev.snapshot)
        from PIL import Image
        self.assertLessEqual(max(Image.open(ev.snapshot.path).size), 640)
        self.assertEqual(FamilyAlert.objects.filter(kind="shop_guard").count(), 2)
        pushes = self.shop_pushes()
        self.assertEqual(len(pushes), 2)
        self.assertIn("/api/v1/m/", pushes[0]["data"]["snapshot_url"])
        self.assertEqual(pushes[0]["data"]["route"], "watchman")
        # the signed link works without auth, a tampered one does not
        url = pushes[0]["data"]["snapshot_url"]
        path = url[url.index("/api/v1/m/"):]
        self.assertEqual(APIClient().get(path).status_code, 200)
        self.assertEqual(APIClient().get(path.replace("s=", "s=0")).status_code, 404)

        # the same alarm again inside the group window -> same alert, no push
        r, _ = self.callback(self.alarm(alarm_id="1002"))
        self.assertTrue(r.data["events"][0]["grouped"])
        ev.refresh_from_db()
        self.assertEqual((ShopEvent.objects.count(), ev.count), (1, 2))
        self.assertEqual(len(self.shop_pushes()), 2)

        # owner feedback: Correct keeps the defaults (never more sensitive)
        m = self.client.post("/api/v1/shop/events/%d/mark" % ev.id,
                             {"status": "correct"}, format="json")
        self.assertEqual(m.status_code, 200, m.data)
        self.assertEqual(m.data["verdict"] if "verdict" in m.data else "correct", "correct")
        cam.refresh_from_db()
        self.assertAlmostEqual(float((cam.tuning or {}).get("person_conf", 0.45)), 0.45)

    def test_motion_vs_person_and_non_alarms(self):
        from core.models import ShopEvent
        self.assertEqual(self.link().status_code, 200)
        r, _ = self.callback(self.alarm(mtype="videoMotion"))
        self.assertTrue(r.data["events"][0]["raised"])
        ev = ShopEvent.objects.get()
        self.assertTrue(ev.possible)                  # plain motion: low confidence
        # privacy-mode toggles and status are NOT alarms (were false alerts)
        for mt in ("openCamera", "closeCamera", "deviceStatus", "online"):
            r, _ = self.callback({"msgType": mt, "did": "7J0A8B9C", "cid": "0"})
            self.assertEqual(r.data["events"][0], {"ignored": "not_alarm"}, mt)
        self.assertEqual(ShopEvent.objects.count(), 1)

    def test_new_ptz_person_type_counts_as_human(self):
        from core.logic import imou as IM
        a = IM.parse_alarm(self.alarm(mtype="e_multiVideoAiPerArea"))
        self.assertTrue(a["human"])
        self.assertFalse(IM.parse_alarm(self.alarm(mtype="videoMotion"))["human"])

    def test_cdn_video_or_foreign_host_is_never_stored(self):
        from core.models import ShopEvent
        self.assertEqual(self.link().status_code, 200)
        r, _ = self.callback(self.alarm(), pic=MP4)
        self.assertTrue(r.data["events"][0]["raised"])
        self.assertFalse(ShopEvent.objects.get().snapshot)         # no video kept
        ShopEvent.objects.all().delete()
        r, get = self.callback(self.alarm(pic="https://169.254.169.254/latest/x.jpg"))
        get.assert_not_called()                                   # SSRF guard
        self.assertFalse(ShopEvent.objects.get().snapshot)

    def test_wrong_safety_code_is_explained(self):
        r = self.link(code="WRONG1")
        self.assertEqual(r.status_code, 502, r.data)
        self.assertEqual(r.data["error"], "imou_error")


# ============================================================== Hikvision
HIK = ('<?xml version="1.0" encoding="UTF-8"?>\r\n<EventNotificationAlert version="2.0" '
       'xmlns="http://www.hikvision.com/ver20/XMLSchema"><ipAddress>192.168.1.64</ipAddress>'
       '<portNo>80</portNo><protocol>HTTP</protocol><macAddress>bc:ad:28:00:00:01'
       '</macAddress><channelID>1</channelID><dateTime>2026-10-27T10:00:00+06:00'
       '</dateTime><activePostCount>1</activePostCount><eventType>%s</eventType>'
       '<eventState>%s</eventState><eventDescription>%s alarm</eventDescription>%s'
       '</EventNotificationAlert>')
ACUSENSE = ('<DetectionRegionList><DetectionRegionEntry><regionID>1</regionID>'
            '<sensitivityLevel>50</sensitivityLevel><detectionTarget>human'
            '</detectionTarget></DetectionRegionEntry></DetectionRegionList>')


def hik_multipart(xml, image, part="linedetection"):
    b = "MIME_boundary"
    body = (('--%s\r\nContent-Disposition: form-data; name="%s"\r\n'
             'Content-Type: application/xml; charset="UTF-8"\r\nContent-Length: %d\r\n\r\n'
             '%s\r\n--%s\r\nContent-Disposition: form-data; name="%sPicture"; '
             'filename="%sPicture.jpg"\r\nContent-Type: image/jpeg\r\nContent-Length: %d'
             '\r\n\r\n') % (b, part, len(xml), xml, b, part, part, len(image))
            ).encode() + image + ("\r\n--%s--\r\n" % b).encode()
    return body, "multipart/form-data; boundary=" + b


class HikvisionDahuaE2ETests(_Base):
    def setUp(self):
        super().setUp()
        self.hik = self.add_camera("hikvision", "Shop door")
        self.dahua = self.add_camera("dahua", "Back door")
        self.dev = APIClient()

    def hook(self, vendor, token, body, ctype):
        return self.dev.generic("POST", "/api/v1/shop/hook/%s/%s" % (vendor, token),
                                body, content_type=ctype)

    def test_isapi_acusense_alarm_snapshot_heartbeat_dedupe(self):
        from core.models import ShopEvent
        tok = self.hik["camera_token"]
        hb = self.hook("hikvision", tok, HIK % ("videoloss", "inactive", "videoloss", ""),
                       "application/xml")
        self.assertEqual((hb.status_code, hb.data["events"]), (200, []))
        body, ct = hik_multipart(HIK % ("linedetection", "active", "linedetection",
                                        ACUSENSE), _jpeg(1920, 1080))
        r = self.hook("hikvision", tok, body, ct)
        self.assertEqual(r.status_code, 200, r.data)
        self.assertTrue(r.data["events"][0]["raised"], r.data)
        ev = ShopEvent.objects.get()
        self.assertEqual(ev.camera_id, self.hik["id"])
        self.assertTrue(ev.signals["inputs"].get("human"))
        self.assertTrue(ev.snapshot)
        from PIL import Image
        self.assertLessEqual(max(Image.open(ev.snapshot.path).size), 640)
        self.assertEqual(len(self.shop_pushes()), 2)               # owner + viewer
        again = self.hook("hikvision", tok, body, ct)
        self.assertTrue(again.data["events"][0]["dedupe"])
        self.assertEqual(ShopEvent.objects.count(), 1)
        self.assertEqual(len(self.shop_pushes()), 2)
        bad = self.hook("hikvision", "not-a-token", body, ct)
        self.assertEqual(bad.status_code, 401)

    def test_isapi_tamper_is_the_cameras_own_alarm(self):
        from core.models import ShopEvent
        r = self.hook("hikvision", self.hik["camera_token"],
                      HIK % ("shelteralarm", "active", "shelteralarm", ""),
                      "application/xml")
        self.assertTrue(r.data["events"][0]["raised"], r.data)
        ev = ShopEvent.objects.get()
        self.assertEqual(ev.type, "camera_alarm")
        self.assertTrue(ev.signals["inputs"].get("tamper"))

    def test_isapi_video_part_is_never_stored(self):
        from core.models import ShopEvent
        body, ct = hik_multipart(HIK % ("fielddetection", "active", "fielddetection", ""),
                                 MP4)
        r = self.hook("hikvision", self.hik["camera_token"], body, ct)
        self.assertEqual(r.status_code, 200)
        self.assertFalse(ShopEvent.objects.get().snapshot)

    def test_dahua_json_and_text_push(self):
        from core.models import ShopEvent
        r = self.hook("dahua", self.dahua["camera_token"], json.dumps(
            {"Code": "CrossLineDetection", "Action": "Start", "Index": 0,
             "Data": {"LocaleTime": "2026-10-27 10:00:00", "Name": "Rule1",
                      "Object": {"ObjectType": "Human"}}}), "application/json")
        self.assertTrue(r.data["events"][0]["raised"], r.data)
        self.assertTrue(ShopEvent.objects.get().signals["inputs"].get("human"))
        stop = self.hook("dahua", self.dahua["camera_token"],
                         "Code=CrossLineDetection;action=Stop;index=0", "text/plain")
        self.assertEqual(stop.data["events"], [])


# ============================================================== Shop Box edge
class EdgePayloadAttributionTests(_Base):
    """The edge client's REAL request body (shopbox.payload) for a camera the
    owner added + checked from the app (site token, no per-camera token)."""

    def test_gateway_camera_alert_is_attributed_to_that_camera(self):
        from core.models import ShopEvent
        edge = os.path.join(os.path.dirname(__file__), "..", "..", "edge", "shopbox")
        sys.path.insert(0, os.path.abspath(edge))
        self.addCleanup(lambda: sys.path.remove(os.path.abspath(edge)))
        from shopbox import payload as P
        cam = self.add_camera("rtsp", "Gate")
        evt = P.build_event("person_detected", {"person": True, "conf": 0.8,
                                                "detector": "yolox_nano"},
                            camera_id="srv%d" % cam["id"], at=None)
        evt["server_camera_id"] = cam["id"]
        _t, form, files = P.build_request(evt, site_token=self.site["enrollment_token"],
                                          camera_token=None, snapshot=_jpeg(),
                                          snapshot_mode="always")
        from django.core.files.uploadedfile import SimpleUploadedFile
        data = dict(form)
        data["snapshot"] = SimpleUploadedFile(*files["snapshot"])
        r = APIClient().post("/api/v1/shop/ingest", data, format="multipart")
        self.assertEqual(r.status_code, 201, r.data)
        ev = ShopEvent.objects.get()
        self.assertEqual(ev.camera_id, cam["id"])
        self.assertEqual(self.shop_pushes()[0]["data"]["camera_name"], "Gate")
