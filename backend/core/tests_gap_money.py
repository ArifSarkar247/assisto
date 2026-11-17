"""gap-money — feature gap lane for Mess and Money (owner order 17 Nov 10:10).

Every gap fixed here gets a test (owner_actions/gaps/money_BN.md):
  * the mess month PDF draws Bangla through pdf_bn (shaped, real table);
  * a due reminder is never sent to someone who already paid after the close,
    and a part-payment reminds only the amount still left.
"""
from django.test import SimpleTestCase

from core.models import MessMember

from .tests_messv2 import V, _Base


class MessPdfBanglaTests(_Base):
    def _month(self):
        m = self.make_mess()
        mid = m["id"]
        self.add(mid, self.eb)
        self.post("a", f"/mess/v2/{mid}/entries",
                  {"kind": "bazar", "date": "2026-11-01", "amount": 100000}, 201)
        self.post("a", f"/mess/v2/{mid}/entries",
                  {"kind": "charge", "date": "2026-11-02", "amount": 70000,
                   "data": {"kind": "wifi"}}, 201)
        return mid

    def test_open_and_closed_month_pdf_use_the_shaped_bangla_face(self):
        mid = self._month()
        r = self.cl["a"].get(V + f"/mess/v2/{mid}/report?pdf=1", HTTP_ACCEPT_LANGUAGE="bn")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.content.startswith(b"%PDF"))
        self.assertIn(b"AssistoAsBn", r.content)       # pdf_bn's shaped Noto Bengali
        self.clock.set(2026, 11, 30, 23)
        self.post("a", f"/mess/v2/{mid}/close", {}, 200)
        r = self.cl["b"].get(V + f"/mess/v2/{mid}/report?month=2026-11&pdf=1",
                             HTTP_ACCEPT_LANGUAGE="bn")
        self.assertEqual(r.status_code, 200)
        self.assertIn(b"AssistoAsBn", r.content)

    def test_english_pdf_renders(self):
        mid = self._month()
        r = self.cl["a"].get(V + f"/mess/v2/{mid}/report?pdf=1", HTTP_ACCEPT_LANGUAGE="en")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.content.startswith(b"%PDF"))
        self.assertIn(b"AssistoAsLat", r.content)

    def test_pdf_builder_lines_up_with_the_math(self):
        """The table is built from the same settlement the screen shows."""
        from core import views_mess as VM
        from core.models import Mess
        mid = self._month()
        mess = Mess.objects.get(pk=mid)
        start, end = VM._period(mess, VM._today())
        s = VM.compute_month(mess, start, end)
        self.assertTrue(s["reconciles"])
        self.assertEqual(sum(r["meal_cost"] for r in s["members"]), 100000)
        self.assertEqual(sum(r["service"] for r in s["members"]), 70000)
        for lang in ("bn", "en"):
            self.assertTrue(VM._pdf(mess, "2026-11", s, lang).startswith(b"%PDF"))


class MessRemindAfterPaymentTests(_Base):
    def test_paid_member_is_not_reminded_and_part_payment_reminds_the_rest(self):
        m = self.make_mess()
        mid = m["id"]
        self.add(mid, self.eb)
        # bazar ৳1,000 -> each of the two will pay ৳500 (both ON all month)
        self.post("a", f"/mess/v2/{mid}/entries",
                  {"kind": "bazar", "date": "2026-11-01", "amount": 100000}, 201)
        self.clock.set(2026, 11, 30, 23)
        s = self.post("a", f"/mess/v2/{mid}/close", {}, 200).json()["summary"]
        dues = sorted(r["due"] for r in s["members"])
        self.assertEqual(dues, [50000, 50000])
        self.clock.set(2026, 12, 2, 10)
        self.clock.push.reset_mock()
        # B pays the whole ৳500 to the manager after the close
        self.post("b", f"/mess/v2/{mid}/entries",
                  {"kind": "deposit", "amount": 50000}, 201)
        # A pays ৳200 of ৳500
        self.post("a", f"/mess/v2/{mid}/entries",
                  {"kind": "deposit", "amount": 20000}, 201)
        n = self.post("a", f"/mess/v2/{mid}/remind", {}, 200).json()["sent"]
        self.assertEqual(n, 1)
        args = self.clock.push.call_args[0]
        self.assertEqual(args[0], self.a)
        self.assertIn("৳300.00", args[4])               # en body: only what is left
        self.assertIn("৳৩০০.০০", args[3])               # bn body in Bangla digits
        # targeted reminder to B (fully paid) sends nothing
        bid = MessMember.objects.get(mess_id=mid, user=self.b).id
        n = self.post("a", f"/mess/v2/{mid}/remind", {"member_id": bid}, 200).json()["sent"]
        self.assertEqual(n, 0)


class ServerParserTests(SimpleTestCase):
    """Money typed in any common way is read to the exact poisha."""

    def test_khata_refuses_an_exponent_instead_of_guessing(self):
        from core.logic import business_khata as K
        self.assertEqual(K.to_poisha("1e3"), 0)           # was ৳13
        self.assertEqual(K.to_poisha("৳১,২৫০.৫০"), 125050)
        self.assertEqual(K.to_poisha("Tk 500"), 50000)

    def test_landlord_commas_and_half_up(self):
        from core.logic import landlord_tenant as LT
        self.assertEqual(LT.to_poisha("1,500"), 150000)  # was 0
        self.assertEqual(LT.to_poisha("12.345"), 1235)   # was 1234 (half-even)
        self.assertEqual(LT.to_poisha("১২০০০.৫০"), 1200050)
        self.assertEqual(LT.to_poisha("NaN"), 0)
        self.assertEqual(LT.to_poisha("bad"), 0)


class MessProRateTests(_Base):
    """Service bills pro-rated by days in the mess, exact to the poisha."""

    def _rows(self, mid):
        return {x["id"]: x for x in self.get("a", f"/mess/v2/{mid}")["summary"]["members"]}

    def test_mid_month_join_pays_only_for_days_present(self):
        mid = self.make_mess()["id"]
        self.add(mid, self.eb)
        self.clock.set(2026, 11, 21, 10)
        self.add(mid, self.ec)                                   # joins on the 21st
        self.post("a", f"/mess/v2/{mid}/entries",
                  {"kind": "charge", "date": "2026-11-21", "amount": 90000,
                   "data": {"kind": "wifi"}}, 201)
        ids = {k: self.member_id(mid, getattr(self, k)) for k in "abc"}
        rows = self._rows(mid)
        # days 30 / 30 / 10 of ৳900: 385.72 + 385.71 + 128.57 = 900.00 exactly
        self.assertEqual(rows[ids["c"]]["service"], 12857)
        self.assertEqual(sorted(rows[ids[k]]["service"] for k in "ab"), [38571, 38572])
        self.clock.set(2026, 11, 30, 23)
        s = self.post("a", f"/mess/v2/{mid}/close", {}, 200).json()["summary"]
        self.assertTrue(s["reconciles"])
        self.assertEqual(sum(r["service"] for r in s["members"]), 90000)

    def test_mid_month_leave_and_rent_by_seat_times_days(self):
        mid = self.make_mess()["id"]
        self.add(mid, self.eb)
        ids = {k: self.member_id(mid, getattr(self, k)) for k in "ab"}
        self.post("a", f"/mess/v2/{mid}/members/{ids['a']}", {"action": "seat_share", "value": 2}, 200)
        self.clock.set(2026, 11, 10, 10)
        self.post("a", f"/mess/v2/{mid}/members/{ids['b']}", {"action": "remove"}, 200)
        # B is in Nov 1-10 (left from the 11th): 10 days; A 30 days
        self.post("a", f"/mess/v2/{mid}/entries",
                  {"kind": "charge", "date": "2026-11-10", "amount": 80000,
                   "data": {"kind": "khala"}}, 201)
        self.post("a", f"/mess/v2/{mid}/entries",
                  {"kind": "charge", "date": "2026-11-10", "amount": 700000,
                   "data": {"kind": "rent", "split": "seat"}}, 201)
        rows = self._rows(mid)
        # khala equal by days 30:10 -> 600 / 200; rent seat×days 60:10 -> 6000 / 1000
        self.assertEqual(rows[ids["a"]]["service"], 60000 + 600000)
        self.assertEqual(rows[ids["b"]]["service"], 20000 + 100000)


class ProRateMathTests(SimpleTestCase):
    def test_full_month_is_unchanged_and_shares_sum_exactly(self):
        import datetime as dt

        from core.logic import mess_v2 as M
        s, e = dt.date(2026, 11, 1), dt.date(2026, 11, 30)
        full = [{"id": i, "seat_share": 1, "joined_on": s, "left_on": None} for i in (1, 2, 3)]
        self.assertEqual(M.charge_shares({"amount": 100}, full, (s, e)),
                         M.charge_shares({"amount": 100}, full))
        mixed = full[:2] + [{"id": 3, "seat_share": 1, "joined_on": dt.date(2026, 11, 30),
                             "left_on": None}]
        for amt in (1, 7, 99999, 1234567):
            self.assertEqual(sum(M.charge_shares({"amount": amt}, mixed, (s, e)).values()), amt)
        self.assertEqual(M.days_present(mixed[2], s, e), 1)
        self.assertEqual(M.days_present({"joined_on": s, "left_on": dt.date(2026, 11, 11)}, s, e), 10)


class OfflineMealCutoffTests(_Base):
    """A meal change saved offline BEFORE the cut-off counts when it syncs
    after it — bounded and checked by the server, never an open door."""

    def setUp(self):
        super().setUp()
        self.mid = self.make_mess()["id"]
        self.add(self.mid, self.eb)

    def meal(self, saved_at=None, cid="off-1", code=200):
        body = {"date": "2026-11-03", "b": 0}
        if cid:
            body["client_id"] = cid
        if saved_at:
            body["saved_at"] = saved_at
        return self.post("b", f"/mess/v2/{self.mid}/meals", body, code)

    def test_saved_before_cutoff_syncs_late_and_is_marked_in_history(self):
        self.clock.set(2026, 11, 2, 23, 30)                     # cut-off was 22:00
        self.meal(code=409)                                      # no saved-at: too late
        self.meal("2026-11-02T22:10:00+06:00", code=409)         # saved after the cut-off
        self.meal("2026-11-02T21:30:00+06:00", cid="", code=409)  # not from the outbox
        self.meal("2026-11-02T21:30:00+06:00")                   # saved 21:30 offline -> OK
        from core.models import MessEntry
        e = MessEntry.objects.get(mess_id=self.mid, kind="meal", date="2026-11-03")
        self.assertEqual(e.data["b"], 0)
        h = self.get("a", f"/mess/v2/{self.mid}/history")["results"]
        self.assertTrue(any("offline_saved_at" in (x["after"] or {}) for x in h))

    def test_bounded_never_more_than_24h_late_and_no_future_clock(self):
        self.clock.set(2026, 11, 3, 22, 30)                      # 24.5 h after the cut-off
        self.meal("2026-11-02T21:30:00+06:00", code=409)
        self.clock.set(2026, 11, 2, 23, 0)
        self.meal("2026-11-02T23:30:00+06:00", code=409)         # "saved" after the cut-off
        self.meal("not-a-time", code=409)


class RemittanceHalfUpTests(SimpleTestCase):
    def test_paisa_and_percent_round_half_up(self):
        from decimal import Decimal

        from core import remittance_service as RS
        from core.logic import remittance as RL
        self.assertEqual(RS._money("12.345", "amount"), Decimal("12.35"))   # was 12.34
        self.assertEqual(RS._money("12.335", "amount"), Decimal("12.34"))
        lines = {x["key"]: x for x in RL.plan_vs_actual(
            {"food": 200}, [{"kind": "expense", "date": "2026-11-05", "amount": "25",
                             "category": "food"}], "2026-11")}
        self.assertEqual(lines["food"]["pct"], 13)                           # 12.5 % -> 13


class NetWorthInvariantTests(_Base):
    """Net worth hero == assets + receivable − liabilities for the SAME as-of
    date, on both pages, exact to the poisha (lead review of design3 shot)."""

    def _setup_money(self):
        from decimal import Decimal as Dm

        from core.models import Account, Loan, SavingsGoal, Transaction
        import datetime as dt
        cash = Account.objects.create(user=self.a, name="Cash", opening_balance=Dm("10000.10"))
        bk = Account.objects.create(user=self.a, name="bKash", acc_type="bkash",
                                    opening_balance=Dm("5000.00"))
        day = dt.date(2026, 11, 2)
        Transaction.objects.create(user=self.a, account=cash, kind="income", amount=Dm("8000.45"), date=day)
        Transaction.objects.create(user=self.a, account=cash, kind="expense", amount=Dm("2200.55"), date=day)
        # my own money moved cash -> bKash: net worth must not change
        Transaction.objects.create(user=self.a, account=cash, to_account=bk, kind="transfer",
                                   amount=Dm("3000.00"), date=day)
        Loan.objects.create(user=self.a, kind="given", person="Rafiq", amount=Dm("2500.00"),
                            repayments=[{"amount": "500.00", "date": "2026-11-03"}])
        Loan.objects.create(user=self.a, kind="taken", person="Shop", amount=Dm("6000.00"),
                            repayments=[{"amount": "1000.00", "date": "2026-11-04"}])
        SavingsGoal.objects.create(user=self.a, title="Eid", target_amount=Dm("9000"),
                                   saved_amount=Dm("1200.25"))

    def test_networth_page_hero_equals_its_parts_and_last_point(self):
        from decimal import Decimal as Dm
        self._setup_money()
        d = self.get("a", "/money/networth")
        # cash 10000.10 + 8000.45 − 2200.55 − 3000 + bKash 5000 + 3000 = 20800.00
        self.assertEqual(Dm(d["assets"]), Dm("20800.00"))
        self.assertEqual(Dm(d["receivable"]), Dm("2000.00"))       # 2500 − 500 repaid
        self.assertEqual(Dm(d["liabilities"]), Dm("5000.00"))      # 6000 − 1000 repaid
        self.assertEqual(Dm(d["net_worth"]),
                         Dm(d["assets"]) + Dm(d["receivable"]) - Dm(d["liabilities"]))
        self.assertEqual(Dm(d["net_worth"]), Dm("17800.00"))
        if d["series"]:
            self.assertEqual(Dm(d["series"][-1]["net_worth"]), Dm(d["net_worth"]))

    def test_finance_tool_agrees_and_no_longer_crashes_on_a_savings_goal(self):
        from decimal import Decimal as Dm
        self._setup_money()
        r = self.post("a", "/finance", {"tool": "net_worth"}, 200).json()   # was a 500
        page = self.get("a", "/money/networth")
        self.assertEqual(Dm(r["receivable"]), Dm(page["receivable"]))    # repayments counted
        self.assertEqual(Dm(r["liabilities"]), Dm(page["liabilities"]))
        self.assertEqual(Dm(r["assets"]), Dm(page["assets"]) + Dm("1200.25"))  # + savings goal
        self.assertEqual(Dm(r["net_worth"]),
                         Dm(r["assets"]) + Dm(r["receivable"]) - Dm(r["liabilities"]))
