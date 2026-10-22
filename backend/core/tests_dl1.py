"""dl1 — account-deletion UX (idempotent request, no raw links/tokens in any
user-visible text, in-app cancel, "Delete now and start fresh" on sign-in
during the grace period) + the owner's "Free calls (testing)" switch."""
from datetime import timedelta
from unittest import mock

from django.core import mail
from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient, APITestCase

from core.models import (AccountDeletionRequest, AuditLog, CallRecord,
                         CallSession, CircleGroup, CircleGroupMember,
                         CircleMember, CreditLedger, FamilyAlert, MemoryItem,
                         NotifEvent, User)

V = "/api/v1"


def _sms_on():
    from core import integrations
    from core.models import Integration
    integrations.save("sms", {"provider": "bulksmsbd", "api_key": "k"})
    Integration.objects.filter(slug="sms").update(status="working")


# ===========================================================================
# A. Account deletion UX
# ===========================================================================
class DeletionUxTests(APITestCase):
    PW = "x123456"

    def setUp(self):
        self.user = User.objects.create_user(
            name="Owner", phone="01970000011", email="owner@example.com",
            password=self.PW)
        self.peer = User.objects.create_user(
            name="Peer", phone="01970000012", email="peer@example.com",
            password=self.PW)
        CircleMember.objects.create(user=self.user, peer_user=self.peer,
                                    name="Peer", state="accepted",
                                    phone="01970000012")
        MemoryItem.objects.create(user=self.user, title="secret note")
        self.client.force_authenticate(user=self.user)
        self.pushes = []
        p = mock.patch("core.push.safe_push",
                       side_effect=lambda *a, **k: self.pushes.append((a, k)))
        p.start()
        self.addCleanup(p.stop)

    def _request(self, **over):
        body = {"password": self.PW}
        body.update(over)
        return self.client.post(f"{V}/account/delete/request", body, format="json")

    # -- 1. idempotent ------------------------------------------------------
    def test_second_request_returns_same_pending_without_new_notices(self):
        r1 = self._request()
        self.assertEqual(r1.status_code, 200, r1.data)
        self.assertNotIn("already_pending", r1.data)
        req = AccountDeletionRequest.objects.get(user=self.user)
        token, eff = req.cancel_token, req.effective_at
        n_notif, n_mail, n_push = (NotifEvent.objects.count(), len(mail.outbox),
                                   len(self.pushes))
        self.assertGreater(n_notif, 0)
        r2 = self._request()
        self.assertEqual(r2.status_code, 200, r2.data)
        self.assertTrue(r2.data["already_pending"])
        self.assertEqual(r2.data["effective_at"], r1.data["effective_at"])
        self.assertEqual(r2.data["id"], r1.data["id"])
        req.refresh_from_db()
        self.assertEqual((req.cancel_token, req.effective_at), (token, eff))
        self.assertEqual(NotifEvent.objects.count(), n_notif)
        self.assertEqual(len(mail.outbox), n_mail)
        self.assertEqual(len(self.pushes), n_push)
        self.assertEqual(FamilyAlert.objects.count(), 0)

    def test_after_cancel_a_new_request_schedules_again(self):
        self._request()
        self.client.post(f"{V}/account/delete/cancel", {}, format="json")
        r = self._request()
        self.assertEqual(r.status_code, 200, r.data)
        self.assertNotIn("already_pending", r.data)
        self.assertEqual(AccountDeletionRequest.objects.get(user=self.user).state,
                         "pending")

    # -- 2. no raw link / token anywhere a user can see ---------------------
    def test_no_link_or_token_in_any_user_visible_text(self):
        self._request()
        token = AccountDeletionRequest.objects.get(user=self.user).cancel_token
        self.assertTrue(token)
        texts = []
        for e in NotifEvent.objects.all():
            texts += [e.title_bn, e.title_en, e.body_bn, e.body_en, str(e.meta)]
        for fa in FamilyAlert.objects.all():
            texts += [fa.title, fa.body, str(fa.payload)]
        for m in mail.outbox:
            texts += [m.subject, m.body]
        for a, k in self.pushes:
            texts += [str(x) for x in a] + [str(k)]
        self.assertTrue(texts)
        blob = "\n".join(texts)
        self.assertNotIn(token, blob)
        self.assertNotIn("assisto://", blob)
        self.assertNotIn("token=", blob)
        self.assertNotIn("cancel_token", blob)

    def test_owner_notice_routes_to_cancel_screen_bilingual(self):
        self._request()
        e = NotifEvent.objects.get(user=self.user)
        self.assertEqual(e.route, "account/delete")
        self.assertEqual(e.meta["action"], "cancel_deletion")
        self.assertTrue(e.title_bn and e.title_en and e.body_bn and e.body_en)
        self.assertIn("Cancel deletion", e.body_en)
        self.assertIn("মুছে ফেলা বাতিল করুন", e.body_bn)

    def test_circle_contact_gets_neutral_notice(self):
        self._request()
        e = NotifEvent.objects.get(user=self.peer)
        self.assertEqual(e.route, "")
        self.assertEqual(e.meta, {"kind": "account_delete_circle"})
        self.assertIn("Owner", e.title_en)
        self.assertNotIn("Cancel", e.body_en)
        peer_mail = [m for m in mail.outbox if "peer@example.com" in m.to]
        self.assertEqual(len(peer_mail), 1)

    # -- cancel (authed) ----------------------------------------------------
    def test_cancel_authed_from_the_app(self):
        self._request()
        r = self.client.post(f"{V}/account/delete/cancel", {}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data["state"], "cancelled")
        st = self.client.get(f"{V}/account/delete/status")
        self.assertEqual(st.data["state"], "cancelled")
        self.assertTrue(AuditLog.objects.filter(
            user=self.user, action="account.delete.cancel").exists())

    def test_status_says_whether_otp_is_needed(self):
        self._request()
        st = self.client.get(f"{V}/account/delete/status")
        self.assertEqual(st.data["state"], "pending")
        self.assertFalse(st.data["otp_required"])
        _sms_on()
        st = self.client.get(f"{V}/account/delete/status")
        self.assertTrue(st.data["otp_required"])

    # -- 3. sign-in during the grace period ---------------------------------
    def test_login_then_restore_keeps_everything(self):
        self._request()
        api = APIClient()
        r = api.post(f"{V}/auth/login", {"identifier": "01970000011",
                                         "password": self.PW}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        api.credentials(HTTP_AUTHORIZATION="Token " + r.data["token"])
        st = api.get(f"{V}/account/delete/status")
        self.assertEqual(st.data["state"], "pending")
        c = api.post(f"{V}/account/delete/cancel", {}, format="json")
        self.assertEqual(c.data["state"], "cancelled")
        self.assertTrue(MemoryItem.objects.filter(user=self.user).exists())

    def test_start_fresh_purges_and_returns_a_clean_account(self):
        self._request()
        old_id = self.user.id
        r = self.client.post(f"{V}/account/delete/start-fresh",
                             {"password": self.PW, "confirm_text": "DELETE"},
                             format="json")
        self.assertEqual(r.status_code, 201, r.data)
        self.assertTrue(r.data["start_fresh"])
        self.assertFalse(User.objects.filter(id=old_id).exists())
        self.assertFalse(MemoryItem.objects.filter(user_id=old_id).exists())
        new = User.objects.get(phone=self.user.phone)
        self.assertNotEqual(new.id, old_id)
        self.assertEqual(new.name, "Owner")
        self.assertFalse(MemoryItem.objects.filter(user=new).exists())
        self.assertFalse(AccountDeletionRequest.objects.filter(user=new).exists())
        a = AuditLog.objects.get(user=new, action="account.delete.start_fresh")
        self.assertEqual(a.detail["old_user_id"], old_id)
        # the returned token works and the same password signs in
        api = APIClient()
        api.credentials(HTTP_AUTHORIZATION="Token " + r.data["token"])
        self.assertEqual(api.get(f"{V}/me").status_code, 200)
        lr = APIClient().post(f"{V}/auth/login", {"identifier": "01970000011",
                                                  "password": self.PW},
                              format="json")
        self.assertEqual(lr.status_code, 200, lr.data)
        self.assertEqual(lr.data["user"]["id"], new.id)

    def test_start_fresh_bangla_confirm_word_accepted(self):
        self._request()
        r = self.client.post(f"{V}/account/delete/start-fresh",
                             {"password": self.PW, "confirm_text": "মুছুন"},
                             format="json")
        self.assertEqual(r.status_code, 201, r.data)

    def test_start_fresh_needs_pending_confirm_and_password(self):
        r = self.client.post(f"{V}/account/delete/start-fresh",
                             {"password": self.PW, "confirm_text": "DELETE"},
                             format="json")
        self.assertEqual(r.status_code, 409)
        self._request()
        r = self.client.post(f"{V}/account/delete/start-fresh",
                             {"password": self.PW, "confirm_text": "ok"},
                             format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (400, "confirm_required"))
        r = self.client.post(f"{V}/account/delete/start-fresh",
                             {"password": "nope", "confirm_text": "DELETE"},
                             format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (403, "bad_password"))
        self.assertTrue(User.objects.filter(id=self.user.id).exists())

    def test_start_fresh_requires_otp_when_sms_connected(self):
        self._request()
        _sms_on()
        r = self.client.post(f"{V}/account/delete/start-fresh",
                             {"password": self.PW, "confirm_text": "DELETE"},
                             format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (403, "otp_required"))
        self.assertTrue(User.objects.filter(id=self.user.id).exists())

    def test_start_fresh_blocked_by_theft_signal(self):
        from core.logic import security as sec
        from core.models import ProtectedPhone
        self._request()
        ph = ProtectedPhone.objects.create(owner=self.user)
        sec.register_signal(ph, "snatch", timezone.now())
        ph.save()
        r = self.client.post(f"{V}/account/delete/start-fresh",
                             {"password": self.PW, "confirm_text": "DELETE"},
                             format="json")
        self.assertEqual(r.status_code, 423)
        self.assertTrue(User.objects.filter(id=self.user.id).exists())

    # -- web path is idempotent too -----------------------------------------
    def test_web_schedule_keeps_existing_pending_date(self):
        from core.models import WebDeletionRequest
        from web import legal_deletion as LD
        self._request()
        req = AccountDeletionRequest.objects.get(user=self.user)
        eff, n = req.effective_at, NotifEvent.objects.count()
        WebDeletionRequest.objects.create(
            contact="01970000011", contact_kind="phone", matched_user=self.user,
            status=WebDeletionRequest.STATUS_VERIFIED)
        done, skipped = LD.schedule_verified(WebDeletionRequest.objects.all())
        self.assertEqual((done, skipped), (1, 0))
        req.refresh_from_db()
        self.assertEqual(req.effective_at, eff)
        self.assertEqual(NotifEvent.objects.count(), n)


# ===========================================================================
# B. Free calls (testing)
# ===========================================================================
class _CallsBase(TestCase):
    def setUp(self):
        self.a = User.objects.create_user(name="Amina", phone="01740000201",
                                          password="pw12345!", language="en")
        self.b = User.objects.create_user(name="Babu", phone="01740000202",
                                          password="pw12345!", language="en")
        self.ab = CircleMember.objects.create(
            user=self.a, peer_user=self.b, name="Babu", state="accepted",
            phone="01740000202")
        CircleMember.objects.create(
            user=self.b, peer_user=self.a, name="Amina", state="accepted",
            direction="incoming", phone="01740000201")
        self.ca = APIClient()
        self.ca.force_authenticate(self.a)
        self.credits0 = self.a.ai_credits

    def place(self, kind):
        return self.ca.post(f"{V}/circle/{self.ab.id}/call", {"kind": kind},
                            format="json")

    def group_call(self, kind):
        g = CircleGroup.objects.create(creator=self.a, name="Fam")
        CircleGroupMember.objects.create(group=g, member=self.a, role="admin")
        CircleGroupMember.objects.create(group=g, member=self.b)
        return self.ca.post(f"{V}/circle/groups/{g.id}/call", {"kind": kind},
                            format="json")

    def assert_no_debit(self):
        self.a.refresh_from_db()
        self.assertEqual(self.a.ai_credits, self.credits0)
        self.assertFalse(CreditLedger.objects.filter(user=self.a, delta__lt=0).exists())


@override_settings(CALLS_FREE_TESTING_DEFAULT=True, TURN_STATIC_SECRET="")
class FreeCallsOnTests(_CallsBase):
    def test_free_plan_video_call_allowed_no_paywall_no_debit(self):
        r = self.place("video")
        self.assertEqual(r.status_code, 201, r.content)
        j = r.json()
        self.assertTrue(j["allowed"])
        self.assertTrue(j["calls_free"])
        self.assertNotIn("prompt", j)
        self.assertNotIn("upgrade_required", j)
        self.assertTrue(CallRecord.objects.get(pk=j["call_id"]).free_testing)
        self.assert_no_debit()

    def test_voice_call_free_and_marked(self):
        r = self.place("voice")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertTrue(r.json()["calls_free"])
        self.assertTrue(CallRecord.objects.get(pk=r.json()["call_id"]).free_testing)
        self.assert_no_debit()

    def test_group_video_free_for_free_plan(self):
        r = self.group_call("video")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertTrue(r.json()["allowed"])
        self.assertTrue(r.json()["calls_free"])
        self.assert_no_debit()

    def test_messenger_group_call_and_link_free(self):
        c = User.objects.create_user(name="Chandni", phone="01740000203",
                                     password="pw12345!")
        CircleMember.objects.create(user=self.a, peer_user=self.b, name="x",
                                    state="pending", phone="01740000209")
        ac = CircleMember.objects.create(user=self.a, peer_user=c, name="Chandni",
                                         state="accepted", phone="01740000203")
        r = self.ca.post(f"{V}/messenger/group-call",
                         {"invitee_member_ids": [ac.id], "kind": "video"},
                         format="json")
        self.assertEqual(r.status_code, 200, r.content)
        r = self.ca.post(f"{V}/messenger/call-link", {"kind": "video"},
                         format="json")
        self.assertEqual(r.status_code, 200, r.content)

    def test_plans_catalogue_says_calls_free(self):
        rows = self.ca.get(f"{V}/plans").json()
        self.assertTrue(rows and all(r.get("calls_free") for r in rows))

    def test_relay_cost_still_recorded_and_labelled_free(self):
        from core import turn_monitor as M
        from core.models import TurnRelayUsage
        cid = self.place("video").json()["call_id"]
        CallRecord.objects.filter(pk=cid).update(duration_sec=600, state="ended")
        CallSession.objects.filter(call_id=cid).update(relayed=True)
        TurnRelayUsage.objects.create(at=timezone.now(), user_id=self.a.id,
                                      bytes_out=50_000_000, call_kind="video",
                                      call_id=cid)
        cost = M.relay_cost(30)
        v = cost["rows"]["video"]
        self.assertEqual(v["relayed_min"], 10.0)
        self.assertEqual(v["free_min"], 10.0)
        self.assertGreater(v["total_bdt"], 0)
        self.assertEqual(v["free_bdt"], v["total_bdt"])
        self.assertTrue(cost["calls_free_now"])
        self.assertGreater(cost["free_testing_bdt"], 0)

    def test_flags_console_shows_effective_value_and_flip_is_audited(self):
        from core.calls_free import calls_free
        from core.views_build61 import flags_flip, flags_snapshot
        f = next(x for x in flags_snapshot()["flags"] if x["id"] == "calls_free_testing")
        self.assertTrue(f["value"])
        ok, _ = flags_flip(self.a.id, "calls_free_testing", False, "")
        self.assertFalse(ok)                       # cost switch -> reason needed
        ok, snap = flags_flip(self.a.id, "calls_free_testing", False, "launch")
        self.assertTrue(ok)
        self.assertFalse(calls_free())
        self.assertEqual(snap["audit"][0]["flag"], "calls_free_testing")
        r = self.place("video")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()["upgrade_required"])


@override_settings(CALLS_FREE_TESTING_DEFAULT=False, TURN_STATIC_SECRET="")
class FreeCallsOffTests(_CallsBase):
    def test_video_needs_premium_again(self):
        r = self.place("video")
        self.assertEqual(r.status_code, 200, r.content)
        j = r.json()
        self.assertFalse(j["allowed"])
        self.assertTrue(j["upgrade_required"])
        self.assertIn("prompt", j)
        r = self.group_call("video")
        self.assertTrue(r.json()["upgrade_required"])

    def test_voice_still_free_but_not_marked(self):
        r = self.place("voice")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertFalse(r.json()["calls_free"])
        self.assertFalse(CallRecord.objects.get(pk=r.json()["call_id"]).free_testing)
        self.assert_no_debit()

    def test_owner_turns_it_on(self):
        from core.calls_free import calls_free
        from core.views_build61 import flags_flip
        ok, _ = flags_flip(self.a.id, "calls_free_testing", True, "beta test")
        self.assertTrue(ok)
        self.assertTrue(calls_free())
        self.assertEqual(self.place("video").status_code, 201)
