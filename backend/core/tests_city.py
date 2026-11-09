"""citydata (owner 9 Nov 11:45): City Service backend — routing (cheapest /
fastest / fewest changes / safer at night, metro exit gate, < 500 ms), fares
(Official / Reported by users / Estimate with dates), live reports (60-min
expiry, merge, flags), corrections -> overrides -> phone package refresh,
crowd fares, trip learning (consent, trimming, confirmation, purge), honest
"no data" + Google Maps link, import + tick without network.
All coordinates/names here are made-up sample data around public landmarks."""
import gzip
import json
from datetime import timedelta
from unittest import mock

from django.core.cache import cache
from django.core.management import call_command
from django.test import SimpleTestCase, TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import city_service as CS
from core.citytransit import engine as E
from core.citytransit import fares as F
from core.models import (CityCorrection, CityDataset, CityFareReport, CityLearned, CityLiveReport,
                         CityTrip, User)

FARMGATE = (23.7577, 90.3897)
MOTIJHEEL = (23.7330, 90.4177)
UTTARA = (23.8690, 90.3675)
SHAHBAG = (23.7385, 90.3958)
NORTH_OF_FARMGATE_GATE = (23.7605, 90.3893)


def make_net(version="20261109-test"):
    stops = [
        # metro
        ["mrt6-UTN", "Uttara North", "উত্তরা উত্তর", 23.8690, 90.3670, "metro", "v", "UTN"],
        ["mrt6-AGA", "Agargaon", "আগারগাঁও", 23.7780, 90.3800, "metro", "v", "AGA"],
        ["mrt6-FAR", "Farmgate", "ফার্মগেট", 23.7580, 90.3900, "metro", "v", "FAR"],
        ["mrt6-SHB", "Shahbag", "শাহবাগ", 23.7390, 90.3960, "metro", "v", "SHB"],
        ["mrt6-MOT", "Motijheel", "মতিঝিল", 23.7280, 90.4190, "metro", "v", "MOT"],
        # bus
        ["n1", "Farmgate", "ফার্মগেট", 23.7572, 90.3902, "bus", "v", ""],
        ["n2", "Karwan Bazar", "কারওয়ান বাজার", 23.7510, 90.3930, "bus", "r", ""],
        ["n3", "Shahbag", "শাহবাগ", 23.7385, 90.3955, "bus", "v", ""],
        ["n4", "Paltan", "পল্টন", 23.7340, 90.4120, "bus", "r", ""],
        ["n5", "Motijheel", "মতিঝিল", 23.7332, 90.4175, "bus", "v", ""],
        ["n6", "Mirpur 10", "মিরপুর ১০", 23.8069, 90.3685, "bus", "v", ""],
        ["n7", "Mohakhali", "মহাখালী", 23.7781, 90.4053, "bus", "v", ""],
        ["n8", "Gulshan 1", "গুলশান ১", 23.7808, 90.4167, "bus", "r", ""],
    ]
    ix = {s[0]: i for i, s in enumerate(stops)}

    def r(rid, mode, name, ids, km, st="r", **kw):
        d = {"id": rid, "mode": mode, "name": name, "name_bn": "", "ref": "", "op": name, "st": st,
             "src": [{"s": "test"}], "stops": [ix[x] for x in ids], "km": km}
        d.update(kw)
        return d

    routes = [
        r("mrt6-a", "metro", "MRT Line 6", ["mrt6-UTN", "mrt6-AGA", "mrt6-FAR", "mrt6-SHB", "mrt6-MOT"],
          [0, 11.73, 14.0, 16.4, 20.1], "v", hw=8, spd=38.0, dwell=30),
        r("mrt6-b", "metro", "MRT Line 6", ["mrt6-MOT", "mrt6-SHB", "mrt6-FAR", "mrt6-AGA", "mrt6-UTN"],
          [0, 3.7, 6.1, 8.37, 20.1], "v", hw=8, spd=38.0, dwell=30),
        r("busA-a", "bus", "Shatabdi", ["n1", "n2", "n3", "n4", "n5"], [0, 0.9, 2.4, 4.2, 4.9], "v"),
        r("busA-b", "bus", "Shatabdi", ["n5", "n4", "n3", "n2", "n1"], [0, 0.7, 2.5, 4.0, 4.9], "v"),
        r("busB-a", "bus", "Gulshan Chaka", ["n6", "n7", "n8"], [0, 5.0, 6.4]),
        r("busB-b", "bus", "Gulshan Chaka", ["n8", "n7", "n6"], [0, 1.4, 6.4]),
        r("leg1", "leguna", "Farmgate-Mohakhali leguna", ["n1", "n7"], [0, 3.0]),
    ]
    gates = [
        {"st": ix["mrt6-FAR"], "ref": "A", "name": "Gate A", "name_bn": "গেট এ", "lat": 23.7595,
         "lon": 90.3896, "side": "N", "near": [["Sample Park", "নমুনা পার্ক", "park", 60]],
         "stands": [ix["n1"]], "routes": [2, 3], "lift": True, "status": "reported"},
        {"st": ix["mrt6-FAR"], "ref": "B", "name": "Gate B", "name_bn": "গেট বি", "lat": 23.7566,
         "lon": 90.3904, "side": "S", "near": [], "stands": [], "routes": [], "lift": None,
         "status": "reported"},
    ]
    return {"fmt": 1, "city": "dhaka", "version": version, "built": "2026-11-09T00:00:00Z",
            "osm_timestamp": "2026-11-08T00:00:00Z", "attribution": CS.ATTRIBUTION,
            "bbox": [23.66, 90.30, 23.95, 90.52],
            "stops": {"cols": ["id", "name", "name_bn", "lat", "lon", "kind", "st", "code"], "rows": stops},
            "routes": routes, "gates": gates,
            "metro": {"line": {"name": "MRT Line 6"}, "service": {"hours_fri": "15:00-21:40"},
                      "recharge": {"text_en": "At every station"}},
            "counts": {"routes": len(routes), "stops": len(stops), "stations": 5, "coverage_pct": 12.5}}


def blob(net=None):
    return gzip.compress(json.dumps(net or make_net()).encode())


# ------------------------------------------------------------------ fares
class FareTests(SimpleTestCase):
    def test_metro_official_chart_and_rate(self):
        self.assertEqual(F.metro(20.1, "UTN", "MOT")["low"], 100)
        self.assertEqual(F.metro(11.73, "AGA", "UTN")["low"], 60)
        f = F.metro(1.2, "X", "Y")
        self.assertEqual((f["low"], f["basis"], f["label"]), (20, "rate", "official"))
        self.assertEqual(F.metro(30, "X", "Y")["low"], 100)
        self.assertEqual(F.metro(16.4, "UTN", "SHB")["low"], 80)
        self.assertEqual(F.metro(20.1, "UTN", "MOT")["card"], 90)       # 10% card discount
        self.assertTrue(F.metro(5, "A", "B")["checked"])

    def test_bus_official_range_and_minimum(self):
        f = F.bus(1.0)
        self.assertEqual((f["low"], f["high"], f["label"]), (10, 10, "official"))
        f = F.bus(10.0)
        self.assertEqual((f["low"], f["high"]), (25, 27))
        self.assertIn("brta", f["source_url"])

    def test_cng_meter_official_with_overcharge_note(self):
        self.assertEqual(F.cng_meter(2.0), 40)
        self.assertEqual(F.cng_meter(5.0), 76)
        self.assertEqual(F.cng_meter(5.0, wait_min=10), 96)
        f = F.cng(5.0, minutes=30)
        self.assertEqual((f["label"], f["meter"], f["low"]), ("official", 76, 76))
        self.assertGreater(f["high"], f["low"])
        self.assertTrue(f["overcharge_note"])
        self.assertEqual(F.BRTA_COMPLAINT["fallback"], "333")

    def test_estimates_are_ranges_never_one_number(self):
        for f in (F.rickshaw(2.0), F.leguna(3.0), F.ride("bike", 6, 25), F.ride("car", 6, 25)):
            self.assertEqual(f["label"], "estimate")
            self.assertLess(f["low"], f["high"])

    def test_reported_by_users_overrides_estimate(self):
        R = F.rates({"rickshaw": {"label": "reported", "per_km_low": 20, "per_km_high": 30,
                                  "min_low": 30, "min_high": 40, "checked": "2026-11-09"}})
        f = F.rickshaw(3.0, R)
        self.assertEqual((f["label"], f["low"], f["high"]), ("reported", 60, 90))


# ------------------------------------------------------------------ engine
class EngineTests(SimpleTestCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.nw = E.Network(make_net())

    def test_farmgate_to_motijheel_three_choices(self):
        ans = self.nw.plan(*FARMGATE, *MOTIJHEEL, minute=10 * 60 + 30)
        self.assertTrue(ans["ok"])
        o = ans["options"]
        for k in ("fastest", "cheapest", "fewest_changes", "safer_night"):
            self.assertIn(k, o)
        self.assertLessEqual(o["fastest"]["minutes"], o["cheapest"]["minutes"])
        self.assertLessEqual(o["cheapest"]["fare"]["high"], o["fastest"]["fare"]["high"])
        self.assertIn("bus", o["cheapest"]["modes"])
        self.assertEqual(o["cheapest"]["fare"]["label"], "official")
        self.assertEqual(o["fewest_changes"]["changes"], 0)
        self.assertLess(ans["ms"], 500)
        ride = [l for l in o["cheapest"]["legs"] if l["mode"] == "bus"][0]
        self.assertEqual(ride["route"], "Shatabdi")
        self.assertEqual(ride["board"]["id"], "n1")
        self.assertIn(ride["alight"]["id"], ("n4", "n5"))   # Paltan + short walk is cheaper
        self.assertEqual(ride["towards"]["name"], "Motijheel")
        self.assertEqual(ride["status"], "verified")
        self.assertTrue(ride["fare"]["checked"])
        self.assertEqual(o["cheapest"]["legs"][0]["mode"], "walk")
        self.assertGreater(o["cheapest"]["legs"][0]["meters"], 0)

    def test_metro_leg_direction_fare_and_exit_gate(self):
        ans = self.nw.plan(*UTTARA, *NORTH_OF_FARMGATE_GATE, minute=11 * 60)
        best = ans["options"]["fastest"]
        metro = [l for l in best["legs"] if l["mode"] == "metro"][0]
        self.assertEqual(metro["board"]["name"], "Uttara North")
        self.assertEqual(metro["alight"]["name"], "Farmgate")
        self.assertEqual(metro["towards"]["name"], "Motijheel")
        self.assertEqual(metro["fare"]["low"], 70)          # official chart UTN-FAR
        self.assertEqual(metro["exit_gate"]["ref"], "A")
        self.assertEqual(metro["exit_gate"]["side"], "N")

    def test_transfer_bus_to_leguna(self):
        ans = self.nw.plan(23.7330, 90.4170, 23.7785, 90.4050, minute=12 * 60)
        self.assertTrue(ans["ok"])
        modes = ans["options"]["fewest_changes"]["modes"]
        self.assertTrue(set(modes) & {"bus", "leguna", "metro"})

    def test_no_route_still_offers_cng_and_ride_share_with_labels(self):
        ans = self.nw.plan(23.70, 90.50, 23.66, 90.51, minute=12 * 60)
        self.assertFalse(ans["ok"])
        modes = {w["mode"]: w for w in ans["other_ways"]}
        self.assertEqual(modes["cng"]["fare"]["label"], "official")
        self.assertEqual(modes["ride_car"]["fare"]["label"], "estimate")
        self.assertLess(modes["ride_bike"]["fare"]["low"], modes["ride_bike"]["fare"]["high"])

    def test_metro_hours_warning_and_peak_slower(self):
        late = self.nw.plan(*UTTARA, *SHAHBAG, minute=22 * 60 + 30)
        self.assertIn("metro_hours", late["warnings"])
        a = self.nw.plan(*FARMGATE, *MOTIJHEEL, minute=9 * 60, modes=["bus"])
        b = self.nw.plan(*FARMGATE, *MOTIJHEEL, minute=13 * 60, modes=["bus"])
        self.assertGreater(a["options"]["fastest"]["minutes"], b["options"]["fastest"]["minutes"])

    def test_hidden_route_and_learned_route(self):
        nw = E.Network(make_net(), {"hide_routes": ["busA-a"], "add_routes": [
            {"id": "trip-x", "mode": "bus", "name": "", "st": "r", "stop_ids": ["n1", "n5"]}]})
        ans = nw.plan(*FARMGATE, *MOTIJHEEL, minute=13 * 60, modes=["bus"])
        ids = {l.get("route_id") for o in ans["options"].values() for l in o["legs"]}
        self.assertNotIn("busA-a", ids)
        self.assertIn("trip-x", ids)

    def test_station_guide(self):
        g = self.nw.station_guide("mrt6-FAR", *NORTH_OF_FARMGATE_GATE)
        self.assertEqual(len(g["gates"]), 2)
        self.assertEqual(g["which_gate"]["ref"], "A")
        self.assertIn("Shatabdi", g["gates"][0]["buses"])
        self.assertIn("Shatabdi", g["connecting_buses"])
        self.assertEqual([s["code"] for s in self.nw.stations()], ["UTN", "AGA", "FAR", "SHB", "MOT"])


# ------------------------------------------------------------------ API
class ApiBase(TestCase):
    def setUp(self):
        cache.clear()
        CS._NET.clear()
        CS._PKG.clear()
        CS._DIR.clear()
        dirs = gzip.compress(json.dumps({"items": [
            {"id": "t-1", "kind": "terminal", "name": "Sample Terminal", "lat": 23.78, "lon": 90.34,
             "status": "v", "sources": [{"s": "osm"}, {"s": "news"}]},
            {"id": "o-1", "kind": "office", "name": "Sample Passport Office", "lat": 23.77, "lon": 90.37,
             "papers_en": ["NID"], "status": "r", "sources": [{"s": "dip"}]}]}).encode())
        CS.import_city("dhaka", blob(), dirs, {"top50": {"pass": 1, "total": 1}})
        self.user = User.objects.create_user(name="U", phone="01799000101", password="x")
        self.user2 = User.objects.create_user(name="V", phone="01799000102", password="x")
        self.user3 = User.objects.create_user(name="W", phone="01799000103", password="x")
        self.c = APIClient()
        self.c.force_authenticate(self.user)

    def as_(self, u):
        c = APIClient()
        c.force_authenticate(u)
        return c


class PlanApiTests(ApiBase):
    def test_plan_with_fares_and_attribution(self):
        r = self.c.get("/api/v1/city/plan?from=%s,%s&to=%s,%s&at=10:30" % (FARMGATE + MOTIJHEEL))
        self.assertEqual(r.status_code, 200)
        d = r.json()
        self.assertTrue(d["ok"])
        self.assertEqual(d["city"], "dhaka")
        self.assertIn("OpenStreetMap", d["attribution"])
        self.assertIn("cheapest", d["options"])
        self.assertTrue(d["data_version"].startswith("20261109-test."))
        self.assertEqual(d["complaint"]["fallback"], "333")
        self.assertTrue(all(s["checked"] for s in d["fare_sources"]))

    def test_other_city_honest_no_data_with_google_maps(self):
        r = self.c.get("/api/v1/city/plan?from=24.8949,91.8687&to=24.90,91.88", HTTP_ACCEPT_LANGUAGE="en")
        d = r.json()
        self.assertFalse(d["ok"])
        self.assertEqual(d["reason"], "no_data")
        self.assertTrue(d["google_maps"].startswith("https://www.google.com/maps/dir/?api=1"))
        self.assertIn("travelmode=transit", d["google_maps"])
        self.assertIn("No route data", d["detail"])
        # Chattogram is a planned city but has no data imported yet
        w = self.c.get("/api/v1/city/where?lat=22.3569&lon=91.7832").json()
        self.assertEqual((w["city"], w["has_data"]), ("chattogram", False))
        w = self.c.get("/api/v1/city/where?lat=23.75&lon=90.39").json()
        self.assertTrue(w["has_data"])
        self.assertEqual(w["coverage_pct"], 12.5)

    def test_bad_input(self):
        self.assertEqual(self.c.get("/api/v1/city/plan?from=x&to=1,2").status_code, 400)
        self.assertEqual(self.c.get("/api/v1/city/where").status_code, 400)

    def test_offline_package_gzip_and_unchanged(self):
        r = self.c.get("/api/v1/city/package?city=dhaka")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r["Content-Encoding"], "gzip")
        doc = json.loads(gzip.decompress(r.content))
        v = doc["v"]
        self.assertEqual(len(doc["net"]["stops"]["rows"]), 13)
        self.assertIn("metro", doc["rates"])
        # the phone can plan offline from the package with the same engine
        nw = E.Network(doc["net"], doc["overrides"])
        self.assertTrue(nw.plan(*FARMGATE, *MOTIJHEEL, minute=600)["ok"])
        r = self.c.get("/api/v1/city/package?city=dhaka&v=" + v)
        self.assertEqual(r.json(), {"unchanged": True, "v": v})
        # an owner change bumps the version -> the phone refreshes
        CS.apply_patch("dhaka", {"action": "hide_stop", "id": "n4"})
        r = self.c.get("/api/v1/city/package?city=dhaka&v=" + v)
        self.assertEqual(r["Content-Encoding"], "gzip")
        self.assertNotEqual(r["X-City-Data-Version"], v)

    def test_stations_station_metro_search_route_dirs(self):
        st = self.c.get("/api/v1/city/stations").json()["stations"]
        self.assertEqual(st[0]["code"], "UTN")
        g = self.c.get("/api/v1/city/station/mrt6-FAR?lat=%s&lon=%s" % NORTH_OF_FARMGATE_GATE).json()
        self.assertEqual(g["which_gate"]["ref"], "A")
        self.assertEqual(g["recharge"]["text_en"], "At every station")
        self.assertEqual(self.c.get("/api/v1/city/station/n1").status_code, 404)
        m = self.c.get("/api/v1/city/metro").json()
        self.assertEqual((m["fare"]["min"], m["fare"]["max"]), (20, 100))
        s = self.c.get("/api/v1/city/search?q=motij").json()
        self.assertTrue(any(x["name"] == "Motijheel" for x in s["stops"]))
        s = self.c.get("/api/v1/city/search?q=shatabdi").json()
        self.assertEqual(s["routes"][0]["status"], "verified")
        r = self.c.get("/api/v1/city/route/busA-a").json()
        self.assertEqual([x["name"] for x in r["stops"]][-1], "Motijheel")
        n = self.c.get("/api/v1/city/stops/near?lat=23.7572&lon=90.3902").json()
        self.assertEqual(n["stops"][0]["id"], "n1")
        t = self.c.get("/api/v1/city/terminals").json()["items"]
        self.assertEqual((t[0]["name"], t[0]["status"]), ("Sample Terminal", "verified"))
        o = self.c.get("/api/v1/city/offices").json()["items"]
        self.assertEqual(o[0]["status"], "reported")


class WomenTests(ApiBase):
    def test_women_info_and_night(self):
        for u in (self.user, self.user2, self.user3):
            self.as_(u).post("/api/v1/city/night-rating", {"route_id": "busB-a", "stars": 4}, format="json")
        CS.apply_patch("dhaka", {"action": "edit_route", "id": "busA-a", "name": "Shatabdi"})
        d = self.c.get("/api/v1/city/women").json()
        self.assertEqual(d["metro_women_coach"]["status"], "verified")
        self.assertEqual(len(d["metro_women_coach"]["sources"]), 2)
        self.assertEqual(d["reserved_seats"]["status"], "reported")
        self.assertEqual(d["women_buses"], [])            # no confirmed public list yet
        self.assertEqual(d["night"], [{"route_id": "busB-a", "stars": 4.0, "count": 3}])
        self.assertFalse(self.c.get("/api/v1/city/route/busA-a").json()["women_only"])


class LiveReportTests(ApiBase):
    def test_merge_count_expiry_and_flags(self):
        r = self.c.post("/api/v1/city/reports", {"kind": "jam", "lat": 23.7577, "lon": 90.3897}, format="json")
        self.assertEqual(r.status_code, 201)
        rid = r.json()["id"]
        # same user again: counted once
        self.c.post("/api/v1/city/reports", {"kind": "jam", "lat": 23.7578, "lon": 90.3898}, format="json")
        r2 = self.as_(self.user2).post("/api/v1/city/reports",
                                       {"kind": "jam", "lat": 23.7580, "lon": 90.3899}, format="json")
        self.assertEqual((r2.json()["id"], r2.json()["count"]), (rid, 2))
        lst = self.c.get("/api/v1/city/reports?lat=23.7577&lon=90.3897").json()["reports"]
        self.assertEqual((len(lst), lst[0]["count"], lst[0]["minutes_ago"]), (1, 2, 0))
        # 60-minute expiry
        later = timezone.now() + timedelta(minutes=61)
        self.assertEqual(CS.live_list(23.7577, 90.3897, now=later), [])
        self.assertEqual(len(CS.live_list(23.7577, 90.3897, now=timezone.now() + timedelta(minutes=59))), 1)
        # moderation: 3 flags hide it
        for u in (self.user, self.user2, self.user3):
            self.as_(u).post("/api/v1/city/reports/%d/flag" % rid)
        self.assertTrue(CityLiveReport.objects.get(pk=rid).hidden)
        self.assertEqual(self.c.get("/api/v1/city/reports?lat=23.7577&lon=90.3897").json()["reports"], [])

    def test_kinds_and_rate_limit(self):
        self.assertEqual(self.c.post("/api/v1/city/reports", {"kind": "party", "lat": 23.75, "lon": 90.39},
                                     format="json").status_code, 400)
        for k in CS.LIVE_KINDS:
            self.assertEqual(self.c.post("/api/v1/city/reports", {"kind": k, "lat": 23.75, "lon": 90.39},
                                         format="json").status_code, 201)
        codes = [self.c.post("/api/v1/city/reports", {"kind": "jam", "lat": 23.70 + i * 0.01, "lon": 90.39},
                             format="json").status_code for i in range(20)]
        self.assertIn(429, codes)


class CorrectionTests(ApiBase):
    def test_one_tap_fix_owner_accepts_change_reaches_routing(self):
        r = self.c.post("/api/v1/city/correction", {"target": "stop", "target_id": "n4",
                                                    "kind": "closed", "text": "stop moved"}, format="json")
        self.assertEqual(r.status_code, 201)
        self.assertEqual(self.c.post("/api/v1/city/correction", {}, format="json").status_code, 400)
        c = CityCorrection.objects.get()
        v0 = CityDataset.objects.get(city="dhaka").ov_version
        self.assertEqual(CS.resolve_correction(c, "accept", {"action": "edit_stop", "id": "n4",
                                                             "name": "Paltan More"}), "")
        c.refresh_from_db()
        self.assertEqual(c.status, "accepted")
        self.assertGreater(CityDataset.objects.get(city="dhaka").ov_version, v0)
        nw = CS.network("dhaka")[0]
        self.assertEqual(nw.stops[nw.by_id["n4"]]["name"], "Paltan More")
        self.assertEqual(CS.apply_patch("dhaka", {"action": "nope"}), "invalid")
        CS.apply_patch("dhaka", {"action": "verify_route", "id": "busB-a"})
        nw = CS.network("dhaka")[0]
        self.assertEqual([r for r in nw.routes if r["id"] == "busB-a"][0]["st"], "v")

    def test_owner_gate_fact(self):
        self.assertEqual(CS.apply_patch("dhaka", {"action": "add_gate", "id": "mrt6-SHB", "ref": "1",
                                                  "lat": "23.7395", "lon": "90.3962", "side": "E"}), "")
        g = CS.station("dhaka", "mrt6-SHB")
        self.assertEqual(g["gates"][0]["status"], "verified")


class CrowdTests(ApiBase):
    def test_rickshaw_fares_become_reported_by_users(self):
        for i in range(8):
            self.c.post("/api/v1/city/fare-report", {"mode": "rickshaw", "km": 2.0 + i * 0.1, "paid": 60},
                        format="json")
        for i in range(4):
            self.as_(self.user2).post("/api/v1/city/fare-report", {"mode": "rickshaw", "km": 0.8, "paid": 30},
                                      format="json")
        self.assertEqual(self.c.post("/api/v1/city/fare-report", {"mode": "rickshaw", "km": 2, "paid": 99999},
                                     format="json").status_code, 400)
        CS.aggregate("dhaka")
        nw = CS.network("dhaka")[0]
        self.assertEqual(nw.rates["rickshaw"]["label"], "reported")
        self.assertIn("12 reports", nw.rates["rickshaw"]["source"])

    def test_night_ratings_feed_safer_at_night(self):
        for u in (self.user, self.user2, self.user3):
            r = self.as_(u).post("/api/v1/city/night-rating", {"route_id": "busA-a", "stars": 1}, format="json")
            self.assertEqual(r.status_code, 201)
        CS.aggregate("dhaka")
        nw = CS.network("dhaka")[0]
        self.assertEqual(nw.night["busA-a"], 1.0)
        ans = CS.plan(*FARMGATE, *MOTIJHEEL, at="22:00")
        self.assertNotIn("busA-a", [l.get("route_id") for l in ans["options"]["safer_night"]["legs"]])


def _trace(start_t=1762650000):
    """Made-up bus trace: stand at Farmgate, ride to Karwan Bazar, stand,
    ride to Shahbag, stand, then Motijheel — with private ends."""
    pts, t = [], start_t
    def go(a, b, secs, steps=6):
        nonlocal t
        for k in range(1, steps + 1):
            pts.append([t + secs * k // steps, a[0] + (b[0] - a[0]) * k / steps, a[1] + (b[1] - a[1]) * k / steps])
        t += secs
    def stand(p, secs=40):
        nonlocal t
        for k in range(0, secs + 1, 10):
            pts.append([t + k, p[0], p[1]])
        t += secs + 1
    home = (23.7620, 90.3860)
    pts.append([t, home[0], home[1]])
    t += 10
    go(home, (23.7572, 90.3902), 300)
    stand((23.7572, 90.3902))
    go((23.7572, 90.3902), (23.7510, 90.3930), 240)
    stand((23.7510, 90.3930))
    go((23.7510, 90.3930), (23.7385, 90.3955), 420)
    stand((23.7385, 90.3955))
    go((23.7385, 90.3955), (23.7332, 90.4175), 600)
    stand((23.7332, 90.4175))
    go((23.7332, 90.4175), (23.7300, 90.4230), 300)
    return pts


class TripLearningTests(ApiBase):
    def test_consent_required_trim_learn_confirm_purge(self):
        r = self.c.post("/api/v1/city/trips", {"mode": "bus", "points": _trace()}, format="json")
        self.assertEqual(r.status_code, 403)
        self.assertTrue(self.c.post("/api/v1/city/trips/consent", {"on": True}, format="json").json()["on"])
        for u in (self.user, self.user2, self.user3):
            CS.consent(u, True)
            r = self.as_(u).post("/api/v1/city/trips", {"mode": "bus", "points": _trace()}, format="json")
            self.assertEqual(r.status_code, 201, r.content)
        t = CityTrip.objects.first()
        self.assertNotIn([_trace()[0][1], _trace()[0][2]], [[p[1], p[2]] for p in t.points])   # home cut
        self.assertFalse(hasattr(t, "user"))                                            # no name link
        self.assertEqual(CS.learn_tick(), 3)
        self.assertTrue(all(x.points == [] for x in CityTrip.objects.all()))
        seg = CityLearned.objects.get(kind="segment", key="n1>n2")
        self.assertEqual((seg.status, len(seg.anons)), ("confirmed", 3))
        CS.learned_to_overrides("dhaka")
        nw = CS.network("dhaka")[0]
        busA = [r for r in nw.routes if r["id"] == "busA-a"][0]
        self.assertTrue(busA["learned_kmh"])
        CityTrip.objects.update(created_at=timezone.now() - timedelta(days=8))
        CS.learn_tick()
        self.assertEqual(CityTrip.objects.count(), 0)

    def test_new_route_discovered_stays_reported_until_confirmed(self):
        net = make_net("20261109-two")
        nw = E.Network(net)
        seq = ["n6", "n7", "n1", "n3"]           # no route visits these in order
        self.assertFalse(CS._covered(nw, seq))
        self.assertTrue(CS._covered(nw, ["n1", "n2", "n3"]))

    def test_short_or_outside_trips_rejected(self):
        CS.consent(self.user, True)
        r = self.c.post("/api/v1/city/trips", {"mode": "bus", "points": [[1, 23.75, 90.39]] * 3},
                        format="json")
        self.assertEqual(r.json()["reason"], "too_short")
        far = [[1000 + i * 10, 40.0 + i * 0.001, -74.0] for i in range(30)]
        self.assertEqual(self.c.post("/api/v1/city/trips", {"mode": "bus", "points": far},
                                     format="json").json()["reason"], "no_city")


class ImportTickTests(TestCase):
    def test_import_rejects_bad_files_and_tick_offline(self):
        with self.assertRaises(ValueError):
            CS.import_city("dhaka", blob(), sha="0" * 64)
        bad = make_net()
        bad["city"] = "chattogram"
        with self.assertRaises(ValueError):
            CS.import_city("dhaka", blob(bad))
        CS.import_city("dhaka", blob())
        small = make_net("v2")
        small["stops"]["rows"] = small["stops"]["rows"][:5]
        small["routes"] = small["routes"][:2]
        with self.assertRaises(ValueError):                 # a much smaller file is refused
            CS.import_city("dhaka", blob(small))
        out = CS.tick(force=True)
        self.assertIn("manifest_error", out)
        self.assertEqual(CS.tick(), "idle")

    def test_tick_imports_from_manifest(self):
        b = blob()
        import hashlib
        files = {"transit_dhaka.json.gz": {"sha256": hashlib.sha256(b).hexdigest()}}

        def fake(url, limit=0, timeout=0):
            if url.endswith("manifest.json"):
                return json.dumps({"files": files}).encode()
            if url.endswith("transit_dhaka.json.gz"):
                return b
            raise OSError("nope")
        with mock.patch.object(CS, "_fetch", side_effect=fake):
            self.assertIn("imported", CS.import_tick(force=True))
            self.assertEqual(CS.import_tick(force=True), "up_to_date")
        self.assertEqual(CityDataset.objects.get(city="dhaka").counts["stations"], 5)

    def test_command_runs(self):
        call_command("city_tick", "--quiet")
