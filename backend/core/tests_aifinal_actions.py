"""aifinal PART 5: action buttons from a FIXED allow-list, never invented,
off by default, invoice only for a business owner."""
from unittest import mock

from django.contrib.auth import get_user_model
from django.test import TestCase

from core import ai_actions as AA
from core import views_chat as VC


def _u(phone="+8801811000001"):
    return get_user_model().objects.create_user(name="a", phone=phone, password="pw12345!")


class ActionTests(TestCase):
    def on(self):
        return mock.patch.object(AA, "enabled", return_value=True)

    def test_off_by_default(self):
        self.assertEqual(AA.suggest(_u(), "remind me tomorrow at 9"), [])

    def test_only_allowed_ids_max_three_emergency_first(self):
        with self.on():
            got = AA.suggest(_u(), "There was an accident on my night bus, share my location, "
                                   "remind me, wake me at my station, open cctv camera")
        self.assertLessEqual(len(got), 3)
        self.assertEqual(got[0]["id"], "call_999")
        for a in got:
            self.assertIn(a["id"], AA.ALLOWED)
            self.assertEqual(a["route"], AA.ALLOWED[a["id"]])

    def test_bangla(self):
        with self.on():
            ids = [a["id"] for a in AA.suggest(_u(), "কাল সকালে ওষুধের কথা মনে করিয়ে দিও")]
        self.assertEqual(ids, ["reminder"])

    def test_invoice_only_for_business_owner(self):
        from core.models import BusinessProfile
        u = _u()
        with self.on():
            self.assertEqual(AA.suggest(u, "make an invoice"), [])
            BusinessProfile.objects.create(user=u, shop_name="S")
            self.assertEqual([a["id"] for a in AA.suggest(u, "make an invoice")], ["invoice"])

    def test_chat_answer_carries_actions_from_the_list_not_the_model(self):
        u = _u("+8801811000002")
        with self.on(), mock.patch.object(VC.ai, "available", return_value=True), \
                mock.patch.object(VC.ai, "generate",
                                  return_value=("Sure. [ACTION: transfer_money]", 0.0)):
            reply, meta, _ = VC._produce_reply(u, None, "remind me to pay rent", "en", [])
        self.assertEqual([a["id"] for a in meta["actions"]], ["reminder"])
