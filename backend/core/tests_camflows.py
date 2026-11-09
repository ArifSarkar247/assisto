"""camflows — the one-tap cloud LIVE view for cameras added through a brand
cloud link (cctvconnect). Found by the emulator E2E (camflows.yml): the live
button used the developer-account clients only, so

  * an Imou camera linked with the user's OWN Imou account (OAuth) could not
    play (the developer account cannot see the user's devices), and
  * a Dahua (DoLynk) camera had no live view at all ("not_vendor").

Now a linked camera plays through its link's own grant; cameras without a
link keep the older paths. Synthetic data only.
"""
from datetime import timedelta
from unittest import mock

from django.utils import timezone

from core import tests_cctvconnect as T
from core import tests_e2e_cctv as E2E
from core.logic.cctv_connect import mocks as M


def setUpModule():
    T.setUpModule()


def tearDownModule():
    T.tearDownModule()


class CloudLiveForLinkedCamerasTests(E2E._Base):
    def setUp(self):
        super().setUp()
        T._clear_caches()
        from core.models import ShopSite
        self.sim = M.VendorSims()
        d = self.sim.add_device("imou", "SIMIMOUSER9", "ZZZ999", channels=1)
        d.oauth_user = True
        self.sim.add_device("dolynk", "SIMDLNVR9", "ABC123", channels=2)
        for target, value in (("core.logic.cctv_connect.base.default_http", self.sim.http),
                              ("core.shop_views._included_cameras", mock.Mock(return_value=10))):
            p = mock.patch(target, value)
            p.start()
            self.addCleanup(p.stop)
        self.sid = self.site["id"]
        ShopSite.objects.filter(pk=self.sid).update(
            away={"until": (timezone.now() + timedelta(days=1)).isoformat()})
        self.owner.is_staff = True              # developer-account bind allowed
        self.owner.save(update_fields=["is_staff"])

    def live(self, cam_id):
        return self.client.post("/api/v1/watchman/cameras/%d/vendor_live" % cam_id, {"hd": False},
                                format="json")

    def test_imou_oauth_camera_plays_through_the_users_own_grant(self):
        from core.models import CctvCloudLink
        T._enable("imou", self.sim.cfg("imou"))
        r = self.client.post("/api/v1/cctv/connect/imou/oauth/start", {"site": self.sid}, format="json")
        state = r.data["state"]
        from rest_framework.test import APIClient
        cb = APIClient().get("/api/v1/cctv/imou/oauth/callback", {"code": "good-code", "state": state})
        self.assertEqual(cb.status_code, 200)
        link = CctvCloudLink.objects.get(site_id=self.sid, provider="imou")
        r = self.client.post("/api/v1/cctv/connect/links/%d/import" % link.id,
                             {"items": [{"serial": "SIMIMOUSER9", "channel": 0}]}, format="json")
        cam = r.data["added"][0]
        self.assertTrue(cam["cloud_alarms"])
        r = self.live(cam["id"])
        self.assertEqual(r.status_code, 201, r.data)
        # the simulator gives an OAuth user RTSP (Imou docs: getStreamUrl)
        self.assertTrue(r.data["url"].startswith("rtsp://live.lechange.com/live/SIMIMOUSER9/"), r.data)
        self.assertEqual(r.data["vendor"], "imou")
        # ended cleanly; nothing of ours to release at Imou for an OAuth token
        r = self.client.post("/api/v1/watchman/cameras/%d/vendor_live/%s/end" % (cam["id"], r.data["id"]),
                             {"seconds": 5}, format="json")
        self.assertEqual(r.status_code, 200, r.data)

    def test_dahua_dolynk_camera_has_live_and_unlinked_dahua_does_not(self):
        T._enable("dolynk", self.sim.cfg("dolynk"))
        r = self.client.post("/api/v1/cctv/connect/dolynk/link",
                             {"site": self.sid, "serial": "SIMDLNVR9", "code": "ABC123", "consent": True},
                             format="json")
        self.assertEqual(r.status_code, 201, r.data)
        link = r.data["link"]
        r = self.client.post("/api/v1/cctv/connect/links/%d/import" % link["id"],
                             {"items": [{"serial": "SIMDLNVR9", "channel": 1}]}, format="json")
        cam = r.data["added"][0]
        self.assertEqual(cam["vendor"], "dahua")
        r = self.live(cam["id"])
        self.assertEqual(r.status_code, 201, r.data)
        self.assertIn("SIMDLNVR9", r.data["url"])
        self.client.post("/api/v1/watchman/cameras/%d/vendor_live/%s/end" % (cam["id"], r.data["id"]),
                         {"seconds": 3}, format="json")
        # unlink -> the camera stays but has no cloud live any more (honest 409)
        r = self.client.delete("/api/v1/cctv/connect/links/%d" % link["id"])
        self.assertEqual(r.status_code, 200, r.data)
        r = self.live(cam["id"])
        self.assertEqual((r.status_code, r.data.get("error")), (409, "not_vendor"), r.data)


class EzvizPollBudgetTests(E2E._Base):
    """Owner 9 Nov: EZVIZ "Message Service" (push) is PAID -> alarms stay
    polled, inside the free trial's 10 000 API calls a day."""

    def test_poll_interval_fits_the_free_daily_calls(self):
        from core import cashguard_views as CG
        self.assertEqual(CG.ezviz_poll_every_min(1), 1)
        self.assertEqual(CG.ezviz_poll_every_min(6), 1)          # 6 x 1440 = 8 640 / day
        self.assertEqual(CG.ezviz_poll_every_min(7), 2)
        self.assertEqual(CG.ezviz_poll_every_min(20), 4)
        self.assertEqual(CG.ezviz_poll_every_min(6, saving=True), 3)
        self.assertEqual(CG.ezviz_poll_every_min(10_000), CG.EZVIZ_POLL_MAX_EVERY_MIN)
        for n in (1, 6, 7, 20, 60):
            every = CG.ezviz_poll_every_min(n)
            self.assertLessEqual(n * 1440 / every, CG.EZVIZ_POLL_CALLS_PER_DAY + 1)

    def test_no_poll_once_the_free_quota_is_used(self):
        from core import cashguard_views as CG
        with mock.patch.object(CG, "ezviz_on", return_value=True), \
                mock.patch("core.logic.cctv_connect.quota.stop", return_value=True), \
                mock.patch("core.logic.ezviz.EzvizClient.from_integration") as mk:
            self.assertEqual(CG.poll_ezviz(), 0)
        mk.assert_not_called()
