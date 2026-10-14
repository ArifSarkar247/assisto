"""
landlord_tenant_tests_snippets.py — plain-assert tests for the LANDLORD–TENANT
rent tracker (#185, §20, built to §21 ADVANCED). Pure stdlib. Run standalone
(`python landlord_tenant_tests_snippets.py`) or import and call run_all(). The
engine is deterministic + holds no money, so every assertion is hand-verified.
"""

try:  # Django harness: core.logic.landlord_tenant_tests_snippets
    from core.logic import landlord_tenant as L
except ImportError:  # standalone
    import landlord_tenant as L  # noqa: E402


def _units():
    return [
        {"id": 1, "label": "Flat 3A", "rent_poisha": 1200000,
         "tenant_name": "Karim", "active": True,
         "utilities": [
             {"name": "water", "amount_poisha": 30000},               # fixed ৳300
             {"name": "service", "share_of_poisha": 60000,
              "share_num": 1, "share_den": 4},                         # 1/4 of ৳600 = ৳150
         ]},
        {"id": 2, "label": "Shop 1", "rent_poisha": 800000,
         "tenant_name": "Rahim", "active": True, "utilities": []},
        {"id": 9, "label": "Empty", "rent_poisha": 500000,
         "tenant_name": "", "active": False, "utilities": []},
    ]


# ----------------------------------------------------------------- honesty
def test_never_holds_or_charges_money():
    assert L.holds_money() is False
    assert L.charges_money() is False
    ms = L.month_summary(_units(), [], "2026-02")
    assert ms["holds_money"] is False and ms["charges_money"] is False


# ----------------------------------------------------------------- amounts
def test_to_poisha_no_float_drift():
    assert L.to_poisha("12000") == 1200000
    assert L.to_poisha("12000.50") == 1200050
    assert L.to_poisha("bad") == 0
    assert L.to_poisha(None) == 0


# ----------------------------------------------------------------- utilities
def test_utility_fixed_and_share_floor_no_float():
    fixed = {"name": "water", "amount_poisha": 30000}
    assert L.utility_amount(fixed) == 30000
    share = {"name": "service", "share_of_poisha": 60000,
             "share_num": 1, "share_den": 4}
    assert L.utility_amount(share) == 15000           # floor(60000/4)
    odd = {"share_of_poisha": 100, "share_num": 1, "share_den": 3}
    assert L.utility_amount(odd) == 33                # floor, never rounds up
    assert L.utility_amount({"share_of_poisha": 100, "share_den": 0}) == 0


def test_monthly_bill_itemised_and_summed():
    b = L.monthly_bill(_units()[0])
    assert b["rent_poisha"] == 1200000
    assert b["utilities_poisha"] == 45000             # 30000 + 15000
    assert b["bill_poisha"] == 1245000
    names = [x["name"] for x in b["breakdown"]]
    assert names == ["water", "service"]


# ----------------------------------------------------------------- validate
def test_validate_unit_ok_and_problems():
    assert L.validate_unit(_units()[0]) == []
    assert "label_required" in L.validate_unit({"rent_poisha": 100})
    assert "rent_required" in L.validate_unit({"label": "X", "rent_poisha": 0})
    assert "utility_name_required" in L.validate_unit(
        {"label": "X", "rent_poisha": 100, "utilities": [{"amount_poisha": 10}]})


def test_active_units_excludes_inactive_sorted():
    us = L.active_units(_units())
    assert [u["label"] for u in us] == ["Flat 3A", "Shop 1"]


# ----------------------------------------------------------------- month
def test_unit_month_due_partial_paid_and_reconcile():
    pays = [
        {"unit_id": 1, "month": "2026-02", "paid_poisha": 1245000},  # full
        {"unit_id": 2, "month": "2026-02", "paid_poisha": 300000},   # partial
        # unit 9 inactive; no payment anywhere
    ]
    um1 = L.unit_month(_units()[0], pays, "2026-02")
    assert um1["bill_poisha"] == 1245000
    assert um1["paid_poisha"] == 1245000
    assert um1["outstanding_poisha"] == 0
    assert um1["status"] == "paid"

    um2 = L.unit_month(_units()[1], pays, "2026-02")
    assert um2["status"] == "partial"
    assert um2["outstanding_poisha"] == 500000           # 800000 - 300000

    um2_none = L.unit_month(_units()[1], [], "2026-02")
    assert um2_none["status"] == "due"
    # reconcile: bill == paid + outstanding (within month, credit apart)
    assert um2["bill_poisha"] == um2["paid_poisha"] + um2["outstanding_poisha"]


def test_overpay_becomes_credit_not_negative_outstanding():
    pays = [{"unit_id": 2, "month": "2026-02", "paid_poisha": 900000}]
    um = L.unit_month(_units()[1], pays, "2026-02")
    assert um["outstanding_poisha"] == 0
    assert um["credit_poisha"] == 100000                  # 900000 - 800000
    assert um["status"] == "paid"


def test_month_summary_totals_reconcile():
    pays = [
        {"unit_id": 1, "month": "2026-02", "paid_poisha": 1245000},
        {"unit_id": 2, "month": "2026-02", "paid_poisha": 300000},
    ]
    ms = L.month_summary(_units(), pays, "2026-02")
    assert ms["unit_count"] == 2                          # inactive excluded
    assert ms["billed_poisha"] == 1245000 + 800000
    assert ms["collected_poisha"] == 1245000 + 300000
    assert ms["outstanding_poisha"] == 500000
    assert ms["billed_poisha"] == ms["collected_poisha"] + ms["outstanding_poisha"]
    assert ms["paid_count"] == 1 and ms["partial_count"] == 1 and ms["due_count"] == 0


# ----------------------------------------------------------------- arrears
def test_arrears_sums_across_range_inclusive():
    pays = [
        {"unit_id": 1, "month": "2026-01", "paid_poisha": 1245000},  # Jan paid
        # Feb nothing for unit 1 → arrears 1245000
        {"unit_id": 2, "month": "2026-01", "paid_poisha": 800000},
        {"unit_id": 2, "month": "2026-02", "paid_poisha": 800000},   # unit 2 fully paid both
    ]
    ar = L.arrears(_units(), pays, "2026-01", "2026-02")
    assert ar["months"] == ["2026-01", "2026-02"]
    u1 = [u for u in ar["units"] if u["unit_id"] == 1][0]
    assert u1["outstanding_poisha"] == 1245000           # only Feb owed
    assert u1["months_in_arrears"] == 1
    u2 = [u for u in ar["units"] if u["unit_id"] == 2][0]
    assert u2["outstanding_poisha"] == 0
    assert ar["total_outstanding_poisha"] == 1245000


def test_arrears_year_rollover_months():
    ar = L.arrears(_units(), [], "2025-12", "2026-02")
    assert ar["months"] == ["2025-12", "2026-01", "2026-02"]


def test_arrears_reversed_range_is_empty_honest():
    ar = L.arrears(_units(), [], "2026-05", "2026-02")
    assert ar["months"] == []
    assert ar["total_outstanding_poisha"] == 0


# ------------------------------------------------- reminder seam (doc-only)
def test_due_reminder_plan_lists_unpaid_and_is_not_wired():
    pays = [{"unit_id": 1, "month": "2026-02", "paid_poisha": 1245000}]  # unit1 paid
    plan = L.due_reminder_plan(_units(), pays, "2026-02", lead_days=3)
    ids = [r["unit_id"] for r in plan["needs_reminder"]]
    assert ids == [2]                                    # only the unpaid unit
    assert plan["wired"] is False                        # honest: plans only
    assert plan["lead_days"] == 3


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"landlord_tenant: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
