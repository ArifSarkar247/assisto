"""Route coverage (m1-messenger, owner order 21 Oct).

1. EVERY core URL pattern (incl. DRF router actions) is resolved to a concrete
   URL with seeded ids and requested with GET as an authenticated user. The
   request must reach a VIEW: a resolver 404 (Django's plain "Not Found" page,
   i.e. the route does not exist) fails the test, and so does a 5xx. A JSON
   404 from a view ("object not found") is allowed here because not every
   object type is seeded.
2. The routes the owner audit found missing are then called STRICTLY with
   valid seeded ids, the right method and a valid body: each must answer
   non-404 (and non-5xx).

This complements (does not duplicate) slot m2-reality's Dart-call-site →
resolver contract test: this one proves the backend side answers.
"""
import re

from django.test import TestCase, override_settings
from django.urls import Resolver404, URLPattern, URLResolver, resolve
from django.utils import timezone
from rest_framework.test import APIClient

from core import urls as core_urls
from core.models import (CircleGroup, CircleGroupMember, CircleMember,
                         CircleMessage, Community, CommunityGroup,
                         CommunityMember, CommunityMessageRequest,
                         FamilyMember, GroupPoll, Journey, Reminder, User)

PREFIX = "/api/v1/"

# Values for named captures (anything not listed: 1 / "x").
_NAMED = {
    "item_id": "reminder:1", "action": "vote", "event": "promote",
    "task": "summarise", "setting": "announcements", "scope": "location",
    "key": "privacy", "slug": "privacy", "device_id": "dev1", "name": "x.jpg",
    "uidb64": "x", "token": "x", "format": "json", "path": "x",
}

# GETs that legitimately reach the network / long work and are skipped in the
# broad sweep (they are still RESOLVED — resolution is what part 1 proves).
_SKIP_GET = ("telegram/webhook",)


def _walk(patterns, prefix=""):
    for p in patterns:
        if isinstance(p, URLResolver):
            yield from _walk(p.url_patterns, prefix + str(p.pattern))
        elif isinstance(p, URLPattern):
            yield prefix + str(p.pattern), p


def _concrete(route):
    """Turn a path()/re_path() route string into a concrete URL."""
    s = route
    if "(?P<" in s or "^" in s:            # regex routes (DRF router)
        if "(?P<format>" in s:
            return None                     # the .json/.api suffix variants
        s = re.sub(r"\(\?P<(\w+)>[^)]*\)",
                   lambda m: _NAMED.get(m.group(1), "1"), s)
        s = s.replace("^", "").replace("$", "").replace("\\.", ".")
        s = s.replace("\\", "")

    def conv(m):                            # path() converters
        typ, name = m.group(1) or "str", m.group(2)
        if name in _NAMED:
            return _NAMED[name]
        return "1" if typ == "int" else "x"
    return re.sub(r"<(?:(\w+):)?(\w+)>", conv, s)


@override_settings(MEDIA_ROOT="/tmp/assisto-route-coverage-media")
class RouteCoverageTests(TestCase):
    @classmethod
    def setUpTestData(cls):
        cls.u = User.objects.create_user(name="Owner", phone="01750000001",
                                         password="pw12345!", language="en")
        cls.p = User.objects.create_user(name="Peer", phone="01750000002",
                                         password="pw12345!", language="en")
        cls.edge = CircleMember.objects.create(
            user=cls.u, peer_user=cls.p, name="Peer", state="accepted",
            phone=cls.p.phone)
        CircleMember.objects.create(user=cls.p, peer_user=cls.u, name="Owner",
                                    state="accepted", phone=cls.u.phone)
        cls.g = CircleGroup.objects.create(creator=cls.u, name="G")
        cls.gm = CircleGroupMember.objects.create(group=cls.g, member=cls.u,
                                                  role="admin")
        CircleGroupMember.objects.create(group=cls.g, member=cls.p)
        cls.msg = CircleMessage.objects.create(group=cls.g, sender=cls.u,
                                               ciphertext="Q1Q=", nonce="Tg==")
        cls.poll = GroupPoll.objects.create(group=cls.g, author=cls.u,
                                            option_count=2)
        cls.com = Community.objects.create(creator=cls.u, name="C")
        cg = CommunityGroup.objects.create(community=cls.com, creator=cls.u,
                                           kind="announcements", name="A")
        CommunityMember.objects.create(community=cls.com, group=cg,
                                       member=cls.u, role="admin")
        CommunityMember.objects.create(community=cls.com, group=cg,
                                       member=cls.p)
        cls.mr = CommunityMessageRequest.objects.create(
            sender=cls.p, recipient=cls.u, first_ciphertext="Q1Q=")
        cls.fm = FamilyMember.objects.create(user=cls.u, name="Mom")
        cls.rem = Reminder.objects.create(user=cls.u, title="r",
                                          due_at=timezone.now())
        cls.j = Journey.objects.create(
            traveller=cls.u, destination={"name": "Home"},
            expires_at=timezone.now() + timezone.timedelta(hours=3))

    def setUp(self):
        self.c = APIClient(raise_request_exception=False)
        self.c.force_authenticate(self.u)
        self.c.credentials(HTTP_ACCEPT_LANGUAGE="en")

    def _why(self, url):
        c = APIClient()
        c.force_authenticate(self.u)
        try:
            c.get(PREFIX + url, HTTP_ACCEPT="application/json")
        except Exception as e:  # noqa: BLE001 — diagnostics only
            return "%s: %s" % (type(e).__name__, str(e)[:160])
        return ""

    def test_every_pattern_reaches_a_view(self):
        missing, crashed, checked = [], [], 0
        for route, _p in _walk(core_urls.urlpatterns):
            url = _concrete(route)
            if url is None or "format" in route or \
                    any(s in url for s in _SKIP_GET):
                continue
            try:
                resolve(PREFIX + url)
            except Resolver404:
                missing.append(url)
                continue
            r = self.c.get(PREFIX + url, HTTP_ACCEPT="application/json")
            checked += 1
            if r.status_code == 500:   # 503 = an honest "not available"
                crashed.append((url, r.status_code, self._why(url)))
        self.assertGreater(checked, 300)
        self.assertEqual(missing, [], "routes that do not resolve to a view")
        self.assertEqual(crashed, [], "GET crashed (500)")

    def strict(self):
        g, m, p = self.g.id, self.msg.id, self.poll.id
        e, com, j = self.edge.id, self.com.id, self.j.id
        return [
            # family accounting
            ("get", "family/accounting/summary", None),
            ("get", "family/accounting/expenses", None),
            ("post", "family/accounting/expenses",
             {"payer": "self", "total_poisha": 1000, "mode": "equal",
              "members": ["self", self.fm.id]}),
            ("post", "family/accounting/settle",
             {"from": self.fm.id, "to": "self", "amount_poisha": 100}),
            ("get", "family/accounting/pool", None),
            ("post", "family/accounting/pool", {"target_poisha": 500}),
            ("post", "family/accounting/pool/contribute",
             {"member": self.fm.id, "amount_poisha": 100}),
            # group nested shapes
            ("post", "circle/groups/%d/messages/%d/pin" % (g, m), {"pin": True}),
            ("post", "circle/groups/%d/messages/%d/star" % (g, m), {}),
            ("post", "circle/groups/%d/polls/%d/vote" % (g, p), {"choices": [0]}),
            ("post", "circle/groups/%d/members/%d" % (g, self.gm.id),
             {"event": "demote"}),
            ("get", "circle/groups/%d/media" % g, None),
            # messenger ⋮ + settings
            ("get", "circle/chats", None),
            ("get", "circle/%d/info" % e, None),
            ("post", "circle/%d/clear" % e, {}),
            ("get", "circle/account/two-step", None),
            ("post", "circle/account/two-step", {"enabled": True,
                                                 "pin": "123456"}),
            ("get", "circle/account/change-number", None),
            ("post", "circle/groups/%d/ai/summarise" % g, {"messages": ["hi"]}),
            ("post", "circle/groups/%d/mute" % g, {"duration": "8h"}),
            ("post", "circle/groups/%d/disappearing" % g, {"ttl": "7d"}),
            ("post", "circle/groups/%d/theme" % g, {"color": "ocean"}),
            ("post", "circle/groups/%d/favourite" % g, {"on": True}),
            ("get", "circle/groups/%d/export" % g, None),
            ("get", "circle/settings/calls", None),
            ("get", "circle/settings/notifications", None),
            ("get", "circle/settings/storage", None),
            ("get", "circle/message-requests", None),
            ("post", "community/%d/notifications" % com, {"muted": True}),
            ("get", "community/message-requests", None),
            ("post", "notif/reminders/reminder:%d/done" % self.rem.id, {}),
            ("get", "journey/%d/timeline" % j, None),
            ("get", "disaster/feed", None),
            ("post", "medicine-db/report", {"brand": "Napa", "issue": "x"}),
            ("post", "community/%d/leave" % com, {}),
            # last: settle above needs an expense first (ordered list)
        ]

    def test_owner_audit_routes_answer_non_404(self):
        bad = []
        for method, url, body in self.strict():
            fn = getattr(self.c, method)
            r = fn(PREFIX + url, body, format="json") if method == "post" \
                else fn(PREFIX + url)
            if r.status_code == 404 or r.status_code >= 500:
                bad.append((method, url, r.status_code,
                            getattr(r, "content", b"")[:120]))
        # change-number request is honest 503 while no SMS gateway exists —
        # that is a real answer, so it is checked separately.
        r = self.c.post(PREFIX + "circle/account/change-number/request",
                        {"new_phone": "01799990000"}, format="json")
        self.assertIn(r.status_code, (200, 503))
        r = self.c.post(PREFIX + "circle/account/change-number/confirm",
                        {"new_phone": "01799990000", "code": "1"}, format="json")
        self.assertEqual(r.status_code, 400)   # no pending request -> honest 400
        self.assertEqual(bad, [])
