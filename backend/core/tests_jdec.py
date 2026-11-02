"""Owner decisions 2 Nov (jdec).

DECISION 1 — guardian journey late tail: it may run up to HARD_TAIL_MIN after
the window end (so "Are you OK?" +10, requester +20, family +35 can fire),
the traveller is told so BEFORE accepting (number from the server constant),
and it STOPS AT ONCE on arrival (geofence / "I've arrived") and on the
traveller's one-tap stop — server state, no further location accepted or
visible to the requester, requester told. Nothing ever runs past end + 45.

DECISION 2 — saved places vs anti-theft safe places: only Home is an
anti-theft safe place by default; School / Office / others have their own
switch, off by default; anti-theft reads only places with the switch on;
journey destinations still use every saved place.

Patches return plain values only (no bare MagicMock gets JSON-encoded)."""
import glob
import importlib
import os
from datetime import timedelta

from django.apps import apps as django_apps
from django.utils import timezone

from core import guardian_journey as GJ
from core import journey_watch as JW
from core.logic import security as sec
from core.models import Journey, JourneyPoint, JourneyRequest, SavedPlace
from core.tests_guardian_journey import GBase, U
from core.tests_journey100 import V

PIN = (22.3569, 91.7832)       # the request's destination
AWAY = (22.0, 91.0)


class GuardianLateTailTests(GBase):
    """Decision 1."""

    def running(self):
        rid = self.ask(start_in=-5, hours=1).json()["id"]
        self.assertEqual(self.act(self.ca, rid, "accept").status_code, 200)
        req = JourneyRequest.objects.get(pk=rid)
        self.assertEqual(req.status, "active")
        self.fix(req.journey, *AWAY)
        return req

    def shift(self, req, minutes_after_end):
        """Move the trip so that NOW is `minutes_after_end` past the window
        end (negative: still inside the window)."""
        end = timezone.now() - timedelta(minutes=minutes_after_end)
        JourneyRequest.objects.filter(pk=req.pk).update(
            window_start=end - timedelta(hours=1), window_end=end,
            started_at=end - timedelta(hours=1))
        Journey.objects.filter(pk=req.journey_id).update(eta=end)
        req.refresh_from_db()
        return end

    def assert_ended_now(self, req, status, outcome):
        req.refresh_from_db()
        j = Journey.objects.get(pk=req.journey_id)
        self.assertEqual((req.status, req.outcome), (status, outcome))
        self.assertNotEqual(j.status, "active")
        self.assertIsNotNone(req.ended_at)
        # path gone at once (retention 0 h) — not on the next sweep
        self.assertEqual(JourneyPoint.objects.filter(journey=j).count(), 0)
        self.assertIsNone(j.last_location)
        # no further location accepted
        r = self.fix(j, *AWAY)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["accepted"], 0)
        self.assertEqual(JourneyPoint.objects.filter(journey=j).count(), 0)
        # nothing visible to the requester any more
        body = self.cb.get(U).json()
        self.assertEqual(body["outgoing"], [])
        self.assertNotIn("live", body["history"][0])
        self.assertEqual(self.cb.get("%s/journey/watching" % V).json()["journeys"], [])
        return j

    # ---- (a) consent text, from the server constant
    def test_consent_payload_says_the_late_tail_before_accepting(self):
        self.assertEqual(GJ.HARD_TAIL_MIN, 45)
        rid = self.ask().json()["id"]
        inc = self.ca.get(U, HTTP_ACCEPT_LANGUAGE="en").json()["incoming"][0]
        self.assertEqual(inc["status"], "pending")
        self.assertEqual(inc["late_tail_min"], GJ.HARD_TAIL_MIN)
        self.assertIn("up to %d minutes after the end time" % GJ.HARD_TAIL_MIN, inc["late_note"])
        self.assertIn("stops at once", inc["late_note"])
        self.assertIn("৪৫ মিনিট", GJ.late_note("bn"))
        self.assertIn("সময় শেষের পর সর্বোচ্চ", GJ.late_note("bn"))
        self.assertNotIn("45", GJ.late_note("bn"))              # Bangla digits
        self.assertTrue(rid)

    # ---- (b) arrival stops at once
    def test_geofence_arrival_inside_the_window_stops_at_once(self):
        req = self.running()
        self.shift(req, -20)
        r = self.fix(req.journey, *PIN)
        self.assertTrue(r.json()["arrived"])
        self.assert_ended_now(req, "arrived", "arrived")
        self.assertTrue(any(c["data"].get("event") == "arrived" for c in self.spy.to(self.b)))

    def test_geofence_arrival_in_the_late_tail_stops_at_once(self):
        req = self.running()
        self.shift(req, 20)                     # 20 min late, inside +45
        r = self.fix(req.journey, *PIN)
        self.assertTrue(r.json()["arrived"])
        self.assert_ended_now(req, "arrived", "arrived")
        self.assertTrue(any(c["data"].get("event") == "arrived" for c in self.spy.to(self.b)))

    def test_i_have_arrived_button_before_and_after_the_end_stops_at_once(self):
        for late in (-10, 30):
            JourneyRequest.objects.all().delete()
            Journey.objects.all().delete()
            self.spy.calls.clear()
            req = self.running()
            self.shift(req, late)
            r = self.ca.post("%s/journey/%d/arrived" % (V, req.journey_id), {}, format="json")
            self.assertEqual(r.json()["status"], "arrived", late)
            self.assert_ended_now(req, "arrived", "arrived")
            self.assertTrue(any(c["data"].get("event") == "arrived"
                                for c in self.spy.to(self.b)), late)

    # ---- one-tap stop during the +45 grace
    def test_one_tap_stop_in_the_late_tail_stops_at_once(self):
        req = self.running()
        self.shift(req, 25)
        JW.sweep(now=timezone.now())            # the late flow is running
        r = self.act(self.ca, req.id, "stop")
        self.assertEqual(r.status_code, 200)
        self.assert_ended_now(req, "ended", "stopped_by_traveller")
        self.assertTrue(self.pushes(self.b, "stopped")[0]["high"])

    def test_stop_from_the_safe_journey_screen_also_ends_the_request(self):
        req = self.running()
        self.shift(req, 15)
        r = self.ca.post("%s/journey/%d/stop" % (V, req.journey_id), {}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assert_ended_now(req, "ended", "stopped_by_traveller")
        self.assertEqual(len(self.pushes(self.b, "stopped")), 1)

    # ---- nothing past end + 45, ever
    def test_a_fix_after_end_plus_45_is_refused_even_between_sweeps(self):
        req = self.running()
        self.shift(req, GJ.HARD_TAIL_MIN + 1)
        r = self.fix(req.journey, *AWAY)        # no sweep ran
        self.assertEqual(r.json()["accepted"], 0)
        self.assert_ended_now(req, "ended", "window_end")
        self.assertEqual(len(self.pushes(self.b, "auto_end")), 1)
        self.assertEqual(len(self.pushes(self.a, "auto_end")), 1)

    def test_im_ok_and_extend_never_push_past_end_plus_45(self):
        req = self.running()
        end = self.shift(req, 30)
        self.assertEqual(self.ca.post("%s/journey/%d/respond" % (V, req.journey_id), {},
                                      format="json").status_code, 200)
        self.ca.post("%s/journey/%d/extend" % (V, req.journey_id), {"minutes": 120},
                     format="json")
        j = Journey.objects.get(pk=req.journey_id)
        self.assertGreater(j.eta, end + timedelta(minutes=GJ.HARD_TAIL_MIN))
        self.assertEqual(GJ.hard_end(req, j), end + timedelta(minutes=GJ.HARD_TAIL_MIN))
        stats = JW.sweep(now=end + timedelta(minutes=GJ.HARD_TAIL_MIN))
        req.refresh_from_db()
        self.assertEqual((req.status, req.outcome), ("ended", "window_end"))
        self.assertGreaterEqual(stats.get("req_auto_end", 0), 1)
        self.assertFalse(Journey.objects.filter(pk=j.pk, status="active").exists())

    def test_just_before_end_plus_45_it_still_runs(self):
        req = self.running()
        end = self.shift(req, 0)
        JW.sweep(now=end + timedelta(minutes=GJ.HARD_TAIL_MIN - 1))
        req.refresh_from_db()
        self.assertEqual(req.status, "active")
        JW.sweep(now=end + timedelta(minutes=GJ.HARD_TAIL_MIN))
        req.refresh_from_db()
        self.assertEqual((req.status, req.outcome), ("ended", "window_end"))


class PlaceSafeTests(GBase):
    """Decision 2."""
    P = "%s/journey/places" % V
    SCHOOL = (23.7300, 90.4000)
    HOME = (23.8000, 90.4100)
    OFFICE = (23.7500, 90.3900)

    def save(self, kind, at, **kw):
        body = {"kind": kind, "label": kind, "name": kind.title(), "lat": at[0], "lng": at[1]}
        body.update(kw)
        r = self.ca.post(self.P, body, format="json")
        self.assertIn(r.status_code, (200, 201), r.content)
        return r.json()

    def test_home_on_by_default_school_office_other_off(self):
        h = self.save("home", self.HOME)
        s = self.save("school", self.SCHOOL)
        o = self.save("office", self.OFFICE)
        x = self.save("other", (23.70, 90.35), label="Nanu", name="Nanu")
        self.assertEqual([h["theft_safe"], s["theft_safe"], o["theft_safe"], x["theft_safe"]],
                         [True, False, False, False])
        self.assertTrue(sec.is_trusted_location(self.a, *self.HOME))
        self.assertFalse(sec.is_trusted_location(self.a, *self.SCHOOL))
        self.assertFalse(sec.is_trusted_location(self.a, *self.OFFICE))
        st = self.ca.get("%s/security/state" % V).json()
        self.assertEqual(st["trusted_place_count"], 1)

    def test_switch_on_and_off_changes_anti_theft_softening(self):
        s = self.save("school", self.SCHOOL)
        url = "%s/%d" % (self.P, s["id"])
        self.assertFalse(sec.is_trusted_location(self.a, *self.SCHOOL))
        r = self.ca.patch(url, {"theft_safe": True}, format="json")
        self.assertEqual((r.status_code, r.json()["theft_safe"]), (200, True))
        self.assertTrue(sec.is_trusted_location(self.a, *self.SCHOOL))
        r = self.ca.patch(url, {"theft_safe": False}, format="json")
        self.assertEqual(r.json()["theft_safe"], False)
        self.assertFalse(sec.is_trusted_location(self.a, *self.SCHOOL))
        # a stray string never switches it on; strangers cannot touch it
        self.assertEqual(self.ca.patch(url, {"theft_safe": "yes"}, format="json").status_code, 400)
        self.assertEqual(self.cc.patch(url, {"theft_safe": True}, format="json").status_code, 404)
        self.assertFalse(SavedPlace.objects.get(pk=s["id"]).theft_safe)
        # Home can be switched off too
        h = self.save("home", self.HOME)
        self.ca.patch("%s/%d" % (self.P, h["id"]), {"theft_safe": False}, format="json")
        self.assertFalse(sec.is_trusted_location(self.a, *self.HOME))

    def test_save_with_the_switch_and_resave_keeps_it(self):
        s = self.save("school", self.SCHOOL, theft_safe=True)
        self.assertTrue(s["theft_safe"])
        again = self.save("school", (23.7310, 90.4010))       # replaces, switch kept
        self.assertEqual((again["id"], again["theft_safe"]), (s["id"], True))
        h = self.save("home", self.HOME, theft_safe=False)
        self.assertFalse(h["theft_safe"])

    def test_journey_destinations_still_use_every_saved_place(self):
        self.save("home", self.HOME)
        self.save("school", self.SCHOOL)
        self.save("office", self.OFFICE)
        rows = self.ca.get(self.P).json()["places"]
        self.assertEqual([p["kind"] for p in rows], ["home", "school", "office"])
        self.assertEqual([p["theft_safe"] for p in rows], [True, False, False])

    def test_data_migration_home_on_everything_else_off(self):
        mk = lambda label, safe: SavedPlace.objects.create(   # noqa: E731
            user=self.a, label=label, name=label, lat=23.7, lng=90.4, theft_safe=safe)
        home, home2 = mk("home", False), mk(" Home ", False)
        school, office, other = mk("school", True), mk("office", True), mk("Nanu", True)
        here = os.path.dirname(os.path.abspath(__file__))
        name = os.path.basename(glob.glob(os.path.join(here, "migrations", "*_placesafe.py"))[0])[:-3]
        mig = importlib.import_module("core.migrations.%s" % name)
        mig.home_on(django_apps, None)
        got = {p.pk: p.theft_safe for p in SavedPlace.objects.filter(user=self.a)}
        self.assertEqual(got, {home.pk: True, home2.pk: True, school.pk: False,
                               office.pk: False, other.pk: False})
