"""circlea — many-to-many guardianship: 2 parents x 2 children.

Mom + Dad both guard Rina and Babu across kids watch, school mode and the
guardian journey. Checks: data (both listed), permissions (co-guardian reads
the plan read-only), alert fan-out to EVERY guardian, the child's screen lists
every watcher by name, removal by the child under the existing consent rules,
and two parents following the same trip (no parent kicks the other off).

Patches return plain values only (no bare MagicMock gets JSON-encoded)."""
from datetime import timedelta
from unittest import mock

from django.core.cache import cache
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import guardian_journey as GJ
from core import guardianship as G
from core import kidswatch_service as KW
from core.models import (CircleMember, Journey, JourneyRequest, JourneyWatcher,
                         KidsWatch, SchoolPlan, User)

V = "/api/v1"


def mk(phone, name):
    return User.objects.create_user(name=name, phone=phone, password="pw12345!")


def pair(a, b, rel_ab="friend", rel_ba="friend"):
    CircleMember.objects.create(user=a, peer_user=b, name=b.name, state="accepted",
                                relation=rel_ab)
    CircleMember.objects.create(user=b, peer_user=a, name=a.name, state="accepted",
                                relation=rel_ba, direction="incoming")


def cl(u):
    c = APIClient()
    c.force_authenticate(u)
    c.credentials(HTTP_ACCEPT_LANGUAGE="en")
    return c


class Spy:
    def __init__(self):
        self.calls = []

    def __call__(self, user, kind, tbn, ten, bbn="", ben="", data=None, **kw):
        self.calls.append({"user": user.pk, "kind": kind, "ten": ten, "ben": ben,
                           "data": dict(data or {})})
        return True

    def users(self):
        return {c["user"] for c in self.calls}


class TwoByTwo(TestCase):
    def setUp(self):
        cache.clear()
        self.mom = mk("01711300001", "Mom")
        self.dad = mk("01711300002", "Dad")
        self.rina = mk("01711300003", "Rina")
        self.babu = mk("01711300004", "Babu")
        self.x = mk("01711300005", "Stranger")
        pair(self.mom, self.dad, "husband", "wife")
        for kid in (self.rina, self.babu):
            pair(self.mom, kid, "child", "mother")
            pair(self.dad, kid, "child", "father")
        pair(self.rina, self.babu, "brother", "sister")
        self.spy = Spy()
        p = mock.patch("core.push.safe_push", side_effect=self.spy)
        p.start()
        self.addCleanup(p.stop)
        now = timezone.now()
        # Rina: Mom's phone school plan (Dad watches) + Dad's watch (Mom guards)
        self.plan_rina = SchoolPlan.objects.create(
            owner=self.mom, child_user=self.rina, child_name="Rina",
            watcher_ids=[self.dad.id], accepted_at=now)
        self.watch_rina = KidsWatch.objects.create(
            owner=self.dad, child_user=self.rina, child_name="Rina",
            imei="8800000901", state="paired", guardian_ids=[self.mom.id])
        # Babu: Mom's school plan ONLY (no watcher chosen) + Dad's one-off trip
        self.plan_babu = SchoolPlan.objects.create(
            owner=self.mom, child_user=self.babu, child_name="Babu",
            watcher_ids=[], accepted_at=now)

    # -------------------------------------------------------------- data
    def test_child_sees_every_guardian_by_name(self):
        r = cl(self.rina).get(V + "/guardians/mine")
        self.assertEqual(r.status_code, 200)
        rows = {g["name"]: g for g in r.json()["guardians"]}
        self.assertEqual(set(rows), {"Mom", "Dad"})
        kinds = {s["kind"] for s in rows["Dad"]["sources"]}
        self.assertEqual(kinds, {"school_mode", "kids_watch"})
        self.assertTrue(rows["Dad"]["removable"])           # via school mode
        # a stranger is never listed; Babu sees only Mom (so far)
        names = {g["name"] for g in cl(self.babu).get(V + "/guardians/mine").json()["guardians"]}
        self.assertEqual(names, {"Mom"})

    def test_one_parent_many_children_with_co_guardians(self):
        r = cl(self.mom).get(V + "/guardians/children")
        self.assertEqual(r.status_code, 200)
        kids = {k["name"]: k for k in r.json()["children"]}
        self.assertEqual(set(kids), {"Rina", "Babu"})
        self.assertEqual([g["name"] for g in kids["Rina"]["co_guardians"]], ["Dad"])
        self.assertEqual(kids["Babu"]["co_guardians"], [])
        dad = {k["name"]: k for k in cl(self.dad).get(V + "/guardians/children").json()["children"]}
        self.assertIn("Rina", dad)
        self.assertEqual([g["name"] for g in dad["Rina"]["co_guardians"]], ["Mom"])
        self.assertEqual(cl(self.x).get(V + "/guardians/children").json()["children"], [])

    # ----------------------------------------------------------- fan-out
    def test_alerts_reach_every_guardian(self):
        # Babu's plan has no watcher, but Dad follows Babu (accepted trip)
        now = timezone.now()
        JourneyRequest.objects.create(requester=self.dad, traveller=self.babu,
                                      window_start=now - timedelta(minutes=5),
                                      window_end=now + timedelta(hours=1),
                                      status="accepted")
        ids = {u.id for u in KW.plan_watchers(self.plan_babu)}
        self.assertEqual(ids, {self.mom.id, self.dad.id})
        # Dad's watch for Rina lists Mom; Mom also owns Rina's school plan
        ids = {u.id for u in KW.watch_audience(self.watch_rina)}
        self.assertEqual(ids, {self.dad.id, self.mom.id})
        self.assertNotIn(self.rina.id, ids)
        # a watch alarm really pushes to both parents
        KW._send(KW.watch_audience(self.watch_rina), "t", "t", "b", "b",
                 {"event": "test"}, family_alert=False)
        self.assertEqual(self.spy.users(), {self.dad.id, self.mom.id})

    def test_co_guardian_who_left_the_childs_circle_gets_nothing(self):
        CircleMember.objects.filter(user=self.rina, peer_user=self.dad).update(blocked=True)
        CircleMember.objects.filter(user=self.dad, peer_user=self.rina).update(state="declined")
        # Mom's watch-less plan: Dad was a chosen watcher (Mom's peer) -> still
        # listed by the plan owner's choice; but a co-guardian from ANOTHER
        # feature must be the child's peer.
        w = KidsWatch.objects.create(owner=self.mom, child_user=self.babu, child_name="Babu",
                                     imei="8800000902", state="paired", guardian_ids=[])
        JourneyRequest.objects.create(requester=self.dad, traveller=self.babu,
                                      window_start=timezone.now(),
                                      window_end=timezone.now() + timedelta(hours=1),
                                      status="accepted")
        CircleMember.objects.filter(user=self.babu, peer_user=self.dad).update(blocked=True)
        CircleMember.objects.filter(user=self.dad, peer_user=self.babu).update(state="declined")
        self.assertEqual({u.id for u in KW.watch_audience(w)}, {self.mom.id})

    # --------------------------------------------------------- permission
    def test_co_guardian_reads_the_plan_read_only(self):
        from core import feature_flags as FF
        from core.models import FeatureFlag
        FF.ensure_seeded()
        FeatureFlag.objects.filter(key="kids_watch").update(enabled_all=True, enabled_play=True)
        FF.invalidate()
        plans = cl(self.dad).get(V + "/school-mode/plans").json()["plans"]
        rina = [p for p in plans if p["id"] == self.plan_rina.id]
        self.assertEqual(len(rina), 1)
        self.assertFalse(rina[0]["mine"])
        # ...but cannot edit it
        r = cl(self.dad).patch(V + "/school-mode/plans/%d" % self.plan_rina.id,
                               {"child_name": "X"}, format="json")
        self.assertIn(r.status_code, (403, 404))
        self.assertEqual([p for p in cl(self.x).get(V + "/school-mode/plans").json()["plans"]], [])

    # ----------------------------------------------------------- removal
    def test_child_removes_a_guardian_under_consent_rules(self):
        r = cl(self.rina).post(V + "/guardians/mine/%d/remove" % self.dad.id)
        self.assertEqual(r.status_code, 200, r.content)
        body = r.json()
        self.assertEqual([x["kind"] for x in body["removed"]], ["school_mode"])
        # the watch was set up by Dad himself -> stays, and the answer says so
        self.assertEqual([(x["kind"], x["set_up_by"]) for x in body["kept"]],
                         [("kids_watch", "Dad")])
        self.plan_rina.refresh_from_db()
        self.assertEqual(self.plan_rina.watcher_ids, [])
        self.assertTrue(self.plan_rina.enabled)
        # both the plan owner and the removed guardian are told
        told = {c["user"] for c in self.spy.calls
                if c["data"].get("event") == "watcher_removed_by_child"}
        self.assertEqual(told, {self.mom.id, self.dad.id})
        # removing the plan OWNER stops that plan (same as the child's stop)
        r = cl(self.rina).post(V + "/guardians/mine/%d/remove" % self.mom.id)
        self.plan_rina.refresh_from_db()
        self.assertFalse(self.plan_rina.enabled)
        # someone who is not my guardian -> 404, nothing changes
        self.assertEqual(cl(self.rina).post(V + "/guardians/mine/%d/remove" % self.x.id)
                         .status_code, 404)

    def test_child_withdraws_a_guardian_journey(self):
        now = timezone.now()
        req = JourneyRequest.objects.create(requester=self.dad, traveller=self.babu,
                                            window_start=now - timedelta(minutes=5),
                                            window_end=now + timedelta(hours=1),
                                            status="accepted")
        r = cl(self.babu).post(V + "/guardians/mine/%d/remove" % self.dad.id)
        self.assertEqual(r.status_code, 200)
        req.refresh_from_db()
        self.assertEqual(req.status, "ended")
        self.assertNotIn("Dad", {g["name"] for g in r.json()["guardians"]})

    # ------------------------------------------------- two parents, one trip
    def test_two_parents_follow_one_trip_without_kicking_each_other(self):
        now = timezone.now()
        mk_req = lambda who: JourneyRequest.objects.create(  # noqa: E731
            requester=who, traveller=self.rina,
            window_start=now - timedelta(minutes=5), window_end=now + timedelta(hours=1),
            status="accepted")
        a, b = mk_req(self.mom), mk_req(self.dad)
        ja, err = GJ.start_trip(a, now)
        self.assertIsNone(err)
        jb, err = GJ.start_trip(b, now)
        self.assertIsNone(err)
        self.assertEqual(ja.id, jb.id)                       # ONE shared trip
        self.assertEqual(Journey.objects.filter(traveller=self.rina, status="active").count(), 1)
        self.assertEqual(JourneyWatcher.objects.filter(journey=ja).count(), 2)
        # Mom cancels: Dad keeps seeing it, Rina is told the truth
        a.refresh_from_db()
        others = GJ.others_live(a)
        self.assertEqual([o.requester_id for o in others], [self.dad.id])
        GJ.finish(a, "cancelled", now, by="requester")
        ja.refresh_from_db()
        self.assertEqual(ja.status, "active")
        self.assertEqual(JourneyWatcher.objects.filter(journey=ja).count(), 1)
        bn, en = GJ.still_watching_texts(a, others)
        self.assertIn("Dad", en)
        self.assertIn("Dad", bn)
        # Rina stops Dad's too: now the trip really ends
        b.refresh_from_db()
        GJ.stop_by_traveller(b, now)
        ja.refresh_from_db()
        self.assertNotEqual(ja.status, "active")
        self.assertIn("Nobody is seeing your location now.",
                      [c["ben"] for c in self.spy.calls if c["user"] == self.rina.id])
