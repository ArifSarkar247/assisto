"""
pa_lifestyle_tests_snippets.py — plain-assert tests for the PA personal
lifestyle manager (#125, §14). Pure stdlib. Deterministic (split from a
passed-in `now`); the reminder seam never sends and never fabricates.
"""
from datetime import datetime

try:  # Django harness
    from core.logic import pa_lifestyle as L
except ImportError:  # standalone
    import pa_lifestyle as L  # noqa: E402


NOW = datetime(2026, 10, 14, 12, 0, 0)


# --------------------------------------------------------------- normalize
def test_normalize_appt_category_fallback():
    a = L.normalize_appt({"category": "zzz", "title": "  Haircut  "})
    assert a["category"] == L.CAT_OTHER and a["title"] == "Haircut"


def test_normalize_pref_default_topic():
    p = L.normalize_pref({"text": "  no nuts  "})
    assert p["topic"] == "general" and p["text"] == "no nuts"


def test_normalize_routine_slot_fallback():
    r = L.normalize_routine({"slot": "midnight", "label": "Yoga"})
    assert r["slot"] == L.SLOT_MORNING and r["label"] == "Yoga"


# --------------------------------------------------------------- validate
def test_validate():
    assert L.validate_appt({"title": "Gym"}) == []
    assert "title_required" in L.validate_appt({"title": " "})
    assert "bad_at" in L.validate_appt({"title": "x", "at": "nope"})
    assert "text_required" in L.validate_pref({"text": " "})
    assert "label_required" in L.validate_routine({"label": " "})


# --------------------------------------------------------------- ordering
def test_order_appts_soonest_first_undated_last():
    appts = [
        {"id": 1, "title": "a", "at": ""},
        {"id": 2, "title": "b", "at": "2026-11-01T10:00"},
        {"id": 3, "title": "c", "at": "2026-10-20T10:00"},
    ]
    out = L.order_appts(appts)
    assert [x["id"] for x in out] == [3, 2, 1]


# --------------------------------------------------------------- split
def test_split_appts_upcoming_vs_past():
    appts = [
        {"id": 1, "title": "future", "at": "2026-11-01T10:00"},
        {"id": 2, "title": "past", "at": "2026-10-01T10:00"},
        {"id": 3, "title": "undated", "at": ""},
    ]
    s = L.split_appts(appts, NOW)
    assert s["upcoming_count"] == 2 and s["past_count"] == 1
    assert s["past"][0]["id"] == 2


# --------------------------------------------------------------- routines
def test_group_routines_day_order_and_time_sort():
    routines = [
        {"id": 1, "slot": "night", "label": "Sleep", "time": "22:00"},
        {"id": 2, "slot": "morning", "label": "Run", "time": "06:00"},
        {"id": 3, "slot": "morning", "label": "Breakfast", "time": ""},
    ]
    groups = L.group_routines(routines)
    assert [g["slot"] for g in groups] == list(L.ROUTINE_SLOTS)
    morning = groups[0]
    assert morning["slot"] == L.SLOT_MORNING
    # timed before untimed within slot
    assert [i["id"] for i in morning["items"]] == [2, 3]
    night = groups[-1]
    assert [i["id"] for i in night["items"]] == [1]


# --------------------------------------------------------------- prefs
def test_prefs_by_topic_grouped_alpha():
    prefs = [
        {"topic": "wardrobe", "text": "dark suits"},
        {"topic": "diet", "text": "no nuts"},
        {"topic": "diet", "text": "green tea"},
        {"topic": "diet", "text": ""},   # dropped (no text)
    ]
    r = L.prefs_by_topic(prefs)
    assert r["count"] == 3
    assert [g["topic"] for g in r["groups"]] == ["diet", "wardrobe"]
    diet = r["groups"][0]["items"]
    assert len(diet) == 2


# --------------------------------------------------------------- seam
def test_reminder_seam_is_honest_and_sends_nothing():
    r = L.reminder_seam({"id": 7, "title": "Salon"})
    assert r["required"] is True and r["mock"] is True
    assert r["scheduled"] == []          # never sends / fabricates
    assert r["appt_id"] == 7
    assert r["marker"] == L.REMINDER_MARKER_KEY


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"pa_lifestyle: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
