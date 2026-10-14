"""
pa_expense_tests_snippets.py — plain-assert tests for PA expense voucher
builder (#113, §14). Pure stdlib. `python pa_expense_tests_snippets.py` or
import and call run_all(). Deterministic; integer-poisha math, no float drift.
"""
try:  # Django harness
    from core.logic import pa_expense as E
except ImportError:  # standalone
    import pa_expense as E  # noqa: E402


# --------------------------------------------------------------- money
def test_to_poisha_basic():
    assert E.to_poisha("100") == 10000
    assert E.to_poisha("100.50") == 10050
    assert E.to_poisha("1,234.5") == 123450
    assert E.to_poisha("0.01") == 1


def test_to_poisha_half_up_and_clamp():
    assert E.to_poisha("1.005") == 101      # third decimal 5 rounds up
    assert E.to_poisha("1.004") == 100
    assert E.to_poisha("-50") == 0          # negatives clamp
    assert E.to_poisha("garbage") == 0
    assert E.to_poisha("") == 0 and E.to_poisha(None) == 0
    assert E.to_poisha(True) == 0


def test_fmt_bdt_grouping():
    assert E.fmt_bdt(10000) == "৳100.00"
    assert E.fmt_bdt(123450) == "৳1,234.50"
    assert E.fmt_bdt(123456789) == "৳12,34,567.89"  # lakh grouping
    assert E.fmt_bdt(0) == "৳0.00"


# --------------------------------------------------------------- normalize
def test_normalize_voucher_bad_status():
    v = E.normalize_voucher({"title": " Trip claim ", "status": "weird"})
    assert v["title"] == "Trip claim"
    assert v["status"] == E.STATUS_DRAFT


def test_normalize_line_bad_category_and_amount():
    ln = E.normalize_line({"category": "spaceship", "amount": "250.75"})
    assert ln["category"] == "other"
    assert ln["amount_poisha"] == 25075
    assert ln["amount"] == "250.75"


# --------------------------------------------------------------- validate
def test_validate_voucher_and_line():
    assert E.validate_voucher({"title": "x"}) == []
    assert "title_required" in E.validate_voucher({"title": ""})
    assert E.validate_line({"category": "meals", "amount": "50"}) == []
    assert "amount_required" in E.validate_line({"category": "meals",
                                                 "amount": "0"})
    assert "bad_date" in E.validate_line({"amount": "5", "date": "nope"})


# --------------------------------------------------------------- status
def test_can_transition_one_way():
    assert E.can_transition("draft", "submitted") is True
    assert E.can_transition("submitted", "approved") is True
    assert E.can_transition("draft", "approved") is False     # no skipping
    assert E.can_transition("approved", "draft") is True      # reject-back
    assert E.can_transition("submitted", "submitted") is True


def test_advance_status():
    assert E.advance_status("draft") == "submitted"
    assert E.advance_status("submitted") == "approved"
    assert E.advance_status("approved") == "approved"


# --------------------------------------------------------------- totals
def test_total_poisha_no_drift():
    lines = [{"amount": "0.10"} for _ in range(10)]  # 10 × 0.10 == 1.00 exactly
    assert E.total_poisha(lines) == 100


def test_category_totals():
    lines = [
        {"category": "meals", "amount": "100"},
        {"category": "meals", "amount": "50"},
        {"category": "transport", "amount": "200"},
    ]
    ct = E.category_totals(lines)
    assert ct == {"meals": 15000, "transport": 20000}


def test_voucher_summary_orders_and_totals():
    s = E.voucher_summary(
        {"title": "Field trip", "status": "submitted"},
        lines=[
            {"id": 2, "date": "2026-11-02", "category": "meals", "amount": "300"},
            {"id": 1, "date": "2026-11-01", "category": "transport",
             "amount": "500"},
            {"id": 3, "date": "", "category": "other", "amount": "100"},  # undated
        ],
    )
    assert [ln["id"] for ln in s["lines"]] == [1, 2, 3]  # dated first, undated last
    assert s["total_poisha"] == 90000
    assert s["total_display"] == "৳900.00"
    assert s["count"] == 3
    assert s["status"] == "submitted"
    assert s["mock"] is False


# --------------------------------------------------------------- seam
def test_ocr_seam_is_honest_and_empty():
    r = E.ocr_seam("receipt-42.jpg")
    assert r["required"] is True and r["mock"] is True
    assert r["fields"] == {}             # never fabricates an amount/merchant
    assert r["marker"] == E.OCR_MARKER_KEY
    assert r["ref"] == "receipt-42.jpg"


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"pa_expense: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
