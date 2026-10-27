"""plans-v2 (owner order 27 Oct): EVERY gate, per plan (free / premium /
business / founder / trial / expired trial), owner-vs-staff, limit edges
(19 / 20 / 21), over-limit existing data readable + editable, flag OFF =
today's behaviour, credit charging for AI calls (credit-leak fixes), the
trial once-only, no auto-charge, and the Owner Admin config block."""
from datetime import timedelta
from unittest import mock

from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import ai, billing, plans
from core import entitlements_service as ES
from core import feature_flags as FF
from core.logic import entitlements as E
from core.logic import pricing as P
from core.models import (BusinessProfile, BusinessStaff, CreditLedger, FeatureFlag,
                         PaymentOrder, User)
from crm import pipeline as pl
from crm.models import (AutomationRule, Contact, CrmMember, CrmOrg, Deal, Lead)

_n = [0]


def _phone():
    _n[0] += 1
    return "0171%07d" % (5500000 + _n[0])


def flag(key="plans_v2", on=True):
    FF.ensure_seeded()
    FeatureFlag.objects.filter(key=key).update(enabled_all=on, enabled_play=on)
    FF.invalidate()


def set_cfg(**kw):
    row = billing.get_config()
    d = dict(row.data or {})
    pv = dict(d.get("plans_v2") or {})
    pv.update(kw)
    d["plans_v2"] = pv
    row.data = d
    row.save()


def user(plan="free", days=30, trial=None, founder=False, credits=0):
    u = User.objects.create_user(name="U%d" % _n[0], phone=_phone(), password="x")
    now = timezone.now()
    if plan != "free":
        u.plan = plan
        u.plan_until = now + timedelta(days=days)
    if trial is not None:   # +days = running, -days = expired
        u.trial_until = now + timedelta(days=trial)
    if founder:
        u.is_founder = True
    u.ai_credits = credits
    u.save()
    return u


def client(u, **headers):
    c = APIClient(**headers)
    c.force_authenticate(u)
    return c


def ai_on(tc, text="AI ok"):
    orig_p, orig_c, orig_k = ai._providers, ai._call_anthropic, ai.active_api_key
    ai._providers = lambda: [("anthropic", "k")]
    ai._call_anthropic = lambda key, model, system, prompt, mx, history=None: (text, 5, 5)
    ai.active_api_key = lambda: "k"
    tc.addCleanup(lambda: setattr(ai, "_providers", orig_p))
    tc.addCleanup(lambda: setattr(ai, "_call_anthropic", orig_c))
    tc.addCleanup(lambda: setattr(ai, "active_api_key", orig_k))


class _V2(TestCase):
    def setUp(self):
        flag(on=True)
        self.addCleanup(FF.invalidate)


# ====================================================================== pure
class PureTests(TestCase):
    def test_defaults_match_the_owner_matrix(self):
        c = E.normalize({})
        m = E.matrix(c)
        self.assertEqual((m["free"]["crm_contacts"], m["premium"]["crm_contacts"],
                          m["business"]["crm_contacts"]), (20, 500, 50000))
        self.assertTrue(m["business"]["crm_unlimited"])
        self.assertFalse(m["premium"]["crm_unlimited"])
        for cap in ("crm_write", "crm_followup_reminders", "automation", "ai_sales_agent",
                    "booking_bot", "reports"):
            self.assertFalse(m["free"][cap], cap)
            self.assertTrue(m["business"][cap], cap)
        self.assertTrue(m["premium"]["crm_write"] and m["premium"]["crm_followup_reminders"])
        for cap in ("automation", "ai_sales_agent", "booking_bot", "reports"):
            self.assertFalse(m["premium"][cap], cap)
        self.assertEqual((c["trial_days"], c["trial_plan"]), (7, "business"))
        # only built features: no team / marketing capability exists
        self.assertNotIn("team_members", E.CAPS)
        self.assertNotIn("marketing", E.CAPS)

    def test_normalize_is_bounded(self):
        c = E.normalize({"trial_days": 999, "trial_plan": "gold",
                         "business_crm_contacts": 10 ** 9, "free_crm_contacts": -5,
                         "free_automation": "on"})
        self.assertEqual(c["trial_days"], 30)
        self.assertEqual(c["trial_plan"], "business")
        self.assertEqual(c["business_crm_contacts"], 1000000)
        self.assertEqual(c["free_crm_contacts"], 0)
        self.assertTrue(c["free_automation"])
        self.assertEqual(E.problems({"trial_plan": "gold"}), ["bad_plans_v2"])
        self.assertEqual(E.problems({"business_crm_contacts": 0}), ["bad_plans_v2"])
        self.assertEqual(E.problems({"premium_crm_contacts": 800, "trial_days": 7}), [])

    def test_tiers(self):
        c = E.normalize({})
        self.assertEqual(E.tier_for("founder", True, False, c), "business")
        self.assertEqual(E.tier_for("annual", True, False, c), "premium")
        self.assertEqual(E.tier_for("premium", True, True, c), "business")   # trial raises
        self.assertEqual(E.tier_for("business", True, True,
                                    E.normalize({"trial_plan": "premium"})), "business")  # never lowers
        self.assertEqual(E.tier_for("premium", False, False, c), "free")
        self.assertEqual(E.needed_plan("crm_write", c), "premium")
        self.assertEqual(E.needed_plan("automation", c), "business")
        self.assertEqual(E.needed_for_contacts(20, c), "premium")
        self.assertEqual(E.needed_for_contacts(500, c), "business")
        self.assertEqual(E.needed_for_contacts(3, c, "business"), None)   # at the cap

    def test_upgrade_body_is_structured_and_bilingual(self):
        b = E.upgrade_body("crm_contacts", "premium", "free", "bn", limit=20, used=20)
        self.assertEqual((b["error"], b["needed_plan"], b["feature"], b["limit"], b["used"]),
                         ("upgrade_required", "premium", "crm_contacts", 20, 20))
        self.assertIn("২০", b["message"]["bn"])
        self.assertIn("20", b["message"]["en"])
        self.assertEqual(b["detail"], b["message"]["bn"])

    def test_pricing_config_carries_the_block(self):
        cfg = P.normalize({})
        self.assertEqual(cfg["plans_v2"]["free_crm_contacts"], 20)
        self.assertIn("bad_plans_v2", P.validate_edit({"plans_v2": {"trial_days": 99}}))


# ================================================================ tiers / trial
class TierTests(_V2):
    def test_each_plan(self):
        self.assertEqual(ES.tier(user("free")), "free")
        self.assertEqual(ES.tier(user("premium")), "premium")
        self.assertEqual(ES.tier(user("annual")), "premium")
        self.assertEqual(ES.tier(user("business")), "business")
        self.assertEqual(ES.tier(user(founder=True)), "business")        # lifetime founder
        self.assertEqual(ES.tier(user(trial=5)), "business")             # v2 trial
        self.assertEqual(ES.tier(user(trial=-1)), "free")                # expired trial
        self.assertEqual(ES.tier(user("premium", days=-1)), "free")      # lapsed plan

    def test_flag_off_trial_stays_premium_and_3_days(self):
        flag(on=False)
        u = user()
        self.assertFalse(ES.on(u))
        self.assertEqual(plans.trial_days(u), 3)
        self.assertEqual(plans.trial_plan(u), "premium")
        r = client(u).post("/api/v1/plans/trial/start")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["days"], 3)
        self.assertEqual(plans.effective_plan(u), "premium")

    def test_v2_trial_is_7_day_business_once_no_card(self):
        u = user()
        c = client(u)
        me = c.get("/api/v1/me/plan").json()
        self.assertTrue(me["trial_available"])
        self.assertEqual((me["trial_days"], me["trial_plan"], me["plans_v2"]), (7, "business", True))
        r = c.post("/api/v1/plans/trial/start")
        self.assertEqual(r.status_code, 200, r.content)
        j = r.json()
        self.assertEqual((j["days"], j["trial_plan"]), (7, "business"))
        u.refresh_from_db()
        left = u.trial_until - timezone.now()
        self.assertTrue(timedelta(days=6, hours=23) < left <= timedelta(days=7))
        self.assertEqual(ES.tier(u), "business")
        v = c.get("/api/v1/plans/v2").json()
        self.assertEqual(v["tier"], "business")
        self.assertTrue(v["trial_active"])
        self.assertTrue(v["trial_until"])          # the clear end date
        self.assertTrue(v["caps"]["automation"])
        # once per account
        r = c.post("/api/v1/plans/trial/start")
        self.assertEqual((r.status_code, r.json()["reason"]), (409, "trial_used"))

    def test_used_old_trial_gets_no_second_one(self):
        u = user(trial=-10)            # used the old 3-day Premium trial
        self.assertFalse(plans.trial_available(u))
        r = client(u).post("/api/v1/plans/trial/start")
        self.assertEqual(r.status_code, 409)

    def test_trial_end_returns_to_free_and_never_charges(self):
        u = user(credits=0)
        client(u).post("/api/v1/plans/trial/start")
        u.refresh_from_db()
        granted = u.ai_credits
        # the clock passes the end date
        User.objects.filter(pk=u.pk).update(trial_until=timezone.now() - timedelta(minutes=1))
        u.refresh_from_db()
        self.assertEqual(ES.tier(u), "free")
        self.assertEqual(plans.effective_plan(u), "free")
        client(u).get("/api/v1/me/plan")
        client(u).get("/api/v1/plans/v2")
        self.assertFalse(PaymentOrder.objects.filter(user=u).exists())   # nothing billed
        self.assertFalse(CreditLedger.objects.filter(user=u, delta__lt=0).exists())
        u.refresh_from_db()
        self.assertEqual(u.plan_until, None)
        self.assertEqual(u.ai_credits, granted)


# ===================================================================== CRM
class _Crm(_V2):
    def org_for(self, owner, name="Shop CRM"):
        org = CrmOrg.objects.create(name=name, owner=owner)
        CrmMember.objects.create(org=org, user=owner, role=CrmMember.OWNER)
        pl.ensure_default_pipeline(org)
        return org

    def contacts(self, org, n):
        Contact.objects.bulk_create([Contact(org=org, name="C%d" % i) for i in range(n)])

    def add_contact(self, c, org, name="New"):
        return c.post("/api/v1/crm/contacts/", {"org": org.id, "name": name}, format="json")

    def assert_upgrade(self, r, feature, needed):
        self.assertEqual(r.status_code, 402, getattr(r, "content", b"")[:400])
        j = r.json()
        self.assertEqual((j["error"], j["feature"], j["needed_plan"]),
                         ("upgrade_required", feature, needed))
        self.assertTrue(j["message"]["bn"] and j["message"]["en"])
        return j


class CrmFreeTests(_Crm):
    def setUp(self):
        super().setUp()
        self.u = user("free")
        self.org = self.org_for(self.u)
        self.c = client(self.u)

    def test_contact_limit_edges_19_20_21(self):
        self.contacts(self.org, 18)
        self.assertEqual(self.add_contact(self.c, self.org).status_code, 201)   # 19th
        self.assertEqual(self.add_contact(self.c, self.org).status_code, 201)   # 20th
        j = self.assert_upgrade(self.add_contact(self.c, self.org), "crm_contacts", "premium")
        self.assertEqual((j["limit"], j["used"]), (20, 20))                     # 21st refused
        self.assertEqual(Contact.objects.filter(org=self.org).count(), 20)
        v = self.c.get("/api/v1/plans/v2?org=%d" % self.org.id).json()
        self.assertEqual(v["crm"]["contacts"], {"used": 20, "limit": 20, "unlimited": False,
                                                "can_add": False, "over": False})

    def test_view_only_leads_deals_pipeline_tasks(self):
        self.assert_upgrade(self.c.post("/api/v1/crm/leads/", {"org": self.org.id, "name": "L"},
                                        format="json"), "crm_write", "premium")
        pipe = self.org.pipelines.first()
        st = pipe.stages.first()
        self.assert_upgrade(self.c.post("/api/v1/crm/deals/", {
            "org": self.org.id, "title": "D", "pipeline": pipe.id, "stage": st.id},
            format="json"), "crm_write", "premium")
        self.assert_upgrade(self.c.post("/api/v1/crm/pipelines/", {
            "org": self.org.id, "name": "P2"}, format="json"), "crm_write", "premium")
        self.assert_upgrade(self.c.post("/api/v1/crm/stages/", {
            "pipeline": pipe.id, "name": "S", "order": 9}, format="json"), "crm_write", "premium")
        self.assert_upgrade(self.c.post("/api/v1/crm/activities/", {
            "org": self.org.id, "kind": "task", "subject": "Call"}, format="json"),
            "crm_write", "premium")
        # reads always work
        for path in ("leads", "deals", "pipelines", "activities", "contacts"):
            self.assertEqual(self.c.get("/api/v1/crm/%s/?org=%d" % (path, self.org.id)).status_code,
                             200, path)
        self.assertEqual(self.c.get("/api/v1/crm/today?org=%d" % self.org.id).status_code, 200)

    def test_no_followup_reminders_no_automation(self):
        lead = Lead.objects.create(org=self.org, name="Old lead")
        self.assert_upgrade(self.c.get("/api/v1/crm/leads/%d/followup/" % lead.id),
                            "crm_followup_reminders", "premium")
        self.assert_upgrade(self.c.patch("/api/v1/crm/leads/%d/" % lead.id,
                                         {"next_follow_up": "2026-11-05"}, format="json"),
                            "crm_followup_reminders", "premium")
        deal = Deal.objects.create(org=self.org, title="Old", pipeline=self.org.pipelines.first(),
                                   stage=self.org.pipelines.first().stages.first())
        self.assert_upgrade(self.c.post("/api/v1/crm/deals/%d/set_next_step/" % deal.id,
                                        {"next_step": "Call", "next_step_due": "2026-11-05"},
                                        format="json"), "crm_followup_reminders", "premium")
        self.assert_upgrade(self.c.post("/api/v1/crm/automation-rules/", {
            "org": self.org.id, "name": "R", "trigger": "lead_created", "action": {"kind": "notify"}},
            format="json"), "automation", "business")

    def test_existing_over_limit_data_stays_readable_and_editable(self):
        self.contacts(self.org, 25)                         # made before plans-v2
        lead = Lead.objects.create(org=self.org, name="Legacy", next_follow_up="2026-10-30")
        r = self.c.get("/api/v1/crm/contacts/?org=%d" % self.org.id)
        self.assertEqual(r.status_code, 200)
        rows = r.json()
        rows = rows.get("results", rows) if isinstance(rows, dict) else rows
        self.assertEqual(len(rows), 25)
        ct = Contact.objects.filter(org=self.org).first()
        r = self.c.patch("/api/v1/crm/contacts/%d/" % ct.id, {"title": "Owner"}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        # editing a legacy lead (re-sending its own follow-up date) works
        r = self.c.patch("/api/v1/crm/leads/%d/" % lead.id,
                         {"name": "Legacy 2", "next_follow_up": "2026-10-30"}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        # deleting works; adding is refused
        self.assertEqual(self.c.delete("/api/v1/crm/contacts/%d/" % ct.id).status_code, 204)
        self.assert_upgrade(self.add_contact(self.c, self.org), "crm_contacts", "premium")

    def test_second_org_is_not_a_way_around(self):
        self.contacts(self.org, 20)
        org2 = self.org_for(self.u, "Second")
        self.assert_upgrade(self.add_contact(self.c, org2), "crm_contacts", "premium")


class CrmPremiumBusinessTests(_Crm):
    def test_premium_full_crm_500_no_automation(self):
        u = user("premium")
        org = self.org_for(u)
        c = client(u)
        r = c.post("/api/v1/crm/leads/", {"org": org.id, "name": "L",
                                          "next_follow_up": "2026-11-02"}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        lead = Lead.objects.get(pk=r.json()["id"])
        self.assertEqual(c.get("/api/v1/crm/leads/%d/followup/" % lead.id).status_code, 200)
        self.assertEqual(c.post("/api/v1/crm/activities/", {
            "org": org.id, "kind": "task", "subject": "Call"}, format="json").status_code, 201)
        self.assert_upgrade(c.post("/api/v1/crm/automation-rules/", {
            "org": org.id, "name": "R", "trigger": "lead_created", "action": {"kind": "notify"}},
            format="json"), "automation", "business")
        self.assert_upgrade(c.post("/api/v1/crm/whatsapp/bulk", {"org": org.id, "text": "hi"},
                                   format="json"), "automation", "business")
        # 500 edge (leads count too): 499 people -> one more ok, then refused
        self.contacts(org, 498)                       # 1 lead + 498 contacts = 499
        self.assertEqual(self.add_contact(c, org).status_code, 201)        # 500th
        j = self.assert_upgrade(self.add_contact(c, org), "crm_contacts", "business")
        self.assertEqual((j["limit"], j["used"]), (500, 500))
        self.assert_upgrade(c.post("/api/v1/crm/leads/", {"org": org.id, "name": "L2"},
                                   format="json"), "crm_contacts", "business")

    def test_business_and_founder_get_automation_and_unlimited_display(self):
        for u in (user("business"), user(founder=True), user(trial=3)):
            org = self.org_for(u)
            c = client(u)
            r = c.post("/api/v1/crm/automation-rules/", {
                "org": org.id, "name": "R", "trigger": "lead_created", "action": {"kind": "notify"}},
                format="json")
            self.assertEqual(r.status_code, 201, r.content)
            v = c.get("/api/v1/plans/v2?org=%d" % org.id).json()
            self.assertTrue(v["crm"]["contacts"]["unlimited"])
            self.assertEqual(v["crm"]["contacts"]["limit"], 50000)   # hidden safety cap

    def test_business_hidden_cap_is_enforced(self):
        set_cfg(business_crm_contacts=3)
        u = user("business")
        org = self.org_for(u)
        self.contacts(org, 3)
        self.assert_upgrade(self.add_contact(client(u), org), "crm_contacts", "business")

    def test_expired_trial_is_free(self):
        u = user(trial=-1)
        org = self.org_for(u)
        self.assert_upgrade(client(u).post("/api/v1/crm/leads/", {"org": org.id, "name": "L"},
                                           format="json"), "crm_write", "premium")

    def test_owner_plan_counts_not_the_staff_members(self):
        free_owner, rich_staff = user("free"), user("business")
        org = self.org_for(free_owner)
        CrmMember.objects.create(org=org, user=rich_staff, role=CrmMember.SALES)
        self.assert_upgrade(client(rich_staff).post("/api/v1/crm/leads/", {
            "org": org.id, "name": "L"}, format="json"), "crm_write", "premium")
        biz_owner, free_staff = user("business"), user("free")
        org2 = self.org_for(biz_owner, "Rich")
        CrmMember.objects.create(org=org2, user=free_staff, role=CrmMember.MANAGER)
        r = client(free_staff).post("/api/v1/crm/automation-rules/", {
            "org": org2.id, "name": "R", "trigger": "lead_created", "action": {"kind": "notify"}},
            format="json")
        self.assertEqual(r.status_code, 201, r.content)
        v = client(free_staff).get("/api/v1/plans/v2?org=%d" % org2.id).json()
        self.assertEqual((v["tier"], v["crm"]["owner_tier"]), ("free", "business"))

    def test_owner_admin_edit_changes_the_limit(self):
        set_cfg(free_crm_contacts=2, free_crm_write=True)
        u = user("free")
        org = self.org_for(u)
        c = client(u)
        self.assertEqual(c.post("/api/v1/crm/leads/", {"org": org.id, "name": "A"},
                                format="json").status_code, 201)
        self.assertEqual(self.add_contact(c, org).status_code, 201)
        self.assert_upgrade(self.add_contact(c, org), "crm_contacts", "premium")


class CrmFlagOffTests(_Crm):
    def setUp(self):
        super().setUp()
        flag(on=False)

    def test_today_behaviour_nothing_gated(self):
        u = user("free")
        org = self.org_for(u)
        c = client(u)
        self.contacts(org, 30)
        self.assertEqual(self.add_contact(c, org).status_code, 201)
        r = c.post("/api/v1/crm/leads/", {"org": org.id, "name": "L",
                                          "next_follow_up": "2026-11-02"}, format="json")
        self.assertEqual(r.status_code, 201)
        self.assertEqual(c.post("/api/v1/crm/automation-rules/", {
            "org": org.id, "name": "R", "trigger": "lead_created", "action": {"kind": "notify"}},
            format="json").status_code, 201)
        self.assertFalse(c.get("/api/v1/plans/v2").json()["on"])


class WebCrmTests(_Crm):
    """The server-rendered web CRM (/crm/) follows the same rules."""

    def web(self, u):
        from django.test import Client
        c = Client()
        c.force_login(u)
        return c

    def test_free_web_crm(self):
        u = user("free")
        org = self.org_for(u)
        c = self.web(u)
        r = c.post("/crm/leads/new", {"name": "L"})
        self.assertEqual(r.status_code, 402)
        self.assertFalse(Lead.objects.filter(org=org).exists())
        self.assertEqual(c.post("/crm/contacts/new", {"name": "C"}).status_code, 302)
        self.contacts(org, 19)
        r = c.post("/crm/contacts/new", {"name": "C21"})
        self.assertEqual(r.status_code, 402)
        self.assertEqual(Contact.objects.filter(org=org).count(), 20)
        self.assertEqual(c.post("/crm/deals/new", {"title": "D"}).status_code, 402)
        r = c.post("/crm/activities/log", {"kind": "note", "body": "x"})
        self.assertEqual((r.status_code, r.json()["feature"]), (402, "crm_write"))
        self.assertEqual(c.get("/crm/contacts").status_code, 200)     # reads work

    def test_premium_web_crm_and_flag_off(self):
        u = user("premium")
        self.org_for(u)
        self.assertEqual(self.web(u).post("/crm/leads/new", {"name": "L"}).status_code, 302)
        flag(on=False)
        f = user("free")
        self.org_for(f)
        self.assertEqual(self.web(f).post("/crm/leads/new", {"name": "L"}).status_code, 302)


# ================================================================ shop / business
class _Shop(_V2):
    def shop(self, owner):
        return BusinessProfile.objects.create(user=owner, shop_name="Rupa")


class ShopGateTests(_Shop):
    def test_ledger_basic_is_free(self):
        u = user("free")
        self.shop(u)
        c = client(u)
        r = c.post("/api/v1/business/khata/parties", {"name": "Karim"},
                   format="json")
        self.assertIn(r.status_code, (200, 201), r.content)
        self.assertEqual(c.get("/api/v1/business/khata/parties").status_code, 200)
        self.assertEqual(c.get("/api/v1/business/reports?period=daily").status_code, 200)

    def test_free_owner_locked_out_of_paid_tools(self):
        u = user("free")
        self.shop(u)
        c = client(u)
        r = c.post("/api/v1/business/ai/voice-entry", {"text": "500 taka"}, format="json")
        self.assertEqual((r.status_code, r.json()["feature"]), (402, "ledger_ai_addons"))
        r = c.post("/api/v1/business/ai/bargain", {"product": 1, "offer": 10}, format="json")
        self.assertEqual((r.status_code, r.json()["feature"]), (402, "ai_sales_agent"))
        r = c.get("/api/v1/business/reports?period=weekly")
        self.assertEqual((r.status_code, r.json()["feature"]), (402, "reports"))
        r = c.get("/api/v1/business/reports/bank-loan")
        self.assertEqual((r.status_code, r.json()["needed_plan"]), (402, "business"))

    def test_premium_keeps_khata_ai_but_not_sales_agent_or_reports(self):
        u = user("premium")
        self.shop(u)
        c = client(u)
        self.assertNotEqual(c.post("/api/v1/business/ai/voice-entry", {"text": "500 taka"},
                                   format="json").status_code, 402)
        self.assertEqual(c.post("/api/v1/business/ai/disclose", {}, format="json").status_code, 402)
        self.assertEqual(c.get("/api/v1/business/reports?period=monthly").status_code, 402)

    def test_business_founder_trial_pass(self):
        for u in (user("business"), user(founder=True), user(trial=2)):
            self.shop(u)
            c = client(u)
            self.assertEqual(c.post("/api/v1/business/ai/disclose", {}, format="json").status_code,
                             200)
            self.assertEqual(c.get("/api/v1/business/reports?period=weekly").status_code, 200)

    def test_staff_follows_the_shop_owner(self):
        owner, staff = user("free"), user("business")
        prof = self.shop(owner)
        BusinessStaff.objects.create(business=prof, member=staff, role="staff")
        r = client(staff).post("/api/v1/business/ai/disclose", {"business": prof.id},
                               format="json")
        self.assertEqual(r.status_code, 402)
        owner2, staff2 = user("business"), user("free")
        prof2 = self.shop(owner2)
        BusinessStaff.objects.create(business=prof2, member=staff2, role="staff")
        r = client(staff2).post("/api/v1/business/ai/disclose", {"business": prof2.id},
                                format="json")
        self.assertEqual(r.status_code, 200)

    def test_flag_off_keeps_the_old_rules(self):
        flag(on=False)
        prem = user("premium")
        self.shop(prem)
        self.assertEqual(client(prem).post("/api/v1/business/ai/disclose", {},
                                           format="json").status_code, 200)
        free = user("free")
        self.shop(free)
        c = client(free)
        r = c.post("/api/v1/business/ai/disclose", {}, format="json")
        self.assertEqual((r.status_code, r.json()["plan_required"]), (402, "business"))
        self.assertEqual(c.get("/api/v1/business/reports?period=weekly").status_code, 200)


class RetentionBookingAgentTests(_Shop):
    def test_retention_needs_business_but_stays_readable(self):
        flag("retention_auto", True)
        u = user("premium")
        self.shop(u)
        c = client(u)
        r = c.post("/api/v1/retention/automations", {"kind": "winback"}, format="json")
        self.assertEqual((r.status_code, r.json()["feature"]), (402, "automation"))
        self.assertEqual(c.get("/api/v1/retention").status_code, 200)       # readable
        t = user(trial=4)
        self.shop(t)
        r = client(t).post("/api/v1/retention/automations", {"kind": "winback"}, format="json")
        self.assertNotEqual(r.status_code, 402)

    def test_booking_live_business_founder_trial(self):
        flag("booking_bot", True)
        for u, ok in ((user("free"), False), (user("premium"), False),
                      (user(founder=True), True), (user(trial=3), True)):
            self.shop(u)
            r = client(u).put("/api/v1/booking/biz", {"enabled": True}, format="json")
            if ok:
                self.assertEqual(r.status_code, 409, r.data)       # plan ok -> not_ready
            else:
                self.assertEqual((r.status_code, r.data["feature"]), (402, "booking_bot"))

    def test_ai_sales_agent_needs_business(self):
        from core import bizagent_service as S
        u = user("premium")
        prof = self.shop(u)
        r = client(u).post("/api/v1/bizagent/channels", {"kind": "messenger",
                                                          "external_id": "123", "token": "t"},
                           format="json")
        self.assertEqual((r.status_code, r.json()["feature"]), (402, "ai_sales_agent"))
        a = S.agent_for(prof)
        self.assertEqual(S.consume_reply(a), (None, "plan_required"))
        st = client(u).get("/api/v1/bizagent/setup").json()
        self.assertEqual(st["plans_v2"], {"on": True, "allowed": False, "needed_plan": "business"})


# ============================================================ credit-leak fixes
class CreditChargeTests(TestCase):
    """Regardless of the flag: every AI call is charged through billing."""

    def setUp(self):
        ai_on(self)

    def test_business_ai_reply_charges_the_shop_owner(self):
        u = user("business", credits=0)
        BusinessProfile.objects.create(user=u, shop_name="Rupa")
        billing.ensure_monthly_pool(u)
        u.refresh_from_db()
        before = u.ai_credits
        self.assertGreater(before, 0)
        r = client(u).post("/api/v1/business/ai/reply", {"text": "দাম কত?"}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        u.refresh_from_db()
        self.assertLess(u.ai_credits, before)
        self.assertTrue(CreditLedger.objects.filter(user=u, reason="consume",
                                                    note="business.ai_reply").exists())

    def test_business_ai_reply_out_of_credits(self):
        u = user("business", days=30)
        BusinessProfile.objects.create(user=u, shop_name="Rupa")
        billing.ensure_monthly_pool(u)
        User.objects.filter(pk=u.pk).update(ai_credits=0)
        r = client(u, HTTP_X_ASSISTO_CREDOUT="1").post("/api/v1/business/ai/reply",
                                                       {"text": "দাম কত?"}, format="json")
        self.assertEqual((r.status_code, r.json()["code"]), (402, "out_of_credits"))
        r = client(u).post("/api/v1/business/ai/reply", {"text": "দাম কত?"}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()["credits_out"])
        self.assertTrue(r.json()["mock"])            # honest draft, never fake AI

    def test_crm_ai_calls_charge_the_org_owner(self):
        from crm import logic
        from crm.models import Conversation
        owner = user("free", credits=50)
        org = CrmOrg.objects.create(name="X", owner=owner)
        lead = Lead.objects.create(org=org, name="Buyer")
        conv = Conversation.objects.create(lead=lead)
        logic.add_message(conv, "in", "price please, we need ERP")
        owner.refresh_from_db()
        self.assertLess(owner.ai_credits, 50)
        notes = set(CreditLedger.objects.filter(user=owner, reason="consume")
                    .values_list("note", flat=True))
        self.assertTrue({"crm.sentiment", "crm.insight", "crm.scoring"} <= notes, notes)

    def test_crm_proposal_out_of_credits_is_credout(self):
        owner = user("free", credits=0)
        org = CrmOrg.objects.create(name="X", owner=owner)
        CrmMember.objects.create(org=org, user=owner, role=CrmMember.OWNER)
        lead = Lead.objects.create(org=org, name="Buyer")
        r = client(owner, HTTP_X_ASSISTO_CREDOUT="1").post(
            "/api/v1/crm/leads/%d/proposal/" % lead.id, {"requirements": "x"}, format="json")
        self.assertEqual((r.status_code, r.json()["code"]), (402, "out_of_credits"))
        r = client(owner).post("/api/v1/crm/leads/%d/proposal/" % lead.id,
                               {"requirements": "x"}, format="json")
        self.assertEqual((r.status_code, r.json()["reason"]), (200, "credits"))
        self.assertFalse(lead.proposals.exists())


# ================================================================ owner admin
class OwnerConfigTests(TestCase):
    def test_pricing_apply_saves_and_refuses_out_of_range(self):
        from core.views_build61 import pricing_apply
        ok, snap = pricing_apply(1, {"config": {"plans_v2": {"free_crm_contacts": 25,
                                                             "trial_days": 5}}})
        self.assertTrue(ok, snap)
        self.assertEqual(billing.cfg()["plans_v2"]["free_crm_contacts"], 25)
        self.assertEqual(billing.cfg()["plans_v2"]["trial_days"], 5)
        self.assertEqual(billing.cfg()["plans_v2"]["premium_crm_contacts"], 500)   # kept
        ok, bad = pricing_apply(1, {"config": {"plans_v2": {"trial_plan": "gold"}}})
        self.assertFalse(ok)
        self.assertIn("bad_plans_v2", bad["problems"])
