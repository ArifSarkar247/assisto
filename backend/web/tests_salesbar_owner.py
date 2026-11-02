"""salesbar: Owner Admin → Sellers → "Meta App Review and permissions" (the
owner ticks only what Meta really granted; the seller app and the comment /
human-agent paths follow it). Audited through OwnerAudit."""
from core import billing
from core.models import OwnerAudit
from web.tests_o2_owner_admin import OwnerBase


class MetaAccessPanelTests(OwnerBase):
    def test_defaults_shown_bn_en(self):
        self.ready()
        r = self.c.get("/owner/sellers?lang=en")
        self.assertContains(r, "Meta App Review and permissions")
        self.assertContains(r, "Not submitted")
        r = self.c.get("/owner/sellers?lang=bn")
        self.assertContains(r, "Meta App Review ও অনুমতি")
        ma = billing.cfg()["seller_agent"]["meta_access"]
        self.assertEqual(ma, {"review": "not_submitted", "comments_fb": False,
                              "comments_ig": False, "human_agent": False})

    def test_owner_ticks_granted_permissions_audited(self):
        self.ready()
        r = self.post("/owner/sellers", {"action": "meta", "review": "approved",
                                         "comments_fb": "on", "reason": "App Review passed"})
        self.assertEqual(r.status_code, 302)
        ma = billing.cfg()["seller_agent"]["meta_access"]
        self.assertEqual(ma["review"], "approved")
        self.assertTrue(ma["comments_fb"])
        self.assertFalse(ma["comments_ig"])
        self.assertFalse(ma["human_agent"])
        self.assertTrue(OwnerAudit.objects.filter(action="bizagent.config").exists())
        # plans / kill switches are untouched by this form
        sa = billing.cfg()["seller_agent"]
        self.assertEqual(sa["plans"]["pro"]["replies"], 2700)
        self.assertFalse(sa["ai_kill"])

    def test_bad_review_value_keeps_the_old_one(self):
        self.ready()
        self.post("/owner/sellers", {"action": "meta", "review": "submitted"})
        self.post("/owner/sellers", {"action": "meta", "review": "hacked"})
        self.assertEqual(billing.cfg()["seller_agent"]["meta_access"]["review"], "submitted")
