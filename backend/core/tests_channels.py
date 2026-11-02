"""channels (2 Nov) — owner phone-test bug: A's channel / community was
invisible to B. Proves: public channel -> B finds it in the directory (name,
topic, @handle), follows, gets a push on a new post (and not when muted);
private channel hidden from the directory and only opened with its invite
code; block; report hides from the directory; minors never listed; rate
limits; community join by link with admin approval -> real E2E group chat
membership; report; web fallback pages; the Discover card seed."""
from unittest import mock

from django.core.cache import cache
from django.test import TestCase
from rest_framework.test import APIClient

from core.models import (Channel, ChannelFollower, CircleGroupMember, Community,
                         CommunityGroup, DiscoverCard, User)

V = "/api/v1"


def mk(phone, name):
    return User.objects.create_user(name=name, phone=phone, password="pw12345!",
                                    language="en")


def cl(u):
    c = APIClient()
    c.force_authenticate(u)
    c.credentials(HTTP_ACCEPT_LANGUAGE="en")
    return c


class ChannelDirectoryTests(TestCase):
    def setUp(self):
        cache.clear()
        self.a, self.b = mk("01730000001", "A"), mk("01730000002", "B")
        self.ca, self.cb = cl(self.a), cl(self.b)

    def create(self, **body):
        body.setdefault("name", "Dhaka Bazar News")
        body.setdefault("description", "daily vegetable prices")
        r = self.ca.post("%s/channels" % V, body, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        return r.json()

    def test_public_channel_found_followed_and_pushed(self):
        ch = self.create(category="news")
        self.assertTrue(ch["is_public"])
        self.assertTrue(ch["handle"])                 # made from the name
        cid = ch["id"]
        for q in ("bazar", "vegetable", ch["handle"]):
            j = self.cb.get("%s/channels/discover" % V, {"q": q}).json()
            self.assertEqual([c["id"] for c in j["results"]], [cid], q)
            self.assertIn("follower_count", j["results"][0])
            self.assertFalse(j["results"][0]["my_following"])
        self.assertIn(cid, [c["id"] for c in
                            self.cb.get("%s/channels/discover" % V).json()["suggested"]])
        r = self.cb.post("%s/channels/%d/follow" % (V, cid), {}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()["channel"]["my_following"])
        self.assertEqual(r.json()["channel"]["follower_count"], 1)
        with mock.patch("core.push.push_to_user_async", return_value=True) as p:
            r = self.ca.post("%s/channels/%d/posts" % (V, cid),
                             {"kind": "text", "text": "Potato 40 tk today"},
                             format="json")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(r.json()["notified"], 1)
        args, kw = p.call_args
        self.assertEqual(args[0], self.b)
        self.assertEqual(args[1], "channel_post")
        self.assertEqual(args[2], "Dhaka Bazar News")
        self.assertEqual(args[4], "Potato 40 tk today")
        self.assertEqual(kw["data"]["channel_id"], str(cid))
        # per-channel mute: no push
        self.cb.post("%s/channels/%d/mute" % (V, cid), {"muted": True}, format="json")
        with mock.patch("core.push.push_to_user_async", return_value=True) as p:
            self.ca.post("%s/channels/%d/posts" % (V, cid),
                         {"kind": "text", "text": "x"}, format="json")
        p.assert_not_called()
        # B (follower) can read + react, cannot post
        d = self.cb.get("%s/channels/%d" % (V, cid)).json()
        self.assertEqual(len(d["posts"]), 2)
        self.assertFalse(d["can_publish"])
        pid = d["posts"][0]["id"]
        r = self.cb.post("%s/channels/%d/posts/%d/react" % (V, cid, pid),
                         {"emoji": "👍"}, format="json")
        self.assertEqual(r.json()["reactions"].get("👍"), 1)
        self.assertEqual(self.cb.post("%s/channels/%d/posts" % (V, cid),
                                      {"kind": "text", "text": "y"},
                                      format="json").status_code, 403)

    def test_owner_sees_own_channel_with_client_shape(self):
        cid = self.create()["id"]
        j = self.ca.get("%s/channels" % V).json()
        self.assertEqual([c["id"] for c in j["owned"]], [cid])
        self.assertTrue(j["owned"][0]["is_owner"])
        d = self.ca.get("%s/channels/%d" % (V, cid)).json()
        self.assertEqual(d["channel"]["name"], "Dhaka Bazar News")
        self.assertTrue(d["can_publish"])
        self.assertEqual(d["posts"], [])
        s = self.ca.get("%s/channels/%d/share-link" % (V, cid)).json()
        self.assertTrue(s["url"].startswith("http"))
        self.assertIn("/ch/", s["url"])
        # owner switches it to private -> leaves the directory; a non-owner
        # cannot switch it back
        r = self.ca.patch("%s/channels/%d" % (V, cid), {"is_public": False},
                          format="json")
        self.assertFalse(r.json()["channel"]["is_public"])
        self.assertEqual(self.cb.get("%s/channels/discover" % V,
                                     {"q": "bazar"}).json()["results"], [])
        self.assertEqual(self.cb.patch("%s/channels/%d" % (V, cid),
                                       {"is_public": True}, format="json"
                                       ).status_code, 403)
        # follower-list visibility no longer needs the owner switch
        r = self.ca.post("%s/channels/%d/list-visibility" % (V, cid),
                         {"visibility": "public"}, format="json")
        self.assertEqual(r.status_code, 200)

    def test_private_channel_hidden_and_joinable_by_invite(self):
        ch = self.create(is_public=False, name="Family News")
        cid = ch["id"]
        self.assertEqual(self.cb.get("%s/channels/discover" % V,
                                     {"q": "family"}).json()["results"], [])
        self.assertEqual(self.cb.get("%s/channels/%d" % (V, cid)).status_code, 404)
        self.assertEqual(self.cb.post("%s/channels/%d/follow" % (V, cid), {},
                                      format="json").status_code, 404)
        url = self.ca.get("%s/channels/%d/share-link" % (V, cid)).json()["url"]
        self.assertIn("?k=", url)
        code = url.split("?k=", 1)[1]
        self.assertEqual(self.cb.get("%s/channels/resolve" % V,
                                     {"handle": ch["handle"], "k": "wrong"}
                                     ).status_code, 404)
        r = self.cb.get("%s/channels/resolve" % V,
                        {"handle": ch["handle"], "k": code})
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["channel"]["id"], cid)
        self.assertEqual(self.cb.post("%s/channels/%d/follow" % (V, cid),
                                      {"k": code}, format="json").status_code, 200)
        self.assertEqual(self.cb.get("%s/channels/%d" % (V, cid)).status_code, 200)
        self.assertEqual(self.cb.get("%s/channels/%d/share-link" % (V, cid)
                                     ).status_code, 403)
        # new code -> old link dead for newcomers
        self.ca.post("%s/channels/%d/invite/reset" % (V, cid), {}, format="json")
        c = cl(mk("01730000003", "C"))
        self.assertEqual(c.get("%s/channels/resolve" % V,
                               {"handle": ch["handle"], "k": code}).status_code, 404)

    def test_block_hides_and_unfollows(self):
        cid = self.create()["id"]
        self.cb.post("%s/channels/%d/follow" % (V, cid), {}, format="json")
        r = self.cb.post("%s/channels/%d/block" % (V, cid), {"blocked": True},
                         format="json")
        self.assertTrue(r.json()["blocked"])
        self.assertFalse(ChannelFollower.objects.filter(user=self.b).exists())
        self.assertEqual(self.cb.get("%s/channels/discover" % V,
                                     {"q": "bazar"}).json()["results"], [])
        self.cb.post("%s/channels/%d/block" % (V, cid), {"blocked": False},
                     format="json")
        self.assertEqual(len(self.cb.get("%s/channels/discover" % V,
                                         {"q": "bazar"}).json()["results"]), 1)

    def test_severe_report_leaves_directory(self):
        cid = self.create()["id"]
        r = self.cb.post("%s/moderation/report" % V, {
            "target_kind": "channel", "target_id": cid,
            "categories": ["scam_fraud"]}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(Channel.objects.get(pk=cid).content_status, "hidden")
        self.assertEqual(self.cb.get("%s/channels/discover" % V,
                                     {"q": "bazar"}).json()["results"], [])

    def test_minor_channel_never_listed(self):
        with mock.patch("core.guardianship.guardian_user_ids", return_value={99}):
            ch = self.create()
            self.assertFalse(ch["is_public"])
            self.assertTrue(ch["minor_private"])
            r = self.ca.patch("%s/channels/%d" % (V, ch["id"]), {"is_public": True},
                              format="json")
            self.assertEqual(r.status_code, 403)
        self.assertEqual(self.cb.get("%s/channels/discover" % V,
                                     {"q": "bazar"}).json()["results"], [])

    def test_create_rate_limit(self):
        for i in range(5):
            self.create(name="Chan %d" % i)
        r = self.ca.post("%s/channels" % V, {"name": "Chan 6"}, format="json")
        self.assertEqual(r.status_code, 429)

    def test_web_fallback_pages(self):
        pub = self.create()
        priv = self.create(is_public=False, name="Secret club")
        r = self.client.get("/ch/%s" % pub["handle"])
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "Dhaka Bazar News")
        self.assertContains(r, "play.google.com")
        self.assertEqual(self.client.get("/ch/%s" % priv["handle"]).status_code, 404)
        code = Channel.objects.get(pk=priv["id"]).invite_code
        self.assertEqual(self.client.get("/ch/%s?k=%s" % (priv["handle"], code)
                                         ).status_code, 200)

    def test_discover_card_seeded(self):
        card = DiscoverCard.objects.get(key="circle_channels")
        self.assertEqual(card.route, "channels")


class CommunityJoinTests(TestCase):
    def setUp(self):
        cache.clear()
        self.a, self.b = mk("01740000001", "Admin A"), mk("01740000002", "B")
        self.c = mk("01740000003", "C")
        self.ca, self.cb, self.cc = cl(self.a), cl(self.b), cl(self.c)

    def test_join_by_link_with_approval_then_chat(self):
        r = self.ca.post("%s/community/create" % V, {
            "name": "Mirpur 10 neighbours", "description": "Block C",
            "groups": ["Bazar", "Security"]}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        cm = r.json()
        self.assertIn("/cm/", cm["invite_url"])
        code = cm["invite_code"]
        mine = self.ca.get("%s/communities" % V).json()["results"]
        self.assertEqual(mine[0]["viewer_role"], "admin")
        self.assertEqual(mine[0]["group_count"], 3)
        # outsider: private -> groups hidden, topic join refused
        self.assertEqual(self.cb.get("%s/community/%d/groups" % (V, cm["id"])
                                     ).status_code, 404)
        topic = CommunityGroup.objects.get(community_id=cm["id"], name="Bazar")
        self.assertEqual(self.cb.post("%s/community/group/%d/join" % (V, topic.id),
                                      {}, format="json").status_code, 403)
        p = self.cb.get("%s/communities/preview" % V, {"code": code}).json()
        self.assertEqual((p["name"], p["state"]), ("Mirpur 10 neighbours", "none"))
        self.assertNotIn("invite_code", p)
        with mock.patch("core.push.push_to_user_async", return_value=True) as push:
            r = self.cb.post("%s/communities/join" % V, {"code": code.upper()},
                             format="json")
        self.assertEqual(r.json()["state"], "requested")
        self.assertEqual(push.call_args[0][0], self.a)
        self.assertEqual(push.call_args[0][1], "community_join")
        g = self.ca.get("%s/community/%d/groups" % (V, cm["id"])).json()
        req = g["join_requests"][0]
        self.assertEqual(req["requester_name"], "B")
        with mock.patch("core.push.push_to_user_async", return_value=True):
            r = self.ca.post("%s/community/join-request/%d/approve" % (V, req["id"]),
                             {}, format="json")
        self.assertEqual(r.json()["state"], "approved")
        self.assertEqual(self.cb.get("%s/communities" % V).json()["results"][0]
                         ["viewer_role"], "member")
        ann = CommunityGroup.objects.get(community_id=cm["id"], kind="announcements")
        self.assertTrue(CircleGroupMember.objects.filter(
            group=ann.circle_group, member=self.b, status="active").exists())
        self.assertTrue(ann.circle_group.announcements_only)
        # member list
        names = [m.get("name") for m in self.cb.get(
            "%s/community/%d/members" % (V, cm["id"])).json()["results"]]
        self.assertIn("Admin A", names)
        # open topic group: one tap -> in the real group chat
        r = self.cb.post("%s/community/group/%d/join" % (V, topic.id), {},
                         format="json")
        self.assertEqual(r.json()["action"], "joined")
        topic.refresh_from_db()
        self.assertTrue(CircleGroupMember.objects.filter(
            group=topic.circle_group, member=self.b, status="active").exists())
        self.assertIn(topic.circle_group_id, [
            x["id"] for x in self.cb.get("%s/circle/groups" % V).json()["results"]])
        # leave -> out of the chats too
        r = self.cb.post("%s/community/%d/leave" % (V, cm["id"]), {}, format="json")
        self.assertTrue(r.json()["left"])
        self.assertFalse(CircleGroupMember.objects.filter(
            member=self.b, status="active").exists())

    def test_wrong_code_and_report(self):
        self.assertEqual(self.cb.post("%s/communities/join" % V, {"code": "nope"},
                                      format="json").status_code, 404)
        cm = self.ca.post("%s/community/create" % V, {"name": "Club"},
                          format="json").json()
        r = self.cc.post("%s/moderation/report" % V, {
            "target_kind": "community", "target_id": cm["id"],
            "categories": ["spam"]}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()["accepted"])
        self.assertEqual(self.client.get("/cm/%s" % Community.objects.get(
            pk=cm["id"]).invite_code).status_code, 200)

    def test_invite_admins_only(self):
        cm = self.ca.post("%s/community/create" % V, {"name": "Club"},
                          format="json").json()
        self.assertEqual(self.cb.get("%s/community/%d/invite" % (V, cm["id"])
                                     ).status_code, 404)
        old = cm["invite_code"]
        new = self.ca.post("%s/community/%d/invite" % (V, cm["id"]), {},
                           format="json").json()["code"]
        self.assertNotEqual(old, new)
        self.assertEqual(self.cb.get("%s/communities/preview" % V,
                                     {"code": old}).status_code, 404)
