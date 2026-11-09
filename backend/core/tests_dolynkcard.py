from unittest import mock

from django.test import TestCase

from core import integrations as I


class _R:
    status_code = 404


class DolynkCardTests(TestCase):
    def test_registered_with_fields(self):
        e = I.REGISTRY["dolynk"]
        keys = [f["key"] for f in e["fields"]]
        self.assertEqual(keys, ["access_key", "secret_key", "product_id", "api_base"])
        self.assertTrue([f for f in e["fields"] if f["key"] == "secret_key"][0]["secret"])
        self.assertEqual(e["test"], "test_dolynk")

    def test_needs_both_keys(self):
        ok, msg = I.test_dolynk({"access_key": "a"})
        self.assertFalse(ok)

    def test_rejects_foreign_host(self):
        ok, msg = I.test_dolynk({"access_key": "a", "secret_key": "b",
                                 "api_base": "https://evil.example.com"})
        self.assertFalse(ok)

    def test_reachable_default_sg(self):
        http = mock.Mock()
        http.get.return_value = _R()
        ok, msg = I.test_dolynk({"access_key": "a", "secret_key": "b"}, http=http)
        self.assertTrue(ok)
        http.get.assert_called_once()
        self.assertIn("open-api-sg.dolynkcloud.com", http.get.call_args[0][0])
