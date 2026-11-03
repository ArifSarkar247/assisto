"""e2eproof: the CI-only fakes behind .github/workflows/e2e.yml (backend/ci_e2e).

The fakes are never installed here (ci_e2e is not in settings_test); these
tests pin their deterministic answers and the "CI only" guard."""
import json
import os
import tempfile
from unittest import mock

from django.core.exceptions import ImproperlyConfigured
from django.test import SimpleTestCase, override_settings

from ci_e2e import fakes

TOOL = "Saving in the app ... ACTION: {\"type\": ...}"


class FakeAnswerTests(SimpleTestCase):
    def test_bangla_in_bangla_out_and_marked(self):
        a = fakes.answer_for("বাংলাদেশের রাজধানী কোথায়?", "", [], TOOL)
        self.assertIn("ঢাকা", a)
        self.assertIn("(CI)", a)
        self.assertTrue(fakes.BN.search(a))

    def test_follow_up_uses_history(self):
        h = [{"role": "user", "content": "বাংলাদেশের রাজধানী কোথায়?"},
             {"role": "assistant", "content": "বাংলাদেশের রাজধানী ঢাকা।"}]
        self.assertIn("আগের প্রশ্নটা মনে আছে", fakes.answer_for("সেখানে কত মানুষ থাকে?", "", h, TOOL))

    def test_photo_follow_up(self):
        p = "User's latest message: বৃত্তটা কোন রঙের?\n\nTheir data summary:\n[Photo shared earlier]: ছবিতে একটি লাল বৃত্ত"
        self.assertIn("ছবিতে যা দেখেছি", fakes.answer_for("বৃত্তটা কোন রঙের?", p, [], TOOL))

    def test_expense_action_line_valid(self):
        from core import ai_tools as AT
        a = fakes.answer_for("চায়ে ৫০ টাকা খরচ লিখে রাখো", "", [], TOOL)
        clean, prop = AT.extract(a)
        self.assertNotIn("ACTION", clean)
        self.assertEqual(prop["type"], "expense")
        self.assertEqual(str(prop["amount"]), "50.00")

    def test_reminder_action_line_valid(self):
        from core import ai_tools as AT
        _clean, prop = AT.extract(fakes.answer_for("৩ মিনিট পরে ওষুধ খাওয়ার কথা মনে করিয়ে দাও", "", [], TOOL))
        self.assertEqual(prop["type"], "reminder")
        self.assertEqual(prop["title"], "ওষুধ খাওয়া")

    def test_no_action_without_tool_rule(self):
        self.assertNotIn("ACTION:", fakes.answer_for("চায়ে ৫০ টাকা খরচ লিখে রাখো", "", [], ""))


class FakeSeamTests(SimpleTestCase):
    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(suffix=".jsonl", delete=False).name
        self.addCleanup(lambda: os.path.exists(self.tmp) and os.unlink(self.tmp))

    def test_places_chandra_and_outbox(self):
        with override_settings(E2E_OUTBOX=self.tmp):
            r = fakes.fake_maps_http("https://places.googleapis.com/v1/places:autocomplete",
                                     {"input": "Chandra"})
            self.assertEqual(r["suggestions"][0]["placePrediction"]["structuredFormat"]["mainText"]["text"],
                             "Chandra")
            d = fakes.fake_maps_http("https://places.googleapis.com/v1/places/ci_chandra_mor?x=1")
            self.assertAlmostEqual(d["location"]["latitude"], 24.0389)
            self.assertEqual(fakes.fake_maps_http("https://places.googleapis.com/v1/places:autocomplete",
                                                  {"input": "Xyz"})["suggestions"], [])
            rows = fakes.read_outbox(kind="maps")
        self.assertEqual(len(rows), 3)

    def test_sms_never_stores_the_code(self):
        with override_settings(E2E_OUTBOX=self.tmp):
            fakes.fake_send_sms("+8801700000001", "Code 135790", "signup", secret="135790")
            row = fakes.read_outbox(kind="sms")[0]
        self.assertNotIn("135790", json.dumps(row))
        self.assertEqual(row["to"], "0001")

    def test_push_recorded_per_user(self):
        u = mock.Mock(pk=7)
        with override_settings(E2E_OUTBOX=self.tmp):
            self.assertEqual(fakes.fake_push_to_user(u, "sos", "বিপদ", "SOS", data={"a": 1}), 1)
            self.assertEqual(fakes.read_outbox(kind="push", user_id=7)[0]["push_kind"], "sos")
            self.assertEqual(fakes.read_outbox(kind="push", user_id=8), [])


class GuardTests(SimpleTestCase):
    def test_refuses_outside_ci(self):
        from ci_e2e.apps import CiE2EConfig
        import ci_e2e
        cfg = CiE2EConfig("ci_e2e", ci_e2e)
        env = {k: v for k, v in os.environ.items() if k not in ("GITHUB_ACTIONS", "ASSISTO_E2E_LOCAL")}
        with mock.patch.dict(os.environ, env, clear=True), \
                mock.patch("ci_e2e.fakes.install") as inst:
            with self.assertRaises(ImproperlyConfigured):
                cfg.ready()
            inst.assert_not_called()
