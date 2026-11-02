"""Play listing pack gate (owner order 3 Nov): owner_actions/PLAY_LISTING_PACK
text stays inside every Play limit and the banned-words list
(tools/play_pack/check_listing.py), and never claims a feature the website
shows as "Coming soon"."""
import importlib.util
from pathlib import Path

from django.test import SimpleTestCase

from web import site_v3

ROOT = Path(__file__).resolve().parents[2]


def _checker():
    spec = importlib.util.spec_from_file_location("check_listing", ROOT / "tools" / "play_pack" / "check_listing.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class PlayListingPackTests(SimpleTestCase):
    def test_every_limit_and_banned_word(self):
        self.assertEqual(_checker().check_all(), [])

    def test_medicine_list_covers_website_list(self):
        c = _checker()
        for w in site_v3.MEDICINE_WORDS:
            self.assertIn(w, c.MEDICINE)

    def test_checker_catches_bad_text(self):
        c = _checker()
        self.assertTrue(c._hits("The best app, like WhatsApp", "en-US"))
        self.assertTrue(c._hits("৳449 per month", "en-US"))
        self.assertTrue(c._hits("সেরা অ্যাপ", "bn-BD"))
        self.assertTrue(c._hits("Destination alarm", "en-US"))

    def test_screenshots_are_live_website_features(self):
        """every screenshot slot names a feature the website lists, and its
        shot is a real CI gallery shot the website already uses"""
        import json
        spec = json.loads((ROOT / "owner_actions" / "PLAY_LISTING_PACK" / "screenshots.json").read_text("utf-8"))
        feats = {f["id"]: f for g in site_v3.FEATURES.values() for f in g}
        for s in spec["slots"]:
            self.assertIn(s["feature"], feats, s)
            self.assertFalse(feats[s["feature"]]["soon"], s)
            self.assertIn(s["shot"], site_v3.shot_names(), s)
