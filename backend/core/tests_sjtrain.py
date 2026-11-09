"""sjtrain (Safe Journey V2, owner order 9 Nov 11:15) — TRAIN 1-9 + the
destination-alarm family note. PROOF tests (all made-up sample data):

  * 3 FAKE PASSENGERS on 701 (+ one fake/outlier phone): every fix goes
    through the real validation (rail line, speed, direction, timetable) and
    the fused position is within 2 km of the true train at every check of a
    long trip (target from the order) — the measured errors are printed;
  * offline on the train: a batch of fixes kept on the phone for 25 minutes
    is accepted when the phone is back online;
  * the family sees the train of a traveller whose phone is OFFLINE (from the
    other passengers), with the sharer count;
  * metro-style line: every station the train passes, in order, Bangla
    names, passed / now passing / next with ETA, licences cited;
  * chat: closed before / after the run, abuse refused by the shared filter,
    the AI router may hide a message (mocked), nothing older than 24 h;
  * seat card: unverified until 3 different people agree; the sun side is
    CALCULATED from the rail path + timetable; no names / ids in answers;
  * destination alarm family note says "time to get off", never "arrived".
"""
import json
import math
import random
from collections import Counter
from datetime import date, datetime, timedelta
from datetime import timezone as dt_timezone
from types import SimpleNamespace
from unittest import mock

from django.test import SimpleTestCase, TestCase, override_settings
from rest_framework.test import APIClient

from core import journey_mode as JM
from core import train_service as TS
from core.logic import train_geo as TG
from core.models import TrainChatMember, TrainChatMessage, TrainSeatAnswer, User

V = "/api/v1"
NO = "701"                       # Subarna: Chattogram 07:00 -> Kamalapur 12:20
DAY = date(2026, 11, 10)         # a Tuesday (701 is off on Mondays)


def _user(n):
    return User.objects.create_user(name="Sample %d" % n, phone="+88019000001%02d" % n,
                                    password="pw12345!")


def _client(u):
    c = APIClient()
    c.force_authenticate(u)
    return c


def _offset(lat, lng, north_m, east_m):
    return (lat + north_m / 111320.0,
            lng + east_m / (111320.0 * math.cos(math.radians(lat))))


class FakeTrain:
    """The TRUE train: running DELAY_MIN late on the timetable line."""
    DELAY_MIN = 22

    def __init__(self):
        self.t = TG.train(NO)
        self.rt = TG.route(NO)
        self.dep, self.arr = TG.times(self.t, DAY)

    def chainage(self, at):
        return TG.sched_chainage(self.t, self.rt, DAY, at - timedelta(minutes=self.DELAY_MIN))

    def speed_kmh(self):
        return self.rt.length / 1000.0 / ((self.arr - self.dep).total_seconds() / 3600.0)


def _phone_fix(train, at, rng, lag_m=0.0, acc=20.0):
    """A passenger's phone: somewhere in the train (coach offset lag_m), GPS
    noise up to ~35 m, Doppler speed + bearing like a real phone."""
    ch = max(0.0, train.chainage(at) - lag_m)
    lat, lng = train.rt.point_at(ch)
    lat, lng = _offset(lat, lng, rng.uniform(-25, 25), rng.uniform(-25, 25))
    return {"lat": lat, "lng": lng, "acc": acc, "at": at.isoformat(),
            "speed_kmh": round(train.speed_kmh() * rng.uniform(0.9, 1.1), 1),
            "bearing": round(train.rt.heading_at(ch), 1)}


class LineDataTests(SimpleTestCase):
    def test_every_passed_station_in_order_with_bangla_names(self):
        rows = TG.line_stations(TG.train(NO))
        self.assertGreaterEqual(len(rows), 20)               # not just the 2 timetable stops
        kms = [r["km"] for r in rows]
        self.assertEqual(kms, sorted(kms))
        self.assertTrue(rows[0]["stop"] and rows[-1]["stop"])
        self.assertTrue(all(r["bn"] for r in rows), "every station has a Bangla name")
        names = " ".join(r["en"] for r in rows)
        self.assertNotIn("Railway Station", names)
        with open(TG.DATA / "line_stations_bd.json", encoding="utf-8") as fh:
            meta = json.load(fh)["_meta"]
        self.assertIn("ODbL", meta["licence"])
        self.assertIn("CC BY-SA", meta["licence"])
        for t in TG.timetable()["trains"]:
            self.assertTrue(TG.line_stations(t), t["no"])

    def test_line_view_passed_passing_next(self):
        t = TG.train(NO)
        rows = TG.line_stations(t)
        mid = rows[len(rows) // 2]
        ch = float(mid["km"]) * 1000.0 + 300.0
        now = datetime(2026, 11, 10, 4, 0, tzinfo=dt_timezone.utc)
        v = TG.line_view(t, DAY, ch, now, delay_min=15)
        i = len(rows) // 2
        self.assertEqual(v["now_index"], i)
        self.assertEqual(v["passing"], i)
        self.assertEqual(v["next_index"], i + 1)
        st = v["stations"]
        self.assertTrue(all(s["passed"] for s in st[:i + 1]))
        self.assertFalse(any(s["passed"] for s in st[i + 1:]))
        eta = datetime.fromisoformat(st[i + 1]["eta"])
        sched = datetime.fromisoformat(st[i + 1]["sched"])
        self.assertEqual((eta - sched).total_seconds(), 15 * 60)
        # far from any station: no "passing"
        gap = max(range(1, len(rows)), key=lambda k: rows[k]["km"] - rows[k - 1]["km"])
        far = (float(rows[gap - 1]["km"]) + 3.0) * 1000.0
        self.assertIsNone(TG.line_view(t, DAY, far, now)["passing"])

    def test_sun_side_is_calculated(self):
        # Dhaka, 9 Nov, noon: the sun is in the south, ~49 deg up
        az, el = TG.sun_position(23.8, 90.4, datetime(2026, 11, 9, 12, 0, tzinfo=TG.DHAKA))
        self.assertAlmostEqual(az, 180, delta=10)
        self.assertAlmostEqual(el, 49, delta=2)
        s = TG.sun_side(TG.train(NO), DAY)
        self.assertEqual(s["label"], "calculated")
        self.assertEqual(s["left"] + s["right"] + s["dark"], 100, s)
        self.assertIn(s["side"], ("left", "right", "none"))
        # an evening train: mostly dark, no sunny side claimed
        self.assertGreater(TG.sun_side(TG.train("702"), DAY)["dark"], 80)


class ThreeFakePassengersTests(TestCase):
    """TARGET (owner order): train position within 2 km where passengers share."""

    def test_position_within_2km_three_passengers_plus_a_fake_phone(self):
        rng = random.Random(9119)
        train = FakeTrain()
        users = [_user(i) for i in range(4)]
        start = train.dep + timedelta(minutes=FakeTrain.DELAY_MIN + 25)
        shares = [TS.start_share(u, train.t, DAY, now=start) for u in users]
        lags = [0.0, 120.0, 260.0]          # three coaches apart
        errors, rejected_fake = [], 0     # the fake phone: refused or dropped
        at = start
        end = train.arr - timedelta(minutes=10)
        k = 0
        while at < end:
            for i in range(3):
                # each phone uploads every ~60 s; passenger 2 is offline for a while
                if i == 2 and 40 <= k % 90 < 55:
                    continue
                TS.add_fixes(shares[i], [_phone_fix(train, at, rng, lags[i])], now=at)
            # the 4th phone claims to be on this train but sits 6 km behind it
            # (a bus on the highway / a joker): rejected or dropped as an outlier
            ch_fake = max(0.0, train.chainage(at) - 6000.0)
            flat, flng = train.rt.point_at(ch_fake)
            r = TS.add_fixes(shares[3], [{"lat": flat, "lng": flng, "acc": 20,
                                          "at": at.isoformat(), "speed_kmh": 60,
                                          "bearing": train.rt.heading_at(ch_fake)}], now=at)
            rejected_fake += r["rejected"]
            if k % 5 == 0:
                q = at + timedelta(seconds=40)
                v = TS.live_view(train.t, DAY, None, now=q)
                self.assertEqual(v["mode"], "live", q)
                err = abs(v["live"]["chainage_m"] - train.chainage(q))
                errors.append(err)
                self.assertGreaterEqual(v["sharers"], 2)   # 3, or 2 while one is offline
                self.assertIn(v["live"]["dropped"], (0, 1))
            at += timedelta(seconds=60)
            k += 1
        errors.sort()
        p50, p95, worst = errors[len(errors) // 2], errors[int(len(errors) * 0.95)], errors[-1]
        print("\nSJTRAIN PROOF 3 fake passengers (+1 fake phone) on %s: %d checks, "
              "error p50 %.0f m, p95 %.0f m, max %.0f m (target < 2000 m)"
              % (NO, len(errors), p50, p95, worst))
        self.assertGreater(len(errors), 40)
        self.assertLess(worst, 2000.0)
        # the line on the screen: the train is between passed and next
        v = TS.live_view(train.t, DAY, None, now=end)
        line = v["line"]
        self.assertIsNotNone(line["next_index"])
        self.assertTrue(line["stations"][0]["passed"])
        self.assertFalse(line["stations"][-1]["passed"])
        self.assertIsNotNone(v["delay_min"])
        self.assertAlmostEqual(v["delay_min"], FakeTrain.DELAY_MIN, delta=6)
        body = json.dumps(v, default=str)
        for leak in ("Sample", "+8801900", '"user'):
            self.assertNotIn(leak, body)

    def test_offline_batch_sent_when_back_online(self):
        rng = random.Random(3)
        train = FakeTrain()
        u = _user(9)
        t0 = train.dep + timedelta(minutes=FakeTrain.DELAY_MIN + 60)
        s = TS.start_share(u, train.t, DAY, now=t0)
        # 25 minutes without internet: the phone kept a fix every 20 s
        batch = [_phone_fix(train, t0 + timedelta(seconds=20 * i), rng) for i in range(75)]
        online = t0 + timedelta(minutes=25)
        r = TS.add_fixes(s, batch, now=online)
        self.assertGreater(r["accepted"], 60, r)
        s.refresh_from_db()
        self.assertAlmostEqual(s.last_chainage, train.chainage(t0 + timedelta(seconds=20 * 74)),
                               delta=500)

    def test_estimate_when_nobody_shares_is_labelled(self):
        train = FakeTrain()
        v = TS.live_view(train.t, DAY, None, now=train.dep + timedelta(hours=2))
        self.assertEqual(v["mode"], "estimate")
        self.assertEqual(v["estimate"]["label"], "estimate")
        self.assertEqual(v["sharers"], 0)
        self.assertIsNone(v["delay_min"])
        self.assertIsNotNone(v["line"]["next_index"])


class FamilySeesTrainWhileOfflineTests(TestCase):
    def test_watcher_gets_live_train_from_other_passengers(self):
        rng = random.Random(5)
        train = FakeTrain()
        now = train.dep + timedelta(minutes=FakeTrain.DELAY_MIN + 90)
        for i in range(3):
            s = TS.start_share(_user(20 + i), train.t, DAY, now=now - timedelta(minutes=2))
            TS.add_fixes(s, [_phone_fix(train, now - timedelta(seconds=30), rng, 100.0 * i)],
                         now=now)
        traveller = _user(30)
        last = train.t["stops"][-1]["st"]
        j = SimpleNamespace(traveller=traveller, eta=None,
                            vehicle={"train": {"no": NO, "date": DAY.isoformat(), "to": last}})
        with mock.patch.object(JM, "_flag", return_value=True), \
                mock.patch.object(JM, "_fresh_fix", return_value=None):   # phone offline
            tr = JM.train_link(j, now=now)
        self.assertEqual(tr["basis"], "live")
        self.assertEqual(tr["sharers"], 3)
        lat, lng = train.rt.point_at(train.chainage(now))
        self.assertLess(TG.haversine_m(lat, lng, tr["lat"], tr["lng"]), 2000)
        self.assertIsNotNone(tr["to_eta"])


@mock.patch("core.train_views.flag_on", return_value=True)
@override_settings(PUSH_SYNC=True)
class ChatWindowAndModerationTests(TestCase):
    def setUp(self):
        self.a, self.b = _user(40), _user(41)
        self.t = TG.train(NO)
        self.dep, self.arr = TG.times(self.t, DAY)

    def _at(self, when):
        p = mock.patch("django.utils.timezone.now", return_value=when)
        p.start()
        self.addCleanup(p.stop)

    def _post(self, u, text):
        c = _client(u)
        c.post(V + "/train/%s/chat/join" % NO, {"date": DAY.isoformat(), "nickname": "নীল"},
               format="json")
        return c.post(V + "/train/%s/chat" % NO, {"date": DAY.isoformat(), "text": text},
                      format="json")

    def test_closed_before_departure(self, _):
        self._at(self.dep - timedelta(hours=2))
        r = self._post(self.a, "ট্রেন কি সময়মতো?")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()["reason"], "not_running")
        room = _client(self.a).get(V + "/train/%s/chat?date=%s" % (NO, DAY)).json()
        self.assertFalse(room["chat"]["open"])

    def test_open_while_running_and_closed_long_after(self, _):
        self._at(self.dep + timedelta(hours=1))
        self.assertEqual(self._post(self.a, "কোন বগিতে খাবার?").status_code, 200)
        w = TS.chat_window(self.t, DAY, self.arr + timedelta(hours=TS.CHAT_CLOSE_AFTER_H, minutes=5),
                           live={})
        self.assertFalse(w["open"])

    def test_abuse_refused_and_ai_can_hide(self, _):
        self._at(self.dep + timedelta(hours=1))
        r = self._post(self.a, "তুই একটা হারামজাদা")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()["reason"], "not_allowed")
        with mock.patch("core.ai.generate", return_value=("HIDE", 0.0)) as g, \
                self.captureOnCommitCallbacks(execute=True):
            r = self._post(self.b, "inbox me, I sell cheap tickets")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(TrainChatMessage.objects.get(pk=r.json()["message"]["id"]).hidden)
        self.assertEqual(g.call_args.kwargs["feature"], "train.chat_mod")
        self.assertIsNone(g.call_args.kwargs["user"])
        with mock.patch("core.ai.generate", return_value=("OK", 0.0)), \
                self.captureOnCommitCallbacks(execute=True):
            r = self._post(self.a, "পরের স্টেশন কোনটা?")
        self.assertFalse(TrainChatMessage.objects.get(pk=r.json()["message"]["id"]).hidden)
        # no AI key / budget: the message stays (the local filter already ran)
        from core.ai import AIUnavailable
        with mock.patch("core.ai.generate", side_effect=AIUnavailable("no_key")), \
                self.captureOnCommitCallbacks(execute=True):
            r = self._post(self.a, "ধন্যবাদ")
        self.assertFalse(TrainChatMessage.objects.get(pk=r.json()["message"]["id"]).hidden)

    def test_nothing_older_than_24h(self, _):
        self._at(self.dep + timedelta(hours=1))
        self._post(self.a, "hello")
        later = self.dep + timedelta(hours=25)
        TrainChatMember.objects.update(ends_at=later + timedelta(days=3))   # a stuck end time
        TrainChatMessage.objects.update(ends_at=later + timedelta(days=3))
        TS.purge(later, Counter())
        self.assertEqual(TrainChatMessage.objects.count(), 0)
        self.assertEqual(TrainChatMember.objects.count(), 0)


@mock.patch("core.train_views.flag_on", return_value=True)
class SeatCardTests(TestCase):
    def setUp(self):
        t = TG.train(NO)
        dep, arr = TG.times(t, DAY)
        p = mock.patch("django.utils.timezone.now", return_value=arr + timedelta(minutes=30))
        p.start()
        self.addCleanup(p.stop)

    def _answer(self, u, **kw):
        body = {"date": DAY.isoformat(), "coach": "ঝ", "seat": "32"}
        body.update(kw)
        return _client(u).post(V + "/train/%s/seat" % NO, body, format="json")

    def test_unverified_until_three_agree(self, _):
        a, b, c, d = (_user(50 + i) for i in range(4))
        r = self._answer(a, facing="forward", place="window", side="left", coach_pos=7).json()
        self.assertFalse(r["facing"]["verified"])
        self.assertEqual(r["facing"]["value"], "forward")
        self._answer(b, facing="forward", place="window", side="left", coach_pos=7)
        r = self._answer(c, facing="forward", place="aisle", side="left").json()
        self.assertTrue(r["facing"]["verified"])           # 3 of 3 agree
        self.assertFalse(r["place"]["verified"])           # 2 of 3
        self.assertFalse(r["coach_pos"]["verified"])       # only 2 answered
        r = self._answer(d, facing="backward").json()
        self.assertTrue(r["facing"]["verified"])           # 3 of 4 >= 66 %
        self.assertEqual(r["sun"]["label"], "calculated")
        self.assertEqual(r["sun_on_seat"]["label"], "calculated")
        body = json.dumps(r)
        for leak in ("Sample", "+88019", '"user'):
            self.assertNotIn(leak, body)
        g = _client(a).get(V + "/train/%s/seat" % NO,
                           {"coach": "ঝ", "seat": "32", "date": DAY.isoformat()}).json()
        self.assertEqual(g["answers"], 4)
        self.assertEqual(g["mine"]["side"], "left")

    def test_answer_replaces_and_validates(self, _):
        a = _user(60)
        self._answer(a, facing="forward")
        self._answer(a, facing="backward")
        self.assertEqual(TrainSeatAnswer.objects.get().facing, "backward")
        self.assertEqual(self._answer(a, facing="sideways").status_code, 400)
        self.assertEqual(self._answer(a, coach_pos=99).status_code, 400)
        self.assertEqual(self._answer(a, coach="", seat="").status_code, 400)
        self.assertEqual(self._answer(a).json()["reason"], "empty")

    def test_only_around_the_trip(self, _):
        a = _user(61)
        with mock.patch("django.utils.timezone.now",
                        return_value=datetime(2026, 11, 11, 6, 0, tzinfo=dt_timezone.utc)):
            r = self._answer(a, facing="forward")
        self.assertEqual(r.json()["reason"], "not_this_trip")


class GetOffNoteTests(TestCase):
    def test_family_note_says_time_to_get_off_never_arrived(self):
        from core import sjalarm as SJ
        u = _user(70)
        with mock.patch("core.family_alerts.alert", return_value={"recipients": 1}) as al, \
                mock.patch("core.models.CircleMember.objects.filter") as f, \
                mock.patch("core.push.member_peer_user", return_value=_user(71)):
            f.return_value = [SimpleNamespace()]
            stats, why = SJ.notify_arrived(u, "বিমানবন্দর", [5], kind="get_off")
        self.assertIsNone(why)
        kind, payload = al.call_args.args[1], al.call_args.kwargs["payload"]
        self.assertEqual(kind, "dest_get_off")
        self.assertIn("নামার সময়", payload["title_bn"])
        self.assertNotIn("arrived", payload["title_en"].lower())
        from core import family_alerts as FA
        self.assertIn("dest_get_off", FA.KINDS)
