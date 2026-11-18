"""cctvdet (CCTV Guard V3 part C, stage 1) — zone detections.

Pure rules (core/logic/cctv_detect.py, watchman zones, shop_guard.combine),
parity with the box (edge/shopbox: the shared thresholds file and the tamper
fixture), then the real path: the owner draws gate / post zones in the app ->
the box's REAL request body (shopbox.payload) -> shop/ingest -> alert with
the measured confidence, the zone label, a template / AI description, and
the 10 s clip envelope accepted.
"""
import json
import os
import sys
from datetime import datetime
from unittest import mock

from django.test import SimpleTestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import tests_e2e_cctv as E2E
from core.logic import cctv_detect as CD
from core.logic import cctv_rules as CR
from core.logic import shop_guard as SG
from core.logic import watchman as WM

EDGE = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "edge", "shopbox"))
LOWER = [[0.3, 0.5], [0.7, 0.5], [0.7, 1.0], [0.3, 1.0]]
ALL_DAY = {"days": [0, 1, 2, 3, 4, 5, 6], "start": "00:00", "end": "00:00"}


def _edge_json(*parts):
    with open(os.path.join(EDGE, *parts), encoding="utf-8") as f:
        return json.load(f)


class ZoneConfigTests(SimpleTestCase):
    def test_gate_and_post_zones_with_their_own_schedule_and_options(self):
        out = WM.normalize_zone_config({"zones": [
            {"id": "g1", "type": "gate", "points": LOWER, "label": "Shutter",
             "opts": {"watch_open": True, "open_min": 9999, "closed_at": 1.7e9, "x": 1}},
            {"id": "p1", "type": "post", "points": LOWER, "opts": {"absent_min": "7"}},
            {"id": "r1", "type": "restricted", "points": LOWER, "schedule": ALL_DAY,
             "opts": {"dwell_s": 90, "absent_min": 3}}]})
        g, p, r = out["zones"]
        self.assertEqual(g["opts"], {"watch_open": True, "open_min": 720, "closed_at": 1.7e9})
        self.assertNotIn("schedule", g)
        self.assertEqual(p["schedule"], CD.POST_DEFAULT_SCHEDULE)    # a post needs hours
        self.assertEqual(p["opts"], {"absent_min": 7})
        self.assertEqual(r["opts"], {"dwell_s": 90})                 # absent_min is post-only
        self.assertEqual(r["schedule"], ALL_DAY)

    def test_bad_zone_schedule_is_refused(self):
        with self.assertRaises(WM.ZoneError) as e:
            WM.normalize_zone_config({"zones": [{"type": "post", "points": LOWER,
                                                 "schedule": {"days": [9], "start": "x"}}]})
        self.assertEqual(e.exception.code, "bad_schedule")

    def test_all_day_zone_schedule(self):
        self.assertTrue(WM.is_armed(ALL_DAY, datetime(2026, 11, 9, 3, 0)))
        self.assertFalse(WM.is_armed({"days": [1], "start": "00:00", "end": "00:00"},
                                     datetime(2026, 11, 9, 3, 0)))     # Monday


class ZoneGateTests(SimpleTestCase):
    v2 = {"v": 2, "schedule": {"days": [0, 1, 2, 3, 4, 5, 6], "start": "22:00", "end": "06:00"},
          "zones": [{"id": "g1", "type": "gate", "points": LOWER},
                    {"id": "p1", "type": "post", "points": LOWER,
                     "schedule": {"days": [0, 1, 2, 3, 4, 5, 6], "start": "10:00", "end": "21:00"}},
                    {"id": "g2", "type": "gate", "points": LOWER, "opts": {"watch_open": True}}]}

    def gate(self, etype, zone, hh, **sig):
        return CD.zone_gate(self.v2, etype, {"zone": zone, **sig},
                            datetime(2026, 11, 9, hh, 0), WM.is_armed)

    def test_person_at_gate_follows_the_camera_schedule(self):
        self.assertIsNone(self.gate("gate_person", "g1", 23))
        self.assertEqual(self.gate("gate_person", "g1", 12), "not_armed")

    def test_post_only_inside_its_hours_and_open_gate_always(self):
        self.assertIsNone(self.gate("post_empty", "p1", 12))
        self.assertEqual(self.gate("post_empty", "p1", 23), "post_off_hours")
        self.assertIsNone(self.gate("gate_open", "g2", 12))

    def test_deleted_zone_is_silent_and_other_types_untouched(self):
        self.assertEqual(self.gate("gate_person", "gone", 23), "zone_gone")
        self.assertIsNone(self.gate("person_detected", "g1", 12))
        self.assertIsNone(self.gate("loitering", "", 12))          # server night rule
        self.assertEqual(self.gate("loitering", "g1", 12, zone_dwell=True), "not_armed")


class CombineTests(SimpleTestCase):
    def combine(self, etype, **sig):
        return SG.combine({"type": etype, "signals": sig}, [], now=1.7e9)

    def test_each_detection_needs_its_observation(self):
        self.assertTrue(self.combine("gate_person", person=True, zone_breach=True)["raise"])
        self.assertFalse(self.combine("gate_person", zone="g1")["raise"])
        self.assertTrue(self.combine("post_empty", absent=True, minutes=5)["raise"])
        self.assertFalse(self.combine("post_empty")["raise"])
        self.assertTrue(self.combine("gate_open", gate_open=True)["raise"])
        self.assertFalse(self.combine("gate_open")["raise"])
        self.assertTrue(self.combine("loitering", zone_dwell=True, human=True)["raise"])
        self.assertFalse(self.combine("loitering")["raise"])           # not night, no zone

    def test_later_stage_types_never_raise_yet(self):
        for t in CD.LATER_TYPES:
            self.assertFalse(self.combine(t, person=True)["raise"], t)


class SharedWithTheBoxTests(SimpleTestCase):
    def test_measured_table_equals_the_shared_thresholds_file(self):
        m = _edge_json("shopbox", "cctv_thresholds.json")["measured"]
        self.assertEqual({k: v for k, v in m.items() if not k.startswith("_")}, CD.MEASURED)
        self.assertEqual(m.get("_run", ""), CD.MEASURED_RUN)

    def test_tamper_rule_is_the_same_on_box_and_server(self):
        fix = _edge_json("tests", "fixtures", "detect_cases.json")["tamper"]
        for name, seq in fix.items():
            st = {}
            for s in seq:
                st, kind = CR.assess_still(st, s["grid"], s["mean"], s["std"], s["ir"], s["ts"])
                self.assertEqual(kind, s["expect"], (name, s["ts"]))

    def test_every_new_model_type_has_words_and_is_known_to_the_box(self):
        from core.models import ShopEvent
        from core import shop_views as SV
        types = {t for t, _ in ShopEvent.TYPES}
        for t in CD.ZONE_TYPES + CD.LATER_TYPES:
            self.assertIn(t, types)
            self.assertIn(t, SV.EVENT_WORDS)
            self.assertTrue(CD.words(t, "bn") and CD.words(t, "en"))

    def test_confidence_is_the_measured_precision_or_honestly_none(self):
        self.assertEqual(CD.confidence("not_a_detection", 0.75), 0.75)
        with mock.patch.dict(CD.MEASURED, {"gate_person": {"p": 0.94, "r": 0.91, "n": 400}}):
            self.assertEqual(CD.confidence("gate_person", 0.75), 0.94)
            self.assertIn("৯৪%", CD.measured_text("gate_person", "bn"))
            self.assertIn("94%", CD.measured_text("gate_person", "en"))
        with mock.patch.dict(CD.MEASURED, {}, clear=True):
            self.assertIn("not measured", CD.measured_text("post_empty", "en"))


class DetectionIngestE2ETests(E2E._Base):
    def setUp(self):
        super().setUp()
        sys.path.insert(0, EDGE)
        self.addCleanup(lambda: sys.path.remove(EDGE))
        self.cam = self.add_camera("rtsp", "Shop front")
        hh = timezone.localtime(timezone.now()).hour
        away = {"days": [0, 1, 2, 3, 4, 5, 6], "start": "%02d:00" % ((hh + 2) % 24),
                "end": "%02d:00" % ((hh + 3) % 24)}
        z = self.client.put("/api/v1/shop/cameras/%d/zones" % self.cam["id"], {"zone_config": {
            "zones": [{"id": "g1", "type": "gate", "points": LOWER, "label": "Shutter"},
                      {"id": "p1", "type": "post", "points": LOWER, "label": "Cash counter",
                       "schedule": ALL_DAY, "opts": {"absent_min": 5}},
                      {"id": "p2", "type": "post", "points": LOWER, "schedule": away}],
            "schedule": None, "sensitivity": "medium", "quiet_hours": None}}, format="json")
        self.assertEqual(z.status_code, 200, z.data)
        self.assertEqual(z.data["zone_config"]["zones"][1]["opts"], {"absent_min": 5})

    def send(self, etype, det):
        from shopbox import payload as P
        sig = P.build_signals(etype, detector="yolox_nano", det=det)
        evt = P.build_event(etype, sig, camera_id="srv%d" % self.cam["id"])
        evt["server_camera_id"] = self.cam["id"]
        _t, form, files = P.build_request(evt, site_token=self.site["enrollment_token"],
                                          camera_token=None, snapshot=E2E._jpeg(),
                                          snapshot_mode="always")
        from django.core.files.uploadedfile import SimpleUploadedFile
        data = dict(form)
        if files:
            data["snapshot"] = SimpleUploadedFile(*files["snapshot"])
            return APIClient().post("/api/v1/shop/ingest", data, format="multipart")
        return APIClient().post("/api/v1/shop/ingest", data, format="json")

    def test_person_at_gate_alert_with_zone_label_and_measured_line(self):
        from core.models import ShopEvent
        r = self.send("gate_person", {"zone": "g1", "label": "Shutter", "conf": 0.81})
        self.assertIn(r.status_code, (200, 201), r.data)
        ev = ShopEvent.objects.get(type="gate_person")
        self.assertEqual(ev.signals["inputs"]["zone"], "g1")
        self.assertTrue(self.shop_pushes())
        rows = self.client.get("/api/v1/shop/events?site=%d" % self.site["id"],
                               HTTP_ACCEPT_LANGUAGE="bn").data["events"]
        d = rows[0]["detect"]
        self.assertEqual(d["title"], CD.WORDS["gate_person"][0])
        self.assertIn("Shutter", d["detail"])
        self.assertTrue(d["measured_text"])
        self.assertTrue(d["desc"])                    # template until the AI pass
        self.assertEqual(d["desc_src"], "template")

    def test_post_empty_raised_in_hours_and_silent_outside(self):
        from core.models import ShopEvent
        self.send("post_empty", {"zone": "p1", "label": "Cash counter", "minutes": 5})
        self.assertTrue(ShopEvent.objects.filter(type="post_empty").exists())
        self.send("post_empty", {"zone": "p2", "minutes": 5})
        self.assertEqual(ShopEvent.objects.filter(type="post_empty").count(), 1)
        self.send("post_empty", {"zone": "deleted", "minutes": 5})
        self.assertEqual(ShopEvent.objects.filter(type="post_empty").count(), 1)

    def test_box_tamper_and_dwell_loitering(self):
        from core.models import ShopEvent
        self.send("camera_health", {"kind": "covered"})
        ev = ShopEvent.objects.get(type="camera_health")
        self.assertEqual(ev.signals["inputs"]["kind"], "covered")
        self.assertFalse(ev.possible)
        self.send("loitering", {"zone": "g1", "seconds": 130})
        # g1 follows the camera schedule (None = always armed)
        self.assertTrue(ShopEvent.objects.filter(type="loitering").exists())

    def test_the_detection_clip_may_be_10_seconds(self):
        from core.logic import phonecam_clips as PCL
        from core.logic import cash_guard as CG
        self.assertIn("camera_health", CD.LONG_CLIP_TYPES)
        self.assertGreaterEqual(PCL.PREVIEW_MAX_S, 10.0)
        self.assertLess(CG.CLIP_MAX_S, 10.0)     # the cash clip stays 3-5 s


# ============================================================ stage 2
class Stage2RuleTests(SimpleTestCase):
    def test_parking_zones_lines_and_crowd_options(self):
        out = WM.normalize_zone_config({"zones": [
            {"id": "pk", "type": "parking", "points": LOWER, "opts": {"crowd_n": 5, "overstay_min": 2}},
            {"id": "np", "type": "no_parking", "points": LOWER},
            {"id": "l1", "type": "entry_line", "points": [[0.5, 0], [0.5, 1]],
             "opts": {"vehicles": True, "notify": True, "in_side": "right", "crowd_n": 4}},
            {"id": "q", "type": "restricted", "points": LOWER, "opts": {"crowd_n": 1}},
            {"id": "q2", "type": "restricted", "points": LOWER, "opts": {"crowd_n": 6, "crowd_s": 5}}]})
        pk, np_, l1, q, q2 = out["zones"]
        self.assertEqual(pk["opts"], {"overstay_min": 5})          # clamped, no crowd on parking
        self.assertEqual(np_["opts"], {"wrong_s": 120})
        self.assertEqual(l1["opts"], {"vehicles": True, "notify": True, "in_side": "right"})
        self.assertNotIn("opts", q)                                # a crowd of 1 is no crowd
        self.assertEqual(q2["opts"], {"crowd_n": 6, "crowd_s": 10})

    def test_combine_and_gate_for_crowd_and_vehicles(self):
        c = lambda t, **s: SG.combine({"type": t, "signals": s}, [], now=1.7e9)["raise"]
        self.assertTrue(c("crowd", crowd=True, count=6))
        self.assertFalse(c("crowd", count=6))
        for t in CD.VEHICLE_TYPES:
            self.assertTrue(c(t, vehicle=True))
            self.assertFalse(c(t, person=True))
        v2 = {"v": 2, "schedule": {"days": [0, 1, 2, 3, 4, 5, 6], "start": "22:00", "end": "06:00"},
              "zones": [{"id": "q", "type": "restricted", "points": LOWER},
                        {"id": "pk", "type": "parking", "points": LOWER}]}
        noon = datetime(2026, 11, 9, 12, 0)
        # a queue / a car matter by day too: not the night guard schedule
        self.assertIsNone(CD.zone_gate(v2, "crowd", {"zone": "q"}, noon, WM.is_armed))
        self.assertIsNone(CD.zone_gate(v2, "parking_overstay", {"zone": "pk"}, noon, WM.is_armed))

    def test_plate_parser_is_the_same_on_box_and_server(self):
        from core.logic import bd_plate as BP
        for c in _edge_json("tests", "fixtures", "detect_cases.json")["plates"]:
            got = BP.parse_bd_plate(c["text"])
            if c["bn"] is None:
                self.assertIsNone(got)
                continue
            for k in ("bn", "en", "number", "partial"):
                self.assertEqual(got[k], c[k], (k, c))

    def test_detail_shows_vehicle_direction_and_plate(self):
        sig = {"inputs": {"zone": "l1", "zone_label": "Gate", "cls": "car", "dir": "in",
                          "plate": {"bn": "ঢাকা মেট্রো-গ ১২-৩৪৫৬", "en": "DHAKA METRO-GA 12-3456",
                                    "number": "12-3456", "partial": False, "source": "box_ocr"}}}
        self.assertIn("ঢুকেছে", CD.detail("vehicle_in_out", sig, "bn"))
        self.assertIn("DHAKA METRO-GA 12-3456", CD.detail("vehicle_in_out", sig, "en"))
        f = CD.event_fields("vehicle_in_out", sig, "bn")
        self.assertEqual(f["plate"]["number"], "12-3456")
        # the AI's reading (beside inputs) counts when the box had none
        ai = {"inputs": {"cls": "car"}, "plate": {"number": "15-7788", "partial": True}}
        self.assertEqual(CD.plate_of(ai)["number"], "15-7788")


class Stage2IngestE2ETests(E2E._Base):
    def setUp(self):
        super().setUp()
        sys.path.insert(0, EDGE)
        self.addCleanup(lambda: sys.path.remove(EDGE))
        self.cam = self.add_camera("rtsp", "Parking gate")
        z = self.client.put("/api/v1/shop/cameras/%d/zones" % self.cam["id"], {"zone_config": {
            "zones": [{"id": "l1", "type": "entry_line", "points": [[0.5, 0], [0.5, 1]],
                       "opts": {"vehicles": True}},
                      {"id": "l2", "type": "entry_line", "points": [[0.2, 0], [0.2, 1]],
                       "opts": {"vehicles": True, "notify": True}},
                      {"id": "np", "type": "no_parking", "points": LOWER, "label": "Gate front"},
                      {"id": "pk", "type": "parking", "points": LOWER, "label": "Bay 1",
                       "opts": {"overstay_min": 30, "notify": True}}],
            "schedule": None, "sensitivity": "medium", "quiet_hours": None}}, format="json")
        self.assertEqual(z.status_code, 200, z.data)

    send = DetectionIngestE2ETests.send

    def test_parking_is_report_only_unless_the_owner_turns_ringing_on(self):
        # cctvdet3 (lead decision): vehicle detections are saved for the log /
        # daily report without a ringing push until measured >= 90/90; the
        # owner can turn ringing on per zone (opts.notify)
        from core.models import ShopEvent
        self.send("wrong_parking", {"zone": "np", "label": "Gate front", "cls": "car",
                                    "seconds": 150})
        self.assertTrue(ShopEvent.objects.filter(type="wrong_parking").exists())
        loud = [k for k in self.shop_pushes() if not (k.get("data") or {}).get("quiet")]
        self.assertEqual(loud, [])
        self.send("parking_overstay", {"zone": "pk", "label": "Bay 1", "cls": "car",
                                       "seconds": 1900, "minutes": 31})
        self.assertTrue(ShopEvent.objects.filter(type="parking_overstay").exists())
        loud = [k for k in self.shop_pushes() if not (k.get("data") or {}).get("quiet")]
        self.assertTrue(loud)                  # rings (to each person of the site)

    def test_report_only_rule_and_notify_option(self):
        v2 = {"zones": [{"id": "np", "type": "no_parking", "opts": {}},
                        {"id": "pk", "type": "parking", "opts": {"notify": True}},
                        {"id": "g", "type": "gate", "opts": {}}]}
        self.assertTrue(CD.report_only(v2, "wrong_parking", {"zone": "np"}))
        self.assertTrue(CD.report_only(v2, "vehicle_in_out", {"zone": "missing"}))
        self.assertFalse(CD.report_only(v2, "parking_overstay", {"zone": "pk"}))
        self.assertFalse(CD.report_only(v2, "gate_person", {"zone": "g"}))
        self.assertEqual(CD.clean_opts({"notify": True, "wrong_s": 90}, "no_parking"),
                         {"notify": True, "wrong_s": 90})
        self.assertNotIn("notify", CD.clean_opts({"notify": True}, "gate"))

    def test_vehicle_log_is_silent_unless_the_line_says_notify(self):
        from core.models import ShopEvent
        self.send("vehicle_in_out", {"zone": "l1", "dir": "in", "cls": "car"})
        self.assertTrue(ShopEvent.objects.filter(type="vehicle_in_out").exists())
        loud = [k for k in self.shop_pushes() if not (k.get("data") or {}).get("quiet")]
        self.assertEqual(loud, [])
        self.send("vehicle_in_out", {"zone": "l2", "dir": "out", "cls": "bus",
                                     "plate": {"bn": "১৫-৭৭৮৮", "en": "15-7788",
                                               "number": "15-7788", "partial": True}})
        # the same camera + type inside the group window is ONE alert, counted
        ev = ShopEvent.objects.get(type="vehicle_in_out")
        self.assertEqual(ev.count, 2)

    def test_wrong_parking_alert_row(self):
        from core.models import ShopEvent
        self.send("wrong_parking", {"zone": "np", "label": "Gate front", "cls": "motorbike",
                                    "seconds": 150})
        ShopEvent.objects.get(type="wrong_parking")
        rows = self.client.get("/api/v1/shop/events?site=%d" % self.site["id"],
                               HTTP_ACCEPT_LANGUAGE="en").data["events"]
        d = rows[0]["detect"]
        self.assertIn("Gate front", d["detail"])
        self.assertIn("motorbike", d["detail"])
