"""pay1: owner panel — Payments (switches reach the app config at runtime,
fees/prices validated + audited, refund reverses the grant), P&L per channel,
Integrations lists EPS + the Play Billing RTDN fields."""
from unittest import mock

from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from core import billing, integrations
from core.models import Integration, OwnerAudit, PaymentOrder, User
from core.payments import service as S
from core.tests_pay1 import FakeEps, enable_eps
from web.tests_o2_owner_admin import OwnerBase


class PaymentsPanelTests(OwnerBase):
    def setUp(self):
        super().setUp()
        self.u = User.objects.create_user(name="Rina", phone="01711000201", password="x")
        self.fake = FakeEps()
        p = mock.patch("core.payments.eps._http", side_effect=self.fake)
        p.start()
        self.addCleanup(p.stop)
        q = mock.patch("core.push.push_to_user", return_value=0)
        q.start()
        self.addCleanup(q.stop)
        self.ready()

    def _form(self, **over):
        d = {"action": "save", "play_enabled": "on", "gateway_enabled": "on",
             "gateway_on_play": "on", "web_enabled": "on", "play_fee_subs": "0.15",
             "play_fee_packs": "0.15", "gateway_fee": "0.02", "reminder_days": "7, 3, 1",
             "reason": "test"}
        d.update(over)
        return {k: v for k, v in d.items() if v is not None}

    def test_page_bn_en(self):
        r = self.c.get("/owner/payments?lang=en")
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "Ways to pay")
        self.assertContains(r, "/api/v1/payments/gateway/ipn")
        self.assertContains(r, "Keys not added yet")
        r = self.c.get("/owner/payments?lang=bn")
        self.assertContains(r, "পেমেন্টের উপায়")

    def test_kill_switch_reaches_app_config_and_is_audited(self):
        # pay-e2e: the default is now OFF (owner 26 Oct) — switch it on first
        self.assertFalse(billing.cfg()["payments"]["gateway_on_play"])
        self.post("/owner/payments", self._form())
        self.assertTrue(billing.cfg()["payments"]["gateway_on_play"])
        r = self.post("/owner/payments", self._form(gateway_on_play=None))
        self.assertEqual(r.status_code, 302, r.content[:400])
        self.assertFalse(billing.cfg()["payments"]["gateway_on_play"])
        a = OwnerAudit.objects.filter(action="payments.update").order_by("-id").first()
        self.assertIn("gateway_on_play", a.after)
        api = APIClient()
        api.credentials(HTTP_AUTHORIZATION="Token " + Token.objects.create(user=self.u).key)
        enable_eps()
        cfg = api.get("/api/v1/payments/config?flavour=play").json()
        gw = [c for c in cfg["channels"] if c["id"] == "gateway"][0]
        self.assertFalse(gw["enabled"])

    def test_prices_and_fees(self):
        r = self.post("/owner/payments", self._form(**{"price_play_premium_monthly": "219",
                                                       "gateway_fee": "0.025"}))
        self.assertEqual(r.status_code, 302)
        p = billing.cfg()["payments"]
        self.assertEqual(p["channel_prices"]["play"]["premium_monthly"], 219)
        self.assertEqual(p["gateway_fee"], 0.025)
        r = self.post("/owner/payments", self._form(gateway_fee="0.9"))
        self.assertEqual(r.status_code, 400)
        r = self.post("/owner/payments", self._form(**{"price_gateway_premium_monthly": "-5"}))
        self.assertEqual(r.status_code, 400)
        self.assertEqual(billing.cfg()["payments"]["gateway_fee"], 0.025)

    def test_refund_action(self):
        enable_eps()
        o = S.checkout(self.u, "premium_monthly")
        self.fake.pay(o.merchant_tx_id)
        S.complete(o)
        self.u.refresh_from_db()
        self.assertEqual(self.u.plan, "premium")
        r = self.post("/owner/payments", {"action": "refund", "order": o.pk})
        self.assertEqual(r.status_code, 400)              # reason required
        r = self.post("/owner/payments", {"action": "refund", "order": o.pk,
                                          "reason": "customer asked"})
        self.assertEqual(r.status_code, 302)
        self.assertEqual(PaymentOrder.objects.get(pk=o.pk).status, "refunded")
        self.u.refresh_from_db()
        self.assertEqual(self.u.plan, "free")
        self.assertTrue(OwnerAudit.objects.filter(action="payments.refund", ok=True).exists())
        r = self.c.get("/owner/pnl?lang=en")
        self.assertContains(r, "Net revenue per channel")

    def test_integrations_lists_eps_and_rtdn_fields(self):
        r = self.c.get("/owner/integrations?lang=en")
        self.assertContains(r, "EPS payment gateway")
        self.assertContains(r, "RTDN push audience")

    def test_eps_integration_test_button_is_honest(self):
        integrations.save("eps", {"merchant_id": "m", "store_id": "s", "username": "u@test",
                                  "password": "p", "hash_key": "wrong", "mode": "sandbox"})
        st, detail = integrations.test("eps")
        self.assertEqual(st, "failing")
        self.assertIn("eps_auth", detail)
        enable_eps()
        st, detail = integrations.test("eps")
        self.assertEqual(st, "working", detail)
        self.assertEqual(Integration.objects.get(slug="eps").status, "working")
