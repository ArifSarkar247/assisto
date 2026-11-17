"""gap-bizai P0 (17 Nov): a customer who said STOP to a shop gets NO path
from the CRM — not Assisto SMS and not the seller's own WhatsApp / phone SMS
(the free paths used to stay one tap away). Bulk leaves them out with the
reason, and a send can never be logged for them."""
from unittest import mock

from core.logic import msg_guard as MG
from core.models import KhataParty

from .models import CustomerMessage
from .tests_crm100 import A, _World


@mock.patch("core.logic.msg_guard.in_quiet_hours", return_value=False)
class StopRespectedEverywhereTests(_World):
    def test_preview_offers_no_path_to_a_stop_customer(self, _q):
        ok = self.client.post(A + "/send/preview", {"party": self.party.pk, "text": "hi"},
                              format="json").data
        self.assertTrue(ok["wa_url"])
        self.assertIs(ok["opted_out"], False)
        MG.record_opt_out(self.biz.pk, "01712345678")
        r = self.client.post(A + "/send/preview", {"party": self.party.pk, "text": "hi"},
                             format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertIs(r.data["opted_out"], True)
        self.assertEqual((r.data["wa_url"], r.data["sms_uri"]), ("", ""))
        self.assertFalse(r.data["sms"]["available"])         # no Assisto SMS either

    def test_send_log_refused_for_a_stop_customer(self, _q):
        MG.record_opt_out(self.biz.pk, "01712345678")
        r = self.client.post(A + "/send/log", {"party": self.party.pk,
                                               "channel": "whatsapp_link", "text": "hi"},
                             format="json")
        self.assertEqual(r.status_code, 409)
        self.assertFalse(CustomerMessage.objects.exists())

    def test_bulk_leaves_stop_customers_out_with_the_reason(self, _q):
        p2 = KhataParty.objects.create(business=self.biz, book="customer", name="Rahela",
                                       phone="01811111111")
        MG.record_opt_out(self.biz.pk, "01712345678")      # Karim said STOP
        r = self.client.post(A + "/send/bulk", {
            "targets": [{"party": self.party.pk}, {"party": p2.pk}],
            "text": "{name}, new stock"}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual([c["name"] for c in r.data["cards"]], ["Rahela"])
        self.assertEqual(r.data["opted_out"], 1)
        self.assertEqual([s["reason"] for s in r.data["skipped"]], ["opted_out"])
        self.assertNotIn("01712345678", str(r.data["cards"]))
