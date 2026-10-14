"""
daily_challenges_tests_snippets.py — plain-assert tests for the DAILY CHALLENGE
/ QUIZ engine (#173, §21). Pure stdlib. `python daily_challenges_tests_snippets.py`
or import and call run_all(). The engine is deterministic, so every assertion
is hand-verified against fixed inputs.
"""

try:  # Django harness
    from core.logic import daily_challenges as D
except ImportError:  # standalone
    import daily_challenges as D  # noqa: E402


# ---------------------------------------------------------------- bank quality
def test_bank_has_at_least_20_items():
    assert len(D.BANK) >= 20, len(D.BANK)


def test_bank_ids_unique_and_indexed():
    ids = [it["id"] for it in D.BANK]
    assert len(ids) == len(set(ids))
    for it in D.BANK:
        assert D.BANK_BY_ID[it["id"]] is it


def test_bank_covers_all_four_categories():
    cats = {it["cat"] for it in D.BANK}
    assert cats == set(D.CATEGORIES), cats


def test_bank_item_shapes_valid():
    for it in D.BANK:
        assert it["kind"] in ("quiz", "task")
        assert isinstance(it["q"], tuple) and len(it["q"]) == 2
        assert isinstance(it["explain"], tuple) and len(it["explain"]) == 2
        if it["kind"] == "quiz":
            assert len(it["options"]) >= 2
            assert isinstance(it["answer"], int)
            assert 0 <= it["answer"] < len(it["options"])
            for o in it["options"]:
                assert isinstance(o, tuple) and len(o) == 2
        else:
            assert it["options"] == []
            assert it["answer"] is None


def test_known_facts_are_correct():
    # spot-check that the marked-correct option is the true fact
    def ans(item_id):
        it = D.BANK_BY_ID[item_id]
        return it["options"][it["answer"]][1]  # english text
    assert ans("gen_bd_capital") == "Dhaka"
    assert ans("gen_water_boil") == "100°"
    assert ans("gen_continents") == "7"
    assert ans("safe_otp") == "Never share it"
    assert ans("fin_emergency_fund") == "3–6 months"


# ---------------------------------------------------------------- determinism
def test_daily_index_wraps_within_bank():
    for ds in ("2026-01-01", "2026-06-15", "2099-12-31"):
        idx = D.daily_index(ds)
        assert 0 <= idx < len(D.BANK)


def test_daily_is_deterministic_same_day():
    a = D.daily("2026-10-14", "bn")
    b = D.daily("2026-10-14", "bn")
    assert a == b
    assert a["item_id"] == D.daily("2026-10-14", "en")["item_id"]


def test_daily_advances_by_one_each_day():
    i1 = D.daily_index("2026-10-14")
    i2 = D.daily_index("2026-10-15")
    assert i2 == (i1 + 1) % len(D.BANK)


def test_daily_bad_date_is_honest():
    out = D.daily("not-a-date")
    assert out["ok"] is False and out["reason"] == "bad_date"
    assert D.daily_index("2026-13-40") is None


def test_daily_presentation_localized_and_honest_flags():
    bn = D.daily("2026-03-21", "bn")
    en = D.daily("2026-03-21", "en")
    assert bn["ok"] is True
    assert bn["question"] != en["question"]  # different language text
    assert bn["ai_required"] is False
    assert bn["deterministic"] is True
    assert bn["mock"] is False  # curated real facts, not mock AI


def test_by_id_roundtrips_and_rejects_unknown():
    it = D.BANK[0]
    p = D.by_id(it["id"], "2026-01-01", "en")
    assert p["ok"] is True and p["item_id"] == it["id"]
    assert D.by_id("nope", "2026-01-01")["ok"] is False


# ---------------------------------------------------------------- scoring
def test_quiz_correct_and_wrong_points():
    it = next(i for i in D.BANK if i["kind"] == "quiz")
    good = D.score(it["id"], it["answer"])
    assert good["correct"] is True and good["points"] == D.POINTS_CORRECT
    wrong_idx = (it["answer"] + 1) % len(it["options"])
    bad = D.score(it["id"], wrong_idx)
    assert bad["correct"] is False and bad["points"] == D.POINTS_TRY


def test_quiz_skip_scores_zero():
    it = next(i for i in D.BANK if i["kind"] == "quiz")
    s = D.score(it["id"], None)
    assert s["correct"] is False and s["points"] == 0


def test_task_done_scores_task_points():
    it = next(i for i in D.BANK if i["kind"] == "task")
    s = D.score(it["id"], 1)
    assert s["correct"] is True and s["points"] == D.POINTS_TASK
    # not done
    assert D.score(it["id"], None)["points"] == 0


def test_score_unknown_item_scores_zero():
    s = D.score("ghost_item", 0)
    assert s["points"] == 0 and s["reason"] == "unknown_item"


def test_build_progress_row_shape():
    it = next(i for i in D.BANK if i["kind"] == "quiz")
    row = D.build_progress_row(it["id"], it["answer"])
    for k in ("item_id", "kind", "answer", "correct", "points"):
        assert k in row
    assert "id" not in row  # collection assigns the id
    assert row["correct"] is True


# ---------------------------------------------------------------- streak
def _row(date, item_id, answer=1, points=5):
    return {"date": date, "item_id": item_id, "answer": answer,
            "kind": D.BANK_BY_ID[item_id]["kind"], "points": points}


def test_streak_counts_consecutive_ending_today():
    iid = D.BANK[0]["id"]
    rows = [_row("2026-10-12", iid), _row("2026-10-13", iid),
            _row("2026-10-14", iid)]
    assert D.streak(rows, "2026-10-14") == 3


def test_streak_allows_yesterday_anchor():
    iid = D.BANK[0]["id"]
    rows = [_row("2026-10-12", iid), _row("2026-10-13", iid)]
    # not done today yet, but yesterday done -> streak still current
    assert D.streak(rows, "2026-10-14") == 2


def test_streak_broken_by_gap_is_zero_when_old():
    iid = D.BANK[0]["id"]
    rows = [_row("2026-10-01", iid), _row("2026-10-02", iid)]
    assert D.streak(rows, "2026-10-14") == 0  # ended long ago -> over


def test_streak_ignores_skipped_rows():
    iid = D.BANK[0]["id"]
    rows = [_row("2026-10-13", iid), _row("2026-10-14", iid, answer=None)]
    # today's row is a skip (answer None) -> today doesn't count; yesterday does
    assert D.streak(rows, "2026-10-14") == 1


def test_longest_streak_tracks_best_past_run():
    iid = D.BANK[0]["id"]
    rows = [_row("2026-01-01", iid), _row("2026-01-02", iid),
            _row("2026-01-03", iid), _row("2026-02-01", iid)]
    assert D.longest_streak(rows) == 3


# ---------------------------------------------------------------- summary/seam
def test_summarise_totals_points_and_accuracy():
    q = next(i for i in D.BANK if i["kind"] == "quiz")
    t = next(i for i in D.BANK if i["kind"] == "task")
    rows = [
        {"date": "2026-10-14", "item_id": q["id"], "kind": "quiz",
         "answer": q["answer"], "correct": True, "points": D.POINTS_CORRECT},
        {"date": "2026-10-13", "item_id": q["id"], "kind": "quiz",
         "answer": (q["answer"] + 1) % len(q["options"]), "correct": False,
         "points": D.POINTS_TRY},
        {"date": "2026-10-12", "item_id": t["id"], "kind": "task",
         "answer": 1, "correct": True, "points": D.POINTS_TASK},
    ]
    s = D.summarise(rows, "2026-10-14")
    assert s["total_points"] == D.POINTS_CORRECT + D.POINTS_TRY + D.POINTS_TASK
    assert s["total_completed"] == 3
    assert s["quiz_attempts"] == 2 and s["correct_count"] == 1
    assert s["accuracy"] == 50
    assert s["current_streak"] == 3
    assert s["done_today"] is True


def test_summarise_empty_is_honest():
    s = D.summarise([], "2026-10-14")
    assert s["total_points"] == 0 and s["total_completed"] == 0
    assert s["accuracy"] is None  # no quizzes -> no accuracy, not 0%
    assert s["done_today"] is False


def test_points_never_hold_money_seam_returns_days_only():
    # the seam only reports how many Premium days points WOULD buy; it never
    # grants anything. 25 pts/day default -> 100 pts == 4 days.
    assert D.premium_days_from_points(100) == 4
    assert D.premium_days_from_points(0) == 0
    assert D.premium_days_from_points(-5) == 0


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"daily_challenges: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
