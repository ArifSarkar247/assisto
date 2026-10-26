"""cctv1 — Home & shop watchman phase 1.

Two-account end-to-end (owner + family viewer) on the backend: setup wizard →
camera added → gateway compatibility check (simulated gateway) → zones →
event → snapshot alert → mark wrong → thresholds adapt. Plus: errors
(unreachable / wrong code / rate limit), offline gateway, grouping, daily cap,
quiet hours, Imou (mocked), NO VIDEO on any CCTV upload endpoint, the
camera secret never stored, and the feature flag gate.
"""
import io
import json
import os
import shutil
import tempfile
from datetime import datetime, timedelta
from unittest import mock

from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import SimpleTestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient, APITestCase

from core.logic import watchman as WM
from core.models import User

_MEDIA = tempfile.mkdtemp(prefix="wm-media-")


def _jpeg(w=800, h=450):
    from PIL import Image
    b = io.BytesIO()
    Image.new("RGB", (w, h), (30, 80, 140)).save(b, "JPEG")
    return b.getvalue()


MP4 = b"\x00\x00\x00\x18ftypmp42\x00\x00\x00\x00mp42isom" + b"\x00" * 2048


# ============================================================ pure logic
class ZonesPureTests(SimpleTestCase):
    def test_valid_v2_config_normalised_and_legacy_cash_mirrored(self):
        out = WM.normalize_zone_config({
            "zones": [{"type": "cash", "points": [[0.1, 0.1], [0.5, 0.1], [0.5, 0.5]]},
                      {"type": "entry_line", "points": [[0, 0.9], [1.2, 0.9]]},
                      {"type": "restricted", "points": [[0.6, 0.6], [0.9, 0.6], [0.9, 0.9], [0.6, 0.9]]}],
            "schedule": {"days": [0, 6, 6], "start": "22:00", "end": "06:00"},
            "sensitivity": "high", "quiet_hours": {"start": "23:00", "end": "07:00"}},
            legacy={"hours": {"open": "09:00", "close": "21:00"}})
        self.assertEqual(out["v"], 2)
        self.assertEqual(out["cash_zone"], [[0.1, 0.1], [0.5, 0.1], [0.5, 0.5]])
        self.assertEqual(out["zones"][1]["points"][1], [1.0, 0.9])   # clamped
        self.assertEqual(out["schedule"]["days"], [0, 6])
        self.assertTrue(out["restricted_zone"])
        self.assertEqual(out["hours"]["open"], "09:00")              # legacy kept

    def test_bad_inputs_have_codes(self):
        cases = [
            ({"zones": [{"type": "cash", "points": [[0, 0], [1, 1]]}]}, "zone_needs_three_points"),
            ({"zones": [{"type": "entry_line", "points": [[0, 0]]}]}, "line_needs_two_points"),
            ({"zones": [{"type": "x", "points": []}]}, "bad_zone_type"),
            ({"zones": [{"type": "cash", "points": [["a", 1]] * 3}]}, "bad_point"),
            ({"zones": [{"type": "cash", "points": [[0, 0], [0, 1], [1, 1]]}] * 9}, "too_many_zones"),
            ({"schedule": {"days": [9], "start": "01:00", "end": "02:00"}}, "bad_schedule"),
            ({"schedule": {"days": [1], "start": "01:00", "end": "01:00"}}, "bad_schedule"),
            ({"sensitivity": "max"}, "bad_sensitivity"),
            ({"quiet_hours": {"start": "25:00", "end": "01:00"}}, "bad_quiet_hours"),
        ]
        for raw, code in cases:
            with self.assertRaises(WM.ZoneError) as cm:
                WM.normalize_zone_config(raw)
            self.assertEqual(cm.exception.code, code, raw)

    def test_overnight_schedule_belongs_to_start_day(self):
        sched = {"days": [4], "start": "22:00", "end": "06:00"}      # Friday night
        fri_23 = datetime(2026, 10, 23, 23, 0)                         # a Friday
        sat_05 = datetime(2026, 10, 24, 5, 0)
        sat_23 = datetime(2026, 10, 24, 23, 0)
        fri_12 = datetime(2026, 10, 23, 12, 0)
        self.assertTrue(WM.is_armed(sched, fri_23))
        self.assertTrue(WM.is_armed(sched, sat_05))
        self.assertFalse(WM.is_armed(sched, sat_23))
        self.assertFalse(WM.is_armed(sched, fri_12))
        self.assertTrue(WM.is_armed(None, fri_12))                    # no schedule = on guard
        self.assertTrue(WM.in_window({"start": "23:00", "end": "07:00"}, sat_05))
        self.assertFalse(WM.in_window({"start": "23:00", "end": "07:00"}, fri_12))

    def test_adaptive_thresholds_are_bounded(self):
        t = {}
        for _ in range(40):
            t = WM.adapt(t, "wrong")
        self.assertEqual(t["person_conf"], 0.85)
        self.assertEqual(t["motion_mult"], 3.0)
        self.assertEqual(t["cooldown_s"], 900)
        self.assertEqual(t["wrong"], 40)
        for _ in range(40):
            t = WM.adapt(t, "correct")
        # back toward the defaults — never MORE sensitive than the default
        self.assertGreaterEqual(t["person_conf"], 0.45)
        self.assertLess(t["person_conf"], 0.46)
        self.assertGreaterEqual(t["motion_mult"], 1.0)
        self.assertEqual(WM.adapt({}, "correct")["person_conf"], 0.45)


# ============================================================ API base
@override_settings(MEDIA_ROOT=_MEDIA)
class _Base(APITestCase):
    @classmethod
    def tearDownClass(cls):
        super().tearDownClass()
        shutil.rmtree(_MEDIA, ignore_errors=True)
        os.makedirs(_MEDIA, exist_ok=True)

    def setUp(self):
        self.owner = User.objects.create_user(name="Rahim", phone="01710002001",
                                              password="pw")
        self.owner.ai_credits = 500
        self.owner.language = "en"
        self.owner.save()
        self.family = User.objects.create_user(name="Karima", phone="01710002002",
                                               password="pw")
        self.family.language = "bn"
        self.family.save()
        self.client.force_authenticate(self.owner)
        self.pushes = []
        p = mock.patch("core.push.safe_push",
                       side_effect=lambda *a, **k: self.pushes.append((a, k)) or True)
        p.start()
        self.addCleanup(p.stop)

    def dev(self, token):
        c = APIClient()
        c.credentials(HTTP_X_SHOP_TOKEN=token)
        return c

    def setup_home(self, gateway="pc"):
        r = self.client.post("/api/v1/shop/watchman/setup",
                             {"kind": "home", "gateway": gateway, "name": "Home"},
                             format="json")
        self.assertEqual(r.status_code, 201, r.data)
        return r.data

    def add_camera(self, site_id, vendor="imou", name="Gate"):
        r = self.client.post("/api/v1/shop/sites/%d/cameras" % site_id,
                             {"name": name, "kind": "shopbox", "vendor": vendor,
                              "source": {"host": "192.168.1.20", "port": 554,
                                         "channel": 1, "password": "LEAK"}},
                             format="json")
        self.assertEqual(r.status_code, 201, r.data)
        return r.data


# ============================================================ setup wizard
class SetupTests(_Base):
    def test_empty_state_then_home_setup_on_personal_plan(self):
        r = self.client.get("/api/v1/shop/watchman")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.data["setup_needed"])
        self.assertEqual(r.data["sites"], [])
        self.assertFalse(r.data["can_shop"])
        self.assertNotIn("theft", json.dumps(r.data["notice"]).lower())
        self.assertNotIn("চুরি", json.dumps(r.data["notice"], ensure_ascii=False))
        site = self.setup_home()
        self.assertEqual(site["kind"], "home")
        self.assertEqual(site["gateway"], "pc")
        self.assertEqual(site["snapshot_retention_days"], 3)      # short default
        self.assertIn("enrollment_token", site)
        self.assertTrue(site["gateway_state"]["never_seen"])

    def test_shop_needs_business_plan_and_bad_inputs(self):
        r = self.client.post("/api/v1/shop/watchman/setup",
                             {"kind": "shop", "gateway": "shopbox"}, format="json")
        self.assertEqual(r.status_code, 402)
        self.assertEqual(r.data["error"], "plan_required")
        self.owner.plan = "business"
        self.owner.plan_until = timezone.now() + timedelta(days=30)
        self.owner.save()
        r = self.client.post("/api/v1/shop/watchman/setup",
                             {"kind": "shop", "gateway": "shopbox"}, format="json")
        self.assertEqual(r.status_code, 201)
        self.assertEqual(r.data["name"], "My shop")
        for body, code in (({"kind": "office", "gateway": "pc"}, "bad_kind"),
                           ({"kind": "home", "gateway": "tv"}, "bad_gateway")):
            r = self.client.post("/api/v1/shop/watchman/setup", body, format="json")
            self.assertEqual((r.status_code, r.data["error"]), (422, code))

    def test_camera_gets_default_v2_config_and_no_password_kept(self):
        site = self.setup_home()
        cam = self.add_camera(site["id"])
        self.assertEqual(cam["vendor"], "imou")
        self.assertTrue(cam["zones_v2"])
        self.assertNotIn("password", cam["source"])
        self.assertNotIn("LEAK", json.dumps(cam))
        # personal plan: 0 included -> the camera costs credits per 30 days
        self.assertGreater(cam["charged_credits"], 0)
        self.assertIsNotNone(cam["billed_until"])

    def test_feature_flag_off_hides_owner_endpoints(self):
        with mock.patch("core.watchman_views.feature_on", return_value=False):
            r = self.client.get("/api/v1/shop/watchman")
            self.assertEqual(r.status_code, 403)
            self.assertEqual(r.data["error"], "feature_off")


# ============================================================ gateway check
class GatewayCheckTests(_Base):
    def setUp(self):
        super().setUp()
        self.site = self.setup_home()
        self.cam = self.add_camera(self.site["id"])
        self.gw = self.dev(self.site["enrollment_token"])

    def _queue(self, **extra):
        body = {"secret": "L1ABCD", "host": "192.168.1.20", "channel": 1}
        body.update(extra)
        return self.client.post("/api/v1/shop/cameras/%d/check" % self.cam["id"],
                                body, format="json")

    def test_full_check_flow_secret_handed_over_once_and_never_stored(self):
        from core.models import ShopGatewayTask, ShopCamera
        r = self._queue()
        self.assertEqual(r.status_code, 201)
        self.assertNotIn("L1ABCD", json.dumps(r.data))            # owner never sees it
        self.assertFalse(r.data["gateway"]["online"])
        tid = r.data["id"]
        hb = self.gw.post("/api/v1/shop/heartbeat", {}, format="json")
        self.assertEqual(hb.data["tasks_pending"], 1)
        t = self.gw.get("/api/v1/shop/gateway/tasks")
        self.assertEqual(t.status_code, 200)
        self.assertEqual(t.data["tasks"][0]["request"]["secret"], "L1ABCD")
        self.assertEqual(t.data["tasks"][0]["request"]["vendor"], "imou")
        # wiped from OUR database at hand-out
        row = ShopGatewayTask.objects.get(pk=tid)
        self.assertNotIn("secret", row.request)
        self.assertEqual(row.status, "running")
        self.assertEqual(self.gw.get("/api/v1/shop/gateway/tasks").data["tasks"], [])
        for c in ShopCamera.objects.all():
            self.assertNotIn("L1ABCD", json.dumps([c.source, c.compat, c.zone_config,
                                                   c.device_info]))
        result = {"ok": True, "steps": [
            {"key": "reachable", "ok": True, "code": "", "detail": "tcp ok"},
            {"key": "auth", "ok": True, "code": "",
             "detail": "rtsp://admin:L1ABCD@192.168.1.20:554/cam opened"},
            {"key": "stream", "ok": True, "code": "", "detail": "1920x1080 @ 15fps"},
            {"key": "snapshot", "ok": True, "code": "", "detail": ""},
            {"key": "events", "ok": None, "code": "not_checked", "detail": ""},
            {"key": "bogus", "ok": True}],
            "info": {"width": 1920, "height": 1080, "fps": 15.0, "codec": "h264",
                     "onvif": True, "rtsp_path": "/cam/realmonitor?channel=1&subtype=1"}}
        r = self.gw.post("/api/v1/shop/gateway/tasks/%d/result" % tid,
                         {"result": json.dumps(result),
                          "snapshot": SimpleUploadedFile("p.jpg", _jpeg(), "image/jpeg")},
                         format="multipart")
        self.assertEqual(r.status_code, 200, r.data)
        st = self.client.get("/api/v1/shop/gateway/tasks/%d/status" % tid)
        self.assertEqual(st.data["status"], "done")
        self.assertTrue(st.data["result"]["ok"])
        self.assertEqual(len(st.data["result"]["steps"]), 5)      # unknown key dropped
        self.assertNotIn("L1ABCD", json.dumps(st.data))           # redacted detail
        self.assertTrue(st.data["gateway"]["online"])
        cam = ShopCamera.objects.get(pk=self.cam["id"])
        self.assertEqual(cam.compat["info"]["width"], 1920)
        self.assertTrue(cam.preview)
        from PIL import Image
        self.assertLessEqual(max(Image.open(cam.preview.path).size), 640)
        pv = self.client.get("/api/v1/shop/cameras/%d/preview" % cam.id)
        self.assertEqual(pv.status_code, 200)
        self.assertEqual(pv.data["source"], "check")
        # the gateway config carries the source + path, NEVER the secret
        cfg = self.gw.get("/api/v1/shop/config")
        blob = json.dumps(cfg.data)
        self.assertNotIn("L1ABCD", blob)
        c0 = cfg.data["cameras"][0]
        self.assertEqual(c0["source"]["vendor"], "imou")
        self.assertEqual(c0["source"]["rtsp_path"], "/cam/realmonitor?channel=1&subtype=1")
        self.assertIn("tuning", c0)
        self.assertEqual(c0["zones"]["v"], 2)

    def test_failed_check_unreachable_and_wrong_code_are_reported(self):
        tid = self._queue().data["id"]
        self.gw.get("/api/v1/shop/gateway/tasks")
        self.gw.post("/api/v1/shop/gateway/tasks/%d/result" % tid, {"result": json.dumps({
            "ok": False, "steps": [{"key": "reachable", "ok": True},
                                   {"key": "auth", "ok": False, "code": "auth_failed",
                                    "detail": "401 Unauthorized"}]})}, format="multipart")
        st = self.client.get("/api/v1/shop/gateway/tasks/%d/status" % tid).data
        self.assertFalse(st["result"]["ok"])
        self.assertEqual(st["result"]["steps"][1]["code"], "auth_failed")
        # retry: a new check is accepted
        self.assertEqual(self._queue(secret="L1RIGHT").status_code, 201)

    def test_input_errors(self):
        r = self._queue(secret="")
        self.assertEqual((r.status_code, r.data["error"]), (422, "code_required"))
        from core.models import ShopCamera
        ShopCamera.objects.filter(pk=self.cam["id"]).update(source={})
        r = self.client.post("/api/v1/shop/cameras/%d/check" % self.cam["id"],
                             {"secret": "x"}, format="json")
        self.assertEqual((r.status_code, r.data["error"]), (422, "host_required"))
        r = self.client.post("/api/v1/shop/cameras/999/check", {}, format="json")
        self.assertEqual(r.status_code, 404)

    def test_rate_limit_per_hour(self):
        with mock.patch("core.shop_views.watchman_cfg",
                        side_effect=lambda k, d: 2 if k == "watchman_tasks_per_hour" else d):
            self.assertEqual(self._queue().status_code, 201)
            self.assertEqual(self._queue().status_code, 201)
            r = self._queue()
            self.assertEqual((r.status_code, r.data["error"]), (429, "rate_limited"))

    def test_offline_gateway_task_expires_and_secret_is_wiped(self):
        from core.models import ShopGatewayTask
        tid = self._queue().data["id"]
        ShopGatewayTask.objects.filter(pk=tid).update(
            created=timezone.now() - timedelta(minutes=11))
        st = self.client.get("/api/v1/shop/gateway/tasks/%d/status" % tid).data
        self.assertEqual(st["status"], "expired")
        self.assertEqual(st["result"]["code"], "gateway_no_answer")
        self.assertTrue(st["gateway"]["never_seen"])
        self.assertNotIn("secret", ShopGatewayTask.objects.get(pk=tid).request)
        # overview: honest "gateway offline since X"
        from core.models import ShopSite
        seen = timezone.now() - timedelta(hours=2)
        ShopSite.objects.filter(pk=self.site["id"]).update(last_seen=seen)
        ov = self.client.get("/api/v1/shop/watchman").data["sites"][0]["gateway_state"]
        self.assertFalse(ov["online"])
        self.assertEqual(ov["offline_since"], seen.isoformat())

    def test_phone_gateway_cannot_check_lan_cameras(self):
        site = self.setup_home(gateway="phone")
        cam = self.add_camera(site["id"], vendor="hikvision")
        r = self.client.post("/api/v1/shop/cameras/%d/check" % cam["id"],
                             {"secret": "x", "host": "192.168.1.30"}, format="json")
        self.assertEqual((r.status_code, r.data["error"]), (409, "gateway_cannot_check"))

    def test_discover_task_results(self):
        r = self.client.post("/api/v1/shop/sites/%d/discover" % self.site["id"])
        self.assertEqual(r.status_code, 201)
        self.gw.get("/api/v1/shop/gateway/tasks")
        self.gw.post("/api/v1/shop/gateway/tasks/%d/result" % r.data["id"], {
            "result": json.dumps({"ok": True, "discovered": [
                {"host": "192.168.1.20", "xaddr": "http://u:p@192.168.1.20/onvif/device_service",
                 "manufacturer": "Dahua", "model": "IPC"},
                {"host": "bad host;rm", "xaddr": ""}]})}, format="multipart")
        st = self.client.get("/api/v1/shop/gateway/tasks/%d/status" % r.data["id"]).data
        self.assertEqual(len(st["result"]["discovered"]), 1)
        self.assertNotIn("u:p@", json.dumps(st))

    def test_camera_token_cannot_pull_gateway_secrets(self):
        from core.models import ShopCamera
        self._queue()
        cam_tok = ShopCamera.objects.get(pk=self.cam["id"]).camera_token
        r = self.dev(cam_tok).get("/api/v1/shop/gateway/tasks")
        self.assertEqual(r.status_code, 401)

    def test_other_site_token_cannot_read_or_answer_tasks(self):
        tid = self._queue().data["id"]
        other = User.objects.create_user(name="X", phone="01710002099", password="pw")
        from core.models import ShopSite
        s2 = ShopSite.objects.create(owner=other, name="Other")
        bad = self.dev(s2.enrollment_token)
        self.assertEqual(bad.get("/api/v1/shop/gateway/tasks").data["tasks"], [])
        r = bad.post("/api/v1/shop/gateway/tasks/%d/result" % tid,
                     {"result": "{}"}, format="multipart")
        self.assertEqual(r.status_code, 404)


# ============================================================ alerts
class AlertPipelineTests(_Base):
    def setUp(self):
        super().setUp()
        self.site = self.setup_home()
        self.cam = self.add_camera(self.site["id"], name="Front door")
        from core.models import ShopCamera
        self.camobj = ShopCamera.objects.get(pk=self.cam["id"])
        self.camdev = self.dev(self.camobj.camera_token)

    def _ingest(self, etype="person_detected", snap=True, **sig):
        data = {"type": etype, "signals": json.dumps(dict({"person": True, "conf": 0.7}, **sig))}
        if snap:
            data["snapshot"] = SimpleUploadedFile("s.jpg", _jpeg(), "image/jpeg")
        return self.camdev.post("/api/v1/shop/ingest", data, format="multipart")

    def _zones(self, **cfg):
        body = {"zones": [], "schedule": None, "sensitivity": "medium",
                "quiet_hours": None}
        body.update(cfg)
        return self.client.put("/api/v1/shop/cameras/%d/zones" % self.cam["id"],
                               {"zone_config": body}, format="json")

    def test_two_account_e2e_alert_viewer_and_mark_wrong(self):
        from core.models import FamilyAlert, ShopEvent, ShopCamera
        # owner adds the family viewer by phone
        r = self.client.post("/api/v1/shop/sites/%d/viewers" % self.site["id"],
                             {"phone": "01710002002"}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        self.assertNotIn("01710002002", json.dumps(r.data))         # masked
        self.pushes.clear()                       # (the "shared with you" push)
        # zones drawn on the snapshot
        z = self._zones(zones=[{"type": "restricted",
                                "points": [[0.1, 0.1], [0.6, 0.1], [0.6, 0.7]]}])
        self.assertEqual(z.status_code, 200, z.data)
        # a person seen while on guard -> ONE alert with ONE snapshot
        r = self._ingest()
        self.assertEqual(r.status_code, 201, r.data)
        ev = ShopEvent.objects.get(pk=r.data["event_id"])
        self.assertTrue(ev.snapshot)
        # both accounts are told, in their own language, never accusatory
        fa_owner = FamilyAlert.objects.get(user=self.owner, kind="shop_guard")
        fa_family = FamilyAlert.objects.get(user=self.family, kind="shop_guard")
        self.assertIn("Suspicious — please check", fa_owner.title)
        self.assertIn("সন্দেহজনক — একটু দেখে নিন", fa_family.title)
        for fa in (fa_owner, fa_family):
            self.assertNotIn("theft", (fa.title + fa.body).lower())
            self.assertNotIn("চুরি", fa.title + fa.body)
        self.assertEqual(len(self.pushes), 2)
        data = self.pushes[0][1]["data"]
        self.assertEqual(data["label"], "suspicious_please_check")
        self.assertIn("/api/v1/m/", data["snapshot_url"])            # signed link
        # the viewer sees the site + the alert, read-only
        fam = APIClient()
        fam.force_authenticate(self.family)
        ov = fam.get("/api/v1/shop/watchman").data
        self.assertEqual(ov["sites"][0]["role"], "viewer")
        self.assertNotIn("enrollment_token", ov["sites"][0])
        evs = fam.get("/api/v1/shop/events?site=%d" % self.site["id"]).data
        self.assertEqual(evs["role"], "viewer")
        self.assertEqual(evs["events"][0]["label"], "suspicious_please_check")
        self.assertTrue(evs["events"][0]["snapshot_url"])
        # viewer cannot mark, change zones or queue checks
        self.assertEqual(fam.post("/api/v1/shop/events/%d/mark" % ev.id,
                                  {"status": "wrong"}, format="json").status_code, 404)
        self.assertEqual(fam.put("/api/v1/shop/cameras/%d/zones" % self.cam["id"],
                                 {"zone_config": {}}, format="json").status_code, 404)
        # owner marks WRONG -> stored + this camera's thresholds adapt
        m = self.client.post("/api/v1/shop/events/%d/mark" % ev.id,
                             {"status": "wrong"}, format="json")
        self.assertEqual(m.data["status"], "false_alarm")
        self.assertEqual(m.data["tuning"]["wrong"], 1)
        self.assertAlmostEqual(m.data["tuning"]["person_conf"], 0.5)
        cam = ShopCamera.objects.get(pk=self.cam["id"])
        self.assertEqual(cam.tuning["cooldown_s"], 240)
        cfg = self.camdev.get("/api/v1/shop/config").data["cameras"][0]
        self.assertAlmostEqual(cfg["tuning"]["person_conf"], 0.5)
        # marking the same verdict again does not adapt twice
        m2 = self.client.post("/api/v1/shop/events/%d/mark" % ev.id,
                              {"status": "wrong"}, format="json")
        self.assertIsNone(m2.data["tuning"])
        # viewer leaves
        r = fam.delete("/api/v1/shop/sites/%d/viewers/%d" % (self.site["id"], self.family.id))
        self.assertEqual(r.status_code, 200)
        self.assertEqual(fam.get("/api/v1/shop/watchman").data["sites"], [])

    def test_viewer_unknown_phone_and_self(self):
        r = self.client.post("/api/v1/shop/sites/%d/viewers" % self.site["id"],
                             {"phone": "01799999999"}, format="json")
        self.assertEqual((r.status_code, r.data["error"]), (404, "user_not_found"))
        r = self.client.post("/api/v1/shop/sites/%d/viewers" % self.site["id"],
                             {"phone": "01710002001"}, format="json")
        self.assertEqual((r.status_code, r.data["error"]), (409, "is_owner"))

    def test_outside_armed_schedule_nothing_is_raised(self):
        now = timezone.localtime()
        start = (now + timedelta(hours=2)).strftime("%H:%M")
        end = (now + timedelta(hours=3)).strftime("%H:%M")
        self._zones(schedule={"days": list(range(7)), "start": start, "end": end})
        r = self._ingest()
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.data["raised"])
        self.assertEqual(r.data["reason_signals"], ["not_armed"])

    def test_device_cannot_claim_armed_on_a_legacy_camera(self):
        from core.models import ShopCamera
        ShopCamera.objects.filter(pk=self.cam["id"]).update(zone_config={})
        r = self._ingest(armed=True)
        self.assertFalse(r.data["raised"])

    def test_grouping_same_camera_type_one_alert_with_count(self):
        from core.models import ShopEvent, FamilyAlert
        a = self._ingest()
        b = self._ingest()
        self.assertEqual(a.status_code, 201)
        self.assertEqual(b.status_code, 200)
        self.assertTrue(b.data["grouped"])
        self.assertEqual(b.data["count"], 2)
        self.assertEqual(ShopEvent.objects.count(), 1)
        self.assertEqual(FamilyAlert.objects.filter(user=self.owner).count(), 1)
        ev = self.client.get("/api/v1/shop/events?site=%d" % self.site["id"]).data["events"][0]
        self.assertEqual(ev["count"], 2)

    def test_daily_cap_holds_extra_alerts_honestly(self):
        with mock.patch("core.shop_views.watchman_cfg",
                        side_effect=lambda k, d: 1 if k == "watchman_daily_alert_cap" else d):
            self.assertEqual(self._ingest().status_code, 201)
            r = self._ingest("zone_intrusion", zone_breach=True)
            self.assertFalse(r.data["raised"])
            self.assertEqual(r.data["held"], "daily_cap")
        ov = self.client.get("/api/v1/shop/watchman").data["sites"][0]
        self.assertEqual(ov["held_today"], 1)

    def test_quiet_hours_save_the_alert_but_push_nothing(self):
        from core.models import ShopEvent
        now = timezone.localtime()
        self._zones(quiet_hours={"start": (now - timedelta(hours=1)).strftime("%H:%M"),
                                 "end": (now + timedelta(hours=1)).strftime("%H:%M")})
        r = self._ingest()
        self.assertEqual(r.status_code, 201)
        self.assertEqual(ShopEvent.objects.count(), 1)
        self.assertEqual(self.pushes, [])

    def test_zone_intrusion_needs_a_breach(self):
        self.assertFalse(self._ingest("zone_intrusion").data["raised"])
        r = self._ingest("zone_intrusion", zone_breach=True)
        self.assertTrue(r.data["raised"])
        self.assertGreaterEqual(r.data["confidence"], 0.75)

    def test_zone_errors_are_honest(self):
        r = self._zones(zones=[{"type": "entry_line", "points": [[0.1, 0.1]]}])
        self.assertEqual((r.status_code, r.data["error"]), (422, "line_needs_two_points"))
        self.assertIn("2", r.data["detail"])


# ============================================================ no video, ever
@override_settings(MEDIA_ROOT=_MEDIA)
class NoVideoTests(_Base):
    def setUp(self):
        super().setUp()
        self.site = self.setup_home()
        self.cam = self.add_camera(self.site["id"])
        from core.models import ShopCamera
        self.camobj = ShopCamera.objects.get(pk=self.cam["id"])

    def _videos(self):
        return [SimpleUploadedFile("clip.mp4", MP4, "video/mp4"),
                SimpleUploadedFile("snap.jpg", MP4, "image/jpeg"),   # lying label
                SimpleUploadedFile("clip.webm", b"\x1aE\xdf\xa3" + b"\x00" * 600,
                                   "application/octet-stream")]

    def test_ingest_refuses_every_video(self):
        dev = self.dev(self.camobj.camera_token)
        for v in self._videos():
            r = dev.post("/api/v1/shop/ingest", {"type": "person_detected",
                                                 "snapshot": v}, format="multipart")
            self.assertEqual(r.status_code, 415, v.name)
            self.assertEqual(r.data["error"], "video_not_accepted")
        r = dev.post("/api/v1/shop/ingest", {"type": "person_detected",
                                             "clip": SimpleUploadedFile("c.mp4", MP4, "video/mp4")},
                     format="multipart")
        self.assertEqual(r.status_code, 415)

    def test_gateway_result_refuses_video(self):
        from core.models import ShopGatewayTask
        t = ShopGatewayTask.objects.create(site=self.camobj.site, camera=self.camobj,
                                           action="check", status="running")
        dev = self.dev(self.site["enrollment_token"])
        for v in self._videos():
            r = dev.post("/api/v1/shop/gateway/tasks/%d/result" % t.id,
                         {"result": "{}", "snapshot": v}, format="multipart")
            self.assertEqual(r.status_code, 415, v.name)

    def test_no_cctv_upload_endpoint_stores_video(self):
        """Every CCTV (shop/*) POST route gets a multipart video; none may
        store it. Afterwards no file under MEDIA_ROOT looks like a video."""
        from core.models import ShopGatewayTask
        ShopGatewayTask.objects.create(site=self.camobj.site, camera=self.camobj,
                                       action="check", status="running")
        routes = []
        from core import urls as U
        for p in U.urlpatterns:
            r = str(p.pattern)
            if r.startswith("shop/"):
                routes.append(r)
        self.assertGreater(len(routes), 20)
        dev = self.dev(self.site["enrollment_token"])
        for r in routes:
            url = "/api/v1/" + (r.replace("<int:pk>", str(self.camobj.id))
                                .replace("<int:uid>", "1")
                                .replace("<str:vendor>", "hikvision")
                                .replace("<str:camera_token>", self.camobj.camera_token)
                                .replace("<str:token>", "x"))
            for c in (self.client, dev):
                c.post(url, {"snapshot": SimpleUploadedFile("v.mp4", MP4, "video/mp4"),
                             "file": SimpleUploadedFile("v.mp4", MP4, "video/mp4"),
                             "type": "person_detected", "result": "{}"},
                       format="multipart")
        from core.shop_views import looks_like_video, VIDEO_EXTS
        for root, _d, files in os.walk(_MEDIA):
            for f in files:
                self.assertFalse(f.lower().endswith(VIDEO_EXTS), f)
                with open(os.path.join(root, f), "rb") as fh:
                    self.assertFalse(looks_like_video(fh.read(1024)), f)

    def test_models_have_no_video_field(self):
        from core.models import ShopEvent, ShopCamera, ShopGatewayTask, ShopSite
        for m in (ShopEvent, ShopCamera, ShopGatewayTask, ShopSite):
            names = {f.name for f in m._meta.get_fields()}
            self.assertFalse(any("video" in n or "clip" in n for n in names), m)


# ============================================================ Imou
class ImouTests(_Base):
    def setUp(self):
        super().setUp()
        self.site = self.setup_home()
        self.cam = self.add_camera(self.site["id"], vendor="imou")

    def test_sign_matches_imou_formula(self):
        import hashlib
        from core.logic.imou import sign
        self.assertEqual(sign(1700000000, "abc", "S3CR3T"), hashlib.md5(
            b"time:1700000000,nonce:abc,appSecret:S3CR3T").hexdigest())

    def test_link_without_keys_is_honest(self):
        r = self.client.post("/api/v1/shop/cameras/%d/imou" % self.cam["id"],
                             {"device_serial": "8F0ABC", "safety_code": "L1X"},
                             format="json")
        self.assertEqual((r.status_code, r.data["error"]), (503, "imou_not_configured"))

    def _fake_http(self, calls, fail=None):
        def http(url, body, timeout):
            method = url.rsplit("/", 1)[1]
            calls.append((method, json.loads(body)))
            if fail and method == fail:
                return 200, json.dumps({"result": {"code": "DV9999", "msg": "no"}})
            data = {"accessToken": "T", "expireTime": 3600} if method == "accessToken" else {}
            return 200, json.dumps({"result": {"code": "0", "data": data}})
        return http

    def test_link_then_callback_alarm_becomes_alert(self):
        from core.logic import imou as IM
        from core.models import ShopCamera, ShopEvent
        IM._token_cache.clear()
        calls = []
        client = IM.ImouClient("APPID", "SECRET", http=self._fake_http(calls))
        with mock.patch("core.watchman_views.imou_cloud_on", return_value=True), \
                mock.patch("core.logic.imou.ImouClient.from_integration",
                           return_value=client):
            r = self.client.post("/api/v1/shop/cameras/%d/imou" % self.cam["id"],
                                 {"device_serial": "8f0abc", "safety_code": "L1X"},
                                 format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertTrue(r.data["camera"]["cloud_alarms"])
        methods = [m for m, _ in calls]
        self.assertIn("bindDevice", methods)
        self.assertIn("setMessageCallback", methods)
        cam = ShopCamera.objects.get(pk=self.cam["id"])
        self.assertEqual(cam.vendor_ref, "8F0ABC:0")
        self.assertNotIn("L1X", json.dumps([cam.source, cam.compat]))   # code not stored
        tok = IM.callback_token("APPID", "x")
        with mock.patch("core.watchman_views.imou_cloud_on", return_value=True), \
                mock.patch("core.integrations.get", return_value={"app_id": "APPID"}), \
                mock.patch("core.logic.imou.callback_token", return_value=tok), \
                mock.patch("core.logic.imou.fetch_snapshot", return_value=_jpeg()):
            bad = self.client.post("/api/v1/shop/imou/callback/wrong", {}, format="json")
            self.assertEqual(bad.status_code, 404)
            ok = APIClient().post("/api/v1/shop/imou/callback/%s" % tok,
                                  json.dumps({"msgType": "alarm", "did": "8F0ABC", "cid": "0",
                                              "labelType": "human",
                                              "picurlArray": ["https://x.easy4ip.com/a.jpg"]}),
                                  content_type="application/json")
            self.assertEqual(ok.status_code, 200)
            self.assertTrue(ok.data["events"][0]["raised"])
            st = APIClient().post("/api/v1/shop/imou/callback/%s" % tok,
                                  json.dumps({"msgType": "deviceStatus", "did": "8F0ABC"}),
                                  content_type="application/json")
            self.assertEqual(st.data["events"][0]["ignored"], "not_alarm")
        ev = ShopEvent.objects.get()
        self.assertEqual(ev.type, "camera_alarm")
        self.assertFalse(ev.possible)
        self.assertTrue(ev.snapshot)

    def test_link_failure_is_explained(self):
        from core.logic import imou as IM
        IM._token_cache.clear()
        calls = []
        client = IM.ImouClient("APPID2", "S", http=self._fake_http(calls, fail="bindDevice"))
        with mock.patch("core.watchman_views.imou_cloud_on", return_value=True), \
                mock.patch("core.logic.imou.ImouClient.from_integration",
                           return_value=client), \
                mock.patch.object(IM.ImouClient, "device_online",
                                  side_effect=IM.ImouError("DV1")):
            r = self.client.post("/api/v1/shop/cameras/%d/imou" % self.cam["id"],
                                 {"device_serial": "8F0ABC", "safety_code": "BAD"},
                                 format="json")
        self.assertEqual((r.status_code, r.data["error"]), (502, "imou_error"))
        self.assertIn("gateway", r.data["detail"])

    def test_snapshot_host_allowlist(self):
        from core.logic.imou import snapshot_url_allowed
        self.assertTrue(snapshot_url_allowed("https://cdn.easy4ip.com/p.jpg"))
        self.assertFalse(snapshot_url_allowed("http://cdn.easy4ip.com/p.jpg"))
        self.assertFalse(snapshot_url_allowed("https://169.254.169.254/latest"))
        self.assertFalse(snapshot_url_allowed("https://easy4ip.com.evil.io/p.jpg"))

    def test_integration_registered_with_test(self):
        from core import integrations as I
        self.assertIn("imou", I.REGISTRY)
        ok, _ = I.test_imou({"app_id": "A", "app_secret": "B"},
                            http=self._fake_http([]))
        self.assertTrue(ok)


class PrivacyTextTests(APITestCase):
    def test_privacy_policy_explains_cctv_snapshots_en_bn(self):
        from django.test import Client
        en = Client().get("/privacy?lang=en").content.decode()
        self.assertIn("CCTV watchman", en)
        self.assertIn("never keeps video", en)
        self.assertIn("3 days by default", en)
        bn = Client().get("/privacy").content.decode()
        self.assertIn("সিসিটিভি ওয়াচম্যান", bn)
        self.assertIn("কখনো ভিডিও রাখা হয় না", bn)
        app_en = str(Client().get("/api/v1/legal/privacy",
                                  HTTP_ACCEPT_LANGUAGE="en").json())
        self.assertIn("CCTV watchman", app_en)
        app_bn = str(Client().get("/api/v1/legal/privacy",
                                  HTTP_ACCEPT_LANGUAGE="bn").json())
        self.assertIn("সিসিটিভি", app_bn)
