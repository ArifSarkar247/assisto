"""billapp (27 Oct) — the small server additions the app's new Credits /
Refund / Plan screens read: per-bucket detail + debt + action costs on
/credits/state, a paged /credits/history, the suggested refund shown before
a request, the refund-request rate limit, and the caller's own CRM usage on
/plans/v2. Google is always mocked (tests_billing2.PlayCase)."""
from datetime import timedelta
from decimal import Decimal

from django.core.cache import cache
from django.utils import timezone

from core import credits as CR
from core import tests_billing2 as B2
from core.models import CreditLot, PaidOrder, User
from core.payments import refunds as R
from core.tests_pay1 import _client


class CreditsStateDetailTests(B2.Base):
    def setUp(self):
        super().setUp()
        self.api = _client(self.u)

    def test_bucket_detail_debt_costs_never_cash(self):
        CR.grant(self.u, CR.PACK, 20, reason="topup", key="p1")
        CR.grant(self.u, CR.FREE, 5, key="f1")
        st = self.api.get("/api/v1/credits/state").json()
        rows = {r["bucket"]: r for r in st["bucket_detail"]}
        self.assertEqual(rows["pack"]["remaining"], 20)
        self.assertIsNone(rows["pack"]["expires_at"])        # packs never expire
        self.assertEqual(rows["free"]["remaining"], 5)
        self.assertNotIn("plan", rows)                          # empty buckets omitted
        self.assertEqual(st["debt"], 0)
        self.assertFalse(st["withdrawable"])
        self.assertEqual(st["action_costs"]["ai_msg_cheap"], 1)
        self.assertTrue(all(isinstance(v, int) for v in st["action_costs"].values()))
        self.assertNotIn("provider_cost", str(st["action_costs"]))

    def test_debt_is_positive_number(self):
        CR.grant(self.u, CR.PACK, 5, reason="topup", key="p2")
        CR.spend(self.u, 5, note="ai")
        CR.revoke_amount(self.u, 3, why="test", debt=True, key="d1")
        st = self.api.get("/api/v1/credits/state").json()
        self.assertEqual(st["debt"], 3)
        self.assertTrue(st["blocked"])
        self.assertEqual(st["balance"], -3)


class PlanLotDetailTests(B2.PlayCase):
    def test_locked_and_expiry_per_bucket(self):
        self.sub()
        self.verify("t")
        lot = CreditLot.objects.get(bucket="plan")
        st = self.api.get("/api/v1/credits/state").json()
        plan = [r for r in st["bucket_detail"] if r["bucket"] == "plan"][0]
        self.assertEqual((plan["remaining"], plan["locked"]), (18, 72))
        self.assertEqual(plan["unlocks_at"], lot.unlocks_at.isoformat())
        self.assertEqual(plan["expires_at"], lot.expires_at.isoformat())


class HistoryPagingTests(B2.Base):
    def setUp(self):
        super().setUp()
        self.api = _client(self.u)
        for i in range(7):
            CR.grant(self.u, CR.FREE, 1, key="g%d" % i)

    def test_pages_cover_every_row_once(self):
        a = self.api.get("/api/v1/credits/history?limit=3").json()
        self.assertEqual((len(a["ledger"]), a["total"], a["next_offset"]), (3, 7, 3))
        b = self.api.get("/api/v1/credits/history?limit=3&offset=3").json()
        c = self.api.get("/api/v1/credits/history?limit=3&offset=6").json()
        self.assertIsNone(c["next_offset"])
        ids = [r["id"] for r in a["ledger"] + b["ledger"] + c["ledger"]]
        self.assertEqual(len(set(ids)), 7)
        self.assertEqual(ids, sorted(ids, reverse=True))        # newest first
        self.assertIn("balance_after", a["ledger"][0])

    def test_bad_params_fall_back(self):
        r = self.api.get("/api/v1/credits/history?limit=abc&offset=-5").json()
        self.assertEqual((r["offset"], len(r["ledger"])), (0, 7))
        self.assertIn("credits_state", r)


class RefundSuggestAndRateTests(B2.PlayCase):
    def setUp(self):
        super().setUp()
        cache.clear()
        self.sub()
        self.verify("t")
        self.o = PaidOrder.objects.get()

    def test_suggested_amount_shown_before_asking(self):
        CR.spend(self.u, 9, note="ai")                           # half the usable 18
        lst = self.api.get("/api/v1/credits/refunds").json()
        row = lst["purchases"][0]
        self.assertTrue(row["eligible"])
        self.assertEqual(Decimal(row["suggested"]), Decimal("179.10"))   # 199 x (81/90)
        self.assertEqual(row["usage"]["credits_used"], 9)
        self.assertIn("days_share", row["usage"])

    def test_not_eligible_has_no_suggestion(self):
        PaidOrder.objects.filter(pk=self.o.pk).update(
            purchased_at=timezone.now() - timedelta(hours=60))
        row = self.api.get("/api/v1/credits/refunds").json()["purchases"][0]
        self.assertEqual((row["eligible"], row["reason"], row["suggested"]),
                         (False, "outside_window", None))

    def test_rate_limit_429_after_six_tries(self):
        codes = [self.api.post("/api/v1/credits/refunds", {"purchase_id": 999999},
                               format="json").status_code for _ in range(R.RATE_PER_HOUR + 1)]
        self.assertEqual(codes[:R.RATE_PER_HOUR], [404] * R.RATE_PER_HOUR)
        self.assertEqual(codes[-1], 429)
        r = self.api.post("/api/v1/credits/refunds", {"purchase_id": self.o.pk}, format="json")
        self.assertEqual((r.status_code, r.json()["reason"]), (429, "rate_limited"))
        self.assertTrue(r.json()["message"])
        self.assertIn("policy", r.json())

    def test_rate_limit_is_per_user(self):
        for _ in range(R.RATE_PER_HOUR + 1):
            self.api.post("/api/v1/credits/refunds", {"purchase_id": 999999}, format="json")
        other = User.objects.create_user(name="Other", phone="01711005099", password="x")
        r = _client(other).post("/api/v1/credits/refunds", {"purchase_id": 999999},
                                format="json")
        self.assertEqual(r.status_code, 404)


class OwnCrmUsageTests(B2.Base):
    def test_own_crm_contacts_only_for_org_owner(self):
        api = _client(self.u)
        self.assertNotIn("own_crm_contacts", api.get("/api/v1/plans/v2").json())
        from crm.models import CrmOrg, Contact
        org = CrmOrg.objects.create(name="Shop", owner=self.u)
        Contact.objects.create(org=org, name="A")
        j = api.get("/api/v1/plans/v2").json()
        self.assertEqual(j["own_crm_contacts"]["used"], 1)
        self.assertIn("limit", j["own_crm_contacts"])
