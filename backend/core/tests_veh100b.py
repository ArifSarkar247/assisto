"""
veh100b — vehicle tracking robustness, proven against frames RECORDED from
real devices (tracker/fixtures/traccar_frames.json: Traccar's public decoder
tests, Apache-2.0, source + date in the file) and end-to-end through the real
tracker server over TCP:

  * corpus sweep: every recorded GT06 / H02 (text + binary) / GPS103 /
    Teltonika / JT808 frame decodes or fails with the protocol's own
    FrameError — never a crash — and the decoded counts never regress;
  * exact values on hand-checked recorded frames (Traccar's own expectations:
    GT06 0x26 = tamper, 0xA4 = low battery, H02 binary 4.69898 / -74.06971 at
    2015-08-31 21:53:21 UTC, JT808 0x0704 = 14 satellites ...);
  * clock: a tracker set to local time (UTC+6) keeps every fix; GPS-rollover
    dates are dropped;
  * late alerts (offline backlog) say when; non-safety ones go in-app only;
  * GPS jump never flips a geofence; fence hysteresis; stale backlog never
    drives alert state;
  * engine hot + parked fuel drop (OBD / CAN / JT808 fuel);
  * real TCP: JT808 4G tracker register -> auth -> drive -> blind-area batch
    -> SOS -> interval params -> engine cut (relay bit confirmed); Concox 4G
    (0xA0 / 0xA4) drive + alarm; Sinotrack binary H02 drive; a dropped socket
    is unregistered and the reconnected device gets the queued command.
"""
import asyncio
import json
import os
from datetime import datetime, timedelta, timezone as dtz

from django.test import SimpleTestCase
from django.utils import timezone
from rest_framework.test import APITestCase

from core.logic import vehicle_tracking as VT
from core.models import VehiclePosition, VehicleTracker, VehicleAuditLog, VehicleCommand
from core.tests_e2e_vehicle import _TcpBase, scenario_path, HOME
from core.tests_v1_vehicle import _Setup, IMEI_A, cut_confirmed
from tracker.protocols import gt06, h02, jt808, teltonika, tk103

FIX = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "tracker", "fixtures", "traccar_frames.json")
PORT_JT = 15033
PORT_4G = 15034
PORT_H02B = 15035
PORT_RECON = 15036
JT_ID = "13800138000"
H02B_ID = "9180271180"


def _corpus():
    with open(FIX) as f:
        return json.load(f)


def _kinds(items, fn, err):
    out = {}
    for x in items:
        try:
            k = fn(x)
        except err:
            k = "frame_error"
        out[k] = out.get(k, 0) + 1
    return out


def _one(split, parse, data):
    frames, _ = split(data)
    return parse(frames[0])["kind"] if frames else "none"


# =========================================================================== corpus

class RecordedFrameCorpusTests(SimpleTestCase):
    """Never a crash on a real frame; decoded counts never regress (numbers
    measured on 2 Nov — they only go up when a decoder learns more)."""

    def setUp(self):
        self.c = _corpus()
        self.assertIn("Traccar", self.c["_source"])

    def test_gt06(self):
        k = _kinds(self.c["gt06_hex"],
                   lambda h: _one(gt06.split_frames, gt06.parse_frame, bytes.fromhex(h)),
                   gt06.FrameError)
        self.assertGreaterEqual(k.get("gps", 0), 24, k)
        self.assertGreaterEqual(k.get("alarm", 0), 21, k)
        self.assertGreaterEqual(k.get("status", 0), 10, k)
        self.assertGreaterEqual(k.get("login", 0), 6, k)
        self.assertLessEqual(k.get("frame_error", 0), 15, k)

    def test_h02_text_and_binary(self):
        k = _kinds(self.c["h02_text"],
                   lambda t: _one(h02.split_frames, h02.parse_frame, t.encode()),
                   h02.FrameError)
        self.assertGreaterEqual(k.get("gps", 0), 32, k)
        self.assertLessEqual(k.get("frame_error", 0), 2, k)
        k = _kinds(self.c["h02_binary_hex"],
                   lambda h: _one(h02.split_frames, h02.parse_frame, bytes.fromhex(h)),
                   h02.FrameError)
        self.assertEqual(k, {"gps": len(self.c["h02_binary_hex"])})

    def test_gps103(self):
        def f(t):
            t = t if t.endswith(";") else t + ";"
            return _one(tk103.split_frames, tk103.parse_frame, t.encode())
        k = _kinds(self.c["gps103_text"], f, tk103.FrameError)
        self.assertGreaterEqual(k.get("gps", 0), 50, k)

    def test_teltonika(self):
        def f(h):
            pk, _ = teltonika.split_packet(bytes.fromhex(h))
            return teltonika.parse_packet(pk)["kind"] if pk else "none"
        k = _kinds(self.c["teltonika_hex"], f, teltonika.FrameError)
        self.assertGreaterEqual(k.get("avl", 0), 24, k)

    def test_jt808(self):
        k = _kinds(self.c["jt808_hex"],
                   lambda h: _one(jt808.split_frames, jt808.parse_frame, bytes.fromhex(h)),
                   jt808.FrameError)
        self.assertGreaterEqual(k.get("gps", 0), 43, k)
        self.assertGreaterEqual(k.get("gps_batch", 0), 5, k)
        self.assertGreaterEqual(k.get("register", 0), 4, k)


class RecordedFrameValueTests(SimpleTestCase):
    """Exact values on recorded frames (expectations = Traccar's own test
    assertions or hand-decoded bytes, written next to each)."""

    def gt(self, h):
        frames, _ = gt06.split_frames(bytes.fromhex(h))
        return gt06.parse_frame(frames[0])

    def test_gt06_alarm_frames_fixed_size_lbs(self):
        # Traccar: ALARM_TAMPERING. LBS length byte is 0x08 here (9 on other
        # devices); before veh100b we skipped BY the length and read "vibration".
        p = self.gt("78782526160913063918c002780fab0c44750f00040008027f14084c"
                    "0038420600030c020007398e0d0a")
        self.assertEqual((p["kind"], p["alarm"]), ("alarm", "tamper"))
        self.assertTrue(p["crc_ok"])
        # 0x27 (Traccar: ALARM_LOW_BATTERY)
        p = self.gt("78782627100419092D07C5027AC91C0C4658000005370900000000000000"
                    "008002001900FF00004DF60D0A")
        self.assertEqual(p["alarm"], "low_battery")
        self.assertTrue(p["status"]["relay_cut"])           # terminal info 0x80

    def test_gt06_4g_frames(self):
        # 0xA4 4G alarm (Traccar: ALARM_LOW_BATTERY); CRC in the recorded
        # frame does not match -> kept, flagged
        p = self.gt("78782DA4150817073B10CF032EEA9C0B6CE0800015141001CC0100009A00"
                    "000000000A6F24014605041900FF01908A640D0A")
        self.assertEqual((p["kind"], p["alarm"]), ("alarm", "low_battery"))
        self.assertFalse(p["crc_ok"])
        self.assertTrue(p["ack_required"])
        # 0xA0 4G location (Traccar: KEY_IGNITION false); Brazil (MCC 724)
        p = self.gt("787829a01707150f2d0ecd01635100041e96d000087c02d4020000912e00"
                    "0000000718798d000e0006ed3ce50d0a")
        f = p["fix"]
        self.assertEqual(p["kind"], "gps")
        self.assertIs(f["ignition"], False)
        self.assertEqual(f["at"], datetime(2023, 7, 21, 15, 45, 14, tzinfo=dtz.utc))
        self.assertAlmostEqual(f["lat"], -12.936676, places=5)
        self.assertAlmostEqual(f["lng"], -38.396418, places=5)
        self.assertEqual(f["sats"], 13)
        # 0x22 with ACC=1 and the re-upload flag
        p = self.gt("787822221106160a1016c60278019407c7783800040001940504700046fc"
                    "01030100065f570d0a")
        self.assertIs(p["fix"]["ignition"], True)
        self.assertTrue(p["fix"]["buffered"])

    def test_h02_binary_recorded(self):
        # Traccar: location("2015-08-31T21:53:21.000Z", true, 4.69898, -74.06971)
        b = bytes.fromhex("24410600082621532131081504419390060740418306000000ffff"
                          "fbfdff0015060000002c02dc0c000000001f")
        frames, rest = h02.split_frames(b)
        p = h02.parse_frame(frames[0])
        self.assertEqual(rest, b"")
        self.assertEqual(p["imei"], "4106000826")
        self.assertEqual(p["fix"]["at"], datetime(2015, 8, 31, 21, 53, 21, tzinfo=dtz.utc))
        self.assertAlmostEqual(p["fix"]["lat"], 4.69898, places=4)
        self.assertAlmostEqual(p["fix"]["lng"], -74.06971, places=4)
        self.assertTrue(p["fix"]["valid"])
        # a Sinotrack in DHAKA (recorded upstream): 23.83572, 90.41626
        b = bytes.fromhex("2491802711800850240512192350143206090249758e000001ffffbbff"
                          "00bdf0900000000001d60161cc4b9a35")
        p = h02.parse_frame(h02.split_frames(b)[0][0])
        self.assertEqual(p["imei"], H02B_ID)
        self.assertAlmostEqual(p["fix"]["lat"], 23.83572, places=4)
        self.assertAlmostEqual(p["fix"]["lng"], 90.41626, places=4)

    def test_h02_text_firmware_variants(self):
        parse = lambda t: h02.parse_frame(t.encode())["fix"]   # noqa: E731
        # no leading zeros on longitude ("954.9490" = 9 deg 54.949 min)
        f = parse("*HQ,353588020068342,V1,062840,A,5241.1249,N,954.9490,E,0.00,0.00,"
                  "231013,ffffffff,000106,000002,000203,004c87,24#")
        self.assertAlmostEqual(f["lng"], 9.915817, places=4)
        # no decimal point (37 deg 57.3392 min S)
        f = parse("*HQ,5905101893,V1,105759,A,37573392,S,145037022,E,000.00,173,280122,"
                  "FF7FFBFF,,,9059e2c,8232,4#")
        self.assertAlmostEqual(f["lat"], -37.955653, places=4)
        # an extra field before the date
        f = parse("*HQ,4210209006,V1,054048,A,2828.2297,N,07733.4332,E,000.5,047,4,"
                  "080918,EEE7FBDF,4261193,0#")
        self.assertEqual(f["at"], datetime(2018, 9, 8, 5, 40, 48, tzinfo=dtz.utc))
        # empty time + V = alive, nothing stored
        self.assertEqual(h02.parse_frame(
            b"*HQ,353505510948929,V1,,V,,N,,E,0.00,0,,FFFFF7FF,f0,a,11a0,c0c6#")["kind"],
            "heartbeat")

    def jt(self, h):
        frames, _ = jt808.split_frames(bytes.fromhex(h))
        return jt808.parse_frame(frames[0])

    def test_jt808_recorded(self):
        # 0x0200, 2013 header: GMT+8 device time -> UTC
        p = self.jt("7e02000048051160004464000d00000000000c00020159885e06cbf34400000000000"
                    "020080718072201040000000130011c310109e4020063e50100e60100e708000000"
                    "0000000000ee0a01cc01262c009a6743001e7e")
        f = p["fix"]
        self.assertEqual((p["kind"], p["imei"]), ("gps", "51160004464"))
        self.assertEqual(f["at"], datetime(2020, 8, 7, 10, 7, 22, tzinfo=dtz.utc))
        self.assertAlmostEqual(f["lat"], 22.64483, places=5)
        self.assertEqual(f["sats"], 9)
        self.assertTrue(f["valid"])
        self.assertIs(f["ignition"], False)
        # 0x0704, 2019 header, blind-area batch (Traccar: KEY_SATELLITES 14)
        p = self.jt("7e0704402d0100000866496077582164881d0001000028000000000000000701a0"
                    "0192091f2a4700160000000226050916422701040000258230010031010e507e")
        self.assertEqual(p["kind"], "gps_batch")
        self.assertTrue(p["v2019"])
        self.assertEqual(p["imei"], "866496077582164")
        self.assertEqual(p["fixes"][0]["sats"], 14)
        self.assertIs(p["fixes"][0]["ignition"], True)
        # heartbeat + register
        self.assertEqual(self.jt("7e0002000004304832546500b7ca7e")["kind"], "heartbeat")

    def test_jt808_roundtrip_escape_and_alarm_bits(self):
        at = datetime(2026, 11, 2, 9, 0, 0, tzinfo=dtz.utc)
        # serial 0x7E7D forces both escapes
        fr = jt808.location_packet("013800138000", 0x7E7D, at=at, lat=23.78, lng=90.41,
                                   speed_kmh=42.5, course=181, ignition=True,
                                   alarms=("sos", "power_cut"), relay_cut=True)
        self.assertNotIn(b"\x7e", fr[1:-1])
        frames, rest = jt808.split_frames(b"junk" + fr + fr[:5])
        self.assertEqual((len(frames), rest), (1, fr[:5]))
        p = jt808.parse_frame(frames[0])
        self.assertEqual(p["serial"], 0x7E7D)
        f = p["fix"]
        self.assertEqual(f["at"], at)
        self.assertEqual((f["speed_kmh"], f["course"]), (42.5, 181))
        self.assertEqual(sorted(f["alarms"]), ["power_cut", "sos"])
        self.assertTrue(f["relay_cut"] and f["ignition"])
        self.assertTrue(p["checksum_ok"])

    def test_gt06_and_h02_encoders_roundtrip(self):
        at = datetime(2026, 11, 2, 9, 30, 5, tzinfo=dtz.utc)
        p = gt06.parse_frame(gt06.gps4g_packet(at, 23.7808, 90.413, 40, 90, 5,
                                               realtime=False))
        self.assertEqual((p["fix"]["at"], p["fix"]["ignition"], p["fix"]["buffered"]),
                         (at, True, True))
        p = gt06.parse_frame(gt06.alarm4g_packet(at, 23.7808, 90.413, 0, "sos", 6))
        self.assertEqual(p["alarm"], "sos")
        b = h02.binary_packet(H02B_ID, at, 23.7808, -90.413, 40, 90, status=0xFFFFFFFF)
        p = h02.parse_frame(h02.split_frames(b)[0][0])
        self.assertAlmostEqual(p["fix"]["lng"], -90.413, places=4)
        self.assertTrue(p["fix"]["ignition"])


# =========================================================================== pure logic

def UT(s=0):
    return datetime(2026, 11, 2, 6, 0, tzinfo=dtz.utc) + timedelta(seconds=s)


def north(m):
    return 23.78 + m / 111000.0


FENCE = {"geofences": [{"id": "h", "name": "Home", "lat": 23.78, "lng": 90.41,
                        "radius_m": 200}]}


class ClockAndOrderTests(SimpleTestCase):
    def test_learns_local_time_offset_and_clears_it(self):
        now = UT()
        at, st = VT.correct_clock(UT(6 * 3600 + 4), now, {})
        self.assertEqual((at, st["clk_off"]), (UT(4), 21600))
        at, st = VT.correct_clock(UT(6 * 3600 + 30), now, st)
        self.assertEqual(at, UT(30))
        at, st = VT.correct_clock(UT(2), now, st)          # owner fixed the clock
        self.assertEqual((at, st.get("clk_off")), (UT(2), None))
        at, st = VT.correct_clock(UT(7900), now, {})        # not a zone offset
        self.assertEqual((at, st), (now, {}))

    def test_gps_jump_never_flips_a_fence(self):
        st, a = VT.evaluate_alerts({}, {"at": UT(0), "lat": 23.78, "lng": 90.41}, FENCE, 12)
        st, a = VT.evaluate_alerts(st, {"at": UT(10), "lat": 23.83, "lng": 90.41}, FENCE, 12)
        self.assertEqual(a, [])                              # 5.5 km in 10 s
        st, a = VT.evaluate_alerts(st, {"at": UT(20), "lat": 23.7801, "lng": 90.41},
                                   FENCE, 12)
        self.assertEqual(a, [])
        # a REAL move is accepted after JUMP_RESET_N rejections
        for i in range(VT.JUMP_RESET_N + 1):
            st, a = VT.evaluate_alerts(st, {"at": UT(30 + i), "lat": 23.83, "lng": 90.41},
                                       FENCE, 12)
        self.assertEqual([x["kind"] for x in a], ["geofence_exit"])

    def test_fence_hysteresis(self):
        st, _ = VT.evaluate_alerts({}, {"at": UT(0), "lat": 23.78, "lng": 90.41}, FENCE, 12)
        seq = [(210, []), (230, ["geofence_exit"]), (190, []), (205, []),
               (150, ["geofence_enter"])]
        for i, (m, want) in enumerate(seq):
            st, a = VT.evaluate_alerts(st, {"at": UT(60 * (i + 1)), "lat": north(m),
                                            "lng": 90.41}, FENCE, 12)
            self.assertEqual([x["kind"] for x in a], want, m)

    def test_stale_backlog_never_drives_state(self):
        st, _ = VT.evaluate_alerts({}, {"at": UT(600), "lat": north(500), "lng": 90.41,
                                        "ignition": False}, FENCE, 2)
        st2, a = VT.evaluate_alerts(st, {"at": UT(0), "lat": 23.78, "lng": 90.41,
                                         "ignition": True}, FENCE, 2)
        self.assertEqual((a, st2), ([], st))


class EngineAlertTests(SimpleTestCase):
    def test_engine_hot_debounced_and_rearmed(self):
        st, kinds = {}, []
        for i, c in enumerate((100, 106, 107, 108, 90, 106, 106)):
            st, a = VT.evaluate_alerts(st, {"at": UT(i * 10), "lat": 23.7, "lng": 90.4,
                                            "speed_kmh": 30,
                                            "obd": {"coolant_temp_c": c}}, {}, 12)
            kinds += [x["kind"] for x in a]
        self.assertEqual(kinds, ["engine_hot", "engine_hot"])

    def test_parked_fuel_drop_not_driving_use(self):
        st, kinds = {}, []
        seq = [(0, 60), (0, 60), (40, 50), (40, 45), (0, 45), (0, 45), (0, 34), (0, 33),
               (0, 33)]
        for i, (spd, lvl) in enumerate(seq):
            st, a = VT.evaluate_alerts(st, {"at": UT(i * 60), "lat": 23.7, "lng": 90.4,
                                            "speed_kmh": spd,
                                            "obd": {"fuel_level_pct": lvl}}, {}, 12)
            kinds += [(x["kind"], x["from"], x["to"]) for x in a]
        self.assertEqual(kinds, [("fuel_drop", 45, 33)])
        t, b = VT.alert_text({"kind": "fuel_drop", "from": 45, "to": 33, "unit": "pct"},
                             "Car", "bn")
        self.assertIn("৪৫%", b)
        self.assertNotRegex(b, "[0-9]")
        t, b = VT.alert_text({"kind": "engine_hot", "temp_c": 107}, "Car", "en")
        self.assertIn("107", b)

    def test_late_suffix_bn_en(self):
        a = {"kind": "overspeed", "speed_kmh": 80, "limit_kmh": 60, "late_at": "14:05"}
        _, bn = VT.alert_text(a, "Car", "bn")
        _, en = VT.alert_text(a, "Car", "en")
        self.assertIn("১৪:০৫", bn)
        self.assertNotRegex(bn, "[0-9]")
        self.assertIn("14:05", en)
        self.assertIn("offline", en)


# =========================================================================== ingest

class IngestClockAndLateTests(_Setup, APITestCase):
    def test_tracker_on_local_time_keeps_every_fix(self):
        from core import vehicle_service as VS
        now = timezone.now()
        fixes = [{"at": now + timedelta(hours=6) - timedelta(seconds=10 * k),
                  "lat": 23.78 + k * 1e-4, "lng": 90.41, "speed_kmh": 20, "valid": True}
                 for k in range(5)]
        n = VS.ingest({self.t.id: {"fixes": fixes, "status": {}}}, now=now)
        self.assertEqual(n, 5)                    # before veh100b: 1 (all clamped)
        ats = sorted(VehiclePosition.objects.filter(tracker=self.t, at__gt=now - timedelta(
            seconds=60)).values_list("at", flat=True))
        self.assertEqual(len(ats), 5)
        self.assertLessEqual(ats[-1], now + timedelta(seconds=1))
        self.t.refresh_from_db()
        self.assertEqual(self.t.alert_state["clk_off"], 21600)

    def test_rollover_date_dropped(self):
        from core import vehicle_service as VS
        n = VS.ingest({self.t.id: {"fixes": [{
            "at": datetime(2006, 1, 1, tzinfo=dtz.utc), "lat": 23.7, "lng": 90.4,
            "speed_kmh": 0, "valid": True}], "status": {}}})
        self.assertEqual(n, 0)

    def test_late_backlog_alerts(self):
        from core import vehicle_service as VS
        self.t.speed_limit_kmh = 60
        self.t.geofences = FENCE["geofences"]
        self.t.alert_state = {}
        self.t.save()
        now = timezone.now()
        t0 = now - timedelta(hours=2)
        fixes = [{"at": t0, "lat": 23.78, "lng": 90.41, "speed_kmh": 0, "valid": True},
                 {"at": t0 + timedelta(seconds=300), "lat": 23.80, "lng": 90.41,
                  "speed_kmh": 75, "valid": True},
                 {"at": t0 + timedelta(seconds=305), "lat": 23.801, "lng": 90.41,
                  "speed_kmh": 76, "valid": True}]
        VS.ingest({self.t.id: {"fixes": fixes, "status": {}}}, now=now)
        ex = VehicleAuditLog.objects.get(tracker=self.t, action="alert_geofence_exit")
        ov = VehicleAuditLog.objects.get(tracker=self.t, action="alert_overspeed")
        self.assertTrue(ex.detail["pushed"])           # safety: still pushed
        self.assertFalse(ov.detail["pushed"])          # late noise: in-app only
        self.assertTrue(ex.detail["late_at"])


# =========================================================================== real TCP

class JT808EndToEndTests(_TcpBase):
    PORT = PORT_JT

    def test_jt808_register_drive_batch_sos_params_and_engine_cut(self):
        from tracker.sim import JT808Device
        tid = self.pair(JT_ID, "Truck", protocol="jt808")
        path = scenario_path(datetime.now(dtz.utc))

        async def run():
            srv = self.server()
            await srv.start()
            try:
                bad = JT808Device("13900000001")
                await bad.connect("127.0.0.1", self.PORT)
                self.assertFalse(await bad.register(timeout=1.0))
                await bad.close()

                dev = JT808Device(JT_ID)
                await dev.connect("127.0.0.1", self.PORT)
                self.assertTrue(await dev.register())
                self.assertTrue(dev.auth_code)
                for p in path:
                    await dev.fix(p["lat"], p["lng"], p["speed_kmh"], p["ign"], p["at"])
                await dev.heartbeat()
                for s in (3, 2, 1):           # SOS level for 3 frames -> one alert
                    await dev.fix(path[-1]["lat"], path[-1]["lng"], 0, False,
                                  datetime.now(dtz.utc) - timedelta(seconds=s),
                                  alarms=("sos",))
                self.assertTrue(await self.wait(lambda: VehiclePosition.objects.filter(
                    tracker_id=tid).count() >= len(path) + 3), "positions not flushed")
                # blind-area re-upload of older stored points: stored, no alert
                old = datetime.now(dtz.utc) - timedelta(minutes=20)
                await dev.batch([{"at": old + timedelta(seconds=10 * i), "lat": HOME[0],
                                  "lng": HOME[1], "speed_kmh": 0} for i in range(3)],
                                ignition=False)
                self.assertTrue(await self.wait(lambda: VehiclePosition.objects.filter(
                    tracker_id=tid).count() >= len(path) + 6), "batch not stored")
                self.assertTrue(await self.wait(lambda: jt808.M_LOCATION_BATCH in dev.acks))
                # interval (0x8103) queued at pairing
                self.assertTrue(await self.wait(lambda: "PARAMS" in dev.commands))
                self.assertTrue(await self.wait(lambda: VehicleCommand.objects.filter(
                    tracker_id=tid, kind="set_interval", state="acked").exists()))
                r = cut_confirmed(self.client, tid)
                self.assertEqual(r.status_code, 201, r.data)
                cid = r.data["command"]["id"]
                self.assertTrue(await self.wait(
                    lambda: VehicleCommand.objects.get(pk=cid).state == "acked"),
                    "JT808 engine cut never acked")
                self.assertIn("RELAY,1#", dev.commands)
                # the relay bit on the next fix is the device-side truth
                await dev.fix(path[-1]["lat"], path[-1]["lng"], 0, False)
                self.assertTrue(await self.wait(lambda: VehiclePosition.objects.filter(
                    tracker_id=tid, io__relay_cut=True).exists()))
                await dev.close()
            finally:
                await srv.stop()

        asyncio.run(run())
        t = self.assert_app_view(tid, len(path) + 7)
        self.assertEqual(t["protocol"], "jt808")
        self.assertTrue(t["relay_cut"])
        self.assert_alerts_pushed(tid, ["geofence_exit", "overspeed", "off_route",
                                        "long_stop", "device_alarm"])
        self.assertEqual(self.pushed_alerts().count("device_alarm"), 1)
        self.assertTrue(VehicleAuditLog.objects.filter(action="unknown_imei",
                                                       imei="13900000001").exists())


class Concox4GEndToEndTests(_TcpBase):
    PORT = PORT_4G

    def test_jm_vl01_class_4g_frames(self):
        from tracker.sim import GT06Device
        tid = self.pair(IMEI_A, "Car 4G")
        path = scenario_path(datetime.now(dtz.utc))

        async def run():
            srv = self.server()
            await srv.start()
            try:
                dev = GT06Device(IMEI_A)
                await dev.connect("127.0.0.1", self.PORT)
                self.assertTrue(await dev.login())
                for p in path:
                    await dev.raw(gt06.gps4g_packet(p["at"], p["lat"], p["lng"],
                                                    p["speed_kmh"], 90, dev._ser(),
                                                    ignition=p["ign"]))
                last = path[-1]
                await dev.raw(gt06.alarm4g_packet(datetime.now(dtz.utc), last["lat"],
                                                  last["lng"], 0, "power_cut", dev._ser(),
                                                  ignition=False))
                self.assertTrue(await self.wait(lambda: gt06.P_ALARM_4G in dev.acks))
                self.assertTrue(await self.wait(lambda: VehiclePosition.objects.filter(
                    tracker_id=tid).count() >= len(path) + 1), "4G fixes not stored")
                await dev.close()
            finally:
                await srv.stop()

        asyncio.run(run())
        self.assertEqual(VehiclePosition.objects.filter(tracker_id=tid).count(),
                         len(path) + 1)
        got = self.pushed_alerts()
        for k in ("geofence_exit", "overspeed", "device_alarm"):
            self.assertIn(k, got)
        t = VehicleTracker.objects.get(pk=tid)
        self.assertEqual(t.protocol, "gt06")
        self.assertIs(t.ignition, False)


class H02BinaryEndToEndTests(_TcpBase):
    PORT = PORT_H02B

    def test_sinotrack_binary_drive(self):
        tid = self.pair(H02B_ID, "Bike", protocol="h02")
        path = scenario_path(datetime.now(dtz.utc))

        async def run():
            srv = self.server()
            await srv.start()
            try:
                reader, writer = await asyncio.open_connection("127.0.0.1", self.PORT)
                for p in path:
                    # ACC = status bit 10 (set = on); all alarm bits clear (high)
                    st = 0xFFFFFFFF if p["ign"] else 0xFFFFFBFF
                    writer.write(h02.binary_packet(H02B_ID, p["at"], p["lat"], p["lng"],
                                                   p["speed_kmh"], 90, status=st))
                    await writer.drain()
                    await asyncio.sleep(0.002)
                self.assertTrue(await self.wait(lambda: VehiclePosition.objects.filter(
                    tracker_id=tid).count() >= len(path)), "binary H02 not stored")
                writer.close()
            finally:
                await srv.stop()

        asyncio.run(run())
        got = self.pushed_alerts()
        self.assertIn("geofence_exit", got)
        self.assertIn("overspeed", got)
        self.assertEqual(VehicleTracker.objects.get(pk=tid).protocol, "h02")


class ReconnectTests(_TcpBase):
    PORT = PORT_RECON

    def test_dead_socket_unregistered_and_command_reaches_new_socket(self):
        from tracker.sim import GT06Device
        tid = self.pair(IMEI_A, "Car")

        async def run():
            srv = self.server()
            await srv.start()
            try:
                d1 = GT06Device(IMEI_A)
                await d1.connect("127.0.0.1", self.PORT)
                self.assertTrue(await d1.login())
                self.assertTrue(await self.wait(lambda: tid in srv.sessions))
                d1.writer.transport.abort()          # RST, no goodbye
                self.assertTrue(await self.wait(lambda: tid not in srv.sessions),
                                "dead socket kept as the live session")
                d2 = GT06Device(IMEI_A)
                await d2.connect("127.0.0.1", self.PORT)
                self.assertTrue(await d2.login())
                from core import vehicle_service as VS
                VS.queue_interval(VehicleTracker.objects.get(pk=tid))
                self.assertTrue(await self.wait(lambda: any(
                    c.startswith("TIMER,") for c in d2.commands)),
                    "queued interval command not delivered after reconnect")
                await d2.close()
            finally:
                await srv.stop()

        asyncio.run(run())
