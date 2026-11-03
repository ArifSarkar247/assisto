"""p2tools — Daily tools (flag `daily_tools`): the switch exists, is OFF by
default in BOTH registries, is honest in the DoD audit, and the app's tools
are offline (no new server route / no network call in the engine)."""
import re
from pathlib import Path

from django.test import TestCase

from core import feature_audit as FA
from core import feature_flags as FF

APP_LIB = Path(__file__).resolve().parents[2] / "app" / "lib"


class DailyToolsFlagTests(TestCase):
    def setUp(self):
        FF.invalidate()

    def tearDown(self):
        FF.invalidate()

    def test_flag_registered_off_by_default(self):
        m = FF.meta("daily_tools")
        self.assertFalse(m["default_on"])
        self.assertEqual(m["section"], "daily_life")
        feats, _ = FF.resolve(None, play=True)
        self.assertFalse(feats["daily_tools"])
        self.assertFalse(FF.resolve(None, play=False)[0]["daily_tools"])
        # the existing writing tools keep today's behaviour
        self.assertTrue(feats["quick_tools"])

    def test_dart_mirror_off_and_audit_not_done(self):
        src = (APP_LIB / "feature_registry.dart").read_text()
        self.assertRegex(src, r"(?m)^  'daily_tools': false,$")
        a = FA.AUDIT["daily_tools"]
        self.assertEqual(a["play"], "hide")
        self.assertIn("F", a["codes"])  # no owner real-phone proof yet

    def test_engine_is_offline(self):
        eng = (APP_LIB / "widgets" / "daily_tools_engine.dart").read_text()
        for bad in ("package:http", "dart:io", "ApiClient", "Uri.parse"):
            self.assertNotIn(bad, eng)
        # standard BD land / weight factors are the documented ones
        self.assertTrue(re.search(r"UnitDef\('katha', 720\)", eng))
        self.assertTrue(re.search(r"UnitDef\('bigha', 14400\)", eng))
        self.assertTrue(re.search(r"UnitDef\('bhori', 11\.664\)", eng))
