"""
pa_research_tests_snippets.py — plain-assert tests for PA research &
presentation organizer (#114, §14). Pure stdlib. Deterministic outline export.
`python pa_research_tests_snippets.py` or import and call run_all().
"""
try:  # Django harness
    from core.logic import pa_research as R
except ImportError:  # standalone
    import pa_research as R  # noqa: E402


# --------------------------------------------------------------- normalize
def test_normalize_item_bad_kind_falls_back():
    it = R.normalize_item({"kind": "weird", "text": " a note "})
    assert it["kind"] == R.KIND_NOTE
    assert it["text"] == "a note"


def test_normalize_section_bad_order():
    s = R.normalize_section({"heading": "  Intro ", "order": "oops"})
    assert s["order"] == 0 and s["heading"] == "Intro"


# --------------------------------------------------------------- validate
def test_validate_topic():
    assert R.validate_topic({"title": "x"}) == []
    assert "title_required" in R.validate_topic({"title": "   "})


def test_validate_item():
    assert R.validate_item({"kind": "note", "text": "hi"}) == []
    assert "text_required" in R.validate_item({"kind": "note", "text": ""})
    assert R.validate_item({"kind": "source", "ref": "http://x"}) == []
    assert "source_required" in R.validate_item({"kind": "source",
                                                 "text": "", "ref": ""})


def test_validate_section():
    assert R.validate_section({"heading": "Agenda"}) == []
    assert "heading_required" in R.validate_section({"heading": ""})


# --------------------------------------------------------------- queries
def test_notes_and_sources_split():
    items = [
        {"kind": "note", "text": "n1"},
        {"kind": "source", "text": "s1", "ref": "http://a"},
        {"kind": "note", "text": "n2"},
    ]
    assert [n["text"] for n in R.notes(items)] == ["n1", "n2"]
    assert [s["text"] for s in R.sources(items)] == ["s1"]


def test_order_sections_by_order_then_heading():
    secs = [
        {"id": 1, "heading": "Zed", "order": 2},
        {"id": 2, "heading": "Alpha", "order": 1},
        {"id": 3, "heading": "Beta", "order": 1},
    ]
    out = R.order_sections(secs)
    assert [s["id"] for s in out] == [2, 3, 1]  # order 1 (Alpha,Beta) then 2


def test_section_bullets_cleans_blank_lines():
    s = {"heading": "x", "bullets": " first \n\n  second  \n"}
    assert R.section_bullets(s) == ["first", "second"]


# --------------------------------------------------------------- summary
def test_research_summary_counts():
    s = R.research_summary(
        {"title": "Market entry"},
        items=[
            {"kind": "note", "text": "a"},
            {"kind": "source", "ref": "http://x"},
        ],
        sections=[{"heading": "Intro", "order": 1, "bullets": "p1\np2"}],
    )
    assert s["counts"] == {"notes": 1, "sources": 1, "sections": 1, "bullets": 2}
    assert s["ai_required"] is False and s["mock"] is False


# --------------------------------------------------------------- export
def test_outline_export_deterministic():
    out = R.outline_export(
        {"title": "Q4 Plan"},
        sections=[
            {"heading": "Goals", "order": 1, "bullets": "Grow\nHire"},
            {"heading": "Risks", "order": 2, "bullets": "Budget"},
        ],
    )
    expected = (
        "Q4 Plan\n"
        "\n"
        "1. Goals\n"
        "   - Grow\n"
        "   - Hire\n"
        "2. Risks\n"
        "   - Budget"
    )
    assert out == expected


def test_outline_export_with_sources():
    out = R.outline_export(
        {"title": "T"},
        sections=[{"heading": "H", "order": 1, "bullets": "b1"}],
        include_sources=True,
        items=[
            {"kind": "source", "text": "WHO report", "ref": "who.int"},
            {"kind": "source", "ref": "data.gov.bd"},
            {"kind": "note", "text": "ignored"},
        ],
    )
    assert "Sources:" in out
    assert "- WHO report (who.int)" in out
    assert "- data.gov.bd" in out
    assert "ignored" not in out  # notes are never exported as sources


def test_outline_export_empty():
    assert R.outline_export({"title": ""}, sections=[]) == ""


# --------------------------------------------------------------- seam
def test_ai_seam_is_honest_and_empty():
    r = R.ai_seam("GDP of Bangladesh", task="research")
    assert r["required"] is True and r["mock"] is True
    assert r["result"] == ""             # never fabricates a researched fact
    assert r["marker"] == R.AI_MARKER_KEY
    assert r["topic"] == "GDP of Bangladesh"


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"pa_research: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
