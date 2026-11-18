"""vehicle-e2e (18 Nov): the ST-906 emulator E2E (reality flow 12v) — server side.

* The EXACT frames the flow's simulated ST-906 writes (app/integration_test/
  flows/vehicle_st906_flow.dart: text V1 + 32-byte binary '$' record) parse
  to the right fix, and the binary vector equals the reference encoder.
* tracker/protocols/h02.binary_packet wrote 5 minute digits for longitude
  ('%05d'): any longitude under 10 minutes (e.g. 90.0100 E) made an odd hex
  string and the simulator crashed — fixed to 6 digits.
* seed_reality._vehicle only acts for the 'vehicle' drive: engine-cut
  allow-list for A, A's Security PIN, online window 60 s (its lower bound).
"""
import os
from datetime import datetime, timezone as dtz
from unittest import mock

from django.contrib.auth import get_user_model
from django.contrib.auth.hashers import check_password
from django.test import SimpleTestCase, TestCase

from tracker.protocols import h02

AT = datetime(2026, 11, 18, 6, 45, 12, tzinfo=dtz.utc)
DEV = "9100000001"
# vehicle_st906_flow.dart _St906.v1(AT, 23.756, 90.374, 30 km/h, ign on, course 90)
TEXT_V1 = (b"*HQ,9100000001,V1,064512,A,2345.3600,N,09022.4400,E,16.20,90,181126,"
           b"FFFFFFFF,470,01,0001,0001#")
# _St906.bin(AT, 23.756, 90.374, 30 km/h, ign on, course 90)
BIN_HEX = ("9100000001" "064512" "181126" "23453600" "06" "090224400e" "016090" "ffffffff")


class St906SimFrames(SimpleTestCase):
    def test_text_v1_as_the_flow_writes_it(self):
        frames, rest = h02.split_frames(TEXT_V1)
        self.assertEqual((len(frames), rest), (1, b""))
        p = h02.parse_frame(frames[0])
        f = p["fix"]
        self.assertEqual((p["kind"], p["imei"], f["at"]), ("gps", DEV, AT))
        self.assertAlmostEqual(f["lat"], 23.756, places=5)
        self.assertAlmostEqual(f["lng"], 90.374, places=5)
        self.assertAlmostEqual(f["speed_kmh"], 30.0, places=0)
        self.assertTrue(f["ignition"])
        off = TEXT_V1.replace(b"FFFFFFFF", b"FFFFFBFF")
        self.assertFalse(h02.parse_frame(off)["fix"]["ignition"])

    def test_binary_record_as_the_flow_writes_it(self):
        b = (b"$" + bytes.fromhex(BIN_HEX)).ljust(32, b"\x00")
        self.assertEqual(b, h02.binary_packet(DEV, AT, 23.756, 90.374, 30, 90,
                                              status=0xFFFFFFFF))
        frames, rest = h02.split_frames(b + TEXT_V1)        # coalesced TCP read
        self.assertEqual((len(frames), rest), (2, b""))
        p = h02.parse_frame(frames[0])
        f = p["fix"]
        self.assertEqual((p["imei"], f["at"], f["course"]), (DEV, AT, 90))
        self.assertAlmostEqual(f["lat"], 23.756, places=5)
        self.assertAlmostEqual(f["lng"], 90.374, places=5)
        self.assertAlmostEqual(f["speed_kmh"], 16 * h02.KNOT_KMH, places=1)
        self.assertTrue(f["valid"] and f["ignition"])

    def test_binary_encoder_small_minutes(self):
        # 90.0100 E = 90 deg 0.6 min -> lng_m 6000: was 5 digits -> odd hex
        b = h02.binary_packet(DEV, AT, 23.0050, 90.0100, 40, 10)
        f = h02.parse_frame(h02.split_frames(b)[0][0])["fix"]
        self.assertAlmostEqual(f["lng"], 90.01, places=4)
        self.assertAlmostEqual(f["lat"], 23.005, places=4)

    def test_relay_commands_are_what_the_flow_expects(self):
        cut = h02.server_command(DEV, h02.COMMANDS["engine_cut"], AT)
        self.assertEqual(cut, b"*HQ,9100000001,S20,064512,1,1#")
        self.assertEqual(h02.server_command(DEV, h02.COMMANDS["engine_restore"], AT),
                         b"*HQ,9100000001,S20,064512,1,0#")
        rep = h02.parse_frame(b"*HQ,9100000001,V4,S20,DONE,064513#")
        self.assertEqual(rep["kind"], "cmd_reply")
        self.assertTrue(h02.reply_ok(rep["text"]))


class SeedVehicleBlock(TestCase):
    def _run(self, drive):
        from core.management.commands.seed_reality import Command
        u = get_user_model().objects.create_user(name="A", phone="01710009901", password="pw")
        c = Command()
        c.steps = []
        with mock.patch.dict(os.environ, {"REALITY_DRIVE": drive}):
            c._vehicle({"a": u})
        return u, c.steps

    def test_noop_for_other_groups(self):
        from core import vehicle_service as VS
        _, steps = self._run("start+personal")
        self.assertEqual(steps, [])
        self.assertEqual(VS.vcfg()["online_window_s"], 600)

    def test_vehicle_drive(self):
        from core import feature_flags as FF, vehicle_service as VS
        from core.models import ProtectedPhone
        u, steps = self._run("start+vehicle")
        self.assertTrue(steps and all(s["ok"] for s in steps), steps)
        self.assertTrue(FF.is_on("vehicle_engine_cut", u))
        ph = ProtectedPhone.objects.filter(owner=u).first()
        self.assertTrue(check_password("2468", ph.security_pin_hash))
        self.assertEqual(VS.vcfg()["online_window_s"], 60)


class SilentSweepShortMinutes(TestCase):
    """sweep_silent had a hard 10-minute pre-filter: silent_min 1-9 never
    alerted (reality flow 12v, run 44288248689)."""

    def test_silent_min_below_ten_alerts_once(self):
        from datetime import timedelta
        from django.utils import timezone
        from core import vehicle_service as VS
        from core.models import NotifEvent, VehicleTracker
        u = get_user_model().objects.create_user(name="O", phone="01710009902", password="pw")
        now = timezone.now()
        t = VehicleTracker.objects.create(
            owner=u, imei="9100000002", name="Dhaka Car", state="paired", protocol="h02",
            paired_at=now, last_seen_at=now - timedelta(minutes=3),
            last_lat=23.7505, last_lng=90.3935, alert_prefs={"silent_min": 2})
        self.assertEqual(VS.sweep_silent(now), 1)
        self.assertTrue(NotifEvent.objects.filter(user=u, title_en__contains="not responding").exists())
        self.assertEqual(VS.sweep_silent(now + timedelta(seconds=30)), 0)   # once per silence
        t.alert_prefs = {"silent_min": 5}
        t.alert_state = {}
        t.save(update_fields=["alert_prefs", "alert_state"])
        self.assertEqual(VS.sweep_silent(now), 0)                          # 3 < 5 min
