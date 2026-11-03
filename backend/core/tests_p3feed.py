"""p3feed (owner PART 3): live feed + Daily info from OFFICIAL sources only.

* Bangladesh Bank USD rate is owner-entered (no BB API) and leads the
  currency card with its own source + date; old -> stale.
* Official notice links card (load-shedding / BMD / flood) is always there.
* Prayer times come a week ahead so an offline phone shows the right day.
* Nothing is invented: no entry -> no official row; sports stay needs_key.
"""
from datetime import date, timedelta

from django.test import SimpleTestCase
from django.utils import timezone

from core import world_service as SVC
from core.logic import world_feeds as WF
from core.tests_p4_world import _WBase


class PureTests(SimpleTestCase):
    def test_fx_official_none_until_entered(self):
        rows = [{"key": "fx_usd_bb", "value": None, "effective_date": "", "updated_at": ""}]
        self.assertIsNone(WF.fx_official(rows, "bn", date(2026, 11, 3)))

    def test_fx_official_fresh_and_stale(self):
        rows = [{"key": "fx_usd_bb", "value": 122.5, "effective_date": "2026-11-02",
                 "updated_at": "2026-11-02"}]
        o = WF.fx_official(rows, "en", date(2026, 11, 3))
        self.assertEqual(o["bdt"], 122.5)
        self.assertEqual(o["source"], "Bangladesh Bank")
        self.assertIn("bb.org.bd", o["source_url"])
        self.assertFalse(o["stale"])
        self.assertTrue(WF.fx_official(rows, "en", date(2026, 11, 10))["stale"])

    def test_notice_links_official_https_only(self):
        c = WF.notices_card("bn")
        self.assertGreaterEqual(len(c["links"]), 9)
        for ln in c["links"]:
            self.assertTrue(ln["url"].startswith("https://"), ln)
            host = ln["url"].split("/")[2]
            self.assertTrue(host.endswith(".gov.bd") or host.endswith("bb.org.bd"), host)
            self.assertTrue(ln["label"])
        self.assertIn("power", {ln["group"] for ln in c["links"]})
        self.assertNotEqual(WF.notices_card("en")["links"][0]["label"], c["links"][0]["label"])

    def test_notices_is_a_card(self):
        self.assertIn("notices", WF.CARDS)
        self.assertTrue(WF.merge_cards({})["notices"])
        self.assertIn("fx_usd_bb", WF.ADMIN_VALUES)
        self.assertIn("fx", WF.ADMIN_SOURCES)


class TodayFeedTests(_WBase):
    def today(self, lang="bn"):
        return self.client.get("/api/v1/world/today", HTTP_ACCEPT_LANGUAGE=lang).json()

    def test_no_official_rate_until_owner_enters(self):
        c = self.today()["cards"]["currency"]
        self.assertNotIn("official", c)
        self.assertEqual(c["rows"][0]["code"], "USD")   # indicative rows unchanged

    def test_official_rate_leads_with_source_and_date(self):
        SVC.set_admin_value(None, "fx_usd_bb", 122.75, timezone.localdate())
        o = self.today("en")["cards"]["currency"]["official"]
        self.assertEqual(o["bdt"], 122.75)
        self.assertEqual(o["source"], "Bangladesh Bank")
        self.assertEqual(o["date"], timezone.localdate().isoformat())
        self.assertFalse(o["stale"])

    def test_official_rate_shown_even_when_indicative_feed_down(self):
        self.net.routes["https://open.er-api.com/"] = (500, b"")
        SVC.set_admin_value(None, "fx_usd_bb", 122.75,
                            timezone.localdate() - timedelta(days=9))
        j = self.today()
        c = j["cards"]["currency"]
        self.assertEqual(c["rows"], [])
        self.assertTrue(c["official"]["stale"])
        self.assertNotIn("currency", j["hidden"])

    def test_currency_hidden_when_nothing_real(self):
        self.net.routes["https://open.er-api.com/"] = (500, b"")
        self.assertEqual(self.today()["hidden"]["currency"], "unavailable")

    def test_notices_card_and_switch_off(self):
        self.assertIn("notices", self.today()["cards"])
        self.client.post("/api/v1/world/prefs", {"cards": {"notices": False}}, format="json")
        self.assertNotIn("notices", self.today()["cards"])

    def test_prayer_week_ahead_for_offline(self):
        p = self.today()["cards"]["prayer"]
        self.assertEqual(len(p["days"]), 7)
        tomorrow = (timezone.localdate() + timedelta(days=1)).isoformat()
        self.assertEqual(p["days"][0]["date"], tomorrow)
        self.assertIn("fajr", p["days"][0]["times"])
        self.assertIn("isha", p["days"][6]["times"])

    def test_sports_honest_needs_key(self):
        j = self.today()
        self.assertEqual(j["hidden"]["cricket"], "needs_key")
        self.assertNotIn("cricket", j["cards"])
