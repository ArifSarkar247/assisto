"""remnotes (owner review 28 Oct) — Reminders & Notes server rules.

* A note's checklist / tags / colour / priority / due date / reminder link,
  a reminder's priority + label and a to-do's priority + repeat SURVIVE a
  round trip (the first sync used to wipe them — the app replaces its copy
  with the server's list).
* Everything is sanitised, never rejected (an offline write must not get
  stuck): long lists trimmed, unknown colour -> "", someone else's vault
  document dropped from attachments.
* Abuse caps per day / in total (bilingual message, 429) — no paywall.
* Share a note with one accepted My Circle member: a copy in their notes,
  attachments never copied, push (not in quiet hours), strangers / blocked
  refused, rate-limited.
"""
from unittest import mock

from django.core.cache import cache
from django.test import TestCase
from rest_framework.test import APIClient

from core import remnotes as RN
from core.models import CircleMember, Document, Note, Reminder, Todo, User

V = "/api/v1"


def mk(phone, name, lang="en"):
    return User.objects.create_user(name=name, phone=phone, password="pw12345!",
                                    language=lang)


def cl(u, lang="en"):
    c = APIClient()
    c.force_authenticate(u)
    c.credentials(HTTP_ACCEPT_LANGUAGE=lang)
    return c


def pair(a, b):
    ab = CircleMember.objects.create(user=a, peer_user=b, name=b.name, phone=b.phone,
                                     relation="mother", state="accepted")
    ba = CircleMember.objects.create(user=b, peer_user=a, name=a.name,
                                     state="accepted", direction="incoming")
    return ab, ba


class Base(TestCase):
    def setUp(self):
        cache.clear()
        self.a = mk("01711300001", "Rina")
        self.b = mk("01711300002", "Ma", lang="bn")
        self.x = mk("01711300003", "Stranger")
        self.ab, self.ba = pair(self.a, self.b)
        self.ca, self.cb, self.cx = cl(self.a), cl(self.b, "bn"), cl(self.x)
        self.pushes = []

        def spy(user, kind, tbn, ten, bbn="", ben="", data=None, **kw):
            self.pushes.append({"user": user.pk, "kind": kind, "ten": ten,
                                "data": dict(data or {})})
            return True

        p = mock.patch("core.push.safe_push", side_effect=spy)
        p.start()
        self.addCleanup(p.stop)


class NoteFieldsSurviveSyncTests(Base):
    """The bug: checklist etc. vanished after the first sync."""

    def test_checklist_tags_colour_due_round_trip(self):
        r = self.ca.post(f"{V}/notes/", {
            "title": "Bazar", "body": "", "pinned": True,
            "checklist": [{"text": "চাল", "done": False}, {"text": "ডাল", "done": True}],
            "tags": ["bazar", "family"], "color": "green", "priority": "high",
            "due_at": "2026-11-01T03:00:00Z", "reminder_local_id": "123-456",
        }, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        listed = self.ca.get(f"{V}/notes/").json()
        self.assertEqual(len(listed), 1)
        n = listed[0]
        self.assertEqual(n["checklist"], [{"text": "চাল", "done": False},
                                          {"text": "ডাল", "done": True}])
        self.assertEqual(n["tags"], ["bazar", "family"])
        self.assertEqual(n["color"], "green")
        self.assertEqual(n["priority"], "high")
        self.assertTrue(n["due_at"].startswith("2026-11-01"))
        self.assertEqual(n["reminder_local_id"], "123-456")
        self.assertTrue(n["pinned"])

    def test_update_ticks_checklist(self):
        nid = self.ca.post(f"{V}/notes/", {"title": "x", "checklist": ["a", "b"]},
                           format="json").json()["id"]
        r = self.ca.patch(f"{V}/notes/{nid}/", {"checklist": [
            {"text": "a", "done": True}, {"text": "b", "done": False}]}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(Note.objects.get(pk=nid).checklist[0], {"text": "a", "done": True})

    def test_reminder_priority_and_label_round_trip(self):
        r = self.ca.post(f"{V}/reminders/", {
            "title": "Medicine", "due_at": "2026-11-01T02:00:00Z",
            "recurrence": "daily", "recurrence_rule": {"freq": "daily", "time": "08:00"},
            "priority": "high", "category": "Health", "link": {}}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        got = self.ca.get(f"{V}/reminders/").json()[0]
        self.assertEqual(got["priority"], "high")
        self.assertEqual(got["category"], "Health")

    def test_todo_priority_and_repeat_round_trip(self):
        r = self.ca.post(f"{V}/todos/", {
            "title": "Pay rent", "priority": "high", "due_at": "2026-11-05T04:00:00Z",
            "recurrence_rule": {"freq": "monthly", "interval": 1, "day_of_month": 5}},
            format="json")
        self.assertEqual(r.status_code, 201, r.content)
        got = self.ca.get(f"{V}/todos/").json()[0]
        self.assertEqual(got["priority"], "high")
        self.assertEqual(got["recurrence_rule"],
                         {"freq": "monthly", "interval": 1, "day_of_month": 5})

    def test_old_app_payload_still_works(self):
        # an older app build sends only title/body/pinned (and nulls)
        r = self.ca.post(f"{V}/notes/", {"title": "old", "body": "b", "pinned": False,
                                         "checklist": None, "tags": None,
                                         "color": None, "priority": None}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        n = Note.objects.get(pk=r.json()["id"])
        self.assertEqual((n.checklist, n.tags, n.color, n.priority), ([], [], "", "none"))


class SanitiseNeverRejectTests(Base):
    def test_lists_trimmed_and_bad_values_cleaned(self):
        r = self.ca.post(f"{V}/notes/", {
            "title": "t" * 500,
            "checklist": [{"text": f"item {i}"} for i in range(RN.CHECKLIST_MAX + 50)]
            + [{"text": "   "}, 42],
            "tags": ["#a", "A", "b", "", *[f"t{i}" for i in range(40)]],
            "color": "neon-pink", "priority": "urgent!!",
        }, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        n = Note.objects.get(pk=r.json()["id"])
        self.assertEqual(len(n.checklist), RN.CHECKLIST_MAX)
        self.assertEqual(n.tags[:2], ["a", "b"])  # '#' stripped, duplicate 'A' dropped
        self.assertEqual(len(n.tags), RN.TAGS_MAX)
        self.assertEqual(n.color, "")
        self.assertEqual(n.priority, "none")
        self.assertEqual(len(n.title), 200)

    def test_bad_repeat_rule_becomes_empty(self):
        self.assertEqual(RN.clean_rule({"freq": "hourly"}), {})
        self.assertEqual(RN.clean_rule({"freq": "weekly", "weekday": 9, "interval": 0,
                                        "time": "25:00"}),
                         {"freq": "weekly", "interval": 1})
        self.assertEqual(RN.clean_rule("daily"), {})

    def test_only_own_vault_documents_attach(self):
        mine = Document.objects.create(user=self.a, title="NID")
        theirs = Document.objects.create(user=self.x, title="Secret")
        r = self.ca.post(f"{V}/notes/", {"title": "papers", "attachments": [
            {"doc_id": mine.pk, "title": "renamed"}, {"doc_id": theirs.pk}, "junk"]},
            format="json")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(Note.objects.get(pk=r.json()["id"]).attachments,
                         [{"doc_id": mine.pk, "title": "NID"}])

    def test_notes_are_per_user(self):
        nid = self.ca.post(f"{V}/notes/", {"title": "mine"}, format="json").json()["id"]
        self.assertEqual(self.cx.get(f"{V}/notes/").json(), [])
        self.assertEqual(self.cx.patch(f"{V}/notes/{nid}/", {"title": "x"},
                                       format="json").status_code, 404)


class CapTests(Base):
    def test_daily_cap_refuses_bilingual(self):
        with mock.patch.object(RN, "DAILY_CREATES", 2):
            for i in range(2):
                self.assertEqual(self.cb.post(f"{V}/todos/", {"title": f"t{i}"},
                                              format="json").status_code, 201)
            r = self.cb.post(f"{V}/todos/", {"title": "t3"}, format="json")
        self.assertEqual(r.status_code, 429)
        self.assertEqual(r.json()["reason"], "daily_cap")
        self.assertIn("কাল", r.json()["detail"])
        self.assertEqual(Todo.objects.filter(user=self.b).count(), 2)

    def test_total_cap_english(self):
        with mock.patch.dict(RN.TOTAL_CAP, {"reminder": 1}):
            self.assertEqual(self.ca.post(f"{V}/reminders/", {"title": "a", "link": {}},
                                          format="json").status_code, 201)
            r = self.ca.post(f"{V}/reminders/", {"title": "b", "link": {}}, format="json")
        self.assertEqual(r.status_code, 429)
        self.assertEqual(r.json()["reason"], "total_cap")
        self.assertIn("limit", r.json()["detail"])
        self.assertEqual(Reminder.objects.filter(user=self.a).count(), 1)

    def test_updates_never_capped(self):
        nid = self.ca.post(f"{V}/notes/", {"title": "a"}, format="json").json()["id"]
        with mock.patch.dict(RN.TOTAL_CAP, {"note": 0}):
            self.assertEqual(self.ca.patch(f"{V}/notes/{nid}/", {"title": "b"},
                                           format="json").status_code, 200)


class ShareNoteTests(Base):
    def _note(self, **kw):
        doc = Document.objects.create(user=self.a, title="NID")
        data = {"title": "Bazar list", "body": "for Friday",
                "checklist": [{"text": "চাল", "done": False}], "tags": ["bazar"],
                "color": "yellow", "attachments": [{"doc_id": doc.pk}]}
        data.update(kw)
        return self.ca.post(f"{V}/notes/", data, format="json").json()["id"]

    def test_copy_lands_in_circle_member_notes_with_push(self):
        nid = self._note()
        r = self.ca.post(f"{V}/notes/{nid}/share/", {"circle_id": self.ab.id},
                         format="json")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(r.json()["attachments_dropped"], 1)
        got = self.cb.get(f"{V}/notes/").json()
        self.assertEqual(len(got), 1)
        n = got[0]
        self.assertEqual(n["title"], "Bazar list")
        self.assertEqual(n["checklist"], [{"text": "চাল", "done": False}])
        self.assertEqual(n["attachments"], [])  # vault stays private
        self.assertEqual(n["shared_from"], {"user": self.a.pk, "name": "Rina"})
        self.assertEqual(n["source"], "shared")
        push = [p for p in self.pushes if p["user"] == self.b.pk]
        self.assertEqual(len(push), 1)
        self.assertEqual(push[0]["data"]["route"], "notes")
        # the sender's note is untouched
        self.assertEqual(Note.objects.filter(user=self.a).count(), 1)

    def test_shared_from_is_read_only(self):
        r = self.ca.post(f"{V}/notes/", {"title": "x", "shared_from": {"user": 999,
                                                                       "name": "Fake"}},
                         format="json")
        self.assertEqual(Note.objects.get(pk=r.json()["id"]).shared_from, {})

    def test_stranger_and_other_peoples_edges_refused(self):
        nid = self._note()
        # x's edge id, not the caller's
        xe = CircleMember.objects.create(user=self.x, peer_user=self.b, name="Ma",
                                         state="accepted")
        for cid in (xe.id, 99999, "abc", None):
            r = self.ca.post(f"{V}/notes/{nid}/share/", {"circle_id": cid}, format="json")
            self.assertEqual(r.status_code, 404, (cid, r.content))
            self.assertEqual(r.json()["reason"], "not_in_circle")
        # someone else's note cannot be shared by me
        xn = Note.objects.create(user=self.x, title="theirs")
        self.assertEqual(self.ca.post(f"{V}/notes/{xn.pk}/share/",
                                      {"circle_id": self.ab.id},
                                      format="json").status_code, 404)
        self.assertEqual(Note.objects.filter(user=self.b).count(), 0)

    def test_pending_or_blocked_refused(self):
        nid = self._note()
        self.ab.state = "pending"
        self.ab.save()
        self.assertEqual(self.ca.post(f"{V}/notes/{nid}/share/", {"circle_id": self.ab.id},
                                      format="json").status_code, 404)
        self.ab.state = "accepted"
        self.ab.save()
        self.ba.blocked = True  # Ma blocked Rina
        self.ba.save()
        self.assertEqual(self.ca.post(f"{V}/notes/{nid}/share/", {"circle_id": self.ab.id},
                                      format="json").status_code, 404)
        self.assertEqual(Note.objects.filter(user=self.b).count(), 0)

    def test_quiet_hours_no_push_but_copy(self):
        nid = self._note()
        with mock.patch("core.family_alerts.in_quiet_hours", return_value=True):
            r = self.ca.post(f"{V}/notes/{nid}/share/", {"circle_id": self.ab.id},
                             format="json")
        self.assertEqual(r.status_code, 201)
        self.assertEqual(Note.objects.filter(user=self.b).count(), 1)
        self.assertEqual([p for p in self.pushes if p["user"] == self.b.pk], [])

    def test_rate_limited_bangla(self):
        nid = self._note()
        ca_bn = cl(self.a, "bn")
        with mock.patch.object(RN, "SHARES_PER_DAY", 1):
            self.assertEqual(ca_bn.post(f"{V}/notes/{nid}/share/", {"circle_id": self.ab.id},
                                        format="json").status_code, 201)
            r = ca_bn.post(f"{V}/notes/{nid}/share/", {"circle_id": self.ab.id},
                           format="json")
        self.assertEqual(r.status_code, 429)
        self.assertEqual(r.json()["reason"], "rate_limited")
        self.assertIn("কাল", r.json()["detail"])
