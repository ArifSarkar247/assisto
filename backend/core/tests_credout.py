"""credout — out of AI credits mid-task + consumable credit packs.

* Play packs are CONSUMABLE: the same product bought again with a new token
  credits again; the same token verified twice credits once; the server
  consumes, and says when it could not (the app then consumes itself).
* Home chat (/agent), Assisto AI chat (/send, /stream, /regenerate): out of
  credits answers 402 {reason:'credits', code:'out_of_credits'} and saves
  NOTHING (no turn, no reply, no charge) so the app can keep the typed text,
  open the buy-credits sheet and send the same request again.
"""
from django.test import TestCase
from rest_framework.test import APIClient

from core import ai
from core.models import ChatMessage, ChatSession, CreditPurchase, User
from core.payments import play
from core.tests_pay1 import PlayBase


def _pack(user, state=0, consumed=0, order="GPA.1111-0001"):
    return {"purchaseState": state, "consumptionState": consumed, "orderId": order,
            "acknowledgementState": 0,
            "obfuscatedExternalAccountId": play.account_id(user)}


class ConsumablePackTests(PlayBase):
    def test_same_product_two_tokens_credits_twice(self):
        self.g.products["tokA"] = _pack(self.u, order="GPA.1111-000A")
        self.g.products["tokB"] = _pack(self.u, order="GPA.1111-000B")
        r1 = self.verify("tokA", kind="pack", product="credits_p20")
        r2 = self.verify("tokB", kind="pack", product="credits_p20")
        self.assertEqual((r1.status_code, r2.status_code), (200, 200))
        self.assertEqual((r1.json()["granted"], r2.json()["granted"]), (20, 20))
        self.assertTrue(r1.json()["consumed"] and r2.json()["consumed"])
        self.assertEqual(sorted(self.g.consumed), ["tokA", "tokB"])
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 40)
        self.assertEqual(CreditPurchase.objects.filter(user=self.u,
                                                       provider="play_billing").count(), 2)

    def test_same_token_twice_credits_once(self):
        self.g.products["tokA"] = _pack(self.u)
        a = self.verify("tokA", kind="pack", product="credits_p50").json()
        b = self.verify("tokA", kind="pack", product="credits_p50").json()
        self.assertEqual((a["granted"], b["granted"]), (55, 0))
        self.assertEqual(b["state"], "granted")
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 55)
        self.assertEqual(self.g.consumed, ["tokA"])      # consumed once

    def test_consume_failure_is_reported_then_retried_without_regrant(self):
        self.g.products["tokA"] = _pack(self.u)
        real = self.g.__call__

        def no_consume(method, url, body=None, headers=None):
            if url.endswith(":consume"):
                return 500, {"error": {"message": "backend error"}}
            return real(method, url, body, headers)

        from unittest import mock
        with mock.patch("core.payments.play._http", side_effect=no_consume):
            r = self.verify("tokA", kind="pack", product="credits_p100").json()
        self.assertTrue(r["ok"])
        self.assertEqual(r["granted"], 115)
        self.assertFalse(r["consumed"])                 # app must consume
        r = self.verify("tokA", kind="pack", product="credits_p100").json()
        self.assertEqual(r["granted"], 0)                # never granted twice
        self.assertTrue(r["consumed"])
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 115)

    def test_all_four_packs_map_to_play_products(self):
        from core.payments import catalog
        for pid, credits in (("credits_p20", 20), ("credits_p50", 55),
                             ("credits_p100", 115), ("credits_p200", 240)):
            self.assertEqual(catalog.sku_for_play(pid), "pack_" + pid.split("_", 1)[1])
            self.assertEqual(catalog.describe(catalog.sku_for_play(pid))["credits"], credits)


class _AiOn:
    def ai_on(self):
        orig_p, orig_c = ai._providers, ai._call_anthropic
        ai._providers = lambda: [("anthropic", "k")]
        ai._call_anthropic = lambda key, model, system, prompt, mx, history=None: ("AI ok", 5, 5)
        self.addCleanup(lambda: setattr(ai, "_providers", orig_p))
        self.addCleanup(lambda: setattr(ai, "_call_anthropic", orig_c))


class OutOfCreditsChatTests(_AiOn, TestCase):
    def setUp(self):
        from datetime import timedelta
        from django.utils import timezone
        self.u = User.objects.create_user(name="Mita", phone="01711000077", password="x")
        self.u.plan = "free"
        self.u.trial_until = timezone.now() - timedelta(days=1)
        self.u.ai_credits = 0
        self.u.save()
        self.c = APIClient()
        self.c.force_authenticate(self.u)
        self.ai_on()

    def _assert_402(self, r):
        self.assertEqual(r.status_code, 402, getattr(r, "content", b"")[:300])
        j = r.json()
        self.assertEqual((j["reason"], j["code"], j["ok"]), ("credits", "out_of_credits", False))
        self.assertGreater(j["need"], 0)
        self.assertEqual(j["balance"], 0)
        self.assertTrue(j["message"])

    def test_ai_chat_send_402_saves_nothing_then_succeeds_after_topup(self):
        s = ChatSession.objects.create(user=self.u, source="ai")
        r = self.c.post(f"/api/v1/chat/sessions/{s.id}/send",
                        {"text": "write me a poem about rain"}, format="json")
        self._assert_402(r)
        self.assertFalse(ChatMessage.objects.filter(session=s).exists())
        s.refresh_from_db()
        self.assertEqual(s.title, "")
        # credits land (a verified pack) -> the SAME text goes through once
        User.objects.filter(pk=self.u.pk).update(ai_credits=20)
        r = self.c.post(f"/api/v1/chat/sessions/{s.id}/send",
                        {"text": "write me a poem about rain"}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()["ai_used"])
        self.assertEqual(list(ChatMessage.objects.filter(session=s)
                              .values_list("role", flat=True)), ["user", "assistant"])

    def test_stream_402_is_plain_json(self):
        s = ChatSession.objects.create(user=self.u, source="ai")
        r = self.c.post(f"/api/v1/chat/sessions/{s.id}/stream",
                        {"text": "explain photosynthesis"}, format="json")
        self._assert_402(r)
        self.assertFalse(ChatMessage.objects.filter(session=s).exists())

    def test_regenerate_402_keeps_old_reply_and_undoes_edit(self):
        s = ChatSession.objects.create(user=self.u, source="ai")
        um = ChatMessage.objects.create(session=s, role="user", text="old question")
        ChatMessage.objects.create(session=s, role="assistant", text="old answer")
        r = self.c.post(f"/api/v1/chat/sessions/{s.id}/regenerate",
                        {"edit": "new question"}, format="json")
        self._assert_402(r)
        um.refresh_from_db()
        self.assertEqual(um.text, "old question")
        self.assertTrue(ChatMessage.objects.filter(session=s, text="old answer").exists())

    def test_home_agent_question_402_persists_nothing(self):
        r = self.c.post("/api/v1/agent", {"text": "what is the capital of france?"},
                        format="json")
        self._assert_402(r)
        self.assertFalse(ChatSession.objects.filter(user=self.u, source="home").exists())

    def test_home_agent_actions_never_need_credits(self):
        r = self.c.post("/api/v1/agent", {"text": "remind me to call mom tomorrow 9am"},
                        format="json")
        self.assertEqual(r.status_code, 200)

    def test_premium_with_empty_pool_gets_the_same_402(self):
        from datetime import timedelta
        from django.utils import timezone
        from core.models import CreditLedger  # noqa: F401 — pool bookkeeping
        self.u.plan = "premium"
        self.u.plan_until = timezone.now() + timedelta(days=30)
        self.u.save()
        from core import billing
        billing.ensure_monthly_pool(self.u)        # this month's pool lands...
        User.objects.filter(pk=self.u.pk).update(ai_credits=0)   # ...and is spent
        s = ChatSession.objects.create(user=self.u, source="ai")
        r = self.c.post(f"/api/v1/chat/sessions/{s.id}/send",
                        {"text": "plan my week"}, format="json")
        self.assertEqual(r.status_code, 402)
        self.assertEqual(r.json()["code"], "out_of_credits")

    def test_no_key_still_answers_free_brain(self):
        ai._providers = lambda: []
        s = ChatSession.objects.create(user=self.u, source="ai")
        r = self.c.post(f"/api/v1/chat/sessions/{s.id}/send",
                        {"text": "what is my balance"}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.json()["ai_used"])
