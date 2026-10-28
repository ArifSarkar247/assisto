"""cctvx — CCTV extras (owner order 28 Oct, "beat every CCTV app").

Pure rules first (settings bounds, never-accusing wording, no-sale window,
offline transitions, open/late, siren routes, caps inside the 40 % rule,
placement statistics, report, GD draft, privacy kit), then the API on the
real views: no-sale drawer open (alerted / cleared by a sale / cleared by a
khata entry / off), escalation chain, offline + recovery (quiet hours vs
away), shop opened / late opening, siren (Imou cloud mocked, Hikvision LAN
task, EZVIZ honest no), clip sharing re-wrapped for a Circle member (real
X25519 crypto, the same 24 h / viewed delete), evidence facts + GD draft,
placement helper, privacy kit, the nightly guard report in the evening brief,
the minute job.
"""
import base64
import json
import os
import sys
from datetime import datetime, timedelta, timezone as dtz
from unittest import mock

from django.core.files.base import ContentFile
from django.core.management import call_command
from django.test import SimpleTestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient

from core.logic import cash_guard as CG
from core.logic import cctv_extras as CX
from core.models import User
from core.tests_cashguard import _Base, _MEDIA, _jpeg, _vector, ROOT

EDGE = os.path.join(ROOT, "edge", "shopbox")


def _edge_clip():
    if EDGE not in sys.path:
        sys.path.insert(0, EDGE)
    from shopbox import clip as EC
    return EC


def _keypair():
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
    k = X25519PrivateKey.generate()
    priv = k.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
                           serialization.NoEncryption())
    pub = k.public_key().public_bytes(serialization.Encoding.Raw,
                                      serialization.PublicFormat.Raw)
    return priv, pub


# ============================================================ pure
class SettingsTests(SimpleTestCase):
    def test_defaults_and_server_bounds(self):
        s = CX.settings_of({})
        self.assertEqual((s["nosale_min"], s["escalate_min"], s["offline_min"]), (2, 2, 10))
        self.assertTrue(s["nosale_on"] and s["offline_on"] and s["late_on"])
        s = CX.settings_of({"nosale_min": 99, "offline_min": 1, "late_min": "x",
                            "escalate_min": True})
        self.assertEqual((s["nosale_min"], s["offline_min"], s["late_min"],
                          s["escalate_min"]), (10, 5, 30, 2))
        self.assertEqual(CX.settings_of({"nosale_min": 0})["nosale_min"], 1)

    def test_apply_settings_validates(self):
        g = CX.apply_settings({"_state": {"x": 1}}, {"nosale_min": 4, "escalation": [5, 5, 6],
                                                      "shop_phone": "017-1234 5678",
                                                      "closed_days": [4, 4]}, {5, 6})
        self.assertEqual((g["nosale_min"], g["escalation"], g["shop_phone"], g["closed_days"]),
                         (4, [5, 6], "01712345678", [4]))
        self.assertEqual(g["_state"], {"x": 1})            # server state untouched
        for body, code in (({"escalation": [9]}, "not_in_circle"),
                           ({"escalation": [1, 2, 3, 4]}, "chain_too_long"),
                           ({"escalation": "x"}, "bad_escalation"),
                           ({"shop_phone": "call me"}, "bad_phone"),
                           ({"closed_days": [9]}, "bad_days")):
            with self.assertRaises(CX.SettingsError) as cm:
                CX.apply_settings({}, body, {1, 2, 3, 4})
            self.assertEqual(cm.exception.code, code)
        self.assertEqual(CX.clean_phone("999"), "999")
        self.assertEqual(CX.clean_phone("+8801712345678"), "+8801712345678")


class WordingTests(SimpleTestCase):
    def test_nothing_we_emit_accuses_anyone(self):
        for t in CX.all_strings():
            self.assertFalse(CG.accuses(t), t)

    def test_no_sale_title_says_the_owner_decides(self):
        self.assertEqual(CX.nosale_title("bn"),
                         "বিক্রি ছাড়া ড্রয়ার খোলা — ক্লিপ দেখে আপনি সিদ্ধান্ত নিন")
        self.assertEqual(CX.nosale_title("en"),
                         "Drawer opened with no sale — watch the clip and decide")
        self.assertTrue(CX.nosale_title("en", away=True).startswith("You are away — "))
        self.assertIn("২", CX.nosale_body("bn", 2, 70))          # Bangla digits

    def test_offline_text(self):
        t, b = CX.offline_text("bn", "gateway", "", 10)
        self.assertIn("বিদ্যুৎ বা ইন্টারনেট বন্ধ হতে পারে", t)
        self.assertIn("১০", b)
        t, _ = CX.offline_text("en", "camera", "Till", 10)
        self.assertIn("power or internet may be cut", t)


class NoSaleRuleTests(SimpleTestCase):
    def test_window_and_clear(self):
        w = CX.nosale_window(1000, 1030, 120)
        self.assertEqual(w, (880, 1150))
        self.assertTrue(CX.nosale_cleared(w, [1100]))
        self.assertFalse(CX.nosale_cleared(w, [700, 1200]))
        s = CX.settings_of({})
        self.assertTrue(CX.nosale_applies("hand_in_cash_zone", s, True))
        self.assertFalse(CX.nosale_applies("hand_in_cash_zone", s, False))
        self.assertFalse(CX.nosale_applies("person_detected", s, True))
        self.assertFalse(CX.nosale_applies("drawer_open", dict(s, nosale_on=False), True))
        self.assertEqual(CX.nosale_tip(3, 2), "raise_window")
        self.assertIsNone(CX.nosale_tip(3, 10))


class OfflineRuleTests(SimpleTestCase):
    def test_one_alert_per_outage_then_recovery(self):
        ents = [{"key": "g", "kind": "gateway", "name": "", "last_ts": 0},
                {"key": "c1", "kind": "camera", "name": "Till", "last_ts": None}]
        st, went, back = CX.offline_transitions(ents, 599, {}, 600)
        self.assertEqual((st, went, back), ({}, [], []))
        st, went, back = CX.offline_transitions(ents, 600, {}, 600)
        self.assertEqual([e["key"] for e in went], ["g"])
        st2, went, back = CX.offline_transitions(ents, 900, st, 600)
        self.assertEqual(went, [])                              # no repeat
        ents[0]["last_ts"] = 1500
        st3, went, back = CX.offline_transitions(ents, 1510, st2, 600)
        self.assertEqual(st3, {})
        self.assertEqual(back[0][0]["key"], "g")
        self.assertEqual(back[0][1], 25)                        # 1500 s silent
        self.assertEqual(CX.offline_minutes_today([(0, 600), (900, None)], 300, 1500), 15)


class OpenCloseRuleTests(SimpleTestCase):
    H = {"open": "09:00", "close": "21:00"}

    def test_open_notice_and_late(self):
        s = CX.settings_of({})
        self.assertFalse(CX.open_notice_due(self.H, 8 * 60, 2, s, {}))
        self.assertTrue(CX.open_notice_due(self.H, 9 * 60 + 5, 2, s, {}))
        self.assertFalse(CX.open_notice_due(self.H, 9 * 60 + 5, 2, s, {"opened_at": "09:01"}))
        self.assertFalse(CX.open_notice_due(self.H, 9 * 60 + 5, 4, dict(s, closed_days=[4]), {}))
        self.assertFalse(CX.open_notice_due({"open": "00:00", "close": "00:00"}, 600, 2, s, {}))
        self.assertFalse(CX.late_due(self.H, 9 * 60 + 29, 2, s, {}, True))
        self.assertTrue(CX.late_due(self.H, 9 * 60 + 30, 2, s, {}, True))
        self.assertFalse(CX.late_due(self.H, 9 * 60 + 30, 2, s, {}, False))   # offline: not "late"
        self.assertFalse(CX.late_due(self.H, 9 * 60 + 40, 2, s, {"late_sent": True}, True))
        self.assertTrue(CX.is_open_now({"open": "20:00", "close": "02:00"}, 60))


class SirenRouteTests(SimpleTestCase):
    def test_only_documented_apis(self):
        self.assertEqual(CX.siren_route("imou", "DEV:0", "", False), ("imou_cloud", ""))
        self.assertEqual(CX.siren_route("imou", "", "", False)[1], "imou_not_linked")
        self.assertEqual(CX.siren_route("hikvision", "", "pc", True), ("hik_lan", ""))
        self.assertEqual(CX.siren_route("hikvision", "", "phone", True)[1], "hik_needs_gateway")
        self.assertEqual(CX.siren_route("ezviz", "EZ:A:1", "", False), (None, "ezviz_no_api"))
        self.assertEqual(CX.siren_route("tapo", "", "pc", True), (None, "vendor_no_api"))


class CapsCostTests(SimpleTestCase):
    def test_every_tier_inside_the_40_percent_rule(self):
        for tier in CG.TIERS:
            caps = CG.caps_for(tier, {})
            extra = CX.extra_caps(tier)
            self.assertTrue(CX.inside_40_rule(tier, caps, extra), tier)
            for k in ("offline_day", "escalations_day", "sirens_day", "notices_day"):
                self.assertGreaterEqual(extra[k], 0)
        # nothing is unlimited: admin knobs are clamped
        self.assertEqual(CX.extra_caps("business", {"cctvx_business_escalations_day": 10 ** 6})
                         ["escalations_day"], 100)
        self.assertEqual(CX.extra_caps("nope")["tier"], "free")

    def test_premium_worst_case_numbers(self):
        caps = CG.caps_for("premium", {})
        extra = CX.extra_caps("premium")
        total = CG.monthly_cost_bdt(caps) + CX.extras_monthly_cost_bdt(caps, extra)
        self.assertLessEqual(total, CG.HEADROOM_BDT["premium"])
        self.assertGreater(CX.extras_monthly_cost_bdt(caps, extra), 0)


class PlacementRuleTests(SimpleTestCase):
    def test_tips(self):
        good = {"zone_mean": 120, "zone_std": 40, "zone_dark": 0.02, "zone_bright": 0.01,
                "zone_area": 0.15, "zone_margin": 0.1, "zone_edges": 0.1}
        r = CX.placement_report(good, "bn")
        self.assertTrue(r["ok"])
        self.assertEqual(r["score"], 100)
        dark = dict(good, zone_mean=20, zone_dark=0.8)
        r = CX.placement_report(dark, "bn")
        self.assertFalse(r["ok"])
        self.assertIn("অন্ধকার", " ".join(r["tips"]))
        r = CX.placement_report(dict(good, zone_area=0.9, zone_margin=0.0), "en")
        keys = {c["key"] for c in r["checks"] if not c["ok"]}
        self.assertEqual(keys, {"size_large", "edge"})
        self.assertFalse(CX.placement_report({}, "en")["ok"])


class TextsTests(SimpleTestCase):
    def test_report_gd_and_privacy_kit(self):
        lines = CX.report_lines({"drawer_nosale": 1, "drawer_sale": 4})
        self.assertIn("বিক্রিসহ ৪বার, বিক্রি ছাড়া ১বার", lines[0]["bn"])
        gd = CX.gd_draft("bn", {"event_id": 12, "files": 3, "manifest_sha256": "ab" * 32})
        self.assertIn("SHA-256", gd)
        self.assertIn("ab" * 32, gd)
        self.assertFalse(CG.accuses(gd))
        kit = CX.privacy_kit("রহিম স্টোর", 7)
        self.assertEqual(kit["sticker"]["en"][0], "CCTV in operation")
        self.assertIn("২৪ ঘণ্টা", kit["staff_notice"]["bn"])
        self.assertIn("No sound recording", " ".join(kit["sticker"]["en"]))
        self.assertFalse(kit["legal_note"])
        for t in kit["sticker"]["en"] + [kit["staff_notice"]["en"]]:
            self.assertNotIn("law", t.lower())


# ============================================================ API
@override_settings(MEDIA_ROOT=_MEDIA)
class _X(_Base):
    def setUp(self):
        super().setUp()
        from core.models import CircleMember, ShopSite
        self.mgr = User.objects.create_user(name="Manager", phone="01710004001", password="pw")
        self.mgr.language = "bn"
        self.mgr.save()
        CircleMember.objects.create(user=self.owner, peer_user=self.mgr, state="accepted",
                                    name="Manager", relation="friend")
        self.sobj = ShopSite.objects.get(pk=self.site["id"])
        self.m = APIClient()
        self.m.force_authenticate(self.mgr)

    def records(self):
        """The shop records its sales in Assisto (a sale 3 days ago)."""
        from core.models import ShopPosEvent
        ShopPosEvent.objects.create(site_id=self.site["id"], kind="sale", amount=100,
                                    at=timezone.now() - timedelta(days=3))

    def guard(self, **body):
        r = self.client.put("/api/v1/shop/sites/%d/guard" % self.site["id"], body,
                            format="json")
        self.assertEqual(r.status_code, 200, r.data)
        return r.data

    def tick(self, minutes=0, **kw):
        from core import cctvx_views as CXV
        return CXV.tick(timezone.now() + timedelta(minutes=minutes, **kw))

    def texts(self):
        return [" ".join(str(x) for x in a[2:6]) for a, k in self.pushes]


class NoSaleTests(_X):
    def test_no_sale_drawer_alert_after_the_window(self):
        from core.models import ShopEvent, ShopGuardTask
        self.records()
        r = self.ingest(ref="ab" * 16)
        self.assertEqual(r.status_code, 201, r.data)
        self.assertTrue(r.data["clip_wanted"])              # the edge still cuts the clip
        ev = ShopEvent.objects.get(pk=r.data["event_id"])
        self.assertTrue(ev.pending)
        self.assertEqual(self.pushes, [])                   # nothing yet
        self.assertEqual(self.client.get("/api/v1/shop/events?site=%d" % self.site["id"])
                         .data["events"], [])
        self.assertEqual(ShopGuardTask.objects.get().kind, "nosale")
        self.tick(minutes=1)
        self.assertEqual(self.pushes, [])                   # window not over
        self.tick(minutes=3)
        ev.refresh_from_db()
        self.assertFalse(ev.pending)
        self.assertEqual(ev.signals["nosale"]["window_min"], 2)
        a, k = self.pushes[0]
        self.assertTrue(a[3].startswith("Drawer opened with no sale — watch the clip and decide"))
        self.assertTrue(a[2].startswith("বিক্রি ছাড়া ড্রয়ার খোলা — ক্লিপ দেখে আপনি সিদ্ধান্ত নিন"))
        self.assertTrue(k["data"]["nosale"])
        self.assertFalse(any(CG.accuses(t) for t in self.texts()))
        row = self.client.get("/api/v1/shop/events?site=%d" % self.site["id"]).data["events"][0]
        self.assertTrue(row["nosale"])
        # the report counts it
        rep = self.client.get("/api/v1/shop/sites/%d/guard/report" % self.site["id"])
        self.assertEqual(rep.data["counts"]["drawer_nosale"], 1)
        self.assertEqual(rep.data["credits"], 0)

    def test_a_sale_in_the_window_clears_and_deletes_the_touch(self):
        from core.models import ShopEvent, ShopPosEvent
        self.records()
        r = self.ingest()
        ShopPosEvent.objects.create(site_id=self.site["id"], kind="sale", amount=5000,
                                    at=timezone.now() + timedelta(seconds=70))
        self.tick(minutes=3)
        self.assertFalse(ShopEvent.objects.filter(pk=r.data["event_id"]).exists())
        self.assertEqual(self.pushes, [])
        rep = self.client.get("/api/v1/shop/sites/%d/guard/report" % self.site["id"])
        self.assertEqual(rep.data["counts"]["drawer_sale"], 1)

    def test_a_khata_entry_clears_it_too(self):
        from core.models import BusinessProfile, KhataEntry, KhataParty, ShopEvent
        biz = BusinessProfile.objects.create(user=self.owner, shop_name="Rahim Store")
        party = KhataParty.objects.create(business=biz, book="customer", name="Karim")
        KhataEntry.objects.create(party=party, direction="gave", amount_poisha=10000,
                                  at=timezone.now())        # also makes "uses records"
        r = self.ingest()
        self.assertTrue(ShopEvent.objects.get(pk=r.data["event_id"]).pending)
        self.tick(minutes=3)
        self.assertFalse(ShopEvent.objects.filter(pk=r.data["event_id"]).exists())

    def test_repeat_touches_are_one_episode(self):
        from core.models import ShopEvent, ShopGuardTask
        self.records()
        r1 = self.ingest()
        r2 = self.ingest()
        self.assertEqual(r1.data["event_id"], r2.data["event_id"])
        self.assertEqual(ShopEvent.objects.get().count, 2)
        self.assertEqual(ShopGuardTask.objects.count(), 1)

    def test_off_or_no_records_means_the_immediate_cash_alert(self):
        r = self.ingest()                                   # no records at all
        self.assertTrue(self.pushes[0][0][3].startswith("Possible cash removal"))
        from core.models import ShopEvent
        ShopEvent.objects.update(status="checked")
        self.records()
        self.guard(nosale_on=False)
        self.ingest()
        self.assertEqual(len(self.pushes), 2)
        self.assertFalse(ShopEvent.objects.filter(pending=True).exists())
        self.assertNotEqual(r.data["event_id"], None)

    def test_owner_tunes_the_window_inside_bounds(self):
        d = self.guard(nosale_min=99)
        self.assertEqual(d["settings"]["nosale_min"], 10)
        self.assertEqual(d["bounds"]["nosale_min"], [1, 10])
        d = self.guard(nosale_min=5)
        self.records()
        self.ingest()
        self.tick(minutes=3)
        self.assertEqual(self.pushes, [])                   # 5 min window
        self.tick(minutes=6)
        self.assertEqual(len(self.pushes), 1)

    def test_wrong_answers_suggest_a_wider_window_never_change_it(self):
        from core.models import ShopEvent
        self.records()
        for i in range(3):
            ShopEvent.objects.update(status="checked")
            r = self.ingest()
            self.tick(minutes=3 + i * 4)
            self.client.post("/api/v1/shop/events/%d/mark" % r.data["event_id"],
                             {"status": "wrong"}, format="json")
        d = self.client.get("/api/v1/shop/sites/%d/guard" % self.site["id"]).data
        self.assertEqual(d["tip"], "raise_window")
        self.assertEqual(d["settings"]["nosale_min"], 2)


class EscalationTests(_X):
    def test_chain_only_from_the_circle(self):
        bad = self.client.put("/api/v1/shop/sites/%d/guard" % self.site["id"],
                              {"escalation": [self.family.id]}, format="json")
        self.assertEqual((bad.status_code, bad.data["error"]), (422, "not_in_circle"))
        d = self.guard(escalation=[self.mgr.id])
        self.assertEqual(d["settings"]["escalation"], [self.mgr.id])
        self.assertEqual([p["uid"] for p in d["circle"]], [self.mgr.id])

    def test_unopened_alert_goes_to_the_manager_then_stops_when_opened(self):
        from core.models import ShopEvent, ShopGuardTask
        self.guard(escalation=[self.mgr.id])
        r = self.ingest()                                   # immediate cash alert
        ev_id = r.data["event_id"]
        self.assertEqual(ShopGuardTask.objects.get().kind, "escalate")
        self.assertEqual(self.m.get("/api/v1/shop/events/%d" % ev_id).status_code, 404)
        self.tick(minutes=1)
        self.assertEqual(len(self.pushes), 1)               # not yet
        self.tick(minutes=3)
        a, k = self.pushes[-1]
        self.assertEqual(a[0].pk, self.mgr.pk)
        self.assertIn("এখনো দেখেননি", a[2])
        self.assertTrue(k["high_priority"])
        self.assertTrue(k["data"]["escalated"])
        d = self.m.get("/api/v1/shop/events/%d" % ev_id)
        self.assertEqual((d.status_code, d.data["role"]), (200, "escalated"))
        self.assertTrue(d.data["actions"]["siren"]["allowed"])
        self.assertFalse(d.data["actions"]["share_clip"])
        o = self.m.post("/api/v1/shop/events/%d/opened" % ev_id, {}, format="json")
        self.assertTrue(o.data["opened_at"])
        self.assertTrue(ShopEvent.objects.get(pk=ev_id).opened_at)
        log = ShopGuardTask.objects.get().state["log"]
        self.assertTrue(any(x.get("sent") for x in log))
        self.assertTrue(any(x.get("opened_by") == self.mgr.pk for x in log))

    def test_owner_opening_the_list_stops_it(self):
        self.guard(escalation=[self.mgr.id])
        self.ingest()
        self.client.get("/api/v1/shop/events?site=%d" % self.site["id"])
        self.tick(minutes=3)
        self.assertEqual([a[0].pk for a, k in self.pushes], [self.owner.pk])

    def test_escalations_are_capped(self):
        from core.models import ShopEvent
        self.guard(escalation=[self.mgr.id])
        for i in range(4):
            ShopEvent.objects.update(status="checked")
            self.ingest()
        ShopEvent.objects.update(status="open")
        self.tick(minutes=3)
        sent = [a for a, k in self.pushes if a[0].pk == self.mgr.pk]
        self.assertEqual(len(sent), CX.extra_caps("free")["escalations_day"])


class OfflineTests(_X):
    def test_gateway_silent_alert_once_then_recovered(self):
        from core.models import ShopSite
        ShopSite.objects.filter(pk=self.site["id"]).update(
            last_seen=timezone.now() - timedelta(minutes=11))
        self.tick()
        off = [(a, k) for a, k in self.pushes if k["data"].get("notice") == "offline"]
        self.assertEqual(len(off), 1)
        self.assertIn("বিদ্যুৎ বা ইন্টারনেট বন্ধ হতে পারে", off[0][0][2])
        self.assertTrue(off[0][1]["high_priority"])
        self.tick(minutes=1)
        self.assertEqual(len([1 for a, k in self.pushes if k["data"].get("notice") == "offline"]), 1)
        ShopSite.objects.filter(pk=self.site["id"]).update(last_seen=timezone.now())
        self.tick(minutes=1)
        back = [a for a, k in self.pushes if k["data"].get("notice") == "recovered"]
        self.assertEqual(len(back), 1)
        rep = self.client.get("/api/v1/shop/sites/%d/guard/report" % self.site["id"])
        self.assertGreaterEqual(rep.data["counts"]["offline_min"], 10)

    def test_quiet_hours_saved_not_pushed_unless_away(self):
        from core.models import FamilyAlert, ShopSite
        now = timezone.localtime()
        quiet = {"start": (now - timedelta(hours=1)).strftime("%H:%M"),
                 "end": (now + timedelta(hours=1)).strftime("%H:%M")}
        self.client.put("/api/v1/shop/cameras/%d/zones" % self.cam["id"],
                        {"zone_config": {"zones": [], "schedule": None,
                                         "sensitivity": "medium", "quiet_hours": quiet}},
                        format="json")
        ShopSite.objects.filter(pk=self.site["id"]).update(
            last_seen=timezone.now() - timedelta(minutes=11))
        self.tick()
        self.assertEqual([k for a, k in self.pushes if k["data"].get("notice") == "offline"], [])
        self.assertTrue(FamilyAlert.objects.filter(user=self.owner,
                                                   payload__notice="offline").exists())
        # away mode: quiet hours are ignored
        self.client.put("/api/v1/shop/sites/%d/away" % self.site["id"], {"on": True, "hours": 2},
                        format="json")
        ShopSite.objects.filter(pk=self.site["id"]).update(
            last_seen=timezone.now(), guard={})
        ShopSite.objects.filter(pk=self.site["id"]).update(
            last_seen=timezone.now() - timedelta(minutes=12))
        self.tick()
        self.assertEqual(len([k for a, k in self.pushes if k["data"].get("notice") == "offline"]), 1)

    def test_offline_switch_and_camera_stream(self):
        from core.models import ShopCamera, ShopSite
        self.guard(offline_on=False)
        ShopSite.objects.filter(pk=self.site["id"]).update(
            last_seen=timezone.now() - timedelta(minutes=30))
        self.tick()
        self.assertEqual(self.pushes, [])
        self.guard(offline_on=True)
        ShopSite.objects.filter(pk=self.site["id"]).update(last_seen=timezone.now())
        ShopCamera.objects.filter(pk=self.cam["id"]).update(
            last_seen=timezone.now() - timedelta(minutes=15))
        self.tick()
        off = [a for a, k in self.pushes if k["data"].get("notice") == "offline"]
        self.assertEqual(len(off), 1)
        self.assertIn("Till", off[0][3])

    def test_heartbeat_live_ids_and_motion(self):
        from core.models import ShopCamera, ShopSite
        site = ShopSite.objects.get(pk=self.site["id"])
        dev = APIClient()
        old = timezone.now() - timedelta(minutes=30)
        ShopCamera.objects.filter(pk=self.cam["id"]).update(last_seen=old)
        with mock.patch("core.cctvx_views.note_motion") as nm:
            r = dev.post("/api/v1/shop/heartbeat",
                         {"site_token": site.enrollment_token, "camera_ids": [self.cam["id"]],
                          "live_ids": [], "motion_at": timezone.now().timestamp()},
                         format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(ShopCamera.objects.get(pk=self.cam["id"]).last_seen, old)
        self.assertEqual(nm.call_count, 1)
        dev.post("/api/v1/shop/heartbeat",
                 {"site_token": site.enrollment_token, "camera_ids": [self.cam["id"]],
                  "live_ids": [self.cam["id"]]}, format="json")
        self.assertGreater(ShopCamera.objects.get(pk=self.cam["id"]).last_seen, old)


class OpenLateTests(_X):
    def _hours(self):
        from core.models import ShopSite
        ShopSite.objects.filter(pk=self.site["id"]).update(
            hours={"open": "09:00", "close": "21:00"})
        self.sobj.refresh_from_db()

    def _at(self, hh, mm):
        local = timezone.localtime().replace(hour=hh, minute=mm, second=0, microsecond=0)
        return local

    def test_first_movement_after_opening_time(self):
        from core import cctvx_views as CXV
        self._hours()
        at = self._at(9, 7)
        self.assertFalse(CXV.note_motion(self.sobj, self._at(8, 50), self._at(8, 50)))
        self.assertTrue(CXV.note_motion(self.sobj, at, at))
        self.sobj.refresh_from_db()
        self.assertFalse(CXV.note_motion(self.sobj, self._at(10, 0), self._at(10, 0)))
        opened = [a for a, k in self.pushes if k["data"].get("notice") == "opened"]
        self.assertEqual(len(opened), 1)
        self.assertIn("০৯:০৭", opened[0][4])
        self.assertEqual(CXV.report_counts(self.sobj, self._at(20, 0))["opened_at"], "09:07")

    def test_late_opening_once(self):
        from core import cctvx_views as CXV
        from core.models import ShopSite
        self._hours()
        ShopSite.objects.filter(pk=self.site["id"]).update(last_seen=self._at(9, 40))
        self.sobj.refresh_from_db()
        self.assertFalse(CXV.run_late(self.sobj, self._at(9, 20)))
        self.assertTrue(CXV.run_late(self.sobj, self._at(9, 40)))
        self.sobj.refresh_from_db()
        self.assertFalse(CXV.run_late(self.sobj, self._at(9, 41)))
        late = [a for a, k in self.pushes if k["data"].get("notice") == "late"]
        self.assertEqual(len(late), 1)
        self.assertIn("এখনো খোলেনি", late[0][2])

    def test_closed_day_no_late(self):
        from core import cctvx_views as CXV
        from core.models import ShopSite
        self._hours()
        at = self._at(9, 40)
        self.guard(closed_days=[at.weekday()])
        self.sobj.refresh_from_db()
        ShopSite.objects.filter(pk=self.site["id"]).update(last_seen=at)
        self.sobj.refresh_from_db()
        self.assertFalse(CXV.run_late(self.sobj, at))


class SirenTests(_X):
    def _imou_cam(self):
        from core.models import ShopCamera
        r = self.client.post("/api/v1/shop/sites/%d/cameras" % self.site["id"],
                             {"name": "Door", "kind": "shopbox", "vendor": "imou"},
                             format="json")
        ShopCamera.objects.filter(pk=r.data["id"]).update(vendor_ref="6E0ABC:0")
        return ShopCamera.objects.get(pk=r.data["id"])

    def test_imou_siren_on_then_off(self):
        cam = self._imou_cam()
        r = self.ingest()
        ev = r.data["event_id"]
        calls = []
        from core.logic import imou as IM

        def http(url, body, timeout):
            calls.append((url.rsplit("/", 1)[1], json.loads(body)["params"]))
            if url.endswith("accessToken"):
                return 200, json.dumps({"result": {"code": "0", "data": {
                    "accessToken": "T", "expireTime": 3600}}})
            return 200, json.dumps({"result": {"code": "0", "data": {}}})
        IM._token_cache.clear()
        client = IM.ImouClient("APP", "SEC", http=http)
        with mock.patch("core.watchman_views.imou_cloud_on", return_value=True), \
                mock.patch("core.logic.imou.ImouClient.from_integration", return_value=client):
            s = self.client.post("/api/v1/shop/events/%d/siren" % ev,
                                 {"camera_id": cam.id, "seconds": 10}, format="json")
            self.assertEqual(s.status_code, 200, s.data)
            self.assertEqual((s.data["route"], s.data["status"]), ("imou_cloud", "sounding"))
            on = [p for m, p in calls if m == "setDeviceCameraStatus"]
            self.assertEqual((on[0]["enableType"], on[0]["enable"], on[0]["deviceId"]),
                             ("siren", True, "6E0ABC"))
            again = self.client.post("/api/v1/shop/events/%d/siren" % ev,
                                     {"camera_id": cam.id}, format="json")
            self.assertEqual(again.status_code, 429)
            self.tick(seconds=15)
            off = [p for m, p in calls if m == "setDeviceCameraStatus"]
            self.assertEqual(off[-1]["enable"], False)

    def test_ezviz_and_unknown_are_honest(self):
        r = self.client.post("/api/v1/shop/sites/%d/cameras" % self.site["id"],
                             {"name": "Ez", "kind": "shopbox", "vendor": "ezviz"}, format="json")
        ev = self.ingest().data["event_id"]
        s = self.client.post("/api/v1/shop/events/%d/siren" % ev, {"camera_id": r.data["id"]},
                             format="json")
        self.assertEqual((s.status_code, s.data["reason"]), (409, "ezviz_no_api"))
        s = self.client.post("/api/v1/shop/events/%d/siren" % ev, {}, format="json")
        self.assertEqual((s.status_code, s.data["reason"]), (409, "vendor_no_api"))   # onvif

    def test_hikvision_lan_task_and_result(self):
        from core.models import ShopGatewayTask, ShopSite
        r = self.client.post("/api/v1/shop/sites/%d/cameras" % self.site["id"],
                             {"name": "Hik", "kind": "shopbox", "vendor": "hikvision",
                              "source": {"host": "192.168.1.64", "http_port": 8080}},
                             format="json")
        ev = self.ingest().data["event_id"]
        s = self.client.post("/api/v1/shop/events/%d/siren" % ev, {"camera_id": r.data["id"]},
                             format="json")
        self.assertEqual(s.status_code, 202, s.data)
        t = ShopGatewayTask.objects.get(pk=s.data["task_id"])
        self.assertEqual((t.action, t.request["host"], t.request["http_port"]),
                         ("siren", "192.168.1.64", 8080))
        self.assertNotIn("secret", t.request)
        gw = APIClient()
        tok = ShopSite.objects.get(pk=self.site["id"]).enrollment_token
        gw.credentials(HTTP_X_SHOP_TOKEN=tok)
        got = gw.get("/api/v1/shop/gateway/tasks").data["tasks"]
        self.assertEqual(got[0]["action"], "siren")
        res = gw.post("/api/v1/shop/gateway/tasks/%d/result" % t.id,
                      {"result": json.dumps({"ok": True, "code": "ok",
                                             "method": "audio_alarm", "seconds": 15})},
                      format="multipart")
        self.assertEqual(res.status_code, 200, res.data)
        t.refresh_from_db()
        self.assertEqual((t.status, t.result["method"]), ("done", "audio_alarm"))

    def test_viewer_cannot_sound_it(self):
        from core.models import ShopSiteViewer
        ShopSiteViewer.objects.create(site_id=self.site["id"], user=self.family)
        cam = self._imou_cam()
        ev = self.ingest().data["event_id"]
        fam = APIClient()
        fam.force_authenticate(self.family)
        s = fam.post("/api/v1/shop/events/%d/siren" % ev, {"camera_id": cam.id}, format="json")
        self.assertEqual(s.status_code, 403)


class ShareTests(_X):
    def _clip(self):
        from core.models import ShopEvent, ShopEventClip, UserPublicKey
        v = _vector()
        ev = ShopEvent.objects.get(pk=self.ingest(ref="cd" * 16).data["event_id"])
        meta = dict(v["meta"])
        meta["wraps"] = {str(self.owner.id): v["meta"]["wraps"]["7"]}
        ct = base64.b64decode(v["ciphertext"])
        c = ShopEventClip(event=ev, meta=meta, size=len(ct), sha256=v["meta"]["sha256"],
                          expires_at=timezone.now() + timedelta(hours=24))
        c.blob.save("e.bin", ContentFile(ct), save=False)
        c.save()
        priv, pub = _keypair()
        EC = _edge_clip()
        UserPublicKey.objects.create(user=self.mgr, public_key=base64.b64encode(pub).decode(),
                                     key_id=EC.key_id(pub), scheme=CG.CLIP_SCHEME)
        return ev, c, ct, priv, pub, v

    def _wrap(self, ev, priv_owner, pub_mgr):
        EC = _edge_clip()
        env = self.client.get("/api/v1/shop/events/%d/clip" % ev.id)
        if env.status_code == 200:
            meta = env.data["meta"]
        else:     # the owner already watched it: the phone kept the envelope
            meta = self._kept_meta
        return EC.rewrap_for(meta, self.owner.id, priv_owner,
                             base64.b64encode(pub_mgr).decode())

    def test_share_rewrap_member_opens_same_24h_then_deleted(self):
        ev, clip, ct, priv, pub, v = self._clip()
        t = self.client.get("/api/v1/shop/events/%d/share-targets" % ev.id)
        self.assertEqual(t.data["people"][0]["uid"], self.mgr.id)
        self.assertTrue(t.data["people"][0]["has_key"])
        w = self._wrap(ev, base64.b64decode(v["recipient_private"]), pub)
        s = self.client.post("/api/v1/shop/events/%d/clip/share" % ev.id,
                             {"uid": self.mgr.id, "wrap": w}, format="json")
        self.assertEqual(s.status_code, 201, s.data)
        clip.refresh_from_db()
        self.assertEqual(s.data["expires_at"], clip.expires_at.isoformat())   # same 24 h
        pushed = [a for a, k in self.pushes if a[0].pk == self.mgr.pk]
        self.assertIn("ক্লিপ", pushed[0][2])
        # the member opens it with THEIR private key (the server never could)
        env = self.m.get("/api/v1/shop/events/%d/clip" % ev.id)
        self.assertEqual(env.status_code, 200, env.data)
        self.assertTrue(env.data["shared"])
        self.assertEqual(env.data["meta"]["wrap"]["sender_pub"], w["sender_pub"])
        EC = _edge_clip()
        plain = EC.open_clip(ct, env.data["meta"], self.mgr.id, priv)
        import hashlib
        self.assertEqual(hashlib.sha256(plain).hexdigest(), v["plain_sha256"])
        # the member watched it -> kept for the owner; the owner watched -> gone
        path = clip.blob.path
        r = self.m.post("/api/v1/shop/events/%d/clip/viewed" % ev.id, {}, format="json")
        self.assertFalse(r.data["deleted"])
        self.assertTrue(os.path.exists(path))
        r = self.client.post("/api/v1/shop/events/%d/clip/viewed" % ev.id, {}, format="json")
        self.assertTrue(r.data["deleted"])
        self.assertFalse(os.path.exists(path))

    def test_owner_watched_first_member_still_gets_it_then_deleted(self):
        ev, clip, ct, priv, pub, v = self._clip()
        w = self._wrap(ev, base64.b64decode(v["recipient_private"]), pub)
        self.client.post("/api/v1/shop/events/%d/clip/share" % ev.id,
                         {"uid": self.mgr.id, "wrap": w}, format="json")
        r = self.client.post("/api/v1/shop/events/%d/clip/viewed" % ev.id, {}, format="json")
        self.assertEqual((r.data["deleted"], r.data["kept_for"]), (False, 1))
        r = self.m.post("/api/v1/shop/events/%d/clip/viewed" % ev.id, {}, format="json")
        self.assertTrue(r.data["deleted"])

    def test_share_after_delete_needs_the_same_ciphertext(self):
        from django.core.files.uploadedfile import SimpleUploadedFile
        ev, clip, ct, priv, pub, v = self._clip()
        self._kept_meta = self.client.get("/api/v1/shop/events/%d/clip" % ev.id).data["meta"]
        self.client.post("/api/v1/shop/events/%d/clip/viewed" % ev.id, {}, format="json")
        w = self._wrap(ev, base64.b64decode(v["recipient_private"]), pub)
        s = self.client.post("/api/v1/shop/events/%d/clip/share" % ev.id,
                             {"uid": self.mgr.id, "wrap": w}, format="json")
        self.assertEqual((s.status_code, s.data["error"]), (409, "share_need_blob"))
        bad = self.client.post("/api/v1/shop/events/%d/clip/share" % ev.id,
                               {"uid": self.mgr.id, "wrap": json.dumps(w),
                                "blob": SimpleUploadedFile("c.bin", os.urandom(len(ct)))},
                               format="multipart")
        self.assertEqual((bad.status_code, bad.data["error"]), (422, "share_bad_blob"))
        ok = self.client.post("/api/v1/shop/events/%d/clip/share" % ev.id,
                              {"uid": self.mgr.id, "wrap": json.dumps(w),
                               "blob": SimpleUploadedFile("c.bin", ct)}, format="multipart")
        self.assertEqual(ok.status_code, 201, ok.data)
        r = self.m.post("/api/v1/shop/events/%d/clip/viewed" % ev.id, {}, format="json")
        self.assertTrue(r.data["deleted"])

    def test_only_circle_people_and_caps(self):
        ev, clip, ct, priv, pub, v = self._clip()
        w = self._wrap(ev, base64.b64decode(v["recipient_private"]), pub)
        s = self.client.post("/api/v1/shop/events/%d/clip/share" % ev.id,
                             {"uid": self.family.id, "wrap": w}, format="json")
        self.assertEqual(s.status_code, 403)
        bad = dict(w, key_id="ffffff")
        s = self.client.post("/api/v1/shop/events/%d/clip/share" % ev.id,
                             {"uid": self.mgr.id, "wrap": bad}, format="json")
        self.assertEqual((s.status_code, s.data["error"]), (422, "share_bad_wrap"))
        s = self.client.post("/api/v1/shop/events/%d/clip/share" % ev.id,
                             {"uid": self.mgr.id, "wrap": w}, format="json")
        self.assertEqual(s.status_code, 201, s.data)
        self.assertEqual(self.client.get("/api/v1/shop/events/%d/share-targets" % ev.id)
                         .data["shares_left"], 0)
        # one more person per clip (inside the clip's cost budget)
        from core.models import CircleMember, UserPublicKey
        m2 = User.objects.create_user(name="Brother", phone="01710004002", password="pw")
        CircleMember.objects.create(user=self.owner, peer_user=m2, state="accepted")
        priv2, pub2 = _keypair()
        EC = _edge_clip()
        UserPublicKey.objects.create(user=m2, public_key=base64.b64encode(pub2).decode(),
                                     key_id=EC.key_id(pub2), scheme=CG.CLIP_SCHEME)
        w2 = self._wrap(ev, base64.b64decode(v["recipient_private"]), pub2)
        s = self.client.post("/api/v1/shop/events/%d/clip/share" % ev.id,
                             {"uid": m2.id, "wrap": w2}, format="json")
        self.assertEqual((s.status_code, s.data["error"]), (429, "share_cap"))
        self.assertEqual(self.m.post("/api/v1/shop/events/%d/clip/share" % ev.id,
                                     {"uid": self.mgr.id, "wrap": w}, format="json").status_code,
                         404)


class EvidencePlacementKitTests(_X):
    def test_evidence_facts_and_gd(self):
        ev = self.ingest().data["event_id"]
        r = self.client.get("/api/v1/shop/events/%d/evidence" % ev)
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data["hash"], "sha256")
        self.assertEqual(r.data["facts"]["event_id"], ev)
        self.assertFalse(CG.accuses(r.data["gd_draft"]))
        h = "ab" * 32
        p = self.client.post("/api/v1/shop/events/%d/evidence" % ev,
                             {"manifest_sha256": h, "files": 5}, format="json")
        self.assertIn(h, p.data["gd_draft"])
        self.assertEqual(self.client.post("/api/v1/shop/events/%d/evidence" % ev,
                                          {"manifest_sha256": "nope"}, format="json").status_code,
                         422)
        self.assertEqual(self.m.get("/api/v1/shop/events/%d/evidence" % ev).status_code, 404)

    def test_placement_helper_dark_vs_good(self):
        import io
        from PIL import Image, ImageDraw
        from core.models import ShopCamera
        cam = ShopCamera.objects.get(pk=self.cam["id"])
        b = io.BytesIO()
        Image.new("RGB", (640, 360), (5, 5, 5)).save(b, "JPEG")
        cam.preview.save("p.jpg", ContentFile(b.getvalue()), save=True)
        r = self.client.get("/api/v1/shop/cameras/%d/placement" % cam.id,
                            HTTP_ACCEPT_LANGUAGE="bn")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertFalse(r.data["ok"])
        self.assertEqual(r.data["credits"], 0)
        self.assertIn("light", [c["key"] for c in r.data["checks"] if not c["ok"]])
        im = Image.new("RGB", (640, 360), (140, 140, 140))
        d = ImageDraw.Draw(im)
        for x in range(0, 640, 16):
            d.line([(x, 0), (x, 360)], fill=(30, 30, 30), width=3)
        b = io.BytesIO()
        im.save(b, "JPEG")
        cam.preview.save("p2.jpg", ContentFile(b.getvalue()), save=True)
        r = self.client.get("/api/v1/shop/cameras/%d/placement" % cam.id)
        self.assertTrue(r.data["ok"], r.data)

    def test_privacy_kit(self):
        r = self.client.get("/api/v1/shop/sites/%d/privacy-kit" % self.site["id"])
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["sticker"]["bn"][0], "সিসিটিভি চালু আছে")
        self.assertIn("A5", r.data["sizes"])
        self.assertEqual(self.m.get("/api/v1/shop/sites/%d/privacy-kit" % self.site["id"])
                         .status_code, 404)


class BriefAndJobTests(_X):
    def test_evening_brief_has_the_guard_report(self):
        from core.agentcore import proactive as P
        self.records()
        self.ingest()
        self.tick(minutes=3)
        b = P.build_brief(self.owner, "brief_evening", timezone.now())
        g = [s for s in b["sections"] if s["key"] == "guard"]
        self.assertEqual(len(g), 1, b["sections"])
        self.assertIn("বিক্রি ছাড়া ১বার", g[0]["lines"][0]["bn"])
        self.assertFalse(b["ai_used"])
        m = P.build_brief(self.owner, "brief_morning", timezone.now())
        self.assertFalse([s for s in m["sections"] if s["key"] == "guard"])

    def test_minute_job_registered_and_runs(self):
        from core import ops_health as H
        self.assertIn("shop_guard_tick", H.JOB_BY_NAME)
        self.assertEqual(H.JOB_BY_NAME["shop_guard_tick"].interval, 60)
        call_command("shop_guard_tick", "--quiet")
