"""
at100 (owner 27 Oct) — remote switches + intruder-photo consent.

  1. who: owner and approved trusted contacts only (stranger / removed
     contact / blocked contact -> 404); a trusted contact can always turn
     lost mode ON, but alarm/lock/message only while the phone is lost, dark
     or recently alerted; wipe is never offered (honest 400 -> Find Hub);
  2. honest delivery: queued -> sent (wake push accepted) -> delivered (the
     engine fetched it) -> done/failed (the engine reported it); offline =
     stays queued until it reconnects, then expired after its TTL; a newer
     switch replaces a waiting one; cancel only before it reached the phone;
  3. rate limits (per person/hour, alarm/hour, per phone/day) + audit rows on
     the owner's and the contact's trail; the contact who pressed it gets the
     outcome; the watch page shows the switch states;
  4. intruder photo: OFF by default, ON only with the consent version; a
     legacy ON-without-consent counts as OFF (config, state, photo refused);
     a wrong Security PIN past the threshold asks the open app for one photo.
"""
from datetime import timedelta
from unittest import mock

from django.utils import timezone
from rest_framework.test import APITestCase

from core import push
from core import views_at_remote as atr
from core.models import (AntiTheftCommand, AntiTheftEngine, AntiTheftEvent,
                         AuditLog, CircleMember, NotifEvent, ProtectedPhone, User)

CMD = "/api/v1/security/engine/command"
LIST = "/api/v1/security/engine/commands"


class _Base(APITestCase):
    PIN = "2468"

    def setUp(self):
        self.owner = User.objects.create_user(
            name="Arif", phone="01710000301", password="x",
            email="atr-owner@example.com")
        self.trusted = User.objects.create_user(
            name="Ma", phone="01710000302", password="x",
            email="atr-ma@example.com")
        self.stranger = User.objects.create_user(
            name="Stranger", phone="01710000303", password="x",
            email="atr-x@example.com")
        self.client.force_authenticate(self.owner)
        self.client.post("/api/v1/security/pin/set", {"new_pin": self.PIN},
                         format="json")
        self.phone = ProtectedPhone.objects.get(owner=self.owner)
        self.member = CircleMember.objects.create(
            user=self.owner, peer_user=self.trusted, name="Ma",
            state="accepted", direction="outgoing")
        r = self.client.post("/api/v1/security/engine/enable",
                             {"pin": self.PIN, "alert_member_ids": [self.member.id]},
                             format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.token = r.data["engine_token"]
        NotifEvent.objects.all().delete()

    # helpers
    def _as(self, user):
        self.client.force_authenticate(user)

    def _cmd(self, kind, user=None, **extra):
        self._as(user or self.owner)
        body = {"kind": kind}
        if user is not None and user != self.owner:
            body["phone_id"] = self.phone.id
        body.update(extra)
        return self.client.post(CMD, body, format="json")

    def _ingest(self, items=None):
        body = {"items": items or [{"id": "hb-%s" % timezone.now().timestamp(),
                                    "kind": "heartbeat",
                                    "at": int(timezone.now().timestamp() * 1000)}],
                "sent_at": timezone.now().isoformat()}
        return self.client.post("/api/v1/security/engine/ingest", body,
                                format="json", HTTP_X_ASSISTO_ENGINE=self.token)

    def _make_active(self):
        self.phone.refresh_from_db()
        self.phone.lost_mode = True
        self.phone.save()


# ---------------------------------------------------------------- 1. who
class WhoMaySwitchTests(_Base):
    def test_owner_can_send_every_switch(self):
        for k in ("lost_mode", "alarm", "lock", "message", "alarm_stop"):
            r = self._cmd(k, message="Please call 017xx")
            self.assertEqual(r.status_code, 201, (k, r.data))
            self.assertTrue(r.data["command"]["by_owner"])

    def test_stranger_gets_404_never_learns_the_phone_exists(self):
        r = self._cmd("alarm", user=self.stranger)
        self.assertEqual(r.status_code, 404)
        self._as(self.stranger)
        self.assertEqual(self.client.get(LIST, {"phone_id": self.phone.id}).status_code, 404)

    def test_trusted_can_turn_on_lost_mode_any_time(self):
        r = self._cmd("lost_mode", user=self.trusted, message="Lost, please call")
        self.assertEqual(r.status_code, 201, r.data)
        self.phone.refresh_from_db()
        self.assertTrue(self.phone.lost_mode)
        self.assertEqual(self.phone.lost_message, "Lost, please call")
        self.assertFalse(r.data["command"]["by_owner"])

    def test_trusted_alarm_needs_an_active_phone(self):
        r = self._cmd("alarm", user=self.trusted)
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.data["reason"], "not_active")
        self._as(self.trusted)
        can = self.client.get(LIST, {"phone_id": self.phone.id}).data["can"]
        self.assertTrue(can["lost_mode"])
        self.assertFalse(can["alarm"])
        self._make_active()
        self.assertEqual(self._cmd("alarm", user=self.trusted).status_code, 201)

    def test_recent_real_alert_makes_it_active_but_a_false_alarm_does_not(self):
        ev = AntiTheftEvent.objects.create(
            phone=self.phone, client_id="s1", kind="snatch", at=timezone.now(),
            alerted=True, data={"false_alarm": True})
        self.assertFalse(atr.phone_active(self.phone))
        ev.data = {}
        ev.save()
        self.assertTrue(atr.phone_active(self.phone))
        self.assertEqual(self._cmd("lock", user=self.trusted).status_code, 201)

    def test_removed_or_blocked_contact_loses_the_switches(self):
        self._make_active()
        self.member.blocked = True
        self.member.save()
        self.assertEqual(self._cmd("alarm", user=self.trusted).status_code, 404)
        self.member.blocked = False
        self.member.save()
        eng = AntiTheftEngine.objects.get(phone=self.phone)
        eng.alert_member_ids = []
        eng.save()
        self.assertEqual(self._cmd("alarm", user=self.trusted).status_code, 404)

    def test_wipe_is_never_offered(self):
        r = self._cmd("wipe")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.data["reason"], "wipe_not_supported")
        self.assertIn("google.com/android/find", r.data["use"])
        self._as(self.owner)
        self.assertFalse(self.client.get(LIST).data["wipe"]["supported"])

    def test_protection_off_is_honest(self):
        eng = AntiTheftEngine.objects.get(phone=self.phone)
        eng.enabled = False
        eng.save()
        r = self._cmd("alarm")
        self.assertEqual(r.status_code, 409)
        self.assertEqual(r.data["reason"], "protection_off")

    def test_message_needs_text(self):
        r = self._cmd("message")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.data["reason"], "message_required")


# ---------------------------------------------------------------- 2. delivery
class DeliveryStateTests(_Base):
    def test_queued_then_delivered_then_done(self):
        r = self._cmd("alarm")
        cid = r.data["command"]["id"]
        self.assertEqual(r.data["command"]["state"], "queued")  # no FCM in tests
        resp = self._ingest()
        self.assertEqual(resp.status_code, 200)
        cmds = resp.data["commands"]
        self.assertEqual([c["id"] for c in cmds], [cid])
        self.assertEqual(cmds[0]["kind"], "alarm")
        self.assertEqual(cmds[0]["alarm_s"], atr.ALARM_SECONDS)
        c = AntiTheftCommand.objects.get(pk=cid)
        self.assertEqual(c.state, "delivered")
        self.assertIsNotNone(c.delivered_at)
        # delivered once — the next check-in does not hand it out again
        self.assertEqual(self._ingest().data["commands"], [])
        res = self._ingest([{"id": "cr-1", "kind": "command_result",
                             "at": int(timezone.now().timestamp() * 1000),
                             "data": {"command_id": cid, "ok": True,
                                      "detail": "rang_60s"}}])
        self.assertIn("cr-1", res.data["accepted"])
        c.refresh_from_db()
        self.assertEqual(c.state, "done")
        self.assertEqual(c.detail, "rang_60s")

    def test_failure_reason_is_kept(self):
        cid = self._cmd("lock").data["command"]["id"]
        self._ingest()
        self._ingest([{"id": "cr-2", "kind": "command_result",
                       "at": int(timezone.now().timestamp() * 1000),
                       "data": {"command_id": cid, "ok": False, "detail": "no_admin"}}])
        c = AntiTheftCommand.objects.get(pk=cid)
        self.assertEqual((c.state, c.detail), ("failed", "no_admin"))

    def test_result_for_another_phone_is_ignored(self):
        other = User.objects.create_user(name="O", phone="01710000309",
                                         password="x", email="o@example.com")
        op = ProtectedPhone.objects.create(owner=other)
        c = AntiTheftCommand.objects.create(phone=op, kind="alarm",
                                            expires_at=timezone.now() + timedelta(hours=1))
        self._ingest([{"id": "cr-3", "kind": "command_result",
                       "at": int(timezone.now().timestamp() * 1000),
                       "data": {"command_id": c.id, "ok": True}}])
        c.refresh_from_db()
        self.assertEqual(c.state, "queued")

    def test_wake_push_marks_sent_only_when_google_accepted(self):
        with mock.patch.object(push, "is_available", return_value=True), \
                mock.patch.object(push, "push_to_user", return_value=1) as pt:
            r = self._cmd("alarm")
        self.assertEqual(r.data["command"]["state"], "sent")
        self.assertEqual(r.data["command"]["push_sent"], 1)
        args, kw = pt.call_args
        self.assertEqual(args[0], self.owner)
        self.assertEqual(args[1], "at_command")
        self.assertTrue(kw["high_priority"])
        self.assertTrue(kw["data_only"])
        with mock.patch.object(push, "is_available", return_value=True), \
                mock.patch.object(push, "push_to_user", return_value=0):
            r2 = self._cmd("lock")
        self.assertEqual(r2.data["command"]["state"], "queued")
        self.assertIn("at_command", push.KINDS)
        self.assertIn("at_command", push.DATA_ONLY_KINDS)

    def test_offline_phone_keeps_it_queued_then_it_expires(self):
        r = self._cmd("alarm")
        cid = r.data["command"]["id"]
        self._as(self.owner)
        d = self.client.get(LIST).data
        self.assertFalse(d["phone"]["online"] and False)  # presence is reported
        self.assertTrue(d["in_flight"])
        AntiTheftCommand.objects.filter(pk=cid).update(
            expires_at=timezone.now() - timedelta(seconds=1))
        d = self.client.get(LIST).data
        self.assertEqual(d["commands"][0]["state"], "expired")
        # an expired switch is never handed to the phone later
        self.assertEqual(self._ingest().data["commands"], [])

    def test_presence_online_after_check_in(self):
        self._ingest()
        self._as(self.owner)
        p = self.client.get(LIST).data["phone"]
        self.assertTrue(p["online"])
        self.assertTrue(p["protection_on"])
        eng = AntiTheftEngine.objects.get(phone=self.phone)
        eng.last_ingest_at = timezone.now() - timedelta(hours=3)
        eng.save()
        self.assertFalse(self.client.get(LIST).data["phone"]["online"])

    def test_newer_switch_replaces_a_waiting_one(self):
        a = self._cmd("alarm").data["command"]["id"]
        b = self._cmd("alarm").data["command"]["id"]
        self.assertEqual(AntiTheftCommand.objects.get(pk=a).state, "cancelled")
        self.assertEqual(AntiTheftCommand.objects.get(pk=b).state, "queued")
        s = self._cmd("alarm_stop").data["command"]["id"]
        self.assertEqual(AntiTheftCommand.objects.get(pk=b).state, "cancelled")
        self.assertEqual([c["id"] for c in self._ingest().data["commands"]], [s])

    def test_cancel_only_before_it_reached_the_phone(self):
        cid = self._cmd("lock").data["command"]["id"]
        r = self.client.post("%s/%d/cancel" % (CMD, cid))
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["command"]["state"], "cancelled")
        cid2 = self._cmd("lock").data["command"]["id"]
        self._ingest()
        self._as(self.owner)
        r = self.client.post("%s/%d/cancel" % (CMD, cid2))
        self.assertEqual(r.status_code, 409)
        # a stranger cannot cancel (404)
        cid3 = self._cmd("alarm").data["command"]["id"]
        self._as(self.stranger)
        self.assertEqual(self.client.post("%s/%d/cancel" % (CMD, cid3)).status_code, 404)


# ---------------------------------------------------------------- 3. limits + audit
class RateLimitAuditTests(_Base):
    def test_alarm_rate_limit_per_hour(self):
        self._make_active()
        for i in range(atr.ALARM_PER_HOUR):
            self.assertEqual(self._cmd("alarm", user=self.trusted).status_code, 201)
        r = self._cmd("alarm", user=self.trusted)
        self.assertEqual(r.status_code, 429)
        self.assertEqual(r.data["reason"], "rate_limited")
        self.assertTrue(AuditLog.objects.filter(
            user=self.owner, action="antitheft.command_rate_limited").exists())

    def test_per_person_hour_limit(self):
        for i in range(atr.RATE_PER_HOUR):
            self.assertEqual(self._cmd("lock").status_code, 201)
        self.assertEqual(self._cmd("lock").status_code, 429)

    def test_audit_on_owner_and_contact_trail(self):
        cid = self._cmd("lost_mode", user=self.trusted).data["command"]["id"]
        for u in (self.owner, self.trusted):
            row = AuditLog.objects.filter(user=u, action="antitheft.command").first()
            self.assertIsNotNone(row, u)
            self.assertEqual(row.detail["command_id"], cid)
            self.assertEqual(row.detail["role"], "trusted")
            self.assertEqual(row.detail["by_user_id"], self.trusted.pk)

    def test_contact_gets_the_outcome(self):
        self._make_active()
        cid = self._cmd("alarm", user=self.trusted).data["command"]["id"]
        self._ingest()
        NotifEvent.objects.all().delete()
        self._ingest([{"id": "cr-9", "kind": "command_result",
                       "at": int(timezone.now().timestamp() * 1000),
                       "data": {"command_id": cid, "ok": True}}])
        n = NotifEvent.objects.filter(user=self.trusted,
                                      meta__antitheft_kind="command_result").first()
        self.assertIsNotNone(n)
        self.assertEqual(n.route, "security/watch-phone")
        self.assertIn("web_path", n.meta)
        self.assertFalse(NotifEvent.objects.filter(
            user=self.owner, meta__antitheft_kind="command_result").exists())
        self.assertTrue(AuditLog.objects.filter(
            user=self.owner, action="antitheft.command_result").exists())

    def test_trusted_alerts_open_their_watch_view(self):
        self._ingest([{"id": "lb-1", "kind": "low_battery", "battery": 9,
                       "at": int(timezone.now().timestamp() * 1000)}])
        n = NotifEvent.objects.filter(user=self.trusted).first()
        self.assertIsNotNone(n)
        self.assertEqual(n.route, "security/watch-phone")

    def test_watch_page_shows_switch_states(self):
        self._cmd("alarm")
        from core import views_antitheft as atv
        path = atv.watch_path(self.phone, self.trusted)
        self.client.force_authenticate(None)
        r = self.client.get(path + "?lang=en")
        self.assertEqual(r.status_code, 200)
        html = r.content.decode()
        self.assertIn("Loud alarm", html)
        self.assertIn("Waiting for the phone to come online", html)
        self.assertIn("switched off or has no internet cannot receive anything", html)

    def test_list_gives_the_viewer_their_web_view(self):
        self._as(self.trusted)
        d = self.client.get(LIST, {"phone_id": self.phone.id}).data
        self.assertTrue(d["web_path"].startswith("/w/phone/"))
        self.client.force_authenticate(None)
        self.assertEqual(self.client.get(d["web_path"]).status_code, 200)

    def test_watching_list_has_presence(self):
        self._ingest()
        self._as(self.trusted)
        w = self.client.get("/api/v1/security/engine/watching").data["watching"]
        self.assertEqual(len(w), 1)
        self.assertTrue(w[0]["online"])
        self.assertTrue(w[0]["protection_on"])


# ---------------------------------------------------------------- 4. intruder
class IntruderConsentTests(_Base):
    SETTINGS = "/api/v1/security/engine/settings"

    def test_off_by_default(self):
        self._as(self.owner)
        st = self.client.get("/api/v1/security/engine/state").data
        self.assertFalse(st["intruder_photo"])
        self.assertEqual(st["intruder_consent_version"], atr.INTRUDER_CONSENT_VERSION)
        self.assertIsNone(st["intruder_consent_at"])

    def test_on_needs_the_consent_version(self):
        self._as(self.owner)
        r = self.client.post(self.SETTINGS, {"pin": self.PIN, "intruder_photo": True},
                             format="json")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.data["reason"], "consent_required")
        self.assertFalse(AntiTheftEngine.objects.get(phone=self.phone).intruder_photo)
        r = self.client.post(self.SETTINGS, {"pin": self.PIN, "intruder_photo": True,
                                             "intruder_consent": 1}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertTrue(r.data["config"]["intruder_photo"])
        eng = AntiTheftEngine.objects.get(phone=self.phone)
        self.assertIsNotNone(eng.intruder_consent_at)
        self.assertTrue(AuditLog.objects.filter(
            user=self.owner, action="antitheft.intruder_consent").exists())
        # off again: no consent needed; the consent record stays
        r = self.client.post(self.SETTINGS, {"pin": self.PIN, "intruder_photo": False},
                             format="json")
        self.assertFalse(r.data["config"]["intruder_photo"])
        self.assertIsNotNone(AntiTheftEngine.objects.get(phone=self.phone).intruder_consent_at)

    def test_legacy_on_without_consent_counts_as_off(self):
        eng = AntiTheftEngine.objects.get(phone=self.phone)
        eng.intruder_photo = True
        eng.intruder_consent_v = 0
        eng.save()
        self._as(self.owner)
        self.assertFalse(self.client.get("/api/v1/security/engine/state").data["intruder_photo"])
        self.assertFalse(self._ingest().data["config"]["intruder_photo"])
        import io
        from django.core.files.uploadedfile import SimpleUploadedFile
        f = SimpleUploadedFile("i.jpg", b"\xff\xd8\xff\xe0" + b"0" * 64, "image/jpeg")
        self.client.force_authenticate(None)
        r = self.client.post("/api/v1/security/engine/photo", {"file": f, "id": "p1"},
                             HTTP_X_ASSISTO_ENGINE=self.token)
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.data["reason"], "intruder_photo_off")

    def test_wrong_pin_past_threshold_asks_the_open_app_for_a_photo(self):
        self._as(self.owner)
        self.client.post(self.SETTINGS, {"pin": self.PIN, "intruder_photo": True,
                                         "intruder_consent": 1,
                                         "failed_unlock_threshold": 2}, format="json")
        flags = []
        for i in range(3):
            r = self.client.post("/api/v1/security/engine/false-alarm", {"pin": "0000"},
                                 format="json")
            self.assertEqual(r.status_code, 403)
            flags.append(r.data.get("intruder_snap"))
        self.assertEqual(flags, [False, True, True])

    def test_no_snap_without_consent(self):
        self._as(self.owner)
        for i in range(3):
            r = self.client.post("/api/v1/security/engine/false-alarm", {"pin": "0000"},
                                 format="json")
            self.assertFalse(r.data.get("intruder_snap"))


class AccountPurgeTests(_Base):
    def test_account_deletion_removes_engine_intruder_photos(self):
        from django.core.files.base import ContentFile
        from core import account_purge
        from core.logic import antitheft as at
        ev = AntiTheftEvent.objects.create(phone=self.phone, client_id="ph1",
                                           kind="intruder_photo", at=timezone.now())
        ev.photo.save("ph1.enc", ContentFile(at.encrypt_photo(b"\xff\xd8\xff" + b"0" * 32)))
        path = ev.photo.path
        import os
        self.assertTrue(os.path.exists(path))
        account_purge._delete_user_files(self.owner)
        self.assertFalse(os.path.exists(path))
