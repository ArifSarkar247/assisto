"""flagproof (17 Nov 2026): the reality seed sets up the two-account proofs for
the hidden features (flows 21 + 31-36) — and ONLY for the flagproof drive, so
no other reality group's circle or data changes."""
import json
import os
import tempfile
from io import StringIO
from unittest import mock

from django.core.management import call_command
from django.test import TestCase

from core import feature_flags as FF
from core.management.commands import seed_reality as SR
from core.models import BloodDonor, CircleMember, FeatureFlag, NearbyAlertPref, User


def _seed(drive):
    f = os.path.join(tempfile.mkdtemp(), "seed.json")
    with mock.patch.dict(os.environ, {"REALITY_DRIVE": drive}):
        call_command("seed_reality", out=f, stdout=StringIO())
    return json.load(open(f))


class FlagproofSeedTests(TestCase):
    def test_flagproof_drive_sets_up_every_two_account_proof(self):
        d = _seed("start+flagproof")
        self.assertEqual(d["failed_steps"], [], d["failed_steps"])
        ids = {k: d["users"][k]["id"] for k in ("a", "b", "c", "d")}
        for key in SR.FLAGPROOF_KEYS:
            row = FeatureFlag.objects.get(key=key)
            self.assertTrue(set(ids.values()) <= set(row.allow_user_ids or []), key)
            FF.invalidate()
            self.assertTrue(FF.is_on(key, User.objects.get(pk=ids["a"])), key)
        # A and D are mutual close family (missing alert "I am safe" path)
        for u, p in ((ids["a"], ids["d"]), (ids["d"], ids["a"])):
            m = CircleMember.objects.get(user_id=u, peer_user_id=p)
            self.assertEqual((m.state, m.relation), ("accepted", "brother"))
        self.assertTrue(BloodDonor.objects.filter(user_id=ids["b"], enabled=True,
                                                  blood_group="O+").exists())
        self.assertTrue(NearbyAlertPref.objects.filter(user_id=ids["c"], enabled=True,
                                                       district="dhaka").exists())
        # D's salon page is public and taking bookings (flow 33 books it as A)
        from rest_framework.test import APIClient
        c = APIClient()
        c.force_authenticate(User.objects.get(pk=ids["a"]))
        r = c.get("/api/v1/booking/p/flagproof-salon")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertTrue(r.json()["taking_bookings"])

    def test_other_drives_leave_the_circle_alone(self):
        d = _seed("start+circle")
        self.assertEqual(d["failed_steps"], [], d["failed_steps"])
        self.assertFalse(CircleMember.objects.filter(user_id=d["users"]["a"]["id"],
                                                     peer_user_id=d["users"]["d"]["id"]).exists())
        self.assertFalse(BloodDonor.objects.filter(user_id=d["users"]["b"]["id"]).exists())
