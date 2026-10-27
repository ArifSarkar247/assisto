"""feature-flags: flag resolution per flavour / rollout / allow-list / owner,
GET /api/v1/features (ETag + 304, signed-out first run), registry defaults =
today's behaviour, the Dart mirror in lock-step, and the DoD audit seed."""
import re
from pathlib import Path

from django.test import TestCase
from rest_framework.test import APIClient

from core import feature_audit as FA
from core import feature_flags as FF
from core.models import FeatureFlag, User

APP_LIB = Path(__file__).resolve().parents[2] / "app" / "lib"


def _flag(key, **kw):
    FF.ensure_seeded()
    FeatureFlag.objects.filter(key=key).update(**kw)
    FF.invalidate()


class RegistryTests(TestCase):
    def test_keys_unique_sections_known_routes_unique(self):
        self.assertEqual(len(FF.KEYS), len(set(FF.KEYS)))
        secs = {s[0] for s in FF.SECTIONS}
        routes = []
        for k, sec, en, bn, on, rts in FF.REGISTRY:
            self.assertIn(sec, secs, k)
            self.assertTrue(en and bn, k)
            if k != "crm":   # "CRM" is a product name in both (lang_gate allowlist)
                self.assertTrue(re.search(r"[ঀ-৿]", bn), k)  # real Bangla
            routes += list(rts)
        self.assertEqual(len(routes), len(set(routes)))

    def test_defaults_keep_todays_behaviour(self):
        feats, preview = FF.resolve(None, play=True)
        self.assertEqual(preview, [])
        # visible today, in both builds
        for k in ("my_circle", "reminders", "money", "crm", "cctv_watchman",
                  "vehicle_tracking", "anti_theft", "photo_studio", "offers",
                  "business_agent", "daily_info"):
            self.assertTrue(feats[k], k)
            self.assertTrue(FF.resolve(None, play=False)[0][k], k)
        # not visible today (code-gated showpieces / not built yet)
        for k in ("unseen_world", "agent_studio", "area_community", "fall_detect", "remote_support",
                  "corporate_meetings", "marketing", "retention", "booking"):
            self.assertFalse(feats[k], k)

    def test_audit_covers_every_key(self):
        self.assertEqual(set(FA.AUDIT), set(FF.KEYS))
        for k, a in FA.AUDIT.items():
            self.assertEqual(len(a["codes"]), FF.N_CHECKS, k)
            self.assertTrue(set(a["codes"]) <= set("PF?"), k)
            self.assertIn(a["play"], ("show", "hide"), k)
            # strict DoD: nothing is 9/9 today
            self.assertNotEqual(a["codes"], "P" * 9, k)

    def test_dart_mirror_in_lock_step(self):
        src = (APP_LIB / "feature_registry.dart").read_text()
        defaults = dict(re.findall(r"^  '(\w+)': (true|false),$", src, re.M))
        self.assertEqual(set(defaults), set(FF.KEYS))
        for k, sec, en, bn, on, rts in FF.REGISTRY:
            self.assertEqual(defaults[k], "true" if on else "false", k)
        routes = dict(re.findall(r"^  '(\w+)': '(\w+)',$", src, re.M))
        self.assertEqual(routes, FF.ROUTE_FEATURE)
        # every sidebar `feature:` key is a registry key
        sb = (APP_LIB / "widgets" / "sidebar_sections.dart").read_text()
        used = set(re.findall(r"feature: '(\w+)'", sb))
        self.assertTrue(used)
        self.assertLessEqual(used, set(FF.KEYS))

    def test_routes_exist_in_chatnav(self):
        src = (APP_LIB / "widgets" / "chatnav.dart").read_text()
        known = set(re.findall(r"^\s+'(\w+)': \(_\) =>", src, re.M))
        self.assertLessEqual(set(FF.ROUTE_FEATURE), known)


class ResolutionTests(TestCase):
    def setUp(self):
        FF.invalidate()
        self.u = User.objects.create_user(name="U", phone="01700000001", password="pw-123456")
        self.tester = User.objects.create_user(name="T", phone="01700000002", password="pw-123456")
        self.owner = User.objects.create_superuser(name="O", phone="01700000003", password="pw-123456")

    def tearDown(self):
        FF.invalidate()

    def test_play_only_hide(self):
        _flag("crm", enabled_all=True, enabled_play=False)
        self.assertTrue(FF.is_on("crm", self.u, play=False))
        self.assertFalse(FF.is_on("crm", self.u, play=True))

    def test_off_for_all_hides_both_builds(self):
        _flag("crm", enabled_all=False, enabled_play=True)
        self.assertFalse(FF.is_on("crm", self.u, play=False))
        self.assertFalse(FF.is_on("crm", self.u, play=True))

    def test_owner_and_staff_see_hidden_as_preview(self):
        _flag("crm", enabled_all=False)
        feats, preview = FF.resolve(self.owner, play=True)
        self.assertTrue(feats["crm"])
        self.assertIn("crm", preview)
        self.u.is_staff = True
        self.u.save()
        self.assertTrue(FF.is_on("crm", self.u, play=True))

    def test_allow_list_tester(self):
        _flag("remote_support", enabled_all=False, allow_user_ids=[self.tester.pk])
        feats, preview = FF.resolve(self.tester, play=True)
        self.assertTrue(feats["remote_support"])
        self.assertEqual(preview, ["remote_support"])
        self.assertFalse(FF.is_on("remote_support", self.u, play=True))

    def test_rollout_is_stable_and_partial(self):
        _flag("offers", rollout_pct=50)
        users = [User.objects.create_user(name="R%d" % i, phone="0171%07d" % i,
                                          password="pw-123456") for i in range(60)]
        on = [FF.is_on("offers", x) for x in users]
        self.assertTrue(0 < sum(on) < 60)
        self.assertEqual(on, [FF.is_on("offers", x) for x in users])   # stable
        self.assertFalse(FF.is_on("offers", None))       # signed out: only 100%
        _flag("offers", rollout_pct=0)
        self.assertFalse(any(FF.is_on("offers", x) for x in users))
        _flag("offers", rollout_pct=100)
        self.assertTrue(FF.is_on("offers", None))

    def test_unknown_key_never_hides(self):
        self.assertTrue(FF.is_on("no_such_feature", self.u))

    def test_cache_and_invalidate(self):
        FF.ensure_seeded()
        self.assertTrue(FF.is_on("crm", self.u))
        FeatureFlag.objects.filter(key="crm").update(enabled_all=False)
        self.assertTrue(FF.is_on("crm", self.u))       # cached copy (30 s)
        FF.invalidate()
        self.assertFalse(FF.is_on("crm", self.u))

    def test_seed_never_overwrites(self):
        self.assertEqual(FF.ensure_seeded(), len(FF.KEYS))
        FeatureFlag.objects.filter(key="crm").update(enabled_all=False, note="mine")
        self.assertEqual(FF.ensure_seeded(), 0)
        f = FeatureFlag.objects.get(key="crm")
        self.assertFalse(f.enabled_all)
        self.assertEqual(f.note, "mine")
        seeded = FeatureFlag.objects.get(key="money")
        self.assertEqual(seeded.dod_checks, FA.checks_bools("money"))
        self.assertIn("Audit 26 Oct", seeded.note)
        self.assertIn("অডিট", seeded.note_bn)
        self.assertEqual(FeatureFlag.objects.get(key="booking").dod_status, "hidden")

    def test_validate(self):
        ok, p = FF.validate({"enabled_all": "1", "rollout_pct": "40",
                             "allow_user_ids": "3, 5 5,7", "dod_status": "in_progress"})
        self.assertEqual(p, [])
        self.assertEqual(ok["allow_user_ids"], [3, 5, 7])
        self.assertFalse(ok["enabled_play"])
        _, p = FF.validate({"rollout_pct": "140"})
        self.assertIn("rollout_pct", p)
        _, p = FF.validate({"allow_user_ids": "abc"})
        self.assertIn("allow_user_ids", p)
        _, p = FF.validate({"dod_status": "done", "dod_0": "1"})
        self.assertIn("dod_not_complete", p)
        form = {"dod_status": "done", **{"dod_%d" % i: "1" for i in range(9)}}
        self.assertEqual(FF.validate(form)[1], [])


class EndpointTests(TestCase):
    def setUp(self):
        FF.invalidate()
        self.u = User.objects.create_user(name="U", phone="01700000011", password="pw-123456")
        self.c = APIClient()

    def tearDown(self):
        FF.invalidate()

    def test_signed_out_first_run_gets_public_set(self):
        r = self.c.get("/api/v1/features")
        self.assertEqual(r.status_code, 200)
        j = r.json()
        self.assertEqual(j["flavour"], "apk")
        self.assertEqual(set(j["features"]), set(FF.KEYS))
        self.assertTrue(j["features"]["money"])
        self.assertEqual(j["preview"], [])

    def test_flavour_header_and_etag_304(self):
        _flag("vehicle_tracking", enabled_play=False)
        self.c.force_authenticate(self.u)
        r = self.c.get("/api/v1/features", HTTP_X_ASSISTO_FLAVOUR="play")
        self.assertEqual(r.json()["flavour"], "play")
        self.assertFalse(r.json()["features"]["vehicle_tracking"])
        tag = r["ETag"]
        self.assertIn("private", r["Cache-Control"])
        r2 = self.c.get("/api/v1/features", HTTP_X_ASSISTO_FLAVOUR="play",
                        HTTP_IF_NONE_MATCH=tag)
        self.assertEqual(r2.status_code, 304)
        r3 = self.c.get("/api/v1/features", HTTP_IF_NONE_MATCH=tag)   # website APK
        self.assertEqual(r3.status_code, 200)
        self.assertTrue(r3.json()["features"]["vehicle_tracking"])
        _flag("vehicle_tracking", enabled_play=True)                    # owner flips
        r4 = self.c.get("/api/v1/features", HTTP_X_ASSISTO_FLAVOUR="play",
                        HTTP_IF_NONE_MATCH=tag)
        self.assertEqual(r4.status_code, 200)
        self.assertNotEqual(r4["ETag"], tag)

    def test_owner_sees_hidden_in_play(self):
        _flag("remote_support", enabled_all=False)
        owner = User.objects.create_superuser(name="O", phone="01700000012", password="pw-123456")
        self.c.force_authenticate(owner)
        j = self.c.get("/api/v1/features", HTTP_X_ASSISTO_FLAVOUR="play").json()
        self.assertTrue(j["features"]["remote_support"])
        self.assertIn("remote_support", j["preview"])


class UnseenRenameTests(TestCase):
    """unseen-rename (owner 27 Oct): the daily info hub moved from flag key
    `unseen_world` to `daily_info`; `unseen_world` is now the NEW travel
    feature, default OFF. Old apps (no `fv`) keep their hub; the owner's old
    row is carried over by migration 0096 and the new key starts hidden."""

    def setUp(self):
        FF.invalidate()
        self.u = User.objects.create_user(name="U", phone="01700000021", password="pw-123456")
        self.c = APIClient()

    def tearDown(self):
        FF.invalidate()

    def test_registry_names_and_defaults(self):
        m = FF.meta("daily_info")
        self.assertEqual((m["label_en"], m["label_bn"]),
                         ("Daily info and services", "আজকের তথ্য ও সেবা"))
        self.assertTrue(m["default_on"])
        n = FF.meta("unseen_world")
        self.assertFalse(n["default_on"])
        self.assertEqual(n["routes"], [])
        for k, sec, en, bn, on, rts in FF.REGISTRY:
            if k != "unseen_world":   # only the NEW feature may carry the name
                self.assertNotIn("Unseen World", en, k)
                self.assertNotIn("অদেখা দুনিয়া", bn, k)

    def test_new_app_gets_real_meaning(self):
        _flag("daily_info", enabled_all=True)
        j = self.c.get("/api/v1/features?fv=2").json()
        self.assertTrue(j["features"]["daily_info"])
        self.assertFalse(j["features"]["unseen_world"])

    def test_old_app_keeps_daily_hub_under_old_key(self):
        j = self.c.get("/api/v1/features").json()           # no fv = old app
        self.assertTrue(j["features"]["unseen_world"])
        _flag("daily_info", enabled_all=False)               # owner hides the hub
        j = self.c.get("/api/v1/features").json()
        self.assertFalse(j["features"]["unseen_world"])
        self.assertEqual(self.c.get("/api/v1/features?fv=junk").status_code, 200)

    def test_old_app_preview_follows_daily_info_only(self):
        owner = User.objects.create_superuser(name="O", phone="01700000022", password="pw-123456")
        body = FF.payload(owner, play=True, fv=1)            # travel hidden, hub on
        self.assertNotIn("unseen_world", body["preview"])
        self.assertIn("unseen_world", FF.payload(owner, play=True, fv=2)["preview"])
        _flag("daily_info", enabled_all=False)
        body = FF.payload(owner, play=True, fv=1)
        self.assertIn("unseen_world", body["preview"])
        self.assertIn("daily_info", body["preview"])

    def _migrate(self):
        import importlib
        from django.apps import apps
        mod = importlib.import_module("core.migrations.0096_daily_info_flag")
        mod.forward(apps, None)
        FF.invalidate()

    def test_migration_carries_owner_row_and_resets_new_key(self):
        FeatureFlag.objects.create(key="unseen_world", enabled_all=True, enabled_play=False,
                                   rollout_pct=40, allow_user_ids=[self.u.pk],
                                   dod_status="in_progress", dod_checks=[True] + [False] * 8,
                                   note="owner note")
        self._migrate()
        d = FeatureFlag.objects.get(key="daily_info")
        self.assertEqual((d.enabled_all, d.enabled_play, d.rollout_pct, d.allow_user_ids,
                          d.dod_checks[0], d.note),
                         (True, False, 40, [self.u.pk], True, "owner note"))
        n = FeatureFlag.objects.get(key="unseen_world")
        self.assertEqual((n.enabled_all, n.enabled_play, n.allow_user_ids, n.dod_status),
                         (False, False, [], "hidden"))
        self.assertFalse(FF.is_on("unseen_world", self.u, play=False))
        # idempotent: running again never overwrites the carried row
        FeatureFlag.objects.filter(key="daily_info").update(rollout_pct=70)
        self._migrate()
        self.assertEqual(FeatureFlag.objects.get(key="daily_info").rollout_pct, 70)

    def test_migration_no_row_is_noop(self):
        self._migrate()
        self.assertFalse(FeatureFlag.objects.exists())
        self.assertTrue(FF.is_on("daily_info", self.u))
        self.assertFalse(FF.is_on("unseen_world", self.u))
