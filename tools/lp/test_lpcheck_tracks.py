"""Unit tests for lpcheck_tracks.py (stdlib unittest; CI only)."""
import copy
import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lpcheck_tracks as lt  # noqa: E402


def _first(lang, prefix):
    d = os.path.join(lt.CONTENT_DIR, lang)
    names = sorted(n for n in os.listdir(d) if n.startswith(prefix)) if os.path.isdir(d) else []
    return os.path.join(d, names[0]) if names else None


class TrackCheckTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def _run(self, lang, name, doc):
        os.makedirs(os.path.join(self.tmp, lang), exist_ok=True)
        p = os.path.join(self.tmp, lang, name)
        with open(p, "w", encoding="utf-8") as f:
            json.dump(doc, f, ensure_ascii=False)
        res, _ = lt.run([p])
        return res[p]

    def _test_doc(self, lang, prefix):
        p = _first(lang, prefix)
        if not p:
            self.skipTest(f"no {prefix} content yet")
        with open(p, encoding="utf-8") as f:
            return os.path.basename(p), json.load(f)

    def test_repo_tests_pass_in_isolation(self):
        for lang, prefix in (("ja", "jlpt-n5-"), ("ja", "jft-basic-"), ("ko", "eps-topik-"), ("de", "de-a1-")):
            name, d = self._test_doc(lang, prefix)
            r = self._run(lang, name, d)
            self.assertEqual(r.errors, [], f"{name}: {r.errors[:5]}")

    def _first_q(self, d):
        for s in d["sections"]:
            for p in s.get("parts", []):
                if p.get("questions"):
                    return p["questions"][0]

    def test_bad_answer_letter(self):
        name, d = self._test_doc("ko", "eps-topik-")
        self._first_q(d)["answer"] = "E"
        r = self._run("ko", name, d)
        self.assertTrue(any("[answer]" in e for e in r.errors))

    def test_duplicate_options(self):
        name, d = self._test_doc("ja", "jlpt-n5-")
        q = self._first_q(d)
        q["options"][1] = q["options"][0]
        r = self._run("ja", name, d)
        self.assertTrue(any("not distinct" in e for e in r.errors))

    def test_wrong_question_count(self):
        name, d = self._test_doc("de", "de-a1-")
        d["sections"][0]["parts"][0]["questions"].pop()
        r = self._run("de", name, d)
        self.assertTrue(any("format needs" in e for e in r.errors))

    def test_practice_label_required(self):
        name, d = self._test_doc("de", "de-a1-")
        d["practice_label"] = {"en": "Official result", "bn": "ফল"}
        d["title"]["en"] = "Official A1 exam"
        r = self._run("de", name, d)
        self.assertTrue(any("[label]" in e for e in r.errors))

    def test_banned_marker_and_bangla_in_target(self):
        name, d = self._test_doc("ja", "jft-basic-")
        q = self._first_q(d)
        q["prompt"] = "みんなの日本語 " + str(q.get("prompt", ""))
        q["options"][0] = "আমি"
        r = self._run("ja", name, d)
        self.assertTrue(any("[copyright]" in e for e in r.errors))

    def test_listening_needs_script(self):
        name, d = self._test_doc("ko", "eps-topik-")
        lq = d["sections"][1]["parts"][0]["questions"][0]
        lq.pop("script", None)
        r = self._run("ko", name, d)
        self.assertTrue(any("needs script" in e for e in r.errors))

    def test_explain_bn_must_be_bangla(self):
        name, d = self._test_doc("de", "de-a1-")
        self._first_q(d)["explain_bn"] = "because"
        r = self._run("de", name, d)
        self.assertTrue(any("[bilingual]" in e for e in r.errors))

    def test_cross_test_copy_is_error(self):
        name, d = self._test_doc("ko", "eps-topik-")
        d2 = copy.deepcopy(d)
        d2["bundle_id"] = "eps-topik-999"
        os.makedirs(os.path.join(self.tmp, "ko"), exist_ok=True)
        paths = []
        for n, doc in ((name, d), ("eps-topik-999.json", d2)):
            p = os.path.join(self.tmp, "ko", n)
            with open(p, "w", encoding="utf-8") as f:
                json.dump(doc, f, ensure_ascii=False)
            paths.append(p)
        res, _ = lt.run(paths)
        self.assertTrue(any("[duplicates]" in e for e in res[paths[1]].errors))

    def test_lessons_minimums(self):
        p = _first("ja", "lessons-")
        if not p:
            self.skipTest("no lessons yet")
        with open(p, encoding="utf-8") as f:
            d = json.load(f)
        d["lessons"][0]["vocab"] = d["lessons"][0]["vocab"][:2]
        d["lessons"][0]["practice"]["speaking"] = []
        r = self._run("ja", os.path.basename(p), d)
        self.assertTrue(any("need >= 6" in e for e in r.errors))
        self.assertTrue(any("practice.speaking" in e for e in r.errors))


if __name__ == "__main__":
    unittest.main()
