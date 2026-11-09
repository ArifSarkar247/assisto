"""Unit tests for the Language Partner content pipeline (CI: python -m unittest discover -s tools/lp/tests)."""
import copy
import glob
import json
import os
import sys
import tempfile
import unittest

LP = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, LP)
sys.path.insert(0, os.path.join(LP, "tts"))

import lpcheck  # noqa: E402
import plan as ttsplan  # noqa: E402
import render_visuals  # noqa: E402
import export_bundle  # noqa: E402

BUNDLES = sorted(glob.glob(os.path.join(LP, "content", "ielts", "ielts-*-[0-9][0-9][0-9].json")))


def check_one(b, name="ielts-ac-001.json"):
    """Run every per-bundle check on an in-memory bundle."""
    r = lpcheck.Result(os.path.join(LP, "content", "ielts", name))
    for fn in (lpcheck.check_format, lpcheck.check_listening_structure, lpcheck.check_answers,
               lpcheck.check_timing_and_level, lpcheck.check_visuals, lpcheck.check_internal_duplicates):
        fn(b, r)
    lpcheck.check_copyright(b, r, lpcheck.load_known())
    return r


class Helpers(unittest.TestCase):
    def test_answer_counts(self):
        self.assertEqual(lpcheck.answer_counts("£45"), (0, 1))
        self.assertEqual(lpcheck.answer_counts("car park"), (2, 0))
        self.assertEqual(lpcheck.answer_counts("7.30 pm"), (1, 1))
        self.assertEqual(lpcheck.answer_counts("2,500"), (0, 1))

    def test_limit_text(self):
        self.assertEqual(lpcheck.parse_limit_text("Write ONE WORD ONLY for each answer."), (1, False))
        self.assertEqual(lpcheck.parse_limit_text("Write ONE WORD AND/OR A NUMBER for each answer."), (1, True))
        self.assertEqual(lpcheck.parse_limit_text("Write NO MORE THAN TWO WORDS AND/OR A NUMBER."), (2, True))
        self.assertEqual(lpcheck.parse_limit_text("Choose NO MORE THAN THREE WORDS from the passage"), (3, False))

    def test_norm(self):
        self.assertEqual(lpcheck.norm_answer(" Car-Park. "), "car park")
        self.assertIn(lpcheck.norm_text("don't go"), lpcheck.norm_text("I said: Don’t go!"))

    def test_fingerprint_blocks_known_text(self):
        known = lpcheck.load_known()
        self.assertGreater(len(known), 100)
        txt = ("Some say it is a truth universally acknowledged, that a single man in possession "
               "of a good fortune, must be in want of a wife.")
        hits = [s for s in lpcheck.shingles(txt) if lpcheck.shingle_hash(s) in known]
        self.assertTrue(hits)
        own = "Vertical farms stack growing trays under coloured lights inside disused warehouses."
        self.assertFalse([s for s in lpcheck.shingles(own) if lpcheck.shingle_hash(s) in known])

    def test_writing_boilerplate_exempt(self):
        a = lpcheck.writing_topic_key("Some people think X. To what extent do you agree or disagree? "
                                      "Give reasons for your answer and include any relevant examples "
                                      "from your own knowledge or experience. Write at least 250 words.")
        self.assertTrue(a.startswith("some people think x"))
        self.assertNotIn("250", a)


class BandTables(unittest.TestCase):
    def test_tables_cover_0_to_40_and_match_official_anchors(self):
        d = json.load(open(os.path.join(LP, "content", "ielts", "band_tables.json"), encoding="utf-8"))
        self.assertIn("ielts.org", d["source"]["url"])
        anchors = {"listening": [(16, 5), (23, 6), (30, 7), (35, 8)],
                   "reading_academic": [(15, 5), (23, 6), (30, 7), (35, 8)],
                   "reading_general": [(15, 4), (23, 5), (30, 6), (35, 7)]}
        for k, an in anchors.items():
            rows = d[k]
            cov = sorted(v for r in rows for v in range(r["min"], r["max"] + 1))
            self.assertEqual(cov, list(range(41)), k)
            for raw, band in an:
                self.assertEqual([r["band"] for r in rows if r["min"] <= raw <= r["max"]], [band])
            bands = [r["band"] for r in sorted(rows, key=lambda r: r["min"])]
            self.assertEqual(bands, sorted(bands), f"{k} must be monotonic")


@unittest.skipUnless(BUNDLES, "no bundles yet")
class Bundles(unittest.TestCase):
    def setUp(self):
        self.path = BUNDLES[0]
        self.b = json.load(open(self.path, encoding="utf-8"))
        self.name = os.path.basename(self.path)

    def test_real_bundle_passes(self):
        r = check_one(copy.deepcopy(self.b), self.name)
        self.assertEqual(r.errors, [])

    def _first(self, sec, types):
        for p in self.b[sec]["parts"]:
            for g in p["groups"]:
                if g["type"] in types:
                    return g
        self.skipTest(f"no {types} group")

    def test_detects_answer_outside_word_limit(self):
        g = self._first("listening", lpcheck.COMPLETION)
        g["questions"][0]["accept"] = ["one two three four five"]
        self.assertTrue(any("word_limit" in e for e in check_one(self.b, self.name).errors))

    def test_detects_fake_evidence(self):
        g = self._first("reading", lpcheck.COMPLETION | set(lpcheck.TFNG))
        q = next(q for q in g["questions"] if q.get("evidence"))
        q["evidence"] = "this sentence never appears anywhere in the passage at all"
        self.assertTrue(any("evidence not found" in e for e in check_one(self.b, self.name).errors))

    def test_detects_bad_option_key(self):
        g = self._first("listening", lpcheck.OPTION_SINGLE)
        g["questions"][0]["answer"] = "Z"
        self.assertTrue(any("not an option" in e or "not in options" in e
                            for e in check_one(self.b, self.name).errors))

    def test_detects_missing_question(self):
        self.b["reading"]["parts"][2]["groups"][-1]["questions"].pop()
        self.assertTrue(any("[format]" in e for e in check_one(self.b, self.name).errors))

    def test_detects_copyrighted_text(self):
        tx = self.b["reading"]["parts"][0]["texts"][0]["paragraphs"][0]
        tx["text"] += (" It was the best of times, it was the worst of times, it was the age of "
                       "wisdom, it was the age of foolishness.")
        self.assertTrue(any("[copyright]" in e for e in check_one(self.b, self.name).errors))

    def test_detects_banned_marker(self):
        self.b["writing"]["tasks"][1]["prompt"] += " Taken from Cambridge IELTS 99."
        self.assertTrue(any("banned marker" in e for e in check_one(self.b, self.name).errors))

    def test_detects_missing_bangla(self):
        g = self._first("reading", lpcheck.ALL_TYPES)
        g["questions"][0]["explain_bn"] = "english only"
        self.assertTrue(any("[bilingual]" in e for e in check_one(self.b, self.name).errors))

    def test_detects_cross_bundle_copy(self):
        other = copy.deepcopy(self.b)
        results = {"a": lpcheck.Result("a"), "b": lpcheck.Result("b")}
        lpcheck.check_cross_duplicates(results, {"a": self.b, "b": other})
        self.assertTrue(any("[duplicates]" in e for e in results["a"].errors))

    def test_tts_plan_structure(self):
        plan = ttsplan.build([self.path])
        self.assertEqual(len(plan["files"]), 4)
        for f in plan["files"]:
            cues = [i for i in f["items"] if i["kind"] == "cue"]
            self.assertGreaterEqual(len(cues), 1)
            texts = [plan["clips"][i["clip"]]["text"] for i in f["items"] if i["kind"] == "speech"]
            self.assertTrue(texts[-1].startswith("That is the end of Part"))
            voices = {(v["engine"], v["voice"]) for v in f["speakers"].values()}
            self.assertEqual(len(voices), len(f["speakers"]), "distinct voice per speaker")
            self.assertNotIn(("kokoro", "bm_george"), voices, "narrator voice reserved")
        for c in plan["clips"].values():
            if c["engine"] == "melo":
                self.assertIn("fallback", c)

    def test_export_shape(self):
        with tempfile.TemporaryDirectory() as td:
            idx = {"bundles": [{"bundle_id": self.b["bundle_id"], "checks_passed": True,
                                "file": os.path.relpath(self.path, os.path.dirname(os.path.dirname(LP)))}]}
            ip = os.path.join(td, "index.json")
            json.dump(idx, open(ip, "w"))
            export_bundle.main(["--index", ip, "--out", os.path.join(td, "o")])
            d = json.load(open(os.path.join(td, "o", "bundle.json"), encoding="utf-8"))
            self.assertEqual(d["schema"], 1)
            mock = d["items"][0]
            self.assertEqual(mock["kind"], "mock")
            L = mock["data"]["listening"]
            R = mock["data"]["reading"]
            self.assertEqual(L["duration_sec"], 1800)
            self.assertEqual(R["duration_sec"], 3600)
            self.assertEqual(sum(len(p["questions"]) for p in L["parts"]), 40)
            self.assertEqual(sum(len(p["questions"]) for p in R["passages"]), 40)
            for p in L["parts"]:
                self.assertIn(p["accent"], ("uk", "us", "au"))
                self.assertTrue(p["transcript"] and p["audio"].startswith("audio/"))
            for p in L["parts"] + R["passages"]:
                for q in p["questions"]:
                    self.assertTrue(q["tag"] and q["explain_bn"] and q["answer"])
            self.assertEqual(sum(1 for i in d["items"] if i["kind"] == "question"), 80)

    def test_render_visuals(self):
        with tempfile.TemporaryDirectory() as td:
            render_visuals.main(["--out", td, self.path])
            for fn in os.listdir(td):
                self.assertTrue(open(os.path.join(td, fn)).read().startswith("<svg"))


if __name__ == "__main__":
    unittest.main()
