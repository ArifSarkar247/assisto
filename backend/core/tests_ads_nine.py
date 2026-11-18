"""ads-nine (board row 54): the app reports every ad REQUEST and every failed
load (no fill / error / timeout); Owner Admin -> Ads shows requests ->
impressions -> fill rate, read-only, no user id. A paid account must never
make an ad request: its events are refused AND counted as a "paid leak"
(must stay 0). Made-up sample phone numbers only."""
from datetime import timedelta
from unittest import mock

from django.core.cache import cache
from django.utils import timezone
from rest_framework.test import APITestCase

from core import admob_service as AS
from core.logic import ads as A
from core.models import AdPlacementStat, User


def _mk(phone, plan="free"):
    u = User.objects.create_user(name="N" + phone[-2:], phone=phone, password="pw")
    u.plan = plan
    if plan != "free":
        u.plan_until = timezone.now() + timedelta(days=30)
    u.trial_until = timezone.now() - timedelta(days=1)
    u.save()
    return u


class CleanEventTests(APITestCase):
    def test_request_and_no_fill_are_valid_kinds(self):
        for k in ("request", "no_fill"):
            ev, why = A.clean_event({"kind": k, "format": "banner",
                                     "placement": "banner_dictionary",
                                     "ad_event_id": "0123456789abcdef"})
            self.assertIsNone(why, k)
            self.assertEqual(ev["kind"], k)

    def test_report_fill_rate(self):
        rows = [{"placement": "banner_dictionary", "format": "banner", "requests": 10,
                 "no_fill": 3, "impressions": 7, "clicks": 1, "paid_events": 0,
                 "revenue_micros": 0, "currency": ""}]
        r = A.placement_report(rows)[0]
        self.assertEqual((r["requests"], r["no_fill"], r["fill_pct"]), (10, 3, 70.0))
        # old builds: impressions without requests -> no fill rate, never > 100 %
        r = A.placement_report([dict(rows[0], requests=0)])[0]
        self.assertIsNone(r["fill_pct"])
        r = A.placement_report([dict(rows[0], requests=2)])[0]
        self.assertEqual(r["fill_pct"], 100.0)


class RequestCountingTests(APITestCase):
    def setUp(self):
        cache.clear()
        self.free = _mk("01999000701")

    def ev(self, user, **d):
        self.client.force_authenticate(user)
        return self.client.post("/api/v1/ads/event", d, format="json")

    @mock.patch("core.admob_service.is_test_event", return_value=True)
    def test_request_no_fill_impression_counted_once_per_instance(self, _t):
        for _ in range(2):  # a repeat of the same instance is not a new request
            self.ev(self.free, kind="request", format="banner",
                    placement="banner_dictionary", ad_event_id="aaaaaaaaaaaaaaaa")
        self.ev(self.free, kind="request", format="banner",
                placement="banner_dictionary", ad_event_id="bbbbbbbbbbbbbbbb")
        self.ev(self.free, kind="no_fill", format="banner",
                placement="banner_dictionary", ad_event_id="bbbbbbbbbbbbbbbb")
        self.ev(self.free, kind="impression", format="banner",
                placement="banner_dictionary", ad_event_id="aaaaaaaaaaaaaaaa")
        row = AdPlacementStat.objects.get(placement="banner_dictionary")
        self.assertEqual((row.requests, row.no_fill, row.impressions), (2, 1, 1))
        # Google TEST ads (real ids off) -> TEST rows, never income
        stats = AS.placement_stats(7, test=True)
        self.assertEqual(stats[0]["fill_pct"], 50.0)
        src = AS.stats_source(7)
        self.assertEqual((src["test_requests"], src["test_no_fill"], src["fill_pct"]),
                         (2, 1, 50.0))
        self.assertEqual(src["paid_leaks"], 0)

    def test_paid_account_request_is_a_counted_leak_not_a_view(self):
        prem = _mk("01999000702", "premium")
        r = self.ev(prem, kind="request", format="banner", placement="banner_dictionary",
                    ad_event_id="cccccccccccccccc")
        self.assertEqual(r.json()["reason"], "not_free")
        self.assertEqual(AS.stats_source(7)["paid_leaks"], 1)
        self.assertEqual(AS.placement_stats(7), [])
        self.assertEqual(AS.placement_stats(7, test=True), [])
        # clicks / paid values from a paid phone are refused and not leaks
        self.ev(prem, kind="click", format="banner", placement="banner_dictionary")
        self.assertEqual(AS.stats_source(7)["paid_leaks"], 1)


from web.tests_o2_owner_admin import OwnerBase  # noqa: E402


class OwnerAdsRequestsTests(OwnerBase):
    def setUp(self):
        super().setUp()
        self.ready()

    def test_ads_page_shows_requests_fill_and_leaks_read_only(self):
        today = timezone.localdate()
        AdPlacementStat.objects.create(date=today, placement="banner_dictionary",
                                       fmt="banner", requests=20, no_fill=5,
                                       impressions=15, test=True)
        en = self.c.get("/owner/ads?lang=en").content.decode()
        for s in ('id="ads-requests"', "Ad requests (app events)", "Fill rate",
                  'id="ads-paid-leaks"', "Ad events from paid"):
            self.assertIn(s, en, s)
        self.assertIn("75.0%", en)  # 15 / 20
        AdPlacementStat.objects.create(date=today, placement="banner_dictionary",
                                       fmt="paid_leak", impressions=2)
        bn = self.c.get("/owner/ads?lang=bn").content.decode()
        self.assertIn("বিজ্ঞাপন অনুরোধ", bn)
        self.assertIn("পূরণের হার", bn)
        self.assertIn("শূন্য হওয়া উচিত", bn)
