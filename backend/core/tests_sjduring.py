"""sjduring — Safe Journey V2 DURING the trip (owner order 9 Nov 11:15).

Pure rules (states, ladder, radius by place type, dwell, PIN need, night),
the ORM glue on fake-GPS journeys (normal trip, route change + extend, tea
stop near the destination, impossible early arrival, danger PIN silent red,
two journeys at once, phone off honest reason, night check-ins), the watcher
board, and a CORPUS of simulated journeys (traffic, tea stops, detours, late
but moving) that measures the false-alert rate against the old rules.
All places and people are made up."""
import base64
import random
from datetime import timedelta
from math import cos, radians

from django.test import TestCase, override_settings
from django.utils import timezone

from core import journey_during as JDUR
from core import journey_watch as JW
from core.models import (Journey, JourneyEvent, JourneyPoint, JourneyWatcher)
from core.tests_journey100 import Base, cl, edge, mk

V = "/api/v1"
# made-up trip: ~20 km due north (a Badda -> Gazipur style ride)
O = (23.7800, 90.4260)
D = (23.9600, 90.4260)
WATCHER_KINDS = ("check_on", "check_red", "overdue_alert", "long_stop", "off_route",
                 "signal_lost", "fast_pin", "arrival_unusual", "danger_pin")
LATE_KINDS = ("overdue_alert",)


def day0(days=1, hour=9):
    """A fixed DAYTIME start in the past (night rules are tested on their own)."""
    return timezone.localtime(timezone.now() - timedelta(days=days)).replace(
        hour=hour, minute=0, second=0, microsecond=0)


def north(p, m):
    return (p[0] + m / 111320.0, p[1])


def east(p, m):
    return (p[0], p[1] + m / (111320.0 * cos(radians(p[0]))))


# ------------------------------------------------------------------ pure
class PureTests(TestCase):
    def test_radius_by_place_type(self):
        self.assertEqual(JDUR.arrival_radius({"kind": "home"}), 150)
        self.assertEqual(JDUR.arrival_radius({"label": "office"}), 150)
        self.assertEqual(JDUR.arrival_radius({"kind": "airport"}), 400)
        self.assertEqual(JDUR.arrival_radius({"name": "Hazrat Shahjalal International Airport"}), 400)
        self.assertEqual(JDUR.arrival_radius({"name": "মহাখালী বাস টার্মিনাল"}), 400)
        self.assertEqual(JDUR.arrival_radius({"name": "Kamalapur Railway Station"}), 400)
        self.assertEqual(JDUR.arrival_radius({"name": "সদরঘাট লঞ্চ ঘাট"}), 400)
        self.assertEqual(JDUR.arrival_radius({"name": "Sample University"}), 400)
        self.assertEqual(JDUR.arrival_radius({"name": "Aunt's house"}), 150)

    def test_dwell_needs_two_minutes_inside(self):
        t = timezone.now()
        inside = north(D, -50)
        pts = [(*north(D, -900), t), (*inside, t + timedelta(seconds=60)),
               (*inside, t + timedelta(seconds=150))]
        self.assertEqual(JDUR.dwell(pts, D, 150), (False, 90))
        pts.append((*inside, t + timedelta(seconds=185)))
        ok, s = JDUR.dwell(pts, D, 150)
        self.assertTrue(ok)
        self.assertEqual(s, 125)
        # one lucky GPS jump at the end never arrives
        self.assertFalse(JDUR.dwell([(*north(D, -3000), t), (*D, t + timedelta(seconds=300))],
                                    D, 150)[0])

    def test_earliest_possible(self):
        t = timezone.now()
        c = JDUR.earliest_possible(O, D, "car", t)
        self.assertGreater(c, t + timedelta(minutes=10))     # 20 km at 100 km/h = 12 min
        given = t + timedelta(minutes=55)
        self.assertEqual(JDUR.earliest_possible(O, D, "car", t, given), given)
        self.assertIsNone(JDUR.earliest_possible(None, D, "car", t))

    def kw(self, **k):
        base = dict(status="active", fix_age_min=0.5, lost_min=15, still_min=0, dist_m=8000,
                    off_route=False, speed_kmh=20, mode="local_bus")
        base.update(k)
        return base

    def test_states(self):
        c = JDUR.classify
        self.assertEqual(c(**self.kw())["state"], "moving")
        self.assertEqual(c(**self.kw(speed_kmh=4))["state"], "slow")
        self.assertEqual(c(**self.kw(still_min=12, speed_kmh=18))["state"], "slow")   # jam
        self.assertEqual(c(**self.kw(still_min=12, speed_kmh=3, mode="walk"))["state"], "stopped")
        self.assertEqual(c(**self.kw(off_route=True))["state"], "off_route")
        self.assertEqual(c(**self.kw(dist_m=800))["state"], "nearly")
        st = c(**self.kw(dist_m=800, still_min=20))
        self.assertEqual((st["state"], st["stopped_min"]), ("nearly", 20))
        st = c(**self.kw(fix_age_min=20, battery=4, lost_why="battery"))
        self.assertEqual((st["state"], st["battery"], st["why"]), ("phone_off", 4, "battery"))
        self.assertEqual(c(**self.kw(status="arrived"))["state"], "arrived")

    def test_late_while_moving_never_asks(self):
        for s in ("moving", "slow", "nearly", "phone_off"):
            self.assertFalse(JDUR.late_alert_allowed({"state": s}))
        self.assertTrue(JDUR.late_alert_allowed({"state": "stopped"}))

    def test_ladder_ask_amber_red(self):
        t = timezone.now()
        sig = {"kind": "long_stop", "key": "k1"}
        acts, d = JDUR.ladder({}, sig, t)
        self.assertEqual([a[0] for a in acts], ["ask"])
        acts, d = JDUR.ladder(d, sig, t + timedelta(minutes=4))
        self.assertEqual(acts, [])
        acts, d = JDUR.ladder(d, sig, t + timedelta(minutes=5))
        self.assertEqual([a[0] for a in acts], ["amber"])
        acts, d = JDUR.ladder(d, sig, t + timedelta(minutes=14))
        self.assertEqual(acts, [])
        acts, d = JDUR.ladder(d, sig, t + timedelta(minutes=15))
        self.assertEqual([a[0] for a in acts], ["red"])
        acts, d = JDUR.ladder(d, sig, t + timedelta(minutes=40))
        self.assertEqual(acts, [])                       # never twice
        self.assertIn("long_stop", d["abnormal"])

    def test_answer_stops_ladder_and_no_reask_same_signal(self):
        t = timezone.now()
        sig = {"kind": "off_route", "key": "e1"}
        _a, d = JDUR.ladder({}, sig, t)
        d, amber = JDUR.answer_ask(d, "extend", t + timedelta(minutes=2))
        self.assertFalse(amber)
        for m in (6, 20, 60):
            acts, d = JDUR.ladder(d, sig, t + timedelta(minutes=m))
            self.assertEqual(acts, [])

    def test_signal_gone_before_amber_closes_quietly(self):
        t = timezone.now()
        _a, d = JDUR.ladder({}, {"kind": "long_stop", "key": "x"}, t)
        acts, d = JDUR.ladder(d, None, t + timedelta(minutes=3))   # bus moved on
        self.assertEqual(acts, [])
        acts, d = JDUR.ladder(d, None, t + timedelta(minutes=10))
        self.assertEqual(acts, [])
        self.assertEqual(d["ask"]["answered"], "cleared")

    def test_phone_off_amber_at_once_red_only_with_good_battery(self):
        t = timezone.now()
        good = {"kind": "phone_off", "key": "f", "good_batt": True}
        acts, d = JDUR.ladder({}, good, t)
        self.assertEqual([a[0] for a in acts], ["amber"])
        acts, d = JDUR.ladder(d, good, t + timedelta(minutes=10))
        self.assertEqual([a[0] for a in acts], ["red"])
        low = {"kind": "phone_off", "key": "g", "good_batt": False, "battery": 3}
        acts, d = JDUR.ladder({}, low, t)
        acts2, d = JDUR.ladder(d, low, t + timedelta(minutes=60))
        self.assertEqual(([a[0] for a in acts], acts2), (["amber"], []))
        acts, d = JDUR.ladder(d, None, t + timedelta(minutes=61))   # back
        self.assertEqual([a[0] for a in acts], ["back"])

    def test_night_checkin_alone_never_alerts(self):
        t = timezone.now()
        sig = {"kind": "night_checkin", "key": "n1"}
        _a, d = JDUR.ladder({}, sig, t)
        for m in (5, 15, 29):
            acts, d = JDUR.ladder(d, sig, t + timedelta(minutes=m))
            self.assertEqual(acts, [])
        acts, d = JDUR.ladder(d, {"kind": "long_stop", "key": "s"}, t + timedelta(minutes=30))
        self.assertEqual([a[0] for a in acts], ["ask"])

    def test_night_hours(self):
        n = timezone.now().replace(hour=23)
        self.assertTrue(JDUR.is_night(n))
        self.assertTrue(JDUR.is_night(n.replace(hour=5)))
        self.assertFalse(JDUR.is_night(n.replace(hour=6)))
        self.assertFalse(JDUR.is_night(n.replace(hour=21)))

    def test_pin_needed(self):
        self.assertEqual(JDUR.pin_needed({}, always=False, too_early=False), [])
        self.assertEqual(JDUR.pin_needed({}, always=True, too_early=False), ["always"])
        self.assertEqual(JDUR.pin_needed({"abnormal": ["off_route"]}, always=False,
                                         too_early=True), ["too_early", "off_route"])


# ------------------------------------------------------------- ORM / sim
class Sim(Base):
    """Drives a journey minute by minute with fake GPS, exactly like the
    location view + the every-minute sweeper do."""

    def mkj(self, traveller=None, member=None, eta_min=80, mode="local_bus",
            start=None, dest=None, origin=None, **kw):
        traveller = traveller or self.a
        start = start or (timezone.now() - timedelta(hours=6))
        dest = dest or {"name": "Sample Chowrasta", "lat": D[0], "lng": D[1]}
        j = Journey.objects.create(
            traveller=traveller, origin=origin or {"lat": O[0], "lng": O[1]},
            destination=dest, eta=start + timedelta(minutes=eta_min), mode=mode,
            vehicle={"mode": mode}, overdue_grace_min=10, response_window_min=10,
            stop_alert_min=20, expires_at=start + timedelta(hours=48), **kw)
        Journey.objects.filter(pk=j.pk).update(created_at=start)
        JourneyWatcher.objects.create(journey=j, member=member or self.ab)
        return Journey.objects.get(pk=j.pk)

    def step(self, j, t, p, battery=80, sweep=True):
        if p is not None:
            JourneyPoint.objects.create(journey=j, lat=p[0], lng=p[1], battery=battery, at=t)
            JW.on_location(j, p[0], p[1], t, battery, now=t)
            j.last_location = JW.location_row(j.last_location, p[0], p[1], t, battery, "app")
            j.save()
            if j.status == "active" and JDUR.enabled(j):
                if JDUR.auto_arrival(j, t, 10) == "arrived":
                    JW.on_arrived(j, t)
                    j.save()
                    return j
            elif j.status == "active":
                ok, _d = JW.SJ.arrival_check({"destination": j.destination,
                                              "arrival_radius_m": j.arrival_radius_m}, p[0], p[1])
                if ok:
                    JW.on_arrived(j, t)
                    j.save()
                    return j
        if sweep and j.status == "active":
            JW._sweep_journey(j, t, __import__("collections").Counter())
        return Journey.objects.get(pk=j.pk)

    def watcher_events(self, j, kinds=WATCHER_KINDS):
        return list(JourneyEvent.objects.filter(journey=j, kind__in=kinds))

    def asks(self):
        return [c for c in self.spy.to(self.a) if c["data"].get("event") == "check_ask"]


class ScenarioTests(Sim):
    def test_normal_trip_arrives_after_dwell_no_alerts(self):
        t0 = day0()
        j = self.mkj(start=t0)
        dist = 20000
        m = 0
        for m in range(0, 70):
            j = self.step(j, t0 + timedelta(minutes=m), north(O, min(dist - 40, m * 300)))
            if j.status != "active":
                break
        self.assertEqual(j.status, "arrived")
        # inside 150 m first at minute ~67; arrived only 2 minutes later
        first_in = next(i for i in range(70) if min(dist - 40, i * 300) >= dist - 150)
        self.assertGreaterEqual(m, first_in + 2)
        self.assertEqual(self.watcher_events(j), [])
        self.assertEqual(self.asks(), [])

    def test_route_change_with_extend_family_sees_only_time_extended(self):
        t0 = day0()
        j = self.mkj(start=t0)
        for m in range(0, 20):
            j = self.step(j, t0 + timedelta(minutes=m), north(O, m * 300))
        # detour 5 km east (outside the 3 km corridor)
        base = north(O, 19 * 300)
        for k, m in enumerate(range(20, 24)):
            j = self.step(j, t0 + timedelta(minutes=m), east(base, 4000 + k * 400))
        self.assertEqual(len(self.asks()), 1)
        self.assertEqual(j.during["ask"]["kind"], "off_route")
        self.assertEqual([c for c in self.spy.to(self.b)], [])     # family does not know
        r = self.ca.get("%s/journey/%d/during" % (V, j.id))
        self.assertEqual(r.json()["ask"]["kind"], "off_route")
        self.assertIsNotNone(r.json()["ask"]["from"])
        self.assertEqual(r.json()["extend_default"], 40)
        r = self.ca.post("%s/journey/%d/answer" % (V, j.id), {"action": "extend", "minutes": 40},
                         format="json")
        self.assertEqual(r.status_code, 200, r.content)
        pb = self.spy.to(self.b)
        self.assertEqual(len(pb), 1)
        self.assertEqual(pb[0]["data"]["event"], "extended")
        self.assertEqual(pb[0]["data"]["lat"], "")              # no place
        self.assertIn("extended", pb[0]["ten"].lower())
        j = Journey.objects.get(pk=j.pk)
        for m in range(24, 40):
            j = self.step(j, t0 + timedelta(minutes=m), east(base, 5200))
        self.assertEqual(self.watcher_events(j), [])            # answered: never amber
        self.assertIn("off_route", j.during["abnormal"])

    def test_tea_stop_near_destination_no_alert_then_ask_traveller_first(self):
        t0 = day0()
        j = self.mkj(start=t0, eta_min=40)          # late by design
        for m in range(0, 64):
            j = self.step(j, t0 + timedelta(minutes=m), north(O, min(19400, m * 300)))
        tea = north(O, 19400)                         # 600 m before, past the ETA
        for m in range(64, 64 + 29):
            j = self.step(j, t0 + timedelta(minutes=m), tea)
        self.assertEqual(self.watcher_events(j), [])
        self.assertEqual(self.asks(), [])
        card = JDUR.board_card(j, self.b, t0 + timedelta(minutes=92))
        self.assertEqual(card["state"], "nearly")
        self.assertTrue(card["near_note"])
        for m in range(93, 98):
            j = self.step(j, t0 + timedelta(minutes=m), tea)
        self.assertEqual(len(self.asks()), 1)          # 30 min: the traveller first
        self.assertEqual(j.during["ask"]["kind"], "near_stop")
        self.assertEqual(self.watcher_events(j), [])

    def test_late_while_moving_is_slow_in_traffic_no_alert(self):
        t0 = day0()
        j = self.mkj(start=t0, eta_min=20)
        for m in range(0, 90):
            j = self.step(j, t0 + timedelta(minutes=m), north(O, m * 110))   # 6.6 km/h crawl
        self.assertEqual(j.during["state"]["state"], "slow")
        self.assertEqual(self.watcher_events(j), [])
        self.assertEqual(self.asks(), [])

    def test_impossible_early_arrival_blocked(self):
        # the owner bug (6 Nov): "arrived" minutes after leaving
        t0 = day0()
        j = self.mkj(start=t0, mode="cng")
        for m in range(0, 3):
            j = self.step(j, t0 + timedelta(minutes=m), O)
        for m in range(3, 12):      # GPS (or a wrong pin) says "at the destination"
            j = self.step(j, t0 + timedelta(minutes=m), D)
        self.assertEqual(j.status, "active")
        self.assertEqual([e.kind for e in self.watcher_events(j)], ["fast_pin"])
        self.assertIn("fast_pin", JDUR.badges(j))

    def test_impossible_early_arrival_with_pin_waits_for_pin(self):
        self.ca.post("%s/journey/duress-pin" % V, {"pin": "2468", "duress_pin": "1357"},
                     format="json")
        t0 = timezone.now() - timedelta(minutes=20)
        j = self.mkj(start=t0, mode="car")
        for m in range(0, 2):
            j = self.step(j, t0 + timedelta(minutes=m), O)
        for m in range(2, 8):
            j = self.step(j, t0 + timedelta(minutes=m), D)
        self.assertEqual(j.status, "active")
        self.assertIn("too_early", j.during["pin_wait"]["why"])
        r = self.ca.get("%s/journey/%d/during" % (V, j.id))
        self.assertTrue(r.json()["pin_wait"])
        r = self.ca.post("%s/journey/%d/arrive-pin" % (V, j.id), {"pin": "2468"}, format="json")
        self.assertEqual(r.json()["status"], "arrived")
        j = Journey.objects.get(pk=j.pk)
        self.assertEqual(j.status, "arrived")
        self.assertEqual(set(JDUR.badges(j)), {"fast_pin", "pin_ok"})
        pb = [c for c in self.spy.to(self.b) if c["data"]["event"] == "arrived"]
        self.assertIn("Confirmed with PIN", pb[0]["ten"])

    def test_no_destination_coords_never_auto_arrives(self):
        t0 = day0()
        j = self.mkj(start=t0, dest={"name": "Gazipur (no pin)"})
        for m in range(0, 30):
            j = self.step(j, t0 + timedelta(minutes=m), O)
        self.assertEqual(j.status, "active")

    def test_phone_off_good_battery_amber_then_red(self):
        t0 = day0()
        j = self.mkj(start=t0)
        for m in range(0, 10):
            j = self.step(j, t0 + timedelta(minutes=m), north(O, m * 300), battery=70)
        lost = JW.LOST_FIX_MIN
        for m in range(10, 10 + lost + 12):
            j = self.step(j, t0 + timedelta(minutes=m), None)
        kinds = [e.kind for e in self.watcher_events(j)]
        if not j.during["state"].get("night"):
            self.assertEqual(kinds, ["check_on", "check_red"])

    def test_phone_off_low_battery_honest_reason_never_red(self):
        t0 = day0()
        j = self.mkj(start=t0)
        for m in range(0, 10):
            j = self.step(j, t0 + timedelta(minutes=m), north(O, m * 300), battery=4)
        for m in range(10, 60):
            j = self.step(j, t0 + timedelta(minutes=m), None)
        evs = self.watcher_events(j)
        self.assertEqual([e.kind for e in evs], ["check_on"])
        self.assertEqual(evs[0].payload.get("lost_why"), "battery")
        en = JDUR.watcher_text("check_on", j, "Rina", "en", evs[0].payload)[1]
        self.assertIn("battery", en)
        self.assertIn("4%", en)

    def test_unanswered_long_stop_amber_then_red(self):
        t0 = day0()
        j = self.mkj(start=t0, mode="walk")
        for m in range(0, 6):
            j = self.step(j, t0 + timedelta(minutes=m), north(O, m * 70))
        spot = east(north(O, 5 * 70), 900)
        for m in range(6, 60):
            j = self.step(j, t0 + timedelta(minutes=m), spot)
        kinds = [e.kind for e in self.watcher_events(j)]
        self.assertEqual(kinds, ["check_on", "check_red"])
        ask_at = JDUR._dt(j.during["ask"]["at"])
        amber = JDUR._dt(j.during["ask"]["amber_at"])
        red = JDUR._dt(j.during["ask"]["red_at"])
        self.assertEqual((amber - ask_at), timedelta(minutes=5))
        self.assertEqual((red - amber), timedelta(minutes=10))
        bn = JDUR.watcher_text("check_on", j, "রিনা", "bn", {})[0]
        self.assertIn("খোঁজ নিন", bn)


@override_settings(TIME_ZONE="Asia/Dhaka")
class NightTests(Sim):
    def test_night_trip_checks_in_privately_every_30_min(self):
        now = timezone.localtime(timezone.now())
        t0 = (now - timedelta(days=1)).replace(hour=22, minute=30, second=0, microsecond=0)
        j = self.mkj(start=t0, eta_min=200, mode="long_bus")
        for m in range(0, 95):
            j = self.step(j, t0 + timedelta(minutes=m), north(O, m * 150))
        n = len(self.asks())
        self.assertGreaterEqual(n, 2)
        self.assertEqual(self.watcher_events(j), [])     # unanswered check-ins alone: nothing


class DangerPinTests(Sim):
    def setUp(self):
        super().setUp()
        r = self.ca.post("%s/journey/duress-pin" % V, {"pin": "2468", "duress_pin": "1357"},
                         format="json")
        self.assertEqual(r.status_code, 200, r.content)

    def test_danger_pin_traveller_sees_arrived_watchers_silent_red(self):
        j = self.mkj(start=timezone.now() - timedelta(minutes=50))
        JW.on_location(j, *north(D, -60), timezone.now(), 60)
        j.last_location = {"lat": north(D, -60)[0], "lng": D[1], "at": timezone.now().isoformat(),
                           "battery": 60}
        j.save()
        safe_face = {"ok": True, "status": "arrived", "state": "arrived"}
        r = self.ca.post("%s/journey/%d/arrive-pin" % (V, j.id), {"pin": "1357"}, format="json")
        self.assertEqual(r.status_code, 200)
        body = r.json()
        self.assertEqual({k: body[k] for k in safe_face}, safe_face)
        j = Journey.objects.get(pk=j.pk)
        self.assertEqual(j.status, "active")                  # live location goes on
        self.assertTrue(j.during["cover"])
        self.assertEqual(self.spy.sos[-1]["silent"], True)
        self.assertEqual(self.ca.get("%s/journey/active" % V).json(), {})
        self.assertEqual(self.ca.get("%s/journey/%d/during" % (V, j.id)).json()["state"], "arrived")
        self.assertEqual(self.spy.to(self.a), [])              # nothing to this phone
        pb = [c for c in self.spy.to(self.b) if c["data"]["event"] == "danger_pin"]
        self.assertEqual(pb[0]["data"]["level"], "red")
        self.assertTrue(pb[0]["high"])
        board = self.cb.get("%s/journey/watch-board" % V).json()
        self.assertEqual(board["count"], 1)
        self.assertEqual(board["active"][0]["level"], "red")
        # the 30 s clip
        clip = base64.b64encode(b"\x00\x00\x00\x18ftypM4A fake-aac").decode()
        self.assertEqual(self.ca.post("%s/journey/%d/danger-audio" % (V, j.id),
                                      {"audio_b64": clip}, format="json").json(), {"ok": True})
        g = self.cb.get("%s/journey/%d/danger-audio" % (V, j.id))
        self.assertEqual(g.status_code, 200)
        self.assertEqual(g.json()["audio_b64"], clip)
        self.assertEqual(self.cc.get("%s/journey/%d/danger-audio" % (V, j.id)).status_code, 404)
        # privacy: gone with the locations
        JW.expire(Journey.objects.get(pk=j.pk))
        self.assertNotIn("audio", Journey.objects.get(pk=j.pk).during)

    def test_safe_pin_confirmed_and_wrong_pin(self):
        j = self.mkj(start=timezone.now() - timedelta(minutes=50))
        r = self.ca.post("%s/journey/%d/arrive-pin" % (V, j.id), {"pin": "0000"}, format="json")
        self.assertEqual(r.json()["pin"], "wrong")
        r = self.ca.post("%s/journey/%d/arrive-pin" % (V, j.id), {"pin": "2468"}, format="json")
        self.assertEqual(r.json()["status"], "arrived")
        board = self.cb.get("%s/journey/watch-board" % V).json()
        self.assertEqual(board["count"], 0)
        self.assertIn("pin_ok", board["finished"][0]["badges"])

    def test_pin_always_pref(self):
        r = self.ca.post("%s/journey/arrive-pin-pref" % V, {"always": True}, format="json")
        self.assertTrue(r.json()["always"])
        t0 = day0()
        j = self.mkj(start=t0)
        for m in range(0, 70):
            j = self.step(j, t0 + timedelta(minutes=m), north(O, min(19960, m * 300)))
        self.assertEqual(j.status, "active")
        self.assertEqual(j.during["pin_wait"]["why"], ["always"])


class TwoJourneysTests(Sim):
    def test_husband_wife_watch_each_other_child_watches_both(self):
        kid = mk("01711000009", "Kid")
        ba = edge(self.b, self.a)
        a_kid, b_kid = edge(self.a, kid), edge(self.b, kid)
        t0 = timezone.now() - timedelta(minutes=30)
        ja = self.mkj(traveller=self.a, member=self.ab, start=t0)
        JourneyWatcher.objects.create(journey=ja, member=a_kid)
        jb = self.mkj(traveller=self.b, member=ba, start=t0,
                      dest={"name": "Sample Airport", "kind": "airport", "lat": 23.85, "lng": 90.40})
        JourneyWatcher.objects.create(journey=jb, member=b_kid)
        for m in range(0, 10):
            ja = self.step(ja, t0 + timedelta(minutes=m), north(O, m * 300))
            jb = self.step(jb, t0 + timedelta(minutes=m), east(O, -m * 200))
        ka = cl(kid)
        ka.credentials(HTTP_ACCEPT_LANGUAGE="en")
        board = ka.get("%s/journey/watch-board" % V).json()
        self.assertEqual(board["count"], 2)
        self.assertEqual({c["name"] for c in board["active"]}, {"Rina", "Mother"})
        self.assertEqual(self.ca.get("%s/journey/watch-board" % V).json()["count"], 1)
        self.assertEqual(self.cb.get("%s/journey/watch-board" % V).json()["count"], 1)
        self.assertEqual(self.cc.get("%s/journey/watch-board" % V).json()["count"], 0)
        card = [c for c in board["active"] if c["name"] == "Rina"][0]
        self.assertIn(card["state"], ("moving", "slow"))
        self.assertEqual(card["mode"], "local_bus")


# ----------------------------------------------------------------- corpus
def make_corpus(n, seed=9):
    """Safe journeys only (nobody was in danger): traffic jams, tea stops,
    detours, late-but-moving, near-destination stops, GPS jitter. Each is a
    list of (minute, point) + who answers a private ask and how fast."""
    rnd = random.Random(seed)
    out = []
    kinds = ("normal", "traffic", "tea", "detour", "late", "near_tea", "jitter")
    for i in range(n):
        kind = kinds[i % len(kinds)]
        dist = rnd.randint(8000, 20000)
        kmh = rnd.uniform(12, 25)
        per_min = kmh * 1000 / 60.0
        travel = dist / per_min
        eta = travel * rnd.uniform(0.55, 1.1)           # often "late"
        dest = north(O, dist)
        track, pos, m = [], 0.0, 0
        jam_at = rnd.uniform(0.2, 0.7) * dist
        jam_len = rnd.randint(8, 40)
        tea_at = rnd.uniform(0.3, 0.7) * dist
        tea_len = rnd.randint(10, 25)
        det_at = rnd.uniform(0.3, 0.6) * dist
        det_len = rnd.randint(8, 18)
        stopped = 0
        while pos < dist - 20 and m < 400:
            p = north(O, pos)
            if kind == "traffic" and pos >= jam_at and stopped < jam_len:
                stopped += 1
            elif kind == "tea" and pos >= tea_at and stopped < tea_len:
                stopped += 1
                p = east(p, 80)
            elif kind == "near_tea" and pos >= dist - 700 and stopped < rnd.randint(10, 29):
                stopped += 1
            elif kind == "detour" and det_at <= pos and stopped < det_len:
                stopped += 1
                p = east(p, 3500 + 200 * stopped)
                pos += per_min * 0.5
            else:
                pos += per_min * (0.4 if kind == "late" else 1.0)
            if kind == "jitter" and rnd.random() < 0.15:
                p = east(p, rnd.choice((-1, 1)) * rnd.randint(300, 1200))
            track.append((m, p))
            m += 1
        for k in range(4):                                # arrive and stay
            track.append((m + k, north(dest, -30)))
        answers = rnd.random() < 0.85                     # a safe traveller sees the ask
        out.append({"kind": kind, "dist": dist, "eta": eta, "track": track,
                    "answers": answers, "answer_after": rnd.randint(1, 4), "mode":
                    rnd.choice(("local_bus", "cng", "car", "bike"))})
    return out


class CorpusTests(Sim):
    N = 42

    def run_corpus(self, v2=True):
        t_base = timezone.now() - timedelta(days=30)
        res = {"journeys": 0, "watcher_alerts": 0, "late_alerts": 0, "arrived": 0,
               "asks": 0, "false_arrived": 0}
        for i, c in enumerate(make_corpus(self.N)):
            t0 = t_base + timedelta(hours=8 * i)
            t0 = timezone.localtime(t0).replace(hour=10, minute=0)
            dest = {"name": "Sample place %d" % i, "lat": north(O, c["dist"])[0], "lng": O[1]}
            with override_settings(SJ_DURING_V2=v2):
                j = self.mkj(start=t0, eta_min=c["eta"], mode=c["mode"], dest=dest)
                asked_at = None
                for m, p in c["track"]:
                    t = t0 + timedelta(minutes=m)
                    j = self.step(j, t, p)
                    if j.status != "active":
                        if JW.SJ.haversine_m(p[0], p[1], dest["lat"], dest["lng"]) > 400:
                            res["false_arrived"] += 1
                        break
                    ask = (j.during or {}).get("ask") or {}
                    if v2 and c["answers"] and ask and not ask.get("answered"):
                        asked_at = asked_at or t
                        if t - asked_at >= timedelta(minutes=c["answer_after"]):
                            d, _amb = JDUR.answer_ask(j.during, "ok", t)
                            j.during = d
                            j.save(update_fields=["during"])
                            asked_at = None
                    elif not v2 and c["answers"] and j.ask_sent_at and j.escalated_at is None:
                        # old rules: the same traveller answers "I'm OK"
                        if t - j.ask_sent_at >= timedelta(minutes=c["answer_after"]):
                            j.eta = t + timedelta(minutes=JW.OK_SNOOZE_MIN - JW.effective_grace(j))
                            j.ask_sent_at = None
                            j.save(update_fields=["eta", "ask_sent_at"])
            res["journeys"] += 1
            res["arrived"] += int(j.status == "arrived")
            evs = self.watcher_events(j)
            res["watcher_alerts"] += len(evs)
            res["late_alerts"] += sum(1 for e in evs if e.kind in LATE_KINDS or
                                      (e.payload or {}).get("why") == "late_stopped")
        res["asks"] = len(self.asks())
        return res

    def test_false_alert_rate_v2_vs_old(self):
        new = self.run_corpus(v2=True)
        old = self.run_corpus(v2=False)
        per20 = lambda r, k: round(20.0 * r[k] / max(1, r["journeys"]), 2)
        print("SJDURING_CORPUS v2 journeys=%d arrived=%d false_arrived=%d private_asks=%d "
              "watcher_alerts=%d (%.2f/20) false_late_alerts=%d (%.2f/20)" % (
                  new["journeys"], new["arrived"], new["false_arrived"], new["asks"],
                  new["watcher_alerts"], per20(new, "watcher_alerts"),
                  new["late_alerts"], per20(new, "late_alerts")))
        print("SJDURING_CORPUS old journeys=%d arrived=%d false_arrived=%d "
              "watcher_alerts=%d (%.2f/20) false_late_alerts=%d (%.2f/20)" % (
                  old["journeys"], old["arrived"], old["false_arrived"],
                  old["watcher_alerts"], per20(old, "watcher_alerts"),
                  old["late_alerts"], per20(old, "late_alerts")))
        self.assertEqual(new["false_arrived"], 0)
        self.assertLess(per20(new, "late_alerts"), 1.0)          # owner target
        self.assertLessEqual(new["watcher_alerts"], old["watcher_alerts"])
