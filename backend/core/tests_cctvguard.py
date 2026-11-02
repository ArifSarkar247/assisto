"""cctvguard (owner CCTV order G): traffic meter, relay cap (only when the
owner confirmed limits), emergency never cut, prefer P2P, vendor live
SD default / HD on tap / 5-min idle stop / max live per account."""
from datetime import timedelta
from unittest import mock

from django.test import SimpleTestCase, override_settings
from django.utils import timezone
from rest_framework.test import APITestCase

from core.logic import cctv_traffic as T
from core.models import User

ON = {"confirmed": True, "relay_mb": 1}      # 1 MB per camera: easy to fill
OFF = {"confirmed": False, "relay_mb": 300}


class LogicTests(SimpleTestCase):
    def test_bytes_capped_by_seconds(self):
        self.assertEqual(T.sane_bytes(10 ** 12, 10), 10 * T.MAX_LIVE_BYTES_S + T.SLACK_BYTES)
        self.assertEqual(T.sane_bytes(5000, 10), 5000)
        self.assertEqual(T.sane_bytes(-5, 10), 0)
        self.assertEqual(T.sane_bytes("nan", 10), 0)
        self.assertEqual(T.sane_bytes(True, 10), 0)

    def test_cumulative_reports_never_double_count(self):
        doc, r, d = T.add_live({}, 7, 1, 1_000_000, 60, "direct")
        self.assertEqual((r, d), (0, 1_000_000))
        doc, r, d = T.add_live(doc, 7, 1, 1_000_000, 60, "direct")   # same report again
        self.assertEqual((r, d), (0, 0))
        doc, r, d = T.add_live(doc, 7, 1, 3_000_000, 120, "relay")   # turned relay
        self.assertEqual((r, d), (2_000_000, 0))
        doc, r, d = T.add_live(doc, 7, 1, 4_000_000, 130, "direct")  # relay latches
        self.assertEqual(r, 1_000_000)
        c = doc["cams"]["7"]
        self.assertEqual(c["relay_bytes"], 3_000_000)
        self.assertEqual(c["direct_bytes"], 1_000_000)
        self.assertEqual(c["live_s"], 130)

    def test_session_memory_bounded(self):
        doc = {}
        for i in range(T.KEEP_SESSIONS + 15):
            doc, _, _ = T.add_live(doc, 1, i, 10, 1, "lan")
        self.assertEqual(len(doc["sess"]), T.KEEP_SESSIONS)

    def test_cap_levels(self):
        self.assertEqual(T.cap_state(10 ** 9, 300, False)["level"], "off")
        self.assertEqual(T.cap_state(100 * 10 ** 6, 300, True)["level"], "ok")
        self.assertEqual(T.cap_state(240 * 10 ** 6, 300, True)["level"], "notice")
        self.assertEqual(T.cap_state(300 * 10 ** 6, 300, True)["level"], "paused")
        self.assertEqual(T.cap_state(0, 0, True)["level"], "paused")
        self.assertTrue(T.gate({"level": "paused"}, emergency=True))
        self.assertFalse(T.gate({"level": "paused"}))
        self.assertTrue(T.gate({"level": "notice"}))

    def test_pool_and_account_total(self):
        self.assertEqual(T.pool_mb(300, 3), 900)
        self.assertEqual(T.pool_mb(300, 0), 300)
        doc = {"cams": {"1": {"relay_bytes": 5, "vendor_est_bytes": 100},
                        "2": {"relay_bytes": 5}}, "turn_bytes": 50}
        self.assertEqual(T.account_relay_bytes(doc), 150)    # max(10, 50) + vendor
        doc["turn_bytes"] = 1
        self.assertEqual(T.account_relay_bytes(doc), 110)

    def test_vendor_estimate_and_clamp(self):
        self.assertEqual(T.vendor_estimate_bytes(60, False), 60 * 512 * 1000 // 8)
        self.assertEqual(T.vendor_estimate_bytes(60, True), 60 * 2048 * 1000 // 8)
        # reported 1 h, but last touch 10 s after start -> idle stop at +310 s
        self.assertEqual(T.vendor_seconds(1000, 1010, 9000, 3600), 310)
        self.assertEqual(T.vendor_seconds(1000, 1000, 1100, 0), 100)
        self.assertEqual(T.vendor_seconds(1000, 1000, 1100, 50), 50)
        doc = T.add_vendor({}, 3, 99999, hd=True)
        self.assertEqual(doc["cams"]["3"]["vendor_s"], T.VENDOR_MAX_S)

    def test_messages_bangla_honest(self):
        m = T.messages("notice", 85, "bn")
        self.assertIn("৮৫", m)
        self.assertIn("Wi-Fi", m)
        p = T.messages("paused", 100, "bn")
        self.assertIn("একই Wi-Fi-তে বা সরাসরি সংযোগে দেখা যাবে", p)
        self.assertIn("সতর্কতা", p)
        self.assertEqual(T.messages("ok", 10, "bn"), "")
        for lv in ("notice", "paused", "paused_vendor"):
            for lang in ("bn", "en"):
                low = T.messages(lv, 90, lang).lower()
                self.assertNotIn("theft", low)
                self.assertNotIn("চুরি", low)

    def test_month_key_dhaka(self):
        from datetime import datetime, timezone as dtz
        self.assertEqual(T.month_key(datetime(2026, 10, 31, 19, 0, tzinfo=dtz.utc)), "2026-11")
        self.assertEqual(T.month_key(datetime(2026, 10, 31, 17, 0, tzinfo=dtz.utc)), "2026-10")


class _Base(APITestCase):
    def setUp(self):
        from core.models import ShopCamera, ShopSite
        self.owner = User.objects.create_user(name="Owner", phone="01710007001",
                                              password="pw")
        self.owner.plan = "business"
        self.owner.plan_until = timezone.now() + timedelta(days=30)
        self.owner.ai_credits = 100
        self.owner.language = "bn"
        self.owner.save()
        self.site = ShopSite.objects.create(owner=self.owner, name="Main")
        self.cam = ShopCamera.objects.create(site=self.site, name="Gate", kind="shopbox")
        self.client.force_authenticate(self.owner)
        from django.core.cache import cache
        cache.clear()

    def cfg(self, c):
        p = mock.patch("core.cctv_traffic.cfg", return_value=dict(c))
        p.start()
        self.addCleanup(p.stop)

    def fill(self, mb, cam=None):
        from core import cctv_traffic as CT
        cam = cam or self.cam

        def fn(doc):
            doc, _, _ = T.add_live(doc, cam.pk, "seed%d" % mb, mb * 10 ** 6, 10 ** 6, "relay")
            return doc
        CT._update(self.owner.pk, timezone.now(), fn)


@override_settings(TURN_STATIC_SECRET="test-secret", TURN_HOST="turn.example.test",
                   TURN_PORT=3478)
class LiveCapTests(_Base):
    def _online(self):
        from rest_framework.test import APIClient
        r = APIClient().post("/api/v1/shop/heartbeat",
                             {"camera_token": self.cam.camera_token, "caps": ["live"]},
                             format="json")
        self.assertEqual(r.status_code, 200)

    def _start(self):
        with mock.patch("core.logic.rtc.throttle_decision",
                        return_value={"throttled": False, "reason": ""}):
            return self.client.post("/api/v1/shop/live/start", {"camera": self.cam.id},
                                    format="json")

    @staticmethod
    def _turn(r):
        return any(u.startswith("turn") for x in r.data["ice"]["ice_servers"]
                   for u in x["urls"])

    def _pending_turn(self):
        from rest_framework.test import APIClient
        with mock.patch("core.logic.rtc.throttle_decision",
                        return_value={"throttled": False, "reason": ""}):
            p = APIClient().get("/api/v1/shop/live/pending",
                                HTTP_X_SHOP_TOKEN=self.cam.camera_token)
        ice = p.data["sessions"][0]["ice"]["ice_servers"]
        return any(u.startswith("turn") for x in ice for u in x["urls"])

    def test_not_confirmed_counts_but_never_blocks(self):
        self.cfg(OFF)
        self._online()
        self.fill(5000)
        r = self._start()
        self.assertEqual(r.status_code, 201, r.data)
        self.assertTrue(self._turn(r))
        self.assertEqual(r.data["traffic"]["level"], "off")
        self.assertTrue(self._pending_turn())

    def test_cap_reached_relay_off_p2p_stays(self):
        self.cfg(ON)
        self._online()
        self.fill(2)                       # 2 MB of a 1 MB pool
        r = self._start()
        self.assertEqual(r.status_code, 201, r.data)
        self.assertFalse(self._turn(r))    # STUN only: P2P / LAN still work
        self.assertTrue(r.data["ice"]["ice_servers"])
        self.assertEqual(r.data["traffic"]["level"], "paused")
        self.assertIn("একই Wi-Fi-তে বা সরাসরি সংযোগে দেখা যাবে", r.data["traffic"]["message"])
        self.assertFalse(self._pending_turn())   # the device side too

    def test_notice_at_80_percent(self):
        self.cfg({"confirmed": True, "relay_mb": 10})
        self._online()
        self.fill(9)
        r = self._start()
        self.assertTrue(self._turn(r))
        self.assertEqual(r.data["traffic"]["level"], "notice")
        self.assertIn("৯০", r.data["traffic"]["message"])

    def test_sos_never_cut(self):
        from core.models import FamilyAlertDelivery
        other = User.objects.create_user(name="Kid", phone="01710007002", password="pw")
        FamilyAlertDelivery.objects.create(event_key="s1", kind="sos", sender=self.owner,
                                           recipient=other)
        self.cfg(ON)
        self._online()
        self.fill(5)
        r = self._start()
        self.assertTrue(self._turn(r))
        self.assertEqual(r.data["traffic"]["level"], "emergency")
        self.assertTrue(self._pending_turn())
        # mid-session report over the cap: emergency -> not stopped
        u = self.client.post("/api/v1/shop/live/%d/usage" % r.data["id"],
                             {"bytes": 10 ** 6, "seconds": 30, "path": "relay"}, format="json")
        self.assertFalse(u.data["stop"])

    def test_resolved_sos_no_longer_exempt(self):
        from core.models import FamilyAlertDelivery
        other = User.objects.create_user(name="Kid", phone="01710007003", password="pw")
        FamilyAlertDelivery.objects.create(event_key="s1", kind="sos", sender=self.owner,
                                           recipient=other)
        FamilyAlertDelivery.objects.create(event_key="r1", kind="sos_resolved",
                                           sender=self.owner, recipient=other)
        self.cfg(ON)
        self._online()
        self.fill(5)
        self.assertFalse(self._turn(self._start()))

    def test_usage_reports_and_stop_when_cap_hit_mid_session(self):
        from core.models import ShopLiveSession
        self.cfg({"confirmed": True, "relay_mb": 2})
        self._online()
        r = self._start()
        sid = r.data["id"]
        ShopLiveSession.objects.filter(pk=sid).update(
            answered_at=timezone.now() - timedelta(seconds=100), status="active")
        u = self.client.post("/api/v1/shop/live/%d/usage" % sid,
                             {"bytes": 500_000, "seconds": 20, "path": "lan"}, format="json")
        self.assertEqual(u.status_code, 200, u.data)
        self.assertFalse(u.data["stop"])
        u = self.client.post("/api/v1/shop/live/%d/usage" % sid,
                             {"bytes": 2_600_000, "seconds": 60, "path": "relay"}, format="json")
        self.assertTrue(u.data["stop"])
        self.assertIn("একই Wi-Fi", u.data["message"])
        s = ShopLiveSession.objects.get(pk=sid)
        self.assertEqual((s.status, s.end_reason, s.relayed), ("ended", "relay_cap", True))
        g = self.client.get("/api/v1/cctv/usage")
        row = g.data["cameras"][0]
        self.assertEqual(row["direct_mb"], 0.5)       # before the switch to relay
        self.assertEqual(row["relay_mb"], 2.1)

    def test_end_records_bytes_clamped(self):
        from core.models import ShopLiveSession
        self.cfg(OFF)
        self._online()
        sid = self._start().data["id"]
        ShopLiveSession.objects.filter(pk=sid).update(
            answered_at=timezone.now() - timedelta(seconds=30), status="active")
        e = self.client.post("/api/v1/shop/live/%d/end" % sid,
                             {"relayed": False, "seconds": 9999, "bytes": 10 ** 12,
                              "path": "direct"}, format="json")
        self.assertEqual(e.status_code, 200)
        g = self.client.get("/api/v1/cctv/usage").data
        row = g["cameras"][0]
        # 10^12 bytes reported, but only ~35 s of video can be real
        self.assertLessEqual(row["direct_mb"], 35 * T.MAX_LIVE_BYTES_S / 1e6 + 0.3)
        self.assertEqual(row["relay_mb"], 0.0)
        self.assertTrue(g["vendor_is_estimate"])

    def test_other_users_session_404(self):
        self.cfg(OFF)
        self._online()
        sid = self._start().data["id"]
        stranger = User.objects.create_user(name="X", phone="01710007009", password="pw")
        self.client.force_authenticate(stranger)
        u = self.client.post("/api/v1/shop/live/%d/usage" % sid, {"bytes": 1}, format="json")
        self.assertEqual(u.status_code, 404)


class TurnLogTests(_Base):
    def test_turn_usage_counted_only_for_relayed_live(self):
        from core import cctv_traffic as CT
        from core.models import ShopLiveSession
        self.assertFalse(CT.note_turn_usage(self.owner.pk, 5_000_000))   # a call, say
        ShopLiveSession.objects.create(site=self.site, camera=self.cam, owner=self.owner,
                                       expires_at=timezone.now() + timedelta(minutes=5),
                                       relayed=True, status="active")
        self.assertTrue(CT.note_turn_usage(self.owner.pk, 5_000_000))
        self.assertEqual(CT.month_doc(self.owner.pk)["turn_bytes"], 5_000_000)
        self.cfg(OFF)
        self.assertEqual(CT.usage_for(self.owner)["relay_used_mb"], 5.0)


class _FakeImou:
    def __init__(self):
        self.calls = []

    def live_hls(self, dev, ch, hd):
        self.calls.append(("live", dev, ch, hd))
        return ("https://cmgw.easy4ipcloud.com/live/%s.m3u8" % ("hd" if hd else "sd"), "LT1")

    def unbind_live(self, tok):
        self.calls.append(("unbind", tok))


class VendorLiveTests(_Base):
    def setUp(self):
        super().setUp()
        from core.models import ShopCamera
        self.cam.vendor, self.cam.vendor_ref = "imou", "DEV1:0"
        self.cam.save()
        self.cam2 = ShopCamera.objects.create(site=self.site, name="Back", kind="shopbox",
                                              vendor="imou", vendor_ref="DEV2:0")
        self.cam3 = ShopCamera.objects.create(site=self.site, name="Side", kind="shopbox",
                                              vendor="imou", vendor_ref="DEV3:0")
        self.fake = _FakeImou()
        for target, val in (("core.logic.imou.ImouClient.from_integration", self.fake),
                            ("core.watchman_views.imou_cloud_on", True)):
            p = mock.patch(target, return_value=val)
            p.start()
            self.addCleanup(p.stop)
        self.cfg(OFF)

    def _open(self, cam, hd=None):
        body = {} if hd is None else {"hd": hd}
        return self.client.post("/api/v1/watchman/cameras/%d/vendor_live" % cam.pk, body,
                                format="json")

    def test_sd_default_hd_on_tap(self):
        r = self._open(self.cam)
        self.assertEqual(r.status_code, 201, r.data)
        self.assertFalse(r.data["hd"])
        self.assertEqual(r.data["idle_seconds"], 300)
        self.assertTrue(r.data["estimate"])
        self.assertEqual(self.fake.calls[-1], ("live", "DEV1", "0", False))
        r = self._open(self.cam2, hd=True)
        self.assertTrue(r.data["hd"])
        self.assertEqual(self.fake.calls[-1], ("live", "DEV2", "0", True))

    def test_max_two_live_per_account(self):
        self.assertEqual(self._open(self.cam).status_code, 201)
        self.assertEqual(self._open(self.cam2).status_code, 201)
        r = self._open(self.cam3)
        self.assertEqual(r.status_code, 429)
        self.assertEqual(r.data["error"], "live_limit")
        self.assertIn("২", r.data["detail"])

    def test_idle_stop_and_estimate(self):
        r = self._open(self.cam)
        vid = r.data["id"]
        base = "/api/v1/watchman/cameras/%d/vendor_live/%s" % (self.cam.pk, vid)
        t = self.client.post(base + "/touch", {}, format="json")
        self.assertEqual(t.status_code, 200)
        # 10 minutes without a touch: the touch is refused, end is clamped
        later = timezone.now() + timedelta(minutes=10)
        with mock.patch("django.utils.timezone.now", return_value=later):
            t = self.client.post(base + "/touch", {}, format="json")
            self.assertEqual(t.status_code, 410)
            e = self.client.post(base + "/end", {"seconds": 3600}, format="json")
        self.assertEqual(e.status_code, 200)
        self.assertLessEqual(e.data["seconds"], 305)
        self.assertGreaterEqual(e.data["seconds"], 295)
        self.assertIn(("unbind", "LT1"), self.fake.calls)
        # second end adds nothing
        e2 = self.client.post(base + "/end", {"seconds": 3600}, format="json")
        self.assertEqual(e2.data["seconds"], 0)
        u = self.client.get("/api/v1/cctv/usage").data
        row = [x for x in u["cameras"] if x["camera"] == self.cam.pk][0]
        self.assertIn(row["vendor_min"], (5, 6))
        self.assertGreater(row["vendor_est_mb"], 15)          # ~19 MB at 512 kbps

    def test_cap_paused_blocks_vendor_live_honestly(self):
        self.cfg(ON)
        self.fill(5)
        r = self._open(self.cam)
        self.assertEqual(r.status_code, 402)
        self.assertEqual(r.data["error"], "relay_cap")
        self.assertIn("Wi-Fi", r.data["detail"])

    def test_not_configured_is_honest(self):
        with mock.patch("core.watchman_views.imou_cloud_on", return_value=False):
            r = self._open(self.cam)
        self.assertEqual(r.status_code, 409)
        self.assertEqual(r.data["error"], "not_configured")

    def test_stranger_and_viewer_404(self):
        from core.models import ShopSiteViewer
        x = User.objects.create_user(name="X", phone="01710007010", password="pw")
        self.client.force_authenticate(x)
        self.assertEqual(self._open(self.cam).status_code, 404)
        # a family viewer sees alerts + snapshots, never live unless allowed
        ShopSiteViewer.objects.create(site=self.site, user=x)
        self.assertEqual(self._open(self.cam).status_code, 404)


class VendorClientTests(SimpleTestCase):
    def test_ezviz_quality_and_domain(self):
        from core.logic import ezviz as EZ
        c = EZ.EzvizClient("k", "s")
        seen = {}

        def fake_call(path, form):
            seen.update(form, path=path)
            return {"url": "https://open.ezvizlife.com/v3/openlive/x.m3u8"}
        c.call = fake_call
        self.assertTrue(c.live_address("SER", 1, hd=False).endswith(".m3u8"))
        self.assertEqual((seen["quality"], seen["protocol"]), (2, 2))
        c.live_address("SER", 1, hd=True)
        self.assertEqual(seen["quality"], 1)
        c.call = lambda p, f: {"url": "https://evil.example.com/x.m3u8"}
        with self.assertRaises(EZ.EzvizError):
            c.live_address("SER")

    def test_imou_sd_stream_and_existing_live(self):
        from core.logic import imou as IM
        c = IM.ImouClient("a", "s")
        c.token = lambda: "T"
        calls = []

        def call(method, params=None):
            calls.append((method, dict(params or {})))
            if method == "bindDeviceLive":
                raise IM.ImouError("LV1001")
            return {"streams": [
                {"streamId": 0, "hls": "https://x.easy4ipcloud.com/hd.m3u8", "liveToken": "L"},
                {"streamId": 1, "hls": "https://x.easy4ipcloud.com/sd.m3u8", "liveToken": "L"}]}
        c.call = call
        url, tok = c.live_hls("D", "0", hd=False)
        self.assertTrue(url.endswith("sd.m3u8"))
        self.assertEqual(calls[0][1]["streamId"], 1)
        self.assertEqual(calls[1][0], "getLiveStreamInfo")
        url, _ = c.live_hls("D", "0", hd=True)
        self.assertTrue(url.endswith("hd.m3u8"))
