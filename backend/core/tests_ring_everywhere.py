"""ring-everywhere — owner 24 Oct: "CALLS MUST RING LIKE WHATSAPP ON EVERY
PHONE".

  * native delivered / ringing / decline ack (per-call HMAC, no token)
  * bounded, idempotent resend of the ring push when no ack after 4 s
  * Calling… until the ringing ack, then Ringing (caller side)
  * never-delivered missed call shown once when the phone comes online
  * FCM message id recorded; dead tokens (UNREGISTERED / INVALID_ARGUMENT /
    SENDER_ID_MISMATCH) dropped
  * Owner Admin: delivery rate by brand / model / Android version

Run: manage.py test core.tests_ring_everywhere --settings=assisto_backend.settings_test
"""
from datetime import timedelta

from django.test import TestCase
from django.utils import timezone

from core import call_ack as A
from core import push
from core.logic import call_signal as CS
from core.models import CallRecord, CallSession, Device
from core.tests_c2_calls import _Pair
from core.tests_push import _PushBase

V = "/api/v1"


def _ring_payloads(fake):
    return [p["message"] for p in fake.sent_payloads()
            if p["message"]["data"].get("kind") == "call"]


class _RingBase(_Pair, _PushBase):
    def setUp(self):
        super().setUp()
        self.mk()
        Device.objects.create(user=self.b, push_token="bdev")

    def ack(self, cid, stage="delivered", sig=None, **facts):
        if sig is None:
            sig = A.sign(cid, self.b.id)
        from rest_framework.test import APIClient
        return APIClient().post(f"{V}/circle/calls/{cid}/ack",
                                {"sig": sig, "stage": stage, **facts},
                                format="json")

    def push_age(self, cid, seconds):
        """Move the last ring push `seconds` into the past."""
        past = timezone.now() - timedelta(seconds=seconds)
        CallSession.objects.filter(call_id=cid).update(last_push_at=past)
        CallRecord.objects.filter(pk=cid).update(started_at=past)
        CallSession.objects.filter(call_id=cid).update(
            caller_seen_at=timezone.now())


class SignatureTests(TestCase):
    def test_sign_verify(self):
        s = A.sign(12, 34)
        self.assertEqual(len(s), 32)
        self.assertTrue(A.verify(12, 34, s))
        self.assertFalse(A.verify(12, 35, s))
        self.assertFalse(A.verify(13, 34, s))
        self.assertFalse(A.verify(12, 34, ""))
        self.assertFalse(A.verify(12, 34, None))

    def test_due_resend_rule(self):
        now = timezone.now()
        t0 = now - timedelta(seconds=A.RESEND_AFTER_S)
        self.assertTrue(A.due_resend("ringing", now, t0, None, True, None, None, 0))
        # not yet the first slot (2 s)
        self.assertFalse(A.due_resend("ringing", now, now - timedelta(seconds=1),
                                      None, True, None, None, 0))
        # acked (delivered or ringing) -> never
        self.assertFalse(A.due_resend("ringing", now, t0, None, True, now, None, 0))
        self.assertFalse(A.due_resend("ringing", now, t0, None, True, None, now, 0))
        # bounded
        self.assertFalse(A.due_resend("ringing", now, t0, t0, True, None, None,
                                      A.MAX_RESENDS))
        # no push device / not ringing
        self.assertFalse(A.due_resend("ringing", now, t0, None, False, None, None, 0))
        self.assertFalse(A.due_resend("connecting", now, t0, None, True, None, None, 0))

    def test_clean_facts(self):
        self.assertEqual(A.clean_facts({"brand": "Realme", "model": "RMX3491",
                                        "sdk": "33"}), ("realme", "RMX3491", 33))
        self.assertEqual(A.clean_facts({"sdk": "x"}), ("", "", 0))
        self.assertEqual(A.clean_facts({"sdk": 999})[2], 0)
        self.assertEqual(A.android_label(33), "Android 13 (33)")
        self.assertEqual(A.android_label(0), "?")


class AckTests(_RingBase):
    def test_ring_push_carries_sig_and_records_fcm_message_id(self):
        cid = self.place()["call_id"]
        ring = _ring_payloads(self.fake)[0]
        self.assertEqual(ring["data"]["ack_sig"], A.sign(cid, self.b.id))
        self.assertEqual(ring["data"]["attempt"], "0")
        self.assertEqual(ring["android"]["collapse_key"], "call-%s" % cid)
        s = CallSession.objects.get(call_id=cid)
        self.assertIsNotNone(s.fcm_sent_at)
        self.assertEqual(s.fcm_msg_id, "projects/x/messages/1")
        self.assertIsNotNone(s.last_push_at)

    def test_delivered_moves_caller_from_calling_to_ringing(self):
        cid = self.place()["call_id"]
        st = self.ca.get(f"{V}/circle/calls/{cid}").json()
        self.assertEqual(st["phase"], "calling")
        r = self.ack(cid, "delivered", brand="Xiaomi", model="Redmi Note 12",
                     sdk=34)
        self.assertEqual(r.status_code, 200, r.content)
        # calls95: the phone CONFIRMED the push -> the caller sees Ringing
        self.assertEqual(r.json()["phase"], "ringing")
        s = CallSession.objects.get(call_id=cid)
        self.assertIsNotNone(s.delivered_at)
        self.assertEqual((s.callee_brand, s.callee_model, s.callee_sdk),
                         ("xiaomi", "Redmi Note 12", 34))
        r = self.ack(cid, "ringing")
        self.assertEqual(r.json()["phase"], "ringing")
        st = self.ca.get(f"{V}/circle/calls/{cid}").json()
        self.assertEqual(st["phase"], "ringing")
        # the caller got the live call.state over the real-time queue too
        evs = self.events(self.ca, topics="call")["events"]
        phases = [e["payload"].get("phase") for e in evs
                  if e["topic"] == "call.state"]
        self.assertIn("ringing", phases)

    def test_bad_sig_or_wrong_call_is_404_and_changes_nothing(self):
        cid = self.place()["call_id"]
        self.assertEqual(self.ack(cid, sig="nope").status_code, 404)
        self.assertEqual(self.ack(cid, sig=A.sign(cid, self.a.id)).status_code, 404)
        self.assertEqual(self.ack(cid + 999).status_code, 404)
        self.assertEqual(self.ack(cid, stage="answer").status_code, 400)
        self.assertIsNone(CallSession.objects.get(call_id=cid).delivered_at)

    def test_native_decline_ends_the_call(self):
        cid = self.place()["call_id"]
        r = self.ack(cid, "decline").json()
        self.assertTrue(r["ended"])
        self.assertEqual(CallRecord.objects.get(pk=cid).state, "declined")
        # idempotent: a second decline / a late delivered ack is harmless
        self.assertEqual(self.ack(cid, "decline").status_code, 200)
        r = self.ack(cid, "delivered").json()
        self.assertTrue(r["ended"])     # the phone cancels its stale ring

    def test_ack_is_idempotent(self):
        cid = self.place()["call_id"]
        self.ack(cid, "ringing", brand="realme", model="RMX3491", sdk=33)
        first = CallSession.objects.get(call_id=cid)
        self.ack(cid, "ringing", brand="other", model="x", sdk=30)
        again = CallSession.objects.get(call_id=cid)
        self.assertEqual(first.ringing_at, again.ringing_at)
        self.assertEqual(first.delivered_at, again.delivered_at)
        self.assertEqual(again.callee_brand, "realme")


class ResendTests(_RingBase):
    def test_resend_schedule_bounded_and_idempotent(self):
        """calls95: resends at 2, 4, 8, 16, 24 s after placement while the
        phone has not acked; each slot sends ONE copy even when both phones
        poll at once; never more than MAX_RESENDS."""
        cid = self.place()["call_id"]
        self.assertEqual(len(_ring_payloads(self.fake)), 1)
        # 1 s: not due
        self.push_age(cid, 1)
        self.ca.get(f"{V}/circle/calls/{cid}")
        self.assertEqual(len(_ring_payloads(self.fake)), 1)
        for k, at in enumerate(A.RESEND_SCHEDULE_S, start=1):
            self.push_age(cid, at)        # placed `at` s ago, last push too
            self.ca.get(f"{V}/circle/calls/{cid}")
            self.ca.get(f"{V}/circle/calls/{cid}")
            self.events(self.ca)
            rings = _ring_payloads(self.fake)
            self.assertEqual(len(rings), 1 + k, "slot %s s" % at)
            self.assertEqual(rings[-1]["data"]["attempt"], str(k))
            self.assertEqual(rings[-1]["android"]["collapse_key"], "call-%s" % cid)
        # schedule used up: never again
        self.push_age(cid, 40)
        self.ca.get(f"{V}/circle/calls/{cid}")
        self.assertEqual(len(_ring_payloads(self.fake)), 1 + A.MAX_RESENDS)
        self.assertEqual(CallSession.objects.get(call_id=cid).push_resends,
                         A.MAX_RESENDS)

    def test_resend_slots_follow_placement_with_min_gap(self):
        now = timezone.now()
        t0 = now - timedelta(seconds=8.5)
        # 2 resends done, the 3rd slot (8 s) is due
        self.assertTrue(A.due_resend("ringing", now, t0, now - timedelta(seconds=4),
                                     True, None, None, 2))
        # ...but never closer than RESEND_MIN_GAP_S to the previous send
        self.assertFalse(A.due_resend("ringing", now, t0, now - timedelta(seconds=1),
                                      True, None, None, 2))
        # the 4th slot (16 s) is not due at 8.5 s
        self.assertFalse(A.due_resend("ringing", now, t0, now - timedelta(seconds=4),
                                      True, None, None, 3))
        self.assertEqual(A.next_resend_at_s(0), 2)
        self.assertIsNone(A.next_resend_at_s(A.MAX_RESENDS))
        # every slot lies inside the ring window
        self.assertLess(max(A.RESEND_SCHEDULE_S), CS.RING_TIMEOUT_S)

    def test_no_resend_once_delivered(self):
        cid = self.place()["call_id"]
        self.ack(cid, "delivered")
        self.push_age(cid, 10)
        self.ca.get(f"{V}/circle/calls/{cid}")
        self.assertEqual(len(_ring_payloads(self.fake)), 1)

    def test_no_resend_without_a_push_device(self):
        Device.objects.filter(user=self.b).delete()
        self.online(self.b)     # reachable by the in-app poll only
        cid = self.place()["call_id"]
        self.fake.calls.clear()
        self.push_age(cid, 10)
        self.ca.get(f"{V}/circle/calls/{cid}")
        self.assertEqual(_ring_payloads(self.fake), [])


class MissedOnReconnectTests(_RingBase):
    def test_never_delivered_missed_call_is_shown_once_on_reconnect(self):
        cid = self.place()["call_id"]
        # the caller gives up before the phone ever got the push
        self.ev(self.ca, cid, "cancel")
        s = CallSession.objects.get(call_id=cid)
        self.assertTrue(s.missed_pending)
        # token registration tells the phone something is waiting
        r = self.cb.post(f"{V}/devices/register",
                         {"push_token": "bdev", "brand": "vivo",
                          "model": "Y21", "sdk_int": 31}, format="json")
        self.assertEqual(r.json()["missed_pending"], 1)
        d = Device.objects.get(user=self.b, push_token="bdev")
        self.assertEqual((d.brand, d.model, d.sdk_int), ("vivo", "Y21", 31))
        items = self.cb.get(f"{V}/circle/calls/missed_pending",
                            HTTP_ACCEPT_LANGUAGE="en").json()["items"]
        self.assertEqual(len(items), 1)
        it = items[0]
        self.assertEqual((it["kind"], it["call_id"]), ("missed_call", str(cid)))
        self.assertEqual(it["group_key"], "caller-%s" % self.a.id)
        self.assertIn("Missed call from", it["title"])
        # shown ONCE
        again = self.cb.get(f"{V}/circle/calls/missed_pending").json()["items"]
        self.assertEqual(again, [])

    def test_delivered_call_is_not_pending(self):
        cid = self.place()["call_id"]
        self.ack(cid, "delivered")
        self.ev(self.ca, cid, "cancel")
        self.assertFalse(CallSession.objects.get(call_id=cid).missed_pending)

    def test_offline_timeout_without_delivery_is_pending(self):
        cid = self.place()["call_id"]
        self.age(cid, CS.OFFLINE_ACK_PUSHED_S + 2)
        CallSession.objects.filter(call_id=cid).update(push_resends=A.MAX_RESENDS)
        self.ca.get(f"{V}/circle/calls/{cid}")
        s = CallSession.objects.get(call_id=cid)
        self.assertEqual(s.end_reason, "offline")
        self.assertTrue(s.missed_pending)

    def test_answered_or_declined_is_not_pending(self):
        cid = self.place()["call_id"]
        self.ev(self.cb, cid, "decline")
        self.assertFalse(CallSession.objects.get(call_id=cid).missed_pending)

    def test_only_the_callee_sees_it(self):
        cid = self.place()["call_id"]
        self.ev(self.ca, cid, "cancel")
        self.assertEqual(self.ca.get(f"{V}/circle/calls/missed_pending")
                         .json()["items"], [])
        self.assertEqual(len(self.cb.get(f"{V}/circle/calls/missed_pending")
                             .json()["items"]), 1)


class DeadTokenTests(_PushBase):
    def _send_with(self, code, body):
        u = self.mkuser("01700009901")
        Device.objects.create(user=u, push_token="dead-tok")
        self.fake.send_code, self.fake.send_body = code, body
        push.send_to_token("dead-tok", {"kind": "call"})
        return Device.objects.filter(push_token="dead-tok").exists()

    def test_unregistered_dropped(self):
        self.assertFalse(self._send_with(404, {"error": {
            "status": "NOT_FOUND",
            "details": [{"errorCode": "UNREGISTERED"}]}}))

    def test_invalid_token_dropped(self):
        self.assertFalse(self._send_with(400, {"error": {
            "status": "INVALID_ARGUMENT",
            "message": "The registration token is not a valid FCM registration token"}}))

    def test_sender_mismatch_dropped(self):
        self.assertFalse(self._send_with(403, {"error": {
            "status": "PERMISSION_DENIED",
            "details": [{"errorCode": "SENDER_ID_MISMATCH"}]}}))

    def test_other_errors_keep_the_token(self):
        self.assertTrue(self._send_with(500, {"error": {"status": "INTERNAL"}}))

    def test_invalid_argument_not_about_token_keeps_it(self):
        self.assertTrue(self._send_with(400, {"error": {
            "status": "INVALID_ARGUMENT", "message": "ttl is bad"}}))

    def test_message_id_returned(self):
        res = {}
        self.fake.send_body = {"name": "projects/x/messages/0:42"}
        Device.objects.create(user=self.mkuser("01700009902"), push_token="t2")
        self.assertTrue(push.send_to_token("t2", {"a": 1}, result=res))
        self.assertEqual(res["name"], "projects/x/messages/0:42")


class DeliveryStatsTests(_RingBase):
    def test_rate_by_brand_model_android(self):
        Device.objects.filter(user=self.b).update(brand="samsung",
                                                  model="SM-A155F", sdk_int=34)
        # 1) delivered + reported its own facts
        c1 = self.place()["call_id"]
        self.ack(c1, "delivered", brand="realme", model="RMX3491", sdk=33)
        self.age(c1, 10)
        self.ev(self.ca, c1, "cancel")
        # 2) never delivered -> falls back to the Device row facts
        c2 = self.place()["call_id"]
        self.age(c2, 10)          # (a cancel within 4 s is not an attempt)
        self.ev(self.ca, c2, "cancel")
        # 3) still ringing, not acked -> not judged yet
        self.place()
        st = A.delivery_stats()
        self.assertEqual((st["attempts"], st["delivered"], st["pct"]), (2, 1, 50))
        brands = {b["brand"]: (b["attempts"], b["delivered"]) for b in st["brands"]}
        self.assertEqual(brands, {"realme": (1, 1), "samsung": (1, 0)})
        androids = {a["sdk"]: a["android"] for a in st["androids"]}
        self.assertEqual(androids[33], "Android 13 (33)")
        models = {(r["brand"], r["model"]) for r in st["rows"]}
        self.assertEqual(models, {("realme", "RMX3491"), ("samsung", "SM-A155F")})


from web.tests_o2_owner_admin import OwnerBase  # noqa: E402


class OwnerRingDeliveryPanelTests(OwnerBase):
    def test_card_on_calls_page(self):
        self.ready()
        r = self.c.get("/owner/calls?lang=en")
        self.assertContains(r, 'id="ring-delivery"')
        self.assertContains(r, "Ring delivery by phone (last 7 days)")
        r = self.c.get("/owner/calls?lang=bn")
        self.assertContains(r, "ফোন অনুযায়ী রিং পৌঁছানো (গত ৭ দিন)")
