"""homeorder (explicit owner order 2 Nov 17:35/17:40): SOS first + Train
tracker as SERVER-SIDE default Discover items the owner can override from
Owner Admin; items only while their feature flag is ON; a Sponsored / ad card
is never placed right next to SOS or Blood donor (server + app)."""
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APITestCase

from core import feature_flags as FF
from core.logic import discover as D
from core.models import DiscoverCard, FeatureFlag, User


def _row(id, type="FEATURE", route="", order=None):
    return {"id": id, "type": type, "enabled": True, "start_at": None,
            "end_at": None, "audience": "all", "min_build": None,
            "order": id if order is None else order, "route": route}


def _ok(cards):
    """No ad directly next to a protected card."""
    for a, b in zip(cards, cards[1:]):
        for x, y in ((a, b), (b, a)):
            if x["type"] in D.AD_TYPES and D.is_protected(y):
                return False
    return True


class SeparateAdsPureTests(TestCase):
    now = timezone.now()

    def ids(self, rows, seg="free", route_on=None):
        out = D.visible_cards(rows, seg, None, self.now, route_on=route_on)
        self.assertTrue(_ok(out), out)
        return [r["id"] for r in out]

    def test_sponsor_after_sos_moves_one_slot_later(self):
        rows = [_row(1, route="emergency"), _row(2, "SPONSORED"), _row(3, route="journey"),
                _row(4, route="money")]
        self.assertEqual(self.ids(rows), [1, 3, 2, 4])

    def test_sponsor_before_blood_moves(self):
        rows = [_row(1, route="journey"), _row(2, "SPONSORED"), _row(3, route="blood_panel"),
                _row(4, route="money")]
        self.assertEqual(self.ids(rows), [2, 1, 3, 4])

    def test_sponsor_between_sos_and_blood_goes_after_next_free_gap(self):
        rows = [_row(1, route="emergency"), _row(2, "SPONSORED"), _row(3, route="blood_panel"),
                _row(4, route="money"), _row(5, route="notes")]
        self.assertEqual(self.ids(rows), [1, 3, 4, 2, 5])

    def test_sponsor_dropped_when_no_allowed_slot(self):
        rows = [_row(1, route="emergency"), _row(2, "SPONSORED"), _row(3, route="blood_panel")]
        self.assertEqual(self.ids(rows), [1, 3])

    def test_new_emergency_hub_route_is_protected_too(self):
        rows = [_row(1, route="emergency_hub"), _row(2, "SPONSORED"), _row(3, route="notes")]
        self.assertEqual(self.ids(rows), [1, 3, 2])

    def test_admob_is_an_ad_too(self):
        rows = [_row(1, route="emergency"), _row(2, "ADMOB"), _row(3, route="notes")]
        self.assertEqual(self.ids(rows), [1, 3, 2])

    def test_rule_reapplied_after_flag_hides_a_card(self):
        # [SOS, train(off), sponsor] -> train hidden would make the sponsor
        # touch SOS; it must move past the next card instead.
        rows = [_row(1, route="emergency"), _row(2, route="train_tracker"),
                _row(3, "SPONSORED"), _row(4, route="notes")]
        self.assertEqual(self.ids(rows, route_on=lambda r: r != "train_tracker"), [1, 4, 3])

    def test_untouched_when_rule_holds(self):
        rows = [_row(1, route="journey"), _row(2, "SPONSORED"), _row(3, route="notes")]
        self.assertEqual(self.ids(rows), [1, 2, 3])
        self.assertEqual(D.SOS_ROUTE, "emergency")   # until emhub lands


def _flag(key, **kw):
    FF.ensure_seeded()
    FeatureFlag.objects.filter(key=key).update(**kw)
    FF.invalidate()


class FeedTests(APITestCase):
    def setUp(self):
        FF.invalidate()
        self.u = User.objects.create_user(name="U", phone="01710019001", password="pw")
        self.owner = User.objects.create_user(name="O", phone="01710019002", password="pw",
                                              is_staff=True, is_superuser=True)

    def tearDown(self):
        FF.invalidate()

    def keys(self, user=None, headers=None):
        self.client.force_authenticate(user or self.u)
        r = self.client.get("/api/v1/discover/cards", **(headers or {}))
        self.assertEqual(r.status_code, 200)
        return [c["key"] for c in r.data["cards"]]

    def test_defaults_are_ordinary_owner_editable_rows(self):
        sos = DiscoverCard.objects.get(key="sos")
        tr = DiscoverCard.objects.get(key="train_tracker")
        self.assertEqual((sos.route, sos.type, sos.enabled), ("emergency", "FEATURE", True))
        self.assertEqual(tr.route, "train_tracker")
        first = DiscoverCard.objects.order_by("order", "id")
        self.assertEqual([c.key for c in first[:2]], ["sos", "train_tracker"])
        for c in (sos, tr):
            f = {k: getattr(c, k) for k in ("title_bn", "title_en", "desc_bn", "desc_en", "url")}
            self.assertEqual(D.safety_issues(f), [], c.key)
            self.assertIn(c.icon, D.ICONS)
            self.assertIn(c.route, D.ROUTE_KEYS)

    def test_sos_first_train_only_with_flag(self):
        k = self.keys()
        self.assertEqual(k[0], "sos")
        self.assertNotIn("train_tracker", k)
        _flag("train_tracker", enabled_all=True, enabled_play=True, rollout_pct=100)
        self.assertEqual(self.keys()[:2], ["sos", "train_tracker"])
        # Play build follows the Play switch
        _flag("train_tracker", enabled_play=False)
        self.assertNotIn("train_tracker",
                         self.keys(headers={"HTTP_X_ASSISTO_FLAVOUR": "play"}))
        self.assertIn("train_tracker", self.keys())

    def test_preview_only_feature_hidden_even_for_owner(self):
        # flag OFF -> the owner gets it as a preview elsewhere, never on Discover
        self.assertNotIn("train_tracker", self.keys(self.owner))

    def test_owner_can_remove_reorder_and_add_without_a_build(self):
        self.client.force_authenticate(self.owner)
        sos = DiscoverCard.objects.get(key="sos")
        r = self.client.patch("/api/v1/admin/discover/cards/%d" % sos.pk,
                              {"enabled": False}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertNotIn("sos", self.keys())
        self.client.force_authenticate(self.owner)
        self.client.patch("/api/v1/admin/discover/cards/%d" % sos.pk, {"enabled": True},
                          format="json")
        ids = list(DiscoverCard.objects.exclude(pk=sos.pk).values_list("id", flat=True))
        r = self.client.post("/api/v1/admin/discover/reorder", {"ids": ids + [sos.pk]},
                             format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(self.keys()[-1], "sos")
        # a new feature item (blood donor) appears only once its flag is ON
        self.client.force_authenticate(self.owner)
        r = self.client.post("/api/v1/admin/discover/cards",
                             {"type": "FEATURE", "title_bn": "রক্তদাতা", "title_en": "Blood donor",
                              "route": "blood_panel", "icon": "bloodtype"}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        self.assertNotIn(r.data["key"], self.keys())
        _flag("blood_donors", enabled_all=True, enabled_play=True, rollout_pct=100)
        self.assertIn(r.data["key"], self.keys())

    def test_sponsor_booked_next_to_sos_is_moved_and_labelled(self):
        sos = DiscoverCard.objects.get(key="sos")
        DiscoverCard.objects.create(key="sp-x", type="SPONSORED", title_bn="দোকান",
                                    title_en="Shop", url="https://shop.example.com",
                                    sponsor_name="Shop", order=sos.order + 1)
        self.client.force_authenticate(self.u)
        cards = self.client.get("/api/v1/discover/cards").data["cards"]
        keys = [c["key"] for c in cards]
        i = keys.index("sp-x")
        self.assertEqual(keys[0], "sos")
        self.assertGreater(i, 1)
        self.assertEqual(cards[i]["label"], "sponsored")
        # the owner preview shows the same enforced order
        self.client.force_authenticate(self.owner)
        p = self.client.get("/api/v1/admin/discover/preview?segment=free").data["cards"]
        self.assertEqual([c["key"] for c in p], keys)
