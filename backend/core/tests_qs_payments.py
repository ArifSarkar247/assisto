"""qs-payments (quality sweep, owner item 5) — money invariants.

  * billing.charge: never negative, insufficient leaves balance + ledger
    untouched, ad-wallet split for free users only, safety actions free;
  * billing.credit: zero / negative grants do nothing;
  * confirm_topup: idempotent, unknown id; start_topup never grants without a
    provider; expire_credits never below zero and runs once;
  * credits are never withdrawable: no cash-out route exists;
  * gateway orders: another user's order is 404, idempotency-key reuse with a
    different SKU is refused, per-hour rate limit, an unpaid order grants
    nothing and cannot be "refunded", a pack refund reverses once.
"""
from datetime import timedelta
from unittest import mock

from django.test import TestCase
from django.urls import get_resolver
from django.utils import timezone

from core import billing
from core.models import (AdWallet, CreditLedger, CreditPurchase, PaymentOrder,
                         User)
from core.payments import service as S
from core.tests_pay1 import PayBase, _client, enable_eps

STRONG = "ai_msg_strong"


class ChargeInvariantTests(TestCase):
    def setUp(self):
        self.u = User.objects.create_user(name="Mita", phone="01711000091",
                                          password="x")
        self.need = billing.pricing.credits_for(STRONG, 1, billing.cfg())
        self.assertGreater(self.need, 0)
        g = mock.patch.object(billing, "guard_state", return_value={"over": False})
        g.start()
        self.addCleanup(g.stop)

    def _set(self, credits, ad_paisa=None):
        User.objects.filter(pk=self.u.pk).update(ai_credits=credits)
        self.u.refresh_from_db()
        if ad_paisa is not None:
            AdWallet.objects.update_or_create(user=self.u,
                                              defaults={"balance_paisa": ad_paisa})

    def test_exact_balance_reaches_zero_not_below(self):
        self._set(self.need)
        r = billing.charge(self.u, STRONG)
        self.assertTrue(r["ok"])
        self.assertEqual(r["balance"], 0)
        r2 = billing.charge(self.u, STRONG)
        self.assertFalse(r2["ok"])
        self.assertEqual(r2["reason"], "insufficient")
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 0)
        self.assertEqual(CreditLedger.objects.filter(user=self.u).count(), 1)

    def test_insufficient_changes_nothing(self):
        self._set(self.need - 1)
        r = billing.charge(self.u, STRONG)
        self.assertFalse(r["ok"])
        self.assertEqual(r["charged"], 0)
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, self.need - 1)
        self.assertFalse(CreditLedger.objects.filter(user=self.u).exists())
        self.assertEqual(billing.guard_can(self.u, STRONG), (False, "insufficient"))

    def test_qty_multiplies_and_is_checked_whole(self):
        self._set(self.need * 2)
        r = billing.charge(self.u, STRONG, qty=3)
        self.assertFalse(r["ok"])          # never a partial charge
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, self.need * 2)

    def test_free_user_spends_credits_first_then_ad_wallet(self):
        self._set(1, ad_paisa=(self.need) * 100 + 50)
        self.assertEqual(billing.guard_can(self.u, STRONG), (True, "ok"))
        r = billing.charge(self.u, STRONG)
        self.assertTrue(r["ok"])
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 0)
        w = AdWallet.objects.get(user=self.u)
        self.assertEqual(w.balance_paisa, (self.need) * 100 + 50 - (self.need - 1) * 100)
        self.assertGreaterEqual(w.balance_paisa, 0)
        reasons = sorted(CreditLedger.objects.filter(user=self.u)
                         .values_list("reason", flat=True))
        self.assertEqual(reasons, ["ad_spend", "consume"])

    def test_sub_credit_ad_paisa_is_not_spendable(self):
        self._set(self.need - 1, ad_paisa=99)   # 0.99 credit in the wallet
        self.assertFalse(billing.charge(self.u, STRONG)["ok"])
        self.assertEqual(AdWallet.objects.get(user=self.u).balance_paisa, 99)

    def test_paid_user_cannot_spend_ad_wallet(self):
        User.objects.filter(pk=self.u.pk).update(
            plan="premium", plan_until=timezone.now() + timedelta(days=30))
        self.u.refresh_from_db()
        with mock.patch.object(billing, "ensure_monthly_pool", return_value=0):
            self._set(0, ad_paisa=10_000)
            r = billing.charge(self.u, STRONG)
        self.assertFalse(r["ok"])
        self.assertEqual(AdWallet.objects.get(user=self.u).balance_paisa, 10_000)

    def test_guard_over_blocks_free_costly_but_never_safety(self):
        self._set(100)
        with mock.patch.object(billing, "guard_state", return_value={"over": True}):
            self.assertEqual(billing.charge(self.u, STRONG)["reason"], "guard_over")
            self.assertTrue(billing.charge(self.u, "sos")["ok"])
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 100)

    def test_safety_action_is_free_even_at_zero(self):
        self._set(0)
        r = billing.charge(self.u, "sos")
        self.assertTrue(r["ok"])
        self.assertEqual(r["charged"], 0)
        self.assertFalse(CreditLedger.objects.exists())

    def test_credit_rejects_zero_and_negative(self):
        self._set(5)
        self.assertEqual(billing.credit(self.u, "adjust", 0), 5)
        self.assertEqual(billing.credit(self.u, "adjust", -50), 5)
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 5)
        self.assertFalse(CreditLedger.objects.exists())
        # unknown source maps to 'adjust', never an arbitrary reason
        billing.credit(self.u, "cashout", 2)
        self.assertEqual(CreditLedger.objects.get().reason, "adjust")


class TopupAndExpiryTests(TestCase):
    def setUp(self):
        self.u = User.objects.create_user(name="Joy", phone="01711000092",
                                          password="x")

    def test_start_topup_without_provider_grants_nothing(self):
        with mock.patch.object(billing, "enabled_payment_provider", return_value=""):
            r = billing.start_topup(self.u, "p50")
        self.assertFalse(r["ok"])
        self.assertIn(r["state"], ("needs_provider", "bad_pack", "disabled"))
        self.u.refresh_from_db()
        self.assertEqual(int(self.u.ai_credits or 0), 0)
        self.assertFalse(CreditPurchase.objects.exists())

    def test_confirm_topup_idempotent_and_unknown(self):
        self.assertEqual(billing.confirm_topup(999999)["reason"], "not_found")
        p = CreditPurchase.objects.create(user=self.u, pack_id="p50", price_bdt=50,
                                          credits=55, provider="bkash",
                                          status="pending")
        r1 = billing.confirm_topup(p.id, "T1")
        r2 = billing.confirm_topup(p.id, "T1")
        self.assertEqual(r1["granted"], 55)
        self.assertEqual(r2["granted"], 0)
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 55)
        self.assertEqual(CreditLedger.objects.filter(user=self.u).count(), 1)

    def test_expire_never_below_zero_and_runs_once(self):
        now = timezone.now()
        CreditPurchase.objects.create(user=self.u, pack_id="p50", price_bdt=50,
                                      credits=55, provider="eps",
                                      status="confirmed", granted=True,
                                      expires_at=now - timedelta(days=1))
        User.objects.filter(pk=self.u.pk).update(ai_credits=7)   # spent most
        self.assertEqual(billing.expire_credits(now), 7)
        self.assertEqual(billing.expire_credits(now), 0)
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 0)


class NoWithdrawalRouteTests(TestCase):
    def test_no_cash_out_endpoint_exists(self):
        def walk(patterns, prefix=""):
            for p in patterns:
                if hasattr(p, "url_patterns"):
                    yield from walk(p.url_patterns, prefix + str(p.pattern))
                else:
                    yield prefix + str(p.pattern)
        routes = [r.lower() for r in walk(get_resolver().url_patterns)]
        # samity_payouts = the user's own savings-group record book (a
        # tracker, no money moves through Assisto) — not a credit cash-out.
        bad = [r for r in routes
               if any(w in r for w in ("withdraw", "cashout", "cash-out",
                                       "payout", "redeem-cash"))
               and "samity_payouts" not in r]
        self.assertEqual(bad, [])


class GatewayOrderEdgeTests(PayBase):
    def setUp(self):
        super().setUp()
        enable_eps()

    def test_other_users_order_is_404(self):
        o = self.buy_gw("premium_monthly", pay=False)
        other = User.objects.create_user(name="Other", phone="01711000093",
                                         password="x")
        r = _client(other).get("/api/v1/payments/orders/%d" % o.id)
        self.assertEqual(r.status_code, 404)
        self.assertEqual(self.api.get("/api/v1/payments/orders/%d" % o.id)
                         .status_code, 200)

    def test_idempotency_key_bound_to_sku(self):
        a = S.checkout(self.u, "premium_monthly", idem="k1")
        b = S.checkout(self.u, "premium_monthly", idem="k1")
        self.assertEqual(a.pk, b.pk)
        with self.assertRaises(S.PayError) as e:
            S.checkout(self.u, "pack_p50", idem="k1")
        self.assertEqual(e.exception.reason, "idempotency_conflict")

    def test_hourly_rate_limit(self):
        for _ in range(15):
            S.checkout(self.u, "pack_p50")
        with self.assertRaises(S.PayError) as e:
            S.checkout(self.u, "pack_p50")
        self.assertEqual(e.exception.status, 429)

    def test_unpaid_order_grants_nothing_and_cannot_be_refunded(self):
        o = self.buy_gw("pack_p50", pay=False)
        o = S.complete(o)      # gateway still says Cancel
        self.assertNotEqual(o.status, "paid")
        self.u.refresh_from_db()
        self.assertEqual(int(self.u.ai_credits or 0), 0)
        _, changed = S.refund_order(o)
        self.assertFalse(changed)
        self.assertFalse(CreditLedger.objects.filter(user=self.u).exists())

    def test_failed_payment_status_grants_nothing(self):
        o = self.buy_gw("pack_p50", status="Failed")
        self.assertNotEqual(o.status, "paid")
        self.u.refresh_from_db()
        self.assertEqual(int(self.u.ai_credits or 0), 0)

    def test_pack_refund_reverses_once(self):
        o = self.buy_gw("pack_p50")
        self.u.refresh_from_db()
        got = self.u.ai_credits
        self.assertGreater(got, 0)
        o2, ch1 = S.refund_order(o)
        _, ch2 = S.refund_order(o2)
        self.assertTrue(ch1)
        self.assertFalse(ch2)
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 0)
        self.assertEqual(CreditLedger.objects.filter(user=self.u, delta__lt=0)
                         .count(), 1)
        # a refunded order is never re-granted by a late verify
        S.complete(PaymentOrder.objects.get(pk=o.pk), via="ipn")
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 0)
