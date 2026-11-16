"""emailrel (16 Nov): Owner Admin -> Email health card — sent today,
failures, bounces, cap thresholds, masked addresses only, and "remove from
list" (audited). Made-up sample addresses."""
from core import email_sender
from core.models import EmailLog, EmailSuppression, OwnerAudit
from web.tests_o2_owner_admin import OwnerBase

DEAD = "nobody-xyz@example.com"


class EmailHealthPageTests(OwnerBase):
    def setUp(self):
        super().setUp()
        self.ready()
        h = email_sender.email_hash
        EmailLog.objects.create(purpose="otp", to_hash=h("a@example.com"), status="sent")
        EmailLog.objects.create(purpose="otp", to_hash=h(DEAD),
                                to_masked=email_sender.mask_email(DEAD),
                                status="failed", error_kind="bounce", detail="550 5.1.1")
        email_sender.suppress(DEAD, "hard_bounce", "550", "550 5.1.1 user unknown")

    def test_card_numbers_and_masks(self):
        html = self.c.get("/owner/email-health?lang=en").content.decode()
        self.assertIn('id="email-health"', html)
        self.assertIn('id="eh-sent">1<', html)
        self.assertIn('id="eh-failed">1<', html)
        self.assertIn('id="eh-bounces">1<', html)
        self.assertIn("Bad address (bounce)", html)
        self.assertIn(email_sender.mask_email(DEAD), html)
        self.assertNotIn(DEAD, html)
        self.assertIn("not connected", html)                 # honest: no SMTP entry here
        bn = self.c.get("/owner/email-health?lang=bn").content.decode()
        self.assertIn("ইমেইল স্বাস্থ্য", bn)
        self.assertIn('href="/owner/email-health"', bn)      # in the nav

    def test_remove_from_list_is_audited(self):
        row = EmailSuppression.objects.get()
        r = self.post("/owner/email-health", {"remove": str(row.pk)})
        self.assertEqual(r.status_code, 302)
        self.assertFalse(EmailSuppression.objects.exists())
        self.assertTrue(OwnerAudit.objects.filter(action="email.unsuppress").exists())
