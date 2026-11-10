"""lpapp — Language Partner V2 app data on the backend side:
progress collections are per-user, and the bundled Life English /
vocabulary files the app ships (and lpcore imports) keep their shape."""
import json
import os

from django.contrib.auth import get_user_model
from django.test import SimpleTestCase, TestCase
from rest_framework.test import APIClient

V = "/api/v1"
User = get_user_model()
ASSETS = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
                      "app", "assets", "lp")


def _client(n):
    u = User.objects.create_user(name="Learner %d" % n, phone="+88017120000%02d" % n, password="pw12345!")
    c = APIClient()
    c.force_authenticate(u)
    return c


class LpCollectionsTests(TestCase):
    def test_progress_collections_are_per_user(self):
        a, b = _client(1), _client(2)
        for path, body in (("lp/days", {"day": 20400, "kind": "life:bank", "minutes": 10}),
                           ("lp/vocab", {"card_id": "ielts_health_diet", "box": 2, "due": 20402}),
                           ("lp/results", {"kind": "mock", "mock_id": "m1", "overall": 6.5,
                                           "bands": {"listening": 7.0}})):
            r = a.post("%s/%s/" % (V, path), body, format="json")
            self.assertIn(r.status_code, (200, 201), path)
            self.assertEqual(len(a.get("%s/%s/" % (V, path)).json()), 1, path)
            self.assertEqual(b.get("%s/%s/" % (V, path)).json(), [], path)


class LpAssetsTests(SimpleTestCase):
    def _load(self, name):
        with open(os.path.join(ASSETS, name), encoding="utf-8") as f:
            return json.load(f)

    def test_life_scenarios_complete(self):
        j = self._load("life_en_v1.json")
        sc = j["scenarios"]
        self.assertEqual(len(sc), 10)
        ids = {s["id"] for s in sc}
        self.assertEqual(ids, {"airport", "embassy", "market", "metro", "bus", "directions",
                               "rickshaw", "hospital", "bank", "job"})
        for s in sc:
            for k in ("title_en", "title_bn", "role_en", "role_bn", "opening"):
                self.assertTrue(s[k].strip(), (s["id"], k))
            self.assertGreaterEqual(len(s["sentences"]), 8)
            self.assertGreaterEqual(len(s["vocab"]), 8)
            self.assertGreaterEqual(len(s["drill"]), 5)
            for x in s["sentences"]:
                self.assertTrue(x["en"] and x["bn"])
            for d in s["drill"]:
                self.assertTrue(d["q"] and d["a"] and d["bn"])

    def test_vocab_lists(self):
        j = self._load("vocab_v1.json")
        groups = {t["group"] for t in j["topics"]}
        self.assertEqual(groups, {"ielts", "life"})
        ids = [w["id"] for t in j["topics"] for w in t["words"]]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertGreaterEqual(len(ids), 150)
        for t in j["topics"]:
            for w in t["words"]:
                self.assertTrue(w["w"] and w["bn"] and w["ex"], w["id"])
