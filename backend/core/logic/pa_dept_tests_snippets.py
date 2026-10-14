"""
pa_dept_tests_snippets.py — plain-assert tests for the PA Departmental-update
roll-up (#117, §14, CORPORATE). Pure stdlib. Deterministic, hand-verified.
`python pa_dept_tests_snippets.py` or import and call run_all().
"""

try:  # Django harness
    from core.logic import pa_dept as A
except ImportError:  # standalone
    import pa_dept as A  # noqa: E402


def _by_phrase(res, phrase):
    return [ln for ln in res["lines"] if ln["phrase"] == phrase]


# --------------------------------------------------------------- validation

def test_validate_needs_a_named_department():
    assert "no_departments" in A.validate([])
    assert "no_departments" in A.validate([{"lead": "X"}])  # no name
    assert A.validate([{"department": "Sales", "highlights": ["ok"]}]) == []


def test_validate_flags_empty_update():
    p = A.validate([{"department": "Sales"}])  # name but nothing in it
    assert "empty_update" in p


# --------------------------------------------------------------- determinism

def test_rollup_is_deterministic():
    ups = [{"department": "Sales", "lead": "A",
            "highlights": ["won deal"], "blockers": ["staffing"],
            "metrics": [{"label": "Pipeline", "value": "৳4.2L"}]},
           {"department": "Ops", "highlights": ["shipped"], "blockers": []}]
    assert A.rollup(ups) == A.rollup(ups)


# --------------------------------------------------------------- honest flags

def test_carries_marker_and_mock():
    res = A.rollup([{"department": "Sales", "highlights": ["x"]}])
    assert res["mock"] is True
    assert res["marker"] == A.MARKER_KEY
    assert res["ai_required"] is False


# --------------------------------------------------------------- counts

def test_counts_departments_highlights_blockers_blocked():
    ups = [{"department": "Sales", "highlights": ["a", "b"],
            "blockers": ["x"]},
           {"department": "Ops", "highlights": ["c"], "blockers": []},
           {"department": "HR", "highlights": [], "blockers": ["y", "z"]}]
    c = A.rollup(ups)["counts"]
    assert c["departments"] == 3
    assert c["highlights"] == 3
    assert c["blockers"] == 3
    assert c["blocked"] == 2  # Sales + HR


def test_clear_when_no_blockers_anywhere():
    res = A.rollup([{"department": "Sales", "highlights": ["ok"]}])
    assert _by_phrase(res, A.PHRASE_CLEAR)
    assert not _by_phrase(res, A.PHRASE_BLOCKED)


# --------------------------------------------------------------- structure

def test_department_order_preserved():
    ups = [{"department": "Zeta", "highlights": ["z"]},
           {"department": "Alpha", "highlights": ["a"]}]
    depts = [ln["text"] for ln in A.rollup(ups)["lines"]
             if ln["role"] == A.ROLE_DEPT]
    assert depts == ["Zeta", "Alpha"]  # input order, NOT sorted


def test_lead_folded_into_dept_header():
    res = A.rollup([{"department": "Sales", "lead": "Karim",
                     "highlights": ["x"]}])
    dept = [ln for ln in res["lines"] if ln["role"] == A.ROLE_DEPT][0]
    assert dept["text"] == "Sales — Karim"


def test_bullets_passthrough_from_string_and_list():
    res = A.rollup([{"department": "Sales",
                     "highlights": "First\n\nSecond\n  \nThird"}])
    hls = [ln["text"] for ln in res["lines"]
           if ln["role"] == A.ROLE_ITEM and ln["phrase"] == A.PHRASE_HIGHLIGHTS]
    assert hls == ["First", "Second", "Third"]


def test_owner_text_verbatim():
    res = A.rollup([{"department": "Sales", "blockers": ["EXACT BLOCKER 9"]}])
    assert any(ln["text"] == "EXACT BLOCKER 9" for ln in res["lines"])


# --------------------------------------------------------------- metrics

def test_metric_value_reported_verbatim_never_computed():
    res = A.rollup([{"department": "Sales",
                     "metrics": [{"label": "Growth", "value": "92%"},
                                 {"label": "Revenue", "value": "৳4.2L"}]}])
    metrics = [ln["text"] for ln in res["lines"]
               if ln["role"] == A.ROLE_METRIC]
    assert "Growth: 92%" in metrics
    assert "Revenue: ৳4.2L" in metrics  # taka + value untouched


def test_metric_without_label_is_dropped():
    res = A.rollup([{"department": "Sales",
                     "metrics": [{"label": "", "value": "99"}]}])
    assert not any(ln["role"] == A.ROLE_METRIC for ln in res["lines"])


# --------------------------------------------------------------- key-gated AI

def test_ai_synthesis_seam_sets_flag_but_always_assembles():
    res = A.rollup([{"department": "Sales", "highlights": ["real hl"]}],
                   want_ai_synthesis=True)
    assert res["ai_required"] is True
    assert any(ln["text"] == "real hl" for ln in res["lines"])


# --------------------------------------------------------------- runner

def run_all():
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and callable(v)]
    for fn in fns:
        fn()
    print(f"pa_dept: {len(fns)} checks passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
