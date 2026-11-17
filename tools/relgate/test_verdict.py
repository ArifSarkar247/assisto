"""gatefix: the gate verdict + reality class rules (run by release_gate.yml).

Owner 17 Nov ("stronger test + phone list"): owner two-phone checklist items
never change a flow's class, but a failed step (e.g. the media proof) is
still C and FAILS the gate, and needs_key is still B (FAIL when required).
"""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "reality"))
import summarize  # noqa: E402


def flow(status="pass", steps_ok=True, needs_key=(), owner_checks=()):
    return {"id": "18_circle_real_call", "status": status,
            "steps": [{"name": "voice media flows", "ok": steps_ok}],
            "needs_key": list(needs_key), "owner_checks": list(owner_checks)}


class KlassTests(unittest.TestCase):
    def test_owner_checks_keep_class_a(self):
        self.assertEqual(summarize.klass(flow(owner_checks=["app-closed ring"])), "A")

    def test_failed_media_proof_is_c(self):
        self.assertEqual(summarize.klass(flow(status="fail", steps_ok=False,
                                              owner_checks=["app-closed ring"])), "C")

    def test_needs_key_still_b(self):
        self.assertEqual(summarize.klass(flow(needs_key=["two phones"])), "B")


class VerdictTests(unittest.TestCase):
    def run_verdict(self, cls, owner_checks=()):
        with tempfile.TemporaryDirectory() as d:
            row = {"id": "18_circle_real_call", "class": cls, "failed_step": "", "detail": "",
                   "note": "", "owner_checks": list(owner_checks)}
            (Path(d) / "reality_summary.json").write_text(json.dumps({"rows": [row]}))
            p = subprocess.run([sys.executable, str(HERE / "verdict.py"), d, "circle",
                                "18_circle_real_call"], capture_output=True, text=True)
            return p.returncode, json.loads((Path(d) / "gate_leg.json").read_text()), p.stdout

    def test_a_with_owner_checks_passes_and_lists_them(self):
        rc, leg, out = self.run_verdict("A", ["app-closed FCM ring"])
        self.assertEqual((rc, leg["verdict"]), (0, "PASS"))
        self.assertIn("app-closed FCM ring", out)
        self.assertEqual(leg["owner_checks"][0]["check"], "app-closed FCM ring")

    def test_failed_step_fails(self):
        rc, leg, _ = self.run_verdict("C", ["app-closed FCM ring"])
        self.assertEqual((rc, leg["verdict"]), (1, "FAIL"))

    def test_b_still_fails(self):
        rc, leg, _ = self.run_verdict("B")
        self.assertEqual((rc, leg["verdict"]), (1, "FAIL"))


if __name__ == "__main__":
    unittest.main()
