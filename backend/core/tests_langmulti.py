"""langmulti — Language Partner packs 4-8 (Arabic for Gulf work, German,
French, Spanish, Chinese). Pure-data tests: every pack validates (structure,
bn+en, Bangla digits, estimate label, levels covered, mock sections + timing),
per-language normalisation/alignment, checklists and the ladder estimate."""
from django.test import SimpleTestCase

from core.logic import langmulti_packs as LP

BANNED = ("goethe-institut logo", "official delf", "official dele", "official hsk",
          "certified by", "guaranteed score", "official score")


class PackValidity(SimpleTestCase):
    def test_packs_present_in_owner_order(self):
        have = LP.codes()
        self.assertIn("ar", have)
        # owner order: never ship a later language while an earlier one is missing
        self.assertEqual(have, list(LP.ORDER[:len(have)]))

    def test_every_pack_validates(self):
        for code in LP.codes():
            with self.subTest(code=code):
                self.assertEqual(LP.validate(LP.load(code)), [])

    def test_no_official_claims(self):
        for code in LP.codes():
            raw = str(LP.load(code)).lower()
            for b in BANNED:
                self.assertNotIn(b, raw, f"{code}: {b}")

    def test_unknown_code(self):
        self.assertIsNone(LP.load("xx"))
        self.assertIsNone(LP.load("../secrets"))

    def test_validator_catches_problems(self):
        p = LP.load("ar")
        p["estimate_label"] = {"en": "Your score", "bn": "স্কোর"}
        p["placement"][0]["answer"] = 9
        p["scenarios"] = [s for s in p["scenarios"] if s["place"] != "doctor"]
        p["lessons"][0]["title"]["bn"] = "Script 1"
        errs = " | ".join(LP.validate(p))
        self.assertIn("estimate label", errs)
        self.assertIn("bad options/answer", errs)
        self.assertIn("no scenario for doctor", errs)
        self.assertIn("bn has no Bangla", errs)


class Arabic(SimpleTestCase):
    def setUp(self):
        self.p = LP.load("ar")

    def test_script_first_and_gulf_work(self):
        self.assertEqual([l["kind"] for l in self.p["lessons"][:3]], ["script"] * 3)
        self.assertTrue(self.p["rtl"])
        self.assertIn("SA", self.p["probashi_link"]["countries"])
        titles = " ".join(l["title"]["en"].lower() for l in self.p["lessons"])
        for w in ("driver", "housekeeping", "construction", "salary"):
            self.assertIn(w, titles)

    def test_normalize_harakat_alef_digits(self):
        a = LP.normalize("أَنا ٥٧ مريضة", self.p)
        self.assertEqual(a, "انا 57 مريضه")

    def test_align_arabic(self):
        rows, score = LP.align("أبي جوازي لو سمحت", "ابي جوازي سمحت", self.p)
        self.assertEqual([r["status"] for r in rows], ["ok", "ok", "miss", "ok"])
        self.assertEqual(score, 75)

    def test_writing_checklist(self):
        task = self.p["mock"]["sections"][2]["items"][0]
        good = LP.check_list(task, "بنغلاديش ٠٥٠١٢٣٤٥٦٧", self.p)
        self.assertEqual(good["passed"], good["total"])
        bad = LP.check_list(task, "", self.p)
        self.assertLess(bad["passed"], bad["total"])
        self.assertTrue(bad["estimate"])


class Ladder(SimpleTestCase):
    def test_ladder_stops_at_first_failed_level(self):
        p = LP.load("ar")
        res = ([{"level": "W1", "skill": "reading", "ok": True}] * 4
               + [{"level": "W2", "skill": "listening", "ok": True},
                  {"level": "W2", "skill": "listening", "ok": False},
                  {"level": "W2", "skill": "listening", "ok": False}]
               + [{"level": "W3", "skill": "reading", "ok": True}] * 3)
        e = LP.estimate(p, res)
        self.assertEqual(e["level"], "W1")       # W3 perfect but W2 failed
        self.assertEqual(e["weak"], ["listening"])
        self.assertTrue(e["estimate"])
        self.assertIn("আনুমানিক", e["label"]["bn"])

    def test_below_first_level_and_empty(self):
        p = LP.load("ar")
        self.assertIsNone(LP.estimate(p, [{"level": "W1", "skill": "reading", "ok": False}])["level"])
        self.assertIsNone(LP.estimate(p, [])["level"])

    def test_grade_item(self):
        p = LP.load("ar")
        q = p["placement"][0]
        self.assertTrue(LP.grade_item(q, q["answer"], p))
        self.assertFalse(LP.grade_item(q, "x", p))
        self.assertIsNone(LP.grade_item({"type": "write"}, "", p))
