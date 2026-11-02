"""cctvarm — the automatic guard (owner CCTV order 3 Nov, W5: B13, B14, E3,
E8, E9). Pure rules first (hysteresis / GPS jitter, stale = unknown, arm
dwell, hold then fall back to the schedule, shop closed, no-movement), then
the API + hooks end to end: consent per member, distance-only presence,
the minute job arming/disarming with a log + owner notice, indoor privacy
on ingest and live view, day-end -> guard on, SOS at home -> live for the
allowed family only.
"""
from datetime import datetime, timedelta, timezone as dtz
from unittest import mock

from django.test import SimpleTestCase
from django.utils import timezone
from rest_framework.test import APITestCase

from core.logic import cctv_arm as ARM
from core.models import User

FF_KEY = "home_watchman"
HOME = (23.7808, 90.4142)            # Dhaka
T0 = datetime(2026, 11, 3, 6, 0, tzinfo=dtz.utc)


def _m(state, at, consent=True):
    return {"consent": consent, "state": state, "at": ARM.iso(at)}


# ===================================================================== pure
class HysteresisTests(SimpleTestCase):
    def test_inside_radius_is_home_far_is_away(self):
        self.assertEqual(ARM.classify(40, 20, "unknown"), "home")
        self.assertEqual(ARM.classify(150, 20, "away"), "home")
        self.assertEqual(ARM.classify(900, 30, "home"), "away")

    def test_gps_jitter_in_the_band_never_flaps(self):
        # a phone sitting at ~220 m with jittering fixes keeps its state
        for d in (160, 220, 260, 199, 240, 170):
            self.assertEqual(ARM.classify(d, 30, "home"), "home", d)
            self.assertEqual(ARM.classify(d, 30, "away"), "away", d)
            self.assertEqual(ARM.classify(d, 30, None), "unknown", d)

    def test_away_needs_the_accuracy_margin(self):
        # 320 m with a 40 m fix could be 280 m -> not sure -> keep
        self.assertEqual(ARM.classify(320, 40, "home"), "home")
        self.assertEqual(ARM.classify(360, 40, "home"), "away")

    def test_bad_fixes_are_ignored(self):
        self.assertEqual(ARM.classify(10, 400, "away"), "away")       # 400 m accuracy
        self.assertEqual(ARM.classify("x", 10, "home"), "home")
        self.assertEqual(ARM.classify(-5, 10, "away"), "away")
        self.assertEqual(ARM.classify(float("nan"), 10, "away"), "away")

    def test_radius_bounds(self):
        self.assertEqual(ARM.clamp_radius(10), 80)
        self.assertEqual(ARM.clamp_radius(9999), 500)
        self.assertEqual(ARM.clamp_radius("x"), ARM.RADIUS_DEFAULT_M)

    def test_distance(self):
        d = ARM.distance_m(HOME[0], HOME[1], HOME[0] + 0.009, HOME[1])
        self.assertTrue(990 < d < 1010, d)


class SummaryTests(SimpleTestCase):
    def test_stale_member_is_unknown(self):
        self.assertEqual(ARM.member_state(_m("home", T0), T0 + timedelta(minutes=29)), "home")
        self.assertEqual(ARM.member_state(_m("home", T0), T0 + timedelta(minutes=31)), "unknown")
        self.assertEqual(ARM.member_state(_m("home", T0, consent=False), T0), "unknown")

    def test_summary(self):
        now = T0
        self.assertEqual(ARM.summarize({}, now), ("off", []))
        self.assertEqual(ARM.summarize({"1": _m("away", now, consent=False)}, now)[0], "off")
        self.assertEqual(ARM.summarize({"1": _m("away", now), "2": _m("away", now)}, now)[0],
                         "all_away")
        s, home = ARM.summarize({"1": _m("away", now), "2": _m("home", now)}, now)
        self.assertEqual((s, home), ("someone_home", ["2"]))
        # one stale member: never "all away" on a guess
        old = now - timedelta(minutes=45)
        self.assertEqual(ARM.summarize({"1": _m("away", now), "2": _m("away", old)}, now)[0],
                         "unknown")
        # but a definite "home" is still definite
        self.assertEqual(ARM.summarize({"1": _m("home", now), "2": _m("away", old)}, now)[0],
                         "someone_home")


class DecideTests(SimpleTestCase):
    def test_arms_only_after_the_dwell(self):
        st, ev = ARM.decide_family({}, "all_away", T0)
        self.assertFalse(st.get("fam_armed"))
        self.assertEqual(ev, [])
        st, ev = ARM.decide_family(st, "all_away", T0 + timedelta(minutes=4))
        self.assertFalse(st.get("fam_armed"))
        st, ev = ARM.decide_family(st, "all_away", T0 + timedelta(minutes=5))
        self.assertTrue(st["fam_armed"])
        self.assertEqual([e["what"] for e in ev], ["armed_family"])
        # no repeat event while it stays armed
        st, ev = ARM.decide_family(st, "all_away", T0 + timedelta(minutes=6))
        self.assertEqual(ev, [])

    def test_a_blip_of_unknown_restarts_the_dwell(self):
        st, _ = ARM.decide_family({}, "all_away", T0)
        st, _ = ARM.decide_family(st, "unknown", T0 + timedelta(minutes=3))
        st, ev = ARM.decide_family(st, "all_away", T0 + timedelta(minutes=6))
        self.assertFalse(st.get("fam_armed"))
        self.assertEqual(ev, [])

    def test_return_disarms_and_turns_privacy_on(self):
        st = {"fam_armed": True, "last_definite": ARM.iso(T0)}
        st, ev = ARM.decide_family(st, "someone_home", T0, ["7"], privacy_on=True,
                                   has_indoor=True)
        self.assertFalse(st["fam_armed"])
        self.assertTrue(st["privacy"])
        self.assertEqual(st["privacy_by"], "7")
        self.assertEqual([e["what"] for e in ev], ["disarmed_return", "privacy_on"])
        self.assertEqual(ev[0]["uids"], ["7"])
        # no indoor camera chosen -> no privacy state
        st2, _ = ARM.decide_family({}, "someone_home", T0, ["7"], True, False)
        self.assertFalse(st2["privacy"])

    def test_unknown_never_changes_anything_until_the_hold_ends(self):
        st = {"fam_armed": True, "last_definite": ARM.iso(T0)}
        st, ev = ARM.decide_family(st, "unknown", T0 + timedelta(minutes=59))
        self.assertTrue(st["fam_armed"])            # never disarmed on a guess
        self.assertEqual(ev, [])
        st, ev = ARM.decide_family(st, "unknown", T0 + timedelta(minutes=60))
        self.assertFalse(st["fam_armed"])           # back to the owner's schedule
        self.assertEqual([e["what"] for e in ev], ["unknown_fallback"])
        # unknown from a quiet start: never armed on a guess
        st, ev = ARM.decide_family({}, "unknown", T0)
        self.assertFalse(st.get("fam_armed"))
        self.assertEqual(ev, [])

    def test_privacy_also_holds_on_unknown(self):
        st = {"privacy": True, "privacy_by": "7", "last_definite": ARM.iso(T0)}
        st, _ = ARM.decide_family(st, "unknown", T0 + timedelta(minutes=20))
        self.assertTrue(st["privacy"])

    def test_off_clears(self):
        st, ev = ARM.decide_family({"fam_armed": True}, "off", T0)
        self.assertFalse(st["fam_armed"])
        self.assertEqual([e["what"] for e in ev], ["family_off"])


class ShopAndNomoveTests(SimpleTestCase):
    def test_shop_closed(self):
        h = {"open": "09:00", "close": "21:00"}
        wed = datetime(2026, 11, 4, 22, 0)
        self.assertTrue(ARM.shop_closed(h, [], wed))
        self.assertFalse(ARM.shop_closed(h, [], wed.replace(hour=10)))
        self.assertTrue(ARM.shop_closed(h, [wed.weekday()], wed.replace(hour=10)))
        self.assertIsNone(ARM.shop_closed({}, [], wed))
        self.assertFalse(ARM.shop_closed({"open": "00:00", "close": "00:00"}, [], wed))
        night = {"open": "18:00", "close": "02:00"}
        self.assertFalse(ARM.shop_closed(night, [], wed.replace(hour=1)))
        self.assertTrue(ARM.shop_closed(night, [], wed.replace(hour=3)))
        # a finished day-end counts until its end time, even inside hours
        self.assertTrue(ARM.shop_closed(h, [], wed.replace(hour=10), T0 + timedelta(hours=1), T0))

    def test_next_open(self):
        self.assertEqual(ARM.next_open({"open": "09:00"}, datetime(2026, 11, 4, 22, 0)),
                         datetime(2026, 11, 5, 9, 0))
        self.assertEqual(ARM.next_open({"open": "09:00"}, datetime(2026, 11, 4, 7, 0)),
                         datetime(2026, 11, 4, 9, 0))
        self.assertIsNone(ARM.next_open({}, datetime(2026, 11, 4, 7, 0)))

    def test_nomove(self):
        cfg = {"on": True, "from": "06:00", "by": "10:00"}
        day = datetime(2026, 11, 4, 9, 59, tzinfo=dtz.utc)
        self.assertIsNone(ARM.nomove_due(cfg, None, day, False))           # not yet
        self.assertEqual(ARM.nomove_due(cfg, None, day.replace(hour=10, minute=0), False),
                         "no_movement")
        self.assertEqual(ARM.nomove_due(cfg, None, day.replace(hour=10), True), "offline")
        self.assertEqual(ARM.nomove_due(cfg, day.replace(hour=7), day, False), "moved")
        # yesterday's movement does not count today
        self.assertEqual(ARM.nomove_due(cfg, day - timedelta(days=1), day.replace(hour=10),
                                        False), "no_movement")
        done = dict(cfg, last_day=day.date().isoformat())
        self.assertIsNone(ARM.nomove_due(done, None, day.replace(hour=11), False))
        self.assertIsNone(ARM.nomove_due(dict(cfg, on=False), None, day.replace(hour=11), False))

    def test_texts_never_claim_medical_detection(self):
        for lang in ("bn", "en"):
            title, body = ARM.nomove_text(lang, "Room", "10:00", "no_movement")
            self.assertTrue("চিকিৎসা-যন্ত্র নয়" in body or "not a medical device" in body)
        self.assertIn("১০:০০", ARM.nomove_text("bn", "ঘর", "10:00", "no_movement")[0])
        self.assertIn("999", ARM.sos_text("en", "Karima", "Home")[1])
        self.assertIn("শব্দ", ARM.sos_text("bn", "করিমা", "বাড়ি")[1])

    def test_normalize_bounds(self):
        a = ARM.normalize({"radius_m": 5, "indoor": [1, "x", True, 2], "junk": 1,
                           "log": [{"a": 1}] * 99})
        self.assertEqual(a["radius_m"], 80)
        self.assertEqual(a["indoor"], [1, 2])
        self.assertNotIn("junk", a)
        self.assertEqual(len(a["log"]), ARM.LOG_MAX)
        self.assertFalse(a["family_on"])        # off by default
        self.assertFalse(a["sos_live"])


# ====================================================================== API
def _link(a, b):
    from core.models import CircleMember
    CircleMember.objects.create(user=a, peer_user=b, name=b.name, state="accepted",
                                relation="spouse", phone=b.phone)
    CircleMember.objects.create(user=b, peer_user=a, name=a.name, state="accepted",
                                relation="spouse", phone=a.phone)


class AutoGuardApiTests(APITestCase):
    def setUp(self):
        from core import feature_flags as FF
        from core.models import FeatureFlag, ShopCamera, ShopSite, ShopSiteViewer
        self.owner = User.objects.create_user(name="Rahim", phone="01710009001", password="pw")
        self.owner.language = "en"
        self.owner.save()
        self.wife = User.objects.create_user(name="Karima", phone="01710009002", password="pw")
        self.son = User.objects.create_user(name="Sabbir", phone="01710009003", password="pw")
        self.stranger = User.objects.create_user(name="X", phone="01710009004", password="pw")
        _link(self.owner, self.wife)
        _link(self.wife, self.son)
        self.pushes = []
        p = mock.patch("core.push.safe_push",
                       side_effect=lambda *a, **k: self.pushes.append((a, k)) or True)
        p.start()
        self.addCleanup(p.stop)
        FF.ensure_seeded()
        FeatureFlag.objects.filter(key=FF_KEY).update(enabled_all=True, enabled_play=True)
        FF.invalidate()
        self.addCleanup(FF.invalidate)
        now = timezone.now()
        self.site = ShopSite.objects.create(owner=self.owner, name="Home", kind="home",
                                            gateway="phone")
        self.cam = ShopCamera.objects.create(site=self.site, name="Living room",
                                             kind="shopbox", last_seen=now,
                                             device_info={"caps": ["live"]})
        self.gate = ShopCamera.objects.create(site=self.site, name="Gate", kind="shopbox",
                                              last_seen=now, device_info={"caps": ["live"]})
        ShopSiteViewer.objects.create(site=self.site, user=self.son)
        self.client.force_authenticate(self.owner)
        self.url = "/api/v1/shop/sites/%d/arm" % self.site.id

    def as_user(self, u):
        from rest_framework.test import APIClient
        c = APIClient()
        c.force_authenticate(u)
        return c

    def save_home(self):
        from core.models import SavedPlace
        return SavedPlace.objects.create(user=self.owner, label="home", name="Our flat",
                                         lat=HOME[0], lng=HOME[1], theft_safe=True)

    def setup_family(self):
        self.save_home()
        r = self.client.post(self.url, {"family_on": True, "invite": [self.wife.id],
                                        "my_consent": True, "indoor": [self.cam.id]},
                             format="json")
        self.assertEqual(r.status_code, 200, r.data)
        w = self.as_user(self.wife)
        r = w.post("/api/v1/shop/arm/consent", {"site": self.site.id, "consent": True},
                   format="json")
        self.assertEqual(r.status_code, 200, r.data)
        return w

    def report(self, client, dist, acc=20):
        return client.post("/api/v1/shop/arm/presence",
                           {"reports": [{"site": self.site.id, "distance_m": dist,
                                         "accuracy_m": acc}]}, format="json")

    def site_now(self):
        self.site.refresh_from_db()
        return self.site

    # ------------------------------------------------------------- consent
    def test_off_by_default_and_needs_home_first(self):
        r = self.client.get(self.url)
        self.assertEqual(r.status_code, 200, r.data)
        self.assertFalse(r.data["config"]["family_on"])
        self.assertFalse(r.data["config"]["sos_live"])
        self.assertEqual(r.data["members"], [])
        names = {c["name"] for c in r.data["candidates"]}
        self.assertIn("Karima", names)               # My Circle, one tap
        self.assertIn("Sabbir", names)               # a viewer of the place
        r = self.client.post(self.url, {"family_on": True}, format="json")
        self.assertEqual(r.status_code, 422)
        self.assertEqual(r.data.get("code") or r.data.get("error"), "no_home")

    def test_member_consent_is_theirs_and_withdrawable(self):
        self.save_home()
        r = self.client.post(self.url, {"family_on": True,
                                        "invite": [self.wife.id, self.stranger.id]},
                             format="json")
        self.assertEqual(r.status_code, 200, r.data)
        uids = {m["uid"] for m in r.data["members"]}
        self.assertEqual(uids, {self.wife.id})        # a stranger can't be added
        self.assertEqual(r.data["members"][0]["state"], "no_consent")
        self.assertTrue(any("asks" in a[3] for a, _k in self.pushes))
        w = self.as_user(self.wife)
        mine = w.get("/api/v1/shop/arm/mine").data["sites"]
        self.assertEqual(len(mine), 1)
        self.assertIsNone(mine[0]["home"])            # no Home point before yes
        # before yes, a reading is refused
        self.assertEqual(self.report(w, 20).data["sites"][0]["state"], "no_consent")
        w.post("/api/v1/shop/arm/consent", {"site": self.site.id, "consent": True},
               format="json")
        mine = w.get("/api/v1/shop/arm/mine").data["sites"]
        self.assertAlmostEqual(mine[0]["home"]["lat"], HOME[0])
        self.assertEqual(self.report(w, 20).data["sites"][0]["state"], "home")
        # withdraw: the state is forgotten at once
        w.post("/api/v1/shop/arm/consent", {"site": self.site.id, "consent": False},
               format="json")
        arm = ARM.arm_of(self.site_now())
        self.assertNotIn("state", arm["members"][str(self.wife.id)])
        self.assertNotIn("at", arm["members"][str(self.wife.id)])
        # a stranger cannot consent to someone else's place
        r = self.as_user(self.stranger).post("/api/v1/shop/arm/consent",
                                             {"site": self.site.id, "consent": True},
                                             format="json")
        self.assertEqual(r.status_code, 404)

    def test_no_coordinates_are_stored(self):
        w = self.setup_family()
        self.report(w, 25)
        arm = ARM.arm_of(self.site_now())
        m = arm["members"][str(self.wife.id)]
        self.assertEqual(set(m) - {"consent", "consent_at", "invited", "state", "at", "src"},
                         set())

    # ------------------------------------------------------- arm / disarm
    def test_everyone_out_arms_after_dwell_and_return_disarms(self):
        from core import shop_views as SV
        w = self.setup_family()
        now = timezone.now()
        self.report(w, 2000)
        self.report(self.client, 1500)
        ARM.tick(now=now)
        self.assertFalse(SV.away_now(self.site_now(), now))      # dwell first
        ARM.tick(now=now + timedelta(minutes=6))
        site = self.site_now()
        self.assertTrue(SV.away_now(site, now + timedelta(minutes=6)))
        notes = [a for a, _k in self.pushes if "Everyone is out" in a[3]]
        self.assertEqual(len(notes), 1)
        self.assertEqual(notes[0][0].pk, self.owner.pk)          # owner only
        self.assertEqual(ARM.arm_of(site)["log"][0]["what"], "armed_family")
        # GPS jitter around 220 m: still out, no flap, no new notice
        n = len(self.pushes)
        for d in (220, 180, 260):
            self.report(w, d)
            ARM.tick(now=now + timedelta(minutes=7))
        self.assertTrue(SV.away_now(self.site_now(), now + timedelta(minutes=7)))
        self.assertEqual(len(self.pushes), n)
        # she is back: guard off + indoor privacy, both logged and told
        self.report(w, 30)
        ARM.tick(now=now + timedelta(minutes=8))
        site = self.site_now()
        self.assertFalse(SV.away_now(site, now + timedelta(minutes=8)))
        whats = [x["what"] for x in ARM.arm_of(site)["log"]]
        self.assertIn("disarmed_return", whats)
        self.assertIn("privacy_on", whats)
        self.assertTrue(any("Karima is back home" in a[3] for a, _k in self.pushes))
        r = self.client.get(self.url)
        self.assertTrue(r.data["status"]["privacy"])
        self.assertEqual(r.data["status"]["summary"], "someone_home")

    def test_stale_member_never_arms_or_disarms_on_a_guess(self):
        from core import shop_views as SV
        w = self.setup_family()
        now = timezone.now()
        self.report(w, 2000)
        self.report(self.client, 2000)
        ARM.tick(now=now)
        ARM.tick(now=now + timedelta(minutes=6))
        self.assertTrue(SV.away_now(self.site_now(), now + timedelta(minutes=6)))
        # 40 minutes later nobody was heard: "not known" — still armed
        later = now + timedelta(minutes=40)
        ARM.tick(now=later)
        self.assertTrue(SV.away_now(self.site_now(), later))
        self.assertEqual(ARM.arm_of(self.site_now())["state"]["summary"], "unknown")
        # after the hold: back to the owner's own schedule, logged + told
        much = now + timedelta(minutes=6 + ARM.HOLD_MIN + 1)
        ARM.tick(now=much)
        self.assertFalse(SV.away_now(self.site_now(), much))
        self.assertEqual(ARM.arm_of(self.site_now())["log"][0]["what"], "unknown_fallback")

    def test_unknown_member_blocks_all_away(self):
        w = self.setup_family()
        now = timezone.now()
        self.report(self.client, 2000)          # owner out, wife never heard
        ARM.tick(now=now)
        ARM.tick(now=now + timedelta(minutes=10))
        self.assertFalse(ARM.auto_armed(self.site_now(), now + timedelta(minutes=10)))
        del w

    def test_heartbeat_is_a_source_only_with_consent(self):
        from core.models import ProtectedPhone
        self.save_home()
        self.client.post(self.url, {"family_on": True, "invite": [self.wife.id]},
                         format="json")
        now = timezone.now()
        ProtectedPhone.objects.create(owner=self.wife, last_heartbeat_at=now,
                                      last_lat=HOME[0] + 0.0002, last_lng=HOME[1])
        ARM.tick(now=now)
        m = ARM.arm_of(self.site_now())["members"][str(self.wife.id)]
        self.assertNotIn("state", m)                         # no consent yet
        self.as_user(self.wife).post("/api/v1/shop/arm/consent",
                                     {"site": self.site.id, "consent": True}, format="json")
        ARM.tick(now=now + timedelta(seconds=30))
        m = ARM.arm_of(self.site_now())["members"][str(self.wife.id)]
        self.assertEqual((m["state"], m["src"]), ("home", "hb"))

    # ----------------------------------------------------------- privacy
    def _privacy_on(self):
        w = self.setup_family()
        self.report(w, 20)
        ARM.tick(now=timezone.now())
        self.assertTrue(ARM.privacy_blocks(self.site_now(), self.cam))
        return w

    def test_privacy_mutes_indoor_alerts_and_live_only(self):
        from core import shop_views as SV
        self._privacy_on()
        site = self.site_now()
        now = timezone.now()
        d, ev = SV._ingest_event(site, self.cam, {"type": "person_detected",
                                                  "at": now.timestamp(),
                                                  "signals": {"detector": "x"}}, now)
        self.assertIsNone(ev)
        self.assertEqual(d["reason_signals"], ["privacy_home"])
        d, _ev = SV._ingest_event(site, self.gate, {"type": "person_detected",
                                                    "at": now.timestamp(),
                                                    "signals": {"detector": "x"}}, now)
        self.assertNotEqual(d.get("reason_signals"), ["privacy_home"])   # gate keeps guarding
        r = self.client.post("/api/v1/shop/live/start", {"camera": self.cam.id}, format="json")
        self.assertEqual(r.status_code, 423, r.data)
        # the owner can turn the indoor cameras back on (logged)
        r = self.client.post(self.url, {"privacy_pause": True}, format="json")
        self.assertFalse(r.data["status"]["privacy"])
        self.assertEqual(r.data["log"][0]["what"], "privacy_paused")
        self.assertFalse(ARM.privacy_blocks(self.site_now(), self.cam))
        # the pause holds while she stays home (the minute job keeps it)
        ARM.tick(now=timezone.now() + timedelta(minutes=1))
        self.assertFalse(ARM.privacy_blocks(self.site_now(), self.cam))

    # -------------------------------------------------------- shop closed
    def test_day_end_turns_the_guard_on_with_a_notice(self):
        from core import shop_views as SV
        self.site.hours = {"open": "00:00", "close": "00:00"}     # open all day
        self.site.save(update_fields=["hours"])
        r = self.client.post("/api/v1/shop/sites/%d/eod" % self.site.id,
                             {"counted_cash": 0, "opening_float": 0}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        self.assertNotIn("guard_on", r.data)                     # switch is off
        self.client.post(self.url, {"closed_on": True}, format="json")
        r = self.client.post("/api/v1/shop/sites/%d/eod" % self.site.id,
                             {"counted_cash": 1, "opening_float": 1}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        g = r.data["guard_on"]
        self.assertTrue("guard on" in g.lower() or "পাহারা চালু" in g, g)
        self.assertTrue(SV.away_now(self.site_now()))
        self.assertTrue(any("Shop closed" in a[3] for a, _k in self.pushes))

    def test_shop_hours_close_and_open(self):
        self.site.hours = {"open": "09:00", "close": "21:00"}
        self.site.save(update_fields=["hours"])
        self.client.post(self.url, {"closed_on": True}, format="json")
        night = timezone.make_aware(datetime(2026, 11, 4, 23, 0))
        ARM.tick(now=night)
        self.assertTrue(ARM.auto_armed(self.site_now(), night))
        morning = timezone.make_aware(datetime(2026, 11, 5, 9, 30))
        ARM.tick(now=morning)
        self.assertFalse(ARM.auto_armed(self.site_now(), morning))
        whats = [x["what"] for x in ARM.arm_of(self.site_now())["log"]]
        self.assertEqual(whats[:2], ["open_again", "armed_closed"])

    # ----------------------------------------------------------- no-move
    def test_no_movement_by_time_tells_chosen_family_once(self):
        from core import shop_views as SV
        r = self.client.post(self.url, {"nomove": {str(self.cam.id): {
            "on": True, "from": "06:00", "by": "10:00", "people": [self.wife.id,
                                                                  self.stranger.id]}}},
            format="json")
        self.assertEqual(r.status_code, 200, r.data)
        row = [c for c in r.data["cameras"] if c["id"] == self.cam.id][0]
        self.assertEqual(row["nomove"]["people"], [self.wife.id])   # stranger dropped
        day = timezone.make_aware(datetime(2026, 11, 4, 10, 5))
        self.cam.last_seen = day
        self.cam.save(update_fields=["last_seen"])
        self.gate.last_seen = day
        self.gate.save(update_fields=["last_seen"])
        ARM.tick(now=day)
        hit = [a for a, _k in self.pushes if "No movement" in a[3] or "নড়াচড়া" in a[2]]
        self.assertEqual({a[0].pk for a in hit}, {self.owner.pk, self.wife.pk})
        n = len(self.pushes)
        ARM.tick(now=day + timedelta(minutes=5))           # once a day
        self.assertEqual(len(self.pushes), n)
        # next day movement at 07:00 -> no alert
        nxt = day + timedelta(days=1)
        site = self.site_now()
        SV._ingest_event(site, self.cam, {"type": "motion", "at": nxt.timestamp(),
                                          "signals": {"detector": "x"}},
                         nxt.replace(hour=7, minute=0))
        self.cam.last_seen = nxt
        self.cam.save(update_fields=["last_seen"])
        ARM.tick(now=nxt)
        self.assertEqual(len([a for a, _k in self.pushes if "No movement" in a[3]]),
                         len([a for a in hit if "No movement" in a[3]]))

    def test_bad_window_is_refused(self):
        r = self.client.post(self.url, {"nomove": {str(self.cam.id): {
            "on": True, "from": "11:00", "by": "10:00"}}}, format="json")
        self.assertEqual(r.status_code, 422)

    # --------------------------------------------------------------- SOS
    def test_sos_at_home_opens_live_for_allowed_family_only(self):
        from core import family_alerts as FA
        self.save_home()
        self.client.post(self.url, {"sos_live": True, "invite": [self.wife.id],
                                    "family_on": True}, format="json")
        self.as_user(self.wife).post("/api/v1/shop/arm/consent",
                                     {"site": self.site.id, "consent": True}, format="json")
        st = FA.sos(self.wife, lat=HOME[0] + 0.0003, lng=HOME[1], client_id="t1")
        self.assertGreaterEqual(st.get("home_live", 0), 1)
        live = [a for a, k in self.pushes
                if (k.get("data") or {}).get("route") == "watchman/sos_live"]
        # the owner (in her circle) — never the stranger; the son is a viewer
        # in her circle too
        self.assertEqual({a[0].pk for a in live}, {self.owner.pk, self.son.pk})
        self.assertIsNotNone(ARM.sos_camera(self.son, self.cam.id))
        self.assertIsNone(ARM.sos_camera(self.stranger, self.cam.id))
        r = self.as_user(self.son).get("/api/v1/shop/arm/sos-live")
        self.assertEqual(len(r.data["grants"]), 1)
        self.assertEqual(r.data["grants"][0]["by_name"], "Karima")
        # SOS overrides indoor privacy for the allowed family
        self.assertFalse(ARM.privacy_blocks(self.site_now(), self.cam))
        r = self.as_user(self.stranger).get("/api/v1/shop/arm/sos-live")
        self.assertEqual(r.data["grants"], [])
        r = self.as_user(self.stranger).post("/api/v1/shop/live/start",
                                             {"camera": self.cam.id}, format="json")
        self.assertEqual(r.status_code, 404)

    def test_sos_away_from_home_or_switch_off_opens_nothing(self):
        from core import family_alerts as FA
        self.save_home()
        self.client.post(self.url, {"invite": [self.wife.id], "family_on": True},
                         format="json")
        self.as_user(self.wife).post("/api/v1/shop/arm/consent",
                                     {"site": self.site.id, "consent": True}, format="json")
        st = FA.sos(self.wife, lat=HOME[0], lng=HOME[1], client_id="t2")
        self.assertEqual(st.get("home_live", 0), 0)              # switch off
        self.client.post(self.url, {"sos_live": True}, format="json")
        st = FA.sos(self.wife, lat=HOME[0] + 0.05, lng=HOME[1], client_id="t3")
        self.assertEqual(st.get("home_live", 0), 0)              # 5 km away
        self.assertIsNone(ARM.sos_camera(self.son, self.cam.id))

    def test_flag_off_hides_the_api(self):
        from core import feature_flags as FF
        from core.models import FeatureFlag
        FeatureFlag.objects.filter(key=FF_KEY).update(enabled_all=False, enabled_play=False)
        FF.invalidate()
        r = self.as_user(self.stranger).get("/api/v1/shop/arm/mine")
        self.assertEqual(r.status_code, 403)
