"""mapscost (owner order 3 Nov 18:40, PART 1) — paid maps calls only through
the capped server proxy. CI makes NO real Google call: maps_cost.HTTP is
replaced by a recorder that returns plain dicts (never a bare MagicMock).

Covers: per-user daily limit, global daily cap + free fallback, off without a
key / with the cost switch off, reverse-geocode cache hit within 50 m (and a
miss beyond), Autocomplete (2+ chars, session token, field masks) + ONE Place
Details Essentials, Routes once + cached, SOS makes zero maps calls, the
usage-card math, the server key never reaching the app, the web share page on
OpenStreetMap tiles with attribution."""
from unittest import mock

from django.core.cache import cache
from django.test import TestCase, override_settings
from django.utils import timezone

from core import maps_cost as MC
from core.models import MapsGeoCache, MapsUsage
from core.tests_journey100 import V, Base, cl, mk

KEY = "srv-key-NEVER-TO-PHONE"


class Rec:
    """Records every would-be Google call; answers like Google would."""

    def __init__(self):
        self.calls = []

    def __call__(self, url, body=None, headers=None):
        self.calls.append({"url": url, "body": body, "headers": headers or {}})
        if "geocode/json" in url:
            return {"status": "OK", "results": [{"formatted_address": "Road 5, Dhanmondi, Dhaka"}]}
        if "places:autocomplete" in url:
            return {"suggestions": [{"placePrediction": {
                "placeId": "ChIJabc123", "structuredFormat": {
                    "mainText": {"text": "Bashundhara City"},
                    "secondaryText": {"text": "Panthapath, Dhaka"}}}}]}
        if "/v1/places/" in url:
            return {"id": "ChIJabc123", "location": {"latitude": 23.7509, "longitude": 90.3901},
                    "formattedAddress": "Panthapath, Dhaka 1205"}
        if "computeRoutes" in url:
            return {"routes": [{"duration": "1500s", "distanceMeters": 6400}]}
        raise AssertionError("unexpected url " + url)


class MapsBase(TestCase):
    def setUp(self):
        cache.clear()
        self.u1 = mk("01711900001", "Rina")
        self.u2 = mk("01711900002", "Karim")
        self.c1, self.c2 = cl(self.u1), cl(self.u2)
        self.rec = Rec()
        patches = [mock.patch.object(MC, "HTTP", self.rec),
                   mock.patch.object(MC, "server_key", lambda: KEY)]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)

    def limits(self, api, **kw):
        MC.save_config(api, kw)


class LimitTests(MapsBase):
    def test_per_user_daily_limit_then_fallback(self):
        self.limits("geocode", user_day=2, global_day=100)
        pts = [(23.70, 90.40), (23.71, 90.40), (23.72, 90.40)]
        states = [self.c1.get("%s/maps/reverse?lat=%s&lng=%s" % (V, la, ln)).json()
                  for la, ln in pts]
        self.assertEqual([s["state"] for s in states], ["ok", "ok", "user_cap"])
        self.assertEqual(len(self.rec.calls), 2)                 # the 3rd never paid
        self.assertEqual(states[2]["address"], "")
        self.assertEqual(states[2]["coords"], "23.72000, 90.40000")
        self.assertIn("google.com/maps/search/?api=1&query=23.720000,90.400000",
                      states[2]["gmaps_url"])
        # another user still has their own allowance
        r = self.c2.get("%s/maps/reverse?lat=23.73&lng=90.40" % V).json()
        self.assertEqual(r["state"], "ok")
        row = MapsUsage.objects.get(api="geocode", user_id=self.u1.id)
        self.assertEqual((row.count, row.capped), (2, 1))

    def test_global_daily_cap_and_fallback(self):
        self.limits("geocode", user_day=50, global_day=1)
        a = self.c1.get("%s/maps/reverse?lat=23.70&lng=90.40" % V).json()
        b = self.c2.get("%s/maps/reverse?lat=23.80&lng=90.41" % V).json()
        self.assertEqual((a["state"], b["state"]), ("ok", "global_cap"))
        self.assertEqual(len(self.rec.calls), 1)
        self.assertTrue(b["gmaps_url"].startswith("https://www.google.com/maps/search/"))
        card = MC.usage_card()
        g = [r for r in card["rows"] if r["api"] == "geocode"][0]
        self.assertEqual((g["today"], g["capped_today"]), (1, 1))

    def test_off_without_key_or_with_cost_switch_off(self):
        with mock.patch.object(MC, "server_key", lambda: ""):
            r = self.c1.get("%s/maps/reverse?lat=23.7&lng=90.4" % V).json()
        self.assertEqual(r["state"], "off")
        with mock.patch("core.billing.flag_on", lambda *a, **k: False):
            r = self.c1.get("%s/maps/autocomplete?q=Bashundhara&session=abcdefgh12" % V).json()
        self.assertEqual(r["state"], "off")
        self.assertEqual(self.rec.calls, [])
        self.assertFalse(MapsUsage.objects.exists())

    def test_plan_cap_hook_refuses_and_notes(self):
        noted = []
        with mock.patch.object(MC, "_plan_allowed", lambda u: False):
            r = self.c1.get("%s/maps/reverse?lat=23.70&lng=90.40" % V).json()
        self.assertEqual(r["state"], "plan_cap")
        with mock.patch.object(MC, "_plan_note", lambda u: noted.append(u.id)):
            self.c1.get("%s/maps/reverse?lat=23.71&lng=90.40" % V)
        self.assertEqual(noted, [self.u1.id])
        self.assertEqual(len(self.rec.calls), 1)
        # before safeplans merges the hook falls back to "allowed"
        self.assertTrue(MC._plan_allowed(self.u1))

    def test_bad_points_are_refused_without_a_call(self):
        for q in ("lat=&lng=", "lat=200&lng=90", "lat=0&lng=0", "lat=x&lng=y"):
            self.assertEqual(self.c1.get("%s/maps/reverse?%s" % (V, q)).json()["state"], "bad")
        self.assertEqual(self.rec.calls, [])

    def test_owner_limits_validated(self):
        with self.assertRaises(ValueError):
            MC.save_config("geocode", {"user_day": -1})
        with self.assertRaises(ValueError):
            MC.save_config("nope", {"user_day": 1})
        with self.assertRaises(ValueError):
            MC.save_config(None, bdt_per_usd=0)


class GeoCacheTests(MapsBase):
    def test_cache_hit_within_50m_and_miss_beyond(self):
        r1 = self.c1.get("%s/maps/reverse?lat=23.746000&lng=90.376000" % V).json()
        self.assertEqual((r1["state"], r1["address"]), ("ok", "Road 5, Dhanmondi, Dhaka"))
        # ~30 m north-east (also across a grid-cell edge for some points)
        r2 = self.c2.get("%s/maps/reverse?lat=23.746200&lng=90.376200" % V).json()
        self.assertEqual((r2["state"], r2["address"]), ("cache", "Road 5, Dhanmondi, Dhaka"))
        self.assertEqual(len(self.rec.calls), 1)
        # just across a cell boundary, 20 m away -> still a hit
        MC.cache_store(23.749990, 90.380000, "en", "Edge Road")
        self.assertEqual(MC.cache_lookup(23.750150, 90.380000, "en"), "Edge Road")
        # ~120 m away -> pays again
        r3 = self.c1.get("%s/maps/reverse?lat=23.747100&lng=90.376000" % V).json()
        self.assertEqual(r3["state"], "ok")
        self.assertEqual(len(self.rec.calls), 2)

    def test_cache_is_per_language(self):
        MC.cache_store(23.7, 90.4, "bn", "ঢাকা")
        self.assertIsNone(MC.cache_lookup(23.7, 90.4, "en"))
        self.assertEqual(MapsGeoCache.objects.count(), 1)


class SearchTests(MapsBase):
    def test_short_query_and_bad_session_make_no_call(self):
        self.assertEqual(self.c1.get("%s/maps/autocomplete?q=a&session=abcdefgh12" % V)
                         .json()["state"], "short")
        self.assertEqual(self.c1.get("%s/maps/autocomplete?q=Bashundhara&session=x" % V)
                         .json()["state"], "bad_session")
        self.assertEqual(self.rec.calls, [])

    def test_autocomplete_session_token_field_masks_then_one_details(self):
        s = "sess-0001-abcdef"
        r = self.c1.get("%s/maps/autocomplete?q=Bashun&session=%s&lat=23.75&lng=90.39" % (V, s)).json()
        self.assertEqual(r["state"], "ok")
        self.assertEqual(r["results"], [{"place_id": "ChIJabc123", "name": "Bashundhara City",
                                         "secondary": "Panthapath, Dhaka"}])
        call = self.rec.calls[0]
        self.assertEqual(call["body"]["sessionToken"], s)
        self.assertEqual(call["body"]["includedRegionCodes"], ["bd"])
        self.assertEqual(call["headers"]["X-Goog-FieldMask"], MC.AUTOCOMPLETE_MASK)
        self.assertEqual(call["headers"]["X-Goog-Api-Key"], KEY)
        d = self.c1.get("%s/maps/place?id=ChIJabc123&session=%s" % (V, s)).json()
        self.assertEqual((d["state"], d["lat"], d["lng"]), ("ok", 23.7509, 90.3901))
        det = self.rec.calls[1]
        self.assertIn("sessionToken=%s" % s, det["url"])
        self.assertEqual(det["headers"]["X-Goog-FieldMask"], "id,location,formattedAddress")
        # the same place again is served from cache — no second Details call
        d2 = self.c2.get("%s/maps/place?id=ChIJabc123&session=other-sess-01" % V).json()
        self.assertEqual(d2["state"], "cache")
        self.assertEqual(len(self.rec.calls), 2)
        # and the resolved address now feeds the 50 m reverse cache
        self.assertEqual(MC.cache_lookup(23.7510, 90.3902, "en"), "Panthapath, Dhaka 1205")

    def test_old_text_search_is_capped_too(self):
        self.limits("text_search", user_day=1, global_day=10)
        rows = [{"name": "X", "address": "", "lat": 23.7, "lng": 90.4}]
        with mock.patch("core.journey_geo.geocoder_ready", lambda: True), \
                mock.patch("core.journey_geo._places_text", side_effect=lambda *a: list(rows)):
            a = self.c1.get("%s/journey/geocode?q=Bashundhara" % V).json()
            b = self.c1.get("%s/journey/geocode?q=Bashundhara" % V).json()
        self.assertEqual((a["state"], b["state"]), ("ok", "user_cap"))


class RouteTests(MapsBase):
    def test_eta_once_then_cached(self):
        q = "olat=23.75&olng=90.39&dlat=23.80&dlng=90.42&mode=cng"
        a = self.c1.get("%s/maps/eta?%s" % (V, q)).json()
        self.assertEqual((a["state"], a["minutes"], a["distance_m"]), ("ok", 25, 6400))
        self.assertEqual(self.rec.calls[0]["headers"]["X-Goog-FieldMask"],
                         "routes.duration,routes.distanceMeters")
        b = self.c1.get("%s/maps/eta?%s" % (V, q)).json()
        self.assertEqual(b["state"], "cache")
        self.assertEqual(len(self.rec.calls), 1)
        self.assertIn("google.com/maps/dir/", b["gmaps_url"])

    def test_eta_capped_still_gives_the_free_directions_link(self):
        self.limits("routes", user_day=0)
        a = self.c1.get("%s/maps/eta?olat=23.75&olng=90.39&dlat=23.8&dlng=90.42" % V).json()
        self.assertEqual(a["state"], "user_cap")
        self.assertIn("google.com/maps/dir/", a["gmaps_url"])
        self.assertEqual(self.rec.calls, [])


class SosNeverCallsMapsTests(Base):
    def test_sos_paths_make_zero_maps_calls(self):
        rec = Rec()
        boom = mock.Mock(side_effect=AssertionError("network during SOS"))
        with mock.patch.object(MC, "HTTP", rec), \
                mock.patch.object(MC, "server_key", lambda: KEY), \
                mock.patch("core.maps_cost.allow", side_effect=AssertionError("maps during SOS")), \
                mock.patch("core.journey_geo._places_text", boom), \
                mock.patch("core.nearby._get", boom):
            j, _ = self.start()
            r = self.ca.post("%s/journey/sos" % V,
                             {"journey_id": j.id, "lat": 23.75, "lng": 90.39}, format="json")
            self.assertEqual(r.status_code, 200, r.content)
            r = self.ca.post("%s/family/sos" % V, {"lat": 23.75, "lng": 90.39}, format="json")
            self.assertLess(r.status_code, 500, r.content)
        self.assertEqual(rec.calls, [])
        boom.assert_not_called()
        self.assertFalse(MapsUsage.objects.exists())


class UsageCardMathTests(TestCase):
    def test_cost_only_above_free_cap_usd_and_bdt(self):
        self.assertEqual(MC.cost_usd(9999, 10000, 5.0), 0.0)
        self.assertEqual(MC.cost_usd(10500, 10000, 5.0), 2.5)
        today = timezone.localdate()
        MapsUsage.objects.create(day=today, api="geocode", user_id=1, count=10400)
        MapsUsage.objects.create(day=today, api="geocode", user_id=2, count=100, capped=7)
        MapsUsage.objects.create(day=today, api="routes", user_id=1, count=5100)
        MC.save_config(None, bdt_per_usd=120)
        card = MC.usage_card()
        g = {r["api"]: r for r in card["rows"]}
        self.assertEqual((g["geocode"]["month"], g["geocode"]["today"]), (10500, 10500))
        self.assertEqual(g["geocode"]["capped_today"], 7)
        self.assertEqual(g["geocode"]["free_left"], 0)
        self.assertEqual((g["geocode"]["usd"], g["geocode"]["bdt"]), (2.5, 300.0))
        self.assertEqual(g["routes"]["usd"], 1.0)                 # 100 over x $10/1000
        self.assertEqual(g["autocomplete"]["free_left"], 10000)
        self.assertEqual((card["usd"], card["bdt"]), (3.5, 420.0))

    def test_previous_month_not_counted(self):
        today = timezone.localdate()
        last = today.replace(day=1) - timezone.timedelta(days=1)
        MapsUsage.objects.create(day=last, api="geocode", user_id=1, count=50000)
        g = [r for r in MC.usage_card()["rows"] if r["api"] == "geocode"][0]
        self.assertEqual(g["month"], 0)


class KeyNeverToPhoneTests(MapsBase):
    def test_no_maps_answer_contains_the_server_key(self):
        bodies = [self.c1.get("%s/maps/status" % V).content,
                  self.c1.get("%s/maps/reverse?lat=23.7&lng=90.4" % V).content,
                  self.c1.get("%s/maps/autocomplete?q=Gulshan&session=abcdefgh12" % V).content,
                  self.c1.get("%s/maps/eta?olat=23.7&olng=90.4&dlat=23.8&dlng=90.41" % V).content]
        for b in bodies:
            self.assertNotIn(KEY.encode(), b)
        self.assertEqual(self.c1.get("%s/maps/status" % V).json()["min_chars"], 2)

    def test_needs_login(self):
        from rest_framework.test import APIClient
        self.assertIn(APIClient().get("%s/maps/reverse?lat=23.7&lng=90.4" % V).status_code,
                      (401, 403))


class WebShareOsmTests(Base):
    @override_settings(MAP_TILE_URL="")
    def test_share_page_uses_osm_tiles_with_attribution_and_origin_referrer(self):
        from core import journey_watch as JW
        j, _ = self.start()
        html = self.client.get("/j/%s" % JW.web_token(j)).content.decode()
        self.assertIn("tile.openstreetmap.org", html)
        self.assertIn("openstreetmap.org/copyright", html)
        self.assertIn("strict-origin", html)
        # the app's own map (flutter_map) still never gets the OSMF server
        self.assertEqual(JW.tile_config()["tile_url"], "")

    @override_settings(MAP_TILE_URL="https://maps.example.com/{z}/{x}/{y}.png?key=k")
    def test_licensed_tiles_win_when_configured(self):
        from core import journey_watch as JW
        self.assertIn("maps.example.com", JW.tile_config(web=True)["tile_url"])


class ChandraSearchTests(MapsBase):
    """jsearch (owner phone test 4 Nov 00:05): typing "Ch" / "Chandra" near
    Gazipur lists Chandra Mor and Chandra Bus Terminal with the area line and
    the distance; bias to the user + Bangladesh; one Details ends it."""

    def setUp(self):
        super().setUp()
        base = self.rec

        def rec(url, body=None, headers=None):
            if "places:autocomplete" in url:
                base.calls.append({"url": url, "body": body, "headers": headers or {}})
                return {"suggestions": [
                    {"placePrediction": {"placeId": "ChIJchandraMor", "distanceMeters": 2140,
                                         "structuredFormat": {
                                             "mainText": {"text": "Chandra Mor"},
                                             "secondaryText": {"text": "Kaliakair, Gazipur"}}}},
                    {"placePrediction": {"placeId": "ChIJchandraBus", "distanceMeters": 2380,
                                         "structuredFormat": {
                                             "mainText": {"text": "Chandra Bus Terminal"},
                                             "secondaryText": {"text": "Chandra, Kaliakair, Gazipur"}}}}]}
            if "/v1/places/ChIJchandraMor" in url:
                base.calls.append({"url": url, "body": body, "headers": headers or {}})
                return {"id": "ChIJchandraMor", "location": {"latitude": 24.0469, "longitude": 90.2405},
                        "formattedAddress": "Chandra Mor, Dhaka-Tangail Hwy, Kaliakair 1750, Gazipur"}
            return base(url, body, headers)
        p = mock.patch.object(MC, "HTTP", rec)
        p.start()
        self.addCleanup(p.stop)

    def test_two_letters_already_search_with_bias_region_and_distance(self):
        s = "chandra-sess-0001"
        r = self.c1.get("%s/maps/autocomplete?q=Ch&session=%s&lat=24.03&lng=90.25" % (V, s)).json()
        self.assertEqual(r["state"], "ok")
        body = self.rec.calls[0]["body"]
        self.assertEqual((body["input"], body["sessionToken"]), ("Ch", s))
        self.assertEqual(body["includedRegionCodes"], ["bd"])
        self.assertEqual(body["regionCode"], "bd")
        self.assertIn(body["languageCode"], ("bn", "en"))
        self.assertEqual(body["locationBias"]["circle"]["center"], {"latitude": 24.03, "longitude": 90.25})
        self.assertEqual(body["origin"], {"latitude": 24.03, "longitude": 90.25})
        self.assertIn("distanceMeters", self.rec.calls[0]["headers"]["X-Goog-FieldMask"])

    def test_chandra_lists_mor_and_bus_terminal_then_details_ends_session(self):
        s = "chandra-sess-0002"
        r = self.c1.get("%s/maps/autocomplete?q=Chandra&session=%s&lat=24.03&lng=90.25" % (V, s)).json()
        self.assertEqual([x["name"] for x in r["results"]], ["Chandra Mor", "Chandra Bus Terminal"])
        self.assertEqual(r["results"][0]["secondary"], "Kaliakair, Gazipur")
        self.assertEqual(r["results"][0]["distance_m"], 2140)
        d = self.c1.get("%s/maps/place?id=ChIJchandraMor&session=%s" % (V, s)).json()
        self.assertEqual(d["state"], "ok")
        self.assertEqual((d["lat"], d["lng"]), (24.0469, 90.2405))
        self.assertIn("Kaliakair", d["address"])
        det = self.rec.calls[1]
        self.assertIn("sessionToken=%s" % s, det["url"])
        self.assertEqual(det["headers"]["X-Goog-FieldMask"], "id,location,formattedAddress")
        self.assertEqual(len(self.rec.calls), 2)

    def test_search_uses_places_new_never_legacy_endpoints(self):
        self.c1.get("%s/maps/autocomplete?q=Chandra&session=chandra-sess-0003" % V)
        self.c1.get("%s/maps/place?id=ChIJchandraMor&session=chandra-sess-0003" % V)
        for c in self.rec.calls:
            self.assertTrue(c["url"].startswith("https://places.googleapis.com/v1/"), c["url"])
            self.assertNotIn("maps/api/place", c["url"])
