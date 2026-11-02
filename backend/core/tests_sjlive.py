"""sjlive — Safe Journey card 1 "Live Location" (owner order 3 Nov):
Share for a While (ends by itself, never "late", SOS keeps it on), Request
Location (location only: consent, visible, stop, exact end, no late tail),
honest accuracy (stored, shown, rough fixes never "arrive"), offline buffer
replay, Who is where now, Child School from the child's phone (holidays,
fixes drive the plan, CCTV gate snapshot only through the camera seam).

Patches return plain values only (no bare MagicMock gets JSON-encoded)."""
import tempfile
from datetime import timedelta
from unittest import mock

from django.core.files.base import ContentFile
from django.test import override_settings
from django.utils import timezone

from core import guardian_journey as GJ
from core import journey_watch as JW
from core import sj_live as SL
from core.logic import school_mode as SM
from core.models import Journey, JourneyEvent, JourneyRequest, SchoolPlan
from core.tests_journey100 import HOME, V, Base, edge
from core.tests_kidswatch import CFG, L, SCHOOL, pair_circle
from core.tests_kidswatch import HOME as K_HOME
from core.tests_kidswatch import mk as kmk

U = "%s/journey/requests" % V
_MEDIA = tempfile.mkdtemp(prefix="sjlive-test-")


class ShareForAWhileTests(Base):
    def share(self, minutes=60, **kw):
        body = {"share_minutes": minutes, "watcher_ids": [self.ab.id]}
        body.update(kw)
        return self.ca.post("%s/journey/start" % V, body, format="json")

    def test_share_starts_without_destination_and_tells_the_watcher(self):
        r = self.share(60)
        self.assertEqual(r.status_code, 201, r.content)
        body = r.json()
        self.assertTrue(body["share"])
        j = Journey.objects.get(pk=body["id"])
        self.assertTrue(SL.is_share(j))
        self.assertEqual((j.stop_alert_min, j.overdue_grace_min, j.route_deviation),
                         (0, 0, False))
        left = (j.eta - timezone.now()).total_seconds() / 60
        self.assertTrue(58 <= left <= 60.5, left)
        started = [c for c in self.spy.to(self.b) if c["data"].get("event") == "started"]
        self.assertEqual(len(started), 1)
        self.assertIn("Live Location", started[0]["ten"])
        self.assertIn("লাইভ লোকেশন", started[0]["tbn"])
        self.assertNotIn("destination", started[0]["ben"])

    def test_share_needs_people_and_a_sane_time(self):
        self.assertEqual(self.share(60, watcher_ids=[]).json()["detail"], "watcher_required")
        self.assertEqual(self.share(5).json()["detail"], "bad_share_minutes")
        self.assertEqual(self.share(24 * 60 + 1).status_code, 400)
        self.assertEqual(self.share(180).status_code, 201)
        self.assertEqual(self.share(45).status_code, 201)          # custom

    def test_share_ends_by_itself_and_is_never_late(self):
        j = Journey.objects.get(pk=self.share(60).json()["id"])
        self.ca.post("%s/journey/%d/location" % (V, j.id), {"lat": 23.7, "lng": 90.4},
                     format="json")
        # just before the end: nothing; and never an "Are you OK?"
        JW.sweep(now=j.eta - timedelta(minutes=1))
        j.refresh_from_db()
        self.assertEqual(j.status, "active")
        self.assertEqual(JW.overdue(j, j.eta + timedelta(hours=1))[0], "no_eta")
        JW.sweep(now=j.eta + timedelta(seconds=30))
        j.refresh_from_db()
        self.assertEqual(j.status, "stopped")
        self.assertEqual(len(self.events(j, "share_ended")), 1)
        self.assertFalse(self.events(j, "overdue_alert"))
        ended = [c for c in self.spy.to(self.b) if c["data"].get("event") == "share_ended"]
        self.assertEqual(len(ended), 1)
        mine = [c for c in self.spy.to(self.a) if c["data"].get("event") == "share_ended"]
        self.assertEqual(len(mine), 1)               # the sharer is told too
        JW.sweep(now=j.eta + timedelta(minutes=2))   # idempotent
        self.assertEqual(len(self.events(j, "share_ended")), 1)
        # privacy: retention 0 h -> the path is gone
        j.refresh_from_db()
        self.assertIsNone(j.last_location)

    def test_fix_after_the_end_is_refused_and_phone_told_to_stop(self):
        j = Journey.objects.get(pk=self.share(60).json()["id"])
        Journey.objects.filter(pk=j.pk).update(eta=timezone.now() - timedelta(seconds=5))
        r = self.ca.post("%s/journey/%d/location" % (V, j.id), {"lat": 23.7, "lng": 90.4},
                         format="json").json()
        self.assertEqual((r["status"], r["accepted"]), ("stopped", 0))

    def test_open_sos_keeps_sharing_past_the_end(self):
        j = Journey.objects.get(pk=self.share(60).json()["id"])
        Journey.objects.filter(pk=j.pk).update(sos_active=True)
        JW.sweep(now=j.eta + timedelta(minutes=1))
        j.refresh_from_db()
        self.assertEqual(j.status, "active")


class AccuracyAndBufferTests(Base):
    def test_accuracy_stored_shown_and_rough_fix_never_arrives(self):
        j, _ = self.start()
        r = self.ca.post("%s/journey/%d/location" % (V, j.id),
                         {"lat": HOME["lat"], "lng": HOME["lng"], "acc": 1800.4},
                         format="json").json()
        self.assertFalse(r["arrived"])                       # a cell-tower fix at the pin
        w = self.cb.get("%s/journey/watching" % V).json()["journeys"][0]
        self.assertEqual(w["acc_m"], 1800)
        r = self.ca.post("%s/journey/%d/location" % (V, j.id),
                         {"lat": HOME["lat"], "lng": HOME["lng"], "acc": 12},
                         format="json").json()
        self.assertTrue(r["arrived"])
        j.refresh_from_db()
        self.assertEqual(j.last_location["acc"], 12)

    def test_junk_accuracy_is_dropped_and_old_builds_unchanged(self):
        self.assertIsNone(SL.clean_acc("x"))
        self.assertIsNone(SL.clean_acc(-3))
        self.assertIsNone(SL.clean_acc(10 ** 6))
        self.assertEqual(SL.clean_acc("7.6"), 8)
        self.assertTrue(SL.acc_ok_for_arrival(None, 120))
        self.assertTrue(SL.acc_ok_for_arrival(240, 120))
        self.assertFalse(SL.acc_ok_for_arrival(241, 120))
        j, _ = self.start()
        r = self.fix(j, HOME["lat"], HOME["lng"]).json()       # no acc at all
        self.assertTrue(r["arrived"])

    def test_offline_buffer_replay_sorted_newest_wins(self):
        j, _ = self.start()
        now = timezone.now()
        pts = [{"lat": 23.71, "lng": 90.39, "at": (now - timedelta(minutes=m)).isoformat(),
                "battery": 50, "acc": 9, "src": "bg"} for m in (5, 25, 15)]
        pts.append({"lat": "bad", "lng": 1})
        r = self.ca.post("%s/journey/%d/location" % (V, j.id), {"points": pts},
                         format="json").json()
        self.assertEqual(r["accepted"], 3)
        j.refresh_from_db()
        self.assertEqual(j.points.count(), 3)
        ats = list(j.points.values_list("at", flat=True))
        self.assertEqual(ats, sorted(ats))
        self.assertEqual(j.last_location["at"], (now - timedelta(minutes=5)).isoformat())
        self.assertEqual((j.last_location["acc"], j.last_location["src"]), (9, "bg"))


class RequestLocationTests(Base):
    def setUp(self):
        super().setUp()
        self.ba = edge(self.b, self.a)              # Mother -> Rina

    def ask(self, start_in=0, hours=2, **kw):
        now = timezone.now()
        body = {"member_id": self.ba.id, "kind": "location",
                "start": (now + timedelta(minutes=start_in)).isoformat(),
                "end": (now + timedelta(minutes=start_in, hours=hours)).isoformat()}
        body.update(kw)
        return self.cb.post(U, body, format="json")

    def act(self, client, rid, action):
        return client.post("%s/%d/%s" % (U, rid, action), {}, format="json")

    def test_consent_states_pending_declined_accepted(self):
        r = self.ask(start_in=30)
        self.assertEqual(r.status_code, 201, r.content)
        rid = r.json()["id"]
        asked = [c for c in self.spy.to(self.a) if c["data"].get("event") == "asked"]
        self.assertIn("Live Location", asked[0]["ten"])
        inc = self.ca.get(U).json()["incoming"][0]
        self.assertEqual((inc["kind"], inc["late_tail_min"], inc["late_note"]),
                         ("location", 0, ""))
        # pending: nothing is shared, and the requester cannot start it
        self.assertFalse(Journey.objects.filter(traveller=self.a).exists())
        self.assertEqual(self.act(self.cb, rid, "start").status_code, 403)
        self.assertEqual(self.act(self.ca, rid, "decline").status_code, 200)
        self.assertEqual(JourneyRequest.objects.get(pk=rid).status, "declined")
        self.assertFalse(Journey.objects.filter(traveller=self.a).exists())

    def test_accepted_runs_visible_stoppable_and_ends_exactly_on_time(self):
        rid = self.ask().json()["id"]
        self.assertEqual(self.act(self.ca, rid, "accept").status_code, 200)
        self.act(self.ca, rid, "start")
        req = JourneyRequest.objects.get(pk=rid)
        j = req.journey
        self.assertIsNotNone(j)
        self.assertTrue(SL.is_share(j))
        self.assertEqual(j.stop_alert_min, 0)
        g = self.ca.get("%s/journey/active" % V).json()["guardian"]   # always visible
        self.assertEqual(g["name"], "Mother")
        self.assertEqual(GJ.hard_end(req, j), req.window_end)          # no late tail
        self.fix(j, 1.3521, 103.8198)                                  # abroad (Singapore)
        out = self.cb.get(U).json()["outgoing"][0]
        self.assertAlmostEqual(out["live"]["lat"], 1.3521, places=3)
        JW.sweep(now=req.window_end + timedelta(seconds=30))
        req.refresh_from_db()
        j.refresh_from_db()
        self.assertEqual((req.outcome, j.status), ("window_end", "stopped"))
        self.assertFalse(JourneyEvent.objects.filter(journey=j, kind="overdue_alert").exists())

    def test_traveller_stops_any_time(self):
        rid = self.ask().json()["id"]
        self.act(self.ca, rid, "accept")
        self.act(self.ca, rid, "start")
        self.assertEqual(self.act(self.ca, rid, "stop").status_code, 200)
        req = JourneyRequest.objects.get(pk=rid)
        self.assertEqual(req.outcome, "stopped_by_traveller")
        self.assertTrue(any(c["data"].get("event") == "stopped" for c in self.spy.to(self.b)))

    def test_location_only_is_never_standing(self):
        r = self.ask(standing=True, minor_declared=True,
                     schedule={"days": ["sun"], "start": "07:00", "end": "14:00"})
        self.assertEqual(r.status_code, 400)


class WhereNowTests(Base):
    def test_watcher_sees_live_rows_only_stranger_nothing(self):
        r = self.ca.post("%s/journey/start" % V,
                         {"share_minutes": 60, "watcher_ids": [self.ab.id]}, format="json")
        j = Journey.objects.get(pk=r.json()["id"])
        self.ca.post("%s/journey/%d/location" % (V, j.id),
                     {"lat": 23.75, "lng": 90.39, "acc": 15, "battery": 70}, format="json")
        rows = self.cb.get("%s/journey/where-now" % V).json()["people"]
        self.assertEqual(len(rows), 1)
        self.assertEqual((rows[0]["kind"], rows[0]["name"], rows[0]["acc_m"], rows[0]["battery"]),
                         ("share", "Rina", 15, 70))
        self.assertLess(rows[0]["fix_age_s"], 60)
        self.assertEqual(self.cc.get("%s/journey/where-now" % V).json()["people"], [])
        JW.sweep(now=j.eta + timedelta(minutes=1))
        self.assertEqual(self.cb.get("%s/journey/where-now" % V).json()["people"], [])


@override_settings(MEDIA_ROOT=_MEDIA)
class ChildSchoolTests(Base):
    def setUp(self):
        super().setUp()
        self.dad = kmk("01711300001", "Abba")
        self.mom = kmk("01711300002", "Ammu")
        self.kid = kmk("01711300003", "Rafi")
        pair_circle(self.dad, self.mom)
        pair_circle(self.dad, self.kid)
        pair_circle(self.kid, self.mom)
        from core.tests_journey100 import cl
        self.cd = cl(self.dad)

    def plan(self, **kw):
        body = dict(CFG, child_user_id=self.kid.id, watcher_ids=[self.mom.id])
        body.update(kw)
        return self.cd.post(V + "/school-mode/plans", body, format="json")

    def test_holidays_validated_and_no_school_on_a_holiday(self):
        self.assertEqual(SM.clean_holidays(["2026-11-03", "2026-11-03", "2026-11-01"]),
                         ["2026-11-01", "2026-11-03"])
        with self.assertRaises(ValueError):
            SM.clean_holidays(["3 Nov"])
        cfg = SM.validate(dict(CFG, holidays=["2026-11-01"]))
        self.assertFalse(SM.is_school_day(cfg, L(1, 8, 0)))        # Sunday, a holiday
        self.assertTrue(SM.is_school_day(cfg, L(2, 8, 0)))
        day, ev = SM.on_tick(cfg, {}, L(1, 9, 0), phone=True)
        self.assertEqual(ev, [])                                   # no late alert
        r = self.plan(holidays=["2026-11-01", "bad"])
        self.assertEqual(r.json()["reason"], "bad_holiday")
        r = self.plan(holidays=["2026-11-01"])
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(r.json()["plan"]["config"]["holidays"], ["2026-11-01"])

    def test_two_parents_many_children_on_with_safe_journey(self):
        self.assertEqual(self.plan().status_code, 201)
        kid2 = kmk("01711300004", "Mim")
        pair_circle(self.dad, kid2)
        self.assertEqual(self.plan(child_user_id=kid2.id).status_code, 201)
        plans = self.cd.get(V + "/school-mode/plans").json()["plans"]
        self.assertEqual(len(plans), 2)
        from core.tests_journey100 import cl
        seen = cl(self.mom).get(V + "/school-mode/plans").json()["plans"]
        self.assertEqual(len(seen), 2)                              # the other parent

    def test_phone_fixes_drive_the_plan(self):
        pid = self.plan().json()["plan"]["id"]
        p = SchoolPlan.objects.get(pk=pid)
        # not accepted by the child yet: nothing happens
        at = L(1, 7, 50)
        self.assertEqual(SL.feed_school(self.kid, [(at, SCHOOL[0], SCHOOL[1], 60, "app", 10)],
                                        now=at), 0)
        p.accepted_at = timezone.now()
        p.save()
        n = SL.feed_school(self.kid, [(at - timedelta(minutes=20), K_HOME[0], K_HOME[1],
                                       60, "app", 10),
                                      (at, SCHOOL[0], SCHOOL[1], 60, "app", 10)], now=at)
        self.assertGreaterEqual(n, 1)
        p.refresh_from_db()
        self.assertEqual(p.day["state"], "at_school")
        self.assertIsNotNone(p.day["arrived_school_at"])
        # a rough fix never moves the state machine
        p2 = SchoolPlan.objects.get(pk=pid)
        p2.day = {}
        p2.save()
        self.assertEqual(SL.feed_school(self.kid, [(at, SCHOOL[0], SCHOOL[1], 60, "app", 900)],
                                        now=at), 0)
        rows = SL.where_now(self.dad, now=at + timedelta(minutes=1))
        self.assertTrue(any(r["kind"] == "school" and r["name"] == "Rafi" for r in rows))

    def test_gate_camera_only_through_the_cctv_seam(self):
        from core.models import ShopCamera, ShopEvent, ShopSite
        other = ShopSite.objects.create(owner=self.mom, name="Not mine", enrollment_token="s-x")
        cam_x = ShopCamera.objects.create(site=other, name="X", camera_token="c-x")
        self.assertEqual(self.plan(gate_camera_id=cam_x.id).json()["reason"], "camera_not_found")
        pid = self.plan().json()["plan"]["id"]
        # no camera linked -> hidden (404 no_camera)
        r = self.cd.get(V + "/school-mode/plans/%d/gate-snapshot" % pid)
        self.assertEqual(r.status_code, 404)
        site = ShopSite.objects.create(owner=self.dad, name="Gate", enrollment_token="s-1")
        cam = ShopCamera.objects.create(site=site, name="School gate", camera_token="c-1")
        r = self.cd.patch(V + "/school-mode/plans/%d" % pid, {"gate_camera_id": cam.id},
                          format="json")
        self.assertEqual(r.status_code, 200, r.content)
        p = SchoolPlan.objects.get(pk=pid)
        arrived = L(1, 7, 55)
        p.day = {"date": "2026-11-01", "arrived_school_at": arrived.isoformat()}
        p.save()
        r = self.cd.get(V + "/school-mode/plans/%d/gate-snapshot?event=arrived_school" % pid)
        self.assertEqual(r.json()["reason"], "no_snapshot")
        ev = ShopEvent.objects.create(site=site, camera=cam, type="person")
        ev.snapshot.save("gate.jpg", ContentFile(b"\xff\xd8\xff\xd9"), save=True)
        ShopEvent.objects.filter(pk=ev.pk).update(created=arrived + timedelta(minutes=3))
        far = ShopEvent.objects.create(site=site, camera=cam, type="person")
        far.snapshot.save("far.jpg", ContentFile(b"\xff\xd8\xff\xd9"), save=True)
        ShopEvent.objects.filter(pk=far.pk).update(created=arrived + timedelta(hours=2))
        r = self.cd.get(V + "/school-mode/plans/%d/gate-snapshot?event=arrived_school" % pid)
        self.assertEqual(r.status_code, 200, r.content)
        self.assertIn("gate", r.json()["url"])
        # the other parent (a watcher) sees it too; a stranger never
        from core.tests_journey100 import cl
        self.assertEqual(cl(self.mom).get(
            V + "/school-mode/plans/%d/gate-snapshot" % pid).status_code, 200)
        self.assertEqual(self.cc.get(
            V + "/school-mode/plans/%d/gate-snapshot" % pid).status_code, 404)
        self.assertEqual(self.cd.get(
            V + "/school-mode/plans/%d/gate-snapshot?event=x" % pid).status_code, 400)


class PureTests(Base):
    def test_share_minutes_bounds(self):
        self.assertEqual([SL.share_minutes(x) for x in (60, "180", 14, 1441, "x", None)],
                         [60, 180, None, None, None, None])

    def test_where_now_is_mocked_clock_safe(self):
        with mock.patch("core.sj_live.timezone.now", return_value=timezone.now()):
            self.assertEqual(SL.where_now(self.c), [])
