"""ads-guard (owner 17 Nov): Owner Admin ad numbers come from the app's own
SDK events — honestly labelled "app events — estimated", with no AdMob API
sync claimed. Google TEST-ad events (real ids off, or an owner / staff /
tester / Play-reviewer account) are counted apart and are NEVER revenue.
Premium / Plus / Business: no ad config, no event counted. Made-up sample
phone numbers only."""
from datetime import timedelta
from unittest import mock

from django.core.cache import cache
from django.utils import timezone
from rest_framework.test import APITestCase

from core import admob_service as AS
from core import billing
from core.models import AdPlacementStat, User


class _Base(APITestCase):
    def mk(self, phone, plan="free", **kw):
        u = User.objects.create_user(name="G" + phone[-2:], phone=phone, password="pw", **kw)
        u.plan = plan
        if plan != "free":
            u.plan_until = timezone.now() + timedelta(days=30)
        u.trial_until = timezone.now() - timedelta(days=1)
        u.save()
        return u

    def setUp(self):
        cache.clear()
        self.free = self.mk("01999000501")
        self.tester = self.mk("01999000502")
        self.staff = self.mk("01999000503", is_staff=True)

    def caps(self, **kw):
        row = billing.get_config()
        d = dict(row.data or {})
        d["ad_rewards"] = dict(d.get("ad_rewards") or {}, **kw)
        row.data = d
        row.save()

    def ev(self, user, **d):
        self.client.force_authenticate(user)
        return self.client.post("/api/v1/ads/event", d, format="json")


class TestVsRealTests(_Base):
    def test_real_ids_off_every_event_is_test(self):
        self.caps(admob_real_ids=False)
        self.ev(self.free, kind="impression", format="banner", placement="banner_dictionary")
        self.ev(self.free, kind="paid", format="banner", placement="banner_dictionary",
                value_micros=900, currency="USD", precision="precise")
        self.assertTrue(all(r.test for r in AdPlacementStat.objects.all()))
        self.assertEqual(AS.placement_stats(7), [])
        self.assertEqual(AS.placement_stats(7, test=True)[0]["impressions"], 1)
        src = AS.stats_source(7)
        self.assertEqual((src["real_impressions"], src["test_impressions"]), (0, 1))
        self.assertFalse(src["api_connected"])
        self.assertEqual(src["source"], "app_events")

    def test_real_ids_on_owner_staff_tester_are_test_free_user_real(self):
        self.caps(admob_real_ids=True)
        with mock.patch("core.integrations.get",
                        return_value={"ad_test_phones": "01999000502"}):
            for u in (self.free, self.tester, self.staff):
                self.ev(u, kind="impression", format="native", placement="home_native")
        real = AdPlacementStat.objects.get(test=False)
        test = AdPlacementStat.objects.get(test=True)
        self.assertEqual((real.impressions, test.impressions), (1, 2))
        self.assertEqual(AS.placement_stats(7)[0]["impressions"], 1)
        self.assertTrue(AS.stats_source(7)["real_ids_on"])

    def test_error_counts_as_test(self):
        with mock.patch("core.billing.cfg", side_effect=RuntimeError):
            self.assertTrue(AS.is_test_event(self.free))

    def test_test_paid_value_never_reaches_ad_income(self):
        from core import ad_money_service as AMS
        AdPlacementStat.objects.create(date=timezone.localdate(), placement="rewarded_credits",
                                       fmt="rewarded", currency="USD", paid_events=10,
                                       revenue_micros=9_000_000, test=True)
        _bdt, n, _src = AMS.real_income()
        self.assertEqual(n, 0)


class PaidPlansTests(_Base):
    def test_paid_plans_get_no_ads_and_count_nothing(self):
        self.caps(admob_real_ids=True)
        for plan in ("premium", "plus", "business"):
            u = self.mk("0199900060" + str(len(plan)), plan)
            self.client.force_authenticate(u)
            j = self.client.get("/api/v1/ads/config").json()
            self.assertFalse(j["ads_enabled"], plan)
            self.assertFalse(any(j["placements"].values()), plan)
            r = self.ev(u, kind="impression", format="banner", placement="banner_dictionary")
            self.assertEqual(r.json()["reason"], "not_free", plan)
        self.assertFalse(AdPlacementStat.objects.exists())


from web.tests_o2_owner_admin import OwnerBase  # noqa: E402


class OwnerAdsSourceCardTests(OwnerBase):
    def setUp(self):
        super().setUp()
        self.ready()

    def test_card_labels_source_and_splits_test(self):
        today = timezone.localdate()
        AdPlacementStat.objects.create(date=today, placement="home_native", fmt="native",
                                       impressions=7)
        AdPlacementStat.objects.create(date=today, placement="home_native", fmt="native",
                                       impressions=40, test=True)
        AdPlacementStat.objects.create(date=today, placement="home_native", fmt="native",
                                       currency="USD", paid_events=40,
                                       revenue_micros=5_000_000, test=True)
        en = self.c.get("/owner/ads?lang=en").content.decode()
        for s in ('id="ads-source"', "app events — estimated",
                  "No AdMob Reporting API sync is connected", "enable “AdMob API”"):
            self.assertIn(s, en, s)
        self.assertNotIn("USD 5.00", en)  # test value is never shown as revenue
        bn = self.c.get("/owner/ads?lang=bn").content.decode()
        self.assertIn("অ্যাপের ইভেন্ট — আনুমানিক", bn)
        self.assertIn("টেস্ট বিজ্ঞাপনের ইমপ্রেশন", bn)
