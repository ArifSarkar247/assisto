"""pay-hardening (25 Oct quality sweep) — the money edges of EPS + Google Play.

Everything is mocked (EPS and Google are the faithful mocks from
core/tests_pay1.py, plus one-shot failure injection). Every test checks that
a plan / credits / revenue are granted or revoked EXACTLY once and that
credits never go below zero.

EPS      x-hash/token failures, token cache + expiry, network/5xx at init and
         verify, amount/currency/tx/provider-tx mismatches, duplicate and
         replayed IPNs, IPN retry after a transient verify failure,
         out-of-order callbacks (fail after success, success after fail,
         success after refund), pending -> timeout -> late success, unknown
         order, IPN envelope/clock-skew checks, redirect host allow-list.
Play     OAuth/API errors (4xx/5xx/timeouts) on verify and on RTDN (Pub/Sub
         retry re-processes), acknowledgement retry, every subscription
         state via RTDN with revenue counted once per order id, revoke /
         voided exactly once and never resurrected, refund before verify,
         license testers (subs + packs), pack consume retry, OIDC clock skew.
"""
import base64
import json
from datetime import timedelta
from decimal import Decimal
from unittest import mock

import requests
from django.test import TestCase
from django.utils import timezone

from core import billing, integrations
from core.models import (CreditLedger, CreditPurchase, Integration, PaymentEvent,
                         PaymentOrder, PlanPeriod, PlayPurchase, User, WebhookReceipt)
from core.payments import catalog, eps, gateway as G, play, service as S
from core import tests_pay1 as T


def _rev():
    return dict(billing._today_ledger().revenue_by_source or {})


def _credits(u):
    u.refresh_from_db()
    return int(u.ai_credits or 0)


def _plan(u):
    from core import plans
    u.refresh_from_db()
    return plans.effective_plan(u)


# ======================================================================= EPS: unit
class EpsTokenTests(TestCase):
    C = {"username": "u@test", "password": "pw", "hash_key": T.HASH_KEY, "mode": "sandbox"}

    def setUp(self):
        eps.reset_cache()
        self.addCleanup(eps.reset_cache)

    def _ok(self, expire=None):
        return 200, {"token": "tok-A", "expireDate": expire, "errorMessage": None}

    def test_token_is_cached_until_near_expiry(self):
        with mock.patch("core.payments.eps._http", return_value=self._ok()) as h:
            self.assertEqual(eps._token(self.C), "tok-A")
            self.assertEqual(eps._token(self.C), "tok-A")
            self.assertEqual(h.call_count, 1)
            eps._token(self.C, force=True)
            self.assertEqual(h.call_count, 2)

    def test_short_expire_date_wins_and_naive_is_utc(self):
        # expires in 30 s (naive => UTC): inside the 60 s safety margin -> refetch
        soon = (timezone.now() + timedelta(seconds=30)).replace(tzinfo=None).isoformat()
        with mock.patch("core.payments.eps._http", return_value=self._ok(soon)) as h:
            eps._token(self.C)
            eps._token(self.C)
            self.assertEqual(h.call_count, 2)

    def test_garbage_expire_date_falls_back_to_50_min(self):
        with mock.patch("core.payments.eps._http", return_value=self._ok("not-a-date")) as h:
            eps._token(self.C)
            eps._token(self.C)
            self.assertEqual(h.call_count, 1)

    def test_auth_failures_raise(self):
        for resp in [(200, {"token": None, "errorMessage": "Invalid hash provided."}),
                     (500, {}), (200, None)]:
            eps.reset_cache()
            with mock.patch("core.payments.eps._http", return_value=resp):
                with self.assertRaises(G.GatewayError) as cm:
                    eps._token(self.C)
                self.assertEqual(cm.exception.reason, "eps_auth")

    def test_map_status_and_amount(self):
        for s, want in [("Success", "paid"), ("COMPLETED", "paid"), (" paid ", "paid"),
                        ("Failed", "failed"), ("fail", "failed"), ("Cancelled", "cancelled"),
                        ("Cancel", "cancelled"), ("Pending", "pending"), (None, "pending"),
                        ("", "pending"), ("Refunded", "pending")]:
            self.assertEqual(eps.map_status(s), want, s)
        self.assertEqual(eps._amount("199"), Decimal("199.00"))
        self.assertEqual(eps._amount("199.004"), Decimal("199.00"))
        for bad in (None, "", "abc", "1,99"):
            self.assertEqual(eps._amount(bad), Decimal("-1"))

    def test_ipn_key_base64_32_bytes_used_raw(self):
        raw = bytes(range(32))
        k = base64.b64encode(raw).decode()
        self.assertEqual(eps._ipn_key_bytes(k), raw)
        env = eps.encrypt_ipn({"a": 1}, k)
        self.assertEqual(eps.decrypt_ipn(env, k), {"a": 1})
        with self.assertRaises(ValueError):
            eps.decrypt_ipn("AAAA:", k)

    def test_redirect_allow_list(self):
        g = eps.EpsGateway()
        self.assertTrue(g.redirect_allowed("https://sandboxpg.eps.com.bd/PG?x=1"))
        self.assertTrue(g.redirect_allowed("https://eps.com.bd/"))
        for bad in ("http://sandboxpg.eps.com.bd/PG", "https://evil-eps.com.bd/",
                    "https://eps.com.bd.evil.com/", "https://evil.com/?eps.com.bd",
                    "javascript:alert(1)", "", "https://[::1"):
            self.assertFalse(g.redirect_allowed(bad), bad)

    def test_tx_from_return(self):
        g = eps.EpsGateway()
        self.assertEqual(g.tx_from_return({"MerchantTransactionId": " 123 "}), "123")
        self.assertEqual(g.tx_from_return({"merchant_transaction_id": "9" * 40}), "9" * 32)
        self.assertEqual(g.tx_from_return({"Status": "Success"}), "")


class EpsIpnEnvelopeTests(TestCase):
    """tx_from_ipn authenticity / freshness (the IPN is a trigger only)."""
    def setUp(self):
        T.enable_eps(ipn_key=T.IPN_KEY)
        self.g = eps.EpsGateway()

    def _env(self, payload, key=T.IPN_KEY):
        return json.dumps({"Data": eps.encrypt_ipn(payload, key)}).encode()

    def _reason(self, body):
        with self.assertRaises(G.GatewayError) as cm:
            self.g.tx_from_ipn(body, {})
        return cm.exception.reason

    def test_malformed_bodies(self):
        self.assertEqual(self._reason(b"\xff\xfe"), "bad_payload")
        self.assertEqual(self._reason(b"not json"), "bad_payload")
        self.assertEqual(self._reason(b"[1, 2]"), "bad_payload")
        self.assertEqual(self._reason(json.dumps({"Data": "garbage"})), "bad_signature")

    def test_decrypted_non_object_is_bad_payload_not_a_crash(self):
        # BUG (fixed): a validly-encrypted JSON list crashed with AttributeError (500)
        self.assertEqual(self._reason(self._env([1, 2, 3])), "bad_payload")
        self.assertEqual(self._reason(self._env("just a string")), "bad_payload")

    def test_missing_tx(self):
        self.assertEqual(self._reason(self._env({"transaction_id": "E1"})), "bad_payload")

    def test_clock_skew_window(self):
        now = timezone.now()
        ok = self.g.tx_from_ipn(self._env({"merchant_transaction_id": "1234567890",
                                           "transaction_id": "E1",
                                           "timestamp": (now + timedelta(minutes=29)).isoformat()}), {})
        self.assertEqual(ok, ("1234567890", "E1"))
        # naive timestamps are UTC
        naive = (now - timedelta(minutes=10)).replace(tzinfo=None).isoformat()
        self.assertEqual(self.g.tx_from_ipn(self._env({"MerchantTransactionId": "1234567890",
                                                       "timestamp": naive}), {})[0], "1234567890")
        for ts in (now + timedelta(minutes=31), now - timedelta(minutes=31)):
            self.assertEqual(self._reason(self._env({"merchant_transaction_id": "1",
                                                     "timestamp": ts.isoformat()})), "stale")
        self.assertEqual(self._reason(self._env({"merchant_transaction_id": "1",
                                                 "timestamp": "yesterday"})), "bad_payload")

    def test_no_key_configured(self):
        g = eps.EpsGateway()
        g.c = {k: v for k, v in g.c.items() if k != "ipn_key"}       # no ipn_key
        with self.assertRaises(G.GatewayError) as cm:
            g.tx_from_ipn(self._env({"merchant_transaction_id": "1"}), {})
        self.assertEqual(cm.exception.reason, "ipn_key_missing")
        # plain notifications are accepted only while no key is set (trigger only)
        self.assertEqual(g.tx_from_ipn(json.dumps({"merchant_transaction_id": "77"}), {}),
                         ("77", ""))


# ======================================================================= EPS: flows
class EpsFlowHardeningTests(T.PayBase):
    def setUp(self):
        super().setUp()
        T.enable_eps(ipn_key=T.IPN_KEY)

    def _ipn(self, tx, ptx="EPS1", **kw):
        p = {"transaction_id": ptx, "merchant_transaction_id": tx, "status": "SUCCESS",
             "timestamp": timezone.now().isoformat()}
        p.update(kw)
        return self.client.post("/api/v1/payments/gateway/ipn",
                                json.dumps({"Data": eps.encrypt_ipn(p, T.IPN_KEY)}),
                                content_type="application/json")

    def _periods(self):
        return PlanPeriod.objects.filter(user=self.u, source="gateway").count()

    # ---- session creation
    def test_init_network_error_marks_order_failed(self):
        def boom(method, url, body=None, headers=None):
            if url.endswith("/InitializeEPS"):
                raise requests.ConnectionError("down")
            return self.fake(method, url, body, headers)
        with mock.patch("core.payments.eps._http", side_effect=boom):
            with self.assertRaises(S.PayError) as cm:
                S.checkout(self.u, "premium_monthly")
        self.assertEqual(cm.exception.reason, "gateway_error")
        o = PaymentOrder.objects.get()
        self.assertEqual(o.status, "failed")
        self.assertIn("network", o.detail)

    def test_init_error_code_and_foreign_redirect_refused(self):
        for patch_resp, why in [
                ((200, {"RedirectURL": "https://sandboxpg.eps.com.bd/x", "ErrorCode": "500",
                        "ErrorMessage": "boom"}), "init_failed"),
                ((200, {"RedirectURL": "https://phish.example/x", "ErrorCode": None,
                        "ErrorMessage": ""}), "bad_redirect"),
                ((502, {}), "init_failed")]:
            def fake(method, url, body=None, headers=None, _r=patch_resp):
                if url.endswith("/InitializeEPS"):
                    return _r
                return self.fake(method, url, body, headers)
            with mock.patch("core.payments.eps._http", side_effect=fake):
                with self.assertRaises(S.PayError):
                    S.checkout(self.u, "premium_monthly")
            self.assertIn(why, PaymentOrder.objects.latest("pk").detail)
        self.assertFalse(PaymentOrder.objects.filter(status="pending").exists())

    def test_not_configured_gateway_methods(self):
        g = eps.EpsGateway()
        g.c = {"merchant_id": "m"}
        self.assertFalse(g.configured())
        with self.assertRaises(G.GatewayError):
            g.create_session(None, {}, {})
        with self.assertRaises(G.GatewayError):
            g.verify(None)
        self.assertFalse(g.test()[0])

    def test_owner_test_button(self):
        g = eps.EpsGateway()
        ok, msg = g.test()
        self.assertTrue(ok, msg)
        with mock.patch("core.payments.eps._http", side_effect=requests.Timeout()):
            ok, msg = g.test()
        self.assertFalse(ok)
        self.assertIn("network", msg)
        T.enable_eps(hash_key="wrong")
        ok, msg = eps.EpsGateway().test()
        self.assertFalse(ok)
        self.assertIn("eps_auth", msg)

    # ---- verification failures leave the order pending, grant nothing
    def test_verify_outages_keep_pending(self):
        o = S.checkout(self.u, "premium_monthly")
        self.fake.pay(o.merchant_tx_id)

        def fake(method, url, body=None, headers=None, mode=None):
            if "CheckMerchantTransactionStatus" in url:
                if mode == "timeout":
                    raise requests.Timeout()
                if mode == "500":
                    return 500, {}
                return 200, {"ErrorCode": 404, "ErrorMessage": "Transaction not found"}
            return self.fake(method, url, body, headers)
        for mode in ("timeout", "500", "err"):
            with mock.patch("core.payments.eps._http",
                            side_effect=lambda *a, _m=mode, **k: fake(*a, mode=_m, **k)):
                o = S.complete(o)
            self.assertEqual(o.status, "pending")
        self.assertEqual(PaymentEvent.objects.filter(kind="order.verify_error").count(), 3)
        self.assertEqual(_plan(self.u), "free")
        # gateway back -> one grant
        o = S.complete(o)
        self.assertEqual(o.status, "paid")
        self.assertEqual(self._periods(), 1)

    def test_token_failure_at_verify_and_unconfigured_gateway_keep_pending(self):
        o = S.checkout(self.u, "premium_monthly")
        self.fake.pay(o.merchant_tx_id)
        eps.reset_cache()
        with mock.patch("core.payments.eps._http", return_value=(200, {"token": None})):
            o = S.complete(o)
        self.assertEqual(o.status, "pending")
        self.assertTrue(PaymentEvent.objects.filter(kind="order.verify_error",
                                                    detail__reason="eps_auth").exists())
        with mock.patch.object(eps.EpsGateway, "configured", return_value=False):
            self.assertEqual(S.complete(o).status, "pending")
        self.assertEqual(self._periods(), 0)
        self.assertEqual(S.complete(o).status, "paid")

    def test_currency_mismatch_and_missing_provider_tx_refused(self):
        o = S.checkout(self.u, "premium_monthly")
        res = G.VerifyResult(status="paid", merchant_tx_id=o.merchant_tx_id,
                             provider_tx_id="E9", amount=Decimal("199.00"), currency="USD")
        with mock.patch.object(eps.EpsGateway, "verify", return_value=res):
            o = S.complete(o)
        self.assertIn("currency_mismatch", o.detail)
        self.fake.pay(o.merchant_tx_id)
        self.fake.status_override[o.merchant_tx_id] = {"EPSTransactionId": ""}
        o = S.complete(o)
        self.assertIn("no_provider_tx", o.detail)
        self.assertNotEqual(o.status, "paid")
        self.assertEqual(self._periods(), 0)
        self.assertEqual(_plan(self.u), "free")

    def test_overpaid_or_garbage_amount_refused(self):
        for amt in (1990, None):
            o = S.checkout(self.u, "premium_monthly")
            self.fake.pay(o.merchant_tx_id)
            self.fake.status_override[o.merchant_tx_id] = {"TotalAmount": amt}
            o = S.complete(o)
            self.assertIn("amount_mismatch", o.detail)
        self.assertEqual(self._periods(), 0)

    # ---- duplicates / replays / ordering
    def test_ipn_and_return_and_poll_grant_once(self):
        o = S.checkout(self.u, "pack_p50")
        self.fake.pay(o.merchant_tx_id, eps_tx="EPS-A")
        want = catalog.describe("pack_p50")["credits"]
        self.assertEqual(self._ipn(o.merchant_tx_id, "EPS-A").status_code, 200)
        self._ipn(o.merchant_tx_id, "EPS-B")        # different ptx, still one grant
        S.handle_return({"MerchantTransactionId": o.merchant_tx_id})
        self.api.get("/api/v1/payments/orders/%d" % o.pk)
        S.sweep(now=timezone.now() + timedelta(minutes=10))
        self.assertEqual(_credits(self.u), want)
        self.assertEqual(CreditPurchase.objects.filter(user=self.u).count(), 1)
        self.assertEqual(PaymentEvent.objects.filter(kind="order.paid").count(), 1)
        self.assertAlmostEqual(_rev()["packs"], float(catalog.net(o.amount_bdt, o.sku, "gateway")))

    def test_ipn_retry_after_transient_verify_failure_is_processed(self):
        # BUG (fixed): the receipt was stored before verifying, so EPS's retry of
        # the same IPN was answered "duplicate" and never re-verified.
        o = S.checkout(self.u, "premium_monthly")
        self.fake.pay(o.merchant_tx_id, eps_tx="EPS-R")

        def down(method, url, body=None, headers=None):
            if "CheckMerchantTransactionStatus" in url:
                raise requests.ConnectionError()
            return self.fake(method, url, body, headers)
        with mock.patch("core.payments.eps._http", side_effect=down):
            r = self._ipn(o.merchant_tx_id, "EPS-R")
        self.assertEqual(r.json()["order"], "pending")
        r = self._ipn(o.merchant_tx_id, "EPS-R")
        self.assertEqual(r.json()["order"], "paid")
        r = self._ipn(o.merchant_tx_id, "EPS-R")          # true replay after success
        self.assertEqual(r.json()["message"], "duplicate")
        self.assertEqual(self._periods(), 1)
        self.assertEqual(WebhookReceipt.objects.filter(source="gw_ipn").count(), 1)

    def test_ipn_without_provider_tx_is_idempotent(self):
        o = S.checkout(self.u, "premium_monthly")
        self.fake.pay(o.merchant_tx_id)
        self._ipn(o.merchant_tx_id, "")
        self._ipn(o.merchant_tx_id, "")
        self.assertEqual(self._periods(), 1)
        self.assertFalse(WebhookReceipt.objects.filter(source="gw_ipn").exists())

    def test_fail_after_success_keeps_paid(self):
        o = self.buy_gw("premium_monthly")
        self.fake.sessions[o.merchant_tx_id]["status"] = "Failed"
        o = S.complete(o, via="ipn")
        self.assertEqual(o.status, "paid")
        self.assertEqual(_plan(self.u), "premium")
        self.assertEqual(self._periods(), 1)

    def test_success_after_failed_completes_once(self):
        o = self.buy_gw("premium_monthly", status="Failed")
        self.assertEqual(o.status, "failed")
        self.fake.pay(o.merchant_tx_id)
        o = S.complete(o)
        o = S.complete(o)
        self.assertEqual(o.status, "paid")
        self.assertEqual(self._periods(), 1)

    def test_success_after_refund_is_not_regranted(self):
        o = self.buy_gw("pack_p50")
        got = _credits(self.u)
        self.assertGreater(got, 0)
        S.refund_order(o)
        self.assertEqual(_credits(self.u), 0)
        self._ipn(o.merchant_tx_id, "F" + o.merchant_tx_id[-10:] + "E")
        self._ipn(o.merchant_tx_id, "OTHER")
        S.handle_return({"MerchantTransactionId": o.merchant_tx_id})
        self.assertEqual(PaymentOrder.objects.get(pk=o.pk).status, "refunded")
        self.assertEqual(_credits(self.u), 0)
        self.assertEqual(PaymentEvent.objects.filter(kind="order.paid").count(), 1)
        self.assertEqual(PaymentEvent.objects.filter(kind="order.refunded").count(), 1)
        self.assertAlmostEqual(_rev().get("packs", 0), 0.0)

    def test_refund_after_credits_spent_never_negative(self):
        o = self.buy_gw("pack_p50")
        User.objects.filter(pk=self.u.pk).update(ai_credits=3)       # spent most
        S.refund_order(o)
        S.refund_order(o)
        self.assertEqual(_credits(self.u), 0)
        neg = CreditLedger.objects.filter(user=self.u, delta__lt=0)
        self.assertEqual([x.delta for x in neg], [-3])

    def test_sub_refund_revokes_once(self):
        o = self.buy_gw("premium_monthly")
        S.refund_order(o)
        _, again = S.refund_order(PaymentOrder.objects.get(pk=o.pk))
        self.assertFalse(again)
        self.assertEqual(_plan(self.u), "free")
        self.assertEqual(PlanPeriod.objects.get(source="gateway").status, "revoked")
        self.assertEqual(PaymentEvent.objects.filter(kind="entitlement.revoke").count(), 1)
        self.assertAlmostEqual(_rev().get("subs", 0), 0.0)

    def test_pending_timeout_then_late_success_grants_once(self):
        o = S.checkout(self.u, "premium_monthly")
        self.fake.sessions[o.merchant_tx_id]["status"] = "Pending"
        later = timezone.now() + timedelta(hours=3)
        S.sweep(now=later)
        self.assertEqual(PaymentOrder.objects.get().status, "expired")
        self.assertEqual(_plan(self.u), "free")
        # money did arrive late: the IPN still completes it (exactly once)
        self.fake.pay(o.merchant_tx_id)
        self._ipn(o.merchant_tx_id, "LATE")
        self._ipn(o.merchant_tx_id, "LATE")
        S.sweep(now=later + timedelta(hours=1))
        self.assertEqual(PaymentOrder.objects.get().status, "paid")
        self.assertEqual(self._periods(), 1)

    def test_unknown_order_paths(self):
        self.assertIsNone(S.handle_return({"MerchantTransactionId": "999999999999"}))
        self.assertIsNone(S.handle_return({}))
        self.assertEqual(self._ipn("999999999999").status_code, 404)
        r = self.client.get("/pay/return?MerchantTransactionId=999999999999&Status=Success")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(PlanPeriod.objects.count(), 0)

    def test_no_gateway_configured(self):
        Integration.objects.filter(slug="eps").delete()
        self.assertIsNone(S.handle_return({"MerchantTransactionId": "1"}))
        code, _ = S.handle_ipn(b"{}", {})
        self.assertEqual(code, 503)

    def test_ipn_cannot_redirect_grant_to_another_user(self):
        other = User.objects.create_user(name="Mallory", phone="01811000003", password="x")
        o = S.checkout(self.u, "premium_monthly")
        self.fake.pay(o.merchant_tx_id)
        self._ipn(o.merchant_tx_id, "EPS-X", customer_id=other.pk, user=other.pk)
        self.assertEqual(_plan(self.u), "premium")
        self.assertEqual(_plan(other), "free")
        # another user's order is invisible on the poll endpoint
        r = T._client(other).get("/api/v1/payments/orders/%d" % o.pk)
        self.assertEqual(r.status_code, 404)


# ======================================================================= Play: base
class FlakyGoogle(T.FakeGoogle):
    """FakeGoogle + one-shot failures: fail.append((url_substring, result)),
    result = an Exception to raise or a (status, body) tuple."""
    def __init__(self):
        super().__init__()
        self.fail = []
        self.calls = []

    def __call__(self, method, url, body=None, headers=None):
        self.calls.append((method, url))
        for i, (sub, res) in enumerate(self.fail):
            if sub in url:
                del self.fail[i]
                if isinstance(res, Exception):
                    raise res
                return res
        return super().__call__(method, url, body, headers)


class PlayHBase(T.PlayBase):
    def setUp(self):
        super().setUp()
        self.g = FlakyGoogle()
        p = mock.patch("core.payments.play._http", side_effect=self.g)
        p.start()
        self.addCleanup(p.stop)

    def charges(self):
        return PaymentEvent.objects.filter(kind="play.charge").count()

    def refunds(self):
        return PaymentEvent.objects.filter(kind="play.refund").count()

    def pack(self, tok="ptok", order="GPA.7777-0001", **kw):
        b = {"purchaseState": 0, "consumptionState": 0, "orderId": order,
             "acknowledgementState": 0,
             "obfuscatedExternalAccountId": play.account_id(self.u)}
        b.update(kw)
        self.g.products[tok] = b
        return b

    def on(self, tok, nt=1, sku="credits_p20"):
        return {"packageName": "com.assisto.assisto",
                "oneTimeProductNotification": {"version": "1.0", "notificationType": nt,
                                               "purchaseToken": tok, "sku": sku}}


# ======================================================================= Play: Google errors
class PlayGoogleErrorTests(PlayHBase):
    def test_verify_maps_google_errors(self):
        self.g.subs["t"] = T.sub_body(self.u)
        cases = [((500, {"error": {"message": "backend"}}), 502, "google_error"),
                 ((503, {}), 502, "google_error"),
                 ((401, {"error": {"message": "unauth"}}), 502, "google_error"),
                 ((403, {}), 502, "google_error"),
                 ((410, {}), 400, "not_found"),
                 (requests.Timeout("slow"), 502, "network"),
                 (requests.ConnectionError("dns"), 502, "network")]
        for res, code, reason in cases:
            self.g.fail.append(("/subscriptionsv2/", res))
            r = self.verify("t")
            self.assertEqual(r.status_code, code, (res, r.content))
            self.assertEqual(r.json()["reason"], reason)
        self.assertEqual(_plan(self.u), "free")
        self.assertFalse(PlayPurchase.objects.exists())
        self.assertEqual(self.charges(), 0)
        # Google recovers -> exactly one grant
        self.assertEqual(self.verify("t").status_code, 200)
        self.verify("t")
        self.assertEqual(_plan(self.u), "premium")
        self.assertEqual(self.charges(), 1)

    def test_unknown_token_is_400(self):
        r = self.verify("never-bought")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()["reason"], "not_found")

    def test_oauth_failure_and_token_cache(self):
        self.g.subs["t"] = T.sub_body(self.u)
        self.g.fail.append((play.TOKEN_URI, (400, {"error": "invalid_grant"})))
        r = self.verify("t")
        self.assertEqual(r.status_code, 502)
        self.assertEqual(r.json()["reason"], "play_auth")
        self.verify("t")
        self.verify("t")
        token_calls = [u for _, u in self.g.calls if u == play.TOKEN_URI]
        self.assertEqual(len(token_calls), 2)      # the failed one + ONE cached success

    def test_no_line_items_and_bad_price(self):
        b = T.sub_body(self.u)
        b["lineItems"] = []
        self.g.subs["t"] = b
        r = self.verify("t")
        self.assertEqual(r.json()["reason"], "no_line_items")
        b = T.sub_body(self.u)
        b["lineItems"][0]["autoRenewingPlan"]["recurringPrice"] = {"currencyCode": "USD",
                                                                  "units": "2"}
        self.g.subs["t2"] = b
        self.verify("t2")
        # non-BDT price -> our table price is the revenue, never the foreign number
        self.assertEqual(PlayPurchase.objects.get().price_bdt,
                         Decimal(catalog.price("premium_monthly", "play")))
        self.assertEqual(play._money({"units": "x"}), (None, ""))
        self.assertEqual(play._money(None), (None, ""))
        self.assertEqual(play._money({"units": "1", "nanos": 500000000,
                                      "currencyCode": "BDT"}), (Decimal("1.50"), "BDT"))

    def test_account_id_parsing(self):
        for bad in ("", "x", "u", "uabc-1", "u999999-0000", None):
            self.assertIsNone(play.user_for_account_id(bad))
        self.assertEqual(play.user_for_account_id(play.account_id(self.u)), self.u)

    def test_cfg_bad_service_account(self):
        integrations.save("play_billing", {"service_account_json": "{not json",
                                           "package_name": "com.assisto.assisto"})
        self.assertFalse(play.configured())
        with self.assertRaises(play.PlayError):
            play.access_token()

    def test_ts_parsing(self):
        self.assertIsNone(play._ts(None))
        self.assertIsNone(play._ts("garbage"))
        self.assertIsNotNone(play._ts("2026-10-25T10:00:00").tzinfo)


# ======================================================================= Play: ack retries
class PlayAckTests(PlayHBase):
    def test_ack_failure_is_retried_on_next_sync_and_grants_once(self):
        self.g.subs["t"] = T.sub_body(self.u)
        self.g.fail.append((":acknowledge", (500, {})))
        r = self.verify("t")
        self.assertEqual(r.status_code, 200)
        pp = PlayPurchase.objects.get()
        self.assertFalse(pp.acknowledged)
        self.assertEqual(_plan(self.u), "premium")
        self.g.fail.append((":acknowledge", requests.Timeout()))
        self.verify("t")
        self.assertFalse(PlayPurchase.objects.get().acknowledged)
        self.verify("t")
        self.assertTrue(PlayPurchase.objects.get().acknowledged)
        self.assertEqual(self.g.acks, ["t"])
        self.verify("t")
        self.assertEqual(self.g.acks, ["t"])      # never acked twice
        self.assertEqual(self.charges(), 1)
        self.assertEqual(PlanPeriod.objects.filter(source="play").count(), 1)

    def test_ack_retried_by_rtdn(self):
        self.g.subs["t"] = T.sub_body(self.u)
        self.g.fail.append((":acknowledge", (503, {})))
        self.verify("t")
        self.rtdn_push(self.sn("t", 4), mid="p1")
        self.assertTrue(PlayPurchase.objects.get().acknowledged)

    def test_google_already_acknowledged_no_call(self):
        self.g.subs["t"] = T.sub_body(self.u, ack=True)
        self.verify("t")
        self.assertEqual(self.g.acks, [])
        self.assertTrue(PlayPurchase.objects.get().acknowledged)

    def test_pending_purchase_not_acked_not_entitled_not_revenue(self):
        self.g.subs["t"] = T.sub_body(self.u, state="SUBSCRIPTION_STATE_PENDING")
        r = self.verify("t")
        self.assertFalse(r.json()["entitled"])
        self.assertEqual(self.g.acks, [])
        self.assertEqual(self.charges(), 0)
        self.assertEqual(_plan(self.u), "free")
        # pending purchase abandoned
        self.g.subs["t"] = T.sub_body(self.u, state="SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED",
                                      expiry_days=-1)
        r = self.rtdn_push(self.sn("t", 20), mid="pc")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(_plan(self.u), "free")
        self.assertEqual(self.charges(), 0)


# ======================================================================= Play: RTDN lifecycle
class PlayLifecycleTests(PlayHBase):
    ORD = "GPA.3300-0000-0000-00000"

    def setUp(self):
        super().setUp()
        self.g.subs["t"] = T.sub_body(self.u, order=self.ORD)

    def rt(self, nt, mid, **body):
        if body:
            self.g.subs["t"] = T.sub_body(self.u, **body)
        r = self.rtdn_push(self.sn("t", nt), mid=mid)
        self.assertEqual(r.status_code, 200, r.content)
        return r.json()["outcome"]

    def test_full_lifecycle_revenue_once_per_order(self):
        self.assertEqual(self.rt(4, "m-purchased"), "sub:PURCHASED:SUBSCRIPTION_STATE_ACTIVE")
        self.verify("t")                                       # app verify too
        self.assertEqual(self.charges(), 1)
        self.rt(2, "m-renew1", ack=True, expiry_days=60, order=self.ORD + "..0")
        self.rt(2, "m-renew1b", ack=True, expiry_days=60, order=self.ORD + "..0")  # dup order
        self.assertEqual(self.charges(), 2)
        self.rt(6, "m-grace", ack=True, expiry_days=3, order=self.ORD + "..0",
                  state="SUBSCRIPTION_STATE_IN_GRACE_PERIOD")
        self.assertEqual(_plan(self.u), "premium")
        self.assertEqual(self.charges(), 2)
        self.rt(5, "m-hold", ack=True, expiry_days=-1, order=self.ORD + "..0",
                  state="SUBSCRIPTION_STATE_ON_HOLD")
        self.assertEqual(_plan(self.u), "free")
        self.rt(1, "m-recover", ack=True, expiry_days=30, order=self.ORD + "..1")
        self.assertEqual(_plan(self.u), "premium")
        self.assertEqual(self.charges(), 3)
        self.rt(10, "m-pause", ack=True, order=self.ORD + "..1",
                  state="SUBSCRIPTION_STATE_PAUSED")
        self.assertEqual(_plan(self.u), "free")
        self.rt(7, "m-restart", ack=True, order=self.ORD + "..1")
        self.assertEqual(_plan(self.u), "premium")
        self.rt(3, "m-cancel", ack=True, order=self.ORD + "..1",
                  state="SUBSCRIPTION_STATE_CANCELED")
        self.assertEqual(_plan(self.u), "premium")         # paid time kept
        self.rt(13, "m-expired", ack=True, expiry_days=-1, order=self.ORD + "..1",
                  state="SUBSCRIPTION_STATE_EXPIRED")
        self.assertEqual(_plan(self.u), "free")
        self.assertEqual(self.charges(), 3)
        self.assertEqual(PlanPeriod.objects.filter(source="play").count(), 1)
        rev = _rev()["subs"]
        self.assertAlmostEqual(rev, 3 * float(catalog.net(199, "premium_monthly", "play")), 2)

    def test_canceled_but_already_expired_is_not_entitled(self):
        # clock: Google says CANCELED but its expiry passed 30 s ago
        self.rt(3, "c", ack=True, expiry_days=-30 / 86400.0,
                  state="SUBSCRIPTION_STATE_CANCELED")
        self.assertEqual(_plan(self.u), "free")
        self.assertEqual(self.charges(), 0)

    def test_revoke_exactly_once_and_never_resurrected(self):
        self.rt(4, "p")
        self.assertEqual(self.rt(12, "r1"), "revoked")
        self.assertEqual(self.rt(12, "r2"), "revoked")          # Google resends
        r = self.rtdn_push({"packageName": "com.assisto.assisto",
                            "voidedPurchaseNotification": {"purchaseToken": "t",
                                                           "orderId": self.ORD}}, mid="v")
        self.assertEqual(r.json()["outcome"], "voided")
        self.assertEqual(self.refunds(), 1)
        self.assertEqual(PaymentEvent.objects.filter(kind="entitlement.revoke").count(), 1)
        self.assertAlmostEqual(_rev()["subs"], 0.0, 2)
        # later RTDNs / verifies of the same token change nothing
        self.rt(2, "after1", ack=True, expiry_days=60, order=self.ORD + "..0")
        self.rt(1, "after2", ack=True, expiry_days=60, order=self.ORD + "..1")
        self.verify("t")
        self.assertEqual(_plan(self.u), "free")
        self.assertEqual(PlanPeriod.objects.get(source="play").status, "revoked")
        self.assertEqual(self.charges(), 1)

    def test_refund_before_verify_is_harmless(self):
        # out of order: REVOKED arrives for a token we never saw
        self.g.subs["x"] = T.sub_body(self.u, state="SUBSCRIPTION_STATE_EXPIRED",
                                      expiry_days=-1, order="GPA.X")
        r = self.rtdn_push(self.sn("x", 12), mid="early")
        self.assertEqual(r.json()["outcome"], "revoked")
        self.assertEqual(self.refunds(), 0)
        # the app's verify then re-fetches from Google: expired -> nothing granted
        self.verify("x")
        self.assertEqual(_plan(self.u), "free")
        self.assertEqual(self.charges(), 0)

    def test_test_purchase_refund_has_no_revenue_reversal(self):
        self.g.subs["t"] = T.sub_body(self.u, test=True)
        self.verify("t")
        self.assertEqual(_plan(self.u), "premium")
        self.rt(12, "r")
        self.assertEqual(_plan(self.u), "free")
        self.assertEqual(self.charges(), 0)
        self.assertEqual(self.refunds(), 0)
        self.assertEqual(_rev().get("subs", 0), 0)

    def test_google_outage_on_rtdn_is_retried_by_pubsub(self):
        self.g.fail.append(("/subscriptionsv2/", (500, {})))
        r = self.rtdn_push(self.sn("t", 4), mid="retry-me")
        self.assertEqual(r.status_code, 503)
        self.assertFalse(WebhookReceipt.objects.filter(message_id="retry-me").exists())
        self.g.fail.append((play.TOKEN_URI, requests.Timeout()))
        play.reset_cache()
        r = self.rtdn_push(self.sn("t", 4), mid="retry-me")
        self.assertEqual(r.status_code, 503)
        r = self.rtdn_push(self.sn("t", 4), mid="retry-me")     # Pub/Sub redelivery
        self.assertEqual(r.status_code, 200)
        r = self.rtdn_push(self.sn("t", 4), mid="retry-me")     # then a true duplicate
        self.assertEqual(r.json()["outcome"], "duplicate")
        self.assertEqual(self.charges(), 1)
        self.assertEqual(_plan(self.u), "premium")

    def test_rtdn_for_other_apps_or_strangers_is_ignored(self):
        self.g.subs["s"] = T.sub_body(self.u)
        del self.g.subs["s"]["externalAccountIdentifiers"]
        self.assertEqual(self.push_raw(self.sn("s", 4), "stranger"), "ignored:unknown_account")
        self.assertEqual(self.push_raw(self.sn("gone", 4), "gone"), "ignored:not_found")
        self.assertEqual(self.push_raw({"packageName": "com.assisto.assisto"}, "empty"),
                         "ignored")
        self.assertEqual(_plan(self.u), "free")

    def push_raw(self, data, mid):
        r = self.rtdn_push(data, mid=mid)
        self.assertEqual(r.status_code, 200, r.content)
        return r.json()["outcome"]

    def test_rtdn_other_account_token_is_acked_audited_and_grants_nothing(self):
        # pay-followup: was 400 -> Pub/Sub redelivered forever; now 2xx + audit row
        other = User.objects.create_user(name="Mallory", phone="01811000004", password="x")
        self.verify("t")
        self.g.subs["t"] = T.sub_body(other)            # Google now claims another account
        r = self.rtdn_push(self.sn("t", 2), mid="oa")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["outcome"], "ignored:other_account")
        self.assertEqual(_plan(other), "free")
        self.assertEqual(PlayPurchase.objects.get().user, self.u)
        self.assertTrue(PaymentEvent.objects.filter(kind="play.rtdn_other_account").exists())
        self.assertTrue(WebhookReceipt.objects.filter(message_id="oa").exists())
        # a redelivery is a duplicate no-op
        self.assertEqual(self.rtdn_push(self.sn("t", 2), mid="oa").json()["outcome"], "duplicate")
        # a pack token bound to us but claimed for another account: also acked
        self.pack("pk")
        self.verify("pk", kind="pack", product="credits_p20")
        self.g.products["pk"]["obfuscatedExternalAccountId"] = play.account_id(other)
        r = self.rtdn_push(self.on("pk"), mid="oa-pack")
        self.assertEqual((r.status_code, r.json()["outcome"]), (200, "ignored:other_account"))
        # a real Google outage on RTDN still returns 503 so Pub/Sub retries
        self.g.fail.append(("/subscriptionsv2/", (500, {})))
        self.assertEqual(self.rtdn_push(self.sn("t", 2), mid="outage").status_code, 503)

    def test_bad_envelopes(self):
        for env in [{}, {"message": {"data": "eyJ"}}, {"message": {"messageId": "1",
                                                                   "data": "!!!"}}]:
            r = self.client.post("/api/v1/payments/play/rtdn", json.dumps(env),
                                 content_type="application/json",
                                 HTTP_AUTHORIZATION="Bearer " + T.oidc())
            self.assertEqual(r.status_code, 400)
        r = self.rtdn_push({"subscriptionNotification": {"notificationType": 2}}, mid="nt")
        self.assertEqual(r.status_code, 400)


# ======================================================================= Play: packs
class PlayPackTests(PlayHBase):
    def setUp(self):
        super().setUp()
        self.n = catalog.describe("pack_p20")["credits"]

    def test_consume_failure_retried_without_double_grant(self):
        self.pack()
        self.g.fail.append((":consume", (500, {})))
        r = self.verify("ptok", kind="pack", product="credits_p20")
        self.assertEqual(r.json()["granted"], self.n)
        self.assertFalse(PlayPurchase.objects.get().consumed)
        r = self.verify("ptok", kind="pack", product="credits_p20")
        self.assertEqual(r.json()["granted"], 0)
        self.assertTrue(PlayPurchase.objects.get().consumed)
        self.assertEqual(self.g.consumed, ["ptok"])
        self.assertEqual(_credits(self.u), self.n)
        self.assertEqual(self.charges(), 1)

    def test_already_consumed_no_consume_call(self):
        self.pack(consumptionState=1)
        self.verify("ptok", kind="pack", product="credits_p20")
        self.assertEqual(self.g.consumed, [])
        self.assertTrue(PlayPurchase.objects.get().consumed)

    def test_rtdn_and_verify_race_grant_once(self):
        self.pack()
        self.assertEqual(self.rt(self.on("ptok"), "o1"), "pack:purchased")
        self.assertEqual(self.rt(self.on("ptok"), "o2"), "pack:purchased")
        self.verify("ptok", kind="pack", product="credits_p20")
        self.assertEqual(_credits(self.u), self.n)
        self.assertEqual(CreditPurchase.objects.count(), 1)
        self.assertEqual(self.charges(), 1)

    def rt(self, data, mid):
        r = self.rtdn_push(data, mid=mid)
        self.assertEqual(r.status_code, 200, r.content)
        return r.json()["outcome"]

    def test_rtdn_pack_edges(self):
        self.assertEqual(self.rt(self.on("ptok", nt=2), "c"), "pack:canceled")
        self.assertEqual(self.rt(self.on("ptok", sku="somebody_else"), "u"),
                         "ignored:unknown_product")
        self.assertEqual(self.rt(self.on("nope"), "n"), "ignored:not_found")
        self.assertEqual(_credits(self.u), 0)

    def test_canceled_or_unknown_state_grants_nothing(self):
        for st in (1, 7, None):
            PlayPurchase.objects.all().delete()
            self.pack(purchaseState=st)
            r = self.verify("ptok", kind="pack", product="credits_p20")
            self.assertEqual(r.json()["state"], "canceled")
        self.assertEqual(_credits(self.u), 0)

    def test_license_tester_and_promo_pack_not_revenue(self):
        self.pack("t0", order="GPA.T0", purchaseType=0)
        self.pack("t1", order="GPA.T1", purchaseType=1)
        self.verify("t0", kind="pack", product="credits_p20")
        self.verify("t1", kind="pack", product="credits_p20")
        self.assertEqual(_credits(self.u), 2 * self.n)
        self.assertEqual(self.charges(), 0)
        self.assertEqual(PaymentEvent.objects.filter(kind="play.test_charge").count(), 2)

    def test_voided_after_spend_never_negative_and_once(self):
        self.pack()
        self.verify("ptok", kind="pack", product="credits_p20")
        User.objects.filter(pk=self.u.pk).update(ai_credits=2)
        v = {"packageName": "com.assisto.assisto",
             "voidedPurchaseNotification": {"purchaseToken": "ptok", "orderId": "GPA.7777-0001",
                                            "productType": 2}}
        self.rt(v, "v1")
        self.rt(v, "v2")
        self.assertEqual(_credits(self.u), 0)
        self.assertEqual([x.delta for x in CreditLedger.objects.filter(user=self.u, delta__lt=0)],
                         [-2])
        self.assertEqual(self.refunds(), 1)
        # Google still says PURCHASED (stale) -> a revoked token is never re-granted
        r = self.verify("ptok", kind="pack", product="credits_p20")
        self.assertEqual(r.json()["state"], "canceled")
        self.assertEqual(_credits(self.u), 0)
        self.assertAlmostEqual(_rev().get("packs", 0), 0.0, 2)

    def test_voided_pending_pack_debits_nothing(self):
        self.pack(purchaseState=2)
        self.verify("ptok", kind="pack", product="credits_p20")
        User.objects.filter(pk=self.u.pk).update(ai_credits=5)    # credits from elsewhere
        self.rt({"voidedPurchaseNotification": {"purchaseToken": "ptok"}}, "vp")
        self.assertEqual(_credits(self.u), 5)
        self.assertTrue(PlayPurchase.objects.get().revoked)

    def test_other_users_pack_refused(self):
        other = User.objects.create_user(name="Mallory", phone="01811000005", password="x")
        self.pack()
        r = self.verify("ptok", kind="pack", product="credits_p20", api=T._client(other))
        self.assertEqual(r.status_code, 403)
        self.assertEqual(_credits(other), 0)
        self.verify("ptok", kind="pack", product="credits_p20")
        r = self.verify("ptok", kind="pack", product="credits_p20", api=T._client(other))
        self.assertEqual(r.status_code, 403)
        self.assertEqual(_credits(self.u), self.n)

    def test_bad_requests(self):
        for body in ({}, {"kind": "x", "product_id": "a", "purchase_token": "b"},
                     {"kind": "pack", "product_id": "", "purchase_token": "b"}):
            r = self.api.post("/api/v1/payments/play/verify", body, format="json")
            self.assertEqual(r.status_code, 400)
        r = self.verify("ptok", kind="pack", product="assisto_premium")
        self.assertEqual(r.json()["reason"], "unknown_product")


# ======================================================================= Play: RTDN auth / clock skew
class RtdnAuthSkewTests(PlayHBase):
    def _jwt(self, head=None, **claims):
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.asymmetric import padding
        now = int(timezone.now().timestamp())
        c = {"iss": "accounts.google.com", "aud": T.AUD, "email": T.PUSH_SA,
             "email_verified": True, "iat": now, "exp": now + 3600}
        c.update(claims)
        h = head or {"alg": "RS256", "kid": "k1", "typ": "JWT"}
        si = play._b64url(json.dumps(h).encode()) + "." + play._b64url(json.dumps(c).encode())
        return si + "." + play._b64url(T._OIDC_KEY.sign(si.encode(), padding.PKCS1v15(),
                                                        hashes.SHA256()))

    def _ok(self, jwt):
        try:
            play.verify_oidc(jwt, T.AUD, T.PUSH_SA)
            return True
        except play.PlayError:
            return False

    def test_clock_skew_tolerances(self):
        now = int(timezone.now().timestamp())
        self.assertTrue(self._ok(self._jwt(iat=now + 200)))         # our clock 200 s slow
        self.assertFalse(self._ok(self._jwt(iat=now + 400)))
        self.assertTrue(self._ok(self._jwt(exp=now - 30)))          # 60 s leeway
        self.assertFalse(self._ok(self._jwt(exp=now - 120)))

    def test_claim_and_header_checks(self):
        self.assertFalse(self._ok(self._jwt(head={"alg": "none", "kid": "k1"})))
        self.assertFalse(self._ok(self._jwt(head={"alg": "HS256", "kid": "k1"})))
        self.assertFalse(self._ok(self._jwt(head={"alg": "RS256", "kid": "unknown"})))
        self.assertFalse(self._ok(self._jwt(iss="https://evil.example")))
        self.assertFalse(self._ok(self._jwt(email_verified=False)))
        self.assertFalse(self._ok("a.b"))
        self.assertFalse(self._ok("!!.@@.##"))
        good = self._jwt()
        h, p, s = good.split(".")
        forged = play._b64url(json.dumps({"iss": "accounts.google.com", "aud": T.AUD,
                                          "email": "x@y", "email_verified": True,
                                          "exp": 2 ** 40}).encode())
        self.assertFalse(self._ok(h + "." + forged + "." + s))
        self.assertTrue(self._ok(good))

    def test_certs_unavailable_is_503_and_cached_when_ok(self):
        play.reset_cache()
        self.g.fail.append((play.CERTS_URI, (500, {})))
        with self.assertRaises(play.PlayError) as cm:
            play.verify_oidc(self._jwt(), T.AUD, T.PUSH_SA)
        self.assertEqual(cm.exception.status, 503)
        self.assertTrue(self._ok(self._jwt()))
        self.assertTrue(self._ok(self._jwt()))
        self.assertEqual(len([u for _, u in self.g.calls if u == play.CERTS_URI]), 2)

    def test_shared_token_mode(self):
        c = {"rtdn_audience": "", "rtdn_token": "s3cret"}
        self.assertTrue(play.authenticate_push("", "s3cret", c))
        for bad in ("", "s3cre", "S3CRET", None):
            with self.assertRaises(play.PlayError):
                play.authenticate_push("", bad, c)
        # both configured: both must pass
        c = {"rtdn_audience": T.AUD, "rtdn_token": "s3cret", "rtdn_sa_email": T.PUSH_SA}
        with self.assertRaises(play.PlayError):
            play.authenticate_push("Bearer " + self._jwt(), "wrong", c)
        with self.assertRaises(play.PlayError):
            play.authenticate_push("Basic abc", "s3cret", c)
        self.assertTrue(play.authenticate_push("Bearer " + self._jwt(), "s3cret", c))
