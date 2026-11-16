"""citycov3 (owner City Service order, parts C + D): the official BRTA /
Dhaka RTC bus fare chart joins the data build (route numbers, stops in
order, official km), confirms routes from the public route pages (2
independent sources -> Verified) or adds its own Reported routes, the top-50
measurement demands a labelled + dated fare on every paid leg, and the
coverage map lists where stops are still missing.
All names/coordinates are made-up sample data (tiny test map)."""
from django.test import SimpleTestCase

from core.tests_citydata2 import BT, tiny_osm

SRC = {"s": "BRTA / Dhaka RTC official bus fare chart (2022)", "url": "https://brta.example/chart",
       "date": "2022-08-31", "fetched": "2026-11-16"}


def chart(*routes):
    return {"brta_chart": {"source": SRC, "routes": [
        {"code": code, "code_bn": "", "name": "x", "name_bn": "", "stops": stops} for code, stops in routes]}}


ABG = [["Alpha", "", 0.0], ["Beta", "", 1.4], ["Gamma", "", 2.6], ["Delta", "", 4.0]]


class BrtaChartTests(SimpleTestCase):
    def builder(self, public=None, seeds=None):
        return BT.Builder("dhaka", tiny_osm(), public or {}, seeds or {})

    def test_chart_confirms_public_route_verified_with_number(self):
        pr = {"company": "Sample Paribahan", "company_bn": "", "source": "site-one",
              "source_url": "https://one.example/r", "fetched": "2026-11-09",
              "stops": [("Alpha", ""), ("Beta", ""), ("Gamma", ""), ("Delta", "")]}
        b = self.builder({"bus_routes": [pr]}, chart(("A-101", ABG)))
        b.public_routes()
        net = b.network("v", "")
        self.assertEqual(len(net["routes"]), 2)              # no duplicate route
        for r in net["routes"]:
            self.assertEqual((r["st"], r["ref"], r["brta"]), ("v", "A-101", "A-101"))
            self.assertIn(SRC["url"], [s["url"] for s in r["src"]])
        self.assertEqual(b.brta["confirmed_existing"], 1)
        # its stops now have two sources -> Verified
        rows = {r[1]: r[6] for r in net["stops"]["rows"]}
        self.assertEqual(rows["Alpha"], "v")

    def test_chart_only_route_reported_with_official_km(self):
        b = self.builder({}, chart(("A-200", ABG)))
        b.public_routes()
        net = b.network("v", "")
        a = [r for r in net["routes"] if r["id"].endswith("-a")][0]
        self.assertEqual((a["name"], a["st"], a["ref"], a["km_basis"]), ("BRTA A-200", "r", "A-200", "official"))
        self.assertEqual(a["km"][-1], 4.0)                    # official km, not the estimate
        self.assertEqual(b.brta["new_routes"], 1)

    def test_chart_cannot_confirm_itself_and_return_direction_is_duplicate(self):
        back = [["Delta", "", 0.0], ["Gamma", "", 1.4], ["Beta", "", 2.6], ["Alpha", "", 4.0]]
        b = self.builder({}, chart(("P-1", ABG), ("P-2", back)))
        b.public_routes()
        net = b.network("v", "")
        self.assertEqual(len(net["routes"]), 2)
        self.assertTrue(all(r["st"] == "r" for r in net["routes"]))
        self.assertEqual(b.brta.get("duplicate"), 1)

    def test_insane_official_km_falls_back_to_estimate(self):
        bad = [["Alpha", "", 0.0], ["Beta", "", 0.1], ["Gamma", "", 0.2], ["Delta", "", 0.3]]
        b = self.builder({}, chart(("A-300", bad)))
        b.public_routes()
        a = [r for r in b.network("v", "")["routes"] if r["id"].endswith("-a")][0]
        self.assertEqual(a["km_basis"], "estimate")
        self.assertGreater(a["km"][-1], 3.0)

    def test_unplaced_chart_route_is_a_gap(self):
        b = self.builder({}, chart(("A-400", [["Nowhere", "", 0], ["Nothing", "", 2], ["Nil", "", 3]])))
        b.public_routes()
        self.assertEqual(b.brta["unplaced"], 1)
        self.assertEqual(b.gaps["brta_route_unplaced"][0]["code"], "A-400")


class OfficialKmTests(SimpleTestCase):
    def test_dense_stops_interpolated_between_listed(self):
        pts = [(0, 0, "A", "a", "", ""), (0, 0, "x", "d", "", "dense"), (0, 0, "B", "b", "", "")]
        out = BT.official_km(pts, {"a": 0.0, "b": 3.0}, [0.0, 1.0, 2.0])
        self.assertEqual(out, [0.0, 1.5, 3.0])

    def test_without_first_stop_keeps_estimate(self):
        pts = [(0, 0, "A", "a", "", ""), (0, 0, "B", "b", "", "")]
        self.assertEqual(BT.official_km(pts, {"b": 3.0}, [0.0, 2.0]), [0.0, 2.0])


class SensibleTests(SimpleTestCase):
    def ans(self, fare_leg):
        leg = {"mode": "bus", "fare": fare_leg}
        opt = {"legs": [{"mode": "walk"}, leg], "fare": {"low": 10, "high": 20}, "walk_m": 300, "minutes": 30}
        return {"ok": True, "options": {"fastest": opt, "cheapest": opt}}

    def test_needs_label_and_date(self):
        good = {"label": "official", "checked": "2026-09-22", "high": 20, "low": 10}
        self.assertEqual(BT.sensible(self.ans(good), 5.0), (True, ""))
        ok, why = BT.sensible(self.ans(dict(good, checked="")), 5.0)
        self.assertFalse(ok)
        self.assertIn("label/date", why)
        ok, why = BT.sensible(self.ans(dict(good, label="guess")), 5.0)
        self.assertFalse(ok)

    def test_fare_too_high_fails(self):
        a = self.ans({"label": "estimate", "checked": "2026-09-22", "high": 900, "low": 10})
        a["options"]["fastest"]["fare"]["high"] = 900
        self.assertFalse(BT.sensible(a, 2.0)[0])


class TwoStopLineTests(SimpleTestCase):
    def seed(self, *stops):
        return {"leguna_brtc": {"routes": [{
            "company": "Leguna: sample", "company_bn": "", "op": "leguna", "ref": "", "mode": "leguna",
            "stops": [[s, ""] for s in stops],
            "sources": [{"s": "news", "url": "https://news.example/1", "date": "2026-01-01"}]}]}}

    def test_two_named_stops_make_a_reported_line(self):
        b = BT.Builder("dhaka", tiny_osm(), {}, self.seed("Alpha", "Gamma"))
        b.public_routes()
        net = b.network("v", "")
        legs = [r for r in net["routes"] if r["mode"] == "leguna"]
        self.assertEqual(len(legs), 2)
        self.assertTrue(all(r["st"] == "r" for r in legs))
        self.assertEqual(b.two_stop, 1)

    def test_weak_name_match_not_enough_for_two_stops(self):
        # a shop/hospital name (POI) is too weak to pin a 2-stop line
        b = BT.Builder("dhaka", tiny_osm(), {}, self.seed("Alpha", "Sample Hospital"))
        b.public_routes()
        self.assertEqual([r for r in b.network("v", "")["routes"] if r["mode"] == "leguna"], [])
