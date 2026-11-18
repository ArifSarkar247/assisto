"""ai-reply-core (owner order 17 Nov, part H): AI reply — server tests.

Two accounts A (Amina) and B (Bilal), connected in My Circle. No real AI
call anywhere: ai.generate is replaced by a fake that keeps the real
contract (charges the action's credits through billing, fills out_meta).

Covers: suggest + send by tap, Busy timer expiry, Full auto with the tag,
tag off, blocked topics held (+ notice), group = suggest only (server),
child refused, ping-pong loop guard, rate limit, single-use send token, no
storage / logging of anyone's text, credits charged + cut answers refunded,
ad unlock hint, lane-2 notification token (scoped + revocable), the 40%
pricing rule and the ad placement.

Run: manage.py test core.tests_ai_reply --settings=assisto_backend.settings_test
"""
import json
import logging
from datetime import timedelta
from unittest import mock

from django.test import SimpleTestCase, TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import ai, ai_reply as AR, billing, credits as CR
from core import feature_flags as FF
from core.logic import ad_control as AC, ai_reply_rules as R, plan_book as BOOK, pricing as P
from core.models import (AIUsage, AiReplyEvent, AiReplyMark, AiReplyProfile, AiReplySetting,
                         CircleGroup, CircleGroupMember, CircleMember, CircleMessage, User)

V = "/api/v1"
SECRET = "Bilal secret sentence zebra-4417 about the blue door"
REPLIES = ["Valo achi, tumi?", "Ha bolo bhai", "Ekhon ektu busy"]


def mk(phone, name):
    return User.objects.create_user(name=name, phone=phone, password="pw12345!", language="en")


def cl(u=None):
    c = APIClient()
    if u is not None:
        c.force_authenticate(u)
    c.credentials(HTTP_ACCEPT_LANGUAGE="en")
    return c


def fake_generate(hold=False, category="", replies=None, truncated=False, raw=None):
    """A stand-in for ai.generate with its real contract: charges
    `charge_action` through billing (atomic), reports charged/spend_ref."""
    calls = []

    def _gen(task, data="", tier="cheap", max_tokens=800, feature="", user=None,
             charge_action=None, out_meta=None, pii=None, **kw):
        calls.append({"task": task, "data": data, "feature": feature, "action": charge_action,
                      "pii": pii, "max_tokens": max_tokens})
        res = billing.charge(user, charge_action, qty=1, note=feature)
        if not res["ok"]:
            raise ai.AIUnavailable("credits")
        if isinstance(out_meta, dict):
            out_meta.update({"charged": res["charged"], "spend_ref": res.get("spend_ref", ""),
                             "truncated": truncated})
        body = raw if raw is not None else json.dumps(
            {"hold": hold, "category": category, "replies": replies if replies is not None else REPLIES})
        return body, 0.001
    _gen.calls = calls
    return _gen


class _Base(TestCase):
    def setUp(self):
        self.a = mk("01710000001", "Amina")
        self.b = mk("01710000002", "Bilal")
        self.ab = CircleMember.objects.create(user=self.a, peer_user=self.b, name="Bilal",
                                              state="accepted", phone=self.b.phone)
        self.ba = CircleMember.objects.create(user=self.b, peer_user=self.a, name="Amina",
                                              state="accepted", phone=self.a.phone,
                                              direction="incoming")
        self.ca, self.cb = cl(self.a), cl(self.b)
        for u in (self.a, self.b):
            CR.grant(u, CR.FREE, 20, reason="grant", note="test")
        self.push = mock.patch("core.push.safe_push", return_value=1)
        self.push_mock = self.push.start()
        self.addCleanup(self.push.stop)
        p = mock.patch("core.ai_reply.flag_on", return_value=True)
        p.start()
        self.addCleanup(p.stop)
        p2 = mock.patch("core.ai_reply.is_child", return_value=False)
        self.child = p2.start()
        self.addCleanup(p2.stop)

    def incoming(self, sender=None, edge=None, ct="text"):
        """A message B sent to A (ciphertext only, as the relay stores it)."""
        return CircleMessage.objects.create(member=edge or self.ba, sender=sender or self.b,
                                            recipient_ids=[self.ab.id], content_type=ct,
                                            ciphertext="Q1Q=", nonce="Tg==")

    def set_mode(self, client, edge, **data):
        return client.post("%s/ai/reply/settings/member/%d" % (V, edge.id), data, format="json")

    def auto(self, client, edge, msg, text="kemon acho?"):
        return client.post(V + "/ai/reply/auto", {"member_id": edge.id, "message_id": msg.id,
                                                  "text": text, "context": []}, format="json")

    def send(self, client, edge, token=None, cmid="m1"):
        body = {"ciphertext": "Q1Q=", "nonce": "Tg==", "content_type": "text", "client_msg_id": cmid}
        if token:
            body["ai_reply_token"] = token
        r = client.post("%s/circle/%d/messages" % (V, edge.id), body, format="json")
        self.assertIn(r.status_code, (200, 201), r.content)
        return r.json()

    def rows(self, client, edge):
        r = client.get("%s/circle/%d/messages" % (V, edge.id))
        self.assertEqual(r.status_code, 200, r.content)
        return {x["id"]: x for x in r.json()["results"]}


# ===================================================================== pure
class RulesTests(SimpleTestCase):
    def test_blocked_topics_in_bangla_english_and_romanized(self):
        cases = {
            "৫০০ টাকা বিকাশ করো": "money", "Can you lend me 500 tk": "money",
            "nagad e pathao": "money", "tomar thikana ki?": "address",
            "তুমি কোথায় আছো?": "address", "kal dekha korbo?": "meet", "let's meet tonight": "meet",
            "হাসপাতালে আছি": "health", "accident hoyeche": "health", "promise me": "promise",
            "কথা দাও": "promise", "biye kobe?": "decision", "বিয়ের কথা": "decision",
            "Your OTP is 482913": "otp", "পিন নম্বর দাও": "otp", "bachao!": "sos", "বিপদে আছি": "sos",
        }
        for text, cat in cases.items():
            self.assertEqual(R.classify(text), cat, text)

    def test_everyday_chat_is_not_held(self):
        for t in ("কেমন আছো?", "ki khobor bhai", "how was your day?", "ধারণা ভালো", "বিষয়টা দেখো",
                  "thanks!", "ok"):
            self.assertEqual(R.classify(t), "", t)

    def test_language(self):
        self.assertEqual(R.detect_lang("কেমন আছো?"), "bn")
        self.assertEqual(R.detect_lang("tumi kemon acho bhai"), "roman")
        self.assertEqual(R.detect_lang("How are you doing?"), "en")

    def test_style_profile_keeps_no_raw_text(self):
        prof = R.style_profile([SECRET, "ok bhai", "ok bhai 😂", "thik ache", "thik ache!"] * 3)
        dumped = json.dumps(prof, ensure_ascii=False)
        for word in ("zebra", "4417", "blue door", "secret"):
            self.assertNotIn(word, dumped)
        self.assertIn("ok bhai", prof["phrases"])
        self.assertTrue(set(prof["phrases"]) <= set(R.PHRASES))

    def test_model_output_parsing_drops_risky_replies(self):
        hold, cat, out = R.parse_model('{"hold":false,"replies":["Ha bolo","500 taka dibo"]}')
        self.assertEqual((hold, out), (False, ["Ha bolo"]))
        self.assertEqual(R.parse_model("not json")[0], None)
        self.assertEqual(R.parse_model('{"hold":true,"category":"money","replies":[]}')[:2],
                         (True, "money"))


class MoneyRuleTests(SimpleTestCase):
    """The 40 % CI rule: the default action table + the plan_book cap."""

    def test_reply_actions_priced_and_hold_40pct(self):
        c = P.normalize(P.DEFAULTS())
        for aid in (AR.ACTION_SUGGEST, AR.ACTION_AUTO):
            row = c["action_costs"][aid]
            self.assertGreater(row["provider_cost"], 0, aid)
            self.assertGreaterEqual(row["credits"], P.action_credit_floor(aid, c), aid)
            self.assertGreaterEqual(row["credits"], P.recompute_from_provider_cost(aid, c), aid)
            self.assertGreaterEqual(row["credits"], BOOK.level_credits(row["provider_cost"]), aid)

    def test_unlock_placement_is_rewarded_not_safety(self):
        p = AC.BY_KEY[AR.UNLOCK_PLACEMENT]
        self.assertEqual(p["type"], "rewarded")
        self.assertFalse(p["safety"])
        self.assertTrue(p["on"])

    def test_flags_registered_and_off_by_default(self):
        for k in (AR.FLAG, AR.FLAG_NOTIF):
            self.assertTrue(FF.is_known(k), k)
            self.assertFalse(FF.meta(k)["default_on"], k)


class FlagDefaultTests(TestCase):
    def test_normal_user_sees_both_flags_off(self):
        u = mk("01710000009", "Nadia")
        self.assertFalse(FF.is_on("ai_reply", u))
        self.assertFalse(FF.is_on("ai_reply_notif", u))
        self.assertFalse(AR.flag_on(u))


# ===================================================================== suggest
class SuggestTests(_Base):
    def test_suggest_returns_chips_and_charges_one_reply(self):
        gen = fake_generate()
        before = User.objects.get(pk=self.a.pk).ai_credits
        with mock.patch("core.ai.generate", side_effect=gen):
            r = self.ca.post(V + "/ai/reply/suggest", {
                "source": "circle", "member_id": self.ab.id, "text": "kemon acho?",
                "context": [{"from": "me", "text": "ki khobor"}]}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        d = r.json()
        self.assertTrue(d["ok"])
        self.assertEqual(d["suggestions"], REPLIES)
        self.assertEqual(d["charged"], 1)
        self.assertEqual(User.objects.get(pk=self.a.pk).ai_credits, before - 1)
        self.assertEqual(gen.calls[0]["action"], AR.ACTION_SUGGEST)
        self.assertTrue(gen.calls[0]["pii"])
        self.assertEqual(d["lang"], "roman")

    def test_tap_sends_a_normal_message_without_tag(self):
        mid = self.send(self.ca, self.ab)["id"]          # the tapped chip, encrypted by the phone
        row = self.rows(self.cb, self.ba)[mid]
        self.assertFalse(row["ai_reply"])
        self.assertFalse(row["ai_label"])

    def test_blocked_topic_gives_no_suggestions_and_costs_nothing(self):
        gen = fake_generate()
        with mock.patch("core.ai.generate", side_effect=gen):
            r = self.ca.post(V + "/ai/reply/suggest", {"member_id": self.ab.id,
                                                       "text": "500 taka bkash koro"}, format="json")
        d = r.json()
        self.assertEqual((d["ok"], d["reason"], d["needs_you"], d["category"]),
                         (False, "blocked", True, "money"))
        self.assertEqual(gen.calls, [])

    def test_model_hold_is_respected(self):
        with mock.patch("core.ai.generate", side_effect=fake_generate(hold=True, category="promise",
                                                                      replies=[])):
            d = self.ca.post(V + "/ai/reply/suggest", {"member_id": self.ab.id, "text": "will it be fine?"},
                             format="json").json()
        self.assertEqual((d["reason"], d["category"]), ("blocked", "promise"))

    def test_cut_answer_is_refunded(self):
        before = User.objects.get(pk=self.a.pk).ai_credits
        with mock.patch("core.ai.generate", side_effect=fake_generate(raw='{"hold": false, "repl')):
            r = self.ca.post(V + "/ai/reply/suggest", {"member_id": self.ab.id, "text": "hi"}, format="json")
        self.assertEqual(r.status_code, 503)
        self.assertEqual(User.objects.get(pk=self.a.pk).ai_credits, before)

    def test_no_credits_offers_the_ad_unlock(self):
        def broke(*a, **k):
            raise ai.AIUnavailable("credits")
        with mock.patch("core.ai.generate", side_effect=broke), \
                mock.patch("core.admob_service.placement_on", return_value=True):
            r = self.ca.post(V + "/ai/reply/suggest", {"member_id": self.ab.id, "text": "hi"}, format="json")
        self.assertEqual(r.status_code, 402)
        self.assertEqual(r.json(), {"ok": False, "reason": "no_credits", "unlock": "ad"})

    def test_rate_limit(self):
        with mock.patch("core.ai.generate", side_effect=fake_generate()):
            self.ca.post(V + "/ai/reply/suggest", {"member_id": self.ab.id, "text": "hi"}, format="json")
            r = self.ca.post(V + "/ai/reply/suggest", {"member_id": self.ab.id, "text": "hi"}, format="json")
        self.assertEqual(r.status_code, 429)
        self.assertEqual(r.json()["reason"], "rate_limited")

    def test_flag_off_refuses(self):
        with mock.patch("core.ai_reply.flag_on", return_value=False):
            r = self.ca.post(V + "/ai/reply/suggest", {"member_id": self.ab.id, "text": "hi"}, format="json")
        self.assertEqual((r.status_code, r.json()["reason"]), (403, "flag_off"))

    def test_text_is_never_stored_or_logged(self):
        with mock.patch("core.ai.generate", side_effect=fake_generate()), \
                self.assertLogs("core", level=logging.DEBUG) as logs:
            logging.getLogger("core").debug("probe")
            self.ca.post(V + "/ai/reply/suggest", {"member_id": self.ab.id, "text": SECRET,
                                                   "context": [{"from": "them", "text": SECRET}]},
                         format="json")
            msg = self.incoming()
            self.set_mode(self.ca, self.ab, mode="auto")
            self.auto(self.ca, self.ab, msg, text=SECRET)
        self.assertNotIn("zebra", "\n".join(logs.output))
        stored = []
        for model in (AiReplyEvent, AiReplySetting, AiReplyProfile, AiReplyMark, AIUsage):
            stored += [json.dumps(r, default=str) for r in model.objects.values()]
        self.assertNotIn("zebra", "\n".join(stored))


# ===================================================================== modes
class ModeTests(_Base):
    def test_default_off_and_label_default_on(self):
        d = self.ca.get("%s/ai/reply/settings/member/%d" % (V, self.ab.id)).json()
        self.assertEqual((d["mode"], d["label_on"]), ("off", True))
        self.assertEqual(d["allowed_modes"], ["off", "suggest", "busy", "auto"])

    def test_busy_timer_expires_on_the_server_clock(self):
        d = self.set_mode(self.ca, self.ab, mode="busy", busy_minutes=30).json()
        self.assertEqual(d["mode"], "busy")
        self.assertIsNotNone(d["busy_until"])
        AiReplySetting.objects.filter(user=self.a).update(
            busy_until=timezone.now() - timedelta(seconds=1))
        msg = self.incoming()
        with mock.patch("core.ai.generate", side_effect=fake_generate()) as g:
            r = self.auto(self.ca, self.ab, msg)
        self.assertEqual(r.json()["action"], "skip")
        self.assertEqual(r.json()["reason"], "mode_off")
        self.assertEqual(g.call_count, 0)
        self.assertEqual(self.ca.get("%s/ai/reply/settings/member/%d" % (V, self.ab.id)).json()["mode"], "off")

    def test_busy_until_i_turn_it_off(self):
        d = self.set_mode(self.ca, self.ab, mode="busy", busy_minutes=0).json()
        self.assertEqual((d["mode"], d["busy_until"]), ("busy", None))
        self.assertEqual(self.set_mode(self.ca, self.ab, mode="busy", busy_minutes=45).status_code, 400)

    def test_busy_reply_is_sent_with_the_tag(self):
        self.set_mode(self.ca, self.ab, mode="busy", busy_minutes=60)
        msg = self.incoming()
        gen = fake_generate(replies=["Ekhon busy, pore kotha boli"])
        with mock.patch("core.ai.generate", side_effect=gen):
            d = self.auto(self.ca, self.ab, msg).json()
        self.assertEqual((d["action"], d["kind"]), ("send", "busy"))
        self.assertEqual(gen.calls[0]["action"], AR.ACTION_AUTO)
        mid = self.send(self.ca, self.ab, token=d["token"])["id"]
        self.assertEqual(AiReplyMark.objects.get(message_id=mid).kind, "busy")

    def test_full_auto_with_label_reaches_the_receiver(self):
        self.set_mode(self.ca, self.ab, mode="auto")
        msg = self.incoming()
        with mock.patch("core.ai.generate", side_effect=fake_generate()):
            d = self.auto(self.ca, self.ab, msg).json()
        self.assertEqual(d["action"], "send")
        self.assertEqual(d["reply"], REPLIES[0])
        self.assertTrue(d["label"])
        body = self.send(self.ca, self.ab, token=d["token"])
        self.assertTrue(body["ai_reply"])
        row = self.rows(self.cb, self.ba)[body["id"]]
        self.assertEqual((row["ai_reply"], row["ai_label"]), (True, True))
        # the same incoming message is never answered twice
        with mock.patch("core.ai.generate", side_effect=fake_generate()):
            self.assertIn(self.auto(self.ca, self.ab, msg).json()["reason"], ("done", "answered"))
        # a second ask for the same message (open chat + push at once) is refused too
        AiReplyMark.objects.all().delete()
        CircleMessage.objects.filter(sender=self.a).delete()
        with mock.patch("core.ai.generate", side_effect=fake_generate()):
            self.assertEqual(self.auto(self.ca, self.ab, msg).json()["reason"], "done")

    def test_label_off_per_person(self):
        self.set_mode(self.ca, self.ab, mode="auto", label_on=False)
        msg = self.incoming()
        with mock.patch("core.ai.generate", side_effect=fake_generate()):
            d = self.auto(self.ca, self.ab, msg).json()
        self.assertFalse(d["label"])
        mid = self.send(self.ca, self.ab, token=d["token"])["id"]
        row = self.rows(self.cb, self.ba)[mid]
        self.assertEqual((row["ai_reply"], row["ai_label"]), (True, False))

    def test_send_token_is_single_use_and_bound_to_the_chat(self):
        self.set_mode(self.ca, self.ab, mode="auto")
        msg = self.incoming()
        with mock.patch("core.ai.generate", side_effect=fake_generate()):
            tok = self.auto(self.ca, self.ab, msg).json()["token"]
        self.send(self.ca, self.ab, token=tok, cmid="x1")
        second = self.send(self.ca, self.ab, token=tok, cmid="x2")
        self.assertNotIn("ai_reply", second)
        self.assertFalse(AiReplyMark.objects.filter(message_id=second["id"]).exists())

    def test_blocked_topic_is_held_and_the_user_notified(self):
        self.set_mode(self.ca, self.ab, mode="auto")
        msg = self.incoming()
        gen = fake_generate()
        with mock.patch("core.ai.generate", side_effect=gen):
            d = self.auto(self.ca, self.ab, msg, text="৫০০ টাকা বিকাশ করো প্লিজ").json()
        self.assertEqual((d["action"], d["category"]), ("hold", "money"))
        self.assertEqual(gen.calls, [])
        args = self.push_mock.call_args
        self.assertEqual(args[0][0], self.a)
        self.assertIn("Bilal", args[0][3])
        self.assertEqual(args[1]["data"]["ai_held"], "1")
        held = self.ca.get(V + "/ai/reply/held").json()["results"]
        self.assertEqual([(h["category"], h["message_id"]) for h in held], [("money", msg.id)])
        self.assertEqual(self.ca.post("%s/ai/reply/held/%d/seen" % (V, held[0]["id"])).status_code, 200)
        self.assertEqual(self.ca.get(V + "/ai/reply/held").json()["results"], [])

    def test_sos_and_system_messages_never(self):
        self.set_mode(self.ca, self.ab, mode="auto")
        sysmsg = self.incoming(ct="system")
        self.assertEqual(self.auto(self.ca, self.ab, sysmsg).json()["reason"], "not_text")
        msg = self.incoming()
        self.assertEqual(self.auto(self.ca, self.ab, msg, text="SOS help me").json()["category"], "sos")

    def test_ping_pong_guard(self):
        """Both on Full auto: B's AI reply never triggers A's AI reply."""
        self.set_mode(self.ca, self.ab, mode="auto")
        self.set_mode(self.cb, self.ba, mode="auto")
        a_msg = self.send(self.ca, self.ab, cmid="human1")        # A, a human
        with mock.patch("core.ai.generate", side_effect=fake_generate()):
            d = self.auto(self.cb, self.ba, CircleMessage.objects.get(pk=a_msg["id"])).json()
        self.assertEqual(d["action"], "send")
        b_ai = self.send(self.cb, self.ba, token=d["token"], cmid="bai1")
        gen = fake_generate()
        with mock.patch("core.ai.generate", side_effect=gen):
            d2 = self.auto(self.ca, self.ab, CircleMessage.objects.get(pk=b_ai["id"])).json()
        self.assertEqual((d2["action"], d2["reason"]), ("skip", "loop"))
        self.assertEqual(gen.calls, [])

    def test_rate_limit_one_auto_reply_per_30s_per_chat(self):
        self.set_mode(self.ca, self.ab, mode="auto")
        m1, m2 = self.incoming(), self.incoming()
        with mock.patch("core.ai.generate", side_effect=fake_generate()):
            self.assertEqual(self.auto(self.ca, self.ab, m1).json()["action"], "send")
            d = self.auto(self.ca, self.ab, m2).json()
        self.assertEqual((d["action"], d["reason"]), ("skip", "rate_limited"))

    def test_only_the_peers_message_of_this_chat(self):
        self.set_mode(self.ca, self.ab, mode="auto")
        mine = self.send(self.ca, self.ab, cmid="own")
        r = self.auto(self.ca, self.ab, CircleMessage.objects.get(pk=mine["id"]))
        self.assertEqual(r.status_code, 404)


class GroupAndChildTests(_Base):
    def test_group_is_suggest_only_on_the_server(self):
        g = CircleGroup.objects.create(creator=self.a, name="Family")
        CircleGroupMember.objects.create(group=g, member=self.a, role="admin")
        url = "%s/ai/reply/settings/group/%d" % (V, g.id)
        self.assertEqual(self.ca.get(url).json()["allowed_modes"], ["off", "suggest"])
        for mode in ("busy", "auto"):
            r = self.ca.post(url, {"mode": mode}, format="json")
            self.assertEqual((r.status_code, r.json()["reason"]), (403, "group_suggest_only"))
        self.assertEqual(self.ca.post(url, {"mode": "suggest"}, format="json").json()["mode"], "suggest")
        # not a member -> not found
        self.assertEqual(self.cb.get(url).status_code, 404)

    def test_child_on_either_side_is_refused(self):
        self.child.side_effect = lambda u: u.pk == self.b.pk     # B is a child
        r = self.set_mode(self.ca, self.ab, mode="auto")
        self.assertEqual((r.status_code, r.json()["reason"]), (403, "child"))
        r = self.ca.post(V + "/ai/reply/suggest", {"member_id": self.ab.id, "text": "hi"}, format="json")
        self.assertEqual((r.status_code, r.json()["reason"]), (403, "child"))
        AiReplySetting.objects.create(user=self.a, member=self.ab, mode="auto")   # stale row
        self.assertEqual(self.auto(self.ca, self.ab, self.incoming()).json()["reason"], "child")
        self.child.side_effect = lambda u: u.pk == self.a.pk     # A is a child
        self.assertEqual(self.ca.post(V + "/ai/reply/notif-token").status_code, 403)


class StyleTests(_Base):
    def test_learning_needs_consent_and_keeps_only_a_profile(self):
        url = V + "/ai/reply/style/learn"
        self.assertEqual(self.ca.post(url, {"samples": ["ok bhai"]}, format="json").status_code, 403)
        self.ca.post(V + "/ai/reply/style", {"consent": True}, format="json")
        d = self.ca.post(url, {"samples": [SECRET, "ok bhai", "ok bhai", "thik ache"]}, format="json").json()
        self.assertTrue(d["learned"])
        self.assertNotIn("zebra", json.dumps(AiReplyProfile.objects.get(user=self.a).style))
        # the style reaches the model as a short hint
        gen = fake_generate()
        with mock.patch("core.ai.generate", side_effect=gen):
            self.ca.post(V + "/ai/reply/suggest", {"member_id": self.ab.id, "text": "hi"}, format="json")
        self.assertIn("ok bhai", gen.calls[0]["task"])
        # consent off deletes the profile
        self.ca.post(V + "/ai/reply/style", {"consent": False}, format="json")
        self.assertEqual(AiReplyProfile.objects.get(user=self.a).style, {})


class NotifApiTests(_Base):
    """Lane 2 contract: scoped token, 401 = stay quiet, revocable."""

    def test_token_suggest_and_revoke(self):
        t = self.ca.post(V + "/ai/reply/notif-token").json()
        self.assertTrue(t["ok"])
        native = APIClient()
        url = V + "/ai/reply/suggest"
        body = {"source": "notif", "app": "com.whatsapp", "sender": "Rahim", "text": "kemon acho?",
                "context": [], "lang": "auto", "is_group": False}
        with mock.patch("core.ai.generate", side_effect=fake_generate()):
            r = native.post(url, body, format="json", HTTP_X_ASSISTO_AIREPLY=t["token"])
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(len(r.json()["suggestions"]), 3)
        self.assertEqual(AiReplyEvent.objects.get(kind="suggest").source, "notif")
        # OTP / bank / payment / SOS: refused server side, no AI call
        gen = fake_generate()
        with mock.patch("core.ai.generate", side_effect=gen):
            for text in ("Your OTP is 123456", "Your bKash payment of 500 tk", "SOS"):
                d = native.post(url, dict(body, text=text), format="json",
                                HTTP_X_ASSISTO_AIREPLY=t["token"]).json()
                self.assertEqual((d["ok"], d["reason"]), (False, "blocked"), text)
        self.assertEqual(gen.calls, [])
        self.ca.delete(V + "/ai/reply/notif-token")
        r = native.post(url, body, format="json", HTTP_X_ASSISTO_AIREPLY=t["token"])
        self.assertEqual(r.status_code, 401)
        self.assertEqual(native.post(url, body, format="json",
                                     HTTP_X_ASSISTO_AIREPLY="forged").status_code, 401)

    def test_token_cannot_reach_other_endpoints(self):
        t = self.ca.post(V + "/ai/reply/notif-token").json()["token"]
        r = APIClient().get(V + "/ai/reply/notif-state", HTTP_X_ASSISTO_AIREPLY=t)
        self.assertIn(r.status_code, (401, 403))

    def test_notif_state_for_free_and_paid(self):
        with mock.patch("core.admob_service.placement_on", return_value=True):
            d = self.ca.get(V + "/ai/reply/notif-state").json()
            self.assertEqual(d["unlock_ad_placement"], "ai_reply_unlock")
            self.assertEqual(d["unlock"], "ad")
            self.assertGreaterEqual(d["free_left"], 1)
            self.assertGreaterEqual(d["ads_per_reply"] or 1, 1)
            with mock.patch("core.sponsor_service.is_paid", return_value=True):
                self.assertEqual(self.ca.get(V + "/ai/reply/notif-state").json()["unlock"], "premium")

    def test_flag_off_token_refused(self):
        with mock.patch("core.ai_reply.flag_on", return_value=False):
            r = self.ca.post(V + "/ai/reply/notif-token")
        self.assertEqual((r.status_code, r.json()["reason"]), (403, "flag_off"))
