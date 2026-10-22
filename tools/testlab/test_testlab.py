#!/usr/bin/env python3
"""tl1: dry-run tests for the Test Lab tooling (no credentials needed).

  python3 tools/testlab/test_testlab.py      (from the repo root)

Covers: the summary parser on a fixture of gcloud's --format=json outcome +
the run's stderr + per-device logcats; the device picker on a catalog
fixture (smoke = 3, brand round-robin, deprecated / wrong-ABI skipped,
virtual fill for uncovered API levels); the Robo script lint (incl. every
tl_* id existing in app/lib); and that testlab.yml parses with the inputs
and secrets the owner doc promises.
"""
import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
FIX = os.path.join(HERE, "fixtures")
sys.path.insert(0, HERE)

import pick_devices  # noqa: E402
import robo_lint  # noqa: E402
import summarize  # noqa: E402


def load(name):
    with open(os.path.join(FIX, name)) as f:
        return json.load(f)


class SummaryTest(unittest.TestCase):
    def setUp(self):
        self.md, self.rows = summarize.summarize(
            load("outcome_sample.json"),
            open(os.path.join(FIX, "run_stderr_sample.txt")).read(),
            load("catalog_sample.json"),
            os.path.join(FIX, "results"),
            "physical")
        self.by = {r["model"]: r for r in self.rows}

    def test_rows_and_versions(self):
        self.assertEqual(len(self.rows), 4)
        self.assertEqual(self.by["a10"]["android"], "10 (API 29)")
        self.assertEqual(self.by["MediumPhone.arm"]["android"], "8.0 (API 26)")
        self.assertEqual(self.by["a10"]["device"], "samsung Galaxy A10")

    def test_verdicts(self):
        self.assertEqual(self.by["a10"]["verdict"], "PASS")
        self.assertEqual(self.by["RMX3393"]["verdict"], "FAIL")
        # another app's crash in our logcat must NOT fail our device
        self.assertEqual(self.by["oriole"]["verdict"], "PASS")
        self.assertEqual(self.by["oriole"]["crash"], "no")
        # a native crash of OUR process fails it even if Test Lab said Inconclusive
        self.assertEqual(self.by["MediumPhone.arm"]["verdict"], "FAIL")

    def test_crash_top_frames(self):
        c = self.by["RMX3393"]["crash"]
        self.assertTrue(c.startswith("yes (java)"), c)
        self.assertIn("java.lang.SecurityException", c)
        self.assertIn("Instrumentation.checkStartActivityResult", c)
        n = self.by["MediumPhone.arm"]["crash"]
        self.assertIn("native", n)
        self.assertIn("libflutter.so", n)

    def test_links_and_table(self):
        self.assertIn("console.firebase.google.com/project/assisto-247", self.md)
        self.assertIn("test-lab-abc123xyz/tl-1234-1-physical/a10-29-en-portrait/",
                      self.by["a10"]["shots"])
        self.assertIn("| Device | Android | Robo outcome | Crash (top frame) | Screenshots | Result |", self.md)
        self.assertIn("2/4 devices passed.", self.md)

    def test_empty_outcome_is_fail(self):
        md, rows = summarize.summarize([], "", [], None, "virtual")
        self.assertEqual(rows, [])
        self.assertIn("**FAIL**", md)

    def test_reported_crash_without_logcat(self):
        _, rows = summarize.summarize(
            [{"axis_value": "zz-30-en-portrait", "outcome": "Failed",
              "test_details": "Application crashed."}], "", [], None, "x")
        self.assertEqual(rows[0]["verdict"], "FAIL")
        self.assertTrue(rows[0]["crash"].startswith("yes (reported)"))

    def test_cli_fail_on_fail(self):
        out = os.path.join(FIX, "outcome_sample.json")
        with self.assertRaises(SystemExit) as cm:
            summarize.main(["--outcome", out, "--fail-on-fail",
                            "--results", os.path.join(FIX, "results")])
        self.assertEqual(cm.exception.code, 1)


class PickerTest(unittest.TestCase):
    def setUp(self):
        self.cat = load("catalog_sample.json")

    def models(self, devs):
        return [d.split(",")[0].split("=")[1] for d in devs]

    def test_smoke_is_three(self):
        devs, _ = pick_devices.pick(self.cat, "smoke")
        self.assertEqual(len(devs), 3)
        m = self.models(devs)
        self.assertIn(m[0], ("a10", "a51", "dm1q"))          # Samsung first
        self.assertIn(m[1], ("begonia", "OP4ED5", "RMX3393"))  # a Chinese OEM
        self.assertEqual(m[2], "MediumPhone.arm")              # virtual, arm64 APK
        self.assertIn("version=26", devs[2])

    def test_full_brand_round_robin_and_caps(self):
        devs, report = pick_devices.pick(self.cat, "full", max_physical=5, max_virtual=10)
        m = self.models(devs)
        phys = m[:5]
        # first round = one model per brand present (Samsung, Xiaomi, OPPO, realme, Google)
        self.assertEqual(len(set(phys)), 5)
        self.assertIn("begonia", phys)
        self.assertIn("OP4ED5", phys)
        self.assertIn("RMX3393", phys)
        self.assertNotIn("old_j7", m)  # deprecated + 32-bit only
        self.assertTrue(any("NOT in Test Lab" in r for r in report))  # e.g. vivo
        self.assertTrue(any(r.startswith("catalog brands:") for r in report))
        # every API 26..35 has a device; 36 only on Pixel 9 (not picked: cap)
        apis = {int(d.split("version=")[1].split(",")[0]) for d in devs}
        for a in range(26, 36):
            self.assertIn(a, apis)

    def test_x86_apk_uses_x86_virtual(self):
        devs, _ = pick_devices.pick(self.cat, "smoke", abi="x86_64")
        self.assertTrue(all("MediumPhone," in d for d in devs), devs)


class RoboLintTest(unittest.TestCase):
    def test_committed_script_is_clean(self):
        doc = json.load(open(os.path.join(HERE, "robo_mycircle.json")))
        ids = robo_lint.flutter_ids(os.path.join(ROOT, "app", "lib"))
        self.assertEqual(robo_lint.lint(doc, ids), [])
        for want in ("tl_login_id", "tl_login_password", "tl_login_submit",
                     "tl_drawer_my_circle", "tl_chat_row", "tl_chat_input",
                     "tl_chat_send", "tl_chat_voice_call", "tl_call_hangup",
                     "tl_lang_en", "tl_oem_later"):
            self.assertIn(want, ids)
        # placeholders are present (secrets are filled only at run time)
        text = json.dumps(doc)
        for ph in ("__TL_PHONE__", "__TL_PASSWORD__", "__TL_MSG__"):
            self.assertIn(ph, text)
        self.assertTrue(robo_lint.lint(doc, ids, filled=True))

    def test_lint_catches_mistakes(self):
        bad = [{"actions": [
            {"eventType": "VIEW_CLIKED", "elementDescriptors": [{"resourceId": "x"}]},
            {"eventType": "VIEW_TEXT_CHANGED", "elementDescriptors": [{"resourceId": "tl_nope"}]},
            {"eventType": "WAIT"},
            {"eventType": "VIEW_CLICKED", "elementDescriptors": [{"textRegex": "("}]},
        ]}]
        errs = robo_lint.lint(bad, {"tl_login_id"})
        joined = "\n".join(errs)
        self.assertIn("unknown eventType", joined)
        self.assertIn("needs replacementText", joined)
        self.assertIn("not found as a Semantics identifier", joined)
        self.assertIn("integer delayTime", joined)
        self.assertIn("bad regex", joined)


class WorkflowTest(unittest.TestCase):
    def test_yaml_parses_with_inputs_and_secrets(self):
        try:
            import yaml
        except ImportError:
            self.skipTest("PyYAML not installed")
        p = os.path.join(ROOT, ".github", "workflows", "testlab.yml")
        with open(p) as f:
            raw = f.read()
        doc = yaml.safe_load(raw)
        on = doc.get("on", doc.get(True))
        inputs = on["workflow_dispatch"]["inputs"]
        for k in ("apk_source", "device_set", "robo_timeout"):
            self.assertIn(k, inputs)
        self.assertEqual(inputs["device_set"]["options"], ["smoke", "full"])
        for s in ("GCP_TESTLAB_SA", "CALL_PROOF_A_PHONE", "CALL_PROOF_A_PASSWORD"):
            self.assertIn("secrets." + s, raw)
        self.assertIn("google-github-actions/auth@v2.", raw)  # pinned by version
        self.assertIn("testlab-summary.md", raw)
        self.assertIn("assisto-247", raw)


if __name__ == "__main__":
    unittest.main(verbosity=2)
