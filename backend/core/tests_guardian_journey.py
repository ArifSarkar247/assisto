"""Owner idea 1 — guardian-requested journeys: ask -> one-tap accept ->
start at the window (nudge once when the app is closed) -> arrival tells the
requester -> auto end; the late flow (traveller first, then the requester,
then close family) with the traveller told every time; and the abuse
safeguards as server rules: consent every time for adults, child mode only
for a confirmed parent/child pair under 18, hard end at the window end,
location deleted after the trip, one-tap stop, never silent, audit both
sides, free on every plan, spam caps, strangers locked out.

Patches return plain values only (no bare MagicMock gets JSON-encoded)."""
from datetime import timedelta
from unittest import mock

from django.utils import timezone

from core import guardian_journey as GJ
from core import journey_watch as JW
from core import plans
from core.models import (CircleMember, Journey, JourneyPoint, JourneyRequest, NotifEvent,
                         User)
from core.tests_journey100 import V, Base, edge

U = "%s/journey/requests" % V


class GBase(Base):
    """b (Mother) asks to follow a (Rina). Both directions are in My Circle;
    Rina's brother c is her close family."""

    def setUp(self):
        super().setUp()
        self.ba = edge(self.b, self.a)          # Mother -> Rina
        self.ab.relation = "mother"             # Rina -> Mother
        self.ab.save()
        self.ac = edge(self.a, self.c, relation="brother")
        self.ca_edge = edge(self.c, self.a)

    def ask(self, start_in=60, hours=6, **kw):
        now = timezone.now()
        body = {"member_id": self.ba.id,
                "destination": {"name": "Chattogram", "lat": 22.3569, "lng": 91.7832},
                "start": (now + timedelta(minutes=start_in)).isoformat(),
                "end": (now + timedelta(minutes=start_in, hours=hours)).isoformat(),
                "note": "Call when you reach"}
        body.update(kw)
        return self.cb.post(U, body, format="json")

    def act(self, client, rid, action):
        return client.post("%s/%d/%s" % (U, rid, action), {}, format="json")

    def pushes(self, user, event=None):
        return [c for c in self.spy.to(user)
                if event is None or c["data"].get("event") == event]


class AskAcceptStartTests(GBase):
    def test_full_happy_path_with_nudge_once_and_arrival(self):
        r = self.ask()
        self.assertEqual(r.status_code, 201, r.content)
        rid = r.json()["id"]
        asked = self.pushes(self.a, "asked")
        self.assertEqual(len(asked), 1)
        self.assertIn("Chattogram", asked[0]["ben"])
        self.assertIn("Mother", asked[0]["ten"])
        inc = self.ca.get(U).json()["incoming"]
        self.assertEqual([x["id"] for x in inc], [rid])
        self.assertEqual(self.act(self.ca, rid, "accept").status_code, 200)
        self.assertEqual(len(self.pushes(self.b, "accepted")), 1)
        # before the window: nothing starts, the app cannot start it early
        self.assertEqual(self.act(self.ca, rid, "start").status_code, 409)
        req = JourneyRequest.objects.get(pk=rid)
        at = req.window_start + timedelta(minutes=1)
        JW.sweep(now=at)
        JW.sweep(now=at + timedelta(minutes=1))
        self.assertEqual(len(self.pushes(self.a, "start_now")), 1)   # once, high priority
        self.assertTrue(self.pushes(self.a, "start_now")[0]["high"])
        with mock.patch("core.guardian_journey._now", side_effect=lambda: at):
            s = self.act(self.ca, rid, "start")
        self.assertEqual(s.status_code, 200, s.content)
        req.refresh_from_db()
        j = req.journey
        self.assertEqual((req.status, j.status, j.location_retention_hours), ("active", "active", 0))
        self.assertEqual(list(j.watchers.values_list("member_id", flat=True)), [self.ab.id])
        self.assertEqual(j.eta, req.window_end)
        # the always-visible banner data on the traveller's live screen
        g = self.ca.get("%s/journey/active" % V).json()["guardian"]
        self.assertEqual((g["request_id"], g["name"]), (rid, "Mother"))
        self.assertEqual(len(self.pushes(self.a, "watching")), 1)    # never silent
        # requester sees the live state; arrival tells them
        self.fix(j, 22.40, 91.80)
        out = self.cb.get(U).json()["outgoing"][0]
        self.assertIsNotNone(out["live"]["lat"])
        self.fix(j, 22.3569, 91.7832)                                 # at the pin
        JW.sweep(now=timezone.now() + timedelta(minutes=1))
        req.refresh_from_db()
        self.assertEqual((req.status, req.outcome), ("arrived", "arrived"))
        self.assertTrue(any(c["data"].get("event") == "arrived" for c in self.spy.to(self.b)))
        # location history gone after the trip — only the summary stays
        JW.sweep(now=timezone.now() + timedelta(minutes=2))
        self.assertEqual(JourneyPoint.objects.filter(journey=j).count(), 0)
        j.refresh_from_db()
        self.assertIsNone(j.last_location)
        self.assertIsNotNone(req.arrived_at)
        # audit on both sides
        whats = [x["what"] for x in self.cb.get(U).json()["history"][0]["log"]]
        self.assertEqual(whats[:2], ["asked", "accepted"])
        self.assertIn("started", whats)
        self.assertEqual(self.ca.get(U).json()["history"][0]["log"], self.cb.get(U).json()["history"][0]["log"])

    def test_accept_inside_the_window_starts_at_once(self):
        rid = self.ask(start_in=-5).json()["id"]
        self.act(self.ca, rid, "accept")
        req = JourneyRequest.objects.get(pk=rid)
        self.assertEqual(req.status, "active")
        self.assertEqual(req.journey.status, "active")

    def test_unanswered_request_expires_at_the_window_start(self):
        rid = self.ask(start_in=30).json()["id"]
        JW.sweep(now=timezone.now() + timedelta(minutes=31))
        req = JourneyRequest.objects.get(pk=rid)
        self.assertEqual((req.status, req.outcome), ("expired", "not_answered"))
        self.assertEqual(len(self.pushes(self.b, "expired")), 1)
        self.assertEqual(self.act(self.ca, rid, "accept").status_code, 409)
        self.assertFalse(Journey.objects.filter(traveller=self.a).exists())

    def test_accepted_but_never_started_tells_the_requester_honestly(self):
        rid = self.ask(start_in=-5, hours=1).json()["id"]
        with mock.patch("core.guardian_journey.start_trip", side_effect=lambda r, n=None: (None, "x")):
            self.act(self.ca, rid, "accept")
        req = JourneyRequest.objects.get(pk=rid)
        JW.sweep(now=req.window_end + timedelta(minutes=1))
        req.refresh_from_db()
        self.assertEqual(req.outcome, "not_started")
        self.assertTrue(self.pushes(self.b, "not_started")[0]["high"])


class SafeguardTests(GBase):
    def test_adults_consent_every_time_no_standing(self):
        r = self.ask(standing=True, minor_declared=True,
                     schedule={"days": ["sun"], "start": "07:00", "end": "09:00"})
        self.assertEqual((r.status_code, r.json()["detail"]), (400, "standing_child_only"))
        first = self.ask().json()["id"]
        self.act(self.ca, first, "accept")
        second = self.ask(start_in=600).json()["id"]
        self.assertEqual(JourneyRequest.objects.get(pk=second).status, "pending")  # asks again

    def test_window_rules(self):
        self.assertEqual(self.ask(hours=30).json()["detail"], "window_too_long")
        self.assertEqual(self.ask(start_in=60 * 24 * 9).json()["detail"], "too_far_ahead")
        self.assertEqual(self.ask(destination={}).json()["detail"], "destination_required")
        stranger = CircleMember.objects.create(user=self.b, name="X", state="pending")
        self.assertEqual(self.ask(member_id=stranger.id).json()["detail"], "not_in_circle")

    def test_hard_end_and_points_deleted_and_traveller_told(self):
        rid = self.ask(start_in=-5, hours=1).json()["id"]
        self.act(self.ca, rid, "accept")
        req = JourneyRequest.objects.get(pk=rid)
        j = req.journey
        self.fix(j, 22.0, 91.0)
        self.act(self.ca, rid, "respond")                       # unknown action: 404
        JW.sweep(now=req.window_end + timedelta(minutes=GJ.HARD_TAIL_MIN + 1))
        req.refresh_from_db()
        j.refresh_from_db()
        self.assertEqual((req.status, req.outcome), ("ended", "window_end"))
        self.assertNotEqual(j.status, "active")
        self.assertEqual(JourneyPoint.objects.filter(journey=j).count(), 0)
        self.assertIsNone(j.last_location)
        self.assertEqual(len(self.pushes(self.a, "auto_end")), 1)
        self.assertEqual(len(self.pushes(self.b, "auto_end")), 1)

    def test_late_flow_traveller_first_then_requester_then_family(self):
        rid = self.ask(start_in=-5, hours=1).json()["id"]
        self.act(self.ca, rid, "accept")
        req = JourneyRequest.objects.get(pk=rid)
        j = req.journey
        self.fix(j, 22.0, 91.0)
        end = req.window_end
        JW.sweep(now=end + timedelta(minutes=11))               # ask the traveller only
        asks = [c for c in self.spy.to(self.a) if c["data"].get("event") == "overdue_ask"]
        self.assertEqual(len(asks), 1)
        self.assertFalse([c for c in self.spy.to(self.b) if c["data"].get("event") == "overdue_alert"])
        JW.sweep(now=end + timedelta(minutes=21))               # no answer -> requester
        to_b = [c for c in self.spy.to(self.b) if c["data"].get("event") == "overdue_alert"]
        self.assertEqual(len(to_b), 1)
        self.assertNotEqual(to_b[0]["data"]["lat"], "")         # with the last location
        self.assertFalse([c for c in self.spy.to(self.c) if c["data"].get("event") == "overdue_alert"])
        self.assertEqual(len(self.pushes(self.a, "escalated")), 1)   # traveller told
        JW.sweep(now=end + timedelta(minutes=37))               # second -> close family too
        self.assertTrue([c for c in self.spy.to(self.c) if c["data"].get("event") == "overdue_alert"])
        self.assertEqual(len(self.pushes(self.a, "escalated")), 2)

    def test_one_tap_stop_no_pin_requester_told(self):
        from core.models import DuressPin
        from core.logic import safety_journey as SJ
        DuressPin.objects.create(user=self.a, salt="s", normal_hash=SJ.hash_pin("1234", "s"),
                                 duress_hash=SJ.hash_pin("9876", "s"))
        rid = self.ask(start_in=-5).json()["id"]
        self.act(self.ca, rid, "accept")
        j = JourneyRequest.objects.get(pk=rid).journey
        self.fix(j, 22.0, 91.0)
        r = self.act(self.ca, rid, "stop")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["outcome"], "stopped_by_traveller")
        j.refresh_from_db()
        self.assertNotEqual(j.status, "active")
        self.assertEqual(JourneyPoint.objects.filter(journey=j).count(), 0)
        self.assertTrue(self.pushes(self.b, "stopped")[0]["high"])

    def test_only_the_right_side_can_act(self):
        rid = self.ask().json()["id"]
        self.assertEqual(self.act(self.cc, rid, "accept").status_code, 404)   # stranger
        self.assertEqual(self.act(self.cb, rid, "accept").status_code, 404)   # requester
        self.assertEqual(self.act(self.ca, rid, "cancel").status_code, 404)   # traveller
        self.assertEqual(self.act(self.cb, rid, "cancel").status_code, 200)
        self.assertEqual(len(self.pushes(self.a, "cancelled")), 1)

    def test_spam_caps(self):
        codes = [self.ask(start_in=60 + i).status_code for i in range(4)]
        self.assertEqual(codes, [201, 201, 201, 429])

    def test_free_on_every_plan(self):
        for i, plan in enumerate(plans.PLANS):
            User.objects.filter(pk__in=[self.a.pk, self.b.pk]).update(plan=plan, ai_credits=7)
            JourneyRequest.objects.all().delete()
            r = self.ask(start_in=-5)
            self.assertEqual(r.status_code, 201, (plan, r.content))
            self.assertEqual(self.act(self.ca, r.json()["id"], "accept").status_code, 200, plan)
            self.assertEqual(JourneyRequest.objects.get(pk=r.json()["id"]).status, "active", plan)
            self.assertEqual(set(User.objects.filter(pk__in=[self.a.pk, self.b.pk])
                                 .values_list("ai_credits", flat=True)), {7}, plan)

    def test_every_notice_is_visible_in_app_too(self):
        rid = self.ask(start_in=-5).json()["id"]
        self.act(self.ca, rid, "accept")
        self.act(self.ca, rid, "stop")
        mine = NotifEvent.objects.filter(user=self.a, route="journey/requests")
        self.assertGreaterEqual(mine.count(), 3)   # asked, watching, stopped_self


class ChildModeTests(GBase):
    def setUp(self):
        super().setUp()
        self.ba.relation = "child"       # Mother says: Rina is my child
        self.ba.save()
        self.ab.relation = "friend"      # ...Rina's side does not say parent yet
        self.ab.save()

    def school(self, now):
        loc = timezone.localtime(now)
        day = GJ.DAYS[loc.weekday()]
        s = max(loc - timedelta(minutes=30), loc.replace(hour=0, minute=0))
        e = min(loc + timedelta(hours=2), loc.replace(hour=23, minute=59))
        return {"days": [day], "start": s.strftime("%H:%M"), "end": e.strftime("%H:%M")}

    def test_only_a_confirmed_child_under_18(self):
        now = timezone.now()
        body = dict(standing=True, schedule=self.school(now))
        # the child's own side does not say parent yet
        self.assertEqual(self.ask(**body, minor_declared=True).json()["detail"], "standing_child_only")
        self.ab.relation = "mother"
        self.ab.save()
        # parent did not declare under 18
        self.assertEqual(self.ask(**body).json()["detail"], "standing_child_only")
        r = self.ask(**body, minor_declared=True)
        self.assertEqual(r.status_code, 201, r.content)
        self.assertTrue(r.json()["standing"])

    def test_school_mode_runs_each_day_and_child_always_sees_it(self):
        self.ab.relation = "mother"
        self.ab.save()
        now = timezone.now()
        r = self.ask(standing=True, minor_declared=True, schedule=self.school(now))
        rid = r.json()["id"]
        self.act(self.ca, rid, "accept")                  # the child accepts once
        req = JourneyRequest.objects.get(pk=rid)
        self.assertEqual(req.status, "active")            # inside today's window
        g = self.ca.get("%s/journey/active" % V).json()["guardian"]
        self.assertTrue(g["standing"])
        self.assertEqual(g["name"], "Mother")
        # the child can stop today's trip; school mode stays for the next day
        self.act(self.ca, rid, "stop")
        req.refresh_from_db()
        self.assertEqual((req.status, req.outcome), ("accepted", "stopped_by_traveller"))
        self.assertTrue(self.pushes(self.b, "stopped"))
        # the parent turns school mode off
        self.act(self.cb, rid, "cancel")
        req.refresh_from_db()
        self.assertEqual(req.status, "ended")
