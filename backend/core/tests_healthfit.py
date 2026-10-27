"""healthfit (owner decision 27 Oct): the health & fitness features stay SHOWN
in Play as Health and Fitness — never medical. These tests guard the server
side of that promise:

* every AI call carries the health-safety rule (no medical advice, no
  diagnosis / treatment / therapy / dose, see a doctor, 999 if unsafe);
* the Owner Admin feature labels and the DoD-audit reasons for the four
  features carry no medical claims;
* the in-app privacy policy, health disclaimer and Data-safety summary, and
  the website privacy policy, describe the health & fitness data honestly
  (read-only Health Connect, stays on the phone, never sold / used for ads);
* the website permission table lists only the four Health Connect reads
  (ACTIVITY_RECOGNITION removed — least privilege).
"""
import re
from unittest import mock

from django.test import SimpleTestCase, TestCase

from core import ai, feature_audit, feature_flags, legal
from web import legal_content as LC

FEATURES = ("wellness", "fitness", "smartwatch", "voice_mood")

# Medical-claim words that must never describe these features (en + bn).
# The disclaimer itself ("not medical advice" / "চিকিৎসা-পরামর্শ নয়") is
# allowed and stripped before scanning.
BANNED_EN = re.compile(
    r"\b(diagnos\w*|treat(?:ment|ments|s|ing)?|therap\w*|cure[sd]?|dos(?:e|es|age)|"
    r"disease\w*|clinical\w*|doctor-approved|mental[- ]health|depression|anxiety|"
    r"disorder\w*|prescri\w*|medication\w*|symptom\w*|counsell?ing)\b", re.I)
BANNED_BN = re.compile(
    r"রোগ|চিকিৎসা|থেরাপি|ডোজ|মাত্রা|ওষুধ|মানসিক স্বাস্থ্য|বিষণ্ণতা|উদ্বেগ|নিরাময়|"
    r"প্রেসক্রিপশন|উপসর্গ|লক্ষণ|কাউন্সেলিং")
ALLOWED = re.compile(
    r"not (?:a )?medical advice|no medical advice|চিকিৎসা-পরামর্শ নয়|চিকিৎসা পরামর্শ নয়")


def medical_claims(text):
    """Return the banned words found in [text] (after the allowed disclaimer
    phrases are removed)."""
    t = ALLOWED.sub(" ", text)
    return BANNED_EN.findall(t) + BANNED_BN.findall(t)


class HealthSafetyRuleTests(TestCase):
    def test_rule_text(self):
        r = ai.HEALTH_SAFETY_RULE
        for needle in ("no medical advice", "Never diagnose", "treatment",
                       "therapy", "dose", "doctor", "999"):
            self.assertIn(needle, r, needle)

    def test_every_ai_call_carries_the_rule(self):
        seen = {}

        def fake(key, model, system, prompt, max_tokens, history=None):
            seen["system"] = system
            return "ok", 1, 1

        with mock.patch.object(ai, "_providers", return_value=[("anthropic", "k")]), \
                mock.patch.object(ai, "_today_spend", return_value=0), \
                mock.patch.object(ai, "_user_over_limit", return_value=False), \
                mock.patch.object(ai, "_call_anthropic", side_effect=fake):
            try:
                ai.generate("Answer the user.", data="How much water should I drink?",
                            extra_system="Fitness question.")
            except Exception:  # spend logging etc. is not under test here
                pass
        self.assertIn("system", seen)
        self.assertTrue(seen["system"].startswith(ai._INJECTION_GUARD))
        self.assertIn(ai.HEALTH_SAFETY_RULE, seen["system"])
        self.assertIn("Fitness question.", seen["system"])


class FeatureWordingTests(SimpleTestCase):
    def test_labels_have_no_medical_claims(self):
        for key, _grp, en, bn, *_ in feature_flags.REGISTRY:
            if key in FEATURES:
                self.assertEqual(medical_claims(en + " " + bn), [], key)

    def test_mood_is_a_journal(self):
        row = [r for r in feature_flags.REGISTRY if r[0] == "voice_mood"][0]
        self.assertIn("journal", row[2])

    def test_audit_proposes_show(self):
        for key in FEATURES:
            a = feature_audit.AUDIT[key]
            self.assertEqual(a["play"], "show", key)
            self.assertIn("owner decision 27 oct", a["reason_en"].lower(), key)


class LegalHealthFitnessTests(SimpleTestCase):
    def test_in_app_privacy_has_health_fitness_section(self):
        for lang, heading, needles in (
                ("en", "Health and fitness",
                 ("not medical advice", "only read steps", "never sell")),
                ("bn", "স্বাস্থ্য ও ফিটনেস",
                 ("চিকিৎসা-পরামর্শ নয়", "বিক্রি করি না"))):
            _title, sections = legal._privacy(lang)
            sec = [s for s in sections if s["heading"] == heading]
            self.assertEqual(len(sec), 1, lang)
            for n in needles:
                self.assertIn(n, sec[0]["body"], (lang, n))

    def test_data_safety_mentions_health_and_fitness(self):
        _t, sections = legal._data_safety("en")
        body = " ".join(s["body"] for s in sections
                        if s["heading"].startswith("Health and fitness"))
        self.assertIn("not collected", body)
        self.assertIn("not shared", body)

    def test_health_disclaimer_covers_fitness_and_999(self):
        _t, sections = legal._health_disclaimer("en")
        body = " ".join(s["body"] for s in sections)
        self.assertIn("Mood and energy journal", body)
        self.assertIn("999", body)

    def test_web_permission_table_least_privilege(self):
        health = [p for p in LC.PERMISSIONS if p["id"] == "health"][0]
        perms = {x.strip() for x in health["perm"].split(",")}
        self.assertEqual(perms, {"health.READ_STEPS", "health.READ_HEART_RATE",
                                 "health.READ_SLEEP",
                                 "health.READ_ACTIVE_CALORIES_BURNED"})
        self.assertNotIn("ACTIVITY_RECOGNITION", " ".join(p["perm"] for p in LC.PERMISSIONS))


class WebPrivacyHealthTests(TestCase):
    def test_privacy_page_health_section(self):
        for lang, needles in (
                ("en", ("Health and fitness features", "not medical advice",
                        "Limited Use", "never use it for ads", "call 999")),
                ("bn", ("স্বাস্থ্য ও ফিটনেস ফিচার", "চিকিৎসা-পরামর্শ নয়",
                        "বিক্রি করি না", "৯৯৯"))):
            html = self.client.get("/privacy?lang=%s" % lang).content.decode()
            self.assertIn('id="health_fitness"', html, lang)
            for n in needles:
                self.assertIn(n, html, (lang, n))
