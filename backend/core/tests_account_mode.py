"""acctmode — accounts & finance mode (personal / business / both).

Every direction of switching with entries present in BOTH books: the entry
counts (and the rows themselves) are identical before and after; the mode is a
view preference only. Existing users who never chose get "both" (nothing
hidden) plus a suggestion from what they already use.

Run: manage.py test core.tests_account_mode --settings=assisto_backend.settings_test
"""
import itertools
from datetime import date, timedelta

from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import account_mode as AM
from core.models import (Account, BusinessProfile, BusinessStaff, KhataEntry,
                         KhataParty, PaCollectionItem, Product, Transaction,
                         User)

URL = "/api/v1/account-mode"


def mk(phone, name="U"):
    return User.objects.create_user(name=name, phone=phone, password="pw12345!",
                                    language="en")


def cl(u, lang="en"):
    c = APIClient()
    c.force_authenticate(u)
    c.credentials(HTTP_ACCEPT_LANGUAGE=lang)
    return c


def add_personal(u, n=3):
    acc = Account.objects.create(user=u, name="Cash")
    for i in range(n):
        Transaction.objects.create(user=u, account=acc, amount=100 + i,
                                   date=date.today() - timedelta(days=i),
                                   category="food")


def add_business(u, parties=2):
    prof, _ = BusinessProfile.objects.get_or_create(user=u)
    for i in range(parties):
        p = KhataParty.objects.create(business=prof, book="customer",
                                      name=f"Customer {i}")
        KhataEntry.objects.create(party=p, direction="gave",
                                  amount_poisha=5000, at=timezone.now())
    Product.objects.create(user=u, business=prof, name="Rice", price=60)


def snapshot(u):
    """Every entry in both books — ids + amounts, so a move/retag shows up."""
    return {
        "txns": sorted(Transaction.objects.filter(user=u)
                       .values_list("id", "amount", "category", "account_id")),
        "accounts": sorted(Account.objects.filter(user=u).values_list("id", "name")),
        "parties": sorted(KhataParty.objects.filter(business__user=u)
                          .values_list("id", "name", "archived")),
        "entries": sorted(KhataEntry.objects.filter(party__business__user=u)
                          .values_list("id", "amount_poisha")),
        "products": sorted(Product.objects.filter(user=u).values_list("id", "name")),
    }


class PureLogicTests(TestCase):
    def test_suggest(self):
        self.assertEqual(AM.suggest(False, False), AM.PERSONAL)
        self.assertEqual(AM.suggest(True, False), AM.PERSONAL)
        self.assertEqual(AM.suggest(False, True), AM.BUSINESS)
        self.assertEqual(AM.suggest(True, True), AM.BOTH)

    def test_shows(self):
        self.assertTrue(AM.shows("both", "personal"))
        self.assertTrue(AM.shows("both", "business"))
        self.assertTrue(AM.shows("personal", "personal"))
        self.assertFalse(AM.shows("personal", "business"))
        self.assertFalse(AM.shows("business", "personal"))
        self.assertTrue(AM.shows("garbage", "business"))  # unknown -> both

    def test_normalize(self):
        self.assertEqual(AM.normalize(" Business "), "business")
        self.assertIsNone(AM.normalize("shop"))
        self.assertIsNone(AM.normalize(None))


class DefaultsTests(TestCase):
    def test_new_user_nothing_hidden(self):
        u = mk("+8801700000001")
        r = cl(u).get(URL)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["mode"], "both")
        self.assertFalse(r.data["chosen"])
        self.assertEqual(r.data["suggested"], "personal")
        self.assertEqual(r.data["hidden_with_data"], [])
        self.assertEqual(r.data["modes"], ["personal", "business", "both"])

    def test_existing_business_only_user_keeps_everything_but_gets_hint(self):
        u = mk("+8801700000002")
        add_business(u)
        r = cl(u).get(URL)
        self.assertEqual(r.data["mode"], "both")          # nothing hidden
        self.assertEqual(r.data["suggested"], "business")
        self.assertEqual(r.data["usage"]["business"]["parties"], 2)
        self.assertEqual(r.data["usage"]["business"]["products"], 1)

    def test_existing_both_user_suggested_both(self):
        u = mk("+8801700000003")
        add_personal(u)
        add_business(u)
        r = cl(u).get(URL)
        self.assertEqual(r.data["suggested"], "both")
        self.assertEqual(r.data["usage"]["personal"]["entries"], 3)

    def test_auto_created_empty_profile_is_not_business_use(self):
        # GET /business/profiles auto-creates an empty BusinessProfile.
        u = mk("+8801700000004")
        BusinessProfile.objects.create(user=u)
        r = cl(u).get(URL)
        self.assertFalse(r.data["usage"]["business"]["used"])
        self.assertEqual(r.data["suggested"], "personal")

    def test_staff_member_counts_as_business_use(self):
        boss = mk("+8801700000005")
        prof = BusinessProfile.objects.create(user=boss, shop_name="Boss shop")
        u = mk("+8801700000006")
        BusinessStaff.objects.create(business=prof, member=u, active=True)
        r = cl(u).get(URL)
        self.assertTrue(r.data["usage"]["business"]["used"])

    def test_requires_login(self):
        r = APIClient().get(URL)
        self.assertIn(r.status_code, (401, 403))


class SwitchEveryDirectionTests(TestCase):
    """personal <-> business <-> both, all 6 directions, with entries in both
    books. Nothing is deleted, moved or retagged; switching back shows all."""

    def setUp(self):
        self.u = mk("+8801711111111")
        add_personal(self.u, n=4)
        add_business(self.u, parties=3)
        self.c = cl(self.u)
        self.before = snapshot(self.u)

    def _switch(self, mode):
        r = self.c.post(URL, {"mode": mode}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data["mode"], mode)
        self.assertTrue(r.data["chosen"])
        self.assertEqual(snapshot(self.u), self.before, f"entries changed on -> {mode}")
        return r

    def test_all_six_directions(self):
        for a, b in itertools.permutations(AM.MODES, 2):
            with self.subTest(frm=a, to=b):
                self._switch(a)
                r = self._switch(b)
                expect_hidden = {"personal": ["business"], "business": ["personal"],
                                 "both": []}[b]
                self.assertEqual(r.data["hidden_with_data"], expect_hidden)
                # usage counts are still the full books
                self.assertEqual(r.data["usage"]["personal"]["entries"], 4)
                self.assertEqual(r.data["usage"]["business"]["parties"], 3)

    def test_round_trip_back_to_both_shows_everything(self):
        self._switch("personal")
        self._switch("business")
        r = self._switch("both")
        self.assertEqual(r.data["hidden_with_data"], [])
        g = self.c.get(URL)
        self.assertEqual(g.data["mode"], "both")

    def test_entries_added_while_hidden_survive_switch_back(self):
        self._switch("personal")
        # business entry written while the business area is hidden (e.g. via chat)
        prof = BusinessProfile.objects.get(user=self.u)
        KhataParty.objects.create(business=prof, book="supplier", name="Late")
        self.before = snapshot(self.u)
        r = self._switch("both")
        self.assertEqual(r.data["usage"]["business"]["parties"], 4)

    def test_one_row_with_history(self):
        for m in ("business", "personal", "both"):
            self._switch(m)
        rows = PaCollectionItem.objects.filter(user=self.u, collection="acct_mode")
        self.assertEqual(rows.count(), 1)
        hist = rows.first().data["history"]
        self.assertEqual([h["to"] for h in hist], ["business", "personal", "both"])
        self.assertEqual(hist[0]["from"], None)

    def test_persists_across_devices(self):
        self._switch("business")
        other_device = cl(self.u, lang="bn")
        self.assertEqual(other_device.get(URL).data["mode"], "business")

    def test_bad_mode_422_and_nothing_written(self):
        r = self.c.post(URL, {"mode": "shop"}, format="json")
        self.assertEqual(r.status_code, 422)
        self.assertEqual(r.data["code"], "bad_mode")
        self.assertFalse(PaCollectionItem.objects.filter(
            user=self.u, collection="acct_mode").exists())
        r = cl(self.u, lang="bn").post(URL, {}, format="json")
        self.assertEqual(r.status_code, 422)
        self.assertIn("ধরন", r.data["detail"])

    def test_isolated_per_user(self):
        other = mk("+8801722222222")
        self._switch("business")
        self.assertEqual(cl(other).get(URL).data["mode"], "both")
