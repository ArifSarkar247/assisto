"""p4-world: Owner Admin → Unseen World page (bn/en, feed on/off audited,
gold/fuel values validated + audited, hidden-until-entered on the app side)."""
from core.models import OwnerAudit, WorldAdminValue, WorldFeed
from web.tests_o2_owner_admin import OwnerBase


class WorldPanelTests(OwnerBase):
    def test_requires_login(self):
        r = self.c.get("/owner/world")
        self.assertEqual(r.status_code, 302)

    def test_page_bn_en_and_sources_listed(self):
        self.ready()
        r = self.c.get("/owner/world?lang=en")
        self.assertContains(r, "Data sources")
        self.assertContains(r, "BBC Bangla")
        self.assertContains(r, "ExchangeRate-API")
        self.assertContains(r, "web_search")
        self.assertContains(r, "Gold 22K (per bhori)")
        r = self.c.get("/owner/world?lang=bn")
        self.assertContains(r, "তথ্যের উৎস")

    def test_feed_toggle_audited(self):
        self.ready()
        self.c.get("/owner/world")
        self.assertTrue(WorldFeed.objects.get(slug="news_bbc_bangla").enabled)
        r = self.post("/owner/world", {"action": "feed", "slug": "news_bbc_bangla", "on": "0"})
        self.assertEqual(r.status_code, 302)
        self.assertFalse(WorldFeed.objects.get(slug="news_bbc_bangla").enabled)
        self.assertTrue(OwnerAudit.objects.filter(action="world.feed").exists())
        self.assertEqual(self.post("/owner/world", {"action": "feed", "slug": "nope", "on": "1"}).status_code, 404)

    def test_value_validated_and_audited(self):
        self.ready()
        r = self.post("/owner/world", {"action": "value", "key": "gold_22k", "value": "abc"})
        self.assertEqual(r.status_code, 400)
        self.assertFalse(WorldAdminValue.objects.filter(key="gold_22k", value__isnull=False).exists())
        r = self.post("/owner/world", {"action": "value", "key": "gold_22k", "value": "150,000",
                                       "effective_date": "2026-10-20"})
        self.assertEqual(r.status_code, 302)
        row = WorldAdminValue.objects.get(key="gold_22k")
        self.assertEqual(float(row.value), 150000.0)
        self.assertEqual(row.effective_date.isoformat(), "2026-10-20")
        a = OwnerAudit.objects.filter(action="world.value").first()
        self.assertEqual(a.after["value"], 150000.0)
        # clearing hides the card again
        self.post("/owner/world", {"action": "value", "key": "gold_22k", "value": ""})
        self.assertIsNone(WorldAdminValue.objects.get(key="gold_22k").value)
        self.assertEqual(self.post("/owner/world", {"action": "value", "key": "zzz", "value": "1"}).status_code, 404)
