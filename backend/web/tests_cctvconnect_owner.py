"""cctvconnect (owner 9 Nov 17:20): Owner Admin -> Imou test cameras — the
owner links HIS OWN Imou camera by serial + Safety Code (consent ticked),
bound to our developer account (simulated Imou cloud), unlink = unBindDevice.
Serials only on the page; never any video or picture."""
import os
from unittest import mock

from cryptography.fernet import Fernet

from core import integrations
from core.logic.cctv_connect import mocks as M
from core.models import CctvCloudLink, Integration, ShopCamera
from web.tests_o2_owner_admin import OwnerBase

_KEY = Fernet.generate_key().decode()


def setUpModule():
    os.environ["INTEGRATIONS_FERNET_KEY"] = _KEY
    integrations._FERNET = None


def tearDownModule():
    integrations._FERNET = None


class ImouTestCameraPageTests(OwnerBase):
    def setUp(self):
        super().setUp()
        from core.logic import imou as IM
        IM._token_cache.clear()
        self.sim = M.VendorSims()
        self.sim.add_device("imou", "SIMRANGER2C", "L2C3D4", channels=1)
        p = mock.patch("core.logic.cctv_connect.base.default_http", self.sim.http)
        p.start()
        self.addCleanup(p.stop)
        p = mock.patch("core.shop_views._included_cameras", return_value=4)
        p.start()
        self.addCleanup(p.stop)
        Integration.objects.create(slug="imou", status="working",
                                   enc_blob=integrations._encrypt(self.sim.cfg("imou")))

    def test_link_needs_consent_then_camera_is_owner_test_device_and_unlink(self):
        self.ready()
        r = self.c.get("/owner/imou-devices")
        self.assertEqual(r.status_code, 200)
        self.assertIn('id="imou-add"', r.content.decode())
        r = self.post("/owner/imou-devices", {"action": "add", "serial": "SIMRANGER2C",
                                              "code": "L2C3D4"})
        self.assertEqual(r.status_code, 200)
        self.assertIn('id="imou-err"', r.content.decode())       # no consent -> refused
        self.assertFalse(CctvCloudLink.objects.exists())
        r = self.post("/owner/imou-devices", {"action": "add", "serial": "SIMRANGER2C",
                                              "code": "L2C3D4", "consent": "1", "name": "Desk"})
        self.assertEqual(r.status_code, 302)
        cam = ShopCamera.objects.get(site__owner=self.owner)
        self.assertEqual((cam.vendor, cam.vendor_ref, cam.name), ("imou", "SIMRANGER2C:0", "Desk"))
        self.assertTrue(cam.compat.get("owner_test"))
        self.assertEqual(self.sim.devs["imou"]["SIMRANGER2C"].owner, "sim")
        html = self.c.get("/owner/imou-devices").content.decode()
        self.assertIn("SIMRANGER2C", html)
        self.assertNotIn("L2C3D4", html)                           # the code is never shown/kept
        link = CctvCloudLink.objects.get()
        self.assertNotIn("L2C3D4", link.grant_blob + str(link.state))
        r = self.post("/owner/imou-devices", {"action": "unlink", "link": link.id})
        self.assertEqual(r.status_code, 302)
        self.assertIsNone(self.sim.devs["imou"]["SIMRANGER2C"].owner)   # unBindDevice called
        cam.refresh_from_db()
        self.assertEqual(cam.vendor_ref, "")
