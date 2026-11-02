"""cctv100 — CCTV protocol TRACES through the real parsers and views.

Every fixture lives in core/testdata/cctv_traces/ and its source (public
vendor document / open-source integration) is written in SOURCES.json. The
structure follows those documents; values are synthetic — NOT captured from a
real camera yet (the owner's real-device run adds captured traces).

Covers: Hikvision ISAPI EventNotificationAlert (ver10 + ver20 namespaces,
AcuSense 0..1 TargetRect, older 0..1000 TargetRect, videoloss heartbeat,
shelteralarm tamper, the multipart form Hik firmware posts); Dahua
eventManager attach (multipart/x-mixed-replace text, data={...} IVS JSON with
BoundingBox); Imou Open Platform message callbacks (human, AI-person, status,
duplicate re-send, picture on a foreign host); EZVIZ alarm/device/list
(encrypted picture, lower-case serial, channel filter); and a gateway check
result that must not wipe the server's own camera bookkeeping.
"""
import json
import os
from datetime import datetime
from django.test import SimpleTestCase
from rest_framework.test import APIClient

from core import tests_e2e_cctv as E2E
from core import tests_watchman as TW
from core.logic import camera_hooks as CH

TRACES = os.path.join(os.path.dirname(__file__), "testdata", "cctv_traces")


def trace(name):
    with open(os.path.join(TRACES, name), "rb") as f:
        return f.read()


def hik_multipart(xml, jpeg, boundary="MIME_boundary"):
    """The multipart form Hikvision HTTP Listening posts with "upload picture"
    on: an XML part named after the event + a JPEG part (CRLF, quoted names)."""
    b = boundary.encode()
    body = (b"--" + b + b"\r\nContent-Disposition: form-data; name=\"linedetection\"; "
            b"filename=\"linedetection.xml\"\r\nContent-Type: application/xml\r\n"
            b"Content-Length: " + str(len(xml)).encode() + b"\r\n\r\n" + xml + b"\r\n"
            b"--" + b + b"\r\nContent-Disposition: form-data; name=\"linedetectionImage\"; "
            b"filename=\"linedetectionImage.jpg\"\r\nContent-Type: image/jpeg\r\n"
            b"Content-Length: " + str(len(jpeg)).encode() + b"\r\n\r\n" + jpeg + b"\r\n"
            b"--" + b + b"--\r\n")
    return "multipart/form-data; boundary=" + boundary, body


class TraceSourcesTests(SimpleTestCase):
    def test_every_fixture_names_its_source(self):
        src = json.loads(trace("SOURCES.json"))
        files = sorted(f for f in os.listdir(TRACES) if f != "SOURCES.json")
        self.assertTrue(files)
        for f in files:
            self.assertIn(f, src, "fixture without a written source: " + f)
            self.assertGreater(len(src[f]), 20)
        self.assertIn("synthetic", src["_note"])


class HikvisionTraceTests(SimpleTestCase):
    DAY = datetime(2026, 11, 2, 14, 0)
    NIGHT = datetime(2026, 11, 2, 23, 0)
    HOURS = {"hours": {"open": "09:00", "close": "22:00"}}

    def test_acusense_ver20_human_with_box(self):
        evs = CH.parse_hikvision('application/xml; charset="UTF-8"',
                                 trace("hik_linedetection_acusense_ver20.xml"))
        self.assertEqual(len(evs), 1)
        ev = evs[0]
        self.assertEqual((ev["event"], ev["active"], ev["channel"], ev["target"]),
                         ("linedetection", True, "1", "human"))
        self.assertEqual(ev["at"], "2026-11-02T22:41:07+06:00")
        self.assertEqual(ev["box"], (0.412, 0.288, 0.53, 0.69))
        t, sig = CH.map_event(ev, self.HOURS, self.NIGHT)
        self.assertEqual(t, "after_hours")
        self.assertTrue(sig["human"])
        t, sig = CH.map_event(ev, self.HOURS, self.DAY)
        self.assertEqual((t, sig.get("zone_breach")), ("motion", True))

    def test_box_in_cash_zone_becomes_cash_event(self):
        ev = CH.parse_hikvision("application/xml",
                                trace("hik_linedetection_acusense_ver20.xml"))[0]
        zc = dict(self.HOURS, zones=[{"type": "cash", "points": [
            [0.35, 0.2], [0.7, 0.2], [0.7, 0.8], [0.35, 0.8]]}])
        self.assertTrue(CH._cash_zone(zc))
        t, sig = CH.map_event(ev, zc, self.DAY)
        self.assertEqual(t, "hand_in_cash_zone")
        self.assertTrue(sig["camera_box_in_zone"])

    def test_old_firmware_1000_scale_box(self):
        ev = CH.parse_hikvision("application/xml",
                                trace("hik_fielddetection_rect1000_ver20.xml"))[0]
        self.assertEqual(ev["event"], "fielddetection")
        self.assertEqual(ev["box"], (0.3, 0.5, 0.45, 0.8))

    def test_heartbeat_is_dropped(self):
        evs = CH.parse_hikvision("application/xml", trace("hik_videoloss_heartbeat_ver10.xml"))
        self.assertEqual((evs[0]["event"], evs[0]["active"]), ("videoloss", False))
        self.assertIsNone(CH.map_event(evs[0], self.HOURS, self.NIGHT))

    def test_tamper(self):
        ev = CH.parse_hikvision("application/xml", trace("hik_shelteralarm_ver20.xml"))[0]
        t, sig = CH.map_event(ev, self.HOURS, self.NIGHT)
        self.assertEqual(t, "camera_alarm")
        self.assertTrue(sig["tamper"])

    def test_multipart_with_picture(self):
        ctype, body = hik_multipart(trace("hik_linedetection_acusense_ver20.xml"),
                                    E2E._jpeg())
        evs = CH.parse_hikvision(ctype, body)
        self.assertEqual(evs[0]["event"], "linedetection")
        self.assertTrue(evs[0]["image"].startswith(b"\xff\xd8"))
        self.assertEqual(evs[0]["box"], (0.412, 0.288, 0.53, 0.69))

    def test_new_codes(self):
        day = self.DAY
        self.assertEqual(CH.map_event({"event": "regionexiting", "active": True},
                                      self.HOURS, day)[0], "motion")
        self.assertEqual(CH.map_event({"event": "pir", "active": True},
                                      self.HOURS, self.NIGHT)[1].get("after_hours"), True)


class DahuaTraceTests(SimpleTestCase):
    def test_attach_stream_multipart(self):
        evs = CH.parse_dahua("multipart/x-mixed-replace; boundary=myboundary",
                             trace("dahua_attach_videomotion.mime"))
        self.assertEqual([(e["event"], e["active"], e["channel"]) for e in evs],
                         [("videomotion", True, "0"), ("videomotion", False, "0")])

    def test_attach_with_ivs_data_block(self):
        evs = CH.parse_dahua("text/plain", trace("dahua_attach_crossline_data.txt"))
        self.assertEqual([(e["event"], e["active"]) for e in evs],
                         [("crosslinedetection", True), ("crosslinedetection", False)])
        start = evs[0]
        self.assertEqual(start["target"], "human")
        self.assertEqual(start["at"], "2026-11-02 23:10:05")
        x1, y1, x2, y2 = start["box"]
        self.assertAlmostEqual(x1, 3277 / 8191.0, places=3)
        self.assertAlmostEqual(y2, 6144 / 8191.0, places=3)
        t, sig = CH.map_event(start, {"hours": {"open": "09:00", "close": "22:00"}},
                              datetime(2026, 11, 2, 23, 10))
        self.assertEqual(t, "after_hours")
        self.assertTrue(sig["human"])

    def test_broken_data_block_keeps_event(self):
        evs = CH.parse_dahua("text/plain",
                             b"Code=CrossLineDetection;action=Start;index=2;data={ broken\n")
        self.assertEqual((evs[0]["event"], evs[0]["active"], evs[0]["channel"],
                          evs[0]["box"]), ("crosslinedetection", True, "2", None))

    def test_smart_motion_human(self):
        evs = CH.parse_dahua("text/plain", b"Code=SmartMotionHuman;action=Start;index=0\r\n")
        t, sig = CH.map_event(evs[0], {}, datetime(2026, 11, 2, 12, 0))
        self.assertEqual(t, "motion")
        self.assertTrue(sig["human"])


class HookViewTraceTests(E2E._Base):
    def test_hik_multipart_trace_raises_one_alert_and_heartbeat_none(self):
        from core.models import ShopCamera, ShopEvent
        cam = self.add_camera("hikvision", "Counter (Hik)")
        tok = ShopCamera.objects.get(pk=cam["id"]).camera_token
        url = "/api/v1/shop/hook/hikvision/%s" % tok
        hb = APIClient().post(url, trace("hik_videoloss_heartbeat_ver10.xml"),
                              content_type="application/xml")
        self.assertEqual((hb.status_code, hb.data["events"]), (200, []))
        self.assertEqual(ShopEvent.objects.count(), 0)
        ctype, body = hik_multipart(trace("hik_shelteralarm_ver20.xml"), E2E._jpeg())
        r = APIClient().generic("POST", url, body, content_type=ctype)
        self.assertEqual(r.status_code, 200, r.data)
        self.assertTrue(r.data["events"][0]["raised"])
        ev = ShopEvent.objects.get()
        self.assertTrue(ev.snapshot)
        self.assertNotIn("theft", json.dumps(self.shop_pushes()).lower())

    def test_dahua_text_trace(self):
        from core.models import ShopCamera
        cam = self.add_camera("dahua", "Back door (Dahua)")
        tok = ShopCamera.objects.get(pk=cam["id"]).camera_token
        r = APIClient().generic("POST", "/api/v1/shop/hook/dahua/%s" % tok,
                                trace("dahua_attach_crossline_data.txt"),
                                content_type="text/plain")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(len(r.data["events"]), 1)          # Stop is dropped


class ImouTraceTests(E2E._Base):
    """Borrows the signed fake Imou Open API + helpers from the E2E module
    (functions only — its own tests are not re-run here)."""
    APP_ID = E2E.ImouCloudE2ETests.APP_ID
    SECRET = E2E.ImouCloudE2ETests.SECRET

    def setUp(self):
        super().setUp()
        from core.logic import imou as IM
        IM._token_cache.clear()
        self.cam = self.add_camera("imou", "Gate (Imou)")
        self.calls = []
        self.bound = set()

    imou_http = E2E.ImouCloudE2ETests.imou_http
    link = E2E.ImouCloudE2ETests.link
    callback = E2E.ImouCloudE2ETests.callback

    def _linked(self):
        r = self.link()
        self.assertEqual(r.status_code, 200, r.data)

    def test_human_trace_then_duplicate_resend_is_ignored(self):
        from core.models import ShopCamera, ShopEvent
        self._linked()
        msg = json.loads(trace("imou_callback_human.json"))
        msg["did"] = "7J0A8B9C"                       # the linked test device
        r, get = self.callback(msg)
        self.assertTrue(r.data["events"][0]["raised"], r.data)
        get.assert_called_once()
        n_push = len(self.shop_pushes())
        r, get = self.callback(msg)                   # Imou re-sends the same alarmId
        self.assertEqual(r.data["events"][0], {"ignored": "duplicate"})
        get.assert_not_called()
        self.assertEqual(len(self.shop_pushes()), n_push)
        ev = ShopEvent.objects.get()
        self.assertEqual(ev.count, 1)
        cam = ShopCamera.objects.get(pk=self.cam["id"])
        self.assertEqual(cam.compat["imou_seen_ids"], ["8051237769"])

    def test_ai_person_trace_is_human(self):
        from core.logic import imou as IM
        a = IM.parse_alarm(json.loads(trace("imou_callback_aiper.json")))
        self.assertTrue(a["human"])
        self.assertTrue(a["pic"].startswith("https://lechangecloud.easy4ip.com/"))

    def test_status_trace_is_not_an_alarm(self):
        self._linked()
        msg = json.loads(trace("imou_callback_status_online.json"))
        msg["did"] = "7J0A8B9C"
        r, get = self.callback(msg)
        self.assertEqual(r.data["events"], [{"ignored": "not_alarm"}])
        get.assert_not_called()

    def test_foreign_picture_host_refused_and_reported(self):
        from core.models import ShopCamera, ShopEvent
        self._linked()
        msg = json.loads(trace("imou_callback_foreign_pic.json"))
        msg["did"] = "7J0A8B9C"
        r, get = self.callback(msg)
        self.assertEqual(r.status_code, 200)
        get.assert_not_called()                       # SSRF guard: never downloaded
        self.assertTrue(r.data["events"][0]["raised"])  # the alarm itself still alerts
        self.assertFalse(ShopEvent.objects.get().snapshot)
        cam = ShopCamera.objects.get(pk=self.cam["id"])
        self.assertEqual(cam.compat["imou_pic_host_refused"],
                         "imou-alarm-ap.s3.ap-southeast-1.amazonaws.com")
        self.assertNotIn("Signature", json.dumps(cam.compat))


class EzvizTraceTests(SimpleTestCase):
    def test_alarm_list_rows(self):
        from core.logic import ezviz as EZ
        body = json.loads(trace("ezviz_alarm_device_list.json"))
        self.assertEqual(body["code"], "200")
        rows = [EZ.parse_alarm(r) for r in body["data"]]
        enc, ped = rows
        self.assertEqual((enc["serial"], enc["channel"], enc["human"]),
                         ("BD1234567", "1", False))
        self.assertIsNone(enc["pic"])                 # device-encrypted -> never fetched
        self.assertTrue(enc["encrypted_pic"])
        self.assertEqual(ped["serial"], "BD1234567")  # lower-case serial normalised
        self.assertTrue(ped["human"])
        self.assertEqual(ped["at_ms"], 1793726401000)
        self.assertTrue(ped["pic"].startswith("https://iot-alarm.ezvizlife.com/"))


class CompatBookkeepingTests(TW._Base):
    """A gateway compatibility check result must not wipe the server-owned
    keys (EZVIZ poll cursor, Imou duplicate guard, siren cooldown)."""

    def test_check_result_keeps_server_keys(self):
        from core.models import ShopCamera
        site = self.setup_home()
        cam = self.add_camera(site["id"])
        gw = self.dev(site["enrollment_token"])
        ShopCamera.objects.filter(pk=cam["id"]).update(compat={
            "cloud_last_alarm_ms": 1793726412000, "imou_seen_ids": ["1"],
            "siren_at": 1.0, "ok": False, "steps": []})
        r = self.client.post("/api/v1/shop/cameras/%d/check" % cam["id"],
                             {"secret": "L1ABCD", "host": "192.168.1.20", "channel": 1},
                             format="json")
        self.assertEqual(r.status_code, 201, r.data)
        tid = r.data["id"]
        gw.get("/api/v1/shop/gateway/tasks")
        res = {"ok": True, "steps": [{"key": "reachable", "ok": True, "code": "",
                                      "detail": ""}], "info": {}}
        r = gw.post("/api/v1/shop/gateway/tasks/%d/result" % tid,
                    {"result": json.dumps(res)}, format="multipart")
        self.assertEqual(r.status_code, 200, r.data)
        c = ShopCamera.objects.get(pk=cam["id"]).compat
        self.assertTrue(c["ok"])
        self.assertEqual(c["cloud_last_alarm_ms"], 1793726412000)
        self.assertEqual(c["imou_seen_ids"], ["1"])
        self.assertEqual(c["siren_at"], 1.0)

