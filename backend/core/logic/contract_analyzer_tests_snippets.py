"""
contract_analyzer_tests_snippets.py — plain-assert tests for the CONTRACT /
AGREEMENT ANALYZER (#30, §8). Pure stdlib. `python contract_analyzer_tests_
snippets.py` or import and call run_all(). The engine is deterministic, so
every assertion is hand-verified against fixed inputs.
"""

try:  # Django harness
    from core.logic import contract_analyzer as C
except ImportError:  # standalone
    import contract_analyzer as C  # noqa: E402


# --------------------------------------------------------------- validation

def test_validate_empty():
    assert "empty_text" in C.validate("")
    assert "empty_text" in C.validate(None)


def test_validate_too_short():
    assert "too_short" in C.validate("short lease")


def test_validate_ok():
    assert C.validate("This agreement " * 5) == []


# --------------------------------------------------------------- detection

def test_detects_auto_renewal():
    f = C.detect_clauses("This subscription will automatically renew each year.")
    kinds = [x["kind"] for x in f]
    assert "auto_renewal" in kinds


def test_detects_penalty_and_lockin():
    txt = ("The tenant shall pay a penalty for late payment and is bound by a "
           "minimum term of 24 months with a lock-in period.")
    kinds = [x["kind"] for x in C.detect_clauses(txt)]
    assert "penalty" in kinds
    assert "lock_in" in kinds


def test_detects_bangla_seed():
    # bn seed phrase for penalty (জরিমানা) must trigger the same clause
    f = C.detect_clauses("দেরিতে পরিশোধে জরিমানা প্রযোজ্য হবে।")
    assert any(x["kind"] == "penalty" for x in f)


def test_each_clause_reported_once():
    # two auto-renewal seeds present → still only one auto_renewal flag
    txt = "It will auto-renew. It renews automatically every month."
    f = [x for x in C.detect_clauses(txt) if x["kind"] == "auto_renewal"]
    assert len(f) == 1


def test_no_false_positive_on_clean_text():
    txt = "The parties agree to meet on Tuesday to discuss the project scope."
    assert C.detect_clauses(txt) == []


# --------------------------------------------------------------- severity sort

def test_flags_sorted_worst_first():
    txt = ("We may share your data with third parties. There is a penalty for "
           "default. Price may increase.")
    flags = C.detect_clauses(txt)
    ranks = [C._SEVERITY_RANK[f["severity"]] for f in flags]
    assert ranks == sorted(ranks)   # non-decreasing: high → low
    assert flags[0]["severity"] == "high"


def test_counts_match_flags():
    txt = ("penalty and lock-in and auto-renew; service charge and arbitration; "
           "third party data.")
    res = C.analyze(txt)
    counts = res["counts"]
    assert counts["high"] + counts["medium"] + counts["low"] == len(res["flags"])


# --------------------------------------------------------------- snippet

def test_snippet_shows_user_text():
    txt = "The lender may terminate for convenience at any time whatsoever."
    f = C.detect_clauses(txt)
    term = [x for x in f if x["kind"] == "one_sided_termination"][0]
    assert "terminate for convenience" in term["snippet"]


# --------------------------------------------------------------- checklist

def test_checklist_always_items_present():
    res = C.analyze("The parties agree to the following terms and conditions.")
    for key in C.ALWAYS_CHECK:
        assert key in res["checklist"]


def test_checklist_adds_per_clause():
    res = C.analyze("This contract will auto-renew and carries a penalty clause.")
    assert "verify_renewal" in res["checklist"]
    assert "verify_penalty" in res["checklist"]


def test_checklist_no_duplicates():
    res = C.analyze("penalty penalty penalty, auto-renew auto-renew.")
    assert len(res["checklist"]) == len(set(res["checklist"]))


# --------------------------------------------------------------- analyze shape

def test_analyze_shape_and_honest_flags():
    res = C.analyze("This agreement has a lock-in period and a late fee penalty.")
    for k in ("flags", "counts", "checklist", "clause_kinds", "text_len",
              "ai_required", "mock", "disclaimer", "marker", "problems"):
        assert k in res, k
    assert res["ai_required"] is False     # deterministic layer needs no key
    assert res["mock"] is True             # honest rule-based
    assert res["disclaimer"] is True       # never legal advice
    assert res["marker"] == C.MARKER_KEY
    assert res["problems"] == []


def test_analyze_is_deterministic():
    txt = "Auto-renew, penalty, lock-in, arbitration, hidden service charge."
    assert C.analyze(txt) == C.analyze(txt)


# --------------------------------------------------------------- AI seam

def test_deep_analysis_plan_is_key_gated_with_fallback():
    plan = C.deep_analysis_plan("This has an auto-renewal clause.")
    assert plan["ai_required"] is True
    assert plan["ai_integration"] == "anthropic"
    assert plan["mock"] is True
    assert plan["disclaimer"] is True
    # the deterministic fallback is present so the UI is never empty
    assert "fallback" in plan
    assert any(f["kind"] == "auto_renewal" for f in plan["fallback"]["flags"])


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"contract_analyzer: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
