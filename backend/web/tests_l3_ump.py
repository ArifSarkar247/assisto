"""l3-ump: Google UMP consent debug knobs for AdMob.

Owner Admin -> Ads gets a "Force EEA consent form (testing)" switch (default
OFF) and the AdMob integration an optional "UMP test device IDs" field; the
app's /ads/config carries both. The app only runs the consent flow when its
APK has a REAL AdMob app id (app/lib/ads/consent.dart)."""
from django.test import SimpleTestCase
from rest_framework.test import APIClient

from core.logic import ads as A
from core.logic import pricing as P
from core.models import OwnerAudit, User
from web.tests_o2_owner_admin import OwnerBase


class ConsentConfigPureTests(SimpleTestCase):
    def _cfg(self, **kw):
        base = dict(plan="free", paid=False, admob_cfg={}, admob_working=False,
                    flag_rewarded=True, flag_app_open=True, ad_caps={})
        base.update(kw)
        return A.client_config(**base)

    def test_off_by_default(self):
        c = self._cfg()
        self.assertFalse(c["consent_debug_eea"])
        self.assertEqual(c["consent_test_devices"], [])
        self.assertFalse(P.DEFAULTS()["ad_rewards"]["consent_debug_eea"])
        self.assertFalse(P.normalize({})["ad_rewards"]["consent_debug_eea"])

    def test_debug_on_sends_clean_device_ids(self):
        c = self._cfg(ad_caps={"consent_debug_eea": True},
                      admob_cfg={"ump_test_devices": " ABCDEF0123456789, bad id!,ABCDEF0123456789;33BE2250B43518CCDA7DE426D04EE231 "})
        self.assertTrue(c["consent_debug_eea"])
        self.assertEqual(c["consent_test_devices"],
                         ["ABCDEF0123456789", "33BE2250B43518CCDA7DE426D04EE231"])

    def test_device_ids_never_sent_while_debug_off(self):
        c = self._cfg(admob_cfg={"ump_test_devices": "ABCDEF0123456789"})
        self.assertEqual(c["consent_test_devices"], [])

    def test_device_id_parser(self):
        self.assertEqual(A.ump_test_devices(None), [])
        self.assertEqual(A.ump_test_devices("short"), [])
        self.assertEqual(len(A.ump_test_devices(",".join("D%015d" % i for i in range(40)))), 20)

    def test_normalize_keeps_switch(self):
        self.assertTrue(P.normalize({"ad_rewards": {"consent_debug_eea": True}})
                        ["ad_rewards"]["consent_debug_eea"])


class ConsentOwnerAdminTests(OwnerBase):
    def setUp(self):
        super().setUp()
        self.ready()

    def test_switch_renders_and_saves(self):
        from core import billing
        page = self.c.get("/owner/ads?lang=en").content.decode()
        self.assertIn("Force EEA consent form", page)
        self.assertIn('name="ad_rewards.consent_debug_eea"', page)
        cfg = billing.cfg()
        data = {"action": "settings", "reason": "ump test"}
        for blk, keys in (("ad_rewards", cfg["ad_rewards"]),
                          ("photo_studio", cfg.get("photo_studio") or {})):
            for k, v in keys.items():
                if isinstance(v, bool):
                    if v:
                        data["%s.%s" % (blk, k)] = "on"
                elif isinstance(v, (int, float)):
                    data["%s.%s" % (blk, k)] = str(v)
        data["ad_rewards.consent_debug_eea"] = "on"
        r = self.post("/owner/ads", data)
        self.assertEqual(r.status_code, 302, r.content[:400])
        self.assertTrue(billing.cfg()["ad_rewards"]["consent_debug_eea"])
        a = OwnerAudit.objects.get(action="ads.update")
        self.assertEqual(a.after["ad_rewards.consent_debug_eea"], True)
        free = User.objects.create_user(name="F", phone="01710009917", password="x")
        api = APIClient()
        api.force_authenticate(free)
        j = api.get("/api/v1/ads/config").json()
        self.assertTrue(j["consent_debug_eea"])
        self.assertEqual(j["consent_test_devices"], [])

    def test_bangla_label(self):
        page = self.c.get("/owner/ads?lang=bn").content.decode()
        self.assertIn("সম্মতি ফর্ম", page)
