"""
pa_minutes_tests_snippets.py — plain-assert tests for the PA meeting-minutes
engine (#110, §14, advanced §21). Pure stdlib.
`python pa_minutes_tests_snippets.py` or import and call run_all(). The engine
is deterministic, so every assertion is hand-verified against fixed inputs.
"""

try:  # Django harness
    from core.logic import pa_minutes as M
except ImportError:  # standalone
    import pa_minutes as M  # noqa: E402


def _entry(**kw):
    base = {
        "title": "Weekly sync",
        "date": "2026-10-14",
        "attendees": ["Rahman", "Karim", "Nadia"],
        "agenda": ["Budget review", "Hiring plan"],
        "decisions": ["Approve Q4 budget"],
        "actions": [
            {"title": "Send budget sheet", "owner": "Karim",
             "due": "2026-10-20", "status": "open"},
            {"title": "Post job ad", "owner": "Nadia",
             "due": "2026-10-16", "status": "done"},
            {"title": "Book venue", "owner": "Rahman", "due": "",
             "status": "doing"},
        ],
    }
    base.update(kw)
    return base


# --------------------------------------------------------------- normalise

def test_normalise_status_known_and_fallback():
    assert M.normalise_status("Done") == "done"
    assert M.normalise_status(" DOING ") == "doing"
    assert M.normalise_status("nonsense") == "open"
    assert M.normalise_status("") == "open"


def test_clean_list_from_string_and_list():
    assert M._clean_list("a\nb\n\nc") == ["a", "b", "c"]
    assert M._clean_list([" x ", "", "y"]) == ["x", "y"]
    assert M._clean_list(None) == []


def test_normalise_action_defaults():
    a = M.normalise_action({"title": "  Do it ", "owner": "A",
                            "status": "junk"})
    assert a == {"title": "Do it", "owner": "A", "due": "", "status": "open"}


# --------------------------------------------------------------- validate

def test_validate_ok():
    assert M.validate(**{k: v for k, v in _entry().items()}) == []


def test_validate_title_required():
    assert "title_required" in M.validate("   ")


def test_validate_bad_action():
    bad = M.validate("T", actions=[{"title": ""}])
    assert "bad_action" in bad


def test_validate_action_needs_title():
    assert "action_title_required" in M.validate_action({"owner": "A"})
    assert M.validate_action({"title": "x"}) == []


# --------------------------------------------------------------- ordering

def test_order_actions_not_done_first_then_due_then_title():
    ordered = M.order_actions(_entry()["actions"])
    titles = [a["title"] for a in ordered]
    # not-done sorted by due: 2026-10-20 (Send), then no-due (Book);
    # done (Post job ad) sorts last
    assert titles == ["Send budget sheet", "Book venue", "Post job ad"]


def test_order_actions_nonmutating():
    src = _entry()["actions"]
    before = [dict(a) for a in src]
    _ = M.order_actions(src)
    assert src == before


# --------------------------------------------------------------- build

def test_build_minutes_shape_and_honest_seam():
    e = M.build_minutes(**_entry())
    assert e["title"] == "Weekly sync"
    assert e["attendees"] == ["Rahman", "Karim", "Nadia"]
    assert len(e["actions"]) == 3
    assert e["stt_state"] == M.STT_LOCKED
    assert e["ai_required"] is False and e["mock"] is True
    assert e["problems"] == []


def test_build_minutes_empty_sections_ok():
    e = M.build_minutes("Standup")
    assert e["agenda"] == [] and e["decisions"] == [] and e["actions"] == []
    assert e["problems"] == []


# --------------------------------------------------------------- stt state

def test_transcription_state_locked_and_ready():
    locked = M.transcription_state(False)
    assert locked["state"] == M.STT_LOCKED
    assert locked["can_autominutes"] is False and locked["key"] == "transcription"
    ready = M.transcription_state(True)
    assert ready["state"] == M.STT_READY and ready["can_autominutes"] is True


# --------------------------------------------------------------- action rows

def test_action_rows_flatten_with_meeting_id():
    rows = M.action_rows(_entry(), meeting_id="m7")
    assert all(r["meeting_id"] == "m7" for r in rows)
    assert [r["title"] for r in rows][0] == "Send budget sheet"  # ordered


# --------------------------------------------------------------- summary

def test_summarise_counts_and_sections():
    s = M.summarise(_entry())
    assert s["attendee_count"] == 3
    assert s["open_actions"] == 2 and s["done_actions"] == 1
    assert s["sections"] == ["attendees", "agenda", "decisions", "actions"]
    assert s["mock"] is True and s["ai_required"] is False


def test_summarise_omits_empty_sections_never_pads():
    s = M.summarise({"title": "Quick chat"})
    assert s["sections"] == []           # nothing invented
    assert s["agenda"] == [] and s["decisions"] == []
    assert s["open_actions"] == 0 and s["done_actions"] == 0


def test_summarise_is_deterministic():
    assert M.summarise(_entry()) == M.summarise(_entry())


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"pa_minutes: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
