"""notifs (owner 2 Nov) — CI GUARD: every new My Circle message (1:1 and
group) pushes to the recipient as a DATA-ONLY, HIGH-priority "message" push
the phone can draw; only mute / block / notifications-off skip the ring (and
even then the silent msg_sync ping still goes). Plus the structured
push.trace line (kind, user, device hash, FCM status, name — no content).

Run: manage.py test core.tests_notifs --settings=assisto_backend.settings_test
"""
import json

from core import push
from core.models import Device
from core import tests_m1_messenger as m1

V = m1.V


class MessagePushGuardTests(m1.PushEnforcementTests):
    """Reuses the m1 push fixture: users a (Amina) / b (Bilal), accepted
    1:1 edges ab / ba, b has one device with push token "bdev", fake FCM."""

    # don't re-run the parent's tests under this class
    test_group_mute_suppresses_push = None
    test_one_to_one_iso_mute_suppresses_push = None
    test_hub_organise_mute_suppresses_push = None
    test_messages_pref_off_and_no_preview = None
    test_silence_unknown_callers = None

    def _msgs(self):
        return [p["message"] for p in self.fake.sent_payloads()
                if p["message"]["data"].get("kind") == "message"]

    def _assert_drawable_message_push(self, m, chat_kind, chat_id):
        self.assertEqual(m["token"], "bdev")
        self.assertNotIn("notification", m)            # data-only: phone draws
        self.assertEqual(m["android"]["priority"], "HIGH")  # wakes a dozing phone
        self.assertEqual(m["android"]["ttl"], "86400s")
        d = m["data"]
        self.assertEqual(d["kind"], "message")
        self.assertEqual(d["chat_kind"], chat_kind)
        self.assertEqual(d["chat_id"], str(chat_id))
        self.assertTrue(d["message_id"])
        self.assertEqual(d["channel"], "messages")
        self.assertEqual(d["sender_name"], "Amina")      # native fallback title
        self.assertEqual(d["preview"], "1")
        self.assertTrue(d["title"])                      # plain fallback text
        self.assertNotIn("ciphertext", json.dumps(m))    # never content

    def test_one_to_one_message_pushes_recipient(self):
        r = self.send(self.ca, self.ab, "n1")
        self.assertEqual(r.status_code, 201, r.content)
        msgs = self._msgs()
        self.assertEqual(len(msgs), 1, "a new 1:1 message must push the recipient")
        # chat id = the RECIPIENT's own edge (tap opens his chat)
        self._assert_drawable_message_push(msgs[0], "member", self.ba.id)
        self.assertEqual(msgs[0]["android"]["collapse_key"], "chat-%d" % self.ba.id)

    def test_every_message_pushes_not_just_the_first(self):
        for i in range(3):
            self.send(self.ca, self.ab, "n%d" % i)
        self.assertEqual(len(self._msgs()), 3)
        ids = {m["data"]["message_id"] for m in self._msgs()}
        self.assertEqual(len(ids), 3)

    def test_group_message_pushes_every_other_member(self):
        g = self.group()
        x = self.gmsg(g, self.a)
        push.hook_group_message(self.a, g, x)
        msgs = self._msgs()
        self.assertEqual(len(msgs), 1, "a new group message must push members")
        self._assert_drawable_message_push(msgs[0], "group", g.id)

    def test_block_skips(self):
        self.ba.blocked = True
        self.ba.save()
        self.send(self.ca, self.ab, "n1")
        self.assertEqual(self._msgs(), [])

    def test_mute_skips_ring_but_keeps_silent_delivery_ping(self):
        self.cb.post("%s/circle/%d/controls" % (V, self.ba.id),
                     {"muted_until": "2099-01-01T00:00:00Z"}, format="json")
        self.send(self.ca, self.ab, "n1")
        self.assertEqual(self._msgs(), [])
        kinds = [p["message"]["data"]["kind"] for p in self.fake.sent_payloads()]
        self.assertEqual(kinds, ["msg_sync"])

    def test_preview_off_still_pushes_without_name(self):
        self.cb.post("%s/circle/settings/notifications" % V,
                     {"show_preview": False}, format="json")
        self.send(self.ca, self.ab, "n1")
        m = self._msgs()[0]
        self.assertEqual(m["data"]["preview"], "0")
        self.assertEqual(m["data"]["sender_name"], "")
        self.assertNotIn("Amina", json.dumps(m))

    def test_trace_line_per_device_without_content(self):
        with self.assertLogs("assisto.push.trace", "INFO") as cm:
            self.send(self.ca, self.ab, "n1")
        line = [x for x in cm.output if "kind=message" in x]
        self.assertEqual(len(line), 1, cm.output)
        self.assertIn("user=%d" % self.b.pk, line[0])
        self.assertIn("code=200", line[0])
        self.assertIn("name=", line[0])
        self.assertNotIn("bdev", line[0])          # token never logged
        self.assertNotIn("Q1Q=", line[0])          # ciphertext never logged

    def test_trace_line_when_recipient_has_no_device(self):
        Device.objects.filter(user=self.b).delete()
        with self.assertLogs("assisto.push.trace", "INFO") as cm:
            self.send(self.ca, self.ab, "n1")
        self.assertTrue(any("dev=none" in x for x in cm.output), cm.output)
