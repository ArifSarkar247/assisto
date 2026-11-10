"""admobump — OWNER ADS FINAL (2 Nov), server side:
* /ads/config: interstitials only at the registered EXIT placements, max 4 a
  day, >= 800 s apart (whatever is stored); a pre-2-Nov stored list
  (photo_saved / task_done) maps to the new defaults; never-list screens
  carry no banner;
* Ad impact: `exit` events (app closed right after an interstitial) are an
  aggregate count per placement — deduped, interstitial only, Free only —
  and Owner Admin lists every exit placement with impressions, estimated
  income and the exit share;
* Owner Admin label "Interstitial unit ID" (stored key unchanged)."""
import os
from datetime import timedelta
from unittest import mock

from django.core.cache import cache
from django.test import SimpleTestCase
from django.utils import timezone
from rest_framework.test import APITestCase

from core.logic import ads as A
from core.logic import pricing as P
from core.models import AdPlacementStat, User
from web.tests_o2_owner_admin import OwnerBase


def _cfg(**caps):
    return A.client_config(plan="free", paid=False, admob_cfg={}, admob_working=False,
                           flag_rewarded=True, flag_app_open=True,
                           ad_caps=dict(P.DEFAULTS()["ad_rewards"], **caps))


class ExitConfigTests(SimpleTestCase):
    def test_registered_exit_placements(self):
        # 11 exit placements (2 Nov) + 4 owner transition moments (10 Nov)
        self.assertEqual(len(A.INTERSTITIAL_MOMENTS), 15)
        self.assertIn("photo_after_save", A.INTERSTITIAL_MOMENTS)
        self.assertIn("exam_after_submit", A.INTERSTITIAL_MOMENTS)
        for pid in A.INTERSTITIAL_MOMENTS:
            self.assertFalse(A.is_blocked_screen(pid), pid)

    def test_caps_come_from_ad_control_clamped(self):
        # adcontrol (owner 10 Nov): the old ad_rewards fields no longer decide
        c = _cfg(interstitial_daily_cap=20, interstitial_min_gap_sec=300)
        self.assertEqual((c["interstitial_daily_cap"], c["interstitial_min_gap_sec"]), (6, 180))
        c = A.client_config(plan="free", paid=False, admob_cfg={}, admob_working=False,
                            flag_rewarded=True, flag_app_open=True,
                            ad_caps=P.DEFAULTS()["ad_rewards"],
                            ad_control={"caps": {"interstitial_daily_cap": 99,
                                                 "interstitial_min_gap_sec": 10}})
        self.assertEqual((c["interstitial_daily_cap"], c["interstitial_min_gap_sec"]), (12, 180))

    def test_moments_follow_the_registry_switches(self):
        c = _cfg(interstitial_moments="photo_saved,task_done")
        self.assertEqual(sorted(c["interstitial_moments"]), sorted(A.INTERSTITIAL_MOMENTS))
        off = {"placements": {"plan_after_save": {"on": False}}}
        c = A.client_config(plan="free", paid=False, admob_cfg={}, admob_working=False,
                            flag_rewarded=True, flag_app_open=True,
                            ad_caps=P.DEFAULTS()["ad_rewards"], ad_control=off)
        self.assertNotIn("plan_after_save", c["interstitial_moments"])
        self.assertFalse(c["control"]["placements"]["plan_after_save"]["on"])

    def test_never_list_screens_carry_no_banner(self):
        for s in ("money", "budget", "reminders", "notes_todos", "health_tips",
                  "medicine_db", "crm", "business", "prepaid_meter", "ramadan",
                  "cctv", "vehicle_alerts", "missing_person", "blood_donor",
                  "train_tracker", "destination_alarm", "quran", "food_calories",
                  "task_manager", "school_mode", "kids_watch", "invoice", "sales",
                  "business_khata"):
            self.assertTrue(A.is_blocked_screen(s), s)
            self.assertNotIn(s, A.BANNER_SCREENS)
        c = _cfg(banner_screens="money,budget,dictionary,reminders")
        self.assertEqual(c["banner_screens"], ["dictionary"])

    def test_paid_plan_no_interstitial(self):
        c = A.client_config(plan="premium", paid=True, admob_cfg={}, admob_working=False,
                            flag_rewarded=True, flag_app_open=True,
                            ad_caps=P.DEFAULTS()["ad_rewards"])
        self.assertFalse(c["placements"]["interstitial"])
        self.assertEqual(c["interstitial_moments"], [])


class AdImpactAggregationTests(SimpleTestCase):
    def test_every_placement_listed_with_exit_share(self):
        rows = [
            {"placement": "interstitial_photo_after_save", "format": "interstitial",
             "impressions": 40, "clicks": 1, "paid_events": 0, "revenue_micros": 0, "currency": ""},
            {"placement": "interstitial_photo_after_save", "format": "interstitial",
             "impressions": 0, "clicks": 0, "paid_events": 40, "revenue_micros": 2_000_000,
             "currency": "USD"},
            {"placement": "interstitial_photo_after_save", "format": "exit",
             "impressions": 6, "clicks": 0, "paid_events": 0, "revenue_micros": 0, "currency": ""},
            {"placement": "banner_dictionary", "format": "banner",
             "impressions": 100, "clicks": 2, "paid_events": 0, "revenue_micros": 0, "currency": ""},
        ]
        rep = A.placement_report(rows)
        self.assertNotIn("exit", [r["format"] for r in rep])   # folded in
        imp = A.ad_impact(rep)
        self.assertEqual([r["placement"] for r in imp], list(A.INTERSTITIAL_MOMENTS))
        p = imp[0]
        self.assertEqual(p["placement"], "photo_after_save")
        self.assertEqual((p["impressions"], p["exits"], p["exit_pct"]), (40, 6, 15.0))
        self.assertEqual(p["revenue_text"], "USD 2.00")
        self.assertEqual(imp[1]["impressions"], 0)
        self.assertEqual(imp[1]["revenue_text"], "—")


class ExitEventTests(APITestCase):
    def mk(self, phone, plan="free"):
        u = User.objects.create_user(name="U" + phone[-2:], phone=phone, password="pw")
        u.plan = plan
        if plan != "free":
            u.plan_until = timezone.now() + timedelta(days=30)
        u.save()
        return u

    def setUp(self):
        cache.clear()
        self.free = self.mk("01999300201")
        self.prem = self.mk("01999300202", "premium")

    def post(self, user, **d):
        self.client.force_authenticate(user)
        return self.client.post("/api/v1/ads/event", d, format="json")

    def exits(self, pl="interstitial_photo_after_save"):
        return sum(r.impressions for r in
                   AdPlacementStat.objects.filter(placement=pl, fmt="exit"))

    def test_counted_once_per_minute_no_ids_stored(self):
        ev = {"kind": "exit", "format": "interstitial",
              "placement": "interstitial_photo_after_save"}
        self.assertTrue(self.post(self.free, **ev).json()["counted"])
        self.assertFalse(self.post(self.free, **ev).json()["counted"])   # duplicate
        self.assertEqual(self.exits(), 1)
        row = AdPlacementStat.objects.get(fmt="exit")
        self.assertEqual(row.clicks, 0)
        # the impression counter of the ad itself is untouched
        self.assertFalse(AdPlacementStat.objects.filter(fmt="interstitial").exists())

    def test_only_for_interstitials_and_free_users(self):
        r = self.post(self.free, kind="exit", format="banner", placement="banner_dictionary")
        self.assertEqual(r.status_code, 400)
        r = self.post(self.prem, kind="exit", format="interstitial",
                      placement="interstitial_photo_after_save")
        self.assertEqual(r.json()["reason"], "not_free")
        self.assertEqual(self.exits(), 0)


class OwnerAdImpactTests(OwnerBase):
    def setUp(self):
        super().setUp()
        self.ready()

    def test_ads_page_lists_every_exit_placement(self):
        today = timezone.localdate()
        AdPlacementStat.objects.create(date=today, placement="interstitial_plan_after_save",
                                       fmt="interstitial", impressions=10)
        AdPlacementStat.objects.create(date=today, placement="interstitial_plan_after_save",
                                       fmt="exit", impressions=2)
        html = self.c.get("/owner/ads?lang=en").content.decode()
        self.assertIn('id="ad-impact"', html)
        self.assertIn("Closed the app right after", html)
        for pid in A.INTERSTITIAL_MOMENTS:
            self.assertIn("<th>%s</th>" % pid, html)
        self.assertIn("2 (20%)", html)


class IntegrationLabelTests(SimpleTestCase):
    def test_interstitial_label_no_photo_studio_key_kept(self):
        from core.integrations import REGISTRY
        f = {x["key"]: x for x in REGISTRY["admob"]["fields"]}["interstitial_unit"]
        blob = str(f)
        self.assertIn("Interstitial unit ID", blob)
        self.assertNotIn("Photo Studio", blob)
        self.assertNotIn("ফটো স্টুডিও", blob)
