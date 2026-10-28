"""journey2 — Safe Journey destination picker + ride details + link revoke:
Maps-link parsing (long / short / geo / plain), the short-link resolver's
host allow-list, rough trip time, saved places (validated, one Home/School/
Office, delete, owner-only), place-name search honesty without a key, the
watcher link turned off (old links die, a fresh one works, pre-journey2
links still work), ride details mid-trip (cleaned, pushed once, ONE
language), and distance/rough time on the watcher page + in-app list.

Patches return plain values (never a bare MagicMock that gets JSON-encoded)."""
from unittest import mock

from django.core.cache import cache
from django.test import SimpleTestCase

from core import journey_geo as JG
from core import journey_watch as JW
from core.logic import journey_dest as JD
from core.models import Journey, JourneyEvent, SavedPlace
from core.tests_journey100 import V, Base

LONG = ("https://www.google.com/maps/place/Bashundhara+City/@23.7509,90.3901,17z/"
        "data=!3m1!4b1!4m6!3m5!1s0x0:0x0!8m2!3d23.750912!4d90.390133")


class ParseLinkTests(SimpleTestCase):
    def test_google_place_link_prefers_the_pin_and_keeps_the_name(self):
        got = JD.parse_maps_link(LONG)
        self.assertEqual((got["lat"], got["lng"]), (23.750912, 90.390133))
        self.assertEqual(got["name"], "Bashundhara City")

    def test_other_shapes(self):
        cases = {
            "https://www.google.com/maps?q=23.7806,90.4070": (23.7806, 90.407),
            "https://maps.google.com/?q=23.7806%2C90.4070": (23.7806, 90.407),
            "https://www.google.com/maps/search/?api=1&query=23.81,90.41": (23.81, 90.41),
            "https://www.google.com/maps/@23.7,90.35,15z": (23.7, 90.35),
            "geo:23.7806,90.4070?q=home": (23.7806, 90.407),
            "https://www.openstreetmap.org/#map=17/23.78/90.41": (23.78, 90.41),
            "Meet me here 23.780600, 90.407000 ok": (23.7806, 90.407),
        }
        for text, want in cases.items():
            got = JD.parse_maps_link(text)
            self.assertIsNotNone(got, text)
            self.assertEqual((got["lat"], got["lng"]), want, text)

    def test_no_coordinates_is_none_never_a_guess(self):
        for text in ("", "House 12, 4 Road", "https://example.com/?q=hello",
                     "https://www.google.com/maps?q=200,500", "0.0000, 0.0000",
                     "x" * 3000, "https://maps.app.goo.gl/AbCdEf"):
            self.assertIsNone(JD.parse_maps_link(text), text)

    def test_short_link_resolver_follows_google_only(self):
        hops = {"https://maps.app.goo.gl/AbC": "https://www.google.com/maps/place/X/@1,1,1z"
                                              "/data=!3d23.7001!4d90.4002"}
        got = JG.resolve_short_link("https://maps.app.goo.gl/AbC", fetch=lambda u: hops.get(u, ""))
        self.assertEqual((got["lat"], got["lng"]), (23.7001, 90.4002))
        seen = []

        def evil(u):
            seen.append(u)
            return "https://169.254.169.254/latest/?q=23.7,90.4"
        self.assertIsNone(JG.resolve_short_link("https://maps.app.goo.gl/AbC", fetch=evil))
        self.assertEqual(seen, ["https://maps.app.goo.gl/AbC"])   # never fetched the evil host
        self.assertIsNone(JG.resolve_short_link("http://maps.app.goo.gl/AbC", fetch=evil))
        self.assertTrue(JD.is_short_maps_link("https://maps.app.goo.gl/AbC"))
        self.assertFalse(JD.is_short_maps_link("https://evil.example/AbC"))

    def test_rough_minutes_never_sooner_than_true(self):
        self.assertIsNone(JD.rough_minutes(None))
        self.assertEqual(JD.rough_minutes(0), 5)
        # 5 km straight, CNG 12 km/h x 1.35 road factor = 33.75 -> 35
        self.assertEqual(JD.rough_minutes(5000, "cng"), 35)
        self.assertGreater(JD.rough_minutes(5000, "walk"), JD.rough_minutes(5000, "bike"))

    def test_clean_vehicle_whitelist(self):
        v = JD.clean_vehicle({"plate": "  DHAKA  METRO THA 11-2233 ", "mode": "CNG",
                              "app": "Pathao", "driver_name": "Rahim", "driver_phone": "017-1100 0002",
                              "evil": "<script>", "note": "n" * 500})
        self.assertEqual(v["plate"], "DHAKA METRO THA 11-2233")
        self.assertEqual((v["mode"], v["app"]), ("cng", "pathao"))
        self.assertEqual(v["driver_phone"], "01711000002")
        self.assertNotIn("evil", v)
        self.assertEqual(len(v["note"]), 120)
        self.assertIsNone(JD.clean_vehicle({"mode": "spaceship", "driver_phone": "12"}))
        self.assertIsNone(JD.clean_vehicle("nope"))
        self.assertEqual(JD.ride_line(v, "bn"), "সিএনজি · পাঠাও · DHAKA METRO THA 11-2233")
        self.assertEqual(JD.ride_line(v, "en"), "CNG · Pathao · DHAKA METRO THA 11-2233")


class PlacesTests(Base):
    def test_home_once_validated_deletable_owner_only(self):
        u = "%s/journey/places" % V
        r = self.ca.post(u, {"kind": "home", "name": "Home", "lat": 23.8, "lng": 90.4}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        r2 = self.ca.post(u, {"kind": "home", "name": "New home", "lat": 23.81, "lng": 90.41},
                          format="json")
        self.assertEqual(r2.status_code, 200)
        self.assertTrue(r2.json()["replaced"])
        self.assertEqual(SavedPlace.objects.filter(user=self.a).count(), 1)
        self.ca.post(u, {"kind": "school", "name": "School", "lat": 23.7, "lng": 90.3}, format="json")
        rows = self.ca.get(u).json()["places"]
        self.assertEqual([p["kind"] for p in rows], ["home", "school"])
        self.assertEqual(rows[0]["name"], "New home")
        # bad values are a clean 400 (used to be a 500)
        bad = self.ca.post(u, {"kind": "office", "lat": "abc", "lng": 90.4}, format="json")
        self.assertEqual((bad.status_code, bad.json()["detail"]), (400, "bad_coords"))
        none = self.ca.post(u, {"kind": "office", "name": "Office"}, format="json")
        self.assertEqual((none.status_code, none.json()["detail"]), (400, "coords_required"))
        pid = rows[1]["id"]
        self.assertEqual(self.cc.delete("%s/%d" % (u, pid)).status_code, 404)  # not theirs
        self.assertEqual(self.ca.delete("%s/%d" % (u, pid)).status_code, 200)
        self.assertEqual(len(self.ca.get(u).json()["places"]), 1)

    def test_parse_link_endpoint(self):
        u = "%s/journey/parse-link" % V
        r = self.ca.post(u, {"text": LONG}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["name"], "Bashundhara City")
        self.assertEqual(self.ca.post(u, {"text": "no link"}, format="json").status_code, 400)
        with mock.patch("core.journey_geo._location_of",
                        side_effect=lambda url: "https://www.google.com/maps?q=23.71,90.41"):
            r = self.ca.post(u, {"text": "Shared: https://maps.app.goo.gl/AbCd"}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual((r.json()["lat"], r.json()["lng"]), (23.71, 90.41))

    def test_geocode_is_honestly_off_without_a_key(self):
        r = self.ca.get("%s/journey/geocode?q=Bashundhara" % V).json()
        self.assertEqual(r, {"available": False, "results": [], "state": "off"})

    def test_geocode_with_key_returns_real_rows_only(self):
        rows = [{"name": "Bashundhara City", "address": "Panthapath", "lat": 23.75, "lng": 90.39}]
        with mock.patch("core.journey_geo.geocoder_ready", side_effect=lambda: True), \
                mock.patch("core.journey_geo.integrations.get",
                           side_effect=lambda k: {"api_key": "k"}), \
                mock.patch("core.journey_geo._places_text",
                           side_effect=lambda q, key, lang, near: list(rows)):
            r = self.ca.get("%s/journey/geocode?q=Bashundhara" % V).json()
        self.assertEqual(r["state"], "ok")
        self.assertEqual(r["results"], rows)


class RevokeRideProgressTests(Base):
    def setUp(self):
        super().setUp()
        cache.clear()

    def data(self, token):
        return self.client.get("/j/%s/data" % token)

    def test_turn_link_off_then_share_a_fresh_one(self):
        j, body = self.start()
        old = JW.web_token(j)
        self.assertEqual(old.split(".")[0], str(j.id))       # pre-journey2 shape still valid
        self.assertEqual(self.data(old).json()["state"], "waiting")
        r = self.ca.post("%s/journey/%d/web-link/revoke" % (V, j.id), {}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(self.data(old).json(), {"state": "revoked"})
        self.assertNotIn("lat", self.data(old).json())
        new = r.json()["url"].rsplit("/j/", 1)[1]
        self.assertNotEqual(new, old)
        self.assertEqual(self.data(new).json()["state"], "waiting")
        html = self.client.get("/j/%s" % old).content.decode()
        self.assertIn('"state": "revoked"', html)       # the page renders the off state
        self.assertNotIn('"lat"', html)
        # only the traveller can turn it off
        self.assertEqual(self.cc.post("%s/journey/%d/web-link/revoke" % (V, j.id), {},
                                      format="json").status_code, 404)

    def test_ride_details_mid_trip_cleaned_pushed_once_one_language(self):
        j, _ = self.start(vehicle={"plate": "DHA-1", "mode": "cng", "junk": "x" * 999})
        j.refresh_from_db()
        self.assertEqual(j.vehicle, {"plate": "DHA-1", "mode": "cng"})
        u = "%s/journey/%d/ride" % (V, j.id)
        body = {"app": "pathao", "driver_name": "Rahim", "driver_phone": "01711000009"}
        r = self.ca.post(u, body, format="json")
        self.assertTrue(r.json()["changed"])
        self.assertFalse(self.ca.post(u, body, format="json").json()["changed"])
        evs = JourneyEvent.objects.filter(journey=j, kind="vehicle")
        self.assertEqual(evs.count(), 1)
        mum = self.spy.to(self.b)
        ride = [c for c in mum if "পাঠাও" in c["bbn"]]
        self.assertTrue(ride, mum)
        self.assertIn("সিএনজি", ride[-1]["bbn"])
        self.assertNotIn("cng", ride[-1]["bbn"])
        self.assertIn("Pathao", ride[-1]["ben"])
        d = self.data(JW.web_token(j)).json()
        self.assertEqual(d["ride"]["driver_name"], "Rahim")
        self.assertEqual(d["ride"]["line"], "সিএনজি · পাঠাও · DHA-1")
        en = self.client.get("/j/%s/data?lang=en" % JW.web_token(j)).json()
        self.assertEqual(en["ride"]["line"], "CNG · Pathao · DHA-1")
        # not someone else's trip, not after it ended
        self.assertEqual(self.cc.post(u, body, format="json").status_code, 404)

    def test_distance_and_rough_time_only_with_a_pin(self):
        j, body = self.start(mode="cng")
        self.assertTrue(body["has_pin"])
        self.fix(j, 23.7550, 90.4000)            # ~5 km south of HOME (23.80, 90.40)
        d = self.data(JW.web_token(j)).json()
        self.assertAlmostEqual(d["distance_m"], 5004, delta=30)
        self.assertEqual(d["rough_min"], JD.rough_minutes(d["distance_m"], "cng"))
        w = self.cb.get("%s/journey/watching" % V).json()["journeys"][0]
        self.assertEqual(w["distance_m"], d["distance_m"])
        live = self.ca.get("%s/journey/active" % V).json()
        self.assertEqual(live["distance_m"], d["distance_m"])
        # name only (no pin): no distance, no time — never a guess
        j2, body2 = self.start(destination={"name": "Aunt's house"})
        self.assertFalse(body2["has_pin"])
        self.fix(j2, 23.7550, 90.4000)
        d2 = self.data(JW.web_token(j2)).json()
        self.assertNotIn("distance_m", d2)
        self.assertNotIn("rough_min", d2)

    def test_bangla_page_has_no_raw_codes(self):
        j, _ = self.start(vehicle={"plate": "DHA-1", "mode": "bike", "app": "uber"})
        self.fix(j, 23.7550, 90.4000)
        d = self.data(JW.web_token(j)).json()
        self.assertEqual(d["ride"]["line"], "বাইক · উবার · DHA-1")
        html = self.client.get("/j/%s" % JW.web_token(j)).content.decode()
        self.assertIn("সময়টা যাত্রী নিজে দিয়েছেন", html)
        self.assertEqual(Journey.objects.get(pk=j.pk).mode, "")   # mode came in the ride only
