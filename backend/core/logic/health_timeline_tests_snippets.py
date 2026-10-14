"""
health_timeline_tests_snippets.py — plain-assert tests for the HEALTH-TIMELINE
logic (#69, §10). Pure stdlib. `python3 health_timeline_tests_snippets.py` or
import and call run_all(). The logic is deterministic (time passed in), so every
assertion is hand-verified against fixed inputs.
"""

try:  # Django harness
    from core.logic import health_timeline as H
except ImportError:  # standalone
    import health_timeline as H  # noqa: E402


def _rows():
    return [
        {"id": 1, "category": "visit", "title": "Dr. Rahman checkup",
         "date": "2026-01-10", "doctor": "Dr. Rahman"},
        {"id": 2, "category": "test", "title": "Blood sugar report",
         "date": "2026-03-05", "place": "Popular Diagnostic"},
        {"id": 3, "category": "vaccination", "title": "Flu shot",
         "date": "2026-03-05"},
        {"id": 4, "category": "symptom", "title": "Headache",
         "date": ""},  # undated
        {"id": 5, "category": "weird", "title": "Dentist",
         "date": "2026-02-20"},  # unknown category -> other
    ]


# --------------------------------------------------------------- categories

def test_norm_category_known_and_unknown():
    assert H.norm_category("visit") == "visit"
    assert H.norm_category("VISIT") == "visit"
    assert H.norm_category("weird") == "other"
    assert H.norm_category(None) == "other"


# --------------------------------------------------------------- normalise

def test_normalize_undated_is_honest():
    e = H.normalize({"id": 9, "title": "x", "date": "not-a-date"})
    assert e["undated"] is True
    assert e["date"] is None


def test_normalize_keeps_id_and_trims():
    e = H.normalize({"id": 7, "title": "  Fever  ", "notes": " hi "})
    assert e["id"] == 7
    assert e["title"] == "Fever"
    assert e["notes"] == "hi"


# --------------------------------------------------------------- ordering

def test_order_is_newest_first_deterministic():
    ev = H.order_events(_rows())
    dates = [e["date"] for e in ev]
    # newest dated first, undated last
    assert dates[0] == "2026-03-05"
    assert dates[-1] is None
    # deterministic: same input same output
    assert H.order_events(_rows()) == ev


def test_order_tiebreak_stable_by_id_desc():
    # two same-date events (ids 2 and 3) — id desc tie-break => 3 before 2
    ev = H.order_events(_rows())
    same = [e for e in ev if e["date"] == "2026-03-05"]
    assert [e["id"] for e in same] == [3, 2]


# --------------------------------------------------------------- filtering

def test_filter_by_category():
    out = H.filter_events(_rows(), categories=["test"])
    assert len(out) == 1 and out[0]["id"] == 2


def test_filter_by_query_substring_ci():
    out = H.filter_events(_rows(), query="rahman")
    assert len(out) == 1 and out[0]["id"] == 1


def test_filter_empty_means_all():
    assert len(H.filter_events(_rows())) == 5


# --------------------------------------------------------------- grouping

def test_group_by_month_newest_first_undated_last():
    g = H.group_by_month(_rows())
    keys = [b["key"] for b in g]
    assert keys[0] == "2026-03"
    assert keys[-1] == "undated"
    # March bucket holds both same-date events
    march = next(b for b in g if b["key"] == "2026-03")
    assert march["count"] == 2


def test_group_by_category_in_fixed_order():
    g = H.group_by_category(_rows())
    cats = [b["category"] for b in g]
    # only non-empty categories, in CATEGORIES order
    assert cats == ["visit", "test", "vaccination", "symptom", "other"]


# --------------------------------------------------------------- summary

def test_category_counts_every_category_present():
    c = H.category_counts(_rows())
    assert set(c.keys()) == set(H.CATEGORIES)
    assert c["visit"] == 1 and c["other"] == 1 and c["prescription"] == 0


def test_summary_days_since_last_from_passed_in_today():
    s = H.summary(_rows(), today="2026-03-15")
    assert s["total"] == 5
    assert s["dated"] == 4 and s["undated"] == 1
    assert s["last_event_date"] == "2026-03-05"
    assert s["days_since_last"] == 10


def test_summary_no_dated_events():
    s = H.summary([{"id": 1, "title": "x", "date": ""}], today="2026-03-15")
    assert s["last_event_date"] is None
    assert s["days_since_last"] is None


# --------------------------------------------------------------- validation

def test_validate_requires_title():
    assert "title_required" in H.validate("visit", "   ", "2026-01-01")
    assert H.validate("visit", "ok", "2026-01-01") == []


def test_validate_rejects_bad_date_but_allows_blank():
    assert "bad_date" in H.validate("visit", "ok", "garbage")
    assert H.validate("visit", "ok", "") == []


# --------------------------------------------------------------- disclaimer

def test_disclaimer_is_bilingual_and_not_advice():
    d = H.disclaimer()
    assert "bn" in d and "en" in d
    assert "not medical advice" in d["en"].lower()


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"health_timeline: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
