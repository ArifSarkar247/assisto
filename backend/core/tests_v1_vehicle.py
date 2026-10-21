"""v1-vehicle: vehicle tracking — protocol parsers (official doc vectors), pure
trip/stop/mileage + alert + cut-off logic, pricing, every access-denied case,
the ORM service, and an END-TO-END run of the real asyncio tracker server on a
spare local port (15023 — never 5023) driven by tracker/sim.py."""
import asyncio
import os
from datetime import datetime, timedelta, timezone as dtz
from unittest import mock

from django.contrib.auth.hashers import make_password
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APITestCase, APITransactionTestCase

from core.logic import vehicle_tracking as VT
from core.logic import obd_dtc
from core.logic import pricing as P
from core.models import (User, VehicleTracker, VehiclePosition, VehicleCommand,
                         VehicleAccessGrant, VehicleAuditLog, CircleMember,
                         ProtectedPhone, FamilyAlert, NotifEvent, PaCollectionItem,
                         BusinessProfile, BusinessStaff)
from tracker.protocols import gt06, teltonika

E2E_PORT = 15023
PIN = "2468"
BANNED = ("theft", "thief", "steal", "stole", "চুরি", "চোর")


def luhn_imei(prefix14):
    total = 0
    for i, ch in enumerate(prefix14):
        d = int(ch)
        if i % 2 == 1:
            d *= 2
            if d > 9:
                d -= 9
        total += d
    return prefix14 + str((10 - total % 10) % 10)


IMEI_A = luhn_imei("35933907700391")
IMEI_B = luhn_imei("35630704244101")
IMEI_C = luhn_imei("86123404000001")


def T(sec):
    return datetime(2026, 10, 20, 8, 0, 0, tzinfo=dtz.utc) + timedelta(seconds=sec)


# =========================================================================== GT06
class GT06ProtocolTests(TestCase):
    def test_login_doc_vector_and_ack(self):
        fr = bytes.fromhex("78780D01012345678901234500018CDD0D0A")
        p = gt06.parse_frame(fr)
        self.assertEqual(p["kind"], "login")
        self.assertEqual(p["imei"], "123456789012345")
        self.assertTrue(p["ack_required"])
        self.assertEqual(gt06.ack(0x01, 1), bytes.fromhex("787805010001D9DC0D0A"))

    def test_gps_doc_vector(self):
        fr = bytes.fromhex("78781F120B081D112E10CF027AC7EB0C46584900148F01CC00"
                           "287D001FB8000380810D0A")
        p = gt06.parse_frame(fr)
        f = p["fix"]
        self.assertEqual(p["kind"], "gps")
        self.assertAlmostEqual(f["lat"], 23.111668, places=5)
        self.assertAlmostEqual(f["lng"], 114.409285, places=5)
        self.assertEqual(f["course"], 143)
        self.assertTrue(f["valid"])
        self.assertEqual(f["at"], datetime(2011, 8, 29, 17, 46, 16, tzinfo=dtz.utc))

    def test_bad_crc_rejected(self):
        fr = bytearray.fromhex("78780D01012345678901234500018CDD0D0A")
        fr[-3] ^= 0xFF
        with self.assertRaises(gt06.FrameError):
            gt06.parse_frame(bytes(fr))

    def test_split_frames_partial_and_junk(self):
        a = gt06.login_packet(IMEI_A, 1)
        b = gt06.status_packet(2, ignition=True)
        frames, rest = gt06.split_frames(b"\x00junk" + a + b[:5])
        self.assertEqual(frames, [a])
        frames2, rest2 = gt06.split_frames(rest + b[5:])
        self.assertEqual(frames2, [b])
        self.assertEqual(rest2, b"")
        with self.assertRaises(gt06.FrameError):
            gt06.split_frames(b"\x78\x78\x02\x01\x00")

    def test_roundtrip_gps22_south_west_and_status(self):
        fr = gt06.gps_packet(T(0), -33.86, -70.65, 62, 270, 7, ignition=True)
        f = gt06.parse_frame(fr)["fix"]
        self.assertAlmostEqual(f["lat"], -33.86, places=4)
        self.assertAlmostEqual(f["lng"], -70.65, places=4)
        self.assertEqual(f["speed_kmh"], 62)
        self.assertTrue(f["ignition"])
        st = gt06.parse_frame(gt06.status_packet(9, ignition=True, relay_cut=True))
        self.assertEqual(st["kind"], "status")
        self.assertTrue(st["status"]["ignition"])
        self.assertTrue(st["status"]["relay_cut"])
        self.assertTrue(st["ack_required"])

    def test_command_and_reply_roundtrip(self):
        cmd = gt06.server_command("RELAY,1#", 0xABCDEF01, 5)
        flag, text, serial = gt06.parse_server_command(cmd)
        self.assertEqual((flag, text, serial), (0xABCDEF01, "RELAY,1#", 5))
        rep = gt06.parse_frame(gt06.reply_packet(flag, "Cut off the fuel supply: Success!", 6))
        self.assertEqual(rep["kind"], "cmd_reply")
        self.assertEqual(rep["server_flag"], 0xABCDEF01)
        self.assertTrue(gt06.reply_ok(rep["text"]))
        self.assertFalse(gt06.reply_ok("Command error"))
        self.assertIsNone(gt06.reply_ok("hmm"))

    def test_interval_command_bounded(self):
        self.assertEqual(gt06.interval_command(1, 2), "TIMER,5,10#")
        self.assertEqual(gt06.interval_command(5, 180), "TIMER,5,180#")


# =========================================================================== Teltonika
class TeltonikaProtocolTests(TestCase):
    DOC8 = ("000000000000003608010000016B40D8EA30010000000000000000000000000000000105"
            "021503010101425E0F01F10000601A014E0000000000000000010000C7CF")

    def test_codec8_doc_vector(self):
        p = teltonika.parse_packet(bytes.fromhex(self.DOC8))
        self.assertEqual((p["codec"], p["count"]), (8, 1))
        r = p["records"][0]
        self.assertEqual(r["io"][66], 0x5E0F)
        self.assertEqual(r["io"][0xF1], 0x601A)
        self.assertFalse(r["valid"])            # 0 sats / 0,0
        self.assertEqual(r["ext_voltage_v"], 24.08)
        self.assertEqual(teltonika.ack(1), b"\x00\x00\x00\x01")

    def test_codec12_doc_vector(self):
        pkt = bytes.fromhex("000000000000000F0C010500000007676574696E666F0100004312")
        self.assertEqual(teltonika.codec12_command("getinfo"), pkt)
        self.assertEqual(teltonika.parse_packet(pkt)["text"], "getinfo")
        resp = teltonika.parse_packet(teltonika.codec12_response("DOUT1:1 DOUT2:0"))
        self.assertEqual(resp["kind"], "cmd_reply")
        self.assertTrue(teltonika.reply_ok(resp["text"]))

    def test_imei_handshake(self):
        imei, rest = teltonika.split_imei(bytes.fromhex("000F333536333037303432343431303133"))
        self.assertEqual((imei, rest), ("356307042441013", b""))
        self.assertEqual(teltonika.split_imei(b"\x00\x0f3563"), (None, b"\x00\x0f3563"))
        with self.assertRaises(teltonika.FrameError):
            teltonika.split_imei(b"\x00\x0fABCDEFGHIJKLMNO")

    def test_codec8e_roundtrip_with_obd_and_dtc(self):
        rec = {"at": T(0), "lat": 23.7808, "lng": 90.4130, "speed_kmh": 37, "course": 45,
               "io": {239: 1, 240: 1, 66: 12650, 32: 92, 36: 2100, 48: 61,
                      281: b"P0301,P0420"}}
        pkt = teltonika.build_avl([rec, dict(rec, at=T(5))], teltonika.CODEC_8E)
        p = teltonika.parse_packet(pkt)
        self.assertEqual((p["codec"], p["count"]), (0x8E, 2))
        r = p["records"][0]
        self.assertAlmostEqual(r["lat"], 23.7808, places=5)
        self.assertTrue(r["ignition"])
        self.assertEqual(r["ext_voltage_v"], 12.65)
        self.assertEqual(r["obd"]["coolant_temp_c"], 92)
        self.assertEqual(r["obd"]["rpm"], 2100)
        self.assertEqual(r["obd"]["fuel_level_pct"], 61)
        self.assertEqual(r["obd"]["dtc"], ["P0301", "P0420"])

    def test_codec8_roundtrip_and_bad_crc(self):
        pkt = bytearray(teltonika.build_avl(
            [{"at": T(0), "lat": 1.5, "lng": 2.5, "speed_kmh": 10, "io": {239: 0}}],
            teltonika.CODEC_8))
        self.assertEqual(teltonika.parse_packet(bytes(pkt))["records"][0]["ignition"], False)
        pkt[-1] ^= 0x55
        with self.assertRaises(teltonika.FrameError):
            teltonika.parse_packet(bytes(pkt))

    def test_split_packet(self):
        pkt = bytes.fromhex(self.DOC8)
        self.assertEqual(teltonika.split_packet(pkt[:20]), (None, pkt[:20]))
        self.assertEqual(teltonika.split_packet(pkt + b"\x00"), (pkt, b"\x00"))
        with self.assertRaises(teltonika.FrameError):
            teltonika.split_packet(b"\x01\x00\x00\x00\x00\x00\x00\x10")


# =========================================================================== pure logic
def drive(n, speed, t0=0, lat=23.78, lng=90.41, step=5):
    out = []
    for i in range(n):
        out.append({"at": T(t0 + i * step), "lat": lat, "lng": lng,
                    "speed_kmh": speed, "valid": True})
        lng += (speed / 3.6 * step) / 102000.0 if speed else 0
    return out, lat, lng


class TripLogicTests(TestCase):
    def test_trip_stop_trip_mileage(self):
        a, lat, lng = drive(60, 36)                  # 5 min @36 km/h = 3 km
        p1, _, _ = drive(60, 0, t0=300, lat=lat, lng=lng)   # 5 min parked
        b, _, _ = drive(60, 36, t0=600, lat=lat, lng=lng)
        s = VT.compute_trips(a + p1 + b)
        self.assertEqual(len(s["trips"]), 2)
        self.assertAlmostEqual(s["total_km"], 6.0, delta=0.4)
        self.assertGreaterEqual(len(s["stops"]), 1)
        self.assertEqual(s["max_speed_kmh"], 36)

    def test_gps_jump_dropped_and_gap_splits(self):
        a, lat, lng = drive(20, 40)
        jump = [{"at": T(101), "lat": 30.0, "lng": 100.0, "speed_kmh": 40, "valid": True}]
        b, _, _ = drive(20, 40, t0=2000, lat=lat, lng=lng)   # 30 min gap
        s = VT.compute_trips(a + jump + b)
        self.assertEqual(len(s["trips"]), 2)
        self.assertAlmostEqual(s["total_km"], 2.1, delta=0.2)   # jump ignored

    def test_invalid_and_zero_fixes_ignored(self):
        s = VT.compute_trips([{"at": T(0), "lat": 0, "lng": 0, "speed_kmh": 50},
                              {"at": T(5), "lat": 1, "lng": 1, "speed_kmh": 50,
                               "valid": False}])
        self.assertEqual((s["trips"], s["total_km"], s["points"]), ([], 0, 0))

    def test_night_flag(self):
        a, _, _ = drive(30, 30)
        for f in a:
            f["local_hour"] = 2
        self.assertTrue(VT.compute_trips(a, night=(23, 5))["trips"][0]["night"])

    def test_decide_cutoff(self):
        now = T(1000)
        self.assertEqual(VT.decide_cutoff(T(990), 0, now), (True, "ok"))
        self.assertEqual(VT.decide_cutoff(T(990), 4.9, now), (True, "ok"))
        self.assertEqual(VT.decide_cutoff(T(990), 5, now), (False, "moving"))
        self.assertEqual(VT.decide_cutoff(T(700), 0, now), (False, "stale_fix"))
        self.assertEqual(VT.decide_cutoff(None, 0, now), (False, "no_fix"))
        self.assertEqual(VT.decide_cutoff(T(990), 0, now, online=False), (False, "offline"))
        self.assertEqual(VT.decide_cutoff(None, 80, now, kind="engine_restore"),
                         (True, "ok"))

    def test_geofence_enter_exit_first_observation_silent(self):
        cfg = {"geofences": [{"id": "h", "name": "Home", "lat": 23.78, "lng": 90.41,
                              "radius_m": 200}]}
        st, al = VT.evaluate_alerts({}, {"lat": 23.78, "lng": 90.41, "speed_kmh": 0}, cfg, 12)
        self.assertEqual(al, [])
        st, al = VT.evaluate_alerts(st, {"lat": 23.80, "lng": 90.41, "speed_kmh": 30}, cfg, 12)
        self.assertEqual([a["kind"] for a in al], ["geofence_exit"])
        st, al = VT.evaluate_alerts(st, {"lat": 23.7801, "lng": 90.41}, cfg, 12)
        self.assertEqual([a["kind"] for a in al], ["geofence_enter"])

    def test_overspeed_debounce_and_hysteresis(self):
        cfg = {"speed_limit_kmh": 60}
        f = lambda s: {"lat": 23.7, "lng": 90.4, "speed_kmh": s}  # noqa: E731
        st, al = VT.evaluate_alerts({}, f(80), cfg, 12)
        self.assertEqual(al, [])                      # single spike
        st, al = VT.evaluate_alerts(st, f(82), cfg, 12)
        self.assertEqual([a["kind"] for a in al], ["overspeed"])
        st, al = VT.evaluate_alerts(st, f(85), cfg, 12)
        self.assertEqual(al, [])                      # once
        st, _ = VT.evaluate_alerts(st, f(55), cfg, 12)  # not re-armed (55 > 50)
        st, _ = VT.evaluate_alerts(st, f(80), cfg, 12)
        st, al = VT.evaluate_alerts(st, f(80), cfg, 12)
        self.assertEqual(al, [])
        st, _ = VT.evaluate_alerts(st, f(30), cfg, 12)  # re-armed
        st, _ = VT.evaluate_alerts(st, f(80), cfg, 12)
        st, al = VT.evaluate_alerts(st, f(80), cfg, 12)
        self.assertEqual([a["kind"] for a in al], ["overspeed"])

    def test_night_ignition_edge_only(self):
        cfg = {"night_start": "23:00", "night_end": "05:00", "night_ignition": True}
        st, al = VT.evaluate_alerts({}, {"ignition": False}, cfg, 2)
        st, al = VT.evaluate_alerts(st, {"ignition": True}, cfg, 2)
        self.assertEqual([a["kind"] for a in al], ["night_ignition"])
        st, al = VT.evaluate_alerts(st, {"ignition": True}, cfg, 2)
        self.assertEqual(al, [])
        st, _ = VT.evaluate_alerts(st, {"ignition": False}, cfg, 14)
        st, al = VT.evaluate_alerts(st, {"ignition": True}, cfg, 14)   # daytime
        self.assertEqual(al, [])
        self.assertTrue(VT.in_window(23, 23, 5) and VT.in_window(0, 23, 5))
        self.assertFalse(VT.in_window(5, 23, 5))

    def test_texts_never_accuse(self):
        for lang in ("bn", "en"):
            for k in ("geofence_enter", "geofence_exit", "overspeed", "night_ignition",
                      "device_alarm"):
                t, b = VT.alert_text({"kind": k, "speed_kmh": 90, "limit_kmh": 60,
                                      "alarm": "power_cut"}, "Car", lang)
                for w in BANNED:
                    self.assertNotIn(w, (t + b).lower())
            a, _, _ = drive(40, 30)
            s = VT.compute_trips(a, night=(0, 24))
            txt = VT.rule_summary(s, VT.unusual_trip_facts(s, 20), lang)
            for w in BANNED:
                self.assertNotIn(w, txt.lower())

    def test_downsample(self):
        pts = list(range(1000))
        d = VT.downsample(pts, 100)
        self.assertEqual((len(d), d[0], d[-1]), (100, 0, 999))
        self.assertEqual(VT.downsample(pts[:5], 100), pts[:5])

    def test_dtc_table(self):
        e = obd_dtc.explain("p0301")
        self.assertTrue(e["known"])
        self.assertEqual(e["severity"], "high")
        self.assertIn("মিসফায়ার", e["bn"])
        u = obd_dtc.explain("P0399")
        self.assertFalse(u["known"])
        self.assertIn("ignition", u["en"])
        self.assertIsNone(obd_dtc.explain("hello"))
        self.assertEqual(len(obd_dtc.explain_all(["P0420", "P0420", "x", "U0100"])), 2)


class VehiclePricingTests(TestCase):
    def test_action_passes_margin_and_is_editable(self):
        cfg = P.DEFAULTS()
        floor = P.action_credit_floor("vehicle_tracking_month", cfg)
        self.assertGreater(floor, 0)
        self.assertGreaterEqual(P.credit_cost("vehicle_tracking_month", cfg), floor)
        self.assertEqual(P.validate_edit(cfg), [])
        cfg["action_costs"]["vehicle_tracking_month"]["credits"] = floor - 1
        self.assertIn("action_breaks_margin", P.validate_edit(cfg))

    def test_vehicle_knobs_bounded(self):
        v = P.vehicle_cfg({"vehicle": {"cutoff_max_speed_kmh": 999,
                                       "moving_interval_s": 1, "retention_days": "x"}})
        self.assertEqual(v["cutoff_max_speed_kmh"], 10)
        self.assertEqual(v["moving_interval_s"], 5)
        self.assertEqual(v["retention_days"], 30)
        self.assertIn("limit_negative",
                      P.validate_edit({"vehicle": {"retention_days": -1}}))


# =========================================================================== API
class _Setup:
    def setUp(self):
        mk = User.objects.create_user
        self.owner = mk(name="Owner", phone="01710002001", password="pw")
        self.owner.ai_credits = 500
        self.owner.save()
        self.fam = mk(name="Fam", phone="01710002002", password="pw")
        self.other = mk(name="Stranger", phone="01710002003", password="pw")
        self.staff = mk(name="Driver", phone="01710002004", password="pw")
        for u in (self.owner, self.fam, self.other, self.staff):
            ProtectedPhone.objects.create(owner=u, security_pin_hash=make_password(PIN))
        self.member = CircleMember.objects.create(user=self.owner, name="Fam",
                                                  state="accepted", peer_user=self.fam)
        now = timezone.now()
        self.t = VehicleTracker.objects.create(
            owner=self.owner, imei=IMEI_A, name="Corolla", state="paired",
            protocol="gt06", paired_at=now, billed_until=now + timedelta(days=30),
            last_seen_at=now, last_fix_at=now - timedelta(seconds=10),
            last_lat=23.78, last_lng=90.41, last_speed_kmh=0)
        self.client.force_authenticate(self.owner)

    def as_(self, u):
        self.client.force_authenticate(u)

    def u(self, path=""):
        return "/api/v1/vehicle/trackers/%d%s" % (self.t.id, path)

    def cut(self, pin=PIN, kind="engine_cut"):
        return self.client.post(self.u("/commands"), {"kind": kind, "pin": pin},
                                format="json")


class _Base(_Setup, APITestCase):
    pass


class AccessDeniedTests(_Base):
    def test_stranger_sees_nothing(self):
        self.as_(self.other)
        for path in ("", "/route", "/trips", "/commands", "/obd", "/audit", "/grants"):
            self.assertEqual(self.client.get(self.u(path)).status_code, 404, path)
        self.assertEqual(self.cut().status_code, 404)
        self.assertEqual(self.client.post(self.u("/ai-summary")).status_code, 404)
        self.assertEqual(self.client.patch(self.u(), {"name": "x"}, format="json")
                         .status_code, 404)
        self.assertEqual(self.client.delete(self.u()).status_code, 404)
        self.assertEqual(self.client.get("/api/v1/vehicle/trackers").data["trackers"], [])
        self.assertEqual(VehicleCommand.objects.count(), 0)

    def test_family_view_only_cannot_command_or_manage(self):
        VehicleAccessGrant.objects.create(tracker=self.t, grantee=self.fam, kind="family")
        self.as_(self.fam)
        r = self.client.get(self.u())
        self.assertEqual(r.status_code, 200)
        self.assertNotIn("imei", r.data)                # full IMEI is owner-only
        self.assertEqual(self.client.get(self.u("/route")).status_code, 200)
        self.assertEqual(self.cut().status_code, 403)
        self.assertEqual(self.client.patch(self.u(), {"name": "x"}, format="json")
                         .status_code, 403)
        self.assertEqual(self.client.delete(self.u()).status_code, 403)
        self.assertEqual(self.client.get(self.u("/audit")).status_code, 403)
        self.assertEqual(self.client.get(self.u("/grants")).status_code, 403)
        self.assertEqual(len(self.client.get("/api/v1/vehicle/trackers")
                             .data["trackers"]), 1)

    def test_family_grant_dies_with_circle_edge(self):
        VehicleAccessGrant.objects.create(tracker=self.t, grantee=self.fam, kind="family",
                                          can_command=True)
        self.as_(self.fam)
        self.assertEqual(self.client.get(self.u()).status_code, 200)
        self.member.blocked = True
        self.member.save()
        self.assertEqual(self.client.get(self.u()).status_code, 404)
        self.assertEqual(self.cut().status_code, 404)
        self.member.blocked, self.member.state = False, "declined"
        self.member.save()
        self.assertEqual(self.client.get(self.u("/route")).status_code, 404)

    def test_family_commander_uses_own_pin(self):
        VehicleAccessGrant.objects.create(tracker=self.t, grantee=self.fam, kind="family",
                                          can_command=True)
        self.as_(self.fam)
        self.assertEqual(self.cut(pin="0000").status_code, 403)
        r = self.cut()
        self.assertEqual(r.status_code, 201, r.data)
        self.assertEqual(r.data["command"]["state"], "queued")

    def test_grant_rules(self):
        r = self.client.post(self.u("/grants"), {"kind": "family", "member_id": 999},
                             format="json")
        self.assertEqual(r.status_code, 400)
        pend = CircleMember.objects.create(user=self.owner, name="P", state="pending",
                                           peer_user=self.other)
        r = self.client.post(self.u("/grants"), {"kind": "family", "member_id": pend.id},
                             format="json")
        self.assertEqual(r.status_code, 400)
        # someone else's circle member can't be used
        foreign = CircleMember.objects.create(user=self.other, name="F",
                                              state="accepted", peer_user=self.fam)
        r = self.client.post(self.u("/grants"), {"kind": "family",
                                                 "member_id": foreign.id}, format="json")
        self.assertEqual(r.status_code, 400)
        r = self.client.post(self.u("/grants"), {"kind": "family",
                                                 "member_id": self.member.id}, format="json")
        self.assertEqual(r.status_code, 201)
        # grantee cannot grant onward
        self.as_(self.fam)
        r = self.client.post(self.u("/grants"), {"kind": "family",
                                                 "member_id": self.member.id}, format="json")
        self.assertEqual(r.status_code, 403)

    def test_fleet_grant_needs_business_and_active_staff(self):
        biz = BusinessProfile.objects.create(user=self.owner, shop_name="Fleet Co")
        st = BusinessStaff.objects.create(business=biz, member=self.staff)
        r = self.client.post(self.u("/grants"), {"kind": "fleet", "staff_id": st.id},
                             format="json")
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.data["reason"], "business_only")
        self.owner.plan = "business"
        self.owner.plan_until = timezone.now() + timedelta(days=30)
        self.owner.save()
        r = self.client.post(self.u("/grants"), {"kind": "fleet", "staff_id": st.id,
                                                 "can_command": True}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        self.as_(self.staff)
        self.assertEqual(self.client.get(self.u()).status_code, 200)
        st.active = False
        st.save()
        self.assertEqual(self.client.get(self.u()).status_code, 404)

    def test_fleet_dashboard_business_only(self):
        self.assertEqual(self.client.get("/api/v1/vehicle/fleet").status_code, 403)
        self.owner.plan = "business"
        self.owner.plan_until = timezone.now() + timedelta(days=30)
        self.owner.save()
        r = self.client.get("/api/v1/vehicle/fleet")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["totals"]["vehicles"], 1)
        self.as_(self.other)
        self.other.plan = "business"
        self.other.plan_until = timezone.now() + timedelta(days=30)
        self.other.save()
        self.assertEqual(self.client.get("/api/v1/vehicle/fleet").data["totals"]
                         ["vehicles"], 0)

    def test_approve_and_cancel_denied_for_others(self):
        self.client.patch(self.u(), {"cutoff_requires_approval": True,
                                     "approver_member_id": self.member.id}, format="json")
        r = self.cut()
        self.assertEqual(r.data["command"]["state"], "awaiting_approval")
        cid = r.data["command"]["id"]
        self.as_(self.other)
        self.assertEqual(self.client.post("/api/v1/vehicle/commands/%d/approve" % cid,
                                          {"pin": PIN}, format="json").status_code, 404)
        self.assertEqual(self.client.post("/api/v1/vehicle/commands/%d/cancel" % cid)
                         .status_code, 404)
        self.as_(self.owner)        # requester can't self-approve
        self.assertEqual(self.client.post("/api/v1/vehicle/commands/%d/approve" % cid,
                                          {"pin": PIN}, format="json").status_code, 404)


class CommandGateTests(_Base):
    def test_pin_required(self):
        ProtectedPhone.objects.filter(owner=self.owner).update(security_pin_hash="")
        r = self.cut()
        self.assertEqual((r.status_code, r.data["reason"]), (403, "no_pin"))
        ProtectedPhone.objects.filter(owner=self.owner).update(
            security_pin_hash=make_password(PIN))
        r = self.cut(pin="1111")
        self.assertEqual((r.status_code, r.data["reason"]), (403, "bad_pin"))
        self.assertTrue(VehicleAuditLog.objects.filter(action="command_denied").exists())

    def test_moving_stale_offline_unpaired_refused(self):
        self.t.last_speed_kmh = 22
        self.t.save()
        r = self.cut()
        self.assertEqual((r.status_code, r.data["reason"]), (409, "moving"))
        self.t.last_speed_kmh = 0
        self.t.last_fix_at = timezone.now() - timedelta(minutes=10)
        self.t.save()
        self.assertEqual(self.cut().data["reason"], "stale_fix")
        self.t.last_fix_at = timezone.now()
        self.t.last_seen_at = timezone.now() - timedelta(hours=2)
        self.t.save()
        self.assertEqual(self.cut().data["reason"], "offline")
        self.t.state = "pending"
        self.t.save()
        self.assertEqual(self.cut().data["reason"], "not_paired")
        self.assertEqual(VehicleCommand.objects.count(), 0)
        self.assertGreaterEqual(VehicleAuditLog.objects.filter(
            action="command_denied").count(), 3)

    def test_restore_allowed_while_moving_and_busy_guard(self):
        self.t.last_speed_kmh = 60
        self.t.save()
        r = self.cut(kind="engine_restore")
        self.assertEqual(r.status_code, 201)
        r = self.cut(kind="engine_restore")
        self.assertEqual((r.status_code, r.data["reason"]), (409, "busy"))
        self.assertEqual(self.client.post(self.u("/commands"), {"kind": "self_destruct",
                                                                "pin": PIN},
                                          format="json").status_code, 400)

    def test_approval_flow(self):
        r = self.client.patch(self.u(), {"cutoff_requires_approval": True}, format="json")
        self.assertEqual(r.data["reason"], "approver_required")
        self.client.patch(self.u(), {"cutoff_requires_approval": True,
                                     "approver_member_id": self.member.id}, format="json")
        cid = self.cut().data["command"]["id"]
        self.assertTrue(NotifEvent.objects.filter(user=self.fam).exists())
        self.as_(self.fam)
        self.assertEqual(self.client.post("/api/v1/vehicle/commands/%d/approve" % cid,
                                          {"pin": "9"}, format="json").status_code, 403)
        r = self.client.post("/api/v1/vehicle/commands/%d/approve" % cid, {"pin": PIN},
                             format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(VehicleCommand.objects.get(pk=cid).state, "queued")
        self.assertEqual(VehicleCommand.objects.get(pk=cid).approved_by, self.fam)
        # cancel a queued one (owner)
        self.as_(self.owner)
        r = self.client.post("/api/v1/vehicle/commands/%d/cancel" % cid)
        self.assertEqual(r.data["command"]["state"], "cancelled")

    def test_approval_rechecks_speed(self):
        self.client.patch(self.u(), {"cutoff_requires_approval": True,
                                     "approver_member_id": self.member.id}, format="json")
        cid = self.cut().data["command"]["id"]
        VehicleTracker.objects.filter(pk=self.t.pk).update(last_speed_kmh=40)
        self.as_(self.fam)
        r = self.client.post("/api/v1/vehicle/commands/%d/approve" % cid, {"pin": PIN},
                             format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (409, "moving"))


class PairingAndFeatureTests(_Base):
    def test_pairing_rules(self):
        url = "/api/v1/vehicle/trackers"
        self.assertEqual(self.client.post(url, {"imei": "12345"}, format="json")
                         .data["reason"], "bad_imei")
        self.assertEqual(self.client.post(url, {"imei": IMEI_A[:-1] + str(
            (int(IMEI_A[-1]) + 1) % 10)}, format="json").data["reason"], "bad_imei")
        self.as_(self.other)
        r = self.client.post(url, {"imei": IMEI_A}, format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (409, "imei_taken"))
        r = self.client.post(url, {"imei": IMEI_B}, format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (402, "no_credits"))
        self.other.ai_credits = 100
        self.other.save()
        rec = PaCollectionItem.objects.create(user=self.owner, collection="vehicle/records",
                                              data={"name": "Owner car"})
        r = self.client.post(url, {"imei": IMEI_B, "vehicle_record_id": rec.id},
                             format="json")
        self.assertEqual(r.data["reason"], "bad_vehicle")      # not their record
        r = self.client.post(url, {"imei": IMEI_B, "name": "Bike"}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        self.assertEqual(r.data["tracker"]["state"], "pending")
        self.assertIn("SERVER,1,", r.data["server"]["setup_sms"]["gt06"])
        self.assertEqual(r.data["server"]["port"], 5023)

    def test_patch_validation(self):
        for body in ({"speed_limit_kmh": 500}, {"night_start": "25:00"},
                     {"moving_interval_s": 1}, {"geofences": [{"lat": 99, "lng": 1}]},
                     {"approver_member_id": 12345}):
            self.assertEqual(self.client.patch(self.u(), body, format="json").status_code,
                             400, body)
        r = self.client.patch(self.u(), {"moving_interval_s": 10, "geofences": [
            {"name": "Home", "lat": 23.78, "lng": 90.41, "radius_m": 300}]}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(VehicleCommand.objects.filter(kind="set_interval",
                                                      state="queued").exists())

    def test_obd_decode_carmode_and_ai_without_key(self):
        r = self.client.post("/api/v1/vehicle/obd/decode", {"codes": ["P0171", "zz"]},
                             format="json")
        self.assertEqual([d["code"] for d in r.data["dtc"]], ["P0171"])
        now = timezone.now()
        pts = [{"at": (now - timedelta(seconds=300 - i * 5)).isoformat(),
                "lat": 23.78, "lng": 90.41 + i * 0.0005, "speed_kmh": 40}
               for i in range(60)]
        r = self.client.post("/api/v1/vehicle/carmode/trip", {"points": pts}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        self.assertGreater(r.data["total_km"], 2)
        self.assertTrue(PaCollectionItem.objects.filter(collection="vehicle/trips").exists())
        # positions for an unusual (night) trip, AI unavailable -> honest rule text
        rows = [VehiclePosition(tracker=self.t, at=now - timedelta(seconds=600 - i * 5),
                                lat=23.78, lng=90.41 + i * 0.0006, speed_kmh=45)
                for i in range(100)]
        VehiclePosition.objects.bulk_create(rows)
        self.client.patch(self.u(), {"night_start": "00:00", "night_end": "23:59"},
                          format="json")
        with mock.patch("core.ai._providers", return_value=[]):
            r = self.client.post(self.u("/ai-summary"), {"lang": "en"}, format="json")
        self.assertFalse(r.data["ai"])
        self.assertEqual(r.data["reason"], "no_key")
        self.assertIn("Please check", r.data["text"])
        r = self.client.get(self.u("/route"))
        self.assertGreaterEqual(len(r.data["trips"]), 1)
        self.assertGreater(len(r.data["points"]), 10)


# =========================================================================== service
class ServiceTests(_Base):
    def test_unknown_imei_refused_and_logged_once(self):
        from core import vehicle_service as VS
        VS._unknown_logged.clear()
        self.assertEqual(VS.on_device_connect(IMEI_C, "gt06"), (None, "unknown"))
        self.assertEqual(VS.on_device_connect(IMEI_C, "gt06"), (None, "unknown"))
        self.assertEqual(VehicleAuditLog.objects.filter(action="unknown_imei",
                                                        imei=IMEI_C).count(), 1)

    def test_pair_window_and_billing(self):
        from core import vehicle_service as VS
        now = timezone.now()
        t = VehicleTracker.objects.create(owner=self.owner, imei=IMEI_B, state="pending",
                                          pair_expires_at=now - timedelta(minutes=1))
        self.assertEqual(VS.on_device_connect(IMEI_B, "teltonika"), (None, "expired"))
        t.refresh_from_db()
        self.assertEqual(t.state, "expired")
        t.state, t.pair_expires_at = "pending", now + timedelta(minutes=5)
        t.save()
        bal = User.objects.get(pk=self.owner.pk).ai_credits
        tid, reason = VS.on_device_connect(IMEI_B, "teltonika")
        self.assertEqual((tid, reason), (t.id, "newly_paired"))
        t.refresh_from_db()
        self.assertEqual((t.state, t.protocol), ("paired", "teltonika"))
        self.assertEqual(User.objects.get(pk=self.owner.pk).ai_credits,
                         bal - VS.month_credits())
        self.assertTrue(VehicleCommand.objects.filter(tracker=t, kind="set_interval").exists())

    def test_pair_without_credits_disables(self):
        from core import vehicle_service as VS
        User.objects.filter(pk=self.owner.pk).update(ai_credits=0)
        VehicleTracker.objects.create(owner=self.owner, imei=IMEI_B, state="pending",
                                      pair_expires_at=timezone.now() + timedelta(minutes=5))
        self.assertEqual(VS.on_device_connect(IMEI_B, "gt06"), (None, "disabled"))
        self.assertEqual(VehicleTracker.objects.get(imei=IMEI_B).disabled_reason,
                         "no_credits")

    def test_ingest_alerts_only_owner_and_grantees(self):
        from core import vehicle_service as VS
        outsider = User.objects.create_user(name="Cousin", phone="01710002009",
                                            password="pw")
        CircleMember.objects.create(user=self.owner, name="C", state="accepted",
                                    peer_user=outsider)        # in circle, NOT granted
        VehicleAccessGrant.objects.create(tracker=self.t, grantee=self.fam)
        self.t.geofences = [{"id": "h", "name": "Home", "lat": 23.78, "lng": 90.41,
                             "radius_m": 200}]
        self.t.save()
        now = timezone.now()
        fixes = [{"at": now - timedelta(seconds=10), "lat": 23.78, "lng": 90.41,
                  "speed_kmh": 0, "valid": True},
                 {"at": now, "lat": 23.80, "lng": 90.41, "speed_kmh": 30, "valid": True,
                  "ignition": True, "obd": {"coolant_temp_c": 90}}]
        n = VS.ingest({self.t.id: {"fixes": fixes, "status": {"relay_cut": False}}})
        self.assertEqual(n, 2)
        self.t.refresh_from_db()
        self.assertAlmostEqual(self.t.last_lat, 23.80)
        self.assertTrue(self.t.ignition)
        self.assertEqual(self.t.obd["coolant_temp_c"], 90)
        self.assertTrue(FamilyAlert.objects.filter(user=self.owner, kind="vehicle").exists())
        self.assertTrue(NotifEvent.objects.filter(user=self.fam,
                                                  meta__alert="geofence_exit").exists())
        self.assertFalse(NotifEvent.objects.filter(user=outsider).exists())

    def test_reply_and_timeout_lifecycle(self):
        from core import vehicle_service as VS
        c = VehicleCommand.objects.create(tracker=self.t, kind="engine_cut", state="queued")
        VS.mark_sent(c.id, "RELAY,1#", 77)
        self.assertIsNone(VS.mark_reply(self.t.id, "ok", True, server_flag=78))
        self.assertEqual(VS.mark_reply(self.t.id, "Success!", True, server_flag=77), c.id)
        c.refresh_from_db()
        self.t.refresh_from_db()
        self.assertEqual(c.state, "acked")
        self.assertTrue(self.t.relay_cut)
        c2 = VehicleCommand.objects.create(tracker=self.t, kind="engine_restore",
                                           state="queued")
        VS.mark_sent(c2.id, "RELAY,0#", 1)
        VehicleCommand.objects.filter(pk=c2.id).update(
            sent_at=timezone.now() - timedelta(minutes=10))
        VS.expire_commands()
        c2.refresh_from_db()
        self.assertEqual((c2.state, c2.fail_reason), ("failed", "no_reply"))
        c3 = VehicleCommand.objects.create(tracker=self.t, kind="engine_cut", state="queued")
        VS.mark_sent(c3.id, "RELAY,1#", 5)
        VS.mark_reply(self.t.id, "maybe", None, server_flag=5)
        c3.refresh_from_db()
        self.assertEqual((c3.state, c3.fail_reason), ("failed", "unclear_reply"))

    def test_prune_and_billing_command(self):
        from core import vehicle_service as VS
        from core.management.commands.vehicle_tracking_billing import run_billing
        now = timezone.now()
        VehiclePosition.objects.create(tracker=self.t, at=now - timedelta(days=40),
                                       lat=1, lng=1)
        VehiclePosition.objects.create(tracker=self.t, at=now, lat=1, lng=1)
        self.assertEqual(VS.prune(now), 1)
        self.t.billed_until = now - timedelta(minutes=1)
        self.t.save()
        res = run_billing(now)
        self.assertEqual(res["renewed"], 1)
        User.objects.filter(pk=self.owner.pk).update(ai_credits=0)
        self.t.refresh_from_db()
        self.t.billed_until = now - timedelta(minutes=1)
        self.t.save()
        res = run_billing(now)
        self.assertEqual(res["disabled"], 1)
        self.t.refresh_from_db()
        self.assertEqual((self.t.state, self.t.disabled_reason), ("disabled", "no_credits"))
        self.assertEqual(VS.on_device_connect(IMEI_A, "gt06"), (None, "disabled"))


# =========================================================================== E2E
class TrackerEndToEndTests(_Setup, APITransactionTestCase):
    """Starts the REAL asyncio tracker server on 127.0.0.1:15023 (Store inline
    so the in-memory test DB is shared), drives it with tracker/sim.py over real
    TCP: pair -> stream fixes -> engine-cut via the HTTP API -> device ACK ->
    DB state checked. TransactionTestCase: the server's asyncio tasks get their
    own (context-local) DB connection, so no test-wide transaction may hold
    the shared in-memory SQLite tables."""

    def setUp(self):
        super().setUp()
        self._env = os.environ.get("DJANGO_ALLOW_ASYNC_UNSAFE")
        os.environ["DJANGO_ALLOW_ASYNC_UNSAFE"] = "true"
        from core import vehicle_service as VS
        VS._unknown_logged.clear()
        self.t.delete()

    def tearDown(self):
        if self._env is None:
            os.environ.pop("DJANGO_ALLOW_ASYNC_UNSAFE", None)
        else:
            os.environ["DJANGO_ALLOW_ASYNC_UNSAFE"] = self._env

    def _server(self):
        from core import vehicle_service as VS
        from tracker.server import TrackerServer, Store
        return TrackerServer("127.0.0.1", E2E_PORT, store=Store(inline=True),
                             cfg=VS.vcfg(), flush_s=0.1, cmd_poll_s=0.1)

    async def _wait(self, cond, timeout=8.0):
        loop = asyncio.get_running_loop()
        end = loop.time() + timeout
        while loop.time() < end:
            if cond():
                return True
            await asyncio.sleep(0.05)
        return False

    def _pair(self, imei, name):
        r = self.client.post("/api/v1/vehicle/trackers", {"imei": imei, "name": name},
                             format="json")
        self.assertEqual(r.status_code, 201, r.data)
        return r.data["tracker"]["id"]

    def test_gt06_pair_stream_cut_ack(self):
        from tracker.sim import GT06Device, drive_path
        tid = self._pair(IMEI_A, "Corolla")
        credits0 = User.objects.get(pk=self.owner.pk).ai_credits

        async def scenario():
            srv = self._server()
            await srv.start()
            try:
                # an unknown IMEI is refused: no login ACK, connection closed
                bad = GT06Device(IMEI_C)
                await bad.connect("127.0.0.1", E2E_PORT)
                self.assertFalse(await bad.login(timeout=1.0))
                await bad.close()

                dev = GT06Device(IMEI_A)
                await dev.connect("127.0.0.1", E2E_PORT)
                self.assertTrue(await dev.login())
                now = datetime.now(dtz.utc)
                path = drive_path(23.7808, 90.4130, 40, 36.0, 5,
                                  t0=now - timedelta(seconds=260))
                for p in path:
                    await dev.fix(p["lat"], p["lng"], p["speed_kmh"], True, p["at"])
                last = path[-1]
                for i in range(4):       # parked, fresh fixes
                    await dev.fix(last["lat"], last["lng"], 0, False,
                                  now - timedelta(seconds=15 - i * 5))
                await dev.heartbeat(ignition=False)
                ok = await self._wait(lambda: VehiclePosition.objects.filter(
                    tracker_id=tid).count() >= 44)
                self.assertTrue(ok, "positions not flushed")
                # the set_interval queued at pairing reached the device
                self.assertTrue(await self._wait(lambda: any(
                    c.startswith("TIMER,") for c in dev.commands)))
                # engine cut through the real HTTP API (owner PIN)
                r = self.client.post("/api/v1/vehicle/trackers/%d/commands" % tid,
                                     {"kind": "engine_cut", "pin": PIN}, format="json")
                self.assertEqual(r.status_code, 201, r.data)
                cid = r.data["command"]["id"]
                self.assertTrue(await self._wait(
                    lambda: VehicleCommand.objects.get(pk=cid).state == "acked"),
                    "engine cut never acked")
                self.assertIn("RELAY,1#", dev.commands)
                await dev.close()
            finally:
                await srv.stop()

        asyncio.run(scenario())
        t = VehicleTracker.objects.get(pk=tid)
        self.assertEqual((t.state, t.protocol), ("paired", "gt06"))
        self.assertTrue(t.relay_cut)
        self.assertEqual(t.last_speed_kmh, 0)
        self.assertEqual(User.objects.get(pk=self.owner.pk).ai_credits,
                         credits0 - P.credit_cost("vehicle_tracking_month", P.DEFAULTS()))
        cmd = VehicleCommand.objects.get(tracker=t, kind="engine_cut")
        self.assertEqual(cmd.state, "acked")
        self.assertIn("Success", cmd.response)
        self.assertIsNotNone(cmd.sent_at)
        self.assertTrue(VehicleAuditLog.objects.filter(action="unknown_imei",
                                                       imei=IMEI_C).exists())
        self.assertTrue(VehicleAuditLog.objects.filter(tracker=t,
                                                       action="command_acked").exists())
        r = self.client.get("/api/v1/vehicle/trackers/%d/route" % tid)
        self.assertEqual(len(r.data["trips"]), 1)
        self.assertAlmostEqual(r.data["total_km"], 1.95, delta=0.4)

    def test_teltonika_pair_stream_obd_cut_ack(self):
        from tracker.sim import TeltonikaDevice, drive_path
        tid = self._pair(IMEI_B, "Hiace")

        async def scenario():
            srv = self._server()
            await srv.start()
            try:
                bad = TeltonikaDevice(IMEI_C)
                await bad.connect("127.0.0.1", E2E_PORT)
                self.assertFalse(await bad.handshake())
                await bad.close()

                dev = TeltonikaDevice(IMEI_B)
                await dev.connect("127.0.0.1", E2E_PORT)
                self.assertTrue(await dev.handshake())
                now = datetime.now(dtz.utc)
                path = drive_path(23.75, 90.39, 20, 50.0, 5,
                                  t0=now - timedelta(seconds=130))
                recs = [dict(p, io={teltonika.IO_IGNITION: 1, teltonika.IO_EXT_VOLTAGE:
                                    12700, 32: 88, 48: 55, 281: b"P0420"}) for p in path]
                self.assertEqual(await dev.send(recs), 20)
                stop = path[-1]
                parked = [dict(stop, at=now - timedelta(seconds=10 - i * 5), speed_kmh=0,
                               io={teltonika.IO_IGNITION: 0}) for i in range(3)]
                self.assertEqual(await dev.send(parked, teltonika.CODEC_8), 3)
                self.assertTrue(await self._wait(lambda: VehiclePosition.objects.filter(
                    tracker_id=tid).count() == 23))
                r = self.client.post("/api/v1/vehicle/trackers/%d/commands" % tid,
                                     {"kind": "engine_cut", "pin": PIN}, format="json")
                self.assertEqual(r.status_code, 201, r.data)
                cid = r.data["command"]["id"]
                self.assertTrue(await self._wait(
                    lambda: VehicleCommand.objects.get(pk=cid).state == "acked"))
                self.assertIn("setdigout 1", dev.commands)
                await dev.close()
            finally:
                await srv.stop()

        asyncio.run(scenario())
        t = VehicleTracker.objects.get(pk=tid)
        self.assertEqual((t.protocol, t.ignition, t.relay_cut), ("teltonika", False, True))
        self.assertEqual(t.ext_voltage_v, 12.7)
        self.assertEqual(t.obd["coolant_temp_c"], 88)
        r = self.client.get("/api/v1/vehicle/trackers/%d/obd" % tid)
        self.assertTrue(r.data["available"])
        self.assertEqual(r.data["dtc"][0]["code"], "P0420")
        self.assertTrue(VehicleAuditLog.objects.filter(action="unknown_imei",
                                                       imei=IMEI_C).exists())
