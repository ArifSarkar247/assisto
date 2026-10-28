"""e2e-vehicle (launch NO-GAPS): vehicle tracking end to end.

  * H02 text protocol (Sinotrack ST-901 family): Traccar's public test vector,
    framing, junk, encoder round trips;
  * GT06 alarm packet encoder (CRC-ITU) round trip;
  * planned-route OFF-ROUTE + LONG-STOP alert state machine (pure);
  * ingest idempotency (a re-sent fix is never stored twice);
  * the routes API (stored inside the geofences JSON — no migration);
  * REAL TCP runs of tracker/server.py on spare local ports (15024/15025,
    never 5023) driven by tracker/sim.py: GT06 login ACK -> GPS stream ->
    heartbeat ACK -> SOS alarm ACK -> duplicate re-send -> flood rate limit,
    then the app HTTP API (live position, speed, route playback, trips, stops)
    and every alert as a real FCM v1 push through core.push with ONLY the
    HTTP seam mocked (push._http_post); H02 pair -> stream -> interval command
    -> engine cut S20 -> V4 DONE -> acked; unknown ids refused.
"""
import asyncio
import json
import os
import tempfile
from datetime import datetime, timedelta, timezone as dtz
from unittest import mock

from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APITestCase, APITransactionTestCase

from core import push
from core.logic import vehicle_tracking as VT
from core.models import (User, Device, VehicleTracker, VehiclePosition,
                         VehicleCommand, VehicleAuditLog, NotifEvent, FamilyAlert)
from core.tests_push import SA, FakeFCM
from core.tests_v1_vehicle import _Setup, IMEI_A, IMEI_C, PIN, cut_confirmed
from tracker.protocols import gt06, h02

PORT_GT06 = 15024
PORT_H02 = 15025
H02_ID = "9171234567"          # ST-901 style 10-digit device id

HOME = (23.7808, 90.4130)


def _east(lat, lng, metres):
    import math
    return lat, lng + metres / (111320.0 * math.cos(math.radians(lat)))


def _north(lat, lng, metres):
    return lat + metres / 110574.0, lng


ROUTE_END = _east(*HOME, 3000)
ROUTE = {"id": "r1", "name": "Office", "points": [list(HOME), list(ROUTE_END)],
         "corridor_m": 300, "stop_alert_min": 3}


def scenario_path(now):
    """The drive every E2E test uses (all fixes in the past, ascending):
    leg1  20 fixes east along the planned route @40 km/h (leaves Home fence)
    stop  9 fixes, 30 s apart, on the route (4 min -> stop + long_stop alert)
    leg2  10 fixes NORTH @70 km/h (off the route corridor + over a 60 limit)
    park  4 fixes @0."""
    t = now - timedelta(seconds=900)
    out = []
    lat, lng = HOME
    for i in range(20):
        out.append({"at": t, "lat": lat, "lng": lng, "speed_kmh": 40.0, "ign": True})
        lat, lng = _east(lat, lng, 40 / 3.6 * 5)
        t += timedelta(seconds=5)
    for i in range(9):
        out.append({"at": t, "lat": lat, "lng": lng, "speed_kmh": 0.0, "ign": True})
        t += timedelta(seconds=30)
    for i in range(10):
        lat, lng = _north(lat, lng, 70 / 3.6 * 5)
        out.append({"at": t, "lat": lat, "lng": lng, "speed_kmh": 70.0, "ign": True})
        t += timedelta(seconds=5)
    for i in range(4):
        out.append({"at": t, "lat": lat, "lng": lng, "speed_kmh": 0.0, "ign": False})
        t += timedelta(seconds=5)
    return out


class _PushMixin:
    """Real core.push code path; only the HTTP seam is faked (FakeFCM)."""

    def start_push(self, *users):
        push.reset_cache()
        tmp = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump(SA, tmp)
        tmp.close()
        self.addCleanup(os.unlink, tmp.name)
        self.fcm = FakeFCM()
        o = override_settings(FCM_SERVICE_ACCOUNT_FILE=tmp.name, PUSH_SYNC=True)
        o.enable()
        self.addCleanup(o.disable)
        p = mock.patch.object(push, "_http_post", self.fcm)
        p.start()
        self.addCleanup(p.stop)
        self.addCleanup(push.reset_cache)
        for i, u in enumerate(users):
            Device.objects.create(user=u, push_token="tok-%d-%d" % (u.id, i))

    def pushed_alerts(self):
        return [m["message"]["data"].get("alert")
                for m in self.fcm.sent_payloads()
                if m["message"]["data"].get("kind") == "family_alert"]


# =========================================================================== pure

class H02ProtocolTests(TestCase):
    TRACCAR = (b"*HQ,865205030330012,V1,145452,A,2240.55181,N,11358.32389,E,"
               b"0.00,0,100815,FFFFFBFF#")

    def test_traccar_public_vector(self):
        p = h02.parse_frame(self.TRACCAR)
        self.assertEqual(p["kind"], "gps")
        self.assertEqual(p["imei"], "865205030330012")
        f = p["fix"]
        self.assertEqual(f["at"], datetime(2015, 8, 10, 14, 54, 52, tzinfo=dtz.utc))
        self.assertAlmostEqual(f["lat"], 22.675863, places=5)
        self.assertAlmostEqual(f["lng"], 113.972065, places=5)
        self.assertTrue(f["valid"])
        self.assertFalse(f["ignition"])          # bit 10 clear in FFFFFBFF
        self.assertIsNone(p["alarm"])

    def test_roundtrip_south_west_knots_sos(self):
        at = datetime(2026, 10, 27, 8, 1, 2, tzinfo=dtz.utc)
        b = h02.v1_packet(H02_ID, at, -33.8688, -151.2093, 92.6, 271, sos=True)
        p = h02.parse_frame(b)
        self.assertAlmostEqual(p["fix"]["lat"], -33.8688, places=4)
        self.assertAlmostEqual(p["fix"]["lng"], -151.2093, places=4)
        self.assertAlmostEqual(p["fix"]["speed_kmh"], 92.6, delta=0.1)
        self.assertEqual(p["fix"]["course"], 271)
        self.assertEqual(p["alarm"], "sos")
        self.assertTrue(p["fix"]["ignition"])

    def test_split_junk_partial_heartbeat_reply(self):
        hb = h02.heartbeat_packet(H02_ID)
        frames, rest = h02.split_frames(b"\x00junk" + hb + b"*HQ,91")
        self.assertEqual(frames, [hb])
        self.assertEqual(rest, b"*HQ,91")
        self.assertEqual(h02.parse_frame(hb)["kind"], "heartbeat")
        rep = h02.reply_packet(H02_ID, "S20", "DONE", datetime.now(dtz.utc))
        r = h02.parse_frame(rep)
        self.assertEqual(r["kind"], "cmd_reply")
        self.assertTrue(h02.reply_ok(r["text"]))
        with self.assertRaises(h02.FrameError):
            h02.split_frames(b"*" + b"A" * 400)
        for bad in (b"*HQ,abc,V1#", b"*HQ,9171234567,V1,1,A,99,N,1,E,0,0,1,F#"):
            with self.assertRaises(h02.FrameError):
                h02.parse_frame(bad)

    def test_server_commands(self):
        at = datetime(2026, 10, 27, 13, 3, 5, tzinfo=dtz.utc)
        self.assertEqual(h02.server_command(H02_ID, h02.COMMANDS["engine_cut"], at),
                         b"*HQ,9171234567,S20,130305,1,1#")
        self.assertEqual(h02.interval_command(5, 180), "S71,22,10")


class GT06AlarmTests(TestCase):
    def test_alarm_roundtrip_crc(self):
        at = datetime(2026, 10, 27, 8, 1, 2, tzinfo=dtz.utc)
        fr = gt06.alarm_packet(at, 23.78, 90.41, 12, "sos", 7)
        body = fr[2:-4]
        self.assertEqual(int.from_bytes(fr[-4:-2], "big"), gt06.crc_itu(body))
        p = gt06.parse_frame(fr)
        self.assertEqual((p["kind"], p["alarm"], p["serial"]), ("alarm", "sos", 7))
        self.assertTrue(p["ack_required"])
        self.assertAlmostEqual(p["fix"]["lat"], 23.78, places=5)
        self.assertEqual(p["fix"]["at"], at)


class RouteAlertLogicTests(TestCase):
    def _run(self, fixes, settings):
        st, out = {}, []
        for f in fixes:
            st, al = VT.evaluate_alerts(st, f, settings, 12)
            out.extend(al)
        return st, out

    def test_distance_to_polyline(self):
        lat, lng = _north(*_east(*HOME, 1500), 250)
        d = VT.route_distance_m([list(HOME), list(ROUTE_END)], lat, lng)
        self.assertAlmostEqual(d, 250, delta=5)
        self.assertEqual(VT.route_distance_m([], 1, 1), float("inf"))

    def test_off_route_long_stop_rearm_and_arrival(self):
        now = datetime(2026, 10, 20, 6, 0, tzinfo=dtz.utc)
        fixes = [dict(p, valid=True) for p in scenario_path(now)]
        st, alerts = self._run(fixes, {"routes": [ROUTE]})
        kinds = [a["kind"] for a in alerts]
        self.assertEqual(kinds.count("long_stop"), 1)
        self.assertEqual(kinds.count("off_route"), 1)
        off = next(a for a in alerts if a["kind"] == "off_route")
        self.assertGreater(off["distance_m"], 300)
        self.assertEqual(off["route_name"], "Office")
        # back inside the corridor re-arms; leaving again alerts again
        back = dict(fixes[10], at=now + timedelta(hours=1))
        away = [dict(fixes[-1], at=now + timedelta(hours=1, seconds=s)) for s in (5, 10, 15)]
        st, al = self._run_from(st, [back] + away)
        self.assertEqual([a["kind"] for a in al], ["off_route"])
        # arriving at the end disarms: wandering afterwards never alerts
        end = {"at": now + timedelta(hours=2), "lat": ROUTE_END[0],
               "lng": ROUTE_END[1], "speed_kmh": 0, "valid": True}
        far = [dict(end, lat=end["lat"] + 0.05, at=end["at"] + timedelta(seconds=s))
               for s in (5, 10, 15, 20)]
        st, al = self._run_from(st, [end] + far)
        self.assertEqual(al, [])

    def _run_from(self, st, fixes):
        out = []
        for f in fixes:
            st, al = VT.evaluate_alerts(st, f, {"routes": [ROUTE]}, 12)
            out.extend(al)
        return st, out

    def test_never_armed_when_starting_off_route(self):
        start = _north(*HOME, 2000)
        fixes = [{"at": datetime(2026, 10, 20, 6, 0, s, tzinfo=dtz.utc),
                  "lat": start[0] + s * 1e-4, "lng": start[1], "speed_kmh": 30,
                  "valid": True} for s in range(10)]
        _, alerts = self._run(fixes, {"routes": [ROUTE]})
        self.assertEqual(alerts, [])

    def test_texts_bn_en_never_accuse(self):
        for kind, extra in (("off_route", {"distance_m": 640, "route_name": "Office"}),
                            ("long_stop", {"minutes": 12, "route_name": "Office"})):
            tb, bb = VT.alert_text({"kind": kind, **extra}, "Corolla", "bn")
            te, be = VT.alert_text({"kind": kind, **extra}, "Corolla", "en")
            self.assertTrue(any("ঀ" <= ch <= "৿" for ch in tb + bb))
            self.assertFalse(any("ঀ" <= ch <= "৿" for ch in te + be))
            for w in ("theft", "thief", "চুরি", "চোর"):
                self.assertNotIn(w, (tb + bb + te + be).lower())


# =========================================================================== API + service

class RoutesApiAndIdempotencyTests(_Setup, APITestCase):
    def test_routes_patch_validate_and_keep_fences(self):
        u = self.u()
        fence = {"id": "h", "name": "Home", "lat": HOME[0], "lng": HOME[1], "radius_m": 200}
        self.assertEqual(self.client.patch(u, {"geofences": [fence]}, format="json")
                         .status_code, 200)
        r = self.client.patch(u, {"routes": [ROUTE]}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(len(r.data["settings"]["geofences"]), 1)
        self.assertEqual(r.data["settings"]["routes"][0]["corridor_m"], 300)
        # replacing fences keeps routes and vice versa
        r = self.client.patch(u, {"geofences": []}, format="json")
        self.assertEqual(len(r.data["settings"]["routes"]), 1)
        self.assertEqual(r.data["settings"]["geofences"], [])
        for bad in ([{"points": [[1, 2]]}],                          # 1 point
                    [{"points": [[1, 2], [3, 4]], "corridor_m": 10}],  # corridor too small
                    [{"points": [[91, 2], [3, 4]]}],
                    [dict(ROUTE)] * 6,
                    "nope"):
            r = self.client.patch(u, {"routes": bad}, format="json")
            self.assertEqual(r.status_code, 400, bad)
            self.assertEqual(r.data["reason"], "bad_route")
        self.as_(self.fam)        # no grant -> 404, never a leak
        self.assertEqual(self.client.patch(u, {"routes": []}, format="json").status_code, 404)

    def test_ingest_is_idempotent(self):
        from core import vehicle_service as VS
        VehiclePosition.objects.filter(tracker=self.t).delete()   # _Setup's stopped fixes
        now = timezone.now()
        fixes = [{"at": now - timedelta(seconds=30 - i * 5), "lat": 23.78 + i * 1e-4,
                  "lng": 90.41, "speed_kmh": 20, "valid": True} for i in range(5)]
        self.assertEqual(VS.ingest({self.t.id: {"fixes": fixes}}), 5)
        # the same fixes again (device never got our ACK) + one duplicate inside
        # the batch + one new fix
        again = fixes + [fixes[0], dict(fixes[0], at=now)]
        self.assertEqual(VS.ingest({self.t.id: {"fixes": again}}), 1)
        self.assertEqual(VehiclePosition.objects.filter(tracker=self.t).count(), 6)

    def test_config_exposes_map_and_h02_sms(self):
        with override_settings(MAP_TILE_URL="https://tiles.example/{z}/{x}/{y}.png?key=k"):
            m = self.client.get("/api/v1/vehicle/config").data
        self.assertEqual(m["map"]["tile_url"], "https://tiles.example/{z}/{x}/{y}.png?key=k")
        self.assertIn("OpenStreetMap", m["map"]["attribution"])
        self.assertTrue(m["server"]["setup_sms"]["h02"].startswith("8040000 "))
        # the OSMF public tile server is refused for production traffic
        with override_settings(MAP_TILE_URL="https://tile.openstreetmap.org/{z}/{x}/{y}.png"):
            m = self.client.get("/api/v1/vehicle/config").data
        self.assertEqual(m["map"]["tile_url"], "")

    def test_h02_device_id_pairing(self):
        r = self.client.post("/api/v1/vehicle/trackers",
                             {"imei": H02_ID, "protocol": "h02"}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        self.assertEqual(r.data["tracker"]["protocol"], "h02")
        r = self.client.post("/api/v1/vehicle/trackers",
                             {"imei": "9171234568"}, format="json")       # no proto
        self.assertEqual(r.data["reason"], "bad_imei")

    def test_carmode_trip_replays_alerts(self):
        now = timezone.now()
        pts = [{"at": p["at"].isoformat(), "lat": p["lat"], "lng": p["lng"],
                "speed_kmh": p["speed_kmh"]} for p in scenario_path(now)]
        r = self.client.post("/api/v1/vehicle/carmode/trip",
                             {"points": pts, "speed_limit_kmh": 60, "route": ROUTE},
                             format="json")
        self.assertEqual(r.status_code, 201, r.data)
        kinds = [a["kind"] for a in r.data["alerts"]]
        for k in ("overspeed", "off_route", "long_stop"):
            self.assertIn(k, kinds)
        self.assertGreaterEqual(len(r.data["stops"]), 1)
        r = self.client.post("/api/v1/vehicle/carmode/trip",
                             {"points": pts, "route": {"points": [[1, 1]]}}, format="json")
        self.assertEqual(r.status_code, 400)


# =========================================================================== real TCP

class _TcpBase(_Setup, _PushMixin, APITransactionTestCase):
    PORT = PORT_GT06

    def setUp(self):
        super().setUp()
        self._env = os.environ.get("DJANGO_ALLOW_ASYNC_UNSAFE")
        os.environ["DJANGO_ALLOW_ASYNC_UNSAFE"] = "true"
        from core import vehicle_service as VS
        VS._unknown_logged.clear()
        self.t.delete()
        self.start_push(self.owner)

    def tearDown(self):
        if self._env is None:
            os.environ.pop("DJANGO_ALLOW_ASYNC_UNSAFE", None)
        else:
            os.environ["DJANGO_ALLOW_ASYNC_UNSAFE"] = self._env

    def server(self, **cfg):
        from core import vehicle_service as VS
        from tracker.server import TrackerServer, Store
        return TrackerServer("127.0.0.1", self.PORT, store=Store(inline=True),
                             cfg={**VS.vcfg(), **cfg}, flush_s=0.1, cmd_poll_s=0.1)

    async def wait(self, cond, timeout=8.0):
        loop = asyncio.get_running_loop()
        end = loop.time() + timeout
        while loop.time() < end:
            if cond():
                return True
            await asyncio.sleep(0.05)
        return False

    def pair(self, imei, name, protocol="auto"):
        r = self.client.post("/api/v1/vehicle/trackers",
                             {"imei": imei, "name": name, "protocol": protocol},
                             format="json")
        self.assertEqual(r.status_code, 201, r.data)
        tid = r.data["tracker"]["id"]
        r = self.client.patch("/api/v1/vehicle/trackers/%d" % tid, {
            "speed_limit_kmh": 60, "night_ignition_alert": False,
            "geofences": [{"id": "h", "name": "Home", "lat": HOME[0], "lng": HOME[1],
                           "radius_m": 200}],
            "routes": [ROUTE]}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        return tid

    def assert_app_view(self, tid, n_positions):
        """What the app sees after the drive (the app screens read exactly
        these endpoints)."""
        self.assertEqual(VehiclePosition.objects.filter(tracker_id=tid).count(),
                         n_positions)
        t = self.client.get("/api/v1/vehicle/trackers/%d" % tid).data
        self.assertTrue(t["online"])
        self.assertEqual(t["state"], "paired")
        live = t["live"]
        self.assertIsNotNone(live)
        self.assertEqual(live["speed_kmh"], 0)
        self.assertFalse(live["moving"])
        self.assertLess(live["fix_age_s"], 120)
        self.assertEqual(len(t["settings"]["routes"]), 1)
        r = self.client.get("/api/v1/vehicle/trackers/%d/route" % tid).data
        self.assertGreaterEqual(len(r["points"]), 40)              # playback
        self.assertEqual(r["points"], sorted(r["points"], key=lambda p: p["at"]))
        self.assertAlmostEqual(r["max_speed_kmh"], 70, delta=1)
        self.assertGreaterEqual(len(r["trips"]), 2)                # stop split the drive
        self.assertGreaterEqual(len(r["stops"]), 1)
        tr = self.client.get("/api/v1/vehicle/trackers/%d/trips?hours=48" % tid).data
        self.assertEqual(len(tr["trips"]), len(r["trips"]))
        return t

    def assert_alerts_pushed(self, tid, kinds):
        got = self.pushed_alerts()
        for k in kinds:
            self.assertIn(k, got, "no FCM push for %s (got %s)" % (k, got))
            self.assertTrue(NotifEvent.objects.filter(user=self.owner, meta__alert=k)
                            .exists(), k)
            self.assertTrue(VehicleAuditLog.objects.filter(tracker_id=tid,
                                                           action="alert_" + k).exists())
        self.assertTrue(FamilyAlert.objects.filter(user=self.owner, kind="vehicle").exists())
        # one push per event — no storm from repeated fixes. long_stop fires
        # twice: the 4-min stop on the route, then the car parked (off route,
        # route still armed) for ~7 min until the last (alarm) fix.
        for k in ("overspeed", "off_route", "geofence_exit"):
            self.assertEqual(got.count(k), 1, k)
        self.assertEqual(got.count("long_stop"), 2)
        m = next(x for x in self.fcm.sent_payloads()
                 if x["message"]["data"].get("alert") == "off_route")["message"]
        self.assertEqual(m["token"], "tok-%d-0" % self.owner.id)
        self.assertEqual(m["data"]["route"], "vehicles")
        self.assertTrue(any("ঀ" <= ch <= "৿" for ch in m["notification"]["title"]))


class GT06EndToEndTests(_TcpBase):
    PORT = PORT_GT06

    def test_gt06_full_drive(self):
        from tracker.sim import GT06Device
        tid = self.pair(IMEI_A, "Corolla")
        path = scenario_path(datetime.now(dtz.utc))

        async def run():
            srv = self.server()
            await srv.start()
            try:
                bad = GT06Device(IMEI_C)
                await bad.connect("127.0.0.1", self.PORT)
                self.assertFalse(await bad.login(timeout=1.0))
                await bad.close()

                dev = GT06Device(IMEI_A)
                await dev.connect("127.0.0.1", self.PORT)
                self.assertTrue(await dev.login())
                for p in path:
                    await dev.fix(p["lat"], p["lng"], p["speed_kmh"], p["ign"], p["at"])
                await dev.heartbeat(ignition=False)
                last = path[-1]
                await dev.alarm(last["lat"], last["lng"], "sos",
                                at=datetime.now(dtz.utc) - timedelta(seconds=2))
                self.assertTrue(await self.wait(
                    lambda: dev.acks.count(gt06.P_STATUS) >= 1
                    and dev.acks.count(gt06.P_ALARM) >= 1), "status/alarm not ACKed")
                self.assertTrue(await self.wait(lambda: VehiclePosition.objects.filter(
                    tracker_id=tid).count() >= len(path) + 1), "positions not flushed")
                # flaky link: the device re-sends 5 old fixes + 1 corrupted frame
                for p in path[:5]:
                    await dev.fix(p["lat"], p["lng"], p["speed_kmh"], p["ign"], p["at"])
                junk = bytearray(gt06.status_packet(99))
                junk[-3] ^= 0xFF                                  # break the CRC
                await dev.raw(bytes(junk))
                await dev.heartbeat()
                self.assertTrue(await self.wait(
                    lambda: dev.acks.count(gt06.P_STATUS) >= 2))
                await asyncio.sleep(0.3)
                self.assertGreaterEqual(srv.stats["bad_frames"], 1)
                self.assertEqual(srv.stats["rejected"], 1)
                await dev.close()
            finally:
                await srv.stop()

        asyncio.run(run())
        self.assert_app_view(tid, len(path) + 1)
        self.assert_alerts_pushed(tid, ["geofence_exit", "overspeed", "off_route",
                                        "long_stop", "device_alarm"])
        t = VehicleTracker.objects.get(pk=tid)
        self.assertEqual((t.protocol, t.ignition), ("gt06", False))

    def test_gt06_flood_is_rate_limited(self):
        from tracker.sim import GT06Device
        tid = self.pair(IMEI_A, "Corolla")

        async def run():
            srv = self.server(max_packets_per_min=20)
            await srv.start()
            try:
                dev = GT06Device(IMEI_A)
                await dev.connect("127.0.0.1", self.PORT)
                self.assertTrue(await dev.login())
                for _ in range(120):
                    await dev.heartbeat()
                closed = await self.wait(lambda: dev._task.done(), 5.0)
                self.assertTrue(closed, "flooding device was not disconnected")
                await dev.close()
            finally:
                await srv.stop()

        asyncio.run(run())
        self.assertTrue(VehicleAuditLog.objects.filter(tracker_id=tid,
                                                       action="rate_limited").exists())


class H02EndToEndTests(_TcpBase):
    PORT = PORT_H02

    def test_h02_pair_drive_alerts_and_engine_cut(self):
        from tracker.sim import H02Device
        tid = self.pair(H02_ID, "Bike", protocol="h02")
        path = scenario_path(datetime.now(dtz.utc))

        async def run():
            srv = self.server()
            await srv.start()
            try:
                bad = H02Device("9179999999")
                await bad.connect("127.0.0.1", self.PORT)
                await bad.fix(23.78, 90.41, 0)
                self.assertTrue(await bad.closed(), "unknown H02 id not refused")
                await bad.close()

                dev = H02Device(H02_ID)
                await dev.connect("127.0.0.1", self.PORT)
                for p in path:
                    await dev.fix(p["lat"], p["lng"], p["speed_kmh"], p["ign"], p["at"])
                await dev.heartbeat()
                # SOS bit held for 3 frames -> exactly one alert
                for s in (3, 2, 1):
                    await dev.fix(path[-1]["lat"], path[-1]["lng"], 0, False,
                                  datetime.now(dtz.utc) - timedelta(seconds=s), sos=True)
                self.assertTrue(await self.wait(lambda: VehiclePosition.objects.filter(
                    tracker_id=tid).count() >= len(path) + 3), "positions not flushed")
                # interval command queued at pairing reached the device
                self.assertTrue(await self.wait(
                    lambda: any(c.startswith("S71,") for c in dev.commands)))
                self.assertTrue(await self.wait(lambda: VehicleCommand.objects.filter(
                    tracker_id=tid, kind="set_interval", state="acked").exists()))
                r = cut_confirmed(self.client, tid)
                self.assertEqual(r.status_code, 201, r.data)
                cid = r.data["command"]["id"]
                self.assertTrue(await self.wait(
                    lambda: VehicleCommand.objects.get(pk=cid).state == "acked"),
                    "H02 engine cut never acked")
                self.assertTrue(any(c.startswith("S20,") and c.endswith(",1,1")
                                    for c in dev.commands), dev.commands)
                await dev.close()
            finally:
                await srv.stop()

        asyncio.run(run())
        t = self.assert_app_view(tid, len(path) + 3)
        self.assertEqual(t["protocol"], "h02")
        self.assertTrue(t["relay_cut"])
        self.assert_alerts_pushed(tid, ["geofence_exit", "overspeed", "off_route",
                                        "long_stop", "device_alarm"])
        self.assertEqual(self.pushed_alerts().count("device_alarm"), 1)
        self.assertTrue(VehicleAuditLog.objects.filter(action="unknown_imei",
                                                       imei="9179999999").exists())
