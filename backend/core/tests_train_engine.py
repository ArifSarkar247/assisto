"""train-engine — Train Tracker V2 live engine (owner order 17 Nov).

Pure rules (route index, point checks, Kalman, consensus, ETA, towers, learned
delay, "are you on this train?", the shared-text parser) + the DB/Redis engine
(anonymous trips, 24 h purge, check-in points, shared text, live state, read
API, offline pack) + privacy guarantees. All sample texts are MADE UP in the
public 16318 / group-post style — no real message, no phone number of anyone.
"""
import gzip
import json
import math
import unicodedata
from datetime import date, datetime, timedelta
from unittest import mock

from django.test import SimpleTestCase, TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import ops_health as H
from core import train_data
from core import train_engine as TE
from core import train_source as SRC
from core.logic import train_geo as TG
from core.logic import train_live as L
from core.logic import train_text as TX
from core.models import (RailStation, RailTrain, TrainCellBin, TrainCheckin, TrainObservation,
                         TrainPassing, TrainPing, TrainPointLedger, TrainTrip, User)

V = "/api/v1"
NO = "771"                       # Rangpur Express: Dhaka 09:10 -> Rangpur 19:00 (official)
DAY = date(2026, 11, 3)          # a Tuesday (771 is off on Mondays)
IBRAHIMABAD = "ibrahimabad"      # 11:33, km 117.1
CHATMOHAR = "chatmohar"          # 12:31, km 182.1
BOGURA = "bogura"                # 15:36, km 320.3


def _dep():
    return SRC.times(SRC.train(NO), DAY)[0]


def _ch(code):
    return next(s["ch"] for s in TE.stops(SRC.train(NO)) if s["id"] == code)


def _at(minutes):
    return _dep() + timedelta(minutes=minutes)


def _rt():
    return TE.route_index(NO)


def _pt(ch, minutes, **kw):
    lat, lng = _rt().point_at(ch)
    d = {"lat": lat, "lng": lng, "acc": 12, "at": _at(minutes).timestamp()}
    d.update(kw)
    return d


def _side(p, ch, metres):
    """Move point p `metres` sideways (perpendicular to the line at ch)."""
    a, b = _rt().point_at(ch), _rt().point_at(ch + 30.0)
    h = math.radians(TG.bearing_deg(a[0], a[1], b[0], b[1]) + 90.0)
    lat = p["lat"] + metres * math.cos(h) / 111320.0
    lng = p["lng"] + metres * math.sin(h) / (111320.0 * math.cos(math.radians(p["lat"])))
    return lat, lng


def _user(i):
    return User.objects.create_user(phone="+8801700%06d" % i, password="x" * 10)


# ====================================================================== pure
class RouteIndexTests(SimpleTestCase):
    def test_point_at_and_project_agree(self):
        rt = _rt()
        self.assertGreater(rt.length, 400000)            # Dhaka -> Rangpur by rail
        for ch in (1000, 50000, 200000, 400000):
            lat, lng = rt.point_at(ch)
            got, off = rt.project(lat, lng)
            self.assertAlmostEqual(got, ch, delta=5)
            self.assertLess(off, 1)

    def test_halts_sit_on_the_path_in_order(self):
        ss = TE.stops(SRC.train(NO))
        self.assertEqual([s["id"] for s in ss][:2], ["dhaka-kamalapur", "dhaka-airport"])
        chs = [s["ch"] for s in ss]
        self.assertEqual(chs, sorted(chs))
        st = SRC.stations()
        for s in ss:
            if st[s["id"]]["lat"] is not None:
                _, off = _rt().project(st[s["id"]]["lat"], st[s["id"]]["lng"], radius_cells=3)
                self.assertLess(off, 1500, s["id"])

    def test_official_times_and_ch_to_km(self):
        t = SRC.train(NO)
        sched = TE.sched_times(t, DAY)
        self.assertEqual(sched[BOGURA].strftime("%H:%M"), "15:36")
        self.assertAlmostEqual(TE.ch_to_km(t, _ch(BOGURA)), 320.3, delta=0.01)

    def test_far_point_is_not_on_the_route(self):
        ch, off = _rt().project(22.0, 92.5)          # the sea near Cox's Bazar
        self.assertIsNone(ch)
        self.assertEqual(off, math.inf)


class PointCheckTests(SimpleTestCase):
    def setUp(self):
        self.rt = _rt()

    def chk(self, p, prev=None, seg=L.DEFAULT_SEG_MAX_KMH):
        return L.check_point(p, self.rt, prev, seg)

    def test_mock_provider_refused(self):
        self.assertEqual(self.chk(_pt(50000, 60, mock=True))[1], "mock")

    def test_within_100_m_kept_beyond_refused(self):
        p = _pt(50000, 60)
        p["lat"], p["lng"] = _side(p, 50000, 70)
        ok, why, _, off = self.chk(p)
        self.assertTrue(ok, why)
        q = _pt(50000, 60)
        q["lat"], q["lng"] = _side(q, 50000, 400)
        self.assertEqual(self.chk(q)[1], "off_line")

    def test_bad_accuracy_and_no_gps(self):
        self.assertEqual(self.chk(_pt(50000, 60, acc=400))[1], "bad_accuracy")
        self.assertEqual(self.chk({"lat": None, "lng": None, "at": 1})[1], "no_gps")

    def test_reported_speed_over_the_train_limit(self):
        self.assertEqual(self.chk(_pt(50000, 60, speed=200 / 3.6))[1], "too_fast")
        self.assertTrue(self.chk(_pt(50000, 60, speed=80 / 3.6))[0])

    def test_two_times_segment_max(self):
        # a 40 km/h section: 85 km/h is more than 2x -> refused; 75 is fine
        self.assertEqual(self.chk(_pt(50000, 60, speed=85 / 3.6), seg=40)[1], "too_fast")
        self.assertTrue(self.chk(_pt(50000, 60, speed=75 / 3.6), seg=40)[0])

    def test_implied_speed_between_points(self):
        prev = {"ch": 50000, "at": _at(60).timestamp(), "acc": 10}
        self.assertEqual(self.chk(_pt(80000, 61), prev)[1], "too_fast")   # 30 km / min
        self.assertTrue(self.chk(_pt(51000, 61), prev)[0])                # 60 km/h

    def test_segment_max_from_data_or_schedule(self):
        stops = [{"km": 0}, {"km": 10, "max_kmh": 50}, {"km": 30}]
        self.assertEqual(L.seg_max_kmh(stops, 15000), 50)
        self.assertEqual(L.seg_max_kmh(stops, 5000, sched_avg=50), 80)
        self.assertEqual(L.seg_max_kmh(stops, 5000), L.DEFAULT_SEG_MAX_KMH)


class KalmanTests(SimpleTestCase):
    def test_converges_on_position_and_speed(self):
        kf = None
        noise = [35, -40, 20, -10, 45, -30, 5, 25, -20, 10, -5, 15]
        for i, n in enumerate(noise):
            t = 1000.0 + 30 * i
            kf = L.step(kf, t, 20.0 * 30 * i + n, acc=20)
        self.assertAlmostEqual(kf.v, 20.0, delta=4.0)
        self.assertAlmostEqual(kf.x, 20.0 * 30 * 11, delta=60)
        s = L.Kalman1D.from_state(kf.state())
        s.predict(1000.0 + 30 * 12)
        self.assertAlmostEqual(s.x, 20.0 * 30 * 12, delta=200)

    def test_speed_never_negative_or_above_the_limit(self):
        kf = L.step(None, 0, 5000, acc=10)
        kf = L.step(kf, 30, 3000, acc=10)          # GPS jump backwards
        self.assertGreaterEqual(kf.v, 0.0)
        kf = L.step(kf, 31, 90000, acc=10)
        self.assertLessEqual(kf.v, L.MAX_TRAIN_KMH / 3.6)


class ConsensusTests(SimpleTestCase):
    def r(self, i, x, trust=0.6, sigma=50):
        return {"id": i, "x": x, "v": 15, "sigma": sigma, "trust": trust}

    def test_majority_wins_and_outlier_trust_drops(self):
        c = L.consensus([self.r(1, 100000), self.r(2, 100200), self.r(3, 99900),
                         self.r(4, 130000)])
        self.assertTrue(c["agree"])
        self.assertEqual(c["outliers"], [4])
        self.assertAlmostEqual(c["x"], 100030, delta=200)
        self.assertLess(c["trust"][4], 0.6)
        self.assertGreater(c["trust"][1], 0.6)

    def test_two_disagree_trusted_one_wins_nobody_punished(self):
        c = L.consensus([self.r(1, 100000, trust=0.9), self.r(2, 140000, trust=0.4)])
        self.assertFalse(c["agree"])
        self.assertEqual(c["inliers"], [1])
        self.assertEqual(c["trust"], {})

    def test_confidence_is_never_100(self):
        self.assertLess(L.gps_confidence(20, 1.0, 0), 1.0)
        self.assertLess(L.gps_confidence(1, 0.6, 0), L.gps_confidence(3, 0.6, 0))
        self.assertLess(L.gps_confidence(3, 0.6, 0, agree=False), L.gps_confidence(3, 0.6, 0))

    def test_weighted_median(self):
        self.assertEqual(L.weighted_median([(1, 1), (2, 1), (100, 1)]), 2)
        self.assertEqual(L.weighted_median([(1, 5), (2, 1), (100, 1)]), 1)


class EtaTests(SimpleTestCase):
    def test_formula(self):
        self.assertAlmostEqual(L.eta_minutes(30, 60), 32.0)   # 30 km at 60 km/h + 2 min

    def test_stopped_uses_15_min_average_then_standard(self):
        hist = [[0, 0.0], [900, 15000.0]]                    # 60 km/h over 15 min
        self.assertAlmostEqual(L.eta_speed_kmh(0, hist, 45), 60.0, delta=0.1)
        self.assertEqual(L.eta_speed_kmh(0, [[0, 0.0], [900, 100.0]], 45), 45)
        self.assertEqual(L.eta_speed_kmh(None, [], 45), 45)

    def test_moving_uses_rolling_average(self):
        hist = [[0, 0.0], [600, 8000.0]]                     # 48 km/h
        self.assertAlmostEqual(L.eta_speed_kmh(70, hist, 45), 48.0, delta=0.1)

    def test_history_keeps_15_minutes(self):
        h = []
        for t in range(0, 2000, 100):
            h = L.push_hist(h, t, t * 10)
        self.assertLessEqual(h[-1][0] - h[0][0], L.HIST_WINDOW_S)


class CellTests(SimpleTestCase):
    def test_cell_key(self):
        self.assertEqual(L.cell_key({"mcc": 470, "mnc": 1, "tac": 1234, "cid": 56789}),
                         "470-1-1234-56789")
        self.assertEqual(L.cell_key({"mcc": "470", "mnc": "3", "lac": "77", "cid": "9"}),
                         "470-3-77-9")
        self.assertIsNone(L.cell_key({"mcc": 470, "mnc": 1, "tac": 2147483647, "cid": 5}))
        self.assertIsNone(L.cell_key({"mcc": 470}))
        self.assertIsNone(L.cell_key("x"))

    def test_place_by_cell_honest(self):
        rt = _rt()
        lat, lng = rt.point_at(120000)
        bi, bj = L.cell_bin(lat, lng)
        self.assertIsNone(L.place_by_cell([], rt))
        self.assertIsNone(L.place_by_cell([(bi, bj, 1)], rt))          # too few samples
        p = L.place_by_cell([(bi, bj, 6), (bi, bj + 1, 2)], rt)
        self.assertAlmostEqual(p["x"], 120000, delta=1200)
        self.assertLessEqual(p["confidence"], 0.4)
        self.assertGreaterEqual(p["spread_m"], 400)


class DelayLearningTests(SimpleTestCase):
    def test_needs_minimum_samples(self):
        self.assertIsNone(L.learned_delay([(1, 20), (2, 25)]))

    def test_robust_median_and_recency(self):
        r = L.learned_delay([(1, 20), (8, 22), (15, 25), (22, 300)])
        self.assertLessEqual(r["delay_min"], 25)                      # one bad day ignored
        old_late = [(200, 90)] * 3 + [(1, 10), (2, 12), (3, 11)]
        self.assertLess(L.learned_delay(old_late)["delay_min"], 30)  # recent days win

    def test_predict_chainage(self):
        pts = [(0, 0), (100, 3600), (200, 7200)]
        self.assertEqual(L.predict_chainage(pts, 1800), 50000)
        self.assertEqual(L.predict_chainage(pts, -5), 0)
        self.assertEqual(L.predict_chainage(pts, 9999), 200000)


class OnboardSignalTests(SimpleTestCase):
    def test_moving_on_the_line_at_train_speed_asks(self):
        pts = [_pt(50000, 60), _pt(50500, 60.5), _pt(51000, 61)]          # 60 km/h
        s = L.onboard_signal(pts, _rt())
        self.assertTrue(s["ask"], s)
        self.assertAlmostEqual(s["speed_kmh"], 60, delta=3)

    def test_standing_off_line_mock_or_backwards_does_not_ask(self):
        rt = _rt()
        self.assertFalse(L.onboard_signal([_pt(50000, 60), _pt(50010, 61)], rt)["ask"])
        far = _pt(50000, 60)
        far["lat"], far["lng"] = _side(far, 50000, 500)
        self.assertFalse(L.onboard_signal([far, _pt(51000, 61)], rt)["ask"])
        self.assertFalse(L.onboard_signal([_pt(50000, 60, mock=True), _pt(51000, 61)], rt)["ask"])
        self.assertFalse(L.onboard_signal([_pt(51000, 60), _pt(50000, 61)], rt)["ask"])
        self.assertFalse(L.onboard_signal([_pt(50000, 60)], rt)["ask"])


# ---------------------------------------------------------------- shared text
ST = {
    "A": {"en": "Bonarpara Junction", "bn": "বোনারপাড়া"},
    "B": {"en": "Bogura", "bn": "বগুড়া"},
    "C": {"en": "Rangpur", "bn": "রংপুর"},
    "D": {"en": "Ishwardi Bypass", "bn": "ঈশ্বরদী বাইপাস"},
    "E": {"en": "Ishwardi Junction", "bn": "ঈশ্বরদী"},
    "F": {"en": "Kamalapur Railway Station", "bn": "কমলাপুর"},
}
NAMES = {"771": ["রংপুর এক্সপ্রেস", "Rangpur Express"], "772": ["রংপুর এক্সপ্রেস", "Rangpur Express"],
         "705": ["একতা এক্সপ্রেস", "Ekota Express"]}
KNOWN = {"771", "772", "705"}
NOW = datetime(2026, 11, 17, 13, 0, tzinfo=TG.DHAKA)


def _p(text, **kw):
    return TX.parse(text, ST, NOW, TG.DHAKA, known_trains=KNOWN, train_names=NAMES, **kw)


class SharedTextTests(SimpleTestCase):
    def test_16318_style_reply(self):
        r = _p("Train: 771-RANGPUR EXPRESS, Status: Left Bonarpara at 10:25 AM, "
               "17-Nov-2026, Late: 45 Min.")
        self.assertEqual((r["no"], r["station_id"], r["kind"], r["late_min"]),
                         ("771", "A", "left", 45))
        self.assertEqual(r["at"].strftime("%H:%M %d"), "10:25 17")

    def test_arrived_with_hours_and_minutes(self):
        r = _p("RANGPUR EXPRESS (772) has arrived at Bogura at 11:02 AM. Delay 1 hr 5 min.")
        self.assertEqual((r["no"], r["station_id"], r["kind"], r["late_min"]),
                         ("772", "B", "reached", 65))

    def test_train_name_station_is_not_the_station(self):
        # "Rangpur" is in the train's name; the station is Bogura
        r = _p("Rangpur Express Bogura chere geche 12:10, 30 min late")
        self.assertEqual(r["station_id"], "B")
        self.assertEqual(r["kind"], "left")
        self.assertEqual(r["candidates"], ["771", "772"])     # both directions -> engine picks
        self.assertIsNone(r["no"])

    def test_bangla_post(self):
        r = _p("রংপুর এক্সপ্রেস (৭৭১) বগুড়া ছেড়েছে দুপুর ১২:১০, বিলম্ব ৩৫ মিনিট")
        self.assertEqual((r["no"], r["station_id"], r["kind"], r["late_min"]),
                         ("771", "B", "left", 35))
        self.assertEqual(r["at"].strftime("%H:%M"), "12:10")

    def test_banglish_whatsapp_with_typos(self):
        r = _p("bhai 771 ekhon bogra pouchese, 40 minit let")
        self.assertEqual((r["no"], r["station_id"], r["kind"], r["late_min"]),
                         ("771", "B", "reached", 40))
        r = _p("Ekota exp isurdi bypass cherese 11.40 thik time e")
        self.assertEqual((r["no"], r["station_id"], r["kind"], r["late_min"]),
                         ("705", "D", "left", 0))

    def test_longest_station_name_wins(self):
        r = _p("705 left Ishwardi Bypass at 13:40, running 20 minutes late")
        self.assertEqual(r["station_id"], "D")
        r = _p("705 arrived at Ishwardi at 12:40")
        self.assertEqual(r["station_id"], "E")

    def test_open_train_is_used_when_text_has_none(self):
        r = _p("Train left Bogura 12:01", train_no="772")
        self.assertEqual(r["no"], "772")

    def test_phone_numbers_never_come_back(self):
        r = _p("From 01711000000: 771 left Bogura at 12:00 call 8801811000000")
        self.assertNotIn("01711000000", json.dumps(r, default=str))
        self.assertEqual(r["no"], "771")

    def test_unparseable(self):
        self.assertIsNone(_p("hello how are you"))
        self.assertIsNone(_p("771 Rangpur Express"))          # no state
        self.assertIsNone(_p("x" * 3000))

    def test_after_midnight_time_is_yesterday(self):
        r = TX.parse("771 left Bogura at 11:50 PM", ST,
                     datetime(2026, 11, 17, 0, 20, tzinfo=TG.DHAKA), TG.DHAKA,
                     known_trains=KNOWN, train_names=NAMES)
        self.assertEqual(r["at"].day, 16)


# ====================================================================== DB / Redis
class EngineBase(TestCase):
    @classmethod
    def setUpTestData(cls):
        train_data.load()          # official trains/stations: TrainPassing needs them

    def setUp(self):
        from django.core.cache import cache
        cache.clear()
        TE.STORE.delete(TE.live_key(NO))
        self.t = SRC.train(NO)

    def trip(self, cells=False):
        return TrainTrip.objects.create(key="k%d" % TrainTrip.objects.count(), train_no=NO,
                                        service_date=DAY, cells_ok=cells)

    def feed(self, trip, ch0, minutes0, n=4, step_m=1000, offset=0, **kw):
        """n points 1 min apart at 60 km/h starting at ch0."""
        pts = []
        for i in range(n):
            p = _pt(ch0 + step_m * i, minutes0 + i, speed=step_m / 60.0, **kw)
            if offset:
                p["lat"], p["lng"] = _side(p, ch0 + step_m * i, offset)
            pts.append(p)
        now = _at(minutes0 + n - 1) + timedelta(seconds=5)
        return TE.ingest(trip, pts, now=now), now


class IngestTests(EngineBase):
    def test_anonymous_trip_points_and_live_state(self):
        tr = self.trip()
        res, now = self.feed(tr, 150000, 240)
        self.assertEqual(res["accepted"], 4, res)
        self.assertEqual(TrainPing.objects.filter(trip=tr).count(), 4)
        st = TE.STORE.get("train:live:%s" % NO)
        self.assertEqual(st["mode"], "live")
        self.assertEqual(st["contributors"], 1)
        self.assertAlmostEqual(st["km"], 153.0, delta=0.5)
        self.assertLess(st["confidence"], 1.0)
        self.assertTrue(st["next"] and st["etas"])
        self.assertIn("delay_min", st["next"])

    def test_live_key_has_15_minute_ttl(self):
        with mock.patch.object(TE.STORE, "set", wraps=TE.STORE.set) as s:
            self.feed(self.trip(), 150000, 240)
        keys = [(c.args[0], c.args[2]) for c in s.call_args_list]
        self.assertIn(("train:live:%s" % NO, 900), keys)

    def test_mock_off_line_and_not_running_refused(self):
        tr = self.trip()
        res, _ = self.feed(tr, 150000, 240, mock=True)
        self.assertEqual(res["accepted"], 0)
        self.assertEqual(res["reasons"]["mock"], 4)
        tr.refresh_from_db()
        self.assertEqual(tr.trust, L.TRUST_MIN)
        res, _ = self.feed(self.trip(), 150000, 240, offset=300)
        self.assertEqual(res["reasons"].get("off_line"), 4)
        res = TE.ingest(self.trip(), [_pt(1000, -300)], now=_at(-299))
        self.assertEqual(res["reasons"].get("not_running"), 1)
        self.assertFalse(TrainPing.objects.exists())

    def test_queued_points_up_to_24h_and_future_refused(self):
        tr = self.trip()
        p_old = _pt(150000, 240)
        res = TE.ingest(tr, [p_old], now=_at(240) + timedelta(hours=3))
        self.assertEqual(res["accepted"], 1)          # queued while offline
        res = TE.ingest(self.trip(), [_pt(150000, 240)], now=_at(240) + timedelta(hours=30))
        self.assertEqual(res["reasons"].get("bad_point"), 1)
        res = TE.ingest(self.trip(), [_pt(150000, 240)], now=_at(230))
        self.assertEqual(res["reasons"].get("bad_point"), 1)

    def test_consensus_outlier_loses_trust(self):
        good = [self.trip() for _ in range(3)]
        bad = self.trip()
        for tr in good:
            self.feed(tr, 150000, 240)
        self.feed(bad, 175000, 240)
        st = TE.recompute(self.t, DAY, now=_at(243) + timedelta(seconds=10))
        self.assertEqual(st["contributors"], 3)
        self.assertAlmostEqual(st["km"], 153.0, delta=1.0)
        bad.refresh_from_db()
        self.assertLess(bad.trust, L.TRUST_START)

    def test_cell_learning_only_when_opted_in_then_weak_gps_placed(self):
        cell = {"mcc": 470, "mnc": 1, "tac": 501, "cid": 7001}
        self.feed(self.trip(cells=False), 150000, 240, n=2, cell=cell)
        self.assertFalse(TrainCellBin.objects.exists())
        for _ in range(4):
            self.feed(self.trip(cells=True), 150000, 240, n=2, step_m=100, cell=cell)
        self.assertGreaterEqual(sum(TrainCellBin.objects.values_list("n", flat=True)), 4)
        weak = self.trip()
        res = TE.ingest(weak, [{"lat": None, "lng": None, "at": _at(250).timestamp(),
                                "cell": cell}], now=_at(250))
        self.assertEqual(res["placed_by_cell"], 1)
        weak.refresh_from_db()
        self.assertEqual(weak.mode, "cell")
        self.assertAlmostEqual(weak.kf["x"], 150000, delta=1500)

    def test_tick_purges_after_24h_keeps_tower_counts(self):
        tr = self.trip(cells=True)
        self.feed(tr, 150000, 240, n=2, cell={"mcc": 470, "mnc": 1, "tac": 5, "cid": 9})
        TrainObservation.objects.create(train_no=NO, service_date=DAY, source="text",
                                        station=IBRAHIMABAD, chainage=117000, at=_at(100))
        later = timezone.now() + timedelta(hours=25)
        with mock.patch("django.utils.timezone.now", return_value=later):
            out = TE.tick(later)
        self.assertGreaterEqual(out["pings"], 2)
        self.assertFalse(TrainPing.objects.exists())
        self.assertFalse(TrainTrip.objects.exists())
        self.assertFalse(TrainObservation.objects.exists())
        self.assertTrue(TrainCellBin.objects.exists())

    def test_fresh_rows_survive_the_purge(self):
        self.feed(self.trip(), 150000, 240, n=2)
        TE.purge(timezone.now() + timedelta(hours=23))
        self.assertEqual(TrainPing.objects.count(), 2)

    def test_arrives_at_the_end(self):
        tr = self.trip()
        L_ = _rt().length
        TE.ingest(tr, [_pt(L_ - 300, 640, speed=5)], now=_at(640))
        tr.refresh_from_db()
        self.assertEqual(tr.status, "arrived")


class ReadTests(EngineBase):
    def test_no_data_says_estimated_from_timetable(self):
        r = TE.read(self.t, DAY, _at(120))
        self.assertEqual(r["mode"], "timetable")
        self.assertEqual(r["freshness"]["state"], "timetable")
        self.assertEqual(r["note_bn"], "সময়সূচি থেকে আনুমানিক")
        self.assertEqual(r["note_en"], "Estimated from timetable")
        self.assertEqual(r["contributors"], 0)

    def test_live_payload_small_and_without_rider_data(self):
        self.feed(self.trip(), 150000, 240)
        r = TE.read(self.t, DAY, _at(244))
        self.assertEqual(r["freshness"]["state"], "live")
        raw = json.dumps(r)
        self.assertLess(len(gzip.compress(raw.encode())), 1500)    # 2G friendly
        for k in ("trip", "token", "user", "key", "hist", "trust"):
            self.assertNotIn('"%s"' % k, raw)

    def test_stale_after_three_minutes(self):
        self.feed(self.trip(), 150000, 240)
        r = TE.read(self.t, DAY, _at(250))
        self.assertEqual(r["freshness"]["state"], "stale")
        self.assertGreater(r["freshness"]["age_s"], 180)

    def test_predicted_from_learned_delays_never_live(self):
        tr = RailTrain.objects.get(number=NO)
        for i in range(4):
            sd = DAY - timedelta(days=7 * (i + 1))
            for seq, sid in ((2, IBRAHIMABAD), (3, CHATMOHAR)):
                TrainPassing.objects.create(train=tr, station=RailStation.objects.get(code=sid),
                                            seq=seq, service_date=sd, weekday=DAY.weekday(),
                                            delay_min=40 + i, source="rider_gps")
        with mock.patch("django.utils.timezone.now", return_value=_at(150)):
            r = TE.read(self.t, DAY, _at(150))
        self.assertEqual(r["mode"], "predicted")
        self.assertEqual(r["freshness"]["state"], "predicted")
        self.assertIn(r["delay_min"], range(40, 44))
        self.assertLessEqual(r["confidence"], L.PREDICT_CONF)
        # the predicted train is behind the timetable position
        tt = TE.timetable_payload(self.t, DAY, _at(150))
        self.assertLess(r["km"], tt["km"])

    def test_recompute_records_confirmed_passings(self):
        tr = self.trip()
        c = _ch(IBRAHIMABAD)
        self.feed(tr, c - 2600, 140, n=2)              # just before Ibrahimabad
        TE.ingest(tr, [_pt(c + 900, 143, speed=16)], now=_at(143) + timedelta(seconds=5))
        TE.maybe_recompute(self.t, DAY, _at(143) + timedelta(seconds=6), force=True)
        p = TrainPassing.objects.filter(train__number=NO, station__code=IBRAHIMABAD).first()
        self.assertIsNotNone(p)
        self.assertEqual(p.source, "rider_gps")
        self.assertIsNotNone(p.arrived_at)
        self.assertEqual(p.weekday, DAY.weekday())


class CheckinTests(EngineBase):
    def setUp(self):
        super().setUp()
        self.a, self.b, self.c = _user(1), _user(2), _user(3)
        self.st = SRC.stations()[IBRAHIMABAD]

    def ci(self, u, near=True, minutes=125, kind="reached"):
        # not near = ~5 km away (still a plausible eyewitness; train-e2e:
        # 40+ km away is "not counted", see TrainE2EFixTests)
        lat, lng = (self.st["lat"], self.st["lng"]) if near else (self.st["lat"] + 0.045,
                                                                  self.st["lng"])
        return TE.checkin(u, self.t, DAY, IBRAHIMABAD, kind, _at(minutes).isoformat(), lat, lng, 20,
                          now=_at(minutes) + timedelta(seconds=30))

    def test_near_alone_accepted_but_no_points_until_matched(self):
        r = self.ci(self.a)
        self.assertEqual((r["status"], r["points"]), ("accepted", 0))
        self.assertTrue(TrainObservation.objects.filter(source="checkin").exists())
        r2 = self.ci(self.b, near=False, minutes=128)
        self.assertEqual(r2["status"], "accepted")
        self.assertEqual(r2["points"], TE.CHECKIN_POINTS)
        self.assertEqual(TrainCheckin.objects.get(user=self.a).points, TE.CHECKIN_POINTS)
        self.assertEqual(TE.points_balance(self.a), TE.CHECKIN_POINTS)

    def test_far_alone_pending_then_two_agree(self):
        r = self.ci(self.a, near=False)
        self.assertEqual(r["status"], "pending")
        self.assertFalse(TrainObservation.objects.exists())
        r = self.ci(self.b, near=False, minutes=130)
        self.assertEqual(r["status"], "accepted")
        self.assertEqual(TrainCheckin.objects.get(user=self.a).status, "accepted")

    def test_reports_too_far_apart_in_time_do_not_match(self):
        self.ci(self.a, near=False)
        r = self.ci(self.b, near=False, minutes=125 + TE.CHECKIN_MATCH_MIN + 5)
        self.assertEqual(r["status"], "pending")

    def test_station_must_be_on_this_train_and_once_per_user(self):
        r = TE.checkin(self.a, self.t, DAY, "chattogram", "reached", now=_at(100))  # not on 771
        self.assertEqual(r["reason"], "not_on_this_train")
        self.ci(self.a)
        self.assertEqual(self.ci(self.a)["reason"], "already")
        self.assertEqual(TrainCheckin.objects.count(), 1)

    def test_points_are_not_money_and_ledger_has_no_trail(self):
        names = {f.name for f in TrainPointLedger._meta.get_fields()}
        self.assertFalse(names & {"train_no", "station", "lat", "lng", "service_date"})
        self.assertFalse(names & {"amount", "bdt", "taka", "cash"})

    def test_position_of_the_phone_is_not_stored(self):
        names = {f.name for f in TrainCheckin._meta.get_fields()}
        self.assertFalse(names & {"lat", "lng", "acc"})


class ShareTextEngineTests(EngineBase):
    def setUp(self):
        super().setUp()
        self.a, self.b = _user(11), _user(12)

    def send(self, u, text, minutes=395, **kw):      # 15:45, Bogura is due 15:36
        return TE.share_text(u, text, now=_at(minutes), **kw)

    def test_one_report_waits_two_agree_then_applied(self):
        msg = "Rangpur Express (771) left Bogura at 3:40 PM, late 4 min"
        code, body = self.send(self.a, msg)
        self.assertEqual(code, 200)
        self.assertEqual(body["status"], "pending")
        self.assertFalse(body["applied"])
        self.assertEqual(body["parsed"]["station_id"], BOGURA)
        self.assertEqual(unicodedata.normalize("NFC", body["parsed"]["station_bn"]),
                         unicodedata.normalize("NFC", "বগুড়া"))
        self.assertEqual(body["parsed"]["late_min"], 4)
        code, body = self.send(self.b, "771 Bogra chere geche 15:42, 6 min let")
        self.assertTrue(body["applied"], body)
        st = TE.STORE.get(TE.live_key(NO))
        self.assertEqual(st["mode"], "reported")
        self.assertLess(st["confidence"], 0.5)
        p = TrainPassing.objects.get(station__code=BOGURA)
        self.assertEqual((p.source, p.departed_at is not None), ("shared_text", True))

    def test_train_name_only_picks_the_right_direction(self):
        # "Rangpur Express" is 771 (Dhaka -> Rangpur) and 772 (back): the time decides
        _, body = self.send(self.a, "Rangpur Express Bogura chere geche 3.40 bikal")
        self.assertEqual(body["parsed"]["no"], "771")

    def test_same_person_twice_is_not_two_reports(self):
        self.send(self.a, "771 left Bogura at 15:40")
        _, body = self.send(self.a, "771 left Bogura at 15:41")
        self.assertFalse(body["applied"])

    def test_near_the_station_applies_alone(self):
        st = SRC.stations()[BOGURA]
        _, body = self.send(self.a, "771 left Bogura at 15:40", lat=st["lat"], lng=st["lng"],
                            acc=15)
        self.assertTrue(body["applied"])

    def test_implausible_time_and_wrong_route(self):
        _, body = self.send(self.a, "771 left Bogura at 03:00 AM")
        self.assertEqual(body["reason"], "time_not_plausible")
        _, body = self.send(self.a, "701 left Bogura at 15:40")
        self.assertEqual(body.get("reason"), "not_on_route")

    def test_unparsed(self):
        code, body = self.send(self.a, "kemon acho")
        self.assertEqual((code, body["reason"]), (400, "unparsed"))

    def test_nothing_about_the_sender_is_stored(self):
        self.send(self.a, "771 left Bogura at 15:40 from 01712000000")
        self.send(self.b, "771 left Bogura at 15:42")
        for o in TrainObservation.objects.all():
            blob = json.dumps({f.name: str(getattr(o, f.name)) for f in o._meta.fields})
            self.assertNotIn("01712000000", blob)
        names = {f.name for f in TrainObservation._meta.get_fields()}
        self.assertFalse(names & {"user", "text", "phone", "sender"})


class PrivacyTests(TestCase):
    def test_points_and_trips_carry_no_user(self):
        for m in (TrainTrip, TrainPing, TrainObservation, TrainCellBin, TrainPassing):
            names = {f.name for f in m._meta.get_fields()}
            self.assertFalse(names & {"user", "user_id", "phone", "device_id"}, m.__name__)

    def test_token_is_stored_hashed(self):
        u = _user(21)
        token, trip = TE.open_trip(u, SRC.train(NO), DAY)
        self.assertNotEqual(trip.key, token)
        self.assertEqual(TE.trip_by_token(token), trip)

    def test_no_export_or_sale_endpoint(self):
        from django.urls import get_resolver
        routes = " ".join(str(p.pattern) for p in get_resolver().url_patterns)
        import core.urls as CU
        routes += " ".join(str(p.pattern) for p in CU.urlpatterns)
        for bad in ("train/export", "train/pings", "train/dump", "train/points/export"):
            self.assertNotIn(bad, routes)

    def test_purge_job_runs_every_minute_before_agent_core(self):
        self.assertIn("train_engine_tick", H.MINUTE_JOB_NAMES)
        self.assertEqual(H.MINUTE_JOB_NAMES[-1], "agent_core_run")
        self.assertEqual(H.JOB_BY_NAME["train_engine_tick"].via, "minute_jobs")
        self.assertEqual(TE.KEEP_H, 24)


# ====================================================================== API
@mock.patch("core.train_engine_views.flag_on", return_value=True)
class ApiTests(TestCase):
    def setUp(self):
        from django.core.cache import cache
        cache.clear()
        self.u = _user(31)
        self.c = APIClient()
        self.c.force_authenticate(self.u)
        self.day = timezone.now().astimezone(TG.DHAKA).date().isoformat()

    def test_trip_ping_now_stop(self, _):
        r = self.c.post(V + "/train/%s/trip" % NO, {"date": self.day}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        token = r.json()["token"]
        r = self.c.post(V + "/train/ping", {"token": token, "points": [
            {"lat": 0, "lng": 0, "at": timezone.now().isoformat(), "mock": True}]},
            format="json")
        self.assertEqual(r.json()["reasons"].get("mock"), 1)
        r = self.c.get(V + "/train/%s/now?date=%s" % (NO, self.day), HTTP_ACCEPT_ENCODING="gzip")
        self.assertEqual(r.status_code, 200)
        body = json.loads(gzip.decompress(r.content)) if r.get("Content-Encoding") == "gzip" \
            else r.json()
        self.assertIn(body["mode"], ("timetable", "predicted"))
        r = self.c.post(V + "/train/trip/stop", {"token": token}, format="json")
        self.assertEqual(r.json()["status"], "ended")

    def test_flag_off_blocks_but_stop_still_works(self, flag):
        flag.return_value = False
        self.assertEqual(self.c.post(V + "/train/%s/trip" % NO, {}, format="json").status_code,
                         403)
        self.assertEqual(self.c.get(V + "/train/%s/now" % NO).status_code, 403)
        self.assertEqual(self.c.post(V + "/train/share-text", {"text": "x"},
                                     format="json").status_code, 403)
        self.assertEqual(self.c.post(V + "/train/trip/stop", {"token": "nope"},
                                     format="json").status_code, 200)

    def test_checkin_and_onboard_and_sms(self, _):
        r = self.c.post(V + "/train/%s/checkin" % NO,
                        {"date": self.day, "station_id": IBRAHIMABAD, "kind": "flew"}, format="json")
        self.assertEqual(r.status_code, 400)
        r = self.c.post(V + "/train/%s/onboard" % NO, {"date": self.day, "points": []},
                        format="json")
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.json()["ask"])
        r = self.c.post(V + "/train/sms16318", {"text": "hello"}, format="json")
        self.assertEqual((r.status_code, r.json()["reason"]), (400, "unparsed"))
        r = self.c.post(V + "/train/text", {"text": "kemon acho", "source": "paste"},
                        format="json")
        self.assertEqual(r.status_code, 200)
        self.assertIsNone(r.json()["parsed"])
        self.assertFalse(r.json()["applied"])

    def test_live_view_gets_engine_keys(self, _):
        with mock.patch("core.train_views.flag_on", return_value=True):
            r = self.c.get(V + "/train/%s/live?date=%s" % (NO, self.day)).json()
        self.assertIn(r["freshness"]["state"], ("timetable", "predicted"))
        self.assertIn("line", r)

    def test_offline_pack(self, _):
        meta = self.c.get(V + "/train/offline/meta").json()
        self.assertGreater(meta["size_bytes"], 1000)
        r = self.c.get(V + "/train/offline/pack", HTTP_ACCEPT_ENCODING="gzip")
        self.assertEqual(r["Content-Encoding"], "gzip")
        body = json.loads(gzip.decompress(r.content))
        self.assertEqual(body["ver"], meta["version"])
        self.assertTrue(any(t[0] == NO for t in body["tr"]))     # data lane's compact format
        self.assertIn("st", body)
        self.assertEqual(body["tw"], [])                         # nothing learned yet
        self.assertLess(meta["size_bytes"], 200 * 1024)
        self.assertEqual(self.c.get(V + "/train/offline/pack?have=%s" % meta["version"])
                         .json()["same"], True)

    def test_points_endpoint_says_not_money(self, _):
        self.assertEqual(self.c.get(V + "/train/points").json(),
                         {"ok": True, "points": 0, "money": False})


class TowerMapTests(TestCase):
    def test_tower_map_rows_snap_to_a_rail_segment(self):
        lat, lng = _rt().point_at(_ch(IBRAHIMABAD))
        bi, bj = L.cell_bin(lat, lng)
        TrainCellBin.objects.create(cell="470-1-9-9", bi=bi, bj=bj, n=5)
        TrainCellBin.objects.create(cell="470-1-9-8", bi=bi, bj=bj, n=1)   # too few samples
        m = TE.tower_map()
        self.assertEqual(len(m), 1)
        mcc, mnc, tac, cid, seg, metres, n, la, ln = m[0]
        self.assertLess(L.haversine_m(la / 1e5, ln / 1e5, lat, lng), 1500)
        self.assertEqual((mcc, mnc, tac, cid, n), (470, 1, 9, 9, 5))
        self.assertTrue(0 <= seg < len(SRC.segment_index()))
        self.assertGreaterEqual(metres, 0)


class LoadTests(EngineBase):
    """CI-only load check (never run against the live server): 60 riders x
    20 points on one train + 20k projections stay well inside the budget."""

    def test_projection_throughput(self):
        import time
        rt = _rt()
        pts = [rt.point_at(i * 25.0) for i in range(20000)]
        t0 = time.monotonic()
        for lat, lng in pts:
            rt.project(lat, lng)
        self.assertLess(time.monotonic() - t0, 6.0)

    def test_many_riders_one_train(self):
        import time
        t0 = time.monotonic()
        for k in range(60):
            tr = self.trip()
            pts = [_pt(150000 + 500 * i + 7 * k, 240 + i * 0.5, speed=16.6) for i in range(20)]
            TE.ingest(tr, pts, now=_at(250))
        st = TE.recompute(self.t, DAY, now=_at(250))
        self.assertEqual(st["contributors"], 60)
        self.assertLess(time.monotonic() - t0, 60.0)


class OsmGapTests(SimpleTestCase):
    """Data lane (17 Nov): OSM misses the Pabna-Tebunia track, so its OSM line
    is a 24 km detour for 8 km between the stations. That stretch is drawn as
    the straight chord and riders are matched there by progress (wide
    tolerance); everywhere else the 100 m rule stays."""

    def setUp(self):
        self.t = SRC.train("779")
        self.rt = TE.route_index("779")
        self.ss = {s["id"]: s for s in TE.stops(self.t)}

    def _mid(self, a, b, metres):
        c = (self.ss[a]["ch"] + self.ss[b]["ch"]) / 2.0
        lat, lng = self.rt.point_at(c)
        p = {"lat": lat, "lng": lng, "acc": 15, "at": 1000.0}
        x, y = self.rt.point_at(c), self.rt.point_at(c + 30.0)
        h = math.radians(TG.bearing_deg(x[0], x[1], y[0], y[1]) + 90.0)
        p["lat"] += metres * math.cos(h) / 111320.0
        p["lng"] += metres * math.sin(h) / (111320.0 * math.cos(math.radians(lat)))
        return p, c

    def test_gap_is_flagged_and_drawn_straight(self):
        self.assertTrue(SRC.segment_low_quality("pabna", "tebunia"))
        self.assertTrue(SRC.segment_low_quality("tebunia", "pabna"))
        self.assertFalse(SRC.segment_low_quality("dhaka-kamalapur", "dhaka-airport"))
        gap = self.ss["tebunia"]["ch"] - self.ss["pabna"]["ch"]
        self.assertLess(gap, 10000)                       # chord, not the 24 km detour
        self.assertEqual(len(self.t["lowq"]), 1)
        self.assertAlmostEqual(self.t["lowq"][0][0], self.ss["pabna"]["ch"], delta=1)

    def test_wide_tolerance_only_on_the_gap(self):
        p, c = self._mid("pabna", "tebunia", 800)
        ok, why, ch, _ = L.check_point(p, self.rt, lowq=self.t["lowq"])
        self.assertTrue(ok, why)
        self.assertAlmostEqual(ch, c, delta=900)
        q, _ = self._mid("dhalarchar", "bandherhat", 800)
        self.assertEqual(L.check_point(q, self.rt, lowq=self.t["lowq"])[1], "off_line")
        # without the flag the gap point is refused like any other
        self.assertEqual(L.check_point(p, self.rt)[1], "off_line")

    def test_only_official_times_give_a_delay(self):
        t = SRC.train(NO)
        self.assertTrue(SRC.official_time(t, BOGURA))
        self.assertFalse(SRC.official_time(t, "chattogram"))
