"""train-e2e — bugs the Train Tracker emulator E2E found (each one a test).

1. The station line ignored the engine: riders via /train/ping moved the
   engine's live state, but the timeline (v1 line) stayed at the timetable
   estimate, and "N passengers sharing live" counted v1 shares only.
2. A point inside the 10 s recompute lock waited for the next ping or the
   minute tick (ping-to-live up to ~60 s); now the next read catches up.
3. A check-in from a phone 40+ km from the station was "pending" and could
   be confirmed by one more report; now it is "not counted" and never helps.
4. A stopped Redis cost 0.5 s socket timeout on EVERY store call; now a 30 s
   breaker falls back to the cache at once.
5. GET /train/<no>/live (polled every 30 s, ~20-30 KB JSON) was never
   compressed; now gzip when the phone accepts it (2G).
All data is made up (sample users, the official 771 timetable).
"""
import gzip
import json
from datetime import timedelta
from unittest import mock

from django.test import TestCase, override_settings
from rest_framework.test import APIClient

from core import train_engine as TE
from core import train_service as TS
from core import train_source as SRC
from core.logic import train_geo as TG
from core.models import TrainCheckin, TrainObservation
from core.tests_train_engine import (DAY, IBRAHIMABAD, NO, V, EngineBase, _at, _ch, _pt,
                                     _user)

NATORE, SANTAHAR = "natore", "santahar"


class LineFollowsEngineTests(EngineBase):
    def test_timeline_and_rider_count_follow_the_engine(self):
        c = (_ch(NATORE) + _ch(SANTAHAR)) / 2.0
        now = None
        for lag in (0.0, 120.0, 260.0):
            _, now = self.feed(self.trip(), c - lag - 3000, 300)
        TE.maybe_recompute(self.t, DAY, now, force=True)
        t1 = TG.train(NO)
        view = TS.live_view(t1, DAY, None, now=now)
        TE.enrich_live_view(view, t1, DAY, now=now)
        line = view["line"]
        here = line["stations"][line["now_index"]]["id"]
        nxt = line["stations"][line["next_index"]]["id"]
        ids = [s["id"] for s in line["stations"]]
        # between Natore and Santahar (non-halt stations may sit in between)
        self.assertTrue(ids.index(NATORE) <= ids.index(here) < ids.index(SANTAHAR), here)
        self.assertTrue(ids.index(here) < ids.index(nxt) <= ids.index(SANTAHAR), nxt)
        self.assertEqual(view["sharers"], 3)
        self.assertEqual(view["live"]["sharers"], 3)
        self.assertEqual(view["freshness"]["state"], "live")
        self.assertGreater(view["live"]["speed_kmh"], 20)

    def test_reported_text_moves_the_line_too(self):
        TE._add_obs(self.t, DAY, "text", IBRAHIMABAD, "left", _at(150))
        now = _at(151)
        TE.maybe_recompute(self.t, DAY, now, force=True)
        t1 = TG.train(NO)
        view = TS.live_view(t1, DAY, None, now=now)
        TE.enrich_live_view(view, t1, DAY, now=now)
        line = view["line"]
        ids = [s["id"] for s in line["stations"]]
        self.assertGreaterEqual(line["now_index"], ids.index(IBRAHIMABAD))
        self.assertEqual(view["engine"]["mode"], "reported")


class CatchUpTests(EngineBase):
    def test_point_inside_the_lock_window_shows_on_the_next_read(self):
        c = _ch(IBRAHIMABAD) + 5000
        _, now = self.feed(self.trip(), c, 140, n=3)
        self.assertEqual(TE.STORE.get(TE.live_key(NO))["contributors"], 1)
        tr2 = self.trip()
        res = TE.ingest(tr2, [_pt(c + 1500, 141, speed=16), _pt(c + 2400, 142, speed=16)],
                        now=now + timedelta(seconds=1))
        self.assertEqual(res["accepted"], 2)
        # the lock held: the stored state still says 1 rider ...
        self.assertEqual(TE.STORE.get(TE.live_key(NO))["contributors"], 1)
        # ... and the very next read catches up
        r = TE.read(self.t, DAY, now + timedelta(seconds=2))
        self.assertEqual(r["contributors"], 2)
        self.assertIsNone(TE.STORE.get(TE._dirty_key(NO)))


class FarCheckinTests(EngineBase):
    def test_far_away_phone_is_not_counted_and_never_confirms(self):
        a, b = _user(41), _user(42)
        st = SRC.stations()[IBRAHIMABAD]
        at = _at(125)
        r = TE.checkin(a, self.t, DAY, IBRAHIMABAD, "reached", at.isoformat(),
                       st["lat"] + 0.5, st["lng"], 20, now=at + timedelta(seconds=30))
        self.assertEqual((r["status"], r["reason"], r["points"]),
                         ("rejected", "far_from_station", 0))
        # a second (5 km, plausible) report is still alone: pending
        r = TE.checkin(b, self.t, DAY, IBRAHIMABAD, "reached", at.isoformat(),
                       st["lat"] + 0.045, st["lng"], 20, now=at + timedelta(seconds=40))
        self.assertEqual(r["status"], "pending")
        self.assertFalse(TrainObservation.objects.exists())
        # asking again does not turn it around
        r = TE.checkin(a, self.t, DAY, IBRAHIMABAD, "reached", at.isoformat(),
                       st["lat"], st["lng"], 20, now=at + timedelta(seconds=50))
        self.assertEqual((r["status"], r["reason"]), ("rejected", "already"))
        self.assertEqual(TrainCheckin.objects.get(user=a).status, "rejected")

    def test_two_agreeing_reports_are_accepted(self):
        a, b = _user(43), _user(44)
        st = SRC.stations()[IBRAHIMABAD]
        at = _at(125)
        r1 = TE.checkin(a, self.t, DAY, IBRAHIMABAD, "reached", at.isoformat(),
                        st["lat"] + 0.045, st["lng"], 20, now=at + timedelta(seconds=30))
        r2 = TE.checkin(b, self.t, DAY, IBRAHIMABAD, "reached", at.isoformat(),
                        None, None, None, now=at + timedelta(seconds=40))
        self.assertEqual((r1["status"], r2["status"]), ("pending", "accepted"))
        self.assertEqual(TrainCheckin.objects.get(user=a).status, "accepted")


class RedisBreakerTests(TestCase):
    def tearDown(self):
        TE.LiveStore._client = None
        TE.LiveStore._url = None
        TE.LiveStore._down_until = 0.0

    def test_one_failure_then_the_cache_without_waiting(self):
        url = "redis://127.0.0.1:1/0"
        fake = mock.Mock()
        fake.get.side_effect = OSError("refused")
        fake.set.side_effect = OSError("refused")
        TE.LiveStore._client, TE.LiveStore._url = fake, url
        with override_settings(TRAIN_LIVE_REDIS_URL=url):
            store = TE.LiveStore()
            store.set("train:test", {"a": 1}, 60)      # set fails over to the cache too
            self.assertEqual(store.get("train:test"), {"a": 1})
            self.assertEqual(store.get("train:test"), {"a": 1})
        # only the first call tried Redis; the next ones went straight to the cache
        self.assertEqual(fake.set.call_count, 1)
        self.assertEqual(fake.get.call_count, 0)


@mock.patch("core.train_views.flag_on", return_value=True)
class LiveGzipTests(TestCase):
    def test_live_view_is_gzipped_for_phones(self, _):
        c = APIClient()
        c.force_authenticate(_user(51))
        day = TS.today().isoformat()
        r = c.get(V + "/train/%s/live?date=%s" % (NO, day), HTTP_ACCEPT_ENCODING="gzip")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r["Content-Encoding"], "gzip")
        body = json.loads(gzip.decompress(r.content))
        self.assertIn("line", body)
        self.assertLess(len(r.content), len(json.dumps(body)) / 3)
        plain = c.get(V + "/train/%s/live?date=%s" % (NO, day)).json()
        self.assertEqual(plain["train"]["no"], NO)


class SearchTests(TestCase):
    def test_english_name_and_bangla_digits_find_rangpur_express(self):
        for q in ("Rangpur Express", "rangpur express", "৭৭১", "771"):
            nos = [r["no"] for r in TS.search(q)]
            self.assertIn("771", nos, q)
        r = next(x for x in TS.search("Rangpur Express") if x["no"] == "772")
        self.assertEqual(r["name_en"], "Rangpur Express")
        # the data lane's official list: times and off days
        a = next(x for x in TS.search("771") if x["no"] == "771")
        self.assertEqual((a["dep"], a["arr"], a["off_days"]), ("09:10", "19:00", [0]))
        self.assertEqual((r["dep"], r["arr"], r["off_days"]), ("20:00", "06:00", [6]))
