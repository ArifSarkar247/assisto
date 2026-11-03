"""cctvcap (owner decision 3 Nov 10:40): "0.3 GB relay and 50 AI checks per
camera per month, but SOS, alerts and evidence never stop; at the cap show a
clear Bangla notice and offer an extra pack; live view prefers P2P and LAN."

PROOF at / over BOTH caps:
  * SOS / fall live is never cut (FamilyAlertDelivery SOS, SOS-at-Home grant,
    an SOS that starts DURING a relayed live view);
  * alerts (push + photo) are still delivered, evidence pack + clip fetch work;
  * direct / same-Wi-Fi live still works — only RELAYED live pauses;
  * AI stops in every CCTV AI path through ONE shared counter (template text);
  * Bangla notices at 80 % / 100 % for relay and AI, ONE push at 100 %;
  * the one-tap extra pack (credits) re-opens the cap for this month only.
"""
import json
import os
import re
from datetime import timedelta
from unittest import mock

from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import SimpleTestCase, TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient

from core.logic import cctv_cap as C
from core.logic import cctv_plan as CP
from core.logic import cctv_traffic as T
from core.models import User
# module refs (not names): importing a TestCase class would run its tests here too
from core import tests_cashguard as CGT
from core import tests_cctvguard as G

ON = G.ON

BN_DIGITS = "০১২৩৪৫৬৭৮৯"


def _spend_ok(user, need, note="", now=None, source_type="spend", **kw):
    return {"ok": True, "reason": "ok", "charged": int(need), "balance": 500,
            "spend_ref": "sp:test%d" % int(need)}


def _spend_no(user, need, note="", now=None, source_type="spend", **kw):
    return {"ok": False, "reason": "insufficient", "charged": 0, "balance": 0,
            "spend_ref": ""}


# ================================================================ pure rules
class RuleTests(SimpleTestCase):
    def test_ai_levels(self):
        self.assertEqual(C.ai_state(0, 100)["level"], "ok")
        self.assertEqual(C.ai_state(79, 100)["level"], "ok")
        self.assertEqual(C.ai_state(80, 100)["level"], "notice")
        self.assertEqual(C.ai_state(100, 100)["level"], "full")
        self.assertEqual(C.ai_state(150, 100)["left"], 0)
        self.assertEqual(C.ai_state(0, 0)["level"], "full")       # no AI at all
        self.assertTrue(C.ai_can_take({"ai_used": 1}, 2))
        self.assertFalse(C.ai_can_take(C.ai_take({"ai_used": 1}), 2))

    def test_pack_adds_this_month_and_reopens_push(self):
        d = C.mark_pushed({}, "ai", "2026-11")
        self.assertFalse(C.push_due(d, "ai", "full"))
        self.assertTrue(C.push_due(d, "relay", "paused"))
        self.assertFalse(C.push_due({}, "relay", "notice"))       # only at 100 %
        d = C.add_pack(d, "ai", 100, 80, "sp:1", 5)
        d = C.add_pack(d, "relay", 1000, 150, "sp:2", 6)
        self.assertEqual(C.extra(d), {"relay_mb": 1000, "ai": 100})
        self.assertTrue(C.push_due(d, "ai", "full"))              # may push again
        with self.assertRaises(ValueError):
            C.add_pack(d, "video", 1, 1)
        for i in range(30):
            d = C.add_pack(d, "ai", 1, 1)
        self.assertEqual(len(d["extra"]["buys"]), C.KEEP_BUYS)

    def test_credits_for(self):
        self.assertEqual(C.credits_for(150, 1.0), 150)
        self.assertEqual(C.credits_for(150, 2.0), 75)
        self.assertEqual(C.credits_for(80, 0), 80)

    def test_bangla_notices_honest(self):
        m = C.ai_message("notice", 85, "bn")
        self.assertIn("৮৫", m)
        self.assertIn("সতর্কতা ও ছবি", m)
        f = C.ai_message("full", 100, "bn")
        self.assertIn("ধরন-সময় থেকে লেখা (AI নয়)", f)
        self.assertIn("SOS", f)
        self.assertEqual(C.ai_message("ok", 10, "bn"), "")
        for k in ("relay", "ai"):
            t, b = C.push_text(k, "bn")
            self.assertIn("বাড়তি প্যাক", b)
            self.assertNotRegex(t + b, r"[0-9]")                   # Bangla digits only
        self.assertIn("SOS", C.push_text("relay", "bn")[1])

    def test_profit_table_includes_packs_at_least_40(self):
        t = CP.profit_table()
        self.assertEqual([p["kind"] for p in t["packs"]], ["relay", "ai"])
        self.assertEqual(t["packs"][0]["pct"], 40.6)               # 150 tk / 1 GB
        self.assertEqual(t["packs"][1]["pct"], 42.7)               # 80 tk / 100 AI
        self.assertTrue(t["ok"])
        cheap = CP.profit_table({"extra_relay_bdt": 100})
        self.assertFalse(cheap["ok"])                              # owner warned
        from core.logic import pricing as P
        self.assertIn("cctv_below_40", [w["code"] for w in P.margin_warnings(
            P.normalize({"cctv_plan": {"extra_ai_bdt": 30}}))])

    def test_pack_cfg_bounds_and_play_seam(self):
        c = CP.normalize_cfg({"extra_relay_mb": 10 ** 9, "extra_ai_bdt": "x"})
        self.assertEqual(c["extra_relay_mb"], 10000)
        self.assertEqual(c["extra_ai_bdt"], 80)
        p = CP.packs()
        self.assertEqual((p["relay"]["mb"], p["relay"]["price_bdt"]), (1000, 150))
        self.assertEqual((p["ai"]["checks"], p["ai"]["price_bdt"]), (100, 80))
        self.assertEqual(p["relay"]["play_product"], "cctv_extra_relay_1gb")
        self.assertEqual(p["ai"]["play_product"], "cctv_extra_ai_100")


class OneCounterGuardTests(SimpleTestCase):
    """EVERY paid AI call on CCTV goes through cctv_cap.ai_try_take first."""

    def test_no_cctv_module_calls_vision_without_the_shared_counter(self):
        here = os.path.dirname(__file__)
        pat = re.compile(r"^(cctv|shop|watchman|phonecam|camera_hook|cashguard|cctvx)")
        checked = 0
        for root in (here, os.path.join(here, "logic")):
            for f in sorted(os.listdir(root)):
                if not f.endswith(".py") or f.startswith("tests") or not pat.match(f):
                    continue
                src = open(os.path.join(root, f), encoding="utf-8").read()
                for m in re.finditer(r"\bVP\.ask\(|vision_providers\.ask\(|CVS\.ask\(|"
                                     r"ai\.chat\(|ai\.complete\(", src):
                    checked += 1
                    before = src[:m.start()]
                    self.assertIn("ai_try_take(", before[before.rfind("\ndef "):],
                                  "%s: paid AI call without cctv_cap.ai_try_take" % f)
        self.assertGreaterEqual(checked, 1)          # describe_one is found


# ================================================================ AI counter
class AiCounterTests(G._Base):
    def setUp(self):
        super().setUp()
        from core.models import ShopCamera, ShopSite
        self.site2 = ShopSite.objects.create(owner=self.owner, name="Home")
        ShopCamera.objects.create(site=self.site2, name="Door", kind="shopbox")
        p = mock.patch("core.cctv_cap.ai_per_camera", return_value=2)   # 2 cams x 2
        p.start()
        self.addCleanup(p.stop)
        self.pushed = []
        q = mock.patch("core.push.push_to_user",
                       side_effect=lambda *a, **k: self.pushed.append((a, k)) or 1)
        q.start()
        self.addCleanup(q.stop)

    def test_one_shared_counter_across_sites_and_one_push(self):
        from core import cctv_cap as CC
        self.assertEqual(CC.ai_cap(self.owner), 4)
        self.assertEqual([CC.ai_try_take(self.owner) for _ in range(6)],
                         [True, True, True, True, False, False])
        self.assertEqual(CC.ai_used(self.owner), 4)
        self.assertEqual(len(self.pushed), 1)                      # ONE push at 100 %
        a, k = self.pushed[0]
        self.assertEqual(a[1], "shop_alert")
        self.assertEqual(a[2], "AI ছবি-যাচাই শেষ")
        self.assertEqual(k["data"]["type"], "cctv_cap")
        st = self.client.get("/api/v1/cctv/usage", HTTP_ACCEPT_LANGUAGE="bn").data["cap"]
        self.assertEqual((st["ai"]["level"], st["ai"]["used"], st["ai"]["cap"]), ("full", 4, 4))
        self.assertIn("AI নয়", st["ai"]["message"])
        self.assertIn("কখনো থামে না", st["safety_note"])

    def test_notice_at_80(self):
        from core import cctv_cap as CC
        with mock.patch("core.cctv_cap.ai_per_camera", return_value=5):   # cap 10
            for _ in range(8):
                CC.ai_try_take(self.owner)
            st = CC.status(self.owner, lang="bn")
        self.assertEqual(st["ai"]["level"], "notice")
        self.assertIn("৮০", st["ai"]["message"])
        self.assertEqual(self.pushed, [])                          # no push at 80 %

    def test_legacy_per_site_count_is_carried_once(self):
        from core import cctv_cap as CC
        from core.models import ShopSite
        month = T.month_key(timezone.now())
        ShopSite.objects.filter(pk=self.site.pk).update(
            guard={"_activity": {"ai": {"month": month, "used": 3}}})
        self.assertEqual(CC.ai_used(self.owner), 3)
        self.assertTrue(CC.ai_try_take(self.owner))                # 4 of 4
        self.assertFalse(CC.ai_try_take(self.owner))
        self.assertEqual(CC.ai_used(self.owner), 4)

    def test_failure_is_closed_no_paid_call(self):
        from core import cctv_cap as CC
        with mock.patch("core.cctv_traffic._update", side_effect=RuntimeError("db")):
            self.assertFalse(CC.ai_try_take(self.owner))

    def test_activity_description_uses_the_shared_counter(self):
        from core import cctv_activity as A
        from core import cctv_traffic as CT
        from core.models import ShopEvent
        ev = ShopEvent.objects.create(site=self.site, camera=self.cam, type="person_detected",
                                      signals={"inputs": {}}, confidence=0.9)
        reply = "একজন মানুষ গেটে || A person at the gate"
        with mock.patch("core.cctv_activity.snapshot_bytes", return_value=b"\xff\xd8\xffjpeg"), \
                mock.patch("core.vision_providers.ask", return_value=reply) as ask:
            self.assertEqual(A.describe_one(ev, "vision_claude", {}, timezone.now()), "ai")
            self.assertEqual(ask.call_count, 1)
            from core import cctv_cap as CC
            self.assertEqual(CC.ai_used(self.owner), 1)            # the shared counter
            CT._update(self.owner.pk, timezone.now(), lambda d: dict(d, ai_used=4))   # full
            ev2 = ShopEvent.objects.create(site=self.site, camera=self.cam,
                                           type="person_detected", signals={"inputs": {}},
                                           confidence=0.9)
            self.assertEqual(A.describe_one(ev2, "vision_claude", {}, timezone.now()), "cap")
            self.assertEqual(ask.call_count, 1)                    # no paid call at the cap
        ev2.refresh_from_db()
        self.assertNotIn("desc", ev2.signals)                      # template text stays
        self.assertEqual(A.desc_of(ev2)["src"], "template")
        self.assertEqual(ev2.signals["desc_try"], 3)               # never retried


# ================================================================ relay + live
@override_settings(TURN_STATIC_SECRET="test-secret", TURN_HOST="turn.example.test",
                   TURN_PORT=3478)
class RelayCapTests(G._Base):
    """cctvcap proofs on top of the cctvguard live-cap tests (their helpers
    are borrowed, their tests are not re-run here)."""
    _online = G.LiveCapTests._online
    _start = G.LiveCapTests._start
    _turn = staticmethod(G.LiveCapTests._turn)
    _pending_turn = G.LiveCapTests._pending_turn

    def setUp(self):
        super().setUp()
        self.pushed = []
        q = mock.patch("core.push.push_to_user",
                       side_effect=lambda *a, **k: self.pushed.append((a, k)) or 1)
        q.start()
        self.addCleanup(q.stop)

    def _active(self, sid, secs=100):
        from core.models import ShopLiveSession
        ShopLiveSession.objects.filter(pk=sid).update(
            answered_at=timezone.now() - timedelta(seconds=secs), status="active")

    def test_lan_and_direct_live_keep_running_over_the_cap(self):
        self.cfg(ON)
        self._online()
        self.fill(3)                                       # 3 MB of a 1 MB pool
        r = self._start()
        self.assertEqual(r.status_code, 201, r.data)       # live itself is never refused
        self.assertFalse(self._turn(r))
        sid = r.data["id"]
        self._active(sid)
        for path in ("lan", "direct"):
            u = self.client.post("/api/v1/shop/live/%d/usage" % sid,
                                 {"bytes": 4_000_000, "seconds": 60, "path": path},
                                 format="json")
            self.assertEqual(u.status_code, 200, u.data)
            self.assertFalse(u.data["stop"])
        from core.models import ShopLiveSession
        self.assertEqual(ShopLiveSession.objects.get(pk=sid).status, "active")
        row = self.client.get("/api/v1/cctv/usage").data["cameras"][0]
        self.assertEqual(row["direct_mb"], 4.0)            # free, never counted

    def test_sos_at_home_grant_is_never_cut(self):
        from core.logic import cctv_arm as ARM
        kid = User.objects.create_user(name="Kid", phone="01710007011", password="pw")
        until = timezone.now() + timedelta(minutes=30)

        def apply(a):
            a["sos"] = {"until": ARM.iso(until), "by": kid.pk, "viewers": [self.owner.pk],
                        "at": ARM.iso(timezone.now())}
        ARM.mutate(self.site, apply)
        self.cfg(ON)
        self._online()
        self.fill(5)
        r = self._start()
        self.assertTrue(self._turn(r))
        self.assertEqual(r.data["traffic"]["level"], "emergency")
        self.assertTrue(self._pending_turn())

    def test_sos_starting_during_relayed_live_is_never_cut(self):
        from core.models import FamilyAlertDelivery, ShopLiveSession
        self.cfg({"confirmed": True, "relay_mb": 2})
        self._online()
        r = self._start()
        self.assertTrue(self._turn(r))
        sid = r.data["id"]
        self._active(sid)
        kid = User.objects.create_user(name="Kid", phone="01710007012", password="pw")
        FamilyAlertDelivery.objects.create(event_key="fall1", kind="fall", sender=kid,
                                           recipient=self.owner)
        u = self.client.post("/api/v1/shop/live/%d/usage" % sid,
                             {"bytes": 3_000_000, "seconds": 60, "path": "relay"},
                             format="json")
        self.assertFalse(u.data["stop"])
        self.assertEqual(u.data["level"], "emergency")
        self.assertEqual(ShopLiveSession.objects.get(pk=sid).status, "active")
        from core import cctv_traffic as CT
        self.assertTrue(CT.session_relay_allowed(ShopLiveSession.objects.get(pk=sid)))

    def test_one_push_when_relay_cap_reached(self):
        self.cfg({"confirmed": True, "relay_mb": 2})
        self._online()
        sid = self._start().data["id"]
        self._active(sid, 300)
        for b in (1_000_000, 2_100_000, 2_500_000):
            self.client.post("/api/v1/shop/live/%d/usage" % sid,
                             {"bytes": b, "seconds": 200, "path": "relay"}, format="json")
        relay = [p for p in self.pushed if p[1]["data"].get("cap") == "relay"]
        self.assertEqual(len(relay), 1)
        self.assertEqual(relay[0][0][2], "রিলে-লাইভ সীমা শেষ")
        from core.models import NotifEvent
        self.assertEqual(NotifEvent.objects.filter(user=self.owner,
                                                   meta__cctv_cap="relay").count(), 1)

    def test_extra_relay_pack_reopens_relay_for_this_month(self):
        self.cfg(ON)
        self._online()
        self.fill(2)
        st = self.client.get("/api/v1/cctv/usage", HTTP_ACCEPT_LANGUAGE="bn").data["cap"]
        self.assertEqual(st["relay"]["level"], "paused")
        self.assertEqual([p["kind"] for p in st["packs"]], ["relay", "ai"])
        self.assertEqual(st["packs"][0]["credits"], 150)
        self.assertIn("একই Wi-Fi-তে বা সরাসরি সংযোগে দেখা যাবে", st["relay"]["message"])
        with mock.patch("core.credits.spend", side_effect=_spend_no):
            r = self.client.post("/api/v1/cctv/extra-pack", {"kind": "relay"}, format="json")
        self.assertEqual(r.status_code, 402)
        self.assertEqual(r.data["credits_needed"], 150)
        self.assertEqual(self.client.post("/api/v1/cctv/extra-pack", {"kind": "video"},
                                          format="json").status_code, 422)
        with mock.patch("core.credits.spend", side_effect=_spend_ok):
            r = self.client.post("/api/v1/cctv/extra-pack", {"kind": "relay"}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        self.assertEqual(r.data["bought"]["charged_credits"], 150)
        self.assertEqual(r.data["cap"]["relay"]["cap_mb"], 1 + 1000)
        self.assertEqual(r.data["cap"]["relay"]["level"], "ok")
        self.assertTrue(self._turn(self._start()))         # relay back on
        # next month: the pack is gone (this month only)
        from core import cctv_traffic as CT
        later = timezone.now() + timedelta(days=40)
        self.assertEqual(CT.account_state(self.owner.pk, later)["cap_mb"], 1)

    def test_pack_grant_failure_returns_the_credits(self):
        self.cfg(ON)
        with mock.patch("core.credits.spend", side_effect=_spend_ok), \
                mock.patch("core.credits.return_spend", return_value=150) as ret, \
                mock.patch("core.cctv_traffic._update", side_effect=RuntimeError("db")):
            r = self.client.post("/api/v1/cctv/extra-pack", {"kind": "ai"}, format="json")
        self.assertEqual(r.status_code, 503)
        ret.assert_called_once()
        self.assertEqual(ret.call_args.args[1], "sp:test80")

    def test_extra_ai_pack_adds_100_checks(self):
        from core import cctv_cap as CC
        from core import cctv_traffic as CT
        CT._update(self.owner.pk, timezone.now(), lambda d: dict(d, ai_used=50))
        self.assertFalse(CC.ai_try_take(self.owner))               # 1 camera x 50
        with mock.patch("core.credits.spend", side_effect=_spend_ok):
            r = self.client.post("/api/v1/cctv/extra-pack", {"kind": "ai"}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        self.assertEqual(r.data["cap"]["ai"]["cap"], 150)
        self.assertTrue(CC.ai_try_take(self.owner))


# ================================================================ alerts + evidence


@override_settings(MEDIA_ROOT=CGT._MEDIA)
class SafetyNeverStopsTests(CGT._Base):
    """Both caps full: the alert (push + photo), the clip and the evidence pack
    all still work."""

    def _caps_full(self):
        from core import cctv_traffic as CT
        p = mock.patch("core.cctv_traffic.cfg", return_value={"confirmed": True, "relay_mb": 1})
        p.start()
        self.addCleanup(p.stop)

        def fn(doc):
            doc, _, _ = T.add_live(doc, self.camobj.pk, "seed", 5 * 10 ** 6, 10 ** 6, "relay")
            doc["ai_used"] = 10 ** 6
            return doc
        CT._update(self.owner.pk, timezone.now(), fn)
        self.assertEqual(CT.account_state(self.owner.pk)["level"], "paused")
        from core import cctv_cap as CC
        self.assertEqual(CC.ai_state(self.owner.pk)["level"], "full")

    def test_alert_photo_clip_and_evidence_at_full_caps(self):
        from core.models import ShopEvent
        self._caps_full()
        ref = "c4" * 16
        r = self.dev.post("/api/v1/shop/ingest", {
            "type": "hand_in_cash_zone", "clip_ref": ref,
            "signals": json.dumps({"detector": "yolox_nano", "motion_in_zone": True}),
            "snapshot": SimpleUploadedFile("s.jpg", CGT._jpeg(), content_type="image/jpeg")},
            format="multipart")
        self.assertEqual(r.status_code, 201, r.data)
        ev = ShopEvent.objects.get(pk=r.data["event_id"])
        self.assertTrue(ev.snapshot)                               # the photo is kept
        self.assertTrue(self.pushes)                               # the push went out
        a, k = self.pushes[0]
        self.assertTrue(k["data"].get("snapshot_url"))             # ... with the photo
        self.assertNotIn("AI", a[2])                               # honest template text
        # the clip: upload + owner fetch
        u = self.upload(ref)
        self.assertEqual(u.status_code, 201, u.data)
        g = self.client.get("/api/v1/shop/events/%d/clip" % ev.id)
        self.assertEqual(g.status_code, 200, g.data)
        self.assertIn("/api/v1/m/", g.data["url"])
        # the evidence pack facts + final hash
        e = self.client.get("/api/v1/shop/events/%d/evidence" % ev.id)
        self.assertEqual(e.status_code, 200, e.data)
        self.assertTrue(e.data["gd_draft"])
        p = self.client.post("/api/v1/shop/events/%d/evidence" % ev.id,
                             {"manifest_sha256": "a" * 64, "files": 2}, format="json")
        self.assertIn(p.status_code, (200, 201), p.data)
        # the signed photo link opens
        self.assertEqual(APIClient().get(ev.snapshot.url).status_code, 200)


class NoMigrationTests(TestCase):
    def test_caps_live_in_the_existing_month_row(self):
        from core import cctv_traffic as CT
        u = User.objects.create_user(name="M", phone="01710007099", password="pw")
        CT._update(u.pk, timezone.now(), lambda d: C.add_pack(dict(d, ai_used=1), "ai", 100, 80))
        from core.models import PaCollectionItem
        rows = PaCollectionItem.objects.filter(user=u, collection=CT.COLLECTION)
        self.assertEqual(rows.count(), 1)
        self.assertEqual(rows[0].data["extra"]["ai"], 100)
        self.assertNotIn(BN_DIGITS[0], json.dumps(rows[0].data))
