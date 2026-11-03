"""quranread (owner order 3 Nov 11:45, part B): Learn to read Quran.

The feature is app-side (offline lessons, bundled Tanzil text). The server's
part is the switch: it must exist, stay OFF by default until a qualified Qari
reviews the lessons, map to its route, and carry an honest audit row.
"""
from django.test import TestCase

from core import feature_audit as FA
from core import feature_flags as FF


class QuranLearnFlagTests(TestCase):
    def setUp(self):
        FF.invalidate()

    def tearDown(self):
        FF.invalidate()

    def test_flag_registered_off_and_routed(self):
        m = FF.meta("quran_learn")
        self.assertFalse(m["default_on"])
        self.assertEqual(FF.ROUTE_FEATURE.get("quran_learn"), "quran_learn")
        feats, _ = FF.resolve(None, play=True)
        self.assertFalse(feats["quran_learn"])

    def test_audit_is_honest(self):
        a = FA.AUDIT["quran_learn"]
        self.assertEqual(a["play"], "hide")
        self.assertIn("EXPERIMENTAL", a["reason_en"])
        self.assertIn("NO audio", a["reason_en"])
        self.assertNotEqual(a["codes"], "P" * 9)
