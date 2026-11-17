"""gboxlinux — the Linux / Raspberry Pi / Windows Guard Box's server side:
power-cut / internet-down events on the heartbeat (told once, in Bangla and
English, to the owner + family viewers) and the box's "camera lost" health
warning. Made-up sample data only."""
import time

from django.core.cache import cache
from django.test import SimpleTestCase
from rest_framework.test import APIClient

from core.logic import guardbox_events as GE
from core.logic import phonecam as PC
from core.tests_cctvphone import _Base


class PureBoxEventTests(SimpleTestCase):
    def test_clean_bounds_and_drops_bad_rows(self):
        now = 1_800_000_000.0
        raw = [
            {"id": "a1", "kind": "power_back", "from": now - 3000, "to": now - 600},
            {"id": "b2", "kind": "net_back", "from": now - 900, "to": now + 99999,
             "queued_alerts": 3},
            {"id": "c3", "kind": "power_cut", "from": now - 10, "battery_pct": 77},
            {"id": "d4", "kind": "reboot", "from": now},                 # unknown kind
            {"id": "", "kind": "net_back", "from": now - 10, "to": now},  # no id
            {"id": "e5", "kind": "net_back", "from": now - 30 * 86400, "to": now},  # too old
            {"id": "f6", "kind": "power_back", "from": now - 60, "to": now - 600},  # to < from
            "junk",
        ]
        evs = GE.clean(raw, now)
        self.assertEqual([e["id"] for e in evs], ["a1", "b2", "c3", "f6"])
        self.assertEqual(evs[0]["minutes"], 40)
        self.assertEqual(evs[1]["to"], now)            # never in the future
        self.assertEqual(evs[1]["queued_alerts"], 3)
        self.assertIsNone(evs[2]["to"])
        self.assertEqual(evs[2]["battery_pct"], 77)
        self.assertEqual(evs[3]["minutes"], 0)         # clock not synced: never negative
        self.assertEqual(GE.clean("x", now), [])
        self.assertEqual(len(GE.clean([raw[0]] * 50, now)), GE.MAX_PER_BEAT)

    def test_texts_bangla_digits_and_plain_words(self):
        now = 1_800_000_000.0
        cases = [
            {"id": "a", "kind": "power_back", "from": now - 47 * 60, "to": now},
            {"id": "b", "kind": "power_back", "from": now - 600, "to": now, "on_battery": True},
            {"id": "c", "kind": "power_cut", "from": now, "battery_pct": 55},
            {"id": "d", "kind": "net_back", "from": now - 35 * 60, "to": now, "queued_alerts": 3},
            {"id": "e", "kind": "net_back", "from": now - 35 * 60, "to": now},
        ]
        for ev in GE.clean(cases, now):
            tbn, ten, bbn, ben = GE.text(ev, "Sample Shop", now_ts=now)
            self.assertIn("Sample Shop", tbn)
            self.assertIn("Sample Shop", ten)
            for ch in "0123456789":
                self.assertNotIn(ch, bbn, (ev["kind"], bbn))     # Bangla digits only
            self.assertNotIn("চুরি", bbn)
            self.assertNotIn("theft", ben.lower())
        ev = GE.clean(cases[:1], now)[0]
        self.assertIn("47 minutes", GE.text(ev, "S", now_ts=now)[3])
        self.assertIn("৪৭", GE.text(ev, "S", now_ts=now)[2])
        ev = GE.clean(cases[3:4], now)[0]
        self.assertIn("3 alerts", GE.text(ev, "S", now_ts=now)[3])

    def test_box_cam_lost_health_warning(self):
        h = PC.clean_health({"box_cam_lost": True})
        self.assertEqual(PC.active_conditions(h), {"box_cam_lost"})
        kinds, _ = PC.health_warnings(h, {}, 1000)
        self.assertEqual(kinds, ["box_cam_lost"])
        self.assertNotIn("box_cam_lost", PC.clean_health({"box_cam_lost": 1}))
        tbn, ten, bbn, ben = PC.warning_text("box_cam_lost", "Gate", h)
        self.assertIn("Guard Box", ben)
        self.assertIn("Gate", bbn)


class HeartbeatBoxEventTests(_Base):
    def setUp(self):
        super().setUp()
        cache.clear()

    def _paired(self):
        r = self.claim(self.code()["code"], name="Gate", platform="linux-arm64",
                       model="Raspberry Pi 4 Model B")
        self.assertEqual(r.status_code, 201, r.data)
        return r.data["camera_token"]

    def test_events_told_once_to_owner_and_family(self):
        from core.models import NotifEvent
        tok = self._paired()
        now = time.time()
        body = {"camera_token": tok, "caps": ["gateway", "speaker"], "platform": "linux-arm64",
                "box_events": [{"id": "pw1", "kind": "power_back", "from": now - 1800,
                                "to": now - 60, "after_reboot": True},
                               {"id": "nt1", "kind": "net_back", "from": now - 900,
                                "to": now - 30, "queued_alerts": 2}]}
        before = NotifEvent.objects.filter(meta__source="guard_box").count()
        c = APIClient()
        r = c.post("/api/v1/shop/heartbeat", body, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data["box_events_ok"], 2)
        rows = NotifEvent.objects.filter(meta__source="guard_box")
        self.assertEqual(rows.count() - before, 4)          # 2 events x owner + family viewer
        own = rows.filter(user=self.owner)
        self.assertEqual(sorted(own.values_list("meta__kind", flat=True)),
                         ["net_back", "power_back"])
        self.assertTrue(any("Power is back" in t for t in own.values_list("title_en", flat=True)))
        # the box retries (lost answer): nothing is told twice
        r = c.post("/api/v1/shop/heartbeat", body, format="json")
        self.assertEqual(r.data["box_events_ok"], 2)
        self.assertEqual(NotifEvent.objects.filter(meta__source="guard_box").count() - before, 4)

    def test_no_box_events_key_without_events_and_bad_token(self):
        tok = self._paired()
        c = APIClient()
        r = c.post("/api/v1/shop/heartbeat", {"camera_token": tok}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertNotIn("box_events_ok", r.data)
        r = c.post("/api/v1/shop/heartbeat", {"camera_token": "nope", "box_events": [
            {"id": "x", "kind": "net_back", "from": time.time() - 600, "to": time.time()}]},
            format="json")
        self.assertEqual(r.status_code, 401)

    def test_box_cam_lost_health_pushes_warning(self):
        from core.models import NotifEvent
        tok = self._paired()
        r = APIClient().post("/api/v1/shop/heartbeat",
                             {"camera_token": tok, "health": {"box_cam_lost": True}},
                             format="json")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(NotifEvent.objects.filter(user=self.owner, meta__kind="box_cam_lost").exists())
