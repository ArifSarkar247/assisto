"""adwire (OWNER FINAL ADS ORDER 10 Nov 03:45, part D) — server side of the
four newly wired placements:

* ai_chat_unlock: POST /credits/rewarded/ticket {"placement": "ai_chat_unlock"}
  obeys the owner's live Ad control switch (reason "placement_off"); no
  placement / "credits" keeps the earlier watch-to-earn path; Premium never.
* city_more_routes: GET /maps/transit?peek=1 is a READ-ONLY budget check
  (counts nothing, calls Google never) so a Free user is never asked to watch
  an ad for a Google request the budget would refuse; over budget / key off
  -> "none" (never a limit message).
Sample data only; CI makes no real Google call."""
from unittest import mock

from core import billing
from core import maps_cost as MC
from core.models import MapsUsage
from core.tests_admob import _Base
from core.tests_journey100 import V
from core.tests_mapapp import TransitRec
from core.tests_mapscost import MapsBase


def _switch(key, on):
    row = billing.get_config()
    data = dict(row.data or {})
    data["ad_control"] = {"placements": {key: {"on": on}}}
    row.data = data
    row.save()


class AiChatUnlockTicketTests(_Base):
    def setUp(self):
        super().setUp()
        for p in (mock.patch("core.sponsor_service.admob_real", return_value=True),
                  mock.patch("core.billing.flag_on", return_value=True)):
            p.start()
            self.addCleanup(p.stop)

    def ticket(self, user=None, **body):
        self.client.force_authenticate(user or self.free)
        return self.client.post("/api/v1/credits/rewarded/ticket", body, format="json").json()

    def test_switch_on_issues_a_ticket(self):
        j = self.ticket(placement="ai_chat_unlock")
        self.assertTrue(j["ok"], j)
        self.assertTrue(j["nonce"])

    def test_switch_off_no_ticket_no_ad(self):
        _switch("ai_chat_unlock", False)
        j = self.ticket(placement="ai_chat_unlock")
        self.assertFalse(j["ok"])
        self.assertEqual(j["reason"], "placement_off")
        # the watch-to-earn Credits sheet is a different placement: unaffected
        self.assertTrue(self.ticket()["ok"])

    def test_unknown_placement_is_refused(self):
        j = self.ticket(placement="made_up_spot")
        self.assertEqual(j["reason"], "placement_off")

    def test_premium_never(self):
        j = self.ticket(self.prem, placement="ai_chat_unlock")
        self.assertEqual(j["reason"], "paid_plan")


class TransitPeekTests(MapsBase):
    def setUp(self):
        super().setUp()
        self.rec = TransitRec()
        p = mock.patch.object(MC, "HTTP", self.rec)
        p.start()
        self.addCleanup(p.stop)

    Q = "olat=23.807&olng=90.368&dlat=23.728&dlng=90.419"

    def peek(self, c=None):
        return (c or self.c1).get("%s/maps/transit?peek=1" % V).json()["state"]

    def test_peek_is_ready_and_counts_nothing(self):
        self.assertEqual(self.peek(), "ready")
        self.assertEqual(self.peek(), "ready")
        self.assertEqual(self.rec.calls, [])
        self.assertEqual(MapsUsage.objects.filter(api="routes").count(), 0)

    def test_user_budget_spent_then_none(self):
        self.limits("routes", user_day=1, global_day=100)
        self.assertEqual(self.peek(), "ready")
        self.assertEqual(self.c1.get("%s/maps/transit?%s" % (V, self.Q)).json()["state"], "ok")
        self.assertEqual(self.peek(), "none")          # this user's day is spent
        self.assertEqual(self.peek(self.c2), "ready")   # another user still may

    def test_global_budget_or_key_off_is_none(self):
        self.limits("routes", user_day=10, global_day=0)
        self.assertEqual(self.peek(), "none")
        self.limits("routes", user_day=10, global_day=100)
        with mock.patch.object(MC, "server_key", lambda: ""):
            self.assertEqual(self.peek(), "none")

    def test_plan_cap_is_none(self):
        with mock.patch.object(MC, "_plan_allowed", lambda u: False):
            self.assertEqual(self.peek(), "none")
