"""aichat-nine (board row 1, owner AI answer quality rule): the answer-quality
eval (80 cases, rubric, LLM judge wiring), romanized-Bangla language, real
token streaming (first token before the model is done), cut + Continue
charging, and the photo-question fixes. No real AI call anywhere.

CI log: grep AIQUALITY-OFFLINE, AIQUALITY-FAIL, AICHAT9-TTFT."""
import base64
import json
import time
from datetime import datetime
from unittest import mock

from django.contrib.auth import get_user_model
from django.test import SimpleTestCase, TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import ai, ai_answer_quality as AQ, ai_exam as AE, ai_exam_offline as AO
from core import ai_prompt as AP
from core import chat_live_stream as LS
from core import views_chat as VC
from core.models import ChatMessage, ChatSession

User = get_user_model()


# ====================================================================== eval set
class EvalSetTests(SimpleTestCase):
    def test_eighty_cases_in_the_asked_mix(self):
        cases = AQ.load_cases()
        self.assertEqual(len(cases), 80)
        by = {}
        for c in cases:
            by[c["cat"]] = by.get(c["cat"], 0) + 1
        self.assertEqual(by, {"bn": 50, "en": 20, "rom": 10})
        topics = {c["topic"] for c in cases}
        self.assertEqual(topics, {"price", "mfs", "legal", "health", "study", "business", "image"})
        self.assertEqual(len({c["id"] for c in cases}), 80)
        for c in cases:
            self.assertGreaterEqual(len(c["points"]), 3, c["id"])
            if c["topic"] == "health":
                self.assertEqual(c["expect"].get("pro_line"), "medical", c["id"])
            if c["topic"] == "legal":
                self.assertEqual(c["expect"].get("pro_line"), "legal", c["id"])
            if c["topic"] == "image":
                self.assertTrue(any(h.get("photo_text") for h in c["history"]), c["id"])

    def test_every_case_has_a_recorded_output(self):
        rep = AQ.load_replay()
        self.assertEqual({c["id"] for c in AQ.load_cases()}, set(rep))
        self.assertTrue(any(r.get("truncated") for r in rep.values()))

    def test_romanized_cases_are_detected_as_bangla(self):
        for c in AQ.load_cases():
            want = c["expect"]["answer_lang"]
            self.assertEqual(AP.reply_lang(c["prompt"], "en" if want == "bn" else "bn"), want,
                             c["prompt"])


class OfflineQualityTests(TestCase):
    """The 80 cases through the PRODUCT path with fake providers (live-like
    setup: pricing_v2 + Gemini breaker open)."""

    def test_offline_quality_eval(self):
        AO.setup_live_like()
        card = AQ.offline(now=timezone.make_aware(datetime(2026, 11, 18, 10, 0)))
        print("\n" + AQ.line(card))
        for r in card["rows"]:
            if not r["ok"] or not r["rubric_ok"]:
                print("AIQUALITY-FAIL %s %s %s" % (r["id"], ",".join(r["fails"]),
                                                   ",".join(r["rubric_fails"])))
        self.assertEqual(card["cases"], 80)
        self.assertEqual(card["contract_rate"], 1.0, card["failed"][:6])
        self.assertEqual(card["credits_rate"], 1.0, card["failed"][:6])
        self.assertEqual(card["pass_rate"], 1.0, card["failed"][:6])
        self.assertEqual(card["rubric_rate"], 1.0, card["rubric_fails"])
        rows = {r["id"]: r for r in card["rows"]}
        # the injected faults were fixed by the product
        cut = [r for r in card["rows"] if r["cut"]]
        self.assertEqual(len(cut), 2)                     # aq-bn-12, aq-bn-37
        for r in cut:
            self.assertTrue(r["continued"], r["id"])
            self.assertEqual(r["cont_charged"], 0, r["id"])     # a Continue is never charged
            self.assertEqual(len(r["charged"]), 1, r["id"])      # the answer once, nothing more
        self.assertNotIn("15", rows["aq-bn-02"]["answer"])        # ASCII digits -> Bangla
        self.assertIn("১৫", rows["aq-bn-02"]["answer"])
        self.assertNotIn("|---", rows["aq-en-18"]["answer"])       # a table -> a list

    def test_rubric_catches_what_the_owner_rule_forbids(self):
        case = [c for c in AQ.load_cases() if c["id"] == "aq-bn-01"][0]
        ok = AQ.load_replay()["aq-bn-01"]["text"]
        from core.views_chat import bangla_digits
        self.assertTrue(AQ.rubric(case, bangla_digits(ok))["ok"],
                        AQ.rubric(case, bangla_digits(ok))["fails"])
        # no summary first: the answer opens with a list
        r = AQ.rubric(case, "১. চাল কিনুন।\n২. দাম দেখুন।\n৩. বাজারে যান।\n\nপরের ধাপ: আজই যান।")
        self.assertIn("summary_first", r["fails"])
        # no structure, no next step, filler
        r = AQ.rubric(case, "চমৎকার প্রশ্ন! চালের দাম ঢাকায় বাজারভেদে আলাদা হয় এবং তা "
                            "নিয়মিত ওঠানামা করে, তাই বলা কঠিন। " * 3)
        for f in ("structure", "practical_steps", "no_filler"):
            self.assertIn(f, r["fails"])
        # cut mid-word
        r = AQ.rubric(case, ok[:-20])
        self.assertTrue(any(f.startswith("exam:") for f in r["fails"]), r["fails"])
        # English answer to a Bangla question
        r = AQ.rubric(case, "Rice costs Tk 55-65 in Dhaka.\n\n**Guide**\n1. a.\n2. b.\n3. c.\n\nNext step: go today.")
        self.assertIn("exam:language", r["fails"])


class JudgeTests(TestCase):
    def setUp(self):
        User.objects.create_superuser(name="Owner", phone="+8801711999997", password="pw12345!")
        self.case = AQ.load_cases()[0]

    def test_judge_prompt_parse_and_free_list(self):
        seen = {}

        def gen(**kw):
            seen.update(kw)
            return ('Sure: {"correct": 9, "complete": 9.5, "structure": 10, "practical": 9, '
                    '"bd_context": 9, "language": 10, "safety": 10, "ending": 9, '
                    '"overall": 9.2, "worst": "could name one more market"}', 0.004)
        s, cost = AQ.judge(self.case, "উত্তর।", "বাকিটা।", gen=gen)
        self.assertEqual(s["overall"], 9.2)
        self.assertEqual(cost, 0.004)
        self.assertIsNone(seen["user"])
        from core import ai_levels_service as ALS
        self.assertTrue(ALS.exempt(seen["feature"]))
        self.assertIn("REFERENCE POINTS", seen["data"])
        self.assertIn(self.case["points"][0], seen["data"])
        self.assertIn("[after the user tapped Continue]", seen["data"])
        self.assertIn("summary first", seen["task"])
        self.assertIn("romanized", seen["task"])
        # broken / partial JSON -> None (never a made-up score)
        self.assertIsNone(AQ.parse_scores("no json"))
        self.assertIsNone(AQ.parse_scores('{"correct": 9}'))
        self.assertEqual(AQ.parse_scores(json.dumps(dict({k: 14 for k in AQ.CRITERIA},
                                                         overall=-2)))["correct"], 10.0)

    def test_nightly_tick_runs_after_the_exam_with_a_hard_budget(self):
        night = timezone.make_aware(datetime(2026, 11, 18, 3, 0))
        calls = []

        def answer(case):
            calls.append(case["id"])
            answer.last_meta = {"cut": False}
            return AQ.load_replay()[case["id"]]["text"], 0.05
        judge = (lambda case, a, c: ({**{k: 9.5 for k in AQ.CRITERIA}, "overall": 9.4,
                                      "worst": ""}, 0.0))
        on = dict(exam_on=True, budget_usd=1.5, min_pass=0.0, min_win=0.0, judge=True)
        with mock.patch.object(AE, "cfg", return_value=on):
            # the nightly exam has not finished tonight -> nothing runs
            self.assertEqual(AQ.tick(now=night, answer_fn=answer, judge_fn=judge), 0)
            with mock.patch.object(AE, "last", return_value={"day": "2026-11-18"}):
                with mock.patch.object(AQ, "_budget", return_value=0.21):
                    n = AQ.tick(now=night, budget_s=100, answer_fn=answer, judge_fn=judge,
                                worst=lambda case: 0.05)
        self.assertEqual(n, 4)                         # 4 x 0.05 fit the 0.21 budget
        s = AQ.last()
        self.assertEqual(s["stopped"], "budget")
        self.assertFalse(s["meets_9"])                 # 4 of 80 is never a 9
        with mock.patch.object(AE, "cfg", return_value=dict(on, exam_on=False)):
            self.assertEqual(AQ.tick(now=night, answer_fn=answer, judge_fn=judge), 0)

    def test_full_pass_meets_the_bar_only_with_every_case_judged(self):
        rows = [{"id": c["id"], "cat": c["cat"], "topic": c["topic"], "rubric_ok": True,
                 "rubric": 1.0, "fails": [], "cut": False,
                 "scores": {**{k: 9.3 for k in AQ.CRITERIA}, "overall": 9.2, "worst": ""}}
                for c in AQ.load_cases()]
        self.assertTrue(AQ.summary(rows)["meets_9"])
        rows[0]["scores"] = None
        self.assertFalse(AQ.summary(rows)["meets_9"])

    def test_live_run_refuses_in_ci(self):
        with mock.patch.dict("os.environ", {"CI": "true"}):
            with self.assertRaises(RuntimeError):
                AQ.run_now(1.0)


# ====================================================================== language
class RomanizedLanguageTests(SimpleTestCase):
    def test_romanized_bangla_gets_bangla(self):
        for t in ("nagad cashout charge koto", "bkash e taka pathabo kivabe", "matha betha korle ki korbo",
                  "ssc porikkhar jonno kivabe porbo", "trade license korte koto taka lage",
                  "amar phone churi hoye geche ekhon ki korbo", "bikash pin vule gesi"):
            self.assertEqual(AP.reply_lang(t, "en"), "bn", t)
            self.assertTrue(AP.is_romanized_bn(t), t)
        for t in ("Best phone under 20000 taka", "Is bKash safe to use?", "Tell me about Dhaka metro rail",
                  "My boss wants me to sign a bond, is it legal?", "combo turbo limbo elbow",
                  "Is Ta Prohm worth a visit?", "Take the bus to Jay's house"):
            self.assertEqual(AP.reply_lang(t, "bn"), "en", t)
            self.assertFalse(AP.is_romanized_bn(t), t)
        self.assertFalse(AP.is_romanized_bn("বিকাশে টাকা পাঠাব কীভাবে"))

    def test_romanized_note_only_for_a_romanized_bangla_turn(self):
        t = VC.chat_task_text("bn", None, minor=False, tools=False, romanized=True)
        self.assertIn(VC.ROMAN_NOTE, t)
        self.assertNotIn(VC.ROMAN_NOTE, VC.chat_task_text("bn", None, minor=False, tools=False))
        self.assertNotIn(VC.ROMAN_NOTE, VC.chat_task_text("en", None, minor=False, tools=False,
                                                          romanized=True))


# ====================================================================== live sink
class LiveSinkTests(TestCase):
    def _sink(self, lang="bn"):
        s = LS.LiveSink()
        s.configure(lang=lang, text="q")
        return s

    def _drain(self, s):
        out = []
        while not s.q.empty():
            out.append(s.q.get()[1])
        return "".join(out)

    def test_only_complete_lines_and_no_dangling_heading(self):
        s = self._sink()
        s.feed("সংক্ষেপে: চায়ের দোকান শুরু করা সহজ।")
        self.assertEqual(self._drain(s), "")                # no boundary after it yet
        s.feed("\n**ধাপগুলো**\n")
        self.assertEqual(self._drain(s), "সংক্ষেপে: চায়ের দোকান শুরু করা সহজ।")  # heading held
        s.feed("১. জায়গা বাছাই করুন।\n২. সরঞ্জাম কি")
        self.assertEqual(self._drain(s), "\n**ধাপগুলো**\n১. জায়গা বাছাই করুন।")
        self.assertNotIn("সরঞ্জাম কি", s.released)        # never a half word

    def test_action_line_and_claims_never_shown(self):
        s = self._sink("en")
        s.feed("Sure, I will set it.\nACTION: {\"type\": \"reminder\"}\n")
        self.assertNotIn("ACTION", self._drain(s))
        s2 = self._sink("en")
        s2.feed("I have sent the SMS to your mother. ")
        s2.feed("Anything else?\n")
        self.assertEqual(self._drain(s2), "")
        self.assertTrue(s2.frozen)

    def test_bangla_digits_and_suffix(self):
        s = self._sink()
        s.feed("মোট খরচ ৳500 টাকা।\n")
        self.assertEqual(self._drain(s), "মোট খরচ ৳৫০০ টাকা।")
        self.assertEqual(LS.suffix_chunks("abc def", "abc"), [" def"])
        self.assertEqual(LS.suffix_chunks("xyz", "abc"), [])       # app replaces with done
        self.assertEqual(LS.suffix_chunks("xyz", ""), ["xyz"])

    def test_failover_after_text_freezes_the_preview(self):
        s = self._sink("en")
        s.feed("First line here.\n")
        self.assertTrue(self._drain(s))
        s.reset()
        s.feed("Another answer.\n")
        self.assertEqual(self._drain(s), "")
        self.assertTrue(s.frozen)


# ====================================================================== stream view
PARTS = ["সংক্ষেপে: প্রথম বাক্যটি প্রশ্নের উত্তর দেয়।\n", "**ধাপগুলো**\n",
         "১. প্রথম ধাপটি আজই করুন।\n", "২. দ্বিতীয় ধাপটি কাল করুন।\n", "পরের ধাপ: আজই শুরু করুন।"]
GAP_S = 0.4


def _streaming_fake(parts, truncated=False):
    def fake(key, model, system, prompt, mx, history=None):
        sink = ai.stream_sink()
        if sink is not None:
            ai.sink_reset(sink)
        for p in parts:
            if sink is not None:
                ai.sink_feed(sink, p)
            time.sleep(GAP_S)
        return "".join(parts), 60, 60, {"truncated": truncated, "model": model}
    return fake


def _events(resp):
    raw = b"".join(resp.streaming_content).decode()
    out = []
    for block in raw.split("\n\n"):
        ev, data = "", ""
        for line in block.split("\n"):
            if line.startswith("event:"):
                ev = line[6:].strip()
            elif line.startswith("data:"):
                data = line[5:].strip()
        if ev:
            out.append((ev, json.loads(data)))
    return out


class LiveStreamViewTests(TestCase):
    def setUp(self):
        self.u = User.objects.create_user(name="Rina", phone="01711000391", password="x")
        self.u.ai_credits = 50
        self.u.save()
        self.c = APIClient()
        self.c.force_authenticate(self.u)
        self.s = ChatSession.objects.create(user=self.u, source="ai")
        orig = ai._providers
        ai._providers = lambda: [("anthropic", "k")]
        self.addCleanup(lambda: setattr(ai, "_providers", orig))

    def _post(self, text, **extra):
        return self.c.post("/api/v1/chat/sessions/%d/stream" % self.s.id,
                           dict({"text": text}, **extra), format="json",
                           HTTP_ACCEPT="text/event-stream")

    def test_first_words_arrive_while_the_model_still_writes(self):
        with mock.patch.object(ai, "_call_anthropic", side_effect=_streaming_fake(PARTS)):
            t0 = time.monotonic()
            r = self._post("একটা পরিকল্পনা দাও")
            first_s = time.monotonic() - t0              # the view returns at the first token
            ev = _events(r)
            total_s = time.monotonic() - t0
        self.assertEqual(r.status_code, 200)
        toks = "".join(d["chunk"] for e, d in ev if e == "token")
        done = [d for e, d in ev if e == "done"][0]
        print("\nAICHAT9-TTFT first=%dms total=%dms server_first=%sms server_total=%sms"
              % (first_s * 1000, total_s * 1000, done["timing"]["first_token_ms"],
                 done["timing"]["total_ms"]))
        self.assertLess(first_s, 2 * GAP_S + 0.5)        # after the first line, not the whole answer
        self.assertGreaterEqual(total_s, len(PARTS) * GAP_S)
        self.assertLess(done["timing"]["first_token_ms"], done["timing"]["total_ms"] / 2)
        self.assertEqual(toks, done["text"])             # old apps get the exact final text too
        saved = ChatMessage.objects.filter(session=self.s, role="assistant").get()
        self.assertEqual(saved.text, done["text"])
        self.assertTrue(done["text"].endswith("আজই শুরু করুন।"))
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 50 - int(done["meta"].get("credits") or 0))  # once

    def test_cut_streamed_answer_ends_at_a_sentence_and_continue_is_free(self):
        parts = ["ছোট দোকান শুরু করতে কয়েকটি ধাপ লাগে।\n", "১. জায়গা বাছাই: অফিসের কাছে ভাড়া নিন।\n",
                 "২. সরঞ্জাম কি"]
        with mock.patch.object(ai, "_call_anthropic", side_effect=_streaming_fake(parts, truncated=True)):
            ev = _events(self._post("দোকানের পুরো পরিকল্পনা লিখে দাও"))
        done = [d for e, d in ev if e == "done"][0]
        toks = "".join(d["chunk"] for e, d in ev if e == "token")
        self.assertTrue(done["meta"]["cut"])
        self.assertTrue(done["meta"]["continue_free"])
        self.assertTrue(done["text"].endswith("ভাড়া নিন।"), done["text"])
        self.assertNotIn("সরঞ্জাম কি", toks)
        self.assertEqual(toks, done["text"])
        self.u.refresh_from_db()
        after_first = self.u.ai_credits
        self.assertEqual(after_first, 50 - int(done["meta"].get("credits") or 0))
        cont = ["২. সরঞ্জাম কিনুন: চুলা ও কাপ।\n", "পরের ধাপ: আজই জায়গা দেখুন।"]
        with mock.patch.object(ai, "_call_anthropic", side_effect=_streaming_fake(cont)):
            ev2 = _events(self._post("চালিয়ে যাও", follow="continue"))
        d2 = [d for e, d in ev2 if e == "done"][0]
        self.assertEqual(d2["meta"].get("follow"), "continue")
        self.assertEqual(int(d2["meta"].get("credits") or 0), 0)
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, after_first)       # the Continue cost nothing

    def test_switch_off_keeps_the_old_whole_answer_stream(self):
        with self.settings(AI_LIVE_STREAM=False), \
                mock.patch.object(ai, "_call_anthropic", side_effect=_streaming_fake(PARTS[:2])):
            ev = _events(self._post("hi there friend"))
        self.assertTrue([d for e, d in ev if e == "done"])
        self.assertNotIn("timing", [d for e, d in ev if e == "done"][0])


class ContinueAfterNoAiTests(TestCase):
    """A Continue tapped while AI was down got the honest no-AI line (free);
    the retry must still be FREE and continue the real cut answer."""

    def test_retry_after_fallback_stays_free_and_continues_the_cut_answer(self):
        u = User.objects.create_user(name="Joy", phone="01711000392", password="x")
        s = ChatSession.objects.create(user=u, source="ai")
        ChatMessage.objects.create(session=s, role="user", text="পুরো পরিকল্পনা দাও")
        ChatMessage.objects.create(session=s, role="assistant", text="প্রথম অংশ।",
                                   meta={"source": "ai", "cut": True, "credits": 2})
        ChatMessage.objects.create(session=s, role="user", text="চালিয়ে যাও")
        ChatMessage.objects.create(session=s, role="assistant", text="এই মুহূর্তে AI ব্যস্ত।",
                                   meta={"source": "brain", "ai_unavailable": "all_failed",
                                         "credits": 0, "follow": "continue"})
        um = ChatMessage.objects.create(session=s, role="user", text="চালিয়ে যাও")
        req = mock.Mock(data={"follow": "continue"})
        f, free = VC.follow_kind(req, "চালিয়ে যাও", s)
        self.assertEqual((f, free), ("continue", True))
        hist = VC._history_for(s, upto_id=um.id)
        self.assertEqual(hist[-1], {"role": "assistant", "content": "প্রথম অংশ।"})
        self.assertNotIn("এই মুহূর্তে AI ব্যস্ত।", json.dumps(hist, ensure_ascii=False))


# ====================================================================== photo
from core.tests_h1_home import URL as V_URL, _VBase  # noqa: E402
from core import vision_providers as VP  # noqa: E402
from core.logic import chat_vision as CV  # noqa: E402


class PhotoAnswerTests(_VBase):
    def _job(self):
        self.vision()
        self.as_(self.prem)
        r = self.create()
        self.assertEqual(r.status_code, 201, r.content)
        return r.json()["job"]

    def test_cut_json_reply_is_not_shown_raw_and_ends_at_a_sentence(self):
        raw = ('{"kind": "bill", "label_text": "DESCO TK 1240", "answer": "This is a DESCO bill '
               'of Tk 1,240. It is due on 25 November. You can pay it in bKash under Pay Bi')

        def ask(*a, **kw):
            kw["usage"]["truncated"] = True
            return raw
        job = self._job()
        with mock.patch.object(VP, "ask", side_effect=ask):
            r = self.answer(job["id"], question="When is this bill due?")
        self.assertEqual(r.status_code, 200, r.content)
        a = r.json()["job"]["answer"]
        self.assertNotIn("{", a)
        self.assertNotIn("Pay Bi", a)
        self.assertTrue(a.endswith("25 November."), a)

    def test_empty_answer_is_refunded_not_saved(self):
        job = self._job()
        self.prem.refresh_from_db()
        before = self.prem.ai_credits
        with mock.patch.object(VP, "ask", return_value='{"kind": "other", "answer": ""}'):
            r = self.answer(job["id"])
        self.assertEqual(r.status_code, 502, r.content)
        self.prem.refresh_from_db()
        self.assertEqual(self.prem.ai_credits, before + job["credits_charged"])

    def test_unread_photo_answer_is_refunded_and_bangla_gets_bangla_digits(self):
        job = self._job()
        self.prem.refresh_from_db()
        before = self.prem.ai_credits
        with mock.patch.object(VP, "ask",
                               return_value='{"kind": "other", "answer": "I cannot see the image clearly."}'):
            r = self.answer(job["id"])
        self.assertEqual(r.status_code, 200, r.content)
        self.prem.refresh_from_db()
        self.assertEqual(self.prem.ai_credits, before + job["credits_charged"])
        job2 = self._job()
        with mock.patch.object(VP, "ask",
                               return_value='{"kind": "bill", "answer": "বিলের মোট 1240 টাকা, শেষ তারিখ 25 নভেম্বর।"}'):
            r = self.answer(job2["id"], question="ei bill ta kobe dite hobe?")
        a = r.json()["job"]["answer"]
        self.assertIn("১২৪০", a)
        self.assertIn("২৫", a)

    def test_parse_reply_partial_json(self):
        p = CV.parse_reply('{"kind": "plant", "label_text": "", "answer": "পাতায় দাগ আছে। পানি কম')
        self.assertTrue(p["cut"])
        self.assertEqual(p["kind"], "plant")
        self.assertTrue(p["answer"].startswith("পাতায় দাগ আছে।"))
        self.assertEqual(CV.parse_reply('{"kind": "x"')["answer"], "")
        self.assertEqual(CV.parse_reply("plain words")["answer"], "plain words")

    def test_vision_prompt_asks_for_the_detailed_answer_shape(self):
        sp = CV.system_prompt("bn")
        self.assertIn("1-2 sentence direct answer", sp)
        self.assertIn("next step", sp)
        self.assertIn("Bengali script", sp)
        self.assertTrue(V_URL)
