"""langmulti — Language Partner packs 4-8 in the owner's order: Arabic (work
Arabic for the Gulf), German, French, Spanish, Chinese. Data-only packs in the
p2lang format (core/data/langpacks/<code>.json); these tests add the checks the
framework validator does not make: strict bn+en on every learner string (with
Bangla digits), question text/options in both languages, all five abroad
scenarios, every level reachable by placement, no fake listening (items without
licensed audio are reading items), honest exam-format wording, and grading +
certificate seam end to end."""
import json
import os
import re

from django.test import SimpleTestCase

from core.logic import langpacks as LP

MINE = ("ar", "de", "fr", "es", "zh")          # owner order for this branch
_BN = re.compile(r"[ঀ-৿]")
_TAG = re.compile(r"\b(?:[ABC][12]|HSK ?[1-6]|W[1-3])\b")
_OFFICIAL = re.compile(r"official (score|result|certificate)(?! — not| -)|guaranteed|certified by", re.I)


def _mine():
    return [c for c in MINE if os.path.exists(os.path.join(LP.PACK_DIR, c + ".json"))]


def _raw(code):
    with open(os.path.join(LP.PACK_DIR, code + ".json"), encoding="utf-8") as f:
        return json.load(f)


def _bn_ok(s):
    head = str(s).split("\n")[0]       # after the newline: target-language stimulus
    return bool(_BN.search(head)) and not re.search(r"[0-9]", _TAG.sub("", head))


def _questions(p):
    yield from p["placement"]["questions"]
    for m in p["mock"]:
        for s in m["sections"]:
            yield from s.get("questions") or []


class Packs(SimpleTestCase):
    def test_owner_order(self):
        have = _mine()
        self.assertIn("ar", have)
        self.assertEqual(have, list(MINE[:len(have)]))  # never a later one before an earlier one

    def test_valid_and_available(self):
        cat = {c["code"]: c for c in LP.catalog()}
        for code in _mine():
            with self.subTest(code=code):
                LP.validate(_raw(code))
                self.assertTrue(cat[code]["available"])
                self.assertEqual(cat[code]["counts"]["scenarios"], 5)
                self.assertGreaterEqual(cat[code]["counts"]["lessons"], 8)
                self.assertGreaterEqual(cat[code]["counts"]["pron"], 10)

    def test_strict_bangla_everywhere(self):
        def walk(o, path):
            if isinstance(o, dict):
                for k, v in o.items():
                    if k in ("bn",) or k.endswith("_bn"):
                        for s in (v if isinstance(v, list) else [v]):
                            self.assertTrue(_bn_ok(s), f"{path}.{k}: {str(s)[:50]}")
                    else:
                        walk(v, f"{path}.{k}")
            elif isinstance(o, list):
                for i, v in enumerate(o):
                    walk(v, f"{path}[{i}]")
        for code in _mine():
            walk(_raw(code), code)

    def test_questions_in_both_languages(self):
        for code in _mine():
            for q in _questions(_raw(code)):
                with self.subTest(code=code, q=q["id"]):
                    self.assertTrue(q["text_bn"] and q["text_en"])
                    if "options_bn" in q:
                        self.assertEqual(len(q["options_bn"]), len(q["options"]))
                        self.assertEqual(q["options_en"], q["options"])

    def test_every_level_reachable_by_placement(self):
        for code in _mine():
            p = _raw(code)
            lv = [l["id"] for l in p["levels"]]
            self.assertEqual(sorted({q["level"] for q in p["placement"]["questions"]}), sorted(lv), code)
            top = LP.grade_placement(p, {q["id"]: q["answer"] for q in p["placement"]["questions"]})
            self.assertEqual(top["level"], lv[-1])
            low = LP.grade_placement(p, {})
            self.assertEqual(low["level"], lv[0])
            self.assertTrue(low["estimate"])

    def test_no_fake_listening(self):
        # no licensed recordings -> no listening section; items written for the
        # phone voice are graded as reading until the framework plays tts_text
        for code in _mine():
            for m in _raw(code)["mock"]:
                self.assertNotIn("listening", [s["skill"] for s in m["sections"]])
            for q in _questions(_raw(code)):
                if q.get("tts_text"):
                    self.assertEqual(q["skill"], "reading")

    def test_mock_shape_and_grading(self):
        for code in _mine():
            p = _raw(code)
            for m in p["mock"]:
                skills = {s["skill"] for s in m["sections"]}
                self.assertTrue({"reading", "writing", "speaking"} <= skills, code)
                fmt = m["format_en"].lower()
                self.assertTrue("format" in fmt or "skills check" in fmt, code)
                answers = {q["id"]: q["answer"] for s in m["sections"] for q in s.get("questions") or []}
                g = LP.grade_mock(p, m["id"], answers, texts={})
                self.assertEqual(g["score_pct"], 100)
                self.assertEqual(g["level"], m["bands"][-1]["level"])
                self.assertIn("writing", g["weak"])   # empty writing is a weak area
                self.assertTrue(g["estimate"])

    def test_honest_wording(self):
        for code in _mine():
            raw = json.dumps(_raw(code), ensure_ascii=False)
            self.assertIsNone(_OFFICIAL.search(raw), code)

    def test_certificate_seam(self):
        for code in _mine():
            p = _raw(code)
            r = LP.course_result(code, p["levels"][1]["id"], 72, "2026-11-08")
            self.assertTrue(r["estimate"])
            self.assertEqual(r["lang"], code)


class Arabic(SimpleTestCase):
    def setUp(self):
        self.p = _raw("ar")

    def test_script_first_and_rtl(self):
        self.assertTrue(self.p["rtl"])
        self.assertEqual(self.p["stt_locale"], "ar-SA")
        self.assertEqual([l["id"] for l in self.p["lessons"][:3]], ["ar-s1", "ar-s2", "ar-s3"])
        letters = "".join(i["target"] for l in self.p["lessons"][:3] for i in l["items"])
        for ch in "ابتثجحخدذرزسشصضطظعغفقكلمنهوي":
            self.assertIn(ch, letters)

    def test_gulf_work_tracks(self):
        titles = " ".join(l["title_en"].lower() for l in self.p["lessons"])
        for w in ("driver", "housekeeping", "construction", "shops", "doctor", "salary"):
            self.assertIn(w, titles)
        work = next(s for s in self.p["scenarios"] if s["id"] == "workplace")
        self.assertTrue(any("جوازي" in u["target"] for u in work["useful"]))  # passport phrase

    def test_no_exam_claim(self):
        self.assertEqual(self.p["level_system"], "Work Arabic")
        self.assertIn("no", self.p["mock"][0]["format_en"].lower())
