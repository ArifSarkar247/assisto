"""
antitheft2 (owner 27 Oct) — "battery low / went offline / sudden grab /
stopped checking in" reached the OWNER's own phone two days late, all saying
"Last location not known".

Covers:
  1. every alert carries the best location: the event's fix (accuracy + fix
     time) -> the server's last stored fix ("last seen at") -> an honest
     reason (permission off / location off / no fix yet);
  2. routing: trusted contacts only (in-app + HIGH-priority push + a signed
     web view), never the protected phone; nobody set -> recorded
     (recipients=0) and the app is told to ask for one; the owner's own feed
     never shows alerts about his own phone;
  3. latency: event in -> push dispatched inside the same request (< 1 min,
     measured), FCM android priority HIGH;
  4. false grabs: charging / face-down still / night on the home Wi-Fi
     (unless Night guard) are stored but never alert or freeze; "Are you
     OK?" holds a grab, "I'm OK" drops it, no answer / "I need help" /
     wrong PIN / late arrival escalates — exactly once;
  C. owner-only alerts (Play Vitals, disk, call relay) reach ONLY active
     superusers; a normal account never gets them (push refused, feed
     filtered).
"""
import os
import time
from datetime import timedelta
from io import StringIO
from unittest import mock

from django.core.management import call_command
from django.utils import timezone
from rest_framework.test import APITestCase

from core import push
from core import views_antitheft as atv
from core.logic import antitheft as at
from core.models import (AntiTheftEngine, AntiTheftEvent, CircleMember, Device,
                         FamilyAlert, NotifEvent, ProtectedPhone, User)

HOME = "a" * 64
OTHER = "b" * 64


def _ms(dt):
    return int(dt.timestamp() * 1000)


class _Base(APITestCase):
    PIN = "2468"
    WITH_CONTACT = True

    def setUp(self):
        self.owner = User.objects.create_user(
            name="Arif", phone="01710000201", password="x",
            email="at2-owner@example.com")
        self.family = User.objects.create_user(
            name="Ma", phone="01710000202", password="x",
            email="at2-family@example.com")
        self.client.force_authenticate(self.owner)
        self.client.post("/api/v1/security/pin/set", {"new_pin": self.PIN},
                         format="json")
        self.phone = ProtectedPhone.objects.get(owner=self.owner)
        self.member = CircleMember.objects.create(
            user=self.owner, peer_user=self.family, name="Ma",
            state="accepted", direction="outgoing")
        body = {"pin": self.PIN}
        if self.WITH_CONTACT:
            body["alert_member_ids"] = [self.member.id]
        r = self.client.post("/api/v1/security/engine/enable", body, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.token = r.data["engine_token"]
        self.eng = AntiTheftEngine.objects.get(phone=self.phone)
        NotifEvent.objects.all().delete()   # drop the "protection on" rows

    def _ingest(self, items, **extra):
        body = {"items": items, "sent_at": timezone.now().isoformat()}
        body.update(extra)
        return self.client.post("/api/v1/security/engine/ingest", body,
                                format="json", HTTP_X_ASSISTO_ENGINE=self.token)

    def _notifs(self, user, kind=None):
        qs = NotifEvent.objects.filter(user=user, meta__has_key="antitheft_kind")
        if kind:
            qs = qs.filter(meta__antitheft_kind=kind)
        return qs

    def _ev(self, cid):
        return AntiTheftEvent.objects.get(phone=self.phone, client_id=cid)


# ---------------------------------------------------------------- 1. location
class LocationTextTests(APITestCase):
    def test_event_fix_with_accuracy_and_time(self):
        now = timezone.now()
        loc = at.pick_location(23.78, 90.41, 12.4, now - timedelta(minutes=1), now)
        en, bn = at.location_text(loc, now)
        self.assertIn("±12 m", en)
        self.assertIn("23.780000,90.410000", en)
        self.assertIn("Location at", en)
        self.assertIn("±12 m", bn)

    def test_falls_back_to_server_last_fix_marked_last_seen(self):
        now = timezone.now()
        loc = at.pick_location(None, None, None, None, now,
                               23.7, 90.4, 30.0, now - timedelta(hours=3))
        self.assertEqual(loc["source"], "last_known")
        en, bn = at.location_text(loc, now)
        self.assertTrue(en.startswith("Last seen at"), en)
        self.assertIn("±30 m", en)
        self.assertIn("শেষ দেখা গেছে", bn)

    def test_no_fix_says_why(self):
        now = timezone.now()
        for caps, word_en in (({"locationPermission": False}, "permission"),
                              ({"locationEnabled": False}, "switched off"),
                              ({}, "not got a location")):
            loc = at.pick_location(None, None, None, None, now, caps=caps)
            en, bn = at.location_text(loc, now)
            self.assertIn("not known", en)
            self.assertIn(word_en, en)
            self.assertIn("জানা নেই", bn)

    def test_alert_text_uses_loc(self):
        now = timezone.now()
        loc = at.pick_location(None, None, None, None, now, 23.7, 90.4, 8.0,
                               now - timedelta(minutes=2))
        te, be, tb, bb = at.alert_text("low_battery", "Arif", now, {}, None, None,
                                       20, False, now, loc=loc)
        self.assertNotIn("not known", be)
        self.assertIn("±8 m", be)
        self.assertIn("±8 m", bb)


class LocationIngestTests(_Base):
    def test_event_stores_accuracy_and_fix_time_and_alert_carries_them(self):
        now = timezone.now()
        fix = now - timedelta(seconds=40)
        r = self._ingest([{"id": "lb-1", "kind": "low_battery", "at": _ms(now),
                           "lat": 23.81, "lng": 90.42, "battery": 20,
                           "data": {"battery": 20, "acc": 15.0,
                                    "fix_at": _ms(fix)}}])
        self.assertEqual(r.status_code, 200, r.data)
        ev = self._ev("lb-1")
        self.assertEqual(ev.accuracy_m, 15.0)
        self.assertIsNotNone(ev.fix_at)
        self.assertLess(abs((ev.fix_at - fix).total_seconds()), 2)
        n = self._notifs(self.family, "low_battery").get()
        self.assertIn("±15 m", n.body_en)
        self.assertNotIn("not known", n.body_en)
        self.assertEqual(n.meta["acc"], 15.0)

    def test_event_without_fix_uses_last_heartbeat_fix(self):
        now = timezone.now()
        self._ingest([{"id": "hb-1", "kind": "heartbeat", "at": _ms(now - timedelta(hours=2)),
                       "lat": 23.7, "lng": 90.4, "acc": 25,
                       "fix_at": _ms(now - timedelta(hours=2))}])
        self.eng.refresh_from_db()
        self.assertEqual(self.eng.last_fix_acc, 25.0)
        self._ingest([{"id": "off-x", "kind": "sim_change", "at": _ms(now),
                       "data": {"state": "removed", "v": 2}}])
        n = self._notifs(self.family, "sim_change").get()
        self.assertIn("Last seen at", n.body_en)
        self.assertIn("±25 m", n.body_en)
        self.assertEqual(n.meta["loc_source"], "last_known")

    def test_no_location_ever_says_permission_off(self):
        now = timezone.now()
        self._ingest([{"id": "hb-p", "kind": "heartbeat", "at": _ms(now)}],
                     capabilities={"locationPermission": False,
                                   "locationEnabled": True})
        self._ingest([{"id": "lb-p", "kind": "low_battery", "at": _ms(now),
                       "battery": 19}])
        n = self._notifs(self.family, "low_battery").get()
        self.assertIn("location permission is off", n.body_en)
        st = self.client.get("/api/v1/security/engine/state").data
        self.assertFalse(st["location"]["permission"])
        self.assertFalse(st["location"]["has_fix"])


# ---------------------------------------------------------------- 2. routing
class RoutingTests(_Base):
    def test_alert_goes_to_trusted_contact_only_never_the_phone(self):
        now = timezone.now()
        self._ingest([{"id": "lb-r", "kind": "low_battery", "at": _ms(now),
                       "battery": 20}])
        self.assertEqual(self._notifs(self.family, "low_battery").count(), 1)
        self.assertEqual(self._notifs(self.owner).count(), 0)
        ev = self._ev("lb-r")
        self.assertTrue(ev.alerted)
        self.assertEqual(ev.recipients, 1)
        self.assertIsNotNone(ev.alerted_at)

    def test_owner_feed_hides_old_rows_about_his_own_phone(self):
        # the 25 Oct rows were written to the owner before the routing fix
        NotifEvent.objects.create(
            user=self.owner, type="security", title_en="x", title_bn="x",
            body_en="b", body_bn="b", at=timezone.now(),
            meta={"antitheft_kind": "snatch", "owner_id": self.owner.id,
                  "phone_id": self.phone.id})
        NotifEvent.objects.create(
            user=self.owner, type="security", title_en="t", title_bn="t",
            body_en="b", body_bn="b", at=timezone.now(),
            meta={"antitheft_kind": "test", "owner_id": self.owner.id})
        r = self.client.get("/api/v1/notif/feed")
        kinds = [(i.get("meta") or {}).get("antitheft_kind") for i in r.data["items"]]
        self.assertNotIn("snatch", kinds)
        self.assertIn("test", kinds)    # the owner's own test alarm stays

    def test_web_view_link_for_the_contact(self):
        now = timezone.now()
        self._ingest([{"id": "lb-w", "kind": "low_battery", "at": _ms(now),
                       "lat": 23.7, "lng": 90.4, "battery": 18}])
        n = self._notifs(self.family, "low_battery").get()
        path = n.meta["web_path"]
        self.assertTrue(path.startswith("/w/phone/"))
        self.client.force_authenticate(None)
        r = self.client.get(path)
        self.assertEqual(r.status_code, 200)
        self.assertIn(b"maps", r.content)
        self.assertEqual(r["Cache-Control"], "private, no-store")
        # a tampered link is a 404
        self.assertEqual(self.client.get(path + "x").status_code, 404)
        # removed from the alert list -> the old link stops working
        AntiTheftEngine.objects.filter(pk=self.eng.pk).update(alert_member_ids=[])
        self.assertEqual(self.client.get(path).status_code, 404)

    def test_web_link_never_for_a_stranger(self):
        stranger = User.objects.create_user(name="X", phone="01710000209",
                                            password="x", email="at2-x@example.com")
        tok = atv.watch_token(self.phone, stranger)
        self.client.force_authenticate(None)
        self.assertEqual(self.client.get("/w/phone/%s" % tok).status_code, 404)


class NoTrustedContactTests(_Base):
    WITH_CONTACT = False

    def test_recorded_with_no_recipients_and_app_asked_to_add_one(self):
        st = self.client.get("/api/v1/security/engine/state").data
        self.assertTrue(st["needs_trusted_contact"])
        self.assertEqual(st["trusted_contacts"], 0)
        now = timezone.now()
        self._ingest([{"id": "lb-n", "kind": "low_battery", "at": _ms(now),
                       "battery": 20}])
        ev = self._ev("lb-n")
        self.assertTrue(ev.alerted)
        self.assertEqual(ev.recipients, 0)
        self.assertTrue(ev.data.get("no_recipients"))
        # never falls back to the protected phone itself
        self.assertEqual(self._notifs(self.owner).count(), 0)
        tl = self.client.get("/api/v1/security/engine/timeline").data
        row = [e for e in tl["events"] if e["kind"] == "low_battery"][0]
        self.assertEqual(row["recipients"], 0)


# ---------------------------------------------------------------- 3. latency
class LatencyTests(_Base):
    def test_event_in_to_high_priority_push_dispatched_within_a_minute(self):
        Device.objects.create(user=self.family, push_token="tok-family",
                              platform="android")
        Device.objects.create(user=self.owner, push_token="tok-owner",
                              platform="android")
        sent = []

        def fake_send(token, data, notification=None, priority="high",
                      ttl_s=3600, collapse_key=None, android_channel=None,
                      result=None):
            sent.append({"token": token, "priority": priority, "ttl": ttl_s,
                         "kind": data.get("antitheft_kind"),
                         "t": time.monotonic()})
            return True

        now = timezone.now()
        with mock.patch.object(push, "is_available", return_value=True), \
                mock.patch.object(push, "send_to_token", side_effect=fake_send):
            t0 = time.monotonic()
            r = self._ingest([{"id": "sn-lat", "kind": "low_battery",
                               "at": _ms(now), "battery": 20}])
            t1 = time.monotonic()
        self.assertEqual(r.status_code, 200)
        self.assertEqual([s["token"] for s in sent], ["tok-family"])  # never the phone
        self.assertEqual(sent[0]["priority"], "high")
        self.assertEqual(sent[0]["kind"], "low_battery")
        self.assertLess(sent[0]["t"] - t0, 60.0)
        self.assertLess(t1 - t0, 60.0)
        # and the stored delivery record agrees
        ev = self._ev("sn-lat")
        self.assertLess((ev.alerted_at - ev.received_at).total_seconds(), 60)

    def test_fcm_message_is_android_high_priority(self):
        msg = push.build_message("tok", {"kind": "family_alert"},
                                 {"title": "t", "body": "b"}, priority="high")
        self.assertEqual(msg["message"]["android"]["priority"], "HIGH")


# ------------------------------------------------------- 4. false grabs + OK?
class GrabSuppressionTests(_Base):
    def _grab(self, cid, data, at_dt=None):
        at_dt = at_dt or timezone.now()
        return self._ingest([{"id": cid, "kind": "snatch", "at": _ms(at_dt),
                              "data": data}])

    def _assert_suppressed(self, cid, why):
        ev = self._ev(cid)
        self.assertEqual(ev.data.get("suppressed"), why)
        self.assertEqual(self._notifs(self.family, "snatch").count(), 0)
        self.phone.refresh_from_db()
        self.assertIsNone(self.phone.frozen_until)

    def test_pure_rules(self):
        now = timezone.now()
        self.assertEqual(at.grab_suppression({"charging": True}, now), "charging")
        self.assertEqual(at.grab_suppression({"face_down_still": True}, now),
                         "face_down_still")
        self.assertEqual(at.grab_suppression({"hour": 1, "wifi": HOME}, now,
                                             False, [HOME]), "home_wifi_night")
        self.assertIsNone(at.grab_suppression({"hour": 1, "wifi": HOME}, now,
                                              True, [HOME]))   # Night guard ON
        self.assertIsNone(at.grab_suppression({"hour": 14, "wifi": HOME}, now,
                                              False, [HOME]))  # daytime
        self.assertIsNone(at.grab_suppression({"hour": 1, "wifi": OTHER}, now,
                                              False, [HOME]))  # not home
        self.assertIsNone(at.grab_suppression({"hour": 1}, now, False, [HOME]))

    def test_charging_grab_is_ignored(self):
        self._grab("g-ch", {"charging": True, "hour": 14})
        self._assert_suppressed("g-ch", "charging")

    def test_face_down_still_grab_is_ignored(self):
        self._grab("g-fd", {"face_down_still": True, "hour": 1})
        self._assert_suppressed("g-fd", "face_down_still")

    def test_night_home_wifi_ignored_unless_night_guard(self):
        AntiTheftEngine.objects.filter(pk=self.eng.pk).update(home_wifi=[HOME])
        self._grab("g-home", {"hour": 1, "wifi": HOME})
        self._assert_suppressed("g-home", "home_wifi_night")
        AntiTheftEngine.objects.filter(pk=self.eng.pk).update(night_guard=True)
        self._grab("g-guard", {"hour": 1, "wifi": HOME})
        self.assertEqual(self._notifs(self.family, "snatch").count(), 1)

    def test_settings_save_home_wifi_and_night_guard(self):
        now = timezone.now()
        # no Wi-Fi seen yet -> honest 400
        r = self.client.post("/api/v1/security/engine/settings",
                             {"pin": self.PIN, "home_wifi": "save_current"},
                             format="json")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.data["reason"], "no_wifi")
        self._ingest([{"id": "hb-wifi", "kind": "heartbeat", "at": _ms(now),
                       "wifi": HOME}])
        r = self.client.post("/api/v1/security/engine/settings",
                             {"pin": self.PIN, "home_wifi": "save_current",
                              "night_guard": True}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data["config"]["home_wifi"], [HOME])
        self.assertTrue(r.data["config"]["night_guard"])
        st = self.client.get("/api/v1/security/engine/state").data
        self.assertEqual(st["home_wifi_count"], 1)
        self.assertTrue(st["night_guard"])
        # wrong PIN never changes them
        r = self.client.post("/api/v1/security/engine/settings",
                             {"pin": "0000", "home_wifi": "clear"}, format="json")
        self.assertEqual(r.status_code, 403)
        self.eng.refresh_from_db()
        self.assertEqual(self.eng.home_wifi, [HOME])

    def test_plain_grab_from_old_engine_still_alerts(self):
        self._grab("g-old", {"locked": False})
        self.assertEqual(self._notifs(self.family, "snatch").count(), 1)


class AreYouOkTests(_Base):
    def _pending(self, cid, at_dt=None):
        at_dt = at_dt or timezone.now()
        return self._ingest([{"id": cid, "kind": "snatch", "at": _ms(at_dt),
                              "data": {"confirm": "pending", "hour": 14}}])

    def test_held_grab_alerts_nobody_and_freezes_nothing(self):
        self._pending("ok-1")
        ev = self._ev("ok-1")
        self.assertFalse(ev.alerted)
        self.assertIsNotNone(ev.escalate_at)
        self.assertEqual(self._notifs(self.family).count(), 0)
        self.phone.refresh_from_db()
        self.assertIsNone(self.phone.frozen_until)
        st = self.client.get("/api/v1/security/engine/state").data
        self.assertTrue(st["grab_pending"])

    def test_no_answer_escalates_after_the_window_exactly_once(self):
        self._pending("ok-2")
        self.assertEqual(atv.escalate_due(), 0)          # window not over
        later = timezone.now() + timedelta(seconds=at.CONFIRM_WINDOW_S + 1)
        self.assertEqual(atv.escalate_due(later), 1)
        self.assertEqual(atv.escalate_due(later), 0)     # never twice
        call_command("antitheft_escalate")               # cron backstop: no-op
        self.assertEqual(self._notifs(self.family, "snatch").count(), 1)
        ev = self._ev("ok-2")
        self.assertTrue(ev.alerted)
        self.assertEqual(ev.data["confirm"], "timeout")
        self.phone.refresh_from_db()
        self.assertIsNotNone(self.phone.frozen_until)    # now a theft signal

    def test_cron_escalates_a_due_grab(self):
        # minutejobs: the command's cheap "anything due?" pre-check must still
        # hand a due grab to escalate_due (direct and via minute_jobs)
        self._pending("ok-cron")
        AntiTheftEvent.objects.filter(pk=self._ev("ok-cron").pk).update(
            escalate_at=timezone.now() - timedelta(seconds=1))
        with mock.patch("core.journey_watch.sweep", return_value={}), \
                mock.patch("core.ops_health.lock_path",
                           lambda n: "/tmp/assisto-test-%s-%s.lock" % (os.getpid(), n)):
            call_command("minute_jobs", stdout=StringIO(), stderr=StringIO())
        self.assertTrue(self._ev("ok-cron").alerted)
        self.assertEqual(self._notifs(self.family, "snatch").count(), 1)
        call_command("antitheft_escalate")               # nothing left: no-op
        self.assertEqual(self._notifs(self.family, "snatch").count(), 1)

    def test_im_ok_with_pin_drops_it(self):
        self._pending("ok-3")
        r = self.client.post("/api/v1/security/engine/false-alarm",
                             {"pin": self.PIN}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data["held_cleared"], 1)
        later = timezone.now() + timedelta(minutes=5)
        self.assertEqual(atv.escalate_due(later), 0)
        self.assertEqual(self._notifs(self.family).count(), 0)
        ev = self._ev("ok-3")
        self.assertEqual(ev.data["confirm"], "ok")

    def test_wrong_pin_escalates_at_once(self):
        self._pending("ok-4")
        r = self.client.post("/api/v1/security/engine/false-alarm",
                             {"pin": "0000"}, format="json")
        self.assertEqual(r.status_code, 403)
        self.assertEqual(self._notifs(self.family, "snatch").count(), 1)
        self.assertEqual(self._ev("ok-4").data["confirm"], "wrong_pin")

    def test_i_need_help_escalates_at_once(self):
        self._pending("ok-5")
        r = self.client.post("/api/v1/security/engine/escalate",
                             {"reason": "duress"}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["escalated"], 1)
        self.assertEqual(self._notifs(self.family, "snatch").count(), 1)
        self.assertEqual(self._ev("ok-5").data["confirm"], "duress")

    def test_escalate_is_owner_only(self):
        self._pending("ok-6")
        self.client.force_authenticate(self.family)
        r = self.client.post("/api/v1/security/engine/escalate", {}, format="json")
        self.assertEqual(r.status_code, 404)  # family has no protected phone
        self.assertFalse(self._ev("ok-6").alerted)

    def test_late_pending_grab_escalates_on_arrival(self):
        self._pending("ok-7", timezone.now() - timedelta(minutes=10))
        self.assertEqual(self._notifs(self.family, "snatch").count(), 1)
        self.assertEqual(self._ev("ok-7").data["confirm"], "timeout")

    def test_next_check_in_escalates_a_due_grab(self):
        self._pending("ok-8")
        AntiTheftEvent.objects.filter(phone=self.phone, client_id="ok-8").update(
            escalate_at=timezone.now() - timedelta(seconds=1))
        self._ingest([{"id": "hb-esc", "kind": "heartbeat",
                       "at": _ms(timezone.now())}])
        self.assertEqual(self._notifs(self.family, "snatch").count(), 1)


class OfflineNoiseTests(_Base):
    def test_offline_delivered_after_reconnect_is_history_only(self):
        old = timezone.now() - timedelta(hours=3)
        self._ingest([{"id": "off-late", "kind": "offline", "at": _ms(old),
                       "data": {"reason": "no_network"}}])
        ev = self._ev("off-late")
        self.assertTrue(ev.late)
        self.assertEqual(ev.data["silent"], "delivered_after_reconnect")
        self.assertEqual(self._notifs(self.family, "offline").count(), 0)

    def test_live_airplane_offline_still_alerts(self):
        self._ingest([{"id": "off-now", "kind": "offline",
                       "at": _ms(timezone.now()), "data": {"reason": "airplane"}}])
        self.assertEqual(self._notifs(self.family, "offline").count(), 1)


# ------------------------------------------------------ C. owner-only alerts
class OwnerOnlyAlertTests(APITestCase):
    def setUp(self):
        self.admin = User.objects.create_user(name="Owner", phone="01710000301",
                                              password="x",
                                              email="at2-admin@example.com")
        self.admin.is_superuser = True
        self.admin.is_staff = True
        self.admin.save()
        self.retired = User.objects.create_user(name="Old", phone="01710000302",
                                                password="x",
                                                email="at2-old@example.com")
        self.retired.is_superuser = True
        self.retired.is_active = False
        self.retired.save()
        self.normal = User.objects.create_user(name="User", phone="01710000303",
                                               password="x",
                                               email="at2-user@example.com")
        for u, t in ((self.admin, "t-admin"), (self.retired, "t-old"),
                     (self.normal, "t-user")):
            Device.objects.create(user=u, push_token=t, platform="android")

    def _capture(self):
        sent = []

        def fake_send(token, data, *a, **k):
            sent.append(token)
            return True
        return sent, fake_send

    def test_owner_admin_users_are_active_superusers_only(self):
        self.assertEqual([u.pk for u in push.owner_admin_users()], [self.admin.pk])
        self.assertTrue(push.is_owner_admin(self.admin))
        self.assertFalse(push.is_owner_admin(self.retired))
        self.assertFalse(push.is_owner_admin(self.normal))

    def test_notify_owner_pushes_only_to_owner_admin(self):
        sent, fake = self._capture()
        with mock.patch.object(push, "is_available", return_value=True), \
                mock.patch.object(push, "send_to_token", side_effect=fake):
            push.notify_owner("Play Vitals", "crash rate")
        self.assertEqual(sent, ["t-admin"])

    def test_owner_alert_push_refused_for_a_normal_user(self):
        sent, fake = self._capture()
        with mock.patch.object(push, "is_available", return_value=True), \
                mock.patch.object(push, "send_to_token", side_effect=fake):
            n = push.push_to_user(self.normal, "owner_alert", "x", "x", "y", "y")
        self.assertEqual(n, 0)
        self.assertEqual(sent, [])

    def test_play_vitals_rows_only_for_owner_admin(self):
        from core import play_vitals
        with mock.patch.object(push, "is_available", return_value=False):
            play_vitals._admin_event("play_new_issue", "t", "t", "b", "b", {})
        self.assertEqual(
            list(NotifEvent.objects.filter(meta__source="play_vitals")
                 .values_list("user_id", flat=True)), [self.admin.pk])

    def test_disk_and_call_relay_rows_only_for_owner_admin(self):
        from core import disk_alert, turn_monitor
        disk_alert._alert_rows({"used_pct": 91, "free_gb": 2, "threshold": 80,
                                "total_gb": 20, "path": "/"})
        with mock.patch.object(push, "is_available", return_value=False):
            turn_monitor.deliver([("k", "fire", "relay at 90%")])
        users = set(NotifEvent.objects.filter(type="admin")
                    .values_list("user_id", flat=True))
        self.assertEqual(users, {self.admin.pk})

    def test_normal_user_feed_and_alerts_never_show_owner_rows(self):
        # even if a row ever landed on a normal account by mistake
        NotifEvent.objects.create(user=self.normal, type="admin", title_en="Vitals",
                                  title_bn="Vitals", body_en="b", body_bn="b",
                                  route="owner", meta={"source": "play_vitals"},
                                  at=timezone.now())
        FamilyAlert.objects.create(user=self.normal, kind="disk_alert",
                                   title="Disk", body="full", severity="high",
                                   payload={"source": "uptime_check"})
        self.client.force_authenticate(self.normal)
        feed = self.client.get("/api/v1/notif/feed").data["items"]
        self.assertEqual([i for i in feed if i["type"] == "admin"], [])
        self.assertFalse(any((i.get("title") or {}).get("en") == "Disk" for i in feed))
        alerts = self.client.get("/api/v1/alerts").data
        self.assertFalse(any(a.get("type") == "disk_alert" for a in alerts))
        # the owner admin still sees his
        NotifEvent.objects.create(user=self.admin, type="admin", title_en="Vitals",
                                  title_bn="Vitals", body_en="b", body_bn="b",
                                  route="owner", meta={"source": "play_vitals"},
                                  at=timezone.now())
        self.client.force_authenticate(self.admin)
        feed = self.client.get("/api/v1/notif/feed").data["items"]
        self.assertTrue(any(i["type"] == "admin" for i in feed))
