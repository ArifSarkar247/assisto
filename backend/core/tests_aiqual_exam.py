"""aiqual (owner 9 Nov 21:20, full power item 7): the AI exam matched to the
current setup + the chat quality fixes it found. No real AI call anywhere:
the offline exam replays recorded model outputs through the product path
with fake providers (core/ai_exam_offline.py).

CI log: grep AIEXAM-OFFLINE (score line) and AIEXAM-FAIL (one line per
failing case)."""
import json
import os
from datetime import datetime
from unittest import mock

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import SimpleTestCase, TestCase
from django.utils import timezone

from core import ai, ai_compliance as AC, ai_exam as AE, ai_exam_offline as AO
from core import ai_levels_service as ALS, ai_prompt as AP
from core import gemini_breaker as GB
from core import views_chat as VC

# Raise only (owner rule: thresholds never go down to make CI green).
FLOOR = {"pass_rate": 1.0, "answer_rate": 1.0, "contract_rate": 1.0, "credits_rate": 1.0}


class OfflineExamTests(TestCase):
    """The whole exam, offline, on the live setup of 9 Nov (pricing_v2 +
    Gemini breaker open)."""

    def test_offline_exam_every_case_passes(self):
        AO.setup_live_like()
        self.assertTrue(GB.is_open())
        card = AO.run()
        print("\n" + AO.line(card))
        for f in card["failed"]:
            print("AIEXAM-FAIL %s %s" % (f["id"], ",".join(f["fails"])))
        out = os.environ.get("AIEXAM_OUT")
        if out:
            with open(out, "w", encoding="utf-8") as fh:
                json.dump({k: v for k, v in card.items() if k != "rows"}, fh, ensure_ascii=False,
                          indent=1)
        # BEFORE: the same exam on the 9 Nov chat (verbatim copy, test-only)
        from core.ai_evals import legacy_chat_9nov as LEGACY
        with LEGACY.legacy():
            before = AO.run()
        print(AO.line(before).replace("AIEXAM-OFFLINE", "AIEXAM-OFFLINE-BEFORE"))
        for f in before["failed"]:
            print("AIEXAM-BEFORE-FAIL %s %s" % (f["id"], ",".join(f["fails"])))
        self.assertGreater(card["answer_rate"], before["answer_rate"])
        self.assertEqual(card["cases"], len(AE.load_cases()))
        for k, floor in FLOOR.items():
            self.assertGreaterEqual(card[k], floor, "%s: %s" % (k, card["failed"][:8]))

    def test_every_case_has_a_recorded_output(self):
        rep = AO.load_replay()
        for c in AE.load_cases():
            self.assertIn(c["id"], rep)
            self.assertTrue(rep[c["id"]]["text"].strip(), c["id"])
            if rep[c["id"]].get("truncated"):
                self.assertTrue(rep[c["id"]].get("cont"), c["id"])

    def test_the_net_catches_injected_regressions(self):
        """A broken prompt / router / post-processing must FAIL the exam."""
        AO.setup_live_like()
        cases = {c["id"]: c for c in AE.load_cases()}
        pick = [cases[i] for i in ("exam-024", "exam-020", "exam-077", "exam-122", "exam-036")]
        # 1) post-processing gone: tables, ASCII digits, cut mid-word survive
        with mock.patch.object(VC, "finish_reply",
                               side_effect=lambda r, t, l, **kw: (r, None, False, 0)):
            card = AO.run(cases=pick)
        self.assertLess(card["pass_rate"], 0.5)
        # 2) the router answers Normal with Sonnet
        real = ALS.spec

        def dear(lid, c=None):
            s = real(lid, c)
            if s and lid == "normal":
                s = dict(s, model="claude-sonnet-5-5")
            return s
        with mock.patch.object(ALS, "spec", side_effect=dear):
            card = AO.run(cases=[cases["exam-001"]])
        self.assertIn("contract:router_model", card["failed"][0]["fails"])
        # 3) the date line is dropped -> the reminder lands on a guessed day
        with mock.patch.object(VC, "now_line", return_value="unknown"):
            card = AO.run(cases=[cases["exam-077"]])
        self.assertIn("reminder_due", card["failed"][0]["fails"])

    def test_refuses_a_non_test_database(self):
        with mock.patch.object(AO, "_test_db", return_value=False):
            with self.assertRaises(RuntimeError):
                AO.setup_live_like()
            with self.assertRaises(RuntimeError):
                AO.run(cases=[])


class LiveExamSafetyTests(TestCase):
    """The nightly LIVE exam: no user, no user data, free-list features,
    worst-case budget check before every case, honest gate."""

    def setUp(self):
        get_user_model().objects.create_superuser(name="Owner", phone="+8801711999998",
                                                  password="pw12345!")

    def test_live_calls_have_no_user_and_are_on_the_free_list(self):
        AO.setup_live_like()
        seen = []

        def gen(*a, **kw):
            seen.append(kw)
            if kw.get("out_meta") is not None:
                kw["out_meta"].update(truncated=False, provider="anthropic",
                                      model="claude-haiku-5-5")
            return ("ঠিক আছে — উত্তর এখানে।", 0.001)
        case = [c for c in AE.load_cases() if c["id"] == "exam-001"][0]
        with mock.patch.object(ai, "generate", side_effect=gen):
            AE.product_answer(case)
            AE.reference_answer(case)
        for kw in seen:
            self.assertIsNone(kw["user"])
            self.assertTrue(ALS.exempt(kw["feature"]), kw["feature"])
            self.assertNotIn("+8801711999998", json.dumps(kw, ensure_ascii=False, default=str))
        self.assertEqual(seen[0]["level"], "normal")
        self.assertEqual(seen[1]["level"], "best")        # reference = the Best model

    def test_worst_case_is_checked_before_a_case_runs(self):
        c = dict(exam_on=True, budget_usd=0.05, min_pass=0.0, min_win=0.0, judge=True)
        calls = []
        with mock.patch.object(AE, "cfg", return_value=c):
            AE.tick(now=timezone.make_aware(datetime(2026, 11, 10, 3, 0)), budget_s=100,
                    answer=lambda case: calls.append(1) or ("x।", 0.001),
                    ref=lambda case: ("r", 0.0), judge_fn=lambda case, a, b: ("tie", 0.0),
                    worst=lambda case, sample: 0.02)
        s = AE.last()
        self.assertEqual(s["stopped"], "budget")
        self.assertGreater(s["graded"], 0)
        self.assertLessEqual(s["cost_usd"], 0.05)          # never past the owner's cap
        self.assertEqual(len(calls), s["graded"])
        ok, why = AE.gate(c=c)
        self.assertFalse(ok)
        self.assertIn("incomplete", why)

    def test_judge_sample_rotates_and_is_small(self):
        n = len(AE.load_cases())
        a = [i for i in range(n) if AE.judged(i, n, "2026-11-10")]
        b = [i for i in range(n) if AE.judged(i, n, "2026-11-11")]
        self.assertLessEqual(len(a), AE.JUDGE_PER_NIGHT + 1)
        self.assertNotEqual(a, b)


class PromptTests(TestCase):
    def test_identity_is_honest_while_gemini_is_off(self):
        self.assertIn("Google (Gemini) — say exactly that", AP.system_prompt())
        GB.trip("http_402", "")
        sp = AP.system_prompt()
        self.assertIn("right now your answers come from Anthropic's Claude models", sp)
        self.assertIn("Axon Dynamics", sp)
        self.assertNotIn("say exactly that", sp)

    def test_chat_task_has_format_length_web_and_date(self):
        t = VC.chat_task_text("bn", None, minor=False, tools=True, out_cap=1500, web=True)
        for k in ("NEVER a table", "Bangla digits", "Length budget", "1500", "Web search is on",
                  "ACTION:", "general information only"):
            self.assertIn(k, t)
        self.assertIn("অন্য ভাষায়", t)          # translate: the asked language, not Bangla
        self.assertNotIn("SAFE MODE", t)
        self.assertIn("SAFE MODE", VC.chat_task_text("en", None, minor=True))
        d = VC.chat_data("hi", "-", now=timezone.make_aware(datetime(2026, 11, 9, 21, 40)))
        self.assertTrue(d.startswith("Now: 2026-11-09 (Monday) 21:40"))

    def test_chat_turn_sends_the_date_identity_and_level_budget(self):
        AO.setup_live_like()
        u = get_user_model().objects.create_user(name="Q", phone="+8801700000777", password="pw12345!")
        seen = {}

        def gen(*a, **kw):
            seen.update(kw)
            kw["out_meta"].update(charged=1)
            return ("ঠিক আছে।", 0.0)
        with mock.patch.object(VC.ai, "available", return_value=True), \
                mock.patch.object(VC.ai, "generate", side_effect=gen):
            VC._produce_reply(u, None, "kal sokal 9 tay ammu ke phone korte mone koriye dio",
                              "en", [], level="normal")
        self.assertIn("Now: ", seen["data"])
        self.assertIn("উত্তর সবসময় বাংলায়", seen["extra_system"])   # romanized -> Bangla
        self.assertIn("Length budget", seen["extra_system"])
        self.assertFalse(seen["web"])


class WebRuleTests(SimpleTestCase):
    def test_time_word_alone_never_opens_web_search(self):
        for t in ("আজ মনটা খুব খারাপ", "What should I cook today?", "Remind me today at 5",
                  "today I feel sad", "আজ কী রান্না করব?"):
            self.assertFalse(ALS.needs_web(t), t)
        for t in ("আজকের সোনার দাম কত?", "ajker dollar rate koto?", "What is the weather in Dhaka today?",
                  "latest iPhone price in Bangladesh", "আজকের খবর কী?", "বাংলাদেশ-ভারত ম্যাচের স্কোর কত?",
                  "Who won the 2026 world cup?"):
            self.assertTrue(ALS.needs_web(t), t)


class LanguageAndTopicTests(SimpleTestCase):
    def test_romanized_questions_the_old_list_missed(self):
        for t in ("bus ta kon route e jabe?", "claude ai kmn?", "ajker dollar rate koto?",
                  "mudi dokan er jonno ekta hisab rakhar upay bolo",
                  "biye barite ki gift deya jay 2000 takar moddhe", "ghore boshe online income er upay"):
            self.assertEqual(AP.reply_lang(t, "en"), "bn", t)
        for t in ("What is the weather today?", "Take the bus to Jay's house",
                  "Is Ta Prohm worth a visit?", "Which AI is best for coding?"):
            self.assertEqual(AP.reply_lang(t, "bn"), "en", t)

    def test_romanized_consult_topics(self):
        self.assertEqual(AC.topic_of("pressure high hole ki khabo na"), "medical")
        self.assertEqual(AC.topic_of("jomir dolil haray gele ki korbo"), "legal")
        self.assertEqual(AC.topic_of("bari vara barle ki korbo, aine ki ase"), "legal")
        self.assertEqual(AC.topic_of("I ain't sure what to cook"), "")
        self.assertEqual(AC.topic_of("notun phone e ki ki app lagbe"), "")


class PostProcessTests(TestCase):
    def test_cut_answer_never_mid_word_and_no_dangling_heading(self):
        self.assertEqual(VC.end_at_sentence("ভূমিকা।\n\n## তৃতীয় মাস\n১. ফেসবুক লা"), "ভূমিকা।")
        t = "শুরু। " + "এটি একটি খুব লম্বা অনুচ্ছেদ যেখানে কোনো দাঁড়ি নেই " * 6 + "আর লে"
        out = VC.end_at_sentence(t)
        self.assertTrue(out == "শুরু।" or out.endswith("…"), out)
        self.assertEqual(VC.end_at_sentence("No end at all here but cu"), "No end at all here but …")

    def test_tables_become_lists(self):
        out = VC.tables_to_lists("তুলনা:\n| বিষয় | bKash | Nagad |\n|---|---|---|\n| খরচ | 1.85% | 1.49% |\nশেষ।")
        self.assertNotIn("|", out)
        self.assertIn("- **খরচ** — bKash: 1.85%; Nagad: 1.49%", out)

    def test_bangla_digits_but_not_phones_products_or_english(self):
        out = VC.bangla_digits("বিকাশে ৳500 পাঠান, সকাল 9:00টায়। iPhone 15 ভালো। ফোন 01711223344। ৯৯৯।")
        self.assertIn("৳৫০০", out)
        self.assertIn("৯:০০টায়", out)
        self.assertIn("iPhone 15", out)
        self.assertIn("01711223344", out)
        en = "Dear Sir, I cannot come on 12 May. ধন্যবাদ"
        self.assertEqual(VC.bangla_digits(en), en)

    def test_finish_reply_runs_every_step(self):
        raw = ("সারাংশ: ৳500 লাগবে।\n| ক | খ |\n|---|---|\n| ১ | ২ |\nThere is a memory item here.\n"
               "ACTION: {\"type\": \"note\", \"title\": \"x\"}")
        reply, prop, cut, _n = VC.finish_reply(raw, "x", "bn")
        self.assertEqual(prop, {"type": "note", "title": "x"})
        self.assertNotIn("|", reply)
        self.assertNotIn("memory item", reply)
        self.assertNotIn("500", reply)
        self.assertFalse(cut)


class GradeTests(SimpleTestCase):
    def _c(self, **e):
        return {"id": "t", "cat": "x", "prompt": "p", "history": [], "expect": e}

    def test_continue_must_exist_and_not_repeat(self):
        c = self._c(answer_lang="en", min_chars=10)
        first = "This is the first full sentence of the plan."
        self.assertIn("continue_missing", AE.grade(c, first, {"cut": True})["fails"])
        g = AE.grade(c, first, {"cut": True, "continued": first + " Then finish it."})
        self.assertIn("continue_repeats", g["fails"])
        self.assertTrue(AE.grade(c, first, {"cut": True, "continued": "Step two follows now."})["ok"])

    def test_tables_ascii_digits_web_gemini_credits(self):
        bn = self._c(answer_lang="bn", min_chars=5)
        self.assertIn("table", AE.grade(bn, "তুলনা।\n| ক | খ |\n|---|---|\n| গ | ঘ |\nশেষ।")["fails"])
        self.assertIn("ascii_digits", AE.grade(bn, "দাম ৳500 টাকা।")["fails"])
        self.assertTrue(AE.grade(bn, "দাম ৳৫০০ টাকা।")["ok"])
        self.assertIn("unasked_web_search", AE.grade(bn, "ঠিক আছে।", {"web_asked": True})["fails"])
        self.assertIn("gemini_while_off", AE.grade(bn, "ঠিক আছে।",
                                                   {"gemini_off": True, "provider": "gemini"})["fails"])
        self.assertIn("credits_mismatch", AE.grade(bn, "ঠিক আছে।",
                                                   {"credits_shown": 4, "charged": 1})["fails"])
        self.assertIn("continue_charged", AE.grade(bn, "ঠিক আছে।", {"cont_charged": 1})["fails"])

    def test_admin_words_do_not_flag_ordinary_owners(self):
        en = self._c(answer_lang="en")
        self.assertTrue(AE.grade(en, "Ask the owner of the shop for a receipt.")["ok"])
        self.assertIn("admin_words", AE.grade(en, "The owner hasn't added the API key.")["fails"])


def tearDownModule():
    cache.clear()
