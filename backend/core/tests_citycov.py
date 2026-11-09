"""citycov (9 Nov): Dhaka coverage toward 70 % with honest methods.

* users' stops put into the routes that serve them (engine insert_stops);
* coverage: the SAME stop definition as the data build + a separate corridor
  measure (never mixed into the headline);
* field collection "Add a stop here" / "This bus stops here" / "Yes, it stops
  here": one tap, no names, Reported until 3 different people, rate-limited,
  owner can reject (gone for everyone);
* trip learning promotes a learned stop after 3 separate trips, into the
  route the trips were on (direction-aware);
* the phone's offline package carries the network as applied;
* Owner Admin -> City data -> Users' stops.
All coordinates/names are made-up sample data around public landmarks."""
import gzip
import json
from unittest import mock

from django.core.cache import cache

from core import city_service as CS
from core.citytransit import engine as E
from core.models import CityLearned, User
from core.tests_city import ApiBase, make_net
from web.tests_o2_owner_admin import OwnerBase

# between Karwan Bazar (n2) and Shahbag (n3) on the sample Shatabdi route
MID = (23.7448, 90.3942)


def _ids(nw, rid):
    r = [x for x in nw.routes if x["id"] == rid][0]
    return [nw.stops[i]["id"] for i in r["stops"]], r


class EngineTests(ApiBase):
    def test_insert_stop_between_the_right_pair_with_km(self):
        ov = {"add_stops": [{"id": "u-x", "lat": MID[0], "lon": MID[1], "st": "r"},
                            {"id": "u-far", "lat": 23.80, "lon": 90.45, "st": "r"}],
              "ins_stops": [{"route": "busA-a", "stop": "u-x"}, {"route": "busA-a", "stop": "u-far"}]}
        nw = E.Network(make_net(), ov)
        ids, r = _ids(nw, "busA-a")
        self.assertEqual(ids, ["n1", "n2", "u-x", "n3", "n4", "n5"])       # far one left out
        k = ids.index("u-x")
        self.assertTrue(r["km"][k - 1] < r["km"][k] < r["km"][k + 1])
        self.assertEqual(len(r["km"]), len(r["stops"]))
        self.assertEqual(nw.stops[nw.by_id["u-x"]]["st"], "r")
        ans = nw.plan(*MID, 23.7332, 90.4175, minute=11 * 60, modes=["bus"])
        boards = {l["board"]["id"] for o in ans["options"].values() for l in o["legs"] if l.get("board")}
        self.assertIn("u-x", boards)

    def test_coverage_stop_measure_and_separate_corridor(self):
        core = [23.70, 90.37, 23.78, 90.43]
        nw = E.Network(make_net())
        c = nw.coverage(core)
        self.assertEqual(c["cells"], 9 * 6)       # round(0.08 / 0.009) x round(0.06 / 0.0098)
        self.assertGreater(c["hit_stops"], 0)
        self.assertGreaterEqual(c["corridor_pct"], c["stops_pct"])         # corridor never lower
        self.assertEqual(c["cells"] - c["hit_stops"], len(c["empty"]))
        # a cell set limits the count (built-up measure)
        one = nw.coverage(core, {(5, 2)})
        self.assertEqual(one["cells"], 1)
        # long straight jumps (> 2.5 km) are not a corridor
        self.assertEqual(E.corridor_points([(23.70, 90.37, 23.78, 90.43)]), [])
        self.assertGreater(len(E.corridor_points([(23.7510, 90.3930, 23.7385, 90.3955)])), 10)


class FieldStopTests(ApiBase):
    def setUp(self):
        super().setUp()
        self.user4 = User.objects.create_user(name="X", phone="01799000104", password="x")

    def _add(self, u, lat=MID[0], lon=MID[1], **kw):
        return self.as_(u).post("/api/v1/city/field-stops", dict({"lat": lat, "lon": lon}, **kw), format="json")

    def test_three_people_confirm_then_stop_is_in_both_directions(self):
        r = self._add(self.user, route_id="busA-a")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual((r.json()["status"], r.json()["people"], r.json()["need"]), ("reported", 1, 3))
        self.assertEqual(self._add(self.user, route_id="busA-a").json()["status"], "already")
        g = self.as_(self.user2).get("/api/v1/city/field-stops?lat=%s&lon=%s" % MID).json()
        item = [i for i in g["items"] if i["route_id"] == "busA-a"][0]
        self.assertEqual((item["people"], item["mine"], item["confirmed"]), (1, False, False))
        self.assertEqual([x["name"] for x in g["routes"]], ["Shatabdi"])   # passes close; one per route
        # not in the network yet
        self.assertFalse(any(s["id"].startswith("u-") for s in CS.network("dhaka")[0].stops))
        self.assertEqual(self.as_(self.user2).post("/api/v1/city/field-stops",
                                                   {"lat": MID[0], "lon": MID[1], "id": item["id"]},
                                                   format="json").json()["status"], "reported")
        r = self._add(self.user3, route_id="busA-a")                  # same spot, 3rd person
        self.assertEqual(r.json()["status"], "confirmed")
        nw = CS.network("dhaka")[0]
        ua, _ = _ids(nw, "busA-a")
        ub, _ = _ids(nw, "busA-b")
        uid = [x for x in ua if x.startswith("u-")]
        self.assertEqual(len(uid), 1)
        self.assertIn(uid[0], ub)                                     # sibling direction too
        s = nw.stops[nw.by_id[uid[0]]]
        self.assertEqual(s["st"], "r")                                # Reported by users
        self.assertTrue(s["name"] and s["name_bn"])
        # no names anywhere in what is stored
        row = CityLearned.objects.get(kind="field")
        dump = json.dumps([row.key, row.data, row.anons])
        for u in (self.user, self.user2, self.user3):
            self.assertNotIn(u.phone, dump)
            self.assertNotIn('"%s"' % u.pk, dump)
        # the phone's offline package carries the inserted stop
        _tok, gz = CS.package("dhaka")
        doc = json.loads(gzip.decompress(gz))
        rows = doc["net"]["stops"]["rows"]
        rr = [x for x in doc["net"]["routes"] if x["id"] == "busA-a"][0]
        self.assertIn(uid[0], [rows[i][0] for i in rr["stops"]])
        self.assertEqual(len(rr["km"]), len(rr["stops"]))
        self.assertNotIn("ins_stops", doc["overrides"])          # applied once, not twice
        again = E.Network(doc["net"], doc["overrides"])
        self.assertEqual(_ids(again, "busA-a")[0], ua)
        # live coverage counts users' stops
        cov = CS.live_coverage("dhaka")
        self.assertEqual(cov["user_stops"], 1)
        self.assertGreaterEqual(cov["all"]["corridor_pct"], cov["all"]["stops_pct"])

    def test_add_stop_here_without_bus_attaches_to_passing_routes(self):
        for u in (self.user, self.user2, self.user3):
            self.assertIn(self._add(u).status_code, (200, 201))
        nw = CS.network("dhaka")[0]
        ua, _ = _ids(nw, "busA-a")
        self.assertTrue(any(x.startswith("u-") for x in ua))
        ub, _ = _ids(nw, "busB-a")                                     # far route untouched
        self.assertFalse(any(x.startswith("u-") for x in ub))

    def test_known_stop_bad_route_far_confirm_and_limit(self):
        r = self._add(self.user, 23.7572, 90.3902)                    # Farmgate stop exists
        self.assertEqual(r.json()["status"], "known")
        r = self._add(self.user, 23.7572, 90.3902, route_id="busA-a")  # and that bus serves it
        self.assertEqual(r.json()["status"], "known")
        r = self._add(self.user, route_id="nope")
        self.assertEqual(r.status_code, 404)
        r = self._add(self.user, route_id="busA-a")
        far = self.as_(self.user2).post("/api/v1/city/field-stops",
                                        {"lat": 23.80, "lon": 90.41, "id": r.json()["id"]}, format="json")
        self.assertEqual((far.status_code, far.json()["reason"]), (400, "far"))
        out = self._add(self.user, 40.7, -74.0)
        self.assertEqual(out.status_code, 400)
        cache.clear()
        with mock.patch.object(CS, "FIELD_PER_DAY", 1):
            self.assertEqual(self._add(self.user4, 23.7460, 90.3940, route_id="busA-a").status_code, 201)
            self.assertEqual(self._add(self.user4, 23.7430, 90.3946, route_id="busA-a").status_code, 429)

    def test_owner_reject_removes_stop_for_everyone(self):
        for u in (self.user, self.user2, self.user3):
            self._add(u, route_id="busA-a")
        self.assertTrue(any(x.startswith("u-") for x in _ids(CS.network("dhaka")[0], "busA-a")[0]))
        CityLearned.objects.filter(kind="field").update(status="rejected")
        CS.learned_to_overrides("dhaka")
        self.assertFalse(any(x.startswith("u-") for x in _ids(CS.network("dhaka")[0], "busA-a")[0]))
        self.assertEqual(self._add(self.user4, route_id="busA-a").json()["status"], "rejected")


def _trace_via_mid(start_t):
    """Made-up bus trace: Farmgate -> Karwan Bazar -> (a stop not on the map)
    -> Shahbag -> Motijheel, standing ~40 s at each, with private ends."""
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
    path = [(23.7572, 90.3902), (23.7510, 90.3930), MID, (23.7385, 90.3955), (23.7340, 90.4120),
            (23.7332, 90.4175)]
    pts.append([t, home[0], home[1]])
    t += 10
    go(home, path[0], 300)
    for a, b in zip(path, path[1:]):
        stand(a)
        go(a, b, 240)
    stand(path[-1])
    go(path[-1], (23.7290, 90.4250), 300)
    return pts


class TripPromoteTests(ApiBase):
    def test_learned_stop_promoted_after_three_trips_into_that_route(self):
        CS.consent(self.user, True)
        for k in range(2):
            r = self.c.post("/api/v1/city/trips", {"mode": "bus", "points": _trace_via_mid(1762650000 + k * 86400)},
                            format="json")
            self.assertEqual(r.status_code, 201, r.content)
        CS.learn_tick()
        CS.learned_to_overrides("dhaka")
        self.assertFalse(any(x.startswith("u-") for x in _ids(CS.network("dhaka")[0], "busA-a")[0]))
        learned = CityLearned.objects.get(kind="stop")
        self.assertEqual(len(learned.data["tids"]), 2)
        self.assertIn("n2>n3", learned.data["nb"])
        self.c.post("/api/v1/city/trips", {"mode": "bus", "points": _trace_via_mid(1762650000 + 2 * 86400)},
                    format="json")
        CS.learn_tick()
        CS.learned_to_overrides("dhaka")
        nw = CS.network("dhaka")[0]
        ua, _ = _ids(nw, "busA-a")
        ub, _ = _ids(nw, "busA-b")
        self.assertTrue(any(x.startswith("u-") for x in ua))       # the direction the trips rode
        self.assertFalse(any(x.startswith("u-") for x in ub))      # not the other one
        CityLearned.objects.filter(kind="stop").update(status="rejected")
        CS.learned_to_overrides("dhaka")
        self.assertFalse(any(x.startswith("u-") for x in _ids(CS.network("dhaka")[0], "busA-a")[0]))


class OwnerUserStopsTests(OwnerBase):
    def setUp(self):
        super().setUp()
        from core.tests_city import blob
        CS._NET.clear()
        CS._PKG.clear()
        CS.import_city("dhaka", blob(), b"", {"built_cells": [[5, 6], [6, 6]]})
        self.u = User.objects.create_user(name="R", phone="01788000181", password="x")
        self.ready()

    def test_users_stops_tab_accept_and_coverage_line(self):
        cache.clear()
        obj, err = CS.field_stop(self.u, MID[0], MID[1], "busA-a")
        self.assertEqual(err, "")
        for lang, word in (("en", "Tap report"), ("bn", "যাত্রীদের স্টপ")):
            r = self.c.get("/owner/city?tab=stops&lang=%s" % lang)
            self.assertEqual(r.status_code, 200)
            self.assertContains(r, word)
        r = self.c.get("/owner/city?tab=stops&lang=en")
        self.assertContains(r, "Shatabdi")
        self.assertContains(r, "openstreetmap.org/?mlat=")
        r = self.post("/owner/city/learned/%d" % obj.pk,
                      {"action": "confirm", "back": "/owner/city?tab=stops&city=dhaka"})
        self.assertIn("tab=stops", r["Location"])
        self.assertTrue(any(x.startswith("u-") for x in _ids(CS.network("dhaka")[0], "busA-a")[0]))
        r = self.c.get("/owner/city?tab=data&lang=en")
        self.assertContains(r, "Coverage now (with users")
        self.assertContains(r, "separate measure")
