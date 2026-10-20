"""Camera webhook adapters (Hikvision ISAPI / Dahua event push) → shop_guard."""
import io
import json
from datetime import datetime, time as dtime, timedelta

from django.utils import timezone
from rest_framework.test import APITestCase

from core.logic import camera_hooks as CH
from core.models import User

HIK_XML = b"""<?xml version="1.0" encoding="UTF-8"?>
<EventNotificationAlert version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">
<ipAddress>192.168.1.64</ipAddress><channelID>1</channelID>
<dateTime>2026-10-20T23:10:00+06:00</dateTime><activePostCount>1</activePostCount>
<eventType>%s</eventType><eventState>%s</eventState>
<eventDescription>Line crossing alarm</eventDescription>
</EventNotificationAlert>"""


def _jpeg(px=1280):
    from PIL import Image
    b = io.BytesIO()
    Image.new("RGB", (px, px // 2), (40, 90, 160)).save(b, "JPEG")
    return b.getvalue()


def _multipart(parts, boundary="assistoBOUNDARY"):
    out = b""
    for name, ctype, payload in parts:
        out += (b"--" + boundary.encode() + b"\r\n"
                b'Content-Disposition: form-data; name="' + name.encode() + b'"'
                + (b'; filename="' + name.encode() + b'.jpg"' if ctype.startswith("image/") else b"")
                + b"\r\nContent-Type: " + ctype.encode() + b"\r\n\r\n" + payload + b"\r\n")
    return "multipart/form-data; boundary=" + boundary, out + b"--" + boundary.encode() + b"--\r\n"


class CameraHookParserTests(APITestCase):
    def test_hikvision_xml(self):
        evs = CH.parse_hikvision("application/xml", HIK_XML % (b"linedetection", b"active"))
        self.assertEqual(len(evs), 1)
        self.assertEqual(evs[0]["event"], "linedetection")
        self.assertTrue(evs[0]["active"])
        self.assertEqual(evs[0]["channel"], "1")

    def test_hikvision_multipart_with_image(self):
        ctype, body = _multipart([
            ("linedetection", "application/xml", HIK_XML % (b"linedetection", b"active")),
            ("linedetectionImage", "image/jpeg", _jpeg())])
        evs = CH.parse_hikvision(ctype, body)
        self.assertEqual(evs[0]["event"], "linedetection")
        self.assertTrue(evs[0]["image"].startswith(b"\xff\xd8"))

    def test_hikvision_garbage_is_empty(self):
        self.assertEqual(CH.parse_hikvision("text/plain", b"hello"), [])
        self.assertEqual(CH.parse_hikvision("application/xml", b"<a><b/></a>"), [])

    def test_dahua_json_and_text(self):
        evs = CH.parse_dahua("application/json", json.dumps(
            {"Events": [{"Code": "CrossLineDetection", "Action": "Start", "Index": 0},
                        {"Code": "VideoMotion", "Action": "Stop", "Index": 1}]}).encode())
        self.assertEqual([e["event"] for e in evs], ["crosslinedetection", "videomotion"])
        self.assertEqual([e["active"] for e in evs], [True, False])
        evs = CH.parse_dahua("text/plain", b"Code=CrossRegionDetection;action=Start;index=0\r\n")
        self.assertEqual(evs[0]["event"], "crossregiondetection")
        self.assertTrue(evs[0]["active"])

    def test_after_hours_window(self):
        h = {"open": "09:00", "close": "22:00"}
        self.assertFalse(CH.is_after_hours(h, dtime(10, 0)))
        self.assertTrue(CH.is_after_hours(h, dtime(23, 0)))
        self.assertTrue(CH.is_after_hours(h, dtime(8, 59)))
        night = {"open": "18:00", "close": "06:00"}        # overnight shop
        self.assertFalse(CH.is_after_hours(night, dtime(2, 0)))
        self.assertTrue(CH.is_after_hours(night, dtime(12, 0)))
        self.assertFalse(CH.is_after_hours(None, dtime(3, 0)))

    def test_map_event(self):
        h = {"hours": {"open": "09:00", "close": "22:00"}}
        late, day = datetime(2026, 10, 20, 23, 0), datetime(2026, 10, 20, 12, 0)
        line = {"event": "linedetection", "active": True}
        self.assertEqual(CH.map_event(line, h, late)[0], "after_hours")
        t, sig = CH.map_event(line, h, day)
        self.assertEqual(t, "motion")
        self.assertTrue(sig["zone_breach"])
        t, sig = CH.map_event(line, dict(h, restricted_zone=False), day)
        self.assertNotIn("zone_breach", sig)
        self.assertIsNone(CH.map_event(dict(line, active=False), h, late))
        self.assertIsNone(CH.map_event({"event": "videoloss", "active": True}, h, late))
        t, sig = CH.map_event({"event": "vmd", "active": True}, h, day)
        self.assertEqual((t, sig.get("after_hours")), ("motion", None))


class CameraHookViewTests(APITestCase):
    def setUp(self):
        from core.models import ShopSite, ShopCamera
        self.owner = User.objects.create_user(name="Shop Owner", phone="01710000077",
                                              password="pw")
        self.owner.language = "en"
        self.owner.save()
        self.site = ShopSite.objects.create(owner=self.owner, name="Main Shop")
        # closed all day except a 1-minute window long ago → always after-hours
        now = timezone.localtime()
        o = (now - timedelta(hours=3)).strftime("%H:%M")
        c = (now - timedelta(hours=2)).strftime("%H:%M")
        self.cam = ShopCamera.objects.create(
            site=self.site, name="Back door",
            zone_config={"hours": {"open": o, "close": c}})

    def _post(self, vendor, ctype, body, token=None):
        return self.client.generic("POST", "/api/v1/shop/hook/%s/%s" % (
            vendor, token or self.cam.camera_token), body, content_type=ctype)

    def test_bad_token_401_and_unknown_vendor_401(self):
        self.assertEqual(self._post("hikvision", "application/xml", b"", "nope").status_code, 401)
        self.assertEqual(self._post("acme", "application/xml", b"").status_code, 401)

    def test_hikvision_after_hours_raises_once_with_small_snapshot(self):
        from core.models import ShopEvent, FamilyAlert
        ctype, body = _multipart([
            ("linedetection", "application/xml", HIK_XML % (b"linedetection", b"active")),
            ("linedetectionImage", "image/jpeg", _jpeg(1920))])
        r = self._post("hikvision", ctype, body)
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.data["events"][0]["raised"])
        ev = ShopEvent.objects.get(camera=self.cam)
        self.assertEqual(ev.type, "after_hours")
        from PIL import Image
        self.assertLessEqual(max(Image.open(ev.snapshot.path).size), 640)
        alert = FamilyAlert.objects.get(user=self.owner, kind="shop_guard")
        self.assertIn("Please check", alert.title)
        self.assertNotIn("theft", (alert.title + alert.body).lower())
        # the camera repeats "active" while the event lasts → deduped
        r2 = self._post("hikvision", ctype, body)
        self.assertTrue(r2.data["events"][0]["dedupe"])
        self.assertEqual(ShopEvent.objects.filter(camera=self.cam).count(), 1)
        ev.snapshot.delete(save=False)

    def test_inactive_heartbeat_acknowledged_no_event(self):
        from core.models import ShopEvent
        r = self._post("hikvision", "application/xml",
                       HIK_XML % (b"videoloss", b"inactive"))
        self.assertEqual((r.status_code, r.data["events"]), (200, []))
        self.assertFalse(ShopEvent.objects.exists())

    def test_dahua_motion_open_hours_only_logged(self):
        from core.models import ShopEvent
        self.cam.zone_config = {"hours": {"open": "00:00", "close": "23:59"}}
        self.cam.save()
        r = self._post("dahua", "text/plain", b"Code=VideoMotion;action=Start;index=0")
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.data["events"][0]["raised"])
        self.assertFalse(ShopEvent.objects.exists())

    def test_disabled_camera_ignored(self):
        self.cam.enabled = False
        self.cam.save()
        r = self._post("dahua", "text/plain", b"Code=CrossLineDetection;action=Start")
        self.assertEqual(r.data.get("ignored"), "camera_disabled")
