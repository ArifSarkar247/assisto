"""sosfam-crm-proof (board row 15): STOP is final until the CUSTOMER says
otherwise. A STOP customer gets no CRM path (WhatsApp link, phone SMS,
Assisto SMS — refused with the STOP reason even before price / gateway
checks); the owner sees HOW and WHEN they stopped; the customer's own
re-consent (the same SMS link's "turn back on") opens the paths again."""
from unittest import mock

from rest_framework.test import APIClient

from core.logic import msg_guard as MG
from core.models import BizOptOut

from .models import CustomerMessage
from .tests_crm100 import A, _World

KEY = "01712345678"


@mock.patch("core.logic.msg_guard.in_quiet_hours", return_value=False)
class StopReasonAndReconsentTests(_World):
    def preview(self):
        r = self.client.post(A + "/send/preview", {"party": self.party.pk, "text": "hi"},
                             format="json")
        self.assertEqual(r.status_code, 200, r.data)
        return r.data

    def test_owner_sees_how_and_when(self, _q):
        self.assertNotIn("stop", self.preview())
        MG.record_opt_out(self.biz.pk, KEY, "sms_link")
        pv = self.preview()
        self.assertIs(pv["opted_out"], True)
        self.assertEqual(pv["stop"]["source"], "sms_link")
        self.assertTrue(pv["stop"]["at"])

    def test_assisto_sms_refused_with_the_stop_reason_first(self, _q):
        # no gateway, no credits — the owner still learns the REAL reason
        MG.record_opt_out(self.biz.pk, KEY, "chat")
        r = self.client.post(A + "/send/sms", {"party": self.party.pk, "text": "hello"},
                             format="json")
        self.assertEqual(r.status_code, 409, r.data)
        self.assertEqual(r.data.get("reason"), "opted_out")
        self.assertFalse(CustomerMessage.objects.exists())

    def test_customer_link_reconsent_opens_the_paths_again(self, _q):
        tok = MG.stop_token(self.biz.pk, KEY)
        c = APIClient()
        self.assertEqual(c.post("/api/v1/retention/u/" + tok).status_code, 200)
        self.assertEqual(self.preview()["wa_url"], "")
        page = c.get("/api/v1/retention/u/%s?lang=en" % tok).content.decode()
        self.assertIn("Turn messages back on", page)            # the customer's own way back
        self.assertIn('name="action" value="start"', page)
        on = c.post("/api/v1/retention/u/%s?lang=en" % tok, {"action": "start"})
        self.assertEqual(on.status_code, 200)
        self.assertIn("Messages are on again", on.content.decode())
        self.assertFalse(MG.is_opted_out(self.biz.pk, KEY))
        pv = self.preview()
        self.assertIs(pv["opted_out"], False)
        self.assertTrue(pv["wa_url"])
        # and STOP still works after that (consent is the customer's, both ways)
        self.assertEqual(c.post("/api/v1/retention/u/" + tok).status_code, 200)
        self.assertTrue(BizOptOut.objects.filter(business=self.biz, key=KEY).exists())
        self.assertIs(self.preview()["opted_out"], True)

    def test_owner_cannot_undo_a_stop(self, _q):
        MG.record_opt_out(self.biz.pk, KEY, "chat")
        r = self.client.delete(A.replace("/crm", "") + "/retention/opt-outs")
        self.assertIn(r.status_code, (403, 404, 405))
        self.assertTrue(MG.is_opted_out(self.biz.pk, KEY))
