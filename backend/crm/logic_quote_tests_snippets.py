"""
Hand-verified tests for crm.logic_quote — PURE, no Django, no DB.

Run:  python3 -c "import crm.logic_quote_tests_snippets as a; a.run_all()"

Every expected value below is computed BY HAND in the comment so a reviewer can
confirm no price/tax is invented and no float drift occurs (integer poisha).
"""
from decimal import Decimal

from . import logic_quote as q


def _eq(got, want, label):
    assert got == want, f"{label}: got {got!r} want {want!r}"


def test_money_conversion():
    # 1500.50 BDT → 150050 poisha (exact, no binary-float drift).
    _eq(q.taka_to_poisha("1500.50"), 150050, "taka_to_poisha str")
    _eq(q.taka_to_poisha(Decimal("1500.50")), 150050, "taka_to_poisha Decimal")
    # 0.1 float path goes through Decimal(str()) → 10 poisha, not 9/11.
    _eq(q.taka_to_poisha(0.1), 10, "taka_to_poisha float")
    _eq(q.poisha_to_taka_str(150050), "1500.50", "poisha_to_taka_str")
    _eq(q.poisha_to_taka_str(5), "0.05", "poisha_to_taka_str small")
    # None is a hard error — a missing price must never become a silent 0.
    try:
        q.taka_to_poisha(None)
        assert False, "None must raise"
    except ValueError:
        pass


def test_totals_no_drift():
    # Three lines: 100.00×3 + 250.33×1 + 0.01×7
    #   = 30000 + 25033 + 7 = 55040 poisha subtotal (exact integer sum).
    lines = [
        {"sku": "A", "unit_poisha": 10000, "qty": 3, "price_reviewed": True},
        {"sku": "B", "unit_poisha": 25033, "qty": 1, "price_reviewed": True},
        {"sku": "C", "unit_poisha": 1, "qty": 7, "price_reviewed": True},
    ]
    r = q.compute_totals(lines, discount_pct=0, tax_pct=0)
    _eq(r["subtotal_poisha"], 55040, "subtotal")
    _eq(r["prices_reviewed"], True, "prices reviewed")
    _eq(r["needs_discount_approval"], False, "no discount approval")
    _eq(r["tax_review_required"], False, "no tax => no review")


def test_totals_discount_tax_exact():
    # One line 1000.00 × 1 = 100000 poisha.
    # discount 7.5%  → 7500 poisha  (exact: 100000×3/40 = 7500).
    # taxable        → 92500 poisha.
    # tax 7.5%       → 6937.5 → round half-up → 6938 poisha (single rounding).
    # total          → 99438 poisha.
    lines = [{"sku": "X", "unit_poisha": 100000, "qty": 1, "price_reviewed": True}]
    r = q.compute_totals(lines, discount_pct="7.5", tax_pct="7.5",
                         tax_rate_confirmed=True)
    _eq(r["discount_poisha"], 7500, "discount 7.5%")
    _eq(r["taxable_poisha"], 92500, "taxable")
    _eq(r["tax_poisha"], 6938, "tax 7.5% half-up")
    _eq(r["total_poisha"], 99438, "total")
    _eq(r["tax_review_required"], False, "tax confirmed")


def test_tax_review_required_when_unconfirmed():
    lines = [{"sku": "X", "unit_poisha": 100000, "qty": 1, "price_reviewed": True}]
    r = q.compute_totals(lines, tax_pct="15")   # tax_rate_confirmed defaults False
    _eq(r["tax_review_required"], True, "applied tax w/o confirm => review")


def test_unreviewed_price_flags_quote():
    lines = [
        {"sku": "A", "unit_poisha": 5000, "qty": 1, "price_reviewed": True},
        {"sku": "B", "unit_poisha": 5000, "qty": 1, "price_reviewed": False},
    ]
    r = q.compute_totals(lines)
    _eq(r["prices_reviewed"], False, "any unreviewed line flags whole quote")


def test_missing_price_raises():
    try:
        q.compute_totals([{"sku": "A", "qty": 1}])  # no unit_poisha
        assert False, "missing price must raise"
    except ValueError:
        pass


def test_discount_approval_rule():
    _eq(q.discount_needs_approval(10), False, "10% == threshold, not above")
    _eq(q.discount_needs_approval("10.01"), True, "just above threshold")
    _eq(q.discount_needs_approval(25), True, "25% above")
    _eq(q.discount_needs_approval(5, threshold_pct=20), False, "custom threshold")


def test_approval_gate():
    totals_ok = {"needs_discount_approval": False, "tax_review_required": False}
    _eq(q.approval_gate(totals=totals_ok, prices_reviewed=True,
                        approved=False, discount_approved=False)["can_advance"],
        True, "clean quote can advance")
    totals_disc = {"needs_discount_approval": True, "tax_review_required": False}
    g = q.approval_gate(totals=totals_disc, prices_reviewed=True,
                        approved=False, discount_approved=False)
    _eq(g["can_advance"], False, "unapproved big discount blocks")
    _eq("discount_needs_manager_approval" in g["blockers"], True, "blocker code")
    g2 = q.approval_gate(totals=totals_disc, prices_reviewed=False,
                         approved=False, discount_approved=True)
    _eq(set(g2["blockers"]), {"prices_not_reviewed"}, "only price blocker left")


def test_versions_and_diff():
    _eq(q.next_version([]), 1, "first version")
    _eq(q.next_version([1, 2]), 3, "next after v2")
    old = {"line_items": [{"sku": "A", "qty": 1, "unit_poisha": 10000},
                          {"sku": "B", "qty": 2, "unit_poisha": 5000}],
           "total_poisha": 20000, "discount_pct": 0}
    new = {"line_items": [{"sku": "A", "qty": 3, "unit_poisha": 10000},
                          {"sku": "C", "qty": 1, "unit_poisha": 7000}],
           "total_poisha": 37000, "discount_pct": 5}
    d = q.version_diff(old, new)
    _eq([x["sku"] for x in d["added"]], ["C"], "C added")
    _eq([x["sku"] for x in d["removed"]], ["B"], "B removed")
    _eq(d["changed"][0]["sku"], "A", "A changed")
    _eq(d["changed"][0]["qty_from"], 1, "A qty from")
    _eq(d["changed"][0]["qty_to"], 3, "A qty to")
    _eq(d["total_delta_poisha"], 17000, "total delta")


def test_validity():
    # issued day 100, valid 30 days → until 130.
    _eq(q.validity_until(100, 30), 130, "validity until")
    _eq(q.is_expired(100, 30, 130), False, "last valid day not expired")
    _eq(q.is_expired(100, 30, 131), True, "day after is expired")
    _eq(q.days_left(100, 30, 125), 5, "5 days left")
    _eq(q.days_left(100, 30, 140), -10, "lapsed 10 days")
    _eq(q.validity_until(100, None), None, "no expiry window")
    _eq(q.is_expired(100, None, 9999), False, "no window never expires")


def test_pdf_model_honest():
    quote = {
        "title": "Axon ERP", "version": 2,
        "line_items": [{"sku": "A", "label": "HRM", "unit_poisha": 100000,
                        "qty": 2, "price_reviewed": True}],
        "subtotal_poisha": 200000, "discount_poisha": 0, "discount_pct": 0,
        "tax_poisha": 0, "tax_pct": 0, "total_poisha": 200000,
        "prices_reviewed": True, "tax_review_required": False,
    }
    m = q.build_pdf_model(quote=quote, org_brand={"name": "Axon"},
                          pdf_lib_available=False)
    _eq(m["rendered"], False, "no lib => not a real PDF")
    _eq(m["lines"][0]["amount_taka"], "2000.00", "line amount taka")
    _eq(m["total_taka"], "2000.00", "total taka")
    _eq("structured fallback" in m["render_note"], True, "honest note")
    m2 = q.build_pdf_model(quote=quote, org_brand={"name": "Axon"},
                           pdf_lib_available=True)
    _eq(m2["rendered"], True, "lib present => rendered")


def test_acceptance_token_and_state():
    tok1 = q.make_acceptance_token(quote_id=7, version=2, salt="s")
    tok2 = q.make_acceptance_token(quote_id=7, version=2, salt="s")
    _eq(tok1, tok2, "deterministic token")
    tok3 = q.make_acceptance_token(quote_id=7, version=3, salt="s")
    assert tok1 != tok3, "version change => new token"
    _eq(q.acceptance_transition("issued", "view"), "viewed", "issued->viewed")
    _eq(q.acceptance_transition("viewed", "accept"), "accepted", "viewed->accepted")
    _eq(q.can_accept(link_state="viewed", is_expired_flag=False), True, "can accept")
    _eq(q.can_accept(link_state="viewed", is_expired_flag=True), False,
        "expired cannot accept")
    _eq(q.can_accept(link_state="issued", is_expired_flag=False), False,
        "unviewed cannot accept")
    for bad in [("accepted", "accept"), ("expired", "view"), ("declined", "accept")]:
        try:
            q.acceptance_transition(*bad)
            assert False, f"illegal {bad} must raise"
        except ValueError:
            pass


def test_convert_to_order():
    ok = q.can_convert_to_order(status="accepted", link_state="accepted",
                                is_expired_flag=False)
    _eq(ok["can_convert"], True, "accepted quote converts")
    bad = q.can_convert_to_order(status="sent", link_state="viewed",
                                 is_expired_flag=False)
    _eq(bad["can_convert"], False, "non-accepted blocked")
    quote = {"id": 7, "version": 2, "lead_id": 3,
             "line_items": [{"sku": "A"}], "subtotal_poisha": 200000,
             "discount_poisha": 0, "tax_poisha": 0, "total_poisha": 200000}
    payload = q.build_order_payload(quote=quote, accepted_ordinal=130)
    _eq(payload["total_poisha"], 200000, "order carries same total, no re-price")
    _eq(payload["status"], "order_draft", "hands off as draft")
    _eq(payload["source"], "quote", "provenance preserved")


_TESTS = [
    test_money_conversion, test_totals_no_drift, test_totals_discount_tax_exact,
    test_tax_review_required_when_unconfirmed, test_unreviewed_price_flags_quote,
    test_missing_price_raises, test_discount_approval_rule, test_approval_gate,
    test_versions_and_diff, test_validity, test_pdf_model_honest,
    test_acceptance_token_and_state, test_convert_to_order,
]


def run_all():
    for t in _TESTS:
        t()
    print(f"logic_quote: {len(_TESTS)} tests passed")
    return len(_TESTS)


if __name__ == "__main__":
    run_all()
