"""journey100b — Safe Journey gaps closed in code before the owner's
two-phone test (owner_actions/SAFE_JOURNEY_GAP_TO_100_BN.md).

1. Many parents: Mother AND Father may follow one trip. Before journey100b
   the second accepted request silently STOPPED the first parent's journey
   (and a traveller's own Safe Journey). Now every request joins the running
   journey with its OWN window and hard end; only that parent leaves.

Patches return plain values only (no bare MagicMock gets JSON-encoded)."""
from datetime import timedelta
from unittest import mock

from django.utils import timezone

from core import guardian_journey as GJ
from core import journey_watch as JW
from core.models import Journey, JourneyPoint, JourneyRequest
from core.tests_guardian_journey import GBase, U
from core.tests_journey100 import V


class ManyParentsTests(GBase):
    """b = Mother, c = Father; a = Rina (the traveller)."""

    def setUp(self):
        super().setUp()
        self.ac.relation = "father"
        self.ac.save()

    def ask_father(self, start_in=-5, hours=3):
        now = timezone.now()
        body = {"member_id": self.ca_edge.id,
                "destination": {"name": "Chattogram", "lat": 22.3569, "lng": 91.7832},
                "start": (now + timedelta(minutes=start_in)).isoformat(),
                "end": (now + timedelta(minutes=start_in, hours=hours)).isoformat()}
        r = self.cc.post(U, body, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        return r.json()["id"]

    def both_live(self, mother_hours=1, father_hours=3):
        m = self.ask(start_in=-5, hours=mother_hours).json()["id"]
        self.act(self.ca, m, "accept")
        f = self.ask_father(hours=father_hours)
        self.act(self.ca, f, "accept")
        return JourneyRequest.objects.get(pk=m), JourneyRequest.objects.get(pk=f)

    def watcher_ids(self, j):
        return set(j.watchers.values_list("member_id", flat=True))

    def test_second_parent_joins_instead_of_silently_stopping_the_first(self):
        mreq, freq = self.both_live()
        self.assertEqual((mreq.status, freq.status), ("active", "active"))
        self.assertEqual(mreq.journey_id, freq.journey_id)
        self.assertEqual(Journey.objects.filter(traveller=self.a, status="active").count(), 1)
        j = mreq.journey
        self.assertEqual(self.watcher_ids(j), {self.ab.id, self.ac.id})
        self.assertFalse(self.pushes(self.b, "stopped"))          # Mother never cut off
        self.assertEqual(len(self.pushes(self.c, "started")), 1)  # Father told it began
        self.assertEqual(len(self.pushes(self.a, "watching")), 2)  # traveller told twice
        # the trip lives until the LATER window's hard end
        self.assertGreaterEqual(j.expires_at, freq.window_end + timedelta(minutes=GJ.HARD_TAIL_MIN))
        # a sweep does not end anything
        JW.sweep(now=timezone.now() + timedelta(minutes=1))
        mreq.refresh_from_db()
        freq.refresh_from_db()
        self.assertEqual((mreq.status, freq.status), ("active", "active"))

    def test_arrival_ends_every_request_and_tells_both_parents(self):
        mreq, _f = self.both_live()
        j = mreq.journey
        self.fix(j, 22.40, 91.80)
        self.fix(j, 22.3569, 91.7832)                       # at the pin
        for r in JourneyRequest.objects.filter(traveller=self.a):
            self.assertEqual((r.status, r.outcome), ("arrived", "arrived"))
        self.assertTrue(any(c["data"].get("event") == "arrived" for c in self.spy.to(self.b)))
        self.assertTrue(any(c["data"].get("event") == "arrived" for c in self.spy.to(self.c)))
        self.assertEqual(JourneyPoint.objects.filter(journey=j).count(), 0)   # path gone

    def test_mothers_window_ends_first_only_she_leaves(self):
        mreq, freq = self.both_live(mother_hours=1, father_hours=3)
        j = mreq.journey
        gen0 = j.web_gen
        self.fix(j, 22.0, 91.0)
        at = mreq.window_end + timedelta(minutes=GJ.HARD_TAIL_MIN + 1)
        JW.sweep(now=at)
        mreq.refresh_from_db()
        freq.refresh_from_db()
        j.refresh_from_db()
        self.assertEqual((mreq.status, mreq.outcome), ("ended", "window_end"))
        self.assertEqual(freq.status, "active")
        self.assertEqual(j.status, "active")                # Father still follows
        self.assertEqual(self.watcher_ids(j), {self.ac.id})  # Mother removed
        self.assertGreater(j.web_gen, gen0)                  # her old web link is off
        self.assertEqual(len(self.pushes(self.b, "auto_end")), 1)
        # Father still gets fixes after Mother's end
        with mock.patch("core.guardian_journey._now", side_effect=lambda: at):
            r = self.fix(j, 22.1, 91.1)
        self.assertEqual(r.json()["status"], "active")
        # Father's own hard end closes the trip and deletes the path
        JW.sweep(now=freq.window_end + timedelta(minutes=GJ.HARD_TAIL_MIN + 1))
        j.refresh_from_db()
        freq.refresh_from_db()
        self.assertNotEqual(j.status, "active")
        self.assertEqual(freq.outcome, "window_end")
        self.assertEqual(JourneyPoint.objects.filter(journey=j).count(), 0)

    def test_one_tap_stop_tells_every_parent(self):
        mreq, _f = self.both_live()
        j = mreq.journey
        r = self.ca.post("%s/journey/%d/stop" % (V, j.id), {}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(len(self.pushes(self.b, "stopped")), 1)
        self.assertEqual(len(self.pushes(self.c, "stopped")), 1)
        self.assertFalse(JourneyRequest.objects.filter(traveller=self.a, status="active").exists())


class OwnTripAndParentTests(GBase):
    """The traveller's own Safe Journey and a parent's request never cancel
    each other silently."""

    def own_trip(self):
        j, _ = self.start(eta_min=120)       # watcher b chosen by Rina herself
        return j

    def test_request_joins_own_trip_and_leaving_keeps_it(self):
        j = self.own_trip()
        rid = self.ask(start_in=-5, hours=1).json()["id"]
        self.act(self.ca, rid, "accept")
        req = JourneyRequest.objects.get(pk=rid)
        j.refresh_from_db()
        self.assertEqual(req.journey_id, j.id)              # joined, not replaced
        self.assertEqual(j.status, "active")
        self.fix(j, 23.77, 90.395)
        JW.sweep(now=req.window_end + timedelta(minutes=GJ.HARD_TAIL_MIN + 1))
        req.refresh_from_db()
        j.refresh_from_db()
        self.assertEqual(req.outcome, "window_end")
        self.assertEqual(j.status, "active")                # Rina's own trip goes on
        # b was Rina's own chosen watcher: stays a watcher
        self.assertIn(self.ab.id, set(j.watchers.values_list("member_id", flat=True)))
        self.assertGreater(JourneyPoint.objects.filter(journey=j).count(), 0)

    def test_new_own_trip_carries_the_parent_over(self):
        rid = self.ask(start_in=-5, hours=2).json()["id"]
        self.act(self.ca, rid, "accept")
        old = JourneyRequest.objects.get(pk=rid).journey
        j, _ = self.start(eta_min=30, watcher_ids=[])
        req = JourneyRequest.objects.get(pk=rid)
        self.assertEqual(req.journey_id, j.id)
        self.assertEqual(req.status, "active")
        self.assertIn(self.ab.id, set(j.watchers.values_list("member_id", flat=True)))
        old.refresh_from_db()
        self.assertEqual(old.status, "stopped")
        JW.sweep(now=timezone.now() + timedelta(minutes=1))
        req.refresh_from_db()
        self.assertEqual(req.status, "active")              # not silently "ended"
        self.assertFalse(self.pushes(self.b, "stopped"))


class ClearUrgentScopeTests(GBase):
    def test_clear_urgent_for_one_user_keeps_the_others(self):
        from core.models import FamilyAlert
        j, _ = self.start()
        for u in (self.b, self.c):
            FamilyAlert.objects.create(user=u, kind="journey", payload={"journey_id": j.id})
        JW.clear_urgent(j, user=self.b)
        self.assertEqual(set(FamilyAlert.objects.filter(dismissed=False)
                             .values_list("user_id", flat=True)), {self.c.id})
        JW.clear_urgent(j)
        self.assertFalse(FamilyAlert.objects.filter(dismissed=False).exists())

