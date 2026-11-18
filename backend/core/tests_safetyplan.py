"""safety-plan (board row 49) — two guardians, the family safety plan, and the
per-journey map budget.

  * a CHILD's Safe Journey reaches BOTH guardians (start / arrive / late),
    even when the child picked only one; the child sees both names; the
    second guardian sees the trip in their watching list and board;
  * an ADULT's trip still reaches only the people they chose (privacy);
  * the family safety plan: create, share, the shared member reads it (names
    + numbers from the OWNER's Circle), a stranger never does, validation;
  * maps: paid calls during one live journey are capped (routes 3) and
    counted per journey; the free fallback answers after the cap.

Patches return plain values only (no bare MagicMock gets JSON-encoded)."""
from datetime import timedelta
from unittest import mock

from django.test import override_settings
from django.utils import timezone

from core import journey_watch as JW
from core import maps_cost as MC
from core import safety_plan as SPL
from core.models import CircleMember, GuardianLink, Journey, PaCollectionItem
from core.tests_journey100 import V, Base, cl, edge, mk
from core.tests_mapscost import KEY, Rec


class TwoGuardianBase(Base):
    """a = Rina (the child), b = Mother (Rina chose her), d = Father (an
    approved second guardian Rina did NOT pick for this trip)."""

    def setUp(self):
        super().setUp()
        self.d = mk("01711000009", "Father")
        CircleMember.objects.filter(pk=self.ab.pk).update(relation="mother")
        edge(self.b, self.a, relation="child", direction="incoming")
        GuardianLink.objects.create(child=self.a, guardian=self.d, invited_by=self.b,
                                    decided_by=self.b, state="approved", code="ABCDEFGH",
                                    expires_at=timezone.now() + timedelta(hours=48),
                                    approved_at=timezone.now())

    def events_to(self, u, kind):
        return [c for c in self.spy.to(u) if c["data"].get("event") == kind]


class TwoGuardianJourneyTests(TwoGuardianBase):
    def test_start_reaches_both_guardians_and_child_sees_both(self):
        j, body = self.start()
        self.assertEqual(len(self.events_to(self.b, "started")), 1)
        self.assertEqual(len(self.events_to(self.d, "started")), 1)
        self.assertEqual(self.events(j, "started")[0].recipients, 2)
        self.assertIn("Mother", body["watcher_names"])
        self.assertIn("Father", body["watcher_names"])
        self.assertEqual(self.events_to(self.c, "started"), [])

    def test_arrive_reaches_both(self):
        j, _ = self.start()
        JW.on_arrived(j)
        self.assertEqual(len(self.events_to(self.b, "arrived")), 1)
        self.assertEqual(len(self.events_to(self.d, "arrived")), 1)

    @override_settings(SJ_DURING_V2=False)
    def test_late_alert_reaches_both(self):
        j, _ = self.start(eta_min=-1)
        self.fix(j, 23.76, 90.392)
        Journey.objects.filter(pk=j.pk).update(eta=timezone.now() - timedelta(minutes=12))
        JW.sweep()
        JW.sweep(now=timezone.now() + timedelta(minutes=10))
        self.assertEqual(len(self.events_to(self.b, "overdue_alert")), 1)
        self.assertEqual(len(self.events_to(self.d, "overdue_alert")), 1)
        self.assertEqual(self.events_to(self.c, "overdue_alert"), [])

    def test_second_guardian_sees_trip_in_watching_list_and_board(self):
        j, _ = self.start()
        rows = cl(self.d).get("%s/journey/watching" % V).json()["journeys"]
        self.assertEqual([r["id"] for r in rows], [j.id])
        self.assertTrue(JW.is_watcher(j, self.d))
        self.assertFalse(JW.is_watcher(j, self.c))
        self.assertEqual(cl(self.c).get("%s/journey/watching" % V).json()["journeys"], [])

    def test_removed_second_guardian_gets_nothing(self):
        GuardianLink.objects.filter(guardian=self.d).update(state="removed")
        j, _ = self.start()
        self.assertEqual(self.events_to(self.d, "started"), [])
        self.assertFalse(JW.is_watcher(j, self.d))

    def test_adult_trip_reaches_only_chosen_people(self):
        # an adult with a verified parent: the parent is NOT added silently
        GuardianLink.objects.all().delete()
        j, body = self.start()
        self.assertEqual(self.events_to(self.d, "started"), [])
        self.assertEqual(JW.child_guardian_users(j), [])
        self.assertEqual(body["watcher_names"], ["Mother"])


class SafetyPlanTests(Base):
    def setUp(self):
        super().setUp()
        self.ba = edge(self.b, self.a, relation="child", direction="incoming")
        self.dad = edge(self.a, self.c, relation="father", phone="01711000003")
        CircleMember.objects.filter(pk=self.dad.pk).update(peer_user=None)  # not on Assisto

    def plan(self, **kw):
        body = {"meeting_point": {"name": "Sample Park gate", "lat": 23.7801, "lng": 90.4001,
                                  "note": "by the tea stall"},
                "meeting_point_far": {"name": "Uncle's house, Sample Road"},
                "numbers": [{"number": "999", "label": "Emergency"},
                            {"number": "01711 000 777", "label": "Family doctor"},
                            {"number": "abc", "label": "bad"}],
                "call_order": [self.dad.id, self.ab.id, 99999],
                "shared_with": [self.ab.id, self.dad.id]}
        body.update(kw)
        return self.ca.put("%s/safety-plan" % V, body, format="json")

    def test_create_share_and_shared_member_reads_it(self):
        r = self.plan()
        self.assertEqual(r.status_code, 200, r.content)
        mine = r.json()["mine"]
        self.assertEqual(mine["meeting_point"]["name"], "Sample Park gate")
        self.assertEqual([n["number"] for n in mine["numbers"]], ["999", "01711000777"])
        self.assertEqual([c["member_id"] for c in mine["call_order"]], [self.dad.id, self.ab.id])
        self.assertEqual(mine["call_order"][0]["phone"], "01711000003")
        # only members with an account can receive a shared plan
        self.assertEqual([s["member_id"] for s in mine["shared_with"]], [self.ab.id])
        # Mother was told once
        told = [c for c in self.spy.to(self.b) if c["data"].get("event") == "safety_plan_shared"]
        self.assertEqual(len(told), 1)
        self.assertEqual(told[0]["data"]["route"], "safety_plan")
        self.plan()  # saving again does not re-notify
        told = [c for c in self.spy.to(self.b) if c["data"].get("event") == "safety_plan_shared"]
        self.assertEqual(len(told), 1)
        got = self.cb.get("%s/safety-plan" % V).json()
        self.assertIsNone(got["mine"])
        self.assertEqual(len(got["shared"]), 1)
        sp = got["shared"][0]["plan"]
        self.assertEqual(sp["meeting_point"]["name"], "Sample Park gate")
        self.assertIsNone(sp["shared_with"])          # the reader never sees the share list
        self.assertTrue(any(c["is_you"] for c in sp["call_order"]))

    def test_stranger_never_sees_it(self):
        self.plan()
        self.assertEqual(self.cc.get("%s/safety-plan" % V).json()["shared"], [])

    def test_unshare_and_block_remove_access(self):
        self.plan()
        self.plan(shared_with=[])
        self.assertEqual(self.cb.get("%s/safety-plan" % V).json()["shared"], [])
        self.plan()
        CircleMember.objects.filter(pk=self.ab.pk).update(blocked=True)
        self.assertEqual(self.cb.get("%s/safety-plan" % V).json()["shared"], [])

    def test_empty_plan_refused_and_defaults_listed(self):
        r = self.ca.put("%s/safety-plan" % V, {"numbers": [{"number": "x"}]}, format="json")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()["detail"], "empty")
        g = self.ca.get("%s/safety-plan" % V).json()
        self.assertIn("999", [n["number"] for n in g["defaults"]])
        self.assertIsNone(g["mine"])

    def test_others_members_cannot_be_injected(self):
        # Rina cannot put Mother's own Circle rows into her plan
        r = self.plan(call_order=[self.ba.id], shared_with=[self.ba.id])
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["mine"]["call_order"], [])
        self.assertEqual(r.json()["mine"]["shared_with"], [])

    def test_delete(self):
        self.plan()
        self.ca.delete("%s/safety-plan" % V)
        self.assertFalse(PaCollectionItem.objects.filter(collection=SPL.COLLECTION).exists())

    def test_never_paywalled(self):
        with mock.patch("core.safe_plans.feature_on", return_value=True):
            self.assertEqual(self.plan().status_code, 200)


class JourneyMapBudgetTests(Base):
    def setUp(self):
        super().setUp()
        self.rec = Rec()
        for p in (mock.patch.object(MC, "HTTP", self.rec),
                  mock.patch.object(MC, "server_key", lambda: KEY),
                  mock.patch.object(MC, "ready", lambda: True)):
            p.start()
            self.addCleanup(p.stop)

    def eta(self, k):
        return self.ca.get("%s/maps/eta?olat=%.4f&olng=90.39&dlat=23.80&dlng=90.40"
                           % (V, 23.70 + k * 0.01)).json()

    def test_routes_capped_per_journey_and_counted(self):
        j, _ = self.start()
        states = [self.eta(k)["state"] for k in range(6)]
        self.assertEqual(states[:3], ["ok", "ok", "ok"])
        self.assertEqual(states[3:], ["none", "none", "none"])  # free fallback
        routes = [c for c in self.rec.calls if "computeRoutes" in c["url"]]
        self.assertEqual(len(routes), MC.JOURNEY_CAPS["routes"])
        mc = MC.journey_map_calls(j)
        self.assertEqual(mc["calls"]["routes"], 3)
        self.assertEqual(mc["total"], 3)
        self.assertLess(mc["usd_max"], 0.05)
        body = self.ca.get("%s/journey/active" % V).json()
        self.assertEqual(body.get("map_calls", {}).get("calls", {}).get("routes"), 3)

    def test_no_journey_only_daily_cap(self):
        states = [self.eta(k)["state"] for k in range(4)]
        self.assertEqual(states, ["ok"] * 4)

    def test_live_trip_itself_needs_zero_paid_calls(self):
        j, _ = self.start()
        n0 = len(self.rec.calls)
        for k in range(10):
            self.fix(j, 23.75 + k * 0.004, 90.392)
        JW.sweep()
        JW.on_arrived(Journey.objects.get(pk=j.pk))
        self.assertEqual(len(self.rec.calls), n0)
        self.assertEqual(MC.journey_map_calls(j)["total"], 0)
