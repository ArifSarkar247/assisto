"""pay-e2e — end-to-end payment journeys the app depends on (mocked Google).

  * restore on a new phone / reinstall: the SAME account re-verifies its
    tokens (idempotent: no second grant, no second revenue row).
  * restore on ANOTHER Assisto account signed in to the same Google account:
    refused (other_account), nothing granted twice — subscriptions AND packs,
    with or without the obfuscated account id on the token.
  * plan changes: monthly <-> yearly and Premium <-> Business are allowed by
    precheck (Play replaces the token); the same sku is refused.
  * /payments/state carries the Play status (active / canceled / grace /
    on_hold / paused) + package + product id for the app's deep link.
"""
from django.utils import timezone

from core.models import CreditPurchase, PaymentEvent, PlayPurchase, User
from core.payments import entitlement as E, play

from .tests_pay1 import PlayBase, _client, sub_body


def _pack_body(user, aid=None, state=0, order="GPA.3311-0000-0000-00001"):
    b = {"kind": "androidpublisher#productPurchase", "purchaseState": state,
         "consumptionState": 0, "orderId": order, "acknowledgementState": 0,
         "regionCode": "BD"}
    if aid is not False:
        b["obfuscatedExternalAccountId"] = aid or play.account_id(user)
    return b


class RestoreTwoAccountTests(PlayBase):
    def setUp(self):
        super().setUp()
        self.b = User.objects.create_user(name="Karim", phone="01811000009", password="x")
        self.api_b = _client(self.b)

    def test_restore_same_account_is_idempotent(self):
        self.g.subs["tokA"] = sub_body(self.u)
        self.assertEqual(self.verify("tokA").status_code, 200)
        # new phone: the app re-sends every owned token
        r = self.verify("tokA")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()["entitled"])
        self.assertEqual(PaymentEvent.objects.filter(kind="play.charge").count(), 1)
        self.assertEqual(PlayPurchase.objects.filter(user=self.u).count(), 1)

    def test_sub_restore_on_other_account_refused(self):
        self.g.subs["tokA"] = sub_body(self.u)
        self.verify("tokA")
        r = self.verify("tokA", api=self.api_b)
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()["reason"], "other_account")
        self.assertTrue(r.json()["message"])
        self.b.refresh_from_db()
        self.u.refresh_from_db()
        self.assertEqual(self.b.plan, "free")
        self.assertEqual(self.u.plan, "premium")       # A keeps it
        self.assertEqual(PaymentEvent.objects.filter(kind="play.charge").count(), 1)

    def test_sub_restore_first_on_other_account_refused_by_account_id(self):
        # A bought on phone 1 (RTDN not yet arrived, never verified); B tries
        # to restore it first on phone 2: the obfuscated id says it is A's.
        self.g.subs["tokA"] = sub_body(self.u)
        r = self.verify("tokA", api=self.api_b)
        self.assertEqual(r.status_code, 403)
        self.assertFalse(PlayPurchase.objects.filter(user=self.b).exists())
        # ... and A can still claim it afterwards
        self.assertEqual(self.verify("tokA").status_code, 200)

    def test_pack_restore_on_other_account_refused_no_double_credits(self):
        self.g.products["ptok"] = _pack_body(self.u)
        r = self.verify("ptok", kind="pack", product="credits_p50")
        self.assertEqual(r.status_code, 200, r.content)
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 55)
        r = self.verify("ptok", kind="pack", product="credits_p50", api=self.api_b)
        self.assertEqual(r.status_code, 403)
        self.b.refresh_from_db()
        self.assertEqual(self.b.ai_credits, 0)
        # same account restoring again: no second grant
        self.verify("ptok", kind="pack", product="credits_p50")
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 55)
        self.assertEqual(CreditPurchase.objects.filter(provider="play_billing").count(), 1)

    def test_pack_without_account_id_binds_to_first_verifier_only(self):
        # billing-v2 rule F: a purchase without obfuscatedExternalAccountId is
        # never given to whoever submits it first
        self.g.products["ptok"] = _pack_body(self.u, aid=False)
        r = self.verify("ptok", kind="pack", product="credits_p20")
        self.assertEqual((r.status_code, r.json()["reason"]), (409, "unbound_purchase"))
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 0)
        r = self.verify("ptok", kind="pack", product="credits_p20", api=self.api_b)
        self.assertEqual(r.status_code, 409)
        self.b.refresh_from_db()
        self.assertEqual(self.b.ai_credits, 0)

    def test_pending_pack_then_completed(self):
        self.g.products["ptok"] = _pack_body(self.u, state=2)
        r = self.verify("ptok", kind="pack", product="credits_p20")
        self.assertEqual(r.json()["state"], "pending")
        self.g.products["ptok"]["purchaseState"] = 0
        r = self.verify("ptok", kind="pack", product="credits_p20")
        self.assertEqual(r.json()["state"], "granted")
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 20)
        self.assertEqual(self.g.consumed, ["ptok"])


class PlanChangePrecheckTests(PlayBase):
    def pre(self, sku):
        return self.api.post("/api/v1/payments/play/precheck", {"sku": sku}, format="json")

    def test_same_sku_refused_other_period_and_tiers_allowed(self):
        self.g.subs["tokM"] = sub_body(self.u)
        self.verify("tokM")
        r = self.pre("premium_monthly")
        self.assertEqual((r.status_code, r.json()["reason"]), (409, "already_active"))
        self.assertEqual(self.pre("premium_yearly").status_code, 200)     # period change
        self.assertEqual(self.pre("business_monthly").status_code, 200)   # upgrade

    def test_downgrade_allowed_and_replacement_ends_old_period(self):
        self.g.subs["tokB"] = sub_body(self.u, product="assisto_business", price_units="499")
        self.verify("tokB", product="assisto_business")
        self.assertEqual(self.pre("premium_monthly").status_code, 200)
        self.g.subs["tokB"]["subscriptionState"] = "SUBSCRIPTION_STATE_EXPIRED"
        self.g.subs["tokP"] = sub_body(self.u, linked="tokB", order="GPA.3300-0000-0000-00009")
        self.verify("tokP")
        self.u.refresh_from_db()
        self.assertEqual(self.u.plan, "premium")
        # after the replacement the new sku is the running one
        self.assertEqual(self.pre("premium_monthly").status_code, 409)
        self.assertEqual(self.pre("business_monthly").status_code, 200)


class PlayStatusSummaryTests(PlayBase):
    def state(self):
        return self.api.get("/api/v1/payments/state").json()

    def test_none_without_play(self):
        self.assertIsNone(self.state()["play"])

    def test_active_then_canceled_keeps_plan_until_end(self):
        self.g.subs["t"] = sub_body(self.u)
        self.verify("t")
        s = self.state()
        self.assertEqual(s["play"]["status"], "active")
        self.assertEqual(s["play"]["product_id"], "assisto_premium")
        self.assertEqual(s["play"]["package"], "com.assisto.assisto")
        self.assertTrue(s["managed_by_play"])
        self.g.subs["t"]["subscriptionState"] = "SUBSCRIPTION_STATE_CANCELED"
        self.g.subs["t"]["lineItems"][0]["autoRenewingPlan"]["autoRenewEnabled"] = False
        self.rtdn_push(self.sn("t", 3), mid="c1")
        s = self.state()
        self.assertEqual(s["play"]["status"], "canceled")
        self.assertFalse(s["play"]["auto_renew"])
        self.assertEqual(s["plan"], "premium")

    def test_grace_keeps_plan_and_hold_removes_it_but_still_shows(self):
        self.g.subs["t"] = sub_body(self.u)
        self.verify("t")
        self.g.subs["t"]["subscriptionState"] = "SUBSCRIPTION_STATE_IN_GRACE_PERIOD"
        self.rtdn_push(self.sn("t", 6), mid="g1")
        s = self.state()
        self.assertEqual((s["play"]["status"], s["plan"]), ("grace", "premium"))
        self.g.subs["t"]["subscriptionState"] = "SUBSCRIPTION_STATE_ON_HOLD"
        self.rtdn_push(self.sn("t", 5), mid="h1")
        s = self.state()
        self.assertEqual(s["play"]["status"], "on_hold")
        self.assertEqual(s["plan"], "free")
        self.assertFalse(s["managed_by_play"])
        # payment fixed -> RECOVERED
        self.g.subs["t"]["subscriptionState"] = "SUBSCRIPTION_STATE_ACTIVE"
        self.rtdn_push(self.sn("t", 1), mid="r1")
        s = self.state()
        self.assertEqual((s["play"]["status"], s["plan"]), ("active", "premium"))

    def test_revoked_and_expired_not_shown(self):
        self.g.subs["t"] = sub_body(self.u)
        self.verify("t")
        self.g.subs["t"]["subscriptionState"] = "SUBSCRIPTION_STATE_EXPIRED"
        self.rtdn_push(self.sn("t", 12), mid="v1")
        s = self.state()
        self.assertIsNone(s["play"])
        self.assertEqual(s["plan"], "free")

    def test_other_account_never_sees_status(self):
        self.g.subs["t"] = sub_body(self.u)
        self.verify("t")
        b = User.objects.create_user(name="Karim", phone="01811000009", password="x")
        self.assertIsNone(E.summary(b, timezone.now())["play"])
