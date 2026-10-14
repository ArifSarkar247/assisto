"""
language_partner_tests_snippets.py — plain-assert tests for the LANGUAGE-
LEARNING PARTNER engine (#132, §21). Pure stdlib. Deterministic (no clock —
today's day-number is passed in), so every assertion is hand-verified.
"""

try:  # Django harness
    from core.logic import language_partner as L
except ImportError:  # standalone
    import language_partner as L  # noqa: E402


# --------------------------------------------------------------- deck content

def test_deck_has_enough_bilingual_cards():
    assert len(L.DECK) >= 20, len(L.DECK)
    for c in L.DECK:
        for k in ("id", "deck", "bn", "en", "hint"):
            assert c[k] not in ("", None), (c["id"], k)
        assert c["deck"] in L.DECKS


def test_card_ids_unique():
    ids = [c["id"] for c in L.DECK]
    assert len(ids) == len(set(ids))


def test_all_decks_present():
    decks = {c["deck"] for c in L.DECK}
    assert decks == set(L.DECKS), decks


# --------------------------------------------------------------- prompt/answer

def test_prompt_answer_bn2en():
    pa = L.prompt_answer("g_hello", "bn2en")
    assert pa["prompt"] and pa["answer"] == "Hello"
    assert pa["hint"]  # romanised pronunciation hint present


def test_prompt_answer_en2bn_flips():
    pa = L.prompt_answer("g_hello", "en2bn")
    assert pa["prompt"] == "Hello"
    assert pa["answer"]  # the bangla side


def test_prompt_answer_deterministic():
    assert L.prompt_answer("d_water", "bn2en") == L.prompt_answer("d_water", "bn2en")


# --------------------------------------------------------------- spaced rep

def test_pass_promotes_box():
    r = L.schedule_review(2, True, 100)
    assert r["box"] == 3
    assert r["interval_days"] == L.due_after_days(3)
    assert r["next_due_day"] == 100 + r["interval_days"]


def test_fail_resets_to_box_one():
    r = L.schedule_review(4, False, 50)
    assert r["box"] == 1
    assert r["next_due_day"] == 50 + L.due_after_days(1)


def test_box_caps_at_max():
    r = L.schedule_review(L.MAX_BOX, True, 0)
    assert r["box"] == L.MAX_BOX


def test_intervals_increase_with_box():
    days = [L.due_after_days(b) for b in range(1, L.MAX_BOX + 1)]
    assert days == sorted(days)
    assert days[0] < days[-1]


def test_schedule_deterministic():
    assert L.schedule_review(3, True, 200) == L.schedule_review(3, True, 200)


def test_due_cards_includes_unstudied_and_overdue():
    progress = [
        {"card_id": "g_hello", "box": 2, "next_due_day": 5},   # due at day 10
        {"card_id": "g_thanks", "box": 3, "next_due_day": 99},  # not due yet
    ]
    due = L.due_cards(progress, 10)
    assert "g_hello" in due          # overdue
    assert "g_thanks" not in due     # future
    assert "d_water" in due          # never studied → due


def test_deck_progress_rollup():
    progress = [{"card_id": "n_one", "box": 5, "next_due_day": 0},
                {"card_id": "n_two", "box": 3, "next_due_day": 0}]
    p = L.deck_progress("numbers", progress)
    assert p["started"] == 2
    assert p["total"] == len(L.cards_for("numbers"))
    assert p["mastered"] == 1  # n_one at MAX_BOX
    assert p["avg_box"] == 4.0


# --------------------------------------------------------------- quiz

def test_quiz_builds_questions_with_valid_answer_index():
    qz = L.quiz("greetings", "bn2en", seed=0)
    assert qz["problems"] == []
    assert len(qz["questions"]) == len(L.cards_for("greetings"))
    for q in qz["questions"]:
        assert 0 <= q["answer_index"] < len(q["options"])
        assert q["options"][q["answer_index"]]  # the correct answer is present


def test_quiz_deterministic():
    assert L.quiz("daily", "en2bn", 3) == L.quiz("daily", "en2bn", 3)


def test_quiz_grade_all_correct():
    qz = L.quiz("travel", "bn2en", 1)
    answers = [q["answer_index"] for q in qz["questions"]]
    g = L.grade_quiz(qz["questions"], answers)
    assert g["correct"] == g["total"]
    assert g["percent"] == 100
    assert g["wrong_card_ids"] == []


def test_quiz_grade_counts_wrong_and_missing():
    qz = L.quiz("shopping", "bn2en", 0)
    # answer everything wrong by shifting index
    answers = [(q["answer_index"] + 1) % len(q["options"]) for q in qz["questions"]]
    g = L.grade_quiz(qz["questions"], answers)
    assert g["correct"] == 0
    assert len(g["wrong_card_ids"]) == g["total"]


# --------------------------------------------------------------- AI seam

def test_live_conversation_seam_is_gated_and_mock():
    s = L.live_conversation_seam("daily", "I want rice please")
    assert s["ai_required"] is True
    assert s["mock"] is True
    assert s["reply"] == "" and s["correction"] == ""  # never fabricated
    assert s["marker"] == L.MARKER_KEY


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"language_partner: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
