"""gap-circle (17 Nov gap sweep) — group chat basics a user expects from any
good messenger: a reply keeps its quote, the sender can edit a text inside the
window, delete-for-everyone works from the group screen. Two accounts
(A = admin/sender, B = member) + C (outsider).

Run: manage.py test core.tests_gap_circle --settings=assisto_backend.settings_test
"""
from datetime import timedelta

from django.utils import timezone

from core.models import (CircleGroup, CircleGroupMember, CircleMessage,
                         CircleMessageCopy)
from core.tests_md1_media import V, _Base


class GroupReplyEditTests(_Base):
    def setUp(self):
        super().setUp()
        self.g = CircleGroup.objects.create(creator=self.a, name="Family")
        CircleGroupMember.objects.create(group=self.g, member=self.a,
                                         role="admin")
        self.gmb = CircleGroupMember.objects.create(group=self.g,
                                                    member=self.b)

    def p(self, tail):
        return "%s/circle/groups/%d/%s" % (V, self.g.id, tail)

    def pr(self, ct="Qg=="):
        return {str(self.gmb.id): {"ciphertext": ct, "nonce": "Tg=="}}

    def post(self, client, cmid, **extra):
        body = {"recipient_ids": [self.gmb.id], "per_recipient": self.pr(),
                "client_msg_id": cmid}
        body.update(extra)
        return client.post(self.p("messages"), body, format="json")

    def rows(self, client):
        r = client.get(self.p("messages"))
        self.assertEqual(r.status_code, 200, r.content)
        return {x["id"]: x for x in r.json()["results"]}

    # ------------------------------------------------------------ reply
    def test_reply_keeps_its_quote_link(self):
        first = self.post(self.ca, "g1").json()["id"]
        r = self.post(self.cb, "g2", reply_to=str(first))
        self.assertEqual(r.status_code, 201, r.content)
        rows = self.rows(self.ca)
        self.assertEqual(rows[r.json()["id"]]["reply_to"], first)
        self.assertIsNone(rows[first]["reply_to"])

    def test_reply_to_another_chat_is_dropped(self):
        other = CircleGroup.objects.create(creator=self.c, name="Other")
        foreign = CircleMessage.objects.create(group=other, sender=self.c,
                                               ciphertext="Q1Q=", nonce="Tg==")
        r = self.post(self.ca, "g3", reply_to=foreign.id)
        self.assertEqual(r.status_code, 201, r.content)
        self.assertIsNone(CircleMessage.objects.get(pk=r.json()["id"]).reply_to_id)

    # ------------------------------------------------------------- edit
    def test_sender_edits_inside_window_ciphertext_only(self):
        mid = self.post(self.ca, "g4").json()["id"]
        CircleMessageCopy.objects.create(message_id=mid, for_user=self.b,
                                         by_user=self.a, ciphertext="T0xE",
                                         nonce="Tg==")
        r = self.ca.post(self.p("messages/%d/edit" % mid),
                         {"per_recipient": self.pr("TkVX")}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        x = CircleMessage.objects.get(pk=mid)
        self.assertEqual(x.per_recipient[str(self.gmb.id)]["ciphertext"], "TkVX")
        self.assertIsNotNone(x.edited_at)
        self.assertFalse(CircleMessageCopy.objects.filter(message_id=mid).exists(),
                         "copies sealed the old text")
        self.assertIsNotNone(self.rows(self.cb)[mid]["edited_at"])

    def test_edit_refuses_plaintext(self):
        mid = self.post(self.ca, "g5").json()["id"]
        bad = {str(self.gmb.id): {"ciphertext": "TkVX", "nonce": "Tg==",
                                  "text": "hello"}}
        r = self.ca.post(self.p("messages/%d/edit" % mid),
                         {"per_recipient": bad}, format="json")
        self.assertEqual(r.status_code, 400, r.content)
        self.assertEqual(self.ca.post(self.p("messages/%d/edit" % mid), {},
                                      format="json").status_code, 400)

    def test_only_sender_inside_window_and_never_outsider(self):
        mid = self.post(self.ca, "g6").json()["id"]
        body = {"per_recipient": self.pr("TkVX")}
        self.assertEqual(self.cb.post(self.p("messages/%d/edit" % mid), body,
                                      format="json").status_code, 403)
        self.assertEqual(self.cc.post(self.p("messages/%d/edit" % mid), body,
                                      format="json").status_code, 404)
        CircleMessage.objects.filter(pk=mid).update(
            created_at=timezone.now() - timedelta(minutes=16))
        self.assertEqual(self.ca.post(self.p("messages/%d/edit" % mid), body,
                                      format="json").status_code, 403)

    def test_deleted_or_view_once_cannot_be_edited(self):
        mid = self.post(self.ca, "g7").json()["id"]
        r = self.ca.post(self.p("messages/%d/delete" % mid),
                         {"scope": "everyone"}, format="json")
        self.assertEqual(r.json()["deleted"], "everyone")
        self.assertEqual(self.ca.post(self.p("messages/%d/edit" % mid),
                                      {"per_recipient": self.pr("TkVX")},
                                      format="json").status_code, 403)
        vo = CircleMessage.objects.create(group=self.g, sender=self.a,
                                          ciphertext="Q1Q=", nonce="Tg==",
                                          view_once=True)
        self.assertEqual(self.ca.post(self.p("messages/%d/edit" % vo.id),
                                      {"per_recipient": self.pr("TkVX")},
                                      format="json").status_code, 403)


class CallLogHideTests(_Base):
    def call(self, caller, callee):
        from core.models import CallRecord
        return CallRecord.objects.create(caller=caller, callee=callee,
                                         kind="voice", state="ended")

    def ids(self, client):
        r = client.get(V + "/circle/calls")
        self.assertEqual(r.status_code, 200, r.content)
        return {x["id"] for x in r.json()["calls"]}

    def hide(self, client, body):
        return client.post(V + "/circle/calls/hide", body, format="json")

    def test_remove_one_call_from_my_log_only(self):
        c1, c2 = self.call(self.a, self.b), self.call(self.b, self.a)
        r = self.hide(self.ca, {"ids": [c1.id]})
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(self.ids(self.ca), {c2.id})
        self.assertEqual(self.ids(self.cb), {c1.id, c2.id}, "B keeps theirs")

    def test_clear_all_then_new_calls_still_show(self):
        self.call(self.a, self.b)
        self.call(self.b, self.a)
        self.assertEqual(self.hide(self.ca, {"all": True}).status_code, 200)
        self.assertEqual(self.ids(self.ca), set())
        from core.models import CallRecord
        CallRecord.objects.update(started_at=timezone.now() - timedelta(minutes=5))
        later = self.call(self.b, self.a)
        self.assertEqual(self.ids(self.ca), {later.id})
        self.assertEqual(len(self.ids(self.cb)), 3)

    def test_someone_elses_call_and_bad_input_refused(self):
        c1 = self.call(self.a, self.b)
        self.assertEqual(self.hide(self.cc, {"ids": [c1.id]}).status_code, 404)
        self.assertEqual(self.hide(self.ca, {"ids": "x"}).status_code, 400)
        self.assertEqual(self.hide(self.ca, {}).status_code, 400)
        self.assertEqual(self.ids(self.ca), {c1.id})
