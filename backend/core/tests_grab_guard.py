"""
grab-guard (owner 25 Oct) — "Arif's phone" alerts showed on Arif's own phone.
The server never sends them to the owner (views_antitheft.notify); these
tests pin the extra fields the app uses as its second line of defence:

  * the family_alert push data carries owner_id (+ phone_id);
  * the owner is never a push recipient for a grab (snatch);
  * GET security/engine/state names the protected phone id.
"""
from unittest import mock

from core.tests_at_falsealarm import _Base


class GrabGuardTests(_Base):
    def test_snatch_push_family_only_with_owner_id(self):
        with mock.patch("core.push.safe_push") as sp:
            r = self._ingest([{"id": "snatch-g1", "kind": "snatch",
                               "data": {"locked": False, "confirm_wait": True}}])
        self.assertEqual(r.status_code, 200)
        recips = [c.args[0] for c in sp.call_args_list]
        self.assertIn(self.family, recips)
        self.assertNotIn(self.owner, recips)
        data = sp.call_args_list[0].kwargs["data"]
        self.assertEqual(data["owner_id"], self.owner.id)
        self.assertEqual(data["phone_id"], self.phone.id)
        self.assertEqual(data["alert_kind"], "antitheft")

    def test_engine_state_has_phone_id(self):
        r = self.client.get("/api/v1/security/engine/state")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["phone_id"], self.phone.id)
