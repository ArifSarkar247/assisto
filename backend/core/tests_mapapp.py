"""mapapp (owner order 10 Nov 00:35, PART A 3 + 4): the City Service map's
backend side.

* Google view transit: GET /maps/transit — live Google Routes TRANSIT,
  parsed to a small shape, NEVER cached or stored (a second identical call
  pays again; no DB row besides the usage counter), Google attribution,
  server key never in the answer, caps -> state "none" (never a limit).
* Learn from trips: POST /city/trips/confirm (one tap: which bus, what fare;
  anon key only, no free text) -> ride confirmation + crowd fare + "You
  verified N stops"; processed GPS trips add their known stops too.
* GET /city/map -> tiles base + credits.
CI makes no real Google call (maps_cost.HTTP is replaced). Sample data only."""
import json
from unittest import mock

from django.core.cache import cache

from core import city_service as CS
from core import maps_cost as MC
from core.models import CityFareReport, CityLearned, MapsUsage
from core.tests_city import ApiBase, _trace
from core.tests_mapscost import KEY, MapsBase, Rec
from core.tests_journey100 import V

GOOGLE = {"routes": [{
    "duration": "2460s", "distanceMeters": 9100,
    "polyline": {"encodedPolyline": "abc_def"},
    "travelAdvisory": {"transitFare": {"currencyCode": "BDT", "units": "60"}},
    "legs": [{"steps": [
        {"travelMode": "WALK", "staticDuration": "180s", "distanceMeters": 200},
        {"travelMode": "WALK", "staticDuration": "60s", "distanceMeters": 50},
        {"travelMode": "TRANSIT", "staticDuration": "1500s", "distanceMeters": 8000,
         "transitDetails": {"stopCount": 6, "headsign": "Motijheel",
                            "stopDetails": {"departureStop": {"name": "Mirpur 10"},
                                            "arrivalStop": {"name": "Motijheel"}},
                            "transitLine": {"name": "MRT Line 6", "nameShort": "MRT-6", "color": "#0a7c3e",
                                            "vehicle": {"type": "SUBWAY"},
                                            "agencies": [{"name": "Sample Metro Agency"}]}}},
        {"travelMode": "WALK", "staticDuration": "300s", "distanceMeters": 400},
    ]}]}]}


class TransitRec(Rec):
    def __call__(self, url, body=None, headers=None):
        if "computeRoutes" in url and (body or {}).get("travelMode") == "TRANSIT":
            self.calls.append({"url": url, "body": body, "headers": headers or {}})
            return json.loads(json.dumps(GOOGLE))
        return super().__call__(url, body, headers)


class GoogleTransitTests(MapsBase):
    def setUp(self):
        super().setUp()
        self.rec = TransitRec()
        p = mock.patch.object(MC, "HTTP", self.rec)
        p.start()
        self.addCleanup(p.stop)

    Q = "olat=23.807&olng=90.368&dlat=23.728&dlng=90.419"

    def test_live_transit_parsed_attributed_never_stored(self):
        a = self.c1.get("%s/maps/transit?%s" % (V, self.Q)).json()
        self.assertEqual(a["state"], "ok")
        self.assertEqual(a["attribution"], "Google")
        r = a["routes"][0]
        self.assertEqual((r["minutes"], r["distance_m"], r["fare_bdt"]), (41, 9100, 60))
        self.assertEqual([s["mode"] for s in r["steps"]], ["walk", "metro", "walk"])
        self.assertEqual(r["steps"][0]["minutes"], 4)                       # two walks merged
        m = r["steps"][1]
        self.assertEqual((m["line"], m["from"], m["to"], m["stops"]), ("MRT-6", "Mirpur 10", "Motijheel", 6))
        call = self.rec.calls[0]
        self.assertEqual(call["body"]["travelMode"], "TRANSIT")
        self.assertEqual(call["headers"]["X-Goog-FieldMask"], MC.TRANSIT_MASK)
        self.assertNotIn(KEY, json.dumps(a))                                # key never to the phone
        # never cached: the same request pays (and is counted) again
        self.c1.get("%s/maps/transit?%s" % (V, self.Q))
        self.assertEqual(len(self.rec.calls), 2)
        self.assertEqual(MapsUsage.objects.get(api="routes", user_id=self.u1.id).count, 2)
        # nothing Google-made lands in our City data
        self.assertEqual(CityLearned.objects.count(), 0)
        self.assertEqual(CityFareReport.objects.count(), 0)

    def test_capped_or_off_is_silent_none(self):
        self.limits("routes", user_day=0)
        a = self.c1.get("%s/maps/transit?%s" % (V, self.Q)).json()
        self.assertEqual((a["state"], a["routes"]), ("none", []))          # never "user_cap"
        self.assertIn("travelmode=transit", a["gmaps_url"])
        self.assertEqual(self.rec.calls, [])
        with mock.patch.object(MC, "server_key", lambda: ""):
            b = self.c2.get("%s/maps/transit?%s" % (V, self.Q)).json()
        self.assertEqual(b["state"], "none")

    def test_bad_points_and_no_transit_route(self):
        self.assertEqual(self.c1.get("%s/maps/transit?olat=x" % V).json()["state"], "bad")
        with mock.patch.object(MC, "HTTP", lambda *a, **k: {"routes": [{"legs": [{"steps": [
                {"travelMode": "WALK", "staticDuration": "60s"}]}]}]}):
            a = self.c1.get("%s/maps/transit?%s" % (V, self.Q)).json()
        self.assertEqual((a["state"], a["routes"]), ("none", []))


class TripConfirmTests(ApiBase):
    def test_confirm_counts_stops_fare_and_ride_without_name(self):
        r = self.c.post("/api/v1/city/trips/confirm",
                        {"route_id": "busA-a", "board_id": "n1", "alight_id": "n5", "paid": 25},
                        format="json")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(r.json()["stops_verified"], 2)
        ride = CityLearned.objects.get(kind="ride", key="busA-a")
        self.assertEqual(ride.data["fares"], [25])
        self.assertEqual(ride.data["pairs"], [["n1", "n5"]])
        self.assertEqual(ride.anons, [CS.anon_key(self.user)])             # anon key only, no user id
        f = CityFareReport.objects.get()
        self.assertEqual((f.mode, f.paid), ("bus", 25))
        # same stops again do not double count; another bus adds one stop
        self.c.post("/api/v1/city/trips/confirm", {"route_id": "", "board_id": "n5", "alight_id": "n4"},
                    format="json")
        mine = self.c.get("/api/v1/city/trips/mine").json()
        self.assertEqual((mine["stops_verified"], mine["rides"]), (3, 2))
        self.assertEqual(self.as_(self.user2).get("/api/v1/city/trips/mine").json()["stops_verified"], 0)

    def test_confirm_rejects_unknown_route_stops_and_bad_fare(self):
        bad = [{"route_id": "nope", "board_id": "n1", "alight_id": "n5"},
               {"route_id": "busA-a", "board_id": "n1", "alight_id": "n1"},
               {"route_id": "busA-a", "board_id": "zz", "alight_id": "n5"},
               {"route_id": "busA-a", "board_id": "n1", "alight_id": "n5", "paid": 2},
               {"route_id": "busA-a", "board_id": "n1", "alight_id": "n5", "mode": "plane"}]
        for b in bad:
            self.assertEqual(self.c.post("/api/v1/city/trips/confirm", b, format="json").status_code, 400, b)
        self.assertEqual(CityLearned.objects.count(), 0)

    def test_daily_limit(self):
        cache.clear()
        with mock.patch.object(CS, "RIDE_DAY_MAX", 1):
            ok = self.c.post("/api/v1/city/trips/confirm", {"board_id": "n1", "alight_id": "n2"}, format="json")
            no = self.c.post("/api/v1/city/trips/confirm", {"board_id": "n2", "alight_id": "n3"}, format="json")
        self.assertEqual((ok.status_code, no.status_code), (201, 429))

    def test_processed_gps_trip_adds_known_stops(self):
        CS.consent(self.user, True)
        self.assertEqual(self.c.post("/api/v1/city/trips", {"mode": "bus", "points": _trace()},
                                     format="json").status_code, 201)
        CS.learn_tick()
        self.assertGreaterEqual(self.c.get("/api/v1/city/trips/mine").json()["stops_verified"], 3)

    def test_map_config(self):
        d = self.c.get("/api/v1/city/map").json()
        self.assertTrue(d["tiles_base"].startswith("https://") and d["tiles_base"].endswith("/"))
        self.assertIn("OpenStreetMap", d["credits"])
