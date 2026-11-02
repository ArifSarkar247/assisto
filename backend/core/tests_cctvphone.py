"""cctvphone: an old Android phone as an Assisto camera — pairing code + QR
link, claim (plan cap), unbind, health warnings (charger / battery / heat /
dark), live view (viewers allowed by the owner, SD/HD message, 5-min idle
stop, max 2 live views per account)."""
from datetime import timedelta
from unittest import mock

from django.test import SimpleTestCase
from django.utils import timezone
from rest_framework.test import APIClient, APITestCase

from core.logic import phonecam as PC
from core.models import User


class PureLogicTests(SimpleTestCase):
    def test_code_roundtrip_and_window(self):
        code, valid = PC.pair_code("s3cret", 12, 7, 1_000_000)
        self.assertTrue(code.startswith("12-"))
        self.assertEqual(len(code.split("-")[1]), PC.CODE_LEN)
        self.assertGreater(valid, PC.WINDOW_S - 1)
        self.assertTrue(PC.code_valid("s3cret", code, 12, 7, 1_000_000))
        # still valid in the next window, dead after that
        self.assertTrue(PC.code_valid("s3cret", code, 12, 7, 1_000_000 + PC.WINDOW_S))
        self.assertFalse(PC.code_valid("s3cret", code, 12, 7, 1_000_000 + 3 * PC.WINDOW_S))
        # other site / owner / secret -> invalid
        self.assertFalse(PC.code_valid("s3cret", code, 13, 7, 1_000_000))
        self.assertFalse(PC.code_valid("s3cret", code, 12, 8, 1_000_000))
        self.assertFalse(PC.code_valid("other", code, 12, 7, 1_000_000))

    def test_normalize_accepts_link_spaces_case(self):
        code, _ = PC.pair_code("k", 5, 1, 0)
        tail = code.split("-")[1]
        self.assertEqual(PC.normalize_code(PC.pair_link(code)), code)
        self.assertEqual(PC.normalize_code(" 5 %s " % tail.lower()), code)
        self.assertEqual(PC.normalize_code("5%s" % tail), code)
        self.assertIsNone(PC.normalize_code("abc"))
        self.assertIsNone(PC.normalize_code("5-AAAA0O"))   # 0/O not in alphabet
        self.assertIsNone(PC.normalize_code(None))
        self.assertEqual(PC.code_site(code), 5)

    def test_health_warnings_once_then_again_after_clear(self):
        h = PC.clean_health({"level": 15, "charging": False, "temp_c": 47.5})
        kinds, w = PC.health_warnings(h, {}, 1000)
        self.assertEqual(kinds, ["unplugged", "low_battery", "hot"])
        kinds2, w2 = PC.health_warnings(h, w, 1060)
        self.assertEqual(kinds2, [])                     # no repeat inside 30 min
        kinds3, _ = PC.health_warnings(h, w2, 1000 + PC.WARN_REPEAT_S)
        self.assertEqual(kinds3, ["unplugged", "low_battery", "hot"])
        ok = PC.clean_health({"level": 80, "charging": True, "temp_c": 30})
        k4, w4 = PC.health_warnings(ok, w2, 1100)
        self.assertEqual((k4, w4), ([], {}))             # cleared -> forgotten
        k5, _ = PC.health_warnings(h, w4, 1200)
        self.assertIn("unplugged", k5)

    def test_health_clean_bounds_and_dark(self):
        self.assertIsNone(PC.clean_health("x"))
        h = PC.clean_health({"level": 500, "charging": "yes", "temp_c": True, "dark": True})
        self.assertEqual(h, {"level": None, "charging": None, "temp_c": None, "dark": True})
        self.assertEqual(PC.active_conditions(h), {"dark"})
        # charging + low battery is fine (it is filling up)
        self.assertEqual(PC.active_conditions(
            PC.clean_health({"level": 5, "charging": True})), set())

    def test_warning_texts_bn_en_no_accusation(self):
        for k in PC.WARN_KINDS:
            parts = PC.warning_text(k, "Gate", {"temp_c": 48})
            self.assertEqual(len(parts), 4)
            for p in parts:
                self.assertNotIn("চুরি", p)
                self.assertNotIn("theft", p.lower())

    def test_idle_expiry_and_slots(self):
        self.assertEqual(PC.idle_expiry(0, 100, 600, 300), 400)
        self.assertEqual(PC.idle_expiry(0, 500, 600, 300), 600)   # hard cap
        self.assertTrue(PC.live_slot_free(1))
        self.assertFalse(PC.live_slot_free(2))
        self.assertEqual(PC.clean_quality({"hd": True}), {"hd": True})
        self.assertIsNone(PC.clean_quality({"hd": "1"}))


class _Base(APITestCase):
    def setUp(self):
        from core.models import ShopSite, ShopSiteViewer
        p = mock.patch("core.credits._base_allowance", return_value=0)
        p.start()
        self.addCleanup(p.stop)
        self.owner = User.objects.create_user(name="Owner", phone="01710002001",
                                              password="pw")
        self.owner.plan = "business"
        self.owner.plan_until = timezone.now() + timedelta(days=30)
        self.owner.ai_credits = 100
        self.owner.language = "en"
        self.owner.save()
        self.viewer = User.objects.create_user(name="Wife", phone="01710002002",
                                               password="pw")
        self.stranger = User.objects.create_user(name="X", phone="01710002003",
                                                 password="pw")
        self.site = ShopSite.objects.create(owner=self.owner, name="Home", kind="home")
        ShopSiteViewer.objects.create(site=self.site, user=self.viewer)
        self.client.force_authenticate(self.owner)

    def code(self):
        r = self.client.get("/api/v1/shop/phonecam/pair?site=%d" % self.site.id)
        self.assertEqual(r.status_code, 200, r.data)
        return r.data

    def claim(self, code, **extra):
        return APIClient().post("/api/v1/shop/phonecam/claim",
                                dict({"code": code, "model": "Redmi 5"}, **extra),
                                format="json")


class PairingTests(_Base):
    def test_pair_code_link_and_claim_creates_phone_camera(self):
        from core.models import ShopCamera, NotifEvent
        d = self.code()
        self.assertTrue(d["link"].startswith("https://lifeassisto.com/pc/"))
        self.assertTrue(d["link"].endswith(d["code"]))
        self.assertIn("included", d)
        r = self.claim(d["link"])                       # the scanned link works too
        self.assertEqual(r.status_code, 201, r.data)
        cam = ShopCamera.objects.get(pk=r.data["camera"]["id"])
        self.assertEqual((cam.vendor, cam.kind, cam.site_id), ("phone", "shopbox", self.site.id))
        self.assertEqual(r.data["camera_token"], cam.camera_token)
        self.assertEqual(cam.zone_config.get("v"), 2)   # watchman schedule applies
        self.assertTrue(NotifEvent.objects.filter(user=self.owner,
                                                  meta__kind="paired").exists())
        # listed back to the owner, without the code hash
        d2 = self.code()
        self.assertEqual(len(d2["cameras"]), 1)
        self.assertNotIn("pair_sha", d2["cameras"][0]["source"])
        self.assertIn("pair_sha", ShopCamera.objects.get(pk=cam.pk).source)

    def test_code_is_single_use_and_next_phone_gets_a_new_code(self):
        code = self.code()["code"]
        self.assertEqual(self.claim(code).status_code, 201)
        r = self.claim(code)
        self.assertIn(r.data["error"], ("bad_code", "code_used"))
        code2 = self.code()["code"]
        self.assertNotEqual(code, code2)
        self.assertEqual(self.claim(code2).status_code, 201)

    def test_spent_code_refused_even_if_newest_camera_deleted(self):
        from core.models import ShopCamera
        code = self.code()["code"]
        self.assertEqual(self.claim(code).status_code, 201)
        # the code hash stays on the claimed camera -> refused while it exists
        cam = ShopCamera.objects.get(vendor="phone")
        with mock.patch("core.phonecam_views.pair_nonce", return_value=0):
            r = self.claim(code)
        self.assertEqual((r.status_code, r.data["error"]), (409, "code_used"))
        self.assertTrue(ShopCamera.objects.filter(pk=cam.pk).exists())

    def test_wrong_code_and_other_owner(self):
        r = self.claim("%d-AAAAAA" % self.site.id)
        self.assertEqual((r.status_code, r.data["error"]), (400, "bad_code"))
        self.client.force_authenticate(self.stranger)
        r = self.client.get("/api/v1/shop/phonecam/pair?site=%d" % self.site.id)
        self.assertEqual(r.status_code, 404)

    def test_counts_against_the_plan_cap(self):
        code = self.code()["code"]
        self.owner.ai_credits = 0
        self.owner.save()
        with mock.patch("core.shop_views._included_cameras", return_value=0):
            r = self.claim(code)
        self.assertEqual((r.status_code, r.data["error"]), (402, "camera_cap"))

    def test_flag_off_hides_pairing(self):
        with mock.patch("core.phonecam_views.flag_on", return_value=False):
            r = self.client.get("/api/v1/shop/phonecam/pair?site=%d" % self.site.id)
        self.assertEqual((r.status_code, r.data["error"]), (403, "feature_off"))

    def test_unbind_from_the_camera_phone(self):
        from core.models import ShopCamera
        tok = self.claim(self.code()["code"]).data["camera_token"]
        r = APIClient().post("/api/v1/shop/phonecam/unbind", {},
                             HTTP_X_SHOP_TOKEN=tok, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertFalse(ShopCamera.objects.filter(vendor="phone").exists())
        r = APIClient().post("/api/v1/shop/phonecam/unbind", {},
                             HTTP_X_SHOP_TOKEN="nope", format="json")
        self.assertEqual(r.status_code, 404)

    def test_web_landing_shows_code(self):
        code = self.code()["code"]
        r = APIClient().get("/pc/%s" % code)
        self.assertEqual(r.status_code, 200)
        self.assertIn(code, r.content.decode())
        self.assertEqual(r["X-Robots-Tag"], "noindex, nofollow")


class HealthTests(_Base):
    def test_unplugged_pushes_owner_and_viewer_once(self):
        from core.models import NotifEvent, ShopCamera
        tok = self.claim(self.code()["code"]).data["camera_token"]
        body = {"camera_token": tok, "caps": ["live"],
                "health": {"level": 60, "charging": False, "temp_c": 31}}
        r = APIClient().post("/api/v1/shop/heartbeat", body, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        for u in (self.owner, self.viewer):
            self.assertEqual(NotifEvent.objects.filter(
                user=u, meta__kind="unplugged").count(), 1)
        APIClient().post("/api/v1/shop/heartbeat", body, format="json")
        self.assertEqual(NotifEvent.objects.filter(meta__kind="unplugged").count(), 2)
        cam = ShopCamera.objects.get(camera_token=tok)
        self.assertEqual(cam.source["health"]["level"], 60)
        # hot + dark
        body["health"] = {"level": 60, "charging": True, "temp_c": 46, "dark": True}
        APIClient().post("/api/v1/shop/heartbeat", body, format="json")
        self.assertTrue(NotifEvent.objects.filter(user=self.viewer, meta__kind="hot").exists())
        self.assertTrue(NotifEvent.objects.filter(user=self.owner, meta__kind="dark").exists())

    def test_non_phone_camera_ignores_health(self):
        from core.models import ShopCamera, NotifEvent
        cam = ShopCamera.objects.create(site=self.site, name="Shop box", kind="shopbox")
        APIClient().post("/api/v1/shop/heartbeat",
                         {"camera_token": cam.camera_token,
                          "health": {"charging": False}}, format="json")
        self.assertFalse(NotifEvent.objects.filter(meta__source="phonecam").exists())


class LiveTests(_Base):
    def _phone(self):
        from core.models import ShopCamera
        tok = self.claim(self.code()["code"]).data["camera_token"]
        APIClient().post("/api/v1/shop/heartbeat",
                         {"camera_token": tok, "caps": ["live"]}, format="json")
        return ShopCamera.objects.get(camera_token=tok)

    def _start(self, cam, who=None):
        c = APIClient()
        c.force_authenticate(who or self.owner)
        with mock.patch("core.logic.rtc.throttle_decision",
                        return_value={"throttled": False, "reason": ""}):
            return c.post("/api/v1/shop/live/start", {"camera": cam.id}, format="json")

    def test_viewer_may_watch_unless_owner_switches_off(self):
        cam = self._phone()
        r = self._start(cam, self.viewer)
        self.assertEqual(r.status_code, 201, r.data)
        self.assertEqual(r.data["idle_seconds"], PC.LIVE_IDLE_S)
        r = self.client.patch("/api/v1/shop/phonecam/%d" % cam.id,
                              {"viewers_live": False}, format="json")
        self.assertEqual((r.status_code, r.data["viewers_live"]), (200, False))
        r = self._start(cam, self.viewer)
        self.assertEqual((r.status_code, r.data["error"]), (403, "viewer_live_off"))
        self.assertEqual(self._start(cam, self.stranger).status_code, 404)

    def test_max_two_live_views_per_account(self):
        cams = [self._phone() for _ in range(3)]
        self.assertEqual(self._start(cams[0]).status_code, 201)
        self.assertEqual(self._start(cams[1], self.viewer).status_code, 201)
        r = self._start(cams[2])
        self.assertEqual((r.status_code, r.data["error"]), (429, "live_limit"))
        # re-opening the SAME camera replaces its session (not a third stream)
        self.assertEqual(self._start(cams[0]).status_code, 201)

    def test_idle_expiry_and_touch(self):
        from core.models import ShopLiveSession
        cam = self._phone()
        sid = self._start(cam).data["id"]
        s = ShopLiveSession.objects.get(pk=sid)
        span = (s.expires_at - s.created).total_seconds()
        self.assertLessEqual(span, PC.LIVE_IDLE_S + 2)
        # an ANSWERED session 200 s old (a pending one is swept after 45 s)
        ShopLiveSession.objects.filter(pk=sid).update(
            status="active", answered_at=timezone.now() - timedelta(seconds=190),
            created=timezone.now() - timedelta(seconds=200),
            expires_at=timezone.now() + timedelta(seconds=100))
        r = self.client.post("/api/v1/shop/live/%d/touch" % sid, {}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        s.refresh_from_db()
        left = (s.expires_at - timezone.now()).total_seconds()
        self.assertGreater(left, PC.LIVE_IDLE_S - 10)
        # never past the hard cap from the start
        self.assertLessEqual((s.expires_at - s.created).total_seconds(), 600 + 1)
        # the device side may not keep it alive
        r = APIClient().post("/api/v1/shop/live/%d/touch" % sid, {},
                             HTTP_X_SHOP_TOKEN=cam.camera_token, format="json")
        self.assertEqual(r.status_code, 404)

    def test_quality_signal_is_relayed(self):
        cam = self._phone()
        sid = self._start(cam).data["id"]
        r = self.client.post("/api/v1/shop/live/%d/signal" % sid,
                             {"kind": "quality", "payload": {"hd": True}}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        r = APIClient().get("/api/v1/shop/live/%d/signal?after=0" % sid,
                            HTTP_X_SHOP_TOKEN=cam.camera_token)
        self.assertEqual(r.data["messages"][-1]["kind"], "quality")

    def test_watchman_overview_shows_health_and_live_to_allowed_viewer(self):
        cam = self._phone()
        APIClient().post("/api/v1/shop/heartbeat",
                         {"camera_token": cam.camera_token, "caps": ["live"],
                          "health": {"level": 77, "charging": True}}, format="json")
        c = APIClient()
        c.force_authenticate(self.viewer)
        r = c.get("/api/v1/shop/watchman")
        self.assertEqual(r.status_code, 200, r.data)
        rows = [x for s in r.data["sites"] for x in s["cameras_list"]
                if x["id"] == cam.id]
        self.assertEqual(len(rows), 1)
        self.assertTrue(rows[0]["live_capable"])
        self.assertEqual(rows[0]["health"]["level"], 77)
        self.assertNotIn("source", rows[0])           # viewers never see setup data
        # owner switches family live off -> the viewer row loses it
        self.client.patch("/api/v1/shop/phonecam/%d" % cam.id,
                          {"viewers_live": False}, format="json")
        r = c.get("/api/v1/shop/watchman")
        row = [x for s in r.data["sites"] for x in s["cameras_list"] if x["id"] == cam.id][0]
        self.assertNotIn("live_capable", row)
