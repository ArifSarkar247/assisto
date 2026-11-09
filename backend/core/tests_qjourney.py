"""qjourney (owner Safe Journey V2, 9 Nov): never a false "Arrived".

Owner bug: a Gazipur trip showed "Arrived safely" 5 minutes after leaving
Badda; on 6 Nov two trips "arrived" while the phone was still at the start.
Root cause: POST /journey/<id>/arrived accepted an arrival anywhere, any time,
and a trip could start with a destination without coordinates."""
from datetime import timedelta
from unittest import mock

from django.utils import timezone

from core import journey_watch as JW
from core.logic import journey_arrival as JA
from core.models import Journey, JourneyPoint
from core.tests_journey100 import V, Base

BADDA = {"name": "Badda", "lat": 23.7806, "lng": 90.4265}
GAZIPUR = {"name": "Gazipur Chowrasta", "lat": 23.9999, "lng": 90.4203}


class PureTests(Base):
    def test_badda_to_gazipur_in_5_minutes_is_impossible(self):
        now = timezone.now()
        start = now - timedelta(minutes=5)
        o, d = JA.point(BADDA), JA.point(GAZIPUR)
        c = JA.earliest_arrival(start, o, d, "car")
        self.assertGreater(c, now)          # ~23 km straight: >= 10 min by car
        a = JA.assess(dest=d, now=now, start_at=start, origin=o, here=d, mode="car")
        self.assertEqual(a["reason"], "too_early")
        a = JA.assess(dest=d, now=now + timedelta(minutes=50), start_at=start, origin=o,
                      here=d, mode="car")
        self.assertTrue(a["ok"])

    def test_still_at_the_start_is_far(self):
        now = timezone.now()
        a = JA.assess(dest=JA.point(GAZIPUR), now=now, start_at=now - timedelta(hours=3),
                      origin=JA.point(BADDA), here=JA.point(BADDA))
        self.assertEqual(a["reason"], "far")
        self.assertGreater(a["distance_m"], 20000)

    def test_unverifiable_cases(self):
        now = timezone.now()
        self.assertEqual(JA.assess(dest=None, now=now)["reason"], "no_destination")
        self.assertEqual(JA.assess(dest=JA.point(GAZIPUR), now=now)["reason"], "no_location")
        old = now - timedelta(minutes=JA.FIX_MAX_AGE_MIN + 1)
        self.assertEqual(JA.assess(dest=JA.point(GAZIPUR), now=now, here=JA.point(GAZIPUR),
                                   here_at=old)["reason"], "no_location")
        self.assertIsNone(JA.point({"lat": 0, "lng": 0}))
        self.assertIsNone(JA.point({"lat": "x", "lng": 90}))
        self.assertIsNone(JA.point({"name": "Gazipur"}))


class ViewTests(Base):
    def go(self, minutes_ago=5, **kw):
        body = {"destination": GAZIPUR, "origin": BADDA, "mode": "car",
                "eta": (timezone.now() + timedelta(minutes=60)).isoformat(),
                "watcher_ids": [self.ab.id]}
        body.update(kw)
        r = self.ca.post("%s/journey/start" % V, body, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        Journey.objects.filter(pk=r.json()["id"]).update(
            created_at=timezone.now() - timedelta(minutes=minutes_ago))
        return Journey.objects.get(pk=r.json()["id"])

    def arrive(self, j, **body):
        return self.ca.post("%s/journey/%d/arrived" % (V, j.id), body, format="json")

    def kinds_to_b(self):
        return [c["data"].get("event") for c in self.spy.to(self.b)]

    def test_no_start_without_destination_coordinates(self):
        r = self.ca.post("%s/journey/start" % V, {
            "destination": {"name": "Gazipur"}, "watcher_ids": [self.ab.id]}, format="json")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()["detail"], "destination_coords_required")
        self.assertFalse(Journey.objects.exists())
        # a share-for-a-while still needs no destination
        r = self.ca.post("%s/journey/start" % V, {"share_minutes": 60,
                                                   "watcher_ids": [self.ab.id]}, format="json")
        self.assertEqual(r.status_code, 201, r.content)

    def test_owner_bug_arrived_at_the_start_is_unusual_never_safe(self):
        j = self.go(minutes_ago=12)
        self.fix_at(j, BADDA)
        r = self.arrive(j).json()
        self.assertEqual(r["status"], "arrived")
        self.assertEqual(r["arrival"], "unusual")
        self.assertEqual(r["reason"], "far")
        self.assertIn("arrival_unusual", self.kinds_to_b())
        self.assertNotIn("arrived", self.kinds_to_b())
        bn = [c for c in self.spy.to(self.b) if c["data"].get("event") == "arrival_unusual"][0]
        self.assertIn("অস্বাভাবিক", bn["tbn"])
        self.assertTrue(bn["high"])

    def test_impossibly_early_at_the_destination_is_unusual(self):
        j = self.go(minutes_ago=5)
        r = self.arrive(j, lat=GAZIPUR["lat"], lng=GAZIPUR["lng"], acc=20).json()
        self.assertEqual(r["reason"], "too_early")
        self.assertNotIn("arrived", self.kinds_to_b())

    def test_no_location_at_all_is_unusual(self):
        j = self.go(minutes_ago=90)
        r = self.arrive(j).json()
        self.assertEqual(r["reason"], "no_location")

    def test_real_arrival_is_arrived_safely(self):
        j = self.go(minutes_ago=50)
        r = self.arrive(j, lat=GAZIPUR["lat"] + 0.003, lng=GAZIPUR["lng"], acc=15).json()
        self.assertEqual(r["status"], "arrived")
        self.assertNotIn("arrival", r)
        self.assertIn("arrived", self.kinds_to_b())

    def test_planned_earliest_from_the_start_screen_wins(self):
        later = (timezone.now() + timedelta(minutes=20)).isoformat()
        j = self.go(minutes_ago=50, destination=dict(GAZIPUR, earliest_at=later))
        r = self.arrive(j, lat=GAZIPUR["lat"], lng=GAZIPUR["lng"]).json()
        self.assertEqual(r["reason"], "too_early")

    def test_unusual_with_pin_asks_it_safe_pin_confirms_danger_pin_is_silent(self):
        self.ca.post("%s/journey/duress-pin" % V, {"pin": "1234", "duress_pin": "9876"},
                     format="json")
        j = self.go(minutes_ago=12)
        self.fix_at(j, BADDA)
        r = self.arrive(j)
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()["pin"], "required")
        self.assertEqual(r.json()["arrival"], "unusual")
        j.refresh_from_db()
        self.assertEqual(j.status, "active")          # not accepted without the PIN
        self.assertEqual(self.arrive(j, pin="0000").json()["pin"], "wrong")
        r = self.arrive(j, pin="1234").json()
        self.assertEqual(r["arrival"], "confirmed_pin")
        ev = [c for c in self.spy.to(self.b) if c["data"].get("event") == "arrived"]
        self.assertIn("confirmed with PIN", ev[0]["ten"])
        # danger PIN: the same "arrived" answer, watchers get a silent SOS
        j2 = self.go(minutes_ago=12)
        self.fix_at(j2, BADDA)
        r = self.arrive(j2, pin="9876").json()
        self.assertEqual(r, {"ok": True, "status": "arrived"})
        j2.refresh_from_db()
        self.assertTrue(j2.sos_active and j2.silent)

    def test_shared_check_for_sjduring(self):
        j = self.go(minutes_ago=5)
        out = JW.arrival_plausible(j, here=JA.point(BADDA))
        self.assertFalse(out["ok"])
        self.assertIsNotNone(out["earliest_at"])

    def fix_at(self, j, place):
        JourneyPoint.objects.create(journey=j, lat=place["lat"], lng=place["lng"],
                                    at=timezone.now())
        j.last_location = {"lat": place["lat"], "lng": place["lng"],
                           "at": timezone.now().isoformat()}
        j.save(update_fields=["last_location"])


# ---------------------------------------------------------------- place search
from core import bd_places as BP  # noqa: E402
from core import maps_cost as MC  # noqa: E402
from core.tests_mapscost import KEY, MapsBase  # noqa: E402

S = "qjourney-sess-0001"


class PlaceListTests(MapsBase):
    """Owner V2 proof list: Gai, গাইবান্ধা, Badda, Shahjalal airport — with
    the Google budget on and off. Our own OSM list answers first."""

    def find(self, q, **kw):
        r = self.c1.get("%s/maps/search" % V, {"q": q, "session": S, **kw}).json()
        return r, [x["name"] for x in r["results"]]

    def test_the_list_is_real_and_big(self):
        self.assertTrue(BP.available())
        self.assertIn("OpenStreetMap", BP.source())
        kinds = {r[0] for r in BP._rows}
        for k in ("division", "district", "upazila", "area", "station", "airport"):
            self.assertIn(k, kinds)
        self.assertEqual(sum(1 for r in BP._rows if r[0] == "district"), 64)

    def test_gai_and_bangla_script_find_gaibandha_without_google(self):
        for q in ("Gai", "গাইবান্ধা", "gaibanda"):
            r, names = self.find(q, lang="en")
            self.assertEqual(r["state"], "ok", q)
            self.assertTrue(any("Gaibandha" in n or "গাইবান্ধা" in n for n in names), (q, names))
            row = r["results"][0]
            self.assertTrue(row["place_id"].startswith("bd:"))
            self.assertIsInstance(row["lat"], float)       # no paid Place Details
        bn = self.c1.get("%s/maps/search" % V, {"q": "গাইবান্ধা", "session": S},
                         HTTP_ACCEPT_LANGUAGE="bn").json()
        self.assertIn("গাইবান্ধা", bn["results"][0]["name"])

    def test_badda_and_shahjalal_airport(self):
        _, names = self.find("Badda")
        self.assertTrue(any("Badda" in n or "বাড্ডা" in n for n in names), names)
        r, names = self.find("Shahjalal airport")
        self.assertTrue(any("Shahjalal" in n or "শাহজালাল" in n for n in names), names)
        air = [x for x in r["results"] if x["kind"] == "airport"][0]
        self.assertEqual(air["radius_m"], 400)
        self.assertAlmostEqual(air["lat"], 23.84, delta=0.05)

    def test_budget_on_google_only_when_fewer_than_5_good(self):
        _, _ = self.find("Gai")               # many good local rows
        self.assertEqual(self.rec.calls, [])  # no Google at all
        r, names = self.find("Bashundhara City")
        self.assertTrue(r["google"])
        self.assertIn("Bashundhara City", names)
        self.assertEqual(len(self.rec.calls), 1)
        self.assertEqual(self.rec.calls[0]["body"]["sessionToken"], S)

    def test_budget_off_or_used_up_is_silent(self):
        with mock.patch.object(MC, "server_key", lambda: ""):
            r, names = self.find("Gaibandha")
        self.assertEqual(r["state"], "ok")
        self.assertTrue(names)
        self.limits("autocomplete", user_day=0, global_day=0)
        r, names = self.find("Zzqx nowhere")
        self.assertEqual(r["state"], "none")      # never user_cap / global_cap / off
        self.assertEqual(self.c1.get("%s/maps/status" % V).json()["places"], True)
