"""family100 — family alerts by SERVER push (core/family_alerts.py).

Each alert kind -> the right recipients only; idempotency per (event,
recipient); per-recipient rate limit; SOS rings through quiet hours while
other kinds are held and released by the sweep; members who left / blocked
get nothing; location only with consent (SOS excepted); seen / received
receipts on both sides; the journey_sweep cron runs it; SOS is free."""
from datetime import timedelta
from io import StringIO
from unittest import mock

from django.core.cache import cache
from django.core.management import call_command
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import family_alerts as FA
from core import journey_watch as JW
from core.models import (CircleMember, CirclePrivacy, FamilyAlert,
                         FamilyAlertDelivery, SafetyCheckin, User, WellnessWatch)

V = "/api/v1"


def mk(phone, name, lang="en"):
    return User.objects.create_user(name=name, phone=phone, password="pw12345!",
                                    language=lang)


def cl(u):
    c = APIClient()
    c.force_authenticate(u)
    c.credentials(HTTP_ACCEPT_LANGUAGE="en")
    return c


def pair(a, b, **kw):
    """Both sides of an accepted circle edge (a -> b and b -> a)."""
    ab = CircleMember.objects.create(user=a, peer_user=b, name=b.name,
                                     state="accepted", **kw)
    ba = CircleMember.objects.create(user=b, peer_user=a, name=a.name,
                                     state="accepted", direction="incoming")
    return ab, ba


class Spy:
    def __init__(self):
        self.calls = []

    def safe_push(self, user, kind, tbn, ten, bbn="", ben="", data=None, **kw):
        self.calls.append({"user": user.pk, "kind": kind, "tbn": tbn, "ten": ten,
                           "bbn": bbn, "ben": ben, "data": dict(data or {}),
                           "high": kw.get("high_priority", False)})
        return True

    def to(self, u):
        return [c for c in self.calls if c["user"] == u.pk]


class Base(TestCase):
    def setUp(self):
        cache.clear()
        self.a = mk("01711100001", "Rina")                 # the sender
        self.b = mk("01711100002", "Mother", lang="bn")    # family
        self.c = mk("01711100003", "Brother")              # family
        self.x = mk("01711100004", "Stranger")             # not in circle
        self.ab, self.ba = pair(self.a, self.b, sharing={"location": True})
        self.ac, self.ca_ = pair(self.a, self.c, sharing={"location": False})
        self.ca, self.cb, self.cx = cl(self.a), cl(self.b), cl(self.x)
        self.spy = Spy()
        p = mock.patch("core.push.safe_push", side_effect=self.spy.safe_push)
        p.start()
        self.addCleanup(p.stop)


class SosTests(Base):
    def test_sos_reaches_family_only_with_full_screen_kind(self):
        r = self.ca.post("%s/family/sos" % V, {"lat": 23.75, "lng": 90.39,
                                              "source": "emergency"}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["recipients"], 2)
        self.assertEqual(r.json()["sent"], 2)
        self.assertEqual(sorted(c["user"] for c in self.spy.calls),
                         sorted([self.b.pk, self.c.pk]))
        self.assertEqual({c["kind"] for c in self.spy.calls}, {"sos"})
        self.assertEqual(self.spy.to(self.a), [])
        self.assertEqual(self.spy.to(self.x), [])
        d = self.spy.to(self.b)[0]["data"]
        self.assertEqual(d["route"], "safety/sos")
        self.assertFalse(d["silent"])                 # family phones always ring
        self.assertTrue(d["delivery_id"])
        # in-app fallback card for each recipient (the foreground poll)
        self.assertTrue(FamilyAlert.objects.filter(user=self.b, kind="sos").exists())
        self.assertFalse(FamilyAlert.objects.filter(user=self.x).exists())

    def test_sos_location_goes_to_everyone_in_circle(self):
        self.ca.post("%s/family/sos" % V, {"lat": 23.75, "lng": 90.39}, format="json")
        self.assertEqual(self.spy.to(self.c)[0]["data"]["lat"], 23.75)

    def test_sos_is_idempotent_per_press(self):
        for _ in range(3):
            self.ca.post("%s/family/sos" % V, {"client_id": "press-1"}, format="json")
        self.assertEqual(len(self.spy.calls), 2)
        self.assertEqual(FamilyAlertDelivery.objects.count(), 2)
        r = self.ca.post("%s/family/sos" % V, {"client_id": "press-1"}, format="json")
        self.assertEqual(r.json()["duplicate"], 2)
        # a NEW press is a new event
        self.ca.post("%s/family/sos" % V, {"client_id": "press-2"}, format="json")
        self.assertEqual(len(self.spy.calls), 4)

    def test_sos_rings_in_quiet_hours(self):
        CirclePrivacy.objects.update_or_create(user=self.b, defaults=dict(dnd_enabled=True, dnd_start="00:00",                                     dnd_end="23:59", dnd_family_exception=False))
        self.ca.post("%s/family/sos" % V, {}, format="json")
        self.assertEqual(len(self.spy.to(self.b)), 1)
        self.assertEqual(FamilyAlertDelivery.objects.get(recipient=self.b).status, "sent")

    def test_sos_never_capped(self):
        for i in range(FA.RATE_PER_HOUR + 3):
            self.ca.post("%s/family/sos" % V, {"client_id": "p%d" % i}, format="json")
        self.assertEqual(len(self.spy.to(self.b)), FA.RATE_PER_HOUR + 3)

    def test_sos_is_free(self):
        before = User.objects.get(pk=self.a.pk).ai_credits
        self.ca.post("%s/family/sos" % V, {}, format="json")
        self.assertEqual(User.objects.get(pk=self.a.pk).ai_credits, before)

    def test_sos_with_no_circle_is_honest(self):
        r = self.cx.post("%s/family/sos" % V, {}, format="json")
        self.assertEqual(r.json()["recipients"], 0)
        self.assertEqual(self.spy.calls, [])

    def test_bad_coordinates_are_dropped(self):
        self.ca.post("%s/family/sos" % V, {"lat": 500, "lng": "x"}, format="json")
        self.assertEqual(self.spy.to(self.b)[0]["data"]["lat"], "")

    def test_duress_from_journey_still_rings_family(self):
        from core import push
        push.hook_sos(self.a, lat=23.7, lng=90.4, silent=True, journey_id=None)
        d = self.spy.to(self.b)[0]["data"]
        self.assertTrue(d["duress"])
        self.assertFalse(d["silent"])
        self.assertEqual(self.spy.to(self.a), [])

    def test_resolve_tells_the_same_people_and_clears_cards(self):
        self.ca.post("%s/family/sos" % V, {}, format="json")
        r = self.ca.post("%s/family/sos/resolve" % V, {}, format="json")
        self.assertEqual(r.json()["recipients"], 2)
        kinds = [c["data"]["alert_kind"] for c in self.spy.to(self.b)]
        self.assertEqual(kinds, ["sos", "sos_resolved"])
        self.assertFalse(FamilyAlert.objects.filter(user=self.b, kind="sos",
                                                    dismissed=False).exists())
        # nothing to resolve -> nobody pinged
        r = self.cx.post("%s/family/sos/resolve" % V, {}, format="json")
        self.assertEqual(r.json()["recipients"], 0)


class PrivacyTests(Base):
    def test_left_circle_gets_nothing(self):
        self.ac.delete()
        self.ca_.delete()
        self.ca.post("%s/family/sos" % V, {}, format="json")
        self.assertEqual(self.spy.to(self.c), [])
        self.assertEqual(len(self.spy.to(self.b)), 1)

    def test_blocked_either_side_gets_nothing(self):
        self.ab.blocked = True
        self.ab.save()
        self.ca_.blocked = True      # c blocked a on c's side
        self.ca_.save()
        self.ca.post("%s/family/sos" % V, {}, format="json")
        self.assertEqual(self.spy.calls, [])

    def test_pending_member_gets_nothing(self):
        y = mk("01711100005", "Pending")
        CircleMember.objects.create(user=self.a, peer_user=y, state="pending")
        self.ca.post("%s/family/sos" % V, {}, format="json")
        self.assertEqual(self.spy.to(y), [])

    def test_location_only_with_sharing_consent_for_non_sos(self):
        st = FA.alert(self.a, "checkin_overdue", "t1",
                      payload={"title_en": "{name} is late", "title_bn": "{name} দেরি"},
                      lat=23.7, lng=90.4)
        self.assertEqual(st["sent"], 2)
        self.assertEqual(self.spy.to(self.b)[0]["data"]["lat"], 23.7)   # shares
        self.assertEqual(self.spy.to(self.c)[0]["data"]["lat"], "")     # does not
        self.assertEqual(self.spy.to(self.c)[0]["ten"], "Rina is late")
        self.assertEqual(self.spy.to(self.b)[0]["tbn"], "Rina দেরি")

    def test_explicit_recipients_are_intersected_with_circle(self):
        st = FA.alert(self.a, "scam_report", "s1", recipients=[self.b, self.x],
                      payload={"title_en": "x", "title_bn": "x"})
        self.assertEqual(st["recipients"], 1)
        self.assertEqual(self.spy.to(self.x), [])

    def test_left_circle_while_held_is_revoked(self):
        CirclePrivacy.objects.update_or_create(user=self.c, defaults=dict(dnd_enabled=True, dnd_start="00:00",                                     dnd_end="23:59", dnd_family_exception=False))
        FA.alert(self.a, "scam_report", "s2", payload={"title_en": "x", "title_bn": "x"})
        d = FamilyAlertDelivery.objects.get(recipient=self.c)
        self.assertEqual(d.status, "held")
        self.ac.delete()
        CirclePrivacy.objects.filter(user=self.c).update(dnd_enabled=False)
        FA.sweep()
        d.refresh_from_db()
        self.assertEqual(d.status, "revoked")
        self.assertEqual(self.spy.to(self.c), [])
        self.assertTrue(FamilyAlert.objects.get(pk=d.alert_id).dismissed)


class RulesTests(Base):
    def test_idempotent_per_event_and_recipient(self):
        for _ in range(3):
            FA.alert(self.a, "checkin_overdue", "checkin:9",
                     payload={"title_en": "late", "title_bn": "দেরি"})
        self.assertEqual(FamilyAlertDelivery.objects.count(), 2)
        self.assertEqual(len(self.spy.calls), 2)

    def test_rate_limit_non_urgent_per_recipient(self):
        for i in range(FA.RATE_PER_HOUR + 2):
            FA.alert(self.a, "scam_report", "s%d" % i,
                     payload={"title_en": "x", "title_bn": "x"})
        self.assertEqual(len(self.spy.to(self.b)), FA.RATE_PER_HOUR)
        self.assertEqual(FamilyAlertDelivery.objects.filter(
            recipient=self.b, status="rate_limited").count(), 2)
        # the in-app card is still there for every one
        self.assertEqual(FamilyAlert.objects.filter(user=self.b, kind="scam_report").count(),
                         FA.RATE_PER_HOUR + 2)

    def test_quiet_hours_hold_then_release(self):
        CirclePrivacy.objects.update_or_create(user=self.b, defaults=dict(dnd_enabled=True, dnd_start="00:00",                                     dnd_end="23:59", dnd_family_exception=False))
        FA.alert(self.a, "checkin_overdue", "q1", payload={"title_en": "x", "title_bn": "x"})
        self.assertEqual(self.spy.to(self.b), [])
        self.assertEqual(len(self.spy.to(self.c)), 1)
        FA.sweep()                                            # still quiet
        self.assertEqual(self.spy.to(self.b), [])
        CirclePrivacy.objects.filter(user=self.b).update(dnd_enabled=False)
        FA.sweep()
        FA.sweep()                                            # released once
        self.assertEqual(len(self.spy.to(self.b)), 1)

    def test_family_exception_on_means_not_held(self):
        CirclePrivacy.objects.update_or_create(user=self.b, defaults=dict(dnd_enabled=True, dnd_start="00:00",                                     dnd_end="23:59", dnd_family_exception=True))
        FA.alert(self.a, "checkin_overdue", "q2", payload={"title_en": "x", "title_bn": "x"})
        self.assertEqual(len(self.spy.to(self.b)), 1)

    def test_old_held_alert_expires(self):
        CirclePrivacy.objects.update_or_create(user=self.b, defaults=dict(dnd_enabled=True, dnd_start="00:00",                                     dnd_end="23:59", dnd_family_exception=False))
        FA.alert(self.a, "scam_report", "old", payload={"title_en": "x", "title_bn": "x"})
        FA.sweep(now=timezone.now() + timedelta(hours=FA.HOLD_MAX_HOURS + 1))
        self.assertEqual(FamilyAlertDelivery.objects.get(recipient=self.b).status, "expired")

    def test_no_device_status_when_push_refused(self):
        with mock.patch("core.push.safe_push", side_effect=lambda *a, **k: False), \
                mock.patch("core.push.is_available", return_value=True):
            st = FA.alert(self.a, "checkin_overdue", "nd",
                          payload={"title_en": "x", "title_bn": "x"})
        self.assertEqual(st["no_device"], 2)
        self.assertTrue(FamilyAlert.objects.filter(user=self.b, kind="checkin_overdue").exists())

    def test_unknown_kind_and_never_raises(self):
        self.assertEqual(FA.alert(self.a, "nope", "k")["recipients"], 0)
        self.assertEqual(FA.alert(None, "sos", "k")["recipients"], 0)


class ReceiptTests(Base):
    def test_seen_and_received_both_sides(self):
        self.ca.post("%s/family/sos" % V, {"lat": 23.7, "lng": 90.4}, format="json")
        lst = self.cb.get("%s/family/alerts" % V).json()
        self.assertEqual(lst["unseen"], 1)
        row = lst["received"][0]
        self.assertEqual(row["kind"], "sos")
        self.assertEqual(row["from_name"], "Rina")
        self.assertEqual(row["lat"], 23.7)
        # the phone acked the push, then the user tapped it
        r = self.cb.post("%s/family/alerts/received" % V, {"ids": [row["id"]]}, format="json")
        self.assertEqual(r.json()["updated"], 1)
        self.assertEqual(self.cb.post("%s/family/alerts/%d/seen" % (V, row["id"]))
                         .status_code, 200)
        self.assertEqual(self.cb.get("%s/family/alerts" % V).json()["unseen"], 0)
        sent = self.ca.get("%s/family/alerts" % V).json()["sent"]
        self.assertEqual(len(sent), 1)
        by = {r["name"]: r for r in sent[0]["recipients"]}
        self.assertTrue(by["Mother"]["seen"] and by["Mother"]["received"])
        self.assertFalse(by["Brother"]["seen"])
        # the urgent card left the foreground poll
        self.assertTrue(FamilyAlert.objects.get(pk=FamilyAlertDelivery.objects.get(
            pk=row["id"]).alert_id).dismissed)

    def test_cannot_touch_someone_elses_alert(self):
        self.ca.post("%s/family/sos" % V, {}, format="json")
        d = FamilyAlertDelivery.objects.get(recipient=self.b)
        self.assertEqual(self.cx.post("%s/family/alerts/%d/seen" % (V, d.id)).status_code, 404)
        self.assertEqual(self.cx.post("%s/family/alerts/received" % V, {"ids": [d.id]},
                                      format="json").json()["updated"], 0)
        self.assertEqual(self.cx.get("%s/family/alerts" % V).json()["received"], [])

    def test_bad_ids_and_auth(self):
        self.assertEqual(self.cb.post("%s/family/alerts/received" % V, {"ids": "x"},
                                      format="json").status_code, 400)
        self.assertIn(APIClient().get("%s/family/alerts" % V).status_code, (401, 403))

    def test_delivery_report_command(self):
        out = StringIO()
        call_command("family_alerts_report", stdout=out)
        self.assertIn("no receipts yet", out.getvalue())
        self.ca.post("%s/family/sos" % V, {}, format="json")
        d = FamilyAlertDelivery.objects.get(recipient=self.b)
        FamilyAlertDelivery.objects.filter(pk=d.pk).update(
            received_at=d.pushed_at + timedelta(seconds=4))
        st = FA.delivery_stats()
        self.assertEqual(st["receipts"], 1)
        self.assertEqual(st["p95_s"], 4.0)
        self.assertEqual(st["within_60s"], 1)


class CronTests(Base):
    def test_missed_checkin_via_journey_sweep_once_and_consent(self):
        SafetyCheckin.objects.create(user=self.a, place="Uttara",
                                     eta=timezone.now() - timedelta(minutes=40))
        out = StringIO()
        call_command("journey_sweep", stdout=out)
        call_command("journey_sweep", stdout=out)
        self.assertEqual(len(self.spy.to(self.b)), 1)
        self.assertEqual(len(self.spy.to(self.c)), 1)
        self.assertEqual(self.spy.to(self.x), [])
        d = self.spy.to(self.b)[0]
        self.assertEqual(d["data"]["event"], "checkin_overdue")
        self.assertEqual(d["data"]["route"], "family/alerts")
        self.assertIn("Uttara", d["tbn"] + d["bbn"])
        self.assertEqual(FamilyAlertDelivery.objects.filter(kind="checkin_overdue").count(), 2)

    def test_checkin_arrived_clears_family_cards(self):
        c = SafetyCheckin.objects.create(user=self.a, place="Uttara",
                                         eta=timezone.now() - timedelta(minutes=40))
        JW.sweep()
        SafetyCheckin.objects.filter(pk=c.pk).update(arrived=True, arrived_at=timezone.now())
        JW.sweep()
        self.assertFalse(FamilyAlert.objects.filter(kind="checkin_overdue",
                                                    dismissed=False).exists())

    def test_wellness_unanswered_goes_to_family_once(self):
        WellnessWatch.objects.create(parent=self.a, enabled=True, parent_opt_in=True,
                                     period_hours=2, response_window=30,
                                     quiet_start="00:00", quiet_end="00:00",
                                     last_activity_at=timezone.now() - timedelta(hours=3))
        JW.sweep()
        JW.sweep(now=timezone.now() + timedelta(minutes=31))
        JW.sweep(now=timezone.now() + timedelta(minutes=33))
        ws = [c for c in self.spy.to(self.b) if c["data"].get("event") == "wellness_alert"]
        self.assertEqual(len(ws), 1)
        self.assertEqual(FamilyAlertDelivery.objects.filter(kind="wellness_alert").count(), 2)

    def test_scam_report_reaches_family_with_card(self):
        r = self.ca.post("%s/scam/report" % V,
                         {"message": "Your bKash account is blocked, send OTP"}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(len(self.spy.to(self.b)), 1)
        self.assertTrue(FamilyAlert.objects.filter(user=self.b, kind="scam_report").exists())
        # Mother reads Bangla, Brother English
        self.assertIn("প্রতারণা", self.spy.to(self.b)[0]["tbn"])
        self.assertEqual(FamilyAlert.objects.get(user=self.c, kind="scam_report").title,
                         "Scam alert in your family")
