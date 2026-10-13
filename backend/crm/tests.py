"""
CRM tests — run with NO AI key and NO network.

They verify the HONEST core: scoring is deterministic (strong buying signals →
≥90 high priority; a weak lead scores low), lead capture works, rule-based
sentiment is correct, and proposal/ERP return clean needs-key / needs-integration
states (never fabricated data).

Run (the user will run this, not us):
  manage.py test crm --settings=assisto_backend.settings_test
"""
from django.contrib.auth import get_user_model
from django.test import TestCase

from . import scoring, logic
from .models import CrmOrg, CrmMember, Lead, Conversation, Message, Proposal

User = get_user_model()


class ScoringDeterminismTests(TestCase):
    """Pure-code scoring: same inputs → same score, strong signals → high."""

    def test_strong_lead_scores_high(self):
        # RMG + 500+ staff + multiple explicit buying signals → ≥ 90, high.
        text = "আমাদের গার্মেন্টসের জন্য ভ্যাট কমপ্লায়েন্ট ইআরপি লাগবে, দাম ও মডিউল জানান"
        res = scoring.base_score(industry="rmg", company_size=600,
                                 inbound_texts=[text])
        self.assertGreaterEqual(res["score"], 90)
        self.assertEqual(res["priority"], "high")
        # Deterministic: re-running gives the identical score.
        res2 = scoring.base_score(industry="rmg", company_size=600,
                                  inbound_texts=[text])
        self.assertEqual(res["score"], res2["score"])

    def test_weak_lead_scores_low(self):
        res = scoring.base_score(industry="other", company_size=0,
                                 inbound_texts=["হাই"])
        self.assertLess(res["score"], 50)
        self.assertEqual(res["priority"], "normal")

    def test_english_buying_signals_count(self):
        text = "what is the price and quote for your ERP module?"
        res = scoring.base_score(industry="retail", company_size=120,
                                 inbound_texts=[text])
        # retail(18) + size 100-199 => 14 + 4 signals*10 capped reasonably
        self.assertGreaterEqual(res["score"], 60)
        self.assertIn("price", res["signals"])
        self.assertIn("erp", res["signals"])


class SentimentRuleTests(TestCase):
    def test_positive(self):
        self.assertEqual(scoring.rule_sentiment("পরের সপ্তাহে কথা বলি চলেন"), "pos")

    def test_negative(self):
        self.assertEqual(scoring.rule_sentiment("আমাদের দরকার নেই"), "neg")

    def test_neutral(self):
        self.assertEqual(scoring.rule_sentiment("আপনার অফিস কোথায়?"), "neu")


class CaptureTests(TestCase):
    def setUp(self):
        self.user = User.objects.create_user(phone="0170000000", password="x12345")
        self.org = CrmOrg.objects.create(name="Axon Sales", owner=self.user)
        CrmMember.objects.create(org=self.org, user=self.user,
                                 role=CrmMember.OWNER)

    def test_capture_creates_lead_conversation_message_and_scores(self):
        lead = logic.capture_lead(
            org=self.org, source="whatsapp",
            contact={"phone": "018XXXXXXXX"},
            first_message="আমাদের গার্মেন্টসের জন্য ভ্যাট কমপ্লায়েন্ট ইআরপি লাগবে, দাম কত?",
            company="ABC Garments", industry="rmg", company_size=800,
        )
        self.assertIsInstance(lead, Lead)
        self.assertEqual(Conversation.objects.filter(lead=lead).count(), 1)
        self.assertEqual(
            Message.objects.filter(conversation__lead=lead, direction="in").count(), 1)
        # Strong signals → high priority, computed from real text (no AI key).
        self.assertGreaterEqual(lead.score, 90)
        self.assertEqual(lead.priority, "high")
        self.assertIn("buying_signals", lead.score_reason)

    def test_weak_capture_low_priority(self):
        lead = logic.capture_lead(
            org=self.org, source="messenger",
            contact={}, first_message="হাই",
        )
        self.assertLess(lead.score, 50)
        self.assertEqual(lead.priority, "normal")

    def test_add_message_sets_rule_sentiment_without_ai(self):
        lead = logic.capture_lead(org=self.org, source="whatsapp",
                                  contact={}, first_message="হাই")
        conv = lead.conversations.first()
        msg = logic.add_message(conv, Message.IN, "আমাদের দরকার নেই")
        self.assertEqual(msg.sentiment, "neg")
        # Insight summary is populated (rule-based recap, no AI/network).
        conv.refresh_from_db()
        self.assertTrue(conv.insight)


class NeedsKeyStateTests(TestCase):
    """With no AI key and no ERP integration, these must degrade cleanly."""

    def setUp(self):
        self.user = User.objects.create_user(phone="0171111111", password="x12345")
        self.org = CrmOrg.objects.create(name="Axon Sales", owner=self.user)
        CrmMember.objects.create(org=self.org, user=self.user,
                                 role=CrmMember.OWNER)
        self.lead = logic.capture_lead(org=self.org, source="whatsapp",
                                       contact={}, first_message="price?")

    def test_proposal_returns_needs_key_not_fake(self):
        res = logic.generate_proposal(self.lead, requirements="HRM + VAT")
        self.assertFalse(res.get("ok"))
        self.assertTrue(res.get("needs_key"))
        self.assertEqual(res.get("reason"), "no_key")
        self.assertIn("Available when", res.get("message", ""))
        # Nothing fabricated was stored.
        self.assertEqual(Proposal.objects.filter(lead=self.lead).count(), 0)

    def test_erp_onboard_returns_needs_integration_not_fake(self):
        res = logic.onboard_to_erp(self.lead)
        self.assertFalse(res.get("ok"))
        self.assertTrue(res.get("needs_integration"))
        self.assertIn("Axon ERP", res.get("message", ""))

    def test_followup_always_returns_usable_result(self):
        # No AI key → template draft, honest "suggestion" labelling, no network.
        res = logic.suggest_followup(self.lead)
        self.assertTrue(res.get("ok"))
        self.assertTrue(res.get("draft"))
        self.assertEqual(res.get("draft_source"), "template")
        self.assertIn("suggested_contact_date", res)


class ForecastHonestyTests(TestCase):
    def setUp(self):
        self.user = User.objects.create_user(phone="0172222222", password="x12345")
        self.org = CrmOrg.objects.create(name="Axon Sales", owner=self.user)
        CrmMember.objects.create(org=self.org, user=self.user,
                                 role=CrmMember.OWNER)

    def test_forecast_zero_when_no_open_deals(self):
        # No open deals → honest "not enough data", a zero weighted number, and
        # the auditable method string. Nothing is invented.
        from . import forecast as fc
        from .models import Deal
        res = fc.weighted_forecast(Deal.objects.filter(org=self.org))
        self.assertTrue(res["ok"])
        self.assertFalse(res["has_data"])
        self.assertEqual(res["weighted"], 0.0)
        self.assertEqual(res["open_count"], 0)
        self.assertIn("Σ(value", res["method"])

    def test_forecast_from_real_pipeline(self):
        # Weighted pipeline = Σ(value × probability / 100) over OPEN deals only.
        from decimal import Decimal
        from . import pipeline as pl, forecast as fc
        from .models import Deal
        pipe = pl.ensure_default_pipeline(self.org)
        stage = pipe.stages.first()
        # two open deals + one won (won must NOT count toward the open forecast)
        Deal.objects.create(org=self.org, title="A", pipeline=pipe, stage=stage,
                            value=Decimal("1000000"), probability=25, state="open")
        Deal.objects.create(org=self.org, title="B", pipeline=pipe, stage=stage,
                            value=Decimal("400000"), probability=50, state="open")
        Deal.objects.create(org=self.org, title="C (won)", pipeline=pipe,
                            stage=stage, value=Decimal("900000"),
                            probability=100, state="won")
        res = fc.weighted_forecast(Deal.objects.filter(org=self.org))
        self.assertTrue(res["has_data"])
        self.assertEqual(res["open_count"], 2)
        # 1,000,000×0.25 + 400,000×0.50 = 250,000 + 200,000 = 450,000
        self.assertEqual(res["weighted"], 450000.0)
        self.assertEqual(res["best_case"], 1400000.0)
