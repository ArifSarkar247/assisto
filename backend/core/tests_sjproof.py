"""sjproof — Safe Journey V2 PROOF (owner order 9 Nov 11:15, §PROOF + MEASURED
TARGETS). The emulator e2e (app/integration_test/flows/sj_proof_flow.dart)
drives the phone; these tests pin what it found and measure the targets
on big batches. All places and people are made up.

  * bug found by the e2e: an impossible early "I've arrived" TAP with a PIN
    set never told the watchers ("Unusually fast arrival, PIN asked") —
    only the auto-arrival path did. Now both do; the trip stays live;
  * ZERO impossible "Arrived": 300 random manual taps (far away / too early /
    no fix / stale fix / every mode) through the real /arrived endpoint —
    a plain "arrived" only when the phone is near AND the time is possible;
  * the same batch with a PIN set: every impossible tap asks the PIN, the
    journey stays active.
"""
import random
from datetime import timedelta

from django.utils import timezone

from core import journey_watch as JW
from core.logic import journey_arrival as JA
from core.models import Journey, JourneyEvent
from core.tests_sjduring import D, O, Sim, north

V = "/api/v1"
MODES = ("walk", "cng", "local_bus", "bike", "long_bus", "car", "train", "")


class ManualTooEarlyPinTests(Sim):
    def setUp(self):
        super().setUp()
        r = self.ca.post("%s/journey/duress-pin" % V, {"pin": "2468", "duress_pin": "1357"},
                         format="json")
        self.assertEqual(r.status_code, 200, r.content)

    def test_owner_bug_badda_to_gazipur_tap_after_5_min_watchers_see_fast_pin(self):
        j = self.mkj(start=timezone.now() - timedelta(minutes=5))
        here = north(D, -40)
        r = self.ca.post("%s/journey/%d/arrived" % (V, j.id),
                         {"lat": here[0], "lng": here[1], "acc": 12}, format="json")
        self.assertEqual(r.status_code, 400, r.content)
        self.assertEqual((r.json()["pin"], r.json()["reason"]), ("required", "too_early"))
        j = Journey.objects.get(pk=j.pk)
        self.assertEqual(j.status, "active")                       # never accepted
        self.assertEqual(j.during["pin_wait"]["why"], ["too_early"])
        ev = JourneyEvent.objects.filter(journey=j, kind="fast_pin")
        self.assertEqual(ev.count(), 1)
        self.assertEqual(ev[0].payload["level"], "amber")
        pb = [c for c in self.spy.to(self.b) if c["data"].get("event") == "fast_pin"]
        self.assertEqual(len(pb), 1)                               # the family is told
        self.assertFalse([c for c in self.spy.to(self.a)
                          if c["data"].get("event") == "arrive_pin"])  # no extra push
        card = self.cb.get("%s/journey/watch-board" % V).json()["active"][0]
        self.assertIn("fast_pin", card["badges"])
        # a second tap: still one event, still live
        self.ca.post("%s/journey/%d/arrived" % (V, j.id),
                     {"lat": here[0], "lng": here[1], "acc": 12}, format="json")
        self.assertEqual(JourneyEvent.objects.filter(journey=j, kind="fast_pin").count(), 1)
        # the safe PIN finishes it: "Confirmed with PIN" AND the amber badge stay
        r = self.ca.post("%s/journey/%d/arrived" % (V, j.id),
                         {"lat": here[0], "lng": here[1], "acc": 12, "pin": "2468"},
                         format="json")
        self.assertEqual(r.json()["arrival"], "confirmed_pin")
        fin = self.cb.get("%s/journey/watch-board" % V).json()["finished"][0]
        self.assertEqual(set(fin["badges"]), {"fast_pin", "pin_ok"})

    def test_danger_pin_after_too_early_tap_is_silent_red(self):
        j = self.mkj(start=timezone.now() - timedelta(minutes=5))
        here = north(D, -40)
        self.ca.post("%s/journey/%d/arrived" % (V, j.id),
                     {"lat": here[0], "lng": here[1], "acc": 12}, format="json")
        self.spy.calls.clear()
        r = self.ca.post("%s/journey/%d/arrived" % (V, j.id),
                         {"lat": here[0], "lng": here[1], "acc": 12, "pin": "1357"},
                         format="json")
        # bug found by the e2e: the danger PIN in the "I've arrived" PIN box
        # stopped the phone's location and recorded nothing. Now = the PIN
        # banner: Arrived on this screen, live + red + audio for the watchers
        self.assertEqual(r.json(), {"ok": True, "status": "arrived", "k": 1})
        self.assertTrue(self.spy.sos and self.spy.sos[-1]["silent"])
        j = Journey.objects.get(pk=j.pk)
        self.assertEqual(j.status, "active")                       # live location goes on
        self.assertTrue(j.during["cover"])
        self.assertNotIn("pin_wait", j.during)
        self.assertEqual(self.ca.get("%s/journey/active" % V).json(), {})   # looks finished
        pb = [c for c in self.spy.to(self.b) if c["data"].get("event") == "danger_pin"]
        self.assertEqual(pb[0]["data"]["level"], "red")
        self.assertEqual([c for c in self.spy.to(self.a)
                          if c["data"].get("event") in ("danger_pin", "fast_pin")], [])
        card = self.cb.get("%s/journey/watch-board" % V).json()["active"][0]
        self.assertEqual(card["level"], "red")
        self.assertIsNotNone(card["lat"])
        # the 30 s clip reaches the watcher
        r = self.ca.post("%s/journey/%d/danger-audio" % (V, j.id),
                         {"audio_b64": "AAAAGGZ0eXBNNEEgZmFrZS1hYWM="}, format="json")
        self.assertEqual(r.json(), {"ok": True})
        self.assertEqual(self.cb.get("%s/journey/%d/danger-audio" % (V, j.id)).status_code, 200)

    def test_far_tap_with_pin_asks_pin_but_is_not_a_fast_arrival(self):
        j = self.mkj(start=timezone.now() - timedelta(minutes=90))
        here = north(O, 500)                                       # still at the start
        r = self.ca.post("%s/journey/%d/arrived" % (V, j.id),
                         {"lat": here[0], "lng": here[1], "acc": 12}, format="json")
        self.assertEqual((r.json()["pin"], r.json()["reason"]), ("required", "far"))
        self.assertFalse(JourneyEvent.objects.filter(journey=j, kind="fast_pin").exists())


class ImpossibleArrivedBatchTests(Sim):
    """MEASURED TARGET: zero impossible "Arrived" (owner V2)."""
    N = 300

    def taps(self, seed):
        rnd = random.Random(seed)
        for i in range(self.N):
            mode = MODES[i % len(MODES)]
            elapsed = rnd.choice((1, 3, 5, 8, 12, 20, 35, 60, 120)) + rnd.random()
            where = rnd.choice(("start", "middle", "near", "at", "none", "stale", "rough"))
            yield i, mode, elapsed, where, rnd

    def physics_ok(self, mode, elapsed, here):
        """Independent physics: inside the 1 km ring AND not faster than the
        mode's top straight-line speed (generous: real trips are slower)."""
        if here is None:
            return False
        if JA.haversine_m(here, D) > JA.NEAR_M:
            return False
        km = max(0.0, JA.haversine_m(O, D) - JA.NEAR_M) / 1000.0
        return elapsed / 60.0 >= km / JA.TOP_KMH.get(mode, JA.DEFAULT_KMH)

    def run_batch(self, with_pin):
        res = {"taps": 0, "plain_arrived": 0, "impossible_arrived": 0, "pin_asked": 0,
               "unusual": 0, "impossible": 0, "impossible_left_active_or_unusual": 0}
        if with_pin:
            self.ca.post("%s/journey/duress-pin" % V, {"pin": "2468", "duress_pin": "1357"},
                         format="json")
        for i, mode, elapsed, where, rnd in self.taps(11 if with_pin else 7):
            j = self.mkj(start=timezone.now() - timedelta(minutes=elapsed), mode=mode,
                         member=self.ab)
            body, here = {}, None
            if where in ("start", "middle", "near", "at", "rough"):
                m = {"start": rnd.uniform(0, 800), "middle": rnd.uniform(4000, 16000),
                     "near": rnd.uniform(19050, 19900), "at": rnd.uniform(19900, 20000),
                     "rough": rnd.uniform(19900, 20000)}[where]
                here = north(O, m)
                body = {"lat": here[0], "lng": here[1],
                        "acc": 900 if where == "rough" else rnd.choice((5, 15, 40))}
                if where == "rough":
                    here = None                      # a 900 m fix says nothing
            elif where == "stale":
                p = north(D, -20)
                j.last_location = JW.location_row(j.last_location, p[0], p[1],
                                                  timezone.now() - timedelta(minutes=40), 70, "app")
                j.save(update_fields=["last_location"])
            r = self.ca.post("%s/journey/%d/arrived" % (V, j.id), body, format="json")
            res["taps"] += 1
            out = r.json()
            possible = self.physics_ok(mode, elapsed, here)
            res["impossible"] += int(not possible)
            j = Journey.objects.get(pk=j.pk)
            plain = (j.status == "arrived" and out.get("arrival") is None
                     and r.status_code == 200)
            res["plain_arrived"] += int(plain)
            res["pin_asked"] += int(out.get("pin") == "required")
            res["unusual"] += int(out.get("arrival") == "unusual")
            if plain and not possible:
                res["impossible_arrived"] += 1
            if not possible and (j.status == "active" or out.get("arrival") == "unusual"):
                res["impossible_left_active_or_unusual"] += 1
            self.assertFalse(JourneyEvent.objects.filter(
                journey=j, kind="arrived", payload__confirmed_pin=True).exists())
        return res

    def test_zero_impossible_arrived_no_pin(self):
        r = self.run_batch(with_pin=False)
        print("SJPROOF_ARRIVED no_pin taps=%(taps)d impossible=%(impossible)d "
              "impossible_arrived=%(impossible_arrived)d plain_arrived=%(plain_arrived)d "
              "unusual=%(unusual)d" % r)
        self.assertEqual(r["impossible_arrived"], 0)
        self.assertEqual(r["impossible_left_active_or_unusual"], r["impossible"])
        self.assertGreater(r["plain_arrived"], 10)         # real arrivals still work
        self.assertGreater(r["impossible"], 100)

    def test_zero_impossible_arrived_with_pin(self):
        r = self.run_batch(with_pin=True)
        print("SJPROOF_ARRIVED with_pin taps=%(taps)d impossible=%(impossible)d "
              "impossible_arrived=%(impossible_arrived)d pin_asked=%(pin_asked)d" % r)
        self.assertEqual(r["impossible_arrived"], 0)
        self.assertGreaterEqual(r["pin_asked"], r["impossible"])
