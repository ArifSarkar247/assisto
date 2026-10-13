"""
exam_tests_snippets.py — plain-assert tests for core.logic.exam.
NOT a Django TestCase. Smoke:
    python3 -c "import core.logic.exam_tests_snippets as t; t.run_all()"
"""
from datetime import datetime

from core.logic import exam as E


def test_normalise_requires_url_or_date():
    ok, err = E.normalise_watcher({})
    assert not ok and err == "url_or_date_required", (ok, err)
    ok, err = E.normalise_watcher({"url": "ftp://x"})
    assert not ok and err == "url_invalid", (ok, err)
    ok, data = E.normalise_watcher(
        {"url": "https://results.example.gov.bd", "label": " SSC ", "roll": "123"})
    assert ok and data["label"] == "SSC" and data["roll"] == "123"
    ok2, data2 = E.normalise_watcher({"expected_date": "2026-05-10T10:00"})
    assert ok2 and data2["expected_date"].startswith("2026-05-10")


def test_next_poll_sparse_before_day():
    now = datetime(2026, 5, 1, 10, 0)
    exp = "2026-05-10T10:00"
    assert E.next_poll_minutes(exp, now=now) == E.POLL_BEFORE_MIN


def test_next_poll_backoff_on_result_day():
    now = datetime(2026, 5, 10, 11, 0)
    exp = "2026-05-10T10:00"
    base = E.next_poll_minutes(exp, now=now, consecutive_failures=0)
    more = E.next_poll_minutes(exp, now=now, consecutive_failures=3)
    assert base == E.POLL_DAY_BASE_MIN
    assert more > base and more <= E.POLL_DAY_MAX_MIN


def test_is_result_day():
    exp = "2026-05-10T10:00"
    assert E.is_result_day(exp, now=datetime(2026, 5, 9, 23, 0)) is False
    assert E.is_result_day(exp, now=datetime(2026, 5, 10, 0, 1)) is True
    assert E.is_result_day(None) is False


def test_traffic_spike_note_bilingual():
    assert "overloaded" in E.traffic_spike_note("en")
    assert "ব্যস্ত" in E.traffic_spike_note("bn")


def test_snapshot_changed():
    assert E.snapshot_changed("hash_a", "hash_b") is True
    assert E.snapshot_changed("hash_a", "hash_a") is False
    assert E.snapshot_changed("hash_a", "") is False  # nothing fetched
    assert E.snapshot_changed(None, "new") is True


def test_watcher_phase():
    exp = "2026-05-10T10:00"
    assert E.watcher_phase(exp, now=datetime(2026, 5, 10, 11, 0),
                           result_ready=True) == ("ready", 0)
    state, days = E.watcher_phase(exp, now=datetime(2026, 5, 7, 10, 0))
    assert state == "waiting" and days == 3, (state, days)
    assert E.watcher_phase(exp, now=datetime(2026, 5, 10, 11, 0))[0] == "watching"
    assert E.watcher_phase(None)[0] == "watching"


def test_result_card_user_values_only():
    card = E.result_card(
        {"name": "Rahim", "exam": "SSC", "year": "2026", "roll": "123456",
         "board": "Dhaka", "gpa": "5.00"}, "en")
    assert card["kind"] == "exam_result_card"
    assert "SSC 2026" in card["text"]
    assert "Rahim" in card["text"] and "GPA: 5.00" in card["text"]
    # empty fields omitted, no fabrication
    sparse = E.result_card({"gpa": "4.5"}, "bn")
    assert "জিপিএ: 4.5" in sparse["text"]
    assert "Name" not in sparse["text"] and "নাম" not in sparse["text"]


def test_result_ready_payload():
    p = E.result_ready_payload("SSC", "en")
    assert p["kind"] == "exam_result_ready" and "SSC" in p["body"]


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"exam: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
