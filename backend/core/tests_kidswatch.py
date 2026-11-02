"""kidswatch (owner idea 2, 28 Oct): kids GPS watch + Child School Mode.

  * the "3G" (SeTracker / Wonlex) protocol: doc + Traccar-style vectors,
    index header, binary escaping, both LLLL conventions, junk / partial /
    over-long frames, status alarms, replies;
  * NO REMOTE LISTENING: every forbidden type is refused by the only command
    builder, no builder output is ever forbidden, no code in the repo builds a
    "monitor," wire / SMS text, the API refuses it, the real-TCP watch never
    sees one;
  * School Mode state machine (pure): watch day, early exit, late alerts,
    phone ask-first, "I'm OK" extension, sick day, pause, days off, Wi-Fi
    learning, battery plan;
  * service + API: pairing, refusals, flag OFF, guardians = accepted Circle
    peers only, watch SOS through the family SOS path FREE on every plan and
    in safety-only mode, encrypted voice + expiry, voice reply AMR-only,
    transcript paid-only + no fake text, phone check-in consent / stop /
    history delete, strangers get 404;
  * REAL TCP: tracker/server.py on 127.0.0.1:15041 (never 5023) driven by
    tracker/sim.WatchDevice — refused id, LK, setup commands ACKed, positions,
    SOS, voice up, voice reply down (TK), locate (CR).
"""
import asyncio
import base64
import os
import re
import shutil
import tempfile
from datetime import datetime, timedelta, timezone as dtz
from pathlib import Path
from unittest import mock
from zoneinfo import ZoneInfo

from django.core.cache import cache
from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient, APITransactionTestCase

from core import kidswatch_service as KW
from core.logic import pricing as P
from core.logic import school_mode as SM
from core.models import (CircleMember, FamilyAlert, FamilyAlertDelivery, KidsVoiceNote,
                         KidsWatch, KidsWatchCommand, KidsWatchPosition, NotifEvent,
                         SchoolEvent, SchoolPlan, User)
from tracker.protocols import watch as WP

V = "/api/v1"
DHAKA = ZoneInfo("Asia/Dhaka")
HOME = (23.7808, 90.4130)
TCP_PORT = 15041
REPO = Path(__file__).resolve().parents[2]
_MEDIA = tempfile.mkdtemp(prefix="kidsvoice-test-")


def _east(lat, lng, metres):
    import math
    return lat, lng + metres / (111320.0 * math.cos(math.radians(lat)))


SCHOOL = _east(*HOME, 2000)
CFG = {"start": "08:00", "end": "13:30", "commute_min": 40, "late_min": 15,
       "days": [6, 0, 1, 2, 3],
       "home": {"lat": HOME[0], "lng": HOME[1], "radius_m": 150, "name": "Home"},
       "school": {"lat": SCHOOL[0], "lng": SCHOOL[1], "radius_m": 150, "name": "School"}}
AMR = b"#!AMR\n" + bytes([0x3C]) + bytes(range(31)) + bytes([0x3C]) + \
    b"[]*,}\x7d\x5b\x5d" + bytes(23)          # 2 frames incl. every escaped byte


def L(day, hh, mm):
    """Local Dhaka time on 2026-11-<day> (Nov 1 2026 = Sunday, a school day)."""
    return datetime(2026, 11, day, hh, mm, tzinfo=DHAKA)


def mk(phone, name, credits=0, plan=None):
    u = User.objects.create_user(name=name, phone=phone, password="pw12345!")
    u.ai_credits = credits
    u.trial_until = None
    if plan:
        u.plan = plan
        u.plan_until = timezone.now() + timedelta(days=30)
    u.save()
    return u


def pair_circle(a, b):
    CircleMember.objects.create(user=a, peer_user=b, name=b.name, state="accepted")
    CircleMember.objects.create(user=b, peer_user=a, name=a.name, state="accepted",
                                direction="incoming")


def cl(u):
    c = APIClient()
    c.force_authenticate(u)
    return c


def flag(on=True):
    from core import feature_flags as FF
    from core.models import FeatureFlag
    FF.ensure_seeded()
    FeatureFlag.objects.filter(key="kids_watch").update(enabled_all=on, enabled_play=on)
    FF.invalidate()


class Spy:
    def __init__(self):
        self.calls = []

    def __call__(self, user, kind, tbn, ten, bbn="", ben="", data=None, **kw):
        self.calls.append({"user": user.pk, "kind": kind, "tbn": tbn, "ten": ten,
                           "bbn": bbn, "ben": ben, "data": dict(data or {}),
                           "high": bool(kw.get("high_priority"))})
        return True

    def to(self, u, kind=None):
        return [c for c in self.calls if c["user"] == u.pk and (kind is None or
                                                                c["kind"] == kind)]


# =========================================================================== protocol

class WatchProtocolTests(TestCase):
    DOC_LK = b"[SG*8800000015*000D*LK,50,100,100]"
    # Traccar-style UD frame: GPS fix, 4 cells, no Wi-Fi
    UD = (b"[SG*8800000015*0087*UD,220414,134652,A,22.571707,N,113.8613968,E,0.1,0.0,"
          b"100,7,60,90,1000,50,0000,4,1,460,0,9360,4082,131,9360,4092,148,9360,4091,"
          b"143,9360,4153,141]")

    def test_doc_link_vector(self):
        frames, rest = WP.split_frames(self.DOC_LK)
        self.assertEqual(rest, b"")
        p = WP.parse_frame(frames[0])
        self.assertEqual((p["kind"], p["maker"], p["id"], p["steps"], p["battery"]),
                         ("link", "SG", "8800000015", 50, 100))
        self.assertEqual(WP.reply_for(p), "LK")
        self.assertEqual(WP.frame("SG", "8800000015", "LK"), b"[SG*8800000015*0002*LK]")

    def test_position_vector(self):
        frames, _ = WP.split_frames(self.UD)
        p = WP.parse_frame(frames[0], tz_min=0)
        f = p["fix"]
        self.assertEqual(p["kind"], "position")
        self.assertTrue(f["valid"])
        self.assertAlmostEqual(f["lat"], 22.571707, places=5)
        self.assertAlmostEqual(f["lng"], 113.861397, places=5)
        self.assertEqual(f["at"], datetime(2014, 4, 22, 13, 46, 52, tzinfo=dtz.utc))
        self.assertEqual((f["battery"], f["steps"], f["sats"]), (90, 1000, 7))
        self.assertEqual(len(f["cells"]), 4)
        self.assertEqual(f["cells"][0], {"mcc": 460, "mnc": 0, "lac": 9360, "cid": 4082,
                                         "rssi": 131})
        self.assertEqual(f["alarms"], [])
        self.assertIsNone(WP.reply_for(p))

    def test_local_time_is_dhaka_by_default(self):
        at = datetime(2026, 11, 1, 1, 30, tzinfo=dtz.utc)        # 07:30 in Dhaka
        c = WP.position_content(at, *HOME)
        self.assertIn(",011126,073000,", c)
        p = WP.parse_frame(WP.split_frames(WP.device_frame("3G", "1234567890", c))[0][0])
        self.assertEqual(p["fix"]["at"], at)

    def test_wifi_lbs_and_invalid_gps(self):
        at = datetime(2026, 11, 1, 2, 0, tzinfo=dtz.utc)
        c = WP.position_content(at, 0, 0, valid=False, cells=[{"lac": 1, "cid": 2}],
                                wifi=[{"mac": "AA:BB:CC:DD:EE:01", "rssi": -50},
                                      {"mac": "not-a-mac", "rssi": -40}], acc_m=35)
        f = WP.parse_frame(WP.split_frames(WP.device_frame("SG", "1234567890", c))[0][0])["fix"]
        self.assertFalse(f["valid"])
        self.assertEqual(f["wifi"], [{"mac": "aa:bb:cc:dd:ee:01", "rssi": -50}])
        self.assertEqual(f["cells"][0]["cid"], 2)
        self.assertEqual(f["acc_m"], 35)

    def test_alarm_bits(self):
        self.assertEqual(WP.status_alarms(1 << 16), ["sos"])
        self.assertEqual(WP.status_alarms((1 << 17) | (1 << 20) | (1 << 21)),
                         ["low_battery", "removed", "fall"])
        self.assertEqual(WP.status_alarms(1 << 0 | 1 << 3), [])     # levels, not alarms
        self.assertEqual(WP.status_alarms(1 << 22), [])             # heart rate, not fall
        at = datetime(2026, 11, 1, 2, 0, tzinfo=dtz.utc)
        p = WP.parse_frame(WP.split_frames(WP.device_frame(
            "SG", "1234567890", WP.position_content(at, *HOME, typ="AL",
                                                    status=1 << 16)))[0][0])
        self.assertEqual((p["kind"], p["fix"]["alarms"]), ("alarm", ["sos"]))
        self.assertEqual(WP.reply_for(p), "AL")
        # an AL with no known bit is an "alarm", never guessed to be an SOS
        p = WP.parse_frame(WP.split_frames(WP.device_frame(
            "SG", "1234567890", WP.position_content(at, *HOME, typ="AL_LTE")))[0][0])
        self.assertEqual(p["fix"]["alarms"], ["alarm"])

    def test_voice_escaping_both_length_conventions(self):
        dev = WP.device_frame("3G", "1234567890", b"TK," + AMR)      # LLLL unescaped
        srv = WP.frame("3G", "1234567890", b"TK," + AMR)             # LLLL escaped
        self.assertNotIn(b"]", dev[1:-1])
        self.assertNotIn(b"[", dev[1:])
        self.assertTrue(srv.startswith(b"[SG*1234567890*"))           # 3G answered as SG
        for wire in (dev, srv):
            frames, rest = WP.split_frames(b"\r\njunk" + wire + b"\n")
            self.assertEqual(rest, b"")
            p = WP.parse_frame(frames[0])
            self.assertEqual((p["kind"], p["audio"]), ("voice", AMR))
            self.assertEqual(WP.reply_for(p), "TK,1")
        self.assertEqual(WP.unescape(WP.escape(bytes(range(256)))), bytes(range(256)))

    def test_tk_ack_is_not_a_voice_note(self):
        p = WP.parse_frame(WP.split_frames(b"[SG*1234567890*0004*TK,1]")[0][0])
        self.assertEqual((p["kind"], p["ok"]), ("other", True))
        self.assertIsNone(WP.reply_for(p))
        p = WP.parse_frame(WP.split_frames(b"[SG*1234567890*0004*TK,0]")[0][0])
        self.assertFalse(p["ok"])

    def test_index_header(self):
        fr, _ = WP.split_frames(b"[ZJ*5678901234*0001*0009*TEMP,36.5]")
        self.assertEqual(fr[0][:3], ("ZJ", "5678901234", "0001"))
        p = WP.parse_frame(fr[0])
        self.assertEqual((p["kind"], p["type"]), ("other", "TEMP"))
        self.assertEqual(WP.frame("ZJ", "5678901234", "LK", index="0007"),
                         b"[ZJ*5678901234*0001*0002*LK]")

    def test_fifteen_digit_id_partial_and_multiple(self):
        a = WP.device_frame("3G", "358839237678820", "LK")
        b = WP.device_frame("3G", "358839237678820", "TKQ")
        frames, rest = WP.split_frames(a + b + a[:9])
        self.assertEqual(len(frames), 2)
        self.assertEqual(rest, a[:9])
        self.assertEqual(WP.parse_frame(frames[1])["kind"], "voice_query")
        self.assertEqual(WP.reply_for(WP.parse_frame(frames[1])), "TKQ")

    def test_bad_frames(self):
        with self.assertRaises(WP.FrameError):
            WP.split_frames(b"[S*12*0002*LK]")
        with self.assertRaises(WP.FrameError):
            WP.split_frames(b"[SG*1234567890*FFFFFF*LK]")
        with self.assertRaises(WP.FrameError):
            WP.parse_frame(("SG", "1234567890", None, b"UD,1,2"))
        self.assertTrue(WP.looks_like_watch(self.DOC_LK))
        for other in (b"*HQ,123,V1#", b"##,imei:1234;", b"\x78\x78\x11\x01", b"[x]"):
            self.assertFalse(WP.looks_like_watch(other), other)


# =========================================================================== no remote listening

class NoRemoteListeningTests(TestCase):
    SAMPLES = {"set_interval": {"seconds": 60}, "sos_numbers": {"numbers": ["01711000001"]},
               "voice_down": {"audio": AMR}, "message": {"text": "স্কুল-মোড চালু"},
               "class_mode": {"start": "08:00", "end": "13:30"},
               "timezone": {"tz_hours": 6}}

    def test_every_forbidden_type_is_refused(self):
        self.assertIn("MONITOR", WP.FORBIDDEN)
        for t in sorted(WP.FORBIDDEN) + ["monitor", "custom", "raw", "MONITOR,01711000001"]:
            with self.assertRaises(WP.ForbiddenCommand, msg=t):
                WP.command_content(t, {"phone": "01711000001"})
            with self.assertRaises(WP.ForbiddenCommand, msg=t):
                WP.server_command("SG", "1234567890", t, {"phone": "01711000001"})

    def test_no_builder_output_is_ever_forbidden(self):
        for kind in WP.COMMAND_KINDS:
            content, typ = WP.command_content(kind, self.SAMPLES.get(kind))
            self.assertNotIn(typ, WP.FORBIDDEN, kind)
            self.assertNotIn(b"MONITOR", content.upper(), kind)
            wire, _ = WP.server_command("SG", "1234567890", kind, self.SAMPLES.get(kind))
            frames, _ = WP.split_frames(wire)
            t, _c = WP.parse_server_frame(frames[0])
            self.assertNotIn(t, WP.FORBIDDEN, kind)

    def test_defence_in_depth_even_if_the_table_were_edited(self):
        with mock.patch.object(WP, "COMMAND_KINDS", WP.COMMAND_KINDS + ("monitor_x",)):
            with self.assertRaises(WP.ForbiddenCommand):
                WP.command_content("monitor_x")       # not built: no branch emits it

    def test_service_queue_refuses(self):
        u = mk("01711300001", "Owner")
        w = KidsWatch.objects.create(owner=u, imei="8800000015", child_name="Rina",
                                     state="paired")
        for t in ("monitor", "MONITOR", "call", "custom"):
            with self.assertRaises(WP.ForbiddenCommand):
                KW.queue(w, t, {"phone": "01711000001"})
        self.assertFalse(KidsWatchCommand.objects.filter(watch=w).exists())

    def test_no_code_builds_a_listen_command(self):
        """No Python / Dart source in the repo builds a 'monitor,<phone>' wire
        or SMS text (the only mentions are the FORBIDDEN list + this test)."""
        pat = re.compile(r"(?<![\w])monitor\s*,\s*(?:%|\{|<|\+|\d|\$)|['\"]monitor\s*,"
                         r"|['\"]monitor['\"]\s*:", re.I)
        hits = []
        for root in (REPO / "backend", REPO / "app" / "lib", REPO / "tools"):
            for ext in ("*.py", "*.dart", "*.sh"):
                for f in root.rglob(ext):
                    if f.name == "tests_kidswatch.py" or "migrations" in f.parts:
                        continue
                    try:
                        txt = f.read_text(encoding="utf-8", errors="ignore")
                    except OSError:
                        continue
                    for m in pat.finditer(txt):
                        hits.append("%s: %s" % (f.relative_to(REPO), m.group(0)))
        self.assertEqual(hits, [])

    def test_sms_steps_never_listen(self):
        from core.kidswatch_views import sms_steps
        txt = " ".join(s["sms"] for s in sms_steps("track.example.com", 5023)).lower()
        self.assertIn("pw,123456,ip,track.example.com,5023#", txt)
        self.assertNotIn("monitor", txt)
        self.assertNotIn("call", txt)
        doc = (REPO / "owner_actions" / "KIDS_WATCH_BN.md")
        if doc.exists():
            for line in doc.read_text(encoding="utf-8").lower().splitlines():
                if "pw," in line:
                    self.assertNotIn("monitor", line, line)


# =========================================================================== school mode (pure)

class SchoolModeLogicTests(TestCase):
    def setUp(self):
        self.cfg = SM.validate(CFG)

    def _fix(self, day, at, lat_lng, wifi=None):
        lat, lng = lat_lng if lat_lng else (None, None)
        return SM.on_fix(self.cfg, day, at, lat, lng, wifi)

    def test_validate(self):
        for bad, why in ((dict(CFG, start="8am"), "bad_time"),
                         (dict(CFG, end="08:10"), "end_before_start"),
                         (dict(CFG, late_min=2), "late_range"),
                         (dict(CFG, days=[]), "bad_days"),
                         (dict(CFG, days=[7]), "bad_days")):
            with self.assertRaises(ValueError) as e:
                SM.validate(bad)
            self.assertEqual(str(e.exception), why)
        c = SM.validate(dict(CFG, home={"lat": 1, "lng": 2, "radius_m": 5}))
        self.assertEqual(c["home"]["radius_m"], SM.RADIUS_MIN_M)
        self.assertIsNone(SM.validate(dict(CFG, home={"lat": 0, "lng": 0}))["home"])

    def test_watch_full_school_day(self):
        d, ev = self._fix({}, L(1, 7, 0), HOME)
        self.assertEqual((d["state"], ev), ("at_home", []))
        d, ev = self._fix(d, L(1, 7, 20), _east(*HOME, 400))          # 1 fix out: wait
        self.assertEqual(ev, [])
        d, ev = self._fix(d, L(1, 7, 21), _east(*HOME, 420))
        self.assertEqual([e["kind"] for e in ev], ["left_home"])
        self.assertEqual(SM.battery_phase(self.cfg, d, L(1, 7, 22)), "commute")
        d, ev = self._fix(d, L(1, 7, 45), SCHOOL)
        self.assertEqual([e["kind"] for e in ev], ["arrived_school"])
        self.assertEqual(SM.battery_phase(self.cfg, d, L(1, 7, 46)), "at_school")
        d, ev = self._fix(d, L(1, 10, 0), SCHOOL)
        self.assertEqual(ev, [])
        d, ev = self._fix(d, L(1, 10, 30), _east(*SCHOOL, 300))
        self.assertEqual(ev, [])
        d, ev = self._fix(d, L(1, 10, 31), _east(*SCHOOL, 320))
        self.assertEqual([(e["kind"], e["notify"]) for e in ev], [("left_school_early", "alert")])
        d, ev = self._fix(d, L(1, 10, 40), SCHOOL)
        self.assertEqual([e["kind"] for e in ev], ["back_in_school"])
        d, ev = SM.on_tick(self.cfg, d, L(1, 8, 30))
        self.assertEqual(ev, [])                                       # arrived: no late
        d, ev = SM.on_tick(self.cfg, d, L(1, 13, 30))
        self.assertEqual([e["kind"] for e in ev], ["school_over"])
        self.assertEqual(d["state"], "to_home")
        self.assertEqual(SM.battery_phase(self.cfg, d, L(1, 13, 31)), "commute")
        d, ev = self._fix(d, L(1, 13, 45), _east(*HOME, 1600))
        self.assertEqual([(e["kind"], e["notify"]) for e in ev], [("left_school", "in_app")])
        d, ev = self._fix(d, L(1, 14, 10), HOME)
        self.assertEqual([e["kind"] for e in ev], ["reached_home"])
        d, ev = SM.on_tick(self.cfg, d, L(1, 14, 30))
        self.assertEqual(ev, [])
        self.assertEqual(SM.battery_phase(self.cfg, d, L(1, 23, 0)), "night")

    def test_watch_late_goes_straight_to_parents(self):
        d, _ = self._fix({}, L(1, 7, 0), HOME)
        d, ev = SM.on_tick(self.cfg, d, L(1, 8, 14))
        self.assertEqual(ev, [])
        d, ev = SM.on_tick(self.cfg, d, L(1, 8, 15))
        self.assertEqual([(e["kind"], e["notify"]) for e in ev], [("late_school", "alert")])
        d, ev = SM.on_tick(self.cfg, d, L(1, 8, 16))
        self.assertEqual(ev, [])                                       # once

    def test_phone_asks_child_first(self):
        d, ev = SM.on_tick(self.cfg, {}, L(1, 8, 15), phone=True)
        self.assertEqual([(e["kind"], e["notify"]) for e in ev], [("ask_ok", "child")])
        d, ev = SM.on_tick(self.cfg, d, L(1, 8, 19), phone=True)
        self.assertEqual(ev, [])
        d, ev = SM.on_tick(self.cfg, d, L(1, 8, 20), phone=True)
        self.assertEqual([(e["kind"], e["notify"]) for e in ev], [("late_school", "alert")])

    def test_phone_ok_extends_once(self):
        d, _ = SM.on_tick(self.cfg, {}, L(1, 8, 15), phone=True)
        d, ev = SM.on_checkin(self.cfg, d, L(1, 8, 17), "ok")
        self.assertEqual([e["kind"] for e in ev], ["child_ok"])
        d, ev = SM.on_tick(self.cfg, d, L(1, 8, 25), phone=True)
        self.assertEqual(ev, [])
        d, ev = SM.on_tick(self.cfg, d, L(1, 8, 32), phone=True)
        self.assertEqual([e["kind"] for e in ev], ["late_school"])     # no second ask

    def test_phone_checkins(self):
        d, ev = SM.on_checkin(self.cfg, {}, L(1, 7, 30), "leaving", *HOME)
        self.assertEqual([e["kind"] for e in ev], ["left_home"])
        d, ev = SM.on_checkin(self.cfg, d, L(1, 7, 58), "arrived", *SCHOOL)
        self.assertEqual((ev[0]["kind"], ev[0]["place_match"]), ("arrived_school", "inside"))
        d, ev = SM.on_tick(self.cfg, d, L(1, 8, 20), phone=True)
        self.assertEqual(ev, [])
        d, ev = SM.on_checkin(self.cfg, d, L(1, 13, 40), "leaving")
        self.assertEqual((ev[0]["kind"], ev[0]["place_match"]), ("left_school", "unknown"))
        d, ev = SM.on_checkin(self.cfg, d, L(1, 14, 20), "arrived", *_east(*HOME, 900))
        self.assertEqual((ev[0]["kind"], ev[0]["place_match"]), ("reached_home", "outside"))
        with self.assertRaises(ValueError):
            SM.on_checkin(self.cfg, d, L(1, 14, 21), "monitor")

    def test_sick_day_no_false_home_alert_and_pause(self):
        d, _ = self._fix({}, L(1, 7, 0), HOME)
        d, ev = SM.on_tick(self.cfg, d, L(1, 8, 15))
        self.assertEqual([e["kind"] for e in ev], ["late_school"])     # parents should know
        d, ev = self._fix(d, L(1, 14, 0), HOME)
        self.assertEqual(ev, [])                                       # never left: no notice
        d, ev = SM.on_tick(self.cfg, d, L(1, 14, 30))
        self.assertEqual(ev, [])                                       # no late_home
        p = SM.new_day(L(1, 6, 0))
        p["paused"] = True
        p, ev = SM.on_tick(self.cfg, p, L(1, 8, 30))
        self.assertEqual(ev, [])

    def test_day_off_and_night(self):
        fri = datetime(2026, 10, 30, 8, 30, tzinfo=DHAKA)
        self.assertEqual(SM.window(self.cfg, fri), "off")
        self.assertEqual(SM.on_tick(self.cfg, {}, fri)[1], [])
        self.assertEqual(SM.battery_phase(self.cfg, {}, fri), "night")
        self.assertEqual(SM.window(self.cfg, L(1, 5, 0)), "night")
        self.assertEqual(SM.on_fix(self.cfg, {}, L(1, 5, 0), *_east(*HOME, 5000))[1], [])

    def test_wifi_learning_counts_indoors(self):
        place = dict(self.cfg["school"])
        place["wifi"] = SM.learn_wifi(place, [{"mac": "aa:bb:cc:dd:ee:01", "rssi": -40}])
        self.assertEqual(SM.relation(place, None, None, [{"mac": "aa:bb:cc:dd:ee:01"}]), "in")
        self.assertIsNone(SM.relation(place, None, None, [{"mac": "aa:bb:cc:dd:ee:99"}]))

    def test_interval_plan(self):
        self.assertEqual([WP.interval_for(p) for p in ("commute", "at_school", "at_home",
                                                       "night")], [60, 600, 600, 3600])
        self.assertEqual(WP.command_content("set_interval", {"seconds": 5})[0], b"UPLOAD,60")


# =========================================================================== service + API

@override_settings(KIDSVOICE_ROOT=_MEDIA)
class _Base(TestCase):
    def setUp(self):
        cache.clear()
        flag(True)
        self.owner = mk("01711200001", "Abba", credits=500)
        self.mom = mk("01711200002", "Ammu")
        self.child = mk("01711200003", "Rina")
        self.x = mk("01711200004", "Stranger")
        pair_circle(self.owner, self.mom)
        pair_circle(self.owner, self.child)
        pair_circle(self.child, self.mom)
        self.spy = Spy()
        p = mock.patch("core.push.safe_push", side_effect=self.spy)
        p.start()
        self.addCleanup(p.stop)
        self.c = cl(self.owner)

    def pair_watch(self, code="8800000015", **kw):
        body = {"code": code, "child_name": "Rina", "guardian_ids": [self.mom.id,
                                                                     self.x.id]}
        body.update(kw)
        r = self.c.post(V + "/kids-watch/watches", body, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        return KidsWatch.objects.get(pk=r.data["watch"]["id"])


class PairingTests(_Base):
    def test_flag_off_hides_everything_but_child_controls(self):
        flag(False)
        self.assertEqual(self.c.get(V + "/kids-watch/watches").status_code, 403)
        self.assertEqual(self.c.post(V + "/school-mode/plans", {}, format="json")
                         .status_code, 403)
        self.assertEqual(cl(self.child).get(V + "/school-mode/mine").status_code, 200)

    def test_pair_connect_charge_and_refusals(self):
        w = self.pair_watch()
        self.assertEqual(w.state, "pending")
        self.assertEqual(w.guardian_ids, [self.mom.id])               # stranger dropped
        self.assertEqual(KW.on_watch_connect("8800000099", "SG")[1], "unknown")
        wid, reason, tz = KW.on_watch_connect("8800000015", "3G", "1.2.3.4")
        self.assertEqual((wid, reason, tz), (w.id, "newly_paired", 360))
        w.refresh_from_db()
        self.assertEqual((w.state, w.maker), ("paired", "3G"))
        self.assertTrue(KW.full_mode(w))
        self.owner.refresh_from_db()
        self.assertEqual(self.owner.ai_credits,
                         500 - P.credit_cost("kids_watch_month", P.DEFAULTS()))
        kinds = list(KidsWatchCommand.objects.filter(watch=w).values_list("kind", flat=True))
        for k in ("timezone", "steps_on", "low_battery_alarm", "set_interval"):
            self.assertIn(k, kinds)
        self.assertEqual(KW.on_watch_connect("8800000015", "3G")[1], "paired")
        # someone else cannot claim the same code
        r = cl(self.mom).post(V + "/kids-watch/watches",
                              {"code": "8800000015", "child_name": "X"}, format="json")
        self.assertEqual(r.status_code, 409)
        self.assertEqual(self.c.post(V + "/kids-watch/watches", {"code": "12",
                                                                 "child_name": "R"},
                                     format="json").status_code, 400)

    def test_expired_window_refused_and_15_digit_alias(self):
        w = self.pair_watch()
        KidsWatch.objects.filter(pk=w.pk).update(
            pair_expires_at=timezone.now() - timedelta(minutes=1))
        self.assertEqual(KW.on_watch_connect("8800000015", "SG")[1], "expired")
        w2 = self.pair_watch(code="1234567890")
        wid, reason, _ = KW.on_watch_connect("861234567890123", "SG")
        self.assertEqual((wid, reason), (w2.id, "newly_paired"))
        self.assertEqual(KidsWatch.objects.get(pk=w2.pk).imei, "861234567890123")

    def test_no_credits_pairs_in_safety_only(self):
        User.objects.filter(pk=self.owner.pk).update(ai_credits=0)
        w = self.pair_watch()
        self.assertEqual(KW.on_watch_connect("8800000015", "SG")[1], "newly_paired")
        w.refresh_from_db()
        self.assertEqual(w.state, "paired")
        self.assertFalse(KW.full_mode(w))
        r = self.c.get(V + "/kids-watch/watches/%d/history" % w.id)
        self.assertEqual((r.status_code, r.data["reason"]), (402, "safety_only"))

    def test_access(self):
        w = self.pair_watch()
        self.assertEqual(cl(self.mom).get(V + "/kids-watch/watches/%d" % w.id).status_code, 200)
        self.assertEqual(cl(self.x).get(V + "/kids-watch/watches/%d" % w.id).status_code, 404)
        self.assertEqual(cl(self.mom).patch(V + "/kids-watch/watches/%d" % w.id,
                                            {"child_name": "Z"}, format="json").status_code, 403)
        # mom leaves the Circle -> loses access at once
        CircleMember.objects.filter(user=self.owner, peer_user=self.mom).update(blocked=True)
        self.assertEqual(cl(self.mom).get(V + "/kids-watch/watches/%d" % w.id).status_code, 404)

    def test_command_api_only_locate_and_find(self):
        w = self.pair_watch()
        KW.on_watch_connect("8800000015", "SG")
        for k in ("monitor", "MONITOR", "call", "sos_numbers", "voice_down", "custom"):
            r = self.c.post(V + "/kids-watch/watches/%d/command" % w.id, {"kind": k},
                            format="json")
            self.assertEqual(r.status_code, 400, k)
        r = self.c.post(V + "/kids-watch/watches/%d/command" % w.id, {"kind": "find_watch"},
                        format="json")
        self.assertEqual(r.status_code, 201)

    def test_ingest_positions_and_battery(self):
        w = self.pair_watch()
        KW.on_watch_connect("8800000015", "SG")
        now = timezone.now()
        fix = {"at": now, "valid": True, "lat": HOME[0], "lng": HOME[1], "battery": 77,
               "wifi": [], "alarms": []}
        self.assertEqual(KW.ingest({w.id: {"fixes": [fix], "link": {"steps": 12}}}, now), 1)
        w.refresh_from_db()
        self.assertEqual((w.battery, w.steps, w.last_lat), (77, 12, HOME[0]))
        r = self.c.get(V + "/kids-watch/watches/%d/history" % w.id)
        self.assertEqual(len(r.data["points"]), 1)


class WatchSosTests(_Base):
    def _sos(self, w):
        KW.ingest({w.id: {"fixes": [], "alarms": [["sos", HOME[0], HOME[1]]]}})

    def test_sos_free_on_every_plan_and_in_safety_only(self):
        for i, plan in enumerate((None, "premium", "business")):
            owner = mk("0171190000%d" % i, "P%d" % i, credits=0, plan=plan)
            pair_circle(owner, self.mom)
            w = KidsWatch.objects.create(owner=owner, imei="99000000%02d" % i,
                                         child_name="Kid", state="paired",
                                         guardian_ids=[self.mom.id])
            before = User.objects.get(pk=owner.pk).ai_credits
            self.assertFalse(KW.full_mode(w))                   # unpaid: safety-only
            self._sos(w)
            self.assertTrue(self.spy.to(owner, "sos"), plan)
            self.assertTrue(self.spy.to(self.mom, "sos"), plan)
            self.assertTrue(FamilyAlert.objects.filter(user=owner, kind="sos").exists())
            self.assertEqual(User.objects.get(pk=owner.pk).ai_credits, before)
            self.spy.calls.clear()

    def test_sos_goes_through_family_path_with_child_account(self):
        w = self.pair_watch(child_user_id=self.child.id)
        KW.on_watch_connect("8800000015", "SG")
        w.refresh_from_db()
        self._sos(w)
        d = FamilyAlertDelivery.objects.filter(sender=self.child, kind="sos")
        self.assertEqual(set(d.values_list("recipient_id", flat=True)),
                         {self.owner.id, self.mom.id})
        sos = self.spy.to(self.mom, "sos")
        self.assertEqual(len(sos), 1)                          # never twice
        self.assertIn("Rina", sos[0]["ten"])
        self.assertTrue(sos[0]["high"])
        self.assertEqual(sos[0]["data"]["lat"], HOME[0])
        self._sos(w)                                           # same minute: one event
        self.assertEqual(len(self.spy.to(self.mom, "sos")), 1)

    def test_other_alarms_cooldown(self):
        w = self.pair_watch()
        KW.on_watch_connect("8800000015", "SG")
        w.refresh_from_db()
        KW.ingest({w.id: {"alarms": [["low_battery"], ["low_battery"]]}})
        self.assertEqual(len([c for c in self.spy.to(self.owner)
                              if c["data"].get("event") == "alarm_low_battery"]), 1)


class VoiceTests(_Base):
    def setUp(self):
        super().setUp()
        self.w = self.pair_watch()
        KW.on_watch_connect("8800000015", "SG")
        self.w.refresh_from_db()

    def test_voice_up_encrypted_pushed_free_and_expires(self):
        credits = User.objects.get(pk=self.owner.pk).ai_credits
        note = KW.voice_up(self.w.id, AMR)
        self.assertIsNotNone(note)
        raw = open(os.path.join(_MEDIA, note.file_name), "rb").read()
        self.assertNotIn(AMR, raw)                             # encrypted at rest
        self.assertEqual(note.duration_s, 0.04)
        self.assertTrue(any(c["data"].get("voice_id") == str(note.id)
                            for c in self.spy.to(self.mom)))
        r = cl(self.mom).get(V + "/kids-watch/voice/%d/audio" % note.id)
        self.assertEqual((r.status_code, r.content), (200, AMR))
        self.assertEqual(cl(self.x).get(V + "/kids-watch/voice/%d/audio" % note.id)
                         .status_code, 404)
        self.assertEqual(User.objects.get(pk=self.owner.pk).ai_credits, credits)
        KW.purge_voice(timezone.now() + timedelta(days=KW.VOICE_DAYS, minutes=1))
        self.assertFalse(KidsVoiceNote.objects.filter(pk=note.pk).exists())
        self.assertFalse(os.path.exists(os.path.join(_MEDIA, note.file_name)))

    def test_voice_reply_amr_only_queued(self):
        bad = base64.b64encode(b"\x00\x00\x00 ftypM4A ").decode()
        r = self.c.post(V + "/kids-watch/watches/%d/voice" % self.w.id, {"audio_b64": bad},
                        format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (400, "not_amr"))
        r = cl(self.mom).post(V + "/kids-watch/watches/%d/voice" % self.w.id,
                              {"audio_b64": base64.b64encode(AMR).decode()}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        cmd = KidsWatchCommand.objects.get(watch=self.w, kind="voice_down")
        pend = [p for p in KW.pending_for([self.w.id]) if p["kind"] == "voice_down"]
        if pend:
            self.assertEqual(pend[0]["payload"]["audio"], AMR)
        self.assertEqual(cmd.payload, {"voice_id": r.data["note"]["id"]})   # no audio in DB

    def test_safety_only_has_no_voice(self):
        KidsWatch.objects.filter(pk=self.w.pk).update(billed_until=None)
        self.assertIsNone(KW.voice_up(self.w.id, AMR))
        r = self.c.post(V + "/kids-watch/watches/%d/voice" % self.w.id,
                        {"audio_b64": base64.b64encode(AMR).decode()}, format="json")
        self.assertEqual(r.status_code, 402)

    def test_transcript_paid_only_no_key_and_charged(self):
        from core import bizagent_media as BM
        note = KW.voice_up(self.w.id, AMR)
        r = self.c.post(V + "/kids-watch/voice/%d/transcript" % note.id)
        self.assertEqual((r.status_code, r.data["reason"]), (402, "paid_only"))
        User.objects.filter(pk=self.owner.pk).update(
            plan="premium", plan_until=timezone.now() + timedelta(days=30))
        self.c = cl(User.objects.get(pk=self.owner.pk))     # the fresh (premium) row
        with mock.patch.object(BM, "stt_config", return_value={}):
            r = self.c.post(V + "/kids-watch/voice/%d/transcript" % note.id)
        self.assertEqual((r.status_code, r.data["reason"]), (503, "no_key"))
        self.assertEqual(KidsVoiceNote.objects.get(pk=note.pk).transcript, "")
        prev = BM.set_transcriber(lambda conf, data, mime, lang: "আমি স্কুলে পৌঁছেছি")
        self.addCleanup(BM.set_transcriber, prev)
        with mock.patch.object(BM, "stt_config", return_value={"api_key": "k"}):
            r = self.c.post(V + "/kids-watch/voice/%d/transcript" % note.id)
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data["text"], "আমি স্কুলে পৌঁছেছি")
        self.assertEqual(P.credit_cost("kids_voice_transcript", P.DEFAULTS()), 1)

    def test_pricing_rows_hold_the_40_percent_rule(self):
        cfg = P.DEFAULTS()
        for a in ("kids_watch_month", "kids_voice_transcript"):
            self.assertGreaterEqual(P.credit_cost(a, cfg), P.action_credit_floor(a, cfg), a)


class SchoolPlanApiTests(_Base):
    def _plan_body(self, **kw):
        b = dict(CFG)
        b.update(kw)
        return b

    def test_phone_plan_consent_checkin_stop_and_delete(self):
        r = self.c.post(V + "/school-mode/plans",
                        self._plan_body(child_user_id=self.child.id, watcher_ids=[self.mom.id]),
                        format="json")
        self.assertEqual(r.status_code, 201, r.data)
        pid = r.data["plan"]["id"]
        self.assertFalse(r.data["plan"]["accepted"])
        cc = cl(self.child)
        # not accepted yet: the button does nothing, the tick does nothing
        self.assertEqual(cc.post(V + "/school-mode/plans/%d/checkin" % pid,
                                 {"kind": "leaving"}, format="json").status_code, 409)
        mine = cc.get(V + "/school-mode/mine").data["plans"]
        self.assertEqual(len(mine), 1)
        self.assertEqual({w["name"] for w in mine[0]["watchers"]}, {"Abba", "Ammu"})
        self.assertEqual(cl(self.mom).post(V + "/school-mode/plans/%d/accept" % pid)
                         .status_code, 403)
        self.assertEqual(cc.post(V + "/school-mode/plans/%d/accept" % pid).status_code, 200)
        r = cc.post(V + "/school-mode/plans/%d/checkin" % pid,
                    {"kind": "arrived", "lat": SCHOOL[0], "lng": SCHOOL[1],
                     "audio_b64": base64.b64encode(AMR).decode(), "mime": "audio/amr"},
                    format="json")
        self.assertEqual(r.status_code, 200, r.data)
        ev = SchoolEvent.objects.filter(plan_id=pid).first()
        self.assertIsNotNone(ev.voice_id)
        self.assertTrue(self.spy.to(self.mom))
        self.assertEqual(cl(self.x).get(V + "/school-mode/plans/%d" % pid).status_code, 404)
        self.assertEqual(cl(self.x).post(V + "/school-mode/plans/%d/checkin" % pid,
                                         {"kind": "arrived"}, format="json").status_code, 404)
        # one-tap stop by the child, owner told; works with the flag OFF
        flag(False)
        r = cc.post(V + "/school-mode/plans/%d/stop" % pid)
        self.assertEqual(r.status_code, 200)
        self.assertFalse(SchoolPlan.objects.get(pk=pid).enabled)
        self.assertTrue(any(c["data"].get("event") == "stopped_by_child"
                            for c in self.spy.to(self.owner)))
        r = cc.post(V + "/school-mode/plans/%d/events/clear" % pid)
        self.assertEqual(r.status_code, 200)
        self.assertFalse(SchoolEvent.objects.filter(plan_id=pid).exists())
        self.assertFalse(KidsVoiceNote.objects.filter(plan_id=pid).exists())

    def test_plan_needs_places_and_circle_child(self):
        r = self.c.post(V + "/school-mode/plans",
                        self._plan_body(child_user_id=self.x.id), format="json")
        self.assertEqual(r.data["reason"], "child_not_in_circle")
        r = self.c.post(V + "/school-mode/plans",
                        self._plan_body(child_user_id=self.child.id, school=None),
                        format="json")
        self.assertEqual(r.data["reason"], "places_required")

    def test_watch_plan_tick_late_alert_with_last_location(self):
        w = self.pair_watch()
        KW.on_watch_connect("8800000015", "SG")
        r = self.c.post(V + "/school-mode/plans",
                        self._plan_body(watch_id=w.id, watcher_ids=[self.mom.id],
                                        class_mode=True), format="json")
        self.assertEqual(r.status_code, 201, r.data)
        pid = r.data["plan"]["id"]
        self.assertTrue(KidsWatchCommand.objects.filter(watch=w, kind="class_mode").exists())
        at = L(1, 7, 0).astimezone(dtz.utc)
        KW.ingest({w.id: {"fixes": [{"at": at, "valid": True, "lat": HOME[0],
                                     "lng": HOME[1], "wifi": []}]}}, at)
        self.assertEqual(SchoolPlan.objects.get(pk=pid).day["state"], "at_home")
        out = KW.tick(L(1, 8, 15).astimezone(dtz.utc))
        self.assertGreaterEqual(out["events"], 1)
        late = [c for c in self.spy.to(self.mom) if c["data"].get("event") == "late_school"]
        self.assertEqual(len(late), 1)
        self.assertTrue(late[0]["high"])
        self.assertEqual(late[0]["data"]["lat"], str(HOME[0]))
        self.assertTrue(FamilyAlert.objects.filter(user=self.mom, kind="kids_watch").exists())
        # the battery plan moved the watch to its morning interval
        self.assertTrue(KidsWatchCommand.objects.filter(watch=w, kind="set_interval",
                                                        payload__phase="at_home").exists())

    def test_phone_plan_tick_asks_child_before_parents(self):
        r = self.c.post(V + "/school-mode/plans",
                        self._plan_body(child_user_id=self.child.id), format="json")
        pid = r.data["plan"]["id"]
        cl(self.child).post(V + "/school-mode/plans/%d/accept" % pid)
        self.spy.calls.clear()
        KW.tick(L(1, 8, 15).astimezone(dtz.utc))
        self.assertTrue(any(c["data"].get("event") == "ask_ok"
                            for c in self.spy.to(self.child)))
        self.assertFalse(any(c["data"].get("event") == "late_school"
                             for c in self.spy.to(self.owner)))
        KW.tick(L(1, 8, 21).astimezone(dtz.utc))
        self.assertTrue(any(c["data"].get("event") == "late_school"
                            for c in self.spy.to(self.owner)))


# =========================================================================== real TCP

@override_settings(KIDSVOICE_ROOT=_MEDIA)
class WatchTcpEndToEndTests(APITransactionTestCase):
    """The REAL asyncio tracker server on 127.0.0.1:15041 (Store inline so the
    test DB is shared), driven by tracker.sim.WatchDevice over real TCP."""

    def setUp(self):
        cache.clear()
        self._env = os.environ.get("DJANGO_ALLOW_ASYNC_UNSAFE")
        os.environ["DJANGO_ALLOW_ASYNC_UNSAFE"] = "true"
        flag(True)
        self.owner = mk("01711400001", "Abba", credits=500)
        self.client.force_authenticate(self.owner)
        self.spy = Spy()
        p = mock.patch("core.push.safe_push", side_effect=self.spy)
        p.start()
        self.addCleanup(p.stop)
        KW._unknown_logged.clear()

    def tearDown(self):
        if self._env is None:
            os.environ.pop("DJANGO_ALLOW_ASYNC_UNSAFE", None)
        else:
            os.environ["DJANGO_ALLOW_ASYNC_UNSAFE"] = self._env

    async def _wait(self, cond, timeout=8.0):
        loop = asyncio.get_running_loop()
        end = loop.time() + timeout
        while loop.time() < end:
            if cond():
                return True
            await asyncio.sleep(0.05)
        return False

    def test_watch_roundtrip(self):
        from tracker.server import TrackerServer, Store
        from tracker.sim import WatchDevice
        r = self.client.post(V + "/kids-watch/watches",
                             {"code": "8800000015", "child_name": "Rina"}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        wid = r.data["watch"]["id"]

        async def scenario():
            srv = TrackerServer("127.0.0.1", TCP_PORT, store=Store(inline=True),
                                cfg={"max_packets_per_min": 600}, flush_s=0.1,
                                cmd_poll_s=0.1)
            await srv.start()
            try:
                bad = WatchDevice("8800000099")
                await bad.connect("127.0.0.1", TCP_PORT)
                self.assertFalse(await bad.link(timeout=1.0))
                await bad.close()

                dev = WatchDevice("8800000015", maker="3G")
                await dev.connect("127.0.0.1", TCP_PORT)
                self.assertTrue(await dev.link(battery=64))
                self.assertTrue(await self._wait(lambda: any(
                    c.startswith("UPLOAD,") for c in dev.commands)), dev.commands)
                self.assertIn("LZ,1,6", dev.commands)
                self.assertIn("PEDO,1", dev.commands)
                self.assertTrue(await self._wait(lambda: KidsWatchCommand.objects.filter(
                    watch_id=wid, state="acked").count() >= 4))
                now = datetime.now(dtz.utc)
                for i in range(3):
                    await dev.position(HOME[0] + i * 0.0001, HOME[1],
                                       at=now - timedelta(seconds=30 - i * 10))
                self.assertTrue(await self._wait(lambda: KidsWatchPosition.objects.filter(
                    watch_id=wid).count() == 3))
                self.assertTrue(await dev.alarm(*HOME))
                self.assertTrue(await self._wait(lambda: FamilyAlert.objects.filter(
                    user=self.owner, kind="sos").exists()))
                self.assertTrue(await dev.voice(AMR))
                self.assertTrue(await self._wait(lambda: KidsVoiceNote.objects.filter(
                    watch_id=wid, direction="up").exists()))
                r = self.client.post(V + "/kids-watch/watches/%d/voice" % wid,
                                     {"audio_b64": base64.b64encode(AMR).decode()},
                                     format="json")
                self.assertEqual(r.status_code, 201, r.data)
                nid = r.data["note"]["id"]
                self.assertTrue(await self._wait(lambda: dev.voice_received))
                self.assertEqual(dev.voice_received[0], AMR)
                self.assertTrue(await self._wait(
                    lambda: KidsVoiceNote.objects.get(pk=nid).state == "acked"))
                r = self.client.post(V + "/kids-watch/watches/%d/command" % wid,
                                     {"kind": "locate_now"}, format="json")
                self.assertEqual(r.status_code, 201)
                self.assertTrue(await self._wait(lambda: "CR" in dev.commands))
                r = self.client.post(V + "/kids-watch/watches/%d/command" % wid,
                                     {"kind": "monitor"}, format="json")
                self.assertEqual(r.status_code, 400)
                await asyncio.sleep(0.4)
                self.assertEqual(dev.forbidden_seen, [])
                await dev.close()
            finally:
                await srv.stop()

        asyncio.run(scenario())
        w = KidsWatch.objects.get(pk=wid)
        self.assertEqual((w.state, w.maker, w.battery), ("paired", "3G", 80))
        note = KidsVoiceNote.objects.get(watch=w, direction="up")
        self.assertEqual(KW.read_audio(note), AMR)
        self.assertEqual(w.interval_s, 1800)


def tearDownModule():
    shutil.rmtree(_MEDIA, ignore_errors=True)
