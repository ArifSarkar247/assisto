"""lpaudio: render plans (stdlib only, no TTS) — run in lp-audio.yml before rendering."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import render  # noqa: E402

A = render.A
CONTENT = os.path.join(render.ROOT, "tools", "lp", "content")


class PlanTests(unittest.TestCase):
    def setUp(self):
        self.plans = render.all_plans(CONTENT)

    def test_every_mock_part_has_a_plan(self):
        self.assertGreaterEqual(len(self.plans), 12)
        self.assertEqual(len({p["file"] for p in self.plans}), len(self.plans))

    def test_speakers_get_distinct_voices_never_the_narrator(self):
        for p in self.plans:
            vs = [v["voice"] for v in p["voices"]]
            self.assertEqual(len(vs), len(set(vs)), p["file"])
            self.assertNotIn(A.NARRATOR, vs, p["file"])
            for v in vs:
                self.assertIn(v[:1], ("a", "b"))

    def test_conversations_are_multi_voice(self):
        multi = [p for p in self.plans if len(p["voices"]) >= 2]
        self.assertGreaterEqual(len(multi), 6)
        for p in multi:
            used = {s["voice"] for s in p["segments"]}
            self.assertGreaterEqual(len(used), 3, p["file"])  # narrator + 2 speakers

    def test_accents_are_honest(self):
        for p in self.plans:
            self.assertTrue(set(p["accents"]) <= {"en-GB", "en-US"}, p["file"])

    def test_deterministic(self):
        again = render.all_plans(CONTENT)
        self.assertEqual([p["hash"] for p in again], [p["hash"] for p in self.plans])

    def test_last_part_has_final_check_time(self):
        by = {}
        for p in self.plans:
            by.setdefault(p["bundle"], []).append(p)
        for ps in by.values():
            self.assertEqual(ps[-1]["check_sec"], A.FINAL_CHECK_SEC)
            self.assertIn("end of the listening test", ps[-1]["segments"][-1]["text"])

    def test_speakable(self):
        self.assertEqual(A.speakable("B-R-E-N-N-I-C-K."), "B, R, E, N, N, I, C, K.")
        self.assertEqual(A.speakable("in 1862."), "in eighteen sixty-two.")
        self.assertEqual(A.speakable("the 1920s"), "the nineteen twenties")
        self.assertEqual(A.speakable("22 pounds"), "22 pounds")


if __name__ == "__main__":
    unittest.main()
