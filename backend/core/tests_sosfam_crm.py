"""sosfam-crm-proof (board row 15): a customer's START after a STOP in a
WhatsApp chat must clear the shop-wide STOP too (it used to clear only the
chat flag, so CRM / SMS / automations stayed blocked forever)."""
from core.logic import msg_guard as MG
from core.logic.business_selling import normalize_phone
from core.models import BizOptOut, BookingContact, ChatThread
from core.tests_p1_bizagent import wapayload
from core.tests_salesbar import SB


class ChatReconsentTests(SB):
    def test_stop_then_start_in_whatsapp_reaches_the_shop_wide_list(self):
        self.post_wa(wapayload("STOP", "wamid.sf1"))
        t = self.thread(self.wa)
        key = normalize_phone(t.customer_phone)
        self.assertTrue(t.opted_out)
        self.assertTrue(BizOptOut.objects.filter(business=self.biz, key=key).exists())
        self.assertTrue(MG.is_opted_out(self.biz.pk, key))
        self.assertEqual(MG.opt_out_info(self.biz.pk, key)["source"], "chat")
        self.post_wa(wapayload("START", "wamid.sf2"))
        t.refresh_from_db()
        self.assertFalse(t.opted_out)
        self.assertFalse(BizOptOut.objects.filter(business=self.biz, key=key).exists())
        self.assertFalse(MG.is_opted_out(self.biz.pk, key))
        self.assertIsNone(MG.opt_out_info(self.biz.pk, key))

    def test_record_opt_in_clears_every_place_and_only_for_that_customer(self):
        MG.record_opt_out(self.biz.pk, "01711111111", "owner")
        MG.record_opt_out(self.biz.pk, "01822222222", "sms_link")
        BookingContact.objects.create(business=self.biz, phone="+8801711111111", stop=True)
        self.assertTrue(MG.record_opt_in(self.biz.pk, "01711111111"))
        self.assertFalse(MG.is_opted_out(self.biz.pk, "01711111111"))
        self.assertTrue(MG.is_opted_out(self.biz.pk, "01822222222"))      # others untouched
        self.assertFalse(BookingContact.objects.get(business=self.biz).stop)
        self.assertFalse(MG.record_opt_in(self.biz.pk, "01711111111"))    # idempotent
        self.assertFalse(MG.record_opt_in(self.biz.pk, ""))
        self.assertFalse(ChatThread.objects.filter(business=self.biz, opted_out=True).exists())
