"""qcircle (quality push 9 Nov) — notification channel of system-drawn
My Circle pushes.

Root cause guarded here: build 302 (circlebub) deleted the phone's old
'messages' channel and moved chat notifications to 'chat_msg_v2'. Server
NOTIFICATION pushes (message_request, channel_post, community_join) still
named 'messages', so with the app closed Android drew them on the fallback
'alerts' channel — wrong sound and the user's message mute ignored.

Run: manage.py test core.tests_qcircle --settings=assisto_backend.settings_test
"""
from django.test import SimpleTestCase

from core import push
from core.models import Device
from core import tests_m1_messenger as m1


class ChannelForBuildTests(SimpleTestCase):
    def test_build_name_num(self):
        self.assertEqual(push.build_name_num("1.0.316+316"), 316)
        self.assertEqual(push.build_name_num("1.0.244+10244"), 244)
        self.assertEqual(push.build_name_num("1.0.301"), 301)
        self.assertEqual(push.build_name_num(""), 0)
        self.assertEqual(push.build_name_num(None), 0)
        self.assertEqual(push.build_name_num("junk"), 0)

    def test_message_kinds_use_v2_on_new_builds(self):
        for kind in ("message_request", "channel_post", "community_join",
                     "message", "key_request"):
            self.assertEqual(push.android_channel_for(kind, "1.0.316+316"),
                             "chat_msg_v2", kind)
            self.assertEqual(push.android_channel_for(kind, "1.0.302+302"),
                             "chat_msg_v2", kind)
            # unknown version -> current channel (all Play builds >= 302)
            self.assertEqual(push.android_channel_for(kind, ""), "chat_msg_v2")

    def test_old_builds_keep_their_messages_channel(self):
        self.assertEqual(push.android_channel_for("channel_post", "1.0.301+301"),
                         "messages")

    def test_other_kinds_unchanged(self):
        for kind, ch in (("call", "calls"), ("sos", "sos"),
                         ("reminder", "reminders"), ("offer", "offers"),
                         ("family_alert", "alerts")):
            self.assertEqual(push.android_channel_for(kind, "1.0.316+316"), ch)

    def test_every_kind_maps(self):
        for kind in push.CHANNELS:
            self.assertTrue(push.android_channel_for(kind, "1.0.316"))


class SystemDrawnChannelTests(m1.PushEnforcementTests):
    """Reuses the m1 FCM fixture (b has device "bdev", fake FCM)."""
    test_group_mute_suppresses_push = None
    test_one_to_one_iso_mute_suppresses_push = None
    test_hub_organise_mute_suppresses_push = None
    test_messages_pref_off_and_no_preview = None
    test_silence_unknown_callers = None

    def _sent(self, kind):
        return [p["message"] for p in self.fake.sent_payloads()
                if p["message"]["data"].get("kind") == kind]

    def test_channel_post_notification_targets_chat_msg_v2(self):
        Device.objects.filter(user=self.b).update(app_version="1.0.316+316")
        n = push.push_to_user(self.b, "channel_post", "নতুন পোস্ট", "New post",
                              "বিস্তারিত", "Details", data={"channel_id": "7"})
        self.assertEqual(n, 1)
        m = self._sent("channel_post")[0]
        self.assertIn("notification", m)
        self.assertEqual(m["android"]["notification"]["channel_id"], "chat_msg_v2")
        self.assertEqual(m["data"]["channel"], "messages")   # app maps it

    def test_old_build_device_keeps_messages(self):
        Device.objects.filter(user=self.b).update(app_version="1.0.300+300")
        push.push_to_user(self.b, "message_request", "অনুরোধ", "Request",
                          data={"sender_id": "3"})
        m = self._sent("message_request")[0]
        self.assertEqual(m["android"]["notification"]["channel_id"], "messages")

    def test_per_device_channel(self):
        Device.objects.filter(user=self.b).update(app_version="1.0.300+300")
        Device.objects.create(user=self.b, push_token="bnew",
                              app_version="1.0.316+316")
        push.push_to_user(self.b, "community_join", "যোগ", "Joined")
        got = {m["token"]: m["android"]["notification"]["channel_id"]
               for m in self._sent("community_join")}
        self.assertEqual(got, {"bdev": "messages", "bnew": "chat_msg_v2"})

    def test_calls_still_data_only(self):
        Device.objects.filter(user=self.b).update(app_version="1.0.316+316")
        push.push_to_user(self.b, "call", "কল", "Call", data={"call_id": "1"})
        m = self._sent("call")[0]
        self.assertNotIn("notification", m)
