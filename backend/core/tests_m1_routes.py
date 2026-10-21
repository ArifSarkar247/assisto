"""m1-messenger scope 2: family accounting (balance maths), circle chats,
community request inbox, notif Done, journey timeline, disaster feed,
medicine-db report, nested group URL shapes (+ old aliases)."""
from datetime import timedelta

from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core.models import (CircleGroup, CircleGroupMember, CircleMember,
                         CircleMessage, CommunityMessageRequest, FamExpense,
                         FamilyMember, GroupPoll, Journey, JourneyPoint,
                         JourneyWatcher, Medicine, MedicineLog, Meeting,
                         Reminder, Subscription, SupportTicket, Todo, User)

V = "/api/v1"


def mk(phone, name):
    return User.objects.create_user(name=name, phone=phone, password="pw12345!",
                                    language="en")


def cl(u):
    c = APIClient()
    c.force_authenticate(u)
    c.credentials(HTTP_ACCEPT_LANGUAGE="en")
    return c


class FamAcctTests(TestCase):
    def setUp(self):
        self.u = mk("01720000001", "Dad")
        self.mom = FamilyMember.objects.create(user=self.u, name="Mom")
        self.kid = FamilyMember.objects.create(user=self.u, name="Kid")
        self.c = cl(self.u)
        self.other = cl(mk("01720000009", "Other"))

    def add(self, payer, total, members, **kw):
        return self.c.post("%s/family/accounting/expenses" % V, {
            "payer": payer, "total_poisha": total, "category": "groceries",
            "mode": "equal", "members": members, **kw}, format="json")

    def test_equal_split_remainder_and_summary(self):
        r = self.add("self", 1000, ["self", self.mom.id, self.kid.id])
        self.assertEqual(r.status_code, 201, r.content)
        shares = [s["share_poisha"] for s in r.json()["shares"]]
        self.assertEqual(shares, [334, 333, 333])
        s = self.c.get("%s/family/accounting/summary" % V).json()
        self.assertEqual(s["total_poisha"], 1000)
        nets = {m["member"]: m["net_poisha"] for m in s["members"]}
        self.assertEqual(nets["self"], 666)
        self.assertEqual(sum(nets.values()), 0)
        transfers = {(t["from"], t["to"]): t["amount_poisha"]
                     for t in s["settlements"]}
        self.assertEqual(transfers, {(self.mom.id, "self"): 333,
                                     (self.kid.id, "self"): 333})
        self.assertIn("owes", s["settlements"][0]["message"]["en"])

    def test_settle_partial_then_full(self):
        self.add("self", 1000, ["self", self.mom.id])
        u = "%s/family/accounting/settle" % V
        r = self.c.post(u, {"from": self.mom.id, "to": "self",
                            "amount_poisha": 200}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["remaining"][0]["amount_poisha"], 300)
        # more than owed is refused
        r = self.c.post(u, {"from": self.mom.id, "to": "self",
                            "amount_poisha": 301}, format="json")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()["max_poisha"], 300)
        r = self.c.post(u, {"from": self.mom.id, "to": "self",
                            "amount_poisha": 300}, format="json")
        self.assertEqual(r.json()["remaining"], [])
        # wrong direction: self doesn't owe
        r = self.c.post(u, {"from": "self", "to": self.mom.id,
                            "amount_poisha": 1}, format="json")
        self.assertEqual(r.status_code, 400)
        # settlements never show as expenses
        self.assertEqual(len(self.c.get("%s/family/accounting/expenses" % V)
                             .json()["expenses"]), 1)

    def test_multi_payer_minimal_transfers(self):
        self.add("self", 900, ["self", self.mom.id, self.kid.id])
        self.add(self.mom.id, 600, ["self", self.mom.id, self.kid.id])
        s = self.c.get("%s/family/accounting/summary" % V).json()
        # self +600, mom +100, kid -500 -> kid pays self 500? greedy: kid->self 500
        total_moved = sum(t["amount_poisha"] for t in s["settlements"])
        self.assertEqual(total_moved, 500)
        self.assertTrue(all(t["from"] == self.kid.id for t in s["settlements"]))

    def test_exact_and_shares_modes(self):
        r = self.c.post("%s/family/accounting/expenses" % V, {
            "payer": "self", "mode": "exact", "parts": [
                {"member": "self", "amount_poisha": 100},
                {"member": self.mom.id, "amount_poisha": 250}]}, format="json")
        self.assertEqual(r.json()["total_poisha"], 350)
        r = self.c.post("%s/family/accounting/expenses" % V, {
            "payer": "self", "mode": "shares", "total_poisha": 1000, "parts": [
                {"member": "self", "weight": 1},
                {"member": self.mom.id, "weight": 2}]}, format="json")
        self.assertEqual(sum(s["share_poisha"] for s in r.json()["shares"]), 1000)

    def test_validation_and_isolation(self):
        self.assertEqual(self.add("self", 0, ["self"]).status_code, 400)
        self.assertEqual(self.add(99999, 100, ["self"]).status_code, 400)
        self.assertEqual(self.add("self", 100, [99999]).status_code, 400)
        eid = self.add("self", 100, ["self", self.mom.id]).json()["id"]
        # another user's member id is unknown to them; and can't delete mine
        r = self.other.post("%s/family/accounting/expenses/delete" % V,
                            {"id": eid}, format="json")
        self.assertEqual(r.status_code, 404)
        self.assertEqual(self.other.get("%s/family/accounting/expenses" % V)
                         .json()["expenses"], [])
        r = self.c.post("%s/family/accounting/expenses/delete" % V,
                        {"id": eid}, format="json")
        self.assertEqual(r.json(), {"ok": True})

    def test_pool(self):
        r = self.c.post("%s/family/accounting/pool" % V, {"target_poisha": 1000},
                        format="json")
        self.assertEqual(r.json()["target"], 1000)
        r = self.c.post("%s/family/accounting/pool/contribute" % V,
                        {"member": self.mom.id, "amount_poisha": 850},
                        format="json")
        j = r.json()
        self.assertEqual(j["collected"], 850)
        self.assertEqual(j["state"], "near")
        self.assertEqual(j["breakdown"][0]["name"], "Mom")
        self.assertEqual(self.c.post("%s/family/accounting/pool/contribute" % V,
                                     {"member": self.mom.id, "amount_poisha": -1},
                                     format="json").status_code, 400)
        self.assertEqual(self.c.get("%s/family/accounting/pool" % V)
                         .json()["collected"], 850)
        self.assertEqual(self.c.get("%s/family/accounting/summary?month=13-99" % V)
                         .status_code, 400)


class MiscRouteTests(TestCase):
    def setUp(self):
        self.a = mk("01730000001", "Amina")
        self.b = mk("01730000002", "Bilal")
        self.ab = CircleMember.objects.create(user=self.a, peer_user=self.b,
                                              name="Bilal", state="accepted",
                                              phone=self.b.phone)
        self.ba = CircleMember.objects.create(user=self.b, peer_user=self.a,
                                              name="Amina", state="accepted",
                                              phone=self.a.phone)
        self.ca, self.cb = cl(self.a), cl(self.b)

    def test_circle_chats_unread_and_last(self):
        CircleMessage.objects.create(member=self.ba, sender=self.b,
                                     ciphertext="Q1Q=", nonce="Tg==")
        rows = self.ca.get("%s/circle/chats" % V).json()["results"]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["unread"], 1)
        self.assertEqual(rows[0]["last"]["ciphertext"], "Q1Q=")
        self.assertFalse(rows[0]["last"]["mine"])

    def test_community_request_inbox_recipient_only(self):
        CommunityMessageRequest.objects.create(sender=self.b, recipient=self.a,
                                               first_ciphertext="Q1Q=")
        self.assertEqual(len(self.ca.get("%s/community/message-requests" % V)
                             .json()["results"]), 1)
        self.assertEqual(self.cb.get("%s/community/message-requests" % V)
                         .json()["results"], [])

    def test_notif_done_dispatch(self):
        r = Reminder.objects.create(user=self.a, title="x",
                                    due_at=timezone.now())
        self.assertEqual(self.ca.post("%s/notif/reminders/reminder:%d/done"
                                      % (V, r.id), {}, format="json").status_code, 200)
        r.refresh_from_db()
        self.assertTrue(r.done)
        rr = Reminder.objects.create(user=self.a, title="d", recurrence="daily",
                                     due_at=timezone.now())
        self.ca.post("%s/notif/reminders/reminder:%d/done" % (V, rr.id), {},
                     format="json")
        rr.refresh_from_db()
        self.assertFalse(rr.done)
        self.assertGreater(rr.due_at, timezone.now() + timedelta(hours=20))
        t = Todo.objects.create(user=self.a, title="t")
        self.ca.post("%s/notif/reminders/todo:%d/done" % (V, t.id), {}, format="json")
        t.refresh_from_db()
        self.assertTrue(t.done)
        m = Medicine.objects.create(user=self.a, name="Napa", times=["08:00"])
        self.ca.post("%s/notif/reminders/medicine:%d:08:00/done" % (V, m.id), {},
                     format="json")
        self.assertTrue(MedicineLog.objects.get(medicine=m).taken)
        s = Subscription.objects.create(user=self.a, name="Net", amount=500,
                                        cycle="monthly",
                                        next_due=timezone.localdate())
        self.ca.post("%s/notif/reminders/subscription:%d/done" % (V, s.id), {},
                     format="json")
        s.refresh_from_db()
        self.assertGreater(s.next_due, timezone.localdate())
        mt = Meeting.objects.create(user=self.a, title="m",
                                    when=timezone.now() + timedelta(hours=2))
        iid = "meeting:%d" % mt.id
        self.ca.post("%s/notif/reminders/%s/done" % (V, iid), {}, format="json")
        feed = self.ca.get("%s/notif/reminders" % V).json()["sections"]
        ids = [i["id"] for sec in feed.values() for i in sec]
        self.assertNotIn(iid, ids)
        # someone else's reminder
        self.assertEqual(self.cb.post("%s/notif/reminders/reminder:%d/done"
                                      % (V, r.id), {}, format="json").status_code, 404)
        self.assertEqual(self.ca.post("%s/notif/reminders/zzz/done" % V, {},
                                      format="json").status_code, 404)

    def test_snooze_accepts_app_preset(self):
        r = Reminder.objects.create(user=self.a, title="x", due_at=timezone.now())
        j = self.ca.post("%s/notif/reminders/reminder:%d/snooze" % (V, r.id),
                         {"preset": "1h"}, format="json").json()
        self.assertTrue(j["persisted"])

    def test_journey_timeline_watchers_only(self):
        j = Journey.objects.create(traveller=self.a, destination={"name": "Home"},
                                   expires_at=timezone.now() + timedelta(hours=5))
        JourneyWatcher.objects.create(journey=j, member=self.ab)
        self.ca.post("%s/journey/%d/location" % (V, j.id),
                     {"lat": 23.7, "lng": 90.4, "battery": 50}, format="json")
        r = self.cb.get("%s/journey/%d/timeline" % (V, j.id))
        self.assertEqual(r.status_code, 200)
        self.assertEqual(len(r.json()["points"]), 1)
        stranger = cl(mk("01730000009", "S"))
        self.assertEqual(stranger.get("%s/journey/%d/timeline" % (V, j.id))
                         .status_code, 404)
        Journey.objects.filter(pk=j.pk).update(
            expires_at=timezone.now() - timedelta(minutes=1))
        r = self.ca.get("%s/journey/%d/timeline" % (V, j.id)).json()
        self.assertTrue(r["expired"])
        self.assertEqual(r["points"], [])
        self.assertEqual(JourneyPoint.objects.count(), 0)

    def test_disaster_feed_honest(self):
        j = self.ca.get("%s/disaster/feed" % V).json()
        self.assertEqual(j["feed_state"], "no_key")
        self.assertEqual(j["warnings"], [])
        self.assertTrue(all(s.get("sample") for s in j["samples"]))

    def test_medicine_report_persists(self):
        r = self.ca.post("%s/medicine-db/report" % V,
                         {"brand": "Napa", "issue": "wrong price"}, format="json")
        self.assertEqual(r.status_code, 201)
        self.assertIn("Napa", SupportTicket.objects.get(user=self.a).message)
        self.assertEqual(self.ca.post("%s/medicine-db/report" % V, {},
                                      format="json").status_code, 400)


class GroupShapeTests(TestCase):
    def setUp(self):
        self.a = mk("01740000001", "A")
        self.b = mk("01740000002", "B")
        self.c = mk("01740000003", "C")
        self.ca, self.cb, self.cc = cl(self.a), cl(self.b), cl(self.c)
        self.g = CircleGroup.objects.create(creator=self.a, name="G")
        self.g2 = CircleGroup.objects.create(creator=self.c, name="G2")
        CircleGroupMember.objects.create(group=self.g, member=self.a, role="admin")
        self.mb = CircleGroupMember.objects.create(group=self.g, member=self.b)
        CircleGroupMember.objects.create(group=self.g2, member=self.c, role="admin")
        CircleGroupMember.objects.create(group=self.g2, member=self.a)
        self.poll = GroupPoll.objects.create(group=self.g, author=self.a,
                                             option_count=2)

    def test_nested_vote_and_group_mismatch(self):
        r = self.cb.post("%s/circle/groups/%d/polls/%d/vote"
                         % (V, self.g.id, self.poll.id), {"choices": [1]},
                         format="json")
        self.assertEqual(r.status_code, 200, r.content)
        # poll is not in g2 -> 404 even though A is a member of g2
        r = self.ca.post("%s/circle/groups/%d/polls/%d/vote"
                         % (V, self.g2.id, self.poll.id), {"choices": [0]},
                         format="json")
        self.assertEqual(r.status_code, 404)
        # old flat alias still works
        r = self.cb.post("%s/circle/groups/polls/%d/vote" % (V, self.poll.id),
                         {"choices": [0]}, format="json")
        self.assertEqual(r.status_code, 200)

    def test_nested_message_action_checks_group(self):
        x = CircleMessage.objects.create(group=self.g, sender=self.b,
                                         ciphertext="Q1Q=", nonce="Tg==")
        r = self.ca.post("%s/circle/groups/%d/messages/%d/pin"
                         % (V, self.g.id, x.id), {"pin": True}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        r = self.ca.post("%s/circle/groups/%d/messages/%d/pin"
                         % (V, self.g2.id, x.id), {"pin": True}, format="json")
        self.assertEqual(r.status_code, 404)
        r = self.ca.post("%s/circle/groups/messages/%d/react" % (V, x.id),
                         {"emoji": "x"}, format="json")
        self.assertEqual(r.status_code, 200)

    def test_nested_member_event(self):
        r = self.ca.post("%s/circle/groups/%d/members/%d" % (V, self.g.id, self.mb.id),
                         {"event": "promote"}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.mb.refresh_from_db()
        self.assertEqual(self.mb.role, "admin")
        self.assertEqual(self.cc.post("%s/circle/groups/%d/members/%d"
                                      % (V, self.g.id, self.mb.id),
                                      {"event": "remove"}, format="json")
                         .status_code, 404)
        self.assertEqual(self.ca.post("%s/circle/groups/%d/members/%d"
                                      % (V, self.g.id, self.mb.id), {},
                                      format="json").status_code, 400)

    def test_add_member_by_member_id(self):
        d = mk("01740000004", "D")
        edge_ad = CircleMember.objects.create(user=self.a, peer_user=d,
                                              phone=d.phone, state="accepted")
        r = self.ca.post("%s/circle/groups/%d/members" % (V, self.g.id),
                         {"member_id": edge_ad.id}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(r.json()["user_id"], d.id)

    def test_group_media_honest(self):
        CircleMessage.objects.create(group=self.g, sender=self.a,
                                     content_type="image", blob_ref="b1")
        j = self.cb.get("%s/circle/groups/%d/media" % (V, self.g.id)).json()
        self.assertEqual(len(j["items"]), 1)
        self.assertFalse(j["backend_ready"])
        self.assertEqual(self.cc.get("%s/circle/groups/%d/media" % (V, self.g.id))
                         .status_code, 404)
