"""pay1 — payments: entitlement matrix, EPS gateway (checkout / return / IPN
valid-invalid-replayed-mismatch), Google Play verification + RTDN states,
website /premium OTP checkout, owner switches, per-channel P&L, sweep.

No network: EPS and Google are FAITHFUL MOCKS of the official contracts.
  * EPS: request/response shapes recorded from the public EPS sandbox
    (sandboxpgapi.eps.com.bd) with EPS's published demo merchant; the mock
    rejects a wrong x-hash exactly like the sandbox ("Invalid hash provided.").
  * Google: Play Developer API v3 purchases.subscriptionsv2 / products and the
    RTDN Pub/Sub push envelope; the OIDC token is signed with a throw-away RSA
    key generated per test run (no key material in the repo).
"""
import base64
import hashlib
import hmac
import json
from datetime import timedelta
from decimal import Decimal
from unittest import mock
from urllib.parse import parse_qs, urlparse

from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from core import integrations
from core.models import (CreditLedger, CreditPurchase, DailyLedger, Integration,
                         PaymentEvent, PaymentOrder, PlanPeriod, PlayPurchase, User)
from core.payments import catalog, entitlement as E, eps, play, service as S

HASH_KEY = "test-hash-key-not-real"
IPN_KEY = "test-ipn-key-not-real"


def _client(user):
    c = APIClient()
    c.credentials(HTTP_AUTHORIZATION="Token " + Token.objects.get_or_create(user=user)[0].key)
    return c


def enable_eps(**extra):
    cfg = {"merchant_id": "m-test", "store_id": "s-test", "username": "u@test",
           "password": "pw-test", "hash_key": HASH_KEY, "mode": "sandbox"}
    cfg.update(extra)
    integrations.save("eps", cfg)
    Integration.objects.filter(slug="eps").update(status="working")
    eps.reset_cache()


def _h(v):
    return base64.b64encode(hmac.new(HASH_KEY.encode(), v.encode(), hashlib.sha512).digest()).decode()


class FakeEps:
    """Faithful mock of the EPS API (shapes as recorded from the sandbox)."""
    def __init__(self):
        self.sessions = {}          # tx -> {"amount":..., "status":...}
        self.status_override = {}   # tx -> dict overrides
        self.calls = []

    def pay(self, tx, status="Success", amount=None, eps_tx=None):
        s = self.sessions[tx]
        s["status"] = status
        if amount is not None:
            s["paid_amount"] = amount
        s["eps_tx"] = eps_tx or ("F%sE" % tx[-10:])

    def __call__(self, method, url, body=None, headers=None):
        headers = headers or {}
        self.calls.append((method, url))
        u = urlparse(url)
        if u.path == "/v1/Auth/GetToken":
            if headers.get("x-hash") != _h(body["userName"]):
                return 200, {"token": None, "expireDate": None,
                             "errorMessage": "Invalid hash provided.", "errorCode": "400"}
            return 200, {"token": "eyJ.fake.token", "expireDate":
                         (timezone.now() + timedelta(hours=1)).isoformat(),
                         "errorMessage": None, "errorCode": None}
        if headers.get("Authorization") != "Bearer eyJ.fake.token":
            return 401, {}
        if u.path == "/v1/EPSEngine/InitializeEPS":
            tx = body["merchantTransactionId"]
            if headers.get("x-hash") != _h(tx):
                return 200, {"TransactionId": None, "RedirectURL": None,
                             "ErrorMessage": "Invalid hash provided.", "ErrorCode": "400"}
            self.sessions[tx] = {"amount": body["totalAmount"], "status": "Cancel",
                                 "body": body}
            return 200, {"TransactionId": "baaae310-e606-4345-9bdc-97777ec38898",
                         "RedirectURL": "https://sandboxpg.eps.com.bd/PG?data=baaae310",
                         "ErrorMessage": "", "ErrorCode": None, "FinancialEntityList": None}
        if u.path == "/v1/EPSEngine/CheckMerchantTransactionStatus":
            tx = parse_qs(u.query)["merchantTransactionId"][0]
            if headers.get("x-hash") != _h(tx):
                return 200, {"MerchantTransactionId": None, "Status": None,
                             "ErrorCode": 400, "ErrorMessage": "Invalid hash provided."}
            s = self.sessions.get(tx)
            if s is None:
                return 200, {"MerchantTransactionId": None, "Status": None, "ErrorCode": 404,
                             "ErrorMessage": "Transaction not found"}
            out = {"MerchantTransactionId": tx, "EPSTransactionId": s.get("eps_tx", "F264304081022F"),
                   "Status": s["status"],
                   "TotalAmount": "%.2f" % float(s.get("paid_amount", s["amount"])),
                   "StoreAmount": "0", "TransactionDate": "22 Oct 2026 02:04:43 PM",
                   "TransactionType": "Purchase", "FinancialEntity": "bKash",
                   "ErrorCode": None, "ErrorMessage": None, "CustomerName": "Test",
                   "ValueA": s["body"]["ValueA"], "ProductName": s["body"]["ProductName"]}
            out.update(self.status_override.get(tx, {}))
            return 200, out
        return 404, {}


class PayBase(TestCase):
    def setUp(self):
        self.u = User.objects.create_user(name="Rina", phone="01711000001", password="x")
        self.api = _client(self.u)
        self.fake = FakeEps()
        p = mock.patch("core.payments.eps._http", side_effect=self.fake)
        p.start()
        self.addCleanup(p.stop)
        q = mock.patch("core.push.push_to_user", return_value=1)
        self.push = q.start()
        self.addCleanup(q.stop)

    def buy_gw(self, sku, user=None, pay=True, now=None, status="Success"):
        user = user or self.u
        o = S.checkout(user, sku, now=now)
        if pay:
            self.fake.pay(o.merchant_tx_id, status=status)
            o = S.complete(o, now=now)
        return o


# ======================================================================= catalog
class CatalogTests(TestCase):
    def test_prices_from_server_table(self):
        self.assertEqual(catalog.price("premium_monthly", "gateway"), 199)
        self.assertEqual(catalog.price("business_monthly", "play"), 499)
        # p2-money: the stored 20% is clamped to the safe 9% -> 199*12*0.91
        self.assertEqual(catalog.price("premium_yearly", "gateway"), 2173)
        self.assertEqual(catalog.price("pack_p50", "gateway"), 50)
        self.assertIsNone(catalog.price("premium_weekly", "gateway"))
        self.assertIsNone(catalog.price("pack_nope", "gateway"))

    def test_channel_override_and_fees(self):
        from core import billing
        from core.views_build61 import pricing_apply
        ok, _ = pricing_apply(1, {"config": {"payments": {
            **billing.cfg()["payments"], "channel_prices": {"play": {"premium_monthly": 219}}}}})
        self.assertTrue(ok)
        self.assertEqual(catalog.price("premium_monthly", "play"), 219)
        self.assertEqual(catalog.price("premium_monthly", "gateway"), 199)
        self.assertEqual(catalog.net(100, "premium_monthly", "play"), Decimal("85.00"))
        self.assertEqual(catalog.net(100, "pack_p20", "gateway"), Decimal("98.00"))

    def test_play_product_mapping(self):
        self.assertEqual(catalog.play_product("premium_yearly"), ("assisto_premium", "annual"))
        self.assertEqual(catalog.sku_for_play("assisto_business", "monthly"), "business_monthly")
        self.assertEqual(catalog.sku_for_play("credits_p100"), "pack_p100")
        self.assertEqual(catalog.sku_for_play("somebody_else"), "")

    def test_x_hash_vector(self):
        # Base64(HMAC-SHA512(UTF8(key), UTF8(value))) — the EPS documented mechanism
        exp = base64.b64encode(hmac.new(b"k", b"1234567890", hashlib.sha512).digest()).decode()
        self.assertEqual(eps.x_hash("1234567890", "k"), exp)


# ======================================================================= entitlement matrix
class EntitlementMatrixTests(PayBase):
    def setUp(self):
        super().setUp()
        enable_eps()

    def test_buy_premium_then_stack(self):
        now = timezone.now()
        o = self.buy_gw("premium_monthly", now=now)
        self.assertEqual(o.status, "paid")
        self.u.refresh_from_db()
        self.assertEqual(self.u.plan, "premium")
        first = self.u.plan_until
        self.assertGreater(first, now + timedelta(days=27))
        self.buy_gw("premium_monthly", now=now)
        self.u.refresh_from_db()
        self.assertGreater(self.u.plan_until, first + timedelta(days=27))
        self.assertEqual(PlanPeriod.objects.filter(user=self.u, status="active").count(), 2)

    def test_upgrade_converts_unused_premium(self):
        now = timezone.now()
        self.buy_gw("premium_monthly", now=now)
        self.buy_gw("business_monthly", now=now)
        self.u.refresh_from_db()
        self.assertEqual(self.u.plan, "business")
        prem = PlanPeriod.objects.get(user=self.u, plan="premium")
        self.assertEqual(prem.status, "converted")
        # ~30 days * 199/499 ≈ 12 days of bonus on top of one month of Business
        extra = self.u.plan_until - (now + timedelta(days=28))
        self.assertGreater(extra, timedelta(days=12))

    def test_downgrade_is_queued(self):
        now = timezone.now()
        self.buy_gw("business_monthly", now=now)
        self.buy_gw("premium_monthly", now=now)
        self.u.refresh_from_db()
        self.assertEqual(self.u.plan, "business")
        prem = PlanPeriod.objects.get(user=self.u, plan="premium")
        biz = PlanPeriod.objects.get(user=self.u, plan="business")
        self.assertEqual(prem.starts_at, biz.ends_at)
        later = biz.ends_at + timedelta(hours=1)
        S.sweep(now=later)
        self.u.refresh_from_db()
        self.assertEqual(self.u.plan, "premium")
        self.assertEqual(self.u.plan_until, prem.ends_at)

    def test_expiry_downgrades_to_free(self):
        now = timezone.now()
        self.buy_gw("premium_monthly", now=now)
        S.sweep(now=now + timedelta(days=40))
        self.u.refresh_from_db()
        from core import plans
        self.assertEqual(self.u.plan, "free")
        self.assertEqual(plans.effective_plan(self.u), "free")

    def test_founder_base_survives_payment(self):
        from core import founders as F
        F.grant(self.u, reason="beta", n=12)
        self.u.refresh_from_db()
        founder_until = self.u.plan_until
        now = timezone.now()
        self.buy_gw("business_monthly", now=now)
        self.u.refresh_from_db()
        self.assertEqual(self.u.plan, "business")
        S.sweep(now=now + timedelta(days=50))
        self.u.refresh_from_db()
        self.assertEqual(self.u.plan, "premium")
        self.assertEqual(self.u.plan_until, founder_until)

    def test_same_plan_stacks_after_base(self):
        from core import founders as F
        F.grant(self.u, reason="beta", n=1)
        self.u.refresh_from_db()
        base_until = self.u.plan_until
        self.buy_gw("premium_monthly")
        self.u.refresh_from_db()
        p = PlanPeriod.objects.get(user=self.u)
        self.assertEqual(p.starts_at, base_until)
        self.assertEqual(self.u.plan_until, p.ends_at)

    def test_complete_twice_grants_once(self):
        o = self.buy_gw("premium_monthly")
        S.complete(o)
        S.complete(PaymentOrder.objects.get(pk=o.pk), via="ipn")
        self.assertEqual(PlanPeriod.objects.filter(user=self.u).count(), 1)
        self.assertEqual(PaymentEvent.objects.filter(kind="order.paid").count(), 1)

    def test_provider_tx_reuse_refused(self):
        o1 = self.buy_gw("premium_monthly")
        o2 = S.checkout(self.u, "premium_monthly")
        self.fake.pay(o2.merchant_tx_id, eps_tx=o1.provider_tx_id)
        o2 = S.complete(o2)
        self.assertNotEqual(o2.status, "paid")
        self.assertIn("already used", o2.detail)

    def test_refund_reverses_plan_and_revenue(self):
        o = self.buy_gw("premium_monthly")
        self.assertEqual(DailyLedger.objects.get().revenue_by_source["subs"], 195.02)
        o2, changed = S.refund_order(o, reason="customer asked")
        self.assertTrue(changed)
        self.u.refresh_from_db()
        self.assertEqual(self.u.plan, "free")
        self.assertEqual(DailyLedger.objects.get().revenue_by_source["subs"], 0.0)
        _, again = S.refund_order(o2)
        self.assertFalse(again)

    def test_pack_grant_and_refund_bounded(self):
        o = self.buy_gw("pack_p50")
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 55)
        self.assertEqual(CreditPurchase.objects.get(user=self.u).provider, "eps")
        User.objects.filter(pk=self.u.pk).update(ai_credits=10)    # spent 45
        S.refund_order(o)
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 0)
        self.assertEqual(CreditLedger.objects.filter(user=self.u, delta=-10).count(), 1)

    def test_summary_offers_renew_for_prepaid(self):
        self.buy_gw("premium_yearly")
        s = E.summary(self.u)
        self.assertEqual(s["plan"], "premium")
        self.assertEqual(s["renew"]["sku"], "premium_yearly")
        self.assertFalse(s["managed_by_play"])


# ======================================================================= EPS gateway
class GatewayFlowTests(PayBase):
    def test_honest_when_not_configured(self):
        r = self.api.post("/api/v1/payments/checkout", {"sku": "premium_monthly"}, format="json")
        self.assertEqual(r.status_code, 503)
        self.assertEqual(r.json()["reason"], "not_configured")
        self.assertFalse(PaymentOrder.objects.exists())

    def test_checkout_uses_server_price_and_idempotency(self):
        enable_eps()
        r = self.api.post("/api/v1/payments/checkout",
                          {"sku": "business_monthly", "idem": "k1", "price": 1, "amount": 1},
                          format="json")
        self.assertEqual(r.status_code, 201, r.content)
        o = r.json()["order"]
        self.assertEqual(o["amount_bdt"], "499.00")
        self.assertTrue(o["redirect_url"].startswith("https://sandboxpg.eps.com.bd/"))
        tx = PaymentOrder.objects.get().merchant_tx_id
        self.assertEqual(self.fake.sessions[tx]["amount"], 499.0)
        self.assertGreaterEqual(len(tx), 10)
        self.assertTrue(tx.isdigit())
        r2 = self.api.post("/api/v1/payments/checkout", {"sku": "business_monthly", "idem": "k1"},
                           format="json")
        self.assertEqual(r2.json()["order"]["id"], o["id"])
        self.assertEqual(PaymentOrder.objects.count(), 1)
        r3 = self.api.post("/api/v1/payments/checkout", {"sku": "premium_monthly", "idem": "k1"},
                           format="json")
        self.assertEqual(r3.status_code, 409)

    def test_unknown_sku(self):
        enable_eps()
        r = self.api.post("/api/v1/payments/checkout", {"sku": "premium_forever"}, format="json")
        self.assertEqual(r.status_code, 400)

    def test_wrong_hash_key_is_an_honest_error(self):
        enable_eps(hash_key="wrong")
        r = self.api.post("/api/v1/payments/checkout", {"sku": "premium_monthly"}, format="json")
        self.assertEqual(r.status_code, 502)
        self.assertEqual(PaymentOrder.objects.get().status, "failed")

    def test_return_url_verifies_with_status_api(self):
        enable_eps()
        o = S.checkout(self.u, "premium_monthly")
        # forged "success" redirect while EPS says Cancel -> nothing granted
        r = self.client.get("/pay/return", {"r": "success", "Status": "Success",
                                            "MerchantTransactionId": o.merchant_tx_id})
        self.assertEqual(r.status_code, 200)
        self.u.refresh_from_db()
        self.assertEqual(self.u.plan, "free")
        self.fake.pay(o.merchant_tx_id)
        # EPS sends the browser to our successUrl (carries the signed ?t=)
        t = parse_qs(urlparse(self.fake.sessions[o.merchant_tx_id]["body"]["successUrl"]).query)["t"][0]
        r = self.client.get("/pay/return", {"r": "success", "lang": "en", "t": t,
                                            "MerchantTransactionId": o.merchant_tx_id})
        self.assertContains(r, "Payment received")
        self.assertContains(r, "assisto://payments/done?order=%d" % o.pk)
        self.u.refresh_from_db()
        self.assertEqual(self.u.plan, "premium")

    def test_amount_mismatch_refused(self):
        enable_eps()
        o = S.checkout(self.u, "premium_monthly")
        self.fake.pay(o.merchant_tx_id, amount=1)
        o = S.complete(o)
        self.assertNotEqual(o.status, "paid")
        self.assertIn("amount_mismatch", o.detail)
        self.u.refresh_from_db()
        self.assertEqual(self.u.plan, "free")

    def test_tx_mismatch_refused(self):
        enable_eps()
        o = S.checkout(self.u, "premium_monthly")
        self.fake.pay(o.merchant_tx_id)
        self.fake.status_override[o.merchant_tx_id] = {"MerchantTransactionId": "9999999999"}
        o = S.complete(o)
        self.assertIn("tx_mismatch", o.detail)

    def test_cancel_then_late_success_still_completes(self):
        enable_eps()
        o = S.checkout(self.u, "premium_monthly")
        o = S.complete(o)
        self.assertEqual(o.status, "cancelled")
        self.fake.pay(o.merchant_tx_id)
        out = S.sweep(now=timezone.now() + timedelta(minutes=5))
        self.assertEqual(out["reverified"], 1)
        self.assertEqual(PaymentOrder.objects.get(pk=o.pk).status, "paid")

    def test_poll_endpoint(self):
        enable_eps()
        o = S.checkout(self.u, "pack_p20")
        self.fake.pay(o.merchant_tx_id)
        r = self.api.get("/api/v1/payments/orders/%d" % o.pk)
        self.assertEqual(r.json()["order"]["status"], "paid")
        self.assertEqual(r.json()["state"]["credits"], 20)
        other = _client(User.objects.create_user(name="B", phone="01711000009", password="x"))
        self.assertEqual(other.get("/api/v1/payments/orders/%d" % o.pk).status_code, 404)

    def test_managed_by_play_blocks_gateway_sub(self):
        enable_eps()
        now = timezone.now()
        E.upsert_play_period(self.u, ref="play:x", plan="premium", starts=now,
                             ends=now + timedelta(days=20), entitled=True, auto_renew=True)
        with self.assertRaises(S.PayError) as cm:
            S.checkout(self.u, "premium_monthly")
        self.assertEqual(cm.exception.reason, "managed_by_play")
        S.checkout(self.u, "business_monthly")     # an upgrade is allowed
        S.checkout(self.u, "pack_p20")             # packs always allowed


class IpnTests(PayBase):
    def setUp(self):
        super().setUp()
        enable_eps(ipn_key=IPN_KEY)
        self.o = S.checkout(self.u, "premium_monthly")

    def _ipn(self, payload, key=IPN_KEY):
        body = {"Data": eps.encrypt_ipn(payload, key)}
        return self.client.post("/api/v1/payments/gateway/ipn", json.dumps(body),
                                content_type="application/json")

    def _payload(self, **kw):
        p = {"transaction_id": "EPS123456789", "merchant_transaction_id": self.o.merchant_tx_id,
             "amount": 199, "store_amount": 195, "status": "SUCCESS", "payment_method": "bKash",
             "timestamp": timezone.now().isoformat()}
        p.update(kw)
        return p

    def test_valid_ipn_grants(self):
        self.fake.pay(self.o.merchant_tx_id)
        r = self._ipn(self._payload())
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["status"], "OK")
        self.u.refresh_from_db()
        self.assertEqual(self.u.plan, "premium")

    def test_forged_ipn_without_payment_grants_nothing(self):
        r = self._ipn(self._payload(status="SUCCESS"))
        self.assertEqual(r.status_code, 200)
        self.u.refresh_from_db()
        self.assertEqual(self.u.plan, "free")

    def test_bad_key_rejected(self):
        self.fake.pay(self.o.merchant_tx_id)
        r = self._ipn(self._payload(), key="attacker-key")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(PaymentOrder.objects.get().status, "pending")

    def test_plain_ipn_refused_when_key_set(self):
        self.fake.pay(self.o.merchant_tx_id)
        r = self.client.post("/api/v1/payments/gateway/ipn",
                             json.dumps(self._payload()), content_type="application/json")
        self.assertEqual(r.status_code, 400)

    def test_replay_is_noop(self):
        self.fake.pay(self.o.merchant_tx_id)
        p = self._payload()
        self.assertEqual(self._ipn(p).status_code, 200)
        r = self._ipn(p)
        self.assertEqual(r.json()["message"], "duplicate")
        self.assertEqual(PlanPeriod.objects.count(), 1)

    def test_stale_ipn_rejected(self):
        self.fake.pay(self.o.merchant_tx_id)
        r = self._ipn(self._payload(timestamp=(timezone.now() - timedelta(hours=3)).isoformat()))
        self.assertEqual(r.status_code, 400)

    def test_amount_mismatch_via_ipn(self):
        self.fake.pay(self.o.merchant_tx_id, amount=19.9)
        self._ipn(self._payload())
        self.assertNotEqual(PaymentOrder.objects.get().status, "paid")

    def test_unknown_order(self):
        r = self._ipn(self._payload(merchant_transaction_id="1111111111"))
        self.assertEqual(r.status_code, 404)


# ======================================================================= Google Play
def _rsa():
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    k = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = k.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                          serialization.NoEncryption()).decode()
    return k, pem


_KEY, _PEM = _rsa()
_OIDC_KEY, _ = _rsa()
AUD = "https://api.lifeassisto.com/api/v1/payments/play/rtdn"
PUSH_SA = "rtdn-push@assisto-test.iam.gserviceaccount.com"


def _jwk(pub, kid):
    n = pub.public_numbers()

    def b(i):
        return base64.urlsafe_b64encode(i.to_bytes((i.bit_length() + 7) // 8, "big")).rstrip(b"=").decode()
    return {"kid": kid, "kty": "RSA", "alg": "RS256", "use": "sig", "n": b(n.n), "e": b(n.e)}


def oidc(aud=AUD, email=PUSH_SA, key=None, exp_in=3600):
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import padding
    head = {"alg": "RS256", "kid": "k1", "typ": "JWT"}
    now = int(timezone.now().timestamp())
    claims = {"iss": "https://accounts.google.com", "aud": aud, "email": email,
              "email_verified": True, "iat": now, "exp": now + exp_in, "sub": "123"}
    si = play._b64url(json.dumps(head).encode()) + "." + play._b64url(json.dumps(claims).encode())
    sig = (key or _OIDC_KEY).sign(si.encode(), padding.PKCS1v15(), hashes.SHA256())
    return si + "." + play._b64url(sig)


class FakeGoogle:
    def __init__(self):
        self.subs = {}       # token -> subscriptionsv2 body
        self.products = {}   # token -> products body
        self.acks, self.consumed = [], []

    def __call__(self, method, url, body=None, headers=None):
        if url == play.TOKEN_URI:
            return 200, {"access_token": "ya29.fake", "expires_in": 3600}
        if url == play.CERTS_URI:
            return 200, {"keys": [_jwk(_OIDC_KEY.public_key(), "k1")]}
        assert headers["Authorization"] == "Bearer ya29.fake"
        path = urlparse(url).path
        tok = path.rsplit("/tokens/", 1)[-1]
        from urllib.parse import unquote
        if "/subscriptionsv2/tokens/" in path:
            js = self.subs.get(unquote(tok))
            return (200, js) if js else (404, {"error": {"message": "not found"}})
        if path.endswith(":acknowledge"):
            self.acks.append(unquote(tok.split(":")[0]))
            return 200, {}
        if path.endswith(":consume"):
            self.consumed.append(unquote(tok.split(":")[0]))
            p = self.products.get(unquote(tok.split(":")[0]))
            if p:
                p["consumptionState"] = 1
            return 200, {}
        if "/purchases/products/" in path:
            js = self.products.get(unquote(tok))
            return (200, js) if js else (404, {})
        return 404, {}


def sub_body(user, product="assisto_premium", base_plan="monthly", state="SUBSCRIPTION_STATE_ACTIVE",
             expiry_days=30, order="GPA.3300-0000-0000-00000", ack=False, linked="", price_units="199",
             aid=None, test=False):
    now = timezone.now()
    b = {"kind": "androidpublisher#subscriptionPurchaseV2", "regionCode": "BD",
         "startTime": (now - timedelta(minutes=1)).isoformat().replace("+00:00", "Z"),
         "subscriptionState": state, "latestOrderId": order,
         "acknowledgementState": "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED" if ack
         else "ACKNOWLEDGEMENT_STATE_PENDING",
         "externalAccountIdentifiers": {"obfuscatedExternalAccountId": aid or play.account_id(user)},
         "lineItems": [{"productId": product,
                        "expiryTime": (now + timedelta(days=expiry_days)).isoformat().replace("+00:00", "Z"),
                        "autoRenewingPlan": {"autoRenewEnabled": state == "SUBSCRIPTION_STATE_ACTIVE",
                                             "recurringPrice": {"currencyCode": "BDT",
                                                                "units": price_units}},
                        "offerDetails": {"basePlanId": base_plan}}]}
    if linked:
        b["linkedPurchaseToken"] = linked
    if test:
        b["testPurchase"] = {}
    return b


def rtdn(data, mid="m1"):
    return {"message": {"data": base64.b64encode(json.dumps(data).encode()).decode(),
                        "messageId": mid, "publishTime": "2026-10-22T10:00:00Z"},
            "subscription": "projects/assisto/subscriptions/play-rtdn"}


class PlayBase(PayBase):
    def setUp(self):
        super().setUp()
        integrations.save("play_billing", {
            "service_account_json": json.dumps({"type": "service_account",
                                                "client_email": "play-api@assisto-test.iam.gserviceaccount.com",
                                                "private_key": _PEM, "project_id": "assisto-test"}),
            "package_name": "com.assisto.assisto", "rtdn_audience": AUD, "rtdn_sa_email": PUSH_SA})
        Integration.objects.filter(slug="play_billing").update(status="working")
        play.reset_cache()
        self.g = FakeGoogle()
        p = mock.patch("core.payments.play._http", side_effect=self.g)
        p.start()
        self.addCleanup(p.stop)

    def verify(self, token, kind="sub", product="assisto_premium", api=None):
        return (api or self.api).post("/api/v1/payments/play/verify",
                                      {"kind": kind, "product_id": product, "purchase_token": token},
                                      format="json")

    def rtdn_push(self, data, mid="m1", auth=True, **kw):
        h = {"HTTP_AUTHORIZATION": "Bearer " + oidc(**kw)} if auth else {}
        return self.client.post("/api/v1/payments/play/rtdn", json.dumps(rtdn(data, mid)),
                                content_type="application/json", **h)

    def sn(self, token, nt):
        return {"version": "1.0", "packageName": "com.assisto.assisto",
                "eventTimeMillis": "1792656283478",
                "subscriptionNotification": {"version": "1.0", "notificationType": nt,
                                             "purchaseToken": token, "subscriptionId": "assisto_premium"}}


class PlayVerifyTests(PlayBase):
    def test_subscription_verified_acknowledged_revenue_once(self):
        self.g.subs["tok1"] = sub_body(self.u)
        r = self.verify("tok1")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertTrue(r.json()["entitled"])
        self.u.refresh_from_db()
        self.assertEqual(self.u.plan, "premium")
        self.assertEqual(self.g.acks, ["tok1"])
        ev = PaymentEvent.objects.get(kind="play.charge")
        self.assertEqual(ev.net_bdt, Decimal("169.15"))       # 199 - 15 %
        self.verify("tok1")
        self.assertEqual(PaymentEvent.objects.filter(kind="play.charge").count(), 1)
        self.assertEqual(self.g.acks, ["tok1"])

    def test_license_tester_purchase_is_not_revenue(self):
        self.g.subs["t"] = sub_body(self.u, test=True)
        self.verify("t")
        self.u.refresh_from_db()
        self.assertEqual(self.u.plan, "premium")
        self.assertFalse(PaymentEvent.objects.filter(kind="play.charge").exists())
        self.assertTrue(PaymentEvent.objects.filter(kind="play.test_charge").exists())

    def test_token_of_another_account_refused(self):
        other = User.objects.create_user(name="Mallory", phone="01811000002", password="x")
        self.g.subs["tok1"] = sub_body(self.u)
        r = self.verify("tok1", api=_client(other))
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()["reason"], "other_account")
        other.refresh_from_db()
        self.assertEqual(other.plan, "free")

    def test_forged_account_id_refused(self):
        self.g.subs["tok1"] = sub_body(self.u, aid="u%d-0000000000000000" % self.u.pk)
        self.assertEqual(self.verify("tok1").status_code, 403)

    def test_unknown_product_refused(self):
        self.g.subs["tok1"] = sub_body(self.u, product="someone_else")
        self.assertEqual(self.verify("tok1").status_code, 400)

    def test_honest_when_play_not_configured(self):
        Integration.objects.filter(slug="play_billing").delete()
        r = self.verify("tok1")
        self.assertEqual(r.status_code, 503)

    def test_upgrade_via_linked_token(self):
        self.g.subs["old"] = sub_body(self.u)
        self.verify("old")
        self.g.subs["new"] = sub_body(self.u, product="assisto_business", linked="old",
                                      order="GPA.3300-0000-0000-11111", price_units="499")
        self.verify("new", product="assisto_business")
        self.u.refresh_from_db()
        self.assertEqual(self.u.plan, "business")
        self.assertEqual(PlanPeriod.objects.get(ref=play.ref_for("old")).status, "replaced")

    def test_pack_granted_consumed_once(self):
        self.g.products["ptok"] = {"purchaseState": 0, "consumptionState": 0,
                                   "orderId": "GPA.1111-2222", "acknowledgementState": 0,
                                   "obfuscatedExternalAccountId": play.account_id(self.u)}
        r = self.verify("ptok", kind="pack", product="credits_p100")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["granted"], 115)
        self.assertEqual(self.g.consumed, ["ptok"])
        r = self.verify("ptok", kind="pack", product="credits_p100")
        self.assertEqual(r.json()["granted"], 0)
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 115)

    def test_pending_pack_grants_nothing(self):
        self.g.products["ptok"] = {"purchaseState": 2, "consumptionState": 0,
                                   "obfuscatedExternalAccountId": play.account_id(self.u)}
        r = self.verify("ptok", kind="pack", product="credits_p20")
        self.assertEqual(r.json()["state"], "pending")
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 0)

    def test_precheck_blocks_double_pay(self):
        enable_eps()
        self.buy_gw("premium_monthly")
        r = self.api.post("/api/v1/payments/play/precheck", {"sku": "premium_monthly"}, format="json")
        self.assertEqual(r.status_code, 409)
        self.assertEqual(r.json()["reason"], "prepaid_active")
        r = self.api.post("/api/v1/payments/play/precheck", {"sku": "business_monthly"}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["play_account_id"], play.account_id(self.u))


class RtdnTests(PlayBase):
    def setUp(self):
        super().setUp()
        self.g.subs["tok1"] = sub_body(self.u)
        self.verify("tok1")

    def _state(self):
        self.u.refresh_from_db()
        from core import plans
        return plans.effective_plan(self.u)

    def test_auth_required(self):
        r = self.rtdn_push(self.sn("tok1", 2), auth=False)
        self.assertEqual(r.status_code, 401)
        r = self.rtdn_push(self.sn("tok1", 2), aud="https://evil.example/")
        self.assertEqual(r.status_code, 401)
        r = self.rtdn_push(self.sn("tok1", 2), email="someone@else.iam.gserviceaccount.com")
        self.assertEqual(r.status_code, 401)
        bad_key, _ = _rsa()
        r = self.rtdn_push(self.sn("tok1", 2), key=bad_key)
        self.assertEqual(r.status_code, 401)
        r = self.rtdn_push(self.sn("tok1", 2), exp_in=-3600)
        self.assertEqual(r.status_code, 401)

    def test_fail_closed_without_rtdn_config(self):
        integrations.save("play_billing", {"rtdn_audience": " ", "rtdn_token": " "})
        cfg = integrations.get("play_billing")
        cfg["rtdn_audience"] = ""
        from core.models import Integration as I
        row = I.objects.get(slug="play_billing")
        row.enc_blob = integrations._encrypt({k: v for k, v in cfg.items()
                                              if k not in ("rtdn_audience", "rtdn_token")})
        row.save()
        r = self.rtdn_push(self.sn("tok1", 2))
        self.assertEqual(r.status_code, 503)

    def test_renewed_extends_and_counts_revenue(self):
        self.g.subs["tok1"] = sub_body(self.u, expiry_days=60, ack=True,
                                       order="GPA.3300-0000-0000-00000..0")
        r = self.rtdn_push(self.sn("tok1", 2))
        self.assertEqual(r.status_code, 200, r.content)
        self.u.refresh_from_db()
        self.assertGreater(self.u.plan_until, timezone.now() + timedelta(days=55))
        self.assertEqual(PaymentEvent.objects.filter(kind="play.charge").count(), 2)

    def test_replayed_message_is_noop(self):
        self.rtdn_push(self.sn("tok1", 2), mid="same")
        r = self.rtdn_push(self.sn("tok1", 2), mid="same")
        self.assertEqual(r.json()["outcome"], "duplicate")

    def test_canceled_keeps_access_until_expiry(self):
        self.g.subs["tok1"] = sub_body(self.u, state="SUBSCRIPTION_STATE_CANCELED", ack=True)
        self.rtdn_push(self.sn("tok1", 3))
        self.assertEqual(self._state(), "premium")
        self.assertFalse(PlanPeriod.objects.get(ref=play.ref_for("tok1")).auto_renew)

    def test_grace_period_keeps_access(self):
        self.g.subs["tok1"] = sub_body(self.u, state="SUBSCRIPTION_STATE_IN_GRACE_PERIOD",
                                       expiry_days=3, ack=True)
        self.rtdn_push(self.sn("tok1", 6))
        self.assertEqual(self._state(), "premium")

    def test_on_hold_removes_access_and_recovered_restores(self):
        self.g.subs["tok1"] = sub_body(self.u, state="SUBSCRIPTION_STATE_ON_HOLD",
                                       expiry_days=-1, ack=True)
        self.rtdn_push(self.sn("tok1", 5), mid="a")
        self.assertEqual(self._state(), "free")
        self.g.subs["tok1"] = sub_body(self.u, expiry_days=30, ack=True,
                                       order="GPA.3300-0000-0000-00000..1")
        self.rtdn_push(self.sn("tok1", 1), mid="b")
        self.assertEqual(self._state(), "premium")

    def test_paused_and_expired_remove_access(self):
        self.g.subs["tok1"] = sub_body(self.u, state="SUBSCRIPTION_STATE_PAUSED", ack=True)
        self.rtdn_push(self.sn("tok1", 10), mid="p")
        self.assertEqual(self._state(), "free")
        self.g.subs["tok1"] = sub_body(self.u, state="SUBSCRIPTION_STATE_EXPIRED",
                                       expiry_days=-1, ack=True)
        self.rtdn_push(self.sn("tok1", 13), mid="e")
        self.assertEqual(self._state(), "free")

    def test_revoked_refunds_and_reverses_revenue(self):
        self.rtdn_push(self.sn("tok1", 12))
        self.assertEqual(self._state(), "free")
        self.assertEqual(PlanPeriod.objects.get(ref=play.ref_for("tok1")).status, "revoked")
        ev = PaymentEvent.objects.get(kind="play.refund")
        self.assertEqual(ev.net_bdt, Decimal("-169.15"))
        # a later "active" fetch can never resurrect a revoked token
        self.verify("tok1")
        self.assertEqual(self._state(), "free")

    def test_voided_pack_debits_credits(self):
        self.g.products["ptok"] = {"purchaseState": 0, "consumptionState": 0,
                                   "orderId": "GPA.9999", "acknowledgementState": 0,
                                   "obfuscatedExternalAccountId": play.account_id(self.u)}
        self.verify("ptok", kind="pack", product="credits_p20")
        r = self.rtdn_push({"packageName": "com.assisto.assisto",
                       "voidedPurchaseNotification": {"purchaseToken": "ptok", "orderId": "GPA.9999",
                                                      "productType": 2, "refundType": 1}}, mid="v")
        self.assertEqual(r.json()["outcome"], "voided")
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 0)

    def test_rtdn_for_unverified_token_finds_account(self):
        self.g.subs["fresh"] = sub_body(self.u, product="assisto_business",
                                        order="GPA.3300-0000-0000-22222")
        r = self.rtdn_push(self.sn("fresh", 4), mid="f")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(self._state(), "business")

    def test_wrong_package_ignored(self):
        d = self.sn("tok1", 12)
        d["packageName"] = "com.other.app"
        r = self.rtdn_push(d, mid="w")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(self._state(), "premium")

    def test_test_notification(self):
        r = self.rtdn_push({"packageName": "com.assisto.assisto", "testNotification": {"version": "1.0"}},
                      mid="t")
        self.assertEqual(r.json()["outcome"], "test")


# ======================================================================= config + switches
class ConfigSwitchTests(PayBase):
    def _set(self, **kw):
        from core import billing
        from core.views_build61 import pricing_apply
        ok, _ = pricing_apply(1, {"config": {"payments": {**billing.cfg()["payments"], **kw}}})
        self.assertTrue(ok)

    def test_apk_flavour_gateway_only(self):
        enable_eps()
        r = self.api.get("/api/v1/payments/config?flavour=apk").json()
        self.assertEqual([c["id"] for c in r["channels"]], ["gateway"])
        self.assertTrue(r["channels"][0]["ready"])
        prices = {p["sku"]: p["price_bdt"] for p in r["products"]["gateway"]}
        self.assertEqual(prices["premium_monthly"], 199)

    def test_play_flavour_play_first(self):
        enable_eps()
        r = self.api.get("/api/v1/payments/config?flavour=play").json()
        self.assertEqual([c["id"] for c in r["channels"]], ["play", "gateway"])
        self.assertTrue(r["play_account_id"].startswith("u%d-" % self.u.pk))

    def test_kill_switch_applies_to_everyone(self):
        enable_eps()
        self._set(gateway_on_play=False)
        for u in (self.u, User.objects.create_user(name="R", phone="01911000003", password="x")):
            c = _client(u)
            r = c.get("/api/v1/payments/config?flavour=play").json()
            gw = [ch for ch in r["channels"] if ch["id"] == "gateway"][0]
            self.assertFalse(gw["enabled"])
            r = c.post("/api/v1/payments/checkout", {"sku": "premium_monthly", "flavour": "play"},
                       format="json")
            self.assertEqual(r.status_code, 409)
            r = c.get("/api/v1/payments/config?flavour=apk").json()
            self.assertTrue(r["channels"][0]["enabled"])

    def test_gateway_off_everywhere(self):
        enable_eps()
        self._set(gateway_enabled=False)
        r = self.api.post("/api/v1/payments/checkout", {"sku": "premium_monthly"}, format="json")
        self.assertEqual(r.status_code, 409)
        self.assertEqual(r.json()["reason"], "channel_off")

    def test_play_off(self):
        self._set(play_enabled=False)
        r = self.api.get("/api/v1/payments/config?flavour=play").json()
        self.assertFalse(r["channels"][0]["enabled"])
        r = self.api.post("/api/v1/payments/play/verify",
                          {"kind": "sub", "product_id": "assisto_premium", "purchase_token": "t"},
                          format="json")
        self.assertEqual(r.status_code, 409)

    def test_purchasable_iff_a_channel_is_live(self):
        # NO SHOWPIECES (s2) contract: buy entry points only while a channel
        # is live (owner switch on AND keys added).
        r = self.api.get("/api/v1/payments/config?flavour=apk").json()
        self.assertFalse(r["purchasable"])            # no EPS keys yet
        self.assertFalse(S.any_live("apk"))
        enable_eps()
        r = self.api.get("/api/v1/payments/config?flavour=apk").json()
        self.assertTrue(r["purchasable"])
        self.assertTrue(self.api.get("/api/v1/credits/packs").json()["purchasable"])
        self._set(gateway_on_play=False)
        self.assertFalse(S.any_live("play"))          # Play has no keys either
        self.assertFalse(self.api.get("/api/v1/credits/packs?flavour=play").json()["purchasable"])
        self.assertTrue(S.any_live("apk"))
        self._set(gateway_enabled=False)
        self.assertFalse(self.api.get("/api/v1/payments/config?flavour=apk").json()["purchasable"])

    def test_legacy_topup_points_to_checkout(self):
        enable_eps()
        r = self.api.post("/api/v1/credits/topup", {"pack": "p20"}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["state"], "use_checkout")
        self.assertFalse(CreditPurchase.objects.exists())

    def test_state_endpoint(self):
        r = self.api.get("/api/v1/payments/state").json()
        self.assertEqual(r["plan"], "premium" if r.get("trial") else r["plan"])
        self.assertIn("periods", r)


# ======================================================================= sweep / reminders / P&L
class SweepTests(PayBase):
    def setUp(self):
        super().setUp()
        enable_eps()

    @mock.patch("core.sms_gateway.adapter")
    def test_reminders_once_push_and_sms(self, adapter):
        adapter.return_value.send.return_value = (True, "ok")
        now = timezone.now()
        self.buy_gw("premium_monthly", now=now)
        p = PlanPeriod.objects.get()
        t = p.ends_at - timedelta(days=2)
        out = S.sweep(now=t)
        self.assertEqual(out["reminders"], 1)
        self.assertTrue(self.push.called)
        adapter.return_value.send.assert_called_once()
        self.assertIn("/premium?renew=premium_monthly", adapter.return_value.send.call_args[0][1])
        self.assertEqual(S.sweep(now=t + timedelta(hours=1))["reminders"], 0)
        # 1-day reminder is a separate one
        self.assertEqual(S.sweep(now=p.ends_at - timedelta(hours=12))["reminders"], 1)

    def test_no_reminder_when_already_renewed(self):
        now = timezone.now()
        self.buy_gw("premium_monthly", now=now)
        self.buy_gw("premium_monthly", now=now)
        first = PlanPeriod.objects.order_by("starts_at").first()
        out = S.sweep(now=first.ends_at - timedelta(days=2))
        self.assertEqual(out["reminders"], 0)

    def test_pending_orders_expire(self):
        o = S.checkout(self.u, "premium_monthly")
        self.fake.sessions[o.merchant_tx_id]["status"] = "Pending"
        S.sweep(now=timezone.now() + timedelta(hours=3))
        self.assertEqual(PaymentOrder.objects.get().status, "expired")

    def test_channel_pnl(self):
        self.buy_gw("premium_monthly")
        o = self.buy_gw("pack_p100")
        S.refund_order(o)
        r = S.channel_pnl(30)
        gw = r["channels"]["gateway"]
        self.assertEqual(gw["gross"], Decimal("299.00"))
        self.assertEqual(gw["refunds"], Decimal("100.00"))
        self.assertEqual(gw["net"], Decimal("195.02"))
        self.assertEqual(gw["count"], 2)
        from core import billing
        self.assertIn("gateway", billing.pnl_dashboard(7)["payments_by_channel"])

    def test_management_command(self):
        from django.core.management import call_command
        from io import StringIO
        out = StringIO()
        call_command("payments_sweep", stdout=out)
        self.assertIn("payments_sweep", out.getvalue())


# ======================================================================= website /premium
@override_settings(WEB_PUBLIC_SITE="https://lifeassisto.com")
class WebsiteCheckoutTests(PayBase):
    CODE = "482913"

    def setUp(self):
        super().setUp()
        enable_eps()
        integrations.save("sms", {"provider": "bulksmsbd", "api_key": "test-key",
                                  "sender_id": "8809617000000"})
        Integration.objects.filter(slug="sms").update(status="working")
        p1 = mock.patch("core.sms_gateway._http", return_value=(200, json.dumps(
            {"response_code": 202, "success_message": "SMS Submitted Successfully"})))
        p2 = mock.patch("core.otp._gen_code", return_value=self.CODE)
        p1.start()
        p2.start()
        self.addCleanup(p1.stop)
        self.addCleanup(p2.stop)

    def login(self, phone="01711000001"):
        r = self.client.post("/premium", {"action": "send", "phone": phone})
        self.assertEqual(r.status_code, 200)
        return self.client.post("/premium", {"action": "verify", "phone": phone, "code": self.CODE})

    def test_page_bn_en(self):
        r = self.client.get("/premium")
        self.assertContains(r, "প্রিমিয়াম")
        self.assertContains(r, "৳199")
        r = self.client.get("/premium?lang=en")
        self.assertContains(r, "Sign in with your Assisto number")
        self.assertEqual(r["Cache-Control"], "no-store")

    def test_login_buy_redirects_to_eps(self):
        r = self.login()
        self.assertEqual(r.status_code, 302)
        self.assertIn("as_pay", r.cookies)
        self.assertTrue(r.cookies["as_pay"]["httponly"])
        r = self.client.get("/premium?lang=en")
        self.assertContains(r, "Signed in")
        r = self.client.post("/premium", {"action": "buy", "sku": "premium_yearly"})
        self.assertEqual(r.status_code, 302)
        self.assertTrue(r["Location"].startswith("https://sandboxpg.eps.com.bd/"))
        o = PaymentOrder.objects.get()
        self.assertEqual((o.source, o.amount_bdt), ("web", Decimal("2173.00")))
        self.fake.pay(o.merchant_tx_id)
        r = self.client.get("/pay/return", {"r": "success", "MerchantTransactionId": o.merchant_tx_id})
        self.assertContains(r, "পেমেন্ট সফল")
        self.u.refresh_from_db()
        self.assertEqual(self.u.plan, "premium")
        # same entitlement in the app, instantly
        self.assertEqual(self.api.get("/api/v1/payments/state").json()["plan"], "premium")

    def test_unknown_number_same_answer_no_session(self):
        r = self.client.post("/premium?lang=en", {"action": "send", "phone": "01999999999"})
        self.assertContains(r, "If this number has an Assisto account")
        r = self.client.post("/premium", {"action": "verify", "phone": "01999999999",
                                          "code": self.CODE})
        self.assertEqual(r.status_code, 400)
        self.assertNotIn("as_pay", r.cookies)

    def test_wrong_code(self):
        self.client.post("/premium", {"action": "send", "phone": "01711000001"})
        r = self.client.post("/premium", {"action": "verify", "phone": "01711000001",
                                          "code": "000000"})
        self.assertEqual(r.status_code, 400)

    def test_buy_needs_login(self):
        r = self.client.post("/premium", {"action": "buy", "sku": "premium_monthly"})
        self.assertEqual(r.status_code, 401)
        self.assertFalse(PaymentOrder.objects.exists())

    def test_web_switch_off(self):
        from core import billing
        from core.views_build61 import pricing_apply
        pricing_apply(1, {"config": {"payments": {**billing.cfg()["payments"], "web_enabled": False}}})
        self.login()
        r = self.client.post("/premium?lang=en", {"action": "buy", "sku": "premium_monthly"})
        self.assertEqual(r.status_code, 400)
        self.assertContains(r, "switched off", status_code=400)

    def test_logout(self):
        self.login()
        self.client.post("/premium", {"action": "logout"})
        r = self.client.post("/premium", {"action": "buy", "sku": "premium_monthly"})
        self.assertEqual(r.status_code, 401)


class AnnualBasePlanTests(TestCase):
    """owner 26 Oct: Play yearly base plan id is "annual"; the inactive
    "yearly" base plan on assisto_premium must never map to a sku."""

    def test_annual_maps_both_ways_and_yearly_never_maps(self):
        self.assertEqual(catalog.play_product("business_yearly"),
                         ("assisto_business", "annual"))
        self.assertEqual(catalog.sku_for_play("assisto_premium", "annual"),
                         "premium_yearly")
        self.assertEqual(catalog.sku_for_play("assisto_business", "annual"),
                         "business_yearly")
        self.assertEqual(catalog.sku_for_play("assisto_premium", "yearly"), "")
        self.assertEqual(catalog.sku_for_play("assisto_premium", "monthly"),
                         "premium_monthly")


class FixedAnnualPriceTests(TestCase):
    """owner 26 Oct: Premium ৳249/৳2490, Business ৳499/৳4990 — the yearly
    price is the owner's number, not a derived discount."""

    def test_explicit_annual_price_wins_everywhere(self):
        from core.logic import pricing as P
        cfg = P.normalize({"plans": {
            "premium": {"price": 249, "annual_price": 2490},
            "business": {"price": 499, "annual_price": 4990}}})
        self.assertEqual(P.annual_price("premium", cfg), 2490)
        self.assertEqual(P.annual_price("business", cfg), 4990)
        self.assertEqual(P.effective_annual_discount_pct("premium", cfg), 16)
        self.assertEqual(catalog.price("premium_yearly", "play", cfg), 2490)
        self.assertEqual(catalog.price("business_yearly", "gateway", cfg), 4990)
        annual = [p for p in P.plan_public("en", cfg) if p["id"] == "annual"][0]
        self.assertEqual(annual["price"], 2490)

    def test_unset_annual_price_keeps_the_derived_discount(self):
        from core.logic import pricing as P
        cfg = P.normalize({"plans": {"premium": {"price": 249}}})
        self.assertEqual(P.annual_price("premium", cfg),
                         P.annual_price_at("premium", cfg,
                                           P.effective_annual_discount_pct("premium", cfg)))


class VatInclusiveNetTests(TestCase):
    """owner 26 Oct: BD prices include 15% VAT; Profit Guard counts it."""

    def test_net_fraction_is_vat_inclusive(self):
        from core.logic import pricing as P
        nf = P.net_fraction({"play_fee": 0.15, "gateway_fee": 0.0, "vat": 0.15})
        self.assertAlmostEqual(nf, 0.85 / 1.15, places=4)       # ~0.739
        self.assertAlmostEqual(P.net_fraction({"play_fee": 0.15, "gateway_fee": 0.02,
                                               "vat": 0.0}), 0.83, places=4)


class PlayBillingIntegrationTestHonest(TestCase):
    """The Owner Admin Test passes only when the account may read purchases."""

    def _run(self, status):
        sa = {"client_email": "v@x.iam.gserviceaccount.com", "private_key": "k"}
        with mock.patch.object(play, "access_token", return_value="tok"), \
                mock.patch.object(play, "_http", return_value=(status, {})):
            return integrations.test_play_billing(
                {"service_account_json": json.dumps(sa)})

    def test_permission_missing_fails_honestly(self):
        ok, detail = self._run(401)
        self.assertFalse(ok)
        self.assertIn("permission", detail)

    def test_invalid_fake_token_means_permission_ok(self):
        ok, _ = self._run(400)
        self.assertTrue(ok)


class FixedAnnualNoClampWarningTests(TestCase):
    def test_explicit_annual_price_never_reports_a_clamp(self):
        from core.logic import pricing as P
        cfg = {"vat": 0.15, "annual_discount_pct": 20, "plans": {
            "premium": {"price": 249, "annual_price": 2490, "credits": 90}}}
        codes = [w["code"] for w in P.margin_warnings(cfg)]
        self.assertNotIn("annual_discount_clamped", codes)
