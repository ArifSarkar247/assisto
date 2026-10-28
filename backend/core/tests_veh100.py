"""veh100 (owner order 28 Oct): vehicle tracking to best-in-market.

  * protocols: Coban TK103 / GPS103 (Traccar public vector, login LOAD,
    heartbeat ON, keyword alarms, ACC keywords, jt/kt confirmations, UTC day
    roll-over), GT06 terminal-info alarm bits + 0x23 heartbeat + 0x94
    external voltage, H02 power-cut bit, Teltonika unplug IO 252;
  * pure logic: polygon fences + direction, device-alarm rising edges +
    voltage hysteresis, tracker-silent, alert gate (cooldown / quiet hours /
    daily cap / SOS bypass), stopped-for-N-fixes, driver behaviour (honest
    coverage), day / month stats, maintenance by km + date, paper stages,
    ignition on/off + long-stop-anywhere alerts;
  * API: share links (create / list / revoke / public page + data, every
    state, no history, rate limit), reports (day / month / CSV / driver),
    drivers, maintenance, setup guide, alert prefs, polygon fences, odometer,
    engine cut behind its flag + the second confirmation;
  * service: ingest (status alarms once, odometer, ignition from status),
    silent sweep, IMEI alias pairing, nightly rollup, reminder pushes
    (stages, 1/day cap, quiet hours, idempotent);
  * REAL TCP: TK103 pair -> drive -> power-cut keyword -> push -> engine cut
    (two steps) -> J -> jt -> acked; GT06 heartbeat power-cut + low battery ->
    exactly one push each.
"""
import asyncio
import os
from datetime import date, datetime, timedelta, timezone as dtz
from unittest import mock
from zoneinfo import ZoneInfo

from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APITestCase, APITransactionTestCase

from core import vehicle100 as V1
from core import vehicle_service as VS
from core.logic import vehicle_tracking as VT
from core.models import (VehicleTracker, VehiclePosition, VehicleCommand,
                         VehicleAuditLog, VehicleShareLink, VehicleDriverShift,
                         VehicleDailyStat, VehicleReminderClaim, NotifEvent,
                         PaCollectionItem, VehicleAccessGrant)
from core.tests_v1_vehicle import (_Setup, IMEI_A, IMEI_B, IMEI_C, PIN, luhn_imei,
                                   enable_engine_cut, cut_confirmed)
from core.tests_e2e_vehicle import _PushMixin
from tracker.protocols import gt06, h02, teltonika, tk103

DHAKA = ZoneInfo("Asia/Dhaka")
IMEI_TK = luhn_imei("35958601582980")
PORT_TK = 15027
PORT_GT06_PWR = 15028


def UT(sec=0):
    return datetime(2026, 10, 20, 6, 0, 0, tzinfo=dtz.utc) + timedelta(seconds=sec)


# =========================================================================== protocols

class TK103ProtocolTests(TestCase):
    TRACCAR = (b"imei:359586015829802,tracker,0809231929,13554900601,F,112909.397,A,"
               b"2234.4669,N,11354.3287,E,0.11,;")

    def test_traccar_public_vector(self):
        p = tk103.parse_frame(self.TRACCAR)
        self.assertEqual((p["kind"], p["imei"]), ("gps", "359586015829802"))
        f = p["fix"]
        self.assertEqual(f["at"], datetime(2008, 9, 23, 11, 29, 9, tzinfo=dtz.utc))
        self.assertAlmostEqual(f["lat"], 22.574448, places=5)
        self.assertAlmostEqual(f["lng"], 113.905478, places=5)
        self.assertAlmostEqual(f["speed_kmh"], 0.2, places=1)
        self.assertTrue(f["valid"])
        self.assertNotIn("ignition", f)          # never guessed

    def test_login_heartbeat_and_detection(self):
        self.assertEqual(tk103.parse_frame(tk103.login_packet(IMEI_TK)),
                         {"kind": "login", "imei": IMEI_TK})
        self.assertEqual(tk103.parse_frame(tk103.heartbeat_packet(IMEI_TK))["kind"],
                         "heartbeat")
        self.assertTrue(tk103.looks_like_tk103(b"##,imei:359586015829802,A;"))
        self.assertTrue(tk103.looks_like_tk103(b"359586015829802;"))
        self.assertTrue(tk103.looks_like_tk103(self.TRACCAR))
        self.assertFalse(tk103.looks_like_tk103(b"*HQ,123,V1#"))
        self.assertFalse(tk103.looks_like_tk103(b"\x00\x0f359586015829802"))

    def test_keywords_alarms_ignition_and_replies(self):
        at = UT()
        for kw, alarm in (("help me", "sos"), ("low battery", "low_battery"),
                          ("ac alarm", "power_cut"), ("power alarm", "power_cut")):
            p = tk103.parse_frame(tk103.position_packet(IMEI_TK, at, 23.78, 90.41, 0,
                                                        keyword=kw))
            self.assertEqual(p["fix"]["alarms"], [alarm], kw)
        on = tk103.parse_frame(tk103.position_packet(IMEI_TK, at, 23.78, 90.41, 0,
                                                     keyword="acc on"))
        self.assertIs(on["fix"]["ignition"], True)
        off = tk103.parse_frame(b"imei:%s,acc off;" % IMEI_TK.encode())
        self.assertEqual((off["kind"], off["ignition"]), ("event", False))
        lbs = tk103.parse_frame(b"imei:%s,help me,,,L,,,,,,,;" % IMEI_TK.encode())
        self.assertEqual((lbs["kind"], lbs["alarms"]), ("event", ["sos"]))
        r = tk103.parse_frame(tk103.reply_packet(IMEI_TK, "jt"))
        self.assertEqual((r["kind"], r["for_kind"], tk103.reply_ok(r["text"])),
                         ("cmd_reply", "engine_cut", True))
        self.assertIsNone(tk103.reply_ok("tracker"))

    def test_utc_day_rollover_dhaka(self):
        # 03:30 local on 29 Oct = 21:30 UTC on 28 Oct
        at = datetime(2026, 10, 28, 21, 30, tzinfo=dtz.utc)
        p = tk103.parse_frame(tk103.position_packet(IMEI_TK, at, 23.78, 90.41, 40, 90))
        self.assertEqual(p["fix"]["at"], at)
        self.assertAlmostEqual(p["fix"]["speed_kmh"], 40, delta=0.1)
        self.assertEqual(p["fix"]["course"], 90)

    def test_bad_frames_and_split(self):
        for bad in (b"imei:12,tracker;", b"hello;", b"imei:359586015829802,tracker,"
                    b"2610281929,,F,999999.000,A,2346.8,N,09024.7,E,0,0;",
                    b"imei:359586015829802,tracker,2610281929,,F,112909.000,A,2399.9,N,"
                    b"09024.7,E,0,0;"):
            with self.assertRaises(tk103.FrameError, msg=bad):
                tk103.parse_frame(bad)
        frames, rest = tk103.split_frames(b"\r\n" + tk103.login_packet(IMEI_TK)
                                          + tk103.heartbeat_packet(IMEI_TK) + b"imei:35")
        self.assertEqual(len(frames), 2)
        self.assertEqual(rest, b"imei:35")
        with self.assertRaises(tk103.FrameError):
            tk103.split_frames(b"x" * 600)

    def test_commands(self):
        self.assertEqual(tk103.server_command(IMEI_TK, tk103.COMMANDS["engine_cut"]),
                         b"**,imei:%s,J;" % IMEI_TK.encode())
        self.assertEqual(tk103.parse_server_command(b"**,imei:%s,K;" % IMEI_TK.encode()),
                         (IMEI_TK, "K"))
        self.assertEqual(tk103.interval_command(5, 180), "C,10s")


class GT06AlarmProtocolTests(TestCase):
    def _one(self, data):
        frames, rest = gt06.split_frames(data)
        self.assertEqual(rest, b"")
        return gt06.parse_frame(frames[0])

    def test_terminal_info_alarm_bits_and_voltage_level(self):
        for alarm in ("sos", "low_battery", "power_cut", "vibration"):
            p = self._one(gt06.status_packet(7, True, False, alarm=alarm, voltage_level=2))
            self.assertEqual(p["status"]["alarm"], alarm)
            self.assertEqual(p["voltage_level"], 2)
            self.assertTrue(p["ack_required"])
        self.assertIsNone(self._one(gt06.status_packet(8))["status"]["alarm"])

    def test_heartbeat_0x23_and_info_0x94(self):
        p = self._one(gt06.heartbeat2_packet(9, 3.92, ignition=True, alarm="power_cut"))
        self.assertEqual((p["kind"], p["battery_v"], p["status"]["alarm"]),
                         ("status", 3.92, "power_cut"))
        self.assertTrue(p["ack_required"])
        p = self._one(gt06.ext_voltage_packet(10, 12.64))
        self.assertEqual((p["kind"], p["ext_voltage_v"], p["ack_required"]),
                         ("info", 12.64, False))


class H02TeltonikaAlarmTests(TestCase):
    def test_h02_power_cut_bit_and_reference_vector_clean(self):
        p = h02.parse_frame(h02.v1_packet("9171234567", UT(), 23.78, 90.41, 30,
                                          power_cut=True))
        self.assertIn("power_cut", p["fix"]["alarms"])
        ref = h02.parse_frame(b"*HQ,865205030330012,V1,145452,A,2240.55181,N,"
                              b"11358.32389,E,0.00,0,100815,FFFFFBFF#")
        self.assertEqual(ref["fix"]["alarms"], [])
        self.assertEqual(h02.status_alarms(0xFFFFFFFF & ~(1 << 1)), ["sos"])

    def test_teltonika_unplug_io(self):
        out = teltonika.derive_io({teltonika.IO_UNPLUG: 1, teltonika.IO_EXT_VOLTAGE: 0})
        self.assertEqual(out["alarms"], ["power_cut"])
        self.assertNotIn("alarms", teltonika.derive_io({teltonika.IO_UNPLUG: 0}))


# =========================================================================== pure logic

SQUARE = [[23.780, 90.410], [23.780, 90.420], [23.790, 90.420], [23.790, 90.410]]


class FenceAndAlertLogicTests(TestCase):
    def test_polygon_and_direction(self):
        self.assertTrue(VT.point_in_polygon(SQUARE, 23.785, 90.415))
        self.assertFalse(VT.point_in_polygon(SQUARE, 23.795, 90.415))
        self.assertFalse(VT.point_in_polygon(SQUARE[:2], 23.785, 90.415))
        fence = {"id": "p", "name": "Office", "points": SQUARE, "alert": "exit"}
        cfg = {"geofences": [fence]}
        st, a = VT.evaluate_alerts({}, {"at": UT(), "lat": 23.795, "lng": 90.415}, cfg, 10)
        st, a = VT.evaluate_alerts(st, {"at": UT(5), "lat": 23.785, "lng": 90.415}, cfg, 10)
        self.assertEqual(a, [])                      # enter muted (exit only)
        st, a = VT.evaluate_alerts(st, {"at": UT(10), "lat": 23.795, "lng": 90.415}, cfg, 10)
        self.assertEqual([x["kind"] for x in a], ["geofence_exit"])

    def test_ignition_on_off_opt_in_and_no_double_at_night(self):
        cfg = {"ignition_on": True, "ignition_off": True, "night_ignition": True,
               "night_start": "23:00", "night_end": "05:00"}
        st, a = VT.evaluate_alerts({}, {"ignition": False, "valid": False}, cfg, 12)
        st, a = VT.evaluate_alerts(st, {"ignition": True, "valid": False}, cfg, 12)
        self.assertEqual([x["kind"] for x in a], ["ignition_on"])
        st, a = VT.evaluate_alerts(st, {"ignition": False, "valid": False}, cfg, 12)
        self.assertEqual([x["kind"] for x in a], ["ignition_off"])
        st, a = VT.evaluate_alerts(st, {"ignition": True, "valid": False}, cfg, 1)
        self.assertEqual([x["kind"] for x in a], ["night_ignition"])
        st, a = VT.evaluate_alerts({"ign": False}, {"ignition": True, "valid": False},
                                   {"ignition_on": False}, 12)
        self.assertEqual(a, [])

    def test_long_stop_anywhere(self):
        cfg = {"stop_alert_min": 10}
        st = {}
        st, a = VT.evaluate_alerts(st, {"at": UT(0), "lat": 23.78, "lng": 90.41,
                                        "speed_kmh": 0}, cfg, 10)
        st, a = VT.evaluate_alerts(st, {"at": UT(900), "lat": 23.78, "lng": 90.41,
                                        "speed_kmh": 0}, cfg, 10)
        self.assertEqual(a, [])                      # never moved: parked, no alert
        st, _ = VT.evaluate_alerts(st, {"at": UT(905), "lat": 23.78, "lng": 90.41,
                                        "speed_kmh": 30}, cfg, 10)
        kinds = []
        for i in range(1, 15):
            st, a = VT.evaluate_alerts(st, {"at": UT(905 + i * 60), "lat": 23.79,
                                            "lng": 90.41, "speed_kmh": 0}, cfg, 10)
            kinds += [x["kind"] for x in a]
        self.assertEqual(kinds, ["long_stop"])       # once per stop

    def test_device_alarm_edges_and_voltage_hysteresis(self):
        st, a = VT.evaluate_device({}, ["sos", "vibration"])
        self.assertEqual([x["alarm"] for x in a], ["sos"])
        st, a = VT.evaluate_device(st, ["sos"])
        self.assertEqual(a, [])                      # level held: no repeat
        st, a = VT.evaluate_device(st, [])
        st, a = VT.evaluate_device(st, ["sos"])
        self.assertEqual(len(a), 1)                  # a new press alerts again
        st, a = VT.evaluate_device({}, [], {"ext_voltage_v": 0.1})
        self.assertEqual(a, [])                      # never saw main power: no claim
        st, _ = VT.evaluate_device(st, [], {"ext_voltage_v": 12.5})
        st, a = VT.evaluate_device(st, [], {"ext_voltage_v": 0.2})
        self.assertEqual((a[0]["alarm"], a[0]["source"]), ("power_cut", "voltage"))
        st, a = VT.evaluate_device(st, [], {"ext_voltage_v": 6.0})   # flapping: no re-arm
        st, a = VT.evaluate_device(st, [], {"ext_voltage_v": 0.0})
        self.assertEqual(a, [])
        st, a = VT.evaluate_device({}, [], {"voltage_level": 1})
        self.assertEqual(a[0]["alarm"], "low_battery")
        st, a = VT.evaluate_device(st, [], {"voltage_level": 2})
        self.assertEqual(a, [])
        st, _ = VT.evaluate_device(st, [], {"voltage_level": 5})
        st, a = VT.evaluate_device(st, [], {"voltage_level": 2})
        self.assertEqual(len(a), 1)
        # separate slots: a status alarm is not cleared by a fix without it
        st, a = VT.evaluate_device({}, ["power_cut"], slot="st_alarms")
        st, b = VT.evaluate_device(st, [])
        st, c = VT.evaluate_device(st, ["power_cut"], slot="st_alarms")
        self.assertEqual((len(a), len(b), len(c)), (1, 0, 0))

    def test_silent_once_per_silence(self):
        seen = UT()
        st, a = VT.silent_alert({}, seen, UT(20 * 60), 30)
        self.assertIsNone(a)
        st, a = VT.silent_alert(st, seen, UT(31 * 60), 30)
        self.assertEqual(a["kind"], "tracker_silent")
        st, a = VT.silent_alert(st, seen, UT(90 * 60), 30)
        self.assertIsNone(a)
        st, a = VT.silent_alert(st, UT(100 * 60), UT(140 * 60), 30)
        self.assertIsNotNone(a)                      # new silence re-arms

    def test_gate_cooldown_quiet_cap_and_sos(self):
        day = datetime(2026, 10, 28, 14, 0, tzinfo=DHAKA)
        d, st = VT.gate_alert(None, {"kind": "overspeed"}, day)
        self.assertEqual(d, "push")
        d, st = VT.gate_alert(st, {"kind": "overspeed"}, day + timedelta(minutes=5))
        self.assertEqual(d, "drop")
        d, st = VT.gate_alert(st, {"kind": "overspeed"}, day + timedelta(minutes=11))
        self.assertEqual(d, "push")
        # different alarms never hide each other
        d1, st = VT.gate_alert(st, {"kind": "device_alarm", "alarm": "power_cut"}, day)
        d2, st = VT.gate_alert(st, {"kind": "device_alarm", "alarm": "sos"}, day)
        self.assertEqual((d1, d2), ("push", "push"))
        night = datetime(2026, 10, 28, 23, 30, tzinfo=DHAKA)
        q = {"quiet_start": "23:00", "quiet_end": "06:00"}
        self.assertEqual(VT.gate_alert(None, {"kind": "ignition_on"}, night, q)[0], "inapp")
        self.assertEqual(VT.gate_alert(None, {"kind": "device_alarm", "alarm": "power_cut"},
                                       night, q)[0], "push")       # safety ignores quiet
        st = None
        out = []
        for i in range(5):
            d, st = VT.gate_alert(st, {"kind": "geofence_enter", "fence_id": str(i)},
                                  day, {"daily_push_cap": 3})
            out.append(d)
        self.assertEqual(out, ["push", "push", "push", "inapp", "inapp"])
        d, st = VT.gate_alert(st, {"kind": "device_alarm", "alarm": "sos"}, day,
                              {"daily_push_cap": 3})
        self.assertEqual(d, "push")                  # SOS always pushes
        d, st = VT.gate_alert(st, {"kind": "geofence_enter", "fence_id": "9"},
                              day + timedelta(days=1), {"daily_push_cap": 3})
        self.assertEqual(d, "push")                  # new day resets the cap

    def test_stopped_for(self):
        now = UT(600)
        stopped = [{"at": now - timedelta(seconds=s), "speed_kmh": 0} for s in (5, 10, 15)]
        self.assertEqual(VT.stopped_for(stopped, now), (True, "ok"))
        self.assertEqual(VT.stopped_for(stopped[:2], now), (False, "few_fixes"))
        rolling = stopped[:2] + [{"at": now - timedelta(seconds=15), "speed_kmh": 12}]
        self.assertEqual(VT.stopped_for(rolling, now), (False, "moving"))
        old = [{"at": now - timedelta(seconds=s), "speed_kmh": 0} for s in (300, 310, 320)]
        self.assertEqual(VT.stopped_for(old, now), (False, "stale_fix"))


def _drive(speeds, step_s=3, t0=None, lat=23.78, lng=90.41):
    t = t0 or UT()
    out = []
    for v in speeds:
        out.append({"at": t, "lat": lat, "lng": lng, "speed_kmh": float(v), "valid": True,
                    "ignition": True})
        lng += max(v, 0) / 3.6 * step_s / (111320.0 * 0.915)
        t += timedelta(seconds=step_s)
    return out


class BehaviourAndReportLogicTests(TestCase):
    def test_harsh_events_overspeed_and_score(self):
        b = VT.behaviour(_drive([0, 20, 50, 60, 60, 60, 20, 0, 0], 3), speed_limit_kmh=55)
        self.assertEqual((b["harsh_brake"], b["harsh_accel"]), (1, 1))
        self.assertGreater(b["overspeed_s"], 0)
        self.assertLess(b["score"], 100)
        self.assertFalse(b["limited"])
        smooth = VT.behaviour(_drive([0, 5, 10, 15, 20, 25, 30, 30, 30] * 10, 3), 80)
        self.assertEqual(smooth["score"], 100)

    def test_honest_coverage_limit(self):
        sparse = VT.behaviour(_drive([40, 40, 0, 40, 40], 60))
        self.assertTrue(sparse["limited"])
        self.assertEqual(sparse["harsh_brake"], 0)   # 40->0 over 60 s is NOT harsh
        self.assertTrue(sparse["limit_default"])
        self.assertIsNone(VT.behaviour([])["score"])
        self.assertEqual(VT.score_band(None), "none")
        self.assertEqual([VT.score_band(x) for x in (90, 75, 40)], ["good", "ok", "improve"])

    def test_day_and_month_totals(self):
        fx = _drive([0] + [40] * 60 + [0] * 70, 5)
        d = VT.day_stats(fx, 60)
        self.assertEqual(d["trips"], 1)
        self.assertGreater(d["km"], 0.5)
        self.assertGreater(d["idle_s"], 0)           # ignition on while stopped
        m = VT.month_totals([d, {**d, "score": 50}, {"km": 0, "score": None}])
        self.assertEqual(m["days_driven"], 2)
        self.assertEqual(m["trips"], 2)
        self.assertEqual(m["score"], int(round((d["score"] + 50) / 2)))

    def test_maintenance_and_paper_stages(self):
        today = date(2026, 10, 28)
        r = VT.maintenance_due({"every_km": 5000, "last_km": 10000}, 14800, today)
        self.assertEqual((r["due"], r["by"], r["km_left"]), (True, "km", 200.0))
        r = VT.maintenance_due({"every_km": 5000, "last_km": 10000}, 12000, today)
        self.assertFalse(r["due"])
        r = VT.maintenance_due({"every_days": 90, "last_date": "2026-07-01"}, None, today)
        self.assertEqual((r["due"], r["overdue"], r["by"]), (True, True, "date"))
        r = VT.maintenance_due({"every_km": 3000, "last_km": 0}, None, today)
        self.assertFalse(r["due"])                   # no odometer: honestly unknown
        self.assertEqual([VT.paper_stage(x) for x in (40, 30, 8, 7, 1, 0, -1)],
                         [None, 30, 30, 7, 1, 1, None])


# =========================================================================== API

class _Api(_Setup, APITestCase):
    pass


@override_settings(WEB_PUBLIC_SITE="https://lifeassisto.com")
class ShareLinkTests(_Api):
    def test_create_list_public_states_and_revoke(self):
        r = self.client.post(self.u("/share"), {"hours": 8, "label": "Abbu"}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        url = r.data["link"]["url"]
        self.assertTrue(url.startswith("https://lifeassisto.com/v/"))
        token = url.rsplit("/", 1)[1]
        link = VehicleShareLink.objects.get()
        self.assertNotIn(token, link.token_hash)     # only the hash is stored
        self.client.logout()
        d = self.client.get("/v/%s/data" % token).json()
        self.assertEqual(d["state"], "live")
        self.assertEqual((d["lat"], d["lng"]), (23.78, 90.41))
        self.assertNotIn("points", d)                # never history
        page = self.client.get("/v/%s" % token)
        self.assertEqual(page.status_code, 200)
        self.assertEqual(page["X-Robots-Tag"], "noindex, nofollow")
        self.assertEqual(page["Cache-Control"], "no-store")
        self.assertContains(page, "গাড়ির লাইভ অবস্থান")
        self.assertContains(self.client.get("/v/%s?lang=en" % token), "Vehicle live location")
        self.assertEqual(VehicleShareLink.objects.get().views, 2)
        self.assertEqual(self.client.get("/v/not-a-token/data").status_code, 404)
        # stale -> lost as the fix ages
        VehicleTracker.objects.filter(pk=self.t.pk).update(
            last_fix_at=timezone.now() - timedelta(minutes=20))
        self.assertEqual(self.client.get("/v/%s/data" % token).json()["state"], "lost")
        # paused tracker shows no location
        VehicleTracker.objects.filter(pk=self.t.pk).update(state="disabled")
        d = self.client.get("/v/%s/data" % token).json()
        self.assertEqual(d["state"], "paused")
        self.assertNotIn("lat", d)
        VehicleTracker.objects.filter(pk=self.t.pk).update(state="paired")
        # owner revokes
        self.as_(self.owner)
        lst = self.client.get(self.u("/share")).data
        self.assertEqual(lst["links"][0]["state"], "active")
        self.assertNotIn("url", lst["links"][0])     # the token is shown only once
        r = self.client.delete(self.u("/share/%d" % link.id))
        self.assertEqual(r.data["link"]["state"], "revoked")
        d = self.client.get("/v/%s/data" % token).json()
        self.assertEqual(d, {"state": "revoked"})
        self.assertTrue(VehicleAuditLog.objects.filter(action="share_revoked").exists())

    def test_expiry_limits_and_access(self):
        self.assertEqual(self.client.post(self.u("/share"), {"hours": 5},
                                          format="json").data["reason"], "bad_hours")
        r = self.client.post(self.u("/share"), {"hours": 1}, format="json")
        token = r.data["link"]["url"].rsplit("/", 1)[1]
        VehicleShareLink.objects.update(expires_at=timezone.now() - timedelta(seconds=1))
        self.assertEqual(self.client.get("/v/%s/data" % token).json(), {"state": "expired"})
        for _ in range(V1.MAX_ACTIVE_SHARES):
            self.client.post(self.u("/share"), {"hours": 1}, format="json")
        self.assertEqual(self.client.post(self.u("/share"), {"hours": 1},
                                          format="json").data["reason"], "too_many_links")
        VehicleAccessGrant.objects.create(tracker=self.t, grantee=self.fam, kind="family")
        self.as_(self.fam)                           # viewers cannot share onward
        self.assertEqual(self.client.post(self.u("/share"), {"hours": 1},
                                          format="json").status_code, 403)
        self.as_(self.other)
        self.assertEqual(self.client.get(self.u("/share")).status_code, 404)

    def test_public_rate_limit(self):
        r = self.client.post(self.u("/share"), {"hours": 1}, format="json")
        token = r.data["link"]["url"].rsplit("/", 1)[1]
        self.client.logout()
        from web import views_vehicle_share as WS
        with mock.patch.object(WS, "RATE_PER_MIN", 3):
            codes = [self.client.get("/v/%s/data" % token).status_code for _ in range(5)]
        self.assertEqual(codes[-1], 429)


class ReportDriverTests(_Api):
    def setUp(self):
        super().setUp()
        VehiclePosition.objects.filter(tracker=self.t).delete()
        now = timezone.now()
        start = now - timedelta(minutes=30)
        if (start + timedelta(minutes=9)).astimezone(DHAKA).date() != \
                start.astimezone(DHAKA).date():
            start -= timedelta(minutes=15)        # never straddle local midnight
        self.day = start.astimezone(DHAKA).date()
        self.start = start
        for f in _drive([0] + [45] * 80 + [0] * 5, 5, t0=start):
            VehiclePosition.objects.create(tracker=self.t, at=f["at"], lat=f["lat"],
                                           lng=f["lng"], speed_kmh=f["speed_kmh"],
                                           ignition=True)
        self.drv = PaCollectionItem.objects.create(user=self.owner,
                                                   collection="vehicle/drivers",
                                                   data={"name": "Karim"})

    def test_day_month_csv_and_driver(self):
        r = self.client.post(self.u("/driver"), {"driver_id": self.drv.id}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        VehicleDriverShift.objects.update(started_at=self.start - timedelta(minutes=1))
        rep = self.client.get(self.u("/report?period=day&date=%s" % self.day)).data
        self.assertEqual(rep["totals"]["trips"], 1)
        self.assertGreater(rep["totals"]["km"], 4)
        self.assertEqual(rep["drivers"][0]["name"], "Karim")
        self.assertIsNotNone(rep["totals"]["score"])
        m = self.client.get(self.u("/report?period=month&month=%s" %
                                   self.day.strftime("%Y-%m"))).data
        self.assertEqual(len(m["days"]), 1)
        self.assertEqual(m["totals"]["trips"], 1)
        csv_bn = self.client.get(self.u("/report?period=month&format=csv&month=%s" %
                                        self.day.strftime("%Y-%m")))
        self.assertEqual(csv_bn["Content-Type"], "text/csv; charset=utf-8")
        body = csv_bn.content.decode("utf-8")
        self.assertTrue(body.startswith("﻿তারিখ"))
        self.assertIn("মোট", body)
        en = self.client.get(self.u("/report?period=day&format=csv&lang=en")).content.decode()
        self.assertIn("Distance (km)", en)
        dr = self.client.get("/api/v1/vehicle/drivers/%d/report" % self.drv.id).data
        self.assertEqual(dr["name"], "Karim")
        self.assertEqual(dr["totals"]["trips"], 1)
        # rollup writes vehicle + driver rows; idempotent
        self.assertEqual(V1.rollup_day(self.t, self.day), 2)
        self.assertEqual(V1.rollup_day(self.t, self.day), 2)
        self.assertEqual(VehicleDailyStat.objects.count(), 2)
        # unassign ends the shift
        self.client.post(self.u("/driver"), {"driver_id": None}, format="json")
        self.assertIsNotNone(VehicleDriverShift.objects.get().ended_at)

    def test_bad_inputs_and_access(self):
        for q in ("period=week", "period=day&date=2999-01-01", "period=month&month=13-2026",
                  "period=day&date=yesterday"):
            self.assertEqual(self.client.get(self.u("/report?" + q)).status_code, 400, q)
        other_drv = PaCollectionItem.objects.create(user=self.other,
                                                    collection="vehicle/drivers", data={})
        self.assertEqual(self.client.post(self.u("/driver"), {"driver_id": other_drv.id},
                                          format="json").data["reason"], "bad_driver")
        self.assertEqual(self.client.get("/api/v1/vehicle/drivers/%d/report" %
                                         other_drv.id).status_code, 404)
        self.as_(self.other)
        self.assertEqual(self.client.get(self.u("/report")).status_code, 404)
        self.assertEqual(self.client.get(self.u("/driver")).status_code, 404)


class SettingsGuideMaintenanceTests(_Api):
    def test_alert_prefs_polygon_odometer(self):
        r = self.client.patch(self.u(), {"alert_prefs": {
            "ignition_on": True, "stop_alert_min": 9999, "quiet_start": "23:00",
            "quiet_end": "06:00", "junk": 1}}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        p = r.data["settings"]["alert_prefs"]
        self.assertEqual((p["ignition_on"], p["stop_alert_min"], p["quiet_start"]),
                         (True, 720, "23:00"))
        self.assertNotIn("junk", p)
        self.assertEqual(self.client.patch(self.u(), {"alert_prefs": {"quiet_start": "25:00"}},
                                           format="json").status_code, 400)
        r = self.client.patch(self.u(), {"geofences": [
            {"name": "Office", "points": SQUARE, "alert": "exit"},
            {"name": "Home", "lat": 23.78, "lng": 90.41, "radius_m": 300}]}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        poly = r.data["settings"]["geofences"][0]
        self.assertEqual((poly["type"], len(poly["points"]), poly["alert"]),
                         ("polygon", 4, "exit"))
        for bad in ([{"points": SQUARE[:2]}], [{"points": [[99, 1]] * 3}]):
            self.assertEqual(self.client.patch(self.u(), {"geofences": bad},
                                               format="json").status_code, 400)
        VehicleTracker.objects.filter(pk=self.t.pk).update(odometer_m=2500)
        r = self.client.patch(self.u(), {"odometer_km": 45210}, format="json")
        self.assertEqual(r.data["odometer_km"], 45210.0)
        VehicleTracker.objects.filter(pk=self.t.pk).update(odometer_m=4000)
        self.assertEqual(self.client.get(self.u()).data["odometer_km"], 45211.5)

    def test_setup_guide_per_brand(self):
        g = self.client.get("/api/v1/vehicle/setup-guide?brand=sinotrack&operator=robi").data
        self.assertEqual(g["protocol"], "h02")
        self.assertEqual(g["steps"][0]["sms"], "8030000 internet")
        self.assertIn("5023", g["steps"][1]["sms"])
        c = self.client.get("/api/v1/vehicle/setup-guide?brand=coban&operator=banglalink").data
        self.assertEqual((c["protocol"], c["steps"][1]["sms"]),
                         ("tk103", "apn123456 blweb"))
        t = self.client.get("/api/v1/vehicle/setup-guide?brand=teltonika").data
        self.assertTrue(t["steps"][1]["sms"].startswith("  setparam 2004:"))
        x = self.client.get("/api/v1/vehicle/setup-guide?brand=concox&password=666666").data
        self.assertIn("SERVER,666666,1,", x["steps"][1]["sms"])
        self.assertEqual(self.client.get("/api/v1/vehicle/setup-guide?brand=apple")
                         .status_code, 400)

    def test_maintenance_view_and_tk103_pairing(self):
        rec = PaCollectionItem.objects.create(
            user=self.owner, collection="vehicle/records",
            data={"name": "Corolla", "tax_token_expiry": (timezone.now().astimezone(DHAKA)
                                                          .date() + timedelta(days=5))
                  .isoformat(),
                  "maintenance": [{"id": "oil", "name": "Engine oil", "every_km": 3000,
                                   "last_km": 0}]})
        VehicleTracker.objects.filter(pk=self.t.pk).update(vehicle_record=rec,
                                                           odometer_m=2900 * 1000)
        r = self.client.get("/api/v1/vehicle/maintenance").data
        kinds = sorted(x["kind"] for x in r["due"])
        self.assertEqual(kinds, ["maintenance", "paper"])
        v = r["vehicles"][0]
        self.assertEqual((v["odometer_source"], v["maintenance"][0]["by"]), ("tracker", "km"))
        r = self.client.post("/api/v1/vehicle/trackers", {"imei": IMEI_B, "protocol": "tk103"},
                             format="json")
        self.assertEqual(r.data["tracker"]["protocol"], "tk103")


class EngineCutFlagAndConfirmTests(_Api):
    def post(self, kind="engine_cut", pin=PIN):
        return self.client.post(self.u("/commands"), {"kind": kind, "pin": pin},
                                format="json")

    def confirm(self, cid, token):
        return self.client.post("/api/v1/vehicle/commands/%d/confirm" % cid,
                                {"confirm_token": token}, format="json")

    def test_flag_off_refuses_cut_but_not_restore(self):
        enable_engine_cut(False)
        r = self.post()
        self.assertEqual((r.status_code, r.data["reason"]), (403, "feature_off"))
        self.assertFalse(self.client.get(self.u()).data["engine_cut_enabled"])
        self.assertEqual(self.post("engine_restore").status_code, 201)
        self.assertTrue(VehicleAuditLog.objects.filter(action="command_denied",
                                                       detail__reason="feature_off").exists())

    def test_two_step_confirm_rules(self):
        r = self.post()
        self.assertEqual(r.status_code, 202, r.data)
        cid, token = r.data["command"]["id"], r.data["confirm_token"]
        self.assertEqual(VehicleCommand.objects.get(pk=cid).state, "awaiting_confirm")
        self.assertEqual(VehicleCommand.objects.filter(state="queued").count(), 0)
        self.assertEqual(self.post().data["reason"], "busy")     # one at a time
        self.assertEqual(self.confirm(cid, "wrong").status_code, 403)
        self.as_(self.fam)                                         # not the requester
        self.assertEqual(self.confirm(cid, token).status_code, 404)
        self.as_(self.owner)
        r = self.confirm(cid, token)
        self.assertEqual((r.status_code, r.data["command"]["state"]), (201, "queued"))
        self.assertEqual(self.confirm(cid, token).status_code, 409)   # one-time
        actions = list(VehicleAuditLog.objects.filter(tracker=self.t)
                       .values_list("action", flat=True))
        for a in ("command_requested", "command_denied", "command_confirmed"):
            self.assertIn(a, actions)

    def test_confirm_rechecks_movement_and_timeout(self):
        r = self.post()
        cid, token = r.data["command"]["id"], r.data["confirm_token"]
        # the car moved off between the two taps
        VehiclePosition.objects.create(tracker=self.t, at=timezone.now(), lat=23.78,
                                       lng=90.41, speed_kmh=18)
        r = self.confirm(cid, token)
        self.assertEqual((r.status_code, r.data["reason"]), (409, "moving"))
        self.assertEqual(VehicleCommand.objects.get(pk=cid).state, "cancelled")
        VehiclePosition.objects.filter(speed_kmh=18).delete()
        r = self.post()
        cid, token = r.data["command"]["id"], r.data["confirm_token"]
        VehicleCommand.objects.filter(pk=cid).update(
            created_at=timezone.now() - timedelta(seconds=90))
        r = self.confirm(cid, token)
        self.assertEqual(r.data["reason"], "confirm_timeout")
        # an expired unconfirmed request never blocks a new one
        r = self.post()
        self.assertEqual(r.status_code, 202)

    def test_needs_three_stopped_fixes(self):
        VehiclePosition.objects.filter(tracker=self.t).order_by("at").first().delete()
        r = self.post()
        self.assertEqual((r.status_code, r.data["reason"]), (409, "few_fixes"))

    def test_expire_sweeps_unconfirmed(self):
        r = self.post()
        VehicleCommand.objects.filter(pk=r.data["command"]["id"]).update(
            created_at=timezone.now() - timedelta(minutes=3))
        VS.expire_commands()
        self.assertEqual(VehicleCommand.objects.get(pk=r.data["command"]["id"]).state,
                         "expired")


# =========================================================================== service

class IngestServiceTests(_Api):
    def test_status_alarm_once_odometer_and_status_ignition(self):
        now = timezone.now()
        VehicleTracker.objects.filter(pk=self.t.pk).update(
            alert_prefs={"ignition_on": True}, night_ignition_alert=False)
        VS.ingest({self.t.id: {"fixes": [], "status": {"alarms": ["power_cut"],
                                                       "ignition": False}}}, now=now)
        VS.ingest({self.t.id: {"fixes": [], "status": {"alarms": ["power_cut"]}}},
                  now=now + timedelta(seconds=30))
        self.assertEqual(NotifEvent.objects.filter(user=self.owner,
                                                   meta__alarm="power_cut").count(), 1)
        VS.ingest({self.t.id: {"fixes": [], "status": {"ignition": True}}},
                  now=now + timedelta(seconds=40))
        self.assertTrue(NotifEvent.objects.filter(meta__alert="ignition_on").exists())
        fx = [{"at": now + timedelta(seconds=60 + i * 5), "lat": 23.78,
               "lng": 90.41 + i * 0.0005, "speed_kmh": 40, "valid": True} for i in range(11)]
        VS.ingest({self.t.id: {"fixes": fx, "status": {}}}, now=now + timedelta(seconds=120))
        t = VehicleTracker.objects.get(pk=self.t.pk)
        self.assertAlmostEqual(t.odometer_m, 10 * 0.0005 * 111320 * 0.9151, delta=40)
        # a re-sent old fix never adds distance
        VS.ingest({self.t.id: {"fixes": fx[:3], "status": {}}},
                  now=now + timedelta(seconds=130))
        self.assertAlmostEqual(VehicleTracker.objects.get(pk=self.t.pk).odometer_m,
                               t.odometer_m, delta=0.5)

    def test_quiet_hours_keep_in_app_only(self):
        VehicleTracker.objects.filter(pk=self.t.pk).update(
            alert_prefs={"ignition_on": True, "quiet_start": "00:00", "quiet_end": "23:59"},
            alert_state={"ign": False})
        with mock.patch("core.push.safe_push") as sp:
            VS.ingest({self.t.id: {"fixes": [], "status": {"ignition": True}}},
                      now=datetime(2026, 10, 28, 6, 0, tzinfo=dtz.utc))
        self.assertTrue(NotifEvent.objects.filter(meta__alert="ignition_on").exists())
        sp.assert_not_called()
        self.assertTrue(VehicleAuditLog.objects.filter(action="alert_ignition_on",
                                                       detail__pushed=False).exists())

    def test_silent_sweep_once_and_rearm(self):
        now = timezone.now()
        VehicleTracker.objects.filter(pk=self.t.pk).update(last_seen_at=now -
                                                           timedelta(minutes=45))
        self.assertEqual(VS.sweep_silent(now), 1)
        self.assertEqual(VS.sweep_silent(now + timedelta(minutes=5)), 0)
        self.assertTrue(NotifEvent.objects.filter(meta__alert="tracker_silent").exists())
        VS.ingest({self.t.id: {"fixes": [], "status": {}}}, now=now)   # seen again
        self.assertNotIn("silent_for", VehicleTracker.objects.get(pk=self.t.pk).alert_state)

    def test_imei_alias_pairing(self):
        long_id = "865205030330012"
        t = VehicleTracker.objects.create(owner=self.owner, imei=long_id, protocol="h02",
                                          state="pending",
                                          pair_expires_at=timezone.now() + timedelta(minutes=5))
        tid, reason = VS.on_device_connect("5030330012", "h02")
        self.assertEqual((tid, reason), (t.id, "newly_paired"))
        self.assertEqual(VehicleTracker.objects.get(pk=t.id).imei, "5030330012")
        self.assertTrue(VehicleAuditLog.objects.filter(action="imei_alias_matched").exists())
        # ambiguous / short / not pending: refused
        VehicleTracker.objects.create(owner=self.owner, imei="111222333444555",
                                      state="pending",
                                      pair_expires_at=timezone.now() + timedelta(minutes=5))
        VehicleTracker.objects.create(owner=self.other, imei="911122233344455",
                                      state="pending",
                                      pair_expires_at=timezone.now() + timedelta(minutes=5))
        self.assertEqual(VS.on_device_connect("1122233344", "h02")[1], "unknown")
        self.assertEqual(VS.on_device_connect("123456789", "h02")[1], "unknown")


class ReminderSweepTests(_Api):
    def setUp(self):
        super().setUp()
        self.noon = datetime(2026, 10, 28, 12, 0, tzinfo=DHAKA)
        today = self.noon.date()
        self.rec = PaCollectionItem.objects.create(
            user=self.owner, collection="vehicle/records",
            data={"name": "Corolla",
                  "fitness_expiry": (today + timedelta(days=6)).isoformat(),
                  "route_permit_expiry": (today + timedelta(days=25)).isoformat(),
                  "insurance_expiry": (today - timedelta(days=3)).isoformat(),
                  "odometer_km": 9900,
                  "maintenance": [{"id": "oil", "name": "Engine oil",
                                   "every_km": 5000, "last_km": 5000}]})
        PaCollectionItem.objects.create(
            user=self.owner, collection="vehicle/drivers",
            data={"name": "Karim", "licence_expiry": (today + timedelta(days=1)).isoformat()})
        self.sent = []

    def push(self, user, kind, tbn, ten, bbn, ben, data=None, **kw):
        self.sent.append((user.id, kind, tbn, ten, bbn, ben, data))
        return 1

    def test_one_push_per_day_stages_and_idempotent(self):
        st = V1.sweep_reminders(now=self.noon, push_fn=self.push)
        self.assertEqual((st["pushes"], st["items"]), (1, 4))
        uid, kind, tbn, ten, bbn, ben, data = self.sent[0]
        self.assertEqual((kind, data["route"]), ("reminder", "vehicles"))
        self.assertIn("৪টি", tbn)
        self.assertIn("4 vehicle items", ten)
        self.assertIn("আরও ১টি", bbn)
        self.assertNotIn("insurance", ben.lower())          # already expired: no push
        self.assertEqual(V1.sweep_reminders(now=self.noon + timedelta(hours=1),
                                            push_fn=self.push).get("capped"), 1)
        # next day: nothing new (stages already claimed)
        st = V1.sweep_reminders(now=self.noon + timedelta(days=1), push_fn=self.push)
        self.assertEqual(st.get("pushes", 0), 0)
        # fitness reaches the 1-day stage later -> a fresh push
        st = V1.sweep_reminders(now=self.noon + timedelta(days=5), push_fn=self.push)
        self.assertEqual(st["pushes"], 1)
        self.assertIn("ফিটনেস", self.sent[-1][2])
        self.assertEqual(VehicleReminderClaim.objects.filter(user=self.owner).count(), 5)

    def test_quiet_hours_and_privacy(self):
        st = V1.sweep_reminders(now=datetime(2026, 10, 28, 22, 0, tzinfo=DHAKA),
                                push_fn=self.push)
        self.assertEqual(st, {"quiet_hours": 1})
        self.rec.data["registration_no"] = "DHAKA-METRO-GA-11-2233"
        self.rec.save()
        V1.sweep_reminders(now=self.noon, push_fn=self.push)
        blob = " ".join(str(x) for x in self.sent[0])
        self.assertNotIn("11-2233", blob)                  # never the plate number


# =========================================================================== real TCP

class _Tcp(_Setup, _PushMixin, APITransactionTestCase):
    PORT = PORT_TK

    def setUp(self):
        super().setUp()
        self._env = os.environ.get("DJANGO_ALLOW_ASYNC_UNSAFE")
        os.environ["DJANGO_ALLOW_ASYNC_UNSAFE"] = "true"
        VS._unknown_logged.clear()
        self.t.delete()
        self.start_push(self.owner)

    def tearDown(self):
        if self._env is None:
            os.environ.pop("DJANGO_ALLOW_ASYNC_UNSAFE", None)
        else:
            os.environ["DJANGO_ALLOW_ASYNC_UNSAFE"] = self._env

    def server(self):
        from tracker.server import TrackerServer, Store
        return TrackerServer("127.0.0.1", self.PORT, store=Store(inline=True),
                             cfg=VS.vcfg(), flush_s=0.1, cmd_poll_s=0.1)

    async def wait(self, cond, timeout=8.0):
        loop = asyncio.get_running_loop()
        end = loop.time() + timeout
        while loop.time() < end:
            if cond():
                return True
            await asyncio.sleep(0.05)
        return False


class TK103EndToEndTests(_Tcp):
    PORT = PORT_TK

    def test_tk103_pair_drive_power_cut_engine_cut(self):
        from tracker.sim import TK103Device, drive_path
        r = self.client.post("/api/v1/vehicle/trackers", {"imei": IMEI_TK, "name": "Bike",
                                                          "protocol": "tk103"},
                             format="json")
        self.assertEqual(r.status_code, 201, r.data)
        tid = r.data["tracker"]["id"]
        self.client.patch("/api/v1/vehicle/trackers/%d" % tid, {"speed_limit_kmh": 50},
                          format="json")
        state = {}

        async def run():
            srv = self.server()
            await srv.start()
            try:
                bad = TK103Device(luhn_imei("86123404000002"))
                await bad.connect("127.0.0.1", self.PORT)
                self.assertFalse(await bad.login(timeout=1.0))
                self.assertTrue(await bad.closed())
                await bad.close()

                dev = TK103Device(IMEI_TK)
                await dev.connect("127.0.0.1", self.PORT)
                self.assertTrue(await dev.login())
                now = datetime.now(dtz.utc)
                path = drive_path(23.7808, 90.4130, 20, 60.0, 5,
                                  t0=now - timedelta(seconds=160))
                for p in path:
                    await dev.fix(p["lat"], p["lng"], p["speed_kmh"], p["at"])
                last = path[-1]
                for i in range(3):
                    await dev.fix(last["lat"], last["lng"], 0,
                                  now - timedelta(seconds=40 - i * 10))
                await dev.fix(last["lat"], last["lng"], 0, now - timedelta(seconds=5),
                              keyword="ac alarm")
                await dev.heartbeat()
                self.assertTrue(await self.wait(lambda: "ON" in dev.replies))
                self.assertTrue(await self.wait(lambda: VehiclePosition.objects.filter(
                    tracker_id=tid).count() >= 24), "positions not flushed")
                self.assertTrue(await self.wait(lambda: any(
                    c.startswith("C,") for c in dev.commands)))
                r = cut_confirmed(self.client, tid)
                state["cut"] = (r.status_code, dict(r.data))
                if r.status_code == 201:
                    cid = r.data["command"]["id"]
                    state["acked"] = await self.wait(
                        lambda: VehicleCommand.objects.get(pk=cid).state == "acked")
                state["cmds"] = list(dev.commands)
                await dev.close()
            finally:
                await srv.stop()

        asyncio.run(run())
        self.assertEqual(state["cut"][0], 201, state["cut"][1])
        self.assertTrue(state.get("acked"), "TK103 engine cut never acked")
        self.assertIn("J", state["cmds"])
        t = VehicleTracker.objects.get(pk=tid)
        self.assertEqual((t.state, t.protocol, t.relay_cut), ("paired", "tk103", True))
        self.assertGreater(t.odometer_m, 1000)
        got = self.pushed_alerts()
        self.assertIn("overspeed", got)
        self.assertIn("device_alarm", got)
        self.assertEqual(got.count("device_alarm"), 1)
        self.assertTrue(NotifEvent.objects.filter(meta__alarm="power_cut").exists())
        self.assertTrue(VehicleAuditLog.objects.filter(action="unknown_imei").exists())


class GT06PowerAlarmEndToEndTests(_Tcp):
    PORT = PORT_GT06_PWR

    def test_heartbeat_power_cut_and_low_battery_push_once(self):
        from tracker.sim import GT06Device
        r = self.client.post("/api/v1/vehicle/trackers", {"imei": IMEI_A, "name": "Car"},
                             format="json")
        tid = r.data["tracker"]["id"]

        async def run():
            srv = self.server()
            await srv.start()
            try:
                dev = GT06Device(IMEI_A)
                await dev.connect("127.0.0.1", self.PORT)
                self.assertTrue(await dev.login())
                await dev.fix(23.78, 90.41, 0, False, datetime.now(dtz.utc))
                for _ in range(3):        # the alarm bits repeat in every heartbeat
                    await dev.raw(gt06.status_packet(dev._ser(), alarm="power_cut",
                                                     voltage_level=4))
                    await asyncio.sleep(0.15)
                for _ in range(2):
                    await dev.raw(gt06.status_packet(dev._ser(), voltage_level=1))
                    await asyncio.sleep(0.15)
                self.assertTrue(await self.wait(
                    lambda: dev.acks.count(gt06.P_STATUS) >= 5))
                await asyncio.sleep(0.4)
                await dev.close()
            finally:
                await srv.stop()

        asyncio.run(run())
        got = [m["message"]["data"].get("alarm") for m in self.fcm.sent_payloads()
               if m["message"]["data"].get("alert") == "device_alarm"]
        self.assertEqual(sorted(got), ["low_battery", "power_cut"])
