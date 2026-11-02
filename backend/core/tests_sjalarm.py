"""sjalarm (owner Safe Journey order 3 Nov, Cards 2 + 3) — server side.
  * `train_schedule_verified` (Owner Admin switch): OFF -> every train says
    approved:false ("schedule not verified"); ON for all -> approved:true in
    search, live and estimate; an owner PREVIEW alone never flips it;
  * owner-only trip trace upload: plain users 403 (even with dest_alarm on),
    owner / staff / allow-listed tester can upload; stored OUTSIDE media,
    file name never carries the user's name; invalid traces refused; each
    uploader lists only their own files;
  * destination-alarm arrival notice: only the picked, accepted My Circle
    people, never other circle members; strangers' circle ids ignored; flag
    OFF -> 403.
"""
import json
import os
import shutil
import tempfile
from unittest import mock

from django.test import TestCase, override_settings
from rest_framework.test import APIClient

from core import feature_flags as FF
from core import sjalarm as SJ
from core.models import CircleMember, FeatureFlag, User

V = "/api/v1"


def _user(n, **kw):
    return User.objects.create_user(name="Real Name %d" % n, phone="+88017100000%02d" % n,
                                    password="pw12345!", **kw)


def _client(u):
    c = APIClient()
    c.force_authenticate(u)
    c.credentials(HTTP_ACCEPT_LANGUAGE="en")
    return c


def _flag(key, **kw):
    FeatureFlag.objects.update_or_create(key=key, defaults=kw)
    FF.invalidate()


def _pair(a, b):
    ab = CircleMember.objects.create(user=a, peer_user=b, name=b.name, state="accepted")
    CircleMember.objects.create(user=b, peer_user=a, name=a.name, state="accepted",
                                direction="incoming")
    return ab


def _trace(**kw):
    t = {"format": "assisto-trip-trace/1", "mode": "cityBus", "set_m": 10,
         "stop": {"name": "Shahbag", "lat": 23.7385, "lng": 90.396},
         "points": [{"t": "2026-11-03T08:00:0%dZ" % i, "lat": 23.75 - i * 0.0001,
                     "lng": 90.39, "acc": 8.5, "speed": 7.1} for i in range(5)]}
    t.update(kw)
    return t


class ScheduleVerifiedTests(TestCase):
    def setUp(self):
        FF.invalidate()
        self.u = _user(1)
        self.owner = _user(2, is_superuser=True, is_staff=True)

    def tearDown(self):
        FF.invalidate()

    @mock.patch("core.train_views.flag_on", return_value=True)
    def test_off_until_owner_switches_on_for_all(self, _):
        r = _client(self.u).get(V + "/train/search?q=701").json()
        self.assertTrue(r["trains"])
        self.assertTrue(all(t["approved"] is False for t in r["trains"]))
        # the owner's preview alone must NOT hide the label on the owner's phone
        r = _client(self.owner).get(V + "/train/search?q=701").json()
        self.assertTrue(all(t["approved"] is False for t in r["trains"]))
        self.assertFalse(SJ.schedule_verified())
        _flag("train_schedule_verified", enabled_all=True)
        self.assertTrue(SJ.schedule_verified())
        r = _client(self.u).get(V + "/train/search?q=701").json()
        self.assertTrue(all(t["approved"] is True for t in r["trains"]))
        live = _client(self.u).get(V + "/train/701/live?date=2026-11-03").json()
        self.assertTrue(live["train"]["approved"])
        if live.get("estimate"):
            self.assertTrue(live["estimate"]["approved"])
        cfg = _client(self.u).get(V + "/train/config").json()
        self.assertTrue(cfg["data"]["schedule_verified"])

    def test_registry_defaults_off(self):
        self.assertFalse(FF.meta("train_schedule_verified")["default_on"])
        self.assertFalse(FF.meta("trip_recorder")["default_on"])
        self.assertEqual(FF.meta("trip_recorder")["routes"], [])


class TripTraceTests(TestCase):
    def setUp(self):
        FF.invalidate()
        self.dir = tempfile.mkdtemp(prefix="trip_traces_")
        self.addCleanup(shutil.rmtree, self.dir, True)
        o = override_settings(TRIP_TRACE_ROOT=self.dir)
        o.enable()
        self.addCleanup(o.disable)
        self.u = _user(3)
        self.tester = _user(4)
        self.owner = _user(5, is_superuser=True, is_staff=True)

    def tearDown(self):
        FF.invalidate()

    def test_plain_user_cannot_upload_or_list(self):
        _flag("dest_alarm", enabled_all=True)       # the alarm is on for everybody...
        r = _client(self.u).post(V + "/train/trace", {"trace": _trace()}, format="json")
        self.assertEqual(r.status_code, 403)       # ...the recorder is still owner-only
        self.assertEqual(_client(self.u).get(V + "/train/trace").status_code, 403)
        self.assertEqual(os.listdir(self.dir), [])

    def test_owner_uploads_privately(self):
        r = _client(self.owner).post(V + "/train/trace", {"trace": _trace()}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        name = r.json()["name"]
        self.assertTrue(name.startswith("real_cityBus_"))
        self.assertNotIn("Real", name)
        path = os.path.join(self.dir, "u%d" % self.owner.pk, name)
        self.assertTrue(os.path.isfile(path))
        self.assertFalse(path.startswith(str(os.path.abspath("media"))))
        saved = json.load(open(path))
        self.assertEqual(saved["format"], "assisto-trip-trace/1")
        self.assertIs(saved["synthetic"], False)
        self.assertEqual(len(saved["points"]), 5)
        self.assertEqual(saved["points"][0]["speed"], 7.1)
        self.assertEqual(saved["stop"]["name"], "Shahbag")
        lst = _client(self.owner).get(V + "/train/trace").json()["traces"]
        self.assertEqual([x["name"] for x in lst], [name])

    def test_allow_listed_tester_can_upload_and_sees_only_own(self):
        _flag("trip_recorder", enabled_all=False, allow_user_ids=[self.tester.pk])
        r = _client(self.tester).post(V + "/train/trace", {"trace": _trace(mode="train")},
                                      format="json")
        self.assertEqual(r.status_code, 200, r.content)
        _client(self.owner).post(V + "/train/trace", {"trace": _trace()}, format="json")
        mine = _client(self.tester).get(V + "/train/trace").json()["traces"]
        self.assertEqual(len(mine), 1)
        self.assertTrue(mine[0]["name"].startswith("real_train_"))

    def test_bad_traces_refused(self):
        c = _client(self.owner)
        for bad, why in [({"format": "x"}, "bad_format"),
                         (_trace(points=[]), "no_points"),
                         (_trace(points=[{"t": "x", "lat": 123, "lng": 90}]), "bad_point"),
                         (_trace(points=[{"t": "x", "lat": "23", "lng": 90}]), "bad_point"),
                         ("not a dict", "bad_format")]:
            r = c.post(V + "/train/trace", {"trace": bad}, format="json")
            self.assertEqual(r.status_code, 400, bad)
            self.assertEqual(r.json()["reason"], why)
        with mock.patch.object(SJ, "TRACE_MAX_POINTS", 3):
            r = c.post(V + "/train/trace", {"trace": _trace()}, format="json")
            self.assertEqual(r.json()["reason"], "too_many_points")

    def test_stop_name_control_chars_stripped(self):
        clean, why = SJ.clean_trace(_trace(stop={"name": "Sha\nhbag\x00" + "x" * 200,
                                                 "lat": 23.7, "lng": 90.3}))
        self.assertIsNone(why)
        self.assertEqual(clean["stop"]["name"][:7], "Shahbag")
        self.assertLessEqual(len(clean["stop"]["name"]), SJ.STOP_MAX)


class ArrivedNoticeTests(TestCase):
    def setUp(self):
        FF.invalidate()
        self.a, self.mum, self.friend, self.stranger = _user(6), _user(7), _user(8), _user(9)
        self.mum_edge = _pair(self.a, self.mum)
        self.friend_edge = _pair(self.a, self.friend)
        self.stranger_edge = _pair(self.stranger, self.friend)
        self.pushes = []
        p = mock.patch("core.push.safe_push",
                       side_effect=lambda user, kind, *a, **k: self.pushes.append((user.pk, kind)) or True)
        p.start()
        self.addCleanup(p.stop)

    def tearDown(self):
        FF.invalidate()

    def test_flag_off_403(self):
        r = _client(self.a).post(V + "/train/alarm/arrived",
                                 {"stop": "Shahbag", "circle_ids": [self.mum_edge.pk]}, format="json")
        self.assertEqual(r.status_code, 403)

    @mock.patch("core.train_views.flag_on", return_value=True)
    def test_only_picked_people_get_it(self, _):
        r = _client(self.a).post(
            V + "/train/alarm/arrived",
            {"stop": "Shahbag", "circle_ids": [self.mum_edge.pk, self.stranger_edge.pk, "x"]},
            format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["recipients"], 1)
        got = {u for u, _k in self.pushes}
        self.assertIn(self.mum.pk, got)
        self.assertNotIn(self.friend.pk, got)       # in the circle but not picked
        from core.models import FamilyAlertDelivery
        d = FamilyAlertDelivery.objects.get(recipient=self.mum)
        self.assertEqual(d.kind, "dest_arrived")

    @mock.patch("core.train_views.flag_on", return_value=True)
    def test_nobody_picked_or_only_strangers(self, _):
        for ids in ([], [self.stranger_edge.pk], None):
            r = _client(self.a).post(V + "/train/alarm/arrived", {"stop": "X", "circle_ids": ids},
                                     format="json")
            self.assertEqual(r.status_code, 400)
            self.assertEqual(r.json()["reason"], "no_people")
        self.assertEqual(self.pushes, [])

    def test_texts_carry_name_and_stop(self):
        from core import family_alerts as FA
        seen = {}

        def spy(sender, kind, key, payload=None, recipients=None, **kw):
            seen.update(payload)
            return {"recipients": len(recipients)}
        with mock.patch.object(FA, "alert", side_effect=spy):
            stats, why = SJ.notify_arrived(self.a, "শাহবাগ", [self.mum_edge.pk])
        self.assertIsNone(why)
        self.assertIn("{name}", seen["title_bn"])
        self.assertIn("শাহবাগ", seen["body_bn"])
        self.assertIn("শাহবাগ", seen["body_en"])
        self.assertIn("dest_arrived", FA.KINDS)
