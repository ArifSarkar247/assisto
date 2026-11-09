"""citydata2 (owner 9 Nov, round 2): metro exits for every station, second
public source -> Verified bus routes, OSM stops on the bus path (coverage),
realistic "Fastest" (no needless rickshaw), BRTC women-only routes used only
on request, honest 333 label, bus rate source. Pure-Python parts of the
GitHub Actions data build (deploy/transit) are tested here too.
All coordinates/names are made-up sample data around public landmarks."""
import copy
import importlib.util
import os

from django.test import SimpleTestCase

from core import city_service as CS
from core.citytransit import engine as E
from core.citytransit import fares as F
from core.tests_city import FARMGATE, MOTIJHEEL, ApiBase, make_net

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def _load(name):
    spec = importlib.util.spec_from_file_location(
        "cd2_" + name, os.path.join(ROOT, "deploy", "transit", name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


BT = _load("build_transit")
CP = _load("crawl_public")


class FastestTests(SimpleTestCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.nw = E.Network(make_net())

    def test_fastest_walks_a_normal_distance_instead_of_rickshaw(self):
        # ~1 km east of Farmgate station: a rickshaw saves a few minutes at
        # Tk 30+, a Dhaka commuter walks -> Fastest must not use the rickshaw
        ans = self.nw.plan(23.7580, 90.3998, *MOTIJHEEL, minute=10 * 60 + 30)
        f = ans["options"]["fastest"]
        self.assertNotIn("rickshaw", f["modes"])
        self.assertTrue(set(f["modes"]) & {"metro", "bus"})

    def test_rickshaw_kept_when_it_is_the_real_last_mile(self):
        # > 1.2 km from every stop: no walk access -> rickshaw to the stop
        ans = self.nw.plan(23.7580, 90.4100, *MOTIJHEEL, minute=10 * 60 + 30)
        self.assertTrue(ans["ok"])
        self.assertEqual(ans["options"]["fastest"]["modes"][0], "rickshaw")

    def test_no_rickshaw_leg_under_rick_min(self):
        self.assertGreaterEqual(E.RICK_MIN, 900)
        legs = self.nw._first_mile(23.7580, 90.3960, set(E.MODES) | {"rickshaw"})
        for i, _sec, _lo, _hi, leg in legs:
            if leg[0] == "rickshaw":
                s = self.nw.stops[i]
                self.assertGreaterEqual(E.hav(23.7580, 90.3960, s["lat"], s["lon"]), E.RICK_MIN)

    def test_metro_hours_follow_dmtcl_oct_2026(self):
        ok = self.nw.plan(23.8690, 90.3675, 23.7385, 90.3958, minute=6 * 60 + 40)
        self.assertNotIn("metro_hours", ok["warnings"])
        late = self.nw.plan(23.8690, 90.3675, 23.7385, 90.3958, minute=22 * 60)
        self.assertIn("metro_hours", late["warnings"])


def women_net():
    net = make_net("20261109-women")
    ix = {r[0]: i for i, r in enumerate(net["stops"]["rows"])}
    net["routes"].append({"id": "women-pink-a", "mode": "bus", "name": "BRTC women-only (pink) bus",
                          "name_bn": "", "ref": "", "op": "BRTC", "st": "v", "src": [{"s": "news"}],
                          "stops": [ix["n1"], ix["n5"]], "km": [0, 4.6], "women_only": True,
                          "hw": 2, "spd": 40.0})
    return net


class WomenOnlyRoutingTests(SimpleTestCase):
    def test_women_only_route_used_only_on_request(self):
        nw = E.Network(women_net())
        ids = lambda a: {l.get("route_id") for o in a["options"].values() for l in o["legs"]}
        a = nw.plan(*FARMGATE, *MOTIJHEEL, minute=13 * 60, modes=["bus"])
        self.assertNotIn("women-pink-a", ids(a))
        b = nw.plan(*FARMGATE, *MOTIJHEEL, minute=13 * 60, modes=["bus", "women"])
        self.assertIn("women-pink-a", ids(b))
        leg = [l for o in b["options"].values() for l in o["legs"] if l.get("route_id") == "women-pink-a"][0]
        self.assertTrue(leg["women_only"])


class WomenApiTests(ApiBase):
    def test_women_list_and_plan_mode(self):
        CS.import_city("dhaka", __import__("gzip").compress(
            __import__("json").dumps(women_net()).encode()), None, {})
        CS._NET.clear()
        d = self.c.get("/api/v1/city/women").json()
        self.assertEqual([b["route_id"] for b in d["women_buses"]], ["women-pink-a"])
        r = self.c.get("/api/v1/city/plan?from=%s,%s&to=%s,%s&at=13:00&modes=women" % (FARMGATE + MOTIJHEEL)).json()
        self.assertTrue(r["ok"])


class GateAndComplaintApiTests(ApiBase):
    def test_gate_fields_and_facilities(self):
        net = make_net("20261109-gates")
        net["gates"][0].update({"escalator": True, "basis": "osm", "src": "https://www.openstreetmap.org/node/1"})
        net["metro"]["facilities"] = {"lift": True, "escalator": True, "status": "verified",
                                      "sources": [{"url": "a"}, {"url": "b"}]}
        CS.import_city("dhaka", __import__("gzip").compress(__import__("json").dumps(net).encode()), None, {})
        CS._NET.clear()
        g = self.c.get("/api/v1/city/station/mrt6-FAR?lat=23.7605&lon=90.3893").json()
        a = g["gates"][0]
        self.assertEqual((a["lift"], a["escalator"], a["basis"]), (True, True, "osm"))
        self.assertEqual(g["which_gate"]["basis"], "osm")
        self.assertEqual(g["facilities"]["status"], "verified")
        self.assertEqual(self.c.get("/api/v1/city/metro").json()["facilities"]["lift"], True)

    def test_complaint_label_truthful(self):
        c = CS.complaint({})
        self.assertEqual((c["kind"], c["dial"]), ("national_helpline", "333"))
        self.assertNotIn("BRTA", c["label_en"])
        self.assertIn("333.gov.bd", c["source_url"])
        c = CS.complaint({"complaint": {"number": "16xxx", "verified": True}})
        self.assertEqual((c["kind"], c["dial"]), ("brta", "16xxx"))
        self.assertEqual(F.BRTA_COMPLAINT["number"], "")


# ------------------------------------------------------------ data build
def tiny_osm():
    stopn = {}

    def bs(nid, lat, lon, name):
        stopn[nid] = {"lat": lat, "lon": lon, "name": name, "name_bn": "", "name_en": "",
                      "t": {"highway": "bus_stop"}}
    bs(1, 23.7500, 90.3900, "Alpha")
    bs(2, 23.7600, 90.3900, "Beta")          # on the straight run Alpha -> Gamma
    bs(3, 23.7700, 90.3900, "Gamma")
    bs(4, 23.7600, 90.3990, "Far Side")      # ~900 m off the line
    bs(5, 23.7801, 90.3903, "Delta")
    bs(6, 23.7651, 90.3903, "")              # unnamed: never inserted
    return {"rels": {}, "nodes": {}, "ways": {}, "stopn": stopn,
            "poi": [(23.7652, 90.3912, "Sample Hospital", "", "hospital"),
                    (23.7651, 90.3911, "Bench", "", "bench"),
                    (23.7648, 90.3888, "Sample School", "", "school")],
            "entr": [], "elev": [], "places": [], "stations": [], "dirs": [], "steps": []}


class BuildTests(SimpleTestCase):
    def builder(self, public=None, seeds=None):
        b = BT.Builder("dhaka", tiny_osm(), public or {}, seeds or {})
        return b

    def test_densify_adds_named_osm_stop_on_path_only(self):
        b = self.builder()
        pts = [(23.7500, 90.3900, "Alpha", "n1", "", ""), (23.7700, 90.3900, "Gamma", "n3", "", "")]
        out = b.densify(pts)
        self.assertEqual([p[2] for p in out], ["Alpha", "Beta", "Gamma"])
        self.assertEqual(out[1][5], "dense")

    def test_second_source_marks_route_verified(self):
        pr1 = {"company": "Sample Paribahan", "company_bn": "", "stops": [("Alpha", ""), ("Gamma", ""), ("Delta", "")],
               "source": "site-one", "source_url": "https://one.example/r", "fetched": "2026-11-09"}
        pr2 = dict(pr1, company="Sample Paribahan Bus", source="site-two", source_url="https://two.example/")
        other = dict(pr1, company="Other Transport", stops=[("Delta", ""), ("Gamma", ""), ("Alpha", "")],
                     source="site-two", source_url="https://two.example/")
        b = self.builder({"bus_routes": [pr1], "bus_routes_2": [pr2, other]})
        b.public_routes()
        b.cross_match()
        net = b.network("v", "")
        st = {r["name"]: r["st"] for r in net["routes"]}
        self.assertEqual(st["Sample Paribahan"], "v")
        self.assertEqual(st["Other Transport"], "r")          # only one source
        self.assertEqual((b.second["agreed"], b.second["new"]), (1, 1))
        srcs = [s["s"] for r in net["routes"] if r["name"] == "Sample Paribahan" for s in r["src"]]
        self.assertIn("site-two", srcs)
        # the densified OSM stop stays Reported (OSM is its only source)
        rows = {r[1]: r[6] for r in net["stops"]["rows"]}
        self.assertEqual(rows["Beta"], "r")

    def test_women_seed_routes_flagged(self):
        seeds = {"women": {"routes": [{"company": "BRTC women-only (pink) bus: A - D", "company_bn": "",
                                        "stops": [["Alpha", ""], ["Gamma", ""], ["Delta", ""]],
                                        "source": "news", "source_url": "https://n.example/1",
                                        "fetched": "2026-11-09", "hw": 40,
                                        "sources": [{"s": "news", "url": "https://n.example/1", "date": "x"},
                                                    {"s": "news", "url": "https://n.example/2", "date": "x"}]}]}}
        b = self.builder({}, seeds)
        b.public_routes()
        net = b.network("v", "")
        w = [r for r in net["routes"] if r.get("women_only")]
        self.assertEqual(len(w), 2)
        self.assertTrue(all(r["st"] == "v" and r["hw"] == 40 for r in w))

    def test_side_rule_gates_both_sides_with_near(self):
        b = self.builder()
        a = b.stop("mrt6-AAA", "North St", "", 23.7800, 90.3900, "metro", "osm", "AAA")
        m = b.stop("mrt6-BBB", "Mid St", "", 23.7650, 90.3900, "metro", "osm", "BBB")
        z = b.stop("mrt6-CCC", "South St", "", 23.7500, 90.3900, "metro", "osm", "CCC")
        b.metro_idx = [a, m, z]
        b.gates()
        mine = [g for g in b.gate_list if g["st"] == m]
        self.assertEqual(sorted(g["side"] for g in mine), ["E", "W"])
        self.assertTrue(all(g["basis"] == "side_rule" and g["status"] == "reported" for g in mine))
        east = [g for g in mine if g["side"] == "E"][0]
        self.assertEqual(east["near"][0][0], "Sample Hospital")       # landmark, east side only
        self.assertNotIn("Bench", [n[0] for n in east["near"]])
        self.assertNotIn("Sample School", [n[0] for n in east["near"]])
        self.assertEqual(east["name"], "East side exit")
        self.assertEqual(len({g["st"] for g in b.gate_list}), 3)

    def test_mapped_entrance_wins_over_side_rule(self):
        osm = tiny_osm()
        osm["entr"] = [{"id": 9, "lat": 23.7651, "lon": 90.3905, "ref": "A", "name": "", "name_bn": "",
                        "wheelchair": "yes", "level": ""}]
        osm["elev"] = [(23.7651, 90.3906)]
        b = BT.Builder("dhaka", osm, {}, {})
        a = b.stop("mrt6-AAA", "N", "", 23.7800, 90.3900, "metro", "osm", "AAA")
        m = b.stop("mrt6-BBB", "M", "", 23.7650, 90.3900, "metro", "osm", "BBB")
        b.metro_idx = [a, m]
        b.gates()
        mine = sorted((g for g in b.gate_list if g["st"] == m), key=lambda g: g["basis"])
        self.assertEqual([g["basis"] for g in mine], ["osm", "side_rule"])
        self.assertEqual((mine[0]["ref"], mine[0]["lift"], mine[0]["wheelchair"]), ("A", True, "yes"))

    def test_is_entrance_styles(self):
        self.assertTrue(BT.is_entrance({"railway": "train_station_entrance"}))
        self.assertTrue(BT.is_entrance({"entrance": "main", "public_transport": "station"}))
        self.assertFalse(BT.is_entrance({"entrance": "yes"}))


class CrawlParseTests(SimpleTestCase):
    def test_route_list_page_parsed(self):
        page = """<html><body><h2>Achim Paribahan Bus Route (আছিম পরিবহন)</h2>
        <p>Gabtoli ⇄ Technical ⇄ Ansar Camp ⇄ Mirpur 1</p><p>Service: Semi sitting</p>
        <h2>Trust Transport (ট্রাস্ট ট্রান্সপোর্ট)</h2><p>Route: Mirpur 10 ⇄ Kafrul ⇄ Banani</p>
        <p>Short ⇄ Line</p></body></html>"""
        out = CP.parse_sequences(CP.html_lines(page), "s", "https://x.example/", "2026-11-09")
        self.assertEqual([r["company"] for r in out], ["Achim Paribahan", "Trust Transport"])
        self.assertEqual(out[0]["company_bn"], "আছিম পরিবহন")
        self.assertEqual([s[0] for s in out[0]["stops"]], ["Gabtoli", "Technical", "Ansar Camp", "Mirpur 1"])
        self.assertEqual(out[1]["stops"][0][0], "Mirpur 10")

    def test_hotline_finder_reports_numbers_only_near_words(self):
        page = "<div>হটলাইন: ১৬১০৭</div><p>Office phone 02-1234567</p><p>Call center 09610990998</p>"
        nums = [f["number"] for f in CP.find_hotlines(page)]
        self.assertIn("16107", nums)
        self.assertIn("09610990998", nums)
        self.assertNotIn("02-1234567", nums)


class SeedTests(SimpleTestCase):
    def test_metro_seed_times_and_facilities_have_dated_sources(self):
        import json
        d = json.load(open(os.path.join(ROOT, "deploy", "transit", "seed", "dhaka_metro.json")))
        svc = d["service"]
        self.assertEqual(svc["first_train"]["sat_thu"]["UTN"], "06:30")
        self.assertEqual(svc["last_train"]["sat_thu"]["MOT"], "22:30")
        self.assertEqual(svc["first_train"]["fri"]["UTN"], "15:00")
        self.assertTrue(all(s.get("date") for s in svc["sources"]))
        self.assertEqual(d["facilities"]["status"], "verified")
        self.assertGreaterEqual(len(d["facilities"]["sources"]), 2)
        w = json.load(open(os.path.join(ROOT, "deploy", "transit", "seed", "dhaka_women_buses.json")))
        self.assertGreaterEqual(len(w["routes"]), 8)
        self.assertTrue(all(r["sources"] and r["source_url"].startswith("https://") for r in w["routes"]))
