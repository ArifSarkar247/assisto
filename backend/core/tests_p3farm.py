"""p3farm: Farmer mode per-crop calendar + symptom data — pure tests.

The Dart mirror (app/lib/widgets/farmer_crop_data.dart) is parsed so the
app and the server can never drift apart (lock-step)."""
import os
import re

from django.test import SimpleTestCase

from core.logic import farmer_mode as FM

_DART = os.path.join(os.path.dirname(__file__), "..", "..", "app", "lib",
                     "widgets", "farmer_crop_data.dart")


def _dart_plans():
    if not os.path.exists(_DART):
        return None
    src = open(_DART, encoding="utf-8").read()
    rx = re.compile(r"CropPlan\('(\w+)', \[([\d, ]*)\], \[([\d, ]*)\], \[([\d, ]*)\], '(\w+)'\)")

    def ints(s):
        return tuple(int(x) for x in s.replace(" ", "").split(",") if x)
    return [(c, ints(a), ints(b), ints(h), s) for c, a, b, h, s in rx.findall(src)]


class P3FarmCalendarTests(SimpleTestCase):
    def test_major_crops_present(self):
        crops = {c[0] for c in FM.MAJOR_CROPS}
        for need in ("aman_rice", "boro_rice", "aus_rice", "jute", "potato",
                     "winter_veg", "summer_veg"):
            self.assertIn(need, crops)

    def test_months_valid_and_sourced(self):
        for crop, sow, tp, harvest, src in FM.MAJOR_CROPS:
            self.assertTrue(sow and harvest, crop)
            for m in sow + tp + harvest:
                self.assertTrue(1 <= m <= 12, crop)
            self.assertIn(src, FM.SOURCE_URLS)
            self.assertTrue(FM.SOURCE_URLS[src].startswith("https://")
                            and ".gov.bd" in FM.SOURCE_URLS[src])

    def test_known_seasons(self):
        nov = {r["crop"]: r["jobs"] for r in FM.crop_jobs(11)}
        self.assertEqual(nov["aman_rice"], ["harvest"])
        self.assertEqual(nov["boro_rice"], ["sow"])
        self.assertIn("potato", nov)
        jul = {r["crop"]: r["jobs"] for r in FM.crop_jobs(7)}
        self.assertEqual(jul["aman_rice"], ["sow", "transplant"])
        self.assertIn("harvest", jul["aus_rice"])

    def test_bad_month(self):
        self.assertEqual(FM.crop_jobs(13), [])
        self.assertEqual(FM.crop_jobs("x"), [])
        self.assertEqual(FM.crop_jobs(None), [])

    def test_call_centre(self):
        self.assertEqual(FM.KRISHI_CALL_CENTRE, "16123")

    def test_dart_mirror_lockstep(self):
        plans = _dart_plans()
        if plans is None:
            self.skipTest("app tree not present")
        self.assertEqual(plans, [tuple(c) for c in FM.MAJOR_CROPS])

    def test_dart_never_gives_doses(self):
        if not os.path.exists(_DART):
            self.skipTest("app tree not present")
        src = open(_DART, encoding="utf-8").read().lower()
        for bad in ("ml/", "g/litre", "per litre", "dose:"):
            self.assertNotIn(bad, src)
