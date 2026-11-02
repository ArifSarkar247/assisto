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



# ------------------------------------------------- 2. honest "no location"
class LostReasonTests(GBase):
    """When fixes stop, watchers get the LIKELY reason, never a guess
    dressed as fact: flat battery, the phone killed Assisto in the
    background, or (unknown) the generic line."""

    def post(self, j, **p):
        return self.ca.post("%s/journey/%d/location" % (V, j.id), p, format="json")

    def lost_push(self):
        return [c for c in self.spy.to(self.b) if c["data"].get("event") == "signal_lost"]

    def test_flat_battery_reason(self):
        j, _ = self.start(eta_min=120)
        self.post(j, lat=23.77, lng=90.39, battery=4, src="app")
        JW.sweep(now=timezone.now() + timedelta(minutes=JW.LOST_FIX_MIN + 1))
        ev = self.events(j, "signal_lost")
        self.assertEqual((ev[0].payload["why"], ev[0].payload["battery"]), ("battery", 4))
        p = self.lost_push()[0]
        self.assertIn("৪%", p["bbn"])                # Bangla digits in Bangla
        self.assertIn("4%", p["ben"])
        self.assertNotIn("4%", p["bbn"])            # never an English digit there

    def test_killed_in_background_reason_and_last_known_battery(self):
        j, _ = self.start(eta_min=120)
        self.post(j, lat=23.77, lng=90.39, battery=50, src="app")
        self.post(j, lat=23.771, lng=90.391, src="bg")     # service alone, no battery
        j.refresh_from_db()
        self.assertEqual(j.last_location["src"], "bg")
        self.assertIsNone(j.last_location["battery"])
        self.assertEqual(j.last_location["battery_last"], 50)
        later = timezone.now() + timedelta(minutes=JW.LOST_FIX_MIN + 1)
        JW.sweep(now=later)
        self.assertEqual(self.events(j, "signal_lost")[0].payload["why"], "killed")
        self.assertIn("battery saver", self.lost_push()[0]["ben"])
        # the watcher page says it too, with the last KNOWN battery
        from web.views_journey import public_state
        d, _st = public_state(JW.web_token(j), now=later)
        self.assertEqual((d["state"], d["why"], d["battery_last"]), ("lost", "killed", 50))

    def test_unknown_reason_stays_generic(self):
        j, _ = self.start(eta_min=120)
        self.post(j, lat=23.77, lng=90.39, battery=60, src="app")
        JW.sweep(now=timezone.now() + timedelta(minutes=JW.LOST_FIX_MIN + 1))
        self.assertNotIn("why", self.events(j, "signal_lost")[0].payload)
        self.assertIn("battery saver or offline", self.lost_push()[0]["ben"])
        self.assertFalse(self.lost_push()[0]["high"])          # calm, not an alarm
        self.assertNotIn("http", self.lost_push()[0]["ben"])  # buttons, not raw links

    def test_junk_src_is_ignored(self):
        j, _ = self.start(eta_min=120)
        self.post(j, lat=23.77, lng=90.39, src="<script>")
        j.refresh_from_db()
        self.assertNotIn("src", j.last_location)


# ------------------------------------------------- 3. ETA from real speed
class SpeedEtaTests(GBase):
    def test_observed_speed_ignores_gps_jumps(self):
        from core.logic import journey_dest as JD
        t = timezone.now()
        pts = [(23.750 + k * 0.0005, 90.39, t + timedelta(seconds=30 * k)) for k in range(10)]
        kmh = JD.observed_kmh(pts)
        self.assertAlmostEqual(kmh, 6.7, delta=0.5)             # ~55 m / 30 s
        jumpy = list(pts)
        jumpy[4] = (23.80, 90.45, jumpy[4][2])                  # a 7 km jump
        self.assertAlmostEqual(JD.observed_kmh(jumpy), kmh, delta=2.5)
        self.assertIsNone(JD.observed_kmh(pts[:2]))             # too little data
        self.assertEqual(JD.eta_minutes(5000, "cng", None)[1], "typical")
        self.assertEqual(JD.eta_minutes(5000, "cng", 0.5)[1], "typical")   # standing

    def test_jam_makes_the_time_longer_and_says_why(self):
        j, _ = self.start(eta_min=120, mode="cng")
        t = timezone.now() - timedelta(minutes=5)
        pts = [{"lat": 23.7550 + k * 0.0004, "lng": 90.4000,
                "at": (t + timedelta(seconds=30 * k)).isoformat()} for k in range(10)]
        self.ca.post("%s/journey/%d/location" % (V, j.id), {"points": pts}, format="json")
        from core.logic import journey_dest as JD
        j.refresh_from_db()
        p = JW.progress(j)
        self.assertEqual(p["eta_basis"], "speed")
        self.assertGreater(p["rough_min"], JD.rough_minutes(p["distance_m"], "cng"))
        from web.views_journey import public_state
        d, _st = public_state(JW.web_token(j))
        self.assertEqual(d["eta_basis"], "speed")


# ------------------------------- 4. replayed Dhaka trip: false-alarm count
MIRPUR10 = {"name": "Mirpur 10", "lat": 23.8069, "lng": 90.3687}
MOTIJHEEL = {"name": "Motijheel", "lat": 23.7330, "lng": 90.4172}
ROAD = [(23.8069, 90.3687), (23.7781, 90.3800), (23.7650, 90.3890), (23.7570, 90.3900),
        (23.7510, 90.3930), (23.7380, 90.3960), (23.7350, 90.4120), (23.7335, 90.4160)]


def _trace(per_leg=6):
    out = []
    for a, b in zip(ROAD, ROAD[1:]):
        for k in range(per_leg):
            f = k / float(per_leg)
            out.append((a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f))
    return out


class DhakaReplayTests(GBase):
    """A real road from Mirpur 10 to Motijheel (bends via Farmgate and
    Shahbag), a fix every 30 s, swept after every fix like the minute cron.
    Counts false alarms: off-route with the switch ON, plus one GPS jump."""

    def replay(self, trace, j, t0):
        for k, (lat, lng) in enumerate(trace):
            at = t0 + timedelta(seconds=30 * k)
            self.ca.post("%s/journey/%d/location" % (V, j.id),
                         {"points": [{"lat": lat, "lng": lng, "at": at.isoformat()}]},
                         format="json")
            JW.sweep(now=at + timedelta(seconds=5))
        return t0 + timedelta(seconds=30 * len(trace))

    def test_no_false_off_route_on_the_real_road_even_with_a_gps_jump(self):
        j, _ = self.start(eta_min=180, origin=MIRPUR10, destination=MOTIJHEEL,
                          route_deviation_on=True)
        trace = _trace()
        trace[20:20] = [(23.80, 90.43)]                         # one multipath jump ~5 km
        t0 = timezone.now() - timedelta(minutes=30)
        self.replay(trace[:-3], j, t0)                          # stop before the pin
        self.assertEqual(self.events(j, "off_route"), [])       # 0 false alarms
        self.assertEqual(self.events(j, "long_stop"), [])

    def test_a_real_wrong_turn_is_caught_within_two_fixes(self):
        j, _ = self.start(eta_min=180, origin=MIRPUR10, destination=MOTIJHEEL,
                          route_deviation_on=True)
        t0 = timezone.now() - timedelta(minutes=30)
        t1 = self.replay(_trace()[:10], j, t0)
        self.replay([(23.80, 90.43), (23.801, 90.431)], j, t1)
        self.assertEqual(len(self.events(j, "off_route")), 1)

    def test_crawling_jam_is_not_a_long_stop(self):
        j, _ = self.start(eta_min=180, origin=MIRPUR10, destination=MOTIJHEEL)
        t0 = timezone.now() - timedelta(minutes=30)
        # 25 minutes at ~1.3 km/h (11 m per 30 s) — Farmgate at rush hour
        jam = [(23.7570 - k * 0.0001, 90.3900) for k in range(50)]
        self.replay(jam, j, t0)
        self.assertEqual(self.events(j, "long_stop"), [])


# --------------------------------------- 5. strict bn / en server texts
class ServerTextLanguageTests(GBase):
    """Every watcher push in Bangla has Bangla digits and no English words
    (brand/PIN/SOS and links excepted); every English one has no Bangla."""
    KINDS = [("started", {}), ("arrived", {}), ("extended", {"minutes": 15}),
             ("low_battery", {"battery": 12}), ("overdue_alert", {"minutes": 25}),
             ("ok_again", {}), ("off_route", {"meters": 3500}),
             ("long_stop", {"minutes": 21}), ("signal_lost", {"minutes": 16}),
             ("signal_lost", {"minutes": 16, "why": "battery", "battery": 4}),
             ("signal_lost", {"minutes": 16, "why": "killed"}),
             ("ended", {}), ("duress", {})]
    ALLOWED = {"Assisto", "PIN", "SOS"}

    def test_every_event_text_is_one_language(self):
        import re
        # a pin without a typed name: the user's own words are data, not UI
        j, _ = self.start(eta_min=40, destination={"lat": 23.80, "lng": 90.40})
        loc = {"lat": 23.7712, "lng": 90.3991, "url": "https://lifeassisto.com/j/x"}
        for kind, p in self.KINDS:
            payload = {**loc, **p}
            tbn, bbn = JW.event_text(kind, j, "রিনা", "bn", payload)
            ten, ben = JW.event_text(kind, j, "Rina", "en", payload)
            bn = re.sub(r"https?://\S+", "", tbn + " " + bbn)
            words = set(re.findall(r"[A-Za-z]+", bn)) - self.ALLOWED
            self.assertEqual(words, set(), (kind, p, bn))
            self.assertNotRegex(bn, r"[0-9]", (kind, p, bn))
            en = re.sub(r"https?://\S+", "", ten + " " + ben)
            self.assertNotRegex(en, r"[ঀ-৿]", (kind, p, en))


class WatchingViewReasonTests(GBase):
    def test_watcher_list_carries_reason_and_last_known_battery(self):
        j, _ = self.start(eta_min=120)
        old = timezone.now() - timedelta(minutes=JW.LOST_FIX_MIN + 5)
        self.ca.post("%s/journey/%d/location" % (V, j.id), {"points": [
            {"lat": 23.77, "lng": 90.39, "battery": 41, "src": "app",
             "at": (old - timedelta(minutes=1)).isoformat()},
            {"lat": 23.771, "lng": 90.391, "src": "bg", "at": old.isoformat()}]},
            format="json")
        w = self.cb.get("%s/journey/watching" % V).json()["journeys"][0]
        self.assertEqual((w["why"], w["battery_last"]), ("killed", 41))
        self.assertIsNone(w["battery"])
        self.assertIn(w["eta_basis"], ("speed", "typical"))


# ------------- 6. owner's real trip (2 Nov): jam on the Dhaka–Gazipur road
ABDULLAHPUR = {"name": "Abdullahpur", "lat": 23.8795, "lng": 90.4003}
GAZIPUR = {"name": "Gazipur", "lat": 24.0020, "lng": 90.4200}
HIGHWAY = [(23.8795, 90.4003), (23.8900, 90.4040), (23.8990, 90.4070), (23.9200, 90.4000)]


def _path(points, step_m=250):
    """Interpolate a polyline every ~step_m metres (30 s apart = ~30 km/h)."""
    from core.logic.safety import haversine_m
    out = []
    for a, b in zip(points, points[1:]):
        n = max(1, int(haversine_m(a[0], a[1], b[0], b[1]) // step_m))
        for k in range(n):
            f = k / float(n)
            out.append((a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f))
    out.append(points[-1])
    return out


class TrafficJamTests(GBase):
    """Recorded-shape traces: a bus stuck in a jam on the highway vs a stop
    at an unknown place off the route vs a stop after walking."""

    def go(self, j, trace, t0, every_s=30):
        at = t0
        for lat, lng in trace:
            self.ca.post("%s/journey/%d/location" % (V, j.id),
                         {"points": [{"lat": lat, "lng": lng, "at": at.isoformat()}]},
                         format="json")
            JW.sweep(now=at + timedelta(seconds=5))
            at += timedelta(seconds=every_s)
        return at

    def stand(self, j, spot, t0, minutes):
        # GPS jitter of a few metres, one fix a minute
        pts = [(spot[0] + (0.00002 if k % 2 else -0.00002), spot[1]) for k in range(minutes)]
        return self.go(j, pts, t0, every_s=60)

    def trip(self):
        j, _ = self.start(eta_min=240, origin=ABDULLAHPUR, destination=GAZIPUR,
                          stop_alert_min=20, mode="bus")
        Journey.objects.filter(pk=j.pk).update(created_at=timezone.now() - timedelta(hours=3))
        j.refresh_from_db()
        return j, timezone.now() - timedelta(hours=2)

    def test_jam_on_the_highway_is_not_a_stop_at_23_minutes(self):
        j, t0 = self.trip()
        t1 = self.go(j, _path(HIGHWAY), t0)                 # ~30 km/h for ~10 min
        t2 = self.stand(j, HIGHWAY[-1], t1, 30)             # stuck 30 min on the road
        self.assertEqual(self.events(j, "long_stop"), [])   # the owner's false alert: gone
        self.stand(j, HIGHWAY[-1], t2, 17)                  # 47 min: calm notice
        ev = self.events(j, "long_stop")
        self.assertEqual(len(ev), 1)
        self.assertTrue(ev[0].payload["jam"])
        p = [c for c in self.spy.to(self.b) if c["data"].get("event") == "long_stop"][0]
        self.assertIn("traffic", p["ben"])
        self.assertIn("যানজটে", p["bbn"])
        self.assertFalse(p["high"])
        from core.models import FamilyAlert
        self.assertFalse(FamilyAlert.objects.filter(user=self.b, kind="journey",
                                                    payload__event="long_stop").exists())

    def test_stop_at_an_unknown_place_off_the_route_still_alerts_at_20(self):
        j, t0 = self.trip()
        t1 = self.go(j, _path(HIGHWAY + [(23.9400, 90.4500)]), t0)   # turns 4 km off
        self.stand(j, (23.9400, 90.4500), t1, 22)
        ev = self.events(j, "long_stop")
        self.assertEqual(len(ev), 1)
        self.assertNotIn("jam", ev[0].payload)
        p = [c for c in self.spy.to(self.b) if c["data"].get("event") == "long_stop"][0]
        self.assertTrue(p["high"])

    def test_stop_after_walking_on_the_route_alerts_at_20(self):
        j, _ = self.start(eta_min=240, origin=ABDULLAHPUR, destination=GAZIPUR,
                          stop_alert_min=20)
        Journey.objects.filter(pk=j.pk).update(created_at=timezone.now() - timedelta(hours=3))
        t0 = timezone.now() - timedelta(hours=2)
        walk = _path(HIGHWAY[:2], step_m=40)                # ~5 km/h
        t1 = self.go(j, walk, t0)
        self.stand(j, HIGHWAY[1], t1, 22)
        self.assertEqual(len(self.events(j, "long_stop")), 1)

    def test_push_text_has_no_raw_links_but_data_has_them(self):
        j, t0 = self.trip()
        self.stand(j, HIGHWAY[0], t0, 1)
        Journey.objects.filter(pk=j.pk).update(stop_alert_min=0)
        JW.emit(Journey.objects.get(pk=j.pk), "low_battery", key="5",
                payload={"battery": 5, "lat": 23.88, "lng": 90.40})
        p = [c for c in self.spy.to(self.b) if c["data"].get("event") == "low_battery"][0]
        self.assertNotIn("http", p["ben"] + p["bbn"])
        self.assertTrue(p["data"]["url"].startswith("http"))
        self.assertEqual(p["data"]["lat"], 23.88)


class AdminAlertsSeparateTests(GBase):
    """Owner 2 Nov: server/ops alerts (disk 80 %) never sit among family
    alerts — only in the owner's Admin tab (type "admin")."""

    def test_ops_alert_is_admin_only_and_never_a_family_alert(self):
        from core import push
        from core.models import FamilyAlert, NotifEvent
        self.b.is_superuser = True
        self.b.is_staff = True
        self.b.save()
        with mock.patch.object(push, "is_available", return_value=False):
            push.notify_owner("Disk 80%", "Disk is 80% full")
            push.notify_owner("Disk 80%", "Disk is 80% full")      # no duplicate row
        rows = NotifEvent.objects.filter(type="admin", title_en="Disk 80%")
        self.assertEqual(list(rows.values_list("user_id", flat=True)), [self.b.pk])
        FamilyAlert.objects.create(user=self.b, kind="disk_alert", title="Disk",
                                   body="full", payload={"source": "uptime_check"})
        FamilyAlert.objects.create(user=self.b, kind="journey", title="Late",
                                   body="Rina is late", payload={})
        feed = self.cb.get("%s/notif/feed" % V).data["items"]
        disk = [i for i in feed if (i.get("title") or {}).get("en") in ("Disk", "Disk 80%")]
        self.assertTrue(disk)
        self.assertTrue(all(i["type"] == "admin" for i in disk))
        self.assertTrue(any(i["type"] != "admin" and (i.get("title") or {}).get("en") == "Late"
                            for i in feed))
        alerts = self.cb.get("%s/alerts" % V).data
        self.assertFalse(any(a.get("type") == "disk_alert" for a in alerts))
        # a normal account never gets them at all
        self.assertFalse(NotifEvent.objects.filter(user=self.a, type="admin").exists())
