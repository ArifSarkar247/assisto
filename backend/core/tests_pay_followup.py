"""pay-followup (25 Oct) — the open money risks the hardening pass reported.

1  Play ack sweep: an acknowledge / consume that failed and got no later
   RTDN / verify is retried by the hourly payments sweep (< 3 days old,
   backoff), never granting or counting twice.
2  EPS: a token EPS revoked before its expiry is dropped on 401 / "invalid
   token" and the call retried once with a fresh token.
3  (RTDN other-account -> 2xx is in tests_pay_hardening.)
4  /pay/return shows order number / amount only to the signed-in owner or
   the browser with the signed return token; otherwise a neutral page.
5  EPS IPN naive timestamps: fresh as UTC OR as Asia/Dhaka.
+  Play refund of an older renewal reverses THAT order's revenue.
All mocked: no EPS / Google network.
"""
import json
from datetime import datetime, timedelta, timezone as dt_tz
from unittest import mock
from urllib.parse import parse_qs, urlparse

import requests
from django.core.management import call_command
from django.test import TestCase
from django.utils import timezone

from core.models import PaymentEvent, PaymentOrder, PlayPurchase, User
from core.payments import eps, gateway as G, play, service as S
from core import tests_pay1 as T
from core.tests_pay_hardening import PlayHBase, _plan


# ======================================================================= 1 Play ack sweep
class PlayAckSweepTests(PlayHBase):
    def test_failed_sub_ack_is_retried_by_sweep_with_backoff(self):
        self.g.subs["t"] = T.sub_body(self.u)
        self.g.fail.append((":acknowledge", (500, {})))
        self.verify("t")
        self.assertFalse(PlayPurchase.objects.get().acknowledged)
        now = timezone.now()
        # Google still failing -> backoff recorded, nothing granted twice
        self.g.fail.append((":acknowledge", requests.Timeout()))
        out = play.ack_sweep(now)
        self.assertEqual((out["tried"], out["failed"]), (1, 1))
        meta = PlayPurchase.objects.get().raw["ack_retry"]
        self.assertEqual(meta["n"], 1)
        # inside the backoff window: skipped, no Google call
        n_calls = len(self.g.calls)
        self.assertEqual(play.ack_sweep(now + timedelta(minutes=5))["skipped"], 1)
        self.assertEqual(len(self.g.calls), n_calls)
        # after the backoff: acknowledged once
        out = play.ack_sweep(now + timedelta(minutes=16))
        self.assertEqual(out["acked"], 1)
        pp = PlayPurchase.objects.get()
        self.assertTrue(pp.acknowledged)
        self.assertEqual(self.g.acks, ["t"])
        self.assertEqual(self.charges(), 1)
        self.assertTrue(PaymentEvent.objects.filter(kind="play.ack_sweep").exists())
        # nothing left to do
        self.assertEqual(play.ack_sweep(now + timedelta(hours=2))["tried"], 0)
        self.assertEqual(self.g.acks, ["t"])

    def test_backoff_doubles_and_caps(self):
        self.g.subs["t"] = T.sub_body(self.u)
        self.g.fail.append((":acknowledge", (500, {})))
        self.verify("t")
        now = timezone.now()
        delays = []
        for i in range(7):
            self.g.fail.append((":acknowledge", (503, {})))
            play.ack_sweep(now)
            nxt = play._ts(PlayPurchase.objects.get().raw["ack_retry"]["next"])
            delays.append(round((nxt - now).total_seconds() / 60))
            now = nxt
        self.assertEqual(delays, [15, 30, 60, 120, 240, 360, 360])

    def test_failed_pack_consume_is_retried_by_payments_sweep_command(self):
        self.pack()
        self.g.fail.append((":consume", (500, {})))
        self.verify("ptok", kind="pack", product="credits_p20")
        self.assertFalse(PlayPurchase.objects.get().consumed)
        credits = T.User.objects.get(pk=self.u.pk).ai_credits
        call_command("payments_sweep", stdout=open("/dev/null", "w"))
        self.assertTrue(PlayPurchase.objects.get().consumed)
        self.assertEqual(self.g.consumed, ["ptok"])
        self.assertEqual(User.objects.get(pk=self.u.pk).ai_credits, credits)   # no re-grant
        self.assertEqual(self.charges(), 1)

    def test_old_revoked_pending_and_other_account_are_left_alone(self):
        self.g.subs["old"] = T.sub_body(self.u)
        self.g.subs["rev"] = T.sub_body(self.u, order="GPA.1")
        self.g.subs["pend"] = T.sub_body(self.u, state="SUBSCRIPTION_STATE_PENDING")
        for tok in ("old", "rev"):
            self.g.fail.append((":acknowledge", (500, {})))
            self.verify(tok)
        self.verify("pend")
        PlayPurchase.objects.filter(token_hash=play.token_hash("old")).update(
            created_at=timezone.now() - timedelta(days=3, minutes=1))
        PlayPurchase.objects.filter(token_hash=play.token_hash("rev")).update(revoked=True)
        out = play.ack_sweep()
        self.assertEqual(out["tried"], 0)
        self.assertEqual(self.g.acks, [])
        # a token whose account no longer matches: tried, never raises, backs off
        self.g.subs["x"] = T.sub_body(self.u)
        self.g.fail.append((":acknowledge", (500, {})))
        self.verify("x")
        other = User.objects.create_user(name="M", phone="01811000009", password="x")
        self.g.subs["x"] = T.sub_body(other)
        out = play.ack_sweep()
        self.assertEqual((out["tried"], out["failed"]), (1, 1))
        self.assertEqual(PlayPurchase.objects.get(token_hash=play.token_hash("x")).raw[
            "ack_retry"]["err"], "other_account")
        self.assertEqual(_plan(other), "free")

    def test_unconfigured_play_is_a_noop_and_sweep_survives_crash(self):
        from core import integrations
        integrations.save("play_billing", {})
        self.assertEqual(play.ack_sweep()["tried"], 0)
        with mock.patch("core.payments.play.ack_sweep", side_effect=RuntimeError("x")):
            out = S.sweep()
        self.assertNotIn("play_ack", out)
        self.assertIn("reverified", out)


# ======================================================================= + refund of a renewal
class PlayRenewalRefundTests(PlayHBase):
    ORD = "GPA.3300-0000-0000-00000"

    def test_voided_older_renewal_reverses_that_order_only_once(self):
        self.g.subs["t"] = T.sub_body(self.u, order=self.ORD)
        self.verify("t")
        self.g.subs["t"] = T.sub_body(self.u, order=self.ORD + "..0", ack=True, expiry_days=60)
        self.rtdn_push(self.sn("t", 2), mid="r1")
        self.g.subs["t"] = T.sub_body(self.u, order=self.ORD + "..1", ack=True, expiry_days=90)
        self.rtdn_push(self.sn("t", 2), mid="r2")
        self.assertEqual(self.charges(), 3)

        def voided(order, mid):
            v = {"packageName": "com.assisto.assisto",
                 "voidedPurchaseNotification": {"purchaseToken": "t", "orderId": order,
                                                "productType": 1, "refundType": 1}}
            r = self.rtdn_push(v, mid=mid)
            self.assertEqual(r.status_code, 200, r.content)

        voided(self.ORD + "..0", "v1")                     # the MIDDLE renewal refunded
        refunds = PaymentEvent.objects.filter(kind="play.refund").values_list("ref", flat=True)
        self.assertEqual(list(refunds.all()), [self.ORD + "..0"])
        voided(self.ORD + "..0", "v1b")                    # repeat: no second reversal
        self.assertEqual(refunds.all().count(), 1)
        voided(self.ORD, "v2")                             # another order: reversed too
        self.assertEqual(sorted(refunds.all()), [self.ORD, self.ORD + "..0"])
        voided("GPA.unknown", "v3")                        # unknown order: nothing
        self.assertEqual(refunds.all().count(), 2)
        self.assertEqual(_plan(self.u), "free")

    def test_revoked_without_order_reverses_latest(self):
        self.g.subs["t"] = T.sub_body(self.u, order=self.ORD)
        self.verify("t")
        self.g.subs["t"] = T.sub_body(self.u, order=self.ORD + "..0", ack=True, expiry_days=60)
        self.rtdn_push(self.sn("t", 2), mid="r1")
        self.rtdn_push(self.sn("t", 12), mid="rev")
        self.rtdn_push(self.sn("t", 12), mid="rev2")
        self.assertEqual([e.ref for e in PaymentEvent.objects.filter(kind="play.refund")],
                         [self.ORD + "..0"])


# ======================================================================= 2 EPS token revoked early
class EpsTokenRevokedTests(T.PayBase):
    def setUp(self):
        super().setUp()
        T.enable_eps()

    def _revoke_on_next_call(self, response=(401, {})):
        """EPS revokes the cached token: the next authorised call fails once,
        then a fresh token from GetToken works."""
        real = self.fake.__call__
        state = {"done": False, "token_calls": 0}

        def f(method, url, body=None, headers=None):
            if url.endswith("/v1/Auth/GetToken"):
                state["token_calls"] += 1
            elif not state["done"]:
                state["done"] = True
                return response
            return real(method, url, body, headers)
        return f, state

    def test_401_drops_cached_token_and_retries_once(self):
        o = S.checkout(self.u, "premium_monthly")          # token cached
        self.fake.pay(o.merchant_tx_id)
        for resp in ((401, {}),
                     (200, {"ErrorCode": "401", "ErrorMessage": "Unauthorized"}),
                     (200, {"ErrorCode": 1, "ErrorMessage": "Invalid Token"}),
                     (200, {"ErrorCode": 7, "ErrorMessage": "Token expired"})):
            f, state = self._revoke_on_next_call(resp)
            with mock.patch("core.payments.eps._http", side_effect=f):
                res = eps.EpsGateway().verify(o)
            self.assertEqual(res.status, "paid", resp)
            self.assertEqual(state["token_calls"], 1, resp)   # exactly one refresh

    def test_checkout_survives_revoked_token_and_grant_once(self):
        S.checkout(self.u, "premium_monthly", idem="a")     # token cached
        f, state = self._revoke_on_next_call()
        with mock.patch("core.payments.eps._http", side_effect=f):
            o = S.checkout(self.u, "premium_monthly", idem="b")
        self.assertEqual(o.status, "pending")
        self.fake.pay(o.merchant_tx_id)
        self.assertEqual(S.complete(o).status, "paid")
        self.assertEqual(_plan(self.u), "premium")

    def test_still_rejected_after_refresh_is_verify_failed_not_a_loop(self):
        o = S.checkout(self.u, "premium_monthly")
        calls = []

        def f(method, url, body=None, headers=None):
            calls.append(url)
            if url.endswith("/v1/Auth/GetToken"):
                return self.fake(method, url, body, headers)
            return 401, {}
        with mock.patch("core.payments.eps._http", side_effect=f):
            with self.assertRaises(G.GatewayError) as cm:
                eps.EpsGateway().verify(o)
        self.assertEqual(cm.exception.reason, "verify_failed")
        self.assertEqual(len([c for c in calls if "CheckMerchant" in c]), 2)
        self.assertNotEqual(S.complete(o).status, "paid")

    def test_wrong_hash_is_not_mistaken_for_a_token_problem(self):
        self.assertFalse(eps._token_rejected(200, {"ErrorCode": "400",
                                                   "ErrorMessage": "Invalid hash provided."}))
        self.assertFalse(eps._token_rejected(200, None))
        self.assertTrue(eps._token_rejected(401, None))


# ======================================================================= 4 /pay/return disclosure
class PayReturnDisclosureTests(T.PayBase):
    def setUp(self):
        super().setUp()
        T.enable_eps()
        self.o = S.checkout(self.u, "premium_monthly")
        self.fake.pay(self.o.merchant_tx_id)
        self.success = self.fake.sessions[self.o.merchant_tx_id]["body"]["successUrl"]

    def _t(self):
        return parse_qs(urlparse(self.success).query)["t"][0]

    def test_return_urls_carry_signed_token_for_this_order(self):
        body = self.fake.sessions[self.o.merchant_tx_id]["body"]
        for k in ("successUrl", "failUrl", "cancelUrl"):
            q = parse_qs(urlparse(body[k]).query)
            self.assertTrue(S.return_token_ok(self.o.merchant_tx_id, q["t"][0]))
        self.assertFalse(S.return_token_ok("1234567890123", self._t()))   # bound to the tx
        self.assertFalse(S.return_token_ok(self.o.merchant_tx_id, "garbage"))
        self.assertFalse(S.return_token_ok(self.o.merchant_tx_id, ""))

    def test_tx_id_alone_gets_neutral_page_but_still_completes(self):
        r = self.client.get("/pay/return", {"r": "success", "lang": "en",
                                            "MerchantTransactionId": self.o.merchant_tx_id})
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "we got your payment details")
        self.assertNotContains(r, "#%d ·" % self.o.pk)
        self.assertNotContains(r, "৳")
        self.assertNotContains(r, "Payment received")
        self.assertContains(r, 'href="assisto://payments/done"')
        self.assertEqual(_plan(self.u), "premium")          # the verify still ran
        # an unknown tx looks the same (no existence oracle)
        r2 = self.client.get("/pay/return", {"lang": "en", "MerchantTransactionId": "1"})
        self.assertContains(r2, "we got your payment details")
        self.assertNotContains(r2, "Order not found")

    def test_signed_token_shows_details(self):
        r = self.client.get("/pay/return", {"r": "success", "lang": "en", "t": self._t(),
                                            "MerchantTransactionId": self.o.merchant_tx_id})
        self.assertContains(r, "Payment received")
        self.assertContains(r, "#%d ·" % self.o.pk)
        self.assertContains(r, "৳199")

    def test_expired_token_is_neutral(self):
        t = self._t()
        with mock.patch("django.core.signing.time.time",
                        return_value=__import__("time").time() + S.RETURN_TOKEN_MAX_AGE_S + 60):
            r = self.client.get("/pay/return", {"lang": "en", "t": t,
                                                "MerchantTransactionId": self.o.merchant_tx_id})
        self.assertNotContains(r, "#%d ·" % self.o.pk)
        self.assertContains(r, "we got your payment details")

    def test_signed_in_other_user_sees_neutral_owner_sees_details(self):
        from core.models import WebCheckoutSession
        other = User.objects.create_user(name="M", phone="01811000008", password="x")
        import hashlib
        import secrets as _s
        for who, expect in ((other, False), (self.u, True)):
            raw = _s.token_urlsafe(24)
            WebCheckoutSession.objects.create(
                user=who, token_hash=hashlib.sha256(raw.encode()).hexdigest(),
                expires_at=timezone.now() + timedelta(minutes=30))
            self.client.cookies["as_pay"] = raw
            r = self.client.get("/pay/return", {"lang": "en",
                                                "MerchantTransactionId": self.o.merchant_tx_id})
            self.assertEqual("#%d ·" % self.o.pk in r.content.decode(), expect, who)


# ======================================================================= 5 IPN time zone
class EpsIpnTimezoneTests(TestCase):
    def setUp(self):
        T.enable_eps(ipn_key=T.IPN_KEY)
        self.g = eps.EpsGateway()

    def _ipn(self, ts):
        return self.g.tx_from_ipn(json.dumps({"Data": eps.encrypt_ipn(
            {"merchant_transaction_id": "1234567890", "timestamp": ts}, T.IPN_KEY)}), {})

    def _stale(self, ts):
        with self.assertRaises(G.GatewayError) as cm:
            self._ipn(ts)
        return cm.exception.reason == "stale"

    def test_naive_timestamp_as_utc_or_dhaka(self):
        now_utc = datetime.now(dt_tz.utc)
        dhaka = now_utc.astimezone(eps.DHAKA)
        fmt = "%Y-%m-%dT%H:%M:%S"
        # naive UTC wall clock, and naive Bangladesh wall clock (UTC+6): both fresh
        self.assertEqual(self._ipn((now_utc - timedelta(minutes=10)).strftime(fmt))[0], "1234567890")
        self.assertEqual(self._ipn((dhaka - timedelta(minutes=10)).strftime(fmt))[0], "1234567890")
        self.assertEqual(self._ipn((dhaka + timedelta(minutes=29)).strftime(fmt))[0], "1234567890")
        # space separator (common in BD gateways)
        self.assertEqual(self._ipn(dhaka.strftime("%Y-%m-%d %H:%M:%S"))[0], "1234567890")
        # +-30 min window still applies to both readings
        for d in (dhaka + timedelta(minutes=31), dhaka - timedelta(minutes=31),
                  now_utc - timedelta(hours=3), now_utc + timedelta(hours=3)):
            self.assertTrue(self._stale(d.strftime(fmt)), d)

    def test_explicit_offset_is_taken_literally(self):
        now_utc = datetime.now(dt_tz.utc)
        self.assertEqual(self._ipn(now_utc.astimezone(eps.DHAKA).isoformat())[0], "1234567890")
        # a +06:00 timestamp that is really 6 h old is stale (no double reading)
        self.assertTrue(self._stale((now_utc - timedelta(hours=6)).astimezone(eps.DHAKA).isoformat()))
        self.assertTrue(self._stale((now_utc + timedelta(hours=6)).isoformat()))
