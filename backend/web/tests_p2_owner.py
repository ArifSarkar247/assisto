"""p2-money: Owner Admin — sponsors, campaigns (checklist-gated approval,
safety check, Discover card), reports + CSV, ad impact, new ad knobs."""
from datetime import timedelta

from django.utils import timezone

from core.models import (DiscoverCard, OwnerAudit, Sponsor, SponsorCampaign,
                         SponsorDailyStat)
from web.tests_o2_owner_admin import OwnerBase


class SponsorPanelTests(OwnerBase):
    def setUp(self):
        super().setUp()
        self.ready()

    def _campaign(self, **kw):
        s = Sponsor.objects.create(name="Brand A")
        now = timezone.localtime()
        d = {"sponsor": s.id, "name": "Oct hero", "placement": "discover", "pricing": "flat",
             "price_bdt": "3000", "budget_bdt": "0",
             "start_at": (now - timedelta(days=1)).strftime("%Y-%m-%dT%H:%M"),
             "end_at": (now + timedelta(days=9)).strftime("%Y-%m-%dT%H:%M"),
             "title_bn": "নতুন ফোন", "title_en": "New phone", "body_bn": "ভালো দাম",
             "body_en": "Good price", "link_url": "https://example.com/phone",
             "categories": ["mobile"]}
        d.update(kw)
        r = self.post("/owner/campaigns/new", d)
        return s, r

    def test_pages_render_bn_en(self):
        for lang in ("bn", "en"):
            for path in ("/owner/sponsors", "/owner/impact", "/owner/ads"):
                r = self.c.get(path + "?lang=" + lang)
                self.assertEqual(r.status_code, 200, path)
        self.assertIn("স্পনসর", self.c.get("/owner/sponsors?lang=bn").content.decode())

    def test_sponsor_crud(self):
        r = self.post("/owner/sponsors", {"name": "Brand B", "category": "fashion"})
        self.assertEqual(r.status_code, 302)
        s = Sponsor.objects.get(name="Brand B")
        r = self.post("/owner/sponsors/%d" % s.id, {"name": "Brand B2"})
        s.refresh_from_db()
        self.assertEqual((s.name, s.active), ("Brand B2", False))
        self.assertTrue(OwnerAudit.objects.filter(action="sponsor.update").exists())
        self.assertEqual(self.post("/owner/sponsors", {"name": ""}).status_code, 400)

    def test_campaign_needs_checklist_to_approve(self):
        _, r = self._campaign()
        self.assertEqual(r.status_code, 302)
        c = SponsorCampaign.objects.get()
        self.assertEqual(c.status, "draft")
        r = self.post("/owner/campaigns/%d" % c.id, {"action": "approve"})
        self.assertEqual(r.status_code, 400)
        c.refresh_from_db()
        self.assertEqual(c.status, "draft")
        form = {"action": "save", "name": c.name, "placement": "discover", "pricing": "flat",
                "price_bdt": "3000", "budget_bdt": "0",
                "start_at": timezone.localtime(c.start_at).strftime("%Y-%m-%dT%H:%M"),
                "end_at": timezone.localtime(c.end_at).strftime("%Y-%m-%dT%H:%M"),
                "title_bn": c.title_bn, "title_en": c.title_en, "link_url": c.link_url}
        for k in ("no_scam", "no_gambling", "no_adult", "no_fake_claims",
                  "landing_page_checked", "sponsor_verified"):
            form["chk_" + k] = "on"
        self.assertEqual(self.post("/owner/campaigns/%d" % c.id, form).status_code, 302)
        self.assertEqual(self.post("/owner/campaigns/%d" % c.id,
                                   {"action": "approve"}).status_code, 302)
        c.refresh_from_db()
        self.assertEqual(c.status, "approved")
        # discover placement -> a Free-only SPONSORED Discover card
        self.post("/owner/campaigns/%d" % c.id, {"action": "discover_card"})
        c.refresh_from_db()
        card = DiscoverCard.objects.get(pk=c.discover_card_id)
        self.assertEqual((card.type, card.audience, card.enabled), ("SPONSORED", "free", True))
        self.post("/owner/campaigns/%d" % c.id, {"action": "pause"})
        card.refresh_from_db()
        self.assertFalse(card.enabled)

    def test_safety_check_flags_gambling(self):
        _, r = self._campaign(title_en="Casino jackpot", name="Bad")
        self.assertEqual(r.status_code, 302)
        c = SponsorCampaign.objects.get(name="Bad")
        self.assertTrue(c.safety_issues)

    def test_bad_dates_and_link(self):
        _, r = self._campaign(end_at="", name="X")
        self.assertEqual(r.status_code, 400)
        _, r = self._campaign(link_url="http://example.com", name="Y")
        self.assertEqual(r.status_code, 400)

    def test_report_and_csv(self):
        self._campaign()
        c = SponsorCampaign.objects.get()
        SponsorDailyStat.objects.create(campaign=c, date=timezone.localdate(),
                                        impressions=100, clicks=4)
        r = self.c.get("/owner/campaigns/%d/report" % c.id)
        self.assertEqual(r.status_code, 200)
        r = self.c.get("/owner/campaigns/%d/report.csv" % c.id)
        self.assertEqual(r.status_code, 200)
        self.assertIn("TOTAL", r.content.decode())

    def test_new_ad_knobs_editable_with_bounds(self):
        r = self.post("/owner/ads", {"action": "settings", "ad_rewards.appopen_daily_cap": "2",
                                     "ad_rewards.offer_notif_daily_cap": "1",
                                     "ad_rewards.sponsors_enabled": "on",
                                     "ad_rewards.offers_enabled": "on",
                                     "ad_rewards.community_sponsored_enabled": "on",
                                     "ad_rewards.hero_start_muted": "on",
                                     "reason": "test"})
        self.assertEqual(r.status_code, 302)
        from core import billing
        ar = billing.cfg()["ad_rewards"]
        self.assertEqual((ar["appopen_daily_cap"], ar["offer_notif_daily_cap"]), (2, 1))
        r = self.post("/owner/ads", {"action": "settings", "ad_rewards.appopen_daily_cap": "40",
                                     "reason": "too many"})
        self.assertEqual(r.status_code, 400)
        self.assertEqual(billing.cfg()["ad_rewards"]["appopen_daily_cap"], 2)
