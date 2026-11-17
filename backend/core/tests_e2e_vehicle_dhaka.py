"""flag-vehicle (FLAGSHIP W6): the scripted vehicle-tracking E2E on a realistic
Dhaka commute — no hardware needed.

A simulated Sinotrack ST-901 (H02 text protocol, tracker/sim.py H02Device)
connects over REAL TCP to tracker/server.py running with the PRODUCTION
timings (FLUSH_S, CMD_POLL_S — not the fast test timings), and drives
Dhanmondi 27 -> Panthapath -> Karwan Bazar (made-up sample trip, sim.dhaka_trip):

  parked at Home (ignition off)  -> ignition ON alert
  leaves the Home geofence       -> geofence_exit alert
  fast empty stretch (72 > 60)   -> ONE overspeed alert
  arrives inside the Office fence-> geofence_enter alert
  parks, ignition off            -> ignition OFF alert
  the app API: live position, trip history (trips / km / max speed / playback)
  engine cut while MOVING        -> refused, or (when_stopped) HELD — never sent
                                    until the stopped-only gate passes; then
                                    S20 reaches the device, V4 DONE -> acked
  tracker goes silent            -> tracker_silent alert + honest offline state

Every alert goes through the real core.push FCM v1 code (only the HTTP seam is
faked) and the ALERT LATENCY (device frame written -> FCM request made) is
measured per alert and printed as VEH_E2E_METRICS {json} together with the
measured data use per day. Port 15041 (never 5023).
"""
import asyncio
import json
import time
from datetime import datetime, timedelta, timezone as dtz
from unittest import mock

from django.utils import timezone
from rest_framework.test import APITestCase

from core import push
from core import vehicle_service as VS
from core.logic import vehicle_tracking as VT
from core.models import (VehicleTracker, VehiclePosition, VehicleCommand,
                         VehicleAuditLog, NotifEvent)
from core.tests_e2e_vehicle import _TcpBase
from core.tests_v1_vehicle import _Setup, PIN, cut_confirmed, enable_engine_cut
from tracker import sim
from tracker.server import FLUSH_S

PORT_DHAKA = 15041
DEV_ID = "9171234568"           # ST-901 style 10-digit device id (made up)
HOME = sim.DHAKA_WAYPOINTS[0][1:]
OFFICE = sim.DHAKA_WAYPOINTS[-1][1:]
FENCE_M = 150
ALERT_LATENCY_MAX_S = 6.0       # FLUSH_S (2 s) + ingest + push, with margin


def _inside(p, centre, r=FENCE_M):
    return VT.haversine_m(p["lat"], p["lng"], centre[0], centre[1]) <= r


class DhakaCommuteE2E(_TcpBase):
    PORT = PORT_DHAKA

    def setUp(self):
        super().setUp()
        self.push_log = []                      # (monotonic, payload dict)
        fcm = self.fcm

        def rec(url, body, headers):
            if url != push.TOKEN_URI:
                self.push_log.append((time.monotonic(), json.loads(body.decode())))
            return fcm(url, body, headers)

        p = mock.patch.object(push, "_http_post", rec)
        p.start()
        self.addCleanup(p.stop)

    def server(self, **cfg):
        from tracker.server import TrackerServer, Store, FLUSH_S, CMD_POLL_S
        return TrackerServer("127.0.0.1", self.PORT, store=Store(inline=True),
                             cfg={**VS.vcfg(), **cfg}, flush_s=FLUSH_S,
                             cmd_poll_s=CMD_POLL_S)

    def pair_dhaka(self):
        r = self.client.post("/api/v1/vehicle/trackers",
                             {"imei": DEV_ID, "name": "Bike", "protocol": "h02"},
                             format="json")
        self.assertEqual(r.status_code, 201, r.data)
        tid = r.data["tracker"]["id"]
        r = self.client.patch("/api/v1/vehicle/trackers/%d" % tid, {
            "speed_limit_kmh": 60, "night_ignition_alert": False,
            "alert_prefs": {"ignition_on": True, "ignition_off": True},
            "geofences": [
                {"id": "home", "name": "Home", "lat": HOME[0], "lng": HOME[1],
                 "radius_m": FENCE_M},
                {"id": "office", "name": "Office", "lat": OFFICE[0], "lng": OFFICE[1],
                 "radius_m": FENCE_M}]}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        return tid

    def first_push(self, kind):
        for t, m in self.push_log:
            d = m["message"]["data"]
            if d.get("kind") == "family_alert" and d.get("alert") == kind:
                return t
        return None

    def test_dhaka_commute_alerts_history_cut_offline(self):
        enable_engine_cut(False)              # OFF until the owner's relay test
        tid = self.pair_dhaka()
        now0 = datetime.now(dtz.utc)
        t0 = now0 - timedelta(seconds=600)
        parked = [{"at": t0 + timedelta(seconds=60 * i), "lat": HOME[0], "lng": HOME[1],
                   "speed_kmh": 0.0, "ign": False} for i in range(3)]
        ign_on = [{"at": t0 + timedelta(seconds=180), "lat": HOME[0], "lng": HOME[1],
                   "speed_kmh": 0.0, "ign": True}]
        trip = [dict(p, ign=True) for p in sim.dhaka_trip(t0 + timedelta(seconds=190))]
        end = trip[-1]["at"]
        park = [{"at": end + timedelta(seconds=s), "lat": OFFICE[0], "lng": OFFICE[1],
                 "speed_kmh": 0.0, "ign": ign} for s, ign in ((5, True), (10, True),
                                                             (20, False), (25, False))]
        self.assertLess(park[-1]["at"], now0)
        # burst split points (from the geometry, not hand-tuned indices)
        i_exit = next(i for i, p in enumerate(trip) if not _inside(p, HOME))
        over = [i for i, p in enumerate(trip) if p["speed_kmh"] > 60]
        self.assertGreaterEqual(len(over), 2, "trip must hold >= 2 overspeed fixes")
        i_over = over[1]
        i_enter = next(i for i, p in enumerate(trip) if i > i_over and _inside(p, OFFICE))
        bursts = [("ignition_on", parked + ign_on),
                  ("geofence_exit", trip[:i_exit + 1]),
                  ("overspeed", trip[i_exit + 1:i_over + 1]),
                  ("geofence_enter", trip[i_over + 1:i_enter + 1]),
                  ("ignition_off", trip[i_enter + 1:] + park)]
        n_fixes = sum(len(b) for _, b in bursts)
        lat = {}
        m = {}

        async def run():
            srv = self.server()
            await srv.start()
            try:
                dev = sim.H02Device(DEV_ID)
                await dev.connect("127.0.0.1", self.PORT)
                for kind, fixes in bursts:
                    for p in fixes:
                        await dev.fix(p["lat"], p["lng"], p["speed_kmh"], p["ign"],
                                      p["at"], course=int(p.get("course", 90)))
                    t_w = time.monotonic()
                    ok = await self.wait(lambda: self.first_push(kind) is not None, 12.0)
                    self.assertTrue(ok, "no push for %s (got %s)" % (kind,
                                                                     self.pushed_alerts()))
                    lat[kind] = round(max(0.0, self.first_push(kind) - t_w), 3)
                m["commute_alerts"] = self.pushed_alerts()
                self.assertTrue(await self.wait(lambda: VehiclePosition.objects.filter(
                    tracker_id=tid).count() >= n_fixes, 8.0), "positions not flushed")
                self.assertTrue(await self.wait(lambda: any(
                    c.startswith("S71,") for c in dev.commands), 8.0))

                # ---- engine cut: flag OFF -> refused, never queued
                r = cut_confirmed(self.client, tid)
                self.assertEqual((r.status_code, r.data["reason"]), (403, "feature_off"))
                enable_engine_cut(True)
                # ---- the bike drives off again (live, real clock; stays inside
                # the Office fence so no second fence alert)
                for k in range(4):
                    await dev.fix(OFFICE[0] + 0.0002 * (k + 1), OFFICE[1], 30.0, True,
                                  datetime.now(dtz.utc) - timedelta(seconds=8 - k))
                self.assertTrue(await self.wait(lambda: (VehicleTracker.objects.get(
                    pk=tid).last_speed_kmh or 0) >= 25, 8.0))
                r = cut_confirmed(self.client, tid)
                self.assertEqual((r.status_code, r.data["reason"]), (409, "moving"))
                r = self.client.post("/api/v1/vehicle/trackers/%d/commands" % tid,
                                     {"kind": "engine_cut", "pin": PIN,
                                      "when_stopped": True}, format="json")
                self.assertEqual(r.status_code, 202, r.data)
                self.assertTrue(r.data["wait_stop"])
                cid = r.data["command"]["id"]
                r = self.client.post("/api/v1/vehicle/commands/%d/confirm" % cid,
                                     {"confirm_token": r.data["confirm_token"]},
                                     format="json")
                self.assertEqual((r.status_code, r.data["command"]["state"]),
                                 (201, "queued"), r.data)
                self.assertTrue(r.data["command"]["wait_stop"])
                # several dispatch rounds while moving: NOTHING reaches the relay
                await asyncio.sleep(3 * srv.cmd_poll_s + 0.5)
                self.assertFalse(any(c.startswith("S20,") for c in dev.commands),
                                 "engine cut sent to a MOVING vehicle")
                self.assertTrue(VehicleAuditLog.objects.filter(
                    tracker_id=tid, action="command_held",
                    detail__reason="moving").exists())
                g = self.client.get("/api/v1/vehicle/trackers/%d/commands" % tid).data
                row = next(c for c in g["commands"] if c["id"] == cid)
                self.assertEqual((row["state"], row["wait_stop"], row["held_reason"]),
                                 ("queued", True, "moving"))
                # ---- it stops: three stopped fixes, then the cut goes out
                for _ in range(3):
                    await asyncio.sleep(1.05)
                    await dev.fix(OFFICE[0] + 0.0008, OFFICE[1], 0.0, True,
                                  datetime.now(dtz.utc))
                t_stop = time.monotonic()
                self.assertTrue(await self.wait(lambda: any(
                    c.startswith("S20,") and c.endswith(",1,1") for c in dev.commands),
                    12.0), "held engine cut never sent after the stop")
                i = next(k for k, c in enumerate(dev.commands) if c.startswith("S20,"))
                m["cut_after_stop_s"] = round(dev.command_at[i] - t_stop, 3)
                self.assertTrue(await self.wait(
                    lambda: VehicleCommand.objects.get(pk=cid).state == "acked", 8.0))
                m["bytes_up"], m["bytes_down"] = dev.bytes_up, dev.bytes_down
                m["frames_up"] = dev.frames_up
                await dev.close()
            finally:
                await srv.stop()

        asyncio.run(run())

        # ---- the app's view: live position + trip history (same endpoints)
        t = self.client.get("/api/v1/vehicle/trackers/%d" % tid).data
        self.assertTrue(t["online"])
        self.assertTrue(t["relay_cut"])
        self.assertEqual(t["protocol"], "h02")
        self.assertAlmostEqual(t["live"]["lat"], OFFICE[0] + 0.0008, places=4)
        self.assertFalse(t["live"]["moving"])
        r = self.client.get("/api/v1/vehicle/trackers/%d/route?hours=2" % tid).data
        self.assertGreaterEqual(len(r["points"]), n_fixes)
        self.assertAlmostEqual(r["max_speed_kmh"], 72, delta=1.5)
        self.assertGreaterEqual(len(r["trips"]), 1)
        self.assertTrue(1.6 <= r["total_km"] <= 2.8, r["total_km"])
        tr = self.client.get("/api/v1/vehicle/trackers/%d/trips?hours=24" % tid).data
        self.assertEqual(len(tr["trips"]), len(r["trips"]))

        # ---- every commute alert pushed exactly once (no storm)
        got = m["commute_alerts"]
        for k in ("ignition_on", "geofence_exit", "overspeed", "geofence_enter",
                  "ignition_off"):
            self.assertEqual(got.count(k), 1, (k, got))
            self.assertTrue(VehicleAuditLog.objects.filter(tracker_id=tid,
                                                           action="alert_" + k).exists())
        self.assertNotIn("night_ignition", got)
        cut_push = [x["message"] for _, x in self.push_log
                    if x["message"]["data"].get("command_id") == str(cid)]
        self.assertTrue(cut_push and cut_push[-1]["data"]["state"] == "acked")
        acts = list(VehicleAuditLog.objects.filter(tracker_id=tid)
                    .values_list("action", flat=True))
        for a in ("command_denied", "command_requested", "command_confirmed",
                  "command_held", "command_acked"):
            self.assertIn(a, acts)

        # ---- the tracker goes silent: honest offline state + one alert
        VehicleTracker.objects.filter(pk=tid).update(
            last_seen_at=timezone.now() - timedelta(minutes=45),
            last_fix_at=timezone.now() - timedelta(minutes=45))
        self.assertEqual(VS.sweep_silent(), 1)
        self.assertEqual(VS.sweep_silent(), 0)            # once per silence
        self.assertIn("tracker_silent", self.pushed_alerts())
        t = self.client.get("/api/v1/vehicle/trackers/%d" % tid).data
        self.assertFalse(t["online"])
        self.assertGreaterEqual(t["live"]["fix_age_s"], 45 * 60 - 5)  # last place, aged
        # an engine cut is never accepted (nor held) for an offline tracker
        r = self.client.post("/api/v1/vehicle/trackers/%d/commands" % tid,
                             {"kind": "engine_cut", "pin": PIN, "when_stopped": True},
                             format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (409, "offline"))

        # ---- metrics: alert latency + data per day (measured frame sizes)
        cfg = VS.vcfg()
        avg = m["bytes_up"] / max(1, m["frames_up"])
        per_day = sim.h02_data_per_day(DEV_ID, moving_h=2.0,
                                       moving_s=cfg["moving_interval_s"],
                                       parked_s=cfg["parked_interval_s"])
        measured_day = int(per_day["fixes_per_day"] * (avg + 2 * sim.TCP_SEG_OVERHEAD))
        metrics = {"alert_latency_s": lat,
                   "alert_latency_max_s": max(lat.values()),
                   "cut_sent_after_stop_s": m["cut_after_stop_s"],
                   "trip_fixes": n_fixes, "bytes_up": m["bytes_up"],
                   "bytes_down": m["bytes_down"], "avg_frame_bytes": round(avg, 1),
                   "data_per_day": per_day,
                   "measured_mb_per_day": round(measured_day / 1e6, 3),
                   "measured_mb_per_30_days": round(measured_day * 30 / 1e6, 1),
                   "flush_s": FLUSH_S}
        print("VEH_E2E_METRICS " + json.dumps(metrics, sort_keys=True))
        for k, v in lat.items():
            self.assertLess(v, ALERT_LATENCY_MAX_S, (k, v))
        self.assertLess(m["cut_after_stop_s"], ALERT_LATENCY_MAX_S)
        self.assertLess(per_day["mb_per_30_days"], 50)      # fits the cheapest BD pack


class EngineCutHoldTests(_Setup, APITestCase):
    """flag-vehicle safety: the stopped-only gate runs again right before a cut
    is written to the device; a 'when stopped' cut waits at most
    CUT_HOLD_MAX_MIN, then expires and the owner is told."""

    def moving(self, kmh=40):
        now = timezone.now()
        VehicleTracker.objects.filter(pk=self.t.pk).update(last_speed_kmh=kmh,
                                                            last_fix_at=now)
        VehiclePosition.objects.create(tracker=self.t, at=now, lat=23.781, lng=90.41,
                                       speed_kmh=kmh)

    def request_hold(self):
        r = self.client.post(self.u("/commands"), {"kind": "engine_cut", "pin": PIN,
                                                   "when_stopped": True}, format="json")
        self.assertEqual(r.status_code, 202, r.data)
        r = self.client.post("/api/v1/vehicle/commands/%d/confirm" % r.data["command"]["id"],
                             {"confirm_token": r.data["confirm_token"]}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        return r.data["command"]

    def test_queued_cut_never_dispatched_once_moving(self):
        r = self.cut()                                    # stopped: queued at once
        self.assertEqual(r.data["command"]["state"], "queued")
        self.assertEqual([c["kind"] for c in VS.pending_for([self.t.id])], ["engine_cut"])
        self.moving()                                     # driver set off before dispatch
        self.assertEqual(VS.pending_for([self.t.id]), [])
        self.assertTrue(VehicleAuditLog.objects.filter(action="command_held").exists())
        # restore is never held (it can only make the vehicle safer to drive)
        VehicleCommand.objects.all().delete()
        self.assertEqual(self.cut(kind="engine_restore").status_code, 201)
        self.assertEqual([c["kind"] for c in VS.pending_for([self.t.id])],
                         ["engine_restore"])

    def test_when_stopped_hold_then_expires_with_notice(self):
        self.moving()
        self.assertEqual(self.cut().data["reason"], "moving")     # no opt-in: refused
        c = self.request_hold()
        self.assertEqual((c["state"], c["wait_stop"]), ("queued", True))
        self.assertEqual(c["hold_max_min"], VS.CUT_HOLD_MAX_MIN)
        self.assertEqual(VS.pending_for([self.t.id]), [])
        r = self.client.post(self.u("/commands"), {"kind": "engine_cut", "pin": PIN,
                                                   "when_stopped": True}, format="json")
        self.assertEqual(r.data["reason"], "busy")                 # one at a time
        VehicleCommand.objects.filter(pk=c["id"]).update(
            created_at=timezone.now() - timedelta(minutes=VS.CUT_HOLD_MAX_MIN + 1))
        VS.expire_commands()
        row = VehicleCommand.objects.get(pk=c["id"])
        self.assertEqual((row.state, row.fail_reason), ("expired", "never_stopped"))
        n = NotifEvent.objects.filter(user=self.owner, title_en="Engine cut was not sent")
        self.assertEqual(n.count(), 1)
        self.assertTrue(any("০" <= ch <= "৯" for ch in n[0].body_bn))   # Bangla digits

    def test_hold_can_be_cancelled_and_never_for_stale_or_offline(self):
        self.moving()
        c = self.request_hold()
        r = self.client.post("/api/v1/vehicle/commands/%d/cancel" % c["id"])
        self.assertEqual(r.data["command"]["state"], "cancelled")
        self.assertFalse(r.data["command"]["wait_stop"])
        VehicleTracker.objects.filter(pk=self.t.pk).update(
            last_fix_at=timezone.now() - timedelta(minutes=10), last_speed_kmh=0)
        r = self.client.post(self.u("/commands"), {"kind": "engine_cut", "pin": PIN,
                                                   "when_stopped": True}, format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (409, "stale_fix"))

    def test_approval_of_held_cut_keeps_it_held(self):
        self.client.patch(self.u(), {"cutoff_requires_approval": True,
                                     "approver_member_id": self.member.id}, format="json")
        self.moving()
        c = self.request_hold()
        self.assertEqual(c["state"], "awaiting_approval")
        self.as_(self.fam)
        r = self.client.post("/api/v1/vehicle/commands/%d/approve" % c["id"], {"pin": PIN},
                             format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data["command"]["state"], "queued")
        self.assertEqual(VS.pending_for([self.t.id]), [])           # still moving

    def test_data_per_day_from_real_frames(self):
        d = sim.h02_data_per_day(DEV_ID, moving_h=2.0, moving_s=5, parked_s=180)
        self.assertEqual(d["fixes_per_day"], 1440 + 440)
        self.assertTrue(80 <= d["frame_bytes"] <= 130, d)
        self.assertLess(d["mb_per_30_days"], 20)

    def test_dhaka_trip_is_realistic(self):
        pts = sim.dhaka_trip(datetime(2026, 11, 17, 2, 0, tzinfo=dtz.utc))
        km = sum(VT.haversine_m(a["lat"], a["lng"], b["lat"], b["lng"])
                 for a, b in zip(pts, pts[1:])) / 1000
        self.assertTrue(1.8 <= km <= 2.6, km)
        self.assertEqual(pts[-1]["speed_kmh"], 0)
        for a, b in zip(pts, pts[1:]):             # never a GPS jump
            dt = (b["at"] - a["at"]).total_seconds()
            self.assertLess(VT.haversine_m(a["lat"], a["lng"], b["lat"], b["lng"]) / dt * 3.6,
                            VT.MAX_JUMP_KMH)
