"""billing-v2 — owner order 27 Oct 2026: BILLING, CREDIT AND REFUND HARDENING.
One test class per rule A..V plus the owner add-ons (recorded grants,
verified "Paid" count, unverified-plans scan, trial once per person).
Google is ALWAYS mocked (FakeGoogle): no real refund API is ever called."""
import threading
from datetime import datetime, timedelta, timezone as dt_tz
from decimal import Decimal
from io import StringIO
from unittest import mock

from django.core.management import call_command
from django.db import IntegrityError, OperationalError, connection, transaction
from django.test import TestCase, TransactionTestCase
from django.utils import timezone

from core import billing, credits as CR, plans
from core.models import (AdWallet, AIUsage, BillingReport, CreditAccount, CreditLedger,
                         CreditLot, CreditPurchase, EntitlementGrant, FamilyAlert,
                         FreeGrantClaim, PaidOrder, PaymentEvent, PhotoAdTicket, PlanPeriod,
                         PlayPurchase, RefundRequest, User)
from core.payments import catalog, entitlement as E, orders as O, play, reconcile as RC
from core.payments import refunds as R, service as S
from core.tests_pay1 import PayBase, PlayBase, _client, enable_eps, sub_body

PREM, BIZ = 90, 240


def usable(n):
    return n * 20 // 100


def ledger_ok(u):
    v = CR.verify(u)
    return v["ok"], v


class Base(TestCase):
    def setUp(self):
        self.u = User.objects.create_user(name="Mina", phone="01711005001", password="x")


# ======================================================================= A ledger
class A_LedgerTests(Base):
    def test_append_only(self):
        CR.grant(self.u, CR.FREE, 5, note="t")
        row = CreditLedger.objects.get(user=self.u)
        row.note = "edited"
        with self.assertRaises(ValueError):
            row.save()
        with self.assertRaises(ValueError):
            row.delete()

    def test_every_change_is_one_row_with_bucket_and_source(self):
        CR.grant(self.u, CR.PACK, 20, reason="topup", source_type="play", source_id="GPA.1",
                 key="k:pack")
        r = CR.spend(self.u, 3, note="ai")
        CR.return_spend(self.u, r["spend_ref"])
        rows = list(CreditLedger.objects.filter(user=self.u).order_by("id"))
        self.assertEqual([(x.reason, x.delta, x.bucket) for x in rows],
                         [("topup", 20, "pack"), ("consume", -3, "pack"), ("return", 3, "pack")])
        self.assertEqual(rows[0].source_id, "GPA.1")
        self.assertEqual(rows[-1].balance_after, 20)
        self.assertTrue(ledger_ok(self.u)[0])

    def test_grant_key_is_db_unique(self):
        self.assertIsNotNone(CR.grant(self.u, CR.FREE, 5, key="once"))
        self.assertIsNone(CR.grant(self.u, CR.FREE, 5, key="once"))
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 5)
        with self.assertRaises(IntegrityError), transaction.atomic():
            CreditLot.objects.create(user=self.u, bucket="free", grant_key="once")

    def test_credits_verify_command_reports_mismatch(self):
        CR.grant(self.u, CR.FREE, 5)
        out = StringIO()
        call_command("credits_verify", stdout=out)
        self.assertIn("0 mismatch", out.getvalue())
        User.objects.filter(pk=self.u.pk).update(ai_credits=50)   # a rogue direct write
        out = StringIO()
        with self.assertRaises(SystemExit):
            call_command("credits_verify", stdout=out)
        self.assertIn("MISMATCH user #%d" % self.u.pk, out.getvalue())
        self.assertFalse(BillingReport.objects.filter(kind="credits_verify").first().ok)

    def test_ad_wallet_path_moves_the_balance(self):
        """audit #7: ad credits used to be ledger rows without balance."""
        from core import integrations
        from core.models import Integration
        integrations.save("admob", {"app_id": "x"})
        Integration.objects.filter(slug="admob").update(status="working")
        c = billing.get_config()
        c.data = {**(c.data or {}), "ad_rewards": {"ecpm_bdt": 3000.0}}
        c.save()
        with mock.patch.object(billing, "flag_on", return_value=True), \
                mock.patch("core.integrations.is_enabled", return_value=True):
            r = billing.ad_event(self.u, "rewarded", verified=True)
        self.assertTrue(r["ok"])
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 2)
        self.assertEqual(CR.buckets(self.u)["rewarded"], 2)
        self.assertTrue(ledger_ok(self.u)[0])


# ======================================================================= B buckets
class B_BucketTests(Base):
    def test_spend_order_plan_then_free_rewarded_then_pack(self):
        now = timezone.now()
        CR.grant(self.u, CR.PACK, 20, reason="topup")
        CR.grant(self.u, CR.FREE, 5)
        CR.grant(self.u, CR.REWARDED, 3, reason="rewarded")
        CR.grant(self.u, CR.PLAN, 10, expires_at=now + timedelta(days=5))
        User.objects.filter(pk=self.u.pk).update(plan="premium", plan_until=now + timedelta(days=5))
        self.u.refresh_from_db()
        with mock.patch.object(CR, "_base_allowance", return_value=0):
            CR.spend(self.u, 12, note="a")
            self.assertEqual(CR.buckets(self.u)["plan"], 0)
            self.assertEqual(CR.buckets(self.u)["free"] + CR.buckets(self.u)["rewarded"], 6)
            CR.spend(self.u, 7, note="b")
        b = CR.buckets(self.u)
        self.assertEqual((b["free"], b["rewarded"], b["pack"]), (0, 0, 19))

    def test_pack_never_expires(self):
        CR.grant(self.u, CR.PACK, 20, reason="topup")
        CR.settle(self.u, now=timezone.now() + timedelta(days=3650))
        self.assertEqual(CR.buckets(self.u)["pack"], 20)
        self.assertIsNone(CreditLot.objects.get(user=self.u).expires_at)

    def test_plan_allowance_expires_with_ledger_row_when_plan_ends(self):
        """The owner's leak: 20 + Premium 90 + P20 = 130, Premium expired, 130 kept."""
        now = timezone.now()
        CR.grant(self.u, CR.FREE, 20, note="founding:1")
        User.objects.filter(pk=self.u.pk).update(plan="premium", plan_until=now + timedelta(minutes=25))
        self.u.refresh_from_db()
        CR.settle(self.u, now)                       # base month 90 (no payment)
        CR.grant(self.u, CR.PACK, 20, reason="topup")
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 130)
        CR.settle(self.u, now + timedelta(minutes=30))   # plan over
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 40)
        self.assertTrue(CreditLedger.objects.filter(user=self.u, reason="expire",
                                                    delta=-90, bucket="plan").exists())
        self.assertTrue(ledger_ok(self.u)[0])

    def test_cached_total_follows_direct_writes(self):
        User.objects.filter(pk=self.u.pk).update(ai_credits=7)
        self.u.refresh_from_db()
        CR.settle(self.u)
        self.assertEqual(CR.buckets(self.u)["legacy"], 7)
        User.objects.filter(pk=self.u.pk).update(ai_credits=3)
        CR.settle(self.u)
        self.assertEqual(CR.buckets(self.u)["legacy"], 3)


# ======================================================================= Play helpers
class PlayCase(PlayBase):
    ORD = "GPA.4400-0000-0000-00000"

    def sub(self, token="t", user=None, **kw):
        kw.setdefault("order", self.ORD)
        self.g.subs[token] = sub_body(user or self.u, **kw)
        return self.g.subs[token]

    def rt(self, token, nt, mid):
        r = self.rtdn_push(self.sn(token, nt), mid=mid)
        self.assertEqual(r.status_code, 200, r.content)
        return r.json()["outcome"]

    def bal(self, u=None):
        u = u or self.u
        u.refresh_from_db()
        return u.ai_credits

    def plan_bucket(self):
        return CR.buckets(self.u)["plan"]


# ======================================================================= C annual
class C_AnnualTests(PlayCase):
    def test_annual_grants_month_by_month(self):
        self.sub(base_plan="annual", expiry_days=365)
        self.verify("t")
        lots = CreditLot.objects.filter(user=self.u, bucket="plan")
        self.assertEqual(lots.filter(status="active").count(), 1)
        self.assertEqual(lots.filter(status="scheduled").count(), 11)
        self.assertEqual(self.bal(), usable(PREM))          # never 12 x 90 upfront
        m2 = lots.filter(status="scheduled").order_by("starts_at").first()
        CR.settle(self.u, now=m2.starts_at + timedelta(hours=1))
        m2.refresh_from_db()
        self.assertEqual(m2.status, "active")
        self.assertEqual(self.plan_bucket(), PREM)          # month 1 expired, month 2 in
        self.assertTrue(CreditLedger.objects.filter(user=self.u, reason="expire").exists())

    def test_months_follow_the_paid_period_not_the_calendar(self):
        po = PaidOrder.objects.create(
            channel="play", order_id="GPA.ANN", user=self.u, kind="sub", plan="premium",
            months=12, sku="premium_yearly", purchased_at=timezone.now(),
            period_start=datetime(2026, 10, 31, 10, 0, tzinfo=dt_tz.utc),
            period_end=datetime(2027, 10, 31, 10, 0, tzinfo=dt_tz.utc))
        with mock.patch("django.utils.timezone.now",
                        return_value=datetime(2026, 10, 31, 10, 5, tzinfo=dt_tz.utc)):
            O.grant_allowance(po, source_prefix="play:x", now=datetime(2026, 10, 31, 10, 5, tzinfo=dt_tz.utc))
        starts = list(CreditLot.objects.filter(order=po).order_by("starts_at")
                      .values_list("starts_at", flat=True))
        self.assertEqual(starts[1], datetime(2026, 11, 30, 10, 0, tzinfo=dt_tz.utc))
        self.assertEqual(starts[3], datetime(2027, 1, 31, 10, 0, tzinfo=dt_tz.utc))
        self.assertEqual(len(starts), 12)


# ======================================================================= D idempotency
class D_IdempotencyTests(PlayCase):
    def test_rtdn_retry_restore_and_double_verify_grant_once(self):
        self.sub()
        self.assertEqual(self.rt("t", 4, "m1"), "sub:PURCHASED:SUBSCRIPTION_STATE_ACTIVE")
        self.assertEqual(self.rt("t", 4, "m1"), "duplicate")       # Pub/Sub retry
        self.rt("t", 4, "m2")                                       # resend, new id
        self.verify("t")
        self.verify("t")                                              # restore / reinstall
        self.assertEqual(PaidOrder.objects.count(), 1)
        self.assertEqual(CreditLot.objects.filter(user=self.u, bucket="plan").count(), 1)
        self.assertEqual(self.bal(), usable(PREM))

    def test_latest_successful_order_id_is_preferred(self):
        b = self.sub(order="GPA.OLD-FIELD")
        b["lineItems"][0]["latestSuccessfulOrderId"] = "GPA.NEW-FIELD"
        self.verify("t")
        self.assertTrue(PaidOrder.objects.filter(order_id="GPA.NEW-FIELD").exists())
        self.assertFalse(PaidOrder.objects.filter(order_id="GPA.OLD-FIELD").exists())

    def test_pack_double_client_verify_and_rtdn(self):
        self.g.products["p"] = {"purchaseState": 0, "consumptionState": 0, "orderId": "GPA.P1",
                                "obfuscatedExternalAccountId": play.account_id(self.u)}
        self.verify("p", kind="pack", product="credits_p20")
        self.verify("p", kind="pack", product="credits_p20")
        self.rtdn_push({"packageName": "com.assisto.assisto",
                        "oneTimeProductNotification": {"purchaseToken": "p", "sku": "credits_p20",
                                                       "notificationType": 1}}, mid="o")
        self.assertEqual(CR.buckets(self.u)["pack"], 20)


# ======================================================================= E never trust
class E_NeverTrustTests(PlayCase):
    def test_revoked_payload_is_rechecked_with_google(self):
        self.sub()
        self.verify("t")
        self.assertEqual(self.rt("t", 12, "r"), "revoked:unconfirmed")
        self.assertEqual(plans.effective_plan(User.objects.get(pk=self.u.pk)), "premium")

    def test_voided_payload_needs_the_voided_api(self):
        self.sub()
        self.verify("t")
        r = self.rtdn_push({"packageName": "com.assisto.assisto",
                            "voidedPurchaseNotification": {"purchaseToken": "t", "orderId": self.ORD}},
                           mid="v")
        self.assertEqual(r.json()["outcome"], "voided:unconfirmed")
        self.assertEqual(PaidOrder.objects.get().status, "paid")

    def test_client_price_is_ignored_and_oidc_required(self):
        self.sub(price_units="1")                         # Google list price used, not client
        r = self.api.post("/api/v1/payments/play/verify",
                          {"kind": "sub", "product_id": "assisto_premium", "purchase_token": "t",
                           "price": "0"}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(self.rt("t", 4, "x"), "sub:PURCHASED:SUBSCRIPTION_STATE_ACTIVE")
        r = self.rtdn_push(self.sn("t", 4), mid="noauth", auth=False)
        self.assertEqual(r.status_code, 401)

    def test_paid_period_end_is_googles_expiry_never_local(self):
        """Owner add-on: a paid period's end always comes from subscriptionsv2."""
        b = self.sub(expiry_days=17.25)
        self.verify("t")
        exp = play._ts(b["lineItems"][0]["expiryTime"])
        self.assertEqual(PlanPeriod.objects.get(source="play").ends_at, exp)
        self.assertEqual(PaidOrder.objects.get().period_end, exp)
        self.assertEqual(CreditLot.objects.get(bucket="plan").expires_at, exp)


# ======================================================================= F binding
class F_BindingTests(PlayCase):
    def test_token_never_grants_a_second_account(self):
        other = User.objects.create_user(name="M", phone="01811005002", password="x")
        self.sub()
        self.assertEqual(self.verify("t", api=_client(other)).status_code, 403)
        self.verify("t")
        self.assertEqual(self.verify("t", api=_client(other)).status_code, 403)
        self.assertEqual(self.bal(other), 0)

    def test_no_account_id_is_refused(self):
        b = self.sub()
        del b["externalAccountIdentifiers"]
        r = self.verify("t")
        self.assertEqual((r.status_code, r.json()["reason"]), (409, "unbound_purchase"))

    def test_deleted_account_leaves_a_tombstone(self):
        self.sub()
        self.verify("t")
        uid = self.u.pk
        from core.account_purge import purge_user
        purge_user(self.u)
        pp = PlayPurchase.objects.get()
        self.assertIsNone(pp.user_id)
        self.assertTrue(pp.owner_ref.startswith("u%d-" % uid))
        new = User.objects.create_user(name="New", phone="01711005001", password="x")
        self.g.subs["t"] = sub_body(new)
        self.assertEqual(self.verify("t", api=_client(new)).status_code, 403)
        self.assertEqual(self.bal(new), 0)
        self.assertEqual(PaidOrder.objects.get().user_id, None)     # refund still matches


# ======================================================================= G purchased only
class G_PurchasedOnlyTests(PlayCase):
    def test_pending_grants_nothing(self):
        self.sub(state="SUBSCRIPTION_STATE_PENDING")
        self.verify("t")
        self.assertEqual(self.bal(), 0)
        self.g.products["p"] = {"purchaseState": 2, "orderId": "GPA.P",
                                "obfuscatedExternalAccountId": play.account_id(self.u)}
        r = self.verify("p", kind="pack", product="credits_p20")
        self.assertEqual(r.json()["state"], "pending")
        self.assertEqual(self.bal(), 0)

    def test_ack_only_after_the_grant_succeeded(self):
        self.sub()
        with mock.patch.object(O, "grant_allowance", side_effect=RuntimeError("db down")):
            with self.assertRaises(RuntimeError):
                play.sync_subscription("t", self.u)
        self.assertEqual(self.g.acks, [])
        self.verify("t")
        self.assertEqual(self.g.acks, ["t"])
        self.assertEqual(self.bal(), usable(PREM))

    def test_consume_only_after_grant(self):
        self.g.products["p"] = {"purchaseState": 0, "consumptionState": 0, "orderId": "GPA.P",
                                "obfuscatedExternalAccountId": play.account_id(self.u)}
        with mock.patch.object(E, "grant_pack", side_effect=RuntimeError("x")):
            with self.assertRaises(RuntimeError):
                play.sync_pack("p", "credits_p20", self.u)
        self.assertEqual(self.g.consumed, [])


# ======================================================================= H states
class H_StateTests(PlayCase):
    def test_every_state(self):
        self.sub()
        self.rt("t", 4, "buy")
        self.assertEqual(self.bal(), usable(PREM))
        # RENEWED: new order -> old allowance expires, new one (staged) arrives
        self.sub(order=self.ORD + "..0", expiry_days=60, ack=True)
        self.rt("t", 2, "renew")
        self.assertEqual(self.plan_bucket(), usable(PREM))
        self.assertEqual(PaidOrder.objects.count(), 2)
        # GRACE: access kept, NO new allowance
        self.sub(order=self.ORD + "..0", expiry_days=3, ack=True,
                 state="SUBSCRIPTION_STATE_IN_GRACE_PERIOD")
        self.rt("t", 6, "grace")
        self.assertEqual(plans.effective_plan(User.objects.get(pk=self.u.pk)), "premium")
        self.assertEqual(PaidOrder.objects.count(), 2)
        # ON HOLD: access removed + plan credits expire
        self.sub(order=self.ORD + "..0", expiry_days=-1, ack=True, state="SUBSCRIPTION_STATE_ON_HOLD")
        self.rt("t", 5, "hold")
        self.assertEqual((self.plan_bucket(), plans.effective_plan(User.objects.get(pk=self.u.pk))),
                         (0, "free"))
        # RECOVERED: new paid order -> allowance
        self.sub(order=self.ORD + "..1", expiry_days=30, ack=True)
        self.rt("t", 1, "recover")
        self.assertEqual(self.plan_bucket(), usable(PREM))
        # PAUSED: removed; RESUMED (new order) restored
        self.sub(order=self.ORD + "..1", ack=True, state="SUBSCRIPTION_STATE_PAUSED")
        self.rt("t", 10, "pause")
        self.assertEqual(self.plan_bucket(), 0)
        self.sub(order=self.ORD + "..2", ack=True)
        self.rt("t", 7, "resume")
        self.assertEqual(self.plan_bucket(), usable(PREM))
        # CANCELED: kept until expiry
        self.sub(order=self.ORD + "..2", ack=True, state="SUBSCRIPTION_STATE_CANCELED")
        self.rt("t", 3, "cancel")
        self.assertEqual(self.plan_bucket(), usable(PREM))
        # EXPIRED: removed
        self.sub(order=self.ORD + "..2", ack=True, expiry_days=-1, state="SUBSCRIPTION_STATE_EXPIRED")
        self.rt("t", 13, "exp")
        self.assertEqual(self.plan_bucket(), 0)
        self.assertTrue(ledger_ok(self.u)[0])

    def test_revoked_removes_now(self):
        self.sub()
        self.verify("t")
        self.sub(state="SUBSCRIPTION_STATE_EXPIRED", expiry_days=-1)
        self.assertEqual(self.rt("t", 12, "rev"), "revoked")
        self.assertEqual(self.plan_bucket(), 0)
        self.assertEqual(plans.effective_plan(User.objects.get(pk=self.u.pk)), "free")

    def test_upgrade_premium_to_business_never_doubles(self):
        self.sub("old")
        self.verify("old")
        self.sub("new", product="assisto_business", linked="old", order="GPA.BIZ")
        self.verify("new", product="assisto_business")
        b = CR.buckets(self.u)
        self.assertEqual(b["plan"], usable(BIZ))
        self.assertTrue(CreditLedger.objects.filter(user=self.u, reason="expire",
                                                    note__contains="replaced").exists())
        self.assertEqual(plans.effective_plan(User.objects.get(pk=self.u.pk)), "business")
        self.assertEqual(PlanPeriod.objects.get(ref=play.ref_for("old")).status, "replaced")

    def test_monthly_to_annual_replaces(self):
        self.sub("m")
        self.verify("m")
        self.sub("y", base_plan="annual", expiry_days=365, linked="m", order="GPA.Y")
        self.verify("y")
        self.assertEqual(self.plan_bucket(), usable(PREM))
        self.assertEqual(CreditLot.objects.filter(user=self.u, status="scheduled").count(), 11)


# ======================================================================= I staged unlock
class I_StagedUnlockTests(PlayCase):
    def test_20pct_now_rest_after_48h_edges(self):
        self.sub()
        self.verify("t")
        lot = CreditLot.objects.get(bucket="plan")
        self.assertEqual((lot.remaining, lot.locked), (usable(PREM), PREM - usable(PREM)))
        st = self.api.get("/api/v1/credits/state").json()
        self.assertEqual((st["now_usable"], st["locked"]), (18, 72))
        self.assertEqual(st["unlocks_at"], lot.unlocks_at.isoformat())
        CR.settle(self.u, now=lot.unlocks_at - timedelta(minutes=1))     # 47h59m
        self.assertEqual(self.bal(), 18)
        CR.settle(self.u, now=lot.unlocks_at + timedelta(minutes=1))     # 48h01m
        self.assertEqual(self.bal(), PREM)
        self.assertTrue(CreditLedger.objects.filter(user=self.u, reason="unlock", delta=72).exists())

    def test_pct_and_hours_are_owner_editable_and_bounded(self):
        from core.logic import billing_cfg, pricing
        self.assertIn("bad_billing", pricing.validate_edit({"billing": {"unlock_pct": 150}}))
        self.assertIn("bad_refund_window", pricing.validate_edit({"billing": {"refund_window_hours": 36}}))
        c = billing.get_config()
        c.data = {**c.data, "billing": {"unlock_pct": 50, "unlock_hours": 24}}
        c.save()
        self.sub()
        self.verify("t")
        lot = CreditLot.objects.get(bucket="plan")
        self.assertEqual((lot.remaining, lot.locked), (45, 45))
        self.assertAlmostEqual((lot.unlocks_at - lot.starts_at).total_seconds(), 24 * 3600, delta=5)
        self.assertEqual(billing_cfg.normalize({"unlock_pct": -3})["unlock_pct"], 0)

    def test_every_renewal_is_staged(self):
        self.sub()
        self.verify("t")
        self.sub(order=self.ORD + "..0", expiry_days=60, ack=True)
        self.rt("t", 2, "r")
        lot = CreditLot.objects.filter(bucket="plan", status="active").get()
        self.assertEqual((lot.remaining, lot.locked), (18, 72))


# ======================================================================= J/K refunds
class JK_RefundTests(PlayCase):
    def setUp(self):
        super().setUp()
        self.sub()
        self.verify("t")
        self.o = PaidOrder.objects.get()

    def ask(self, hours):
        PaidOrder.objects.filter(pk=self.o.pk).update(
            purchased_at=timezone.now() - timedelta(hours=hours))
        return self.api.post("/api/v1/credits/refunds", {"purchase_id": self.o.pk,
                                                         "reason": "did not need it"},
                             format="json")

    def test_window_edges(self):
        r = self.ask(48 + 1 / 60.0)                       # 48h01m
        self.assertEqual((r.status_code, r.json()["reason"]), (409, "outside_window"))
        self.assertIn("policy", r.json())
        r = self.ask(47 + 59 / 60.0)                      # 47h59m
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(self.ask(1).json()["reason"], "already_requested")

    def test_window_24h_setting(self):
        c = billing.get_config()
        c.data = {**c.data, "billing": {"refund_window_hours": 24}}
        c.save()
        self.assertEqual(self.ask(25).json()["reason"], "outside_window")
        lst = self.api.get("/api/v1/credits/refunds").json()
        self.assertEqual(lst["window_hours"], 24)

    def test_suggestion_is_the_lower_share(self):
        CR.settle(self.u, now=CreditLot.objects.get(bucket="plan").unlocks_at + timedelta(seconds=1))
        CR.spend(self.u, 45, note="ai")                         # 50% of credits used
        PaidOrder.objects.filter(pk=self.o.pk).update(
            period_start=timezone.now() - timedelta(days=3),
            period_end=timezone.now() + timedelta(days=27))     # 10% of days used
        self.o.refresh_from_db()
        amt, u = O.suggested_refund(self.o)
        self.assertEqual(amt, (Decimal("199") * Decimal("0.5")).quantize(Decimal("0.01")))
        self.assertEqual(u["credits_used"], 45)

    def test_approve_partial_shows_console_steps_and_removes_unused(self):
        CR.spend(self.u, 9, note="ai")
        r = R.create_request(self.u, self.o.pk, "x")
        R.approve(r, None)
        r.refresh_from_db()
        self.assertEqual((r.status, r.action), ("manual", "play_console"))
        self.assertTrue(any("Partial refund" in s for s in r.result["steps"]))
        self.assertEqual(self.g.refunds, [])                  # no API call for a partial
        self.assertEqual(self.plan_bucket(), 0)
        self.assertEqual(plans.effective_plan(User.objects.get(pk=self.u.pk)), "free")
        self.assertTrue(FamilyAlert.objects.filter(user=self.u, kind="billing").exists())
        self.assertTrue(ledger_ok(self.u)[0])

    def test_approve_full_calls_orders_refund_through_the_seam(self):
        r = R.create_request(self.u, self.o.pk, "x")
        R.approve(r, None, amount=Decimal("199.00"))
        r.refresh_from_db()
        self.assertEqual((r.status, r.action), ("approved", "play_api"))
        self.assertEqual(self.g.refunds, [self.ORD + ":refund"])
        self.assertEqual(PaidOrder.objects.get().status, "refunded")
        # Google's later voided notice for OUR refund is not a 2nd refund
        self.g.void("t", self.ORD)
        self.rtdn_push({"packageName": "com.assisto.assisto",
                        "voidedPurchaseNotification": {"purchaseToken": "t", "orderId": self.ORD}},
                       mid="v")
        self.assertFalse(CreditAccount.objects.filter(user=self.u, refund_count__gt=0).exists())
        self.assertGreaterEqual(self.bal(), 0)

    def test_reject_with_note_notifies(self):
        r = R.create_request(self.u, self.o.pk, "x")
        R.reject(r, None, "outside policy")
        self.assertEqual(RefundRequest.objects.get().status, "rejected")
        self.assertTrue(FamilyAlert.objects.filter(user=self.u, kind="billing").exists())

    def test_pack_refund_suggestion_is_unused_credits_only(self):
        self.g.products["p"] = {"purchaseState": 0, "consumptionState": 0, "orderId": "GPA.PK",
                                "obfuscatedExternalAccountId": play.account_id(self.u)}
        self.verify("p", kind="pack", product="credits_p20")
        po = PaidOrder.objects.get(kind="pack")
        CR.spend(self.u, 18 + 5, note="ai")                  # plan 18 first, then 5 from pack
        amt, u = O.suggested_refund(po)
        self.assertEqual(u["credits_used"], 5)
        self.assertEqual(amt, Decimal("15.00"))


# ======================================================================= L Google refunds
class L_GoogleRefundTests(PlayCase):
    def pack(self, tok, order):
        self.g.products[tok] = {"purchaseState": 0, "consumptionState": 0, "orderId": order,
                                "obfuscatedExternalAccountId": play.account_id(self.u)}
        self.verify(tok, kind="pack", product="credits_p20")

    def void(self, tok, order, mid):
        self.g.void(tok, order)
        return self.rtdn_push({"packageName": "com.assisto.assisto",
                               "voidedPurchaseNotification": {"purchaseToken": tok, "orderId": order,
                                                              "productType": 2, "refundType": 1}},
                              mid=mid).json()["outcome"]

    def test_spent_credits_go_negative_and_block(self):
        self.pack("p", "GPA.L1")
        CR.spend(self.u, 15, note="ai")
        self.assertEqual(self.void("p", "GPA.L1", "v"), "voided")
        self.assertEqual(self.bal(), -15)
        r = billing.charge(self.u, "ai_msg_cheap")
        self.assertEqual((r["ok"], r.get("negative")), (False, True))
        self.assertEqual(billing.guard_can(self.u, "ai_msg_cheap")[0], False)
        self.assertTrue(self.api.get("/api/v1/credits/state").json()["blocked"])
        self.assertTrue(ledger_ok(self.u)[0])
        CR.grant(self.u, CR.PACK, 20, reason="topup")              # back above zero
        self.assertTrue(billing.charge(self.u, "ai_msg_cheap")["ok"])

    def test_second_refund_blocks_purchases_until_owner_unblocks(self):
        self.pack("p1", "GPA.L1")
        self.void("p1", "GPA.L1", "v1")
        self.assertFalse(R.purchase_blocked(self.u))
        self.pack("p2", "GPA.L2")
        self.void("p2", "GPA.L2", "v2")
        self.assertTrue(R.purchase_blocked(self.u))
        acct = CreditAccount.objects.get(user=self.u)
        self.assertEqual((acct.refund_count, acct.flagged), (2, True))
        enable_eps()
        with self.assertRaises(S.PayError) as cm:
            S.checkout(self.u, "pack_p20")
        self.assertEqual(cm.exception.reason, "purchase_blocked")
        cfg = self.api.get("/api/v1/payments/config?flavour=play").json()
        self.assertEqual((cfg["purchasable"], cfg["purchase_blocked"]), (False, True))
        R.unblock(self.u, None, "ok")
        self.assertFalse(R.purchase_blocked(self.u))

    def test_daily_voided_poll_catches_a_missed_rtdn(self):
        self.pack("p", "GPA.POLL")
        self.g.void("p", "GPA.POLL")
        out = R.voided_poll()
        self.assertEqual(out["processed"], 1)
        self.assertEqual(R.voided_poll()["processed"], 0)            # idempotent
        self.assertEqual(CR.buckets(self.u)["pack"], 0)
        self.assertTrue(BillingReport.objects.filter(kind="voided_poll").exists())
        out = StringIO()
        call_command("play_voided_poll", stdout=out)
        self.assertIn("play_voided_poll", out.getvalue())

    def test_old_renewal_refund_keeps_the_running_subscription(self):
        self.sub()
        self.verify("t")
        self.sub(order=self.ORD + "..0", expiry_days=60, ack=True)
        self.rt("t", 2, "r")
        self.g.void("t", self.ORD)
        self.rtdn_push({"packageName": "com.assisto.assisto",
                        "voidedPurchaseNotification": {"purchaseToken": "t", "orderId": self.ORD,
                                                       "productType": 1, "refundType": 1}}, mid="v")
        self.assertEqual(plans.effective_plan(User.objects.get(pk=self.u.pk)), "premium")
        self.assertEqual(PaidOrder.objects.get(order_id=self.ORD).status, "voided")
        self.assertEqual(PaidOrder.objects.get(order_id=self.ORD + "..0").status, "paid")


# ======================================================================= M policy page
class M_PolicyPageTests(TestCase):
    def test_refund_policy_bn_en_with_company_email(self):
        from web import legal_content as LC
        r = self.client.get("/refund-policy")
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "রিফান্ড নীতি")
        self.assertContains(r, LC.facts("bn")["email"])
        r = self.client.get("/refund-policy?lang=en")
        self.assertContains(r, "Only the <b>unused part</b> is refunded", html=False)
        self.assertContains(r, "Cancelling is not a refund")
        r = self.client.get("/?lang=en")
        self.assertContains(r, "/refund-policy?lang=en")


# ======================================================================= N atomic spend
class N_SpendTests(Base):
    def test_failed_call_returns_to_the_same_bucket(self):
        CR.grant(self.u, CR.REWARDED, 2, reason="rewarded")
        CR.grant(self.u, CR.PACK, 20, reason="topup")
        r = billing.charge(self.u, "ai_msg_medium")              # 3 credits: 2 rewarded + 1 pack
        self.assertTrue(r["ok"])
        billing.credit(self.u, "adjust", r["charged"], note="ai_refund", spend_ref=r["spend_ref"])
        b = CR.buckets(self.u)
        self.assertEqual((b["rewarded"], b["pack"], b["free"]), (2, 20, 0))
        # a caller that does not pass spend_ref still lands in the same lots
        r = billing.charge(self.u, "ai_msg_medium")
        billing.credit(self.u, "adjust", 3, note="retention sms refund")
        b = CR.buckets(self.u)
        self.assertEqual((b["rewarded"], b["pack"], b["free"]), (2, 20, 0))
        self.assertEqual(CR.return_spend(self.u, r["spend_ref"]), 0)    # never twice

    def test_ai_generate_refund_uses_spend_ref(self):
        from core import ai
        CR.grant(self.u, CR.REWARDED, 6, reason="rewarded")
        self.assertIn("spend_ref=spend_ref", open(ai.__file__).read())
        r = billing.charge(self.u, "ai_msg_cheap")
        CR.return_spend(self.u, r["spend_ref"])
        self.assertEqual(CR.buckets(self.u)["rewarded"], 6)


class N_ConcurrencyTests(TransactionTestCase):
    def test_parallel_spends_never_double_spend(self):
        u = User.objects.create_user(name="C", phone="01711005099", password="x")
        CR.grant(u, CR.PACK, 5, reason="topup")
        ok, errs = [], []
        barrier = threading.Barrier(8)

        def worker():
            try:
                barrier.wait()
                for _ in range(3):
                    try:
                        if CR.spend(User.objects.get(pk=u.pk), 1, note="p")["ok"]:
                            ok.append(1)
                    except OperationalError:
                        errs.append(1)          # sqlite "table locked": a refused try
            finally:
                connection.close()

        ts = [threading.Thread(target=worker) for _ in range(8)]
        [t.start() for t in ts]
        [t.join() for t in ts]
        u.refresh_from_db()
        self.assertLessEqual(len(ok), 5)
        self.assertEqual(u.ai_credits, 5 - len(ok))
        self.assertGreaterEqual(u.ai_credits, 0)
        self.assertTrue(CR.verify(u)["ok"])


# ======================================================================= O rewarded SSV
class O_RewardedTests(Base):
    def test_client_claim_earns_nothing_and_txn_unique(self):
        r = billing.ad_event(self.u, "rewarded", verified=False)
        self.assertEqual(r["reason"], "ssv_required")
        PhotoAdTicket.objects.create(user=self.u, nonce="n1", transaction_id="tx-1")
        with self.assertRaises(IntegrityError), transaction.atomic():
            PhotoAdTicket.objects.create(user=self.u, nonce="n2", transaction_id="tx-1")

    def test_daily_cap_kept(self):
        from core.models import AdEvent
        cap = billing.cfg()["ad_rewards"]["rewarded_daily_cap"]
        for i in range(cap):
            AdEvent.objects.create(user=self.u, kind="rewarded", credited_paisa=100,
                                   at=timezone.now() - timedelta(seconds=10 + i))
        r = billing.ad_event(self.u, "rewarded", verified=True)
        self.assertEqual(r["reason"], "capped")


# ======================================================================= P anti-farming
class P_AntiFarmTests(TestCase):
    def test_trial_once_per_phone_device_email_even_after_delete(self):
        from core.account_purge import purge_user
        u = User.objects.create_user(name="T", phone="01711005010", password="x",
                                     email="t@example.com")
        self.assertEqual(plans.start_trial_button(u, device_id="DEV-1"), (True, "ok"))
        lot = CreditLot.objects.get(user=u, source_type="trial")
        self.assertEqual((lot.bucket, lot.expires_at), ("plan", u.trial_until))
        purge_user(u)
        again = User.objects.create_user(name="T2", phone="01711005010", password="x")
        self.assertEqual(plans.start_trial_button(again), (False, "trial_used_person"))
        other = User.objects.create_user(name="T3", phone="01711005011", password="x")
        self.assertEqual(plans.start_trial_button(other, device_id="DEV-1"),
                         (False, "trial_used_person"))
        mail = User.objects.create_user(name="T4", phone="01711005012", password="x",
                                        email="T@example.com")
        self.assertEqual(plans.start_trial_button(mail), (False, "trial_used_person"))
        self.assertTrue(FreeGrantClaim.objects.filter(kind="trial").exists())

    def test_trial_endpoint_message_bn_en(self):
        a = User.objects.create_user(name="A", phone="01711005020", password="x")
        b = User.objects.create_user(name="B", phone="01711005021", password="x")
        self.assertEqual(_client(a).post("/api/v1/plans/trial/start", HTTP_X_DEVICE_ID="D9").status_code, 200)
        r = _client(b).post("/api/v1/plans/trial/start", HTTP_X_DEVICE_ID="D9", HTTP_ACCEPT_LANGUAGE="en")
        self.assertEqual((r.status_code, r.json()["reason"]), (409, "trial_used_person"))
        self.assertIn("once per person", r.json()["msg"])

    def test_trial_credits_expire_when_the_trial_ends(self):
        u = User.objects.create_user(name="T", phone="01711005030", password="x")
        plans.start_trial_button(u, device_id="D-30")
        u.refresh_from_db()
        self.assertEqual(u.ai_credits, plans.trial_credits())
        CR.settle(u, now=u.trial_until + timedelta(minutes=1))
        u.refresh_from_db()
        self.assertEqual(u.ai_credits, 0)
        self.assertTrue(CreditLedger.objects.filter(user=u, reason="expire").exists())

    def test_founding_credits_not_twice_for_the_same_phone(self):
        from core import growth
        from core.account_purge import purge_user
        c = growth.cfg()
        u = User.objects.create_user(name="F", phone="01711005040", password="x")
        s1 = growth.grant_seat(u, c)
        self.assertGreater(s1.credits, 0)
        purge_user(u)
        u2 = User.objects.create_user(name="F2", phone="01711005040", password="x")
        s2 = growth.grant_seat(u2, c)
        self.assertEqual(s2.credits if s2 else 0, 0)
        u2.refresh_from_db()
        self.assertEqual(u2.ai_credits, 0)

    def test_referral_needs_a_device_id(self):
        from core import growth
        inviter = User.objects.create_user(name="I", phone="01711005050", password="x")
        inviter.referral_code = "ABC123"
        inviter.date_joined = timezone.now() - timedelta(days=3)
        inviter.save()
        invitee = User.objects.create_user(name="J", phone="01711005051", password="x")
        ok, why, _ = growth.claim(invitee, "ABC123", device_id="")
        self.assertEqual((ok, why), (False, "device_required"))

    def test_trial_settings_bounded(self):
        from core.logic import pricing
        n = pricing.normalize({"limits": {"trial_days": 500, "trial_credits": -4}})
        self.assertEqual((n["limits"]["trial_days"], n["limits"]["trial_credits"]), (90, 0))


# ======================================================================= Q reconcile
class Q_ReconcileTests(PlayCase):
    def test_missed_renewal_is_fixed_and_reported(self):
        self.sub()
        self.verify("t")
        self.sub(order=self.ORD + "..0", expiry_days=60, ack=True)     # RTDN never came
        out = RC.reconcile()
        self.assertEqual(out["changed"], 1)
        self.assertEqual(PaidOrder.objects.count(), 2)
        self.assertTrue(BillingReport.objects.filter(kind="reconcile").exists())

    def test_safety_job_expires_plans_without_rtdn(self):
        self.sub(expiry_days=1)
        self.verify("t")
        later = timezone.now() + timedelta(days=2)
        self.assertGreater(CR.settle_all(now=later), 0)
        self.assertEqual(self.plan_bucket(), 0)

    def test_billing_daily_runs_every_step(self):
        out = StringIO()
        call_command("billing_daily", stdout=out)
        for k in ("voided_poll", "reconcile", "credits_verify", "profit_guard"):
            self.assertIn(k, out.getvalue())
        out = StringIO()
        call_command("profit_guard_rollover", stdout=out)
        self.assertIn("expired=", out.getvalue())


# ======================================================================= R profit guard
class R_ProfitGuardTests(Base):
    def test_user_costing_more_than_paid_is_listed(self):
        AIUsage.objects.create(user=self.u, feature="x", model="m", cost_usd=1.0)   # ৳120
        rich = User.objects.create_user(name="R", phone="01711005061", password="x")
        AIUsage.objects.create(user=rich, feature="x", model="m", cost_usd=1.0)
        PaidOrder.objects.create(channel="play", order_id="GPA.R", user=rich, kind="sub",
                                 plan="premium", price=Decimal("199"), purchased_at=timezone.now())
        out = RC.profit_guard_users(push=True)
        ids = [r["user"] for r in out["users"]]
        self.assertIn(self.u.pk, ids)
        self.assertNotIn(rich.pk, ids)


# ======================================================================= S/T test tag + EPS
class S_TestPurchaseTests(PlayCase):
    def test_test_purchase_tagged_never_revenue(self):
        self.sub(test=True)
        self.verify("t")
        self.assertTrue(PaidOrder.objects.get().is_test)
        self.assertTrue(PlayPurchase.objects.get().is_test)
        self.assertFalse(PaymentEvent.objects.filter(kind="play.charge").exists())
        self.assertEqual(billing.plan_segment_counts()["paid"], 0)


class T_EpsTests(PayBase):
    def setUp(self):
        super().setUp()
        enable_eps()

    def test_eps_sub_and_pack_use_the_same_rules(self):
        o = self.buy_gw("premium_monthly")
        self.assertEqual(o.status, "paid")
        po = PaidOrder.objects.get(channel="gateway", kind="sub")
        self.assertEqual(po.period_end, PlanPeriod.objects.get(source="gateway").ends_at)
        lot = CreditLot.objects.get(bucket="plan")
        self.assertEqual((lot.remaining, lot.locked), (18, 72))
        self.buy_gw("pack_p20")
        self.assertEqual(CR.buckets(self.u)["pack"], 20)
        self.assertTrue(PaidOrder.objects.get(kind="pack").is_test)     # sandbox = TEST
        S.refund_order(o, reason="owner")
        self.assertEqual(CR.buckets(self.u)["plan"], 0)
        self.assertEqual(PaidOrder.objects.get(kind="sub").status, "refunded")
        self.assertTrue(CR.verify(self.u)["ok"])


# ======================================================================= V rebuild
class V_RebuildTests(TestCase):
    def make_user3(self):
        u = User.objects.create_user(name="U3", phone="01711005003", password="x")
        t0 = timezone.now() - timedelta(hours=3)
        rows = [(20, "grant", "founding:1", t0 - timedelta(days=3)),
                (90, "grant", "pool:%s" % timezone.localtime(t0).strftime("%Y-%m"), t0 + timedelta(minutes=6)),
                (20, "topup", "pack:p20 play", t0 + timedelta(minutes=15))]
        for d, reason, note, at in rows:
            r = CreditLedger.objects.create(user=u, delta=d, reason=reason, note=note)
            CreditLedger.objects.filter(pk=r.pk).update(created_at=at)
        User.objects.filter(pk=u.pk).update(ai_credits=130)
        PlanPeriod.objects.create(user=u, source="play", ref="play:u3", plan="premium",
                                  starts_at=t0, ends_at=t0 + timedelta(minutes=25), note="EXPIRED")
        return User.objects.get(pk=u.pk)

    def test_user3_dry_run_then_real_run(self):
        u = self.make_user3()
        out = StringIO()
        call_command("credits_rebuild_buckets", "--dry-run", stdout=out)
        self.assertIn("user #%d: before 130 (ledger 130) -> after 40" % u.pk, out.getvalue())
        self.assertIn("adjust -90", out.getvalue())
        u.refresh_from_db()
        self.assertEqual(u.ai_credits, 130)                      # dry run wrote nothing
        call_command("credits_rebuild_buckets", stdout=StringIO())
        u.refresh_from_db()
        self.assertEqual(u.ai_credits, 40)
        b = CR.buckets(u)
        self.assertEqual((b["plan"], b["free"], b["pack"]), (0, 20, 20))
        self.assertEqual(CreditLedger.objects.filter(user=u, source_id="billing_v2").get().delta, -90)
        self.assertTrue(CR.verify(u)["ok"])
        call_command("credits_rebuild_buckets", stdout=StringIO())   # idempotent
        self.assertEqual(CreditLedger.objects.filter(user=u, source_id="billing_v2").count(), 1)

    def test_active_owner_grant_pool_is_kept(self):
        u = User.objects.create_user(name="U25", phone="01711005025", password="x")
        User.objects.filter(pk=u.pk).update(plan="premium",
                                            plan_until=timezone.now() + timedelta(days=360),
                                            ai_credits=90)
        CreditLedger.objects.create(user=u, delta=90, reason="grant",
                                    note="pool:%s" % timezone.localtime().strftime("%Y-%m"))
        u.refresh_from_db()
        plan = __import__("core.rebuild_buckets", fromlist=["x"]).plan_for(u)
        self.assertEqual((plan["target"], plan["buckets"]["plan"]), (90, 90))


# ======================================================================= add-ons
class GrantAndPaidCountTests(PlayCase):
    def test_owner_and_reviewer_grants_are_recorded_never_paid(self):
        owner = User.objects.create_superuser(name="O", phone="01711005900", password="x")
        g = E.owner_grant(self.u, plan="premium", until=timezone.now() + timedelta(days=365),
                          source="play_reviewer", actor=None, reason="seed")
        self.assertEqual(g.source, "play_reviewer")
        self.assertEqual(plans.effective_plan(User.objects.get(pk=self.u.pk)), "premium")
        self.assertFalse(PaymentEvent.objects.filter(kind__in=("play.charge", "order.paid")).exists())
        c = billing.plan_segment_counts()
        self.assertEqual((c["paid"], c["grants"]), (0, 1))
        a = RC.entitlements_audit()
        self.assertFalse([r for r in a["rows"] if r["user"] == self.u.pk and
                          any(i["what"] == "plan" for i in r["items"])])
        self.assertTrue(any(x["label"] == "Play reviewer grant" for x in a["confirmed"]))
        self.assertIsNotNone(owner)

    def test_paid_count_only_real_active_payments(self):
        trial = User.objects.create_user(name="Tr", phone="01711005901", password="x")
        plans.start_trial_button(trial, device_id="D-tr")
        tester = User.objects.create_user(name="Te", phone="01711005902", password="x")
        self.g.subs["test"] = sub_body(tester, test=True, order="GPA.T")
        self.verify("test", api=_client(tester))
        expired = User.objects.create_user(name="Ex", phone="01711005903", password="x")
        self.g.subs["old"] = sub_body(expired, order="GPA.E")
        self.verify("old", api=_client(expired))
        PaidOrder.objects.filter(order_id="GPA.E").update(period_end=timezone.now() - timedelta(hours=1))
        self.sub(order="GPA.REAL")
        self.verify("t")
        c = billing.plan_segment_counts()
        self.assertEqual((c["paid"], c["premium"], c["trial"], c["test"]), (1, 1, 1, 1))

    def test_unverified_plan_found_and_reviewer_fixed(self):
        rogue = User.objects.create_user(name="Rg", phone="01711005904", password="x")
        User.objects.filter(pk=rogue.pk).update(plan="premium",
                                                plan_until=timezone.now() + timedelta(days=30))
        rev = User.objects.create_user(name="Rv", phone="01711005905", password="x")
        User.objects.filter(pk=rev.pk).update(plan="premium",
                                              plan_until=timezone.now() + timedelta(days=300))
        with mock.patch.dict("os.environ", {"PLAY_REVIEWER_PHONE": "01711005905"}):
            dry = RC.entitlements_audit(fix=True, dry_run=True)
            users = {r["user"]: r for r in dry["rows"]}
            self.assertIn(rogue.pk, users)
            self.assertEqual(users[rev.pk]["items"][0]["known_source"], "play_reviewer")
            self.assertFalse(EntitlementGrant.objects.exists())
            out = StringIO()
            call_command("entitlements_audit", "--fix", stdout=out)
        self.assertTrue(EntitlementGrant.objects.filter(user=rev, source="play_reviewer").exists())
        self.assertFalse(EntitlementGrant.objects.filter(user=rogue).exists())
        self.assertEqual(plans.effective_plan(User.objects.get(pk=rev.pk)), "premium")

    def test_seed_play_reviewer_uses_the_grant_path(self):
        env = {"PLAY_REVIEWER_PHONE": "01011112222", "PLAY_REVIEWER_PASSWORD": "a-long-password-1"}
        with mock.patch.dict("os.environ", env):
            call_command("seed_play_reviewer", stdout=StringIO())
        g = EntitlementGrant.objects.get(source="play_reviewer")
        self.assertEqual(g.plan, "premium")
        self.assertFalse(PaidOrder.objects.exists())


class BaseMonthNoDoublingTests(TestCase):
    def test_pre_v2_pool_and_rebuilt_pool_are_never_doubled(self):
        u = User.objects.create_user(name="U25", phone="01711005125", password="x")
        User.objects.filter(pk=u.pk).update(plan="premium",
                                            plan_until=timezone.now() + timedelta(days=360),
                                            ai_credits=90)
        CreditLedger.objects.create(user=u, delta=90, reason="grant",
                                    note="pool:%s" % timezone.localtime().strftime("%Y-%m"))
        u.refresh_from_db()
        CR.settle(u)                                   # deploy, before the rebuild
        u.refresh_from_db()
        self.assertEqual(u.ai_credits, 90)
        call_command("credits_rebuild_buckets", stdout=StringIO())
        CR.settle(u)
        u.refresh_from_db()
        self.assertEqual((u.ai_credits, CR.buckets(u)["plan"]), (90, 90))
        self.assertTrue(CR.verify(u)["ok"])
        CR.settle(u, now=timezone.now() + timedelta(days=32))   # next month: one new month
        u.refresh_from_db()
        self.assertEqual(CR.buckets(u)["plan"], 90)
