"""cctvalerts (W3 smart alert types, 3 Nov) — audit rows B1 B2 B6 B7 B9 B10 B11.

Pure rules (logic/cctv_rules.py) against the vendor fixtures in
testdata/cctv_traces (structure from public vendor docs, synthetic values —
see SOURCES.json), then the real views: Hikvision / Dahua webhooks, the Imou
callback, the EZVIZ poll, the per-camera switches endpoint, night loitering,
dark / covered stills and SD-card health.
"""
import io
import json
from datetime import datetime, timedelta
from unittest import mock

from django.core.files.base import ContentFile
from django.test import SimpleTestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import tests_e2e_cctv as E2E
from core.logic import camera_hooks as CH
from core.logic import cctv_rules as CR
from core.logic import shop_guard as SG
from core.tests_cctv_traces import trace


def _noisy_jpeg(seed=1, dark=False, w=320, h=180):
    """A textured still (real cameras never send a flat picture)."""
    from PIL import Image
    import random
    rnd = random.Random(seed)
    im = Image.new("RGB", (w, h))
    px = im.load()
    for y in range(h):
        for x in range(w):
            if dark:
                v = rnd.randint(0, 6)
                px[x, y] = (v, v, v)
            else:
                v = (x * 255 // w + rnd.randint(-20, 20)) % 256
                px[x, y] = (v, (y * 255 // h) % 256, (v + 60) % 256)
    b = io.BytesIO()
    im.save(b, "JPEG", quality=85)
    return b.getvalue()


def _scene(kind):
    """8x8 grids: a 'left bright' scene, a 'right bright' scene (moved)."""
    if kind == "a":
        return [200.0 if (i % 8) < 4 else 40.0 for i in range(64)]
    if kind == "b":
        return [40.0 if (i % 8) < 4 else 200.0 for i in range(64)]
    return [200.0 if (i % 8) < 4 else 40.0 for i in range(56)] + [120.0] * 8


# ================================================================== pure
class VendorMappingTests(SimpleTestCase):
    def hik(self, name):
        return CH.parse_hikvision("application/xml", trace(name))[0]

    def test_hikvision_codes(self):
        self.assertEqual(CR.classify_hook(self.hik("hik_scenechangedetection_ver20.xml")),
                         {"kind": "moved"})
        self.assertEqual(CR.classify_hook(self.hik("hik_audioexception_ver20.xml")),
                         {"kind": "sound"})
        self.assertEqual(CR.classify_hook(self.hik("hik_diskerror_ver20.xml")),
                         {"kind": "sd_fail"})
        self.assertEqual(CR.classify_hook(self.hik("hik_shelteralarm_ver20.xml")),
                         {"kind": "covered"})
        self.assertEqual(CR.classify_hook(self.hik("hik_linedetection_vehicle_ver20.xml")),
                         {"kind": "line", "object": "vehicle"})
        self.assertEqual(CR.classify_hook(self.hik("hik_linedetection_acusense_ver20.xml")),
                         {"kind": "line", "object": "person"})
        # an intrusion with a person is a "person" alert; plain motion: no type
        self.assertEqual(CR.classify_hook({"event": "fielddetection", "target": "human"}),
                         {"kind": "person", "object": "person"})
        self.assertEqual(CR.classify_hook({"event": "vmd", "target": ""}), {})

    def test_dahua_codes_and_direction(self):
        ev = CH.parse_dahua("text/plain", trace("dahua_attach_crossline_data.txt"))[0]
        self.assertEqual(CR.classify_hook(ev),
                         {"kind": "line", "object": "person", "direction": "a_to_b"})
        ev = CH.parse_dahua("text/plain", trace("dahua_wanderdetection_data.txt"))[0]
        self.assertEqual(CR.classify_hook(ev), {"kind": "loiter", "object": "person"})
        evs = CH.parse_dahua("text/plain", trace("dahua_health_sound_text.txt"))
        self.assertEqual([CR.classify_hook(e)["kind"] for e in evs],
                         ["sd_fail", "sound", "moved"])
        self.assertEqual(CR.classify_hook({"event": "smartmotionvehicle"}),
                         {"kind": "vehicle", "object": "vehicle"})

    def test_map_event_routes_new_kinds(self):
        night = datetime(2026, 11, 2, 23, 30)
        t, sig = CH.map_event(self.hik("hik_scenechangedetection_ver20.xml"), {}, night)
        self.assertEqual((t, sig["kind"], sig["health"]), ("camera_health", "moved", True))
        t, sig = CH.map_event(self.hik("hik_diskerror_ver20.xml"), {}, night)
        self.assertEqual((t, sig["kind"]), ("camera_health", "sd_fail"))
        t, sig = CH.map_event(self.hik("hik_audioexception_ver20.xml"), {}, night)
        self.assertEqual((t, sig["kind"]), ("camera_alarm", "sound"))
        # unchanged: tamper is still the camera's own alarm; heartbeat dropped
        t, sig = CH.map_event(self.hik("hik_shelteralarm_ver20.xml"), {}, night)
        self.assertEqual((t, sig["kind"], sig["tamper"]), ("camera_alarm", "covered", True))
        self.assertIsNone(CH.map_event(self.hik("hik_videoloss_heartbeat_ver10.xml"), {}, night))
        ev = CH.parse_dahua("text/plain", trace("dahua_wanderdetection_data.txt"))[0]
        t, sig = CH.map_event(ev, {}, night)
        self.assertEqual((t, sig["kind"]), ("camera_alarm", "loiter"))

    def test_imou(self):
        self.assertEqual(CR.classify_imou(json.loads(trace("imou_callback_human.json"))),
                         {"kind": "person", "object": "person"})
        self.assertEqual(CR.classify_imou(json.loads(trace("imou_callback_aiper.json"))),
                         {"kind": "person", "object": "person"})
        self.assertEqual(
            CR.classify_imou(json.loads(trace("imou_callback_vehicle_hypothetical.json"))),
            {"kind": "vehicle", "object": "vehicle"})
        self.assertEqual(CR.classify_imou({"msgType": "videoMotion"}), {})
        self.assertEqual(CR.classify_imou({"msgType": "babyCry"}), {"kind": "sound"})
        self.assertEqual(CR.imou_sd_problem(json.loads(trace("imou_callback_sdcard_abnormal.json"))),
                         "problem")
        self.assertEqual(CR.imou_sd_problem({"msgType": "sdcardStatus", "status": "normal"}), "ok")
        self.assertIsNone(CR.imou_sd_problem(json.loads(trace("imou_callback_status_online.json"))))

    def test_ezviz(self):
        rows = json.loads(trace("ezviz_alarm_types.json"))["data"]
        self.assertEqual([CR.classify_ezviz(r).get("kind") for r in rows],
                         ["covered", "line", "moved", "sound", "loiter", "vehicle", "animal"])
        old = json.loads(trace("ezviz_alarm_device_list.json"))["data"]
        self.assertEqual(CR.classify_ezviz(old[0]), {})          # 10002 motion
        self.assertEqual(CR.classify_ezviz(old[1]), {"kind": "person", "object": "person"})
        # the DEVICE name ("Car park cam") never decides the type
        self.assertEqual(CR.classify_ezviz({"alarmName": "Car park cam", "alarmType": 10002}), {})
        st = json.loads(trace("ezviz_storage_status.json"))["data"]
        self.assertEqual(CR.ezviz_sd_state(st), "problem")
        self.assertEqual(CR.ezviz_sd_state([{"index": 0, "status": 0}]), "ok")
        self.assertEqual(CR.ezviz_sd_state([]), "none")


class SupportAndSwitchTests(SimpleTestCase):
    def test_honest_support(self):
        self.assertEqual(CR.support_for("hikvision", "animal"), CR.NO)
        self.assertEqual(CR.support_for("dahua", "animal"), CR.NO)
        self.assertEqual(CR.support_for("imou", "animal"), CR.SOME)
        self.assertEqual(CR.support_for("imou", "animal", seen={"animal"}), CR.YES)
        self.assertEqual(CR.support_for("", "sd_fail"), CR.NO)      # Shop Box camera
        self.assertEqual(CR.support_for("onvif", "line"), CR.YES)   # drawn line
        self.assertEqual(CR.SUPPORT_TEXT[CR.NO], ("এই ক্যামেরায় নেই", "Not on this camera"))
        for k in CR.KINDS:          # every vendor table names every kind
            for v in CR.SUPPORT:
                self.assertIn(k, CR.SUPPORT[v])

    def test_switches(self):
        t = CR.normalize_toggles({"bogus": True, "sound": True})
        self.assertNotIn("bogus", t)
        self.assertTrue(t["sound"])
        self.assertFalse(t["animal"])                 # default off (street dogs)
        self.assertTrue(CR.muted({}, "animal"))
        self.assertTrue(CR.muted({"vehicle": False}, "line", "vehicle"))
        # a PERSON on the line still alerts when "person" is off
        self.assertFalse(CR.muted({"person": False}, "line", "person"))
        self.assertTrue(CR.muted({"person": False}, "person", "person"))
        self.assertFalse(CR.muted({}, None))


class LoiterTests(SimpleTestCase):
    def test_two_minutes_at_night_fires_once(self):
        st, fired = None, []
        for t in range(0, 181, 30):
            st, fire, dur = CR.loiter_step(st, 1000.0 + t, night=True)
            fired.append(fire)
        self.assertEqual(fired.count(True), 1)
        self.assertEqual(fired.index(True), 4)        # at 120 s
        self.assertEqual(dur, 180)

    def test_day_gap_and_native(self):
        st = None
        for t in range(0, 181, 30):
            st, fire, _ = CR.loiter_step(st, 1000.0 + t, night=False)
            self.assertFalse(fire)
        st, _, _ = CR.loiter_step(None, 0.0, True)
        st, _, _ = CR.loiter_step(st, 60.0, True)
        st, fire, dur = CR.loiter_step(st, 200.0, True)      # 140 s gap = new visit
        self.assertEqual((fire, dur), (False, 0))
        _, fire, _ = CR.loiter_step(None, 5.0, True, native=True)
        self.assertTrue(fire)


class StillTests(SimpleTestCase):
    def test_dark_and_covered_need_one_minute(self):
        st, k = CR.assess_still(None, [3.0] * 64, 3.0, 1.0, True, 100.0)
        self.assertIsNone(k)
        st, k = CR.assess_still(st, [3.0] * 64, 3.0, 1.0, True, 130.0)
        self.assertIsNone(k)                           # 30 s: maybe a flicker
        st, k = CR.assess_still(st, [3.0] * 64, 3.0, 1.0, True, 170.0)
        self.assertEqual(k, "dark")
        st, k = CR.assess_still(None, [150.0] * 64, 150.0, 1.0, False, 0.0)
        st, k = CR.assess_still(st, [150.0] * 64, 150.0, 1.0, False, 90.0)
        self.assertEqual(k, "covered")

    def test_moved_needs_two_matching_stills(self):
        a, b = _scene("a"), _scene("b")
        st, k = CR.assess_still(None, a, 120, 80, False, 0)      # learns the scene
        st, k = CR.assess_still(st, _scene("p"), 120, 80, False, 60)
        self.assertIsNone(k)                                      # a person: partial
        st, k = CR.assess_still(st, b, 120, 80, False, 120)
        self.assertIsNone(k)                                      # once: pending
        st, k = CR.assess_still(st, b, 120, 80, False, 150)
        self.assertIsNone(k)                                      # < 2 min apart
        st, k = CR.assess_still(st, b, 120, 80, False, 300)
        self.assertEqual(k, "moved")
        st, k = CR.assess_still(st, b, 120, 80, False, 400)
        self.assertIsNone(k)                                      # new scene learned
        # IR night scene is remembered apart from the day scene
        st, k = CR.assess_still(st, a, 120, 80, True, 500)
        self.assertIsNone(k)
        self.assertIn("ref_ir", st)

    def test_health_refire(self):
        self.assertTrue(CR.health_due({}, "dark", 10))
        self.assertFalse(CR.health_due({"dark": 10}, "dark", 3600))
        self.assertTrue(CR.health_due({"dark": 10}, "dark", 10 + 6 * 3600))


class GuardAndTextTests(SimpleTestCase):
    def test_combine(self):
        r = SG.combine({"type": "loitering", "signals": {"night": True, "kind": "loiter"}}, [])
        self.assertEqual((r["raise"], r["confidence"]), (True, 0.7))
        r = SG.combine({"type": "loitering", "signals": {"kind": "loiter"}}, [])
        self.assertFalse(r["raise"])
        r = SG.combine({"type": "camera_health",
                        "signals": {"kind": "dark", "source": "server_still"}}, [])
        self.assertEqual((r["raise"], r["possible"]), (True, True))
        r = SG.combine({"type": "camera_health",
                        "signals": {"kind": "sd_fail", "source": "camera_webhook"}}, [])
        self.assertEqual((r["raise"], r["possible"]), (True, False))
        # kind / object / direction are context, never extra evidence
        a = SG.combine({"type": "motion", "signals": {"armed": True}}, [])
        b = SG.combine({"type": "motion", "signals": {"armed": True, "kind": "vehicle",
                                                      "object": "vehicle"}}, [])
        self.assertEqual(a["confidence"], b["confidence"])

    def test_bangla_texts(self):
        import re
        for k in CR.KINDS:
            bn = CR.what(k, "bn")
            self.assertFalse(re.search(r"[A-Za-z]", bn.replace("SD", "")), bn)
            self.assertTrue(CR.what(k, "en"))
            self.assertNotIn("চুরি", bn)                  # never "theft"
        self.assertIn("ক → খ", CR.what("line", "bn", "a_to_b"))
        self.assertEqual(CR.line_count(None, "2026-11-02", "a_to_b"),
                         {"day": "2026-11-02", "total": 1, "a_to_b": 1, "b_to_a": 0})
        s = CR.line_count({"day": "2026-11-01", "total": 9}, "2026-11-02")
        self.assertEqual(s["total"], 1)


# ================================================================== views
class _AlertBase(E2E._Base):
    def pushes_full(self):
        return [a for a, k in self.pushes if len(a) > 1 and a[1] == "shop_alert"]

    def types(self, cam_id, lang="en"):
        return self.client.get("/api/v1/shop/cameras/%d/alert-types" % cam_id,
                               HTTP_ACCEPT_LANGUAGE=lang)


class HookAlertTests(_AlertBase):
    def setUp(self):
        super().setUp()
        self.hik = self.add_camera("hikvision", "Shop door")
        self.dev = APIClient()

    def hook(self, name):
        return self.dev.generic("POST", "/api/v1/shop/hook/hikvision/%s" % self.hik["camera_token"],
                                trace(name), content_type="application/xml")

    def test_scene_change_and_sd_are_camera_health_once_per_6h(self):
        from core.models import ShopEvent
        r = self.hook("hik_scenechangedetection_ver20.xml")
        self.assertTrue(r.data["events"][0]["raised"], r.data)
        ev = ShopEvent.objects.get()
        self.assertEqual((ev.type, ev.signals["inputs"]["kind"]), ("camera_health", "moved"))
        a = self.pushes_full()[0]
        self.assertTrue(a[3].startswith("Camera problem — please check"), a)
        self.assertTrue(a[2].startswith("ক্যামেরার সমস্যা"), a)
        self.assertIn("moved", a[5])
        ShopEvent.objects.update(status="checked")
        r = self.hook("hik_scenechangedetection_ver20.xml")
        self.assertEqual(ShopEvent.objects.count(), 1)               # not again within 6 h
        r = self.hook("hik_diskerror_ver20.xml")
        self.assertTrue(r.data["events"][0]["raised"], r.data)
        ev = ShopEvent.objects.order_by("-id").first()
        self.assertEqual(ev.signals["inputs"]["kind"], "sd_fail")
        # the event list says WHAT it is, in the viewer's language
        rows = self.client.get("/api/v1/shop/events?site=%d" % self.site["id"],
                               HTTP_ACCEPT_LANGUAGE="bn").data["events"]
        kinds = {r_["kind"]: r_["what"] for r_ in rows}
        self.assertIn("SD", kinds["sd_fail"])

    def test_switches_endpoint_mutes_and_counts_lines(self):
        from core.models import ShopCamera, ShopEvent
        r = self.types(self.hik["id"])
        self.assertEqual(r.status_code, 200, r.data)
        by = {t["kind"]: t for t in r.data["types"]}
        self.assertEqual(len(by), len(CR.KINDS))
        self.assertFalse(by["animal"]["available"])
        self.assertEqual(by["animal"]["note"], "Not on this camera")
        self.assertFalse(by["animal"]["on"])
        self.assertEqual(r.data["night"]["source"], "default")
        bn = self.types(self.hik["id"], "bn").data
        self.assertEqual({t["kind"]: t for t in bn["types"]}["animal"]["note"], "এই ক্যামেরায় নেই")
        self.assertEqual(bn["night"]["start"], "২২:০০")
        self.assertFalse(r.data["ai_used"])
        # vehicles off
        p = self.client.post("/api/v1/shop/cameras/%d/alert-types" % self.hik["id"],
                             {"types": {"vehicle": False, "sound": True}}, format="json")
        self.assertEqual(p.status_code, 200, p.data)
        by = {t["kind"]: t for t in p.data["types"]}
        self.assertEqual((by["vehicle"]["on"], by["sound"]["on"]), (False, True))
        r = self.hook("hik_linedetection_vehicle_ver20.xml")
        self.assertFalse(r.data["events"][0]["raised"], r.data)
        self.assertEqual(ShopEvent.objects.count(), 0)
        g = self.types(self.hik["id"]).data
        self.assertEqual(g["line_today"]["total"], 1)                  # counted anyway
        self.assertTrue({t["kind"]: t for t in g["types"]}["line"]["seen"])
        # saving zones keeps the switches
        z = self.client.post("/api/v1/shop/cameras/%d/zones" % self.hik["id"],
                             {"zone_config": {"zones": [], "schedule": None,
                                              "sensitivity": "medium"}}, format="json")
        self.assertEqual(z.status_code, 200, z.data)
        cam = ShopCamera.objects.get(pk=self.hik["id"])
        self.assertFalse(cam.zone_config["alert_types"]["vehicle"])
        # a garbage body is refused honestly
        bad = self.client.post("/api/v1/shop/cameras/%d/alert-types" % self.hik["id"],
                               {"types": ["x"]}, format="json")
        self.assertEqual(bad.status_code, 422)

    def test_only_the_owner_and_behind_the_switches(self):
        from core.models import User
        other = User.objects.create_user(name="X", phone="01710003099", password="pw")
        c = APIClient()
        c.force_authenticate(other)
        self.assertEqual(c.get("/api/v1/shop/cameras/%d/alert-types" % self.hik["id"]).status_code,
                         404)
        with mock.patch("core.feature_flags.is_on", return_value=False):
            self.assertEqual(self.types(self.hik["id"]).status_code, 403)


class StillAndLoiterTests(_AlertBase):
    def setUp(self):
        super().setUp()
        from core.models import ShopCamera
        self.cam = ShopCamera.objects.get(pk=self.add_camera("onvif", "Gate")["id"])

    def ingest(self, etype, signals, now, raw=None):
        from core import shop_views as SV
        snap = ContentFile(raw, name="s.jpg") if raw else None
        return SV._ingest_event(self.cam.site, self.cam,
                                {"type": etype, "signals": signals, "at": now.timestamp()},
                                now, snap)

    def test_dark_picture_for_a_minute_is_one_camera_health_alert(self):
        from core.models import ShopEvent
        t0 = timezone.now()
        dark = _noisy_jpeg(dark=True)
        self.ingest("motion", {}, t0, dark)
        self.ingest("motion", {}, t0 + timedelta(seconds=20), dark)
        self.assertFalse(ShopEvent.objects.filter(type="camera_health").exists())
        self.ingest("motion", {}, t0 + timedelta(seconds=75), dark)
        ev = ShopEvent.objects.get(type="camera_health")
        self.assertEqual(ev.signals["inputs"]["kind"], "dark")
        self.assertTrue(ev.possible)                    # a server still check
        # a normal picture never raises a health alert
        self.ingest("motion", {}, t0 + timedelta(seconds=200), _noisy_jpeg(3))
        self.assertEqual(ShopEvent.objects.filter(type="camera_health").count(), 1)

    def test_dark_switch_off_means_no_still_alert(self):
        from core.models import ShopEvent
        self.client.post("/api/v1/shop/cameras/%d/alert-types" % self.cam.id,
                         {"types": {"dark": False, "covered": False, "moved": False}},
                         format="json")
        self.cam.refresh_from_db()
        t0 = timezone.now()
        for s in (0, 30, 90):
            self.ingest("motion", {}, t0 + timedelta(seconds=s), _noisy_jpeg(dark=True))
        self.assertFalse(ShopEvent.objects.filter(type="camera_health").exists())

    def test_person_for_two_minutes_at_night_is_loitering(self):
        from core.models import ShopEvent
        night = timezone.make_aware(datetime(2026, 11, 2, 23, 10))
        for s in (0, 40, 80, 125):
            self.ingest("person_detected", {"conf": 0.8}, night + timedelta(seconds=s))
        ev = ShopEvent.objects.get(type="loitering")
        self.assertGreaterEqual(ev.signals["inputs"]["seconds"], 120)
        texts = [a for a in self.pushes_full() if "2 minutes" in a[5]]
        self.assertTrue(texts, self.pushes_full())
        self.assertTrue(any("২ মিনিটের" in a[4] for a in self.pushes_full()))
        # once per visit
        self.ingest("person_detected", {"conf": 0.8}, night + timedelta(seconds=160))
        self.assertEqual(ShopEvent.objects.filter(type="loitering").count(), 1)

    def test_same_by_day_is_not_loitering(self):
        from core.models import ShopEvent
        day = timezone.make_aware(datetime(2026, 11, 2, 14, 0))
        for s in (0, 40, 80, 125):
            self.ingest("person_detected", {"conf": 0.8}, day + timedelta(seconds=s))
        self.assertFalse(ShopEvent.objects.filter(type="loitering").exists())

    def test_health_still_for_a_cloud_camera(self):
        from core import cctv_alerts as CA
        from core.models import ShopCamera, ShopEvent
        ShopCamera.objects.filter(pk=self.cam.pk).update(vendor="ezviz", vendor_ref="EZ:E9:1")
        self.cam.refresh_from_db()
        t0 = timezone.now()
        dark = _noisy_jpeg(dark=True)
        self.assertIsNone(CA.health_still(self.cam, t0, {}, fetch=lambda c, cl: dark))
        # not due yet (a bad still -> recheck after 5 min, not every minute)
        self.assertIsNone(CA.health_still(self.cam, t0 + timedelta(minutes=1), {},
                                          fetch=lambda c, cl: dark))
        ev = CA.health_still(self.cam, t0 + timedelta(minutes=6), {}, fetch=lambda c, cl: dark)
        self.assertIsNotNone(ev)
        self.assertEqual(ShopEvent.objects.get(type="camera_health").signals["inputs"]["kind"],
                         "dark")
        # the owner switched still checks off -> no vendor call at all
        self.client.post("/api/v1/shop/cameras/%d/alert-types" % self.cam.id,
                         {"types": {"dark": False, "covered": False, "moved": False}},
                         format="json")
        self.cam.refresh_from_db()
        called = []
        CA.health_still(self.cam, t0 + timedelta(hours=9), {},
                        fetch=lambda c, cl: called.append(1) or dark)
        self.assertEqual(called, [])


class ImouAlertTests(_AlertBase):
    APP_ID, SECRET = E2E.ImouCloudE2ETests.APP_ID, E2E.ImouCloudE2ETests.SECRET
    imou_http = E2E.ImouCloudE2ETests.imou_http
    link = E2E.ImouCloudE2ETests.link
    callback = E2E.ImouCloudE2ETests.callback

    def setUp(self):
        super().setUp()
        from core.logic import imou as IM
        IM._token_cache.clear()
        self.cam = self.add_camera("imou", "Gate (Imou)")
        self.calls, self.bound = [], set()
        self.assertEqual(self.link().status_code, 200)

    def test_sd_card_status_raises_one_health_alert(self):
        from core.models import ShopEvent
        msg = json.loads(trace("imou_callback_sdcard_abnormal.json"))
        msg["did"] = "7J0A8B9C"
        r, _ = self.callback(msg)
        self.assertEqual(r.data["events"], [{"sd_status": True}])
        ev = ShopEvent.objects.get()
        self.assertEqual((ev.type, ev.signals["inputs"]["kind"]), ("camera_health", "sd_fail"))
        self.assertEqual(self.types(self.cam["id"]).data["sd"]["state"], "problem")
        r, _ = self.callback(msg)                         # still broken: no new alert
        self.assertEqual(ShopEvent.objects.count(), 1)
        r, _ = self.callback(dict(msg, status="normal"))
        self.assertEqual(self.types(self.cam["id"], "bn").data["sd"]["text"], "SD কার্ড ঠিক আছে")

    def test_vehicle_alarm_says_vehicle_and_animal_is_off_by_default(self):
        from core.models import ShopEvent
        msg = json.loads(trace("imou_callback_vehicle_hypothetical.json"))
        msg.update(did="7J0A8B9C", picurlArray=[])
        r, _ = self.callback(msg)
        self.assertTrue(r.data["events"][0]["raised"], r.data)
        ev = ShopEvent.objects.get()
        self.assertEqual(ev.signals["inputs"]["kind"], "vehicle")
        self.assertTrue(any("vehicle" in a[5] for a in self.pushes_full()))
        r, _ = self.callback(dict(msg, msgType="petDetection", alarmId="77"))
        self.assertFalse(r.data["events"][0]["raised"], r.data)
        by = {t["kind"]: t for t in self.types(self.cam["id"]).data["types"]}
        self.assertTrue(by["animal"]["seen"])             # it did send one
        self.assertEqual(by["animal"]["support"], "yes")
        self.assertFalse(by["animal"]["on"])

    def test_night_loitering_from_repeated_person_alarms(self):
        from core.models import ShopEvent
        night = timezone.make_aware(datetime(2026, 11, 2, 23, 20))
        for i, s in enumerate((0, 45, 90, 130)):
            with mock.patch("django.utils.timezone.now",
                            return_value=night + timedelta(seconds=s)):
                self.callback(E2E.ImouCloudE2ETests.alarm(alarm_id="L%d" % i))
        self.assertEqual(ShopEvent.objects.filter(type="loitering").count(), 1)


class EzvizAlertTests(_AlertBase):
    def setUp(self):
        super().setUp()
        from core.models import ShopCamera
        cam = self.add_camera("ezviz", "Counter")
        ShopCamera.objects.filter(pk=cam["id"]).update(vendor_ref="EZ:BD7654321:1")
        self.cam_id = cam["id"]

    def client_for(self, rows, storage):
        from core.logic import ezviz as EZ
        EZ._token_cache.clear()

        def http(url, form, timeout):
            if url.endswith("/api/lapp/token/get"):
                return 200, json.dumps({"code": "200", "data": {
                    "accessToken": "AT",
                    "expireTime": int((timezone.now().timestamp() + 3600) * 1000),
                    "areaDomain": "https://isgpopen.ezvizlife.com"}})
            if url.endswith("/api/lapp/alarm/device/list"):
                return 200, json.dumps({"code": "200", "data": rows})
            if url.endswith("/api/lapp/device/format/status"):
                return 200, json.dumps(storage)
            return 404, ""
        return EZ.EzvizClient("KEY", "SECRET", http=http)

    def test_poll_types_and_storage(self):
        from core.cashguard_views import poll_ezviz
        from core.models import ShopEvent
        now = timezone.now()
        rows = json.loads(trace("ezviz_alarm_types.json"))["data"]
        base = int(now.timestamp() * 1000)
        for i, r in enumerate(rows):
            r["alarmTime"] = base - 60_000 + i * 1000
        client = self.client_for(rows, json.loads(trace("ezviz_storage_status.json")))
        from core.logic import cash_guard as CG
        with mock.patch("core.shop_views.owner_caps",
                        return_value=dict(CG.caps_for("free", {}), alerts_day=50)):
            n = poll_ezviz(client=client, now=now, getter=lambda u: None)
        self.assertEqual(n, len(rows))
        kinds = {e.signals["inputs"].get("kind"): e.type for e in ShopEvent.objects.all()}
        self.assertEqual(kinds.get("moved"), "camera_health")
        self.assertEqual(kinds.get("sd_fail"), "camera_health")       # storage status 1
        self.assertEqual(kinds.get("line"), "camera_alarm")
        self.assertEqual(kinds.get("covered"), "camera_alarm")
        self.assertNotIn("sound", kinds)                  # off by default
        self.assertNotIn("animal", kinds)                 # off by default
        g = self.types(self.cam_id).data
        self.assertEqual(g["sd"]["state"], "problem")
        by = {t["kind"]: t for t in g["types"]}
        self.assertTrue(by["sound"]["seen"] and by["loiter"]["seen"])
