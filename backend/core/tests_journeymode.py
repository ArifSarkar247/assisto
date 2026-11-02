"""journeymode — Train tracker + Destination alarm INSIDE Safe Journey (owner
order 2 Nov 17:40). Real timetable data (core/data/train): 705 Ekota
Express, Kamalapur -> ... -> Joydebpur -> Tangail -> ... Panchagarh.

1. the train link is stored whitelisted in Journey.vehicle (no migration);
2. watchers see where the train is, the next station and an ESTIMATED time
   at the traveller's station (basis own / live / timetable), only with the
   flag train_tracker on;
3. a train at a station / on its line is NOT "stopped for a long time" at
   the normal 20 min — a later, calm, non-urgent notice; off the line it is
   a normal stop again;
4. a local bus in a jam reuses journey100b's traffic rule;
5. a late train (traveller's own fix) postpones the "Are you OK?" check,
   capped, and never without a fresh fix;
6. strict bn / en texts.
Patches return plain values only (no bare MagicMock gets JSON-encoded)."""
from datetime import timedelta
from unittest import mock

from django.utils import timezone

from core import journey_mode as JM
from core import journey_watch as JW
from core.logic import journey_dest as JD
from core.logic import train_geo as TG
from core.models import Journey
from core.tests_journey100 import Base, V

NO = "705"


def _ids():
    t = TG.train(NO)
    names = {TG.stations()[s["st"]]["en"]: s["st"] for s in t["stops"]}
    jo = next(v for k, v in names.items() if k.startswith("Joydebpur"))
    ta = next(v for k, v in names.items() if k.startswith("Tangail"))
    return t, jo, ta


def _today():
    return timezone.now().astimezone(TG.DHAKA).date()


class TrainJourneyBase(Base):
    def start_train(self, date=None, eta_min=120, to=None, **kw):
        t, jo, ta = _ids()
        st = TG.stations()[to or ta]
        body = {"mode": "train", "destination": {"name": st["en"], "lat": st["lat"], "lng": st["lng"]},
                "vehicle": {"mode": "train",
                            "train": {"no": NO, "date": (date or _today()).isoformat(),
                                      "to": to or ta, "evil": "<script>"}}}
        body.update(kw)
        return self.start(eta_min=eta_min, **body)

    def at_point(self, j, lat, lng, at):
        return self.ca.post("%s/journey/%d/location" % (V, j.id),
                            {"points": [{"lat": lat, "lng": lng, "at": at.isoformat()}]},
                            format="json")


# ------------------------------------------------------------ 1. link stored
class TrainLinkStoredTests(TrainJourneyBase):
    def test_link_is_whitelisted_and_named_in_the_ride_line(self):
        j, _ = self.start_train()
        _t, _jo, ta = _ids()
        self.assertEqual(j.mode, "train")
        self.assertEqual(j.vehicle["train"], {"no": NO, "date": _today().isoformat(), "to": ta})
        line_bn = JD.ride_line(j.vehicle, "bn")
        self.assertIn("ট্রেন", line_bn)
        self.assertIn("৭০৫", line_bn)
        self.assertIn("টাঙ্গাইল", line_bn)
        self.assertIn("Train · 705", JD.ride_line(j.vehicle, "en"))

    def test_bad_links_are_dropped(self):
        self.assertIsNone(JD.clean_train({"no": "abc", "date": "2026-11-02"}))
        self.assertIsNone(JD.clean_train({"no": "705", "date": "tomorrow"}))
        self.assertEqual(JD.clean_train({"no": "7 0 5", "date": "2026-11-02", "to": "n1;drop"}),
                         {"no": "705", "date": "2026-11-02", "to": "n1drop"})

    def test_editing_the_ride_mid_trip_keeps_the_train(self):
        j, _ = self.start_train()
        r = self.ca.post("%s/journey/%d/ride" % (V, j.id), {"plate": "COACH KA"}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        j.refresh_from_db()
        self.assertEqual(j.vehicle["train"]["no"], NO)

    def test_new_travel_modes_are_accepted(self):
        for m in ("local_bus", "long_bus", "metro", "launch"):
            j, _ = self.start(mode=m, vehicle={"mode": m})
            self.assertEqual((j.mode, j.vehicle["mode"]), (m, m))


# ------------------------------------------------------------ 2. watcher view
@mock.patch("core.journey_mode._flag", return_value=True)
class WatcherTrainViewTests(TrainJourneyBase):
    def test_own_fix_on_the_line_gives_next_station_and_estimated_eta(self, _f):
        t, _jo, ta = _ids()
        j, _ = self.start_train()
        lat, lng = TG.route(NO).point_at(60000)          # between Joydebpur and Tangail
        self.at_point(j, lat, lng, timezone.now())
        w = self.cb.get("%s/journey/watching" % V).json()["journeys"][0]
        tr = w["train"]
        self.assertEqual((tr["no"], tr["basis"], tr["label"]), (NO, "own", "estimate"))
        self.assertEqual(tr["next_stop"]["id"], ta)
        self.assertEqual(tr["to"]["id"], ta)
        self.assertIsNotNone(tr["to_eta"])
        self.assertFalse(tr["passed"])
        # the traveller's own screen gets the same block
        a = self.ca.get("%s/journey/active" % V).json()
        self.assertEqual(a["train"]["next_stop"]["id"], ta)

    def test_without_a_fix_it_is_the_timetable_estimate(self, _f):
        self.start_train()
        tr = self.cb.get("%s/journey/watching" % V).json()["journeys"][0]["train"]
        self.assertEqual((tr["basis"], tr["label"]), ("timetable", "estimate"))
        self.assertIsNone(tr["delay_min"])

    def test_a_fix_off_the_line_is_not_used_as_the_train(self, _f):
        j, _ = self.start_train()
        self.at_point(j, 21.43, 92.0, timezone.now())    # Cox's Bazar: no rail line
        tr = self.cb.get("%s/journey/watching" % V).json()["journeys"][0]["train"]
        self.assertNotEqual(tr["basis"], "own")

    def test_flag_off_no_train_block_journey_still_works(self, flag):
        flag.return_value = False
        j, _ = self.start_train()
        w = self.cb.get("%s/journey/watching" % V).json()["journeys"][0]
        self.assertIsNone(w["train"])
        self.assertEqual(w["status"], "active")


# ------------------------------------------------------------ 3/4. stop rules
class ModeAwareStopTests(TrainJourneyBase):
    def stand(self, j, lat, lng, minutes):
        """Arrive at (lat, lng) `minutes` ago and stand there; sweep now."""
        now = timezone.now()
        # the trip began before the stop (fixes older than the start are dropped)
        Journey.objects.filter(pk=j.pk).update(created_at=now - timedelta(minutes=minutes + 15))
        j.refresh_from_db()
        self.at_point(j, lat + 0.01, lng, now - timedelta(minutes=minutes + 1))
        self.at_point(j, lat, lng, now - timedelta(minutes=minutes))
        self.at_point(j, lat, lng, now - timedelta(seconds=30))
        JW.sweep(now=now)
        return self.events(j, "long_stop")

    def test_train_at_a_station_is_not_a_long_stop_at_20_min(self):
        _t, jo, _ta = _ids()
        s = TG.stations()[jo]
        j, _ = self.start_train(eta_min=300)
        self.assertEqual(self.stand(j, s["lat"], s["lng"], 40), [])

    def test_train_at_a_station_gets_a_calm_notice_after_an_hour(self):
        _t, jo, _ta = _ids()
        s = TG.stations()[jo]
        j, _ = self.start_train(eta_min=300)
        ev = self.stand(j, s["lat"], s["lng"], JM.TRAIN_STATION_MIN + 5)
        self.assertEqual(len(ev), 1)
        self.assertEqual(ev[0].payload.get("dwell"), "station")
        title, body = JW.event_text("long_stop", j, "রিনা", "bn", ev[0].payload)
        self.assertIn("স্টেশনে", title)
        self.assertNotIn("অনেকক্ষণ এক জায়গায় থেমে আছেন", title)
        # calm: not an urgent alarm push
        pushes = [c for c in self.spy.to(self.b) if c["data"].get("event") == "long_stop"]
        self.assertTrue(pushes)
        self.assertFalse(any(c["high"] for c in pushes))

    def test_train_stopped_between_stations_on_the_line_waits_longer(self):
        j, _ = self.start_train(eta_min=300)
        lat, lng = TG.route(NO).point_at(60000)
        self.assertEqual(self.stand(j, lat, lng, 30), [])

    def test_off_the_line_is_a_normal_stop(self):
        j, _ = self.start_train(eta_min=300)
        ev = self.stand(j, 23.8069, 90.3687, 25)          # Mirpur 10: ~3 km from any rail line
        self.assertEqual(len(ev), 1)
        self.assertIsNone(ev[0].payload.get("dwell"))

    def test_local_bus_jam_reuses_the_traffic_rule(self):
        o = {"name": "Mirpur 10", "lat": 23.8069, "lng": 90.3687}
        d = {"name": "Motijheel", "lat": 23.7330, "lng": 90.4172}
        j, _ = self.start(eta_min=180, origin=o, destination=d, mode="local_bus",
                          vehicle={"mode": "local_bus"})
        self.assertEqual(self.stand(j, 23.7570, 90.3900, 25), [])   # Farmgate jam
        w, _ = self.start(eta_min=180, origin=o, destination=d, mode="walk",
                          vehicle={"mode": "walk"})
        self.assertEqual(len(self.stand(w, 23.7570, 90.3900, 25)), 1)

    def test_metro_and_launch_rules(self):
        j, _ = self.start(eta_min=180, mode="metro", vehicle={"mode": "metro"})
        self.assertEqual(JM.stop_rule(j, 23.8, 90.4), ("metro", JM.METRO_MIN))
        j.vehicle = {"mode": "launch"}
        self.assertEqual(JM.stop_rule(j, 23.8, 90.4), ("ghat", JM.LAUNCH_MIN))
        j.vehicle = {"mode": "car"}
        self.assertEqual(JM.stop_rule(j, 23.8, 90.4), (None, 20))


# ------------------------------------------------------------ 5. late train
@mock.patch("core.journey_mode._flag", return_value=True)
class LateTrainCheckTests(TrainJourneyBase):
    def test_a_late_train_postpones_the_ok_check_capped(self, _f):
        # yesterday's service: the timetable says it arrived long ago, the
        # traveller's own fix says it is still between Joydebpur and Tangail
        j, _ = self.start_train(date=_today() - timedelta(days=1), eta_min=-25)
        now = timezone.now()
        self.assertEqual(JW.overdue(j, now)[0], "alert")             # before any fix
        lat, lng = TG.route(NO).point_at(60000)
        self.at_point(j, lat, lng, now)
        j.refresh_from_db()
        late = JM.train_late_eta(j, now)
        self.assertIsNotNone(late)
        self.assertLessEqual(late, j.eta + timedelta(minutes=JM.LATE_CAP_MIN))
        self.assertNotIn(JW.overdue(j, now)[0], ("ask", "alert"))

    def test_no_fresh_fix_no_postponing(self, _f):
        j, _ = self.start_train(date=_today() - timedelta(days=1), eta_min=-25)
        lat, lng = TG.route(NO).point_at(60000)
        old = timezone.now() - timedelta(minutes=JM.OWN_FIX_FRESH_MIN + 5)
        self.at_point(j, lat, lng, old)
        j.refresh_from_db()
        self.assertIsNone(JM.train_late_eta(j, timezone.now()))
        self.assertEqual(JW.overdue(j, timezone.now())[0], "alert")

    def test_not_a_train_journey_unchanged(self, _f):
        j, _ = self.start(eta_min=-25, mode="car", vehicle={"mode": "car"})
        self.assertIsNone(JM.train_late_eta(j, timezone.now()))
        self.assertEqual(JW.overdue(j, timezone.now())[0], "alert")


# ------------------------------------------------------------ 6. language
class DwellTextLanguageTests(TrainJourneyBase):
    def test_every_dwell_text_is_one_language(self):
        import re
        j, _ = self.start_train()
        for kind in ("station", "line", "metro", "ghat"):
            p = {"minutes": 65, "dwell": kind, "lat": 23.9, "lng": 90.4}
            tbn, bbn = JW.event_text("long_stop", j, "রিনা", "bn", p)
            ten, ben = JW.event_text("long_stop", j, "Rina", "en", p)
            bn = re.sub(r"https?://\S+", "", tbn + " " + bbn)
            self.assertEqual(set(re.findall(r"[A-Za-z]+", bn)), set(), (kind, bn))
            self.assertNotRegex(bn, r"[0-9]", (kind, bn))
            self.assertIn("৬৫", bn)
            en = re.sub(r"https?://\S+", "", ten + " " + ben)
            self.assertNotRegex(en, r"[ঀ-৿]", (kind, en))
        self.assertTrue(Journey.objects.filter(pk=j.pk).exists())
