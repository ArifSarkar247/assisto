"""
pa_shoot_tests_snippets.py — plain-assert tests for the PA shooting / concert
logistics call-sheet builder (#124, §14). Pure stdlib. Deterministic.
"""
try:  # Django harness
    from core.logic import pa_shoot as H
except ImportError:  # standalone
    import pa_shoot as H  # noqa: E402


# --------------------------------------------------------------- normalize
def test_normalize_sheet_and_block_fallback():
    s = H.normalize_sheet({"title": "  Day 1  "})
    assert s["title"] == "Day 1"
    b = H.normalize_block({"kind": "zzz", "label": " set "})
    assert b["kind"] == H.BLK_OTHER and b["label"] == "set"


def test_normalize_check_default_kind():
    c = H.normalize_check({"label": "Lav mic", "checked": 1})
    assert c["kind"] == "equipment" and c["checked"] is True


def test_parse_time_hhmm_and_datetime():
    assert H._parse_time("09:30") == 570
    assert H._parse_time("2026-10-14T08:15") == 495
    assert H._parse_time("25:00") is None
    assert H._parse_time("nope") is None


# --------------------------------------------------------------- validate
def test_validate_sheet():
    assert H.validate_sheet({"title": "Shoot"}) == []
    assert "title_required" in H.validate_sheet({"title": " "})
    assert "bad_date" in H.validate_sheet({"title": "x", "date": "nope"})


def test_validate_block_end_before_start():
    assert H.validate_block({"label": "Scene 1", "start": "09:00",
                            "end": "11:00"}) == []
    assert "label_required" in H.validate_block({"label": " "})
    assert "end_before_start" in H.validate_block(
        {"label": "x", "start": "14:00", "end": "09:00"})
    assert "bad_start" in H.validate_block({"label": "x", "start": "99:99"})


# --------------------------------------------------------------- ordering
def test_order_blocks_chronological_untimed_last():
    blocks = [
        {"id": 1, "label": "a", "start": ""},
        {"id": 2, "label": "b", "start": "14:00"},
        {"id": 3, "label": "c", "start": "08:30"},
    ]
    out = H.order_blocks(blocks)
    assert [x["id"] for x in out] == [3, 2, 1]


def test_order_blocks_is_pure():
    blocks = [{"id": 1, "label": "a"}]
    H.order_blocks(blocks)
    assert blocks == [{"id": 1, "label": "a"}]


# --------------------------------------------------------------- progress
def test_checklist_progress_overall_and_by_kind():
    items = [
        {"kind": "wardrobe", "label": "Suit", "checked": True},
        {"kind": "wardrobe", "label": "Shoes", "checked": False},
        {"kind": "equipment", "label": "Guitar", "checked": True},
    ]
    assert H.checklist_progress(items) == {"total": 3, "checked": 2, "percent": 66}
    assert H.checklist_progress(items, kind="wardrobe") == {
        "total": 2, "checked": 1, "percent": 50}
    assert H.checklist_progress([]) == {"total": 0, "checked": 0, "percent": 0}


# --------------------------------------------------------------- summary
def test_callsheet_summary_counts():
    s = H.callsheet_summary(
        {"title": "Concert", "date": "2026-11-20", "call_time": "16:00"},
        blocks=[{"id": 1, "label": "Soundcheck", "kind": "soundcheck",
                 "start": "17:00"}],
        contacts=[{"id": 2, "name": "FOH Eng", "role": "Sound"}],
        checks=[{"kind": "equipment", "label": "Mic", "checked": True}],
    )
    assert s["counts"] == {"blocks": 1, "contacts": 1, "checks": 1}
    assert s["checklist"]["percent"] == 100
    assert s["sheet"]["title"] == "Concert"
    assert s["mock"] is False


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"pa_shoot: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
