"""bizauto — business message SAFETY used by every automated sender
(retention / crmauto, tagada + CRM Assisto SMS, AI-sales follow-ups and
comment replies). Owner order P3-C (3 Nov):

  * SMS cost under the owner's 40 % rule — computed from the SMS provider
    settings + the credit prices; FAILS if any config sells an SMS part
    below 40 % profit;
  * opt-out on every automated message: a signed one-tap STOP link (an SMS
    reply never reaches us), honoured server-side at once by every path;
  * one daily cap per customer across every path + the existing caps,
    Owner-Admin editable;
  * quiet hours: Owner-Admin window, always covering 22:00-08:00; a seller's
    own explicit choice wins for AI-sales follow-ups;
  * Meta comment replies behind the Owner-Admin switch, proven with recorded
    webhook payloads (core/testdata/meta_webhooks) + the Data Deletion
    callback Meta App Review needs.

Mocked SMS gateway + mocked Meta Graph — no network, no real key.
"""
import json
import os
from datetime import datetime, timedelta
from unittest import mock

from django.test import SimpleTestCase, TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import billing, sms_service
from core import bizagent_g1_service as G1S
from core import meta_deletion as MD
from core import retention_service as RS
from core.logic import msg_guard as MG
from core.logic import pricing as P
from core.logic import sms_margin as SM
from core.models import (BizOptOut, BusinessProfile, ChatThread, Customer, Message,
                         PricingConfig, SellerChannel, SmsLog, User)
from core.tests_p1_bizagent import APP_SECRET, IG, PAGE, mpayload
from core.tests_salesbar import SB, set_meta_access
from core.tests_smsotp import alpha_ok, connect

FX = os.path.join(os.path.dirname(__file__), "testdata", "meta_webhooks")


def fx(name):
    raw = open(os.path.join(FX, name), encoding="utf-8").read()
    now = str(int(timezone.now().timestamp()))
    return json.loads(raw.replace("__PAGE__", PAGE).replace("__IG__", IG)
                      .replace("__NOW__", now))


def dhaka(y, m, d, hh, mm=0):
    return datetime(y, m, d, hh, mm, tzinfo=MG.DHAKA)


def set_pricing(**blocks):
    """Owner Admin -> Pricing edit (merged into the stored row)."""
    row = PricingConfig.objects.get_or_create(key="global")[0]
    d = P.normalize(row.data)
    for k, v in blocks.items():
        if isinstance(v, dict) and isinstance(d.get(k), dict):
            d[k].update(v)
        else:
            d[k] = v
    row.data = d
    row.save()
    MG.reset_window_cache()


# ======================================================================= 40 % rule
class SmsMarginPureTests(SimpleTestCase):
    def test_old_price_broke_the_rule(self):
        """What was shipped: 1 credit per SMS part, cheapest credit ৳0.833
        (200 tk pack = 240 credits), real cost ৳0.35 -> only ~22 % profit."""
        m = SM.margin(1, 0.35, 200 / 240)
        self.assertLess(m["profit_pct"], 40)

    def test_floor_keeps_40_percent_for_any_cost(self):
        cheapest = 200 / 240
        for cost in (0.0, 0.05, 0.2, 0.25, 0.35, 0.5, 0.75, 1.2, 3.0):
            n = SM.credits_per_part(cost, cheapest)
            self.assertGreaterEqual(SM.margin(n, cost, cheapest)["profit_pct"], 40.0, cost)
            if n > 1:      # and it is the FEWEST credits that do
                self.assertLess(SM.margin(n - 1, cost, cheapest)["profit_pct"], 40.0, cost)

    def test_nothing_sells_credits_never_sells_sms(self):
        self.assertGreater(SM.credits_per_part(0.35, 0), 1000)


class SmsMarginConfigTests(TestCase):
    def test_shipped_config_keeps_40_percent_on_every_credit_we_sell(self):
        """THE proof the owner asked for: per-message SMS cost from the SMS
        provider settings vs what one part is charged, on EVERY product that
        sells credits (plans, annual plans, packs). Fails below 40 %."""
        c = billing.cfg()
        proof = SM.proof(c)
        self.assertTrue(proof["ok"], proof)
        self.assertGreaterEqual(proof["profit_pct"], 40.0, proof)
        per = P.credit_cost("sms", c)
        self.assertEqual(per, proof["credits_per_part"])
        for pid, bdt in SM.bdt_per_credit_rows(c["plans"], c["topup_packs"],
                                               c["annual_discount_pct"]):
            m = SM.margin(per, proof["cost_per_part_bdt"], bdt)
            self.assertGreaterEqual(m["profit_pct"], 40.0, (pid, bdt, m))

    def test_owner_admin_cannot_sell_sms_below_the_rule(self):
        set_pricing(action_costs={"sms": {"provider_cost": 0.002, "credits": 1}})
        self.assertGreaterEqual(P.credit_cost("sms", billing.cfg()), 2)
        self.assertTrue(SM.proof(billing.cfg())["ok"])

    def test_dearer_sms_or_cheaper_credits_raise_the_price(self):
        set_pricing(sms={"default_cost_per_segment_bdt": 0.60})
        c = billing.cfg()
        self.assertEqual(P.credit_cost("sms", c), 3)          # 0.60 / (0.833 x 0.24)
        self.assertTrue(SM.proof(c)["ok"])
        packs = [dict(p) for p in c["topup_packs"]] + [
            {"id": "p500", "price": 500, "credits": 700, "valid_months": 12}]
        set_pricing(topup_packs=packs, sms={"default_cost_per_segment_bdt": 0.35})
        c = billing.cfg()
        self.assertTrue(SM.proof(c)["ok"], SM.proof(c))
        self.assertGreaterEqual(P.credit_cost("sms", c), 3)   # ৳0.714 a credit now

    def test_gateway_with_its_own_higher_cost_charges_more(self):
        connect("sms_alpha", {"api_key": "AK", "cost_per_segment_bdt": "0.90"})
        from core import sms_gateway
        ads = sms_gateway.active()
        self.assertEqual(sms_service.min_credits_for(ads, 2), 2 * 5)   # 0.90 / 0.2 -> 5
        connect("sms_alpha", {"api_key": "AK", "cost_per_segment_bdt": "0.30"})
        self.assertEqual(sms_service.min_credits_for(sms_gateway.active(), 2), 0)


# ======================================================================= quiet hours
class QuietWindowTests(TestCase):
    def setUp(self):
        MG.reset_window_cache()
        self.addCleanup(MG.reset_window_cache)

    def test_default_is_21_to_9(self):
        self.assertTrue(MG.in_quiet_hours(dhaka(2026, 11, 3, 21, 0)))
        self.assertFalse(MG.in_quiet_hours(dhaka(2026, 11, 3, 9, 0)))
        self.assertEqual(MG.quiet_label(), {"start": "21:00", "end": "09:00"})

    def test_owner_admin_window_and_its_22_to_8_floor(self):
        set_pricing(retention={"quiet_start_hour": 22, "quiet_end_hour": 8})
        self.assertFalse(MG.in_quiet_hours(dhaka(2026, 11, 3, 21, 30)))
        self.assertTrue(MG.in_quiet_hours(dhaka(2026, 11, 3, 22, 0)))
        self.assertTrue(MG.in_quiet_hours(dhaka(2026, 11, 4, 7, 59)))
        self.assertFalse(MG.in_quiet_hours(dhaka(2026, 11, 4, 8, 0)))
        nxt = MG.next_allowed_at(dhaka(2026, 11, 3, 23, 0))
        self.assertEqual((nxt.day, nxt.hour), (4, 8))
        # nobody can shrink it below 22:00-08:00 (e.g. 23:00-07:00 typed)
        set_pricing(retention={"quiet_start_hour": 23, "quiet_end_hour": 7})
        self.assertTrue(MG.in_quiet_hours(dhaka(2026, 11, 3, 22, 0)))
        self.assertTrue(MG.in_quiet_hours(dhaka(2026, 11, 4, 7, 30)))
        self.assertEqual(MG.quiet_label(), {"start": "22:00", "end": "08:00"})


# ======================================================================= opt-out + caps
@mock.patch("core.sms_gateway._http", side_effect=alpha_ok)
class OptOutAndCapsTests(TestCase):
    PHONE = "01712345678"

    def setUp(self):
        MG.reset_window_cache()
        self.addCleanup(MG.reset_window_cache)
        connect("sms_alpha", {"api_key": "AK", "cost_per_segment_bdt": "0.30"})
        self.owner = User.objects.create_user(name="Rina", phone="01710000001", password="pw-123456")
        self.owner.plan = "business"
        self.owner.plan_until = timezone.now() + timedelta(days=300)
        self.owner.save()
        billing.ensure_monthly_pool(self.owner)
        User.objects.filter(pk=self.owner.pk).update(ai_credits=40)
        self.owner.refresh_from_db()
        self.biz = BusinessProfile.objects.create(user=self.owner, shop_name="Rina Store")
        self.day = timezone.now().astimezone(MG.DHAKA).replace(hour=11, minute=0)

    def send(self, purpose="crm", text="Eid offer"):
        return sms_service.send_sms(self.PHONE, text, purpose, user=self.owner,
                                    business=self.biz, now=self.day)

    def credits(self):
        return User.objects.get(pk=self.owner.pk).ai_credits

    def test_crm_sms_charged_at_the_40_percent_price(self, _http):
        r = self.send()
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["credits"], P.credit_cost("sms", billing.cfg()) * r["segments"])
        self.assertEqual(self.credits(), 40 - r["credits"])

    def test_stop_link_is_honoured_at_once_everywhere(self, _http):
        key = "01712345678"
        tok = MG.stop_token(self.biz.pk, key)
        self.assertEqual(MG.parse_stop_token(tok), (self.biz.pk, key))
        self.assertIsNone(MG.parse_stop_token(tok[:-1] + ("0" if tok[-1] != "0" else "1")))
        self.assertIn("/api/v1/retention/u/" + tok, MG.stop_link(self.biz.pk, key))
        c = APIClient()
        page = c.get("/api/v1/retention/u/" + tok)          # a link preview stops nobody
        self.assertEqual(page.status_code, 200)
        self.assertIn("Rina Store", page.content.decode())
        self.assertFalse(MG.is_opted_out(self.biz.pk, key))
        done = c.post("/api/v1/retention/u/" + tok)
        self.assertEqual(done.status_code, 200)
        self.assertTrue(BizOptOut.objects.filter(business=self.biz, key=key,
                                                 source="sms_link").exists())
        # the very next send on every path is refused, nothing charged
        before = self.credits()
        for purpose in ("crm", "tagada"):
            r = self.send(purpose)
            self.assertEqual((r["ok"], r["reason"]), (False, "opted_out"), purpose)
        self.assertEqual(self.credits(), before)
        v = MG.gate(self.biz.pk, key, now=self.day, caps=RS.caps_for(self.biz))
        self.assertEqual(v.reason, "opted_out")                  # retention / crmauto
        self.assertEqual(c.get("/api/v1/retention/u/" + tok).status_code, 200)   # idempotent
        self.assertEqual(c.get("/api/v1/retention/u/kzzx1-badsig000").status_code, 404)

    def test_crm_and_tagada_sms_carry_the_one_tap_link(self, _http):
        from core.tagada_engine import sms_final
        out = sms_final(self.biz, "+8801712345678", "বাকি ৫০০ টাকা")
        self.assertIn("/api/v1/retention/u/k", out)
        self.assertNotIn("STOP লিখুন", out)

    def test_one_cap_across_every_path(self, _http):
        caps = RS.caps_for(self.biz)
        self.assertEqual(caps["all_per_customer_day"], 2)
        SmsLog.objects.create(purpose="tagada", phone="+8801712345678", user=self.owner,
                              business=self.biz, status="sent")
        self.assertTrue(MG.gate(self.biz.pk, self.PHONE, now=self.day, caps=caps).ok)
        SmsLog.objects.create(purpose="crm", phone="+8801712345678", user=self.owner,
                              business=self.biz, status="sent")
        # 2 business SMS today -> retention / crmauto may not add a third
        v = MG.gate(self.biz.pk, self.PHONE, now=self.day, caps=caps)
        self.assertEqual((v.ok, v.reason), (False, "customer_daily_cap"))
        r = self.send("crm")
        self.assertEqual((r["ok"], r["reason"]), (False, "customer_daily_cap"))
        # another customer is not affected; Owner Admin may allow 3
        self.assertTrue(MG.gate(self.biz.pk, "01799999999", now=self.day, caps=caps).ok)
        set_pricing(retention={"max_all_per_customer_day": 3})
        self.assertTrue(MG.gate(self.biz.pk, self.PHONE, now=self.day,
                                caps=RS.caps_for(self.biz)).ok)
        set_pricing(retention={"max_all_per_customer_day": 50})            # clamped to 3
        self.assertEqual(RS.caps_for(self.biz)["all_per_customer_day"], 3)

    def test_quiet_hours_refuse_business_sms(self, _http):
        night = self.day.replace(hour=22, minute=30)
        r = sms_service.send_sms(self.PHONE, "x", "crm", user=self.owner, business=self.biz,
                                 now=night)
        self.assertEqual(r["reason"], "quiet_hours")


class OptOutListTests(TestCase):
    def setUp(self):
        from core.tests_retention import _flag_on
        _flag_on()
        from core import feature_flags as FF
        self.addCleanup(FF.invalidate)
        self.owner = User.objects.create_user(name="Rina", phone="01710000001", password="pw-123456")
        self.biz = BusinessProfile.objects.create(user=self.owner, shop_name="Rina Store")
        self.c = APIClient()
        self.c.force_authenticate(self.owner)

    def test_owner_sees_who_stopped_masked_and_cannot_undo(self):
        MG.record_opt_out(self.biz.pk, "01712345678", "sms_link")
        MG.record_opt_out(self.biz.pk, "psid:77", "chat")
        r = self.c.get("/api/v1/retention/opt-outs")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.data["count"], 2)
        whos = [x["who"] for x in r.data["opt_outs"]]
        self.assertNotIn("01712345678", whos)                    # masked
        self.assertIn("Messenger / Instagram", whos)
        self.assertIn("sms_link", [x["source"] for x in r.data["opt_outs"]])
        self.assertEqual(self.c.delete("/api/v1/retention/opt-outs").status_code, 405)
        ov = self.c.get("/api/v1/retention")
        self.assertEqual(ov.status_code, 200)
        self.assertEqual(ov.data["safety"]["all_per_customer_day"], 2)
        self.assertGreaterEqual(ov.data["safety"]["sms_credits_per_part"], 2)
        self.assertEqual(ov.data["quiet"]["start"], "21:00")


# ======================================================================= AI sales
class FollowupQuietTests(SB):
    def _silent_chat(self):
        self.agent.followups_enabled = True
        self.agent.save()
        self.post_meta(mpayload("Panjabi order korbo", "bz1"))
        t = self.thread()
        Message.objects.filter(thread=t).update(created_at=timezone.now() - timedelta(hours=4))
        ChatThread.objects.filter(pk=t.pk).update(last_inbound_at=timezone.now() - timedelta(hours=4))
        return t

    def test_no_followup_at_night_by_default(self):
        self._silent_chat()
        with mock.patch("core.logic.msg_guard.in_quiet_hours", return_value=True):
            self.assertEqual(G1S.run_followups(), 0)

    def test_sellers_own_choice_wins(self):
        self._silent_chat()
        self.agent.quiet_hours = {"start": "00:00", "end": "00:00"}   # "no quiet hours"
        self.agent.save()
        with mock.patch("core.logic.msg_guard.in_quiet_hours", return_value=True):
            self.assertEqual(G1S.run_followups(), 1)

    def test_stop_said_elsewhere_stops_followups(self):
        t = self._silent_chat()
        MG.record_opt_out(self.biz.pk, "psid:" + t.external_user_id, "sms_link")
        ChatThread.objects.filter(pk=t.pk).update(opted_out=False)   # a fresh chat row
        with mock.patch("core.logic.msg_guard.in_quiet_hours", return_value=False):
            self.assertEqual(G1S.run_followups(), 0)


class CommentFixtureTests(SB):
    """Recorded-shape Meta payloads -> the comment path works the day App
    Review passes (Owner Admin -> seller page -> Meta permissions)."""
    CID = "123456789012345_987654321098765"

    def test_switch_off_saves_for_inbox_only(self):
        self.assertEqual(self.post_meta(fx("fb_comment_add.json")).status_code, 200)
        self.assertEqual(self.private_replies(self.CID), [])
        t = ChatThread.objects.get(external_user_id="comment:7712345678901234")
        self.assertEqual(t.messages.filter(direction="in", kind="comment").count(), 1)

    def test_switch_on_one_private_reply_per_comment(self):
        set_meta_access(comments_fb=True)
        self.post_meta(fx("fb_comment_add.json"))
        priv = self.private_replies(self.CID)
        self.assertEqual(len(priv), 1)
        self.assertIn("1200", priv[0]["message"]["text"])        # real catalog price
        self.post_meta(fx("fb_comment_add.json"))                 # Meta redelivery
        self.assertEqual(len(self.private_replies(self.CID)), 1)
        self.post_meta(fx("fb_comment_edited.json"))              # an edit is not a new ask
        self.assertEqual(len(self.private_replies(self.CID)), 1)
        self.post_meta(fx("fb_comment_by_page.json"))             # the Page's own comment
        self.assertEqual(self.private_replies("123456789012345_987654321092222"), [])
        self.post_meta(fx("fb_comment_reply_to_comment.json"))    # a reply under a comment
        self.assertEqual(len(self.private_replies("123456789012345_987654321091111")), 1)

    def test_instagram_comment(self):
        SellerChannel.objects.create(business=self.biz, kind="instagram", external_id=IG,
                                     status="connected", token_enc=SB_enc("IGT"))
        self.post_meta(fx("ig_comment.json"))
        self.assertEqual(self.private_replies("17865799348089039"), [])
        set_meta_access(comments_ig=True)
        p = fx("ig_comment.json")
        p["entry"][0]["changes"][0]["value"]["id"] = "17865799348089040"
        self.post_meta(p)
        self.assertEqual(len(self.private_replies("17865799348089040")), 1)

    def test_stop_in_messenger_means_no_comment_dm(self):
        set_meta_access(comments_fb=True)
        self.post_meta(fx("messenger_stop.json"))
        self.assertTrue(BizOptOut.objects.filter(business=self.biz,
                                                 key="psid:7712345678901234").exists())
        self.post_meta(fx("fb_comment_add.json"))
        self.assertEqual(self.private_replies(self.CID), [])


def SB_enc(token):
    from core import bizagent_service as S
    return S.enc({"token": token})


class DataDeletionTests(SB):
    URL = "/api/v1/bizagent/meta/data-deletion"

    def test_signed_request_deletes_that_persons_chats(self):
        self.post_meta(fx("fb_comment_add.json"))
        self.post_meta(mpayload("hi", "dd1", psid="7712345678901234"))
        self.assertEqual(ChatThread.objects.filter(
            external_user_id__in=["7712345678901234", "comment:7712345678901234"]).count(), 2)
        sr = MD.make_signed_request({"algorithm": "HMAC-SHA256", "issued_at": 1730619000,
                                     "user_id": "7712345678901234"}, APP_SECRET)
        r = self.c.post(self.URL, {"signed_request": sr})
        self.assertEqual(r.status_code, 200, r.content)
        body = r.json()
        self.assertTrue(body["confirmation_code"].startswith("del-"))
        self.assertIn("/api/v1/bizagent/meta/data-deletion/status?code=", body["url"])
        self.assertEqual(ChatThread.objects.filter(
            external_user_id__in=["7712345678901234", "comment:7712345678901234"]).count(), 0)
        page = self.c.get("/api/v1/bizagent/meta/data-deletion/status",
                          {"code": body["confirmation_code"]})
        self.assertEqual(page.status_code, 200)

    def test_bad_signature_is_refused(self):
        sr = MD.make_signed_request({"algorithm": "HMAC-SHA256", "user_id": "1"}, "wrong")
        self.assertEqual(self.c.post(self.URL, {"signed_request": sr}).status_code, 400)
        self.assertEqual(self.c.post(self.URL, {}).status_code, 400)
        self.assertEqual(self.c.get(self.URL).status_code, 405)
