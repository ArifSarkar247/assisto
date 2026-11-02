"""cctvactivity (W10 activity brain + visitor log, owner CCTV order 3 Nov
E1 E2 E5 E6 E7 E10 F2).

Pure rules (logic/cctv_brief.py) first, then the real glue through the API:
counting from the ingest path, the hourly watchman check, the morning Bangla
summary + camera health, footfall next to POS sales, the visitor log search,
capped AI descriptions (mocked vision provider — the first real call happens
when the owner adds a key) and the time-lapse frame list.
"""
from datetime import datetime, timedelta
from unittest import mock

from django.core.files.base import ContentFile
from django.test import SimpleTestCase
from django.utils import timezone

from core import tests_e2e_cctv as E2E
from core.logic import cctv_brief as CB
from core.logic import cctv_extras as CX


def at(y, mo, d, h, mi=0):
    return timezone.make_aware(datetime(y, mo, d, h, mi), timezone.get_current_timezone())


# ================================================================== pure
class BriefRuleTests(SimpleTestCase):
    def cfg(self, **kw):
        c = CB.defaults()
        c.update(kw)
        return c

    def test_visits_are_deduplicated_per_camera(self):
        act, cfg = {}, self.cfg()
        t0 = at(2026, 11, 2, 10, 0)
        for s in (0, 20, 40, 55):                 # one person, 55 s on camera 1
            CB.observe(act, cfg, 1, "person_detected", {}, t0, t0.timestamp() + s)
        CB.observe(act, cfg, 2, "person_detected", {}, t0, t0.timestamp() + 30)
        CB.observe(act, cfg, 1, "person_detected", {}, t0, t0.timestamp() + 200)
        d = act["days"]["2026-11-02"]
        self.assertEqual(d["h"][10], 3)
        self.assertEqual(d["m"][10], 6)
        foot, src = CB.footfall(d)
        self.assertEqual((foot[10], src), (3, "estimate"))

    def test_entry_line_wins_and_direction(self):
        act, cfg = {}, self.cfg()
        t = at(2026, 11, 2, 18, 30)
        for dr in ("a_to_b", "a_to_b", "b_to_a"):
            CB.observe(act, cfg, 1, "line_crossing", {"direction": dr}, t, t.timestamp())
        CB.observe(act, cfg, 1, "line_crossing", {"object": "vehicle"}, t, t.timestamp())
        d = act["days"]["2026-11-02"]
        self.assertEqual(CB.footfall(d, "a_to_b"), (d["la"], "line"))
        self.assertEqual(CB.footfall(d, "a_to_b")[0][18], 2)
        self.assertEqual(CB.footfall(d, "both")[0][18], 2)          # 3 crossings -> 2
        self.assertEqual(d["lt"][18], 3)                             # the car is not a visitor

    def test_health_still_and_non_movement_not_counted(self):
        act = {}
        t = at(2026, 11, 2, 9)
        CB.observe(act, self.cfg(), 1, "motion", {"health_still": True}, t, t.timestamp())
        CB.observe(act, self.cfg(), 1, "void_spike", {}, t, t.timestamp())
        self.assertEqual(act, {})

    def test_open_close_from_shop_cams_outside_night(self):
        act = {}
        cfg = self.cfg(shop_cams=[1], wm_on=True)
        for h, mi, cam in ((3, 0, 1), (9, 12, 1), (13, 0, 2), (21, 40, 1), (23, 30, 1)):
            t = at(2026, 11, 2, h, mi)
            CB.observe(act, cfg, cam, "motion", {}, t, t.timestamp())
        d = act["days"]["2026-11-02"]
        self.assertEqual((d["first"], d["last"]), ("09:12", "21:40"))
        oc = CB.open_close(d, at(2026, 11, 2, 22, 0))
        self.assertIsNone(oc["close"])                    # only 20 min quiet: not final
        oc = CB.open_close(d, at(2026, 11, 2, 22, 41))
        self.assertEqual((oc["open"], oc["close"], oc["confirmed"]), ("09:12", "21:40", False))
        CB.confirm_times(d, "09:00", None)
        oc = CB.open_close(d)
        self.assertEqual((oc["open"], oc["camera_open"], oc["confirmed"]), ("09:00", "09:12", True))
        # watchman presence at night on any camera (wm_cams empty = all)
        self.assertEqual(sorted(d["wp"]), [3, 23])

    def test_watchman_due_and_verdict(self):
        cfg = self.cfg(wm_on=True)
        act = {}
        self.assertEqual(CB.watchman_due(cfg, at(2026, 11, 3, 0, 1), act), ("2026-11-02", 23))
        self.assertIsNone(CB.watchman_due(cfg, at(2026, 11, 2, 15, 1), act))
        self.assertIsNone(CB.watchman_due(self.cfg(), at(2026, 11, 3, 0, 1), act))
        d = CB.day_rec(act, "2026-11-02")
        d["wm"]["23"] = "ok"
        self.assertIsNone(CB.watchman_due(cfg, at(2026, 11, 3, 0, 1), act))
        self.assertEqual(CB.watchman_verdict({"wp": [1]}, 1, False), "ok")
        self.assertEqual(CB.watchman_verdict({"wp": []}, 1, True), "unknown")
        self.assertEqual(CB.watchman_verdict({"wp": []}, 1, False), "miss")

    def test_footfall_vs_sales_conversion_peaks(self):
        foot = [0] * 24
        sales = [0] * 24
        foot[10], foot[11], foot[18] = 10, 4, 20
        sales[10], sales[18], sales[19] = 3, 5, 1
        r = CB.footfall_vs_sales(foot, sales, [0] * 24)
        self.assertEqual((r["visitors"], r["sales"], r["conversion"]), (34, 9, 26.5))
        self.assertEqual(r["peak_hours"], [10, 11, 18])
        row19 = [x for x in r["rows"] if x["hour"] == 19][0]
        self.assertIsNone(row19["conversion"])            # sales, no counted visitor

    def test_settings_bounds(self):
        with self.assertRaises(CB.CfgError):
            CB.normalize_cfg({"brief_hour": 30}, strict=True)
        with self.assertRaises(CB.CfgError):
            CB.normalize_cfg({"wm_start": "22:00", "wm_end": "22:00"}, strict=True)
        with self.assertRaises(CB.CfgError):
            CB.normalize_cfg({"wm_cams": [9]}, {1, 2}, strict=True)
        self.assertEqual(CB.normalize_cfg({"brief_hour": 30})["brief_hour"], 8)
        c = CB.normalize_cfg({"brief_hour": "7", "wm_cams": ["2"], "foot_dir": "b_to_a"}, {2}, True)
        self.assertEqual((c["brief_hour"], c["wm_cams"], c["foot_dir"]), (7, [2], "b_to_a"))

    def test_template_and_ai_cleaning(self):
        d = CB.template_desc("person_detected", {"zone": "গেট"}, "Gate", at(2026, 11, 2, 19, 5), 3)
        self.assertEqual(d["src"], "template")
        self.assertIn("১৯:০৫", d["bn"])
        self.assertIn("৩বার", d["bn"])
        self.assertIn("19:05", d["en"])
        a = CB.clean_ai_desc("একজন মানুষ নীল শার্ট পরে গেটে দাঁড়িয়ে || A person in a blue shirt at the gate")
        self.assertEqual((a["src"], a["en"]), ("ai", "A person in a blue shirt at the gate"))
        self.assertIsNone(CB.clean_ai_desc("একজন চোর দরজায় || A thief at the door"))
        self.assertIsNone(CB.clean_ai_desc(""))
        act = {}
        self.assertEqual(CB.ai_allowed(act, "2026-11", 2), (True, 0))
        CB.ai_take(act, "2026-11")
        CB.ai_take(act, "2026-11")
        self.assertEqual(CB.ai_allowed(act, "2026-11", 2), (False, 2))
        self.assertEqual(CB.ai_allowed(act, "2026-12", 2), (True, 0))   # new month

    def test_search_bangla_digits(self):
        self.assertTrue(CB.matches("একজন মানুষ — Gate, ১৯:০৫", "gate 19:05"))
        self.assertTrue(CB.matches("A person, 19:05", "১৯"))
        self.assertFalse(CB.matches("A person", "vehicle"))

    def test_summary_lines_bn(self):
        info = {"foot": CB.footfall_vs_sales([0] * 10 + [5] + [0] * 13, [0] * 10 + [2] + [0] * 13,
                                             [0] * 10 + [700.0] + [0] * 13),
                "foot_src": "estimate", "oc": {"open": "09:12", "close": "21:40", "confirmed": False},
                "wm": {"ok": 6, "miss": 1, "unknown": 1}, "alerts": 2,
                "health": [{"name": "গেট", "offline_min": 12, "sd": "ok", "last_photo": "21:30"}]}
        lines = CB.summary_lines(info, "bn")
        joined = "\n".join(lines)
        self.assertIn("আগন্তুক: ৫জন (আনুমানিক)", joined)
        self.assertIn("কনভার্সন ৪০.০%", joined)
        self.assertIn("নিশ্চিত করুন", joined)
        self.assertIn("১ ঘণ্টা দেখা যায়নি", joined)
        self.assertIn("গেট: ১২ মিনিট বন্ধ ছিল, SD ঠিক, শেষ ছবি ২১:৩০", joined)
        self.assertFalse(any(ch.isascii() and ch.isdigit() for ch in joined.replace("SD", "")))

    def test_timelapse_plan_and_spread(self):
        self.assertEqual(CB.timelapse_plan(60), {"frames": 60, "delay_cs": 50, "seconds": 30.0})
        self.assertEqual(CB.timelapse_plan(5)["delay_cs"], 200)          # max 2 s / frame
        self.assertEqual(CB.timelapse_plan(500)["frames"], 120)
        self.assertEqual(CB.timelapse_plan(0)["frames"], 0)
        self.assertEqual(CB.spread(list(range(10)), 3), [0, 4, 9])

    def test_guard_settings_keep_activity(self):
        g = {"_state": {"x": 1}, "_activity": {"cfg": {"wm_on": True}}}
        out = CX.apply_settings(g, {"offline_on": False}, set())
        self.assertEqual(out["_activity"], {"cfg": {"wm_on": True}})
        self.assertEqual(out["_state"], {"x": 1})


# ================================================================== glue
class ActivityApiTests(E2E._Base):
    def setUp(self):
        super().setUp()
        from core.models import ShopSite, ShopCamera
        self.cam = self.add_camera("hikvision", "Gate")
        self.cam2 = self.add_camera("hikvision", "Counter")
        self.s = ShopSite.objects.get(pk=self.site["id"])
        self.c1 = ShopCamera.objects.get(pk=self.cam["id"])
        self.c2 = ShopCamera.objects.get(pk=self.cam2["id"])
        self.base = "/api/v1/shop/sites/%d" % self.s.id

    def obs(self, cam, etype, when, **sig):
        from core import cctv_activity as A
        self.s.refresh_from_db()
        return A.observe(self.s, cam, {"type": etype, "signals": sig}, when)

    def event(self, etype, when, cam=None, photo=True, **sig):
        from core.models import ShopEvent
        ev = ShopEvent.objects.create(site=self.s, camera=cam or self.c1, type=etype,
                                      signals={"inputs": sig}, last_at=when)
        ShopEvent.objects.filter(pk=ev.pk).update(created=when)
        ev.refresh_from_db()
        if photo:
            ev.snapshot.save("a%d.jpg" % ev.pk, ContentFile(E2E._jpeg(64, 36)), save=True)
        return ev

    def test_ingest_counts_even_when_not_armed(self):
        from core import shop_views as SV
        now = timezone.now()
        SV._ingest_event(self.s, self.c1, {"type": "person_detected",
                                           "signals": {"human": True}}, now)
        self.s.refresh_from_db()
        d = self.s.guard["_activity"]["days"][timezone.localtime(now).date().isoformat()]
        self.assertEqual(sum(d["h"]), 1)
        # the owner saving guard settings does not wipe it
        r = self.client.put(self.base + "/guard", {"offline_on": True}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.s.refresh_from_db()
        self.assertIn("_activity", self.s.guard)

    def test_day_view_footfall_next_to_sales_and_confirm(self):
        from core.models import ShopPosEvent
        today = timezone.localtime(timezone.now()).date()
        t = lambda h, m=0: timezone.make_aware(datetime(today.year, today.month, today.day, h, m))
        for i in range(4):
            self.obs(self.c1, "person_detected", t(0, 10 + i * 5))
        ShopPosEvent.objects.create(site=self.s, kind="sale", amount=450, at=t(0, 20))
        r = self.client.get(self.base + "/activity", HTTP_ACCEPT_LANGUAGE="bn")
        self.assertEqual(r.status_code, 200, r.data)
        f = r.data["foot"]
        self.assertEqual((f["visitors"], f["sales"], f["amount"], f["conversion"]), (4, 1, 450.0, 25.0))
        self.assertEqual(r.data["foot_src"], "estimate")
        self.assertIn("settings", r.data)
        self.assertEqual({h["name"] for h in r.data["health"]}, {"Gate", "Counter"})
        self.assertTrue(any("আগন্তুক" in ln for ln in r.data["lines"]))
        # confirm / correct the times
        r = self.client.post(self.base + "/activity/confirm",
                             {"date": today.isoformat(), "open": "09:00", "close": "21:30"},
                             format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data["open_close"]["open"], "09:00")
        r = self.client.post(self.base + "/activity/confirm",
                             {"date": today.isoformat(), "open": "25:00"}, format="json")
        self.assertEqual(r.status_code, 422)
        # the family viewer reads, but cannot change
        self.client.force_authenticate(self.family)
        self.assertEqual(self.client.get(self.base + "/activity").status_code, 200)
        self.assertEqual(self.client.put(self.base + "/activity/settings", {"wm_on": True},
                                         format="json").status_code, 404)
        self.assertEqual(self.client.post(self.base + "/activity/confirm",
                                          {"date": today.isoformat(), "open": "09:00"},
                                          format="json").status_code, 404)

    def test_settings_put_validates(self):
        r = self.client.put(self.base + "/activity/settings",
                            {"wm_on": True, "wm_cams": [self.c1.id], "brief_hour": 7},
                            format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual((r.data["wm_on"], r.data["wm_cams"], r.data["brief_hour"]),
                         (True, [self.c1.id], 7))
        self.assertFalse(r.data["ai"]["ready"])
        self.assertEqual(r.data["ai"]["cap"], 100)                   # 2 cameras x 50
        r = self.client.put(self.base + "/activity/settings", {"wm_cams": [999999]}, format="json")
        self.assertEqual(r.status_code, 422)

    def test_watchman_hourly_check_alerts_once_per_missed_hour(self):
        from core import cctv_activity as A
        from core.models import NotifEvent
        A.act_update(self.s, lambda a: a.__setitem__("cfg", CB.normalize_cfg(
            {"wm_on": True, "wm_cams": [self.c1.id]})))
        self.obs(self.c1, "motion", at(2026, 11, 2, 23, 20))
        self.s.refresh_from_db()
        self.assertEqual(A.run_watchman(self.s, at(2026, 11, 3, 0, 1)), "ok")
        self.assertIsNone(A.run_watchman(self.s, at(2026, 11, 3, 0, 2)))   # done once
        self.pushes.clear()
        self.assertEqual(A.run_watchman(self.s, at(2026, 11, 3, 1, 1)), "miss")
        p = self.shop_pushes()
        self.assertEqual(len(p), 2)                      # owner + family viewer
        n = NotifEvent.objects.filter(meta__notice="watchman_missing").first()
        self.assertIn("পাহারার ক্যামেরায় কোনো নড়াচড়া আসেনি", n.body_bn)
        self.assertIn("০০:০০–০১:০০", n.body_bn)
        # cameras offline -> unknown, never blamed
        from core import cctvx_views as CXV
        CXV.update_state(self.s, lambda st, d: st.__setitem__(
            "offline", {"c%d" % self.c1.id: {"since": 1.0}}), at(2026, 11, 3, 2, 0))
        self.pushes.clear()
        self.assertEqual(A.run_watchman(self.s, at(2026, 11, 3, 2, 1)), "unknown")
        self.assertEqual(self.shop_pushes(), [])
        # at most 3 alerts a night
        CXV.update_state(self.s, lambda st, d: st.__setitem__("offline", {}), at(2026, 11, 3, 3, 0))
        for h in (3, 4, 5):
            A.run_watchman(self.s, at(2026, 11, 3, h, 1))
        self.assertEqual(NotifEvent.objects.filter(meta__notice="watchman_missing",
                                                   user=self.owner).count(), 3)

    def test_morning_summary_once_with_health(self):
        from core import cctv_activity as A
        from core.models import NotifEvent
        y = at(2026, 11, 2, 10, 0)
        self.obs(self.c1, "person_detected", y)
        self.event("person_detected", y)
        self.s.refresh_from_db()
        self.assertFalse(A.run_brief(self.s, at(2026, 11, 3, 7, 59)))     # before 08:00
        self.assertTrue(A.run_brief(self.s, at(2026, 11, 3, 8, 0)))
        self.s.refresh_from_db()
        self.assertFalse(A.run_brief(self.s, at(2026, 11, 3, 9, 0)))      # once a day
        n = NotifEvent.objects.filter(meta__notice="daily_brief", user=self.owner).get()
        self.assertIn("কালকের সারাংশ", n.title_bn)
        self.assertIn("আগন্তুক: ১জন (আনুমানিক)", n.body_bn)
        self.assertIn("সতর্কতা: ১টি", n.body_bn)
        self.assertIn("Gate:", n.body_en)
        self.assertIn("শেষ ছবি ১০:০০", n.body_bn)

    def test_visitor_log_search_and_template_label(self):
        today = timezone.localtime(timezone.now()).date()
        t = lambda h, m=0: timezone.make_aware(datetime(today.year, today.month, today.day, h, m))
        self.event("person_detected", t(0, 5), zone="গেট")
        self.event("line_crossing", t(0, 30), cam=self.c2)
        self.event("void_spike", t(0, 40))                          # not a visitor
        r = self.client.get(self.base + "/visitors", HTTP_ACCEPT_LANGUAGE="bn")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(len(r.data["rows"]), 2)
        self.assertTrue(all(x["desc_src"] == "template" for x in r.data["rows"]))
        self.assertTrue(all(x["snapshot_url"] for x in r.data["rows"]))
        self.assertIn("মুখ চেনা হয় না", r.data["label"])
        r = self.client.get(self.base + "/visitors", {"q": "গেট"})
        self.assertEqual([x["type"] for x in r.data["rows"]], ["person_detected"])
        r = self.client.get(self.base + "/visitors", {"q": "counter"})
        self.assertEqual([x["type"] for x in r.data["rows"]], ["line_crossing"])
        r = self.client.get(self.base + "/visitors", {"from": "00:20", "to": "00:59"})
        self.assertEqual([x["type"] for x in r.data["rows"]], ["line_crossing"])
        self.assertEqual(self.client.get(self.base + "/visitors", {"date": "2099-01-01"}).status_code, 400)

    def test_ai_description_only_with_key_and_inside_cap(self):
        from core import cctv_activity as A
        ev = self.event("person_detected", timezone.now() - timedelta(minutes=5))
        # no key -> nothing called
        with mock.patch("core.vision_providers.ask") as ask:
            self.assertEqual(A.describe_due()["ai"], 0)
            ask.assert_not_called()
        reply = "একজন মানুষ নীল শার্ট পরে গেটে দাঁড়িয়ে || A person in a blue shirt at the gate"
        with mock.patch("core.chat_vision_service._active",
                        return_value=("vision_claude", {"api_key": "x"}, 0.002)), \
                mock.patch("core.vision_providers.ask", return_value=reply) as ask:
            self.assertEqual(A.describe_due()["ai"], 1)
            self.assertIn("NEVER identify", ask.call_args.kwargs["system"])
            self.assertEqual(A.describe_due()["ai"], 0)                  # already described
        ev.refresh_from_db()
        self.assertEqual(ev.signals["desc"]["src"], "ai")
        r = self.client.get(self.base + "/visitors", {"q": "blue shirt"})
        self.assertEqual([x["id"] for x in r.data["rows"]], [ev.id])
        self.s.refresh_from_db()
        self.assertEqual(self.s.guard["_activity"]["ai"]["used"], 1)
        # cap reached -> no paid call, template stays
        ev2 = self.event("person_detected", timezone.now() - timedelta(minutes=2))
        with mock.patch("core.chat_vision_service._active",
                        return_value=("vision_claude", {"api_key": "x"}, 0.002)), \
                mock.patch("core.cctv_activity.ai_per_camera", return_value=0), \
                mock.patch("core.vision_providers.ask", return_value=reply) as ask:
            self.assertEqual(A.describe_due()["ai"], 0)
            ask.assert_not_called()
        ev2.refresh_from_db()
        self.assertNotIn("desc", ev2.signals)

    def test_timelapse_frames_from_stored_photos(self):
        today = timezone.localtime(timezone.now()).date()
        t = lambda h, m=0: timezone.make_aware(datetime(today.year, today.month, today.day, h, m))
        for i in range(5):
            self.event("motion", t(0, i * 5))
        self.event("motion", t(0, 40), photo=False)
        r = self.client.get(self.base + "/timelapse")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(len(r.data["frames"]), 5)
        self.assertFalse(r.data["server_video"])
        self.assertEqual(r.data["plan"]["frames"], 5)
        times = [f["time"] for f in r.data["frames"]]
        self.assertEqual(times, sorted(times))
        r = self.client.get(self.base + "/timelapse", {"camera": self.c2.id})
        self.assertEqual(r.data["frames"], [])

    def test_feature_switch_off_blocks(self):
        from core import feature_flags as FF
        from core.models import FeatureFlag
        FeatureFlag.objects.filter(key__in=("home_watchman", "cctv_watchman")).update(
            enabled_all=False, enabled_play=False)
        FF.invalidate()
        self.assertEqual(self.client.get(self.base + "/activity").status_code, 403)
        self.assertEqual(self.client.get(self.base + "/visitors").status_code, 403)
