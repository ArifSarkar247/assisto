"""m1-messenger — every ⋮ / settings route the client calls, incl. denied cases.

Run: manage.py test core.tests_m1_messenger --settings=assisto_backend.settings_test
"""
import json
import os
import shutil
import tempfile
from datetime import timedelta
from io import StringIO
from unittest import mock

from django.core.management import call_command
from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient

from core import push
from core.models import (CallRecord, ChatOrganiseState, ChatSettings,
                         CircleGroup, CircleGroupMember, CircleMember,
                         CircleMessage, CirclePrivacy, Community,
                         CommunityGroup, CommunityMember,
                         CommunityMessageRequest, Device, ModerationReport,
                         MsgChatPref, MsgExport, MsgGroupTimer,
                         MsgUserSettings, Reminder, User)
from core.tests_push import SA, FakeFCM

V = "/api/v1"


def mk(phone, name):
    return User.objects.create_user(name=name, phone=phone, password="pw12345!",
                                    language="en")


class _Base(TestCase):
    def setUp(self):
        self.a = mk("01710000001", "Amina")
        self.b = mk("01710000002", "Bilal")
        self.c = mk("01710000003", "Chaya")
        self.ab = CircleMember.objects.create(
            user=self.a, peer_user=self.b, name="Bilal", state="accepted",
            phone=self.b.phone, public_key="pkB", key_id="kB")
        self.ba = CircleMember.objects.create(
            user=self.b, peer_user=self.a, name="Amina", state="accepted",
            phone=self.a.phone, direction="incoming", public_key="pkA")
        self.ca = self.client_for(self.a)
        self.cb = self.client_for(self.b)
        self.cc = self.client_for(self.c)

    def client_for(self, u):
        c = APIClient()
        c.force_authenticate(u)
        c.credentials(HTTP_ACCEPT_LANGUAGE="en")
        return c

    def send(self, client, edge, cmid, ct="text"):
        return client.post("%s/circle/%d/messages" % (V, edge.id), {
            "ciphertext": "Q1Q=", "nonce": "Tg==", "content_type": ct,
            "client_msg_id": cmid}, format="json")

    def group(self):
        g = CircleGroup.objects.create(creator=self.a, name="Family")
        CircleGroupMember.objects.create(group=g, member=self.a, role="admin")
        CircleGroupMember.objects.create(group=g, member=self.b, role="member")
        return g

    def gmsg(self, g, sender, **kw):
        return CircleMessage.objects.create(
            group=g, sender=sender, ciphertext="Q1Q=", nonce="Tg==", **kw)


# ===================================================================== 1:1
class ChatInfoClearTests(_Base):
    def test_info_shape_and_counts(self):
        self.send(self.ca, self.ab, "m1")
        CircleMessage.objects.create(member=self.ba, sender=self.b,
                                     content_type="image", blob_ref="blob1")
        g = self.group()
        r = self.ca.get("%s/circle/%d/info" % (V, self.ab.id))
        self.assertEqual(r.status_code, 200, r.content)
        j = r.json()
        self.assertEqual(j["message_count"], 2)
        self.assertEqual(j["media_count"], 1)
        self.assertEqual(j["groups_in_common"], [{"id": g.id, "name": "Family"}])
        self.assertEqual(j["phone"], self.b.phone)
        self.assertTrue(j["encryption"]["fingerprint"])
        self.assertFalse(j["blocked"])

    def test_info_denied_for_someone_elses_edge(self):
        r = self.cc.get("%s/circle/%d/info" % (V, self.ab.id))
        self.assertEqual(r.status_code, 404)

    def test_info_hides_phone_of_non_accepted_peer(self):
        self.ab.state = "pending"
        self.ab.save()
        r = self.ca.get("%s/circle/%d/info" % (V, self.ab.id))
        self.assertEqual(r.json()["phone"], "")

    def test_receiver_now_sees_peer_messages(self):
        self.send(self.ca, self.ab, "m1")
        r = self.cb.get("%s/circle/%d/messages" % (V, self.ba.id))
        rows = r.json()["results"]
        self.assertEqual(len(rows), 1)
        self.assertFalse(rows[0]["mine"])

    def test_clear_hides_for_me_only(self):
        self.send(self.ca, self.ab, "m1")
        r = self.ca.post("%s/circle/%d/clear" % (V, self.ab.id), {}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(self.ca.get("%s/circle/%d/messages" % (V, self.ab.id))
                         .json()["results"], [])
        # peer still has it
        self.assertEqual(len(self.cb.get("%s/circle/%d/messages" % (V, self.ba.id))
                             .json()["results"]), 1)
        # new messages after the clear are visible
        self.send(self.cb, self.ba, "m2")
        self.assertEqual(len(self.ca.get("%s/circle/%d/messages" % (V, self.ab.id))
                             .json()["results"]), 1)

    def test_clear_denied(self):
        r = self.cc.post("%s/circle/%d/clear" % (V, self.ab.id), {}, format="json")
        self.assertEqual(r.status_code, 404)

    def test_receiver_can_star_and_delete_for_me(self):
        mid = self.send(self.ca, self.ab, "m1").json()["id"]
        r = self.cb.post("%s/circle/messages/%d/star" % (V, mid), {}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()["starred"])
        r = self.cb.post("%s/circle/messages/%d/delete" % (V, mid),
                         {"scope": "me"}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(self.cb.get("%s/circle/%d/messages" % (V, self.ba.id))
                         .json()["results"], [])
        # outsider cannot touch it
        r = self.cc.post("%s/circle/messages/%d/star" % (V, mid), {}, format="json")
        self.assertEqual(r.status_code, 404)


class ControlsAndSettingsTests(_Base):
    def test_mute_iso_and_always_and_unmute(self):
        until = (timezone.now() + timedelta(hours=8)).isoformat()
        r = self.ca.post("%s/circle/%d/controls" % (V, self.ab.id),
                         {"muted_until": until}, format="json")
        self.assertEqual(r.status_code, 200)
        self.ab.refresh_from_db()
        self.assertIsNotNone(self.ab.muted_until)
        self.ca.post("%s/circle/%d/controls" % (V, self.ab.id),
                     {"muted_until": "2099-01-01T00:00:00Z"}, format="json")
        self.ab.refresh_from_db()
        self.assertEqual(self.ab.muted_until.year, 2099)
        self.ca.post("%s/circle/%d/controls" % (V, self.ab.id),
                     {"muted_until": None}, format="json")
        self.ab.refresh_from_db()
        self.assertIsNone(self.ab.muted_until)

    def test_mute_bad_value(self):
        r = self.ca.post("%s/circle/%d/controls" % (V, self.ab.id),
                         {"muted_until": "soon"}, format="json")
        self.assertEqual(r.status_code, 400)

    def test_favourite_persists_and_shows_in_members(self):
        r = self.ca.post("%s/circle/%d/controls" % (V, self.ab.id),
                         {"favourite": True}, format="json")
        self.assertTrue(r.json()["favourite"])
        rows = self.ca.get("%s/circle/members" % V).json()["results"]
        self.assertTrue(rows[0]["favourite"])
        s = self.ca.get("%s/circle/%d/settings" % (V, self.ab.id)).json()
        self.assertTrue(s["favourite"])

    def test_settings_partial_theme_keeps_timer_and_mirrors(self):
        r = self.ca.post("%s/messenger/chat/%d/settings" % (V, self.ab.id),
                         {"disappearing_sec": 86400}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.ca.post("%s/messenger/chat/%d/settings" % (V, self.ab.id),
                     {"theme": "dark"}, format="json")
        mine = ChatSettings.objects.get(user=self.a, peer=self.ab)
        self.assertEqual(mine.disappearing_sec, 86400)
        self.assertEqual(mine.theme, "dark")
        peer = ChatSettings.objects.get(user=self.b, peer=self.ba)
        self.assertEqual(peer.disappearing_sec, 86400)
        self.assertIsNotNone(MsgChatPref.objects.get(
            user=self.b, chat_kind="member", chat_id=str(self.ba.id))
            .disappearing_since)

    def test_blocked_side_cannot_message_or_call(self):
        # B blocks A (on B's own edge)
        self.cb.post("%s/circle/%d/controls" % (V, self.ba.id),
                     {"blocked": True}, format="json")
        r = self.send(self.ca, self.ab, "m1")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()["dropped"])
        self.assertEqual(CircleMessage.objects.count(), 0)
        r = self.ca.post("%s/circle/%d/call" % (V, self.ab.id),
                         {"kind": "voice"}, format="json")
        self.assertFalse(r.json()["allowed"])
        self.assertEqual(r.json()["reason"], "unavailable")
        self.assertEqual(CallRecord.objects.count(), 0)

    def test_incoming_calls_off_refuses(self):
        self.cb.post("%s/circle/settings/calls" % V,
                     {"incoming_calls": False}, format="json")
        r = self.ca.post("%s/circle/%d/call" % (V, self.ab.id),
                         {"kind": "voice"}, format="json")
        self.assertFalse(r.json()["allowed"])


# ===================================================================== groups
class GroupMenuTests(_Base):
    def setUp(self):
        super().setUp()
        self.g = self.group()
        self.p = lambda s: "%s/circle/groups/%d/%s" % (V, self.g.id, s)

    def test_mute_and_reload_state(self):
        r = self.cb.post(self.p("mute"), {"duration": "8h"}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["mute"], "8h")
        d = self.cb.get("%s/circle/groups/%d" % (V, self.g.id)).json()
        self.assertEqual(d.get("mute"), "8h")
        r = self.cb.post(self.p("mute"), {"duration": "off"}, format="json")
        self.assertFalse(r.json()["muted"])

    def test_mute_denied_and_bad(self):
        self.assertEqual(self.cc.post(self.p("mute"), {"duration": "8h"},
                                      format="json").status_code, 404)
        self.assertEqual(self.cb.post(self.p("mute"), {"duration": "3y"},
                                      format="json").status_code, 400)

    def test_disappearing_hides_and_purges(self):
        r = self.cb.post(self.p("disappearing"), {"ttl": "24h"}, format="json")
        self.assertEqual(r.json()["disappearing_sec"], 86400)
        old = self.gmsg(self.g, self.a)
        CircleMessage.objects.filter(pk=old.pk).update(
            created_at=timezone.now() - timedelta(days=2))
        t = MsgGroupTimer.objects.get(group=self.g)
        MsgGroupTimer.objects.filter(pk=t.pk).update(
            since=timezone.now() - timedelta(days=3))
        fresh = self.gmsg(self.g, self.a)
        rows = self.cb.get(self.p("messages")).json()["results"]
        self.assertEqual([x["id"] for x in rows], [fresh.id])
        out = StringIO()
        call_command("purge_disappearing", stdout=out)
        self.assertIn("group=1", out.getvalue())
        self.assertFalse(CircleMessage.objects.filter(pk=old.pk).exists())
        self.assertTrue(CircleMessage.objects.filter(pk=fresh.pk).exists())

    def test_disappearing_denied_and_bad(self):
        self.assertEqual(self.cc.post(self.p("disappearing"), {"ttl": "24h"},
                                      format="json").status_code, 404)
        self.assertEqual(self.cb.post(self.p("disappearing"), {"ttl": "1h"},
                                      format="json").status_code, 400)

    def test_theme_and_favourite(self):
        r = self.cb.post(self.p("theme"), {"color": "ocean"}, format="json")
        self.assertEqual(r.json()["theme"], "ocean")
        self.assertEqual(self.cb.post(self.p("theme"), {"color": "neon"},
                                      format="json").status_code, 400)
        r = self.cb.post(self.p("favourite"), {"on": True}, format="json")
        self.assertTrue(r.json()["favourite"])
        rows = self.cb.get("%s/circle/groups" % V).json()
        rows = rows.get("results", rows) if isinstance(rows, dict) else rows
        g = [x for x in rows if x["id"] == self.g.id][0]
        self.assertTrue(g["favourite"])
        self.assertEqual(g["theme"], "ocean")
        self.assertEqual(self.cc.post(self.p("favourite"), {"on": True},
                                      format="json").status_code, 404)
        self.assertEqual(self.cc.post(self.p("theme"), {"color": "ocean"},
                                      format="json").status_code, 404)

    def test_clear_group_for_me(self):
        self.gmsg(self.g, self.a)
        self.assertEqual(self.cb.post(self.p("clear"), {}, format="json")
                         .status_code, 200)
        self.assertEqual(self.cb.get(self.p("messages")).json()["results"], [])
        self.assertEqual(len(self.ca.get(self.p("messages")).json()["results"]), 1)
        self.assertEqual(self.cc.post(self.p("clear"), {}, format="json")
                         .status_code, 404)

    def test_group_message_actions_on_screen_path(self):
        x = self.gmsg(self.g, self.a)
        r = self.cb.post(self.p("messages/%d/star" % x.id), {"starred": True},
                         format="json")
        self.assertTrue(r.json()["starred"])
        r = self.cb.post(self.p("messages/%d/react" % x.id), {"emoji": "👍"},
                         format="json")
        self.assertEqual(r.status_code, 200, r.content)
        r = self.cb.post(self.p("messages/%d/delete" % x.id), {}, format="json")
        self.assertEqual(r.json()["deleted"], "me")
        # B is not the sender: delete-for-everyone refused
        r = self.cb.post(self.p("messages/%d/delete" % x.id),
                         {"scope": "everyone"}, format="json")
        self.assertEqual(r.status_code, 403)
        r = self.ca.post(self.p("messages/%d/delete" % x.id),
                         {"scope": "everyone"}, format="json")
        self.assertEqual(r.json()["deleted"], "everyone")
        self.assertEqual(self.cc.post(self.p("messages/%d/star" % x.id), {},
                                      format="json").status_code, 404)

    def test_export_signed_file(self):
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp, True)
        with override_settings(MEDIA_ROOT=tmp):
            self.gmsg(self.g, self.a, per_recipient={
                str(CircleGroupMember.objects.get(group=self.g, member=self.b).id):
                    {"ciphertext": "Zm9y", "nonce": "Yg=="}})
            r = self.cb.get(self.p("export") + "?media=false")
            self.assertEqual(r.status_code, 200, r.content)
            j = r.json()
            self.assertTrue(j["url"].startswith("/api/v1/m/msg_exports/"))
            self.assertEqual(j["message_count"], 1)
            f = self.client.get(j["url"])
            self.assertEqual(f.status_code, 200)
            body = json.loads(b"".join(f.streaming_content))
            self.assertTrue(body["encrypted"])
            self.assertEqual(body["messages"][0]["envelope"]["ciphertext"], "Zm9y")
            # a tampered signature is refused
            bad = j["url"].replace("s=", "s=00")
            self.assertEqual(self.client.get(bad).status_code, 404)
            self.assertEqual(self.cc.get(self.p("export")).status_code, 404)
            # expiry purge
            MsgExport.objects.update(expires_at=timezone.now() - timedelta(hours=1))
            call_command("purge_disappearing", stdout=StringIO())
            self.assertEqual(MsgExport.objects.count(), 0)

    def test_ai_no_key_is_honest(self):
        r = self.cb.post(self.p("ai/summarise"), {"messages": ["hi", "see you at 5"]},
                         format="json")
        self.assertEqual(r.status_code, 200)
        j = r.json()
        self.assertFalse(j["allowed"])
        self.assertEqual(j["reason"], "no_key")
        self.assertIn("AI", j["message"])

    def test_ai_success_and_credits(self):
        from core import ai
        with mock.patch.object(ai, "generate", return_value=("- meet at 5", 0.0)):
            j = self.cb.post(self.p("ai/summarise"), {"messages": ["x"]},
                             format="json").json()
        self.assertTrue(j["allowed"])
        self.assertEqual(j["result"], "- meet at 5")
        with mock.patch.object(ai, "generate",
                               side_effect=ai.AIUnavailable("credits")):
            j = self.cb.post(self.p("ai/translate"), {"messages": ["x"],
                             "target_lang": "bn"}, format="json").json()
        self.assertTrue(j["needs_plan"])

    def test_ai_reminder_books_reminder(self):
        from core import ai
        with mock.patch.object(ai, "generate",
                               return_value=("Buy milk | 2030-01-02 09:30", 0.0)):
            j = self.cb.post(self.p("ai/reminder"), {"messages": ["buy milk"]},
                             format="json").json()
        self.assertEqual(j["reminder"]["title"], "Buy milk")
        r = Reminder.objects.get(user=self.b)
        self.assertEqual(r.source, "ai")
        self.assertIsNotNone(r.due_at)

    def test_ai_denied_and_bad(self):
        self.assertEqual(self.cc.post(self.p("ai/summarise"), {"messages": ["x"]},
                                      format="json").status_code, 404)
        self.assertEqual(self.cb.post(self.p("ai/poem"), {"messages": ["x"]},
                                      format="json").status_code, 400)
        self.assertEqual(self.cb.post(self.p("ai/summarise"), {"messages": []},
                                      format="json").status_code, 400)


# ===================================================================== community
class CommunityMenuTests(_Base):
    def setUp(self):
        super().setUp()
        self.com = Community.objects.create(creator=self.a, name="Para")
        self.ann = CommunityGroup.objects.create(
            community=self.com, creator=self.a, kind="announcements", name="Ann")
        CommunityMember.objects.create(community=self.com, group=self.ann,
                                       member=self.a, role="admin")
        CommunityMember.objects.create(community=self.com, group=self.ann,
                                       member=self.b, role="member")

    def test_notifications_toggle_and_reload(self):
        r = self.cb.post("%s/community/%d/notifications" % (V, self.com.id),
                         {"muted": True}, format="json")
        self.assertTrue(r.json()["notifications_muted"])
        j = self.cb.get("%s/community/%d/groups" % (V, self.com.id)).json()
        self.assertTrue(j["notifications_muted"])
        r = self.cb.post("%s/community/%d/notifications" % (V, self.com.id),
                         {"muted": False}, format="json")
        self.assertFalse(r.json()["notifications_muted"])
        self.assertEqual(self.cc.post("%s/community/%d/notifications" % (V, self.com.id),
                                      {"muted": True}, format="json").status_code, 404)

    def test_leave_member_and_last_admin(self):
        r = self.ca.post("%s/community/%d/leave" % (V, self.com.id), {}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.json()["allowed"])
        self.assertEqual(r.json()["reason"], "promote_before_leaving")
        r = self.cb.post("%s/community/%d/leave" % (V, self.com.id), {}, format="json")
        self.assertTrue(r.json()["left"])
        self.assertEqual(CommunityMember.objects.get(member=self.b).status, "left")
        # now A is the only member: may leave
        r = self.ca.post("%s/community/%d/leave" % (V, self.com.id), {}, format="json")
        self.assertTrue(r.json()["left"])
        self.assertEqual(self.cc.post("%s/community/%d/leave" % (V, self.com.id),
                                      {}, format="json").status_code, 404)


# ===================================================================== account
class TwoStepTests(_Base):
    U = "%s/circle/account/two-step" % V

    def test_set_status_change_disable(self):
        self.assertFalse(self.ca.get(self.U).json()["enabled"])
        r = self.ca.post(self.U, {"enabled": True, "pin": "123456"}, format="json")
        self.assertTrue(r.json()["enabled"])
        row = MsgUserSettings.objects.get(user=self.a)
        self.assertNotIn("123456", row.two_step_hash)
        self.assertTrue(self.ca.get(self.U).json()["enabled"])
        # change needs the current PIN
        r = self.ca.post(self.U, {"enabled": True, "pin": "654321"}, format="json")
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()["reason"], "current_pin_required")
        r = self.ca.post(self.U, {"enabled": False, "current_pin": "123456"},
                         format="json")
        self.assertFalse(r.json()["enabled"])

    def test_bad_pin_format(self):
        r = self.ca.post(self.U, {"enabled": True, "pin": "12"}, format="json")
        self.assertEqual(r.status_code, 400)

    def test_verify_rate_limited(self):
        self.ca.post(self.U, {"enabled": True, "pin": "123456"}, format="json")
        v = self.U + "/verify"
        self.assertEqual(self.ca.post(v, {"pin": "123456"}, format="json")
                         .status_code, 200)
        for i in range(4):
            r = self.ca.post(v, {"pin": "000000"}, format="json")
            self.assertEqual(r.status_code, 403)
        r = self.ca.post(v, {"pin": "000000"}, format="json")
        self.assertEqual(r.status_code, 429)
        # even the right PIN is refused while locked
        r = self.ca.post(v, {"pin": "123456"}, format="json")
        self.assertEqual(r.status_code, 429)
        self.assertTrue(self.ca.get(self.U).json()["locked"])

    def test_verify_when_disabled(self):
        self.assertEqual(self.ca.post(self.U + "/verify", {"pin": "1"},
                                      format="json").status_code, 400)


class ChangeNumberTests(_Base):
    R = "%s/circle/account/change-number/request" % V
    C = "%s/circle/account/change-number/confirm" % V

    def test_sms_not_configured_is_honest(self):
        j = self.ca.get("%s/circle/account/change-number" % V).json()
        self.assertFalse(j["sms_enabled"])
        r = self.ca.post(self.R, {"new_phone": "01799999999"}, format="json")
        self.assertEqual(r.status_code, 503)
        self.assertEqual(r.json()["code"], "sms_not_configured")

    def test_validation(self):
        self.assertEqual(self.ca.post(self.R, {"new_phone": "12"}, format="json")
                         .status_code, 400)
        self.assertEqual(self.ca.post(self.R, {"new_phone": self.b.phone},
                                      format="json").status_code, 409)
        self.assertEqual(self.ca.post(self.C, {"new_phone": "01799999999",
                                               "code": "1"}, format="json")
                         .status_code, 400)

    def fake_otp(self):
        """Stand-in for core/otp.py (slot o1-otp): issue/verify by purpose."""
        codes = {}

        class O:
            @staticmethod
            def issue(phone, purpose, request):
                codes[(phone, purpose)] = "424242"
                return {"ok": True}

            @staticmethod
            def verify(phone, purpose, code):
                return codes.get((phone, purpose)) == code
        return O

    def test_full_flow_with_otp_service(self):
        from core import views_m1_messenger as m1
        o = self.fake_otp()
        with mock.patch.object(m1, "_otp", return_value=o), \
                mock.patch.object(m1, "sms_configured", return_value=True):
            r = self.ca.post(self.R, {"new_phone": "01799999999"}, format="json")
            self.assertEqual(r.status_code, 200, r.content)
            self.assertEqual(self.ca.post(self.R, {"new_phone": "01799999999"},
                                          format="json").status_code, 429)
            r = self.ca.post(self.C, {"new_phone": "01799999999",
                                      "code": "000000"}, format="json")
            self.assertEqual(r.status_code, 403)
            r = self.ca.post(self.C, {"new_phone": "01799999999",
                                      "code": "424242"}, format="json")
            self.assertEqual(r.status_code, 200, r.content)
        self.a.refresh_from_db()
        self.assertEqual(self.a.phone, "+8801799999999")  # c1: canonical
        self.ba.refresh_from_db()
        self.assertEqual(self.ba.phone, "+8801799999999")

    def test_otp_service_missing_means_not_configured(self):
        from core import views_m1_messenger as m1
        with mock.patch.object(m1, "_otp", return_value=None):
            self.assertFalse(m1.sms_configured())

    def test_confirm_needs_two_step_pin(self):
        from core import views_m1_messenger as m1
        self.ca.post("%s/circle/account/two-step" % V,
                     {"enabled": True, "pin": "123456"}, format="json")
        o = self.fake_otp()
        with mock.patch.object(m1, "_otp", return_value=o), \
                mock.patch.object(m1, "sms_configured", return_value=True):
            self.ca.post(self.R, {"new_phone": "01799999998"}, format="json")
            r = self.ca.post(self.C, {"new_phone": "01799999998",
                                      "code": "424242"}, format="json")
            self.assertEqual(r.status_code, 403)
            r = self.ca.post(self.C, {"new_phone": "01799999998",
                                      "code": "424242", "pin": "123456"},
                             format="json")
            self.assertEqual(r.status_code, 200)


# ===================================================================== privacy
class PrivacyTests(_Base):
    def setUp(self):
        super().setUp()
        self.com = Community.objects.create(creator=self.a, name="Para")
        self.grp = CommunityGroup.objects.create(
            community=self.com, creator=self.a, kind="announcements", name="Ann")
        for u in (self.a, self.c):
            CommunityMember.objects.create(community=self.com, group=self.grp,
                                           member=u)

    def stranger_msg(self):
        return self.cc.post("%s/community/message" % V, {
            "recipient_id": self.a.id, "community_id": self.com.id,
            "ciphertext": "Q1Q=", "nonce": "Tg==", "sender_key_id": "k"},
            format="json")

    def test_my_circle_rejects_strangers(self):
        r = self.stranger_msg()
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()["reason"], "who_my_circle")
        self.assertEqual(CommunityMessageRequest.objects.count(), 0)

    def test_everyone_routes_to_requests_then_accept(self):
        self.ca.post("%s/circle/settings/message-privacy" % V,
                     {"who_can_message": "everyone"}, format="json")
        r = self.stranger_msg()
        self.assertEqual(r.status_code, 201, r.content)
        rows = self.ca.get("%s/circle/message-requests" % V).json()["requests"]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["ciphertext"], "Q1Q=")
        self.assertEqual(rows[0]["phone"], "")      # show_phone off
        rid = rows[0]["id"]
        # someone else cannot act on it
        self.assertEqual(self.cb.post("%s/circle/message-requests/%d" % (V, rid),
                                      {"action": "accept"}, format="json")
                         .status_code, 404)
        r = self.ca.post("%s/circle/message-requests/%d" % (V, rid),
                         {"action": "accept"}, format="json")
        self.assertEqual(r.json()["state"], "accepted")
        self.assertEqual(self.ca.get("%s/circle/message-requests" % V)
                         .json()["requests"], [])
        # accepted -> direct route now
        self.assertEqual(self.stranger_msg().json()["route"], "direct")

    def test_decline_block_report(self):
        self.ca.post("%s/circle/settings/message-privacy" % V,
                     {"who_can_message": "everyone"}, format="json")
        rid = self.stranger_msg().json()["message_request_id"]
        r = self.ca.post("%s/circle/message-requests/%d" % (V, rid),
                         {"action": "decline"}, format="json")
        self.assertEqual(r.json()["state"], "declined")
        mr2 = CommunityMessageRequest.objects.create(
            sender=self.c, recipient=self.a, state="pending")
        r = self.ca.post("%s/circle/message-requests/%d" % (V, mr2.id),
                         {"action": "report", "reason": "spam",
                          "also_block": True}, format="json")
        self.assertTrue(r.json()["blocked"])
        self.assertEqual(ModerationReport.objects.count(), 1)
        # blocked sender is refused from now on
        self.assertEqual(self.stranger_msg().status_code, 403)
        self.assertEqual(self.ca.post("%s/circle/message-requests/%d" % (V, rid),
                                      {"action": "dance"}, format="json")
                         .status_code, 400)

    def test_blocked_list(self):
        self.ca.post("%s/circle/%d/controls" % (V, self.ab.id),
                     {"blocked": True}, format="json")
        rows = self.ca.get("%s/circle/blocked" % V).json()["blocked"]
        self.assertEqual([r["id"] for r in rows], [self.ab.id])
        self.ca.post("%s/circle/%d/controls" % (V, self.ab.id),
                     {"blocked": False}, format="json")
        self.assertEqual(self.ca.get("%s/circle/blocked" % V).json()["blocked"], [])


class SettingsPrefsTests(_Base):
    def test_notifications_roundtrip(self):
        j = self.ca.get("%s/circle/settings/notifications" % V).json()
        self.assertTrue(all(j.values()))
        self.ca.post("%s/circle/settings/notifications" % V,
                     {"groups": False, "junk": 1}, format="json")
        j = self.ca.get("%s/circle/settings/notifications" % V).json()
        self.assertFalse(j["groups"])
        self.assertNotIn("junk", j)

    def test_calls_roundtrip(self):
        self.ca.post("%s/circle/settings/calls" % V,
                     {"silence_unknown": True}, format="json")
        j = self.ca.get("%s/circle/settings/calls" % V).json()
        self.assertEqual(j, {"incoming_calls": True, "silence_unknown": True})

    def test_storage_real_usage(self):
        from core import billing
        billing.add_storage(self.a, 5000)
        j = self.ca.get("%s/circle/settings/storage" % V).json()
        self.assertEqual(j["total_bytes"], 5000)
        self.assertGreater(j["quota_bytes"], 0)
        self.assertIn("backup_bytes", j)
        r = self.ca.post("%s/circle/settings/storage" % V,
                         {"auto_download": {"video": True}}, format="json")
        self.assertTrue(r.json()["auto_download"]["video"])
        self.assertEqual(self.ca.post("%s/circle/settings/storage" % V,
                                      {"auto_download": "x"}, format="json")
                         .status_code, 400)

    def test_settings_require_auth(self):
        anon = APIClient()
        for u in ("notifications", "calls", "storage"):
            self.assertIn(anon.get("%s/circle/settings/%s" % (V, u)).status_code,
                          (401, 403))
        self.assertIn(anon.get("%s/circle/account/two-step" % V).status_code,
                      (401, 403))


# ===================================================================== push
class PushEnforcementTests(_Base):
    def setUp(self):
        super().setUp()
        push.reset_cache()
        self.tmp = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump(SA, self.tmp)
        self.tmp.close()
        self.addCleanup(os.unlink, self.tmp.name)
        self.fake = FakeFCM()
        p1 = override_settings(FCM_SERVICE_ACCOUNT_FILE=self.tmp.name,
                               PUSH_SYNC=True)
        p1.enable()
        self.addCleanup(p1.disable)
        p2 = mock.patch.object(push, "_http_post", self.fake)
        p2.start()
        self.addCleanup(p2.stop)
        self.addCleanup(push.reset_cache)
        Device.objects.create(user=self.b, push_token="bdev")

    def test_group_mute_suppresses_push(self):
        g = self.group()
        self.cb.post("%s/circle/groups/%d/mute" % (V, g.id),
                     {"duration": "always"}, format="json")
        x = self.gmsg(g, self.a)
        push.hook_group_message(self.a, g, x)
        self.assertEqual(self.fake.send_calls, [])
        self.cb.post("%s/circle/groups/%d/mute" % (V, g.id),
                     {"duration": "off"}, format="json")
        push.hook_group_message(self.a, g, x)
        self.assertEqual(len(self.fake.send_calls), 1)

    def test_one_to_one_iso_mute_suppresses_push(self):
        self.cb.post("%s/circle/%d/controls" % (V, self.ba.id),
                     {"muted_until": "2099-01-01T00:00:00Z"}, format="json")
        self.send(self.ca, self.ab, "m1")
        self.assertEqual(self.fake.send_calls, [])

    def test_hub_organise_mute_suppresses_push(self):
        self.cb.post("%s/messenger/chats/%d/mute" % (V, self.ba.id),
                     {"duration": "8h"}, format="json")
        self.send(self.ca, self.ab, "m1")
        self.assertEqual(self.fake.send_calls, [])

    def test_messages_pref_off_and_no_preview(self):
        self.cb.post("%s/circle/settings/notifications" % V,
                     {"show_preview": False}, format="json")
        self.send(self.ca, self.ab, "m1")
        m = self.fake.sent_payloads()[0]["message"]
        self.assertEqual(m["data"]["title"], "New message")  # c3-msg: data-only
        self.assertEqual(m["data"]["preview"], "0")  # c3-msg: device hides text too
        self.assertNotIn("Amina", json.dumps(m))
        self.cb.post("%s/circle/settings/notifications" % V,
                     {"messages": False}, format="json")
        n = len(self.fake.send_calls)
        self.send(self.ca, self.ab, "m2")
        self.assertEqual(len(self.fake.send_calls), n)

    def test_silence_unknown_callers(self):
        self.cb.post("%s/circle/settings/calls" % V,
                     {"silence_unknown": True}, format="json")
        self.ba.state = "pending"
        self.ba.save()
        call = CallRecord.objects.create(caller=self.a, callee=self.b,
                                         circle=self.ab)
        self.assertFalse(push.hook_call_placed(self.a, self.ab, call))
        self.ba.state = "accepted"
        self.ba.save()
        self.assertTrue(push.hook_call_placed(self.a, self.ab, call))


class PurgeOneToOneTests(_Base):
    def test_purge_only_after_timer_start(self):
        self.ca.post("%s/messenger/chat/%d/settings" % (V, self.ab.id),
                     {"disappearing_sec": 86400}, format="json")
        before = CircleMessage.objects.create(member=self.ab, sender=self.a,
                                              ciphertext="Q1Q=", nonce="Tg==")
        CircleMessage.objects.filter(pk=before.pk).update(
            created_at=timezone.now() - timedelta(days=5))
        after = CircleMessage.objects.create(member=self.ab, sender=self.a,
                                             ciphertext="Q1Q=", nonce="Tg==")
        MsgChatPref.objects.filter(user=self.a).update(
            disappearing_since=timezone.now() - timedelta(days=3))
        CircleMessage.objects.filter(pk=after.pk).update(
            created_at=timezone.now() - timedelta(days=2))
        out = StringIO()
        call_command("purge_disappearing", stdout=out)
        self.assertIn("1:1=1", out.getvalue())
        self.assertTrue(CircleMessage.objects.filter(pk=before.pk).exists())
        self.assertFalse(CircleMessage.objects.filter(pk=after.pk).exists())
