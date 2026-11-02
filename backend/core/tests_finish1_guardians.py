"""finish1 (2 Nov): ONE guardian source of truth — core/guardianship.py.

2 parents (Mom, Dad) x 2 children (Rina, Babu), checked across all three
features that used to keep their own copy of the rule:

  * missing-person alert  — guardian_check() + who is pushed as FAMILY;
  * child emergency audio — kid_audio.is_guardian() + set_consent();
  * tracker chip          — viewers (location) vs alert audience, the child's
                            "who watches me" list, the parent's children list.

Behaviour kept: verified parent = both My Circle edges agree parent/child;
an aunt who only co-guards a watch is NOT a verified parent (no audio, no
child missing alert without a co-signer); a chip's LOCATION stays with the
owner + chosen guardians. Patches return plain values only."""
from unittest import mock

from django.core.cache import cache
from django.test import TestCase
from django.utils import timezone

from core import chip_service as CS
from core import guardianship as G
from core import kid_audio as KA
from core import missing_alert as MS
from core.models import (CircleMember, KidAudioConsent, KidsWatch, MissingAlert, User,
                         VehicleAccessGrant, VehicleTracker)


def mk(phone, name):
    return User.objects.create_user(name=name, phone=phone, password="pw12345!")


def pair(a, b, rel_ab="friend", rel_ba="friend"):
    CircleMember.objects.create(user=a, peer_user=b, name=b.name, state="accepted",
                                relation=rel_ab)
    CircleMember.objects.create(user=b, peer_user=a, name=a.name, state="accepted",
                                relation=rel_ba, direction="incoming")


def chip(owner, child, imei, grantees):
    t = VehicleTracker.objects.create(owner=owner, kind="chip", imei=imei,
                                      child_user=child, child_name=child.name,
                                      state="paired")
    for g in grantees:
        VehicleAccessGrant.objects.create(tracker=t, grantee=g, kind="family",
                                          can_command=False)
    return t


class TwoParentsTwoChildren(TestCase):
    def setUp(self):
        cache.clear()
        self.mom = mk("01711400001", "Mom")
        self.dad = mk("01711400002", "Dad")
        self.rina = mk("01711400003", "Rina")
        self.babu = mk("01711400004", "Babu")
        self.aunt = mk("01711400005", "Aunt")
        self.x = mk("01711400006", "Stranger")
        pair(self.mom, self.dad, "husband", "wife")
        for kid in (self.rina, self.babu):
            pair(self.mom, kid, "child", "mother")
            pair(self.dad, kid, "child", "father")
            pair(self.aunt, kid, "friend", "friend")
        pair(self.dad, self.aunt, "friend", "friend")
        pair(self.mom, self.x, "friend", "friend")
        p = mock.patch("core.push.safe_push", return_value=True)
        p.start()
        self.addCleanup(p.stop)
        self.parents = (self.mom, self.dad)
        self.kids = (self.rina, self.babu)
        # Mom's chip on Rina's bag (Dad sees it); Dad's chip on Babu's shoe (Mom sees it)
        self.chip_rina = chip(self.mom, self.rina, "865920051234561", [self.dad])
        self.chip_babu = chip(self.dad, self.babu, "865920051234579", [self.mom])
        # Dad's watch on Rina; the aunt co-guards it (not a parent)
        self.watch = KidsWatch.objects.create(
            owner=self.dad, child_user=self.rina, child_name="Rina",
            imei="8800000911", state="paired", guardian_ids=[self.aunt.id])

    # ---------------------------------------------------------- the one rule
    def test_verified_parent_every_pair(self):
        for p in self.parents:
            for k in self.kids:
                self.assertTrue(G.verified_parent(p, k), (p.name, k.name))
                self.assertFalse(G.verified_parent(k, p))        # direction matters
        self.assertFalse(G.verified_parent(self.aunt, self.rina))
        self.assertFalse(G.verified_parent(self.x, self.rina))
        self.assertFalse(G.verified_parent(self.mom, self.mom))
        CircleMember.objects.filter(user=self.rina, peer_user=self.dad).update(blocked=True)
        self.assertFalse(G.verified_parent(self.dad, self.rina))
        self.assertTrue(G.verified_parent(self.dad, self.babu))  # the other child unaffected

    # ------------------------------------------------------- missing alert
    def test_missing_guardian_check_uses_the_rule(self):
        for p in self.parents:
            for k in self.kids:
                g = MS.guardian_check(p, k)
                self.assertEqual((g["ok"], g["basis"]), (True, "circle_mutual"))
        g = MS.guardian_check(self.aunt, self.rina)
        self.assertEqual((g["ok"], g["needs"]), (False, "cosign"))
        # co-signing is unchanged: Dad (husband edge) may co-sign for Mom
        self.assertTrue(MS.guardian_check(self.mom, None, None, cosigner=self.dad)["ok"])

    def test_missing_child_family_push_reaches_every_guardian(self):
        a = MissingAlert(poster=self.mom, subject_user=self.rina, is_child=True,
                         name="Rina", relation="child")
        ids = {u.id for u in MS.family_audience(a)}
        self.assertIn(self.dad.id, ids)        # close family of the poster
        self.assertIn(self.aunt.id, ids)       # co-guards Rina's watch
        self.assertNotIn(self.mom.id, ids)     # never the poster
        self.assertNotIn(self.rina.id, ids)    # never the missing child
        self.assertNotIn(self.x.id, ids)       # Mom's friend, not a guardian
        # Babu: the aunt guards nothing of his -> not told as family
        b = MissingAlert(poster=self.dad, subject_user=self.babu, is_child=True,
                         name="Babu", relation="child")
        ids = {u.id for u in MS.family_audience(b)}
        self.assertEqual(ids, {self.mom.id, self.rina.id})   # Dad's close family
        # an ADULT alert keeps the old audience (poster's close family only)
        c = MissingAlert(poster=self.mom, subject_user=self.rina, is_child=False,
                         name="Rina", relation="child")
        self.assertNotIn(self.aunt.id, {u.id for u in MS.family_audience(c)})

    # -------------------------------------------------- child emergency audio
    def test_kid_audio_every_parent_every_child(self):
        year = timezone.now().year - 10
        for p in self.parents:
            for k in self.kids:
                self.assertTrue(KA.is_guardian(p, k))
                c, why = KA.set_consent(p, k, year)
                self.assertIsNotNone(c, why)
        self.assertEqual(KidAudioConsent.objects.count(), 4)
        # a watch co-guardian is NOT a verified parent: listening is stricter
        self.assertFalse(KA.is_guardian(self.aunt, self.rina))
        self.assertEqual(KA.set_consent(self.aunt, self.rina, year), (None, "not_guardian"))
        self.assertEqual(KA.set_consent(self.rina, self.mom, year), (None, "not_guardian"))

    # ---------------------------------------------------------- tracker chip
    def test_chip_viewers_vs_alert_audience(self):
        self.assertEqual([u.id for u in CS.viewers(self.chip_rina)], [self.mom.id, self.dad.id])
        told = [u.id for u in CS.alert_users(self.chip_rina)]
        self.assertEqual(told[0], self.mom.id)                  # owner first
        self.assertEqual(set(told), {self.mom.id, self.dad.id, self.aunt.id})
        self.assertNotIn(self.rina.id, told)                    # never the child
        self.assertFalse(CS.can_view(self.aunt, self.chip_rina))  # location stays private
        self.assertEqual({u.id for u in CS.alert_users(self.chip_babu)},
                         {self.mom.id, self.dad.id})
        # Mom leaves Dad's Circle: Dad's chip stops sharing with her at once
        CircleMember.objects.filter(user=self.dad, peer_user=self.mom).update(blocked=True)
        self.assertEqual([u.id for u in CS.viewers(self.chip_babu)], [self.dad.id])

    def test_child_sees_chip_watchers_and_parent_sees_both_children(self):
        rows = {g["id"]: g for g in G.guardians_of(self.rina)}
        self.assertEqual(set(rows), {self.mom.id, self.dad.id, self.aunt.id})
        kinds = {s["kind"] for s in rows[self.mom.id]["sources"]}
        self.assertIn("chip", kinds)
        self.assertFalse(rows[self.mom.id]["removable"])        # Mom set the chip up
        for p, other in ((self.mom, self.dad), (self.dad, self.mom)):
            kids = {k["child_user_id"]: k for k in G.children_of(p)}
            self.assertEqual(set(kids), {self.rina.id, self.babu.id}, p.name)
            for k in kids.values():
                self.assertIn(other.id, {c["id"] for c in k["co_guardians"]})
        res = G.remove_guardian(self.rina, self.mom.id)
        self.assertEqual([k["kind"] for k in res["kept"]], ["chip"])
        self.assertTrue(res["kept"][0]["set_up_by"])
