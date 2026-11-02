"""callsbar (owner 2 Nov: calls to the launch bar).

* POST circle/calls/<id>/quality — one report per call per side, metrics
  clamped, a later one-tap rating merges into the same row, strangers 404.
* call_quality.summary — the Owner Admin numbers (bad %, issues, medians,
  data per minute, relay / low-data share) + the Owner Admin card renders.
* GET circle/groups/<id>/members — circle_member_id: MY accepted edge to each
  co-member, so the honest "group call not ready — call one person" sheet can
  start a real 1:1 call in one tap; blocked / not-in-circle -> null.
"""
from django.test import TestCase, override_settings
from rest_framework.test import APIClient

from core import call_quality as Q
from core.models import (CallQualityReport, CallRecord, CircleGroup,
                         CircleGroupMember, CircleMember, User)

V = "/api/v1"


def _user(name, phone):
    return User.objects.create_user(name=name, phone=phone,
                                    password="pw12345!", language="en")


@override_settings(FCM_SERVICE_ACCOUNT_FILE="", PUSH_SYNC=True,
                   TURN_STATIC_SECRET="")
class QualityReportTests(TestCase):
    def setUp(self):
        self.a = _user("Amina", "01740000201")
        self.b = _user("Babu", "01740000202")
        self.c = _user("Chaya", "01740000203")
        self.rec = CallRecord.objects.create(caller=self.a, callee=self.b,
                                             kind="voice", state="ended")
        self.ca, self.cb, self.cc = APIClient(), APIClient(), APIClient()
        self.ca.force_authenticate(self.a)
        self.cb.force_authenticate(self.b)
        self.cc.force_authenticate(self.c)

    def post(self, client, body, cid=None):
        return client.post(f"{V}/circle/calls/{cid or self.rec.id}/quality",
                           body, format="json")

    def test_metrics_then_rating_merge_into_one_row(self):
        r = self.post(self.ca, {"rtt_ms": 180.4, "loss_pct": 3.25,
                                "jitter_ms": 22, "min_kbps": 41,
                                "relayed": True, "low_data": False,
                                "net": "cellular", "talk_s": 125,
                                "data_kb": 610, "reconnects": 1})
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["report"]["rating"], "")
        r = self.post(self.ca, {"rating": "bad", "issue": "choppy"})
        self.assertEqual(r.status_code, 200, r.content)
        rows = CallQualityReport.objects.filter(call=self.rec, user=self.a)
        self.assertEqual(rows.count(), 1)
        row = rows.get()
        self.assertEqual((row.rating, row.issue, row.side),
                         ("bad", "choppy", "caller"))
        self.assertEqual((row.rtt_ms, row.loss_pct, row.min_kbps), (180, 3.25, 41))
        self.assertTrue(row.relayed)
        self.assertEqual((row.net, row.talk_s, row.data_kb, row.reconnects),
                         ("cellular", 125, 610, 1))

    def test_each_side_has_its_own_row(self):
        self.post(self.ca, {"rating": "good"})
        r = self.post(self.cb, {"rating": "good"})
        self.assertEqual(r.status_code, 200)
        self.assertEqual(CallQualityReport.objects.filter(call=self.rec).count(), 2)
        self.assertEqual(CallQualityReport.objects.get(user=self.b).side, "callee")

    def test_stranger_and_unknown_call_404(self):
        self.assertEqual(self.post(self.cc, {"rating": "good"}).status_code, 404)
        self.assertEqual(self.post(self.ca, {"rating": "good"},
                                   cid=999999).status_code, 404)
        self.assertFalse(CallQualityReport.objects.exists())

    def test_hostile_values_are_clamped_or_dropped(self):
        r = self.post(self.ca, {"rating": "great", "issue": "x" * 50,
                                "rtt_ms": -5, "loss_pct": 999,
                                "jitter_ms": "abc", "data_kb": 10 ** 12,
                                "net": "5g-ultra", "relayed": "false"})
        self.assertEqual(r.status_code, 200, r.content)
        row = CallQualityReport.objects.get()
        self.assertEqual(row.rating, "")          # unknown rating dropped
        self.assertEqual(row.issue, "")
        self.assertEqual(row.rtt_ms, 0)
        self.assertEqual(row.loss_pct, 100.0)
        self.assertIsNone(row.jitter_ms)
        self.assertEqual(row.data_kb, Q._MAX_DATA_KB)
        self.assertEqual(row.net, "other")
        self.assertFalse(row.relayed)

    def test_good_rating_never_keeps_an_issue(self):
        self.post(self.ca, {"rating": "good", "issue": "echo"})
        self.assertEqual(CallQualityReport.objects.get().issue, "")

    def test_live_call_report_is_accepted(self):
        live = CallRecord.objects.create(caller=self.a, callee=self.b,
                                         kind="voice", state="active")
        self.assertEqual(self.post(self.ca, {"talk_s": 10}, cid=live.id)
                         .status_code, 200)

    def test_summary_numbers(self):
        rec2 = CallRecord.objects.create(caller=self.a, callee=self.b,
                                         kind="video", state="ended")
        Q.record(self.rec, self.a, "caller", {
            "rating": "good", "rtt_ms": 100, "loss_pct": 1, "talk_s": 60,
            "data_kb": 240, "net": "wifi"})
        Q.record(self.rec, self.b, "callee", {
            "rating": "bad", "issue": "echo", "rtt_ms": 300, "loss_pct": 5,
            "talk_s": 60, "data_kb": 120, "low_data": True, "relayed": True,
            "net": "cellular", "reconnects": 2})
        Q.record(rec2, self.a, "caller", {
            "video": True, "talk_s": 120, "data_kb": 6000,
            "video_paused_s": 14})
        s = Q.summary(7)
        self.assertEqual((s["reports"], s["rated"], s["good"], s["bad"]),
                         (3, 2, 1, 1))
        self.assertEqual(s["bad_pct"], 50)
        self.assertEqual(s["issues"], [("echo", 1)])
        self.assertEqual(s["rtt_median"], 200.0)
        self.assertEqual(s["voice_kb_min"], 180)   # (240+120) KB / 2 min
        self.assertEqual(s["video_kb_min"], 3000)
        self.assertEqual(s["relayed_pct"], 33)
        self.assertEqual(s["low_data_pct"], 33)
        self.assertEqual(s["video_paused_calls"], 1)
        self.assertEqual(s["reconnect_calls"], 1)
        self.assertEqual(s["nets"], {"wifi": 1, "cellular": 1, "other": 0})

    def test_summary_empty(self):
        s = Q.summary(7)
        self.assertEqual(s["reports"], 0)
        self.assertIsNone(s["bad_pct"])
        self.assertIsNone(s["rtt_median"])


class GroupMembersCallEdgeTests(TestCase):
    def setUp(self):
        self.a = _user("Amina", "01740000301")
        self.b = _user("Babu", "01740000302")
        self.c = _user("Chaya", "01740000303")
        self.d = _user("Dipu", "01740000304")
        # a <-> b by peer_user; a -> c by phone only; a -> d blocked
        self.ab = CircleMember.objects.create(
            user=self.a, peer_user=self.b, name="Babu", state="accepted",
            phone="01740000302")
        self.ac = CircleMember.objects.create(
            user=self.a, name="Chaya", state="accepted", phone="+8801740000303")
        CircleMember.objects.create(user=self.a, peer_user=self.d, name="Dipu",
                                    state="accepted", blocked=True,
                                    phone="01740000304")
        self.g = CircleGroup.objects.create(creator=self.a, name="Family")
        for u, role in ((self.a, "admin"), (self.b, "member"),
                        (self.c, "member"), (self.d, "member")):
            CircleGroupMember.objects.create(group=self.g, member=u, role=role)
        self.client_a = APIClient()
        self.client_a.force_authenticate(self.a)

    def test_roster_carries_my_edge_per_member(self):
        r = self.client_a.get(f"{V}/circle/groups/{self.g.id}/members")
        self.assertEqual(r.status_code, 200, r.content)
        body = r.json()
        rows = body.get("results") or body.get("members") or body
        by_user = {row["user_id"]: row for row in rows}
        self.assertEqual(by_user[self.b.id]["circle_member_id"], self.ab.id)
        self.assertEqual(by_user[self.c.id]["circle_member_id"], self.ac.id)
        self.assertIsNone(by_user[self.d.id]["circle_member_id"])   # blocked
        self.assertIsNone(by_user[self.a.id]["circle_member_id"])   # me

    def test_other_viewer_gets_their_own_edges(self):
        cb = APIClient()
        cb.force_authenticate(self.b)
        r = cb.get(f"{V}/circle/groups/{self.g.id}/members")
        self.assertEqual(r.status_code, 200, r.content)
        body = r.json()
        rows = body.get("results") or body.get("members") or body
        # b has no circle edges at all: nobody is one-tap callable
        self.assertTrue(all(row["circle_member_id"] is None for row in rows))


class OwnerCallQualityCardTests(TestCase):
    def test_summary_is_safe_and_card_strings_exist(self):
        from web.owner import i18n
        for lang in ("en", "bn"):
            T = i18n.strings(lang)
            for k in ("cq_title", "cq_note", "cq_empty", "cq_issue_echo",
                      "cq_issue_choppy", "cq_relayed", "cq_low_data"):
                self.assertTrue(T[k], (lang, k))
        self.assertIsNotNone(Q.summary(7))
