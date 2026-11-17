"""admob-connect (owner 17 Nov): the owner and testers only ever get Google's
TEST ad units, even after the owner turns `admob_real_ids` on — so nobody on
the team makes an invalid impression or click on Assisto's real ads.

Test accounts = superuser / staff, ASSISTO_OWNER_PHONES, PLAY_REVIEWER_PHONE
and Owner Admin -> Integrations -> AdMob -> "ad_test_phones". Everyone else
on the Free plan gets the real units; paid plans still get zero ads.
Sample phone numbers only (made up)."""
from datetime import timedelta
from unittest import mock

from django.core.cache import cache
from django.test import SimpleTestCase
from django.utils import timezone
from rest_framework.test import APITestCase

from core import billing
from core.logic import ads as A
from core.models import User
from core.views_ads import test_ads_account


class PhoneHelperTests(SimpleTestCase):
    def test_phone_key_normalises_bd_forms(self):
        self.assertEqual(A.phone_key("01999000111"), "1999000111")
        self.assertEqual(A.phone_key("+8801999000111"), "1999000111")
        self.assertEqual(A.phone_key("abc"), "")
        self.assertEqual(A.phone_key(None), "")

    def test_ad_test_phones_parses_list(self):
        got = A.ad_test_phones(" 01999000111, +8801999000112;\n01999000111 bad ")
        self.assertEqual(got, {"1999000111", "1999000112"})
        self.assertEqual(A.ad_test_phones(None), set())
        many = ",".join("0199900%04d" % i for i in range(80))
        self.assertEqual(len(A.ad_test_phones(many)), 50)

    def test_serving_units_force_test(self):
        caps = {"admob_real_ids": True}
        real, _app, units = A.serving_units(caps, {}, False)
        self.assertTrue(real)
        self.assertFalse(any(A.is_test_id(u) for u in units.values()))
        real, app_id, units = A.serving_units(caps, {}, False, force_test=True)
        self.assertFalse(real)
        self.assertEqual(app_id, "")
        self.assertEqual(units, A.TEST_UNITS)

    def test_client_config_test_only_never_offers_rewarded(self):
        from core.logic import pricing as P
        caps = dict(P.DEFAULTS()["ad_rewards"], admob_real_ids=True,
                    rewarded_daily_cap=5)
        c = A.client_config(plan="free", paid=False, admob_cfg={}, admob_working=False,
                            flag_rewarded=True, flag_app_open=True, ad_caps=caps,
                            test_ads_only=True)
        self.assertFalse(c["real_ids"])
        self.assertTrue(c["test_ads_only"])
        self.assertTrue(c["ads_enabled"])
        self.assertFalse(c["placements"]["rewarded"])
        self.assertTrue(all(A.is_test_id(u) for u in c["units"].values()))


class TestAccountTests(SimpleTestCase):
    def _u(self, phone, staff=False, su=False):
        return mock.Mock(phone=phone, is_staff=staff, is_superuser=su)

    def test_owner_staff_and_listed_phones(self):
        self.assertTrue(test_ads_account(self._u("01999000301", su=True)))
        self.assertTrue(test_ads_account(self._u("01999000302", staff=True)))
        cfg = {"ad_test_phones": "01999000303"}
        self.assertTrue(test_ads_account(self._u("+8801999000303"), cfg))
        self.assertFalse(test_ads_account(self._u("01999000304"), cfg))
        self.assertFalse(test_ads_account(self._u(""), cfg))

    def test_env_owner_and_reviewer_phones(self):
        with mock.patch.dict("os.environ", {"ASSISTO_OWNER_PHONES": "01999000305",
                                            "PLAY_REVIEWER_PHONE": "01999000306"}):
            self.assertTrue(test_ads_account(self._u("01999000305")))
            self.assertTrue(test_ads_account(self._u("01999000306")))
            self.assertFalse(test_ads_account(self._u("01999000307")))

    def test_error_fails_safe_to_test_ads(self):
        with mock.patch("core.test_accounts.is_real_owner", side_effect=RuntimeError):
            self.assertTrue(test_ads_account(self._u("01999000308")))


class ConfigApiTests(APITestCase):
    def mk(self, phone, plan="free", **kw):
        u = User.objects.create_user(name="T" + phone[-2:], phone=phone, password="pw", **kw)
        u.plan = plan
        if plan != "free":
            u.plan_until = timezone.now() + timedelta(days=30)
        u.trial_until = timezone.now() - timedelta(days=1)
        u.save()
        return u

    def setUp(self):
        cache.clear()
        row = billing.get_config()
        d = dict(row.data or {})
        d["ad_rewards"] = dict(d.get("ad_rewards") or {}, admob_real_ids=True)
        row.data = d
        row.save()
        self.free = self.mk("01999000401")
        self.tester = self.mk("01999000402")
        self.owner = self.mk("01999000403", is_staff=True, is_superuser=True)
        self.prem = self.mk("01999000404", "premium")
        self.plus = self.mk("01999000405", "plus")

    def get(self, u, admob_cfg=None):
        self.client.force_authenticate(u)
        with mock.patch("core.integrations.get", return_value=admob_cfg or {}):
            return self.client.get("/api/v1/ads/config").json()

    def test_free_user_gets_real_units(self):
        j = self.get(self.free)
        self.assertTrue(j["real_ids"])
        self.assertFalse(j["test_ads_only"])
        self.assertFalse(any(A.is_test_id(u) for u in j["units"].values()))

    def test_owner_and_listed_tester_get_test_units_only(self):
        cfg = {"ad_test_phones": "01999000402"}
        for u in (self.owner, self.tester):
            j = self.get(u, cfg)
            self.assertFalse(j["real_ids"], u.phone)
            self.assertTrue(j["test_ads_only"])
            self.assertTrue(all(A.is_test_id(x) for x in j["units"].values()))

    def test_premium_and_plus_get_zero_ads(self):
        for u in (self.prem, self.plus):
            j = self.get(u)
            self.assertFalse(j["ads_enabled"], u.plan)
            self.assertTrue(j["paid"])
            self.assertFalse(any(j["placements"].values()))
            self.assertFalse(any(r.get("on") for r in
                                 (j.get("control") or {}).get("placements", {}).values()))

    def test_rewarded_ticket_units_are_never_real_for_testers(self):
        """Photo Studio / Language Partner / Safe Plans / credits tickets carry
        the rewarded unit from _ad_units(user): empty for the owner/testers."""
        from core.photo_studio_service import _ad_units
        cfg = {"ad_test_phones": "01999000402"}
        with mock.patch("core.integrations.get", return_value=cfg):
            self.assertTrue(_ad_units(self.free)["_configured"])
            self.assertFalse(A.is_test_id(_ad_units(self.free)["rewarded"]))
            for u in (self.owner, self.tester):
                got = _ad_units(u)
                self.assertFalse(got["_configured"], u.phone)
                self.assertEqual(got["rewarded"], "")
