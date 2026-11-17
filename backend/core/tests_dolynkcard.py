from django.test import TestCase

from core import integrations as I


class DolynkCardTests(TestCase):
    def test_registered_with_fields(self):
        e = I.REGISTRY["dolynk"]
        keys = [f["key"] for f in e["fields"]]
        self.assertEqual(keys[:4], ["access_key", "secret_key", "product_id", "api_base"])
        self.assertTrue([f for f in e["fields"] if f["key"] == "secret_key"][0]["secret"])
        self.assertEqual(e["test"], "test_dolynk")

    def test_needs_both_keys(self):
        ok, msg = I.test_dolynk({"access_key": "a"})
        self.assertFalse(ok)

    def test_rejects_foreign_host(self):
        ok, msg = I.test_dolynk({"access_key": "a", "secret_key": "b",
                                 "api_base": "https://evil.example.com"})
        self.assertFalse(ok)

    def test_signed_signin_default_sg(self):
        """dolynkreal: the Test is a SIGNED AppAccessToken call to the
        Singapore API (Doc Center "Obtaining AppAccessToken")."""
        import json
        seen = []

        def http(url, body, timeout, headers):
            seen.append((url, headers))
            return 200, json.dumps({"code": "200", "success": True, "msg": "ok",
                                    "data": {"appAccessToken": "t", "validitySeconds": 604800}})
        from core.logic.cctv_connect import dolynk as DL
        DL._tokens.clear()
        ok, msg = I.test_dolynk({"access_key": "a", "secret_key": "b"}, http=http)
        self.assertTrue(ok, msg)
        self.assertIn("DoLynk sign-in OK", msg)
        self.assertEqual(seen[0][0], "https://open-api-sg.dolynkcloud.com/open-api/api-base/auth/getAppAccessToken")
        self.assertEqual(seen[0][1]["ProductId"], "212808822")
        self.assertNotIn("b", msg.split())
