"""sjstart2 (owner Safe Journey V2): the free BD place list now carries the
official unions (BBS names, Bangla + English, placed inside their upazila)
and a hospital layer — built in GitHub Actions (bd-places workflow)."""
from django.test import SimpleTestCase

from core import bd_places as BP


class PlaceLayersTests(SimpleTestCase):
    def test_unions_and_hospitals_are_real_layers(self):
        self.assertTrue(BP.available())
        BP._load()
        by = {}
        for r in BP._rows:
            by[r[0]] = by.get(r[0], 0) + 1
        self.assertGreaterEqual(by.get("union", 0), 1000)
        self.assertGreaterEqual(by.get("hospital", 0), 1000)
        # nothing lost from the earlier list
        for k, n in (("district", 64), ("ghat", 100), ("metro", 10), ("station", 300)):
            self.assertGreaterEqual(by.get(k, 0), n, k)
        self.assertIn("BBS", BP.source())

    def test_every_row_is_inside_bangladesh(self):
        BP._load()
        for r in BP._rows:
            self.assertTrue(20.3 < r[4] < 26.8 and 88.0 < r[5] < 92.8, r[:3])

    def test_official_union_found_in_bangla_and_english(self):
        bn = BP.search("সুবিল", lang="bn")
        self.assertTrue(any(x["kind"] == "union" and x["name"] == "সুবিল" for x in bn), bn[:3])
        en = BP.search("Subil", lang="en")
        u = [x for x in en if x["kind"] == "union"]
        self.assertTrue(u, en[:3])
        self.assertEqual(u[0]["secondary"], "Cumilla")

    def test_hospital_search(self):
        r = BP.search("Dhaka Medical College Hospital", lang="en")
        self.assertEqual(r[0]["kind"], "hospital")
        self.assertAlmostEqual(r[0]["lat"], 23.725, delta=0.03)
