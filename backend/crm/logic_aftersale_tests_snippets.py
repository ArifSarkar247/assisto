"""
Hand-verified tests for crm.logic_aftersale — PURE, no Django, no DB.

Run:  python3 -c "import crm.logic_aftersale_tests_snippets as b; b.run_all()"

Expected values are hand-computed in comments — integer poisha, no float drift,
no invented amounts.
"""
from . import logic_aftersale as a


def _eq(got, want, label):
    assert got == want, f"{label}: got {got!r} want {want!r}"


def test_schedule_exact_split():
    # 10001 poisha / 3 installments:
    #   base = 10001 // 3 = 3333 ; remainder = 10001 - 9999 = 2
    #   installments = [3333, 3333, 3333+2=3335]  Σ = 10001 (no drift).
    sched = a.build_installment_schedule(10001, 3, first_due_ordinal=100,
                                         interval_days=30)
    amts = [s["amount_poisha"] for s in sched]
    _eq(amts, [3333, 3333, 3335], "exact split w/ remainder on last")
    _eq(sum(amts), 10001, "sum equals total — zero drift")
    _eq([s["due_ordinal"] for s in sched], [100, 130, 160], "due dates step")


def test_schedule_guards():
    try:
        a.build_installment_schedule(1000, 0, 100)
        assert False
    except ValueError:
        pass


def test_apply_collection_states():
    inst = {"seq": 1, "amount_poisha": 10000, "due_ordinal": 100,
            "collected_poisha": 0}
    partial = a.apply_collection(inst, 4000, "cash")
    _eq(partial["status"], "partial", "partial collection")
    _eq(partial["collected_poisha"], 4000, "collected tally")
    _eq(inst["collected_poisha"], 0, "original not mutated")
    full = a.apply_collection(partial, 6000, "bank")
    _eq(full["status"], "collected", "fully collected")
    over = a.apply_collection(full, 1, "cheque")
    _eq(over["status"], "overpaid", "overpaid flagged")
    try:
        a.apply_collection(inst, 100, "bitcoin")
        assert False, "bad method must raise"
    except ValueError:
        pass


def test_collection_summary():
    # Two installments 5000 each (booked 10000). First due@100 collected 5000,
    # second due@130 collected 0. Today=135 → second is overdue 5000.
    sched = [
        {"amount_poisha": 5000, "due_ordinal": 100, "collected_poisha": 5000},
        {"amount_poisha": 5000, "due_ordinal": 130, "collected_poisha": 0},
    ]
    s = a.collection_summary(sched, today_ordinal=135)
    _eq(s["booked_poisha"], 10000, "booked")
    _eq(s["collected_poisha"], 5000, "collected")
    _eq(s["outstanding_poisha"], 5000, "outstanding")
    _eq(s["overdue_poisha"], 5000, "overdue (past due + unpaid)")
    _eq(s["overdue_count"], 1, "one overdue")
    _eq(s["fully_collected"], False, "not fully collected")


def test_overpay_does_not_inflate_collected():
    sched = [{"amount_poisha": 5000, "due_ordinal": 100, "collected_poisha": 6000}]
    s = a.collection_summary(sched, today_ordinal=200)
    _eq(s["collected_poisha"], 5000, "collected capped at booked")
    _eq(s["outstanding_poisha"], 0, "no outstanding")


def test_amc_renewal():
    _eq(a.amc_renewal_ordinal(100, 365), 465, "365-day term")
    r = a.renewal_status(465, today_ordinal=400, reminder_lead_days=30)
    _eq(r["state"], "active", "far from renewal")
    r2 = a.renewal_status(465, today_ordinal=440)
    _eq(r2["state"], "due_soon", "within 30 days")
    _eq(r2["needs_reminder"], True, "reminder needed")
    _eq(a.renewal_status(465, 465)["state"], "due_today", "due today")
    _eq(a.renewal_status(465, 470)["state"], "overdue", "overdue")


def test_reminder_schedule():
    # renewal day 465, default lead 30/7/1 → [435, 458, 464], sorted ascending.
    _eq(a.reminder_schedule(465), [435, 458, 464], "reminder fire days")
    _eq(a.reminder_schedule(465, lead_days=(7, 7, 0)), [458, 465], "dedup + 0 lead")


def test_complaint_state_machine():
    _eq(a.complaint_transition("open", "acknowledge"), "acknowledged", "ack")
    _eq(a.complaint_transition("acknowledged", "start"), "in_progress", "start")
    _eq(a.complaint_transition("in_progress", "resolve"), "resolved", "resolve")
    _eq(a.complaint_transition("resolved", "close"), "closed", "close")
    _eq(a.complaint_transition("resolved", "reopen"), "open", "reopen")
    for bad in [("closed", "reopen"), ("open", "close"), ("cancelled", "start")]:
        try:
            a.complaint_transition(*bad)
            assert False, f"illegal {bad} must raise"
        except ValueError:
            pass


def test_complaint_sla():
    # urgent SLA = 1 day, opened@100. today=102, still open → breached.
    s = a.complaint_sla("urgent", opened_ordinal=100, today_ordinal=102,
                        state="in_progress")
    _eq(s["sla_days"], 1, "urgent 1 day")
    _eq(s["due_ordinal"], 101, "due next day")
    _eq(s["breached"], True, "past due + inflight => breached")
    s2 = a.complaint_sla("urgent", 100, 102, state="resolved")
    _eq(s2["breached"], False, "resolved not breached going forward")
    _eq(s2["days_left"], None, "no SLA clock once closed")
    s3 = a.complaint_sla("normal", 100, 103, state="open")
    _eq(s3["breached"], False, "within normal 5-day SLA")


def test_upsell():
    u = a.upsell_signals(owned_module_codes=["hrm", "payroll"],
                         catalog_module_codes=["hrm", "payroll", "vat", "accounts"],
                         amc_state="due_soon", outstanding_poisha=0)
    _eq(u["candidates"], ["vat", "accounts"], "only unowned modules")
    kinds = {s["kind"] for s in u["signals"]}
    _eq("amc_renewal" in kinds, True, "renewal upsell on due_soon")
    _eq(u["suppressed"], False, "paid account not suppressed")
    u2 = a.upsell_signals(owned_module_codes=["hrm"],
                          catalog_module_codes=["hrm", "vat"],
                          outstanding_poisha=5000)
    _eq(u2["suppressed"], True, "unpaid account suppresses upsell")
    _eq(u2["suppress_reason"], "outstanding_balance", "reason given")


def test_erp_handoff():
    rec = a.build_handoff_record(deal_id=7, company_name="Acme",
                                 module_codes=["hrm", "vat"],
                                 order_total_poisha=500000,
                                 erp_link_connected=False)
    _eq(rec["erp_state"], "needs_erp_link", "no link => honest state")
    _eq(rec["transport"], "mock", "nothing sent to ERP")
    _eq("untouched" in rec["note"], True, "Asalify/ERP untouched note")
    _eq(a.handoff_transition("not_started", "prepare"), "preparing", "prepare")
    _eq(a.handoff_transition("submitted", "accept"), "accepted", "accept")
    _eq(a.handoff_transition("rejected", "prepare"), "preparing", "resubmit path")
    for bad in [("completed", "prepare"), ("not_started", "submit")]:
        try:
            a.handoff_transition(*bad)
            assert False, f"illegal {bad} must raise"
        except ValueError:
            pass


_TESTS = [
    test_schedule_exact_split, test_schedule_guards, test_apply_collection_states,
    test_collection_summary, test_overpay_does_not_inflate_collected,
    test_amc_renewal, test_reminder_schedule, test_complaint_state_machine,
    test_complaint_sla, test_upsell, test_erp_handoff,
]


def run_all():
    for t in _TESTS:
        t()
    print(f"logic_aftersale: {len(_TESTS)} tests passed")
    return len(_TESTS)


if __name__ == "__main__":
    run_all()
