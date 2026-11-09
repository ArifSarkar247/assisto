"""sjp0 (owner P0 9 Nov 19:40): the owner's phone showed "Today's place-search
limit is reached" and a 9/120 counter after almost no searches.

Root cause: safe_plans.paid_maps_allowed() refused every Google call for a
Free-plan account (paid_maps cap 0) -> state "plan_cap"; maps_cost.allow()
counted EVERY keystroke as one call; the V1 app shows any non-ok state as
"limit reached". Rules proven here:
  * with every cap used up (user, plan, global) suggestions still come for
    Gaibandha, গাইবান্ধা, Savar and Badda — from our own BD list;
  * no maps answer ever carries a limit / off state;
  * one search session of 9 keystrokes counts ONE call (and one plan note);
  * 'bd:' / 'saved:' ids resolve in /maps/place with zero Google cost, so old
    V1 apps (Place Details on every pick) work too.
"""
import json
from unittest import mock

from core import maps_cost as MC
from core.models import MapsUsage, SavedPlace
from core.tests_mapscost import MapsBase, V

LIMIT_STATES = ("user_cap", "plan_cap", "global_cap", "off", "failed", "bad_session", "capped")
QUERIES = ("Gaibandha", "গাইবান্ধা", "Savar", "Badda")


class NeverALimitTests(MapsBase):
    def exhaust_everything(self):
        for api in MC.APIS:
            self.limits(api, user_day=0, global_day=0)
        p = mock.patch.object(MC, "_plan_allowed", lambda u: False)
        p.start()
        self.addCleanup(p.stop)

    def assert_no_limit(self, body):
        st = body.get("state")
        self.assertNotIn(st, LIMIT_STATES, body)
        txt = json.dumps(body)
        for w in LIMIT_STATES[:3]:
            self.assertNotIn(w, txt)

    def test_every_cap_used_up_still_suggests(self):
        self.exhaust_everything()
        for path in ("maps/autocomplete", "maps/search"):
            for q in QUERIES:
                r = self.c1.get("%s/%s" % (V, path), {"q": q, "session": "owner-sess-0001"}).json()
                self.assert_no_limit(r)
                self.assertEqual(r["state"], "ok", (path, q, r))
                self.assertTrue(r["results"], (path, q))
                top = r["results"][0]
                # V1-client compatible rows: id + name + secondary (+ coordinates)
                for k in ("place_id", "name", "secondary", "lat", "lng"):
                    self.assertIn(k, top, (path, q))
        self.assertEqual(self.rec.calls, [])          # nothing paid

    def test_every_cap_used_up_with_key_off_too(self):
        self.exhaust_everything()
        with mock.patch.object(MC, "server_key", lambda: ""):
            for q in QUERIES:
                r = self.c1.get("%s/maps/autocomplete" % V, {"q": q, "session": "x"}).json()
                self.assert_no_limit(r)
                self.assertEqual(r["state"], "ok", q)

    def test_no_maps_answer_carries_a_limit_state(self):
        self.exhaust_everything()
        bodies = [
            self.c1.get("%s/maps/reverse?lat=23.7&lng=90.4" % V).json(),
            self.c1.get("%s/maps/eta?olat=23.7&olng=90.4&dlat=23.8&dlng=90.41" % V).json(),
            self.c1.get("%s/maps/place?id=ChIJabc123&session=owner-sess-0002" % V).json(),
            self.c1.get("%s/maps/autocomplete?q=Zzqx&session=owner-sess-0002" % V).json(),
            self.c1.get("%s/maps/search?q=Zzqx&session=owner-sess-0002" % V).json(),
            self.c1.get("%s/journey/geocode?q=Gaibandha" % V).json(),
            self.c1.get("%s/journey/geocode?q=Zzqx" % V).json(),
        ]
        for b in bodies:
            self.assert_no_limit(b)

    def test_bd_and_saved_ids_resolve_for_free(self):
        r = self.c1.get("%s/maps/autocomplete" % V, {"q": "Gaibandha", "session": "owner-sess-0003"}).json()
        pid = r["results"][0]["place_id"]
        self.assertTrue(pid.startswith("bd:"), pid)
        d = self.c1.get("%s/maps/place" % V, {"id": pid, "session": "owner-sess-0003"}).json()
        self.assertEqual(d["state"], "ok")
        self.assertAlmostEqual(d["lat"], 25.3, delta=0.4)
        p = SavedPlace.objects.create(user=self.u1, label="Office", name="Office Savar",
                                      lat=23.85, lng=90.26)
        r = self.c1.get("%s/maps/search" % V, {"q": "Savar", "session": "owner-sess-0004"}).json()
        self.assertEqual(r["results"][0]["place_id"], "saved:%d" % p.id)   # mine first
        d = self.c1.get("%s/maps/place" % V, {"id": "saved:%d" % p.id}).json()
        self.assertEqual((d["state"], d["lat"], d["lng"]), ("ok", 23.85, 90.26))
        # another user's saved id never resolves
        self.assertEqual(self.c2.get("%s/maps/place" % V, {"id": "saved:%d" % p.id}).json()["state"],
                         "none")
        # resolving our own ids never pays a Place Details
        self.assertFalse(any("/v1/places/" in c["url"] for c in self.rec.calls))


@mock.patch("core.bd_places.search", lambda *a, **k: [])      # force the Google leg
class OneSessionCountsOnceTests(MapsBase):
    def test_nine_keystrokes_count_one(self):
        notes = []
        word = "Bashundhar"                     # 9 keystrokes from the 2nd letter
        s = "owner-sess-0100"
        with mock.patch.object(MC, "_plan_note", lambda u: notes.append(u.id)):
            for n in range(2, len(word) + 1):
                r = self.c1.get("%s/maps/autocomplete" % V, {"q": word[:n], "session": s}).json()
                self.assertEqual(r["state"], "ok")
            d = self.c1.get("%s/maps/place" % V, {"id": "ChIJabc123", "session": s}).json()
        self.assertEqual(d["state"], "ok")
        self.assertEqual(len(self.rec.calls), 10)      # Google did answer every key
        row = MapsUsage.objects.get(api="autocomplete", user_id=self.u1.id)
        self.assertEqual((row.count, row.capped), (1, 0))
        self.assertEqual(notes, [self.u1.id])          # one plan note per search
        # a NEW search is a new session -> counts one more
        self.c1.get("%s/maps/autocomplete" % V, {"q": "Gulshan", "session": "owner-sess-0101"})
        row.refresh_from_db()
        self.assertEqual(row.count, 2)

    def test_user_cap_counts_sessions_not_keys(self):
        self.limits("autocomplete", user_day=2, global_day=100)
        for i in range(2):
            for n in range(2, 7):
                self.c1.get("%s/maps/autocomplete" % V, {"q": "Bashundhara"[:n], "session": "sess-ok-%04d" % i})
        row = MapsUsage.objects.get(api="autocomplete", user_id=self.u1.id)
        self.assertEqual(row.count, 2)                 # 10 keys, 2 searches
        for n in range(2, 7):
            r = self.c1.get("%s/maps/autocomplete" % V, {"q": "Bashundhara"[:n], "session": "sess-cap-0001"}).json()
            self.assertNotIn(r["state"], LIMIT_STATES)
        row.refresh_from_db()
        self.assertEqual(row.capped, 1)                # a refused search counts once too
