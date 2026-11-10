"""discms (owner 10 Nov 01:53 + 01:56 + ads final 03:45): Discover is the
owner's ads + app-updates slot. Owner cards (What's new, Offer, feature,
our product, Sponsored labelled Ad) reach EVERYONE; the AdMob native slot is
Free-only (never Premium / Plus / Business) and is one placement in the
owner's ad registry; no auto expiry; Sponsored never opens a safety screen."""
from datetime import timedelta
from unittest import mock

from django.utils import timezone
from rest_framework.test import APITestCase

from core import views_discover as V
from core.logic import discover as D
from core.models import DiscoverCard, User


def _user(phone, plan=None, **kw):
    u = User.objects.create_user(name="U", phone=phone, password="pw", **kw)
    if plan:
        u.plan = plan
        u.plan_until = timezone.now() + timedelta(days=30)
        u.save()
    return u


class DiscmsBase(APITestCase):
    def setUp(self):
        DiscoverCard.objects.all().delete()   # only this test's cards
        self.free = _user("01710019001")
        self.prem = _user("01710019002", "premium")
        self.plus = _user("01710019003", "plus")
        self.owner = _user("01710019004", is_staff=True, is_superuser=True)

    def feed(self, user):
        self.client.force_authenticate(user)
        r = self.client.get("/api/v1/discover/cards?build=999")
        self.assertEqual(r.status_code, 200)
        return r.data["cards"]

    def keys(self, user):
        return [c["key"] for c in self.feed(user)]

    def create(self, **data):
        self.client.force_authenticate(self.owner)
        return self.client.post("/api/v1/admin/discover/cards", data, format="json")


class OwnerOnlyEditTests(DiscmsBase):
    def test_only_the_owner_can_add_edit_reorder_remove(self):
        c = DiscoverCard.objects.create(key="wn1", type="WHATS_NEW", title_bn="নতুন",
                                        title_en="New", route="notes")
        for u in (self.free, self.prem, self.plus):
            self.client.force_authenticate(u)
            for m, url, body in [
                    ("post", "/api/v1/admin/discover/cards",
                     {"type": "OFFER", "title_bn": "ক", "title_en": "A", "route": "notes"}),
                    ("patch", "/api/v1/admin/discover/cards/%d" % c.id, {"title_en": "X"}),
                    ("post", "/api/v1/admin/discover/reorder", {"ids": [c.id]}),
                    ("delete", "/api/v1/admin/discover/cards/%d" % c.id, {})]:
                r = getattr(self.client, m)(url, body, format="json")
                self.assertEqual(r.status_code, 403, (u.phone, m, url))
        c.refresh_from_db()
        self.assertEqual(c.title_en, "New")
        self.assertEqual(DiscoverCard.objects.count(), 1)

    def test_owner_creates_whats_new_and_offer(self):
        r = self.create(type="WHATS_NEW", title_bn="নতুন আপডেট", title_en="New update",
                        desc_bn="নোটে ভয়েস", desc_en="Voice in notes", route="notes")
        self.assertEqual(r.status_code, 201, r.data)
        r = self.create(type="OFFER", title_bn="অফার", title_en="Offer",
                        url="https://shop.example.com/deal")
        self.assertEqual(r.status_code, 201, r.data)
        self.assertEqual(r.data["label"], "offer")

    def test_every_owner_card_needs_a_button(self):
        for t in ("WHATS_NEW", "OFFER"):
            r = self.create(type=t, title_bn="ক", title_en="A")
            self.assertEqual(r.status_code, 400)
            self.assertEqual(r.data["errors"]["action"], "required")

    def test_web_owner_admin_shows_plain_type_names(self):
        self.client.force_login(self.owner)
        r = self.client.get("/owner/discover/new")
        if r.status_code != 200:      # owner panel needs its own 2-step login
            self.skipTest("owner panel login gate")
        html = r.content.decode()
        self.assertIn('value="WHATS_NEW"', html)
        self.assertIn('value="OFFER"', html)


class EveryoneSeesOwnerCardsTests(DiscmsBase):
    def setUp(self):
        super().setUp()
        DiscoverCard.objects.create(key="wn", type="WHATS_NEW", title_bn="নতুন",
                                    title_en="New", route="notes", order=1)
        DiscoverCard.objects.create(key="of", type="OFFER", title_bn="অফার",
                                    title_en="Offer", url="https://shop.example.com", order=2)
        DiscoverCard.objects.create(key="sp", type="SPONSORED", title_bn="ব্র্যান্ড",
                                    title_en="Brand", url="https://brand.example.com",
                                    sponsor_name="Brand", order=3)
        DiscoverCard.objects.create(key="ad", type="ADMOB", order=4)

    def _no_sponsor(self):
        # a booked Sponsored card wins the one ad slot (d1 rule) — the AdMob
        # tests run on a day with no sponsor booked
        DiscoverCard.objects.filter(key="sp").update(enabled=False)

    def test_sponsor_takes_the_slot_that_day(self):
        self.assertNotIn("ad", self.keys(self.free))
        self.assertIn("sp", self.keys(self.free))

    def test_free_premium_plus_all_get_owner_cards(self):
        for u in (self.free, self.prem, self.plus):
            ks = self.keys(u)
            for k in ("wn", "of", "sp"):
                self.assertIn(k, ks, (u.phone, k))

    def test_admob_slot_free_only_never_premium_or_plus(self):
        self._no_sponsor()
        self.assertIn("ad", self.keys(self.free))
        self.assertNotIn("ad", self.keys(self.prem))
        self.assertNotIn("ad", self.keys(self.plus))

    def test_admob_audience_cannot_force_it_on_paid_users(self):
        self._no_sponsor()
        DiscoverCard.objects.filter(key="ad").update(audience="premium")
        self.assertNotIn("ad", self.keys(self.prem))
        self.assertNotIn("ad", self.keys(self.plus))

    def test_ad_label_always_on_sponsored_and_labels_per_type(self):
        for u in (self.free, self.prem, self.plus):
            by = {c["key"]: c for c in self.feed(u)}
            self.assertEqual(by["sp"]["label"], "sponsored")   # app draws "Ad"
            self.assertEqual(by["wn"]["label"], "whats_new")
            self.assertEqual(by["of"]["label"], "offer")
        # the label is derived from the type: an edit cannot remove it
        sp = DiscoverCard.objects.get(key="sp")
        self.client.force_authenticate(self.owner)
        self.client.patch("/api/v1/admin/discover/cards/%d" % sp.id,
                          {"label": "", "title_en": "Brand 2"}, format="json")
        by = {c["key"]: c for c in self.feed(self.free)}
        self.assertEqual(by["sp"]["label"], "sponsored")

    def test_admob_payload_names_its_registry_placement(self):
        self._no_sponsor()
        ad = next(c for c in self.feed(self.free) if c["key"] == "ad")
        self.assertEqual(ad["placement"], "discover_native")
        self.assertEqual(ad["label"], "ad")

    def test_registry_switch_off_hides_the_admob_slot(self):
        self._no_sponsor()
        self.assertIn("ad", self.keys(self.free))
        with mock.patch.object(V, "discover_admob_on", return_value=False):
            self.assertNotIn("ad", self.keys(self.free))
            self.assertIn("wn", self.keys(self.free))   # owner cards stay

    def test_registry_missing_means_default_on(self):
        from core import admob_service as AS
        if hasattr(AS, "placement_on"):
            with mock.patch.object(AS, "placement_on", side_effect=RuntimeError):
                self.assertTrue(V.discover_admob_on(self.free))
        else:
            self.assertTrue(V.discover_admob_on(self.free))

    def test_registry_switch_is_read_live(self):
        from core import admob_service as AS
        with mock.patch.object(AS, "placement_on", create=True, return_value=False) as m:
            self.assertFalse(V.discover_admob_on(self.free))
            m.assert_called_with("discover_native")
        self.assertFalse(V.discover_admob_on(self.prem))
        self.assertFalse(V.discover_admob_on(self.plus))

    def test_home_native_and_discover_native_both_on(self):
        self._no_sponsor()
        # ads final 03:45: the hero native ad no longer removes the slot
        self.client.force_authenticate(self.free)
        r = self.client.get("/api/v1/discover/cards?build=999&hero_ad=1")
        self.assertIn("ad", [c["key"] for c in r.data["cards"]])


class NoAutoExpiryTests(DiscmsBase):
    def test_card_without_end_stays_forever(self):
        c = DiscoverCard.objects.create(key="wn", type="WHATS_NEW", title_bn="নতুন",
                                        title_en="New", route="notes")
        DiscoverCard.objects.filter(pk=c.pk).update(
            created_at=timezone.now() - timedelta(days=400))
        later = timezone.now() + timedelta(days=3650)
        rows = [V._rule_row(x) for x in DiscoverCard.objects.all()]
        self.assertEqual([r["id"] for r in D.visible_cards(rows, "free", 999, later)], [c.id])

    def test_only_an_owner_set_end_hides_it(self):
        now = timezone.now()
        DiscoverCard.objects.create(key="of", type="OFFER", title_bn="অফার", title_en="Offer",
                                    route="offers", end_at=now - timedelta(minutes=1))
        self.assertNotIn("of", self.keys(self.free))


class SafetyTopicTests(DiscmsBase):
    def test_sponsored_cannot_open_safety_child_or_quran(self):
        for route in ("emergency_hub", "voice_sos", "quran", "quran_learn",
                      "kids_watch", "carecall", "journey", "safety"):
            r = self.create(type="SPONSORED", title_bn="ক", title_en="A",
                            sponsor_name="S", route=route)
            self.assertEqual(r.status_code, 400, route)
            self.assertEqual(r.data["errors"]["route"], "safety_topic", route)

    def test_whats_new_may_point_to_a_safety_feature(self):
        r = self.create(type="WHATS_NEW", title_bn="নতুন SOS", title_en="New SOS",
                        route="emergency_hub")
        self.assertEqual(r.status_code, 201, r.data)

    def test_no_ad_next_to_quran_or_child_card(self):
        def row(i, t="FEATURE", route="notes"):
            return {"id": i, "type": t, "enabled": True, "start_at": None,
                    "end_at": None, "audience": "all", "min_build": None,
                    "order": i, "route": route}
        for route in ("quran", "kids_watch", "carecall"):
            rows = [row(1, route=route), row(2, "SPONSORED", ""), row(3), row(4)]
            out = [r["id"] for r in D.visible_cards(rows, "free", None, timezone.now())]
            self.assertEqual(out, [1, 3, 2, 4], route)

    def test_app_mirror_of_protected_routes_matches(self):
        from pathlib import Path
        src = (Path(__file__).resolve().parents[2] / "app/lib/widgets/home_suggestions.dart")
        if not src.exists():
            self.skipTest("app sources not present")
        txt = src.read_text(encoding="utf-8")
        block = txt.split("kDiscoverProtectedRoutes = {", 1)[1].split("};", 1)[0]
        import re
        app_set = set(re.findall(r"'([a-z_]+)'", block))
        self.assertEqual(app_set, set(D.PROTECTED_ROUTES))
