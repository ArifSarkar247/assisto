"""langkoja — Korean (EPS-TOPIK / TOPIK) + Japanese (JFT-Basic / JLPT) packs.

Pins: both packs validate through the framework; the exam FORMATS we show match
the official structure we researched (feature cards); everything is original
and labelled an estimate; grading gives sane levels; work paths only link to
official https sites; phone-voice listening is served without answer keys and
is never stored as a course result.
"""
import json
import re
from unittest import mock

from django.contrib.auth import get_user_model
from django.test import SimpleTestCase, TestCase
from rest_framework.test import APIClient

from core.logic import langpacks as LP
from core.logic import listen_tts as LT

User = get_user_model()
V = "/api/v1"
_ASCII_DIGIT = re.compile(r"[0-9]")
_HANGUL = re.compile(r"[가-힣]")
_KANA = re.compile(r"[぀-ヿ]")


def _bn_strings(o, key=None):
    if isinstance(o, dict):
        for k, v in o.items():
            yield from _bn_strings(v, k)
    elif isinstance(o, list):
        for v in o:
            yield from _bn_strings(v, key)
    elif isinstance(o, str) and key and (key == "bn" or key.endswith("_bn")):
        yield key, o


def _all_mcq(p):
    out = list(p["placement"]["questions"])
    for m in p["mock"]:
        for s in m["sections"]:
            out += s.get("questions") or []
    return out


class PackContentTests(SimpleTestCase):
    def setUp(self):
        self.ko = LP.load("ko")
        self.ja = LP.load("ja")

    def test_both_packs_load_and_are_listed_available(self):
        self.assertIsNotNone(self.ko)
        self.assertIsNotNone(self.ja)
        cat = {c["code"]: c for c in LP.catalog()}
        for code in ("ko", "ja"):
            self.assertTrue(cat[code]["available"], code)
            self.assertEqual(cat[code]["counts"]["scenarios"], 5)
            self.assertGreaterEqual(cat[code]["counts"]["lessons"], 15)
            self.assertGreaterEqual(cat[code]["counts"]["mock"], 3)
            self.assertGreaterEqual(cat[code]["counts"]["pron"], 10)

    def test_levels_cover_the_exam_ladders(self):
        self.assertEqual([l["id"] for l in self.ko["levels"]], ["0", "1", "2", "3", "4", "5", "6"])
        self.assertEqual([l["id"] for l in self.ja["levels"]], ["kana", "N5", "N4", "N3", "N2", "N1"])
        self.assertEqual(self.ko["stt_locale"], "ko-KR")
        self.assertEqual(self.ja["stt_locale"], "ja-JP")

    def test_script_comes_first_in_the_lesson_ladder(self):
        self.assertEqual(self.ko["lessons"][0]["level"], "0")
        self.assertIn("Hangul", self.ko["lessons"][0]["title_en"])
        self.assertIn("Hiragana", self.ja["lessons"][0]["title_en"])
        self.assertTrue(any("Katakana" in l["title_en"] for l in self.ja["lessons"] if l["level"] == "kana"))
        for p in (self.ko, self.ja):
            order = [l["id"] for l in p["levels"]]
            idx = [order.index(l["level"]) for l in p["lessons"]]
            self.assertEqual(idx, sorted(idx), "lessons go basic -> advanced")

    def test_placement_reaches_every_level(self):
        for p in (self.ko, self.ja):
            have = {q["level"] for q in p["placement"]["questions"]}
            self.assertEqual(have, {l["id"] for l in p["levels"][1:]})

    def test_eps_mock_matches_the_published_reading_format(self):
        eps = LP.mock_test(self.ko, "eps_style_1")
        qs = eps["sections"][0]["questions"]
        self.assertEqual(len(qs), 25)
        self.assertEqual(eps["minutes"], 40)
        self.assertTrue(all(len(q["options"]) == 4 for q in qs))
        self.assertIn("BOESL", eps["format_en"])
        self.assertIn("200", eps["format_en"])

    def test_jft_mock_has_the_official_section_names(self):
        jft = LP.mock_test(self.ja, "jft_style_1")
        names = [s["title_en"] for s in jft["sections"]]
        self.assertEqual(names[0].split(" (")[0], "Script and Vocabulary")
        self.assertEqual(names[1].split(" (")[0], "Conversation and Expression")
        self.assertEqual(names[2].split(" (")[0], "Reading Comprehension")
        self.assertTrue(all(len(s["questions"]) == 12 for s in jft["sections"]))
        self.assertIn("10-250", jft["format_en"])
        self.assertIn("200", jft["format_en"])

    def test_questions_are_in_the_target_language(self):
        for p, rx in ((self.ko, _HANGUL), (self.ja, _KANA)):
            for q in _all_mcq(p):
                self.assertTrue(rx.search(q["text"]), q["id"])

    def test_answers_are_spread_not_always_first(self):
        for p in (self.ko, self.ja):
            pos = {q["answer"] for q in _all_mcq(p)}
            self.assertEqual(pos, {0, 1, 2, 3})

    def test_unique_ids(self):
        for p in (self.ko, self.ja):
            ids = [q["id"] for q in _all_mcq(p)]
            self.assertEqual(len(ids), len(set(ids)))
            lids = [l["id"] for l in p["lessons"]]
            self.assertEqual(len(lids), len(set(lids)))

    def test_bangla_strings_use_bangla_digits(self):
        """bn text uses Bangla digits; a quoted Korean/Japanese example may keep its own."""
        for p in (self.ko, self.ja):
            for key, s in _bn_strings(p):
                if key == "explain_bn":
                    head = s.split("=")[0]
                    if _HANGUL.search(head) or re.search(r"[぀-ヿ一-鿿]", head):
                        continue
                self.assertIsNone(_ASCII_DIGIT.search(s), s)

    def test_scores_are_estimates_and_original(self):
        blob = json.dumps([self.ko, self.ja], ensure_ascii=False)
        self.assertNotRegex(blob.lower(), r"copyright|©|past paper")
        for p in (self.ko, self.ja):
            for m in p["mock"]:
                self.assertIn("original assisto practice", m["format_en"].lower())
                self.assertIn("Assisto", m["format_bn"])

    def test_perfect_and_empty_placement(self):
        for p, top, bottom in ((self.ko, "6", "0"), (self.ja, "N1", "kana")):
            qs = p["placement"]["questions"]
            g = LP.grade_placement(p, {q["id"]: q["answer"] for q in qs})
            self.assertEqual(g["level"], top)
            self.assertTrue(g["estimate"])
            g0 = LP.grade_placement(p, {})
            self.assertEqual(g0["level"], bottom)
            self.assertTrue(g0["weak"])

    def test_mock_bands(self):
        eps = LP.mock_test(self.ko, "eps_style_1")
        qs = eps["sections"][0]["questions"]
        full = LP.grade_mock(self.ko, "eps_style_1", {q["id"]: q["answer"] for q in qs})
        self.assertEqual(full["level"], "3")
        # ~40% = the usual 80/200 minimum line -> EPS work level "2"
        part = {q["id"]: q["answer"] for q in qs[:10]}
        self.assertEqual(LP.grade_mock(self.ko, "eps_style_1", part)["level"], "2")
        jft = LP.mock_test(self.ja, "jft_style_1")
        ans = {q["id"]: q["answer"] for s in jft["sections"] for q in s["questions"]}
        self.assertEqual(LP.grade_mock(self.ja, "jft_style_1", ans)["level"], "N4")
        g = LP.grade_mock(self.ja, "jft_style_1", {})
        self.assertEqual(g["level"], "kana")
        self.assertEqual(set(g["weak"]), {"vocab", "grammar", "reading"})

    def test_topik2_writing_is_word_counted(self):
        g = LP.grade_mock(self.ko, "topik2_style_1", {}, {"w1": "짧은 글이다."})
        w1 = next(o for o in g["open"] if o["id"] == "w1")
        self.assertFalse(w1["ok"])
        self.assertIn("writing", g["weak"])

    def test_public_pack_hides_keys_and_keeps_work_path(self):
        pub = LP.public_pack(self.ko)
        self.assertNotIn("answer", pub["placement"]["questions"][0])
        self.assertNotIn("ai_role", pub["scenarios"][0])
        self.assertIn("work_path", pub)

    def test_work_paths_link_only_official_https_sites(self):
        allowed = ("boesl.gov.bd", "eps.go.kr", "topik.go.kr", "jpf.go.jp", "jlpt.jp", "bmet.gov.bd")
        for p in (self.ko, self.ja):
            wp = p["work_path"]
            self.assertTrue(wp["title_en"] and wp["title_bn"])
            self.assertGreaterEqual(len(wp["steps"]), 4)
            for s in wp["steps"]:
                self.assertTrue(s["en"] and s["bn"])
            for l in wp["links"]:
                self.assertTrue(l["url"].startswith("https://"), l)
                host = l["url"].split("/")[2]
                self.assertTrue(any(host.endswith(a) for a in allowed), host)
        self.assertIn("BOESL", json.dumps(self.ko["work_path"]))
        self.assertIn("broker", json.dumps(self.ko["work_path"]))

    def test_scenarios_keep_ai_away_from_real_diagnosis(self):
        for p in (self.ko, self.ja):
            doc = next(s for s in p["scenarios"] if s["id"] == "doctor")
            self.assertIn("never give a real diagnosis", doc["ai_role"].lower())


class ListeningLogicTests(SimpleTestCase):
    def test_sets_load(self):
        for code, loc in (("ko", "ko-KR"), ("ja", "ja-JP")):
            d = LT.load(code)
            self.assertIsNotNone(d, code)
            self.assertEqual(d["tts_locale"], loc)
            self.assertGreaterEqual(len(d["questions"]), 10)

    def test_bad_codes(self):
        for c in ("xx", "../ko", "", None, "KO"):
            self.assertIsNone(LT.load(c))

    def test_validator_refuses_bad_sets(self):
        good = LT.load("ko")
        for mutate in (lambda d: d.update(format=2),
                       lambda d: d.update(tts_locale="korean"),
                       lambda d: d["questions"][0].update(answer=9),
                       lambda d: d["questions"][0].update(say=""),
                       lambda d: d["questions"][1].update(id=d["questions"][0]["id"]),
                       lambda d: d.update(label_bn="")):
            d = json.loads(json.dumps(good))
            mutate(d)
            with self.assertRaises(LT.ListenError):
                LT.validate(d)

    def test_public_hides_keys_and_grade(self):
        d = LT.load("ja")
        pub = LT.public(d)
        self.assertNotIn("answer", pub["questions"][0])
        self.assertIn("say", pub["questions"][0])
        g = LT.grade(d, {q["id"]: q["answer"] for q in d["questions"]})
        self.assertEqual(g["score_pct"], 100)
        g = LT.grade(d, {d["questions"][0]["id"]: "x"})
        self.assertEqual(g["answered"], 0)


def _user(n):
    return User.objects.create_user(name="Kolearner %d" % n, phone="+88017120000%02d" % n,
                                    password="pw12345!")


@mock.patch("core.learn_views.flag_on", return_value=True)
class ListeningApiTests(TestCase):
    def setUp(self):
        self.u = _user(1)
        self.c = APIClient()
        self.c.force_authenticate(self.u)

    def test_flag_off(self, _f):
        with mock.patch("core.learn_listen_views.flag_on", return_value=False):
            self.assertEqual(self.c.get(V + "/learn/ko/listening").status_code, 403)
            self.assertEqual(self.c.post(V + "/learn/ko/listening/grade", {"answers": {"kl1": 0}},
                                         format="json").status_code, 403)

    def test_anonymous_refused(self, _f):
        self.assertIn(APIClient().get(V + "/learn/ko/listening").status_code, (401, 403))

    def test_get_and_grade(self, _f):
        with mock.patch("core.learn_listen_views.flag_on", return_value=True):
            j = self.c.get(V + "/learn/ja/listening").json()
            self.assertEqual(j["tts_locale"], "ja-JP")
            self.assertNotIn("answer", j["questions"][0])
            self.assertIn("estimate_label", j)
            self.assertEqual(self.c.get(V + "/learn/en/listening").status_code, 404)
            d = LT.load("ja")
            r = self.c.post(V + "/learn/ja/listening/grade",
                            {"answers": {q["id"]: q["answer"] for q in d["questions"]}}, format="json")
            self.assertEqual(r.status_code, 200)
            self.assertEqual(r.json()["correct"], len(d["questions"]))
            self.assertEqual(self.c.post(V + "/learn/ja/listening/grade", {"answers": {}},
                                         format="json").status_code, 400)
            # practice only: no course result is stored from phone-voice listening
            self.assertEqual(self.c.get(V + "/learn/results").json()["results"], [])

    def test_korean_pack_endpoints(self, _f):
        p = self.c.get(V + "/learn/pack/ko").json()
        self.assertEqual(p["lang"], "ko")
        self.assertIn("work_path", p)
        qs = LP.load("ko")["placement"]["questions"]
        r = self.c.post(V + "/learn/ko/placement", {"answers": {q["id"]: q["answer"] for q in qs}},
                        format="json")
        self.assertEqual(r.json()["level"], "6")
        res = self.c.get(V + "/learn/results").json()["results"]
        self.assertEqual(res[0]["lang"], "ko")
        self.assertEqual(res[0]["level_system"], "TOPIK")
