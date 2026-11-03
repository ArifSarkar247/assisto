"""carecall (owner order 4 Nov 01:50) — Care Call server rules.

Consent once + stop any time; only accepted My Circle family; the text is
stored EXACTLY as written (medicine words never blocked); rings follow the
ladder T -> T+10 (retry) -> setter told after two unanswered rings; Done ->
setter confirmed (also late, from the offline queue); Snooze -> +10 min;
receiver quiet hours defer a ring; fair limits; voice only to the pair."""
import base64
from datetime import date, datetime, timedelta
from unittest import mock

from django.test import TestCase
from rest_framework.test import APIClient

from core import carecall as CC
from core.models import (CareCall, CareCallLink, CareCallRing, CircleMember,
                         CirclePrivacy, User)

V = "/api/v1"
TZ = CC.TZ


def mk(phone, name, lang="en"):
    return User.objects.create_user(name=name, phone=phone, password="pw12345!", language=lang)


def cl(u, lang="en"):
    c = APIClient()
    c.force_authenticate(u)
    c.credentials(HTTP_ACCEPT_LANGUAGE=lang)
    return c


def pair(a, b, a_calls_b="Ammu", b_calls_a="Arif"):
    CircleMember.objects.create(user=a, peer_user=b, name=a_calls_b, phone=b.phone,
                                relation="mother", state="accepted")
    CircleMember.objects.create(user=b, peer_user=a, name=b_calls_a, phone=a.phone,
                                relation="son", state="accepted", direction="incoming")


def at(y, mo, d, h, mi):
    return datetime(y, mo, d, h, mi, tzinfo=TZ)


class Spy:
    def __init__(self):
        self.calls = []

    def __call__(self, user, kind, tbn, ten, bbn="", ben="", data=None, high=False):
        self.calls.append({"user": user.pk, "kind": kind, "tbn": tbn, "ten": ten,
                           "bbn": bbn, "ben": ben, "data": dict(data or {}), "high": high})
        return True

    def kinds(self, u=None):
        return [c["kind"] for c in self.calls if u is None or c["user"] == u.pk]


class Base(TestCase):
    def setUp(self):
        self.arif = mk("01711000001", "Arif Hasan")
        self.ammu = mk("01711000002", "Rahima", lang="bn")
        self.stranger = mk("01711000003", "Stranger")
        pair(self.arif, self.ammu)
        self.spy = Spy()
        p = mock.patch.object(CC, "_push", self.spy)
        p.start()
        self.addCleanup(p.stop)
        self.a, self.m = cl(self.arif), cl(self.ammu, "bn")

    def new(self, **kw):
        body = {"receiver_id": self.ammu.pk, "text": "take your gas tablet",
                "time": "09:00", "repeat": "daily"}
        body.update(kw)
        return self.a.post(V + "/carecall", body, format="json")

    def accept(self):
        return self.m.post(V + "/carecall/consent", {"setter_id": self.arif.pk, "accept": True},
                           format="json")


class ConsentTests(Base):
    def test_people_lists_circle_family_only(self):
        rows = self.a.get(V + "/carecall/people").json()["results"]
        self.assertEqual([r["user_id"] for r in rows], [self.ammu.pk])
        self.assertEqual(rows[0]["name"], "Ammu")
        self.assertEqual(rows[0]["initial"], "A")
        self.assertEqual(rows[0]["link"], "none")

    def test_stranger_refused(self):
        r = self.new(receiver_id=self.stranger.pk)
        self.assertEqual(r.status_code, 404)
        self.assertEqual(r.json()["reason"], "not_in_circle")
        self.assertFalse(CareCall.objects.exists())

    def test_first_care_call_asks_receiver_once(self):
        r = self.new()
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(r.json()["link"], "pending")
        self.assertEqual(self.spy.kinds(self.ammu), ["carecall_invite"])
        inv = self.spy.calls[0]
        self.assertIn("Arif", inv["tbn"])          # the receiver's own name for him
        self.new(time="20:00")                     # a second schedule: no second invite
        self.assertEqual(self.spy.kinds(self.ammu), ["carecall_invite"])
        data = self.m.get(V + "/carecall").json()
        self.assertEqual([i["setter_id"] for i in data["invites"]], [self.arif.pk])
        self.assertEqual(data["received"], [])     # nothing until accepted

    def test_accept_then_stop_any_time(self):
        self.new()
        self.assertEqual(self.accept().json()["status"], "accepted")
        self.assertIn("carecall_status", self.spy.kinds(self.arif))
        self.assertEqual(len(self.m.get(V + "/carecall").json()["received"]), 1)
        r = self.m.post(V + "/carecall/consent", {"setter_id": self.arif.pk, "accept": False},
                        format="json")
        self.assertEqual(r.json()["status"], "stopped")
        self.assertEqual(self.m.get(V + "/carecall").json()["received"], [])
        r = self.new(time="21:00")
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()["reason"], "receiver_stopped")

    def test_nothing_rings_without_consent(self):
        self.new()
        cc = CareCall.objects.get()
        CC.tick(now=cc.next_at + timedelta(seconds=5))
        self.assertFalse(CareCallRing.objects.exists())
        self.assertNotIn("carecall", self.spy.kinds())

    def test_stop_cancels_waiting_rings(self):
        self.new()
        self.accept()
        cc = CareCall.objects.get()
        CC.tick(now=cc.next_at + timedelta(seconds=5))
        self.m.post(V + "/carecall/consent", {"setter_id": self.arif.pk, "accept": False}, format="json")
        self.assertEqual(CareCallRing.objects.get().status, "off")


class TextNeverFilteredTests(Base):
    def test_medicine_words_saved_exactly(self):
        for text in ("গ্যাসের ট্যাবলেটটা খাও", "Napa 500mg + Seclo 20 before food",
                     "ওষুধ খাওয়ার সময়: Losectil, insulin 10 units", "medicine time"):
            r = self.new(text="  " + text + "\n")
            self.assertEqual(r.status_code, 201, r.content)
            self.assertEqual(r.json()["care_call"]["text"], text)
        self.assertEqual(CareCall.objects.count(), 4)

    def test_ring_carries_the_text_unchanged(self):
        self.new(text="গ্যাসের ট্যাবলেটটা খাও")
        self.accept()
        cc = CareCall.objects.get()
        CC.tick(now=cc.next_at + timedelta(seconds=5))
        ring = [c for c in self.spy.calls if c["kind"] == "carecall"][0]
        self.assertEqual(ring["data"]["text"], "গ্যাসের ট্যাবলেটটা খাও")
        self.assertEqual(ring["bbn"], "গ্যাসের ট্যাবলেটটা খাও")
        self.assertTrue(ring["high"])


class ScheduleTests(Base):
    def test_next_slot_rules(self):
        after = at(2026, 11, 4, 9, 30)   # a Wednesday
        self.assertEqual(CC.next_slot("daily", "09:00", [], None, after), at(2026, 11, 5, 9, 0))
        self.assertEqual(CC.next_slot("daily", "10:00", [], None, after), at(2026, 11, 4, 10, 0))
        # chosen days: Friday (4) only
        self.assertEqual(CC.next_slot("days", "09:00", [4], None, after), at(2026, 11, 6, 9, 0))
        self.assertIsNone(CC.next_slot("days", "09:00", [], None, after))
        self.assertEqual(CC.next_slot("once", "11:00", [], date(2026, 11, 4), after), at(2026, 11, 4, 11, 0))
        self.assertIsNone(CC.next_slot("once", "09:00", [], date(2026, 11, 4), after))

    def test_quiet_hours_defer_to_window_end(self):
        self.assertEqual(CC.after_quiet(at(2026, 11, 4, 23, 0), "22:00", "07:00"), at(2026, 11, 5, 7, 0))
        self.assertEqual(CC.after_quiet(at(2026, 11, 5, 6, 0), "22:00", "07:00"), at(2026, 11, 5, 7, 0))
        self.assertEqual(CC.after_quiet(at(2026, 11, 5, 9, 0), "22:00", "07:00"), at(2026, 11, 5, 9, 0))
        self.assertEqual(CC.after_quiet(at(2026, 11, 5, 23, 0), "", ""), at(2026, 11, 5, 23, 0))

    def test_new_link_copies_circle_dnd(self):
        CirclePrivacy.objects.create(user=self.ammu, dnd_enabled=True, dnd_start="21:30", dnd_end="06:30")
        self.new()
        ln = CareCallLink.objects.get()
        self.assertEqual((ln.quiet_start, ln.quiet_end), ("21:30", "06:30"))

    def test_receiver_sets_own_quiet_hours(self):
        self.new()
        self.assertEqual(self.m.post(V + "/carecall/quiet", {"start": "23:00", "end": "06:00"},
                                     format="json").status_code, 200)
        self.assertEqual(CareCallLink.objects.get().quiet_start, "23:00")
        self.assertEqual(self.m.post(V + "/carecall/quiet", {"start": "23:00"}, format="json").status_code, 400)

    def test_ring_inside_quiet_waits(self):
        self.new(time="23:30")
        self.accept()
        cc = CareCall.objects.get()
        t = cc.next_at + timedelta(seconds=5)
        CC.tick(now=t)
        ring = CareCallRing.objects.get()
        self.assertEqual(ring.status, "pending")
        self.assertEqual(ring.due_at.astimezone(TZ).hour, 7)
        self.assertNotIn("carecall", self.spy.kinds())
        CC.tick(now=ring.due_at + timedelta(seconds=1))
        self.assertIn("carecall", self.spy.kinds(self.ammu))

    def test_once_turns_itself_off(self):
        today = (CC.timezone.now().astimezone(TZ) + timedelta(days=1)).date().isoformat()
        self.new(repeat="once", date=today, time="10:00")
        self.accept()
        cc = CareCall.objects.get()
        CC.tick(now=cc.next_at + timedelta(seconds=5))
        cc.refresh_from_db()
        self.assertFalse(cc.active)
        self.assertIsNone(cc.next_at)

    def test_stale_slot_never_rings_late(self):
        self.new()
        self.accept()
        cc = CareCall.objects.get()
        CC.tick(now=cc.next_at + timedelta(hours=2))
        self.assertFalse(CareCallRing.objects.exists())
        cc.refresh_from_db()
        self.assertIsNotNone(cc.next_at)          # the next day still rings


class LadderTests(Base):
    def setUp(self):
        super().setUp()
        self.new()
        self.accept()
        self.cc = CareCall.objects.get()
        self.t0 = self.cc.next_at

    def test_no_answer_retry_after_10_then_tell_setter(self):
        CC.tick(now=self.t0 + timedelta(seconds=5))
        ring = CareCallRing.objects.get()
        self.assertEqual((ring.status, ring.attempts), ("ringing", 1))
        CC.tick(now=self.t0 + timedelta(minutes=4))          # no answer
        ring.refresh_from_db()
        self.assertEqual((ring.status, ring.misses), ("pending", 1))
        self.assertEqual(ring.due_at, ring.last_ring_at + timedelta(minutes=10))
        CC.tick(now=self.t0 + timedelta(minutes=9))           # not yet
        self.assertEqual(self.spy.kinds(self.ammu).count("carecall"), 1)
        CC.tick(now=self.t0 + timedelta(minutes=10, seconds=10))
        self.assertEqual(self.spy.kinds(self.ammu).count("carecall"), 2)
        CC.tick(now=self.t0 + timedelta(minutes=14))
        ring.refresh_from_db()
        self.assertEqual(ring.status, "missed")
        told = [c for c in self.spy.calls if c["user"] == self.arif.pk and c["kind"] == "carecall_status"
                and c["data"].get("status") == "missed"]
        self.assertEqual(len(told), 1)
        self.assertIn("did not answer twice", told[0]["ten"])
        self.assertIn("Ammu", told[0]["ten"])
        CC.tick(now=self.t0 + timedelta(minutes=30))           # never twice
        self.assertEqual(self.spy.kinds(self.ammu).count("carecall"), 2)
        feed = self.a.get(V + "/carecall").json()["feed"]
        self.assertEqual(feed[0]["kind"], "missed")
        self.assertFalse(feed[0]["can_see_location"])         # no sharing for this pair
        self.assertIsNotNone(feed[0]["edge_id"])

    def test_done_confirms_to_setter(self):
        CC.tick(now=self.t0 + timedelta(seconds=5))
        slot = CareCallRing.objects.get().slot
        r = self.m.post(V + "/carecall/ack", {"care_call_id": self.cc.pk, "slot": slot,
                                              "action": "done"}, format="json")
        self.assertEqual(r.json()["status"], "done")
        self.m.post(V + "/carecall/ack", {"care_call_id": self.cc.pk, "slot": slot,
                                          "action": "done"}, format="json")   # idempotent
        ok = [c for c in self.spy.calls if c["kind"] == "carecall_status" and c["data"].get("status") == "done"]
        self.assertEqual(len(ok), 1)
        self.assertIn("confirmed", ok[0]["ten"])
        CC.tick(now=self.t0 + timedelta(minutes=20))
        self.assertEqual(self.spy.kinds(self.ammu).count("carecall"), 1)
        self.assertEqual(self.a.get(V + "/carecall").json()["feed"][0]["kind"], "confirmed")

    def test_snooze_rings_again_in_10(self):
        CC.tick(now=self.t0 + timedelta(seconds=5))
        slot = CareCallRing.objects.get().slot
        with mock.patch.object(CC.timezone, "now", return_value=self.t0 + timedelta(minutes=1)):
            self.m.post(V + "/carecall/ack", {"care_call_id": self.cc.pk, "slot": slot,
                                              "action": "snooze"}, format="json")
        ring = CareCallRing.objects.get()
        self.assertEqual(ring.status, "snoozed")
        CC.tick(now=self.t0 + timedelta(minutes=5))
        self.assertEqual(self.spy.kinds(self.ammu).count("carecall"), 1)
        CC.tick(now=self.t0 + timedelta(minutes=11, seconds=5))
        self.assertEqual(self.spy.kinds(self.ammu).count("carecall"), 2)

    def test_late_offline_done_after_escalation(self):
        for m in (0, 4, 11, 15):
            CC.tick(now=self.t0 + timedelta(minutes=m, seconds=5))
        slot = CareCallRing.objects.get().slot
        r = self.m.post(V + "/carecall/acks", {"acks": [
            {"care_call_id": self.cc.pk, "slot": slot, "action": "done"},
            {"care_call_id": 999999, "slot": slot, "action": "done"}]}, format="json")
        self.assertEqual([x["ok"] for x in r.json()["results"]], [True, True])
        ring = CareCallRing.objects.get()
        self.assertEqual((ring.status, ring.late), ("done", True))
        self.assertIn("late", [c["data"].get("status") for c in self.spy.calls if c["kind"] == "carecall_status"])

    def test_offline_done_before_server_rang(self):
        """The phone's own alarm rang with no internet: the queued Done
        creates the slot row, and the server then never rings it."""
        slot = CC.slot_of(self.t0)
        self.m.post(V + "/carecall/ack", {"care_call_id": self.cc.pk, "slot": slot,
                                          "action": "done"}, format="json")
        CC.tick(now=self.t0 + timedelta(seconds=5))
        self.assertNotIn("carecall", self.spy.kinds(self.ammu))

    def test_stranger_cannot_ack(self):
        CC.tick(now=self.t0 + timedelta(seconds=5))
        r = cl(self.stranger).post(V + "/carecall/ack", {"care_call_id": self.cc.pk,
                                                         "slot": CareCallRing.objects.get().slot,
                                                         "action": "done"}, format="json")
        self.assertEqual(r.status_code, 404)


class LimitsAndVoiceTests(Base):
    def test_active_limit(self):
        with mock.patch.object(CC, "limits", return_value=dict(CC.LIMIT_DEFAULTS, carecall_active_per_setter=2)):
            self.assertEqual(self.new().status_code, 201)
            self.assertEqual(self.new().status_code, 201)
            r = self.new()
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()["reason"], "limit_active")
        self.assertIn("2", r.json()["detail"])

    def test_text_limit_refuses_never_cuts(self):
        r = self.new(text="x" * 301)
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()["reason"], "text_too_long")

    def test_bad_inputs(self):
        self.assertEqual(self.new(time="25:00").json()["reason"], "bad_time")
        self.assertEqual(self.new(repeat="days", days=[]).json()["reason"], "bad_days")
        self.assertEqual(self.new(text="").json()["reason"], "text_required")

    def test_voice_only_for_the_pair(self):
        clip = base64.b64encode(b"\x00\x00\x00\x18ftypM4A " + b"0" * 200).decode()
        r = self.new(text="", voice_b64=clip, voice_sec=4)
        self.assertEqual(r.status_code, 201, r.content)
        cid = r.json()["care_call"]["id"]
        self.assertTrue(r.json()["care_call"]["has_voice"])
        self.assertEqual(self.a.get(V + "/carecall/%d/voice" % cid).status_code, 200)
        self.assertEqual(self.m.get(V + "/carecall/%d/voice" % cid).status_code, 404)   # not accepted yet
        self.accept()
        self.assertEqual(self.m.get(V + "/carecall/%d/voice" % cid).status_code, 200)
        self.assertEqual(cl(self.stranger).get(V + "/carecall/%d/voice" % cid).status_code, 404)

    def test_voice_too_long(self):
        clip = base64.b64encode(b"0" * 100).decode()
        r = self.new(voice_b64=clip, voice_sec=90)
        self.assertEqual(r.json()["reason"], "voice_too_long")

    def test_edit_pause_delete(self):
        cid = self.new().json()["care_call"]["id"]
        r = self.a.post(V + "/carecall/%d" % cid, {"text": "drink water", "time": "10:00",
                                                    "repeat": "days", "days": [0, 2], "active": False},
                        format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertFalse(r.json()["care_call"]["active"])
        self.assertIsNone(r.json()["care_call"]["next_at"])
        self.assertEqual(cl(self.stranger).post(V + "/carecall/%d/delete" % cid).status_code, 404)
        self.assertEqual(self.a.post(V + "/carecall/%d/delete" % cid).status_code, 200)
        self.assertFalse(CareCall.objects.exists())

    def test_bangla_texts(self):
        self.new()
        self.accept()
        self.assertIn("কেয়ার কল", self.spy.calls[0]["tbn"])
        self.assertEqual(CC.time_label(at(2026, 11, 4, 9, 2), "bn"), "সকাল ৯:০২")
        self.assertEqual(CC.time_label(at(2026, 11, 4, 21, 20), "en"), "9:20 PM")
