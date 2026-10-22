"""q1-seams (reality audit 22 Oct): with a WhatsApp key connected, the CRM used
to answer a send with state 'queued' ("Message queued for sending") although
nothing in the codebase ever POSTs the assembled Graph request. Until a live
sender exists the API must report a logged DRAFT, never a claimed send."""
from unittest import mock

from django.contrib.auth import get_user_model
from rest_framework.test import APITransactionTestCase

from . import whatsapp as wa
from .models import CrmOrg, CrmMember, Lead
from .tests import WhatsAppEndpointTests

User = get_user_model()


class HonestWhatsAppStateTests(APITransactionTestCase):
    _wa_models = None
    _wa_schema = WhatsAppEndpointTests._wa_schema

    def setUp(self):
        self._wa_schema(create=True)
        self.user = User.objects.create_user(phone="0174444444", password="x12345")
        self.client.force_authenticate(user=self.user)
        self.org = CrmOrg.objects.create(name="Q1", owner=self.user)
        CrmMember.objects.create(org=self.org, user=self.user,
                                 role=CrmMember.OWNER)
        self.lead = Lead.objects.create(org=self.org, name="Karim",
                                        phone="01712345678",
                                        whatsapp="01712345678")
        self.client.post(f"/api/v1/crm/leads/{self.lead.id}/whatsapp_optin/",
                         {"opted_in": True}, format="json")
        self.client.post(f"/api/v1/crm/leads/{self.lead.id}/whatsapp_receive/",
                         {"text": "hi"}, format="json")

    def tearDown(self):
        self._wa_schema(create=False)

    def test_honest_state_helper(self):
        self.assertFalse(wa.LIVE_SEND_BUILT)
        self.assertEqual(wa.honest_state("queued"), "draft")
        self.assertEqual(wa.honest_state("needs_key"), "needs_key")
        with mock.patch.object(wa, "LIVE_SEND_BUILT", True):
            self.assertEqual(wa.honest_state("queued"), "queued")

    def test_send_with_key_is_a_draft_not_queued(self):
        with mock.patch("crm.views._wa_has_key", return_value=True):
            r = self.client.post(
                f"/api/v1/crm/leads/{self.lead.id}/whatsapp_send/",
                {"text": "thanks"}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data["state"], "draft")
        self.assertFalse(r.data["live_send"])

    def test_bulk_with_key_reports_drafts(self):
        with mock.patch("crm.views._wa_has_key", return_value=True):
            r = self.client.post("/api/v1/crm/whatsapp/bulk",
                                 {"org": self.org.id, "text": "update"},
                                 format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertNotIn("queued", r.data["counts"])
        self.assertEqual(r.data["counts"].get("draft"), 1)
        self.assertFalse(r.data["live_send"])
        self.assertTrue(all(x["state"] != "queued" for x in r.data["results"]))
