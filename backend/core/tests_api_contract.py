"""API contract test — every endpoint the Flutter app calls must exist.

Runs tools/route_check.py in-process against THIS Django URLconf: it scans
app/lib/**/*.dart for every API path (literal and string-built, ${...}/$x
normalised to placeholders), resolves each one with Django's real resolver
(DRF router actions and <int:>/<str:>/<slug:>/<uuid:> converter shapes
included) and checks the view handles the HTTP method the client uses.

It FAILS on any MISSING route, METHOD (405) or SLASH (trailing-slash) mismatch
and prints the full list. Part of the pre-deploy backend suite on purpose: a
client call with no backend route is a screen that can never work.

Skips (does not fail) only when the app sources are not present next to the
backend (e.g. a backend-only deploy checkout).
"""
import importlib.util
import unittest
from pathlib import Path

from django.conf import settings
from django.test import SimpleTestCase

ROOT = Path(settings.BASE_DIR).parent
TOOL = ROOT / "tools" / "route_check.py"
APP_LIB = ROOT / "app" / "lib"


def _load_tool():
    spec = importlib.util.spec_from_file_location("route_check", TOOL)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@unittest.skipUnless(TOOL.exists() and APP_LIB.exists(),
                     "app sources / tools not present in this checkout")
class ApiContractTests(SimpleTestCase):
    def test_every_client_call_has_a_backend_route(self):
        rc = _load_tool()
        summary, rows, bad = rc.run()
        self.assertGreater(summary["calls"], 100,
                           "extractor found suspiciously few client calls")
        if bad:
            lines = "\n".join(rc.format_problem(r) for r in bad)
            self.fail(f"{len(bad)} client API call(s) have no matching backend "
                      f"route ({summary['counts']}):\n{lines}")
