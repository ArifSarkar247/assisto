"""mktengine — Marketing Engine v1 (owner P3-D, flag marketing_engine).

Pure: questionnaire validation, Bangladesh calendar (lunar dates always
estimated, fixed civic dates exact, solemn days never sold on), plan built
only from real numbers, AI number guard, regenerate keeps approvals,
follow-up templates valid for retention.
API: flag off / owner-only, questionnaire -> plan with the REAL sales and
prices, approve / edit, AI polish (no key, number guard, ok), follow-up ->
retention automation -> the retention cron REALLY sends it (STOP honoured),
publish refused honestly until Meta approves, then posts via Graph.
"""
from datetime import date, timedelta
from decimal import Decimal
from unittest import mock

from django.test import SimpleTestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import ai
from core import mktengine_service as MS
from core import retention_service as RS
from core.logic import mktengine as M
from core.logic import msg_guard as MG
from core.logic import retention as R
from core.models import (BizOptOut, FeatureFlag, PaCollectionItem, Product, RetentionAutomation,
                         RetentionSend, SaleLine, User)
from core.tests_retention import _Base

ANSWERS = {
    "business_type": "grocery", "area": "Mirpur 10, Dhaka", "delivery": "city",
    "customers": ["families", "office"], "price_level": "mid", "goals": ["more_sales", "repeat"],
    "budget": "2k_5k", "channels": ["facebook", "whatsapp", "in_store"], "tone": "friendly",
    "offers": ["free_delivery"], "usp": "১০ বছরের পুরোনো দোকান",
}
LUNAR = {"ramadan", "eid_fitr", "eid_adha", "durga_puja"}


def _facts(**kw):
    f = {"shop": "Rina Store", "top_products": [], "slow_movers": [], "catalog": [],
         "catalog_priced": 0, "newest": {}, "sales_90d_count": 0, "sales_90d_total": 0,
         "customers_90d": 0, "repeat_customers": 0, "leads_total": 0, "leads_new_30d": 0,
         "leads_won": 0, "open_quotes": 0}
    f.update(kw)
    return f


# ============================================================ pure
class QuestionnaireTests(SimpleTestCase):
    def test_ten_steps_bangla_first(self):
        self.assertEqual(M.N_STEPS, 11)
        qs = M.questions_for("bn")
        self.assertGreaterEqual(len(qs), 10)
        self.assertEqual(qs[0]["label"], "আপনার ব্যবসা কী ধরনের?")
        self.assertEqual(M.questions_for("en")[0]["label"], "What kind of business is it?")

    def test_validate(self):
        clean, probs = M.validate_answers(ANSWERS)
        self.assertEqual(probs, [])
        self.assertTrue(M.is_complete(clean))
        _, probs = M.validate_answers({"business_type": "casino"})
        self.assertIn("bad_business_type", probs)
        self.assertIn("missing_area", probs)
        clean, probs = M.validate_answers(dict(ANSWERS, offers=["none", "gift"]))
        self.assertEqual(clean["offers"], ["gift"])
        clean, probs = M.validate_answers({"area": "  Uttara  "}, partial=True)
        self.assertEqual((clean, probs), ({"area": "Uttara"}, []))


class CalendarTests(SimpleTestCase):
    def test_fixed_dates_exact(self):
        ev = M.events_between(date(2026, 11, 3), date(2026, 12, 31), "bn")
        by = {e["key"]: e for e in ev}
        self.assertEqual(by["1111"]["date"], "2026-11-11")
        self.assertEqual(by["black_friday"]["date"], "2026-11-27")   # day after 4th Thu
        self.assertEqual(by["victory"]["date"], "2026-12-16")
        self.assertFalse(by["victory"]["estimated"])

    def test_lunar_always_estimated(self):
        ev = M.events_between(date(2026, 1, 1), date(2028, 12, 31), "bn")
        lunar = [e for e in ev if e["key"] in LUNAR]
        self.assertTrue(lunar)
        for e in lunar:
            self.assertTrue(e["estimated"], e)
            self.assertIn("আনুমানিক", e["note"])
        for e in ev:
            if e["key"] not in LUNAR:
                self.assertFalse(e["estimated"], e)
        # lunar keys never sit in the fixed table
        self.assertFalse(LUNAR & {k for _, _, k, _, _ in M.FIXED_DATES})

    def test_ekushe_is_tribute_not_sale(self):
        it = M.calendar_item(ANSWERS, _facts(), "bn", date(2027, 2, 1))
        ek = [r for r in it["entries"] if "২১ ফেব্রুয়ারি" in r["title"]]
        self.assertEqual(len(ek), 1)                  # no lead-in offer post
        self.assertIn("বিক্রির কথা নয়", ek[0]["title"])

    def test_thirty_days_and_estimated_marked(self):
        it = M.calendar_item(ANSWERS, _facts(), "bn", date(2027, 3, 1))
        self.assertEqual(it["end"], "2027-03-30")
        eid = [r for r in it["entries"] if "ঈদুল ফিতর" in r["title"]]
        self.assertTrue(eid and all(r["estimated"] for r in eid))
        self.assertIn("(আনুমানিক)", it["body"])
        for r in it["entries"]:
            self.assertTrue("2027-03-01" <= r["date"] <= "2027-03-30")


class PlanTests(SimpleTestCase):
    FACTS = _facts(
        top_products=[{"name": "মিনিকেট চাল ৫ কেজি", "qty": 12, "revenue": 4200.0, "price": 350.0,
                       "description": ""}],
        slow_movers=[{"name": "সরিষার তেল ১ লিটার", "stock": 9, "price": 245.0}],
        catalog=[{"name": "মিনিকেট চাল ৫ কেজি", "price": 350.0, "description": ""}],
        catalog_priced=2, sales_90d_count=30, sales_90d_total=9000.0, customers_90d=14,
        repeat_customers=5, leads_total=3)

    def test_sections_and_real_prices(self):
        plan = M.build_plan(ANSWERS, self.FACTS, "bn", date(2026, 11, 3))
        secs = {i["section"] for i in plan["items"]}
        self.assertEqual(secs, set(M.SECTIONS))
        post = next(i for i in plan["items"] if i["id"] == "post1")
        self.assertIn("৳৩৫০", post["body"])                   # real catalog price, Bangla digits
        self.assertIn("সবচেয়ে বেশি চলা", post["body"])        # qty 12 >= 3: honest best-seller
        self.assertIn("top_products", post["uses"])
        poster = next(i for i in plan["items"] if i["kind"] == "poster")
        self.assertIn("৳২৪৫", poster["body"])                 # slow mover moves first
        ads = next(i for i in plan["items"] if i["kind"] == "ads")
        self.assertTrue(ads["estimate"])
        self.assertIn("অনুমান", ads["body"])
        self.assertIn("%", ads["body"])
        self.assertNotIn("%%", ads["body"])
        kinds = [i["followup_kind"] for i in plan["items"] if i["kind"] == "followup"]
        self.assertEqual(kinds[0], "reorder")                  # goal "repeat" puts it first
        self.assertNotIn("quote_followup", kinds)              # no open quotes -> not offered
        labels = {f["key"]: f["value"] for f in plan["facts"]}
        self.assertIn("১২", labels["top_products"])
        self.assertIn("৫", labels["repeat_customers"])

    def test_no_invented_claims_without_data(self):
        plan = M.build_plan(ANSWERS, _facts(), "en", date(2026, 11, 3))
        text = "\n".join(i["body"] for i in plan["items"])
        self.assertNotIn("most-bought", text)
        post = next(i for i in plan["items"] if i["id"] == "post1")
        self.assertIn("needs", post)
        self.assertFalse(any(i["kind"] == "offer" for i in plan["items"]))   # no slow movers
        self.assertFalse(any(i["kind"] == "script" for i in plan["items"]))  # no product
        for w in ("testimonial", "5-star", "1000+", "guaranteed"):
            self.assertNotIn(w, text)

    def test_followup_templates_valid_for_retention(self):
        for k in M.FOLLOWUP_KINDS:
            for tone in ("friendly", "premium", "fun", "trust"):
                bn, en = M.followup_template(k, tone)
                self.assertEqual(R.template_problems(k, bn), [], (k, tone))
                self.assertEqual(R.template_problems(k, en), [], (k, tone))

    def test_numbers_guard(self):
        orig = "চাল ৫ কেজি — ৳৩৫০\nফ্রি ডেলিভারি"
        self.assertTrue(M.numbers_ok(orig, "দারুণ চাল (৫ কেজি) মাত্র ৳350!"))
        self.assertFalse(M.numbers_ok(orig, "চাল ৫ কেজি — ৳৩০০"))
        self.assertFalse(M.numbers_ok(orig, "৫০০+ গ্রাহকের পছন্দ! চাল ৳৩৫০"))
        self.assertEqual(M.numbers_in("৳১,২৫০ and 3"), {"1250", "3"})

    def test_regenerate_keeps_approved_and_edited(self):
        old = [{"id": "post1", "status": "approved", "body": "A"},
               {"id": "post2", "status": "draft", "body": "B", "edited": True},
               {"id": "hooks", "status": "draft", "body": "C"}]
        new = [{"id": "post1", "body": "A2"}, {"id": "post2", "body": "B2"}, {"id": "hooks", "body": "C2"}]
        out = M.merge_regenerated(old, new)
        self.assertEqual([i["body"] for i in out], ["A", "B", "C2"])

    def test_apply_edit(self):
        it = {"id": "x", "body": "a", "status": "draft"}
        it, p = M.apply_edit(it, {"status": "approved", "body": "b"})
        self.assertEqual((p, it["status"], it["body"], it["edited"]), ([], "approved", "b", True))
        _, p = M.apply_edit(it, {"status": "yes"})
        self.assertEqual(p, ["bad_status"])
        _, p = M.apply_edit(it, {"body": "  "})
        self.assertEqual(p, ["empty"])


# ============================================================ API
def _mkt_on(on=True):
    from core import feature_flags as FF
    FF.ensure_seeded()
    FeatureFlag.objects.filter(key="marketing_engine").update(enabled_all=on, enabled_play=on)
    FF.invalidate()


class ApiTests(_Base):
    def setUp(self):
        super().setUp()
        _mkt_on()
        self.rice = Product.objects.create(user=self.owner, business=self.biz, name="মিনিকেট চাল ৫ কেজি",
                                           price=Decimal("350"), stock=20)
        self.oil = Product.objects.create(user=self.owner, business=self.biz, name="সরিষার তেল ১ লিটার",
                                          price=Decimal("245"), stock=9)
        self.now = MG.local(timezone.now()).replace(hour=11, minute=30, second=0, microsecond=0)
        for d in (40, 20):
            s = self.sale(self.cust, self.now - timedelta(days=d), total=35000)
            SaleLine.objects.create(sale=s, product=self.rice, product_name=self.rice.name,
                                    qty=2, unit_price=35000)

    def put_answers(self):
        r = self.oc.put("/api/v1/mkt/profile", {"answers": ANSWERS}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        return r

    def test_flag_off_and_owner_only(self):
        _mkt_on(False)
        r = self.oc.get("/api/v1/mkt")
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.data["error"], "feature_off")
        _mkt_on(True)
        from core.models import BusinessStaff
        BusinessStaff.objects.create(business=self.biz, member=self.cust_user, role="staff", active=True)
        r = self.cc.get("/api/v1/mkt?business=%d" % self.biz.id)     # staff: refused
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.data["error"], "owner_only")

    def test_questionnaire_to_plan_with_real_numbers(self):
        r = self.oc.get("/api/v1/mkt", HTTP_ACCEPT_LANGUAGE="bn")
        self.assertEqual(r.status_code, 200)
        self.assertIsNone(r.data["plan"])
        self.assertFalse(r.data["complete"])
        self.assertEqual(r.data["publish"]["reason"], "meta_review_pending")
        # half-way draft save, then generate refuses honestly
        r = self.oc.put("/api/v1/mkt/profile", {"answers": {"area": "Mirpur"}, "partial": True},
                        format="json")
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.data["complete"])
        r = self.oc.post("/api/v1/mkt/generate")
        self.assertEqual(r.data["error"], "questionnaire_incomplete")
        self.put_answers()
        r = self.oc.post("/api/v1/mkt/generate")
        self.assertEqual(r.status_code, 200, r.content)
        plan = r.data["plan"]
        post = next(i for i in plan["items"] if i["id"] == "post1")
        self.assertIn(self.rice.name, post["body"])
        self.assertIn("৳৩৫০", post["body"])
        poster = next(i for i in plan["items"] if i["kind"] == "poster")
        self.assertIn(self.oil.name, poster["body"])        # in stock, unsold for 60 days
        facts = {f["key"]: f["value"] for f in plan["facts"]}
        self.assertIn("৪", facts["top_products"])           # 2 sales x qty 2 = 4
        self.assertIn("২", facts["sales_90d"])
        self.assertIn("১", facts["repeat_customers"])       # Karim bought twice
        self.assertEqual(PaCollectionItem.objects.filter(user=self.owner, collection="mkt_plan").count(), 1)

    def test_approve_edit_regenerate(self):
        self.put_answers()
        self.oc.post("/api/v1/mkt/generate")
        r = self.oc.patch("/api/v1/mkt/items/post1", {"status": "approved", "body": "আমার নিজের লেখা ৳৩৫০"},
                          format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["item"]["status"], "approved")
        self.assertEqual(self.oc.patch("/api/v1/mkt/items/nope", {"status": "approved"},
                                       format="json").status_code, 404)
        r = self.oc.post("/api/v1/mkt/generate")
        post = next(i for i in r.data["plan"]["items"] if i["id"] == "post1")
        self.assertEqual(post["body"], "আমার নিজের লেখা ৳৩৫০")

    def test_polish(self):
        self.put_answers()
        self.oc.post("/api/v1/mkt/generate")
        with mock.patch.object(ai, "generate", side_effect=ai.AIUnavailable("no_key")):
            r = self.oc.post("/api/v1/mkt/items/post1/polish")
        self.assertEqual((r.status_code, r.data["error"]), (503, "ai_no_key"))
        with mock.patch.object(ai, "generate", return_value=("৫০০+ গ্রাহকের পছন্দ! ৳৩৫০", 0.001)):
            r = self.oc.post("/api/v1/mkt/items/post1/polish")
        self.assertEqual(r.data["error"], "ai_changed_numbers")
        with mock.patch.object(ai, "generate", return_value=("দারুণ চাল, দাম ৳৩৫০", 0.001)) as g:
            r = self.oc.post("/api/v1/mkt/items/post1/polish")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertTrue(r.data["item"]["polished"])
        self.assertEqual(r.data["item"]["status"], "draft")
        self.assertEqual(g.call_args.kwargs["user"], self.owner)      # charged to the owner
        self.assertTrue(g.call_args.kwargs["pii"])
        r = self.oc.post("/api/v1/mkt/items/calendar/polish")
        self.assertEqual(r.data["error"], "not_polishable")

    def test_followup_really_sent_through_retention(self):
        self.put_answers()
        self.oc.post("/api/v1/mkt/generate")
        r = self.oc.post("/api/v1/mkt/items/fu_thanks_review/activate")
        self.assertEqual(r.data["error"], "approve_first")
        self.oc.patch("/api/v1/mkt/items/fu_thanks_review", {"status": "approved"}, format="json")
        # retention switch off -> honest refusal, nothing created
        from core import feature_flags as FF
        FeatureFlag.objects.filter(key="retention_auto").update(enabled_all=False, enabled_play=False)
        FF.invalidate()
        r = self.oc.post("/api/v1/mkt/items/fu_thanks_review/activate")
        self.assertEqual((r.status_code, r.data["error"]), (409, "retention_off"))
        self.assertFalse(RetentionAutomation.objects.exists())
        FeatureFlag.objects.filter(key="retention_auto").update(enabled_all=True, enabled_play=True)
        FF.invalidate()
        r = self.oc.post("/api/v1/mkt/items/fu_thanks_review/activate")
        self.assertEqual(r.status_code, 200, r.content)
        a = RetentionAutomation.objects.get()
        self.assertTrue(a.enabled)
        self.assertEqual(a.kind, "thanks_review")
        # activating twice updates the same rule
        self.oc.post("/api/v1/mkt/items/fu_thanks_review/activate")
        self.assertEqual(RetentionAutomation.objects.count(), 1)
        # overview agrees with the live rule
        r = self.oc.get("/api/v1/mkt")
        it = next(i for i in r.data["plan"]["items"] if i["id"] == "fu_thanks_review")
        self.assertTrue(it["automation_on"])
        # a sale 2 days ago -> the retention cron sends OUR text, with the STOP line
        self.sale(self.cust, self.now - timedelta(days=2, hours=1))
        st = RS.run_all(now=self.now)
        self.assertEqual(st["sent"], 1)
        snd = RetentionSend.objects.get()
        self.assertEqual(snd.recipient, self.cust_user)
        self.assertIn("কেনার জন্য অনেক ধন্যবাদ", snd.text)
        self.assertIn("বন্ধ করুন", snd.text)

    def test_followup_respects_stop(self):
        self.put_answers()
        self.oc.post("/api/v1/mkt/generate")
        self.oc.patch("/api/v1/mkt/items/fu_thanks_review", {"status": "approved"}, format="json")
        self.oc.post("/api/v1/mkt/items/fu_thanks_review/activate")
        BizOptOut.objects.create(business=self.biz, key="01710000002", source="in_app")
        self.sale(self.cust, self.now - timedelta(days=2, hours=1))
        self.assertEqual(RS.run_all(now=self.now)["sent"], 0)
        self.assertFalse(RetentionSend.objects.filter(status="sent").exists())

    def test_publish_honest_until_meta_allows(self):
        self.put_answers()
        self.oc.post("/api/v1/mkt/generate")
        self.oc.patch("/api/v1/mkt/items/post1", {"status": "approved"}, format="json")
        r = self.oc.post("/api/v1/mkt/items/post1/publish")
        self.assertEqual((r.status_code, r.data["error"]), (409, "meta_review_pending"))
        self.assertIn("কপি", r.data["detail"])
        from core import bizagent_graph as G
        from core.models import SellerChannel
        ch = SellerChannel.objects.create(business=self.biz, kind="messenger", external_id="1234",
                                          display_name="Rina Page", token_enc="x", status="connected")
        calls = []

        def fake(method, url, headers, body):
            calls.append((method, url, body))
            return 200, {"id": "1234_99"}
        with mock.patch("core.integrations.get", return_value={"page_publish_approved": True}), \
                mock.patch("core.bizagent_service.channel_token", return_value="tok"), \
                mock.patch.object(G, "_transport", side_effect=fake):
            self.assertTrue(MS.publish_state(self.biz)["facebook"])
            r = self.oc.post("/api/v1/mkt/items/post1/publish")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.data["published"]["id"], "1234_99")
        self.assertTrue(calls[0][1].endswith("/1234/feed"))
        self.assertIn("৳৩৫০", calls[0][2]["message"])
        self.assertEqual(ch.kind, "messenger")
