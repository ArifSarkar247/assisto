"""ownerfix (owner fixes 3 Nov 02:55) — items 1 + 3.

1) ONE blood donor feature. The old personal registry (generic collection
   "blood/donors") is gone from the app; every old donor is copied into the
   panel's private "My saved donors" (BloodSavedDonor) by migration
   0142_ownerfix (dry-run counts, idempotent, old rows kept) and by a lazy
   re-sync for rows an OLD app build writes later. Same list rules as the
   panel: never hidden, available first, waiting by exact days left, paused
   shown, header counts. No ads anywhere in blood donor. Chat / old links open
   the one panel.
3) Discover defaults: SOS, Train tracker, Live Location, Destination Alarm,
   Blood donor, then the rest; never an ad next to SOS / Blood donor; the
   owner can still add / reorder in Owner Admin.
VISIBILITY: owner, staff and allow-listed testers see the OFF blood_donors
feature as a preview; a normal user only after the owner switches it ON.
"""
import importlib
from datetime import date, timedelta
from pathlib import Path

from django.apps import apps as django_apps
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APITestCase

from core import blood_panel as BP
from core import feature_flags as FF
from core import screen_synonyms as SS
from core.logic import ads as ADS
from core.logic import blood_rules as BR
from core.logic import discover as D
from core.models import (BloodSavedDonor, DiscoverCard, FeatureFlag, PaCollectionItem,
                         User)

MIG = importlib.import_module("core.migrations.0142_ownerfix")
APP_LIB = Path(__file__).resolve().parents[2] / "app" / "lib"


def _flag(key, **kw):
    FF.ensure_seeded()
    FeatureFlag.objects.filter(key=key).update(**kw)
    FF.invalidate()


def _on(key):
    _flag(key, enabled_all=True, enabled_play=True, rollout_pct=100)


def _old(user, **data):
    return PaCollectionItem.objects.create(user=user, collection=BR.LEGACY_COLLECTION, data=data)


class LegacyMappingTests(TestCase):
    today = date(2026, 11, 3)

    def test_every_field_maps_and_nobody_is_dropped(self):
        m = BR.legacy_to_saved({"name": " Rahim ", "blood_group": "o positive", "area": "Mirpur",
                                "phone": "০১৭১১-০০০৫০১", "availability": "available",
                                "last_donation": "2026-09-01", "share_contact": True}, self.today)
        self.assertEqual(m, {"name": "Rahim", "blood_group": "O+", "area_text": "Mirpur",
                             "phone": "01711000501", "available": True,
                             "last_donation": date(2026, 9, 1)})
        # unknown group / future date / junk -> blank, the person stays listed
        m = BR.legacy_to_saved({"name": "X", "blood_group": "Z", "last_donation": "2030-01-01"},
                               self.today)
        self.assertEqual((m["blood_group"], m["last_donation"], m["available"]), ("", None, True))
        self.assertEqual(BR.legacy_to_saved("junk", self.today)["name"], "")

    def test_paused_and_unavailable_are_paused_never_hidden(self):
        for a in ("paused", "unavailable", "PAUSED"):
            self.assertFalse(BR.legacy_to_saved({"availability": a}, self.today)["available"], a)

    def test_status_exact_days_and_order(self):
        d = self.today
        s = BR.saved_status(True, d - timedelta(days=100), d)
        self.assertEqual((s["status"], s["days_left"], s["donated_days_ago"]), ("waiting", 20, 100))
        self.assertEqual(BR.saved_status(True, None, d)["status"], "available")
        self.assertEqual(BR.saved_status(True, d - timedelta(days=200), d)["status"], "available")
        self.assertEqual(BR.saved_status(False, None, d)["status"], "paused")
        cards = [{"id": 1, "name": "p", "status": "paused", "days_left": 0},
                 {"id": 2, "name": "w-far", "status": "waiting", "days_left": 90},
                 {"id": 3, "name": "a", "status": "available", "days_left": 0},
                 {"id": 4, "name": "w-near", "status": "waiting", "days_left": 3}]
        self.assertEqual([c["id"] for c in sorted(cards, key=BR.saved_sort_key)], [3, 4, 2, 1])


class MigrationTests(TestCase):
    def setUp(self):
        self.a = User.objects.create_user(name="A", phone="01710029001", password="pw")
        self.b = User.objects.create_user(name="B", phone="01710029002", password="pw")
        _old(self.a, name="Rahim", blood_group="O+", availability="available")
        _old(self.a, name="Karim", blood_group="B-", availability="unavailable")
        _old(self.b, name="Sumi", blood_group="A+", phone="01711000001")
        PaCollectionItem.objects.create(user=self.a, collection="mess/members", data={"name": "n"})

    def test_dry_run_counts_then_copy_then_idempotent(self):
        plan = MIG.legacy_plan(django_apps)
        self.assertEqual(plan, {"old_rows": 3, "users": 2, "already_copied": 0, "to_copy": 3})
        self.assertEqual(BloodSavedDonor.objects.count(), 0)          # dry run wrote nothing
        self.assertEqual(MIG.copy_legacy_donors(django_apps, None), 3)
        self.assertEqual(MIG.copy_legacy_donors(django_apps, None), 0)  # re-run: nothing twice
        self.assertEqual(BloodSavedDonor.objects.count(), 3)
        self.assertEqual(MIG.legacy_plan(django_apps)["to_copy"], 0)
        # the old rows are KEPT (a later cleanup removes them)
        self.assertEqual(PaCollectionItem.objects.filter(collection=BR.LEGACY_COLLECTION).count(), 3)
        k = BloodSavedDonor.objects.get(name="Karim")
        self.assertEqual((k.owner, k.available, k.blood_group), (self.a, False, "B-"))
        self.assertEqual(BloodSavedDonor.objects.get(name="Sumi").owner, self.b)
        # the lazy re-sync agrees with the migration (no duplicates)
        self.assertEqual(BP.sync_legacy(self.a), 0)

    def test_row_written_by_an_old_build_after_the_migration_is_picked_up(self):
        MIG.copy_legacy_donors(django_apps, None)
        _old(self.a, name="Late", blood_group="AB+")
        rows, counts = BP.saved_list(self.a)
        self.assertIn("Late", [r["name"] for r in rows])
        self.assertEqual(counts["total"], 3)


class SavedApiTests(APITestCase):
    def setUp(self):
        FF.invalidate()
        self.u = User.objects.create_user(name="U", phone="01710029011", password="pw")
        self.other = User.objects.create_user(name="O", phone="01710029012", password="pw")
        today = timezone.localdate()
        _old(self.u, name="Paused", blood_group="A+", availability="paused")
        _old(self.u, name="Soon", blood_group="O+",
             last_donation=(today - timedelta(days=110)).isoformat())
        _old(self.u, name="Later", blood_group="O+",
             last_donation=(today - timedelta(days=10)).isoformat())
        _old(self.u, name="Now", blood_group="B+")

    def tearDown(self):
        FF.invalidate()

    def get(self, user=None):
        self.client.force_authenticate(user or self.u)
        r = self.client.get("/api/v1/blood-panel/saved")
        self.assertEqual(r.status_code, 200)
        return r.data

    def test_list_never_hides_sorted_with_counts(self):
        d = self.get()
        self.assertEqual([r["name"] for r in d["donors"]], ["Now", "Soon", "Later", "Paused"])
        self.assertEqual([r["status"] for r in d["donors"]],
                         ["available", "waiting", "waiting", "paused"])
        self.assertEqual(d["donors"][1]["days_left"], 10)
        self.assertEqual(d["donors"][2]["days_left"], 110)
        self.assertEqual(d["counts"], {"total": 4, "available": 1, "soon": 2, "paused": 1})
        self.assertTrue(all(r["from_old_list"] for r in d["donors"]))

    def test_private_to_the_owner(self):
        self.assertEqual(self.get(self.other)["donors"], [])
        pk = self.get()["donors"][0]["id"]
        self.client.force_authenticate(self.other)
        self.assertEqual(self.client.delete("/api/v1/blood-panel/saved/%d" % pk).status_code, 404)
        _on("blood_donors")
        r = self.client.post("/api/v1/blood-panel/saved/%d" % pk, {"name": "x"}, format="json")
        self.assertEqual(r.status_code, 404)

    def test_add_edit_follow_the_flag_read_and_delete_never_gated(self):
        self.client.force_authenticate(self.u)
        body = {"name": "Nadia", "blood_group": "ab-", "phone": "০১৮১১ ২২২৩৩৩"}
        r = self.client.post("/api/v1/blood-panel/saved", body, format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (403, "feature_off"))
        _on("blood_donors")
        r = self.client.post("/api/v1/blood-panel/saved", body, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        self.assertEqual((r.data["donor"]["blood_group"], r.data["donor"]["phone"]),
                         ("AB-", "01811222333"))
        pk = r.data["donor"]["id"]
        r = self.client.post("/api/v1/blood-panel/saved/%d" % pk, {"available": False}, format="json")
        self.assertEqual(r.data["donor"]["status"], "paused")
        r = self.client.post("/api/v1/blood-panel/saved", {"name": ""}, format="json")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(set(r.data["fields"]), {"name", "blood_group"})
        future = (timezone.localdate() + timedelta(days=3)).isoformat()
        r = self.client.post("/api/v1/blood-panel/saved/%d" % pk, {"last_donation": future},
                             format="json")
        self.assertEqual(r.data["fields"], ["last_donation"])
        # flag OFF again: still readable + deletable (the user's own data)
        _flag("blood_donors", enabled_all=False)
        self.assertIn("Nadia", [x["name"] for x in self.get()["donors"]])
        self.client.force_authenticate(self.u)
        self.assertEqual(self.client.delete("/api/v1/blood-panel/saved/%d" % pk).status_code, 200)

    def test_deleting_a_migrated_donor_never_comes_back(self):
        rows = self.get()["donors"]
        pk = next(r["id"] for r in rows if r["name"] == "Paused")
        self.client.force_authenticate(self.u)
        self.client.delete("/api/v1/blood-panel/saved/%d" % pk)
        self.assertNotIn("Paused", [r["name"] for r in self.get()["donors"]])
        self.assertEqual(PaCollectionItem.objects.filter(
            user=self.u, collection=BR.LEGACY_COLLECTION).count(), 3)


class VisibilityTests(APITestCase):
    """Owner + testers see the hidden panel; normal users only once ON.
    No flag VALUE is changed by the app code — only the tests flip it."""
    def setUp(self):
        FF.invalidate()
        self.user = User.objects.create_user(name="N", phone="01710029021", password="pw")
        self.tester = User.objects.create_user(name="T", phone="01710029022", password="pw")
        self.owner = User.objects.create_user(name="Ow", phone="01710029023", password="pw",
                                              is_staff=True, is_superuser=True)
        self.staff = User.objects.create_user(name="S", phone="01710029024", password="pw",
                                              is_staff=True)
        _flag("blood_donors", enabled_all=False, allow_user_ids=[self.tester.pk])

    def tearDown(self):
        FF.invalidate()

    def features(self, u):
        self.client.force_authenticate(u)
        r = self.client.get("/api/v1/features")
        self.assertEqual(r.status_code, 200)
        return r.json()

    def donors_status(self, u):
        self.client.force_authenticate(u)
        return self.client.get("/api/v1/blood-panel/donors?district=dhaka").status_code

    def test_default_is_off(self):
        self.assertFalse(dict((r[0], r[4]) for r in FF.REGISTRY)["blood_donors"])

    def test_owner_staff_tester_preview_normal_user_off(self):
        for u in (self.owner, self.staff, self.tester):
            f = self.features(u)
            self.assertTrue(f["features"]["blood_donors"], u.name)
            self.assertIn("blood_donors", f["preview"], u.name)
            self.assertNotEqual(self.donors_status(u), 403, u.name)
        f = self.features(self.user)
        self.assertFalse(f["features"]["blood_donors"])
        self.assertNotIn("blood_donors", f["preview"])
        self.assertEqual(self.donors_status(self.user), 403)

    def test_normal_user_sees_it_after_the_owner_switches_it_on(self):
        _on("blood_donors")
        f = self.features(self.user)
        self.assertTrue(f["features"]["blood_donors"])
        self.assertNotIn("blood_donors", f["preview"])
        self.assertNotEqual(self.donors_status(self.user), 403)


class DiscoverOrderTests(APITestCase):
    LEAD = ["sos", "train_tracker", "journey", "dest_alarm", "blood_donor"]

    def setUp(self):
        FF.invalidate()
        self.u = User.objects.create_user(name="U", phone="01710029031", password="pw")
        self.owner = User.objects.create_user(name="O", phone="01710029032", password="pw",
                                              is_staff=True, is_superuser=True)

    def tearDown(self):
        FF.invalidate()

    def keys(self, user=None):
        self.client.force_authenticate(user or self.u)
        r = self.client.get("/api/v1/discover/cards")
        self.assertEqual(r.status_code, 200)
        return [c["key"] for c in r.data["cards"]]

    def test_seeded_rows_are_ordinary_and_valid(self):
        rows = list(DiscoverCard.objects.order_by("order", "id"))
        self.assertEqual([c.key for c in rows[:5]], self.LEAD)
        live = DiscoverCard.objects.get(key="journey")
        self.assertEqual((live.title_en, live.title_bn, live.route),
                         ("Live Location", "লাইভ লোকেশন", "journey"))
        dest = DiscoverCard.objects.get(key="dest_alarm")
        blood = DiscoverCard.objects.get(key="blood_donor")
        self.assertEqual((dest.route, blood.route), ("dest_alarm", "blood_panel"))
        for c in (live, dest, blood):
            f = {k: getattr(c, k) for k in ("title_bn", "title_en", "desc_bn", "desc_en", "url")}
            self.assertEqual(D.safety_issues(f), [], c.key)
            self.assertIn(c.icon, D.ICONS)
            self.assertIn(c.route, D.ROUTE_KEYS)
        self.assertEqual(DiscoverCard.objects.filter(route="journey").count(), 1)

    def test_flags_off_sos_then_live_location(self):
        self.assertEqual(self.keys()[:2], ["sos", "journey"])
        for k in ("train_tracker", "dest_alarm", "blood_donor"):
            self.assertNotIn(k, self.keys())
        # the owner's preview never shows a hidden card on Discover either
        self.assertNotIn("blood_donor", self.keys(self.owner))

    def test_all_on_owner_order(self):
        for k in ("train_tracker", "dest_alarm", "blood_donors"):
            _on(k)
        self.assertEqual(self.keys()[:5], self.LEAD)

    def test_sponsor_never_next_to_sos_or_blood(self):
        for k in ("train_tracker", "dest_alarm", "blood_donors"):
            _on(k)
        blood = DiscoverCard.objects.get(key="blood_donor")
        DiscoverCard.objects.create(key="sp-b", type="SPONSORED", title_bn="দোকান",
                                    title_en="Shop", url="https://shop.example.com",
                                    sponsor_name="Shop", order=blood.order + 1)
        DiscoverCard.objects.create(key="sp-s", type="SPONSORED", title_bn="দোকান২",
                                    title_en="Shop2", url="https://shop2.example.com",
                                    sponsor_name="Shop2", order=1)
        k = self.keys()
        for sp in ("sp-b", "sp-s"):
            if sp in k:
                i = k.index(sp)
                for j in (i - 1, i + 1):
                    if 0 <= j < len(k):
                        self.assertNotIn(k[j], ("sos", "blood_donor"), (sp, k))

    def test_rerun_keeps_owner_edits_and_owner_reorder_works(self):
        live = DiscoverCard.objects.get(key="journey")
        live.title_en = "Owner name"
        live.save()
        MIG.seed_discover(django_apps, None)
        self.assertEqual(DiscoverCard.objects.get(key="journey").title_en, "Owner name")
        self.assertEqual(DiscoverCard.objects.filter(key__in=self.LEAD).count(), 5)
        # Owner Admin -> Discover: reorder (Live Location first) + add own card
        self.client.force_authenticate(self.owner)
        ids = list(DiscoverCard.objects.exclude(pk=live.pk).values_list("id", flat=True))
        r = self.client.post("/api/v1/admin/discover/reorder", {"ids": [live.pk] + ids},
                             format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(self.keys()[0], "journey")
        self.client.force_authenticate(self.owner)
        r = self.client.post("/api/v1/admin/discover/cards",
                             {"type": "FEATURE", "title_bn": "আমার কার্ড", "title_en": "My card",
                              "route": "dest_alarm", "icon": "alarm"}, format="json")
        self.assertEqual(r.status_code, 201, r.data)


class EntryPointTests(TestCase):
    def test_chat_opens_the_one_panel(self):
        for t in ("রক্তদাতা খুঁজে দাও", "I need blood", "blood donor", "রক্ত লাগবে",
                  "open blood bank"):
            self.assertEqual(SS.resolve(t), "blood_panel", t)
        # unrelated health words never jump to the panel
        self.assertNotEqual(SS.resolve("my blood pressure is high"), "blood_panel")

    def test_old_route_is_an_alias_of_the_panel_flag(self):
        self.assertEqual(FF.ROUTE_FEATURE["blood_donor"], "blood_donors")
        self.assertEqual(FF.ROUTE_FEATURE["blood_panel"], "blood_donors")
        self.assertIn("blood_donor", D.PROTECTED_ROUTES)

    def test_old_screen_and_sidebar_entry_are_gone(self):
        self.assertFalse((APP_LIB / "screens" / "blood_donor_screen.dart").exists())
        sb = (APP_LIB / "widgets" / "sidebar_sections.dart").read_text()
        self.assertNotIn("feature: 'blood_donor',", sb)
        self.assertNotIn("BloodDonorScreen", sb)
        self.assertEqual(sb.count("BloodHubScreen()"), 1)

    def test_no_ads_anywhere_in_blood_donor(self):
        for s in ("blood_panel", "blood_hub", "blood_saved", "blood_request", "blood_thread",
                  "blood_donor"):
            self.assertTrue(ADS.is_blocked_screen(s), s)
        for f in (APP_LIB / "screens" / "blood").glob("*.dart"):
            src = f.read_text()
            for bad in ("/ads/", "AdBannerSlot", "AdExit", "NativeAd", "Interstitial"):
                self.assertNotIn(bad, src, "%s %s" % (f.name, bad))
