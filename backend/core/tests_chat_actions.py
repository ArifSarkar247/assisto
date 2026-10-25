"""chat-actions (owner 26 Oct) — WhatsApp-style chat actions on TWO accounts
(A = Amina, B = Bilal; C = Chaya, an outsider).

Run: manage.py test core.tests_chat_actions --settings=assisto_backend.settings_test
"""
from datetime import timedelta
from io import StringIO

from django.core.management import call_command
from django.test import override_settings
from django.utils import timezone

from core.models import (ChatOrganiseState, ChatSettings, CircleGroup,
                         CircleGroupMember, CircleMediaBlob, CircleMember,
                         CircleMessage, CircleMessageCopy, CircleReport,
                         MsgChatPref, MsgGroupTimer, MsgUserSettings)
from core.tests_md1_media import V, _Base as _MdBase


class _Base(_MdBase):
    def send(self, client, edge, cmid, ct="text"):
        r = client.post("%s/circle/%d/messages" % (V, edge.id), {
            "ciphertext": "Q1Q=", "nonce": "Tg==", "content_type": ct,
            "client_msg_id": cmid}, format="json")
        self.assertIn(r.status_code, (200, 201), r.content)
        return r.json()

    def msgs(self, client, edge):
        r = client.get("%s/circle/%d/messages" % (V, edge.id))
        self.assertEqual(r.status_code, 200, r.content)
        return r.json()["results"]

    def chat_ids(self, client):
        r = client.get(V + "/circle/chats")
        self.assertEqual(r.status_code, 200)
        return [str(x["id"]) for x in r.json()["results"]]

    def act(self, client, mid, scope):
        return client.post("%s/circle/messages/%d/delete" % (V, mid),
                           {"scope": scope}, format="json")


# ===================================================== delete for everyone
class DeleteForEveryoneTests(_Base):
    def test_within_window_removes_ciphertext_and_blob_for_b(self):
        ref = self.upload()
        mid = self.send_media(ref).json()["id"]
        CircleMessageCopy.objects.create(message_id=mid, for_user=self.b, by_user=self.a,
                                         ciphertext="Q0Q=", nonce="Tg==")
        r = self.act(self.ca, mid, "everyone")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["deleted"], "everyone")
        x = CircleMessage.objects.get(pk=mid)
        self.assertEqual((x.ciphertext, x.nonce), ("", ""))
        self.assertFalse(CircleMediaBlob.objects.filter(ref=ref).exists())
        self.assertFalse(CircleMessageCopy.objects.filter(message_id=mid)
                         .exists())
        # B sees the tombstone (server metadata only, no ciphertext)
        row = [m for m in self.msgs(self.cb, self.ba) if m["id"] == mid][0]
        self.assertEqual(row["deleted"], "everyone")
        self.assertEqual(row["ciphertext"], "")

    def test_outside_window_refused(self):
        mid = self.send(self.ca, self.ab, "m1")["id"]
        CircleMessage.objects.filter(pk=mid).update(
            created_at=timezone.now() - timedelta(hours=49))
        r = self.act(self.ca, mid, "everyone")
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()["detail"], "delete_window")
        self.assertEqual(CircleMessage.objects.get(pk=mid).ciphertext, "Q1Q=")

    @override_settings(CIRCLE_DELETE_EVERYONE_WINDOW_MIN=10)
    def test_window_is_server_configurable(self):
        mid = self.send(self.ca, self.ab, "m1")["id"]
        r = self.ca.get("%s/circle/%d/messages" % (V, self.ab.id))
        self.assertEqual(r.json()["delete_window_min"], 10)
        CircleMessage.objects.filter(pk=mid).update(
            created_at=timezone.now() - timedelta(minutes=11))
        self.assertEqual(self.act(self.ca, mid, "everyone").status_code, 403)

    def test_only_sender_and_never_an_outsider(self):
        mid = self.send(self.ca, self.ab, "m1")["id"]
        self.assertEqual(self.act(self.cb, mid, "everyone").status_code, 403)
        self.assertEqual(self.act(self.cc, mid, "everyone").status_code, 404)
        self.assertEqual(self.act(self.cc, mid, "me").status_code, 404)


# ============================================================ delete for me
class DeleteForMeTests(_Base):
    def test_removes_only_my_copy_and_never_redelivered(self):
        mid = self.send(self.ca, self.ab, "m1")["id"]
        CircleMessageCopy.objects.create(message_id=mid, for_user=self.b, by_user=self.a,
                                         ciphertext="Q0Q=", nonce="Tg==")
        r = self.act(self.cb, mid, "me")
        self.assertEqual(r.json()["deleted"], "me")
        # a "restore" (fresh fetch, new device) never brings it back for B
        self.assertNotIn(mid, [m["id"] for m in self.msgs(self.cb, self.ba)])
        self.assertFalse(CircleMessageCopy.objects.filter(
            message_id=mid, for_user=self.b).exists())
        # A still has it
        self.assertIn(mid, [m["id"] for m in self.msgs(self.ca, self.ab)])

    def test_deleted_by_both_is_gone_from_server(self):
        ref = self.upload()
        mid = self.send_media(ref).json()["id"]
        self.act(self.cb, mid, "me")
        self.assertTrue(CircleMessage.objects.filter(pk=mid).exists())
        self.act(self.ca, mid, "me")
        self.assertFalse(CircleMessage.objects.filter(pk=mid).exists())
        self.assertFalse(CircleMediaBlob.objects.filter(ref=ref).exists())


# =============================================================== clear chat
class ClearChatTests(_Base):
    def test_clear_without_starred(self):
        m1 = self.send(self.ca, self.ab, "m1")["id"]
        self.ca.post("%s/circle/messages/%d/star" % (V, m1), {}, format="json")
        r = self.ca.post("%s/circle/%d/clear" % (V, self.ab.id), {},
                         format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(self.msgs(self.ca, self.ab), [])
        self.assertEqual(len(self.msgs(self.cb, self.ba)), 1)   # B untouched
        self.assertIn(str(self.ab.id), self.chat_ids(self.ca))  # row stays

    def test_clear_keep_starred(self):
        m1 = self.send(self.ca, self.ab, "m1")["id"]
        m2 = self.send(self.cb, self.ba, "m2")["id"]
        self.ca.post("%s/circle/messages/%d/star" % (V, m2), {}, format="json")
        r = self.ca.post("%s/circle/%d/clear" % (V, self.ab.id),
                         {"keep_starred": True}, format="json")
        self.assertTrue(r.json()["keep_starred"])
        self.assertEqual([m["id"] for m in self.msgs(self.ca, self.ab)], [m2])
        self.assertEqual(len(self.msgs(self.cb, self.ba)), 2)
        self.assertTrue(CircleMessage.objects.filter(pk=m1).exists())

    def test_cleared_by_both_is_deleted_for_real(self):
        mid = self.send(self.ca, self.ab, "m1")["id"]
        self.ca.post("%s/circle/%d/clear" % (V, self.ab.id), {}, format="json")
        self.assertTrue(CircleMessage.objects.filter(pk=mid).exists())
        self.cb.post("%s/circle/%d/clear" % (V, self.ba.id), {}, format="json")
        self.assertFalse(CircleMessage.objects.filter(pk=mid).exists())

    def test_outsider_cannot_clear(self):
        self.assertEqual(self.cc.post("%s/circle/%d/clear" % (V, self.ab.id),
                                      {}, format="json").status_code, 404)


# ============================================================== delete chat
class DeleteChatTests(_Base):
    def test_hides_for_a_only_and_membership_intact(self):
        ref = self.upload()
        self.send_media(ref)
        old = self.send(self.cb, self.ba, "m2")["id"]
        ChatOrganiseState.objects.create(user=self.a, chat_kind="member",
                                         chat_id=str(self.ab.id), pinned=True)
        r = self.ca.post("%s/circle/%d/delete-chat" % (V, self.ab.id),
                         {"delete_media": True}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        j = r.json()
        self.assertEqual(j["media_refs"], [ref])   # phone wipes its files
        self.assertTrue(j["delete_media"])
        self.assertTrue(j["deleted_at"])
        self.assertNotIn(str(self.ab.id), self.chat_ids(self.ca))
        self.assertEqual(self.msgs(self.ca, self.ab), [])
        self.assertFalse(ChatOrganiseState.objects.get(
            user=self.a, chat_id=str(self.ab.id)).pinned)
        # B unaffected
        self.assertIn(str(self.ba.id), self.chat_ids(self.cb))
        self.assertEqual(len(self.msgs(self.cb, self.ba)), 2)
        # membership intact on both sides
        self.assertEqual(CircleMember.objects.get(pk=self.ab.id).state,
                         "accepted")
        self.assertEqual(CircleMember.objects.get(pk=self.ba.id).state,
                         "accepted")
        # a new message from B re-surfaces the row with ONLY the new message
        new = self.send(self.cb, self.ba, "m3")["id"]
        self.assertIn(str(self.ab.id), self.chat_ids(self.ca))
        ids = [m["id"] for m in self.msgs(self.ca, self.ab)]
        self.assertEqual(ids, [new])
        self.assertNotIn(old, ids)

    def test_outsider_cannot_delete(self):
        r = self.cc.post("%s/circle/%d/delete-chat" % (V, self.ab.id), {},
                         format="json")
        self.assertEqual(r.status_code, 404)
        self.assertIsNone(MsgChatPref.objects.filter(user=self.a).first())


# =================================================================== groups
class GroupActionTests(_Base):
    def setUp(self):
        super().setUp()
        self.g = CircleGroup.objects.create(creator=self.a, name="Family")
        CircleGroupMember.objects.create(group=self.g, member=self.a,
                                         role="admin")
        self.gmb = CircleGroupMember.objects.create(group=self.g,
                                                    member=self.b)

    def p(self, tail):
        return "%s/circle/groups/%d/%s" % (V, self.g.id, tail)

    def gmsg(self, sender, **kw):
        return CircleMessage.objects.create(group=self.g, sender=sender,
                                            ciphertext="Q1Q=", nonce="Tg==",
                                            **kw)

    def group_row(self, client):
        rows = client.get(V + "/circle/chats").json()["results"]
        return [x for x in rows if x.get("group_id") == self.g.id]

    def test_delete_chat_keeps_group_membership(self):
        self.gmsg(self.a)
        r = self.cb.post(self.p("delete-chat"), {}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(self.group_row(self.cb), [])
        self.assertEqual(len(self.group_row(self.ca)), 1)
        self.assertEqual(CircleGroupMember.objects.get(pk=self.gmb.pk).status,
                         "active")
        self.gmsg(self.a)
        self.assertEqual(len(self.group_row(self.cb)), 1)
        self.assertEqual(self.cc.post(self.p("delete-chat"), {},
                                      format="json").status_code, 404)

    def test_delete_for_me_drops_my_sealed_copy(self):
        x = self.gmsg(self.a, per_recipient={
            str(self.gmb.id): {"ciphertext": "Qg==", "nonce": "Tg=="},
            "999": {"ciphertext": "Qw==", "nonce": "Tg=="}})
        r = self.cb.post(self.p("messages/%d/delete" % x.id), {},
                         format="json")
        self.assertEqual(r.json()["deleted"], "me")
        x.refresh_from_db()
        self.assertNotIn(str(self.gmb.id), x.per_recipient)
        self.assertIn(self.b.id, x.hidden_for)

    def test_delete_for_everyone_window(self):
        x = self.gmsg(self.a, per_recipient={str(self.gmb.id): {
            "ciphertext": "Qg==", "nonce": "Tg=="}})
        r = self.ca.post(self.p("messages/%d/delete" % x.id),
                         {"scope": "everyone"}, format="json")
        self.assertEqual(r.status_code, 200)
        x.refresh_from_db()
        self.assertEqual((x.deleted, x.ciphertext, x.per_recipient),
                         ("everyone", "", None))
        y = self.gmsg(self.a)
        CircleMessage.objects.filter(pk=y.pk).update(
            created_at=timezone.now() - timedelta(days=3))
        self.assertEqual(self.ca.post(self.p("messages/%d/delete" % y.id),
                                      {"scope": "everyone"},
                                      format="json").status_code, 403)

    def test_clear_keep_starred_in_group(self):
        a = self.gmsg(self.a)
        b = self.gmsg(self.a, starred_by=[self.b.id])
        self.cb.post(self.p("clear"), {"keep_starred": True}, format="json")
        ids = [m["id"] for m in self.cb.get(self.p("messages")).json()
               ["results"]]
        self.assertEqual(ids, [b.id])
        self.assertNotIn(a.id, ids)

    def test_disappearing_admin_only(self):
        r = self.cb.post(self.p("disappearing"), {"ttl": "7d"}, format="json")
        self.assertEqual(r.status_code, 403)
        r = self.ca.post(self.p("disappearing"), {"ttl": "7d"}, format="json")
        self.assertEqual(r.json()["disappearing_sec"], 604800)
        self.assertEqual(self.group_row(self.cb)[0]["disappearing_sec"],
                         604800)

    def test_group_favourite_on_chat_row(self):
        self.cb.post(self.p("favourite"), {"on": True}, format="json")
        self.assertTrue(self.group_row(self.cb)[0]["favourite"])
        self.assertFalse(self.group_row(self.ca)[0]["favourite"])


# ==================================================== disappearing messages
class DisappearingTests(_Base):
    def test_timer_set_by_a_applies_to_both_and_purge_removes(self):
        r = self.ca.post("%s/messenger/chat/%d/settings" % (V, self.ab.id),
                         {"disappearing_sec": 604800}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        for c, e in ((self.ca, self.ab), (self.cb, self.ba)):
            row = [x for x in c.get(V + "/circle/chats").json()["results"]
                   if str(x["id"]) == str(e.id)][0]
            self.assertEqual(row["disappearing_sec"], 604800)   # timer icon
        ref = self.upload()
        mid = self.send_media(ref).json()["id"]
        bmid = self.send(self.cb, self.ba, "b1")["id"]
        old = timezone.now() - timedelta(days=8)
        CircleMessage.objects.filter(pk__in=[mid, bmid]).update(created_at=old)
        MsgChatPref.objects.filter(chat_kind="member").update(
            disappearing_since=old - timedelta(minutes=1))
        out = StringIO()
        call_command("purge_disappearing", stdout=out)
        self.assertIn("1:1=2", out.getvalue())
        self.assertFalse(CircleMessage.objects.filter(
            pk__in=[mid, bmid]).exists())
        self.assertFalse(CircleMediaBlob.objects.filter(ref=ref).exists())

    def test_default_timer_for_new_chats(self):
        r = self.ca.get(V + "/circle/settings/default-timer")
        self.assertEqual(r.json()["ttl"], "off")
        r = self.ca.post(V + "/circle/settings/default-timer", {"ttl": "24h"},
                         format="json")
        self.assertEqual(r.json()["disappearing_sec"], 86400)
        self.assertEqual(self.ca.post(V + "/circle/settings/default-timer",
                                      {"ttl": "1h"},
                                      format="json").status_code, 400)
        # first message of a NEW chat starts the timer for BOTH sides
        j = self.send(self.ca, self.ab, "m1")
        self.assertEqual(j["default_timer_sec"], 86400)
        self.assertEqual(ChatSettings.objects.get(
            user=self.b, peer=self.ba).disappearing_sec, 86400)
        # not re-applied once the chat exists
        self.assertNotIn("default_timer_sec", self.send(self.ca, self.ab, "m2"))
        # a group A creates starts with it too
        r = self.ca.post(V + "/circle/groups", {"name": "Trip"}, format="json")
        t = MsgGroupTimer.objects.get(group_id=r.json()["id"])
        self.assertEqual(t.disappearing_sec, 86400)

    def test_default_timer_never_touches_existing_chat(self):
        self.send(self.ca, self.ab, "m1")
        MsgUserSettings.objects.update_or_create(
            user=self.b, defaults={"default_disappearing_sec": 604800})
        j = self.send(self.cb, self.ba, "b1")
        self.assertNotIn("default_timer_sec", j)
        self.assertFalse(ChatSettings.objects.filter(
            disappearing_sec__gt=0).exists())


# ============================================================ block / report
class BlockReportFromListTests(_Base):
    def test_block_and_report_from_list(self):
        r = self.ca.post("%s/circle/%d/controls" % (V, self.ab.id),
                         {"blocked": True}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertTrue(CircleMember.objects.get(pk=self.ab.id).blocked)
        r = self.ca.post("%s/messenger/chat/%d/report" % (V, self.ab.id),
                         {"categories": ["spam"], "last_messages": []},
                         format="json")
        self.assertIn(r.status_code, (200, 201), r.content)
        # an outsider can do neither
        self.assertEqual(self.cc.post("%s/circle/%d/controls" % (V, self.ab.id),
                                      {"blocked": True},
                                      format="json").status_code, 404)
        self.assertEqual(self.cc.post(
            "%s/messenger/chat/%d/report" % (V, self.ab.id),
            {"categories": ["spam"]}, format="json").status_code, 404)
        self.assertEqual(CircleReport.objects.count(), 0)
