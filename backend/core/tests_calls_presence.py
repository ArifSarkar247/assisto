"""calls-presence — owner 24 Oct:
  * "a call rang then dropped" (CallRecords 70/71 ended `missed` exactly 20 s
    after placement): the server's OFFLINE_ACK_S cut ended a call whose FCM
    ring HAD been handed to the callee's device before that phone's
    "ringing" ack arrived. With a push delivered the ack window is the full
    ring time now.
  * call health: throttled rtc/turn + phone-reported setup failures are
    logged; the Owner Admin card + banner read them.
  * presence privacy "My contacts" + reciprocity enforced SERVER-side: a
    viewer who may not see last seen never receives it (snapshot or live).

Run: manage.py test core.tests_calls_presence --settings=assisto_backend.settings_test
"""
from datetime import timedelta
from unittest import mock

from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient

from core import call_health as H
from core.logic import call_signal as CS
from core.logic import circle_privacy as CP
from core.models import (CallHealthEvent, CallRecord, CallSession,
                         CircleMember, CirclePresence, CirclePrivacy, Device,
                         User)
from core.tests_c2_calls import _Pair
from core.tests_push import _PushBase

V = "/api/v1"


class SweepWindowTests(TestCase):
    def test_offline_cut_waits_full_ring_when_push_was_sent(self):
        now = timezone.now()
        started = now - timedelta(seconds=CS.OFFLINE_ACK_S + 1)
        seen = now
        # no push: the phone could only ring in-app -> offline at 20 s
        self.assertEqual(CS.sweep_decision("ringing", now, started,
                                           caller_seen=seen), "offline")
        # push handed to a device: still ringing at 21 s
        self.assertIsNone(CS.sweep_decision("ringing", now, started,
                                            caller_seen=seen, push_sent=True))
        late = now - timedelta(seconds=CS.OFFLINE_ACK_PUSHED_S + 1)
        self.assertEqual(CS.sweep_decision("ringing", now, late,
                                           caller_seen=seen, push_sent=True),
                         "offline")
        # an acked ring still rings out as no_answer at 45 s
        self.assertEqual(CS.sweep_decision(
            "ringing", now, late, ringing_at=now - timedelta(seconds=40),
            caller_seen=seen, push_sent=True), "no_answer")


class RangThenDroppedTests(_Pair, _PushBase):
    """The owner's bug end to end (FCM faked)."""

    def setUp(self):
        super().setUp()
        self.mk()
        Device.objects.create(user=self.b, push_token="bdev")

    def test_late_ack_after_20s_keeps_the_call_ringing(self):
        body = self.place()
        cid = body["call_id"]
        self.assertTrue(CallSession.objects.get(call_id=cid).push_sent)
        self.fake.calls.clear()
        # 25 s later the callee phone (cold start / Doze) has not acked yet
        self.age(cid, CS.OFFLINE_ACK_S + 5)
        st = self.ca.get(f"{V}/circle/calls/{cid}").json()
        self.assertEqual(st["phase"], "calling")      # NOT ended/offline
        kinds = [p["message"]["data"]["kind"] for p in self.fake.sent_payloads()]
        self.assertNotIn("call_cancel", kinds)        # the ring is not stopped
        # the ack arrives late -> Ringing, and the callee can still answer
        self.assertEqual(self.ev(self.cb, cid, "ringing")["phase"], "ringing")
        self.assertEqual(self.ev(self.cb, cid, "answer")["phase"], "accepted")

    def test_no_ack_at_all_ends_offline_after_the_ring_window(self):
        cid = self.place()["call_id"]
        self.age(cid, CS.OFFLINE_ACK_PUSHED_S + 2)
        st = self.ca.get(f"{V}/circle/calls/{cid}").json()
        self.assertEqual((st["phase"], st["end_reason"]), ("ended", "offline"))
        self.assertEqual(CallRecord.objects.get(pk=cid).state, "missed")

    def test_ring_push_is_high_priority_short_ttl_data_only(self):
        self.place()
        ring = self.fake.sent_payloads()[0]["message"]
        self.assertEqual(ring["data"]["kind"], "call")
        self.assertEqual(ring["android"]["priority"], "HIGH")
        self.assertEqual(ring["android"]["ttl"], "30s")
        self.assertNotIn("notification", ring)


@override_settings(FCM_SERVICE_ACCOUNT_FILE="", PUSH_SYNC=True)
class NoPushStillTwentySecondsTests(_Pair, TestCase):
    def test_in_app_only_ring_keeps_the_20s_offline_cut(self):
        self.mk()
        self.online(self.b)
        cid = self.place()["call_id"]
        self.assertFalse(CallSession.objects.get(call_id=cid).push_sent)
        self.age(cid, CS.OFFLINE_ACK_S + 3)
        st = self.ca.get(f"{V}/circle/calls/{cid}").json()
        self.assertEqual(st["end_reason"], "offline")


@override_settings(FCM_SERVICE_ACCOUNT_FILE="", PUSH_SYNC=True,
                   TURN_STATIC_SECRET="s3cret", TURN_HOST="turn.example")
class CallHealthTests(_Pair, TestCase):
    def setUp(self):
        self.mk()
        from django.core.cache import cache
        cache.delete(H.CACHE_KEY)

    def test_throttled_rtc_turn_is_logged(self):
        with mock.patch("core.logic.rtc.throttle_decision",
                        return_value={"throttled": True, "reason": "load"}):
            r = self.ca.get(f"{V}/rtc/turn")
        self.assertTrue(r.json()["throttled"])
        ev = CallHealthEvent.objects.get()
        self.assertEqual((ev.step, ev.code, ev.source),
                         ("rtc_config", "throttled_load", "server"))
        s = H.summary()
        self.assertEqual(s["throttled"], 1)
        self.assertEqual(H.alert(s)["kind"], "throttled")

    def test_client_report_validated_capped_and_scoped(self):
        r = self.ca.post(f"{V}/rtc/health", {"step": "nope"}, format="json")
        self.assertEqual(r.status_code, 422)
        # a call id that is not mine is dropped (never trust the phone)
        other = User.objects.create_user(name="X", phone="01740000999",
                                         password="pw12345!")
        foreign = CallRecord.objects.create(caller=other, callee=other,
                                            kind="voice", state="ended")
        r = self.ca.post(f"{V}/rtc/health", {"step": "place", "code": "server",
                                            "call_id": foreign.id},
                         format="json")
        self.assertTrue(r.json()["logged"])
        self.assertIsNone(CallHealthEvent.objects.get().call_id)
        for _ in range(H.CLIENT_MAX_PER_HOUR + 3):
            self.ca.post(f"{V}/rtc/health", {"step": "rtc_config",
                                            "code": "weird"}, format="json")
        self.assertEqual(CallHealthEvent.objects.filter(user=self.a).count(),
                         H.CLIENT_MAX_PER_HOUR)
        self.assertEqual(CallHealthEvent.objects.filter(code="unknown").count(),
                         H.CLIENT_MAX_PER_HOUR - 1)

    def test_summary_funnel_success_and_low_success_alert(self):
        now = timezone.now()

        def rec(reason, state, connected=False, answered=False, acked=True,
                push=True):
            r = CallRecord.objects.create(caller=self.a, callee=self.b,
                                          circle=self.ab, kind="voice",
                                          state=state,
                                          answered_at=now if answered else None)
            CallSession.objects.create(
                call=r, end_reason=reason, push_sent=push,
                ringing_at=now if acked else None,
                connected_at=now if connected else None)
        rec("hangup", "ended", connected=True, answered=True)
        rec("declined", "declined")
        rec("offline", "missed", acked=False)
        rec("failed", "failed", answered=True)
        rec("lost", "ended", connected=True, answered=True)
        rec("no_answer", "missed")
        H.log_event("place", "network", user=self.a, source="client")
        s = H.summary(now=now + timedelta(seconds=1))
        self.assertEqual(s["placed"], 6)
        self.assertEqual(s["attempts"], 7)          # + 1 never placed
        self.assertEqual(s["ok"], 3)                # hangup, declined, no_answer
        self.assertEqual(s["success_pct"], 43)
        self.assertEqual(s["funnel"], {"placed": 6, "push": 6, "acked": 5,
                                       "answered": 3, "connected": 2})
        self.assertEqual(s["failures"]["push"], 1)
        self.assertEqual(s["failures"]["ice"], 1)
        self.assertEqual(s["failures"]["dropped"], 1)
        self.assertEqual(s["failures"]["place"], 1)
        a = H.alert(s)
        self.assertEqual((a["kind"], a["success_pct"]), ("low_success", 43))


from web.tests_o2_owner_admin import OwnerBase  # noqa: E402


class OwnerCallHealthPanelTests(OwnerBase):
    def test_card_on_calls_page_and_banner_on_every_page(self):
        from django.core.cache import cache
        cache.delete(H.CACHE_KEY)
        self.ready()
        r = self.c.get("/owner/calls?lang=en")
        self.assertContains(r, 'id="call-health"')
        self.assertContains(r, "Call health (last 24 hours)")
        self.assertNotContains(r, 'id="call-health-alert"')
        H.log_event("rtc_config", "throttled_load")
        r = self.c.get("/owner/?lang=en")
        self.assertContains(r, 'id="call-health-alert"')
        self.assertContains(r, "Calls need attention")
        r = self.c.get("/owner/calls?lang=bn")
        self.assertContains(r, "কল হেলথ (গত ২৪ ঘণ্টা)")


class PresencePrivacyTests(TestCase):
    """Two accounts, server-side enforcement of last seen / online."""

    def setUp(self):
        self.a = User.objects.create_user(name="Amina", phone="01750000001",
                                          password="pw12345!", language="en")
        self.b = User.objects.create_user(name="Bilal", phone="01750000002",
                                          password="pw12345!", language="en")
        # A saved B; B has NOT saved A back (one-sided)
        self.ab = CircleMember.objects.create(
            user=self.a, peer_user=self.b, name="Bilal", state="accepted",
            phone=self.b.phone)
        self.ca, self.cb = APIClient(), APIClient()
        self.ca.force_authenticate(self.a)
        self.cb.force_authenticate(self.b)

    def priv(self, u, ls, act=None):
        CirclePrivacy.objects.update_or_create(user=u, defaults={
            "visibility": {"last_seen": ls, "active_status": act or ls}})

    def online(self, c):
        c.post(V + "/rt/send", {"topic": "presence.set",
                                "payload": {"state": "online"}}, format="json")

    def a_sees(self):
        return self.ca.get(V + "/circle/rt/state").json()["chats"][
            "member:%d" % self.ab.id]

    def live_presence_to_a(self):
        evs = self.ca.get(V + "/rt/events?after=0&topics=presence").json()
        return [e["payload"] for e in evs["events"]]

    def test_contacts_policy_hides_from_someone_i_did_not_save(self):
        self.priv(self.a, "everyone")
        self.priv(self.b, CP.VIS_CONTACTS)
        self.online(self.cb)
        s = self.a_sees()
        self.assertIsNone(s["online"])
        self.assertIsNone(s["last_seen"])
        self.assertIsNone(s["until"])
        self.assertEqual(self.live_presence_to_a(), [])   # nothing leaked live
        # B saves A back -> A is now B's contact and may see it
        CircleMember.objects.create(user=self.b, peer_user=self.a,
                                    name="Amina", state="accepted",
                                    phone=self.a.phone)
        s = self.a_sees()
        self.assertTrue(s["online"])
        self.assertIsNotNone(s["last_seen"])

    def test_everyone_policy_shows_even_without_saving_back(self):
        self.priv(self.a, "everyone")
        self.priv(self.b, "everyone")
        self.online(self.cb)
        s = self.a_sees()
        self.assertTrue(s["online"])
        self.assertIsNotNone(s["last_seen"])

    def test_reciprocal_nobody_cannot_see_others(self):
        CircleMember.objects.create(user=self.b, peer_user=self.a,
                                    name="Amina", state="accepted",
                                    phone=self.a.phone)
        self.priv(self.b, "everyone")
        self.priv(self.a, "nobody")          # A hides theirs ...
        self.online(self.cb)
        s = self.a_sees()                    # ... so A sees nobody's
        self.assertIsNone(s["online"])
        self.assertIsNone(s["last_seen"])
        self.assertEqual(self.live_presence_to_a(), [])
        # A shares again -> sees B
        self.priv(self.a, CP.VIS_CONTACTS)
        self.assertTrue(self.a_sees()["online"])

    def test_last_seen_hidden_but_online_shown_is_split(self):
        CircleMember.objects.create(user=self.b, peer_user=self.a,
                                    name="Amina", state="accepted",
                                    phone=self.a.phone)
        self.priv(self.a, "everyone")
        self.priv(self.b, "nobody", act="everyone")
        self.online(self.cb)
        s = self.a_sees()
        self.assertTrue(s["online"])
        self.assertIsNone(s["last_seen"])

    def test_blocked_contact_sees_nothing_even_with_everyone(self):
        ba = CircleMember.objects.create(user=self.b, peer_user=self.a,
                                         name="Amina", state="accepted",
                                         phone=self.a.phone, blocked=True)
        self.assertTrue(ba.blocked)
        self.priv(self.a, "everyone")
        self.priv(self.b, "everyone")
        self.online(self.cb)
        s = self.a_sees()
        self.assertIsNone(s["online"])
        self.assertIsNone(s["last_seen"])

    def test_privacy_endpoint_accepts_contacts(self):
        r = self.cb.post(V + "/circle/privacy", {"visibility": {
            "last_seen": "contacts", "active_status": "contacts"}},
            format="json")
        self.assertIn(r.status_code, (200, 201), r.content)
        row = CirclePrivacy.objects.get(user=self.b)
        self.assertEqual(row.visibility["last_seen"], "contacts")
        self.assertEqual(CP.visibility_label("contacts", "en"), "My contacts")
        # a caller that does not say "contact" never sees a contacts-only field
        self.assertFalse(CP.can_see_field(
            {"visibility": {"last_seen": "contacts"}}, {"id": 1}, "last_seen"))
        self.assertEqual(CirclePresence.objects.filter(user=self.a).count(), 0)
