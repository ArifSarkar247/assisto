"""circlea — My Circle Family / Others field (pure rules + endpoints)."""
from django.core.cache import cache
from django.test import SimpleTestCase, TestCase
from rest_framework.test import APIClient

from core import circle_family
from core.logic import circle_family as CF
from core.models import CircleMember, FamilyMember, User

V = "/api/v1"


def mk(phone, name):
    return User.objects.create_user(name=name, phone=phone, password="pw12345!")


def cl(u):
    c = APIClient()
    c.force_authenticate(u)
    c.credentials(HTTP_ACCEPT_LANGUAGE="en")
    return c


def edge(a, b, relation="friend", **kw):
    return CircleMember.objects.create(user=a, peer_user=b, name=b.name,
                                       relation=relation, state="accepted", **kw)


class PureRules(SimpleTestCase):
    def test_normalize(self):
        self.assertEqual(CF.normalize_group("Family"), "family")
        self.assertEqual(CF.normalize_group("others"), "others")
        self.assertEqual(CF.normalize_group("other"), "others")
        self.assertEqual(CF.normalize_group("পরিবার"), "family")
        self.assertEqual(CF.normalize_group("auto"), "")
        self.assertEqual(CF.normalize_group(None), "")
        with self.assertRaises(ValueError):
            CF.normalize_group("enemies")

    def test_auto_and_explicit(self):
        self.assertEqual(CF.effective_group("", "mother"), ("family", True))
        self.assertEqual(CF.effective_group("", "relative"), ("family", True))
        self.assertEqual(CF.effective_group("", "friend"), ("others", True))
        self.assertEqual(CF.effective_group("", "friend", family_linked=True), ("family", True))
        self.assertEqual(CF.effective_group("", "colleague", guardian_linked=True),
                         ("family", True))
        # the user's mark always wins — both ways
        self.assertEqual(CF.effective_group("others", "mother"), ("others", False))
        self.assertEqual(CF.effective_group("family", "friend"), ("family", False))

    def test_filter_and_sections(self):
        rows = [{"name": "Rina", "circle_group": "others", "phone": "01711"},
                {"name": "আম্মা", "circle_group": "family", "phone": ""},
                {"name": "Karim", "circle_group": "family", "phone": "01822"}]
        self.assertEqual([r["name"] for r in CF.filter_rows(rows, "family")],
                         ["আম্মা", "Karim"])
        self.assertEqual([r["name"] for r in CF.filter_rows(rows, "others")], ["Rina"])
        self.assertEqual(len(CF.filter_rows(rows, "all")), 3)
        self.assertEqual([r["name"] for r in CF.filter_rows(rows, "all", "আম")], ["আম্মা"])
        self.assertEqual([r["name"] for r in CF.filter_rows(rows, "all", "0182")], ["Karim"])
        secs = CF.sectioned(rows)
        self.assertEqual([k for k, _ in secs], ["family", "others"])
        self.assertEqual(CF.sectioned([rows[0]]), [("others", [rows[0]])])
        self.assertEqual(CF.sectioned([]), [])


class GroupEndpoints(TestCase):
    def setUp(self):
        cache.clear()
        self.a = mk("01711200001", "Rina")
        self.mom = mk("01711200002", "Mom")
        self.friend = mk("01711200003", "Friend")
        self.cousin = mk("01711200004", "Cousin")
        self.x = mk("01711200005", "Stranger")
        self.e_mom = edge(self.a, self.mom, "mother")
        self.e_friend = edge(self.a, self.friend, "friend")
        self.e_cousin = edge(self.a, self.cousin, "custom", custom_label="Cousin")
        # Family Care already picked the cousin -> Family by default
        FamilyMember.objects.create(user=self.a, name="Cousin", circle_member=self.e_cousin)
        self.c = cl(self.a)

    def _members(self):
        r = self.c.get(V + "/circle/members")
        self.assertEqual(r.status_code, 200)
        return {m["id"]: m for m in r.json()["results"]}

    def test_defaults_from_existing_family_data(self):
        m = self._members()
        self.assertEqual(m[self.e_mom.id]["circle_group"], "family")
        self.assertTrue(m[self.e_mom.id]["circle_group_auto"])
        self.assertEqual(m[self.e_friend.id]["circle_group"], "others")
        self.assertEqual(m[self.e_cousin.id]["circle_group"], "family")

    def test_mark_and_reset(self):
        r = self.c.post(V + "/circle/%d/people-group" % self.e_friend.id,
                        {"group": "family"}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["circle_group"], "family")
        self.assertFalse(r.json()["circle_group_auto"])
        self.assertEqual(self._members()[self.e_friend.id]["circle_group"], "family")
        # mark Mom as Others — the user's choice wins over the relation
        self.c.post(V + "/circle/%d/people-group" % self.e_mom.id,
                    {"group": "others"}, format="json")
        self.assertEqual(self._members()[self.e_mom.id]["circle_group"], "others")
        # back to automatic
        r = self.c.post(V + "/circle/%d/people-group" % self.e_mom.id,
                        {"group": "auto"}, format="json")
        self.assertEqual(r.json()["circle_group"], "family")
        self.assertTrue(r.json()["circle_group_auto"])

    def test_bad_group_and_foreign_edge(self):
        r = self.c.post(V + "/circle/%d/people-group" % self.e_mom.id,
                        {"group": "boss"}, format="json")
        self.assertEqual(r.status_code, 400)
        theirs = edge(self.x, self.a)
        r = self.c.post(V + "/circle/%d/people-group" % theirs.id,
                        {"group": "family"}, format="json")
        self.assertEqual(r.status_code, 404)
        theirs.refresh_from_db()
        self.assertEqual(theirs.circle_group, "")

    def test_chats_and_picker_carry_group_family_first(self):
        r = self.c.get(V + "/circle/chats")
        self.assertEqual(r.status_code, 200)
        r = self.c.get(V + "/family/circle-pick")
        self.assertEqual(r.status_code, 200)
        body = r.json()
        rows = body.get("results", body) if isinstance(body, dict) else body
        groups = [x["circle_group"] for x in rows]
        self.assertEqual(groups, sorted(groups, key=lambda g: 0 if g == "family" else 1))
        self.assertIn("others", groups)

    def test_family_member_ids_helper(self):
        ids = circle_family.family_member_ids(self.a)
        self.assertEqual(ids, {self.e_mom.id, self.e_cousin.id})
        self.e_mom.blocked = True
        self.e_mom.save()
        self.assertEqual(circle_family.family_member_ids(self.a), {self.e_cousin.id})
