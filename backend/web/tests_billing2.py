"""billing-v2 owner panel (owner order 27 Oct; rules K, L, Q, R, U + the
add-ons): refund requests page (approve / custom / reject), flagged users,
billing reports, unverified plans and credits, the payment audit labels
(+20 credits, TEST, Bangla label), the user page ledger + buckets, the
verified Paid count and the Pricing "billing" section."""
from datetime import timedelta
from decimal import Decimal
from unittest import mock

from django.utils import timezone

from core import credits as CR
from core.models import (CreditAccount, EntitlementGrant, OwnerAudit, PaidOrder,
                         PaymentEvent, RefundRequest, User)
from core.payments import entitlement as E, refunds as R
from web.tests_o2_owner_admin import OwnerBase


class BillingPanelTests(OwnerBase):
    def setUp(self):
        super().setUp()
        self.u = User.objects.create_user(name="Rina", phone="01711000301", password="x")
        q = mock.patch("core.push.push_to_user", return_value=0)
        q.start()
        self.addCleanup(q.stop)
        self.ready()
        self.o = PaidOrder.objects.create(
            channel="gateway", order_id="17000000000001", user=self.u, kind="pack",
            sku="pack_p20", price=Decimal("20"), purchased_at=timezone.now() - timedelta(hours=2),
            credits_planned=20)
        CR.grant(self.u, CR.PACK, 20, reason="topup", order=self.o, key="gateway:x:pack")

    def test_refund_requests_page_and_actions(self):
        req = R.create_request(self.u, self.o.pk, "not needed")
        r = self.c.get("/owner/payments/refunds?lang=en")
        self.assertEqual(r.status_code, 200)
        for s in ("Suggested refund", "Approve suggested", "Approve custom amount", "Reject",
                  "17000000000001", "20.00 BDT"):
            self.assertContains(r, s)
        r = self.c.get("/owner/payments/refunds?lang=bn")
        self.assertContains(r, "প্রস্তাবিত রিফান্ড")
        bad = self.post("/owner/payments/refunds", {"req": req.pk, "action": "approve_custom",
                                                    "amount": "999", "note": "x"})
        self.assertEqual(bad.status_code, 400)
        ok = self.post("/owner/payments/refunds", {"req": req.pk, "action": "approve_custom",
                                                   "amount": "10.00", "note": "half"})
        self.assertEqual(ok.status_code, 302)
        req.refresh_from_db()
        self.assertEqual((req.status, req.approved_amount), ("manual", Decimal("10.00")))
        self.assertTrue(OwnerAudit.objects.filter(action="refund.approve_custom").exists())
        self.assertEqual(CR.buckets(self.u)["pack"], 0)

    def test_reject_needs_a_note(self):
        req = R.create_request(self.u, self.o.pk, "x")
        r = self.post("/owner/payments/refunds", {"req": req.pk, "action": "reject", "note": ""})
        self.assertEqual(r.status_code, 400)
        self.post("/owner/payments/refunds", {"req": req.pk, "action": "reject", "note": "policy"})
        self.assertEqual(RefundRequest.objects.get().status, "rejected")

    def test_flagged_list_and_unblock(self):
        CreditAccount.objects.create(user=self.u, refund_count=2, flagged=True,
                                     flag_reason="google refund x2", purchase_blocked=True)
        r = self.c.get("/owner/payments/flagged?lang=en")
        self.assertContains(r, "google refund x2")
        self.post("/owner/payments/flagged", {"user": self.u.pk, "note": "talked to user"})
        self.assertFalse(R.purchase_blocked(self.u))

    def test_reports_and_unverified_pages(self):
        from core.payments import reconcile as RC
        RC.credits_verify()
        r = self.c.get("/owner/payments/reports?lang=en")
        self.assertContains(r, "credits_verify")
        rogue = User.objects.create_user(name="Rg", phone="01711000302", password="x")
        User.objects.filter(pk=rogue.pk).update(plan="premium",
                                                plan_until=timezone.now() + timedelta(days=9))
        rev = User.objects.create_user(name="Rv", phone="01711000303", password="x")
        E.owner_grant(rev, plan="premium", until=timezone.now() + timedelta(days=300),
                      source="play_reviewer", reason="seed")
        r = self.c.get("/owner/payments/unverified?lang=en")
        self.assertContains(r, "/owner/users/%d" % rogue.pk)
        self.assertContains(r, "Play reviewer grant")

    def test_payment_audit_labels_credits_not_taka_and_test_tag(self):
        PaymentEvent.objects.create(user=self.u, kind="credits.grant", channel="play", ref="x",
                                    detail={"credits": 20, "test": True})
        PaymentEvent.objects.create(user=self.u, kind="play.test_charge", channel="play", ref="GPA.T")
        r = self.c.get("/owner/payments?lang=en")
        html = r.content.decode()
        self.assertIn("+20 credits", html)
        self.assertNotIn("৳20.00", html)
        self.assertIn("TEST", html)
        self.assertIn("Play test purchase", html)
        r = self.c.get("/owner/payments?lang=bn")
        self.assertContains(r, "+20 ক্রেডিট")
        self.assertContains(r, "ক্রেডিট যোগ")

    def test_user_page_ledger_buckets_invariant_and_grants(self):
        E.owner_grant(self.u, plan="premium", until=timezone.now() + timedelta(days=30),
                      source="play_reviewer", reason="seed")
        r = self.c.get("/owner/users/%d?lang=en" % self.u.pk)
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "Balance = ledger sum = buckets")
        self.assertContains(r, "Play reviewer grant")
        self.assertContains(r, "full ledger")
        self.assertContains(r, "+20 credits")

    def test_owner_plan_edit_is_a_recorded_grant(self):
        self.post("/owner/users/%d" % self.u.pk, {"action": "plan", "plan": "premium",
                                                  "days": "30", "reason": "gift"})
        g = EntitlementGrant.objects.get(user=self.u)
        self.assertEqual((g.source, g.actor_id, g.reason), ("owner_grant", self.owner.pk, "gift"))

    def test_dashboard_paid_count_separates_trials_tests_grants(self):
        E.owner_grant(self.u, plan="premium", until=timezone.now() + timedelta(days=30),
                      source="play_reviewer", reason="seed")
        r = self.c.get("/owner/?lang=en")
        self.assertContains(r, "Owner/system grants: 1")
        self.assertContains(r, "Trials: 0")

    def test_pricing_billing_section_editable_with_labels(self):
        r = self.c.get("/owner/pricing?lang=en")
        self.assertContains(r, "Staged unlock: % usable at once")
        self.assertContains(r, "Trial: days")
        r = self.post("/owner/pricing", {"section": "billing", "billing.unlock_pct": "30",
                                         "billing.unlock_hours": "24",
                                         "billing.refund_window_hours": "24",
                                         "billing.profit_guard_min_bdt": "20",
                                         "reason": "test"})
        self.assertEqual(r.status_code, 302, r.content[:300])
        from core import billing
        self.assertEqual(billing.cfg()["billing"]["unlock_pct"], 30)
        self.assertEqual(billing.cfg()["billing"]["refund_window_hours"], 24)
