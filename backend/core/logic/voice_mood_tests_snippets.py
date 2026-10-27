"""
voice_mood_tests_snippets.py — plain-assert tests for core.logic.voice_mood.

NOT a Django TestCase. Smoke locally:

    python3 -c "import core.logic.voice_mood_tests_snippets as t; t.run_all()"
"""
from core.logic import voice_mood as V


def test_date_key_normalises_and_rejects():
    assert V._date_key("2026-10-14") == "2026-10-14"
    assert V._date_key("2026-10-14T08:30:00") == "2026-10-14"
    assert V._date_key("2026-1-5") == "2026-01-05"
    assert V._date_key("") is None
    assert V._date_key("not-a-date") is None
    assert V._date_key("2026-13-01") is None


def test_energy_clamps():
    assert V._coerce_energy(3) == 3
    assert V._coerce_energy("4") == 4
    assert V._coerce_energy(99) == V.ENERGY_MAX
    assert V._coerce_energy(-5) == V.ENERGY_MIN
    assert V._coerce_energy(None) == 0
    assert V._coerce_energy("junk") == 0


def test_day_index_roundtrip():
    for iso in ("2026-10-14", "2000-01-01", "1999-12-31", "2026-02-28"):
        assert V._iso_from_index(V._day_index(iso)) == iso


def test_day_index_consecutive():
    a = V._day_index("2026-10-14")
    b = V._day_index("2026-10-15")
    assert b - a == 1


def test_validate():
    assert V.validate("good", date="2026-10-14") == []
    assert "bad_mood" in V.validate("euphoric", date="2026-10-14")
    assert "bad_date" in V.validate("good", date="nope")


def test_fold_latest_wins_and_skips_bad():
    rows = [
        {"id": 1, "mood": "low", "date": "2026-10-14"},
        {"id": 2, "mood": "good", "date": "2026-10-14"},   # later → wins
        {"id": 3, "mood": "bogus", "date": "2026-10-13"},  # skipped
        {"id": 4, "mood": "ok", "date": "bad"},            # skipped
    ]
    f = V.fold_by_day(rows)
    assert set(f.keys()) == {"2026-10-14"}
    assert f["2026-10-14"]["mood"] == "good"
    assert f["2026-10-14"]["score"] == 4


def test_trend_window_and_averages():
    rows = [
        {"id": 1, "mood": "ok", "energy": 3, "date": "2026-10-10"},
        {"id": 2, "mood": "good", "energy": 4, "date": "2026-10-12"},
        {"id": 3, "mood": "great", "date": "2026-10-14"},   # energy unrated
        {"id": 4, "mood": "low", "date": "2026-09-01"},     # outside window
    ]
    tr = V.trend(rows, "2026-10-14")
    assert tr["days"] == 7
    assert len(tr["series"]) == 7
    assert tr["logged_days"] == 3
    # (3 + 4 + 5) / 3 = 4.0
    assert tr["avg_score"] == 4.0
    # energy only rated on 2 of the 3 days → (3+4)/2 = 3.5
    assert tr["avg_energy"] == 3.5
    assert tr["series"][-1]["date"] == "2026-10-14"
    assert tr["series"][0]["date"] == "2026-10-08"


def test_trend_empty_on_bad_today():
    tr = V.trend([{"mood": "ok", "date": "2026-10-14"}], "junk")
    assert tr["logged_days"] == 0
    assert tr["series"] == []


def test_persistently_low_needs_enough_days():
    # one bad day never trips it
    tr1 = V.trend([{"id": 1, "mood": "low", "date": "2026-10-14"}],
                  "2026-10-14")
    assert tr1["persistently_low"] is False
    # three low days does
    rows = [
        {"id": 1, "mood": "low", "date": "2026-10-12"},
        {"id": 2, "mood": "down", "date": "2026-10-13"},
        {"id": 3, "mood": "low", "date": "2026-10-14"},
    ]
    tr2 = V.trend(rows, "2026-10-14")
    assert tr2["persistently_low"] is True
    assert tr2["low_streak"] == 3


def test_low_streak_breaks_on_gap_or_good_day():
    rows = [
        {"id": 1, "mood": "low", "date": "2026-10-12"},
        {"id": 2, "mood": "good", "date": "2026-10-13"},   # breaks streak
        {"id": 3, "mood": "low", "date": "2026-10-14"},
    ]
    tr = V.trend(rows, "2026-10-14")
    assert tr["low_streak"] == 1


def test_suggestions_are_keys_and_add_support_when_low():
    s = V.suggestions("great")
    assert "support" not in s
    s2 = V.suggestions("great", persistently_low=True)
    assert s2[-1] == "support"
    s3 = V.suggestions("low")
    assert "support" in s3  # low bucket already includes it, no dupe
    assert s3.count("support") == 1


def test_check_in_includes_itself_in_trend():
    res = V.check_in("good", energy=4, date="2026-10-14", rows=[],
                     today="2026-10-14")
    assert res["problems"] == []
    assert res["mock"] is False
    assert res["on_device"] is True
    assert res["ai_required"] is False
    assert res["trend"]["logged_days"] == 1
    assert "keep_going" in res["suggestions"]


def test_check_in_bad_input_returns_problems():
    res = V.check_in("nope", date="bad")
    assert "bad_mood" in res["problems"]
    assert "bad_date" in res["problems"]
    assert res["trend"] is None
    assert res["suggestions"] == []


def run_all():
    import inspect
    import sys
    mod = sys.modules[__name__]
    tests = [f for n, f in inspect.getmembers(mod, inspect.isfunction)
             if n.startswith("test_")]
    for fn in tests:
        fn()
    print(f"voice_mood: {len(tests)} tests passed")


if __name__ == "__main__":
    run_all()
