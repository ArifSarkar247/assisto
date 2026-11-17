"""staging (owner order 17 Nov): the allow-listed TEST entitlement for the
owner's "Assisto Test" app (purchases disabled there). Off by default; only
listed account ids; only premium/business; never a purchase (no order, no
payment row); /me/plan says "test_plan" so it is never shown as paid; it ends
when the id leaves the list."""
from django.test import TestCase, override_settings
from rest_framework.test import APIClient

from core import plans
from core.models import PaymentOrder, User

_n = [0]


def _user():
    _n[0] += 1
    return User.objects.create_user(name="T%d" % _n[0], phone="0171%07d" % (6600000 + _n[0]),
                                    password="x")


class TestPlanEntitlement(TestCase):
    def test_off_by_default(self):
        u = _user()
        self.assertEqual(plans.test_plan(u), "")
        self.assertEqual(plans.effective_plan(u), "free")
        self.assertFalse(plans.plan_active(u))

    def test_allow_listed_account_gets_the_plan_others_do_not(self):
        a, b = _user(), _user()
        with override_settings(ASSISTO_TEST_PLAN_USERS="%d:business" % a.pk):
            self.assertEqual(plans.effective_plan(a), "business")
            self.assertTrue(plans.plan_active(a))
            self.assertEqual(plans.effective_plan(b), "free")
            self.assertFalse(plans.plan_active(b))

    def test_only_premium_or_business_and_bad_entries_ignored(self):
        u = _user()
        for raw in ("%d:founder", "%d:", "x%d:premium", "%d:premium_pro"):
            with override_settings(ASSISTO_TEST_PLAN_USERS=raw % u.pk):
                self.assertEqual(plans.test_plan(u), "", raw)
        with override_settings(ASSISTO_TEST_PLAN_USERS=" 9999:business , %d:premium " % u.pk):
            self.assertEqual(plans.effective_plan(u), "premium")

    def test_never_a_purchase_and_marked_as_test(self):
        u = _user()
        with override_settings(ASSISTO_TEST_PLAN_USERS="%d:premium" % u.pk):
            c = APIClient()
            c.force_authenticate(u)
            r = c.get("/api/v1/me/plan")
            self.assertEqual(r.status_code, 200)
            self.assertEqual(r.json()["plan"], "premium")
            self.assertEqual(r.json()["test_plan"], "premium")
            self.assertIsNone(r.json()["plan_until"])
        self.assertFalse(PaymentOrder.objects.filter(user=u).exists())
        u.refresh_from_db()
        self.assertEqual(u.plan, "free", "nothing written to the account")

    def test_ends_when_removed_from_the_list(self):
        u = _user()
        with override_settings(ASSISTO_TEST_PLAN_USERS="%d:business" % u.pk):
            self.assertEqual(plans.effective_plan(u), "business")
        self.assertEqual(plans.effective_plan(u), "free")
        c = APIClient()
        c.force_authenticate(u)
        self.assertEqual(c.get("/api/v1/me/plan").json()["test_plan"], "")
