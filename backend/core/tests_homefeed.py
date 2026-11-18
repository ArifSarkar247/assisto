"""homefeed (board row 38): Today facts are honest about WHEN they are from.

Recorded provider responses (core/test_data_p4: MET Norway, ExchangeRate-API,
publisher RSS) are loaded into the shared WorldFeed rows exactly as the
world_refresh cron stores them, then the clock is moved:

* every live card carries fetched_at / age_min / stale (our last good fetch);
* a source outage keeps the last real numbers with "stale" (never blank, never
  0) — and past the drop limit the numbers stop being shown as today's;
* forecast steps already in the past are dropped;
* once a copy exists the request never waits on a source (speed); a dead
  never-fetched source is not re-asked on every open;
* owner-entered gold / fuel prices turn stale after 7 / 35 days;
* undated headlines of a dead feed disappear; prayer times say their date.
"""
import json
from datetime import datetime, timedelta, timezone as dt_timezone
from unittest import mock

from django.test import SimpleTestCase
from django.utils import timezone

from core import world_service as SVC
from core.logic import world_feeds as WF
from core.models import WorldFeed
from core.tests_p4_world import _WBase, _raw

NOW = datetime(2026, 10, 23, 19, 0, tzinfo=dt_timezone.utc)   # fixture day


def _met():
    return WF.parse_met(json.loads(_raw("met_dhaka.json")))


def _fx():
    return WF.parse_fx(json.loads(_raw("er_usd.json")))


class FreshnessPureTests(SimpleTestCase):
    def test_freshness_fields(self):
        f = WF.freshness(NOW - timedelta(minutes=42), NOW, "weather")
        self.assertEqual(f["age_min"], 42)
        self.assertFalse(f["stale"])
        self.assertEqual(f["fetched_at"], (NOW - timedelta(minutes=42)).isoformat())
        self.assertTrue(WF.freshness(NOW - timedelta(hours=4), NOW, "weather")["stale"])
        self.assertEqual(WF.freshness(None, NOW, "weather"), {})

    def test_too_old_limits(self):
        self.assertFalse(WF.too_old(NOW - timedelta(hours=23), NOW, "weather"))
        self.assertTrue(WF.too_old(NOW - timedelta(hours=25), NOW, "weather"))
        self.assertFalse(WF.too_old(NOW - timedelta(days=30), NOW, "fx"))   # fx is never dropped

    def test_past_forecast_steps_dropped(self):
        w = WF.weather_public(_met(), "bn", NOW)
        self.assertEqual([s["time"] for s in w["next"]], ["2026-10-24T00:00:00Z"])
        self.assertEqual(len(WF.weather_public(_met(), "bn")["next"]), 2)   # no clock = unchanged

    def test_admin_stale_days(self):
        today = NOW.date()
        card = {"updated": (today - timedelta(days=7)).isoformat()}
        self.assertFalse(WF.admin_stale(card, "gold", today))
        card = {"updated": (today - timedelta(days=8)).isoformat()}
        self.assertTrue(WF.admin_stale(card, "gold", today))
        self.assertFalse(WF.admin_stale(card, "fuel", today))
        self.assertTrue(WF.admin_stale({"updated": ""}, "fuel", today))


class TodayFreshnessTests(_WBase):
    def _row(self, slug, kind, payload, ok_ago, fetched_ago=None, err=""):
        return WorldFeed.objects.create(
            slug=slug, kind=kind, payload=payload,
            last_ok_at=NOW - ok_ago if ok_ago is not None else None,
            fetched_at=NOW - (fetched_ago if fetched_ago is not None else ok_ago or timedelta()),
            last_error=err)

    def today(self, lang="bn", now=NOW):
        with mock.patch.object(timezone, "now", return_value=now):
            return self.client.get("/api/v1/world/today", HTTP_ACCEPT_LANGUAGE=lang).json()

    def _hits(self, host):
        return [c for c in self.net.calls if host in c]

    def test_fresh_weather_and_fx_dated(self):
        self._row("weather_dhaka", "weather", _met(), timedelta(minutes=30))
        self._row("fx_usd", "fx", _fx(), timedelta(hours=2))
        j = self.today()
        w, fx = j["cards"]["weather"], j["cards"]["currency"]
        self.assertEqual(w["age_min"], 30)
        self.assertFalse(w["stale"])
        self.assertEqual(fx["age_min"], 120)
        self.assertFalse(fx["stale"])
        self.assertEqual(fx["rows"][0]["code"], "USD")
        self.assertGreater(fx["rows"][0]["bdt"], 0)
        # a copy exists -> the request asked no source (fast open)
        self.assertEqual(self._hits("api.met.no") + self._hits("er-api.com"), [])

    def test_outage_keeps_last_real_numbers_marked_stale(self):
        self.net.routes["https://api.met.no/"] = (503, b"")
        self.net.routes["https://open.er-api.com/"] = (503, b"")
        self._row("weather_dhaka", "weather", _met(), timedelta(hours=5),
                  fetched_ago=timedelta(minutes=5), err="HTTP 503")
        self._row("fx_usd", "fx", _fx(), timedelta(hours=40),
                  fetched_ago=timedelta(minutes=5), err="HTTP 503")
        j = self.today()
        w, fx = j["cards"]["weather"], j["cards"]["currency"]
        self.assertTrue(w["stale"])
        self.assertEqual(w["age_min"], 300)
        self.assertAlmostEqual(w["temp"], 28.4)            # the real last value, not 0 / blank
        self.assertTrue(fx["stale"])
        self.assertTrue(all(r["bdt"] > 0 for r in fx["rows"]))
        self.assertNotIn("weather", j["hidden"])

    def test_weather_older_than_a_day_not_shown_as_today(self):
        self._row("weather_dhaka", "weather", _met(), timedelta(hours=30))
        j = self.today(now=NOW)
        self.assertNotIn("weather", j["cards"])
        self.assertEqual(j["hidden"]["weather"], "stale")
        self.assertEqual(j["hidden_since"]["weather"], (NOW - timedelta(hours=30)).isoformat())

    def test_provider_stopped_updating_is_stale(self):
        self._row("fx_usd", "fx", _fx(), timedelta(minutes=10))
        later = NOW + timedelta(days=3)          # fixture rates are from 23 Oct 00:02 UTC
        WorldFeed.objects.filter(slug="fx_usd").update(last_ok_at=later - timedelta(minutes=10),
                                                       fetched_at=later - timedelta(minutes=10))
        fx = self.today(now=later)["cards"]["currency"]
        self.assertEqual(fx["age_min"], 10)
        self.assertTrue(fx["stale"])

    def test_cold_start_fetches_once_with_short_timeout(self):
        seen = []
        net = self.net

        def spy(method, url, headers=None, body=None, timeout=None):
            seen.append((url.split("/")[2], timeout))
            return net(method, url, headers, body, timeout)
        with mock.patch.object(SVC, "_fetch", spy):
            j = self.today()
        self.assertIn("weather", j["cards"])
        self.assertIn(("api.met.no", SVC.INLINE_TIMEOUT_S), seen)
        self.assertIn(("open.er-api.com", SVC.INLINE_TIMEOUT_S), seen)

    def test_dead_cold_source_not_retried_each_open(self):
        self.net.routes["https://api.met.no/"] = (503, b"")
        self.today()
        n = len(self._hits("api.met.no"))
        self.assertEqual(n, 1)
        self.today(now=NOW + timedelta(minutes=3))
        self.assertEqual(len(self._hits("api.met.no")), 1)
        self.today(now=NOW + timedelta(minutes=11))
        self.assertEqual(len(self._hits("api.met.no")), 2)
        self.assertEqual(self.today(now=NOW + timedelta(minutes=12))["hidden"]["weather"], "unavailable")

    def test_gold_and_fuel_stale_after_their_limits(self):
        day = NOW.date()
        SVC.set_admin_value(None, "gold_22k", 152000, day - timedelta(days=20))
        SVC.set_admin_value(None, "fuel_octane", 126, day - timedelta(days=10))
        c = self.today(lang="en")["cards"]
        self.assertTrue(c["gold"]["stale"])
        self.assertEqual(c["gold"]["updated"], (day - timedelta(days=20)).isoformat())
        self.assertFalse(c["fuel"]["stale"])
        SVC.set_admin_value(None, "gold_22k", 152000, day)
        self.assertFalse(self.today(lang="en")["cards"]["gold"]["stale"])

    def test_news_dated_and_dead_feed_undated_items_dropped(self):
        payload = {"items": [
            {"title": "Dated", "link": "https://feeds.bbci.co.uk/bengali/a",
             "snippet": "", "published": (NOW - timedelta(hours=2)).isoformat()},
            {"title": "Undated", "link": "https://feeds.bbci.co.uk/bengali/b",
             "snippet": "", "published": ""}]}
        r = self._row("news_bbc_bangla", "news", payload, timedelta(minutes=20))
        c = self.today()["cards"]["news_bd"]
        self.assertEqual({i["title"] for i in c["items"]}, {"Dated", "Undated"})
        self.assertEqual(c["age_min"], 20)
        # the feed has failed for 3 days: the undated one is no longer "fresh"
        WorldFeed.objects.filter(pk=r.pk).update(last_ok_at=NOW - timedelta(days=3))
        c = self.today(now=NOW)["cards"]["news_bd"]
        self.assertEqual([i["title"] for i in c["items"]], ["Dated"])   # still < 48 h old
        # two days later the dated one is past 48 h too: honest "unavailable"
        j = self.today(now=NOW + timedelta(days=2))
        self.assertNotIn("news_bd", j["cards"])
        self.assertEqual(j["hidden"]["news_bd"], "unavailable")

    def test_old_live_scores_hidden(self):
        self.keys(sports_cricket={"api_key": "c-test"})
        self._row("sports_cricket", "sports",
                  {"matches": [{"name": "BAN vs IND", "status": "Live", "score": "", "live": True}]},
                  timedelta(hours=7))
        j = self.today()
        self.assertEqual(j["hidden"]["cricket"], "stale")
        self.assertIn("cricket", j["hidden_since"])
        self.assertEqual(self._hits("cricapi"), [])        # a copy exists: no inline call

    def test_prayer_says_its_date(self):
        j = self.today()
        p = j["cards"]["prayer"]
        self.assertEqual(p["date"], timezone.localtime(NOW).date().isoformat())
        self.assertTrue(all(":" in v for v in p["times"].values()))
        self.assertEqual(j["hidden_since"], {})

    def test_bangla_weather_label(self):
        self._row("weather_dhaka", "weather", _met(), timedelta(minutes=5))
        w = self.today("bn")["cards"]["weather"]
        self.assertRegex(w["label"], "[ঀ-৿]")

    def test_ci_world_sample_is_an_honest_outage(self):
        """seed_reality's sample (emulator flow 40): outage weather + old gold."""
        from core import world_sample
        world_sample.load(now=NOW)
        j = self.today()
        w = j["cards"]["weather"]
        self.assertTrue(w["stale"])
        self.assertEqual(w["age_min"], 300)
        self.assertTrue(all(s["time"] > NOW.isoformat() for s in w["next"]))
        self.assertFalse(j["cards"]["currency"]["stale"])
        self.assertTrue(j["cards"]["gold"]["stale"])
        self.assertFalse(j["cards"]["fuel"]["stale"])
        self.assertEqual(self._hits("api.met.no") + self._hits("er-api.com"), [])
