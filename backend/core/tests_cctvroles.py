"""cctvroles (CCTV Guard V3 I, J, K, L).

I  roles: owner / manager / family / guard / STAFF (view only, never
   deletes, exports, shares or changes); the owner's audit list shows views
   AND every export / share / change / delete / role / installer step.
J  installer partners: apply -> Owner Admin approves -> the site owner's
   code / QR -> the partner sees ONLY setup status (never video, photos,
   alerts); commission 10 % of Premium AI only (owner 17 Nov), never auto-paid.
K  privacy wall: no Assisto admin / staff path reaches any camera media;
   export only by the site owner; printable sticker PDF.
L  Premium AI (owner-decided) passes the 40 % worst-case check from the ONE source
   of numbers (cctv_plan + ai_config), base prices unchanged.
"""
import re
from datetime import timedelta
from pathlib import Path

from django.test import SimpleTestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core.logic import cctv_partner as CPT
from core.logic import cctv_plan as CP
from core.logic import cctv_premium_ai as PA
from core.logic import cctv_team as CT
from core.models import User
from core.tests_cctvteam import _Base

BACKEND = Path(__file__).resolve().parents[1]


# ============================================================ pure rules
class PureTests(SimpleTestCase):
    def test_staff_role_and_permission_table(self):
        self.assertIn("staff", CT.ROLES)
        self.assertEqual(CT.clean_role("staff", [], [1]), ("staff", []))
        self.assertIsNone(CT.scope_of("staff", []))
        # ONLY the owner deletes / exports / shares / changes / invites
        for action in ("delete", "export", "share", "settings", "roles", "installer"):
            self.assertTrue(CT.can("owner", action), action)
            for role in CT.ROLES:
                self.assertFalse(CT.can(role, action), (role, action))
        self.assertTrue(CT.can("manager", "mark"))
        for role in ("staff", "family", "guard"):
            self.assertTrue(CT.can(role, "view"))
            self.assertFalse(CT.can(role, "mark"))
        self.assertFalse(CT.can(None, "view"))
        self.assertEqual(CT.suggested_roles("home")[0], "family")
        self.assertIn("staff", CT.suggested_roles("shop"))
        self.assertEqual(set(CT.perm_table()), {"owner"} | set(CT.ROLES))
        self.assertEqual(len(CT.clean_detail("x " * 200)), CT.DETAIL_MAX)
        # audit detail: packed once, read in the reader's language
        raw = CT.pack(who="Su;mon=", role="staff", cam=2, live=1)
        self.assertEqual(CT.unpack(raw)["who"], "Su,mon-")
        self.assertEqual(CT.detail_text("role", raw, "en"), "Su,mon- → staff (2 camera(s)) · live")
        self.assertEqual(CT.detail_text("role", raw, "bn"), "Su,mon- → কর্মী (২ ক্যামেরা) · লাইভ")
        self.assertEqual(CT.detail_text("export", CT.pack(ev=12, h="ab"), "bn"), "সতর্কতা #১২-এর প্রমাণ")
        self.assertEqual(CT.detail_text("change", CT.pack(place="name,hours"), "en"),
                         "place: name, hours")
        self.assertEqual(CT.detail_text("weird", "x=1", "en"), "")

    def test_installer_code_and_checklist(self):
        code = CPT.new_code()
        self.assertEqual(len(code), CPT.CODE_LEN)
        self.assertEqual(CPT.normalize_code(code.lower()[:4] + " - " + code[4:]), code)
        self.assertEqual(CPT.normalize_code(CPT.qr_payload(code)), code)
        for bad in ("", None, "ABC", "O0O0O0O0", "ABCDEFGHJ"):
            self.assertEqual(CPT.normalize_code(bad), "", bad)
        self.assertNotEqual(CPT.code_hash(code), code)
        steps = CPT.setup_checklist({"cameras": 2, "online": 2, "gateway_age_min": 3,
                                     "hours": True, "zones": 2})
        self.assertTrue(CPT.setup_done(steps))
        steps = CPT.setup_checklist({"cameras": 2, "online": 1, "gateway_age_min": None})
        self.assertEqual([s["key"] for s in steps if not s["ok"]],
                         ["cameras_online", "gateway_connected", "hours_set", "zones_set"])
        with self.assertRaises(CPT.PartnerError):
            CPT.clean_apply("A", "Mirpur")

    def test_commission_is_owner_decided_10pct_premium_ai_only(self):
        # cctvprice: owner-decided 17 Nov 12:35 (was a 5 % proposal)
        p = CPT.COMMISSION_RULES
        self.assertTrue(p["approved"])
        self.assertEqual((p["pct_of_net"], p["applies_to"]), (10, "premium_ai"))
        self.assertFalse(p["auto_payout"])
        self.assertEqual(CPT.proposed_commission(1000, 1, in_trial=True), 0)
        self.assertEqual(CPT.proposed_commission(1000, 0, in_trial=False), 0)
        self.assertEqual(CPT.proposed_commission(1000, 13, in_trial=False), 0)
        self.assertEqual(CPT.proposed_commission(1000, 3, in_trial=False), 100)
        self.assertEqual(CPT.proposed_commission(1000, 3, False, premium_ai=False), 0)

    def test_base_prices_unchanged_one_source(self):
        # V3 L: keep 500 Tk = 2 cameras, 250 per extra (never forked)
        self.assertEqual((CP.BASE_PRICE_BDT, CP.BASE_CAMERAS, CP.EXTRA_CAMERA_BDT),
                         (500, 2, 250))
        self.assertEqual(CP.monthly_price(2), 500)
        self.assertEqual(CP.monthly_price(3), 750)
        self.assertNotIn("BASE_PRICE_BDT", Path(PA.__file__).read_text().split('"""', 2)[2])

    def test_premium_ai_passes_40_percent_worst_case(self):
        from core import ai_config
        t = PA.profit_table()
        self.assertTrue(t["ok"], t["min_pct"])
        self.assertGreaterEqual(t["min_pct"], 40.0)
        # ... with the owner-decided 10 % commission on the Premium AI part
        self.assertGreaterEqual(PA.decided_table()["min_pct"], 40.0)
        # 10 % of the WHOLE site net would break the rule -> the base is the
        # Premium AI part only (cctvprice, owner 17 Nov 12:35)
        self.assertLess(PA.profit_table(commission_pct_of_net=10)["min_pct"], 40.0)
        # the commission can NOT go on the base plan (honest: no headroom)
        self.assertFalse(PA.base_with_commission(commission_pct_of_net=10)["ok"])
        # Claude prices come from ai_config: a dearer Haiku makes AI cost more
        dear = {m: dict(p) for m, p in ai_config.DEFAULT_PRICES.items()}
        dear[PA.DESCRIBE_MODEL] = {"in": 10.0, "out": 50.0}
        self.assertGreater(PA.ai_cost_per_camera_bdt(prices=dear)["total"],
                           PA.ai_cost_per_camera_bdt()["total"])
        self.assertNotIn("gemini", PA.DESCRIBE_MODEL + PA.ASK_MODEL + PA.REPORT_MODEL)
        self.assertEqual(CP.TRIAL_DAYS, 7)          # owner 17 Nov: trial stays 7 days


class NoAdsOnCctvTests(SimpleTestCase):
    """V3 L CI guard (server mirror of app/test/cctvroles_noads_test.dart)."""

    def test_every_cctv_key_is_fenced_and_never_listed(self):
        from core.logic import ads as A
        keys = ("cctv", "cctv_grid", "cctv_partner", "watchman", "watchman_alerts",
                "shop_live", "shop_box", "shop_camera_settings", "shop_eod", "guard_box",
                "cash_guard", "installer", "phonecam", "camera_alerts")
        allowed = set(A.BANNER_SCREENS) | set(A.NATIVE_SCREENS) | set(A.APP_OPEN_SCREENS) | \
            set(A.REWARDED_SCREENS)
        for k in keys:
            self.assertTrue(A.is_blocked_screen(k), k)
            self.assertNotIn(k, allowed)


# ============================================================ I: roles + audit
class StaffRoleTests(_Base):
    def setUp(self):
        super().setUp()
        r = self.c["owner"].put("/api/v1/shop/sites/%d/viewers/%d/role"
                                % (self.site.id, self.family.id),
                                {"role": "staff", "cameras": []}, format="json")
        self.assertEqual((r.status_code, r.data["role"]), (200, "staff"))

    def test_staff_views_but_never_deletes_exports_shares_or_changes(self):
        s = self.c["staff"]  # the Assisto superuser — see AdminWallTests
        w = self.c["family"]  # now a STAFF member of the shop
        sid = self.site.id
        self.assertEqual(w.get("/api/v1/shop/events?site=%d" % sid).status_code, 200)
        self.assertEqual(w.get("/api/v1/shop/events/%d" % self.ev_till.id).status_code, 200)
        refused = [
            w.post("/api/v1/shop/events/%d/mark" % self.ev_till.id, {"status": "checked"},
                   format="json"),
            w.get("/api/v1/shop/events/%d/evidence" % self.ev_till.id),
            w.post("/api/v1/shop/events/%d/evidence" % self.ev_till.id,
                   {"manifest_sha256": "a" * 64, "files": 1}, format="json"),
            w.post("/api/v1/shop/events/%d/clip/share" % self.ev_till.id, {"uid": 1},
                   format="json"),
            w.delete("/api/v1/shop/cameras/%d" % self.till.id),
            w.patch("/api/v1/shop/cameras/%d" % self.till.id, {"name": "x"}, format="json"),
            w.patch("/api/v1/shop/sites/%d" % sid, {"name": "x"}, format="json"),
            w.delete("/api/v1/shop/sites/%d/viewers/%d" % (sid, self.guard.id)),
            w.post("/api/v1/shop/sites/%d/share-links" % sid,
                   {"cameras": [self.gate.id], "hours": 1}, format="json"),
            w.post("/api/v1/shop/sites/%d/installer" % sid),
            w.get("/api/v1/shop/sites/%d/access-log" % sid),
            w.get("/api/v1/shop/sites/%d/privacy-kit" % sid),
        ]
        for r in refused:
            self.assertIn(r.status_code, (403, 404, 405), getattr(r, "data", r))
        self.assertTrue(type(self.till).objects.filter(pk=self.till.pk).exists())
        self.assertEqual(s.get("/api/v1/shop/events?site=%d" % sid).status_code, 404)

    def test_roles_endpoint_shows_perms_and_suggestions(self):
        r = self.c["owner"].get("/api/v1/shop/sites/%d/roles" % self.site.id)
        self.assertEqual(r.status_code, 200)
        self.assertIn("staff", r.data["roles"])
        self.assertEqual(r.data["perms"]["staff"], ["view"])
        self.assertIn("delete", r.data["perms"]["owner"])
        self.assertEqual(r.data["suggested"][0], "family")      # a home site


class AuditTests(_Base):
    def test_owner_sees_exports_shares_changes_and_deletes(self):
        o, m = self.c["owner"], self.c["manager"]
        sid = self.site.id
        # a manager marks an alert -> "change" by the manager
        r = m.post("/api/v1/shop/events/%d/mark" % self.ev_gate.id, {"status": "checked"},
                   format="json")
        self.assertEqual(r.status_code, 200)
        # the owner changes a role, exports evidence, makes a link, deletes a camera
        o.put("/api/v1/shop/sites/%d/viewers/%d/role" % (sid, self.family.id),
              {"role": "staff"}, format="json")
        r = o.post("/api/v1/shop/events/%d/evidence" % self.ev_gate.id,
                   {"manifest_sha256": "b" * 64, "files": 2}, format="json")
        self.assertEqual(r.status_code, 200, getattr(r, "data", r))
        o.post("/api/v1/shop/sites/%d/share-links" % sid,
               {"cameras": [self.gate.id], "hours": 1}, format="json")
        self.assertEqual(o.delete("/api/v1/shop/cameras/%d" % self.till.id).status_code, 200)
        log = o.get("/api/v1/shop/sites/%d/access-log?kind=change" % sid).data
        acts = {x["action"]: x for x in log["rows"]}
        self.assertEqual(set(acts), {"change", "role", "export", "share", "delete"})
        self.assertFalse(acts["change"]["is_owner"])
        self.assertEqual(acts["change"]["user_id"], self.manager.id)
        self.assertTrue(acts["export"]["is_owner"])
        self.assertEqual(acts["export"]["detail"], "evidence of alert #%d" % self.ev_gate.id)
        self.assertIn("→ staff", acts["role"]["detail"])
        self.assertEqual(acts["change"]["detail"], "alert #%d: checked" % self.ev_gate.id)
        self.assertEqual(acts["delete"]["detail"], "camera: Till")
        self.assertTrue(all(x["kind"] == "change" for x in log["rows"]))
        self.assertEqual(log["audit_keep_days"], CT.AUDIT_KEEP_DAYS)
        views = o.get("/api/v1/shop/sites/%d/access-log?kind=view" % sid).data["rows"]
        self.assertTrue(all(x["kind"] == "view" for x in views))
        # only the owner sees the list
        self.assertEqual(m.get("/api/v1/shop/sites/%d/access-log" % sid).status_code, 404)


# ============================================================ J: installer partners
class PartnerTests(_Base):
    def setUp(self):
        super().setUp()
        self.tech = User.objects.create_user(name="Technician", phone="01710009077",
                                             password="pw")
        self.t = APIClient()
        self.t.force_authenticate(self.tech)

    def _approve(self):
        from core.models import CctvPartner
        CctvPartner.objects.filter(user=self.tech).update(status="approved")

    def _invite(self):
        r = self.c["owner"].post("/api/v1/shop/sites/%d/installer" % self.site.id)
        self.assertEqual(r.status_code, 201, r.data)
        self.assertTrue(r.data["qr"].endswith(r.data["code"]))
        return r.data

    def test_full_flow_setup_status_only(self):
        r = self.t.post("/api/v1/shop/partner/apply", {"name": "Rana CCTV", "area": "Mirpur 10"},
                        format="json")
        self.assertEqual((r.status_code, r.data["status"]), (201, "pending"))
        inv = self._invite()
        r = self.t.post("/api/v1/shop/partner/join", {"code": inv["code"]}, format="json")
        self.assertEqual((r.status_code, r.data["error"]), (403, "not_approved"))
        self._approve()
        r = self.t.post("/api/v1/shop/partner/join", {"code": inv["qr"]}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        me = self.t.get("/api/v1/shop/partner/me").data
        self.assertEqual(me["partner"]["status"], "approved")
        self.assertEqual(len(me["sites"]), 1)
        site = me["sites"][0]
        self.assertEqual((site["cameras"], site["online"]), (2, 2))
        self.assertEqual(me["commission"]["status"], "decided")
        self.assertTrue(me["commission"]["approved"])
        self.assertEqual((me["commission"]["pct"], me["commission"]["owed_bdt"]), (10, 0))
        # NOTHING but setup facts: no url, no photo, no alert, no token
        blob = repr({k: v for k, v in me.items() if k != "note"}).lower()
        for word in ("url", "still", "snapshot", "clip", "event", "token", "alert", "phone"):
            self.assertNotIn(word, blob, word)
        # the media wall: the partner is a stranger to every media endpoint
        for path in ("/api/v1/shop/events/%d" % self.ev_gate.id,
                     "/api/v1/shop/events/%d/clip" % self.ev_gate.id,
                     "/api/v1/shop/events/%d/evidence" % self.ev_gate.id,
                     "/api/v1/shop/cameras/%d/still" % self.gate.id,
                     "/api/v1/shop/sites/%d/access-log" % self.site.id):
            self.assertEqual(self.t.get(path).status_code, 404, path)
        self.assertEqual(self.t.get("/api/v1/shop/events?site=%d" % self.site.id).status_code,
                         404)
        r = self.t.post("/api/v1/shop/live/start", {"camera": self.gate.id}, format="json")
        self.assertEqual(r.status_code, 404)
        self.assertEqual(self.t.get("/api/v1/shop/grid").data.get("sites", []), [])
        # the owner sees it in the audit list, then ends it
        owner_view = self.c["owner"].get("/api/v1/shop/sites/%d/installer" % self.site.id).data
        link = owner_view["links"][0]
        self.assertEqual((link["status"], link["partner"]["name"]), ("active", "Rana CCTV"))
        log = self.c["owner"].get("/api/v1/shop/sites/%d/access-log?kind=change"
                                  % self.site.id).data["rows"]
        self.assertEqual(sorted(x["detail"] for x in log if x["action"] == "installer"),
                         ["code made", "joined: Rana CCTV"])
        r = self.c["owner"].post("/api/v1/shop/installer/%d/end" % link["id"])
        self.assertEqual(r.data["status"], "ended")
        self.assertEqual(self.t.get("/api/v1/shop/partner/me").data["sites"], [])
        # an ended code can not be reused
        r = self.t.post("/api/v1/shop/partner/join", {"code": inv["code"]}, format="json")
        self.assertEqual(r.data["error"], "bad_code")

    def test_code_rules(self):
        from core.models import CctvInstallerLink
        self.t.post("/api/v1/shop/partner/apply", {"name": "Rana", "area": "Uttara"},
                    format="json")
        self._approve()
        inv = self._invite()
        CctvInstallerLink.objects.filter(pk=inv["id"]).update(
            expires_at=timezone.now() - timedelta(minutes=1))
        r = self.t.post("/api/v1/shop/partner/join", {"code": inv["code"]}, format="json")
        self.assertEqual((r.status_code, r.data["error"]), (410, "expired"))
        r = self.t.post("/api/v1/shop/partner/join", {"code": "nonsense"}, format="json")
        self.assertEqual(r.data["error"], "bad_code")
        for _ in range(CPT.MAX_OPEN_INVITES):
            self._invite()
        r = self.c["owner"].post("/api/v1/shop/sites/%d/installer" % self.site.id)
        self.assertEqual((r.status_code, r.data["error"]), (409, "too_many"))
        # only the site owner makes / ends invites
        self.assertEqual(self.c["manager"].post(
            "/api/v1/shop/sites/%d/installer" % self.site.id).status_code, 404)
        self.assertEqual(self.t.post("/api/v1/shop/installer/%d/end" % inv["id"]).status_code,
                         404)
        # only the code's hash is stored
        self.assertFalse(CctvInstallerLink.objects.filter(code_hash=inv["code"]).exists())

    def test_owner_cannot_be_their_own_installer(self):
        from core.models import CctvPartner
        CctvPartner.objects.create(user=self.owner, name="Me", area="Here", status="approved")
        inv = self._invite()
        r = self.c["owner"].post("/api/v1/shop/partner/join", {"code": inv["code"]},
                                 format="json")
        self.assertEqual(r.data["error"], "own_site")


# ============================================================ K: privacy wall
class AdminWallTests(_Base):
    MEDIA_PATHS = ("/api/v1/shop/events/%(ev)d", "/api/v1/shop/events/%(ev)d/clip",
                   "/api/v1/shop/events/%(ev)d/evidence", "/api/v1/shop/events/%(ev)d/sd-clip",
                   "/api/v1/shop/cameras/%(cam)d/still", "/api/v1/shop/sites/%(site)d/access-log",
                   "/api/v1/shop/sites/%(site)d/privacy-kit",
                   "/api/v1/shop/events?site=%(site)d")

    def _paths(self):
        k = {"ev": self.ev_gate.id, "cam": self.gate.id, "site": self.site.id}
        return [p % k for p in self.MEDIA_PATHS]

    def test_assisto_superuser_cannot_fetch_any_camera_media(self):
        s = self.c["staff"]          # is_staff + is_superuser
        for path in self._paths():
            r = s.get(path)
            self.assertIn(r.status_code, (403, 404), path)
            self.assertNotEqual(r.get("Content-Type", ""), "image/jpeg", path)
        r = s.post("/api/v1/shop/live/start", {"camera": self.gate.id}, format="json")
        self.assertIn(r.status_code, (403, 404))
        self.assertEqual(s.get("/api/v1/shop/grid").data.get("sites", []), [])

    def test_owner_admin_session_has_no_api_media_path(self):
        # the Owner Admin web session is a cookie, never an API credential
        anon = APIClient()
        for path in self._paths():
            self.assertIn(anon.get(path).status_code, (401, 403, 404), path)

    def test_no_cctv_model_in_django_admin_and_no_media_in_owner_admin_code(self):
        from django.contrib import admin
        names = {m.__name__ for m in admin.site._registry}
        self.assertFalse({n for n in names if n.startswith(("Shop", "Cctv", "PhoneCam"))},
                         names)
        bad = re.compile(r"\b(ShopEventClip|ShopEvent|CctvWatchPost|sd_clip)\b|"
                         r"(?<![A-Z])\.(still|preview|blob)\b|snapshot\.url")
        for f in sorted((BACKEND / "web" / "owner").glob("*.py")) + \
                sorted((BACKEND / "web" / "templates" / "owner").glob("*.html")):
            for i, line in enumerate(f.read_text().splitlines(), 1):
                self.assertIsNone(bad.search(line), "%s:%d %s" % (f.name, i, line.strip()))

    def test_export_only_by_the_site_owner_and_sticker_text_owner_only(self):
        for who in ("manager", "family", "guard", "staff", "stranger"):
            r = self.c[who].post("/api/v1/shop/events/%d/evidence" % self.ev_gate.id,
                                 {"manifest_sha256": "c" * 64, "files": 1}, format="json")
            self.assertEqual(r.status_code, 404, who)
            self.assertEqual(self.c[who].get("/api/v1/shop/sites/%d/privacy-kit"
                                             % self.site.id).status_code, 404, who)
        r = self.c["owner"].get("/api/v1/shop/sites/%d/privacy-kit" % self.site.id)
        self.assertEqual(r.status_code, 200)
        self.assertIn("A4", r.data["sizes"])

    def test_sticker_says_no_face_recognition_in_both_languages(self):
        from core.logic import cctv_extras as CX
        kit = CX.privacy_kit("Shop", 7)
        self.assertIn("No face recognition", " ".join(kit["sticker"]["en"]))
        self.assertIn("মুখ চেনার ব্যবস্থা নেই", " ".join(kit["sticker"]["bn"]))
