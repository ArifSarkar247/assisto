"""
mock_interview_tests_snippets.py — plain-assert tests for the MOCK INTERVIEW
engine (#131, §21). Pure stdlib. `python mock_interview_tests_snippets.py` or
import and call run_all(). The engine is deterministic, so every assertion is
hand-verified against fixed inputs.
"""

try:  # Django harness
    from core.logic import mock_interview as M
except ImportError:  # standalone
    import mock_interview as M  # noqa: E402


# --------------------------------------------------------------- bank content

def test_bank_has_enough_bilingual_questions():
    assert len(M.BANK) >= 15, len(M.BANK)
    for q in M.BANK:
        for k in ("id", "category", "q_bn", "q_en", "keywords",
                  "outline_bn", "outline_en"):
            assert k in q and q[k] not in ("", None, []), (q["id"], k)
        assert q["category"] in M.CATEGORIES


def test_all_four_categories_present():
    cats = {q["category"] for q in M.BANK}
    assert cats == set(M.CATEGORIES), cats


def test_ids_unique():
    ids = [q["id"] for q in M.BANK]
    assert len(ids) == len(set(ids))


# --------------------------------------------------------------- next question

def test_next_question_serves_in_order_and_skips_asked():
    first = M.next_question("job", [])
    assert first["question"] is not None
    fid = first["question"]["id"]
    second = M.next_question("job", [fid])
    assert second["question"]["id"] != fid


def test_next_question_wraps_when_all_asked():
    pool = [q["id"] for q in M.questions_for("viva")]
    res = M.next_question("viva", pool)
    assert res["wrapped"] is True
    assert res["question"] is not None  # keeps practising


def test_next_question_bad_category():
    res = M.next_question("nope", [])
    assert "bad_category" in res["problems"]
    assert res["question"] is None


def test_next_question_deterministic():
    a = M.next_question("hr", ["hr_conflict"])
    b = M.next_question("hr", ["hr_conflict"])
    assert a == b


# --------------------------------------------------------------- feedback rubric

def test_feedback_too_short():
    fb = M.feedback("job_tellme", "I am good.")
    assert fb["level"] == "too_short"
    assert "tip_longer" in fb["tips"]
    assert fb["ai_required"] is False and fb["mock"] is True
    assert fb["marker"] == M.MARKER_KEY


def test_feedback_strong_needs_length_and_coverage():
    ans = ("In my current role I built strong experience leading a small team. "
           "My core skill is planning, and my goal is to grow into a lead "
           "position. A key strength is that I learn fast and deliver results "
           "for the team every single week without fail here.")
    fb = M.feedback("job_tellme", ans)
    assert fb["level"] == "strong", fb
    assert fb["coverage"] >= M._COVERAGE_STRONG
    assert "tip_strong" in fb["tips"]


def test_feedback_coverage_matches_and_missing():
    fb = M.feedback("tech_api", "An API is a request and response interface.")
    assert "api" in fb["matched"] and "request" in fb["matched"]
    assert "service" in fb["missing"]
    assert 0.0 <= fb["coverage"] <= 1.0


def test_feedback_bad_question():
    fb = M.feedback("does_not_exist", "whatever")
    assert "bad_question" in fb["problems"]
    assert "bad_question" in fb["tips"]


def test_feedback_deterministic():
    a = M.feedback("hr_mistake", "I made a mistake once and I learned from it.")
    b = M.feedback("hr_mistake", "I made a mistake once and I learned from it.")
    assert a == b


def test_feedback_honest_flags_never_ai():
    for q in M.BANK:
        fb = M.feedback(q["id"], "a decent length answer here for the rubric.")
        assert fb["ai_required"] is False
        assert fb["mock"] is True


# --------------------------------------------------------------- outline/progress

def test_model_outline_bilingual_for_known_id():
    o = M.model_outline("viva_project")
    assert o["outline_bn"] and o["outline_en"]
    assert isinstance(o["keywords"], list)


def test_model_outline_unknown_id_empty():
    o = M.model_outline("ghost")
    assert o["outline_bn"] == "" and o["outline_en"] == ""


def test_session_progress_counts():
    pool = [q["id"] for q in M.questions_for("technical")]
    half = pool[: len(pool) // 2]
    p = M.session_progress("technical", half)
    assert p["done"] == len(half)
    assert p["total"] == len(pool)
    assert 0 <= p["percent"] <= 100


# --------------------------------------------------------------- AI seam

def test_live_interview_seam_is_gated_and_mock():
    s = M.live_interview_seam("job_why", "Because I like the mission.")
    assert s["ai_required"] is True
    assert s["mock"] is True
    assert s["followup"] == "" and s["critique"] == ""  # never fabricated
    assert s["marker"] == M.MARKER_KEY


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"mock_interview: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
