"""b2-badges — My Circle home badge == chat-list sum (one shared function),
exclusions (blocked / removed / orphan / deleted / left group / not a party),
open -> 0, realtime badges.update, the repair_chat_read_state command, the
bell / Reminders-tab badge watermark (POST notif/opened), and the Discover
card rename migration.

Run: manage.py test core.tests_b2_badges --settings=assisto_backend.settings_test
"""
import importlib
import io
from datetime import datetime, timedelta

from django.apps import apps as django_apps
from django.core.management import CommandError, call_command
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core.logic import notif_centre as NC
from core.models import (ChatOrganiseState, CircleGroup, CircleGroupMember,
                         CircleMember, CircleMessage, CircleReceipt,
                         DiscoverCard, FamilyAlert, NotifEvent, Reminder,
                         RtEvent, User)

V = "/api/v1"


def mk(phone, name):
    return User.objects.create_user(name=name, phone=phone, password="pw12345!",
                                    language="en")


class _Base(TestCase):
    def setUp(self):
        self.a = mk("01710000001", "Amina")   # the owner
        self.b = mk("01710000002", "Bilal")   # the peer
        self.c = mk("01710000003", "Chaya")
        self.ab = CircleMember.objects.create(
            user=self.a, peer_user=self.b, name="Bilal", state="accepted",
            phone=self.b.phone, public_key="pkB")
        self.ba = CircleMember.objects.create(
            user=self.b, peer_user=self.a, name="Amina", state="accepted",
            phone=self.a.phone, direction="incoming", public_key="pkA")
        self.ca, self.cb, self.cc = (self.cl(self.a), self.cl(self.b),
                                     self.cl(self.c))

    def cl(self, u):
        c = APIClient()
        c.force_authenticate(u)
        c.credentials(HTTP_ACCEPT_LANGUAGE="en")
        return c

    def send(self, client, edge, cmid):
        r = client.post("%s/circle/%d/messages" % (V, edge.id), {
            "ciphertext": "Q1Q=", "nonce": "Tg==", "client_msg_id": cmid},
            format="json")
        self.assertEqual(r.status_code, 201, r.content)
        return r.json()["id"]

    def badge(self, client):
        return client.get(V + "/home/badges").json()["my_circle_unread"]

    def list_sum(self, client):
        """The app's rule (ChatPreview.unreadOf + _publishUnread)."""
        rows = client.get(V + "/circle/chats").json()["results"]
        s = 0
        for r in rows:
            if r.get("archived"):
                continue
            n = r.get("unread") or 0
            s += n if n > 0 else (1 if r.get("marked_unread") else 0)
        return s

    def assertBadge(self, client, n):
        self.assertEqual(self.badge(client), n)
        self.assertEqual(self.list_sum(client), n)


class MyCircleBadgeTests(_Base):
    def test_owner_bug_14_then_open_is_0_and_new_message_1_then_0(self):
        # the live shape: 14 incoming on the PEER's edge (peer_user = me)
        for i in range(14):
            self.send(self.cb, self.ba, "m%d" % i)
        self.assertBadge(self.ca, 14)
        r = self.ca.post("%s/circle/%d/seen" % (V, self.ab.id))
        self.assertEqual(r.status_code, 200)
        self.assertBadge(self.ca, 0)
        # "app kill / relaunch": a brand-new client sees the server state
        self.assertBadge(self.cl(self.a), 0)
        self.send(self.cb, self.ba, "new")
        self.assertBadge(self.ca, 1)
        self.ca.post("%s/circle/%d/seen" % (V, self.ab.id))
        self.assertBadge(self.cl(self.a), 0)

    def test_group_unread_counted_and_cleared(self):
        g = CircleGroup.objects.create(creator=self.b, name="Family")
        CircleGroupMember.objects.create(group=g, member=self.b, role="admin")
        CircleGroupMember.objects.create(group=g, member=self.a)
        for i in range(3):
            CircleMessage.objects.create(group=g, sender=self.b, ciphertext="x")
        self.send(self.cb, self.ba, "1to1")
        self.assertBadge(self.ca, 4)
        self.ca.post("%s/circle/groups/%d/seen" % (V, g.id))
        self.assertBadge(self.ca, 1)
        self.ca.post("%s/circle/%d/seen" % (V, self.ab.id))
        self.assertBadge(self.ca, 0)

    def test_excludes_blocked_contact(self):
        self.send(self.cb, self.ba, "m1")
        self.ab.blocked = True
        self.ab.save()
        self.assertBadge(self.ca, 0)

    def test_excludes_removed_contact(self):
        self.send(self.cb, self.ba, "m1")
        for st in ("declined", "pending", "blocked"):
            CircleMember.objects.filter(pk=self.ab.pk).update(state=st)
            self.assertBadge(self.ca, 0)

    def test_excludes_orphan_rows_no_edge_of_mine(self):
        self.send(self.cb, self.ba, "m1")
        self.ab.delete()          # my edge is gone; the peer's row remains
        self.assertEqual(CircleMessage.objects.count(), 1)
        self.assertBadge(self.ca, 0)

    def test_excludes_messages_i_am_not_party_to(self):
        bc = CircleMember.objects.create(user=self.b, peer_user=self.c,
                                         name="Chaya", state="accepted",
                                         phone=self.c.phone)
        CircleMember.objects.create(user=self.c, peer_user=self.b,
                                    name="Bilal", state="accepted",
                                    phone=self.b.phone)
        self.send(self.cb, bc, "to-c")
        self.assertBadge(self.ca, 0)
        self.assertBadge(self.cc, 1)

    def test_excludes_deleted_for_everyone(self):
        mid = self.send(self.cb, self.ba, "m1")
        self.send(self.cb, self.ba, "m2")
        CircleMessage.objects.filter(pk=mid).update(deleted="everyone")
        self.assertBadge(self.ca, 1)

    def test_excludes_left_removed_and_deleted_groups(self):
        g = CircleGroup.objects.create(creator=self.b, name="G")
        CircleGroupMember.objects.create(group=g, member=self.b, role="admin")
        gm = CircleGroupMember.objects.create(group=g, member=self.a)
        CircleMessage.objects.create(group=g, sender=self.b, ciphertext="x")
        self.assertBadge(self.ca, 1)
        for st in ("left", "removed"):
            CircleGroupMember.objects.filter(pk=gm.pk).update(status=st)
            self.assertBadge(self.ca, 0)
        CircleGroupMember.objects.filter(pk=gm.pk).update(status="active")
        self.assertBadge(self.ca, 1)
        g.delete()
        self.assertBadge(self.ca, 0)

    def test_archived_and_marked_unread_agree_with_list(self):
        self.send(self.cb, self.ba, "m1")
        ChatOrganiseState.objects.create(user=self.a, chat_kind="member",
                                         chat_id=str(self.ab.id), archived=True)
        self.assertBadge(self.ca, 0)
        ChatOrganiseState.objects.filter(user=self.a).update(archived=False)
        self.ca.post("%s/circle/%d/seen" % (V, self.ab.id))
        self.ca.post(V + "/circle/chats/unread", {
            "chat_kind": "member", "chat_id": self.ab.id, "unread": True},
            format="json")
        self.assertBadge(self.ca, 1)
        self.ca.post("%s/circle/%d/seen" % (V, self.ab.id))
        self.assertBadge(self.ca, 0)

    def test_realtime_badges_update_on_message_and_seen(self):
        RtEvent.objects.all().delete()
        self.send(self.cb, self.ba, "m1")
        self.assertTrue(RtEvent.objects.filter(user=self.a,
                                               topic="badges.update").exists())
        self.assertFalse(RtEvent.objects.filter(user=self.b,
                                                topic="badges.update").exists())
        RtEvent.objects.all().delete()
        self.ca.post("%s/circle/%d/seen" % (V, self.ab.id))
        self.assertTrue(RtEvent.objects.filter(user=self.a,
                                               topic="badges.update").exists())
        ev = self.ca.get(V + "/rt/events?after=0").json()["events"]
        self.assertIn("badges.update", [e["topic"] for e in ev])


class RepairCommandTests(_Base):
    def setUp(self):
        super().setUp()
        # an hour of slack: a slow box must not push setUp rows past the cut
        self.cut = timezone.now() + timedelta(hours=1)
        # chat 1 (A opened it: A replied once): 13 old incoming from B
        self.old = [self.send(self.cb, self.ba, "o%d" % i) for i in range(13)]
        self.send(self.ca, self.ab, "my-reply")
        # chat 2 (never opened by A): C's messages
        self.ac = CircleMember.objects.create(user=self.a, peer_user=self.c,
                                              name="Chaya", state="accepted",
                                              phone=self.c.phone)
        self.ca_edge = CircleMember.objects.create(
            user=self.c, peer_user=self.a, name="Amina", state="accepted",
            phone=self.a.phone)
        self.never = [self.send(self.cc, self.ca_edge, "c%d" % i)
                      for i in range(2)]
        # after the cutoff
        self.late = self.send(self.cb, self.ba, "late")
        CircleMessage.objects.filter(pk=self.late).update(
            created_at=self.cut + timedelta(minutes=5))

    def run_cmd(self, *args):
        out = io.StringIO()
        call_command("repair_chat_read_state", *args, stdout=out)
        return out.getvalue()

    def test_requires_before(self):
        with self.assertRaises(CommandError):
            self.run_cmd()
        with self.assertRaises(CommandError):
            self.run_cmd("--before", "yesterday")

    def test_dry_run_writes_nothing_then_real_run_and_idempotent(self):
        self.assertEqual(self.badge(self.ca), 16)
        out = self.run_cmd("--before", self.cut.isoformat(), "--dry-run")
        self.assertIn("user=%d member:%d messages=13" % (self.a.id, self.ab.id),
                      out)
        self.assertIn("DRY RUN", out)
        self.assertEqual(self.badge(self.ca), 16)
        self.assertFalse(CircleReceipt.objects.filter(
            user=self.a, seen_at__isnull=False).exists())
        out2 = self.run_cmd("--before", self.cut.isoformat(),
                            "--user", str(self.a.id))
        self.assertIn("user=%d member:%d messages=13" % (self.a.id, self.ab.id),
                      out2)
        self.assertIn("marked read: 13 message(s) in 1 chat(s)", out2)
        # never-opened chat (2) + the late message (1) stay unread
        self.assertEqual(self.badge(self.ca), 3)
        for mid in self.old:
            x = CircleMessage.objects.get(pk=mid)
            self.assertIn(self.a.id, x.read_by)
            self.assertTrue(CircleReceipt.objects.get(
                message_id=mid, user=self.a).seen_at)
        for mid in self.never + [self.late]:
            self.assertNotIn(self.a.id,
                             CircleMessage.objects.get(pk=mid).read_by or [])
        # idempotent
        out3 = self.run_cmd("--before", self.cut.isoformat(),
                            "--user", str(self.a.id))
        self.assertIn(": 0 message(s) in 0 chat(s)", out3)
        self.assertEqual(self.badge(self.ca), 3)

    def test_receipt_counts_as_opened(self):
        CircleReceipt.objects.create(message_id=self.never[0], user=self.a,
                                     delivered_at=timezone.now())
        out = self.run_cmd("--before", self.cut.isoformat(), "--user",
                           str(self.a.id))
        self.assertIn("member:%d messages=2" % self.ac.id, out)
        self.assertEqual(self.badge(self.ca), 1)   # only the late one

    def test_group_repair(self):
        g = CircleGroup.objects.create(creator=self.b, name="G")
        CircleGroupMember.objects.create(group=g, member=self.b, role="admin")
        CircleGroupMember.objects.create(group=g, member=self.a)
        CircleMessage.objects.create(group=g, sender=self.b, ciphertext="x")
        CircleMessage.objects.create(group=g, sender=self.a, ciphertext="y")
        CircleMessage.objects.create(group=g, sender=self.b, ciphertext="z")
        out = self.run_cmd("--before", self.cut.isoformat())
        self.assertIn("group:%d messages=2" % g.id, out)


class BellBadgeTests(_Base):
    def ev(self, user, **kw):
        return NotifEvent.objects.create(user=user, type=kw.pop("type", "plan"),
                                         title_en="t", title_bn="t", **kw)

    def bell(self):
        return self.ca.get(V + "/home/badges").json()["notif_unseen"]

    def test_opening_clears_badge_items_stay_unread(self):
        self.ev(self.a)
        self.ev(self.a)
        self.assertEqual(self.bell(), 2)
        r = self.ca.post(V + "/notif/opened", {}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(self.bell(), 0)
        feed = self.ca.get(V + "/notif/feed").json()
        self.assertEqual(feed["unseen"], 2)            # still bold
        self.assertTrue(all(not i["seen"] for i in feed["items"]))
        self.assertEqual(feed["bell_badge"], 0)
        self.ev(self.a)                                # newer -> counts
        self.assertEqual(self.bell(), 1)
        self.assertEqual(self.cl(self.a).get(V + "/home/badges")
                         .json()["notif_unseen"], 1)   # survives relaunch

    def test_sos_and_family_alerts_never_cleared_by_opening(self):
        self.ev(self.a, type="sos")
        fa = FamilyAlert.objects.create(user=self.a, kind="checkin_overdue",
                                        title="please check")
        self.ev(self.a)
        self.assertEqual(self.bell(), 3)
        self.ca.post(V + "/notif/opened", {"scopes": ["bell", "feed"]},
                     format="json")
        self.assertEqual(self.bell(), 2)
        self.assertEqual(self.ca.get(V + "/notif/feed").json()["badge"], 2)
        # handled individually -> stop counting
        self.ca.post("%s/notif/familyalert:%d/seen" % (V, fa.id))
        sos = NotifEvent.objects.get(user=self.a, type="sos")
        self.ca.post("%s/notif/notif:%d/seen" % (V, sos.id))
        self.assertEqual(self.bell(), 0)

    def test_tabs_have_their_own_watermark(self):
        self.ev(self.a)
        self.ca.post(V + "/notif/opened", {"scope": "bell"}, format="json")
        self.assertEqual(self.bell(), 0)
        self.assertEqual(self.ca.get(V + "/notif/feed").json()["badge"], 1)
        self.ca.post(V + "/notif/opened", {"scope": "feed"}, format="json")
        self.assertEqual(self.ca.get(V + "/notif/feed").json()["badge"], 0)

    def test_reminders_tab_badge(self):
        now = timezone.now()
        Reminder.objects.create(user=self.a, title="old",
                                due_at=now - timedelta(hours=3))
        Reminder.objects.create(user=self.a, title="later",
                                due_at=now + timedelta(days=2))
        j = self.ca.get(V + "/notif/reminders").json()
        self.assertEqual(j["badge"], 1)                # upcoming never counts
        self.ca.post(V + "/notif/opened", {"scope": "bell"}, format="json")
        self.assertEqual(self.ca.get(V + "/notif/reminders").json()["badge"], 1)
        self.ca.post(V + "/notif/opened", {"scope": "reminders"}, format="json")
        j = self.ca.get(V + "/notif/reminders").json()
        self.assertEqual(j["badge"], 0)
        self.assertEqual(j["counts"]["missed"] + j["counts"]["today"], 1)

    def test_bad_scope(self):
        r = self.ca.post(V + "/notif/opened", {"scope": "x"}, format="json")
        self.assertEqual(r.status_code, 400)

    def test_new_notif_queues_realtime(self):
        RtEvent.objects.all().delete()
        self.ev(self.a)
        self.assertTrue(RtEvent.objects.filter(user=self.a,
                                               topic="badges.update").exists())


class PureBadgeTests(TestCase):
    def test_badge_count(self):
        ev = [{"id": 1, "type": "plan", "at": "2026-10-22T10:00:00", "seen": False},
              {"id": 2, "type": "plan", "seen": False,
               "at": datetime(2026, 10, 22, 12, 0, 0, 500000)},
              {"id": 3, "type": "plan", "at": "2026-10-22T13:00:00", "seen": True},
              {"id": 4, "type": "sos", "at": "2026-10-01T00:00:00", "seen": False}]
        self.assertEqual(NC.badge_count(ev, None), 3)
        self.assertEqual(NC.badge_count(ev, "2026-10-22T12:00:00.400000"), 2)
        self.assertEqual(NC.badge_count(ev, "2026-10-23T00:00:00"), 1)


class DiscoverRenameMigrationTests(TestCase):
    def test_renames_only_seed_text(self):
        mig = importlib.import_module("core.migrations.0056_b2_badges")
        card = DiscoverCard.objects.get(key="photo_enhance")
        self.assertEqual(card.title_en, "Photo Studio")   # applied in test DB
        self.assertEqual(card.title_bn, "ফটো স্টুডিও")
        # back to the seed -> the migration renames it
        card.title_en, card.title_bn = "Enhance photo", "ছবি উন্নত করুন"
        card.save()
        mig.rename_card(django_apps, None)
        card.refresh_from_db()
        self.assertEqual((card.title_en, card.title_bn),
                         ("Photo Studio", "ফটো স্টুডিও"))
        # an owner edit is never overwritten
        card.title_en, card.title_bn = "My photos", "আমার ছবি"
        card.save()
        mig.rename_card(django_apps, None)
        card.refresh_from_db()
        self.assertEqual((card.title_en, card.title_bn), ("My photos", "আমার ছবি"))
