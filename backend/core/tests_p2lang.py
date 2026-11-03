"""p2lang — IELTS practice (Language Partner, flag language_packs).

Engine: alignment vectors (shared with app/test/ielts_engine_test.dart),
streak, writing/speaking checklists, content honesty (original, bn+en,
estimate label). API: flag off -> 403, key-free checklist, AI estimate parsed
and labelled, credits / no-key states, reading grade, per-user collections.
"""
import json
from unittest import mock

from django.contrib.auth import get_user_model
from django.test import SimpleTestCase, TestCase
from rest_framework.test import APIClient

from core import ai
from core.logic import ielts as IE

User = get_user_model()
V = "/api/v1"

# (target, heard, statuses, score) — the Dart mirror pins the SAME vectors.
ALIGN_VECTORS = [
    ("Students start school in spring.", "students start is school spring",
     ["ok", "ok", "ok", "miss", "ok"], 80),
    ("We visited a very wide valley.", "we visited a berry wide valley",
     ["ok", "ok", "ok", "sub", "ok", "ok"], 83),
    ("I think three things are worth it.", "",
     ["miss"] * 7, 0),
    ("Please sit on this seat.", "please seat on this sit",
     ["ok", "sub", "ok", "ok", "sub"], 60),
    ("a b c", "x y z w", ["sub", "sub", "sub"], 0),
    ("She works and lives in two cities.", "She works and lives in two cities",
     ["ok"] * 7, 100),
]


class EngineTests(SimpleTestCase):
    def test_alignment_vectors(self):
        for target, heard, statuses, score in ALIGN_VECTORS:
            rows, sc = IE.align_words(target, heard)
            self.assertEqual([r["status"] for r in rows], statuses, target)
            self.assertEqual(sc, score, target)

    def test_alignment_empty_target(self):
        self.assertEqual(IE.align_words("", "hello"), ([], 0))

    def test_alignment_curly_apostrophe(self):
        rows, sc = IE.align_words("It’s fine", "it's fine")
        self.assertEqual(sc, 100)

    def test_streak(self):
        self.assertEqual(IE.streak([], 100), {"current": 0, "best": 0, "today_done": False})
        self.assertEqual(IE.streak([98, 99, 100], 100)["current"], 3)
        self.assertTrue(IE.streak([98, 99, 100], 100)["today_done"])
        # yesterday still counts (the learner has today to keep it)
        self.assertEqual(IE.streak([97, 98, 99], 100)["current"], 3)
        # a missed day breaks it, best remembers the old run
        s = IE.streak([90, 91, 92, 93, 97], 100)
        self.assertEqual((s["current"], s["best"]), (0, 4))
        self.assertEqual(IE.streak([99, 99, 100], 100)["current"], 2)

    def test_writing_short_essay_fails_length(self):
        c = IE.writing_check("t2", "I don't agree. Online study is bad.")
        items = {i["id"]: i for i in c["items"]}
        self.assertFalse(items["length"]["ok"])
        self.assertEqual(c["min_words"], 250)
        self.assertFalse(items["formal"]["ok"])
        self.assertTrue(c["estimate"])
        for i in c["items"]:
            self.assertTrue(i["en"] and i["bn"])

    def test_writing_good_letter_passes_structure(self):
        body = ("Dear Mr Rahman,\n\nI am writing because the music from your flat has been "
                "very loud late at night. However, I understand that you enjoy it.\n\n"
                "As a result, I have not been able to sleep well and I am tired at work. "
                "Moreover, my children wake up frequently.\n\nTherefore, could you please "
                "keep the volume low after ten o'clock? Yours sincerely, Karim")
        c = IE.writing_check("t1", body)
        items = {i["id"]: i for i in c["items"]}
        self.assertTrue(items["greeting"]["ok"])
        self.assertTrue(items["paragraphs"]["ok"])
        self.assertTrue(items["linkers"]["ok"])
        self.assertFalse(items["length"]["ok"])  # still under 150 words

    def test_speaking_metrics(self):
        t = "um well I think uh my home town is quite peaceful you know " * 4
        c = IE.speaking_check(t, 30, 0.82)
        self.assertEqual(c["wpm"], round(c["word_count"] * 60 / 30))
        self.assertEqual(c["fillers"], 12)
        self.assertEqual(c["confidence"], 82)
        self.assertIn("clarity", [i["id"] for i in c["items"]])
        # too short to measure pace; no confidence from the phone -> no clarity row
        c2 = IE.speaking_check("hello there", 2, None)
        self.assertEqual(c2["wpm"], 0)
        self.assertNotIn("clarity", [i["id"] for i in c2["items"]])

    def test_content_is_bilingual_and_original(self):
        c = IE.content()
        blob = json.dumps(c).lower()
        for banned in ("cambridge", "copyright"):
            self.assertNotIn(banned, blob)
        for p in c["reading"]:
            self.assertGreaterEqual(len(p["questions"]), 5)
            for q in p["questions"]:
                self.assertTrue(q["bn"] and q["en"])
                if q["type"] == "tfng":
                    self.assertIn(q["answer"], ("true", "false", "notgiven"))
                else:
                    self.assertLess(int(q["answer"]), len(q["options"]))
        for s in c["pron"]:
            self.assertTrue(s["tip_bn"] and s["tip_en"])
        self.assertGreaterEqual(len(c["vocab"]), 30)
        self.assertEqual(len({v["id"] for v in c["vocab"]}), len(c["vocab"]))
        self.assertIn("not an official", c["estimate_label"]["en"])
        self.assertTrue(all(l["url"].startswith("https://") for l in c["official_links"]))

    def test_grade_reading(self):
        g = IE.grade_reading("r_forget", {"q1": "false", "q2": "false"})
        self.assertEqual(g["total"], 5)
        self.assertEqual(g["correct"], 1)
        self.assertIsNone(IE.grade_reading("nope", {}))


def _user(n):
    return User.objects.create_user(name="Learner %d" % n, phone="+88017110000%02d" % n,
                                    password="pw12345!")


def _client(u):
    c = APIClient()
    c.force_authenticate(u)
    return c


_AI_JSON = json.dumps({
    "criteria": [
        {"id": "task", "band": 6.3, "en": "Covers the task.", "bn": "কাজটা করেছেন।"},
        {"id": "coherence", "band": 6, "en": "Clear order.", "bn": "পরিষ্কার ক্রম।"},
        {"id": "lexical", "band": 5.5, "en": "Some repetition.", "bn": "কিছু পুনরাবৃত্তি।"},
        {"id": "grammar", "band": 12, "en": "x", "bn": "x"},
        {"id": "made_up", "band": 9, "en": "x", "bn": "x"},
    ],
    "overall": 6, "fixes": [{"en": "Use 'however' once.", "bn": "however একবার।"}]})

_ESSAY = ("Some people believe online study works. However, I think classrooms help. "
          "Therefore students should mix both.")


@mock.patch("core.ielts_views.flag_on", return_value=True)
class ApiTests(TestCase):
    def setUp(self):
        self.u = _user(1)
        self.c = _client(self.u)

    def test_flag_off_403(self, _f):
        with mock.patch("core.ielts_views.flag_on", return_value=False):
            r = self.c.get(V + "/ielts/content")
            self.assertEqual(r.status_code, 403)
            self.assertEqual(r.json()["reason"], "feature_off")
            r = self.c.post(V + "/ielts/writing/check",
                            {"task": "t2", "prompt_id": "t2_online", "text": _ESSAY}, format="json")
            self.assertEqual(r.status_code, 403)

    def test_anonymous_refused(self, _f):
        self.assertIn(APIClient().get(V + "/ielts/content").status_code, (401, 403))

    def test_content(self, _f):
        with mock.patch.object(ai, "available", return_value=False):
            r = self.c.get(V + "/ielts/content")
        self.assertEqual(r.status_code, 200)
        j = r.json()
        self.assertFalse(j["ai_ready"])
        self.assertTrue(j["speaking"]["p2"][0]["bullets"])

    def test_writing_keyfree(self, _f):
        r = self.c.post(V + "/ielts/writing/check",
                        {"task": "t2", "prompt_id": "t2_online", "text": _ESSAY}, format="json")
        self.assertEqual(r.status_code, 200)
        j = r.json()
        self.assertEqual(j["ai_state"], "not_asked")
        self.assertEqual(j["check"]["kind"], "checklist")
        self.assertIn("not an official", j["estimate_label"]["en"])

    def test_writing_bad_inputs(self, _f):
        for body, reason in (({"task": "t9", "prompt_id": "x", "text": "a"}, "bad_task"),
                             ({"task": "t2", "prompt_id": "x", "text": "a"}, "bad_prompt"),
                             ({"task": "t2", "prompt_id": "t2_online", "text": " "}, "empty"),
                             ({"task": "t2", "prompt_id": "t2_online", "text": "a " * 4000},
                              "too_long")):
            r = self.c.post(V + "/ielts/writing/check", body, format="json")
            self.assertEqual(r.status_code, 400)
            self.assertEqual(r.json()["reason"], reason)

    def test_writing_ai_no_key(self, _f):
        with mock.patch.object(ai, "available", return_value=False):
            r = self.c.post(V + "/ielts/writing/check",
                            {"task": "t2", "prompt_id": "t2_online", "text": _ESSAY,
                             "use_ai": True}, format="json")
        j = r.json()
        self.assertEqual(j["ai_state"], "no_key")
        self.assertIsNone(j["ai"])
        self.assertEqual(j["check"]["kind"], "checklist")   # still useful

    def test_writing_ai_estimate_parsed_and_clamped(self, _f):
        def fake_generate(**kw):
            self.assertIs(kw["user"], self.u)      # credits charged to the learner
            self.assertEqual(kw["feature"], "ielts.writing")
            kw["out_meta"]["charged"] = 3
            return (_AI_JSON, 0.01)
        with mock.patch.object(ai, "available", return_value=True), \
                mock.patch.object(ai, "generate", side_effect=fake_generate):
            r = self.c.post(V + "/ielts/writing/check",
                            {"task": "t2", "prompt_id": "t2_online", "text": _ESSAY,
                             "use_ai": True}, format="json")
        j = r.json()
        self.assertEqual(j["ai_state"], "used")
        self.assertEqual(j["credits_charged"], 3)
        crit = {c["id"]: c for c in j["ai"]["criteria"]}
        self.assertEqual(set(crit), {"task", "coherence", "lexical", "grammar"})
        self.assertEqual(crit["task"]["band"], 6.5)      # half-band steps
        self.assertIsNone(crit["grammar"]["band"])       # out of range dropped
        self.assertTrue(j["ai"]["estimate"])

    def test_writing_ai_out_of_credits(self, _f):
        with mock.patch.object(ai, "available", return_value=True), \
                mock.patch.object(ai, "generate", side_effect=ai.AIUnavailable("credits")):
            r = self.c.post(V + "/ielts/writing/check",
                            {"task": "t1", "prompt_id": "t1_course", "text": _ESSAY,
                             "use_ai": True}, format="json")
        self.assertEqual(r.json()["ai_state"], "credits")

    def test_writing_ai_unreadable(self, _f):
        with mock.patch.object(ai, "available", return_value=True), \
                mock.patch.object(ai, "generate", return_value=("Sorry, no JSON", 0.0)):
            r = self.c.post(V + "/ielts/writing/check",
                            {"task": "t2", "prompt_id": "t2_cities", "text": _ESSAY,
                             "use_ai": True}, format="json")
        self.assertEqual(r.json()["ai_state"], "unreadable")

    def test_speaking_keyfree_and_ai(self, _f):
        body = {"part": "p2", "prompt_id": "p2_skill",
                "transcript": "I learned to swim in the pond near my house " * 5,
                "seconds": 40, "confidence": 0.9}
        r = self.c.post(V + "/ielts/speaking/check", body, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["check"]["confidence"], 90)
        sp = json.dumps({"criteria": [
            {"id": "fluency", "band": 6, "en": "ok", "bn": "ঠিক"},
            {"id": "pronunciation", "band": None, "en": "Use the pronunciation check.",
             "bn": "উচ্চারণ যাচাই ব্যবহার করুন।"}], "overall": 6, "fixes": []})
        with mock.patch.object(ai, "available", return_value=True), \
                mock.patch.object(ai, "generate", return_value=(sp, 0.0)):
            r = self.c.post(V + "/ielts/speaking/check", dict(body, use_ai=True), format="json")
        crit = {c["id"]: c for c in r.json()["ai"]["criteria"]}
        self.assertIsNone(crit["pronunciation"]["band"])

    def test_speaking_bad_prompt(self, _f):
        r = self.c.post(V + "/ielts/speaking/check",
                        {"part": "p1", "prompt_id": "p2_skill", "transcript": "hi"},
                        format="json")
        self.assertEqual(r.json()["reason"], "bad_prompt")

    def test_reading_grade(self, _f):
        r = self.c.post(V + "/ielts/reading/grade",
                        {"passage_id": "r_mobilemoney",
                         "answers": {"q1": "false", "q2": "2", "q3": "false",
                                     "q4": "notgiven", "q5": "true"}},
                        HTTP_ACCEPT_LANGUAGE="en", format="json")
        j = r.json()
        self.assertEqual((j["correct"], j["total"]), (5, 5))
        self.assertTrue(j["rows"][0]["en"])
        r = self.c.post(V + "/ielts/reading/grade", {"passage_id": "r_x", "answers": {}},
                        format="json")
        self.assertEqual(r.status_code, 400)

    def test_practice_collections_are_per_user(self, _f):
        r = self.c.post(V + "/ielts/practice/", {"day": 20000, "kind": "pron", "score": 80},
                        format="json")
        self.assertIn(r.status_code, (200, 201))
        self.assertEqual(len(self.c.get(V + "/ielts/practice/").json()), 1)
        other = _client(_user(2))
        self.assertEqual(other.get(V + "/ielts/practice/").json(), [])
        r = other.post(V + "/ielts/vocab/", {"card_id": "v_benefit", "box": 2}, format="json")
        self.assertIn(r.status_code, (200, 201))


# ======================================================================
# Language Partner framework (owner design 3 Nov 11:45): 8 languages, packs.
# ======================================================================
import copy
import glob
import os

from core import learn_views as LV
from core.logic import langpacks as LP
from core.logic import pricing as PR


class PackFilesTests(SimpleTestCase):
    """Every pack file in core/data/langpacks validates (other agents' packs too)."""

    def test_every_pack_file_is_valid(self):
        files = glob.glob(os.path.join(LP.PACK_DIR, "*.json"))
        self.assertTrue(files)
        for f in files:
            with self.subTest(pack=os.path.basename(f)):
                with open(f, encoding="utf-8") as fh:
                    p = LP.validate(json.load(fh))
                self.assertEqual(os.path.basename(f), p["lang"] + ".json")

    def test_owner_order_and_exam_names(self):
        self.assertEqual(LP.CODES, ("en", "ko", "ja", "ar", "de", "fr", "es", "zh"))
        by = {l["code"]: l for l in LP.LANGUAGES}
        self.assertIn("EPS-TOPIK", by["ko"]["exams_en"])
        self.assertIn("JFT-Basic", by["ja"]["exams_en"])
        self.assertIn("HSK", by["zh"]["exams_en"])
        self.assertEqual(by["ko"]["purpose"], "work_korea")
        for l in LP.LANGUAGES:
            self.assertFalse(any(c.isdigit() and c.isascii() for c in l["exams_bn"]), l["code"])

    def test_catalog_states(self):
        cat = LP.catalog()
        self.assertEqual([c["code"] for c in cat], list(LP.CODES))
        en = cat[0]
        self.assertTrue(en["available"])
        self.assertGreaterEqual(en["counts"]["lessons"], 5)
        self.assertEqual(en["counts"]["scenarios"], 5)


class FrameworkLogicTests(SimpleTestCase):
    def setUp(self):
        self.p = LP.load("en")

    def test_validator_refuses_bad_packs(self):
        bad = copy.deepcopy(self.p)
        bad["placement"]["questions"][0]["answer"] = 99
        with self.assertRaises(LP.PackError):
            LP.validate(bad)
        bad = copy.deepcopy(self.p)
        bad["lessons"][0]["items"][0]["note_en"] = "Copyright 2020 Cambridge"
        with self.assertRaises(LP.PackError):
            LP.validate(bad)
        bad = copy.deepcopy(self.p)
        bad["mock"][0]["sections"].append({"id": "l", "skill": "listening", "questions": [
            dict(bad["placement"]["questions"][0], skill="listening")]})
        with self.assertRaises(LP.PackError):   # listening without licensed audio
            LP.validate(bad)

    def test_public_pack_hides_keys_and_ai_role(self):
        pub = json.dumps(LP.public_pack(self.p))
        self.assertNotIn('"answer"', pub)
        self.assertNotIn("explain_bn", pub)
        self.assertNotIn("ai_role", pub)

    def test_placement(self):
        qs = self.p["placement"]["questions"]
        all_right = {q["id"]: q["answer"] for q in qs}
        self.assertEqual(LP.grade_placement(self.p, all_right)["level"], "C1")
        self.assertEqual(LP.grade_placement(self.p, {})["level"], "A1")
        upto_b1 = {q["id"]: q["answer"] for q in qs if q["level"] in ("A1", "A2", "B1")}
        g = LP.grade_placement(self.p, upto_b1)
        self.assertEqual(g["level"], "B1")
        self.assertTrue(g["estimate"])

    def test_mock(self):
        m = LP.mock_test(self.p, "ielts_style_1")
        qs = m["sections"][0]["questions"]
        g = LP.grade_mock(self.p, "ielts_style_1", {q["id"]: q["answer"] for q in qs},
                          {"w1": "word " * 260}, seconds=60)
        self.assertEqual((g["score_pct"], g["level"], g["weak"]), (100, "C1", []))
        g = LP.grade_mock(self.p, "ielts_style_1", {}, {"w1": "too short"}, seconds=99999)
        self.assertEqual(g["level"], "A2")
        self.assertIn("writing", g["weak"])
        self.assertTrue(g["timed_out"])
        self.assertIsNone(LP.grade_mock(self.p, "nope", {}))

    def test_course_result_seam(self):
        r = LP.course_result("en", "B1", 72, "2026-11-03")
        self.assertEqual((r["level"], r["score"], r["level_system"]), ("B1", 72, "CEFR"))
        self.assertIn("not an official", r["label"]["en"])
        for bad in (("xx", "B1", 1, "2026-11-03"), ("en", "Z9", 1, "2026-11-03"),
                    ("en", "B1", 101, "2026-11-03"), ("en", "B1", 1, "3 Nov")):
            with self.assertRaises(LP.PackError):
                LP.course_result(*bad)

    def test_ai_actions_hold_the_40_percent_rule(self):
        cfg = PR.DEFAULTS()
        for action in ("ai_msg_cheap", "ai_msg_medium"):
            self.assertGreaterEqual(PR.credit_cost(action, cfg), PR.action_credit_floor(action, cfg),
                                    action)
        self.assertLess(LP.ai_allowance("free"), LP.ai_allowance("premium"))


@mock.patch("core.learn_views.flag_on", return_value=True)
class LearnApiTests(TestCase):
    def setUp(self):
        self.u = _user(11)
        self.c = _client(self.u)

    def test_flag_off(self, _f):
        with mock.patch("core.learn_views.flag_on", return_value=False):
            self.assertEqual(self.c.get(V + "/learn/catalog").status_code, 403)
            # my own results are never hidden by the switch
            self.assertEqual(self.c.get(V + "/learn/results").status_code, 200)

    def test_catalog_and_pack(self, _f):
        j = self.c.get(V + "/learn/catalog").json()
        self.assertEqual(len(j["languages"]), 8)
        self.assertEqual(j["ai_left_today"], LP.FREE_AI_PER_DAY)
        with mock.patch.object(ai, "available", return_value=False):
            p = self.c.get(V + "/learn/pack/en").json()
        self.assertFalse(p["ai_ready"])
        self.assertNotIn("answer", p["placement"]["questions"][0])
        self.assertEqual(self.c.get(V + "/learn/pack/ko").status_code, 404)

    def test_placement_and_mock_store_results_for_the_certificate(self, _f):
        qs = LP.load("en")["placement"]["questions"]
        r = self.c.post(V + "/learn/en/placement",
                        {"answers": {q["id"]: q["answer"] for q in qs}}, format="json")
        self.assertEqual(r.json()["level"], "C1")
        self.assertEqual(self.c.post(V + "/learn/en/placement", {"answers": {}},
                                     format="json").status_code, 400)
        r = self.c.post(V + "/learn/en/mock", {"mock_id": "pte_style_1", "answers": {"q1": 1},
                                               "texts": {"s1": "Mobile money lets people send cash quickly."},
                                               "seconds": 300}, format="json")
        self.assertEqual(r.status_code, 200)
        res = self.c.get(V + "/learn/results").json()["results"]
        self.assertEqual([x["kind"] for x in res], ["mock", "placement"])
        self.assertEqual(LV.results_for(self.u)[1]["level"], "C1")
        self.assertEqual(_client(_user(12)).get(V + "/learn/results").json()["results"], [])

    def test_roleplay_free_quota_then_credits(self, _f):
        calls = []

        def fake_generate(**kw):
            calls.append(kw["user"])
            if kw["user"] is not None:
                kw["out_meta"]["charged"] = 1
            return (json.dumps({"reply": "How long will you stay?", "fix_en": "", "fix_bn": ""}), 0.0)
        body = {"scenario_id": "airport", "message": "I am here for work.", "history": []}
        with mock.patch.object(ai, "available", return_value=True), \
                mock.patch.object(ai, "generate", side_effect=fake_generate):
            for _ in range(LP.FREE_AI_PER_DAY):
                j = self.c.post(V + "/learn/en/roleplay", body, format="json").json()
                self.assertTrue(j["free"])
            j = self.c.post(V + "/learn/en/roleplay", body, format="json").json()
        self.assertFalse(j["free"])
        self.assertEqual(j["credits_charged"], 1)
        self.assertEqual(j["reply"], "How long will you stay?")
        self.assertEqual(calls[:LP.FREE_AI_PER_DAY], [None] * LP.FREE_AI_PER_DAY)
        self.assertIs(calls[-1], self.u)

    def test_roleplay_states(self, _f):
        body = {"scenario_id": "airport", "message": "hello"}
        with mock.patch.object(ai, "available", return_value=False):
            self.assertEqual(self.c.post(V + "/learn/en/roleplay", body, format="json")
                             .json()["ai_state"], "no_key")
        with mock.patch.object(ai, "available", return_value=True), \
                mock.patch.object(ai, "generate", side_effect=ai.AIUnavailable("credits")):
            self.assertEqual(self.c.post(V + "/learn/en/roleplay", body, format="json")
                             .json()["ai_state"], "credits")
        self.assertEqual(self.c.post(V + "/learn/en/roleplay", {"scenario_id": "moon", "message": "x"},
                                     format="json").json()["reason"], "bad_scenario")
