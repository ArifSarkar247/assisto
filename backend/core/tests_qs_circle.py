"""qs-circle (quality sweep, owner item 5) — My Circle authorization sweep.

Another user must never read or act through MY circle rows, MY 1:1 messages,
or a group they are not an active member of; key lookups only reveal people I
share a group with or my accepted contacts.
"""
import importlib

from django.test import SimpleTestCase, TestCase
from rest_framework.test import APIClient

from core.models import (CircleGroup, CircleGroupMember, CircleMember,
                         CircleMessage, User)

V = "/api/v1"

# (method, path template) on a 1:1 circle row id
MEMBER_ROUTES = [
    ("get", "circle/{pk}/messages"),
    ("post", "circle/{pk}/messages"),
    ("get", "circle/{pk}/info"),
    ("post", "circle/{pk}/clear"),
    ("get", "circle/{pk}/sharing"),
    ("post", "circle/{pk}/sharing"),
    ("get", "circle/{pk}/settings"),
    ("post", "circle/{pk}/settings"),
    ("get", "circle/{pk}/scheduled"),
    ("post", "circle/{pk}/controls"),
    ("get", "circle/{pk}/see/location"),
    ("post", "circle/{pk}/report"),
    ("post", "circle/{pk}/call"),
    ("post", "circle/{pk}/call/answer"),
    ("get", "circle/{pk}/e2/copies"),
    ("post", "circle/{pk}/e2/resend"),
    ("get", "circle/keys/peer/{pk}"),
    ("post", "circle/request/{pk}/act"),
]

GROUP_ROUTES = [
    ("get", "circle/groups/{pk}"),
    ("get", "circle/groups/{pk}/members"),
    ("get", "circle/groups/{pk}/messages"),
    ("post", "circle/groups/{pk}/messages"),
    ("get", "circle/groups/{pk}/polls"),
    ("post", "circle/groups/{pk}/invite"),
    ("post", "circle/groups/{pk}/call"),
    ("get", "circle/groups/{pk}/export"),
    ("post", "circle/groups/{pk}/clear"),
    ("get", "circle/groups/{pk}/e2/copies"),
    ("post", "circle/groups/{pk}/e2/resend"),
]


class CircleAuthzSweepTests(TestCase):
    def setUp(self):
        mk = User.objects.create_user
        self.a = mk(name="A", phone="01750000001", password="pw12345!")
        self.b = mk(name="B", phone="01750000002", password="pw12345!")
        self.c = mk(name="C", phone="01750000003", password="pw12345!")
        # B <-> C are connected; A is a stranger to both
        self.bc = CircleMember.objects.create(user=self.b, peer_user=self.c,
                                              name="C", state="accepted",
                                              phone="01750000003")
        self.cb = CircleMember.objects.create(user=self.c, peer_user=self.b,
                                              name="B", state="accepted",
                                              direction="incoming",
                                              phone="01750000002")
        self.msg = CircleMessage.objects.create(member=self.bc, sender=self.b,
                                                ciphertext="secret-ct",
                                                nonce="n")
        self.g = CircleGroup.objects.create(creator=self.b, name="Family")
        CircleGroupMember.objects.create(group=self.g, member=self.b, role="admin")
        CircleGroupMember.objects.create(group=self.g, member=self.c)
        self.left = mk(name="L", phone="01750000004", password="pw12345!")
        CircleGroupMember.objects.create(group=self.g, member=self.left,
                                         status="left")
        self.api = APIClient()
        self.api.force_authenticate(self.a)

    def _call(self, client, method, path, body=None):
        fn = getattr(client, method)
        if method == "get":
            return fn(f"{V}/{path}")
        return fn(f"{V}/{path}", body or {"text": "x", "ciphertext": "x",
                                          "nonce": "n", "kind": "voice",
                                          "action": "accept"}, format="json")

    def _assert_refused(self, r, what):
        self.assertIn(r.status_code, (400, 401, 403, 404, 405, 410), what)
        self.assertNotIn(b"secret-ct", r.content, what)

    def test_stranger_cannot_use_someone_elses_circle_row(self):
        before = CircleMessage.objects.count()
        for method, tpl in MEMBER_ROUTES:
            path = tpl.format(pk=self.bc.id)
            r = self._call(self.api, method, path)
            self._assert_refused(r, f"{method.upper()} {path}")
            if r.status_code == 405:
                continue
            self.assertNotEqual(r.status_code // 100, 2, path)
        self.assertEqual(CircleMessage.objects.count(), before)
        self.bc.refresh_from_db()
        self.assertEqual(self.bc.state, "accepted")
        self.assertFalse(self.bc.blocked)

    def test_non_member_and_ex_member_cannot_use_group(self):
        for user in (self.a, self.left):
            api = APIClient()
            api.force_authenticate(user)
            for method, tpl in GROUP_ROUTES:
                path = tpl.format(pk=self.g.id)
                r = self._call(api, method, path)
                self._assert_refused(r, f"{user.name} {method.upper()} {path}")
        self.assertEqual(CircleGroupMember.objects.filter(group=self.g,
                                                          status="active").count(), 2)

    def test_stranger_cannot_act_on_someone_elses_message(self):
        for action in ("delete", "react", "star", "pin", "edit"):
            r = self.api.post(f"{V}/circle/messages/{self.msg.id}/{action}",
                              {"emoji": "x", "text": "y"}, format="json")
            self._assert_refused(r, action)
        self.assertTrue(CircleMessage.objects.filter(pk=self.msg.pk).exists())

    def test_user_keys_only_for_contacts_and_group_peers(self):
        r = self.api.get(f"{V}/circle/keys/users?ids={self.b.id},{self.c.id},x")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["results"], {})
        # C shares the group with B and is B's contact -> visible to B
        api_b = APIClient()
        api_b.force_authenticate(self.b)
        res = api_b.get(f"{V}/circle/keys/users?ids={self.c.id},{self.a.id}") \
            .json()["results"]
        self.assertEqual(set(res), {str(self.c.id)})
        # an ex-member is not a group peer any more
        api_l = APIClient()
        api_l.force_authenticate(self.left)
        self.assertEqual(api_l.get(f"{V}/circle/keys/users?ids={self.b.id}")
                         .json()["results"], {})

    def test_key_request_needs_shared_group_or_own_row(self):
        for body in ({"user_id": self.c.id}, {"user_id": "zz"},
                     {"member_id": self.bc.id}, {"member_id": "zz"}, {}):
            r = self.api.post(f"{V}/circle/keys/request", body, format="json")
            self.assertEqual(r.status_code, 404, body)

    def test_unauthenticated_gets_nothing(self):
        anon = APIClient()
        for method, tpl in MEMBER_ROUTES[:4] + GROUP_ROUTES[:3]:
            path = tpl.format(pk=self.bc.id if "groups" not in tpl else self.g.id)
            r = self._call(anon, method, path)
            self.assertIn(r.status_code, (401, 403), path)


# ---------------------------------------------------------------------------
# qs: the pure-logic snippet suites for group roles / invites / polls / pins
# (circle_groups) and circle_extras were never folded into a Django test run
# (core/tests.py folds the others) — so 60 + 26 checks never ran in CI.
# ---------------------------------------------------------------------------
def _snippet_case(module_path, class_name):
    mod = importlib.import_module(module_path)
    attrs = {}
    for name in dir(mod):
        fn = getattr(mod, name)
        if name.startswith("test_") and callable(fn):
            attrs[name] = (lambda f: lambda self: f())(fn)
    return type(class_name, (SimpleTestCase,), attrs)


CircleGroupsSnippetTests = _snippet_case(
    "core.logic.circle_groups_tests_snippets", "CircleGroupsSnippetTests")
CircleExtrasSnippetTests = _snippet_case(
    "core.logic.circle_extras_tests_snippets", "CircleExtrasSnippetTests")
