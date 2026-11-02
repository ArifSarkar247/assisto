"""salesbar — AI sales assistant production readiness (8 Nov launch).

Mocked Meta (core.bizagent_graph transport) + mocked AI (core.ai seam); no
network, no real key. Covers: webhook verify + signature, comment replies
behind the Meta-permission flag, the 7-day private-reply rule, millisecond
comment times, opt-out (no false positive on "cancel my order") + opt-in +
no template after STOP, the HUMAN_AGENT tag (person only, 24 h - 7 days),
Meta rate-limit retry, the prompt size budget (cost per reply inside the
40% rule for any catalog size), catalog grounding of AI numbers, the audit
log, and the setup API's honest Meta state.
"""
import json
from datetime import timedelta
from decimal import Decimal
from unittest import mock

from django.utils import timezone

from core import bizagent_service as S
from core import bizagent_g1_service as G1S
from core.logic import bizagent as BZ
from core.logic import bizagent_g1 as G1
from core.logic import pricing
from core.models import BizAuditLog, ChatThread, Message, PricingConfig, Product, SellerChannel
from core.tests_p1_bizagent import APP_SECRET, Base, FakeGraph, IG, PAGE, mpayload


def set_meta_access(**kw):
    row = PricingConfig.objects.get_or_create(key="global")[0]
    d = pricing.normalize(row.data)
    d["seller_agent"]["meta_access"].update(kw)
    row.data = d
    row.save()


def comment(cid, text, created=None, page=PAGE, frm="fan1"):
    v = {"item": "comment", "verb": "add", "comment_id": cid, "post_id": "post_1",
         "message": text, "from": {"id": frm, "name": "Fan"}}
    if created is not None:
        v["created_time"] = created
    return {"object": "page", "entry": [{"id": page, "time": int(timezone.now().timestamp()),
                                         "changes": [{"field": "feed", "value": v}]}]}


class RateLimitGraph(FakeGraph):
    """Meta answers the next `n` sends with a TEMPORARY rate-limit error."""

    def __init__(self, n=0, code=613):
        super().__init__()
        self.rl_left = n
        self.code = code

    def __call__(self, method, url, headers, body):
        if self.rl_left > 0 and method == "POST" and "/messages" in url:
            self.rl_left -= 1
            self.calls.append((method, url, body))
            return 400, {"error": {"message": "(#%d) rate limit" % self.code, "code": self.code}}
        return super().__call__(method, url, headers, body)


class SB(Base):
    def setUp(self):
        super().setUp()
        self.agent.comment_dm = True
        self.agent.save()
        self.c.force_authenticate(self.user)

    def private_replies(self, cid):
        return [b for _, _, b in self.fake.calls
                if b and (b.get("recipient") or {}).get("comment_id") == cid]

    def audits(self, action):
        return BizAuditLog.objects.filter(business=self.biz, action=action)


# ======================================================================= webhook
class WebhookVerifyTests(SB):
    def test_verify_token_and_signature(self):
        url = "/api/v1/bizagent/webhook/meta"
        ok = self.c.get(url, {"hub.mode": "subscribe", "hub.verify_token": "vtok",
                              "hub.challenge": "1158201444"})
        self.assertEqual((ok.status_code, ok.content), (200, b"1158201444"))
        for q in ({"hub.mode": "subscribe", "hub.verify_token": "VTOK", "hub.challenge": "1"},
                  {"hub.mode": "unsubscribe", "hub.verify_token": "vtok", "hub.challenge": "1"},
                  {"hub.challenge": "1"}):
            self.assertEqual(self.c.get(url, q).status_code, 403)
        raw = json.dumps(mpayload("hi", "m.sig")).encode()
        unsigned = self.c.post(url, data=raw, content_type="application/json")
        self.assertEqual(unsigned.status_code, 403)
        sha1 = self.c.post(url, data=raw, content_type="application/json",
                           HTTP_X_HUB_SIGNATURE_256="sha1=" + BZ.sign(APP_SECRET, raw)[7:])
        self.assertEqual(sha1.status_code, 403)
        tampered = self.c.post(url, data=raw.replace(b"hi", b"ho"),
                               content_type="application/json",
                               HTTP_X_HUB_SIGNATURE_256=BZ.sign(APP_SECRET, raw))
        self.assertEqual(tampered.status_code, 403)
        self.assertEqual(Message.objects.count(), 0)
        self.assertEqual(self.post_meta(mpayload("hi", "m.sig")).status_code, 200)
        self.assertEqual(self.post_meta(mpayload("hi", "m.sig")).status_code, 200)   # replay
        self.assertEqual(Message.objects.filter(direction="in").count(), 1)


# ======================================================================= comments flag
class CommentFlagTests(SB):
    def test_comment_held_until_meta_grants_permission(self):
        r = self.post_meta(comment("c1", "Panjabi price?"))
        self.assertEqual(r.status_code, 200)
        self.assertEqual(self.fake.calls, [])                       # no failing Graph call
        t = ChatThread.objects.get(external_user_id="comment:fan1")
        self.assertEqual(t.messages.filter(direction="in", kind="comment").count(), 1)
        self.assertEqual(self.audits("comment_held").count(), 1)
        # Meta grants the Facebook comment permission -> the next comment is answered
        set_meta_access(comments_fb=True)
        self.post_meta(comment("c2", "Panjabi price?"))
        priv = self.private_replies("c2")
        self.assertEqual(len(priv), 1)
        self.assertIn("1200", priv[0]["message"]["text"])

    def test_instagram_needs_its_own_permission(self):
        SellerChannel.objects.create(business=self.biz, kind="instagram", external_id=IG,
                                     status="connected", token_enc=S.enc({"token": "IGT"}))
        set_meta_access(comments_fb=True)                          # FB only
        p = {"object": "instagram", "entry": [{"id": IG, "time": int(timezone.now().timestamp()),
             "changes": [{"field": "comments", "value": {
                 "id": "igc1", "text": "Panjabi price?", "from": {"id": "igu", "username": "nila"},
                 "media": {"id": "m1"}}}]}]}
        self.post_meta(p)
        self.assertEqual(self.private_replies("igc1"), [])
        set_meta_access(comments_ig=True)
        p["entry"][0]["changes"][0]["value"]["id"] = "igc2"
        self.post_meta(p)
        self.assertEqual(len(self.private_replies("igc2")), 1)

    def test_private_reply_only_within_7_days(self):
        set_meta_access(comments_fb=True)
        old = int((timezone.now() - timedelta(days=8)).timestamp())
        self.post_meta(comment("old1", "Panjabi price?", created=old))
        self.assertEqual(self.private_replies("old1"), [])
        fresh = int((timezone.now() - timedelta(days=6)).timestamp())
        self.post_meta(comment("new1", "Panjabi price?", created=fresh))
        self.assertEqual(len(self.private_replies("new1")), 1)

    def test_millisecond_comment_time_does_not_crash(self):
        set_meta_access(comments_fb=True)
        ms = int(timezone.now().timestamp() * 1000)
        self.assertEqual(self.post_meta(comment("ms1", "Panjabi price?", created=ms)).status_code,
                         200)
        t = ChatThread.objects.get(external_user_id="comment:fan1")
        self.assertLess(abs((t.last_message_at - timezone.now()).total_seconds()), 120)
        self.assertEqual(len(self.private_replies("ms1")), 1)

    def test_seller_reply_in_comment_chat_is_honest(self):
        self.post_meta(comment("c9", "Saree ache?"))
        t = ChatThread.objects.get(external_user_id="comment:fan1")
        m = S.seller_send(t, "Inbox e janacchi")
        self.assertEqual((m.status, m.send_error), ("blocked", "comment_perm_pending"))
        self.assertEqual(self.fake.calls, [])
        set_meta_access(comments_fb=True)
        m = S.seller_send(t, "Inbox e janacchi")
        self.assertEqual(m.status, "sent")
        self.assertEqual(len(self.private_replies("c9")), 1)
        m = S.seller_send(t, "aro kichu")                           # one reply per comment
        self.assertEqual((m.status, m.send_error), ("blocked", "comment_already_replied"))

    def test_setup_api_shows_meta_state(self):
        r = self.c.get("/api/v1/bizagent/setup")
        self.assertEqual(r.status_code, 200)
        js = r.json()
        self.assertEqual(js["meta_access"]["review"], "not_submitted")
        self.assertFalse(js["features"]["comments_fb"])
        set_meta_access(review="approved", comments_fb=True)
        js = self.c.get("/api/v1/bizagent/setup").json()
        self.assertEqual(js["meta_access"]["review"], "approved")
        self.assertTrue(js["features"]["comments_fb"])
        self.assertFalse(js["features"]["comments_ig"])


# ======================================================================= opt-out
class OptOutTests(SB):
    def test_pure_rules(self):
        for txt in ("STOP", "stop.", "স্টপ", "মেসেজ বন্ধ করুন", "msg bondho koren",
                    "আর মেসেজ দিবেন না", "unsubscribe", "বন্ধ করুন"):
            self.assertTrue(G1.is_opt_out(txt), txt)
        for txt in ("অর্ডারটা বন্ধ করুন", "order ta bondho koren", "দোকান কখন বন্ধ হয়?",
                    "bus stop er kache delivery hobe?", "Panjabi er dam koto?",
                    "order er message ta pai nai, stop hoye gelo?"):
            self.assertFalse(G1.is_opt_out(txt), txt)
        for txt in ("START", "start", "স্টার্ট", "আবার মেসেজ দিন"):
            self.assertTrue(G1.is_opt_in(txt), txt)
        self.assertFalse(G1.is_opt_in("Panjabi start price koto?"))

    def test_cancel_order_is_not_opt_out(self):
        self.post_meta(mpayload("অর্ডারটা বন্ধ করুন", "oo1"))
        self.assertFalse(self.thread().opted_out)

    def test_stop_then_start_and_no_template_after_stop(self):
        self.post_meta(mpayload("STOP", "oo2"))
        t = self.thread()
        self.assertTrue(t.opted_out)
        self.assertEqual(self.audits("opt_out").count(), 1)
        self.post_meta(mpayload("START", "oo3"))
        t.refresh_from_db()
        self.assertFalse(t.opted_out)
        self.assertEqual(self.audits("opt_in").count(), 1)
        self.assertEqual(self.outs(t)[-1].reply_source, "system")

    def test_template_blocked_after_stop(self):
        from core.tests_p1_bizagent import wapayload
        self.post_wa(wapayload("STOP", "wamid.oo4"))
        t = self.thread(self.wa)
        self.assertTrue(t.opted_out)
        n = len(self.fake.calls)
        m = S.send_template(t, "order_update")
        self.assertEqual((m.status, m.send_error), ("blocked", "opted_out"))
        r = self.c.post("/api/v1/bizagent/threads/%d/template" % t.pk,
                        {"name": "order_update"}, format="json")
        self.assertEqual(r.status_code, 409)
        self.assertEqual(r.json().get("error"), "opted_out")
        self.assertEqual(len(self.fake.calls), n)                   # nothing reached Meta


# ======================================================================= 24 h / human agent
class HumanAgentTests(SB):
    def make_old(self, hours):
        self.post_meta(mpayload("hello", "ha.%d" % hours))
        t = self.thread()
        ChatThread.objects.filter(pk=t.pk).update(
            last_inbound_at=timezone.now() - timedelta(hours=hours))
        t.refresh_from_db()
        return t

    def last_body(self):
        return [b for _, _, b in self.fake.calls if b][-1]

    def test_late_human_reply_needs_the_permission(self):
        t = self.make_old(30)
        m = S.seller_send(t, "Dukkhito deri holo, Panjabi ache")
        self.assertEqual((m.status, m.send_error), ("blocked", "outside_24h_window"))
        set_meta_access(human_agent=True)
        n = len(self.fake.calls)
        m = S.seller_send(t, "Dukkhito deri holo, Panjabi ache")
        self.assertEqual(m.status, "sent")
        self.assertEqual(len(self.fake.calls), n + 1)
        body = self.last_body()
        self.assertEqual((body["messaging_type"], body["tag"]), ("MESSAGE_TAG", "HUMAN_AGENT"))
        self.assertEqual(m.meta.get("tag"), "HUMAN_AGENT")

    def test_ai_never_uses_the_tag_and_7_days_is_the_end(self):
        set_meta_access(human_agent=True)
        t = self.make_old(30)
        n = len(self.fake.calls)
        ai = S.send_text(t, "AI text", is_ai=True, source="ai")
        self.assertEqual((ai.status, ai.send_error), ("blocked", "outside_24h_window"))
        auto = S.send_text(t, "automated holding line", is_ai=False)     # not a person
        self.assertEqual(auto.status, "blocked")
        self.assertEqual(len(self.fake.calls), n)
        t2 = self.make_old(24 * 8)
        n = len(self.fake.calls)
        m = S.seller_send(t2, "anyone?")
        self.assertEqual((m.status, m.send_error), ("blocked", "outside_7d_window"))
        self.assertEqual(len(self.fake.calls), n)

    def test_whatsapp_late_reply_needs_template(self):
        from core.tests_p1_bizagent import wapayload
        set_meta_access(human_agent=True)
        self.post_wa(wapayload("hello", "wamid.ha1"))
        t = self.thread(self.wa)
        ChatThread.objects.filter(pk=t.pk).update(
            last_inbound_at=timezone.now() - timedelta(hours=30))
        t.refresh_from_db()
        m = S.seller_send(t, "late")
        self.assertEqual((m.status, m.send_error),
                         ("blocked", "outside_24h_window_template_required"))


# ======================================================================= rate limits
class RateLimitTests(SB):
    def use(self, graph):
        from core import bizagent_graph as G
        prev = G.set_transport(graph)
        self.addCleanup(G.set_transport, prev)
        self.fake = graph

    def test_rate_limited_reply_is_retried(self):
        self.post_meta(mpayload("hello", "rl0"))
        t = self.thread()
        self.use(RateLimitGraph(n=1))
        m = S.seller_send(t, "Panjabi ache")
        self.assertEqual((m.status, m.send_error), ("queued", "rate_limited"))
        self.assertEqual(S.retry_rate_limited(now=timezone.now()), 0)        # < 60 s
        self.assertEqual(S.retry_rate_limited(now=timezone.now() + timedelta(seconds=61)), 1)
        m.refresh_from_db()
        self.assertEqual((m.status, m.send_error), ("sent", ""))

    def test_gives_up_after_three_tries_and_tells_the_seller(self):
        self.post_meta(mpayload("hello", "rl1"))
        t = self.thread()
        self.use(RateLimitGraph(n=10, code=4))
        m = S.seller_send(t, "Panjabi ache")
        with mock.patch.object(S, "notify_seller") as push:
            for i in (1, 2, 3):
                S.retry_rate_limited(now=timezone.now() + timedelta(minutes=2 * i))
        m.refresh_from_db()
        self.assertEqual(m.status, "failed")
        self.assertEqual(m.meta["rl_tries"], 3)
        self.assertEqual(push.call_count, 1)

    def test_window_closed_meanwhile(self):
        self.post_meta(mpayload("hello", "rl2"))
        t = self.thread()
        self.use(RateLimitGraph(n=1))
        m = S.seller_send(t, "Panjabi ache")
        ChatThread.objects.filter(pk=t.pk).update(
            last_inbound_at=timezone.now() - timedelta(hours=25))
        S.retry_rate_limited(now=timezone.now() + timedelta(minutes=2))
        m.refresh_from_db()
        self.assertEqual((m.status, m.send_error), ("failed", "rate_limited_window_closed"))

    def test_permanent_error_is_not_retried(self):
        self.post_meta(mpayload("hello", "rl3"))
        self.fake.fail = True                                   # code 10 = permission
        m = S.seller_send(self.thread(), "x")
        self.assertEqual(m.status, "failed")
        self.assertFalse(BZ.is_rate_limited(m.send_error))

    def test_sweep_is_wired(self):
        out = G1S.run_sweeps(now=timezone.now())
        self.assertIn("rate_limited", out)
        self.assertNotEqual(out["rate_limited"], -1)


# ======================================================================= cost + grounding
class PromptBudgetTests(SB):
    def big_catalog(self, n=500):
        Product.objects.bulk_create([
            Product(user=self.user, business=self.biz, name="Item %03d long product name" % i,
                    price=Decimal(100 + i), min_price=Decimal(90 + i), stock=(i % 3),
                    description="Pure cotton, hand-made, many colours " * 3)
            for i in range(n)])

    def test_prompt_stays_inside_budget_for_any_catalog(self):
        self.big_catalog()
        from core.models import OwnerPolicy
        OwnerPolicy.objects.filter(business=self.biz).update(returns="R" * 2000)
        self.post_meta(mpayload("x" * 4000, "pb1"))
        for i in range(8):
            Message.objects.create(thread=self.thread(), direction="in" if i % 2 == 0 else "out",
                                   text="h" * 3000, status="received" if i % 2 == 0 else "sent")
        seen = {}

        def fake_generate(task, data="", **kw):
            seen.update(task=task, data=data, history=kw.get("history") or [])
            return '{"reply": "Panjabi ৳1200", "confidence": 0.9}', 0.0

        ctx = S.context_for(self.biz, self.agent, "bn")
        with mock.patch("core.ai.key_present", return_value=True), \
                mock.patch("core.ai.generate", side_effect=fake_generate):
            d = S._llm_draft(ctx, "bn", "friendly", "x" * 4000, S._history(self.thread()))
        self.assertEqual(d["text"], "Panjabi ৳1200")
        size = len(seen["task"]) + len(seen["data"]) + \
            sum(len(h["content"]) for h in seen["history"])
        self.assertLessEqual(size, S.PROMPT_BUDGET_CHARS)
        lines = [ln for ln in ctx["facts"].splitlines() if ln.startswith("- Item")]
        self.assertLessEqual(len(lines), S.FACTS_MAX_PRODUCTS)
        self.assertTrue(all("স্টক 0" not in ln for ln in lines[:10]))   # in stock first
        self.assertEqual(len(ctx["catalog"]), 502)                    # post-check sees all

    def test_worst_case_reply_cost_keeps_40_percent(self):
        cfg = pricing.normalize(PricingConfig.objects.get_or_create(key="global")[0].data)
        rows = {r["plan"]: r for r in BZ.plan_margin_rows(cfg)}
        self.assertEqual((rows["pro"]["price"], rows["pro"]["replies"]), (3990, 2700))
        self.assertTrue(rows["pro"]["ok"])
        self.assertGreaterEqual(rows["pro"]["margin_pct"], 40)

    def test_invented_price_from_ai_is_never_sent(self):
        def fake_draft(*a, **k):
            return {"text": "এটার দাম মাত্র ৳৯৯৯, আজই নিন!", "confidence": 0.95}
        self.post_meta(mpayload("hello", "gr0"))
        t = self.thread()
        with mock.patch.object(S, "_llm_draft", side_effect=fake_draft):
            d = S.compose(self.biz, self.agent, t,
                          "amar ammu er jonno ekta gift dorkar, ki suggest korben?", "bn")
        self.assertNotIn("৯৯৯", d.get("text") or "")
        if d.get("source") == "ai":
            self.assertEqual(d.get("risk"), BZ.RISK_NUMBERS)


# ======================================================================= audit
class AuditTests(SB):
    def test_settings_approve_reject_are_audited_without_bodies(self):
        r = self.c.post("/api/v1/bizagent/settings",
                        {"tone": "formal", "returns": "secret policy text"}, format="json")
        self.assertEqual(r.status_code, 200)
        a = self.audits("settings").get()
        self.assertEqual(a.detail["keys"], ["returns", "tone"])
        self.assertNotIn("secret policy text", json.dumps(a.detail))
        self.post_meta(mpayload("hello", "au1"))
        t = self.thread()
        m1 = Message.objects.create(thread=t, direction="out", text="draft one",
                                    status="pending_approval", is_ai=True, meta={"source": "rule"})
        m2 = Message.objects.create(thread=t, direction="out", text="draft two",
                                    status="pending_approval", is_ai=True, meta={"source": "rule"})
        self.assertEqual(self.c.post("/api/v1/bizagent/approvals/%d/approve" % m1.pk, {},
                                     format="json").status_code, 200)
        self.assertEqual(self.c.post("/api/v1/bizagent/approvals/%d/reject" % m2.pk, {},
                                     format="json").status_code, 200)
        self.assertEqual(self.audits("approve").count(), 1)
        self.assertEqual(self.audits("reject").count(), 1)
        listed = self.c.get("/api/v1/bizagent/audit").json()["audit"]
        acts = {row["action"] for row in listed}
        self.assertTrue({"settings", "approve", "reject"} <= acts)
        self.assertNotIn("draft one", json.dumps(listed))
