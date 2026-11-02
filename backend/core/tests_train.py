"""train (owner priority C, 2 Nov): Train Tracker + chat.
  * bundled data: OSM network + timetable load, sources/licences cited,
    every train approved:false;
  * fix validation with fixed coordinates on the real 701 route: on-line,
    off-line, wrong route, too fast, wrong way (chainage + bearing), not
    running, ahead of timetable, bad accuracy;
  * fusion: median, outlier dropped, stale ignored;
  * estimate is labelled 'estimate'; live view switches to 'live' with a
    sharer; SMS compose 'TR <no>' -> 16318 with the 4 taka cost;
  * chat privacy: nickname only (no id / phone / name in any response),
    join first, request-only My Circle (accept creates the pair, decline
    does not), block hides, 3 reports hide, phone numbers masked, rate limit,
    emergency words (bn / en / Banglish) -> 999 + 131, purge after the trip;
  * flag OFF -> 403, but stop-sharing and leave work with the flag OFF.
"""
import json
from collections import Counter
from datetime import date, timedelta
from unittest import mock

from django.test import SimpleTestCase, TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import train_service as TS
from core.logic import train_chat as TC
from core.logic import train_geo as TG
from core.models import (CircleMember, TrainChatMember, TrainChatMessage, TrainChatReport,
                         TrainCircleRequest, TrainShare, User)

V = "/api/v1"
NO = "701"                       # Subarna: Chattogram 07:00 -> Kamalapur 12:20
DAY = date(2026, 11, 3)          # a Tuesday (701 is off on Mondays)


def _east(lat, lng, metres):
    import math
    return lat, lng + metres / (111320.0 * math.cos(math.radians(lat)))


def _at(minutes):
    dep, _ = TG.times(TG.train(NO), DAY)
    return dep + timedelta(minutes=minutes)


def _fix(ch, minutes, **kw):
    lat, lng = TG.route(NO).point_at(ch)
    d = {"lat": lat, "lng": lng, "acc": 15, "at": _at(minutes)}
    d.update(kw)
    return d


class DataTests(SimpleTestCase):
    def test_bundled_data_cites_sources_and_is_unapproved(self):
        tt = TG.timetable()
        self.assertIn("CC BY-SA", tt["_meta"]["trains_source"])
        self.assertIn("ODbL", tt["_meta"]["geometry"])
        self.assertGreaterEqual(len(tt["trains"]), 20)
        self.assertTrue(all(t["approved"] is False for t in tt["trains"]))
        t = TG.train(NO)
        self.assertEqual(t["dep"], "07:00")
        self.assertGreater(TG.route(NO).length, 250000)   # ~321 km by rail
        self.assertLess(TG.network().distance_m(*TG.route(NO).point_at(100000)), 60)


class ValidationTests(SimpleTestCase):
    def setUp(self):
        self.t = TG.train(NO)
        self.rt = TG.route(NO)

    def v(self, fix, prev=None):
        return TG.validate_fix(self.t, DAY, fix, prev)

    def test_on_line_accepted(self):
        ok, why, ch, off = self.v(_fix(50000, 60))
        self.assertTrue(ok, why)
        self.assertAlmostEqual(ch, 50000, delta=200)

    def test_off_line_refused(self):
        f = _fix(50000, 60)
        f["lat"], f["lng"] = _east(f["lat"], f["lng"], 3000)
        self.assertEqual(self.v(f)[1], "off_line")

    def test_bad_accuracy_refused(self):
        self.assertEqual(self.v(_fix(50000, 60, acc=900))[1], "bad_accuracy")

    def test_too_fast_refused(self):
        prev = dict(_fix(50000, 60), chainage=50000)
        self.assertEqual(self.v(_fix(80000, 61), prev)[1], "too_fast")   # 30 km in 1 min

    def test_normal_speed_accepted(self):
        prev = dict(_fix(50000, 60), chainage=50000)
        self.assertTrue(self.v(_fix(51000, 61), prev)[0])                # 60 km/h

    def test_wrong_way_by_chainage(self):
        prev = dict(_fix(60000, 60), chainage=60000)
        self.assertEqual(self.v(_fix(58000, 63), prev)[1], "wrong_way")

    def test_wrong_way_by_bearing(self):
        heading = self.rt.heading_at(50000)
        f = _fix(50000, 60, speed_kmh=60, bearing=(heading + 180) % 360)
        self.assertEqual(self.v(f)[1], "wrong_way")
        g = _fix(50000, 60, speed_kmh=60, bearing=heading)
        self.assertTrue(self.v(g)[0])

    def test_not_running_and_ahead_of_timetable(self):
        self.assertEqual(self.v(_fix(1000, -180))[1], "not_running")
        self.assertEqual(self.v(_fix(1000, 60 * 30))[1], "not_running")
        # 250 km after only 30 minutes: impossible by the timetable
        self.assertEqual(self.v(_fix(250000, 30))[1], "ahead_of_timetable")

    def test_wrong_route_refused(self):
        # a point on another line (the Sylhet route) is on A rail line but not on 701's
        t2 = TG.train("709")
        lat, lng = TG.route("709").point_at(TG.route("709").length - 20000)
        ok, why, _, _ = self.v({"lat": lat, "lng": lng, "acc": 10, "at": _at(60)})
        self.assertFalse(ok)
        self.assertEqual(why, "off_route")
        self.assertIsNotNone(t2)


class FusionTests(SimpleTestCase):
    def test_median_outlier_and_stale(self):
        t = TG.train(NO)
        now = _at(120)
        f = lambda ch, age: {"chainage": ch, "at": now - timedelta(seconds=age), "speed_kmh": 60}
        r = TG.fuse(t, [f(100000, 10), f(100400, 20), f(99800, 30), f(140000, 5), f(10, 900)], now)
        self.assertEqual(r["label"], "live")
        self.assertEqual(r["sharers"], 3)
        self.assertEqual(r["dropped"], 1)
        self.assertAlmostEqual(r["chainage_m"], 100000, delta=500)
        self.assertIsNone(TG.fuse(t, [f(1, 900)], now))

    def test_estimate_is_labelled(self):
        e = TG.estimate(TG.train(NO), DAY, _at(160))
        self.assertEqual(e["label"], "estimate")
        self.assertEqual(e["state"], "running")
        self.assertFalse(e["approved"])
        self.assertAlmostEqual(e["chainage_m"], TG.route(NO).length / 2, delta=2000)


class ChatRuleTests(SimpleTestCase):
    def test_emergency_words(self):
        for w in ("আমি অসুস্থ", "সাহায্য করুন", "HELP please", "someone is sick",
                  "amake bachao", "ami osustho", "need a doctor"):
            self.assertTrue(TC.is_emergency(w), w)
        for w in ("very helpful", "ট্রেন কোথায়?", "train late?"):
            self.assertFalse(TC.is_emergency(w), w)

    def test_sms_compose(self):
        self.assertEqual(TC.sms_body("701"), "TR 701")
        self.assertEqual(TC.sms_uri("701"), "sms:16318?body=TR%20701")
        self.assertEqual(TC.SMS_COST_BDT, 4)

    def test_nickname_and_masking(self):
        self.assertEqual(TC.clean_nickname("নীল পাখি")[0], "নীল পাখি")
        self.assertEqual(TC.clean_nickname("01711223344")[1], "nickname_invalid")
        self.assertEqual(TC.clean_nickname("x")[1], "nickname_length")
        self.assertNotIn("01711223344", TC.clean_message("call 01711223344")[0])


def _user(n):
    return User.objects.create_user(name="Real Name %d" % n, phone="+88017000000%02d" % n,
                                    password="pw12345!")


def _client(u):
    c = APIClient()
    c.force_authenticate(u)
    return c


@mock.patch("core.train_views.flag_on", return_value=True)
class ApiTests(TestCase):
    def setUp(self):
        self.a, self.b, self.c = _user(1), _user(2), _user(3)
        self.day = TS.today().isoformat()

    def _join(self, u, nick):
        r = _client(u).post(V + "/train/%s/chat/join" % NO, {"date": self.day, "nickname": nick},
                            format="json")
        self.assertEqual(r.status_code, 200, r.content)

    def _say(self, u, text):
        return _client(u).post(V + "/train/%s/chat" % NO, {"date": self.day, "text": text},
                               format="json")

    def test_live_estimate_and_sms(self, _):
        r = _client(self.a).get(V + "/train/%s/live?date=%s" % (NO, self.day)).json()
        self.assertEqual(r["mode"], "estimate")
        self.assertEqual(r["estimate"]["label"], "estimate")
        self.assertEqual(r["sms"], {"to": "16318", "body": "TR 701", "cost_bdt": 4})
        self.assertFalse(r["train"]["approved"])
        self.assertTrue(r["stops"] and all(s["label"] == "estimate" for s in r["stops"]))

    def test_share_then_live_then_stop(self, _):
        t = TG.train(NO)
        d = TS.today()
        dep, arr = TG.times(t, d)
        now = dep + (arr - dep) / 2
        s = TS.start_share(self.a, t, d, now=now)
        ch = TG.sched_chainage(t, TG.route(NO), d, now)
        lat, lng = TG.route(NO).point_at(ch)
        r = TS.add_fixes(s, [{"lat": lat, "lng": lng, "acc": 10, "at": now.isoformat()}], now=now)
        self.assertEqual(r["accepted"], 1, r)
        v = TS.live_view(t, d, self.b, now=now)
        self.assertEqual(v["mode"], "live")
        self.assertEqual(v["live"]["sharers"], 1)
        self.assertFalse({"user", "user_id", "phone", "name"} & set(v["live"]))
        # a bad point is refused and counted
        r = TS.add_fixes(s, [{"lat": 0, "lng": 0, "acc": 10,
                              "at": (now + timedelta(seconds=30)).isoformat()}],
                         now=now + timedelta(seconds=30))
        self.assertEqual(r["rejected"], 1)
        # stop works even with the flag OFF
        with mock.patch("core.train_views.flag_on", return_value=False):
            r = _client(self.a).post(V + "/train/share/%d/stop" % s.id).json()
        self.assertEqual(r["status"], "ended")
        self.assertEqual(_client(self.b).post(V + "/train/share/%d/stop" % s.id).status_code, 404)

    def test_chat_privacy_and_request_only_circle(self, _):
        self.assertEqual(self._say(self.a, "hi").status_code, 409)      # join first
        self._join(self.a, "নীল")
        self._join(self.b, "সবুজ")
        r = self._say(self.a, "ট্রেন কোথায়? 01711223344")
        self.assertEqual(r.status_code, 200)
        room = _client(self.b).get(V + "/train/%s/chat?date=%s" % (NO, self.day))
        body = room.content.decode()
        for leak in ("Real Name", "+8801700", "01711223344", '"user', '"user_id'):
            self.assertNotIn(leak, body)
        msg = room.json()["messages"][0]
        self.assertEqual(set(msg), {"id", "nick", "mine", "text", "at", "emergency"})
        self.assertEqual(msg["nick"], "নীল")
        # B asks A -> nothing in My Circle until A decides
        mid = msg["id"]
        self.assertEqual(_client(self.b).post(V + "/train/chat/msg/%d/circle" % mid).status_code, 200)
        self.assertFalse(CircleMember.objects.filter(user=self.b, peer_user=self.a).exists())
        reqs = _client(self.a).get(V + "/train/%s/chat?date=%s" % (NO, self.day)).json()["circle_requests"]
        self.assertEqual([x["nick"] for x in reqs], ["সবুজ"])
        # only the recipient may act
        self.assertEqual(_client(self.b).post(V + "/train/chat/request/%d/accept" % reqs[0]["id"]).status_code, 404)
        self.assertEqual(_client(self.a).post(V + "/train/chat/request/%d/accept" % reqs[0]["id"]).status_code, 200)
        self.assertTrue(CircleMember.objects.filter(user=self.b, peer_user=self.a, state="accepted").exists())
        self.assertTrue(CircleMember.objects.filter(user=self.a, peer_user=self.b, state="accepted").exists())

    def test_decline_creates_nothing(self, _):
        self._join(self.a, "নীল")
        self._join(self.c, "লাল")
        mid = self._say(self.a, "hello").json()["message"]["id"]
        _client(self.c).post(V + "/train/chat/msg/%d/circle" % mid)
        req = TrainCircleRequest.objects.get()
        _client(self.a).post(V + "/train/chat/request/%d/decline" % req.id)
        self.assertFalse(CircleMember.objects.filter(user__in=(self.a, self.c)).exists())

    def test_outsider_cannot_act_on_messages(self, _):
        self._join(self.a, "নীল")
        mid = self._say(self.a, "hello").json()["message"]["id"]
        self.assertEqual(_client(self.c).post(V + "/train/chat/msg/%d/circle" % mid).status_code, 404)

    def test_block_and_reports_hide(self, _):
        self._join(self.a, "নীল")
        for u, n in ((self.b, "সবুজ"), (self.c, "লাল")):
            self._join(u, n)
        mid = self._say(self.a, "spam").json()["message"]["id"]
        _client(self.b).post(V + "/train/chat/msg/%d/block" % mid)
        self.assertEqual(_client(self.b).get(V + "/train/%s/chat?date=%s" % (NO, self.day)).json()["messages"], [])
        self.assertEqual(len(_client(self.c).get(V + "/train/%s/chat?date=%s" % (NO, self.day)).json()["messages"]), 1)
        d = _user(4)
        self._join(d, "হলুদ")
        for u in (self.b, self.c, d):
            _client(u).post(V + "/train/chat/msg/%d/report" % mid, {"reason": "spam"}, format="json")
        self.assertTrue(TrainChatMessage.objects.get(pk=mid).hidden)
        self.assertEqual(TrainChatReport.objects.count(), 3)

    def test_emergency_shows_hotlines(self, _):
        self._join(self.a, "নীল")
        r = self._say(self.a, "একজন যাত্রী অসুস্থ").json()
        self.assertTrue(r["emergency"])
        self.assertEqual(r["hotlines"], {"police": "999", "rail": "131"})

    def test_rate_limit(self, _):
        self._join(self.a, "নীল")
        codes = [self._say(self.a, "m%d" % i).status_code for i in range(TC.PER_MIN + 1)]
        self.assertEqual(codes[-1], 429)

    def test_purge_after_trip(self, _):
        self._join(self.a, "নীল")
        self._say(self.a, "hello")
        TS.start_share(self.a, TG.train(NO), TS.today())
        later = TrainChatMember.objects.get().ends_at + timedelta(minutes=1)
        stats = Counter()
        TS.purge(later, stats)
        self.assertEqual(TrainChatMessage.objects.count(), 0)
        self.assertEqual(TrainChatMember.objects.count(), 0)
        self.assertEqual(TrainShare.objects.count(), 0)
        self.assertGreater(stats["train_purged"], 0)
        # wired into the existing per-minute sweep
        from core import journey_watch
        self.assertIn("_sweep_train", open(journey_watch.__file__).read())

    def test_flag_off(self, flag):
        flag.return_value = False
        self.assertEqual(_client(self.a).get(V + "/train/search?q=701").status_code, 403)
        self.assertEqual(_client(self.a).post(V + "/train/%s/chat/leave" % NO,
                                              {"date": self.day}, format="json").status_code, 200)

    def test_search_and_bad_input(self, _):
        r = _client(self.a).get(V + "/train/search?q=সুবর্ণ").json()
        self.assertTrue(any(t["no"] == "701" for t in r["trains"]))
        self.assertEqual(_client(self.a).get(V + "/train/999/live").status_code, 404)
        self.assertEqual(_client(self.a).get(V + "/train/701/live?date=2001-01-01").status_code, 400)
        cfg = _client(self.a).get(V + "/train/config").json()
        self.assertEqual(cfg["hotlines"], {"police": "999", "rail": "131"})
        self.assertIn("ODbL", cfg["attribution"])
