"""kidaudio (owner 2 Nov PART 1 b): child emergency audio — the gates (no
emergency / adult / unverified guardian / no prior consent / flag off ->
refused, each refusal audited), the emergencies that count (SOS, fall, late
journey with no answer, watch SOS) and the ones that end it ("I'm safe",
answered "Are you OK?"), the session time limit enforced by the SERVER, the
per-emergency cap, the audit visible to BOTH sides, the visible-notice
contract (no notice -> no audio), and the watch path (a normal call; never a
listen command)."""
from datetime import timedelta
from unittest import mock

from django.core.cache import cache
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import kid_audio as KA
from core.models import (CallRecord, CircleMember, FamilyAlertDelivery, Journey,
                         KidAudioConsent, KidAudioSession, KidsWatch,
                         KidsWatchCommand, User)


def link(a, b, rel_ab, rel_ba):
    CircleMember.objects.create(user=a, peer_user=b, name=b.name, relation=rel_ab, state="accepted")
    CircleMember.objects.create(user=b, peer_user=a, name=a.name, relation=rel_ba, state="accepted")


class Spy:
    def __init__(self):
        self.calls = []

    def __call__(self, user, tbn, ten, bbn, ben, data=None, high=False):
        self.calls.append({"user": user.pk, "tbn": tbn, "data": dict(data or {}), "high": high})

    def to(self, user, event=None):
        return [c for c in self.calls if c["user"] == user.pk
                and (event is None or c["data"].get("event") == event)]


class Base(TestCase):
    n = 0

    def mk(self, name):
        Base.n += 1
        u = User.objects.create_user(name=name, phone="0172%07d" % Base.n, password="pw-123456")
        u.language = "en"
        u.save()
        return u

    def setUp(self):
        cache.clear()
        self.p1 = mock.patch.object(KA, "flag_on", lambda user=None: True)
        self.p1.start()
        self.spy = Spy()
        self.p2 = mock.patch.object(KA, "_notify", self.spy)
        self.p2.start()
        self.now = timezone.now()
        self.parent = self.mk("Baba")
        self.child = self.mk("Rina")
        link(self.parent, self.child, "child", "father")
        self.year = self.now.year - 12

    def tearDown(self):
        self.p1.stop()
        self.p2.stop()

    def consent(self, agree=True):
        c, reason = KA.set_consent(self.parent, self.child, self.year)
        self.assertEqual(reason, "")
        if agree:
            ok, r = KA.child_agree(self.child, c, self.year)
            self.assertTrue(ok, r)
        c.refresh_from_db()
        return c

    def sos(self, at=None, key="c:abc"):
        d = FamilyAlertDelivery.objects.create(event_key=key, kind="sos", sender=self.child,
                                               recipient=self.parent)
        if at is not None:
            FamilyAlertDelivery.objects.filter(pk=d.pk).update(created_at=at)
        return d

    def api(self, user):
        c = APIClient()
        c.force_authenticate(user)
        return c


class GateTests(Base):
    def test_no_emergency_refused_and_audited(self):
        c = self.consent()
        s, reason = KA.request_listen(self.parent, c)
        self.assertEqual(reason, "no_emergency")
        self.assertEqual(s.status, "refused")
        self.assertEqual(KidAudioSession.objects.filter(status="refused").count(), 1)
        # the child is told a refused attempt happened
        self.assertTrue(self.spy.to(self.child, "refused"))
        self.assertFalse(self.spy.to(self.child, "listen"))

    def test_old_sos_is_not_an_emergency(self):
        c = self.consent()
        self.sos(at=self.now - timedelta(seconds=KA.EMERGENCY_WINDOW_S + 60))
        self.assertEqual(KA.request_listen(self.parent, c)[1], "no_emergency")

    def test_im_safe_ends_the_emergency(self):
        c = self.consent()
        self.sos()
        FamilyAlertDelivery.objects.create(event_key="r:1", kind="sos_resolved",
                                           sender=self.child, recipient=self.parent)
        self.assertEqual(KA.request_listen(self.parent, c)[1], "no_emergency")

    def test_adult_refused(self):
        adult_year = self.now.year - 18
        c, reason = KA.set_consent(self.parent, self.child, adult_year)
        self.assertIsNone(c)
        self.assertEqual(reason, "adult")
        # a consent made while a minor stops by itself when the child turns 18
        c = self.consent()
        KidAudioConsent.objects.filter(pk=c.pk).update(birth_year=adult_year)
        c.refresh_from_db()
        self.sos()
        s, reason = KA.request_listen(self.parent, c)
        self.assertEqual(reason, "adult")
        self.assertEqual(s.status, "refused")

    def test_is_minor_is_conservative(self):
        self.assertTrue(KA.is_minor(self.now.year - 17, self.now))
        self.assertFalse(KA.is_minor(self.now.year - 18, self.now))
        self.assertFalse(KA.is_minor("x", self.now))
        self.assertFalse(KA.is_minor(self.now.year + 1, self.now))

    def test_unverified_guardian_refused(self):
        uncle = self.mk("Mama")
        # one-sided: uncle says "child", child does not say father/mother
        link(uncle, self.child, "child", "relative")
        self.assertFalse(KA.is_guardian(uncle, self.child))
        c, reason = KA.set_consent(uncle, self.child, self.year)
        self.assertEqual(reason, "not_guardian")
        # a real consent cannot be used by someone else
        good = self.consent()
        self.sos()
        ok, reason, _ = KA.check(uncle, self.child, good)
        self.assertEqual((ok, reason), (False, "not_guardian"))
        # the parent edge blocked -> no longer verified
        CircleMember.objects.filter(user=self.child, peer_user=self.parent).update(blocked=True)
        self.assertEqual(KA.request_listen(self.parent, good)[1], "not_guardian")

    def test_no_prior_consent_refused(self):
        c = self.consent(agree=False)           # parent set it, child did not agree
        self.sos()
        self.assertEqual(KA.request_listen(self.parent, c)[1], "no_consent")
        ok, r = KA.child_agree(self.child, c, self.year + 1)
        self.assertEqual((ok, r), (False, "year_mismatch"))
        ok, _ = KA.child_agree(self.child, c, self.year)
        self.assertTrue(ok)
        KA.revoke(self.child, c)
        c.refresh_from_db()
        self.assertEqual(KA.request_listen(self.parent, c)[1], "no_consent")

    def test_changed_terms_need_the_child_again(self):
        c = self.consent()
        c2, _ = KA.set_consent(self.parent, self.child, self.year - 1)
        self.assertIsNone(c2.child_ok_at)

    def test_flag_off_refused_over_api(self):
        c = self.consent()
        self.sos()
        with mock.patch.object(KA, "flag_on", lambda user=None: False):
            r = self.api(self.parent).post("/api/v1/kid-audio/listen",
                                           {"consent_id": c.pk}, format="json")
            self.assertEqual(r.status_code, 403)
            self.assertEqual(r.json()["reason"], "flag_off")
            # revoking is never flag-gated
            r = self.api(self.child).post("/api/v1/kid-audio/consent/%d/revoke" % c.pk)
            self.assertEqual(r.status_code, 200)


class EmergencyTests(Base):
    def test_sos_grants_and_pushes_the_child(self):
        c = self.consent()
        self.sos()
        s, reason = KA.request_listen(self.parent, c)
        self.assertEqual(reason, "")
        self.assertEqual((s.status, s.emergency_kind), ("requested", "sos"))
        push = self.spy.to(self.child, "listen")
        self.assertTrue(push and push[0]["high"])

    def test_late_journey_without_answer(self):
        c = self.consent()
        j = Journey.objects.create(traveller=self.child, status="active",
                                   ask_sent_at=self.now - timedelta(minutes=12),
                                   escalated_at=self.now - timedelta(minutes=2))
        em = KA.active_emergency(self.child, self.now)
        self.assertEqual(em["kind"], "journey_late")
        # the child answered "Are you OK?" -> not an emergency
        Journey.objects.filter(pk=j.pk).update(responded_at=self.now - timedelta(minutes=1))
        self.assertIsNone(KA.active_emergency(self.child, self.now))
        self.assertEqual(KA.request_listen(self.parent, c)[1], "no_emergency")

    def test_late_but_not_escalated_is_not_enough(self):
        Journey.objects.create(traveller=self.child, status="active",
                               ask_sent_at=self.now - timedelta(minutes=3))
        self.assertIsNone(KA.active_emergency(self.child, self.now))

    def test_session_cap_per_emergency(self):
        c = self.consent()
        self.sos()
        for _ in range(KA.MAX_SESSIONS_PER_EMERGENCY):
            s, reason = KA.request_listen(self.parent, c)
            self.assertEqual(reason, "")
            KA.end_session(s, "stopped", by="guardian")
        s, reason = KA.request_listen(self.parent, c)
        self.assertEqual(reason, "session_cap")

    def test_one_live_session_at_a_time(self):
        c = self.consent()
        self.sos()
        KA.request_listen(self.parent, c)
        self.assertEqual(KA.request_listen(self.parent, c)[1], "busy")


class SessionTests(Base):
    def grant(self):
        c = self.consent()
        self.sos()
        s, reason = KA.request_listen(self.parent, c)
        self.assertEqual(reason, "")
        return c, s

    def call(self):
        return CallRecord.objects.create(caller=self.child, callee=self.parent,
                                         kind="voice", state="active")

    def test_notice_required_to_go_live(self):
        _c, s = self.grant()
        ok, reason = KA.child_started(self.child, s, notice_shown=False)
        self.assertEqual((ok, reason), (False, "notice_required"))
        s.refresh_from_db()
        self.assertEqual((s.status, s.reason), ("ended", "notice_failed"))
        self.assertIsNone(s.started_at)

    def test_notice_contract_over_api(self):
        _c, s = self.grant()
        url = "/api/v1/kid-audio/sessions/%d/event" % s.pk
        r = self.api(self.parent).post(url, {"event": "started", "notice_shown": True}, format="json")
        self.assertEqual(r.status_code, 403)          # only the child's phone
        r = self.api(self.child).post(url, {"event": "started"}, format="json")
        self.assertEqual(r.status_code, 409)
        self.assertEqual(r.json()["reason"], "notice_required")

    def test_time_limit_is_enforced_by_the_server(self):
        _c, s = self.grant()
        rec = self.call()
        ok, _ = KA.child_started(self.child, s, notice_shown=True)
        self.assertTrue(ok)
        s.refresh_from_db()
        self.assertEqual((s.status, s.call_id), ("live", rec.pk))
        # inside the limit: nothing happens
        self.assertEqual(KA.enforce(self.child, now=s.started_at + timedelta(seconds=60)), 0)
        later = s.started_at + timedelta(seconds=KA.MAX_SESSION_S + 1)
        self.assertEqual(KA.enforce(self.parent, now=later), 1)
        s.refresh_from_db()
        rec.refresh_from_db()
        self.assertEqual((s.status, s.reason, s.ended_by), ("ended", "time_limit", "server"))
        self.assertNotIn(rec.state, ("ringing", "connecting", "active", "reconnecting"))
        self.assertEqual(KA.session_row(s, self.child)["seconds"], KA.MAX_SESSION_S)
        self.assertTrue(self.spy.to(self.child, "ended"))

    def test_emergency_over_ends_the_live_session(self):
        _c, s = self.grant()
        self.call()
        KA.child_started(self.child, s, notice_shown=True)
        FamilyAlertDelivery.objects.create(event_key="r:2", kind="sos_resolved",
                                           sender=self.child, recipient=self.parent)
        KA.enforce(self.child)
        s.refresh_from_db()
        self.assertEqual((s.status, s.reason), ("ended", "emergency_over"))

    def test_child_revoke_ends_live_session(self):
        c, s = self.grant()
        KA.child_started(self.child, s, notice_shown=True)
        KA.revoke(self.child, c)
        s.refresh_from_db()
        self.assertEqual((s.status, s.ended_by), ("ended", "child"))

    def test_child_stop_over_api(self):
        _c, s = self.grant()
        r = self.api(self.child).post("/api/v1/kid-audio/sessions/%d/event" % s.pk,
                                      {"event": "stop"}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["session"]["ended_by"], "child")

    def test_pending_gives_the_childs_circle_row(self):
        _c, s = self.grant()
        r = self.api(self.child).get("/api/v1/kid-audio/pending").json()
        edge = CircleMember.objects.get(user=self.child, peer_user=self.parent)
        self.assertEqual((r["pending"]["id"], r["pending"]["member_id"]), (s.pk, edge.pk))
        # the parent has nothing pending
        self.assertIsNone(self.api(self.parent).get("/api/v1/kid-audio/pending").json()["pending"])

    def test_pending_expires(self):
        _c, s = self.grant()
        later = s.created_at + timedelta(seconds=KA.START_WINDOW_S + 5)
        self.assertIsNone(KA.pending_for_child(self.child, now=later))
        s.refresh_from_db()
        self.assertEqual(s.status, "missed")

    def test_poll_hook_is_cheap_when_nothing_is_live(self):
        cache.clear()
        with self.assertNumQueries(0):
            self.assertEqual(KA.enforce(self.child), 0)

    def test_audit_visible_to_both_sides(self):
        c = self.consent()
        KA.request_listen(self.parent, c)            # refused: no emergency
        self.sos()
        _s, _ = KA.request_listen(self.parent, c)    # granted
        stranger = self.mk("Other")
        a = self.api(self.parent).get("/api/v1/kid-audio/log").json()["sessions"]
        b = self.api(self.child).get("/api/v1/kid-audio/log").json()["sessions"]
        x = self.api(stranger).get("/api/v1/kid-audio/log").json()["sessions"]
        self.assertEqual(sorted(r["id"] for r in a), sorted(r["id"] for r in b))
        self.assertEqual(len(a), 2)
        self.assertEqual(x, [])
        self.assertEqual({r["status"] for r in b}, {"refused", "requested"})
        self.assertEqual({r["role"] for r in b}, {"child"})
        for r in b:
            for k in ("guardian_name", "requested_at", "status", "reason", "seconds"):
                self.assertIn(k, r)


class WatchTests(Base):
    def setUp(self):
        super().setUp()
        self.w = KidsWatch.objects.create(owner=self.parent, child_user=self.child,
                                          imei="8800001234", child_name="Rina", state="paired")

    def test_watch_is_a_normal_call_never_a_listen_command(self):
        from tracker.protocols import watch as WP
        c, _ = KA.set_consent(self.parent, self.child, self.year, watch=self.w,
                              watch_phone="01711-000001")
        KA.child_agree(self.child, c, self.year)
        c.refresh_from_db()
        # no emergency -> refused, nothing sent to the watch
        self.assertEqual(KA.request_listen(self.parent, c, "watch")[1], "no_emergency")
        self.assertFalse(KidsWatchCommand.objects.filter(watch=self.w).exists())
        bucket = int(self.now.timestamp()) // 60
        KidsWatch.objects.filter(pk=self.w.pk).update(alert_state={"sos_direct": "sos_direct:%d" % bucket})
        c.refresh_from_db()
        r = self.api(self.parent).post("/api/v1/kid-audio/listen",
                                       {"consent_id": c.pk, "channel": "watch"}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        body = r.json()
        self.assertEqual(body["dial"], "01711000001")
        self.assertEqual(body["session"]["status"], "dialled")
        self.assertEqual(body["session"]["emergency_kind"], "watch_sos")
        cmds = list(KidsWatchCommand.objects.filter(watch=self.w))
        self.assertEqual([x.kind for x in cmds], ["message"])
        for x in cmds:
            content, typ = WP.command_content(x.kind, x.payload)
            self.assertNotIn(typ, WP.FORBIDDEN)
            self.assertNotIn(b"MONITOR", content.upper())
        self.assertIn("MONITOR", WP.FORBIDDEN)          # the guard stays

    def test_watch_needs_the_childs_own_watch(self):
        other = self.mk("Other kid")
        w2 = KidsWatch.objects.create(owner=self.parent, child_user=other,
                                      imei="8800001235", child_name="X", state="paired")
        c, reason = KA.set_consent(self.parent, self.child, self.year, watch=w2, watch_phone="017")
        self.assertEqual((c, reason), (None, "no_watch"))
