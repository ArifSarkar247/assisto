"""
Django DB tests for the AXON scenario assertions that MUST run through the REAL
view layer (they need the database + the DRF request cycle, so they cannot live
in the standalone pure `crm_scenario.run_all()`).

These complement crm/crm_scenario.py: run_all() asserts every REPORT number in
pure code; this file asserts the two GATES that are enforced inside the views
(not in the pure helpers):

  1. Closing a deal/lead as LOST with NO (or an invalid) loss reason is REJECTED
     — LeadViewSet.mark_lost and DealViewSet.move both require a valid reason.
  2. The proposal approval workflow: a >10% discount lands PENDING; it cannot be
     SENT before it is APPROVED; approval requires manage rights AND owner-
     reviewed prices (ProposalViewSet.transition).

Run (the integrator runs this, not us):
  manage.py test crm.tests_scenario --settings=assisto_backend.settings_test
"""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from rest_framework.exceptions import PermissionDenied, ValidationError
from rest_framework.test import APIRequestFactory, force_authenticate

from . import pipeline as pl
from . import quoting
from .models import CrmOrg, CrmMember, Lead, Deal, Proposal, Product
from .views import LeadViewSet, DealViewSet, ProposalViewSet

User = get_user_model()


class _Base(TestCase):
    def setUp(self):
        self.factory = APIRequestFactory()
        self.owner = User.objects.create_user(
            name="Owner", phone="01999111222", password="x")
        self.rep = User.objects.create_user(
            name="Rep", phone="01999111333", password="x")
        self.org = CrmOrg.objects.create(name="AXON", owner=self.owner)
        self.om = CrmMember.objects.create(
            org=self.org, user=self.owner, role=CrmMember.OWNER)
        self.rm = CrmMember.objects.create(
            org=self.org, user=self.rep, role=CrmMember.SALES)
        self.pipe = pl.ensure_default_pipeline(self.org)
        self.lead = Lead.objects.create(
            org=self.org, name="Buyer", company="Buyer Co", industry="rmg",
            company_size=600, source="whatsapp", assigned_to=self.om)


class LossReasonGateTests(_Base):
    """A LOST close with no/invalid reason is refused by the view."""

    def _mark_lost(self, data):
        req = self.factory.post("/crm/leads/x/mark_lost/", data, format="json")
        force_authenticate(req, user=self.owner)
        return LeadViewSet.as_view({"post": "mark_lost"})(req, pk=self.lead.pk)

    def test_mark_lost_without_reason_is_rejected(self):
        resp = self._mark_lost({})
        self.assertEqual(resp.status_code, 400)
        self.lead.refresh_from_db()
        self.assertNotEqual(self.lead.status, "lost")

    def test_mark_lost_with_invalid_reason_is_rejected(self):
        resp = self._mark_lost({"loss_reason": "not-a-real-reason"})
        self.assertEqual(resp.status_code, 400)

    def test_mark_lost_with_valid_reason_succeeds(self):
        resp = self._mark_lost({"loss_reason": "no_budget"})
        self.assertEqual(resp.status_code, 200)
        self.lead.refresh_from_db()
        self.assertEqual(self.lead.status, "lost")
        deal = self.lead.deals.first()
        self.assertEqual(deal.state, "lost")
        self.assertEqual(deal.loss_reason, "no_budget")

    def test_deal_move_to_lost_without_reason_is_rejected(self):
        """DealViewSet.move onto a Lost stage without a reason is refused too."""
        deal = Deal.objects.create(
            org=self.org, title="D", pipeline=self.pipe,
            stage=self.pipe.stages.order_by("order").first(), owner=self.om,
            value=Decimal(100000), probability=10, next_step="x")
        lost = self.pipe.stages.filter(is_lost=True).first()
        req = self.factory.post("/crm/deals/x/move/", {"stage": lost.id},
                                format="json")
        force_authenticate(req, user=self.owner)
        resp = DealViewSet.as_view({"post": "move"})(req, pk=deal.pk)
        self.assertEqual(resp.status_code, 400)
        deal.refresh_from_db()
        self.assertEqual(deal.state, "open")


class ProposalApprovalGateTests(_Base):
    """The discount-approval + send workflow enforced in ProposalViewSet."""

    def setUp(self):
        super().setUp()
        Product.objects.create(org=self.org, sku="ERP-CORE", name="Core",
                               unit_price=Decimal("250000"), price_reviewed=True)

    def _transition(self, prop, to, user):
        req = self.factory.post("/crm/proposals/x/transition/", {"to": to},
                                format="json")
        force_authenticate(req, user=user)
        return ProposalViewSet.as_view({"post": "transition"})(req, pk=prop.pk)

    def test_over_threshold_discount_lands_pending(self):
        prop = quoting.make_quote(self.lead, [{"sku": "ERP-CORE", "qty": 1}],
                                  discount_pct=15, created_by=self.om)
        self.assertTrue(prop.discount_needs_approval)
        self.assertEqual(prop.status, Proposal.PENDING)

    def test_cannot_send_before_approved(self):
        prop = quoting.make_quote(self.lead, [{"sku": "ERP-CORE", "qty": 1}],
                                  discount_pct=15, created_by=self.om)
        resp = self._transition(prop, Proposal.SENT, self.owner)
        self.assertEqual(resp.status_code, 400)   # must approve first
        prop.refresh_from_db()
        self.assertNotEqual(prop.status, Proposal.SENT)

    def test_salesperson_cannot_approve(self):
        prop = quoting.make_quote(self.lead, [{"sku": "ERP-CORE", "qty": 1}],
                                  discount_pct=15, created_by=self.om)
        resp = self._transition(prop, Proposal.APPROVED, self.rep)
        self.assertEqual(resp.status_code, 403)   # only owner/manager

    def test_approve_requires_reviewed_prices(self):
        """A quote using an UNREVIEWED product cannot be approved/sent."""
        Product.objects.create(org=self.org, sku="ERP-WIP", name="WIP",
                               unit_price=Decimal("50000"), price_reviewed=False)
        prop = quoting.make_quote(self.lead, [{"sku": "ERP-WIP", "qty": 1}],
                                  discount_pct=15, created_by=self.om)
        self.assertFalse(prop.prices_reviewed)
        resp = self._transition(prop, Proposal.APPROVED, self.owner)
        self.assertEqual(resp.status_code, 400)   # prices_reviewed gate

    def test_full_approve_then_send_flow(self):
        prop = quoting.make_quote(self.lead, [{"sku": "ERP-CORE", "qty": 1}],
                                  discount_pct=15, created_by=self.om)
        r1 = self._transition(prop, Proposal.APPROVED, self.owner)
        self.assertEqual(r1.status_code, 200)
        prop.refresh_from_db()
        self.assertEqual(prop.status, Proposal.APPROVED)
        r2 = self._transition(prop, Proposal.SENT, self.owner)
        self.assertEqual(r2.status_code, 200)
        prop.refresh_from_db()
        self.assertEqual(prop.status, Proposal.SENT)
