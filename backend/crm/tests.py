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


# ---------------------------------------------------------------------------
# FIRST-RUN + role scoping + ref-code tests (the in-app CRM "never show a raw
# couldn't-load" work). These drive the real DRF endpoints under /crm/ so they
# cover the client first-run contract: a brand-new user sees orgs == [] (not an
# error); an owner who creates an org gets a seeded pipeline with the default
# stages and a working dashboard; a salesperson who joined via invite code can
# sell but gets a restricted (not errored) financial dashboard.
# Run with the rest of the suite: manage.py test crm  (the integrator runs it).
# ---------------------------------------------------------------------------
import logging

from rest_framework.test import APITestCase

from .models import Deal, Stage
from . import errors as crm_errors
from . import pipeline as pl


class FirstRunApiTests(APITestCase):
    """Brand-NEW user → GET /crm/orgs/ returns [] (first-run, NOT an error),
    then 'Start your CRM' creates an org + owner membership + seeded stages."""

    def setUp(self):
        self.user = User.objects.create_user(phone="0170000001", password="x12345")
        self.client.force_authenticate(user=self.user)

    def test_brand_new_user_has_no_orgs(self):
        r = self.client.get("/api/v1/crm/orgs/")
        self.assertEqual(r.status_code, 200)
        # DRF list → [] (the client reads [] as first-run, never as an error).
        self.assertEqual(list(r.data), [])

    def test_start_crm_creates_org_owner_and_seeded_pipeline(self):
        r = self.client.post("/api/v1/crm/orgs/",
                             {"name": "Axon Sales", "industry": "rmg",
                              "team_size": "small"}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        org = CrmOrg.objects.get(id=r.data["id"])
        self.assertEqual(org.industry, "rmg")
        # Creator is seeded as OWNER.
        m = CrmMember.objects.get(org=org, user=self.user)
        self.assertEqual(m.role, CrmMember.OWNER)
        # A sample pipeline with the FULL set of default stages exists, incl. a
        # Won and a Lost stage (so mark_won / mark_lost work immediately).
        pipe = org.pipelines.filter(is_default=True).first()
        self.assertIsNotNone(pipe)
        self.assertEqual(pipe.stages.count(), len(pl.DEFAULT_STAGES))
        self.assertTrue(pipe.stages.filter(is_won=True).exists())
        self.assertTrue(pipe.stages.filter(is_lost=True).exists())
        # The org now shows up in the user's list — first-run is over.
        r2 = self.client.get("/api/v1/crm/orgs/")
        self.assertEqual(len(r2.data), 1)
        # A unique invite code was minted.
        self.assertTrue(org.invite_code)
        self.assertEqual(len(org.invite_code), 8)

    def test_owner_dashboard_loads_after_create(self):
        r = self.client.post("/api/v1/crm/orgs/", {"name": "Axon"}, format="json")
        org_id = r.data["id"]
        d = self.client.get(f"/api/v1/crm/dashboard?org={org_id}")
        self.assertEqual(d.status_code, 200, d.data)
        self.assertTrue(d.data["ok"])
        # Owner is NOT restricted — sees the financial sections.
        self.assertNotIn("restricted", d.data)
        self.assertIn("forecast", d.data)
        self.assertIn("pipeline_value", d.data)


class JoinAndRoleTests(APITestCase):
    """SALESPERSON joins via code → can sell (create/list leads) but cannot see
    the profit/forecast dashboard (restricted, not errored). Owner-only invite."""

    def setUp(self):
        self.owner = User.objects.create_user(phone="0170000010", password="x12345")
        self.rep = User.objects.create_user(phone="0170000011", password="x12345")
        self.org = CrmOrg.objects.create(name="Axon Sales", owner=self.owner)
        CrmMember.objects.create(org=self.org, user=self.owner, role=CrmMember.OWNER)
        pl.ensure_default_pipeline(self.org)

    def test_invite_code_is_owner_only(self):
        # A non-member cannot read the invite code (scoped away → 404), and a
        # salesperson member cannot either (403), only the owner can.
        self.client.force_authenticate(user=self.rep)
        r = self.client.get(f"/api/v1/crm/orgs/{self.org.id}/invite/")
        self.assertIn(r.status_code, (403, 404))
        self.client.force_authenticate(user=self.owner)
        r2 = self.client.get(f"/api/v1/crm/orgs/{self.org.id}/invite/")
        self.assertEqual(r2.status_code, 200, r2.data)
        self.assertEqual(r2.data["invite_code"], self.org.invite_code)

    def test_join_with_code_adds_salesperson(self):
        self.client.force_authenticate(user=self.rep)
        r = self.client.post("/api/v1/crm/join",
                             {"code": self.org.invite_code}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertTrue(r.data["joined"])
        m = CrmMember.objects.get(org=self.org, user=self.rep)
        # Joiner always lands as plain SALES — never owner/manager (no privilege
        # escalation via the join path).
        self.assertEqual(m.role, CrmMember.SALES)

    def test_join_with_bad_code_is_clean_validation_error_with_ref(self):
        self.client.force_authenticate(user=self.rep)
        r = self.client.post("/api/v1/crm/join", {"code": "NOPECODE"},
                             format="json")
        self.assertEqual(r.status_code, 400)
        # Every CRM error carries a reference code the user can quote to support.
        self.assertIn("ref", r.data)
        self.assertEqual(len(r.data["ref"]), 6)

    def test_salesperson_can_sell_but_dashboard_is_restricted(self):
        CrmMember.objects.create(org=self.org, user=self.rep, role=CrmMember.SALES)
        self.client.force_authenticate(user=self.rep)
        # CAN sell: create + list leads.
        c = self.client.post("/api/v1/crm/leads/",
                             {"org": self.org.id, "name": "Prospect",
                              "company": "ABC", "industry": "rmg"}, format="json")
        self.assertIn(c.status_code, (200, 201), c.data)
        lst = self.client.get(f"/api/v1/crm/leads/?org={self.org.id}")
        self.assertEqual(lst.status_code, 200)
        # CANNOT see profit/forecast: dashboard returns a restricted (not errored)
        # payload with NO financial fields.
        d = self.client.get(f"/api/v1/crm/dashboard?org={self.org.id}")
        self.assertEqual(d.status_code, 200, d.data)
        self.assertTrue(d.data.get("restricted"))
        self.assertNotIn("pipeline_value", d.data)
        self.assertNotIn("forecast", d.data)
        self.assertNotIn("won_value", d.data)


class RefCodeCorrelationTests(APITestCase):
    """The ref code the client shows is the SAME one written to the server log,
    so support can grep the log for a user-reported code and find the context."""

    def setUp(self):
        self.user = User.objects.create_user(phone="0170000020", password="x12345")
        self.client.force_authenticate(user=self.user)

    def test_error_ref_is_logged_with_context(self):
        with self.assertLogs("crm.errors", level="WARNING") as cm:
            r = self.client.post("/api/v1/crm/join", {"code": ""}, format="json")
        self.assertEqual(r.status_code, 400)
        ref = r.data["ref"]
        # The exact code the client received appears in a server log line.
        joined = "\n".join(cm.output)
        self.assertIn(ref, joined)
        self.assertIn("ref=" + ref, joined)

    def test_ref_code_shape(self):
        code = crm_errors.ref_code()
        self.assertEqual(len(code), 6)
        # Unambiguous alphabet: never 0/O/1/I.
        self.assertFalse(set(code) & set("01OI"))
