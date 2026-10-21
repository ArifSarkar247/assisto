"""Owner DEFAULT home quick buttons: pure engine, /admin/pricing edit, app GET,
and the Dart catalog mirror (fails if HomeQuickButtons.catalog drifts)."""
import re
from pathlib import Path

from django.test import SimpleTestCase
from rest_framework.test import APITestCase

from core.logic import home_defaults as HD
from core.logic import pricing as P
from core.models import User

DART = (Path(__file__).resolve().parents[2]
        / "app" / "lib" / "widgets" / "home_quick_buttons.dart")


class HomeDefaultsLogicTests(SimpleTestCase):
    def test_catalog_mirrors_dart(self):
        src = DART.read_text(encoding="utf-8")
        keys = re.findall(r"QuickShortcut\(\s*'([a-z_]+)'", src)
        self.assertEqual(tuple(keys), HD.CATALOG)
        m = re.search(r"defaults = \[(.*?)\]", src, re.S)
        self.assertEqual(tuple(re.findall(r"'([a-z_]+)'", m.group(1))), HD.DEFAULT)

    def test_normalize(self):
        self.assertEqual(HD.normalize(None), list(HD.DEFAULT))
        self.assertEqual(HD.normalize("junk"), list(HD.DEFAULT))
        r = HD.normalize(["scam", "nope", "scam", 5, "money"])
        self.assertEqual(r[:2], ["scam", "money"])
        self.assertEqual(len(r), 6)
        self.assertEqual(len(set(r)), 6)

    def test_validate(self):
        ok = ["scam", "money", "notes", "ai_chat", "family", "tax"]
        self.assertEqual(HD.validate(ok), [])
        self.assertEqual(HD.validate("x"), ["home_quick_not_list"])
        self.assertIn("home_quick_count", HD.validate(ok[:5]))
        self.assertIn("home_quick_unknown", HD.validate(ok[:5] + ["bogus"]))
        self.assertIn("home_quick_duplicate", HD.validate(ok[:5] + ["scam"]))

    def test_pricing_config_carries_it(self):
        self.assertEqual(P.normalize({})["home_quick_defaults"], list(HD.DEFAULT))
        self.assertEqual(P.DEFAULTS()["home_quick_defaults"], list(HD.DEFAULT))
        self.assertIn("home_quick_count",
                      P.validate_edit({"home_quick_defaults": ["scam"]}))


class HomeDefaultsApiTests(APITestCase):
    def setUp(self):
        self.u = User.objects.create_user(name="U", phone="01710000601", password="pw")
        self.owner = User.objects.create_user(name="O", phone="01710000602", password="pw")
        self.owner.is_superuser = True
        self.owner.save()

    def test_requires_auth(self):
        self.assertIn(self.client.get("/api/v1/app/home-defaults").status_code, (401, 403))

    def test_default_then_owner_edit_flows_to_app(self):
        self.client.force_authenticate(self.u)
        r = self.client.get("/api/v1/app/home-defaults")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data, {"quick_buttons": list(HD.DEFAULT), "count": 6})

        new = ["emergency", "money", "reminders", "scam", "nearby", "notes"]
        # non-owner cannot edit
        self.assertEqual(self.client.post("/api/v1/admin/pricing",
                                          {"home_quick_defaults": new},
                                          format="json").status_code, 403)
        self.client.force_authenticate(self.owner)
        p = self.client.post("/api/v1/admin/pricing",
                             {"config": {"home_quick_defaults": new}, "reason": "t"},
                             format="json")
        self.assertEqual(p.status_code, 200)
        self.assertEqual(p.data["config"]["home_quick_defaults"], new)
        # an unrelated pricing edit keeps it
        self.client.post("/api/v1/admin/pricing", {"config": {"vat": 0.01}}, format="json")

        self.client.force_authenticate(self.u)
        self.assertEqual(self.client.get("/api/v1/app/home-defaults").data["quick_buttons"], new)

    def test_owner_bad_edit_rejected(self):
        self.client.force_authenticate(self.owner)
        for bad, code in ((["scam"], "home_quick_count"),
                          (["scam", "money", "notes", "ai_chat", "family", "zzz"],
                           "home_quick_unknown"),
                          (["scam"] * 6, "home_quick_duplicate"),
                          ("scam", "home_quick_not_list")):
            r = self.client.post("/api/v1/admin/pricing",
                                 {"config": {"home_quick_defaults": bad}}, format="json")
            self.assertEqual(r.status_code, 400, bad)
            self.assertIn(code, r.data["problems"])
